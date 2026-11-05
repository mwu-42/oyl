import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A shelf, in Oyl's Dock: the latest screenshots and screen recordings as they're taken, or
/// (the other one) whatever's just been saved, and files dropped on it or made by converting, each
/// there to be dragged out into another app (or turned into another format first; see `Converter`).
///
/// Screenshots are the files in the folder screenshots go to (the Desktop, unless it's been
/// changed) that macOS has marked as screen captures, so nothing else there shows up. What's been
/// saved is what's newest in Downloads, where what comes by AirDrop goes, and downloads from a
/// browser, and attachments saved out of Messages (and what's been saved since into the folders in
/// it, two deep, as an app exports into a folder of its own there); what's come from elsewhere onto
/// the Desktop (an
/// attachment dragged out of Messages, say); and what's been saved into Photos from Messages and
/// the like (see `SavedPhotos`). Not what's still downloading, or screenshots (they're on theirs).
/// Watching starts the first time a shelf's opened, since reading these asks permission, and from
/// launch after that.
@MainActor
final class Shelf: ObservableObject {
    /// What a shelf watches for.
    enum Source: String {
        case screenshots, saved
    }

    struct Item: Identifiable, Equatable {
        enum Kind: String {
            /// Saved into a folder it watches, or (`photo`) into Photos, and copied out of there.
            case screenshot, recording, saved, photo, dropped, converted
        }

        let url: URL
        let kind: Kind
        let date: Date
        var id: URL { url }

        var isCapture: Bool { kind == .screenshot || kind == .recording }
        /// Found in the folder it watches, rather than put there.
        var isWatched: Bool { isCapture || kind == .saved || kind == .photo }
    }

    let source: Source

    @Published private(set) var items: [Item] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    /// Items being converted, and what into.
    @Published private(set) var converting: [URL: FileFormat] = [:]
    /// What went wrong converting an item, said on it for a few seconds.
    @Published private(set) var failures: [URL: String] = [:]
    /// The file just made, picked out for a moment.
    @Published private(set) var fresh: URL?
    /// The folder it watches couldn't be read: permission to it was turned down.
    @Published private(set) var isBlocked = false
    /// What each screenshot and recording shows, in a few words (see `ScreenshotLabeler`), by
    /// path: empty for one there was nothing to go by in. Kept across launches, so each is only
    /// looked at once.
    @Published private(set) var labels: [String: String]

