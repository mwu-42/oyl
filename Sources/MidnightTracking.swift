import SwiftUI

/// The hands, as Midnight Oyl shows them: a constellation across the band's sky. Each joint the
/// hand-pose model finds is a star, the fingertips brightest, with small glints, the knuckles and
/// the wrist next; the bones are fine dotted lines between them, stopping short of each star, the
/// way an atlas draws a figure. Its name is engraved by it, as the charts name theirs: the
/// gesture it's making, in Latin, or just MANUS; while the hands are the pointer, a sign for what
/// they're doing (Gemini's as two fingers scroll, the triangle's as three swipe, the sun's as two
/// hands zoom), and each a sight at its index fingertip, where its pointer is (see `PointerMode`). When a hand comes, its lines
/// draw on out from the wrist; when it's lost, it fades. It goes where the hand goes, across the
/// whole band and down its solid sky (where a hand's held, up in front of the Mac, it's well in
/// the band), keeping its own shape; behind the page it dims a little, so the type reads, and it
/// fades a little where the plate dissolves.
///
/// It reads `HandTrackFeed.shared` as it draws, 30 times a second, so nothing else re-renders for
/// it. (It needs no pictures from the camera, only where the hands are.)
struct HandConstellation: View {
    /// The band's frame, how far down it reaches, the page in it, and how far open it is.
    let size: CGSize
    let reach: CGFloat
    let page: CGRect
    let bloom: Double
    var active: Bool = true
    @StateObject private var reading = TrackingReading()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { _ in
            // The moment's taken at each tick of the timeline, so each tick's canvas is a new one,
            // drawn again (it'd otherwise look the same as the last to SwiftUI, and might not be).
            let time = MidnightBackdrop.clock
            Canvas { canvas, _ in
                reading.take(HandTrackFeed.shared.latest, at: ProcessInfo.processInfo.systemUptime)
                HandSky(canvas: canvas, size: size, reach: reach, page: page, bloom: bloom, time: time, reading: reading).draw()
            }
        }
        .allowsHitTesting(false)
    }
}

/// What the constellation keeps from frame to frame: the joints, eased so the stars don't shiver
/// with the model's jitter; and when a hand and its gesture last came, for their entrances.
final class TrackingReading: ObservableObject {
    struct Joint {
        var point = CGPoint.zero
        var confidence: Float = 0
        var found = false
        /// When it was last read.
        var read: TimeInterval = 0
    }

    /// Every joint, in the order they're kept: the wrist, then each finger from its root out.
    static let joints = ["wrist"] + fingers.flatMap { finger in
        (finger == "thumb" ? ["CMC", "MP", "IP", "Tip"] : ["MCP", "PIP", "DIP", "Tip"]).map { finger + $0 }
    }
    static let fingers = ["thumb", "index", "middle", "ring", "little"]
    static let slots = Dictionary(uniqueKeysWithValues: joints.enumerated().map { ($1, $0) })
    static let tips = [4, 8, 12, 16, 20]
    static let knuckles = [5, 9, 13, 17]
    /// The figure's lines, as an atlas would draw a hand: the thumb out from the wrist; the wrist
    /// to the first and last knuckles, and across the knuckles; and each finger out from its
    /// knuckle.
    static let lines: [(Int, Int)] = {
        var names: [(String, String)] = [("wrist", "thumbCMC"), ("thumbCMC", "thumbMP"), ("thumbMP", "thumbIP"),
                                         ("thumbIP", "thumbTip"), ("wrist", "indexMCP"), ("wrist", "littleMCP"),
                                         ("indexMCP", "middleMCP"), ("middleMCP", "ringMCP"), ("ringMCP", "littleMCP")]
        for finger in ["index", "middle", "ring", "little"] {
            names += [(finger + "MCP", finger + "PIP"), (finger + "PIP", finger + "DIP"), (finger + "DIP", finger + "Tip")]
        }
        return names.compactMap { line -> (Int, Int)? in
            guard let from = slots[line.0], let to = slots[line.1] else { return nil }
            return (from, to)
        }
    }()

