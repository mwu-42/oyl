import AppKit
import os
import SwiftUI

/// A moyl: Midnight Oyl's Oyl. Where Gargoyle has a little imp for each thing going on, Midnight
/// has a little planet, as real as one can be that small (see `Planet`): a sphere lit from one
/// side, its surface turning under the light, a thin rim of air on the lit limb. An agent's is a
/// gas giant, banded, with a storm; the song's a ringed one; a timer's an ice giant; staying
/// awake's an ocean world, clouded; the battery's and bedtime's rocky, cratered. It's colored as its Oyl is (an agent's pastel, a timer's white deepening to blue, staying awake's
/// sea green, bedtime's pajama lavender), paled a little toward Midnight's white, and shows what
/// it's up to the way a planet would: an agent's turns quicker while it works, and wears Claude's
/// orange as a polar cap; the song's has rings, swelling on the beat, that glint as they go round
/// while it sings; a timer's has a moon going once round while its time runs, the orbit still ahead of it
/// what's left; staying awake's spins fast and can't keep still; the battery's is mostly in shadow
/// while it's low, coming into the light as it charges; the bedtime one is all but new. One that
/// needs you glows, pulsing; one whose work is done flares like a nova.
///
/// This view draws it in the middle of its frame, as big as the frame's height allows. In the
/// band's sky, `MoylSprite` shows them as layers (see `MoylsView`).
struct Moyl: View {
    let kind: Kind
    @Environment(\.displayScale) private var scale

    init(_ kind: Kind) {
        self.kind = kind
    }

    init(_ job: Walker.Job) {
        kind = job.moyl
    }

    var body: some View {
        // Slower than an Oyl: it only turns and glows.
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let beat = CGFloat(max(Beat.level - 0.3, 0) / 0.7), beats = Beat.position(at: time)
            Canvas { canvas, size in
                MoylDrawing(canvas: canvas, time: time, beat: beat, beats: beats, scale: scale)
                    .draw(kind, at: CGPoint(x: size.width / 2, y: size.height / 2), radius: Self.radius(in: size),
                          date: context.date)
            }
        }
    }

    /// How big its planet is in a frame of `size`, with room round it for its rings and moon.
    static func radius(in size: CGSize) -> CGFloat {
        min(size.height * 0.3, size.width * 0.17)
    }
}

extension Moyl {
    /// Whose moyl it is, as far as its looks go.
    enum Kind: Equatable {
        /// An Oyl as it is: on its own, white; or running an agent, in its pastel with Claude's
        /// cap, at whatever the agent's doing.
        case oyl(AgentActivity, skin: Color, hat: Color?)
        /// At one of Oyl's own jobs.
        case duty(OylDuty)
    }
}

extension Walker.Job {
    /// What its moyl looks like.
    var moyl: Moyl.Kind {
        switch self {
        case .hangout: return .oyl(.idle, skin: Oyl.white, hat: nil)
        case .agent(let session): return .oyl(session.activity, skin: Oyl.pastel(session.skin), hat: session.cap)
        default: return duty.map { .duty($0) } ?? .oyl(.idle, skin: Oyl.white, hat: nil)
        }
    }
}

/// Draws moyls into a canvas, each a planet of `radius` at `center`, its rings and moon reaching
/// about twice that either side.
struct MoylDrawing {
    let canvas: GraphicsContext
    let time: TimeInterval
    /// The bass, 0...1, and where the beat is, while there's a steady one (see `Beat`).
    var beat: CGFloat = 0
    var beats: Double?
    /// 0...1, its own: so several on the bar together turn, lean and glow out of step.
    var seed: Double = 0
    /// Pixels to a point, for its planet's picture.
    var scale: CGFloat = 2

    /// Its planet, and all about it. `flare` (0...1) is how bright it's flaring, its work done;
    /// `poke`, how far (0...1) through the twinkle it gives when it's clicked.
    func draw(_ kind: Moyl.Kind, at center: CGPoint, radius: CGFloat, date: Date, flare: Double = 0, poke: Double? = nil) {
        let time = self.time + seed * 97
        var look = MoylLook(kind, date: date, time: time, bop: bop)
        let flare = CGFloat(min(max(flare, 0), 1))
        if flare > 0 {
            look.lit += (1 - look.lit) * flare
            look.glow = max(look.glow, 0.18 + 0.42 * Double(flare))
            look.glowTone = Tone.starlight
        }
        if let poke, poke < 1 { look.glow = max(look.glow, 0.32 * (1 - poke)) }
        var center = center
        if look.jitter > 0 {
            center.x += look.jitter * CGFloat(0.6 * sin(time * 53) + 0.4 * sin(time * 31))
            center.y += look.jitter * CGFloat(0.5 * sin(time * 47 + 1))
        }
        let r = radius * (1 + look.swell)
        let globe = Globe(center: center, radius: r, seed: seed,
                          turn: look.spin.isFinite ? CGFloat((time / look.spin).truncatingRemainder(dividingBy: 1) * 2 * .pi) : 0)

        halo(look, globe, flare: flare)
        if flare > 0 { rays(globe, flare: flare, time: time) }
        if look.rings > 0 { rings(look, globe, near: false) }
        if let moon = look.moon { orbit(moon, globe, near: false, time: time) }
        sphere(look, globe)
        if look.candle { candle(globe, look: look, time: time) }
        if look.rings > 0 { rings(look, globe, near: true) }
        if let moon = look.moon { orbit(moon, globe, near: true, time: time) }
        if look.sparkles { sparkles(globe, time: time) }
        if let poke, poke < 1 {
            var star = canvas
            star.opacity = 1 - poke
            Self.star(in: star, at: CGPoint(x: center.x + r * 1.25, y: center.y - r * (0.9 + 0.7 * CGFloat(poke))),
                      size: r * 0.55 * CGFloat(1 - poke * 0.5), tone: .starlight)
        }
    }

    private var bop: CGFloat { Self.bop(beat: beat, beats: beats) }

