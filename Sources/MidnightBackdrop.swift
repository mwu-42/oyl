import MetalKit
import os
import SwiftUI

/// Midnight Oyl's band: across the whole top of the screen, flush with it and covering the menu
/// bar, its foot deepest under the notch (`reach`, with a soft point there) and rising a little
/// toward the screen's edges. It blooms out of the notch by `bloom` (0 just the notch, 1 full):
/// opening out every way at once, like a flower, its petals unfurling across the band (see
/// `Flower`). The backdrop's laid out in this shape, but flows in and out of it (see `Liquid`) and
/// leaves no edge; the page and the moon are clipped to it, and it's what's clicked.
struct MidnightArch: Shape {
    var bloom: Double
    /// The hardware notch it grows out of, at the top center.
    var notch = MidnightArch.notch
    /// How far down it comes under the notch, in points from the top (the frame's height, at most).
    var reach: CGFloat = MidnightArch.full
    /// When, on the backdrop's clock, for the petals' ripple while it opens (now, unless it's set).
    var time: Double?

    /// About the size of a MacBook's notch.
    static let notch = CGSize(width: 200, height: 34)
    /// Past any screen: the frame's whole height. (Finite, so it animates.)
    static let full: CGFloat = 10_000

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(bloom, reach) }
        set {
            bloom = newValue.first
            reach = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let band = Self.band(in: rect, reach: reach)
        guard bloom < 1 else { return band }
        // Opening, as far as the flower's come (a little short of its soft edge).
        let plate = Plate(size: rect.size, reach: reach)
        let flower = Flower.path(plate, bloom: bloom, time: time ?? MidnightBackdrop.clock, inset: 0.4)
            .offsetBy(dx: rect.minX, dy: rect.minY)
        return band.intersection(flower)
    }

    /// The band fully open, in `rect`.
    private static func band(in rect: CGRect, reach: CGFloat) -> Path {
        let plate = Plate(size: rect.size, reach: reach)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + plate.width, y: rect.minY))
        for x in Design.footSamples(width: plate.width).reversed() {
            path.addLine(to: CGPoint(x: rect.minX + x, y: rect.minY + Design.foot(x, plate)))
        }
        path.closeSubpath()
        return path
    }

    /// The glass's mask in a frame of `size`: whole where the plate always is, however its outline
    /// flows, thinning out over `Design.glassFeather` points toward where it can pinch up to (the
    /// foot pulled up as far as it ever pinches there, clear of the page, and the dissolve's
    /// furthest start), to nothing `Design.glassInset` short of that; and whole behind the moon's
    /// dial. So the blur never shows past the plate, nor an edge. Where the plate swells out past
    /// that, it's dark glass without the blur (the backdrop darkens it a little more there). (In
    /// steps, each a stroke of that line clipped to it, narrower and fainter toward it: the window
    /// server's blur takes only an image.) It's drawn small, a pixel for each 4 points, and
    /// stretched: it's soft all through, and that keeps it quick to draw again each frame the band
    /// opens or grows.
    func glassMask(in size: CGSize, page: CGRect) -> NSImage {
        let scale: CGFloat = 0.25
        let frame = CGRect(origin: .zero, size: size)
        let width = max(Int((size.width * scale).rounded(.up)), 1), height = max(Int((size.height * scale).rounded(.up)), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: size) }
        // Measured down from the top, as the shape is.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        // Where the plate always is: the foot pulled up as far as it ever pinches, from the right
        // edge to the left (squeezed, as the shape is, while it opens). (Every other point along
        // it is plenty, for strokes this wide; always both ends.)
        let plate = Plate(size: size, reach: reach)
        let moon = MidnightBackdrop.moon(in: size, reach: plate.reach)
        let liquid = Liquid.smooth((bloom - 0.4) / 0.6)
        // (It runs on past the screen's edges, so the strokes don't stop short of them.)
        let every = Array(stride(from: Liquid.count - 1, to: 0, by: -2)) + [0]
        var line = every.map { index -> CGPoint in
            let point = Liquid.point(around: Liquid.around(index, plate), plate: plate, size: size, page: page, moon: moon,
                                     overflow: (0, 0))
            let inward = point.room * liquid + 5.3
            return CGPoint(x: point.at.x - point.out.x * inward, y: point.at.y - point.out.y * inward)
        }
        line = [CGPoint(x: plate.width + 100, y: line[0].y)] + line + [CGPoint(x: -100, y: line[line.count - 1].y)]
        var edge = Path()
        edge.addLines(line)
        var always = edge
        always.addLine(to: CGPoint(x: -100, y: 0))
        always.addLine(to: CGPoint(x: plate.width + 100, y: 0))
        always.closeSubpath()
        // Opening, only as far as the flower's come, its edge thinning out too.
        if bloom < 1 {
            let flower = Flower.path(plate, bloom: bloom, time: time ?? MidnightBackdrop.clock, inset: 0.6)
            always = always.intersection(flower)
            edge = always
        }

        // Its edge is never shown (there's no glass that near it), so it's left hard: softened,
        // each stroke after would leave a little of the fill along it.
        context.setShouldAntialias(false)
        context.addPath(Self.band(in: frame, reach: reach).cgPath)
        context.clip()
        context.addPath(always.cgPath)
        context.clip()
        context.setShouldAntialias(true)
        context.setFillColor(.black)
        context.fill(frame)
        context.setBlendMode(.copy)
        context.setLineJoin(.bevel)
        // Narrower while it's small, opening, as the plate's dissolve is.
        let opened = CGFloat(0.2 + 0.8 * Liquid.smooth((bloom - 0.1) / 0.7))
        let stroked = edge.cgPath
        let steps = 8
        for step in 0...steps {
            // Each stroke sets everything nearer the edge than `inward` to its alpha, and each
            // narrower one after takes back the part nearer still: so the glass steps down, band
            // by band, from whole to none.
            let through = CGFloat(step) / CGFloat(steps)
            let inward = (Design.glassInset + Design.glassFeather * (1 - through)) * opened
            let middle = 1 - (CGFloat(step) + 0.5) / CGFloat(steps)
            let alpha = step == steps ? 0 : middle * middle * (3 - 2 * middle)
            context.setStrokeColor(CGColor(gray: 0, alpha: alpha))
            context.setLineWidth(2 * inward)
            context.addPath(stroked)
            context.strokePath()
        }
        // Behind the moon's dial, whole, thinning out short of the foot, as it comes into view.
        // (The outline never pinches in there.)
        context.resetClip()
        context.setShouldAntialias(false)
        context.addPath(Self.band(in: frame, reach: reach).cgPath)
        context.clip()
        if bloom < 1 {
            context.addPath(Flower.path(plate, bloom: bloom, time: time ?? MidnightBackdrop.clock, inset: 0.6).cgPath)
            context.clip()
        }
        context.setShouldAntialias(true)
        let shown = CGFloat(min(max((bloom - 0.7) / 0.3, 0), 1))
        if shown > 0, let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: [CGColor(gray: 0, alpha: shown), CGColor(gray: 0, alpha: 0)] as CFArray,
                                            locations: [0, 1]) {
            context.setBlendMode(.normal)
            context.drawRadialGradient(fade, startCenter: moon.center, startRadius: moon.radius * 64 / 58,
                                       endCenter: moon.center, endRadius: moon.radius * 76 / 58, options: [.drawsBeforeStartLocation])
        }
        guard let image = context.makeImage() else { return NSImage(size: size) }
        let mask = NSImage(cgImage: image, size: size)
        // Stretched over the band. (With no cap insets at all, AppKit leaves a mask its own size,
        // a quarter of the band's, in the window's top right corner: a little grey copy of the
        // band's glass, blooming by itself up there, and none under the band.)
        mask.resizingMode = .stretch
        mask.capInsets = NSEdgeInsets(top: Self.maskCap, left: Self.maskCap, bottom: Self.maskCap, right: Self.maskCap)
        return mask
    }

    /// The glass mask's cap insets: a hair, so it's all stretched.
    static let maskCap: CGFloat = 0.01
}

/// Everything behind the band's content, drawn by one Metal shader: a Victorian celestial atlas
/// plate engraved in silver-white on deep night, spread across the top of the screen. The notch
/// is the celestial pole, with a polar grid round it; stars sized by magnitude and the Milky Way
/// across it; a planisphere on the left, an orrery and then the moon on the right, a clock (new at
/// midnight, full at noon, in a dial of the day); the Plough on the planisphere, Cygnus under the page. It's
/// laid out on `MidnightArch(bloom:notch:reach:)`, but it's never that shape: its foot flows like
/// ink in water, swelling and pinching in slow lobes that wander along it and come and go, its
/// deepest part drifting off center, a lasting swell under the moon; never pinching in over the
/// page or the moon. And it has no edge: up from the flowing foot it dissolves into the desktop
/// over a band 30 to 60 points wide that ripples as it goes, the ground and the lines fading and
/// the stars thinning out, like the night sky running out. What carries the sense of an edge
/// drifts out of it into `overflow`, the room below: motes rising and drifting away, loose stars,
/// three fine filaments holding stars out, a drop of light that gathers at the foot's lowest
/// point and falls, and the orrery's outermost planet swinging out on its long orbit.
///
/// Opening, it blooms out of the notch like a flower (see `Flower`), and the sky with it: stars
/// ignite as its front reaches them, the grid sweeps on, the charts draw on and turn into place,
/// the moon waxes to the hour's phase; then what drifts out of it comes out. Open, it carries on quietly: the dials turn, stars twinkle, dust
/// drifts, and now and then a star falls. Growing to a taller page draws new rings and stars into
/// the new room. The page's column is kept quiet.
struct MidnightBackdrop: View, Animatable {
    var bloom: Double
    var active: Bool = true
    var notch = MidnightArch.notch
    /// How far down it reaches now (animated; see `NotchState.bloomReach`).
    var reach: CGFloat = MidnightArch.full
    /// The reach before the last change, and how far through growing from it (0→1, animated with
    /// `reach`; 1 at rest). The room between the two feet is where new rings and stars draw on.
    var grownFrom: CGFloat = MidnightArch.full
    var growth: Double = 1
    /// Pinned: 0 to 1, animated. The moon's dial turns and the lamp is lit.
    var lit: Double = 0
    /// How far past its frame it draws, either side and below (see `Midnight.overflow`): room for
    /// the foot to swell into, and for what drifts out past it.
    var overflow = (side: CGFloat(0), below: CGFloat(0))
    /// The page, in the frame's points: kept quiet, and never pinched in over. (The moon's kept
    /// clear of anyway.)
    var page: CGRect = .zero
    /// Turned over, rising from the foot of its frame instead (Oyl's Dock): its edge, and what
    /// spills past it, above, its `overflow.below` going up. (`page` is then measured up from
    /// the bottom.)
    var flipped = false
    /// The planisphere, the orrery, the moon's dial and Cygnus; without them (in the Dock, too
    /// shallow for them), only the pole's grid, the stars and what spills.
    var charts = true

    var animatableData: AnimatablePair<Double, AnimatablePair<CGFloat, AnimatablePair<Double, Double>>> {
        get { AnimatablePair(bloom, AnimatablePair(reach, AnimatablePair(growth, lit))) }
        set {
            bloom = newValue.first
            reach = newValue.second.first
            growth = newValue.second.second.first
            lit = newValue.second.second.second
        }
    }

    var body: some View {
        Surface(bloom: bloom, active: active, notch: notch, reach: reach, grownFrom: grownFrom, growth: growth, lit: lit,
                overflow: overflow, page: page, flipped: flipped, charts: charts)
            // Laid out in the frame, but spilling past it below (above, turned over; and either
            // side, given room).
            .padding(EdgeInsets(top: flipped ? -overflow.below : 0, leading: -overflow.side, bottom: flipped ? 0 : -overflow.below,
                                trailing: -overflow.side))
            .allowsHitTesting(false)
    }

    /// The moon and its dial in a band of `size` reaching `reach`: the center, and the dial's
    /// outer radius (the pin's circle; the disc is 36/58 of it, the inscription at 67/58).
    static func moon(in size: CGSize, reach: CGFloat) -> (center: CGPoint, radius: CGFloat) {
        (Charts(Plate(size: size, reach: reach)).moon, Design.moonRadius)
    }

    /// The planisphere's middle, whose hours are set round it at 132 (in the frame's points).
    static func planisphere(in size: CGSize, reach: CGFloat) -> CGPoint { Charts(Plate(size: size, reach: reach)).planisphere }

    /// Cygnus's foot star, Albireo, which its name's set by.
    static func cygnus(in size: CGSize, reach: CGFloat) -> CGPoint { Charts(Plate(size: size, reach: reach)).cygnus }

    /// How deep the band's foot is, `x` along a band of `size` reaching `reach` (as it rests, before
    /// it flows), in the frame's points.
    static func foot(atX x: CGFloat, in size: CGSize, reach: CGFloat) -> CGFloat {
        Design.foot(x, Plate(size: size, reach: reach))
    }

    /// The backdrop's clock: seconds since it started, which every bloom carries on from.
    static var clock: Double { CACurrentMediaTime() - Renderer.epoch }

    /// How much of the plate there is at `point` in a band of `size` reaching `reach`, `bloom`
    /// open, at `time` on the backdrop's `clock`, its foot kept clear of `page` and swelling into
    /// `overflow`: 1 well inside, thinning to nothing where it dissolves, as the shader has it (bar
    /// its mottling). For what's set over it, so it goes where the plate goes.
    static func presence(at point: CGPoint, in size: CGSize, reach: CGFloat, page: CGRect,
                         overflow: (side: CGFloat, below: CGFloat), bloom: Double, time: Double) -> Double {
        let plate = Plate(size: size, reach: reach)
        let inside = -Design.outline(point.x, point.y, plate)
        let rim = Liquid.point(around: point.x - plate.middle, plate: plate, size: size, page: page,
                               moon: moon(in: size, reach: reach), overflow: overflow)
        let now = Liquid.sample(rim, time: time)
        let opened = 0.2 + 0.8 * Liquid.smooth((bloom - 0.1) / 0.7)
        let start = Double(now.start) * opened, width = Double(now.width) * opened
        let flow = Double(now.flow) * Liquid.smooth((bloom - 0.4) / 0.6) + Flower.overshoot(bloom)
        return Liquid.smooth((Double(inside) + flow - start) / width) * Flower.open(at: point, plate, bloom: bloom, time: time)
    }

    /// Compiles the shader ahead of the first bloom, off the main thread, so that one opens on time.
    static func prepare() {
        DispatchQueue.global(qos: .utility).async { _ = Renderer.pipeline }
    }
}

// MARK: Design

/// What the shape, the layout and the shader agree on, in points from the band's top left.
private enum Design {
    /// The foot: `reach` down under the notch (its soft point `point` deeper than the curve, about
    /// `pointWidth` wide), rising toward the screen's edges by `sag` of its depth, as how far out
    /// it is (0 under the notch, 1 at an edge) to the power `curve`.
    static let sag: CGFloat = 0.22, curve: CGFloat = 2.4, point: CGFloat = 10, pointWidth: CGFloat = 36

    /// How deep the foot is at `x`.
    static func foot(_ x: CGFloat, _ plate: Plate) -> CGFloat {
        let dx = x - plate.middle, out = min(abs(dx) / max(plate.middle, 1), 1)
        return (plate.reach - point) * (1 - sag * pow(out, curve)) + point * exp(-pow(dx / pointWidth, 2))
    }