    private(set) var now: TimeInterval = 0
    /// Two hands' worth of joints, eased; the first `handCount` are in use (kept after the hands
    /// go, so they can fade).
    private(set) var hands = [[Joint]](repeating: [Joint](repeating: Joint(), count: joints.count), count: 2)
    private(set) var handCount = 0
    /// The picture's width over its height.
    private(set) var aspect: CGFloat = 4.0 / 3
    /// When a hand was last in view, and when one came into view after none.
    private(set) var seen = -TimeInterval.infinity
    private(set) var arrived = -TimeInterval.infinity
    /// The gesture it reads as now, if any, and when that last changed. While the hand's the
    /// pointer, it reads as that, whatever its shape.
    private(set) var gesture: String?
    private(set) var gestureChanged = -TimeInterval.infinity
    /// The hand's the pointer.
    private(set) var pointing = false
    private var lastDraw: TimeInterval?

    /// 1 while a hand's in view, fading to 0 over a moment once it's gone.
    var presence: Double { min(max(1 - (now - seen) / 0.6, 0), 1) }
    /// 0 to 1 over the moment after a hand comes into view.
    var arrival: Double { min(max((now - arrived) / 0.8, 0), 1) }

    func take(_ latest: HandTrack?, at now: TimeInterval) {
        let step = min(max(now - (lastDraw ?? now), 0), 0.25)
        lastDraw = now
        self.now = now

        // A reading that's stopped coming is no reading.
        let track = latest.flatMap { now - $0.time < 0.75 ? $0 : nil }
        if let track { aspect = track.aspect }
        let count = min(track?.hands.count ?? 0, 2)
        if let track, count > 0 {
            let fresh = presence == 0
            if fresh { arrived = now }
            // Light easing: enough to take the shiver out, too little to lag.
            let ease = CGFloat(1 - exp(-step / 0.06))
            for hand in 0..<count {
                let snap = fresh || hand >= handCount
                for joint in track.hands[hand] {
                    guard let slot = Self.slots[joint.name] else { continue }
                    let old = hands[hand][slot]
                    let jump = hypot(joint.point.x - old.point.x, joint.point.y - old.point.y) > 0.12
                    hands[hand][slot].point = snap || jump || !old.found ? joint.point
                        : CGPoint(x: old.point.x + (joint.point.x - old.point.x) * ease, y: old.point.y + (joint.point.y - old.point.y) * ease)
                    hands[hand][slot].confidence = joint.confidence
                    hands[hand][slot].found = true
                    hands[hand][slot].read = now
                }
                for slot in hands[hand].indices where hands[hand][slot].read != now { hands[hand][slot].found = false }
            }
            handCount = count
            seen = now
        }

        let pointer = PointerFeed.shared.shown
        pointing = pointer != .off
        let doing = PointerFeed.shared.shape
        let named = pointer == .off ? track?.gesture : pointer == .needsAccess ? "pointer, unpermitted"
            : doing == .scrolling ? "pointer, scrolling" : doing == .swiping ? "pointer, swiping"
            : doing == .zooming ? "pointer, zooming" : "pointer"
        let reads = count > 0 ? named : nil
        if reads != gesture {
            gesture = reads
            gestureChanged = now
        }
    }

    /// What the constellation's called for `gesture`: in Latin, as a star chart names its figures.
    static func name(for gesture: String?) -> String {
        switch gesture {
        case "open palm": return "PALMA"
        case "point left", "point right": return "INDEX"
        case "horns": return "CORNUA"
        case "pinky": return "MINIMUS"
        case "pinch": return "FORCIPES"
        case "peace": return "PAX"
        case "ok": return "ANULUS"
        case "thumbs up": return "POLLEX"
        case "announce": return "PRAECO"
        case "tilt left", "tilt right": return "LIBRA"
        case "fist": return "PUGNUS"
        // The lyre, for rock 'n' roll.
        case "rock": return "LYRA"
        // The hands as the pointer are marked in signs, not named: the sight says it points;
        // Gemini's, two fingers scrolling; the triangle's, three swiping; the sun's, two hands
        // zooming. (Wanting Accessibility, a padlock, drawn by `HandSky`.)
        case "pointer", "pointer, unpermitted": return ""
        case "pointer, scrolling": return "\u{264A}\u{FE0E}"
        case "pointer, swiping": return "\u{25B3}"
        case "pointer, zooming": return "\u{2609}"
        default: return "MANUS"
        }
    }
}

/// One frame of the constellation, drawn from what `TrackingReading` has, over a band of `size`
/// reaching `reach` with `page` in it, `bloom` open, at `time` on the backdrop's clock.
struct HandSky {
    let canvas: GraphicsContext
    let size: CGSize
    let reach: CGFloat
    let page: CGRect
    let bloom: Double
    let time: Double
    let reading: TrackingReading