    /// The bob to the beat, as the song's moyl swells with it: 0 between beats, 1 on one. To the
    /// music's beat while it has a steady one, else the bass as it comes.
    static func bop(beat: CGFloat, beats: Double?) -> CGFloat {
        guard let beats else { return beat }
        let through = beats - beats.rounded(.down)
        return CGFloat(pow(0.5 + 0.5 * cos(2 * .pi * through), 2))
    }

    // MARK: The planet

    /// The light comes from the upper left, as an atlas plate's does.
    fileprivate static let light = CGFloat(atan2(-0.62, -0.78))

    /// The planet itself, as `Planet` pictures it.
    fileprivate func sphere(_ look: MoylLook, _ globe: Globe) {
        guard let image = Self.planet(look, globe, seed: seed, scale: scale) else { return }
        let half = globe.radius + Planet.margin(globe.radius)
        canvas.draw(Image(decorative: image, scale: scale),
                    in: CGRect(x: globe.center.x - half, y: globe.center.y - half, width: 2 * half, height: 2 * half))
    }

    /// Its planet's picture, `scale` pixels to a point, its middle the picture's.
    fileprivate static func planet(_ look: MoylLook, _ globe: Globe, seed: Double, scale: CGFloat) -> CGImage? {
        Planet.picture(look.surface, tone: look.tone, cap: look.cap, seed: seed, radius: globe.radius, scale: scale,
                       view: Planet.View(tilt: globe.tilt, inclination: globe.inclination, turn: globe.turn,
                                         light: look.light ?? light, lit: look.lit))
    }

    /// A faint glow round it, in its color (or another's): Midnight's is moonlight, never a blaze.
    fileprivate func halo(_ look: MoylLook, _ globe: Globe, flare: CGFloat) {
        guard look.glow > 0.01 else { return }
        halo(look.glowTone ?? look.tone, globe, strength: look.glow, reach: 2 + 1.6 * flare)
    }

    /// A glow in `tone`, `strength` at its brightest, out to `reach` radii.
    fileprivate func halo(_ tone: Tone, _ globe: Globe, strength: Double, reach: CGFloat = 2) {
        let reach = globe.radius * reach
        canvas.fill(Self.circle(globe.center, reach), with: .radialGradient(
            Gradient(stops: [.init(color: tone.color(strength), location: 0), .init(color: tone.color(strength * 0.3), location: 0.45),
                             .init(color: tone.color(0), location: 1)]),
            center: globe.center, startRadius: globe.radius * 0.8, endRadius: reach))
    }

