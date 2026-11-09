import AppKit
import ImageIO
import SwiftUI

/// Screenshots ideas are jotted about: taken from the ideas page's camera (an area picked out by
/// hand, as ⇧⌘4 has you), kept in Oyl's own folder named for the idea's id in tod (tod keeps only
/// the idea itself), and shown small on its row, a click from opening and a drag from a chat.
@MainActor
final class IdeaPictures: ObservableObject {
    /// The ideas that have one.
    @Published private(set) var ids: Set<String> = []
    let folder: URL
    private var thumbnails: [String: NSImage] = [:]

    nonisolated static var ownFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oyl/Ideas", isDirectory: true)
    }

    init(folder: URL = IdeaPictures.ownFolder) {
        self.folder = folder
        let kept = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        ids = Set(kept.filter { $0.pathExtension == "png" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    /// The idea `id`'s screenshot, if it has one.
    func url(for id: String) -> URL? {
        ids.contains(id) ? file(for: id) : nil
    }

    /// Small, to show on its row (made once).
    func thumbnail(for id: String) -> NSImage? {
        if let made = thumbnails[id] { return made }
        guard let url = url(for: id), let made = Self.thumbnail(of: url) else { return nil }
        thumbnails[id] = made
        return made
    }

    /// `shot` moved in as the idea `id`'s screenshot: whether it was.
    @discardableResult
    func keep(_ shot: URL, for id: String) -> Bool {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return false }
        let files = FileManager.default, target = file(for: id)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try files.moveItem(at: shot, to: target)
        } catch {
            return false
        }
        thumbnails[id] = nil
        ids.insert(id)
        return true
    }

    /// The screenshots of ideas gone from tod altogether (not only done: one checked off can be
    /// brought back) moved to the Trash, once they're a day old, so one whose idea hasn't reached
    /// tod yet is never lost. (`discard` is for a test to give.)
    func prune(keeping kept: Set<String>, now: Date = Date(),
               discard: (URL) -> Void = { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        for id in ids.subtracting(kept) {
            let url = file(for: id)
            let taken = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            guard now.timeIntervalSince(taken) > 86_400 else { continue }
            discard(url)
            ids.remove(id)
            thumbnails[id] = nil
        }
    }

    private func file(for id: String) -> URL {
        folder.appendingPathComponent(id).appendingPathExtension("png")
    }

    /// A picture `size` pixels across at most, read without the whole of it.
    nonisolated static func thumbnail(of url: URL, size: Int = 160) -> NSImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// An area of the screen picked out by hand, as ⇧⌘4 has you (Space for a window, Escape to
    /// call it off), by macOS's own `screencapture`: where it's saved, or nil if it was called off.
    static func take(_ done: @escaping @MainActor (URL?) -> Void) {
        let shot = FileManager.default.temporaryDirectory.appendingPathComponent("Oyl idea \(UUID().uuidString).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // A window without its shadow.
        capture.arguments = ["-i", "-o", shot.path]
        capture.terminationHandler = { _ in
            let taken = FileManager.default.fileExists(atPath: shot.path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(taken ? shot : nil) }
            }
        }
        do {
            try capture.run()
        } catch {
            done(nil)
        }
    }
}

/// What's being jotted on the ideas page, kept while the notch is closed (as it is while a
/// screenshot's taken for it): the words, the screenshot they're about if there is one, and
/// whether the field's to take the keyboard as it comes up.
@MainActor
final class IdeaDraft: ObservableObject {
    @Published var text = ""
    /// A screenshot just taken, no idea's yet.
    @Published private(set) var shot: URL?
    private(set) var shotImage: NSImage?
    @Published var wantsKeyboard = false

    /// `url` is the screenshot the idea's about (in place of any before it).
    func attach(_ url: URL) {
        drop()
        shotImage = IdeaPictures.thumbnail(of: url)
        shot = url
    }

    /// The screenshot let go of, and its file with it, since no idea has it.
    func drop() {
        if let shot { try? FileManager.default.removeItem(at: shot) }
        shotImage = nil
        shot = nil
    }

    /// The screenshot, handed over to the idea it's about: no longer the draft's.
    func handOver() -> URL? {
        defer {
            shotImage = nil
            shot = nil
        }
        return shot
    }
}

/// A screenshot an idea's about, small: in Oyl's look, rounded, with a hairline round it; in
/// Midnight Oyl's, its color paled a little toward moonlight and its edges feathered into the
/// night, with nothing round it.
struct IdeaShot: View {
    let image: NSImage
    var width: CGFloat = 28
    var height: CGFloat = 18
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let picture = Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: width, height: height)
            .clipped()
        if theme == .midnight {
            picture
                .saturation(0.65)
                .mask(RoundedRectangle(cornerRadius: 3).padding(1.5).blur(radius: 1.5))
                .shadow(color: Midnight.moonlight.opacity(0.3), radius: 3)
        } else {
            let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
            picture
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
        }
    }
}
