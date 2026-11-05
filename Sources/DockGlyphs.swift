import AppKit
import simd

/// An app's icon redrawn for Oyl's Dock: its glyph lifted off its tile (what stands out from the
/// tile's own colors), as a mask, and traced round its edges, with spots along them for Midnight
/// Oyl's glints. Made once an app's first shown, off the main thread.
struct DockGlyph: @unchecked Sendable {
    /// White where the glyph is, clear elsewhere, `side` pixels square.
    let mask: CGImage
    /// White along the glyph's edges.
    let outline: CGImage
    /// Where its glints go along the edges, 0...1 from the top left.
    let sparkles: [CGPoint]

    static let side = 192
}

enum DockGlyphs {
    /// What stands out from the tile it's on: the tile's colors (sampled round the inside of its
    /// edge, and taken as running smoothly across it, for a gradient) set against each pixel's,
    /// those far enough off them the glyph. Nil if that's next to nothing or all of it (a picture
    /// of an icon, with no one glyph on it).
    nonisolated static func lift(_ icon: CGImage) -> DockGlyph? {
        liftedMask(icon).flatMap(finish)
    }

    /// Just the first letter of what's lifted (the C of the name on Canva's icon), made as big as a
    /// glyph is: the part of it furthest left, or, where the letters are joined up (as script's
    /// are), what's left of the next one with a hole in it (Canva's a), cut off at its outside.
    nonisolated static func liftFirstLetter(_ icon: CGImage) -> DockGlyph? {
        // Lifted twice as fine, since it's made so much bigger.
        let side = DockGlyph.side * 2
        guard let mask = liftedMask(icon, side: side), let first = Parts(mask, side: side).first else { return nil }
        guard first.bounds.width > first.bounds.height * 1.6 else { return finish(fitted(first.mask, side: side, in: first.bounds)) }
        guard let hole = Parts.holes(in: first.mask, side: side).first else { return nil }
        // Out from the hole's left side, along its middle, to the letter's own outside.
        let row = Int(hole.midY)
        var cut = Int(hole.minX) - 1
        while cut > Int(first.bounds.minX), first.mask[row * side + cut] > 0.5 { cut -= 1 }
        var letter = first.mask
        for y in 0..<side { for x in max(cut, 0)..<side { letter[y * side + x] = 0 } }
        guard let part = Parts(letter, side: side).parts.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
              part.bounds.width > 4 else { return nil }
        return finish(fitted(part.mask, side: side, in: part.bounds))
    }

    /// Google's G, for Chrome: a ring open at the top right, and its bar in from the right to the
    /// middle.
    @MainActor
    static func googleG() -> DockGlyph? {
        let side = DockGlyph.side
        guard let context = Pixels.context(side: side) else { return nil }
        let middle = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        let outer = CGFloat(side) * 0.28, width = outer * 0.38
        // (The context counts up from the bottom, so angles go anticlockwise.)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(width)
        context.addArc(center: middle, radius: outer - width / 2, startAngle: .pi * 42 / 180, endAngle: 2 * .pi, clockwise: false)
        context.strokePath()
        context.fill(CGRect(x: middle.x - outer * 0.02, y: middle.y - width / 2, width: outer * 1.02, height: width))
        guard let image = context.makeImage(), let pixels = Pixels(image, side: side) else { return nil }
        return finish((0..<side * side).map { pixels.alpha($0 % side, $0 / side) })
    }