    /// A nova: thin rays out from it, long and short by turns, slowly turning.
    fileprivate func rays(_ globe: Globe, flare: CGFloat, time: TimeInterval) {
        let c = globe.center, r = globe.radius
        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4 + .pi / 8 + CGFloat(time * 0.25)
            let length = r * (index % 2 == 0 ? 1.3 + 2.4 * flare : 0.7 + 1.1 * flare)
            let out = CGPoint(x: cos(angle), y: sin(angle)), side = CGPoint(x: -out.y, y: out.x)
            let base = r * 0.85, half = r * 0.085
            var ray = Path()
            ray.move(to: CGPoint(x: c.x + out.x * base + side.x * half, y: c.y + out.y * base + side.y * half))
            ray.addLine(to: CGPoint(x: c.x + out.x * (r + length), y: c.y + out.y * (r + length)))
            ray.addLine(to: CGPoint(x: c.x + out.x * base - side.x * half, y: c.y + out.y * base - side.y * half))
            ray.closeSubpath()
            canvas.fill(ray, with: .linearGradient(Gradient(colors: [Tone.starlight.color(0.85 * Double(flare)), Tone.starlight.color(0)]),
                                                   startPoint: CGPoint(x: c.x + out.x * base, y: c.y + out.y * base),
                                                   endPoint: CGPoint(x: c.x + out.x * (r + length), y: c.y + out.y * (r + length))))
        }
    }

    /// Its rings round its equator, the far half behind it and the near half in front: bands of
    /// ice and dust in its color whitened, the broadest brightest, a dark gap before the outer
    /// two, brightening with the beat; while it sings, a glint going round them, as a record's sheen.
    fileprivate func rings(_ look: MoylLook, _ globe: Globe, near: Bool) {
        let ringing = 2 * .pi * CGFloat((time / 2.4).truncatingRemainder(dividingBy: 1))
        let ice = look.tone.mix(.starlight, 0.6)
        for (scale, opacity) in Self.ringBands {
            var ring = Path()
            globe.trace(into: &ring, steps: 48, turning: false, near: near, scale: scale) { step in
                (latitude: 0, longitude: 2 * .pi * CGFloat(step) / 48)
            }
            let lineWidth = max(0.35, globe.radius * 0.05)
            canvas.stroke(ring, with: .color(ice.color(min(opacity * look.rings, 0.9))), lineWidth: lineWidth)
            guard look.singing, scale == 1.56 || scale == 1.88 else { continue }
            for half in [0, CGFloat.pi] {
                var glint = Path()
                globe.trace(into: &glint, steps: 6, turning: false, near: near, scale: scale) { step in
                    (latitude: 0, longitude: half - ringing * (scale > 1.7 ? 1 : 1.4) + Self.glint * CGFloat(step) / 6)
                }
                canvas.stroke(glint, with: .color(Tone.starlight.color(0.6)), style: StrokeStyle(lineWidth: lineWidth * 0.6, lineCap: .round))
            }
        }
    }

    /// The rings, fine bands close enough to run together: how far out each is (in radii), and how
    /// thick with ice. Faint within, broad and bright, a dark gap, then fainter again.
    private static let ringBands: [(CGFloat, Double)] = [
        (1.28, 0.08), (1.32, 0.1), (1.36, 0.12), (1.4, 0.14), (1.44, 0.26), (1.48, 0.36), (1.52, 0.42), (1.56, 0.46), (1.6, 0.44),
        (1.64, 0.42), (1.68, 0.38), (1.72, 0.32), (1.76, 0.04), (1.8, 0.03), (1.84, 0.26), (1.88, 0.28), (1.92, 0.24), (1.96, 0.1),
        (2, 0.16),
    ]

    /// How long a glint on the singing moyl's rings is, round them.
    fileprivate static let glint: CGFloat = 0.5
    /// How far out a moon's orbit is, in radii.
    fileprivate static let moonOrbit: CGFloat = 2.05

    /// A moon on its orbit, and as much of the orbit as there is to draw: for a timer, the stretch
    /// it's yet to go round, dotted.
    private func orbit(_ moon: MoylLook.Moon, _ globe: Globe, near: Bool, time: TimeInterval) {
        orbitPath(moon, globe, near: near, time: time)
        let (spot, isNear) = globe.point(latitude: 0, longitude: moon.angle(at: time), turning: false, scale: Self.moonOrbit)
        guard isNear == near else { return }
        self.moon(moon, at: spot, globe)
    }

    /// The moon's orbit, dotted: the near or the far half, as far as it's drawn.
    fileprivate func orbitPath(_ moon: MoylLook.Moon, _ globe: Globe, near: Bool, time: TimeInterval) {
        let at = moon.angle(at: time), ahead: CGFloat, orbit: Double
        switch moon {
        case .timer(_, let running):
            // Ahead of it, the rest of the way back up to the top.
            ahead = at + .pi
            orbit = running ? 0.55 : 0.32
        case .circling(_, _, let shown):
            ahead = 2 * .pi
            orbit = shown
        }
        guard orbit > 0 else { return }
        var path = Path()
        let steps = max(Int(ahead / (2 * .pi) * 48), 2)
        globe.trace(into: &path, steps: steps, turning: false, near: near, scale: Self.moonOrbit) { step in
            (latitude: 0, longitude: at - ahead * CGFloat(step) / CGFloat(steps))
        }
        canvas.stroke(path, with: .color(Tone.silver.color(orbit)),
                      style: StrokeStyle(lineWidth: max(0.45, globe.radius * 0.06), lineCap: .round,
                                         dash: [0.01, max(1.6, globe.radius * 0.22)]))
    }

    /// The moon itself, at `spot`: a little rocky world, lit as its planet is.
    fileprivate func moon(_ moon: MoylLook.Moon, at spot: CGPoint, _ globe: Globe) {
        let size = Self.moonSize(globe.radius)
        guard let image = Planet.picture(.rocky, tone: moon.tone, cap: nil, seed: 0.61, radius: size, scale: scale,
                                         view: Planet.View(tilt: 0, inclination: 0.2, turn: 0, light: Self.light, lit: 0.74)) else { return }
        let half = size + Planet.margin(size)
        canvas.draw(Image(decorative: image, scale: scale), in: CGRect(x: spot.x - half, y: spot.y - half, width: 2 * half, height: 2 * half))
    }

    fileprivate static func moonSize(_ radius: CGFloat) -> CGFloat { max(radius * 0.24, 1.6) }

    /// A glint on the singing moyl's rings, for `MoylSprite`'s: a soft bright point.
    fileprivate func glintDot(side: CGFloat) {
        let middle = CGPoint(x: side / 2, y: side / 2)
        canvas.fill(Self.circle(middle, side / 2), with: .radialGradient(Gradient(colors: [Tone.starlight.color(0.95), Tone.starlight.color(0)]),
                                                                        center: middle, startRadius: 0, endRadius: side / 2))
    }

    /// Where the selfie's stars twinkle round it, in radii from its middle, and how bright each
    /// is at `time` (0...1).
    fileprivate static let sparkleSpots = [CGPoint(x: 1.7, y: -1.05), CGPoint(x: -1.6, y: -0.7), CGPoint(x: 1.45, y: 1)]
    fileprivate static func twinkle(_ index: Int, at time: TimeInterval) -> CGFloat {
        CGFloat(max(0, sin(time * 3 + Double(index) * 2.1)))
    }

    /// Stars twinkling round it, for the selfie just taken.
    private func sparkles(_ globe: Globe, time: TimeInterval) {
        let c = globe.center, r = globe.radius
        for (index, spot) in Self.sparkleSpots.enumerated() {
            let twinkle = Self.twinkle(index, at: time)
            guard twinkle > 0.05 else { continue }
            Self.star(in: canvas, at: CGPoint(x: c.x + spot.x * r, y: c.y + spot.y * r), size: r * 0.42 * twinkle, tone: .starlight)
        }
    }

    /// A candle lit on its night side: a warm point, flickering.
    private func candle(_ globe: Globe, look: MoylLook, time: TimeInterval) {
        candle(at: Self.candleSpot(globe, look: look), radius: globe.radius, flicker: Self.flicker(at: time))
    }

    fileprivate func candle(at spot: CGPoint, radius r: CGFloat, flicker: CGFloat) {
        canvas.fill(Self.circle(spot, r * 0.55 * flicker), with: .radialGradient(
            Gradient(colors: [Tone.candle.color(0.7), Tone.candle.color(0)]), center: spot, startRadius: 0, endRadius: r * 0.55 * flicker))
        canvas.fill(Self.circle(spot, max(r * 0.08, 0.6)), with: .color(Tone.starlight.color()))
    }

    /// Where the candle is, on the night side not far from the terminator.
    fileprivate static func candleSpot(_ globe: Globe, look: MoylLook) -> CGPoint {
        let light = look.light ?? Self.light, r = globe.radius
        return CGPoint(x: globe.center.x - cos(light) * r * 0.5 + r * 0.12, y: globe.center.y - sin(light) * r * 0.5 - r * 0.1)
    }

    fileprivate static func flicker(at time: TimeInterval) -> CGFloat {
        CGFloat(0.8 + 0.2 * sin(time * 17) * sin(time * 7.3))
    }

    /// A four-pointed star, an engraver's twinkle.
    static func star(in context: GraphicsContext, at spot: CGPoint, size r: CGFloat, tone: Tone = .starlight) {
        var star = Path()
        star.move(to: CGPoint(x: spot.x, y: spot.y - r))
        star.addQuadCurve(to: CGPoint(x: spot.x + r, y: spot.y), control: spot)
        star.addQuadCurve(to: CGPoint(x: spot.x, y: spot.y + r), control: spot)
        star.addQuadCurve(to: CGPoint(x: spot.x - r, y: spot.y), control: spot)
        star.addQuadCurve(to: CGPoint(x: spot.x, y: spot.y - r), control: spot)
        context.fill(star, with: .color(tone.color()))
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    }
}