    static let shownWatched = 12
    static let keptMost = 12
    /// Still downloading, under these: Safari's, Chrome's (and the like), Firefox's, Opera's.
    nonisolated private static let unfinished: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]

    /// A folder it watches, and whether only what came from elsewhere counts there.
    struct Watched: Equatable {
        let folder: URL
        var onlyReceived = false
        /// How far into the folders in it what's saved there is looked for.
        var depth = 0
    }

    private var folders: [Watched] = []
    private var watchers: [DispatchSourceFileSystemObject] = []
    /// For the folders looked into: changes anywhere under them.
    private var deepWatcher: FolderEvents?
    private var photos: SavedPhotos?
    /// What's been saved into Photos, copied out.
    private var fromPhotos: [Item] = []
    private var scanning: DispatchWorkItem?
    /// And again a little after.
    private var rescanning: DispatchWorkItem?
    /// What's in the folder it watches.
    private var watched: [Item] = []
    private var kept: [Item]
    /// What's been taken off the shelf from there (it stays where it is).
    private var hidden: [String]
    private var loading: Set<URL> = []
    private var sharing: NSSharingService?
    /// Waiting to be labeled, newest first; one's labeled at a time.
    private var unlabeled: [Item] = []
    private var labeling: URL?
    /// Screenshots and recordings taken since then are renamed to their labels as soon as they
    /// have them, if they've still the names macOS gave them (older ones only when asked).
    private let renamingSince: Date

    init(_ source: Source) {
        self.source = source
        let saved = UserDefaults.standard.array(forKey: Self.key("kept", source)) as? [[String: Any]] ?? []
        kept = saved.compactMap { entry in
            guard let path = entry["path"] as? String, let kind = (entry["kind"] as? String).flatMap(Item.Kind.init) else { return nil }
            return Item(url: URL(fileURLWithPath: path), kind: kind, date: entry["date"] as? Date ?? .distantPast)
        }
        hidden = UserDefaults.standard.stringArray(forKey: Self.key("hidden", source)) ?? []
        labels = UserDefaults.standard.dictionary(forKey: Self.key("labels", source)) as? [String: String] ?? [:]
        if UserDefaults.standard.object(forKey: "shelf.renamingSince") == nil { UserDefaults.standard.set(Date(), forKey: "shelf.renamingSince") }
        renamingSince = UserDefaults.standard.object(forKey: "shelf.renamingSince") as? Date ?? Date()
        if UserDefaults.standard.bool(forKey: Self.key("watching", source)), isOn { watch(asking: false) }
        refresh()
    }

    /// Where its settings are kept: the screenshots' shelf's as they always were.
    static func key(_ name: String, _ source: Source) -> String {
        source == .screenshots ? "shelf.\(name)" : "shelf.\(source.rawValue).\(name)"
    }

    private func key(_ name: String) -> String { Self.key(name, source) }

    /// The shelf is in the Dock (it can be turned off).
    var isOn: Bool { (source == .saved ? Feature.savedShelf : Feature.screenshotsShelf).isOn }

    /// Turned off: its folders (and Photos) aren't watched, till it's back and opened again.
    func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers = []
        deepWatcher?.cancel()
        deepWatcher = nil
        folders = []
        photos?.stop()
        photos = nil
        scanning?.cancel()
        rescanning?.cancel()
    }

    /// Watches its folders (again, if where screenshots go has changed), and for what's been saved,
    /// Photos too: asking to see it, if it hasn't yet, only once the shelf's opened (`asking`).
    func watch(asking: Bool = true) {
        guard isOn else { return }
        UserDefaults.standard.set(true, forKey: key("watching"))
        if source == .saved {
            if photos == nil {
                let photos = SavedPhotos()
                photos.changed = { [weak self] items in
                    self?.fromPhotos = items
                    self?.refresh()
                }
                self.photos = photos
            }
            photos?.start(asking: asking)
        }
        let folders = watchedFolders
        guard folders != self.folders else {
            scan()
            return
        }
        watchers.forEach { $0.cancel() }
        watchers = []
        deepWatcher?.cancel()
        // A folder looked into is told of changes anywhere under it, which watching it alone isn't.
        deepWatcher = FolderEvents(folders.filter { $0.depth > 0 }.map(\.folder)) { [weak self] in
            MainActor.assumeIsolated { self?.scanSoon() }
        }
        self.folders = folders
        for watched in folders where watched.depth == 0 {
            let descriptor = Darwin.open(watched.folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                                    queue: .main)
            watcher.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scanSoon() }
            }
            watcher.setCancelHandler { close(descriptor) }
            watcher.resume()
            watchers.append(watcher)
        }
        scan()
    }

    /// The folders it watches: the first is the one it's for.
    var watchedFolders: [Watched] {
        switch source {
        case .screenshots:
            return [Watched(folder: Self.screenshotFolder())]
        case .saved:
            let home = FileManager.default.homeDirectoryForCurrentUser
            return [Watched(folder: home.appendingPathComponent("Downloads", isDirectory: true), depth: 2),
                    Watched(folder: home.appendingPathComponent("Desktop", isDirectory: true), onlyReceived: true)]
        }
    }

    var watchedFolder: URL { watchedFolders[0].folder }

    /// Where screenshots are saved: as set in the Screenshot app's options, or the Desktop.
    static func screenshotFolder() -> URL {
        let set = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        if let set, !set.isEmpty {
            let path = (set as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// A screenshot's written, then marked as one a moment later: looked for once things settle,
    /// and again a little after.
    private func scanSoon() {
        scanning?.cancel()
        rescanning?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        let again = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        scanning = work
        rescanning = again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: again)
    }

    private func scan() {
        let folders = folders
        guard !folders.isEmpty else { return }
        let source = source
        DispatchQueue.global(qos: .utility).async {
            let keys: Set<URLResourceKey> = [.creationDateKey, .addedToDirectoryDateKey, .isRegularFileKey, .isDirectoryKey]
            var found: [Item] = []
            var blocked = false
            for (index, watched) in folders.enumerated() {
                do {
                    let urls = try FileManager.default.contentsOfDirectory(at: watched.folder, includingPropertiesForKeys: Array(keys),
                                                                           options: [.skipsHiddenFiles])
                    found += urls.compactMap { url -> Item? in
                        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                        return Self.item(url, values, source: source, onlyReceived: watched.onlyReceived)
                    }
                    if watched.depth > 0 { found += Self.savedInside(urls, depth: watched.depth) }
                } catch {
                    // The rest it can do without.
                    if index == 0 { blocked = true }
                }
            }
            found.sort { $0.date > $1.date }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isBlocked = blocked
                    self.watched = Array(found.prefix(Self.shownWatched * 2))
                    self.refresh()
                }
            }
        }
    }

    /// One of the folder's files, if it's one this shelf has: a screenshot or recording, or a file
    /// or folder that's done downloading (and, `onlyReceived`, came from elsewhere), as of when it
    /// got there.
    nonisolated static func item(_ url: URL, _ values: URLResourceValues, source: Source, onlyReceived: Bool = false) -> Item? {
        switch source {
        case .screenshots:
            guard isScreenCapture(url), values.isRegularFile == true else { return nil }
            let movie = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
            return Item(url: url, kind: movie ? .recording : .screenshot, date: values.creationDate ?? .distantPast)
        case .saved:
            guard values.isRegularFile == true || values.isDirectory == true, !unfinished.contains(url.pathExtension.lowercased()),
                  !isScreenCapture(url), !onlyReceived || isReceived(url) else { return nil }
            return Item(url: url, kind: .saved, date: values.addedToDirectoryDate ?? values.creationDate ?? .distantPast)
        }
    }

    /// What's been saved into the folders among `entries` (a watched folder's), up to `depth` down:
    /// each file (or folder) added to its folder over a minute (`margin`) after that folder came
    /// there itself, so a folder unzipped or moved in whole shows as itself, not each file in it.
    /// Only so many are looked through, in case one's huge.
    nonisolated static func savedInside(_ entries: [URL], depth: Int, margin: TimeInterval = 60) -> [Item] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .addedToDirectoryDateKey, .isRegularFileKey, .isDirectoryKey, .isPackageKey]
        var found: [Item] = []
        var budget = 4000
        func added(_ values: URLResourceValues) -> Date { values.addedToDirectoryDate ?? values.creationDate ?? .distantPast }
        func look(in folder: URL, came: Date, level: Int) {
            guard budget > 0, let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                                           options: [.skipsHiddenFiles]) else { return }
            for url in contents {
                budget -= 1
                guard budget > 0 else { return }
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                let since = added(values)
                if since > came.addingTimeInterval(margin) {
                    if let item = item(url, values, source: .saved) { found.append(item) }
                } else if values.isDirectory == true, values.isPackage != true, level < depth {
                    look(in: url, came: since, level: level + 1)
                }
            }
        }
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true, values.isPackage != true else { continue }
            look(in: url, came: added(values), level: 1)
        }
        return found
    }

    /// macOS marks what it captures with an extended attribute; a screenshot renamed is still one.
    nonisolated static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    /// Come from elsewhere: macOS marks what's downloaded (by Messages, AirDrop or a browser) as
    /// it's saved, and a copy dragged out keeps the mark. (What an app that's kept to itself makes
    /// is marked too, but not as downloaded.)
    nonisolated static func isReceived(_ url: URL) -> Bool {
        var mark = [UInt8](repeating: 0, count: 256)
        let length = getxattr(url.path, "com.apple.quarantine", &mark, mark.count, 0, 0)
        guard length > 0, let text = String(bytes: mark.prefix(length), encoding: .utf8),
              let flags = text.split(separator: ";").first.flatMap({ UInt32($0, radix: 16) }) else { return false }
        return flags & 0x1 != 0
    }

    private func refresh() {
        let files = FileManager.default
        let shots = (watched + fromPhotos).sorted { $0.date > $1.date }.filter { !hidden.contains($0.url.path) }.prefix(Self.shownWatched)
        let shown = Set(shots.map(\.url))
        let others = kept.filter { !shown.contains($0.url) && files.fileExists(atPath: $0.url.path) }
        let all = (Array(shots) + others).sorted { $0.date > $1.date }
        if all != items { items = all }
        let urls = Set(all.map(\.url))
        let current = thumbnails.filter { urls.contains($0.key) }
        if current.count != thumbnails.count { thumbnails = current }
        for item in all where thumbnails[item.url] == nil { makeThumbnail(for: item.url) }
        unlabeled = all.filter { $0.isCapture && labels[$0.url.path] == nil && $0.url != labeling }
        labelNext()
    }

    /// The label for an item, once there is one.
    func label(for item: Item) -> String? {
        labels[item.url.path].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Off the main thread, in the background, one at a time.
    private func labelNext() {
        guard labeling == nil, Feature.labelScreenshots.isOn, let item = unlabeled.first else { return }
        unlabeled.removeFirst()
        let url = item.url, movie = item.kind == .recording
        labeling = url
        Task { @MainActor [weak self] in
            let label = await Task.detached(priority: .utility) { await ScreenshotLabeler.label(for: url, movie: movie) }.value
            guard let self else { return }
            self.labeling = nil
            self.labels[url.path] = label ?? ""
            self.saveLabels()
            if label != nil, item.date >= self.renamingSince, Self.hasMacOSName(url), FileManager.default.fileExists(atPath: url.path) {
                self.renameToLabel(item)
            }
            self.labelNext()
        }
    }

    /// Only those still about, or that might be again (taken off the shelf), and not too many.
    private func saveLabels() {
        let files = FileManager.default
        if labels.count > 200 { labels = labels.filter { files.fileExists(atPath: $0.key) } }
        UserDefaults.standard.set(labels, forKey: key("labels"))
    }

    private func makeThumbnail(for url: URL) {
        guard !loading.contains(url) else { return }
        loading.insert(url)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 140, height: 90), scale: 2,
                                                   representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.loading.remove(url)
                    guard self.items.contains(where: { $0.url == url }) else { return }
                    self.thumbnails[url] = image ?? NSWorkspace.shared.icon(forFile: url.path)
                }
            }
        }
    }

    // MARK: Keeping and taking off

    /// Files dropped on the shelf (or just made), newest first; the oldest go once there are too many.
    func keep(_ urls: [URL], as kind: Item.Kind = .dropped) {
        let showing = Set(items.map(\.url))
        for url in urls.map(\.standardizedFileURL) where kind == .converted || !showing.contains(url) {
            kept.removeAll { $0.url == url }
            kept.insert(Item(url: url, kind: kind, date: Date()), at: 0)
        }
        kept = Array(kept.prefix(Self.keptMost))
        saveKept()
        refresh()
    }

    /// Off the shelf. The file itself stays where it is.
    func remove(_ item: Item) {
        if item.isWatched {
            hidden.append(item.url.path)
            hidden = Array(hidden.suffix(100))
            UserDefaults.standard.set(hidden, forKey: key("hidden"))
        }
        kept.removeAll { $0.url == item.url }
        saveKept()
        refresh()
    }

    /// Into the Trash, and so off the shelf.
    func trash(_ item: Item) {
        // A copy out of Photos is only taken off: it's in Photos still.
        guard item.kind != .photo else {
            remove(item)
            return
        }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        } catch {
            fail(item.url, "Couldn't move it to the Trash")
            return
        }
        watched.removeAll { $0.url == item.url }
        remove(item)
    }

    private func saveKept() {
        let entries: [[String: Any]] = kept.map { ["path": $0.url.path, "kind": $0.kind.rawValue, "date": $0.date] }
        UserDefaults.standard.set(entries, forKey: key("kept"))
    }

    // MARK: Converting

    /// Converts in the background; what it makes goes on the shelf, first, picked out for a moment.
    func convert(_ item: Item, to format: FileFormat) {
        guard converting[item.url] == nil else { return }
        converting[item.url] = format
        failures[item.url] = nil
        Task { @MainActor in
            do {
                let made = try await Converter.convert(item.url, to: format)
                converting[item.url] = nil
                keep([made], as: .converted)
                let shown = made.standardizedFileURL
                fresh = shown
                try? await Task.sleep(for: .seconds(3))
                if fresh == shown { fresh = nil }
            } catch {
                converting[item.url] = nil
                fail(item.url, (error as? LocalizedError)?.errorDescription ?? "Couldn't convert it")
            }
        }
    }

    private func fail(_ url: URL, _ reason: String) {
        failures[url] = reason
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                if self?.failures[url] == reason { self?.failures[url] = nil }
            }
        }
    }

    // MARK: Using

    func open(_ item: Item) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// To someone nearby: macOS's own AirDrop window comes up to pick who to.
    func airDrop(_ item: Item) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [item.url]) else { return }
        // Held while its window's up.
        sharing = service
        // Oyl's never in front, and the window would come up behind whatever is.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [item.url])
    }

    /// Still called what macOS called it: "Screenshot 2026-11-01 at 10.23.45 PM", say, or by the
    /// name screenshots have been set to have.
    private static func hasMacOSName(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        let custom = CFPreferencesCopyAppValue("name" as CFString, "com.apple.screencapture" as CFString) as? String
        return (["Screenshot", "Screen Shot", "Screen Recording"] + [custom].compactMap { $0 }).contains { name.hasPrefix($0 + " ") }
    }

    /// The file renamed to its label (and a number, if that's taken), where it is.
    func renameToLabel(_ item: Item) {
        guard let label = label(for: item) else { return }
        let name = label.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -").trimmingCharacters(in: .whitespaces)
        let folder = item.url.deletingLastPathComponent(), type = item.url.pathExtension
        func named(_ number: Int) -> URL {
            folder.appendingPathComponent(number == 1 ? name : "\(name) \(number)").appendingPathExtension(type)
        }
        var number = 1
        while FileManager.default.fileExists(atPath: named(number).path) { number += 1 }
        let renamed = named(number)
        do {
            try FileManager.default.moveItem(at: item.url, to: renamed)
        } catch {
            fail(item.url, "Couldn't rename it")
            return
        }
        // It's the same screenshot, still marked as one: everything about it goes with it.
        let moved = Item(url: renamed, kind: item.kind, date: item.date)
        labels[renamed.path] = labels.removeValue(forKey: item.url.path)
        thumbnails[renamed] = thumbnails.removeValue(forKey: item.url)
        watched = watched.map { $0.url == item.url ? moved : $0 }
        kept = kept.map { $0.url == item.url ? moved : $0 }
        saveLabels()
        saveKept()
        refresh()
    }

    /// The file, to paste into a chat or a folder; a picture's pixels too, for apps that only take those.
    func copy(_ item: Item) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let entry = NSPasteboardItem()
        entry.setString(item.url.absoluteString, forType: .fileURL)
        if Converter.kind(of: item.url) == .image, let image = NSImage(contentsOf: item.url), let tiff = image.tiffRepresentation {
            entry.setData(tiff, forType: .tiff)
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { entry.setData(png, forType: .png) }
        }
        pasteboard.writeObjects([entry])
    }
}