    /// Only what's brightest on an icon: Activity Monitor's pulse, glowing white across its
    /// screen, without the dimmer grid behind it (which `lift` would take too). Looked at nearly
    /// to the tile's edge, since the pulse runs right off it.
    nonisolated static func liftBrightest(_ icon: CGImage) -> DockGlyph? {
        let side = DockGlyph.side
        guard let pixels = Pixels(icon, side: side), let tile = pixels.solidBounds(), tile.width > CGFloat(side) / 3 else { return nil }
        let inner = tile.insetBy(dx: tile.width * 0.06, dy: tile.height * 0.06)
        var mask = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side where inner.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                let color = pixels.color(x, y)
                mask[y * side + x] = smoothstep(0.62, 0.8, 0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z)
            }
        }
        mask = Morphology.cleaned(mask, side: side)
        guard mask.reduce(0, +) > Float(side * side) / 400 else { return nil }
        return finish(mask)
    }

    /// What's lifted off an icon, as a mask `side` pixels square (see `lift`).
    private nonisolated static func liftedMask(_ icon: CGImage, side: Int = DockGlyph.side) -> [Float]? {
        guard let pixels = Pixels(icon, side: side) else { return nil }
        // The tile: what's solid. A rounded square inside its edge is what's looked at, clear of
        // its rim and the glass's shine there.
        guard let tile = pixels.solidBounds(), tile.width > CGFloat(side) / 3 else { return nil }
        let inner = tile.insetBy(dx: tile.width * 0.085, dy: tile.height * 0.085)
        let corner = inner.width * 0.2
        let ring = (0..<96).map { index in point(onRoundedRect: inner.insetBy(dx: 2, dy: 2), corner: corner, at: Double(index) / 96) }
        // Its corners, where a glyph's least likely to reach: a few spots in each, toward the tile's.
        let corners = [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)].flatMap { side -> [CGPoint] in
            let middle = CGPoint(x: side.0 < 0 ? inner.minX + corner : inner.maxX - corner,
                                 y: side.1 < 0 ? inner.minY + corner : inner.maxY - corner)
            return [-0.25, 0, 0.25].map { turn in
                let angle = atan2(side.1, side.0) + turn
                return CGPoint(x: middle.x + cos(angle) * corner * 0.7, y: middle.y + sin(angle) * corner * 0.7)
            }
        }
        let sample = { (point: CGPoint) in (pixels.uv(point), pixels.color(around: point)) }
        guard let background = Plane.fit(corners: corners.map(sample), edge: ring.map(sample)) else { return nil }

        var mask = [Float](repeating: 0, count: side * side), area = 0
        for y in 0..<side {
            for x in 0..<side {
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                let inside = depth(of: point, in: inner, corner: corner)
                guard inside > 0 else { continue }
                area += 1
                let off = distance(pixels.color(x, y), background.color(at: pixels.uv(point)))
                let edge = Float(min(inside / 3, 1))
                mask[y * side + x] = smoothstep(0.08, 0.2, off) * edge
            }
        }
        mask = Morphology.cleaned(mask, side: side)
        let covered = mask.reduce(0, +) / Float(max(area, 1))
        // (A glyph can all but fill its tile, as Spotify's circle does, its waves cut out of it.)
        guard covered > 0.015, covered < 0.97 else { return nil }
        return mask
    }

    /// A piece of a mask `source` pixels square, moved to the middle of a glyph's and scaled to be
    /// as big as a glyph is (as Finder's magnifying glass is): its longer side 56% of the whole.
    private nonisolated static func fitted(_ mask: [Float], side source: Int, in bounds: CGRect) -> [Float] {
        let side = DockGlyph.side
        let scale = CGFloat(side) * 0.56 / max(bounds.width, bounds.height)
        var out = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                // Where this pixel comes from, read between the four round it.
                let sx = bounds.midX + (CGFloat(x) + 0.5 - CGFloat(side) / 2) / scale - 0.5
                let sy = bounds.midY + (CGFloat(y) + 0.5 - CGFloat(side) / 2) / scale - 0.5
                let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                let fx = Float(sx - CGFloat(x0)), fy = Float(sy - CGFloat(y0))
                func at(_ x: Int, _ y: Int) -> Float { x >= 0 && y >= 0 && x < source && y < source ? mask[y * source + x] : 0 }
                let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
                let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
                out[y * side + x] = top * (1 - fy) + bottom * fy
            }
        }
        return out
    }

    /// For an app with no icon of its own: a four-pointed star's outline, full in the middle, with
    /// the first letter (or figure) of its name in there.
    @MainActor
    static func starLetter(_ name: String) -> DockGlyph? {
        let side = DockGlyph.side
        guard let context = Pixels.context(side: side) else { return nil }
        let middle = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        // Its points out at `reach` up and down, a little less across; its sides drawn in toward
        // `waist`, round enough to leave room for the letter.
        let reach = CGFloat(side) * 0.46, across = reach * 0.86, waist = reach * 0.2
        let star = CGMutablePath()
        star.move(to: CGPoint(x: middle.x, y: middle.y + reach))
        star.addQuadCurve(to: CGPoint(x: middle.x + across, y: middle.y), control: CGPoint(x: middle.x + waist, y: middle.y + waist))
        star.addQuadCurve(to: CGPoint(x: middle.x, y: middle.y - reach), control: CGPoint(x: middle.x + waist, y: middle.y - waist))
        star.addQuadCurve(to: CGPoint(x: middle.x - across, y: middle.y), control: CGPoint(x: middle.x - waist, y: middle.y - waist))
        star.addQuadCurve(to: CGPoint(x: middle.x, y: middle.y + reach), control: CGPoint(x: middle.x - waist, y: middle.y + waist))
        star.closeSubpath()
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(CGFloat(side) * 0.034)
        context.setLineJoin(.round)
        context.addPath(star)
        context.strokePath()
        if let initial = initial(of: name) {
            // As tall as the star leaves room for in its middle, by the letter's own outline.
            let font = CTFontCreateWithName(NSFont.systemFont(ofSize: 1, weight: .semibold).fontName as CFString, CGFloat(side) * 0.3, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: initial, attributes: [
                .font: font, .foregroundColor: CGColor(gray: 1, alpha: 1),
            ]))
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.textPosition = CGPoint(x: middle.x - bounds.midX, y: middle.y - bounds.midY)
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage(), let pixels = Pixels(image, side: side) else { return nil }
        return finish((0..<side * side).map { pixels.alpha($0 % side, $0 / side) })
    }

    /// The first letter or figure of `name`, as a capital: "Tone_Matrix" is T.
    nonisolated static func initial(of name: String) -> String? {
        name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() }
    }

    /// An SF Symbol, as a glyph: Finder's (a magnifying glass), or a folder's.
    @MainActor
    static func symbol(_ name: String) -> DockGlyph? {
        let side = DockGlyph.side
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(side) * 0.42, weight: .regular)),
              let context = Pixels.context(side: side) else { return nil }
        let size = symbol.size, fit = CGFloat(side) * 0.56 / max(size.width, size.height)
        let drawn = CGSize(width: size.width * fit, height: size.height * fit)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(in: CGRect(x: (CGFloat(side) - drawn.width) / 2, y: (CGFloat(side) - drawn.height) / 2,
                               width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(), let pixels = Pixels(image, side: side) else { return nil }
        return finish((0..<side * side).map { pixels.alpha($0 % side, $0 / side) })
    }

    /// The mask, its edges (the mask grown a pixel, less the mask shrunk one), and spots spread
    /// along them.
    private nonisolated static func finish(_ mask: [Float]) -> DockGlyph? {
        let side = DockGlyph.side
        let grown = Morphology.extreme(mask, side: side, max: true), shrunk = Morphology.extreme(mask, side: side, max: false)
        let edges = zip(grown, shrunk).map { min(max($0 - $1, 0), 1) }
        guard let maskImage = Pixels.white(mask, side: side), let outline = Pixels.white(edges, side: side) else { return nil }
        // Spread out: each the farthest from those picked so far, starting from the top.
        let along = edges.indices.filter { edges[$0] > 0.6 }.map { CGPoint(x: Double($0 % side), y: Double($0 / side)) }
        var spots: [CGPoint] = []
        if let first = along.min(by: { $0.y < $1.y }) {
            spots.append(first)
            var nearest = along.map { hypot($0.x - first.x, $0.y - first.y) }
            while spots.count < 14, let far = nearest.indices.max(by: { nearest[$0] < nearest[$1] }), nearest[far] > 8 {
                let spot = along[far]
                spots.append(spot)
                for index in along.indices { nearest[index] = min(nearest[index], hypot(along[index].x - spot.x, along[index].y - spot.y)) }
            }
        }
        return DockGlyph(mask: maskImage, outline: outline,
                         sparkles: spots.map { CGPoint(x: ($0.x + 0.5) / Double(side), y: ($0.y + 0.5) / Double(side)) })
    }

    // MARK: Shapes

    /// How far `point` is inside the rounded rect (negative outside).
    private nonisolated static func depth(of point: CGPoint, in rect: CGRect, corner: CGFloat) -> CGFloat {
        let dx = max(rect.minX + corner - point.x, point.x - (rect.maxX - corner), 0)
        let dy = max(rect.minY + corner - point.y, point.y - (rect.maxY - corner), 0)
        if dx > 0 && dy > 0 { return corner - hypot(dx, dy) }
        return min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
    }

    /// A point `fraction` of the way round a rounded rect's edge, near enough (its corners cut).
    private nonisolated static func point(onRoundedRect rect: CGRect, corner: CGFloat, at fraction: Double) -> CGPoint {
        let inner = rect.insetBy(dx: corner * 0.3, dy: corner * 0.3)
        let perimeter = 2 * (inner.width + inner.height), along = CGFloat(fraction) * perimeter
        switch along {
        case ..<inner.width: return CGPoint(x: inner.minX + along, y: inner.minY)
        case ..<(inner.width + inner.height): return CGPoint(x: inner.maxX, y: inner.minY + along - inner.width)
        case ..<(2 * inner.width + inner.height): return CGPoint(x: inner.maxX - (along - inner.width - inner.height), y: inner.maxY)
        default: return CGPoint(x: inner.minX, y: inner.maxY - (along - 2 * inner.width - inner.height))
        }
    }

    private nonisolated static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return (d * d).sum().squareRoot()
    }

    private nonisolated static func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// A mask's separate parts (touching pixels more than half in, and the soft edge round them), left