/// A planet's sphere as it's seen: leaning by `tilt`, its north pole tipped toward us by
/// `inclination`, and turned `turn` round its axis.
fileprivate struct Globe {
    let center: CGPoint
    let radius: CGFloat
    let tilt: CGFloat
    let inclination: CGFloat
    let turn: CGFloat

    /// A moyl's: leaning a little more or less by its `seed`, tipped a little toward us.
    init(center: CGPoint, radius: CGFloat, seed: Double, turn: CGFloat) {
        self.center = center
        self.radius = radius
        tilt = CGFloat(-0.3 + 0.24 * (seed - 0.5))
        inclination = 0.34
        self.turn = turn
    }

    /// Where a point at `latitude` and `longitude` (0 facing us) comes out, `scale` radii from
    /// the middle, and whether it's on our side of the planet. Meridians turn with it; rings and
    /// moons don't.
    func point(latitude: CGFloat, longitude: CGFloat, turning: Bool, scale: CGFloat = 1) -> (CGPoint, Bool) {
        let longitude = longitude + (turning ? turn : 0)
        let x = cos(latitude) * sin(longitude), y = sin(latitude), z = cos(latitude) * cos(longitude)
        let up = y * cos(inclination) - z * sin(inclination)
        let near = z * cos(inclination) + y * sin(inclination)
        let flat = CGPoint(x: x * radius * scale, y: -up * radius * scale)
        return (CGPoint(x: center.x + flat.x * cos(tilt) - flat.y * sin(tilt), y: center.y + flat.x * sin(tilt) + flat.y * cos(tilt)),
                near > 0)
    }

    /// Adds a line through `steps + 1` points (`place` says where each is) to `path`: only where
    /// it's on our side, or with `near` false, only where it's behind (or, with `near` nil, all).
    func trace(into path: inout Path, steps: Int, turning: Bool, near: Bool? = true, scale: CGFloat = 1,
               place: (Int) -> (latitude: CGFloat, longitude: CGFloat)) {
        var drawing = false
        for step in 0...steps {
            let spot = place(step)
            let (point, isNear) = self.point(latitude: spot.latitude, longitude: spot.longitude, turning: turning, scale: scale)
            guard near == nil || isNear == near else {
                drawing = false
                continue
            }
            if drawing { path.addLine(to: point) } else { path.move(to: point) }
            drawing = true
        }
    }

    /// Its north polar cap, down to about latitude 55° (to be clipped to the disc).
    var cap: Path {
        let latitude: CGFloat = 0.96
        var path = Path()
        // The cap's edge across the front, then up and over the pole, beyond the limb.
        trace(into: &path, steps: 20, turning: false, near: nil) { step in
            (latitude: latitude, longitude: -.pi / 2 + .pi * CGFloat(step) / 20)
        }
        let over = { (x: CGFloat, y: CGFloat) -> CGPoint in
            CGPoint(x: center.x + x * cos(tilt) - y * sin(tilt), y: center.y + x * sin(tilt) + y * cos(tilt))
        }
        path.addLine(to: over(radius * 1.2, -radius * 1.3))
        path.addLine(to: over(-radius * 1.2, -radius * 1.3))
        path.closeSubpath()
        return path
    }
}

