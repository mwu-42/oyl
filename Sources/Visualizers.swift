import Combine
import SwiftUI

// The visualizer draws with Core Animation layers that subscribe to the spectrum directly.
// Frames arrive ~30 times a second; keeping SwiftUI out of that loop is most of the power saving,
// and short implicit layer animations (run by the render server, not this process) smooth the
// steps between frames.

/// The open notch's spectrum: a filled, gradient curve with a live outline and a slower
/// trailing line — a much simplified take on a spectrum analyzer.
struct SpectrumCurve: View {
    @ObservedObject var spectrum: AudioSpectrum
    let color: NSColor
    /// Midnight Oyl's: a fine white line over a galaxy in `palette`'s colors (the cover's), and
    /// the held line dotted.
    var engraved = false
    var palette: [NSColor] = []

    var body: some View {
        LayerView { CurveLayers(frames: spectrum.frames.eraseToAnyPublisher()) } update: {
            $0.configure(color: color, engraved: engraved, palette: palette)
        }
    }
}

/// Hosts one of the layer views below.
private struct LayerView<Layers: NSView>: NSViewRepresentable {
    let make: () -> Layers
    let update: (Layers) -> Void

    init(_ make: @escaping () -> Layers, update: @escaping (Layers) -> Void) {
        self.make = make
        self.update = update
    }

    func makeNSView(context: Context) -> Layers { make() }
    func updateNSView(_ view: Layers, context: Context) { update(view) }
}

final class CurveLayers: NSView {
    private static let colorFade: CFTimeInterval = 0.6
    /// How much wider than the curve the galaxy is, to drift along under it, and how long it takes
    /// to drift across and back.
    private static let galaxyWidth: CGFloat = 1.6
    private static let driftTime: CFTimeInterval = 140