/// to right, specks left out.
private struct Parts {
    struct Part {
        let mask: [Float]
        let bounds: CGRect
    }

    let parts: [Part]
    var first: Part? { parts.first }

    /// The holes in a mask (what's clear of it but can't be reached from its edges), left to
    /// right, specks left out.
    nonisolated static func holes(in mask: [Float], side: Int) -> [CGRect] {
        var seen = [Bool](repeating: false, count: side * side)
        func fill(from start: Int) -> [Int] {
            var queue = [start], pixels: [Int] = []
            seen[start] = true
            while let index = queue.popLast() {
                pixels.append(index)
                let x = index % side, y = index / side
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                    let next = ny * side + nx
                    if !seen[next], mask[next] <= 0.5 {
                        seen[next] = true
                        queue.append(next)
                    }
                }
            }
            return pixels
        }
        // Everything clear that reaches the edges isn't a hole.
        for index in 0..<side * side {
            let x = index % side, y = index / side
            guard x == 0 || y == 0 || x == side - 1 || y == side - 1, !seen[index], mask[index] <= 0.5 else { continue }
            _ = fill(from: index)
        }
        var holes: [CGRect] = []
        for index in 0..<side * side where !seen[index] && mask[index] <= 0.5 {
            let pixels = fill(from: index)
            guard pixels.count >= 6 else { continue }
            let xs = pixels.map { $0 % side }, ys = pixels.map { $0 / side }
            holes.append(CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()! + 1, height: ys.max()! - ys.min()! + 1))
        }
        return holes.sorted { $0.minX < $1.minX }
    }

    nonisolated init(_ mask: [Float], side: Int) {
        var label = [Int](repeating: -1, count: side * side)
        var found: [(pixels: [Int], minX: Int)] = []
        for start in mask.indices where mask[start] > 0.5 && label[start] < 0 {
            let id = found.count
            var queue = [start], pixels: [Int] = [], minX = side
            label[start] = id
            while let index = queue.popLast() {
                pixels.append(index)
                minX = min(minX, index % side)
                let x = index % side, y = index / side
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                    let next = ny * side + nx
                    if mask[next] > 0.5 && label[next] < 0 {
                        label[next] = id
                        queue.append(next)
                    }
                }
            }
            found.append((pixels, minX))
        }
        let total = found.reduce(0) { $0 + $1.pixels.count }
        parts = found.enumerated()
            .filter { $0.element.pixels.count * 50 > total }
            .sorted { $0.element.minX < $1.element.minX }
            .map { id, part in
                var out = [Float](repeating: 0, count: side * side)
                var minX = side, minY = side, maxX = 0, maxY = 0
                for index in part.pixels {
                    let x = index % side, y = index / side
                    // Its own pixels, and the soft edge round them that's no other part's.
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                            let near = ny * side + nx
                            guard label[near] == id || label[near] < 0 else { continue }
                            out[near] = mask[near]
                        }
                    }
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                return Part(mask: out, bounds: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
            }
    }
}