/// A moyl's looks at a moment: its colors, how it's lit and turning, and what's about it.
fileprivate struct MoylLook {
    enum Moon: Equatable {
        /// A timer's: once round over its time, `gone` of the way.
        case timer(gone: Double, running: Bool)
        /// Round and round, once each `period` seconds, its orbit drawn this faintly.
        case circling(period: TimeInterval, tone: Tone, orbit: Double)

        /// How far round its orbit it is at `time` (0 facing us, π at the back): a timer's round
        /// clockwise from the top, once over the timer's time.
        func angle(at time: TimeInterval) -> CGFloat {
            switch self {
            case .timer(let gone, _): return .pi - 2 * .pi * CGFloat(min(max(gone, 0), 1))
            case .circling(let period, _, _): return -2 * .pi * CGFloat((time / period).truncatingRemainder(dividingBy: 1))
            }
        }

        var tone: Tone {
            if case .circling(_, let tone, _) = self { return tone }
            return .white
        }

        /// Its orbit as it's drawn, not where the moon is on it: a timer's in steps of 5° (each is
        /// drawn anew).
        var drawn: Moon {
            if case .timer(let gone, let running) = self { return .timer(gone: (gone * 72).rounded(.down) / 72, running: running) }
            return self
        }
    }

    /// What its planet's picture comes to, as opposed to what turns, moves or glows.
    struct Plate: Equatable {
        let surface: Planet.Surface
        let tone: Tone
        let cap: Tone?
        let lit: Int
        let light: CGFloat?
    }

    /// In steps (a timer's deepens all the time, and its pictures are drawn again only when
    /// that shows).
    var plate: Plate {
        Plate(surface: surface, tone: tone.stepped, cap: cap, lit: Int((lit * 100).rounded()), light: light)
    }

    /// What the pictures of its rings and its moon's orbit come to.
    struct Rim: Equatable {
        let rings: Bool
        let orbit: Moon?
    }

    var rim: Rim { Rim(rings: rings > 0, orbit: moon?.drawn) }

    var tone: Tone
    /// What kind of world it is.
    var surface = Planet.Surface.banded
    /// Seconds a turn (infinite: still).
    var spin: TimeInterval = 18
    /// How much of the disc the light reaches, 0...1, and from where (nil: the upper left).
    var lit: CGFloat = 0.74
    var light: CGFloat?
    var glow = 0.1
    var glowTone: Tone?
    var cap: Tone?
    /// How bright its rings are (none at 0).
    var rings = 0.0
    var moon: Moon?
    /// How much bigger it is, swelling on the beat.
    var swell: CGFloat = 0
    var jitter: CGFloat = 0
    var sparkles = false
    /// Its rings glinting, as it sings.
    var singing = false
    var candle = false

    init(_ kind: Moyl.Kind, date: Date, time: TimeInterval, bop: CGFloat) {
        /// A pulse for what has to be seen, 0...1, about once a second.
        let pulse = 0.5 + 0.5 * sin(time * 2 * .pi * 0.9)
        switch kind {
        case .oyl(let activity, let skin, let hat):
            tone = .pale(skin)
            if let hat { cap = .pale(hat, keep: 0.8) }
            switch activity {
            case .coding, .running: spin = 2.4
            case .reading, .browsing, .writing: spin = 3.6
            case .thinking: spin = 6
            case .delegating:
                // Its subagent, a moon of its own.
                spin = 3.6
                moon = .circling(period: 5.5, tone: tone, orbit: 0.22)
            case .waiting:
                // Asking for you: glowing, pulsing, in the yellow of Gargoyle's "!".
                spin = 9
                glow = 0.16 + 0.26 * pulse
                glowTone = .pale(Color(red: 1, green: 0.8, blue: 0.26), keep: 0.6)
            case .done:
                spin = 16
                lit = 0.92
                glow = 0.3
            case .idle:
                spin = hat != nil ? 12 : 24
            }
        case .duty(let duty):
            tone = .pale(duty.skin(at: date) ?? Oyl.white)
            switch duty {
            case .music(_, .reading):
                // An audiobook: no beat to swell with, its rings still, a pale moon going slowly
                // round (its orbit undrawn, so close outside the rings) and a glow coming and
                // going as it thinks it over.
                rings = 0.7
                moon = .circling(period: 16, tone: .white, orbit: 0)
                glow = 0.08 + 0.12 * (0.5 - 0.5 * cos(time * 2 * .pi / 11))
                spin = 14
            case .music(_, let listening):
                rings = 0.55 + 0.45 * Double(bop)
                swell = 0.05 * bop
                singing = listening == .singing
                spin = 9
            case .timer(let timer):
                let left = timer.fractionLeft(at: date)
                // Deepening in 5% steps (each is drawn anew).
                tone = .pale(Oyl.timer(((1 - left) * 20).rounded() / 20))
                surface = .icy
                moon = .timer(gone: 1 - left, running: timer.isRunning)
                if !timer.isRunning {
                    spin = .infinity
                    lit = 0.55
                } else if left < 0.1 {
                    // Nearly time.
                    spin = 5
                    glow = 0.14 + 0.24 * pulse
                } else {
                    spin = 10
                }
            case .awake(let mode):
                surface = .ocean
                spin = 1.3
                jitter = 0.45
                glow = 0.14
                switch mode {
                case .until: moon = .circling(period: 5, tone: .white, orbit: 0.2)
                case .whileRunning: moon = .circling(period: 12, tone: .white, orbit: 0.3)
                case .indefinitely: break
                }
            case .battery(.tired(let percent)):
                // Running low: mostly in shadow, turning slowly, faintly red.
                surface = .rocky
                lit = 0.12 + 0.3 * CGFloat(min(max(percent, 0), 100)) / 100
                spin = 40
                glow = 0.06 + 0.08 * pulse
                glowTone = .pale(Color(red: 1, green: 0.36, blue: 0.32), keep: 0.6)
            case .battery(.recharging(let percent)):
                // Coming into the light as it fills.
                surface = .rocky
                let full = CGFloat(min(max(Double(percent) / Double(PowerWatcher.recovered), 0), 1))
                lit = 0.35 + 0.6 * full
                spin = 8
                glow = 0.12
            case .bedtime(let stage):
                tone = .pale(Oyl.pajamas, keep: 0.6)
                surface = .rocky
                switch stage {
                case .candle:
                    lit = 0.42
                    spin = 24
                    candle = true
                case .bed:
                    // Asleep: all but new.
                    lit = 0.08
                    spin = 50
                    glow = 0
                case .remind:
                    lit = 0.5
                    spin = 14
                    glow = 0.18 + 0.28 * pulse
                }
            case .selfie:
                surface = .icy
                sparkles = true
                spin = 12
            case .notes:
                // Taking notes: a banded world, ruled like paper, a little moon going busily round
                // it for the pen, and a glow coming and going as it listens.
                surface = .banded
                moon = .circling(period: 4.5, tone: .white, orbit: 0.2)
                glow = 0.08 + 0.1 * (0.5 - 0.5 * cos(time * 2 * .pi / 3.2))
                spin = 7
            }
        }
    }
}

/// A color as its red, green and blue (sRGB), for mixing shades of it.
struct Tone: Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `color`'s, worked out once (it's asked for every frame, and the asking costs more than
    /// the drawing).
    init(_ color: Color) {
        if let known = Self.known.withLock({ $0[color] }) {
            self = known
            return
        }
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: Double(resolved.redComponent), green: Double(resolved.greenComponent), blue: Double(resolved.blueComponent))
        let tone = self
        Self.known.withLock {
            // A timer's color changes as it goes; those gone by needn't be kept.
            if $0.count > 256 { $0 = [:] }
            $0[color] = tone
        }
    }

    private static let known = OSAllocatedUnfairLock(initialState: [Color: Tone]())

    /// `color` as a moyl's colored: most of its hue kept, the rest Midnight's white.
    static func pale(_ color: Color, keep: Double = 0.62) -> Tone {
        Tone(color).mix(.white, 1 - keep)
    }

    /// To the nearest 1% of each, which no one could tell from it.
    var stepped: Tone {
        Tone(red: (red * 100).rounded() / 100, green: (green * 100).rounded() / 100, blue: (blue * 100).rounded() / 100)
    }

    func mix(_ other: Tone, _ amount: Double) -> Tone {
        Tone(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
             blue: blue + (other.blue - blue) * amount)
    }

    func color(_ opacity: Double = 1) -> Color {
        Color(red: red, green: green, blue: blue).opacity(opacity)
    }

    // Midnight's own (see `Midnight`), and a candle's.
    static let white = Tone(red: 0.95, green: 0.96, blue: 0.98)
    static let ink = Tone(red: 0.014, green: 0.018, blue: 0.04)
    static let silver = Tone(red: 0.84, green: 0.87, blue: 0.93)
    static let starlight = Tone(red: 1, green: 0.95, blue: 0.86)
    static let candle = Tone(red: 1, green: 0.78, blue: 0.5)
}