    /// How steeply the foot falls at `x` (down over across).
    static func slope(_ x: CGFloat, _ plate: Plate) -> CGFloat {
        let dx = x - plate.middle, half = max(plate.middle, 1), out = min(abs(dx) / half, 1)
        let tip = point * exp(-pow(dx / pointWidth, 2))
        return -(plate.reach - point) * sag * curve * pow(max(out, 1e-4), curve - 1) / half * (dx < 0 ? -1 : 1)
            - 2 * dx / (pointWidth * pointWidth) * tip
    }

    /// How far below the foot (x, y) is, negative above it, inside the band: as the shader works
    /// it out (see its `outline`).
    static func outline(_ x: CGFloat, _ y: CGFloat, _ plate: Plate) -> CGFloat {
        (y - foot(x, plate)) / sqrt(1 + pow(slope(x, plate), 2))
    }

    /// Where along the foot the band's outline is drawn: every 4 points or so, edge to edge.
    static func footSamples(width: CGFloat) -> [CGFloat] {
        let count = max(Int(width / 4), 2)
        return (0...count).map { width * CGFloat($0) / CGFloat(count) }
    }

    /// About how far the page reaches either side of the middle, whichever page it is: the charts
    /// keep clear of it.
    static let pageHalf: CGFloat = 350
    /// The moon's dial's outer radius.
    static let moonRadius: CGFloat = 58
    /// The orrery's outermost planet: its orbit's half-length, how eccentric (its far end out past
    /// the plate, the sun near the near end), how wide it looks (tilted as the others are), and how
    /// long it takes to go round, in seconds.
    static let wanderer = (length: CGFloat(66), eccentricity: CGFloat(0.78), tilt: CGFloat(0.42), period: 90.0)
    static var wandererWidth: CGFloat {
        wanderer.length * sqrt(1 - wanderer.eccentricity * wanderer.eccentricity) * wanderer.tilt
    }
    /// How far round the orbit goes a radian, on average (Ramanujan's), and the dots' spacing.
    static var wandererRound: CGFloat {
        let a = wanderer.length, b = wandererWidth
        return (3 * (a + b) - sqrt((3 * a + b) * (a + 3 * b))) / 2
    }
    static var wandererDots: CGFloat { 2 * .pi * wandererRound / (2 * .pi * wandererRound / 4.6).rounded() }

    /// The glass's blur, thinned out toward where the plate dissolves: none in the last
    /// `glassInset` points, whole by `glassFeather` further in.
    static let glassInset: CGFloat = 4, glassFeather: CGFloat = 60
}

/// The band in a frame of a given size: how wide it is, and how far down it reaches.
private struct Plate {
    let width: CGFloat
    let reach: CGFloat

    init(size: CGSize, reach: CGFloat) {
        width = max(size.width, 1)
        self.reach = max(min(reach, size.height), 1)
    }

    var middle: CGFloat { width / 2 }
}

/// Where things go on the plate, in points from the band's top left: the planisphere left, the
/// orrery and then the moon right (higher and lower), Cygnus under the page, a little left of the
/// notch. Asymmetric, and clear of the page wherever the screen's wide enough for that, and of
/// the screen's edges.
private struct Charts {
    let planisphere: CGPoint, orrery: CGPoint, moon: CGPoint, cygnus: CGPoint

    /// None on the plate: all far off it, below and (the planisphere) to the left.
    static let away = Charts(planisphere: CGPoint(x: -100_000, y: 100_000), orrery: CGPoint(x: 100_000, y: 100_000),
                             moon: CGPoint(x: 100_000, y: 100_000), cygnus: CGPoint(x: 100_000, y: 100_000))

    private init(planisphere: CGPoint, orrery: CGPoint, moon: CGPoint, cygnus: CGPoint) {
        self.planisphere = planisphere
        self.orrery = orrery
        self.moon = moon
        self.cygnus = cygnus
    }

    init(_ plate: Plate) {
        let middle = plate.middle, page = Design.pageHalf, reach = plate.reach
        planisphere = CGPoint(x: middle - min(page + 200, middle - 70), y: 150)
        orrery = CGPoint(x: middle + min(page + 110, middle - 255), y: 118)
        moon = CGPoint(x: middle + min(page + 285, middle - 85), y: min(max(reach * 0.48, 128), max(reach - 110, 128)))
        cygnus = CGPoint(x: middle - 150, y: reach - 38)
    }
}

// MARK: The bloom

/// How the band opens: out of the notch every way at once, like a flower, its front spreading
/// wider than deep, as the band is, seven petals unfurling (turning a little as they open) with
/// the notches between them filling in as it comes, the soft edge rippling; the foot swelling a
/// touch past where it rests and settling. Fully open, it covers it all, so the band rests as it
/// is. The shader works it out just as this does (see its `flowerOpen`).
private enum Flower {
    /// Where it opens from (points down from the top, under the notch's middle).
    static let top: CGFloat = 16

    /// How much wider than deep it opens.
    static func stretch(_ plate: Plate) -> CGFloat { max(plate.middle / plate.reach, 1) * 0.92 }

    /// How far out (in its own measure, wider than deep) its front is when fully open: past every
    /// corner of the band, and what swells and spills from its foot.
    static func reach(_ plate: Plate) -> CGFloat { 1.5 * (plate.reach + 20) }

    /// How far out its edge is `angle` round (down is π/2), `bloom` open, and how soft it is there.
    static func edge(_ angle: Double, _ plate: Plate, bloom: Double, time: Double) -> (radius: Double, soft: Double) {
        let b = min(max(bloom, 0), 1), t = time.truncatingRemainder(dividingBy: 3600)
        let front = Double(reach(plate)) * b
        let depth = 0.4 * (1 - Liquid.smooth((b - 0.5) / 0.5)), turn = 0.35 + 0.6 * (1 - b)
        // (Uneven: the petals bunch and spread round it, and some reach further than others.)
        let around = angle + 0.22 * sin(2 * angle + 0.7) - turn
        let petal = (1 - depth * (1 - pow(0.5 + 0.5 * cos(7 * around), 0.7))) * (1 - depth * 0.35 * (0.5 + 0.5 * sin(3 * angle + 1.1)))
        let ripple = 1 + 0.03 * (1 - b) * sin(13 * angle + 1.9 * t) * sin(7 * angle - 1.3 * t + 1)
        return (front * petal * ripple, 0.1 * front + 8)
    }

    /// How much of it's open at `point`: 1 well inside, nothing past its edge.
    static func open(at point: CGPoint, _ plate: Plate, bloom: Double, time: Double) -> Double {
        guard bloom < 1 else { return 1 }
        let v = CGPoint(x: (point.x - plate.middle) / stretch(plate), y: point.y - top)
        let edge = edge(atan2(Double(v.y), Double(v.x)), plate, bloom: bloom, time: time)
        return 1 - Liquid.smooth((Double(hypot(v.x, v.y)) - edge.radius + edge.soft) / edge.soft)
    }

    /// The foot's swell as the bloom comes to rest: out a touch past where it rests, and back.
    static func overshoot(_ bloom: Double) -> Double {
        5 * sin(.pi * min(max((bloom - 0.72) / 0.28, 0), 1))
    }

    /// Its outline, `inset` of the way into its soft edge, in the band's points.
    static func path(_ plate: Plate, bloom: Double, time: Double, inset: Double) -> Path {
        var path = Path()
        let steps = 240, stretch = Double(stretch(plate))
        for step in 0..<steps {
            let angle = 2 * Double.pi * Double(step) / Double(steps)
            let edge = edge(angle, plate, bloom: bloom, time: time)
            let radius = max(edge.radius - edge.soft * inset, 0)
            let point = CGPoint(x: Double(plate.middle) + cos(angle) * radius * stretch, y: Double(top) + sin(angle) * radius)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: The liquid outline

/// The band's foot as it flows, never a straight edge: swelling and pinching in slow lobes that
/// wander along it and come and go, its deepest part drifting off center and back, a lasting
/// swell under the moon; and along it, where the plate dissolves. Worked out here, at `count`
/// points along the foot a frame, for the shader to read, and for what's set over the plate, so
/// it goes where the plate goes. It never pinches in over the page or the moon, and never swells
/// past the room the window leaves.
private enum Liquid {
    /// How many points along the foot the shader's told about, evenly from the left edge to the right.
    static let count = 240

    /// What doesn't change from frame to frame at a point along the foot: how far along it is
    /// (from under the notch, negative on the left), of how far it goes each way; where it is and
    /// which way is out; how far it is from the page and the moon, how far up it may pinch and
    /// down it may swell; and how much the moon's lasting swell lifts it.
    struct Point {
        var around: CGFloat, span: CGFloat
        var at: CGPoint, out: CGPoint
        var clear: CGFloat, room: CGFloat, swell: CGFloat, moon: CGFloat
    }

    /// At a point along the foot, now: how far it's flowed out (points, negative in), where the
    /// plate starts to dissolve up from it and over how far, and the furthest it ever pinches in
    /// there (which the glass's blur keeps clear of).
    struct Sample {
        var flow: Float, start: Float, width: Float, pinch: Float
    }

    /// The lobes: where each lives, how far either way it wanders and how wide it is (fractions of
    /// the way from under the notch to an edge, negative on the left), and how long it takes to
    /// swell and pinch, and to wander (seconds).
    static let lobes: [(home: CGFloat, wander: CGFloat, width: CGFloat, swells: Double, wanders: Double, phase: Double)] = [
        (-0.78, 0.12, 0.15, 41, 57, 0.4),   // out on the left, under the planisphere
        (-0.38, 0.1, 0.12, 29, 43, 2.3),    // between it and the page
        (0.14, 0.16, 0.2, 47, 61, 4.1),     // under the page, off to one side or the other
        (0.52, 0.1, 0.13, 35, 49, 5.6),     // the right, under the orrery
    ]
    /// How far the moon's kept clear of, its inscription and all, as a fraction of the dial's radius.
    static let moonClear: CGFloat = 80 / 58
    /// At most, in points: how far the foot pinches in, and swells out; and the room it leaves
    /// past it, for what drifts out, before the window's edge.
    static let pinch: CGFloat = 50, swell: CGFloat = 45, drift: CGFloat = 52

    static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// How far along the foot the `index`th point is.
    static func around(_ index: Int, _ plate: Plate) -> CGFloat {
        plate.middle * (2 * CGFloat(index) / CGFloat(count - 1) - 1)
    }

    /// The point `around` along the foot of a band of `size`, with how far it is from the page and
    /// the moon's dial, and the room below the frame.
    static func point(around a: CGFloat, plate: Plate, size: CGSize, page: CGRect,
                      moon: (center: CGPoint, radius: CGFloat), overflow: (side: CGFloat, below: CGFloat)) -> Point {
        let x = min(max(plate.middle + a, 0), plate.width)
        let at = CGPoint(x: x, y: Design.foot(x, plate))
        let slope = Design.slope(x, plate), length = sqrt(1 + slope * slope)
        let out = CGPoint(x: -slope / length, y: 1 / length)
        func distance(to rect: CGRect) -> CGFloat {
            hypot(max(rect.minX - at.x, 0, at.x - rect.maxX), max(rect.minY - at.y, 0, at.y - rect.maxY))
        }
        let toMoon = max(hypot(at.x - moon.center.x, at.y - moon.center.y) - moon.radius * moonClear, 0)
        let clear = page.isEmpty ? toMoon : min(distance(to: page), toMoon)
        let room = (size.height + overflow.below - at.y) / max(out.y, 1e-3)
        return Point(around: a, span: plate.middle, at: at, out: out, clear: clear,
                     room: min(max(clear - 42, 0), pinch), swell: min(max(room - drift, 0), swell),
                     moon: exp(-pow((a - (moon.center.x - plate.middle)) / 150, 2)))
    }

    /// The foot at `p` at `time`: its lobes, waves and drift, soft against the room it has either
    /// way; and the plate's dissolve up from it, narrowed where it has to be to stay clear of the
    /// page and the moon.
    static func sample(_ p: Point, time: Double) -> Sample {
        let a = Double(p.around), span = Double(p.span), t = time
        func wave(_ period: Double, _ phase: Double) -> Double { sin(2 * .pi * t / period + phase) }
        func turn(_ period: Double, _ offset: Double) -> Double {
            (t / period + offset).truncatingRemainder(dividingBy: 1) * 2 * .pi
        }
        // The lobes, each wandering round its home, widening and narrowing, swelling out and
        // pinching in (more often out); a slow beat between two long waves along it all; the
        // deepest part drifting off center and back; and the moon's lasting swell.
        var x = 0.0
        for lobe in lobes {
            let center = (Double(lobe.home) + Double(lobe.wander) * wave(lobe.wanders, lobe.phase * 1.7)) * span
            let width = Double(lobe.width) * span * (1 + 0.25 * wave(lobe.wanders * 0.7, lobe.phase))
            x += (0.15 + 0.85 * wave(lobe.swells, lobe.phase)) * exp(-pow((a - center) / width, 2))
        }
        x += 0.4 * sin(a * 0.0123 - turn(31, 0.2)) * sin(a * 0.0071 + turn(53, 0.6))
        let drifted = (0.16 * wave(37, 0) + 0.07 * wave(23, 1.3)) * span
        x += 0.7 * exp(-pow((a - drifted) / (0.2 * span), 2))
        x += Double(p.moon)
        let flow = Double(x >= 0 ? p.swell : p.room) * tanh(x)

        // The dissolve: its start ripples in and out, a long ripple running along it from left to
        // right, a shorter one running back, a fine shimmer over them; its width swells and
        // narrows slowly, wider on the left (38 to 60) than the right (30 to 46), and never so
        // wide it reaches the page or the moon.
        let start = 3 + 1.3 * sin(a * 0.026 - turn(17, 0.1)) + 0.7 * sin(a * 0.059 + turn(11, 0.55))
            + 0.3 * sin(a * 0.141 - turn(6.5, 0.3))
        let uneven = 0.5 + 0.3 * sin(a * 0.0113 + turn(41, 0.7)) + 0.2 * sin(a * 0.0187 - turn(29, 0.2))
        let right = smooth((a + 150) / 300)
        let narrowest = 38 + (30 - 38) * right, widest = 60 + (46 - 60) * right
        let width = max(min(narrowest + (widest - narrowest) * uneven, Double(p.clear) + flow - start - 6), 12)
        return Sample(flow: Float(flow), start: Float(start), width: Float(width), pinch: Float(p.room))
    }
}

// MARK: Drawing

extension MidnightBackdrop {
    /// Hosts the Metal view.
    private struct Surface: NSViewRepresentable {
        let bloom: Double
        let active: Bool
        let notch: CGSize
        let reach: CGFloat
        let grownFrom: CGFloat
        let growth: Double
        let lit: Double
        let overflow: (side: CGFloat, below: CGFloat)
        let page: CGRect
        let flipped: Bool
        let charts: Bool

        func makeNSView(context: Context) -> BackdropView { BackdropView() }

        func updateNSView(_ view: BackdropView, context: Context) {
            view.renderer?.flipped = flipped
            view.renderer?.charts = charts
            view.update(bloom: bloom, notch: notch, reach: reach, grownFrom: grownFrom, growth: growth, lit: lit,
                        overflow: overflow, page: page, active: active)
        }
    }

    /// A see-through Metal view that draws only while it's active and on screen, and never takes
    /// the mouse.
    private final class BackdropView: MTKView {
        let renderer: Renderer?
        var active = true {
            didSet { if active != oldValue { updatePaused() } }
        }
        private var occlusion: NSObjectProtocol?
        /// Drawing the Dock's while it's up, on a clock of its own (see `updatePaused`), and how
        /// many times it's ticked (at rest, every other tick draws).
        private var ticking: Timer?
        private var ticks = 0
        private var clockStarted: CFTimeInterval = 0
        /// Gone a second without a frame while up: said once, in the log.
        private var stalled = false
        /// The screens are asleep, or the session's locked: then nothing's shown to draw for (and
        /// waiting for something to draw into could hold everything up).
        private var away = false
        private var awayWatch: [NSObjectProtocol] = []
        private static let log = Logger(subsystem: "local.nott", category: "midnight")

        init() {
            renderer = MidnightMetal.device.flatMap(Renderer.init)
            super.init(frame: .zero, device: MidnightMetal.device)
            wantsLayer = true
            layer?.isOpaque = false
            layer?.backgroundColor = .clear
            colorPixelFormat = .bgra8Unorm
            clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            framebufferOnly = true
            preferredFramesPerSecond = 60
            delegate = renderer
            let workspace = NSWorkspace.shared.notificationCenter
            for (name, gone) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                                 (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
                awayWatch.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.away = gone }
                })
            }
            updatePaused()
        }

        deinit {
            awayWatch.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        }

        required init(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(bloom: Double, notch: CGSize, reach: CGFloat, grownFrom: CGFloat, growth: Double, lit: Double,
                    overflow: (side: CGFloat, below: CGFloat), page: CGRect, active: Bool) {
            guard let renderer else { return }
            keepScale()
            let changed = bloom != renderer.bloom || notch != renderer.notch || reach != renderer.reach
                || grownFrom != renderer.grownFrom || growth != renderer.growth || lit != renderer.lit
                || overflow != renderer.overflow || page != renderer.page
            renderer.bloom = bloom
            renderer.notch = notch
            renderer.reach = reach
            renderer.grownFrom = grownFrom
            renderer.growth = growth
            renderer.lit = lit
            renderer.overflow = overflow
            renderer.page = page
            // Opening, growing or lighting up wants every frame; at rest everything moves slowly
            // enough for half.
            let moving = bloom < 0.999 || growth < 0.999 || (lit > 0.001 && lit < 0.999)
            let rate = moving ? 60 : 30
            if preferredFramesPerSecond != rate { preferredFramesPerSecond = rate }
            self.active = active
            if changed && isPaused { needsDisplay = true }
        }

        /// The layer's scale, kept to its window's. Made before it's in a window that's on a
        /// screen (the Dock's is, at launch), it's left at 0, which shows nothing of what's drawn
        /// into it however well it's drawn, and nothing puts it right till the window's backing
        /// changes: so it's set as it goes into a window, as that changes, and checked each time
        /// it's told what to draw.
        private func keepScale() {
            guard let scale = window?.backingScaleFactor, scale > 0, let layer, layer.contentsScale != scale else { return }
            layer.contentsScale = scale
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            keepScale()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            keepScale()
            if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
            occlusion = nil
            if let window {
                occlusion = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePaused() }
                }
            }
            updatePaused()
        }

