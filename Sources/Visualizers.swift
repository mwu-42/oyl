import Combine
import SwiftUI

// Both visualizers draw with Core Animation layers that subscribe to the spectrum directly.
// Frames arrive ~30 times a second; keeping SwiftUI out of that loop is most of the power saving,
// and short implicit layer animations (run by the render server, not this process) smooth the
// steps between frames.

/// The closed notch's four bars.
struct SpectrumBars: View {
    @ObservedObject var spectrum: AudioSpectrum
    let isPlaying: Bool
    let color: NSColor
    var barWidth: CGFloat = 3
    var height: CGFloat = 16

    private let interval = 0.3

    var body: some View {
        Group {
            if isPlaying && !spectrum.isLive {
                // No audio yet (or capture was denied): decorative motion instead.
                TimelineView(.animation(minimumInterval: interval)) { context in
                    let tick = Int(context.date.timeIntervalSinceReferenceDate / interval)
                    HStack(alignment: .center, spacing: barWidth * BarLayers.spacing) {
                        ForEach(0..<SpectrumFrame.barCount, id: \.self) { bar in
                            Capsule()
                                .fill(Color(nsColor: color))
                                .frame(width: barWidth,
                                       height: max(barWidth, height * (0.2 + 0.8 * Self.noise(bar: bar, tick: tick))))
                        }
                    }
                    .animation(.easeInOut(duration: interval), value: tick)
                }
            } else {
                LayerView { BarLayers(frames: spectrum.frames.eraseToAnyPublisher()) } update: {
                    $0.configure(color: color, barWidth: barWidth)
                }
            }
        }
        .frame(width: BarLayers.width(barWidth: barWidth), height: height)
    }

    private static func noise(bar: Int, tick: Int) -> CGFloat {
        let noise = sin(Double(tick &* 7 &+ bar &* 13) * 12.9898) * 43758.5453
        return 0.15 + 0.85 * CGFloat(noise - noise.rounded(.down))
    }
}

/// The open notch's spectrum: a filled, gradient curve with a live outline and a slower
/// trailing line — a much simplified take on a spectrum analyzer.
struct SpectrumCurve: View {
    @ObservedObject var spectrum: AudioSpectrum
    let color: NSColor

    var body: some View {
        LayerView { CurveLayers(frames: spectrum.frames.eraseToAnyPublisher()) } update: {
            $0.configure(color: color)
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

final class BarLayers: NSView {
    static let spacing: CGFloat = 0.7  // gap between bars, as a fraction of bar width
    static let colorFade: CFTimeInterval = 0.6

    static func width(barWidth: CGFloat) -> CGFloat {
        let count = CGFloat(SpectrumFrame.barCount)
        return count * barWidth + (count - 1) * barWidth * spacing
    }

    private let bars = (0..<SpectrumFrame.barCount).map { _ in CALayer() }
    private var levels: [Float] = []
    private var color: NSColor?
    private var barWidth: CGFloat = 3
    private var subscription: AnyCancellable?

    init(frames: AnyPublisher<SpectrumFrame, Never>) {
        super.init(frame: .zero)
        wantsLayer = true
        bars.forEach { layer?.addSublayer($0) }
        subscription = frames.sink { [weak self] frame in
            self?.levels = frame.bars
            self?.layoutBars(animation: 0.12)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(color: NSColor, barWidth: CGFloat) {
        self.barWidth = barWidth
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars { bar.cornerRadius = barWidth / 2 }
        CATransaction.commit()
        if color != self.color {
            // A new song's color fades in; only the first one is set outright.
            CATransaction.begin()
            Self.configureTransaction(self.color == nil ? nil : Self.colorFade)
            for bar in bars { bar.backgroundColor = color.cgColor }
            CATransaction.commit()
            self.color = color
        }
        layoutBars(animation: nil)
    }

    override func layout() {
        super.layout()
        layoutBars(animation: nil)
    }

    private func layoutBars(animation duration: CFTimeInterval?) {
        CATransaction.begin()
        Self.configureTransaction(duration)
        var x = (bounds.width - Self.width(barWidth: barWidth)) / 2
        for (index, bar) in bars.enumerated() {
            let level = index < levels.count ? CGFloat(levels[index]) : 0
            let height = max(barWidth, bounds.height * (0.2 + 0.8 * level))
            bar.frame = CGRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            x += barWidth * (1 + Self.spacing)
        }
        CATransaction.commit()
    }

    static func configureTransaction(_ duration: CFTimeInterval?) {
        if let duration {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: duration < 0.2 ? .linear : .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
    }
}

final class CurveLayers: NSView {
    private let fill = CAGradientLayer()
    private let fillShape = CAShapeLayer()
    private let fade = CAGradientLayer()
    private let trail = CAShapeLayer()
    private let line = CAShapeLayer()
    private var latest = SpectrumFrame.silent
    private var color: NSColor?
    private var subscription: AnyCancellable?

    init(frames: AnyPublisher<SpectrumFrame, Never>) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        fill.mask = fillShape
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
        [fill, fade, trail, line].forEach { layer?.addSublayer($0) }

        subscription = frames.sink { [weak self] frame in
            self?.latest = frame
            self?.redraw(animation: 0.12)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(color: NSColor) {
        guard color != self.color else { return }
        // Sweep from the artwork's color toward a neighbouring hue, like the reference's
        // pink-to-violet fill.
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        (color.usingColorSpace(.sRGB) ?? color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        let neighbour = NSColor(hue: (hue + 0.92).truncatingRemainder(dividingBy: 1),
                                saturation: min(saturation + 0.1, 1), brightness: brightness, alpha: 1)
        // A new song's colors fade in; only the first ones are set outright.
        CATransaction.begin()
        BarLayers.configureTransaction(self.color == nil ? nil : BarLayers.colorFade)
        fill.colors = [color.cgColor, neighbour.cgColor]
        CATransaction.commit()
        self.color = color
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [fill, fillShape, fade, trail, line] { sublayer.frame = bounds }
        CATransaction.commit()
        redraw(animation: nil)
    }

    private func redraw(animation duration: CFTimeInterval?) {
        CATransaction.begin()
        BarLayers.configureTransaction(duration)
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