// MARK: - In the band's sky

/// One moyl in the band's sky, as Core Animation layers rather than a drawing redone each frame:
/// a stack of pictures (its glow, the far halves of its rings and its moon's orbit, its planet,
/// the near halves) drawn once and then only moved, scaled, faded and swapped. Its planet's
/// turning is pictures of a whole turn, drawn as they're first wanted; its moon, the glints on its
/// rings and its stars are little layers of their own, moved about. `MoylsView` keeps one for each.
@MainActor
final class MoylSprite {
    /// The whole moyl, its planet in the middle, in the bar's layer (which counts up from the
    /// bottom).
    let layer = CALayer()
    private let halo = CALayer(), flare = CALayer(), rays = CALayer()
    private let behind = CALayer(), globe = CALayer(), candle = CALayer(), before = CALayer()
    private let moon = Satellite(), glints = [Satellite(), Satellite()]
    private let poke = CALayer(), sparkles = [CALayer(), CALayer(), CALayer()]
    /// The stardust it scatters into, leaving.
    private let dust = (0..<8).map { _ in CALayer() }
    private let seed: Double

    private var radius: CGFloat = 0
    private var plate: MoylLook.Plate?
    private var turns: [Int: CGImage] = [:]
    private var rim: MoylLook.Rim?
    private var glowTone: Tone?
    private var moonTone: Tone?

    /// Pictures each frame of its turn is drawn among, round the whole turn.
    private static let steps = 96

    init(seed: Double) {
        self.seed = seed
        layer.allowsGroupOpacity = true
        // Bottom to top, as `MoylDrawing.draw` lays them down.
        for part in [halo, flare, rays, behind, moon.behind, glints[0].behind, glints[1].behind, globe, candle, before,
                     moon.before, glints[0].before, glints[1].before, poke] + sparkles + dust {
            part.contentsScale = LabelPictures.scale
            layer.addSublayer(part)
        }
    }

    /// How wide (and tall) its layer is: room for its rings, its moon and their glow.
    private var side: CGFloat { radius * 5 }
    private var middle: CGPoint { CGPoint(x: side / 2, y: side / 2) }