        /// Paused, it still draws once when told to (a new bloom, a new size), but no more.
        ///
        /// The Dock's, while it's up, is drawn on a clock of its own, never by the view's display
        /// link. Under the menu bar's level, the Dock can count as covered by a window that's only
        /// see-through (macOS's screenshot overlay, left up after a screenshot, is one); and with
        /// nothing over it at all, the display link can go quiet with the Dock in plain sight. Either
        /// way the sky would stop on its last frame, which, coming up after it last wilted, is
        /// none: only the bar and its icons. The band's goes by the display link while it's up and
        /// showing.
        private func updatePaused() {
            let covered = window?.occlusionState.contains(.visible) != true
            let clocked = active && renderer?.flipped == true && window != nil
            let showing = active && renderer != nil && !covered && !clocked
            if clocked, ticking == nil {
                stalled = false
                clockStarted = CACurrentMediaTime()
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                ticking = timer
            } else if !clocked {
                ticking?.invalidate()
                ticking = nil
            }
            isPaused = !showing
            enableSetNeedsDisplay = !showing && !clocked
            if !showing, !clocked { needsDisplay = true }
        }

        /// The Dock's clock: a frame each tick while it's opening or growing, every other at rest;
        /// and if none's got drawn for a second, why, in the log.
        private func tick() {
            guard !away else {
                clockStarted = CACurrentMediaTime()
                return
            }
            ticks += 1
            keepScale()
            if preferredFramesPerSecond >= 60 || ticks % 2 == 0 { draw() }
            let last = max(renderer?.lastFrame ?? 0, clockStarted)
            guard let renderer, CACurrentMediaTime() - last > 1 else {
                stalled = false
                return
            }
            guard !stalled else { return }
            stalled = true
            let gone = CACurrentMediaTime() - last, missed = renderer.missed
            let visible = window?.occlusionState.contains(.visible) == true
            Self.log.error("The Dock's sky has drawn nothing for \(gone, format: .fixed(precision: 1)) s: \(missed, privacy: .public) tries without a drawable, view \(Int(self.bounds.width))x\(Int(self.bounds.height)), window visible \(visible, privacy: .public)")
        }
    }

    /// Draws the backdrop: one pass of the shader over the whole frame. The slow clockwork (the
    /// dials, the planets, what falls when) is worked out here, a few numbers a frame, and handed
    /// to the shader.
    final class Renderer: NSObject, MTKViewDelegate {
        var bloom = 0.0
        var notch = MidnightArch.notch
        var reach = MidnightArch.full
        var grownFrom = MidnightArch.full
        var growth = 1.0
        var lit = 0.0
        /// How far the drawable reaches past the bloom's frame, either side and below, in points.
        var overflow = (side: CGFloat(0), below: CGFloat(0))
        /// The page, in the frame's points (see `MidnightBackdrop.page`).
        var page: CGRect = .zero
        /// The moment to draw the moon (a clock) and the hour for: now, unless it's set.
        var date: Date?
        /// Turned over, and without its charts (see `MidnightBackdrop`).
        var flipped = false
        var charts = true
        private let queue: MTLCommandQueue
        /// The moon's phase as the clock has it (0 new, ½ full) and the hour (0–24), and when they
        /// were last worked out.
        private var night = (phase: 0.0, hour: 0.0)
        private var nightChecked = -Double.infinity
        /// How far the pinned moon's dial has turned, and the time it was last drawn.
        private var dial = 0.0
        private var drawn: Double?
        /// The points along the foot, which change only with the shape (and what they were worked
        /// out for); and where the drop that's gathering hangs from, and in which of its rounds.
        private var rim: [Liquid.Point] = []
        private var rimFor: (reach: CGFloat, size: CGSize, page: CGRect, side: CGFloat, below: CGFloat, charts: Bool)?
        private var dropFrom: (round: Double, index: Int)?

        /// One for all of them, compiled the first time it's needed.
        static let pipeline: MTLRenderPipelineState? = {
            guard let device = MidnightMetal.device else { return nil }
            do {
                let library = try MidnightMetal.library(shader)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "backdropVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "backdropFragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("Midnight Oyl's backdrop shader didn't build: \(error)")
                return nil
            }
        }()

        /// When the backdrop's clock started: shared, so each bloom carries on from the last.
        fileprivate static let epoch = CACurrentMediaTime()

        init?(device: MTLDevice) {
            guard let queue = MidnightMetal.queue ?? device.makeCommandQueue(), Self.pipeline != nil else { return nil }
            self.queue = queue
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        /// When a frame was last drawn (on `CACurrentMediaTime`'s clock), and how many tries since
        /// had nothing to draw into.
        private(set) var lastFrame: CFTimeInterval?
        private(set) var missed = 0

        func draw(in view: MTKView) {
            guard view.bounds.width > 0, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
            else {
                missed += 1
                return
            }
            let time = CACurrentMediaTime() - Self.epoch
            encode(encoder, pixels: view.drawableSize, scale: view.drawableSize.width / view.bounds.width, time: time)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
            lastFrame = CACurrentMediaTime()
            missed = 0
        }

        /// Draws one frame into whatever `encoder` renders to, `pixels` big at `scale` pixels a point:
        /// the bloom's frame, and `overflow` round it.
        func encode(_ encoder: MTLRenderCommandEncoder, pixels: CGSize, scale: CGFloat, time: Double) {
            guard let pipeline = Self.pipeline else { return }
            // The plate's laid out in the bloom's own frame, top center in the drawable.
            let points = CGSize(width: max(pixels.width / scale - 2 * overflow.side, 1),
                                height: max(pixels.height / scale - overflow.below, 1))
            let plate = Plate(size: points, reach: reach)
            let from = Plate(size: points, reach: grownFrom)
            let reach = Double(plate.reach), grownFrom = Double(from.reach)
            let charts = self.charts ? Charts(plate) : .away
            let growth = min(max(growth, 0), 1)
            if time - nightChecked > 60 || time < nightChecked {
                night = Self.night(at: date ?? Date())
                nightChecked = time
            }
            // The pinned dial turns once in two minutes, easing in and out with the lamp.
            if let drawn { dial = (dial + lit * min(max(time - drawn, 0), 0.1) * 2 * .pi / 120).truncatingRemainder(dividingBy: 2 * .pi) }
            drawn = time

            var u = Uniforms()
            u.width = Float(pixels.width)
            u.height = Float(pixels.height)
            u.scale = Float(scale)
            u.plate = 1
            u.mapX = Float(1 / scale)
            u.mapY = Float(1 / scale)
            u.pole = Float(notch.height)
            u.middle = Float(plate.middle)
            u.flowerTop = Float(Flower.top)
            u.stretch = Float(Flower.stretch(plate))
            u.front = Float(Flower.reach(plate))
            // As far as anything on the plate is from the pole, for the opening's front to reach.
            u.extent = Float(hypot(plate.middle, plate.reach))
            u.planisphereX = Float(charts.planisphere.x)
            u.planisphereY = Float(charts.planisphere.y)
            u.orreryX = Float(charts.orrery.x)
            u.orreryY = Float(charts.orrery.y)
            u.moonX = Float(charts.moon.x)
            u.moonY = Float(charts.moon.y)
            u.cygnusX = Float(charts.cygnus.x)
            u.cygnusY = Float(charts.cygnus.y)
            let quiet = page.isEmpty ? CGRect(x: plate.middle - Design.pageHalf, y: 0, width: 2 * Design.pageHalf, height: plate.reach - 120)
                : page
            u.quietLeft = Float(quiet.minX)
            u.quietRight = Float(quiet.maxX)
            u.quietFoot = Float(quiet.maxY)
            u.reach = Float(reach)
            u.grownFrom = Float(grownFrom)
            u.growth = Float(growth)
            u.bloom = Float(bloom)
            u.lit = Float(min(max(lit, 0), 1))
            // Wrapped hourly, so a float still counts in fine steps however long it's open; anything
            // that has to keep turning smoothly past that is worked out here instead.
            u.time = Float(time.truncatingRemainder(dividingBy: 3600))
            u.phase = Float(night.phase)
            u.hour = Float(night.hour)
            u.disc = Float(Self.turn(time, period: 1440, offset: 0.35))
            u.planet1 = Float(Self.turn(time, period: 60, offset: 0.6))
            u.planet2 = Float(Self.turn(time, period: 150, offset: 2.4))
            u.planet3 = Float(Self.turn(time, period: 400, offset: 4.1))
            u.planet4 = Float(Self.turn(time, period: 1100, offset: 5.3))
            u.moonlet = Float(Self.turn(time, period: 8, offset: 0))
            u.colure = Float(4 * Double.pi / 180 * sin(2 * .pi * time / 40))
            u.dial = Float(dial)
            u.streakAlong = -1
            let sky = Sky(width: Double(plate.width), reach: reach, page: Double(quiet.maxY), charts: charts)
            if let streak = Self.shootingStar(at: time, sky: sky, grownFrom: grownFrom, growth: growth) {
                u.streakX = Float(streak.start.x)
                u.streakY = Float(streak.start.y)
                u.streakDX = Float(streak.heading.x)
                u.streakDY = Float(streak.heading.y)
                u.streakLength = Float(streak.length)
                u.streakAlong = Float(streak.along)
            }
            if let comet = Self.comet(at: time, sky: sky) {
                u.cometX = Float(comet.head.x)
                u.cometY = Float(comet.head.y)
                u.cometDX = Float(comet.tail.x)
                u.cometDY = Float(comet.tail.y)
                u.comet = Float(comet.strength)
            }
            if let spark = Self.spark(at: time, sky: sky, pole: Double(u.pole)) {
                u.sparkX = Float(spark.at.x)
                u.sparkY = Float(spark.at.y)
                u.spark = Float(spark.strength)
            }
            u.glitch = Float(Self.glitch(at: time))
            u.side = Float(overflow.side)
            u.mottle = Float(Self.turn(time, period: 41, offset: 0.7))
            u.flip = flipped ? 1 : 0

            // The foot as it flows now, at evenly spaced points along it.
            if rimFor == nil || rimFor!.reach != plate.reach || rimFor!.size != points || rimFor!.page != page
                || rimFor!.side != overflow.side || rimFor!.below != overflow.below || rimFor!.charts != self.charts {
                let moon = charts.moon == Charts.away.moon ? (center: charts.moon, radius: 0) : MidnightBackdrop.moon(in: points, reach: plate.reach)
                rim = (0..<Liquid.count).map { index in
                    Liquid.point(around: Liquid.around(index, plate), plate: plate, size: points, page: page, moon: moon,
                                 overflow: overflow)
                }
                rimFor = (plate.reach, points, page, overflow.side, overflow.below, self.charts)
            }
            let flowing = rim.map { Liquid.sample($0, time: time) }
            u.span = Float(plate.middle)
            // The drop hangs from the foot's lowest point as each one starts to gather, and from
            // that same point of the rim, wherever it flows, till it's gone.
            let round = (time / 10).rounded(.down)
            if dropFrom?.round != round {
                let foot = rim.indices.filter { abs(rim[$0].around) < plate.middle * 0.5 }
                let lowest = foot.max { a, b in
                    rim[a].at.y + CGFloat(flowing[a].flow) * rim[a].out.y < rim[b].at.y + CGFloat(flowing[b].flow) * rim[b].out.y
                }
                dropFrom = (round, lowest ?? Liquid.count / 2)
            }
            if let index = dropFrom?.index, index < rim.count {
                let at = rim[index].at, flow = CGFloat(flowing[index].flow)
                u.dropX = Float(at.x + flow * rim[index].out.x - points.width / 2)
                u.dropY = Float(at.y + flow * rim[index].out.y - plate.reach)
            }
            let drop = Self.drop(at: time)
            u.dropBelow = Float(drop.below)
            u.dropRadius = Float(drop.radius)
            u.dropLight = Float(drop.light)
            u.dropBurst = Float(drop.burst)
            let wanderer = Self.wanderer(at: time)
            u.wandererX = Float(wanderer.x)
            u.wandererY = Float(wanderer.y)

            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            var table = flowing.map { SIMD4<Float>($0.flow, $0.start, $0.width, $0.pinch) }
            encoder.setFragmentBytes(&table, length: MemoryLayout<SIMD4<Float>>.stride * table.count, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    /// What the shader's told each frame; laid out as its `Uniforms` (all floats, in order).
    private struct Uniforms {
        var width: Float = 0, height: Float = 0, scale: Float = 0
        var plate: Float = 0
        var mapX: Float = 0, mapY: Float = 0
        var pole: Float = 0
        var reach: Float = 0, grownFrom: Float = 0, growth: Float = 0
        var bloom: Float = 0, lit: Float = 0, time: Float = 0
        var phase: Float = 0, hour: Float = 0
        var disc: Float = 0
        var planet1: Float = 0, planet2: Float = 0, planet3: Float = 0, planet4: Float = 0
        var moonlet: Float = 0, colure: Float = 0, dial: Float = 0
        var streakX: Float = 0, streakY: Float = 0, streakDX: Float = 0, streakDY: Float = 0
        var streakLength: Float = 0, streakAlong: Float = 0
        var cometX: Float = 0, cometY: Float = 0, cometDX: Float = 0, cometDY: Float = 0, comet: Float = 0
        var sparkX: Float = 0, sparkY: Float = 0, spark: Float = 0
        var glitch: Float = 0
        var side: Float = 0
        var mottle: Float = 0, span: Float = 0, dropX: Float = 0, dropY: Float = 0
        var dropBelow: Float = 0, dropRadius: Float = 0, dropLight: Float = 0, dropBurst: Float = 0
        var wandererX: Float = 0, wandererY: Float = 0
        var middle: Float = 0, flowerTop: Float = 0, stretch: Float = 0, front: Float = 0, extent: Float = 0
        var planisphereX: Float = 0, planisphereY: Float = 0, orreryX: Float = 0, orreryY: Float = 0
        var moonX: Float = 0, moonY: Float = 0, cygnusX: Float = 0, cygnusY: Float = 0
        var quietLeft: Float = 0, quietRight: Float = 0, quietFoot: Float = 0
        var flip: Float = 0
    }
}

// MARK: The clockwork

extension MidnightBackdrop.Renderer {
    /// The band the clockwork plays across: how wide, how deep, how far down the page comes, and
    /// where the charts are (points from its top left).
    fileprivate struct Sky {
        let width: Double, reach: Double, page: Double
        let charts: Charts
        var middle: Double { width / 2 }
    }

    /// A shooting star in points: where it starts, which way it heads (a unit vector), how far it
    /// goes, and how far along it is (0–1).
    struct Streak {
        var start: CGPoint
        var heading: CGPoint
        var length: Double
        var along: Double
    }

    /// The shooting star falling at `time`, if one is. Each 11 s, with a chance of 0.7, one falls
    /// at a hashed moment for 0.6 s, down-left or down-right at 20–35°, in one of the lanes the
    /// band leaves room for (out on the left; under the orrery; under the page), never through
    /// the page. While growing into new room, one is sure to cross it.
    fileprivate static func shootingStar(at time: Double, sky: Sky, grownFrom: Double, growth: Double) -> Streak? {
        let reach = sky.reach, middle = sky.middle
        if reach > grownFrom + 1, growth < 1 {
            let target = grownFrom + (reach - grownFrom) / max(growth, 0.02)
            let along = (growth - 0.16) / 0.3
            if target - grownFrom >= 60, along >= 0, along <= 1 {
                let angle = 18 * Double.pi / 180
                return Streak(start: CGPoint(x: middle + 220, y: grownFrom - 30), heading: CGPoint(x: -cos(angle), y: sin(angle)),
                              length: 190, along: along)
            }
        }
        let slot = (time / 11).rounded(.down)
        guard hash(slot, 1) < 0.7 else { return nil }
        let along = (time - slot * 11 - hash(slot, 2) * 10.2) / 0.6
        guard along >= 0, along <= 1 else { return nil }
        let rightward = hash(slot, 3) < 0.5
        let angle = (20 + 15 * hash(slot, 4)) * Double.pi / 180
        var length = 70 + 70 * hash(slot, 5)
        let across = hash(slot, 6), down = hash(slot, 7)
        let orrery = sky.charts.orrery
        var start: CGPoint
        switch Int(hash(slot, 8) * 3) {
        case 1 where reach - orrery.y >= 170:
            let y = orrery.y + 104 + 20 * down
            start = CGPoint(x: orrery.x + (rightward ? -90 + 50 * across : 40 - 50 * across), y: y)
            length = min(length, (reach * 0.8 - 30 - y) / sin(angle))
        case 2 where reach - sky.page >= 90:
            let y = sky.page + 12 + 12 * down
            start = CGPoint(x: middle + (rightward ? -260 + 120 * across : 260 - 120 * across), y: y)
            length = min(length, (reach - 44 - y) / sin(angle))
        default:
            start = CGPoint(x: rightward ? 24 + 60 * across : max(sky.charts.planisphere.x + 60, 140) - 60 * across, y: 48 + 50 * down)
        }
        guard length > 40 else { return nil }
        return Streak(start: start, heading: CGPoint(x: rightward ? cos(angle) : -cos(angle), y: sin(angle)),
                      length: length, along: along)
    }

    /// The comet at `time`, given room under the page: each 180 s, with a chance of 0.5, one
    /// crosses under it over 14 s, its tail turned away from the orrery's sun. Its head, the
    /// tail's way (a unit vector), and how bright (fading in and out).
    fileprivate static func comet(at time: Double, sky: Sky) -> (head: CGPoint, tail: CGPoint, strength: Double)? {
        guard sky.reach - sky.page > 100 else { return nil }
        let slot = (time / 180).rounded(.down)
        guard hash(slot, 11) < 0.5 else { return nil }
        let along = (time - slot * 180 - hash(slot, 12) * 160) / 14
        guard along >= 0, along <= 1 else { return nil }
        let way = hash(slot, 13) < 0.5 ? along : 1 - along
        let head = CGPoint(x: sky.middle - 320 + 640 * way, y: sky.reach - 64 + 18 * way - 12 * sin(.pi * way))
        let away = CGPoint(x: head.x - sky.charts.orrery.x, y: head.y - sky.charts.orrery.y)
        let length = max(hypot(away.x, away.y), 1)
        let strength = min(along / 0.15, 1) * min((1 - along) / 0.15, 1)
        return (head, CGPoint(x: away.x / length, y: away.y / length), strength * strength * (3 - 2 * strength))
    }

    /// The glint at a crossing of the grid's lines, about one every 2 s: off the page, on the
    /// plate, clear of the charts. Where, in points, and how bright now.
    fileprivate static func spark(at time: Double, sky: Sky, pole: Double) -> (at: CGPoint, strength: Double)? {
        let slot = (time / 2).rounded(.down)
        let along = (time - slot * 2) / 1.3
        guard along < 1 else { return nil }
        let rings = max(((sky.middle - 200) / 80).rounded(.down), 1)
        let plate = Plate(size: CGSize(width: sky.width, height: sky.reach), reach: sky.reach)
        for attempt in 0..<10 {
            let salt = UInt64(20 + 3 * attempt)
            let radius = 200 + 80 * (hash(slot, salt) * rings).rounded(.down)
            let angle = ((hash(slot, salt + 1) * 13).rounded(.down) - 6) * 15 * Double.pi / 180
            let at = CGPoint(x: sky.middle + radius * sin(angle), y: pole + radius * cos(angle))
            let onPage = abs(at.x - sky.middle) < Design.pageHalf - 40 && at.y < sky.page + 20
            let onPlate = at.x > 16 && at.x < sky.width - 16 && at.y > 44 && at.y < Design.foot(at.x, plate) - 30
            let charts = sky.charts
            let clear = hypot(at.x - charts.planisphere.x, at.y - charts.planisphere.y) > 156
                && hypot(at.x - charts.moon.x, at.y - charts.moon.y) > 72 && hypot(at.x - charts.orrery.x, at.y - charts.orrery.y) > 102
            if !onPage, onPlate, clear {
                let rise = sin(.pi * along)
                return (at, rise * rise)
            }
        }
        return nil
    }

    /// Whether the plate's glitching at `time`, and with what slices: rarely (each 23 s, with a
    /// chance of 0.5, for 80 ms). 0 if not; otherwise a seed for the slices.
    static func glitch(at time: Double) -> Double {
        let slot = (time / 23).rounded(.down)
        let since = time - slot * 23 - hash(slot, 31) * 22.8
        return hash(slot, 30) < 0.5 && since >= 0 && since < 0.08 ? 1 + slot.truncatingRemainder(dividingBy: 997) : 0
    }

    /// The drop of light at the dome's point at `time`, in points: how far its middle is below the
    /// point (negative, still in the plate), how big it is, how bright its core, and how far
    /// through bursting into sparkles (0–1). Each 10 s, at a hashed moment, it gathers 20 points up
    /// in the dissolving plate for 3.4 s, slides out of it over 0.8, falls 30 slowly over 2.2,
    /// shrinking and dimming, and bursts over 0.9. (Slowly enough to fall smoothly at the 30
    /// frames a second the backdrop draws at rest.)
    static func drop(at time: Double) -> (below: Double, radius: Double, light: Double, burst: Double) {
        let slot = (time / 10).rounded(.down)
        var t = time - slot * 10 - hash(slot, 41) * 2.4
        let radius = 4.2, gathers = -20.0, parted = 4.0
        func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        guard t >= 0 else { return (0, 0, 0, 0) }
        if t < 3.4 {
            let gathered = 1 - pow(1 - t / 3.4, 2)
            return (gathers, radius * gathered, gathered, 0)
        }
        t -= 3.4
        if t < 0.8 { return (gathers + (parted - gathers) * smooth(t / 0.8), radius, 1, 0) }
        t -= 0.8
        if t < 2.2 {
            let fallen = t / 2.2
            return (parted + 30 * (1 - cos(.pi / 2 * fallen)), radius - 1.6 * fallen, 1 - 0.4 * fallen, 0)
        }
        t -= 2.2
        if t < 0.9 { return (parted + 30, 2.6 * max(1 - t / 0.25, 0), 0.6 * max(1 - t / 0.25, 0), t / 0.9) }
        return (0, 0, 0, 0)
    }

    /// Where the orrery's outermost planet is at `time`, in the orrery's own plane (design points,
    /// from its sun): once round its long orbit each 90 s, as Kepler has it, quick past the sun and
    /// slow out at the far end, past the plate's edge.
    static func wanderer(at time: Double) -> CGPoint {
        let length = Double(Design.wanderer.length), eccentricity = Double(Design.wanderer.eccentricity)
        let mean = turn(time, period: Design.wanderer.period, offset: 0.2)
        var anomaly = mean + eccentricity * sin(mean)
        for _ in 0..<8 {
            anomaly -= (anomaly - eccentricity * sin(anomaly) - mean) / (1 - eccentricity * cos(anomaly))
        }
        return CGPoint(x: length * (eccentricity - cos(anomaly)), y: Double(Design.wandererWidth) * sin(anomaly))
    }

    /// The moon's phase at `date`, the moon being a clock (see `clockPhase`), and the hour there
    /// (0–24).
    static func night(at date: Date) -> (phase: Double, hour: Double) {
        let clock = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(clock.hour ?? 0) + Double(clock.minute ?? 0) / 60 + Double(clock.second ?? 0) / 3600
        return (clockPhase(hour / 24), hour)
    }

    /// The moon's phase (0 new, ½ full) at `day` (0 to 1, from midnight), as the clock it is: new
    /// at midnight, it waxes, lit by as much of its face as the morning's gone (half at six), till
    /// it's full at noon; then it wanes, dark by as much as the afternoon and evening have, till
    /// it's new again at midnight. (Its terminator's the real one's, so the phase that lights a
    /// share of the face isn't that share: a crescent's lit by less than its phase says.)
    static func clockPhase(_ day: Double) -> Double {
        let day = day - day.rounded(.down)
        let lit = day < 0.5 ? day * 2 : 2 - day * 2
        let phase = acos(min(max(1 - 2 * lit, -1), 1)) / (2 * .pi)
        return day < 0.5 ? phase : 1 - phase
    }

    /// How far round something that turns once each `period` seconds is at `time`, in radians.
    private static func turn(_ time: Double, period: Double, offset: Double) -> Double {
        (time / period + offset).truncatingRemainder(dividingBy: 1) * 2 * .pi
    }

    /// A number in 0..<1, the same each time for the same `n` and `salt` (splitmix64).
    private static func hash(_ n: Double, _ salt: UInt64) -> Double {
        var z = UInt64(bitPattern: Int64(n)) &* 0x9E37_79B9_7F4A_7C15 &+ salt &* 0xD1B5_4A32_D192_ED03
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}

// MARK: Shader

// Everything is drawn in design points (820 across, heights down from the top, squeezed toward
// the notch while it opens), traced once a pixel: each weight of line is a distance to its nearest
// line, and the chromatic fringe is that distance moved a fraction of a pixel along its own slope.
// Each motif is only looked at inside its own bounds.
private let shader = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float width, height, scale;      // the drawable, in pixels; pixels a point
    float plate;                     // points a design point
    float mapX, mapY;                // design points a pixel, across and down
    float pole;                      // the notch's foot, in design points down
    float reach, grownFrom, growth;  // design points; growth 0 to 1
    float bloom, lit, time;
    float phase, hour;               // the moon, a clock (0 new at midnight, 0.5 full at noon); the hour, 0 to 24
    float disc;                      // the planisphere's star disc, turned
    float planet1, planet2, planet3, planet4, moonlet, colure, dial;
    float streakX, streakY, streakDX, streakDY, streakLength, streakAlong;   // along < 0: none falling
    float cometX, cometY, cometDX, cometDY, comet;
    float sparkX, sparkY, spark;
    float glitch;
    float side;                      // how far the drawable reaches past the bloom either side, points
    float mottle;                    // how far round the dissolve's mottling has drifted
    float span;                      // how far along the foot goes each way, points
    float dropX, dropY;              // the point of the foot the drop hangs from, from under the notch's, points
    float dropBelow, dropRadius, dropLight, dropBurst;   // the drop, points
    float wandererX, wandererY;      // the orrery's outermost planet, in its plane
    float middle;                    // the band's middle, under the notch
    float flowerTop, stretch, front; // the bloom: where it opens from, how much wider than deep, how far its front goes
    float extent;                    // as far as anything on the plate is from the pole
    float planisphereX, planisphereY, orreryX, orreryY, moonX, moonY, cygnusX, cygnusY;
    float quietLeft, quietRight, quietFoot;   // the page's column
    float flip;                      // 1: turned over, rising from the drawable's foot
};

struct Fragment { float4 position [[position]]; };

vertex Fragment backdropVertex(uint id [[vertex_id]]) {
    float2 corner = float2((id << 1) & 2, id & 2);
    Fragment out;
    out.position = float4(corner * 2 - 1, 0, 1);
    return out;
}

constant float PI = 3.14159265;
constant float TAU = 6.2831853;
constant float SAG = \(Design.sag), CURVE = \(Design.curve);
constant float POINT = \(Design.point);
constant float POINT_WIDTH = \(Design.pointWidth);
constant float WANDERER_LENGTH = \(Design.wanderer.length), WANDERER_ECCENTRICITY = \(Design.wanderer.eccentricity);
constant float WANDERER_WIDTH = \(Design.wandererWidth), WANDERER_ROUND = \(Design.wandererRound);
constant float WANDERER_DOTS = \(Design.wandererDots);
// How far past the edge anything spills, in points: what drifts out of the plate, and under the
// foot's lowest point, where the drop falls. Past them, nothing's drawn.
constant float SPREAD = 42, SPILL = 60;
// How many points along the foot the CPU works out how it flows (see `Liquid`); how far in it
// ever pinches and out it swells (points).
constant int RIM_COUNT = \(Liquid.count);
constant float PINCH = \(Liquid.pinch), SWELL = \(Liquid.swell);
constant float GLASS_INSET = \(Design.glassInset), GLASS_FEATHER = \(Design.glassFeather);
// Where the three filaments are rooted (points along the foot from under the notch, negative on
// the left), how long they are, and which way they lean; and how far in from the edge their
// roots are, deep in the plate's dissolve.
constant float3 FILAMENTS[3] = { float3(-520, 46, -1), float3(300, 36, 1), float3(-130, 30, 1) };
constant float FILAMENT_ROOT = 16;

constant float3 INK = float3(0.014, 0.018, 0.040);
constant float3 WHITE = float3(0.95, 0.96, 0.98);
constant float3 SILVER = float3(0.84, 0.87, 0.93);
constant float3 MOONLIGHT = float3(0.80, 0.87, 1.00);
constant float3 STARLIGHT = float3(1.00, 0.95, 0.86);
constant float3 NEBULA = float3(0.74, 0.70, 0.92);
constant float3 FRINGE_RED = float3(1.00, 0.70, 0.76);
constant float3 FRINGE_BLUE = float3(0.66, 0.78, 1.00);

// The Plough, on the planisphere's disc (from its center), and how bright each star is; its
// lines run from the first star round, the last closing the bowl.
constant float2 PLOUGH[7] = { float2(-70, 30), float2(-46, 22), float2(-24, 26), float2(-4, 34),
                              float2(4, 58), float2(34, 62), float2(38, 36) };
constant float PLOUGH_M[7] = { 1.8, 1.9, 1.8, 3.3, 2.4, 1.9, 2.4 };
constant int2 PLOUGH_LINES[7] = { int2(0, 1), int2(1, 2), int2(2, 3), int2(3, 4), int2(4, 5), int2(5, 6), int2(6, 3) };
// Cygnus, under the page: Deneb, Sadr, the wings, Albireo (from Albireo).
constant float2 CYGNUS[5] = { float2(-16, -74), float2(-10, -50), float2(-45, -46), float2(26, -58), float2(0, 0) };
constant float CYGNUS_M[5] = { 1.25, 2.2, 2.5, 2.9, 3.1 };
// The moon's craters: where (from its center) and how big.
constant float3 CRATERS[8] = { float3(12, -10, 5), float3(20, 8, 3.4), float3(6, 16, 6.5), float3(26, -4, 2.2),
                               float3(2, -22, 3), float3(-14, 4, 4.4), float3(-9, -15, 2.6), float3(-19, 17, 3.6) };

float sq(float x) { return x * x; }

// Ease-out cubic, clamped.
float ease(float x) {
    x = saturate(x);
    return 1 - (1 - x) * (1 - x) * (1 - x);
}

float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3 - 2 * f);
    return mix(mix(hash12(i), hash12(i + float2(1, 0)), u.x), mix(hash12(i + float2(0, 1)), hash12(i + 1), u.x), u.y);
}

float2 rotate(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x + s * p.y, -s * p.x + c * p.y);
}