/// A tile's colors, as running smoothly across it: each channel a + b·u + c·v (u and v −1...1
/// across and down), fitted to what's round its edge, leaving out what doesn't fit (where the
/// glyph reaches the edge).
private struct Plane {
    var a = SIMD3<Float>(repeating: 0), b = SIMD3<Float>(repeating: 0), c = SIMD3<Float>(repeating: 0)

    func color(at uv: SIMD2<Float>) -> SIMD3<Float> { a + b * uv.x + c * uv.y }

    /// Fitted to the tile's corners first, where a glyph seldom reaches (so one reaching its edge
    /// in places, as Spotify's circle does, doesn't pull it off), then to those spots round the
    /// edge near enough that, and the corners, again, to take in all of a gradient.
    static func fit(corners: [(SIMD2<Float>, SIMD3<Float>)], edge: [(SIMD2<Float>, SIMD3<Float>)]) -> Plane? {
        guard var plane = solve(corners) else { return nil }
        for _ in 0..<3 {
            let near = edge.filter { simd_length(plane.color(at: $0.0) - $0.1) <= 0.07 }
            guard let fitted = solve(corners + near) else { break }
            plane = fitted
        }
        return plane
    }

    /// Least squares, the three channels together (they share the same u and v).
    private static func solve(_ samples: [(SIMD2<Float>, SIMD3<Float>)]) -> Plane? {
        var m = simd_float3x3(), r = (SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 0))
        for (uv, color) in samples {
            let row = SIMD3<Float>(1, uv.x, uv.y)
            m += simd_float3x3(rows: [row * row.x, row * row.y, row * row.z])
            r.0 += color * row.x
            r.1 += color * row.y
            r.2 += color * row.z
        }
        guard abs(m.determinant) > 1e-6 else { return nil }
        let inverse = m.inverse
        // Per channel: [a, b, c] = inverse · [Σ color, Σ color·u, Σ color·v].
        var plane = Plane()
        for channel in 0..<3 {
            let solved = inverse * SIMD3<Float>(r.0[channel], r.1[channel], r.2[channel])
            plane.a[channel] = solved.x
            plane.b[channel] = solved.y
            plane.c[channel] = solved.z
        }
        return plane
    }
}