    func draw() {
        let presence = reading.presence * min(max((bloom - 0.7) / 0.3, 0), 1)
        guard presence > 0 else { return }
        for hand in 0..<reading.handCount {
            figure(hand, shown: presence)
        }
    }

    /// Where a hand's joints go in the band: the hand as a whole goes where it is in the picture,
    /// across the band's width, and down its solid sky (the picture's height, all but its edges,
    /// squeezed in between the menu bar and where the plate starts to dissolve, so a hand held up
    /// anywhere it's likely to be is well in the band); its joints round its palm keep the hand's
    /// own shape, at a size that reads in the band.
    private func places(of joints: [TrackingReading.Joint]) -> [CGPoint]? {
        let palm = ([0] + TrackingReading.knuckles).map { joints[$0] }.filter(\.found)
        guard !palm.isEmpty else { return nil }
        let center = CGPoint(x: palm.map(\.point.x).reduce(0, +) / CGFloat(palm.count),
                             y: palm.map(\.point.y).reduce(0, +) / CGFloat(palm.count))
        let x = size.width * (0.08 + 0.84 * center.x)
        // The fingers reach up from the palm, so it sits a little lower in the sky than its wrist.
        let top: CGFloat = 92, bottom = max(MidnightBackdrop.foot(atX: x, in: size, reach: reach) - 74, top + 40)
        let down = min(max((center.y - 0.12) / 0.76, 0), 1)
        let at = CGPoint(x: x, y: top + (bottom - top) * down)
        let scale = max(bottom - 52, 120) * 1.8
        return joints.map { joint in
            CGPoint(x: at.x + (joint.point.x - center.x) * reading.aspect * scale, y: at.y + (joint.point.y - center.y) * scale)
        }
    }

    /// How much of the figure shows at `point`: most of it, wherever the band is (a little less
    /// where the plate's dissolving), and dimmed a little behind the page, so its type still reads.
    private func showing(at point: CGPoint) -> Double {
        let plate = MidnightBackdrop.presence(at: point, in: size, reach: reach, page: page, overflow: Midnight.overflow,
                                              bloom: bloom, time: time)
        let behind = page.insetBy(dx: -10, dy: -10)
        let dx = max(behind.minX - point.x, point.x - behind.maxX, 0), dy = max(behind.minY - point.y, point.y - behind.maxY, 0)
        let clear = min(hypot(dx, dy) / 18, 1)
        let settled = min(plate / 0.6, 1)
        return (0.4 + 0.6 * settled) * (0.62 + 0.38 * Double(clear * clear * (3 - 2 * clear)))
    }

    private func figure(_ index: Int, shown: Double) {
        let joints = reading.hands[index]
        guard let points = places(of: joints) else { return }
        let showing = points.map(showing(at:))
        let drawn = reading.arrival

        // The lines: fine and dotted, drawing on out from the wrist as it comes, stopping short of
        // each star.
        for (from, to) in TrackingReading.lines where joints[from].found && joints[to].found {
            let level = Double(Self.level(of: to) - 1)
            let out = min(max(drawn * 4 - level, 0), 1)
            guard out > 0 else { continue }
            let a = points[from], b = points[to]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 8 else { continue }
            let unit = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
            let start = CGPoint(x: a.x + unit.x * 4, y: a.y + unit.y * 4)
            let end = CGPoint(x: start.x + unit.x * (length - 8) * out, y: start.y + unit.y * (length - 8) * out)
            var line = Path()
            line.move(to: start)
            line.addLine(to: end)
            let opacity = 0.8 * shown * min(showing[from], showing[to])
            canvas.stroke(line, with: .color(Midnight.silver.opacity(opacity)),
                          style: StrokeStyle(lineWidth: 1.15, lineCap: .round, dash: [0.01, 3]))
        }

        // The stars: the fingertips brightest, with glints; the knuckles and the wrist next; the
        // rest faint. Each twinkles a little, and comes on as the line reaches it.
        for (slot, joint) in joints.enumerated() where joint.found {
            let tip = TrackingReading.tips.contains(slot)
            let major = tip || slot == 0 || TrackingReading.knuckles.contains(slot)
            let reached = min(max(drawn * 4 - Double(Self.level(of: slot)) + 1, 0), 1)
            let twinkle = 0.86 + 0.14 * sin(time * (2.1 + 0.37 * Double(slot)) + Double(slot * 7 + index * 3))
            let light = min(shown * showing[slot] * reached * twinkle * Double(0.7 + 0.3 * min(joint.confidence, 1)) * 1.1, 1)
            guard light > 0.01 else { continue }
            Self.star(at: points[slot], radius: tip ? 2.5 : major ? 1.8 : 1.25, glint: tip ? 9.5 : major ? 4.5 : 0,
                      light: light * (tip ? 1 : major ? 0.92 : 0.75), in: canvas)
        }

        // Each hand's its own pointer: its hot spot, the index fingertip, as a sight.
        let indexTip = TrackingReading.tips[1]
        if reading.pointing, joints[indexTip].found {
            Self.sight(at: points[indexTip], light: shown * showing[indexTip] * drawn, in: canvas)
        }

        // Its name, engraved above and to the right of it, like CYGNUS by its cross: the gesture,
        // for the hand that's making it. As the pointer, a sign instead, and only for what it's doing.
        let found = points.indices.filter { joints[$0].found }
        guard let right = found.map({ points[$0].x }).max(), let top = found.map({ points[$0].y }).min() else { return }
        let gesture = index == 0 ? reading.gesture : nil
        let since = min(max((reading.now - reading.gestureChanged) / 0.5, 0), 1)
        let at = CGPoint(x: right + 10, y: max(top - 2, 46))
        let opacity = 0.55 * shown * showing[0] * drawn * (index == 0 ? since : 1)
        guard opacity > 0.01 else { return }
        if reading.pointing {
            let sign = gesture == "pointer, unpermitted" ? Text(Image(systemName: "lock")) : Text(TrackingReading.name(for: gesture))
            canvas.draw(sign.font(.system(size: 11, weight: .light, design: .serif)).foregroundStyle(Midnight.white.opacity(opacity * 1.4)),
                        at: at, anchor: .bottomLeading)
            return
        }
        canvas.draw(Text(TrackingReading.name(for: gesture)).font(Midnight.smallCaps(7)).tracking(1.8)
                        .foregroundStyle(Midnight.white.opacity(opacity)), at: at, anchor: .bottomLeading)
    }