float segment(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    return length(pa - ba * saturate(dot(pa, ba) / dot(ba, ba)));
}

// How far along a dashed line `along` is from its nearest dash: dashes `on` long, every `period`.
float dashGap(float along, float period, float on) {
    return max(abs(along - period * round(along / period)) - on * 0.5, 0.0);
}

// How much thinner a ring trimming on is `around` (0–1 round it) with its head at `trim`: none
// well behind the head, thinning to nothing over the last 20°, so it draws on without a notch.
float feather(float around, float trim) {
    return (1 - saturate((trim - around) * 18)) * 3;
}

// The distance to an ellipse of radii r about the origin (signed, good near it).
float ellipse(float2 p, float2 r) {
    float k0 = length(p / r), k1 = length(p / (r * r));
    return k0 * (k0 - 1) / max(k1, 1e-5);
}

// The distance to a quadratic curve from a through b's pull to c.
float bezier(float2 p, float2 a, float2 b, float2 c) {
    float2 A = b - a, B = a - 2 * b + c, C = A * 2, D = a - p;
    float k = 1 / dot(B, B);
    float kx = k * dot(A, B), ky = k * (2 * dot(A, A) + dot(D, B)) / 3, kz = k * dot(D, A);
    float s = ky - kx * kx, s3 = s * s * s;
    float q = kx * (2 * kx * kx - 3 * ky) + kz;
    float h = q * q + 4 * s3;
    if (h >= 0) {
        h = sqrt(h);
        float2 x = (float2(h, -h) - q) / 2;
        float2 uv = sign(x) * pow(abs(x), float2(1.0 / 3.0));
        float t = saturate(uv.x + uv.y - kx);
        return length(D + (C + B * t) * t);
    }
    float z = sqrt(-s);
    float v = acos(q / (s * z * 2)) / 3;
    float m = cos(v), n = sin(v) * 1.732050808;
    float2 t = saturate(float2(m + m, -n - m) * z - kx);
    return min(length(D + (C + B * t.x) * t.x), length(D + (C + B * t.y) * t.y));
}

