import AppKit
import Photos

/// What's been saved into the Photos library from other apps, for the Recently Saved shelf: from
/// Messages (Add to Photos Library, Save Photo), Safari and the like, here or on an iPhone, but not
/// what a camera took or a screenshot. Each is copied out of the library into Oyl's own folder,
/// so it's a file like everything else on the shelf, to drag into another app.
///
/// Photos says who brought each in, though not publicly: as forensic research on its database has
/// it, 1 and 2 are the iPhone's cameras, the rest apps. Where it doesn't say, something's taken to
/// have been saved if it was added well after it was made, as nothing a camera takes is.
@MainActor
final class SavedPhotos: NSObject, PHPhotoLibraryChangeObserver {
    /// The newest saved, as files, newest first, once they've been copied out.
    var changed: ([Shelf.Item]) -> Void = { _ in }

    /// As many as the shelf shows.
    nonisolated static let most = 12
    /// How long ago it can have been saved to count.
    nonisolated static let within: TimeInterval = 30 * 24 * 3600
    nonisolated static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Oyl/Saved Photos", isDirectory: true)

    private var observing = false
    private var looking: DispatchWorkItem?

    /// Looks at the library, and from then on whenever it changes: if Oyl's been allowed to,
    /// or (`asking`) once it has, asking if it hasn't been yet.
    func start(asking: Bool) {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            begin()
        case .notDetermined where asking:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                guard status == .authorized || status == .limited else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.begin() } }
            }
        default:
            break
        }
    }

    /// Stops looking at the library.
    func stop() {
        looking?.cancel()
        guard observing else { return }
        observing = false
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    private func begin() {
        if !observing {
            observing = true
            PHPhotoLibrary.shared().register(self)
        }
        look()
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.lookSoon() } }
    }

    /// A sync brings changes in bursts: once they've settled.
    private func lookSoon() {
        looking?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.look() }
        }
        looking = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func look() {
        DispatchQueue.global(qos: .utility).async {
            let saved = Self.newestSaved()
            Self.clearOut(keeping: Set(saved.map { Self.place(for: $0.asset).lastPathComponent }))
            Self.copyOut(saved) { items in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.changed(items) } }
            }
        }
    }

    // MARK: Which

    /// The newest saved to the library, and when each was.
    nonisolated private static func newestSaved() -> [(asset: PHAsset, added: Date)] {
        // What's been added lately, if Photos keeps that; otherwise the library, the newest last.
        let recent = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumRecentlyAdded, options: nil).firstObject
        let assets = recent.map { PHAsset.fetchAssets(in: $0, options: nil) } ?? PHAsset.fetchAssets(with: nil)
        let since = Date().addingTimeInterval(-within)
        var found: [(asset: PHAsset, added: Date)] = []
        for index in stride(from: assets.count - 1, through: max(0, assets.count - 1500), by: -1) {
            let asset = assets.object(at: index)
            guard asset.mediaType == .image || asset.mediaType == .video, let added = addedDate(of: asset), added > since,
                  wasSaved(importedBy: importedBy(asset), screenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                           created: asset.creationDate, added: added) else { continue }
            found.append((asset, added))
        }
        return Array(found.sorted { $0.added > $1.added }.prefix(most))
    }

    /// Brought in from an app, rather than taken there and then: by who Photos says brought it in
    /// (not a camera), or failing that, or for a screenshot, by its having been added well after it
    /// was made (one sent you, rather than one of your own).
    nonisolated static func wasSaved(importedBy: Int?, screenshot: Bool, created: Date?, added: Date) -> Bool {
        if importedBy == 1 || importedBy == 2 { return false }
        if let importedBy, importedBy != 0, !screenshot { return true }
        guard let created else { return false }
        return added.timeIntervalSince(created) > 60
    }

    nonisolated private static func addedDate(of asset: PHAsset) -> Date? {
        if #available(macOS 26, *) { return asset.addedDate }
        return nil
    }

    /// Who Photos says brought it in, if it says (it doesn't publicly, so only if it still can).
    nonisolated private static func importedBy(_ asset: PHAsset) -> Int? {
        guard asset.responds(to: NSSelectorFromString("importProperties")),
              let properties = asset.value(forKey: "importProperties") as? NSObject,
              properties.responds(to: NSSelectorFromString("importedBy")) else { return nil }
        return (properties.value(forKey: "importedBy") as? NSNumber)?.intValue
    }

    // MARK: As files

    /// Its own folder in Oyl's, by its identifier (anything a converted copy's put beside it
    /// stays with it).
    nonisolated private static func place(for asset: PHAsset) -> URL {
        let name = asset.localIdentifier.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return folder.appendingPathComponent(String(name), isDirectory: true)
    }

    /// The original, which is what was saved (a Live Photo's still).
    nonisolated private static func original(of asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let wanted: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        return resources.first { $0.type == wanted } ?? resources.first
    }

    /// Each copied out, if it isn't already (from iCloud, if it's only there), then all of them told.
    nonisolated private static func copyOut(_ saved: [(asset: PHAsset, added: Date)], done: @escaping @Sendable ([Shelf.Item]) -> Void) {
        let files = FileManager.default
        let group = DispatchGroup()
        let lock = NSLock()
        var made: [(url: URL, added: Date)] = []
        for (asset, added) in saved {
            guard let resource = original(of: asset) else { continue }
            let place = place(for: asset)
            let url = place.appendingPathComponent(resource.originalFilename.replacingOccurrences(of: "/", with: "-"))
            if files.fileExists(atPath: url.path) {
                made.append((url, added))
                continue
            }
            try? files.createDirectory(at: place, withIntermediateDirectories: true)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            group.enter()
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if error == nil {
                    lock.withLock { made.append((url, added)) }
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .utility)) {
            let items = lock.withLock { made }.sorted { $0.added > $1.added }.map { Shelf.Item(url: $0.url, kind: .photo, date: $0.added) }
            done(items)
        }
    }

    /// The copies of what's no longer among the newest, gone (and their folders, if nothing else
    /// is in them).
    nonisolated private static func clearOut(keeping: Set<String>) {
        let files = FileManager.default
        guard let places = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for place in places where !keeping.contains(place.lastPathComponent) {
            let inside = (try? files.contentsOfDirectory(atPath: place.path)) ?? []
            if inside.count <= 1 { try? files.removeItem(at: place) }
        }
    }
}
