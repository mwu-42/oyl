import AppKit
import SwiftUI

/// ⌘-dragging something off the shelf sends it off. It's used wherever it's dropped (a chat, a
/// mail, a folder, an app), and then it's gone from the Mac, into the Trash. If the drag is let go
/// nowhere, nothing happens to it.
///
/// What's dragged out is a copy, set aside in Oyl's caches. On the same disk it's a clone, so it
/// takes no room and costs nothing to make. The original can go into the Trash as soon as the drop
/// lands, even though the app it went to may not have read it yet: a browser uploads it a moment
/// later, the Finder copies it in its own time, an app opens it as it starts up. The copies go a
/// day later, or right away if the drag landed nowhere.
enum SendOff {
    nonisolated static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oyl/Sent Off", isDirectory: true)
    }

    /// How long a copy is kept for the app it went to.
    nonisolated static let kept: TimeInterval = 24 * 3600
    /// The most that's copied when it can't be cloned (it's on another disk). Anything bigger
    /// goes out as a plain drag and stays put.
    nonisolated static let copiedMost = 100_000_000

    /// A copy of `url` under its own name, in a folder of its own in `folder`, or nil if it
    /// couldn't be made.
    nonisolated static func setAside(_ url: URL, in folder: URL = SendOff.folder) -> URL? {
        let files = FileManager.default
        let place = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = place.appendingPathComponent(url.lastPathComponent)
        do {
            try files.createDirectory(at: place, withIntermediateDirectories: true)
            if clonefile(url.path, copy.path, 0) != 0 {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? .max) <= copiedMost else {
                    try? files.removeItem(at: place)
                    return nil
                }
                try files.copyItem(at: url, to: copy)
            }
            return copy
        } catch {
            try? files.removeItem(at: place)
            return nil
        }
    }

    /// A copy that was set aside, gone along with its folder. Only one in `folder`, though.
    nonisolated static func discard(_ copy: URL, in folder: URL = SendOff.folder) {
        let place = copy.deletingLastPathComponent()
        guard place.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: place)
    }

    /// The copies set aside more than a day before `now`, gone.
    nonisolated static func sweep(_ folder: URL = SendOff.folder, now: Date = Date()) {
        let files = FileManager.default
        guard let places = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for place in places {
            let made = (try? place.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if now.timeIntervalSince(made) > kept { try? files.removeItem(at: place) }
        }
    }

    /// What macOS plays when something goes into the Trash, if its interface sounds are on.
    @MainActor static func chime() {
        let enabled = CFPreferencesCopyAppValue("com.apple.sound.uiaudio.enabled" as CFString, "com.apple.systemsound" as CFString)
        if let enabled = enabled as? NSNumber, !enabled.boolValue { return }
        trashSound?.stop()
        trashSound?.play()
    }

    @MainActor private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif",
        byReference: true)

    /// The picture as it's dragged to be sent off, `size` big: a Trash mark at its top right, so it's
    /// plain it won't be coming back. It matches the tile's own Trash button: a dark disc in Oyl's
    /// look, and ink ringed in silver with a starlight can in Midnight Oyl's.
    static func marked(_ picture: NSImage, size: NSSize, midnight: Bool) -> NSImage {
        let ink = midnight ? NSColor(Midnight.ink).withAlphaComponent(0.9) : NSColor.black.withAlphaComponent(0.7)
        let ring = NSColor(Midnight.silver).withAlphaComponent(0.7)
        let can = midnight ? NSColor(Midnight.starlight) : NSColor.white
        let symbol = NSImage(systemSymbolName: "trash", accessibilityDescription: "To the Trash")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [can])))
        return NSImage(size: size, flipped: false) { rect in
            picture.draw(in: rect)
            let side = min(18, max(12, rect.height * 0.3))
            let disc = NSRect(x: rect.maxX - side - 3, y: rect.maxY - side - 3, width: side, height: side)
            let round = NSBezierPath(ovalIn: disc)
            ink.setFill()
            round.fill()
            if midnight {
                ring.setStroke()
                round.lineWidth = 0.6
                round.stroke()
            }
            if let symbol {
                let drawn = symbol.size
                symbol.draw(in: NSRect(x: disc.midX - drawn.width / 2, y: disc.midY - drawn.height / 2,
                                       width: drawn.width, height: drawn.height))
            }
            return true
        }
    }
}