// How a box filter covers a line `width` pixels wide, `d` pixels from its middle.
float line(float d, float width) {
    return saturate(min(d + 0.5 * width, 0.5) - max(d - 0.5 * width, -0.5));
}

// How a dot `radius` points across covers a pixel `d` points from its middle.
float spot(float d, float radius, float scale) {
    return saturate((radius - d) * scale + 0.5);
}

// One arm of a glint: thin across, tapering to nothing `size` along.
float arm(float across, float along, float size) {
    return exp(-across / 0.3) * saturate(1 - along / size);
}

// A four-pointed glint `size` points long, with shorter, fainter diagonals; `d` in points.
float glint(float2 d, float size) {
    float2 a = abs(d);
    float2 r = abs(float2(d.x + d.y, d.x - d.y)) * 0.7071;
    return arm(a.x, a.y, size) + arm(a.y, a.x, size) + (arm(r.x, r.y, size * 0.45) + arm(r.y, r.x, size * 0.45)) * 0.4;
}

// A star of magnitude m, `d` points away: its core and a little halo, and with `arms`, a glint
// that long (points).
float star(float2 d, float m, float arms, float scale) {
    float radius = clamp(0.3 + 0.3 * (6.5 - m), 0.3, 2.4);
    float brightness = 0.35 + 0.65 * (6.5 - m) / 5.5;
    float r = length(d);
    float light = spot(r, radius, scale) + exp(-r / (radius * 0.7 + 0.35)) * 0.22;
    if (arms > 0) light += glint(d, arms);
    return light * brightness;
}

// How deep the band's foot is at x (points from its left; `middle` is half its width), and how
// steeply it falls there: deepest, `reach` down, under the notch, with a soft point there, rising
// toward the screen's edges by SAG of its depth (as Design.foot has it).
float2 footAt(float x, float reach, float middle) {
    float dx = x - middle, out = min(abs(dx) / middle, 1.0);
    float tip = POINT * exp(-sq(dx / POINT_WIDTH));
    float slope = -(reach - POINT) * SAG * CURVE * pow(max(out, 1e-4), CURVE - 1) / middle * sign(dx)
        - 2 * dx / (POINT_WIDTH * POINT_WIDTH) * tip;
    return float2((reach - POINT) * (1 - SAG * pow(out, CURVE)) + tip, slope);
}

// How lit a moon of `radius` is at p (from its center) at `phase`: positive on the lit side of
// the terminator, by about that many design points.
float moonLit(float2 p, float radius, float phase) {
    float side = phase < 0.5 ? 1.0 : -1.0;
    float w = sqrt(max(radius * radius - p.y * p.y, 0.0));
    return (side * p.x - cos(TAU * phase) * w) * 0.8;
}

// The moon's phase at `day` (0 to 1 from midnight), as the clock it is: lit by as much of its face
// as the morning's gone, then dark by as much as the afternoon and evening have (see
// `MidnightBackdrop.clockPhase`).
float clockPhase(float day) {
    float lit = day < 0.5 ? day * 2 : 2 - day * 2;
    float phase = acos(clamp(1 - 2 * lit, -1.0, 1.0)) / TAU;
    return day < 0.5 ? phase : 1 - phase;
}

// The distances to each weight of line, nearest first (design points), and how much engraved
// fill (petals) is here.
struct Trace {
    float bold, major, minor, fine, grid, hair;
    float fill;
};

// What every motif needs to know about the pixel and the moment.
struct Sky {
    float2 q;           // the pixel, in design points
    float2 toPoints;    // points a design point, across and down
    float ppu, scale;   // pixels a design point; pixels a point
    float bloom, time, pole, reach;
    float quiet;        // 1 deep in the page and camera's column
    float wing;         // 1 out in the wings
    float milky;        // how deep in the Milky Way
    float room;         // the flare where the foot's passing into new room
    bool inRoom;        // below the foot it grew from
    float grownFrom, target, growth;
    float plate;        // how much of the plate is here: 0 where it's dissolved into the desktop
    float middle;       // the band's middle, under the notch
    float extent;       // as far as anything on the plate is from the pole
    float2 planisphere;
    float flowerTop, stretch, front;   // the bloom's middle, how much wider than deep, its full reach
};

// How far open the bloom has to be for its front to reach `at` (0 at its middle, 1 its full reach).
float arrival(float2 at, Sky s) {
    return length(float2((at.x - s.middle) / s.stretch, at.y - s.flowerTop)) / s.front;
}

// How far a star at `at` has come on (0 dark, 1 lit), and how many magnitudes brighter it's
// flaring: as the opening's front reaches it, or as the foot passes it into new room.
float2 ignite(float2 at, float salt, Sky s) {
    float start = arrival(at, s) * 0.95 + 0.02 * salt;
    float since = s.bloom - start;
    float on = saturate(since / 0.015 + 0.5);
    float flare = 2.5 * saturate(1 - since / 0.08) * on + 3 * s.room;
    return float2(on, flare);
}

// How far round from the meridian a circle of `radius` round the pole is drawn, in radians: it
// sweeps on both ways once the opening's front reaches it, and in new room once the growing foot
// has passed its lowest point.
float swept(float radius, Sky s) {
    float opening = saturate((s.bloom - (s.pole + radius - s.flowerTop) / s.front) / 0.15) * PI;
    if (!s.inRoom || s.pole + radius < s.grownFrom) return opening;
    float passed = saturate((s.pole + radius - s.grownFrom) / max(s.target - s.grownFrom, 1.0));
    return min(opening, saturate((s.growth - passed) / 0.35) * PI * 0.5);
}

// The pole's grid: declination circles every 80 from 120, alternately solid and dotted; hour
// lines every 15° from 60 out, reaching out with the opening's front; and the graduated circle at
// 440, its ticks popping in behind its sweep.
void polarGrid(float2 v, Sky s, thread Trace &t) {
    float r = length(v);
    float phi = atan2(v.x, v.y);   // 0 straight down the meridian
    float k = clamp(round((r - 120) / 80), 0.0, floor((s.extent - 120) / 80));
    float radius = 120 + 80 * k;
    float off = abs(r - radius);
    if (off < 6 && k != 4 && abs(phi) <= swept(radius, s)) {
        float d = off;
        if (fmod(k, 2.0) > 0.5) d = length(float2(off, dashGap(radius * phi, TAU * radius / round(TAU * radius / 4.4), 1.2)));
        t.grid = min(t.grid, d);
    }
    float front = s.bloom * s.front;
    if (abs(phi) < PI * 0.5 + 0.05 && r < front) {
        float h = round(phi / (PI / 12)) * (PI / 12);
        float d = r > 60 ? r * abs(sin(phi - h)) : length(v - 60 * float2(sin(h), cos(h)));
        t.hair = min(t.hair, d);
    }
    if (abs(r - 443) < 9) {
        float reach = swept(440, s);
        if (abs(phi) <= reach) {
            t.minor = min(t.minor, abs(r - 440));
            t.fine = min(t.fine, abs(r - 446.5));
            float degree = phi * 180 / PI;
            float kd = round(degree);
            if (abs(kd) * PI / 180 <= reach - 0.04) {
                float n = abs(kd);
                float tick = fmod(n, 10.0) == 0 ? 6.0 : (fmod(n, 5.0) == 0 ? 4.0 : 2.2);
                float across = abs(degree - kd) * PI / 180 * r;
                t.fine = min(t.fine, length(float2(across, max(max(440 - r, r - 440 - tick), 0.0))));
            }
        }
    }
}

// A constellation's dotted line from a toward b, drawn `drawn` of the way, stopping 5 short of
// each star.
float constellation(float2 p, float2 a, float2 b, float drawn) {
    if (drawn <= 0) return 1e3;
    float2 ab = b - a;
    float len = length(ab);
    float2 dir = ab / len, pa = p - a;
    float along = dot(pa, dir), across = abs(dir.x * pa.y - dir.y * pa.x);
    float outside = max(5 - along, along - (5 + (len - 10) * drawn));
    return length(float2(across, max(dashGap(along - 5, 3.1, 0.1), max(outside, 0.0))));
}

// The planisphere, left and partly off the plate: a fixed hour scale (three rings, a tick a
// degree; its numerals are SwiftUI's) round a star disc that turns, with the Plough on it, and the
// horizon's window over it. It draws on clockwise from XII by `trim` as the bloom opens, and the
// disc turns in. `p` is from its center.
void planisphere(float2 p, Sky s, float trim, float turn, float drawn, thread Trace &t, thread float3 &light) {
    float r = length(p);
    float around = fract(atan2(p.x, -p.y) / TAU + 1);   // 0 at XII, clockwise
    if (around >= trim) return;
    float thin = trim < 1 ? feather(around, trim) : 0.0;
    t.bold = min(t.bold, abs(r - 146) + thin);
    t.minor = min(t.minor, min(abs(r - 139), abs(r - 125)) + thin);
    if (r > 137 && r < 148) {
        float degree = around * 360, k = round(degree);
        float tick = fmod(k, 15.0) == 0 ? 7.0 : (fmod(k, 5.0) == 0 ? 4.2 : 2.2);
        float across = abs(degree - k) * PI / 180 * r;
        t.fine = min(t.fine, length(float2(across, max(max(146 - tick - r, r - 146), 0.0))));
    }
    t.minor = min(t.minor, abs(ellipse(p - float2(0, -11), float2(109.5, 92.7))));
    if (r > 124) return;

    float2 d = rotate(p, turn);
    float a = atan2(d.y, d.x);
    float period = TAU * 44 / 69;
    t.fine = min(t.fine, length(float2(abs(r - 44), dashGap(44 * a, period, 1.5))));
    t.fine = min(t.fine, length(float2(abs(r - 88), dashGap(88 * a, period, 1.5))));
    float spoke = round(a / (TAU / 12)) * (TAU / 12);
    t.grid = min(t.grid, r > 8 ? r * abs(sin(a - spoke)) : length(d - 8 * float2(cos(spoke), sin(spoke))));
    float2 e = d - float2(20, -16);
    float ecliptic = abs(length(e) - 92);
    if (ecliptic < 4) t.minor = min(t.minor, length(float2(ecliptic, dashGap(92 * atan2(e.y, e.x), TAU * 92 / 89, 4))));
    t.major = min(t.major, min(segment(d, float2(-4, 0), float2(4, 0)), segment(d, float2(0, -4), float2(0, 4))));

    float iso = s.ppu / s.scale;
    float2 id = floor(d / 15);
    if (hash12(id + 91.7) < 0.38) {
        float2 at = (id + 0.2 + 0.6 * hash22(id + 17.3)) * 15;
        if (length(at) < 118 && length(at - float2(20, -16)) > 3) {
            float m = 3 + 3.4 * hash12(id + 5.9);
            float warm = hash12(id + 2.1);
            light += (warm < 0.2 ? STARLIGHT : WHITE) * star((d - at) * iso, m, 0.0, s.scale) * drawn;
        }
    }
    if (d.x > -82 && d.x < 50 && d.y > 10 && d.y < 74) {
        float lines = saturate((s.bloom - 0.6) / 0.4) * 7;
        for (int i = 0; i < 7; i++) {
            t.major = min(t.major, constellation(d, PLOUGH[PLOUGH_LINES[i].x], PLOUGH[PLOUGH_LINES[i].y], saturate(lines - i)));
            float m = PLOUGH_M[i];
            light += WHITE * star((d - PLOUGH[i]) * iso, m, m < 2.4 ? 3 + 3.2 * (2.4 - m) : 0.0, s.scale) * drawn;
        }
    }
}