    /// Shows `walker`'s moyl as it is at `date`, on a bar `height` tall in a window `top` tall,
    /// with the bass at `beat` and the beat at `beats` (see `Beat`), `shown` (0...1) as far as
    /// Midnight's band lets it be.
    func show(_ walker: Walker, at date: Date, height: CGFloat, top: CGFloat, beat: CGFloat, beats: Double?, shown: Double = 1) {
        let r = Walker.moylRadius(height: height)
        if r != radius { resize(r) }
        // As `MoylDrawing` reckons it: its own time, so no two keep step.
        let time = date.timeIntervalSinceReferenceDate + seed * 97
        let look = MoylLook(walker.job.moyl, date: date, time: time, bop: MoylDrawing.bop(beat: beat, beats: beats))
        let place = walker.place(at: date, height: height)
        var center = place.center
        if look.jitter > 0 {
            center.x += look.jitter * CGFloat(0.6 * sin(time * 53) + 0.4 * sin(time * 31))
            center.y += look.jitter * CGFloat(0.5 * sin(time * 47 + 1))
        }
        layer.position = CGPoint(x: center.x, y: top - center.y)
        // A touch bigger at the front of its orbit, smaller at the back; swelling on the beat.
        let scale = (1 + 0.06 * place.near) * (1 + look.swell)
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        Self.fade(layer, walker.visibility(at: date) * shown)
        let shape = Globe(center: middle, radius: r, seed: seed, turn: 0)

        // Its planet, at the picture for how far it's turned.
        if look.plate != plate {
            plate = look.plate
            turns = [:]
        }
        let step = look.spin.isFinite ? Int((time / look.spin).truncatingRemainder(dividingBy: 1) * Double(Self.steps)) : 0
        if turns[step] == nil {
            let turned = Globe(center: middle, radius: r, seed: seed, turn: CGFloat(step) * 2 * .pi / CGFloat(Self.steps))
            var plated = look
            plated.tone = look.plate.tone
            turns[step] = MoylDrawing.planet(plated, turned, seed: seed, scale: LabelPictures.scale)
        }
        set(globe, turns[step])

        // Its rings and its moon's orbit, behind it and in front.
        if look.rim != rim {
            rim = look.rim
            // At their brightest (they're faded as the beat goes), with no glints (those move).
            var drawn = look
            drawn.rings = look.rings > 0 ? 1 : 0
            drawn.singing = false
            drawn.moon = look.moon?.drawn
            for (part, near) in [(behind, false), (before, true)] {
                set(part, picture { drawing in
                    if drawn.rings > 0 { drawing.rings(drawn, shape, near: near) }
                    if let moon = drawn.moon { drawing.orbitPath(moon, shape, near: near, time: time) }
                })
            }
        }
        let rings = look.rings > 0 ? min(look.rings, 1) : 1
        Self.fade(behind, rings)
        Self.fade(before, rings)

        // Its glow: pulsing for what needs you, brighter for a moment when it's clicked.
        let poked = walker.poked.map { date.timeIntervalSince($0) / 1.2 }.flatMap { $0 < 1 ? $0 : nil }
        let tone = (look.glowTone ?? look.tone).stepped
        if tone != glowTone {
            glowTone = tone
            set(halo, picture { $0.halo(tone, shape, strength: 1) })
        }
        Self.fade(halo, min(max(look.glow, poked.map { 0.32 * (1 - $0) } ?? 0), 1))

        // Flaring, its work done: a starlit glow, and rays.
        let flaring = CGFloat(walker.flare(at: date))
        Self.show(flare, flaring > 0)
        Self.show(rays, flaring > 0)
        if flaring > 0 {
            flare.opacity = Float(0.18 + 0.42 * flaring)
            let grown = (2 + 1.6 * flaring) / 2
            flare.transform = CATransform3DMakeScale(grown, grown, 1)
            rays.opacity = Float(flaring)
            let length = 0.45 + 0.55 * flaring
            rays.transform = CATransform3DScale(CATransform3DMakeRotation(-CGFloat(time * 0.25), 0, 0, 1), length, length, 1)
        }

        // Its moon, and the glints going round its rings while it sings.
        if let orbit = look.moon {
            if orbit.tone.stepped != moonTone {
                moonTone = orbit.tone.stepped
                let size = MoylDrawing.moonSize(r)
                let image = picture(side: size * 2.4) { $0.moon(orbit, at: CGPoint(x: size * 1.2, y: size * 1.2), shape) }
                moon.picture(image, side: size * 2.4)
            }
            let (spot, near) = shape.point(latitude: 0, longitude: orbit.angle(at: time), turning: false, scale: MoylDrawing.moonOrbit)
            moon.place(at: flip(spot), near: near)
        } else {
            moon.hide()
        }
        for (index, glint) in glints.enumerated() {
            guard look.singing else {
                glint.hide()
                continue
            }
            let ringing = 2 * .pi * CGFloat((time / 2.4).truncatingRemainder(dividingBy: 1))
            let (spot, near) = shape.point(latitude: 0, longitude: CGFloat(index) * .pi - ringing + MoylDrawing.glint / 2, turning: false,
                                           scale: 1.9)
            if glint.isEmpty { glint.picture(picture(side: r * 0.5) { $0.glintDot(side: r * 0.5) }, side: r * 0.5) }
            glint.place(at: flip(spot), near: near)
        }

        // A candle on its night side, flickering.
        Self.show(candle, look.candle)
        if look.candle {
            if candle.contents == nil { set(candle, picture(side: r * 1.2) { $0.candle(at: CGPoint(x: r * 0.6, y: r * 0.6), radius: r, flicker: 1) }) }
            candle.bounds = CGRect(x: 0, y: 0, width: r * 1.2, height: r * 1.2)
            candle.position = flip(MoylDrawing.candleSpot(shape, look: look))
            let flicker = MoylDrawing.flicker(at: time)
            candle.transform = CATransform3DMakeScale(flicker, flicker, 1)
        }

        // The twinkle when it's clicked, and the selfie's stars.
        Self.show(poke, poked != nil)
        if let poked {
            let progress = CGFloat(poked)
            poke.position = flip(CGPoint(x: middle.x + r * 1.25, y: middle.y - r * (0.9 + 0.7 * progress)))
            poke.opacity = Float(1 - progress)
            poke.transform = CATransform3DMakeScale(1 - progress * 0.5, 1 - progress * 0.5, 1)
        }
        // Going: scattering into stardust, drifting up and out as it flares and fades.
        let pop = CGFloat(walker.popped(at: date)?.pop ?? 0)
        for (index, speck) in dust.enumerated() {
            Self.show(speck, pop > 0)
            guard pop > 0 else { continue }
            let angle = CGFloat(index) / CGFloat(dust.count) * 2 * .pi + CGFloat(seed) * 3
            let reach = r * (0.8 + 2.4 * (1 - (1 - pop) * (1 - pop))) * (index % 2 == 0 ? 1 : 0.75)
            speck.position = flip(CGPoint(x: middle.x + cos(angle) * reach, y: middle.y + sin(angle) * reach * 0.8 - r * 0.9 * pop))
            let size = 1.4 - 0.9 * pop
            speck.transform = CATransform3DMakeScale(size, size, 1)
        }
        for (index, sparkle) in sparkles.enumerated() {
            let twinkle = look.sparkles ? MoylDrawing.twinkle(index, at: time) : 0
            Self.show(sparkle, twinkle > 0.05)
            guard twinkle > 0.05 else { continue }
            let spot = MoylDrawing.sparkleSpots[index]
            sparkle.position = flip(CGPoint(x: middle.x + spot.x * r, y: middle.y + spot.y * r))
            sparkle.transform = CATransform3DMakeScale(twinkle * 0.42 / 0.55, twinkle * 0.42 / 0.55, 1)
        }
    }

    /// Drawn for a bar of a new height: everything again.
    private func resize(_ r: CGFloat) {
        radius = r
        plate = nil
        turns = [:]
        rim = nil
        glowTone = nil
        moonTone = nil
        candle.contents = nil
        for glint in glints { glint.picture(nil, side: 0) }
        layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        for part in [halo, flare, behind, before] {
            part.frame = layer.bounds
        }
        // Just the planet and its air.
        let globeSide = 2 * (r + Planet.margin(r))
        globe.bounds = CGRect(x: 0, y: 0, width: globeSide, height: globeSide)
        globe.position = middle
        let shape = Globe(center: middle, radius: r, seed: seed, turn: 0)
        set(flare, picture { $0.halo(.starlight, shape, strength: 1) })
        // The rays at their longest, to be turned and grown.
        let reach = r * 4.8, seed = self.seed
        rays.bounds = CGRect(x: 0, y: 0, width: reach * 2, height: reach * 2)
        rays.position = middle
        set(rays, picture(side: reach * 2) { drawing in
            drawing.rays(Globe(center: CGPoint(x: reach, y: reach), radius: r, seed: seed, turn: 0), flare: 1, time: 0)
        })
        // One star picture, for the click's twinkle and the selfie's, scaled for each.
        let star = picture(side: r * 1.1) { MoylDrawing.star(in: $0.canvas, at: CGPoint(x: r * 0.55, y: r * 0.55), size: r * 0.55) }
        for twinkle in [poke] + sparkles {
            twinkle.bounds = CGRect(x: 0, y: 0, width: r * 1.1, height: r * 1.1)
            set(twinkle, star)
        }
        let mote = picture(side: r * 0.55) { $0.glintDot(side: r * 0.55) }
        for speck in dust {
            speck.bounds = CGRect(x: 0, y: 0, width: r * 0.55, height: r * 0.55)
            set(speck, mote)
        }
    }