    static func configureTransaction(_ duration: CFTimeInterval?) {
        if let duration {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: duration < 0.2 ? .linear : .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
    }

    private let fill = CAGradientLayer()
    private let fillShape = CAShapeLayer()
    /// Under the curve, masked to it: the fill, and in Midnight Oyl, a galaxy in the cover's
    /// colors (drawn once a song, then only drifted) and its twinkling stars.
    private let space = CALayer()
    private let galaxy = CALayer()
    private let twinkles = CALayer()
    private var palette: [NSColor] = []
    private var drawnGalaxy: (colors: [NSColor], size: CGSize)?
    private let fade = CAGradientLayer()
    private let trail = CAShapeLayer()
    private let line = CAShapeLayer()
    private var latest = SpectrumFrame.silent
    private var color: NSColor?
    private var engraved = false
    private var subscription: AnyCancellable?

    init(frames: AnyPublisher<SpectrumFrame, Never>) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        space.mask = fillShape
        [fill, galaxy, twinkles].forEach { space.addSublayer($0) }
        galaxy.isHidden = true
        twinkles.isHidden = true
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        // Darken toward the baseline so the fill glows from the top edge down.
        fade.colors = [NSColor.black.withAlphaComponent(0.8).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        for stroke in [trail, line] {
            stroke.fillColor = nil
            stroke.lineJoin = .round
            stroke.lineCap = .round
        }
        trail.lineWidth = 1
        trail.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
        line.lineWidth = 1.25
        line.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        [space, fade, trail, line].forEach { layer?.addSublayer($0) }

        subscription = frames.sink { [weak self] frame in
            self?.latest = frame
            self?.redraw(animation: 0.12)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(color: NSColor, engraved: Bool = false, palette: [NSColor] = []) {
        if engraved != self.engraved {
            self.engraved = engraved
            engrave(engraved)
            self.color = nil
        }
        self.palette = palette
        defer { drawGalaxy() }
        guard color != self.color else { return }
        // Sweep from the artwork's color toward a neighbouring hue, like the reference's
        // pink-to-violet fill.
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        (color.usingColorSpace(.sRGB) ?? color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        let neighbour = NSColor(hue: (hue + 0.92).truncatingRemainder(dividingBy: 1),
                                saturation: min(saturation + 0.1, 1), brightness: brightness, alpha: 1)
        // A new song's colors fade in; only the first ones are set outright.
        CATransaction.begin()
        Self.configureTransaction(self.color == nil ? nil : Self.colorFade)
        if engraved {
            // Faint, falling away to almost nothing at the baseline (no dark fade to slab it).
            fill.colors = [color.withAlphaComponent(0.03).cgColor, neighbour.withAlphaComponent(0.18).cgColor]
        } else {
            fill.colors = [color.cgColor, neighbour.cgColor]
        }
        CATransaction.commit()
        self.color = color
    }

    /// Midnight Oyl's look, or Oyl's own: the line, the held line and the fill's direction.
    private func engrave(_ engraved: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.isHidden = engraved
        galaxy.isHidden = !engraved
        twinkles.isHidden = !engraved
        // Engraved, the fill runs up from the baseline; otherwise across, from the art's color.
        fill.startPoint = engraved ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
        fill.endPoint = engraved ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
        line.lineWidth = engraved ? 1 : 1.25
        trail.lineWidth = 1
        trail.lineDashPattern = engraved ? [0.1, 2.6] : nil
        trail.strokeColor = engraved ? NSColor(Midnight.silver).withAlphaComponent(0.35).cgColor
                                     : NSColor.white.withAlphaComponent(0.3).cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [space, fill, fillShape, twinkles, fade, trail, line] { sublayer.frame = bounds }
        CATransaction.commit()
        redraw(animation: nil)
        drawGalaxy()
    }

    /// Midnight Oyl's galaxy, drawn for the cover's colors (paled a touch toward Midnight's white)
    /// at this size; Core Animation drifts it and twinkles its stars from then on.
    private func drawGalaxy() {
        guard engraved, bounds.width > 0, bounds.height > 0 else { return }
        let size = bounds.size, colors = (palette.isEmpty ? [color ?? .white] : palette).map { Midnight.pale($0, keep: 0.8) }
        if let drawn = drawnGalaxy, drawn.colors == colors, drawn.size == size { return }
        let resized = drawnGalaxy?.size != size
        drawnGalaxy = (colors, size)
        let scale = window?.backingScaleFactor ?? 2, seed = Galaxy.seed(colors)
        let wide = CGSize(width: size.width * Self.galaxyWidth, height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if resized {
            galaxy.frame = CGRect(origin: .zero, size: wide)
            galaxy.contentsScale = scale
            // Drifting slowly one way and back, as the sky turns.
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = wide.width / 2
            drift.toValue = size.width - wide.width / 2
            drift.duration = Self.driftTime / 2
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            galaxy.add(drift, forKey: "drift")
        }
        twinkles.sublayers = Galaxy.twinkles(in: size, colors: colors, scale: scale, seed: seed)
        CATransaction.commit()
        // A new song's galaxy fades in over the last.
        CATransaction.begin()
        Self.configureTransaction(galaxy.contents == nil || resized ? nil : Self.colorFade)
        galaxy.contents = Galaxy.picture(wide, colors: colors, scale: scale, seed: seed)
        CATransaction.commit()
    }

    private func redraw(animation duration: CFTimeInterval?) {
        CATransaction.begin()
        Self.configureTransaction(duration)
        fillShape.path = Self.path(latest.curve, in: bounds, closed: true)
        line.path = Self.path(latest.curve, in: bounds, closed: false)
        trail.path = Self.path(latest.hold, in: bounds, closed: false)
        CATransaction.commit()
    }

    /// A smooth (Catmull-Rom) curve through the values, optionally closed along the baseline.
    private static func path(_ values: [Float], in bounds: CGRect, closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard values.count > 1, bounds.width > 0 else { return path }
        let inset: CGFloat = 1.5
        let points = values.enumerated().map { index, value in
            CGPoint(x: bounds.minX + bounds.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: bounds.minY + inset + (bounds.height - 2 * inset) * CGFloat(value))
        }
        path.move(to: points[0])
        for index in 0..<points.count - 1 {
            let p0 = points[max(index - 1, 0)], p1 = points[index]
            let p2 = points[index + 1], p3 = points[min(index + 2, points.count - 1)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        if closed {
            path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
            path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY))
            path.closeSubpath()
        }
        return path
    }
}

/// Midnight Oyl's galaxy under the music page's wave: a band of soft cloud wandering across in the
/// cover's colors, dark lanes of dust in it, fine star dust thickest along it and a few brighter
/// stars; and over it, little four-pointed stars twinkling on their own rounds. Where things go is
/// seeded by the colors, so a song's galaxy is the same each time it's shown.
enum Galaxy {
    static func seed(_ colors: [NSColor]) -> UInt64 {
        colors.reduce(0x9E37_79B9_7F4A_7C15) { seed, color in
            let color = color.usingColorSpace(.sRGB) ?? color
            let parts = [color.redComponent, color.greenComponent, color.blueComponent].map { UInt64(($0 * 255).rounded()) }
            return parts.reduce(seed) { ($0 ^ $1) &* 0x100_0000_01B3 }
        }
    }

    /// The galaxy `size` points across, falling away a little toward the baseline.
    static func picture(_ size: CGSize, colors: [NSColor], scale: CGFloat, seed: UInt64) -> CGImage? {
        let pixels = (width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)))
        guard pixels.width > 0, pixels.height > 0, !colors.isEmpty, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        var random = Scatter(state: seed)
        let w = size.width, h = size.height
        // The band's spine, wandering up and down across; its color changing along it, by turns.
        let phase = random.range(0, 2 * .pi), waves = random.range(1.2, 2.2), start = random.range(0, CGFloat(colors.count))
        func spine(_ x: CGFloat) -> CGFloat { h * (0.5 + 0.2 * sin(phase + x / w * waves * 2 * .pi)) }
        func tone(at x: CGFloat) -> NSColor {
            let along = start + x / w * CGFloat(colors.count) * 1.3
            let index = Int(along) % colors.count, next = (index + 1) % colors.count
            return colors[index].blended(withFraction: along - floor(along), of: colors[next]) ?? colors[index]
        }
        func blob(at point: CGPoint, radius: CGFloat, stretch: CGFloat, color: NSColor, alpha: CGFloat) {
            guard let gradient = CGGradient(colorsSpace: space, colors: [color.withAlphaComponent(alpha).cgColor,
                                                                         color.withAlphaComponent(0).cgColor] as CFArray,
                                            locations: [0, 1]) else { return }
            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            context.scaleBy(x: stretch, y: 1)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
            context.restoreGState()
        }

        // The clouds, and brighter knots of them nearer the spine, whitening.
        for _ in 0..<Int(w / 5) {
            let x = random.range(-h, w + h), y = spine(x) + random.range(-0.3, 0.3) * h
            blob(at: CGPoint(x: x, y: y), radius: random.range(0.3, 0.8) * h, stretch: random.range(1.3, 2.4), color: tone(at: x),
                 alpha: random.range(0.12, 0.26))
        }
        for _ in 0..<Int(w / 16) {
            let x = random.range(0, w), y = spine(x) + random.range(-0.12, 0.12) * h
            blob(at: CGPoint(x: x, y: y), radius: random.range(0.12, 0.3) * h, stretch: random.range(1.2, 2),
                 color: tone(at: x).blended(withFraction: 0.35, of: .white) ?? .white, alpha: random.range(0.14, 0.3))
        }
        // Lanes of dust darkening it, along and just off the spine.
        context.setBlendMode(.destinationOut)
        for _ in 0..<Int(w / 40) + 2 {
            let x = random.range(0, w), y = spine(x) + random.range(-0.18, 0.18) * h
            blob(at: CGPoint(x: x, y: y), radius: random.range(0.12, 0.28) * h, stretch: random.range(2, 4), color: .black,
                 alpha: random.range(0.2, 0.4))
        }
        context.setBlendMode(.normal)
        // The star dust, most of it along the band.
        for _ in 0..<Int(w * h / 9) {
            let x = random.range(0, w)
            let y = random.next() < 0.65 ? spine(x) + (random.next() + random.next() - 1) * 0.35 * h : random.range(0, h)
            let r = random.range(0.2, 0.55)
            context.setFillColor((tone(at: x).blended(withFraction: 0.6, of: .white) ?? .white).withAlphaComponent(random.range(0.25, 0.85)).cgColor)
            context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        // A few brighter stars, with fine glints.
        for _ in 0..<Int(w / 24) {
            let x = random.range(0, w), y = random.range(0.08, 0.92) * h, r = random.range(0.5, 0.9), arm = random.range(1.5, 3.5)
            context.setFillColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            context.fill([CGRect(x: x - arm, y: y - 0.15, width: 2 * arm, height: 0.3), CGRect(x: x - 0.15, y: y - arm, width: 0.3, height: 2 * arm)])
            context.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        // Falling away a little toward the baseline.
        if let fall = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.white.cgColor] as CFArray,
                                 locations: [0, 1]) {
            context.setBlendMode(.destinationIn)
            context.drawLinearGradient(fall, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        }
        return context.makeImage()
    }

    /// The twinkling stars, about one every 16 points across, each flashing now and then on its
    /// own round.
    static func twinkles(in size: CGSize, colors: [NSColor], scale: CGFloat, seed: UInt64) -> [CALayer] {
        var random = Scatter(state: seed ^ 0x5BD1_E995)
        let images = colors.map { sparkle($0.blended(withFraction: 0.55, of: .white) ?? .white, scale: scale) }
        return (0..<max(Int(size.width / 16), 4)).compactMap { index in
            guard let image = images[index % images.count] else { return nil }
            let star = CALayer(), side = random.range(6, 12)
            star.frame = CGRect(x: random.range(0, size.width) - side / 2, y: random.range(0.08, 0.85) * size.height - side / 2,
                                width: side, height: side)
            star.contents = image
            star.contentsScale = scale
            star.opacity = 0
            let period = CFTimeInterval(random.range(1.8, 5)), flash = CFTimeInterval(random.range(0.35, 0.8)) / period
            let times = [0, flash * 0.4, flash, 1].map { NSNumber(value: $0) }
            let shine = CAKeyframeAnimation(keyPath: "opacity")
            shine.values = [0, 1, 0, 0]
            shine.keyTimes = times
            let grow = CAKeyframeAnimation(keyPath: "transform.scale")
            grow.values = [0.3, 1, 0.3, 0.3]
            grow.keyTimes = times
            let twinkle = CAAnimationGroup()
            twinkle.animations = [shine, grow]
            twinkle.duration = period
            twinkle.repeatCount = .infinity
            twinkle.timeOffset = CFTimeInterval(random.next()) * period
            star.add(twinkle, forKey: "twinkle")
            return star
        }
    }

    /// A little four-pointed star in `color`, with a white heart.
    private static func sparkle(_ color: NSColor, scale: CGFloat, side: CGFloat = 12) -> CGImage? {
        let pixels = Int((side * scale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let c = side / 2, r = side / 2
        let star = CGMutablePath()
        star.move(to: CGPoint(x: c, y: c - r))
        star.addQuadCurve(to: CGPoint(x: c + r, y: c), control: CGPoint(x: c, y: c))
        star.addQuadCurve(to: CGPoint(x: c, y: c + r), control: CGPoint(x: c, y: c))
        star.addQuadCurve(to: CGPoint(x: c - r, y: c), control: CGPoint(x: c, y: c))
        star.addQuadCurve(to: CGPoint(x: c, y: c - r), control: CGPoint(x: c, y: c))
        if let glow = CGGradient(colorsSpace: space, colors: [color.withAlphaComponent(0.5).cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: [0, 1]) {
            context.drawRadialGradient(glow, startCenter: CGPoint(x: c, y: c), startRadius: 0, endCenter: CGPoint(x: c, y: c),
                                       endRadius: r * 0.55, options: [])
        }
        context.addPath(star)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: c - 0.8, y: c - 0.8, width: 1.6, height: 1.6))
        return context.makeImage()
    }

    /// A seeded stream of numbers from 0 to 1.
    private struct Scatter {
        var state: UInt64

        mutating func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 11) / CGFloat(UInt64(1) << 53)
        }

        mutating func range(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * next() }
    }
}