// The orrery and armillary, right and high: a rayed sun, four tilted orbits each with its planet
// (the third with a moon, the fourth ringed), and round them a meridian circle ticked every 10°,
// the equator and a rocking colure. Opening, it grows from 0.6×, trims on, and the planets spiral
// out to their places. `p` is from its center.
void orrery(float2 p, Sky s, float grow, constant Uniforms &u, thread Trace &t, thread float3 &light) {
    float size = mix(0.6, 1.0, grow);
    float2 l = float2(0.978 * p.x - 0.208 * p.y, 0.208 * p.x + 0.978 * p.y) / size;
    float r = length(l);
    float iso = s.ppu / s.scale * size;
    float around = fract(atan2(l.y, l.x) / TAU + 1.25);
    if (around < grow) {
        float thin = grow < 1 ? feather(around, grow) : 0.0;
        float orbit = min(min(abs(ellipse(l, float2(23, 9.66))), abs(ellipse(l, float2(39, 16.4)))),
                          min(abs(ellipse(l, float2(58, 24.4))), abs(ellipse(l, float2(79, 33.2)))));
        t.minor = min(t.minor, orbit * size + thin);
        t.major = min(t.major, abs(r - 92) * size + thin);
        t.minor = min(t.minor, abs(ellipse(l, float2(92, 26))) * size);
        float2 c = rotate(l, u.colure);
        float colure = abs(ellipse(c, float2(26, 92)));
        if (colure < 4) t.fine = min(t.fine, length(float2(colure, dashGap(92 * atan2(c.y, c.x), TAU * 92 / 128, 2))) * size);
        if (r > 90 && r < 98) {
            float a = atan2(l.y, l.x) * 180 / PI, k = round(a / 10) * 10;
            float tick = fmod(abs(k), 30.0) == 0 ? 5.0 : 2.6;
            float across = abs(a - k) * PI / 180 * r;
            t.fine = min(t.fine, length(float2(across, max(max(92 - r, r - 92 - tick), 0.0))) * size);
        }
    }
    // The sun and its rays.
    if (r < 12) {
        light += STARLIGHT * (spot(r * iso, 4.6, s.scale) * 0.95 + exp(-r * iso / 3.5) * 0.35) * grow;
        float a = atan2(l.y, l.x), k = round(a / (TAU / 12));
        float ray = (fmod(abs(k), 2.0) < 0.5) ? 9.7 : 7.9;
        float along = r * cos(a - k * TAU / 12), across = r * abs(sin(a - k * TAU / 12));
        t.minor = min(t.minor, length(float2(across, max(max(5.8 - along, along - ray), 0.0))) * size);
    }
    // The planets, spiralling out to their places as it opens.
    float out = ease(grow), lag = (1 - out) * 5;
    float2 radii[4] = { float2(23, 9.66), float2(39, 16.4), float2(58, 24.4), float2(79, 33.2) };
    float angles[4] = { u.planet1, u.planet2, u.planet3, u.planet4 };
    float sizes[4] = { 1.4, 1.9, 1.8, 2.5 };
    for (int i = 0; i < 4; i++) {
        float a = angles[i] - lag;
        float2 at = radii[i] * float2(cos(a), sin(a)) * out;
        float2 d = l - at;
        float dist = length(d);
        if (dist > 12) continue;
        light += WHITE * spot(dist * iso, sizes[i], s.scale) * 0.95 * grow;
        if (grow <= 0) continue;
        if (i == 2) {
            t.fine = min(t.fine, abs(dist - 5.3) * size);
            float2 moonlet = at + 5.3 * float2(cos(u.moonlet), sin(u.moonlet));
            light += WHITE * spot(length(l - moonlet) * iso, 0.8, s.scale) * 0.9 * grow;
        }
        if (i == 3) t.minor = min(t.minor, abs(ellipse(d, float2(5.6, 1.9))) * size);
    }
}

// The moon, low right, a clock: new at midnight, waxing through the morning, full at noon and
// waning to midnight again (see `clockPhase`), the lit part engraved silver with its craters, the
// dark part hatched. Round it a dial of the day: midnight at the top, noon at the foot, a tick an
// hour (longer every three, longest every six), the moon at every third hour, and a glint for now.
// Opening, the dial trims on and the disc waxes from new to the hour's phase; pinned, the dial
// turns and a starlight lamp breathes round it. `p` is from its center.
void moon(float2 p, Sky s, constant Uniforms &u, thread Trace &t, thread float3 &light) {
    float r = length(p);
    float opening = saturate((s.bloom - 0.45) / 0.55);
    float trim = ease(opening * 1.6);
    float around = fract(atan2(p.x, -p.y) / TAU + 1);
    float iso = s.ppu / s.scale;
    if (r < 37) {
        float phase = u.phase * ease(opening);
        float inside = saturate((36 - r) * s.ppu + 0.5);
        float lit = moonLit(p, 36, phase);
        float lighted = saturate(lit * s.ppu + 0.5) * inside;
        float crater = 1e3;
        for (int i = 0; i < 8; i++) crater = min(crater, abs(length(p - CRATERS[i].xy) - CRATERS[i].z));
        float ink = line(crater * s.ppu, 0.55 * s.scale) * 0.42;
        float limb = 0.86 + 0.14 * sqrt(saturate(1 - r * r / 1296));
        light += SILVER * 0.92 * limb * (1 - ink) * lighted * smoothstep(0.0, 0.2, opening);
        float hatch = abs(fract((p.x + p.y) / (2.6 * 1.41421) + 0.5) - 0.5) * 2.6;
        if (around < trim) t.fine = min(t.fine, hatch + max(lit, 0.0) * 2 + max(r - 35.5, 0.0) * 4);
    }
    float halo = exp(-max(r - 36, 0.0) / 12) * 0.10 * opening;
    float lamp = u.lit * (0.8 + 0.2 * sin(TAU * 0.27 * s.time)) * exp(-max(r - 36, 0.0) / 15) * 0.2;
    light += (MOONLIGHT * halo + STARLIGHT * lamp) * step(35.5, r);
    if (around < trim) {
        float thin = trim < 1 ? feather(around, trim) : 0.0;
        t.bold = min(t.bold, abs(r - 36) + thin);
        t.minor = min(t.minor, abs(r - 46) + thin);
        t.major = min(t.major, abs(r - 58) + thin);
    }
    if (r < 44 || r > 60) return;
    float turned = fract(around - u.dial / TAU + 1);
    float hours = turned * 24, k = fmod(round(hours), 24.0);
    if (k / 24 < trim - 0.02) {
        float tick = fmod(k, 6.0) == 0 ? 6.0 : fmod(k, 3.0) == 0 ? 4.5 : 3.0;
        float across = abs(hours - round(hours)) * TAU / 24 * r;
        t.fine = min(t.fine, length(float2(across, max(max(46 - r, r - 46 - tick), 0.0))));
    }
    float j = fmod(round(turned * 8), 8.0);
    if (j / 8 < trim) {
        float a = j / 8 * TAU + u.dial;
        float2 pip = p - 54.5 * float2(sin(a), -cos(a));
        float pr = length(pip);
        t.fine = min(t.fine, abs(pr - 2.3));
        light += SILVER * 0.7 * saturate(moonLit(pip, 2.3, clockPhase(j / 8)) * s.ppu * 2 + 0.5) * spot(pr * iso, 2.3, s.scale);
    }
    float now = u.hour / 24 * TAU + u.dial;
    float2 mark = (p - 58 * float2(sin(now), -cos(now))) * iso;
    light += mix(WHITE, STARLIGHT, u.lit) * (glint(mark, 4.5) * 0.9 + spot(length(mark), 1.1, s.scale)) * smoothstep(0.75, 1.0, opening);
}

// Cygnus, the Northern Cross, under the page, its foot star Albireo at `albireo`: its dotted
// lines draw on from Deneb. `drawn` 0 to 1.
void cygnus(float2 q, float2 albireo, Sky s, float drawn, thread Trace &t, thread float3 &light) {
    float2 at[5];
    for (int i = 0; i < 5; i++) at[i] = albireo + CYGNUS[i];
    float first = saturate(drawn * 2), then = saturate(drawn * 2 - 1);
    t.major = min(t.major, constellation(q, at[0], at[1], first));
    t.major = min(t.major, min(constellation(q, at[1], at[2], then), constellation(q, at[1], at[3], then)));
    t.major = min(t.major, constellation(q, at[1], at[4], then));
    for (int i = 0; i < 5; i++) {
        float m = CYGNUS_M[i];
        float2 on = ignite(at[i], 0.3, s);
        light += (i == 4 ? STARLIGHT : WHITE) * star((q - at[i]) * s.toPoints, m - on.y, m < 2.4 ? 3 + 3.2 * (2.4 - m) : 0.0, s.scale)
            * on.x * smoothstep(0.0, 0.3, drawn);
    }
}

// The faint stars: one in some 14-point cells, a dot each (no arms), three times as many in the
// Milky Way; in the quiet column two of three fainter than 5 are dropped.
float3 faintStars(Sky s) {
    float2 id = floor(s.q / 14);
    float chance = (0.16 + 0.11 * s.wing) * (1 + 2 * s.milky);
    if (hash12(id) > chance) return 0;
    float2 at = (id + 0.2 + 0.6 * hash22(id + 31.7)) * 14;
    float2 d = (s.q - at) * s.toPoints;
    if (dot(d, d) > 16) return 0;
    float m = 4 + 2.5 * sqrt(hash12(id + 7.3));
    float salt = hash12(id + 3.9);
    if (m > 5 && s.quiet > 0.5 && salt < 0.667) return 0;
    // Where the plate dissolves, they thin out, one by one.
    float thinned = smoothstep(salt * 0.85, salt * 0.85 + 0.15, s.plate);
    float2 on = ignite(at, salt, s) * float2(thinned, 1);
    if (on.x <= 0) return 0;
    float twinkle = 1 + 0.08 * sin(s.time * (1.2 + 2.6 * salt) + salt * 40);
    float light = star(d, m - on.y, 0.0, s.scale) * twinkle * on.x;
    return (hash12(id + 13.1) < 0.18 ? STARLIGHT : WHITE) * light;
}

// The bright stars: one in some 46-point cells, looked for in the four nearest; the brightest
// with glint arms. They twinkle, now and then flash their arms, and flare as they ignite. No
// glints in the quiet column.
float3 brightStars(Sky s, float2 moon) {
    float3 light = 0;
    float2 base = floor(s.q / 46 - 0.5);
    for (int i = 0; i < 4; i++) {
        float2 id = base + float2(i & 1, i >> 1);
        if (hash12(id + 11.3) > (0.3 + 0.16 * s.wing) * (1 + s.milky)) continue;
        float2 at = (id + 0.15 + 0.7 * hash22(id)) * 46;
        float2 d = (s.q - at) * s.toPoints;
        if (dot(d, d) > 420) continue;
        if (length(at - s.planisphere) < 150 || length(at - moon) < 62) continue;
        float salt = hash12(id + 5.1);
        float thinned = smoothstep(salt * 0.85, salt * 0.85 + 0.15, s.plate);
        float2 on = ignite(at, salt, s) * float2(thinned, 1);
        if (on.x <= 0) continue;
        float m = 0.6 + 3.4 * pow(hash12(id + 2.7), 0.6);
        float rate = 0.2 + 0.4 * salt;
        float twinkle = m < 3 ? 1 + 0.25 * sin(TAU * rate * s.time + salt * 31) : 1 + 0.08 * sin(TAU * rate * s.time + salt * 31);
        float flash = pow(saturate(sin(TAU * s.time / (8 + 4 * salt) + salt * 17)), 24.0);
        float lit = m - on.y;
        float arms = lit < 2.4 ? 3 + 3.2 * (2.4 - lit) : 0.0;
        arms = max(arms, flash * (m < 3.2 ? 5.0 : 0.0));
        if (s.quiet > 0.5) arms = 0;
        light += (hash12(id + 13.7) < 0.18 ? STARLIGHT : WHITE) * star(d, lit, arms, s.scale) * twinkle * on.x;
    }
    return light;
}

// MARK: The dissolve, and what drifts out of it

// How far below the band's foot q is (points, negative above it, in the band), measured square
// to the foot (it's gentle enough for that to hold).
float outline(float2 q, float reach, float middle) {
    float2 foot = footAt(q.x, reach, middle);
    return (q.y - foot.x) * rsqrt(1 + foot.y * foot.y);
}

// The foot `a` along it (points from under the notch, negative on the left), from the points the
// CPU worked out how it flows at: how far it's flowed out, where the plate starts to dissolve up
// from it and over how far, and the furthest it ever pinches in (points).
float4 rimAt(float a, float span, constant float4 *rim) {
    float f = clamp((a / span * 0.5 + 0.5) * (RIM_COUNT - 1), 0.0, RIM_COUNT - 1.001);
    int i = int(f);
    return mix(rim[i], rim[i + 1], f - float(i));
}

// How much of the bloom is open at q, `bloom` of the way: out of the notch every way at once,
// wider than deep, seven petals unfurling and the notches between them filling in, the soft edge
// rippling (as Flower has it). 1 well inside, nothing past its edge.
float flowerOpen(float2 q, float bloom, float time, Sky s) {
    if (bloom >= 1) return 1;
    float2 v = float2((q.x - s.middle) / s.stretch, q.y - s.flowerTop);
    float angle = atan2(v.y, v.x);
    float front = s.front * bloom;
    float depth = 0.4 * (1 - smoothstep(0.5, 1.0, bloom)), turn = 0.35 + 0.6 * (1 - bloom);
    // (Uneven: the petals bunch and spread round it, and some reach further than others.)
    float around = angle + 0.22 * sin(2 * angle + 0.7) - turn;
    float petal = (1 - depth * (1 - pow(0.5 + 0.5 * cos(7 * around), 0.7))) * (1 - depth * 0.35 * (0.5 + 0.5 * sin(3 * angle + 1.1)));
    float ripple = 1 + 0.03 * (1 - bloom) * sin(13 * angle + 1.9 * time) * sin(7 * angle - 1.3 * time + 1);
    float radius = front * petal * ripple, soft = 0.1 * front + 8;
    return 1 - smoothstep(radius - soft, radius, length(v));
}

