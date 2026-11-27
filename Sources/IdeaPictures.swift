import AppKit
import ImageIO
import SwiftUI

/// A screenshot picked out by hand, and pictures read small (a project's screenshots, see
/// `ProjectStore`).
@MainActor
enum IdeaPictures {
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