    /// How far out along its finger a joint is: the wrist 0, each finger's root 1, out to its tip 4.
    private static func level(of slot: Int) -> Int { slot == 0 ? 0 : (slot - 1) % 4 + 1 }

    /// A sight, as the pointer's drawn (`PointerFigure`): a fine ring with four ticks out from it.
    static func sight(at point: CGPoint, light: Double, in canvas: GraphicsContext) {
        guard light > 0.01 else { return }
        var sight = Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
        for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 2) {
            sight.move(to: CGPoint(x: point.x + cos(angle) * 8.5, y: point.y + sin(angle) * 8.5))
            sight.addLine(to: CGPoint(x: point.x + cos(angle) * 12, y: point.y + sin(angle) * 12))
        }
        canvas.stroke(sight, with: .color(Midnight.white.opacity(0.8 * light)), lineWidth: 0.8)
    }

    /// A star: a soft halo of moonlight, a white core, and with `glint`, four fine arms that long,
    /// shorter fainter diagonals between.
    static func star(at point: CGPoint, radius: CGFloat, glint: CGFloat, light: Double, in canvas: GraphicsContext) {
        let halo = radius * 4.5
        canvas.fill(Path(ellipseIn: CGRect(x: point.x - halo, y: point.y - halo, width: 2 * halo, height: 2 * halo)),
                    with: .radialGradient(Gradient(colors: [Midnight.moonlight.opacity(0.42 * light), Midnight.moonlight.opacity(0)]),
                                          center: point, startRadius: 0, endRadius: halo))
        if glint > 0 {
            var arms = Path()
            for (length, angle) in [(glint, 0.0), (glint, Double.pi / 2), (glint * 0.45, Double.pi / 4), (glint * 0.45, -Double.pi / 4)] {
                let along = CGPoint(x: cos(angle) * length, y: sin(angle) * length)
                let across = CGPoint(x: -sin(angle) * 0.32, y: cos(angle) * 0.32)
                arms.move(to: CGPoint(x: point.x - along.x, y: point.y - along.y))
                arms.addLine(to: CGPoint(x: point.x + across.x, y: point.y + across.y))
                arms.addLine(to: CGPoint(x: point.x + along.x, y: point.y + along.y))
                arms.addLine(to: CGPoint(x: point.x - across.x, y: point.y - across.y))
                arms.closeSubpath()
            }
            canvas.fill(arms, with: .color(Midnight.white.opacity(0.9 * light)))
        }
        canvas.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)),
                    with: .color(Midnight.white.opacity(light)))
    }
}