// What drifts out of the plate where it dissolves. `p` is the pixel round the rim and out from
// it (points: along from the dome's point, negative on the left; out from the edge the plate's
// cut to, negative inside), `ahead` and `outward` those two ways on screen. Motes rising out of
// the thinning plate at all depths and drifting up and away past it as they fade, a few with
// arms; and loose stars scattered through it and just past it, twinkling. (Born at all depths,
// so that nothing traces the edge.) Adds the ink to lay under them, out over the desktop, to
// `veil`.
float3 rimLights(float2 p, float2 ahead, float2 outward, Sky s, thread float &veil) {
    float3 light = 0;
    // The motes: one in most 14-point lengths of rim, each on its own few-second round. Each
    // drifts toward the top, so only its own length and the one it's come up from can hold it.
    if (p.y > -32 && p.y < 38) {
        float base = floor(p.x / 14), upward = base < 0 ? -1.0 : 1.0;
        for (int i = 0; i < 2; i++) {
            float id = base - upward * i;
            float2 g = hash22(float2(id, 41.7));
            float4 h = float4(g, fract(g.x * 13.7 + g.y * 7.3), fract(g.x * 4.7 + g.y * 9.1));
            if (h.x > 0.75) continue;
            float age = fract(s.time / (3.2 + 3.4 * h.z) + h.y);
            float up = id < 0 ? -1.0 : 1.0;
            float2 at = float2((id + 0.5 + (h.y - 0.5) * 0.5) * 14 + up * (3 + 8 * h.x) * age,
                               -3 - 24 * h.w + (18 + 18 * h.z) * (1 - sq(1 - age)));
            float2 d = p - at;
            float r2 = dot(d, d);
            if (r2 > 16) continue;
            float fade = smoothstep(0.0, 0.12, age) * pow(1 - age, 1.6) * (0.55 + 0.8 * h.x);
            float size = 0.55 + 0.95 * h.z * h.z, r = sqrt(r2);
            float mote = spot(r, size, s.scale) + exp(-r2 / (2 * size * size + 0.6)) * 0.45;
            if (h.x < 0.12) mote += glint(ahead * d.x + outward * d.y, 3.4) * 0.7;
            light += SILVER * mote * fade;
            veil = max(veil, exp(-r2 / 5) * 0.45 * saturate(fade));
        }
    }
    // The loose stars: one in most 46-point lengths, anywhere from deep in the dissolve to a
    // little past it.
    float id = round(p.x / 46);
    float2 h = hash22(float2(id, 63.1));
    if (h.x < 0.6 && id != 0) {
        float2 at = float2((id + (h.y - 0.5) * 0.7) * 46, -34 + 48 * hash12(float2(id, 5.5)));
        float2 d = ahead * (p.x - at.x) + outward * (p.y - at.y);
        if (dot(d, d) < 100) {
            float twinkle = 0.5 + 0.5 * sin(TAU * (0.15 + 0.25 * h.y) * s.time + h.x * 40);
            float flash = pow(saturate(sin(TAU * s.time / (7 + 5 * h.y) + h.y * 13)), 16.0);
            float3 tint = h.x < 0.12 ? STARLIGHT : WHITE;
            light += tint * star(d, 2.8 - 1.2 * flash, 2 + 3 * twinkle + 4 * flash, s.scale) * (0.5 + 0.5 * twinkle);
            veil = max(veil, exp(-length(d) / 2.5) * 0.35);
        }
    }
    return light;
}

// A filament of light rooted deep in the plate's dissolve, rising `size` points out of it in a lazy
// S and holding a star out at its tip, a smaller one where it turns; unfurled `grow` of the way,
// swaying `sway` radians (more toward its tip), leaning back along the rim (`turn` -1) or on (1).
// It comes up out of the plate, so it fades in from its root. `p` is from its root (points: along
// the rim, out). Adds its ink to `veil`.
float3 filament(float2 p, float size, float turn, float grow, float sway, float twinkle, float scale, thread float &veil) {
    float2 c[5] = { float2(0, 0), float2(0.34, 0.3), float2(0.14, 0.58), float2(-0.06, 0.86), float2(0.22, 1.0) };
    for (int i = 0; i < 5; i++) c[i] = rotate(c[i] * float2(turn, 1) * size * grow, sway * c[i].y);
    float d = min(bezier(p, c[0], c[1], c[2]), bezier(p, c[2], c[3], c[4]));
    float rooted = smoothstep(0.0, 0.35 * size, p.y);
    float ink = (line(d * scale, 0.55 * scale) * 0.7 + exp(-d / 1.2) * 0.06) * rooted;
    veil = max(veil, exp(-d / 1.6) * 0.4 * grow * rooted);
    float beads = star(p - c[4], 2.3, 2.5 + 3 * twinkle, scale) * smoothstep(0.6, 1.0, grow)
        + star(p - c[2], 4.2, 0.0, scale) * smoothstep(0.4, 0.8, grow) * 0.8;
    veil = max(veil, exp(-length(p - c[4]) / 2.5) * 0.45 * grow);
    return SILVER * ink * smoothstep(0.05, 0.3, grow) + WHITE * beads;
}

// The orrery's outermost planet, on a long orbit about its sun whose far end is out past the
// plate's edge: round it once each 90 s, quick past the sun, slow out in the air. The orbit's
// dotted, and trims on from the sun's end as the orrery opens (`grow`). `p` is from the orrery's
// middle. Adds its ink to `veil`.
float3 wanderer(float2 p, float grow, constant Uniforms &u, Sky s, thread float &veil) {
    float size = mix(0.6, 1.0, grow);
    float2 l = float2(0.978 * p.x - 0.208 * p.y, 0.208 * p.x + 0.978 * p.y) / size;
    float iso = s.ppu / s.scale * size;
    float3 light = 0;
    float2 radii = float2(WANDERER_LENGTH, WANDERER_WIDTH);
    float2 e = l - float2(WANDERER_LENGTH * WANDERER_ECCENTRICITY, 0);
    float off = abs(ellipse(e, radii));
    if (off < 3) {
        // How far round it from the far end, near enough: the angle round an ellipse this flat
        // covers little of it at the ends and much along the sides.
        float angle = atan2(e.y / radii.y, e.x / radii.x);
        float along = WANDERER_ROUND * angle - 0.5 * (WANDERER_ROUND - radii.y) * sin(2 * angle);
        float d = length(float2(off, dashGap(along, WANDERER_DOTS, 1.1))) * iso;
        float shown = step(PI * (1 - grow), abs(angle));
        light += SILVER * line(d * s.scale, 0.5 * s.scale) * 0.4 * shown;
        veil = max(veil, saturate(1.2 - d) * 0.22 * shown);
    }
    float2 v = (l - float2(u.wandererX, u.wandererY)) * iso;
    float r2 = dot(v, v);
    if (r2 < 100) {
        float r = sqrt(r2);
        light += (WHITE * spot(r, 1.7, s.scale) + MOONLIGHT * exp(-r / 2.2) * 0.3) * grow;
        veil = max(veil, exp(-r / 3) * 0.4 * grow);
    }
    return light;
}

// A hairline `width` points wide at distance `d` (design points), as silver with pale red and blue
// fringes either side: the line moved `fringe` pixels along `dir`, worked out from d's own slope.
float3 engrave(float d, float width, float alpha, float ppu, float scale, float2 dir, float fringe, float limit) {
    float2 slope = clamp(float2(dfdx(d), dfdy(d)), -limit, limit);
    float shift = dot(slope, dir) * fringe;
    float w = width * scale;
    float core = line(d * ppu, w), red = line((d + shift) * ppu, w), blue = line((d - shift) * ppu, w);
    return alpha * (SILVER * core + (1 - core) * (FRINGE_RED * red * 0.24 + FRINGE_BLUE * blue * 0.28));
}

// Holographic thin film, pearly: mostly silver, with a little color running through it.
float3 film(float x) {
    float3 c = MOONLIGHT * (0.5 + 0.5 * cos(TAU * x)) + float3(1.0, 0.72, 0.86) * (0.5 + 0.5 * cos(TAU * (x - 0.33)))
        + NEBULA * (0.5 + 0.5 * cos(TAU * (x - 0.66)));
    return mix(c * 0.67, SILVER, 0.65);
}