/// Growing and shrinking a mask by a pixel, and tidying it.
private enum Morphology {
    /// Each pixel the most (or least) of it and those round it.
    nonisolated static func extreme(_ mask: [Float], side: Int, max: Bool) -> [Float] {
        var out = mask
        for y in 0..<side {
            for x in 0..<side {
                var value = mask[y * side + x]
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                        let other = mask[ny * side + nx]
                        value = max ? Swift.max(value, other) : Swift.min(value, other)
                    }
                }
                out[y * side + x] = value
            }
        }
        return out
    }

    /// Specks and pinholes gone: softened a pixel round, then sharpened again.
    nonisolated static func cleaned(_ mask: [Float], side: Int) -> [Float] {
        var out = mask
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                var sum: Float = 0
                for dy in -1...1 { for dx in -1...1 { sum += mask[(y + dy) * side + x + dx] } }
                let t = min(max((sum / 9 - 0.3) / 0.4, 0), 1)
                out[y * side + x] = t * t * (3 - 2 * t)
            }
        }
        return out
    }
}

/// An image's pixels, drawn `side` square, straight (not premultiplied) 0...1.
private struct Pixels {
    let side: Int
    private let bytes: [UInt8]

    nonisolated init?(_ image: CGImage, side: Int) {
        guard let context = Self.context(side: side) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        self.side = side
        // Rows top first, as the context keeps them.
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
    }

    nonisolated static func context(side: Int) -> CGContext? {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    nonisolated func alpha(_ x: Int, _ y: Int) -> Float { Float(bytes[(y * side + x) * 4 + 3]) / 255 }

    nonisolated func color(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let i = (y * side + x) * 4, a = max(Float(bytes[i + 3]), 1)
        return SIMD3(Float(bytes[i]) / a, Float(bytes[i + 1]) / a, Float(bytes[i + 2]) / a)
    }

    /// The average of the few pixels round `point`.
    nonisolated func color(around point: CGPoint) -> SIMD3<Float> {
        var sum = SIMD3<Float>(repeating: 0), count: Float = 0
        for dy in -1...1 {
            for dx in -1...1 {
                let x = Int(point.x) + dx, y = Int(point.y) + dy
                guard x >= 0, y >= 0, x < side, y < side else { continue }
                sum += color(x, y)
                count += 1
            }
        }
        return sum / max(count, 1)
    }

    nonisolated func uv(_ point: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(point.x) / Float(side) * 2 - 1, Float(point.y) / Float(side) * 2 - 1)
    }

    /// Where it's solid (more than half opaque).
    nonisolated func solidBounds() -> CGRect? {
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where bytes[(y * side + x) * 4 + 3] > 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// A white image, as opaque as `values` say, rows top first.
    nonisolated static func white(_ values: [Float], side: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for (index, value) in values.enumerated() {
            let a = UInt8(min(max(value, 0), 1) * 255)
            bytes[index * 4] = a
            bytes[index * 4 + 1] = a
            bytes[index * 4 + 2] = a
            bytes[index * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