    /// From the picture's top-left coordinates to the layer's, which count up from the bottom.
    private func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: side - point.y) }

    // Each only if it's changed, so Core Animation has no more to send on than moved.

    fileprivate static func show(_ part: CALayer, _ shown: Bool) {
        if part.isHidden == shown { part.isHidden = !shown }
    }

    fileprivate static func fade(_ part: CALayer, _ opacity: Double) {
        let opacity = Float(opacity)
        if part.opacity != opacity { part.opacity = opacity }
    }

    private func set(_ part: CALayer, _ image: CGImage?) {
        if (part.contents as AnyObject?) !== image { part.contents = image }
    }

    /// A picture, `side` points square (the whole layer's, by default), drawn by `draw`.
    private func picture(side: CGFloat? = nil, _ draw: @escaping (MoylDrawing) -> Void) -> CGImage? {
        let side = side ?? self.side, seed = self.seed
        return Self.bitmap(of: Canvas { canvas, _ in
            draw(MoylDrawing(canvas: canvas, time: 0, seed: seed, scale: LabelPictures.scale))
        }
        .frame(width: side, height: side))
    }

    /// A moyl's ring of words, as round a seal (and as "MIDNIGHT ✦ OYL" round the band's moon):
    /// `text` in Midnight's engraved capitals all the way round at `radius` (its letters' middle),
    /// upright at the top and reading clockwise, ✦ between; said twice or more if it's short, set
    /// smaller if it's long (or at the least, cut short), and spaced to come out even. Over a soft
    /// ring of night, so it reads on a light menu bar too.
    static func ring(_ text: String, radius: CGFloat) -> CGImage? {
        let reach = radius + Self.ringBacking
        return bitmap(of: Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(MoylDrawing.circle(center, reach), with: .radialGradient(
                Gradient(stops: [.init(color: Tone.ink.color(0), location: (radius - 8) / reach),
                                 .init(color: Tone.ink.color(0.5), location: radius / reach), .init(color: Tone.ink.color(0), location: 1)]),
                center: center, startRadius: 0, endRadius: reach))
            func letters(of words: String, size: CGFloat) -> [(glyph: GraphicsContext.ResolvedText, width: CGFloat)] {
                words.map { letter in
                    let glyph = context.resolve(Text(String(letter)).font(Midnight.smallCaps(size)).foregroundStyle(Midnight.silver))
                    return (glyph, glyph.measure(in: CGSize(width: 60, height: 60)).width)
                }
            }
            func length(_ letters: [(glyph: GraphicsContext.ResolvedText, width: CGFloat)]) -> CGFloat {
                letters.reduce(0) { $0 + $1.width } + Self.ringSpacing * CGFloat(letters.count)
            }
            let around = 2 * .pi * radius, separator = Self.ringSeparator
            var size = Self.ringFont, words = text
            var set = letters(of: words + separator, size: size)
            if length(set) > around {
                // Smaller, a little at a time, and only then cut short.
                while length(set) > around, size > 5 {
                    size = max(5, size - 0.25)
                    set = letters(of: words + separator, size: size)
                }
                while length(set) > around, words.count > 4 {
                    words = String(words.dropLast(words.hasSuffix("…") ? 2 : 1)) + "…"
                    set = letters(of: words + separator, size: size)
                }
            } else {
                set = letters(of: String(repeating: words + separator, count: max(1, Int(around / length(set)))), size: size)
            }
            let spacing = (around - set.reduce(0) { $0 + $1.width }) / CGFloat(max(set.count, 1))
            var along: CGFloat = 0
            for (glyph, width) in set {
                let angle = -CGFloat.pi / 2 + (along + width / 2) / radius
                along += width + spacing
                var place = context
                place.translateBy(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                place.rotate(by: .radians(Double(angle) + .pi / 2))
                place.draw(glyph, at: .zero, anchor: .center)
            }
        }
        .frame(width: 2 * reach, height: 2 * reach))
    }

    /// The ring's letters' size, the least room between them, what goes between sayings of its
    /// words, and how far its soft backing reaches past its letters' middle.
    nonisolated private static let ringFont: CGFloat = 7.5, ringSpacing: CGFloat = 0.9, ringSeparator = "  ✦  "
    nonisolated static let ringBacking: CGFloat = 9

    /// How far out a ring of `text` goes (its letters' middle) round a moyl on a bar `height`
    /// tall: far enough out for all of it, once, but no less than just past its moon's orbit,
    /// and no more than the room under the bar allows.
    static func ringRadius(for text: String, height: CGFloat) -> CGFloat {
        // Letter by letter, each rounded up, as the ring measures them.
        let font = NSFont(name: "Copperplate", size: ringFont) ?? .systemFont(ofSize: ringFont)
        let letters = Array(text + ringSeparator)
        let length = letters.reduce(0) { $0 + (String($1) as NSString).size(withAttributes: [.font: font]).width.rounded(.up) }
            + ringSpacing * CGFloat(letters.count)
        return min(max(length / (2 * .pi) + 1, Walker.ringRadius(height: height)), (height + WalkerOverlay.below) / 2 - 8)
    }

    /// `view` as a picture for a layer, at the bar's scale: drawn straight into a bitmap laid out
    /// as Core Animation shows one (`ImageRenderer`'s own pictures cost it more to show).
    static func bitmap(of view: some View) -> CGImage? {
        let scale = LabelPictures.scale
        var image: CGImage?
        ImageRenderer(content: view).render { size, render in
            let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            context.scaleBy(x: scale, y: scale)
            render(context)
            image = context.makeImage()
        }
        return image
    }

    /// Something that goes round the planet, behind it or in front: two layers, one either side
    /// of the planet's, only one of them showing.
    @MainActor
    private final class Satellite {
        let behind = CALayer(), before = CALayer()

        var isEmpty: Bool { behind.contents == nil }

        func picture(_ image: CGImage?, side: CGFloat) {
            for part in [behind, before] {
                part.contents = image
                part.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            }
        }

        func place(at point: CGPoint, near: Bool) {
            (near ? before : behind).position = point
            MoylSprite.show(behind, !near)
            MoylSprite.show(before, near)
        }

        func hide() {
            MoylSprite.show(behind, false)
            MoylSprite.show(before, false)
        }
    }
}