/// Drags out of the shelf, as the files themselves. The Dock listens in, to get out of the way
/// of wherever they're going (see `DockController`).
@MainActor
final class ShelfDrag: NSObject, NSDraggingSource {
    static let shared = ShelfDrag()

    /// Where the pointer's got to, in screen coordinates.
    var moved: (NSPoint) -> Void = { _ in }
    /// Where it was let go.
    var ended: (NSPoint) -> Void = { _ in }
    private(set) var isDragging = false

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Into Oyl's own Dock too: onto an app there.
        context == .outsideApplication ? [.copy, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        isDragging = true
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        moved(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        ended(screenPoint)
    }
}

/// Changes anywhere under some folders, as FSEvents tells of them (a file saved into a folder in
/// one, which watching the folder itself doesn't hear), a moment's worth at a time, on the main
/// queue.
final class FolderEvents {
    private var stream: FSEventStreamRef?
    private let changed: () -> Void

    init?(_ folders: [URL], changed: @escaping () -> Void) {
        self.changed = changed
        guard !folders.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                                           copyDescription: nil)
        let told: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderEvents>.fromOpaque(info).takeUnretainedValue().changed()
        }
        guard let stream = FSEventStreamCreate(nil, told, &context, folders.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func cancel() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { cancel() }
}
