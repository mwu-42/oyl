import AppKit
import SwiftUI

/// Oyl's app icon: just Oyl, drawn by the app's own `OylDrawing`, big and looking out, on a
/// plain dark tile. Run by `make.sh`, which writes `Oyl.icns` from it.
struct OylIcon: View {
    /// The macOS icon grid: a 1024 canvas, the rounded square 824 across in the middle of it.
    static let canvas: CGFloat = 1024
    static let side: CGFloat = 824
    static let corner: CGFloat = 185

    var body: some View {
        let square = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        ZStack {
            ZStack {
                LinearGradient(colors: [Color(white: 0.2), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
                // Oyl, looking straight out (its look swings back to the middle at this moment),
                // eyes open, filling the tile: 12 points to its unit, its spikes to its feet about
                // 49 units, with its middle a little above the drawing's.
                Canvas { canvas, size in
                    OylDrawing(canvas: canvas, size: size, time: 2 * .pi / 0.45, beat: 0, skin: Oyl.white)
                        .draw(.idle, hat: false, walking: false, surfing: false)
                }
                .frame(width: 1200, height: 600)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
                .position(x: Self.side / 2, y: Self.side / 2 + 36)
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(square)
            .overlay(square.strokeBorder(.white.opacity(0.08), lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 10)
        }
        .frame(width: Self.canvas, height: Self.canvas)
    }
}

@main
@MainActor
enum MakeIcon {
    /// `Icon <folder>`: the iconset's PNGs, and a 1024 preview beside them.
    static func main() {
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Oyl.iconset", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
            for scale in scales {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                write(pixels: points * scale, to: folder.appendingPathComponent(name))
            }
        }
    }

    private static func write(pixels: Int, to url: URL) {
        let renderer = ImageRenderer(content: OylIcon().environment(\.displayScale, 2))
        renderer.scale = CGFloat(pixels) / OylIcon.canvas
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: pixels, height: pixels)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