fragment float4 backdropFragment(Fragment in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                 constant float4 *rim [[buffer(1)]]) {
    float2 pixel = in.position.xy;
    if (u.flip > 0.5) pixel.y = u.height - pixel.y;
    // In points from the bloom's own top left (the drawable reaches past it either side).
    float2 point = pixel / u.scale - float2(u.side, 0);
    float MID = u.middle;
    float2 q = float2(MID + (pixel.x - u.width * 0.5) * u.mapX, pixel.y * u.mapY);
    float R = u.reach, time = u.time, bloom = saturate(u.bloom);

    // The band as it's cut, the one the page and the moon are clipped to: how far up inside it
    // from its foot this pixel is, in points (negative below it), and which way is out, on screen.
    float edge = outline(q, R, MID);
    float2 slope = float2(dfdx(edge), dfdy(edge));
    float perPixel = max(length(slope), 1e-6);
    float2 toPoints = float2(1 / (u.mapX * u.scale), 1 / (u.mapY * u.scale));
    float inside = -edge * toPoints.y;
    float2 fromTip = (q - float2(MID, R)) * toPoints;
    float liquid = smoothstep(0.4, 1.0, bloom);
    float2 tip = float2(u.dropX, u.dropY) * liquid;
    bool underTip = abs(fromTip.x - tip.x) < 26;
    if (quad_all(-inside > SWELL + (underTip ? SPILL : SPREAD))) return float4(0);
    float2 outward = slope / perPixel, ahead = float2(outward.y, -outward.x);
    float depth = -edge;

    Sky s;
    s.ppu = rsqrt(u.mapX * u.mapY);
    s.scale = u.scale;
    s.toPoints = toPoints;
    s.bloom = bloom;
    s.time = time;
    s.pole = u.pole;
    s.reach = R;
    s.middle = MID;
    s.extent = u.extent;
    s.planisphere = float2(u.planisphereX, u.planisphereY);
    s.flowerTop = u.flowerTop;
    s.stretch = u.stretch;
    s.front = u.front;
    // How far the bloom's come here.
    float open = flowerOpen(q, bloom, time, s);
    float perPoint = s.ppu / u.scale;   // points a design point, roughly, either way

    // The outline flows (as the CPU's worked out, round the rim), and the plate dissolves into the
    // desktop in from it, over a band that's uneven and moving and mottled as it goes, like the
    // sky running out; along the top, under the menu bar, it holds on, dark. (Narrower while it's
    // still small, opening, and only flowing once it's mostly open.) How far in from the flowing
    // outline this is (points), and how much of the plate is here, 0 to 1.
    float held = smoothstep(36.0, 110.0, point.y);
    float decor = smoothstep(0.55, 1.0, bloom) * held;
    float aroundRim = 0, flowed = 0, pinch = 0, plate = 1;
    if (inside < 68 + PINCH) {
        aroundRim = q.x - MID;
        float4 here = rimAt(aroundRim, u.span, rim);
        // (Coming to rest, the foot swells a touch past where it rests, and settles.)
        flowed = here.x * liquid + 5 * sin(PI * saturate((bloom - 0.72) / 0.28));
        pinch = here.w;
        float opened = 0.2 + 0.8 * smoothstep(0.1, 0.8, bloom);
        float start = here.y * held * opened;
        float width = mix(12.0, here.z, smoothstep(30.0, 160.0, point.y)) * opened;
        plate = smoothstep(start, start + width, inside + flowed);
        if (plate > 0 && plate < 1) {
            float mottle = noise(point / 21 + 3 * float2(cos(u.mottle), sin(u.mottle)));
            plate = saturate(plate + (mottle - 0.5) * 1.6 * plate * (1 - plate));
        }
    }
    plate *= open;
    float flowing = inside + flowed;
    if (quad_all(-flowing > (underTip ? SPILL : SPREAD))) return float4(0);
    s.plate = plate;

    // What drifts out of it: motes and loose stars, the filaments, the drop of light, the orrery's
    // outermost planet. Light, and the ink to lay under it out over the desktop.
    float3 spill = 0;
    float veil = 0;
    if (decor > 0 && flowing > -SPREAD && flowing < 34) {
        float2 p = float2(aroundRim * perPoint, -flowing);
        float spilt = 0;
        spill = rimLights(p, ahead, outward, s, spilt);
        // The filament rooted nearest (they're far apart).
        int i = aroundRim < -325 ? 0 : (aroundRim < 85 ? 2 : 1);
        float2 from = float2((aroundRim - FILAMENTS[i].x) * perPoint, FILAMENT_ROOT - flowing);
        float size = FILAMENTS[i].y;
        float grow = ease((bloom - 0.6 - 0.1 * i) / 0.32);
        if (grow >= 0.05 && abs(from.x) < size * 0.75 && from.y > -2 && from.y < size * 1.2) {
            float sway = 0.14 * sin(time * (0.37 + 0.05 * i) + i * 2.1);
            float twinkle = 0.5 + 0.5 * sin(time * (1.1 + 0.3 * i) + i * 4.0);
            spill += filament(from, size, FILAMENTS[i].z, grow, sway, twinkle, u.scale, spilt);
        }
        spill *= decor;
        veil = spilt * decor;
    }
    // The drop: a bead of glass that gathers in the dissolving plate at the dome's point, slides
    // out of it and falls, and bursts.
    if (underTip && decor > 0 && (u.dropRadius > 0 || u.dropBurst > 0) && fromTip.y - tip.y > -32 && fromTip.y - tip.y < SPILL) {
        float2 dropAt = tip + float2(0, u.dropBelow);
        float2 v = fromTip - dropAt;
        float r = length(v), radius = u.dropRadius * decor;
        if (radius > 0.05) {
            float body = saturate((radius - r) * u.scale + 0.5);
            float ring = exp(-sq((r - radius + 0.45) / 0.45));
            spill += WHITE * ring * 0.5 * decor;
            veil = max(veil, body * 0.6 + exp(-max(r - radius, 0.0) / 2) * 0.2 * saturate(radius));
        }
        spill += WHITE * (spot(r, 0.8, u.scale) + exp(-r / 1.5) * 0.35 + glint(v, 4.0) * 0.5) * u.dropLight * decor;
        // Bursting, a ring of seven sparkles flying out, settling a little, fading: the one this
        // pixel's nearest round the ring.
        if (u.dropBurst > 0) {
            float burst = u.dropBurst;
            float2 settled = v - float2(0, 5 * burst * burst);
            float k = fmod(round((atan2(settled.y, settled.x) - 0.5) / (TAU / 7)) + 7, 7.0);
            float angle = (k + 0.3 * hash12(float2(k, 3.7))) * TAU / 7 + 0.5;
            float2 d = settled - (3 + 10 * ease(burst) * (0.6 + 0.4 * hash12(float2(k, 8.1)))) * float2(cos(angle), sin(angle));
            if (dot(d, d) < 30) {
                float shine = sq(1 - burst) * (0.65 + 0.35 * sin(burst * 30 + k * 2.0)) * decor;
                spill += WHITE * (glint(d, 2.6) * 0.7 + spot(length(d), 0.6, u.scale)) * shine;
                veil = max(veil, exp(-length(d) / 2) * 0.3 * shine);
            }
        }
    }
    float clockwork = saturate((bloom - 0.3) / 0.6);
    float2 ORRERY = float2(u.orreryX, u.orreryY);
    float2 fromOrrery = q - ORRERY;
    if (clockwork > 0 && fromOrrery.x > -30 && fromOrrery.x < 130 && fromOrrery.y > -54 && fromOrrery.y < 32) {
        float spilt = 0;
        spill += wanderer(fromOrrery, clockwork, u, s, spilt) * held;
        veil = max(veil, spilt * held);
    }
    // Out past the edge, it fades before the drawable's own edge can cut it.
    float room = min(min(pixel.x, u.width - pixel.x), u.height - pixel.y) / u.scale;
    // (And only as far as the bloom's come.)
    float4 over = float4(spill, max(veil, max(spill.r, max(spill.g, spill.b)))) * smoothstep(0.0, 10.0, room) * open;
    if (quad_all(plate <= 0.002)) return over;

    // Now and then, a glitch: a few slices of the plate jump sideways, gone grey and split.
    float2 tq = q;
    float sliced = 0;
    if (u.glitch > 0) {
        for (int i = 0; i < 4; i++) {
            float2 h = hash22(float2(u.glitch, i * 7.1));
            if (i >= 2 && h.x < 0.5) continue;
            float top = h.y * R * 0.9, tall = 4 + 14 * hash12(float2(u.glitch + i, 3.3));
            if (q.y > top && q.y < top + tall) {
                tq.x += (hash12(float2(i, u.glitch)) - 0.5) * 12;
                sliced = 1;
            }
        }
    }

    s.q = tq;
    float2 moonAt = float2(u.moonX, u.moonY), PLANISPHERE = s.planisphere;
    float rPlanisphere = length(tq - PLANISPHERE), rMoon = length(tq - moonAt);
    float column = max(max(u.quietLeft + 16 - tq.x, tq.x - u.quietRight + 16), tq.y - u.quietFoot - 14);
    s.quiet = (1 - smoothstep(-16.0, 14.0, column)) * smoothstep(60.0, 70.0, rMoon);
    s.wing = smoothstep(0.5 * (u.quietRight - u.quietLeft) - 40, 0.5 * (u.quietRight - u.quietLeft) + 20, abs(tq.x - MID));
    float2 milkyFrom = float2(-40, R * 0.95), milkyTo = float2(2 * MID + 40, 30);
    float2 across = normalize(float2(milkyFrom.y - milkyTo.y, milkyTo.x - milkyFrom.x));
    s.milky = exp(-sq(dot(tq - milkyFrom, across) / 60) * 0.5);
    s.grownFrom = u.grownFrom;
    s.growth = saturate(u.growth);
    s.target = u.grownFrom + (R - u.grownFrom) / max(s.growth, 0.02);
    bool growing = R > u.grownFrom + 0.5 && s.growth < 0.999;
    // Growing, the old foot and the new.
    float fromFoot = growing ? footAt(q.x, u.grownFrom, MID).x : 0.0, foot = growing ? footAt(q.x, R, MID).x : 0.0;
    s.inRoom = growing && tq.y > fromFoot;
    s.room = s.inRoom && rMoon > 66 && depth > 16 ? exp(-sq((foot - tq.y) / 28)) * (1 - s.growth) : 0.0;

    // The engraving.
    Trace t = { 1e3, 1e3, 1e3, 1e3, 1e3, 1e3, 0 };
    float3 light = 0;
    // The charts and the moon's dial stand over the sky: no grid or field stars under them.
    if (rPlanisphere > 146.5 && rMoon > 58.5) polarGrid(tq - float2(MID, u.pole), s, t);
    float chart = ease((bloom - 0.25) / 0.5);
    float dial = ease(saturate((bloom - 0.45) / 0.55) * 1.6);
    if (rPlanisphere < 149 && chart > 0) {
        float turn = u.disc - (1 - ease((bloom - 0.25) / 0.65)) * 50 * PI / 180;
        planisphere(tq - PLANISPHERE, s, chart, turn, smoothstep(0.3, 0.7, bloom), t, light);
    }
    float rOrrery = length(tq - ORRERY);
    if (rOrrery < 100 && clockwork > 0) orrery(tq - ORRERY, s, clockwork, u, t, light);
    if (rMoon < 66 && dial > 0) moon(tq - moonAt, s, u, t, light);
    // A pen of light at the head of each ring as it trims on.
    if (bloom < 0.999) {
        float3 drawing = float3(chart, clockwork, dial), heads = drawing * TAU;
        // (The orrery's is on its armillary ring, tilted and grown as the orrery is.)
        float2 armillary = 92 * mix(0.6, 1.0, clockwork) * float2(sin(heads.y), -cos(heads.y));
        float2 pens[3] = { PLANISPHERE + 146 * float2(sin(heads.x), -cos(heads.x)),
                           ORRERY + float2(0.978 * armillary.x + 0.208 * armillary.y, -0.208 * armillary.x + 0.978 * armillary.y),
                           moonAt + 58 * float2(sin(heads.z), -cos(heads.z)) };
        for (int i = 0; i < 3; i++) {
            if (drawing[i] <= 0 || drawing[i] >= 1) continue;
            float2 v = (tq - pens[i]) * s.toPoints;
            if (dot(v, v) < 90) light += WHITE * (glint(v, 7) + spot(length(v), 1.0, u.scale)) * 0.9 * sin(PI * drawing[i]);
        }
    }
    float2 albireo = float2(u.cygnusX, u.cygnusY);
    float2 fromAlbireo = tq - albireo;
    if (fromAlbireo.x > -60 && fromAlbireo.x < 40 && fromAlbireo.y > -86 && fromAlbireo.y < 12) {
        float drawn = saturate((bloom - 0.6) / 0.4);
        cygnus(tq, albireo, s, drawn, t, light);
    }
    if (rPlanisphere > 147 && rMoon > 59) {
        light += faintStars(s);
        light += brightStars(s, moonAt);
    }

    // The pole star, flaring at the notch's foot as the bloom opens (where the notch is on screen,
    // while the plate's still squeezed up into it); the star at the dome's tip.
    float2 toPole = (tq - float2(MID, u.pole * u.plate * u.scale * u.mapY)) * s.toPoints;
    float pole = exp(-sq((bloom - 0.1) / 0.05));
    if (pole > 0.01) light += WHITE * (glint(toPole, 14) + exp(-length(toPole) / 2.5)) * pole * 1.2;
    float2 toTip = (tq - float2(MID, R - 8)) * s.toPoints;
    if (dot(toTip, toTip) < 200) light += WHITE * (glint(toTip, 7) * (0.8 + 0.2 * sin(time * 0.7)) + spot(length(toTip), 1.2, u.scale)) * smoothstep(0.4, 0.8, bloom);
    // The hour of the night: a lozenge on the graduated circle, midnight on the meridian.
    float hourAngle = fmod(u.hour + 12, 24.0) / 24 * PI - PI * 0.5;
    float2 lozenge = rotate(tq - float2(MID, u.pole) - 440 * float2(sin(hourAngle), cos(hourAngle)), -hourAngle);
    if (abs(lozenge.x) + abs(lozenge.y) < 8) {
        float diamond = abs(lozenge.x) / 2.2 + abs(lozenge.y) / 4.2 - 1;
        light += WHITE * saturate(-diamond * 2.2 * s.ppu + 0.5) * 0.7 * smoothstep(0.7, 1.0, bloom) * (1 - 0.7 * s.quiet);
    }
    // A shooting star: a white head with a glint, and a tail fading over its last 45%.
    if (u.streakAlong >= 0) {
        float2 from = float2(u.streakX, u.streakY), heading = float2(u.streakDX, u.streakDY);
        float2 head = from + heading * u.streakLength * u.streakAlong;
        float2 tail = from + heading * u.streakLength * max(u.streakAlong - 0.45, 0.0);
        if (length(tq - (head + tail) * 0.5) < u.streakLength * 0.3 + 12) {
            float shown = smoothstep(0.0, 0.12, u.streakAlong) * (1 - smoothstep(0.7, 1.0, u.streakAlong));
            float fade = saturate(1 - dot(head - tq, heading) / (u.streakLength * 0.45));
            float2 shift = normalize(tq - float2(MID, R * 0.6)) * 0.4 / s.ppu;
            float3 streak = float3(line(segment(tq + shift, tail, head) * s.ppu, 0.75 * u.scale),
                                   line(segment(tq, tail, head) * s.ppu, 0.75 * u.scale),
                                   line(segment(tq - shift, tail, head) * s.ppu, 0.75 * u.scale));
            streak = streak.g * WHITE + (streak.r - streak.g) * FRINGE_RED * 0.3 + (streak.b - streak.g) * FRINGE_BLUE * 0.3;
            light += (streak * fade * 0.9 + WHITE * glint((tq - head) * s.toPoints, 5)) * shown;
        }
    }
    // The comet: a soft head and a 40-point tail turned from the sun.
    if (u.comet > 0) {
        float2 v = (tq - float2(u.cometX, u.cometY)) * s.toPoints;
        if (dot(v, v) < 2400) {
            float2 away = float2(u.cometDX, u.cometDY);
            float along = dot(v, away), aside = abs(away.x * v.y - away.y * v.x);
            float tail = exp(-sq(aside / (0.6 + max(along, 0.0) * 0.16))) * saturate(1 - along / 40) * smoothstep(-2.0, 3.0, along) * 0.42;
            float ion = exp(-sq(aside / 0.35)) * saturate(1 - along / 46) * step(0.0, along) * 0.25;
            float head = spot(length(v), 1.5, u.scale) + exp(-length(v) / 3) * 0.45;
            light += (mix(MOONLIGHT, WHITE, 0.5) * (tail + ion) + WHITE * head) * u.comet;
        }
    }
    // A glint at a crossing of the grid's lines.
    if (u.spark > 0) {
        float2 v = (tq - float2(u.sparkX, u.sparkY)) * s.toPoints;
        if (dot(v, v) < 120) light += WHITE * (glint(v, 5.5) + spot(length(v), 1.0, u.scale)) * u.spark * 0.9;
    }

    // The lines, with their fringes: thin, pale, wider at the peak of the opening or a glitch.
    float swell = saturate(4 * bloom * (1 - bloom));
    float2 dir = normalize(tq - float2(MID, R * 0.6) + float2(0.01, 0));
    float fringe = 0.35 + 0.35 * swell + 0.35 * sliced;
    float limit = 1.5 * max(u.mapX, u.mapY);
    float ppu = s.ppu, scale = u.scale;
    float3 lines = engrave(t.bold, 0.8, 0.62, ppu, scale, dir, fringe, limit)
        + engrave(t.major, 0.7, 0.55, ppu, scale, dir, fringe, limit)
        + engrave(t.minor, 0.6, 0.34, ppu, scale, dir, fringe, limit)
        + engrave(t.fine, 0.5, 0.2, ppu, scale, dir, fringe, limit)
        // (The faintest two go without: their fringes would be too faint to see.)
        + SILVER * (line(t.grid * ppu, 0.5 * scale) * 0.15 + line(t.hair * ppu, 0.45 * scale) * 0.10);
    float weight = (1 - 0.68 * s.quiet) * (1 + 1.6 * s.room);
    // One near halo of moonlight round the stronger lines, swelling a little while it opens.
    float points = ppu / scale;
    float glow = (exp(-t.bold * points / 2.5) * 0.10 + exp(-t.major * points / 2.5) * 0.10 + exp(-t.minor * points / 2.5) * 0.035)
        * (1 + 0.6 * swell);
    lines = lines * weight + MOONLIGHT * glow * weight + SILVER * t.fill + MOONLIGHT * s.room * 0.05;

    // The Milky Way: a faint mottled band, lower left to upper right.
    if (s.milky > 0.03) {
        float mottle = noise(tq / 38) * 0.65 + noise(tq / 13 + 7.0) * 0.35;
        light += (SILVER * 0.04 * mottle + NEBULA * 0.02 * (1 - mottle)) * s.milky * 3 * smoothstep(0.3, 0.8, bloom) * (1 - 0.5 * s.quiet)
            * sqrt(plate);
    }
    // Star dust drifting up and to the right, small motes and a few big soft ones.
    float3 motes = 0;
    // (The big ones would be too faint to see in the quiet column.)
    for (int layer = 0; layer < (s.quiet > 0.9 ? 1 : 2); layer++) {
        float size = layer == 0 ? 52.0 : 118.0;
        float2 drift = point + (layer == 0 ? float2(-4.0, 5.0) : float2(-2.2, 2.6)) * time + float2(sin(time * 0.07 + layer * 2.1) * 9, 0);
        float2 id = floor(drift / size);
        if (hash12(id + 7.0 + layer * 13.0) > 0.5) continue;
        float2 h = hash22(id + layer * 31.0);
        float2 center = (0.25 + 0.5 * h) * size + float2(sin(time * 0.3 + h.y * TAU), cos(time * 0.23 + h.x * TAU)) * size * 0.06;
        float2 d = drift - id * size - center;
        float radius = layer == 0 ? mix(0.6, 2.2, h.x) : mix(5.0, 11.0, h.y);
        float strength = (layer == 0 ? 0.22 : 0.05) * (0.5 + 0.5 * sin(time * 0.4 + h.x * 20));
        motes += SILVER * exp(-dot(d, d) / (2 * radius * radius)) * strength;
    }
    motes *= (1 - 0.55 * s.quiet) * smoothstep(0.2, 0.7, bloom);
    // The moon's light under it, screened into halftone dots.
    float3 under = 0;
    if (rMoon < 150) {
        float tone = exp(-sq(rMoon / 68)) * 0.8 * step(36.0, rMoon) * smoothstep(0.5, 1.0, bloom);
        float2 screen = rotate(point, PI / 4) / 3.4;
        float dots = length(fract(screen) - 0.5) * 3.4;
        under = SILVER * smoothstep(0.45, -0.45, (dots - sqrt(tone) * 1.7) * u.scale) * tone * 0.05;
    }

    // The holographic sheen: a band of pearly film sweeping across now and then, finely ruled.
    float along = dot(point, float2(0.87, 0.5)) / 410;
    float sheen = exp(-sq((along - (fract(time / 14) * 3.6 - 1.2)) / 0.17));
    // Where the plate dissolves, its lines and ground go with it; its lights (the stars, the
    // charts' lights) linger a little longer, out over the desktop.
    float3 foil = SILVER, shine = lines * plate + light * sqrt(plate);
    float ruling = 0;
    if (sheen > 0.002) {
        ruling = 0.6 + 0.4 * sin(dot(point, float2(-0.5, 0.87)) * 2.4 + along * 40);
        foil = film(along * 1.4 + time * 0.02 + ruling * 0.08);
        shine *= mix(float3(1), foil * 1.25, sheen * 0.15);
    }

    // The glass: dark, darkest under the menu bar so the notch disappears into it, clearer toward
    // the edge so the desktop shows faintly through, a breath of moonlight low down.
    float top = 1 - smoothstep(0, 46, point.y);
    float alpha = min(mix(0.6, 0.82, smoothstep(6, 150, depth)) + 0.3 * top, 0.97);
    // Where the glass's blur doesn't reach (out where the outline swells and pinches), a little
    // more ink, so the plate doesn't show lighter there.
    alpha += (1 - alpha) * 0.35 * (1 - smoothstep(GLASS_INSET, GLASS_INSET + GLASS_FEATHER, inside - pinch - 5.3));
    alpha *= plate;
    float3 tint = INK + MOONLIGHT * 0.015 * smoothstep(R * 0.45, R, tq.y) + foil * sheen * ruling * 0.04;
    float3 color = tint * alpha + shine + (motes + under) * plate;
    if (sliced > 0) color = mix(color, float3(dot(color, float3(0.3, 0.55, 0.15))), 0.8);
    // Film grain, a new one every 1/24 s.
    float grain = hash12(pixel + floor(time * 24) * 37.0) - 0.5;
    color = max(color * (1 + grain * 0.10) + grain * 0.010 * plate, 0.0);
    float a = max(alpha, max(color.r, max(color.g, color.b)));
    // What's drifting out of it, over it.
    return over + float4(color, saturate(a)) * (1 - over.a);
}
"""
