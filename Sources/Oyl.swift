import SwiftUI

/// Oyl, Oyl's imp: white, with a spiky head and big sleepy eyes. It acts out what its agent is doing (at a laptop for code, a
/// speech bubble for a chat), wears an orange hat while it's running a Claude (a black one while
/// it's running Muse), bops along to
/// music (or reads along to an audiobook), and with nothing to run, hangs out. In Midnight Oyl it's drawn as its moyl instead, a
/// little planet (see `Moyl`), wherever it is.
struct Oyl: View {
    var activity: AgentActivity = .idle
    var hat = false
    /// Its hat's color: Claude's orange, or Muse's black.
    var hatColor = Oyl.hatOrange
    /// Walking off to the left, for one that's finished (see `WalkerOverlay`).
    var walking = false
    /// On a surfboard, riding the visualizer's wave.
    var surfing = false
    /// With no agent to run: off on its own, a new pastime every so often.
    var hangingOut = false
    /// Music's playing, so while hanging out it bops its head to it.
    var music = false
    /// White on its own; a pastel when it's on a task (see `pastel(_:)`).
    var skin = Oyl.white
    /// One of the app's own jobs, which decides its color too.
    var duty: OylDuty?

    static let hatOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let museBlack = Color(white: 0.1)
    static let white = Color(white: 0.96)
    static let seafoam = Color(red: 0.45, green: 0.94, blue: 0.8)

    /// The pastel numbered `number`, for an Oyl on a task (see `AgentSession.skin`).
    static func pastel(_ number: Int) -> Color {
        pastels[number % pastels.count]
    }

    /// The pastel a new task's Oyl gets: the same each time for the same task, unless an Oyl
    /// already out has it, so several at once can be told apart.
    static func pastel(for task: String, avoiding taken: Set<Int>) -> Int {
        // FNV-1a, since Swift's own hashing changes from launch to launch; its high bits, which
        // are the best mixed.
        var hash: UInt32 = 2_166_136_261
        for byte in task.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let first = Int((UInt64(hash) * UInt64(pastels.count)) >> 32)
        return (0..<pastels.count).lazy.map { (first + $0) % pastels.count }.first { !taken.contains($0) } ?? first
    }

    // Clear of the jobs' own colors: sea green for staying awake, blue for timers, grey for a tired
    // battery.
    private static let pastels = [
        Color(red: 1, green: 0.7, blue: 0.8),       // pink
        Color(red: 1, green: 0.88, blue: 0.46),     // butter
        Color(red: 0.6, green: 0.93, blue: 0.68),   // mint
        Color(red: 0.64, green: 0.72, blue: 1),     // periwinkle
        Color(red: 0.8, green: 0.65, blue: 1),      // lavender
        Color(red: 0.82, green: 0.95, blue: 0.45),  // lime
        Color(red: 1, green: 0.64, blue: 0.56),     // coral
    ]
    /// Around Oyls on the menu bar, so a white one shows on a light one too.
    static let menuBarOutline = Color(white: 0.15).opacity(0.55)

    @Environment(\.notchTheme) private var theme

    /// What it is as a moyl: at the same job, in the same color.
    var moyl: Moyl.Kind {
        if let duty { return .duty(duty) }
        if hangingOut || walking || surfing { return .oyl(.idle, skin: skin, hat: hat ? hatColor : nil) }
        return .oyl(activity, skin: skin, hat: hat ? hatColor : nil)
    }

    var body: some View {
        if theme == .midnight {
            Moyl(moyl)
        } else {
            imp
        }
    }

    private var imp: some View {
        // A touch slower while hanging out, since that's on screen all the time.
        TimelineView(.animation(minimumInterval: 1.0 / (hangingOut ? 12 : 15))) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let beat = CGFloat(max(Beat.level - 0.3, 0) / 0.7), beats = Beat.position(at: time), bars = Beat.bars
            Canvas { canvas, size in
                let skin = duty?.skin(at: context.date) ?? skin
                var drawing = OylDrawing(canvas: canvas, size: size, time: time, beat: beat, skin: skin, beats: beats, bars: bars)
                drawing.cap = hatColor
                if let duty {
                    drawing.perform(duty)
                } else if hangingOut {
                    drawing.hangOut(music: music)
                } else {
                    drawing.draw(activity, hat: hat, walking: walking, surfing: surfing)
                }
            }
        }
    }
}

/// Draws in a 100 × 50 space scaled to fit: Oyl in a 40 × 44 box on the left (or in the middle
/// when it has nothing to work at, or walking), props on the right.
struct OylDrawing {
    let canvas: GraphicsContext
    let size: CGSize
    let time: TimeInterval
    let beat: CGFloat
    let skin: Color
    /// Drawn around it, if anything: on the menu bar, so it shows on a light one.
    var outline: Color?
    /// How quick its steps are, walking, against a stroll.
    var pace: Double = 1
    /// Where it is in the music's beat, while there's a steady one (see `Beat.position(at:)`).
    var beats: Double?
    /// The visualizer's bars, bass to treble (see `Beat.bars`).
    var bars: [Float] = []
    /// Its hat's color, when it wears one.
    var cap = Oyl.hatOrange
    private static let ink = Color(white: 0.08)  // its eyes
    private static let paper = Color.white.opacity(0.92)
    /// What it does at a laptop, standing left of the middle to make room.
    static let props: Set<AgentActivity> = [.coding, .running, .reading, .browsing, .thinking, .writing, .delegating]
    private static let codeColors = [Oyl.hatOrange, Color(red: 0.45, green: 0.7, blue: 1), Color(red: 0.45, green: 0.85, blue: 0.5)]

    /// The pose: where its eyes look, its hands and feet go, how high it is.
    private struct Pose {
        var look = CGPoint.zero
        var hands = (CGPoint(x: 12, y: 31), CGPoint(x: 28, y: 31))
        var feet = (CGPoint(x: 14, y: 41), CGPoint(x: 31, y: 37))
        var lift: CGFloat = 0
        var squash: CGFloat = 1
        var eyesClosed = false
        var lid: CGFloat = 0.36  // how far its lids come down
        /// Its head bopping: dropped this far on its neck, and tipped this much (radians).
        var nod: CGFloat = 0
        var tilt: CGFloat = 0
    }

    func draw(_ activity: AgentActivity, hat: Bool, walking: Bool, surfing: Bool) {
        let atWork = Self.props.contains(activity) && !walking && !surfing
        let pose = pose(for: activity, walking: walking, surfing: surfing)

        let space = self.space
        // Facing left when walking, the way it goes.
        let body = body(in: space, at: atWork ? 6 : 30, pose: pose, mirrored: walking)
        if surfing {
            // A board under its feet.
            let board = Path(roundedRect: CGRect(x: 1, y: 41.5, width: 38, height: 4.2), cornerRadius: 2.1)
            body.fill(board, with: .color(Oyl.hatOrange))
            body.fill(Path(CGRect(x: 19, y: 41.5, width: 2, height: 4.2)), with: .color(.white.opacity(0.85)))
        }
        drawOyl(in: body, pose: pose, hat: hat)

        guard !walking, !surfing else { return }
        switch activity {
        case .coding, .running, .reading, .browsing, .thinking:
            laptop(in: space, activity: activity)
            if activity == .thinking { thoughts(in: space) }
        case .writing:
            bubble(in: space)
        case .delegating:
            var helper = space
            helper.translateBy(x: 62, y: 16 - abs(sin(time * .pi * 1.6)) * 4)
            helper.scaleBy(x: 0.55, y: 0.55)
            drawOyl(in: helper, pose: Pose(look: CGPoint(x: -0.8, y: 0)), hat: false)
        case .waiting:
            // "!" for your attention, blinking.
            if Int(time * 3) % 3 != 2 {
                let mark = Color(red: 1, green: 0.8, blue: 0.26)
                space.fill(Path(roundedRect: CGRect(x: 76, y: 6, width: 4, height: 13), cornerRadius: 2), with: .color(mark))
                space.fill(Path(ellipseIn: CGRect(x: 75.8, y: 22, width: 4.4, height: 4.4)), with: .color(mark))
            }
        case .done:
            var check = Path()
            check.move(to: CGPoint(x: 74, y: 16))
            check.addLine(to: CGPoint(x: 79, y: 22))
            check.addLine(to: CGPoint(x: 89, y: 9))
            space.stroke(check, with: .color(Color(red: 0.45, green: 0.85, blue: 0.5)),
                         style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        case .idle:
            break
        }
    }

    /// The drawing space, scaled to fit and centered.
    private var space: GraphicsContext {
        let scale = min(size.width / 100, size.height / 50)
        var space = canvas
        space.translateBy(x: (size.width - 100 * scale) / 2, y: (size.height - 50 * scale) / 2)
        space.scaleBy(x: scale, y: scale)
        return space
    }

    /// Where to draw Oyl's 40 × 44 box, at `x` in the drawing space, lifted and squashed as posed.
    private func body(in space: GraphicsContext, at x: CGFloat, pose: Pose, mirrored: Bool = false) -> GraphicsContext {
        var body = space
        body.translateBy(x: x, y: 3 - pose.lift)
        if mirrored {
            body.translateBy(x: 40, y: 0)
            body.scaleBy(x: -1, y: 1)
        }
        // Squashing down from the feet, so a bop looks like a bounce.
        body.translateBy(x: 20, y: 44)
        body.scaleBy(x: 1 + (1 - pose.squash) * 0.6, y: pose.squash)
        body.translateBy(x: -20, y: -44)
        return body
    }

    /// Breathing, blinking and bopping to the beat, whatever else it's up to.
    private func restingPose() -> Pose {
        var pose = Pose()
        let breath = sin(time * 2 * .pi / 3)
        pose.squash = 1 + 0.025 * breath - beat * 0.08
        pose.lift = beat * 3
        pose.eyesClosed = time.truncatingRemainder(dividingBy: 3.7) < 0.12
        return pose
    }

    private func pose(for activity: AgentActivity, walking: Bool, surfing: Bool) -> Pose {
        var pose = restingPose()
        if walking {
            let stride = sin(time * pace * 2 * .pi * 1.8)
            pose.feet = (CGPoint(x: 18 + stride * 5, y: 41.5), CGPoint(x: 22 - stride * 5, y: 41.5))
            pose.hands = (CGPoint(x: 12 - stride * 2, y: 31), CGPoint(x: 28 + stride * 2, y: 31))
            pose.lift += abs(stride) * 1.4
            pose.look = CGPoint(x: 0.7, y: 0)
            return pose
        }
        if surfing {
            // Knees bent, arms out for balance, swaying.
            let sway = sin(time * 2 * .pi / 2.2)
            pose.feet = (CGPoint(x: 11, y: 40.5), CGPoint(x: 29, y: 40.5))
            pose.hands = (CGPoint(x: 4, y: 24 + sway * 3), CGPoint(x: 36, y: 22 - sway * 3))
            pose.look = CGPoint(x: 0.8, y: 0.1)
            return pose
        }
        switch activity {
        case .coding, .running:
            // Both hands at the keys, taking turns.
            let tap = sin(time * 2 * .pi * 3) > 0
            pose.hands = (CGPoint(x: 30, y: tap ? 31 : 33), CGPoint(x: 35, y: tap ? 33 : 31))
            pose.look = CGPoint(x: 0.8, y: 0.3)
        case .thinking:
            pose.look = CGPoint(x: 0.5, y: -0.9)
            pose.hands.1 = CGPoint(x: 26, y: 24)  // chin in hand
        case .reading, .browsing:
            pose.look = CGPoint(x: 0.5 + 0.4 * sin(time * 1.6), y: 0.2)
            pose.hands.1 = CGPoint(x: 33, y: 33)
        case .writing, .delegating:
            pose.look = CGPoint(x: 0.9, y: 0)
        case .waiting:
            pose.lift += abs(sin(time * .pi * 1.6)) * 5
            pose.hands = (CGPoint(x: 9, y: 24), CGPoint(x: 31, y: 24))  // arms up
            pose.look = CGPoint(x: 0, y: 0.4)
        case .idle, .done:
            pose.look = CGPoint(x: 0.6 * sin(time * 0.45), y: 0.15)
        }
        return pose
    }

    /// Where its head goes, in its 40 × 44 box: dropped and tipped on its neck as posed.
    private func headContext(in context: GraphicsContext, pose: Pose) -> GraphicsContext {
        var head = context
        head.translateBy(x: 20, y: 25 + pose.nod)
        head.rotate(by: .radians(Double(pose.tilt)))
        head.translateBy(x: -20, y: -25)
        return head
    }

    private func drawOyl(in context: GraphicsContext, pose: Pose, hat: Bool) {
        // Its head (and all on it) apart from the rest, so it can bop.
        let top = headContext(in: context, pose: pose)
        let head = CGPoint(x: 20, y: 15), radius: CGFloat = 11
        var heads = [Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius, width: 2 * radius, height: 2 * radius))]
        let torso = Path(ellipseIn: CGRect(x: 14, y: 24, width: 12, height: 11))
        // Its spikes, chunky ones: two long ones up and out, shorter ones around the sides.
        let spikes: [(CGFloat, CGFloat, CGFloat)] = [(-0.78, -0.62, 11), (0.35, -0.94, 11), (0.97, -0.25, 7),
                                                     (-1, 0.05, 7.5), (-0.8, 0.6, 6), (0.9, 0.45, 4.5)]
        for (dx, dy, length) in spikes {
            let tip = CGPoint(x: head.x + dx * (radius + length), y: head.y + dy * (radius + length))
            let base = CGPoint(x: head.x + dx * radius * 0.6, y: head.y + dy * radius * 0.6)
            let width: CGFloat = length > 8 ? 5 : 4
            var spike = Path()
            spike.move(to: tip)
            spike.addLine(to: CGPoint(x: base.x - dy * width, y: base.y + dx * width))
            spike.addLine(to: CGPoint(x: base.x + dy * width, y: base.y - dx * width))
            spike.closeSubpath()
            heads.append(spike)
        }
        var limbs: [(Path, CGFloat)] = []
        for (shoulder, hand) in [(CGPoint(x: 15, y: 26), pose.hands.0), (CGPoint(x: 25, y: 26), pose.hands.1)] {
            limbs.append((Path { $0.move(to: shoulder); $0.addLine(to: hand) }, 3))
        }
        for (hip, foot) in [(CGPoint(x: 17, y: 33), pose.feet.0), (CGPoint(x: 23, y: 33), pose.feet.1)] {
            limbs.append((Path { $0.move(to: hip); $0.addLine(to: foot) }, 3.8))
        }

        // The outline: everything stroked first, then filled over, so only the outside edge
        // shows (no need to merge the shapes).
        if let outline {
            let rim: CGFloat = 0.7
            for shape in heads { top.stroke(shape, with: .color(outline), lineWidth: 2 * rim) }
            context.stroke(torso, with: .color(outline), lineWidth: 2 * rim)
            for (limb, width) in limbs {
                context.stroke(limb, with: .color(outline), style: StrokeStyle(lineWidth: width + 2 * rim, lineCap: .round))
            }
        }
        for shape in heads { top.fill(shape, with: .color(skin)) }
        context.fill(torso, with: .color(skin))
        for (limb, width) in limbs {
            context.stroke(limb, with: .color(skin), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }

        // Big sleepy eyes: white, with the pupil looking about and a heavy lid over the top.
        for center in [CGPoint(x: 14.9, y: 18), CGPoint(x: 25.1, y: 18)] {
            let eye = CGRect(x: center.x - 4, y: center.y - 3.5, width: 8, height: 7)
            guard !pose.eyesClosed else {
                top.stroke(Path { $0.move(to: CGPoint(x: eye.minX + 0.6, y: center.y + 0.8))
                                      $0.addQuadCurve(to: CGPoint(x: eye.maxX - 0.6, y: center.y + 0.8),
                                                      control: CGPoint(x: center.x, y: center.y + 2.4)) },
                               with: .color(Self.ink), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                continue
            }
            var inside = top
            inside.clip(to: Path(ellipseIn: eye))
            inside.fill(Path(ellipseIn: eye), with: .color(Self.ink))
            let glint = CGPoint(x: center.x + pose.look.x * 1.6, y: center.y + 0.6 + pose.look.y * 1.1)
            inside.fill(Path(ellipseIn: CGRect(x: glint.x - 1.2, y: glint.y - 1.2, width: 2.4, height: 2.4)), with: .color(.white))
            inside.fill(Path(CGRect(x: eye.minX, y: eye.minY, width: eye.width, height: eye.height * pose.lid)), with: .color(skin))
        }

        if hat {
            // A beanie with a bobble: orange for Claude; black for Muse, its band paler so it
            // shows against a dark menu bar.
            var shape = Path()
            shape.move(to: CGPoint(x: 10.5, y: 8.6))
            shape.addQuadCurve(to: CGPoint(x: 29.5, y: 8.6), control: CGPoint(x: 20, y: -4))
            shape.closeSubpath()
            top.fill(shape, with: .color(cap))
            let band = cap == Oyl.hatOrange ? Color(red: 0.72, green: 0.38, blue: 0.27) : Color(white: 0.36)
            top.fill(Path(roundedRect: CGRect(x: 9.6, y: 7.4, width: 20.8, height: 3.2), cornerRadius: 1.6), with: .color(band))
            top.fill(Path(ellipseIn: CGRect(x: 18, y: -0.6, width: 4, height: 4)), with: .color(cap == Oyl.hatOrange ? cap : band))
        }
    }

    /// A laptop on the right, its screen showing the work.
    private func laptop(in context: GraphicsContext, activity: AgentActivity) {
        context.fill(Path(roundedRect: CGRect(x: 56, y: 9, width: 36, height: 25), cornerRadius: 3), with: .color(Color(white: 0.34)))
        context.fill(Path(roundedRect: CGRect(x: 58.5, y: 11.5, width: 31, height: 20), cornerRadius: 1.5), with: .color(Color(white: 0.07)))
        context.fill(Path(roundedRect: CGRect(x: 51, y: 34, width: 46, height: 3.6), cornerRadius: 1.8), with: .color(Color(white: 0.27)))
        func line(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ color: Color) {
            guard width > 0 else { return }
            context.fill(Path(roundedRect: CGRect(x: x, y: y, width: width, height: 2.6), cornerRadius: 1.3), with: .color(color))
        }
        switch activity {
        case .coding:
            // Lines of code typed out, then cleared for the next lines.
            var typed = (time * 14).truncatingRemainder(dividingBy: 60)
            for (index, (indent, length)) in [(0.0, 14.0), (4.0, 18.0), (4.0, 10.0), (0.0, 16.0)].enumerated() {
                let shown = min(max(typed, 0), length)
                line(61 + indent, 14 + CGFloat(index) * 4.3, shown, Self.codeColors[index % 3])
                typed -= length
            }
        case .running:
            var prompt = Path()
            prompt.move(to: CGPoint(x: 61, y: 14))
            prompt.addLine(to: CGPoint(x: 63.5, y: 15.6))
            prompt.addLine(to: CGPoint(x: 61, y: 17.2))
            context.stroke(prompt, with: .color(Self.codeColors[2]), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            line(65.5, 14.3, 12, .white.opacity(0.8))
            let phase = time.truncatingRemainder(dividingBy: 2.4)
            for row in 0..<3 where phase > 0.5 + Double(row) * 0.5 {
                line(61, 19 + CGFloat(row) * 4, [20, 14, 23][row], .white.opacity(0.4))
            }
        case .thinking:
            if Int(time * 2) % 2 == 0 { line(61, 14, 2.6, .white.opacity(0.7)) }  // a cursor, waiting
        default:
            // Text going by: gray for code, blue for the web.
            let color = activity == .browsing ? Self.codeColors[1] : .white.opacity(0.6)
            let shift = time * 5
            let offset = CGFloat(shift.truncatingRemainder(dividingBy: 4.3))
            var inside = context
            inside.clip(to: Path(CGRect(x: 58.5, y: 11.5, width: 31, height: 20)))
            for row in 0..<6 {
                let width = [22.0, 14, 18, 9, 24, 16][(row + Int(shift / 4.3)) % 6]
                line(61, 13 + CGFloat(row) * 4.3 - offset, width, color)
            }
        }
    }

    /// Thought bubbles rising from its head.
    private func thoughts(in context: GraphicsContext) {
        let shown = Int(time * 2) % 4
        for (index, bubble) in [(39.0, 9.0, 1.4), (44.0, 4.5, 1.9), (50.5, 1.5, 2.4)].enumerated() where index < shown {
            context.fill(Path(ellipseIn: CGRect(x: bubble.0 - bubble.2, y: bubble.1 - bubble.2, width: 2 * bubble.2, height: 2 * bubble.2)),
                         with: .color(.white.opacity(0.75)))
        }
    }

    /// A speech bubble filling up with words, for a reply in a chat.
    private func bubble(in context: GraphicsContext) {
        var shape = Path(roundedRect: CGRect(x: 54, y: 5, width: 40, height: 25), cornerRadius: 6)
        shape.move(to: CGPoint(x: 57, y: 24))
        shape.addLine(to: CGPoint(x: 48, y: 31))
        shape.addLine(to: CGPoint(x: 62, y: 28))
        shape.closeSubpath()
        context.fill(shape, with: .color(Self.paper))
        var written = (time * 16).truncatingRemainder(dividingBy: 80)
        for (index, length) in [28.0, 22, 16].enumerated() {
            let shown = min(max(written, 0), length)
            if shown > 0 {
                context.fill(Path(roundedRect: CGRect(x: 59, y: 10 + CGFloat(index) * 5.5, width: shown, height: 2.8), cornerRadius: 1.4),
                             with: .color(Color(white: 0.3)))
            }
            written -= length
        }
    }
}

// MARK: - Hanging out

extension OylDrawing {
    /// What it gets up to with no agent to run: a pastime every 12 s, always in the same order
    /// (so any Oyls on screen together do the same), or bopping its head while music plays.
    fileprivate enum Pastime { case butterfly, toss, doze, wave, read, sip, dance }
    private static let pastimes: [Pastime] = [.butterfly, .toss, .doze, .wave, .read, .sip]
    private static let scene: TimeInterval = 12
    private static let blue = Color(red: 0.45, green: 0.7, blue: 1)

    /// Oyl on the left, as when at work, with what it's playing with to its right.
    func hangOut(music: Bool) {
        let count = Self.pastimes.count
        let index = Int(time / Self.scene), t = time.truncatingRemainder(dividingBy: Self.scene)
        let now: Pastime = music ? .dance : Self.pastimes[index % count]
        let last: Pastime = music ? .dance : Self.pastimes[(index + count - 1) % count]
        var pose = pose(for: now, at: t)
        if t < 0.6 {
            // Easing out of the last one.
            pose = Self.blend(self.pose(for: last, at: t + Self.scene), pose, CGFloat(t / 0.6))
        }
        let space = self.space
        let body = body(in: space, at: 6, pose: pose)
        drawOyl(in: body, pose: pose, hat: false)

        // Its things fade in and out with the pastime; things it holds move with it.
        var props = space, held = body
        props.opacity = now == .dance ? 1 : min(t / 0.5, (Self.scene - t) / 0.5, 1)
        held.opacity = props.opacity
        switch now {
        case .butterfly:
            butterfly(in: props, at: butterflySpot)
        case .toss:
            ball(in: held, at: tossedBall(at: t).ball)
        case .doze:
            snores(in: props)
        case .wave:
            // A heart, once it's waved.
            let since = t < 7 ? t - 3 : t - 9
            if since > 0 && since < 1.6 {
                var faded = props
                faded.opacity *= 1 - since / 1.6
                Self.heart(in: faded, at: CGPoint(x: 45 + since * 3, y: 15 - since * 6))
            }
        case .read:
            book(in: held, at: t)
        case .sip:
            mug(in: held, at: t)
        case .dance:
            notes(in: props)
        }
    }

    private func pose(for pastime: Pastime, at t: TimeInterval) -> Pose {
        var pose = restingPose()
        let lookingAbout = CGPoint(x: 0.6 * sin(time * 0.45), y: 0.15)
        switch pastime {
        case .butterfly:
            // Watching it (its eyes are about x 26, y 21 in the drawing space), and hopping for it.
            let spot = butterflySpot
            pose.look = CGPoint(x: Self.clamp((spot.x - 26) / 30), y: Self.clamp((spot.y - 21) / 12))
            pose.lift += 5 * Self.during(t, 7, 7.6, ease: 0.3)
        case .toss:
            let toss = tossedBall(at: t)
            pose.hands = (CGPoint(x: 12, y: 30), toss.hand)
            pose.look = CGPoint(x: Self.clamp((toss.ball.x - 20) / 12), y: Self.clamp((toss.ball.y - 19) / 9))
        case .doze:
            Self.sit(&pose)
            pose.eyesClosed = true
            pose.squash = 1 + 0.045 * sin(time * 2 * .pi / 4.5)
            pose.hands = (CGPoint(x: 19, y: 32), CGPoint(x: 27, y: 32))
        case .wave:
            // Waving at you, twice.
            let up = max(Self.during(t, 0, 3), Self.during(t, 7, 9))
            pose.hands.1 = Self.mix(pose.hands.1, CGPoint(x: 36 + 2 * sin(time * 2 * .pi * 2.2), y: 16), up)
            pose.look = Self.mix(lookingAbout, CGPoint(x: 0, y: 0.3), up)
        case .read:
            Self.sit(&pose)
            pose.hands = (CGPoint(x: 18, y: 31), CGPoint(x: 32, y: 31))
            pose.look = CGPoint(x: 0.15 + 0.3 * sin(time * 1.3), y: 0.9)
        case .sip:
            pose.hands.1 = mugHand(at: t)
            pose.eyesClosed = pose.eyesClosed || sipping(at: t) > 0.8
            pose.look = CGPoint(x: 0.6, y: 0.5)
        case .dance:
            // Bopping its head, lids low: down on each beat and back up, tipped one way then the
            // other, a foot lifting between beats to tap down on the next.
            let bop = self.bop
            pose.nod = 2.6 * bop.depth
            pose.tilt = (bop.count % 2 == 0 ? 0.07 : -0.07) * bop.depth
            pose.lift = 0
            pose.squash = 1 - 0.03 * bop.depth
            pose.lid = 0.5
            pose.look = CGPoint(x: 0.3, y: 0.4)
            pose.hands = (CGPoint(x: 12, y: 31 + bop.depth), CGPoint(x: 28, y: 31 + bop.depth))
            pose.feet = (CGPoint(x: 14, y: 41), CGPoint(x: 27, y: 41 - 2.4 * max(0, sin(2 * .pi * (bop.through - 0.5)))))
        }
        return pose
    }

    /// Its head bopping: how far down (0 up, 1 all the way), on which beat, and how far through
    /// it. To the music's beat while it has a steady one, down on each and easing back up; else
    /// to the bass as it comes; else, with nothing to hear, to a tempo of its own.
    private var bop: (depth: CGFloat, count: Int, through: Double) {
        let position: Double
        if let beats {
            position = beats
        } else if beat > 0 {
            return (beat, 0, 0)
        } else {
            position = time * 1.8
        }
        let count = position.rounded(.down), through = position - count
        return (CGFloat(pow(0.5 + 0.5 * cos(2 * .pi * through), 1.5)), Int(count), through)
    }

    /// Sat down, legs out in front.
    private static func sit(_ pose: inout Pose) {
        pose.lift -= 5
        pose.feet = (CGPoint(x: 27, y: 36.5), CGPoint(x: 32, y: 35))
    }

    private static func blend(_ from: Pose, _ to: Pose, _ amount: CGFloat) -> Pose {
        let f = amount * amount * (3 - 2 * amount)
        var pose = to
        pose.look = mix(from.look, to.look, f)
        pose.hands = (mix(from.hands.0, to.hands.0, f), mix(from.hands.1, to.hands.1, f))
        pose.feet = (mix(from.feet.0, to.feet.0, f), mix(from.feet.1, to.feet.1, f))
        pose.lift = from.lift + (to.lift - from.lift) * f
        pose.squash = from.squash + (to.squash - from.squash) * f
        pose.nod = from.nod + (to.nod - from.nod) * f
        pose.tilt = from.tilt + (to.tilt - from.tilt) * f
        pose.eyesClosed = f < 0.5 ? from.eyesClosed : to.eyesClosed
        return pose
    }

    private static func mix(_ from: CGPoint, _ to: CGPoint, _ f: CGFloat) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat { min(max(value, -1), 1) }

    /// 1 from `start` to `end`, 0 otherwise, easing over `ease` seconds at each end.
    private static func during(_ t: TimeInterval, _ start: TimeInterval, _ end: TimeInterval,
                               ease: TimeInterval = 0.3) -> CGFloat {
        let f = CGFloat(min(max(min(t - start, end - t) / ease, 0), 1))
        return f * f * (3 - 2 * f)
    }

    // Butterfly

    /// Where the butterfly it watches has flitted to, in the drawing space.
    private var butterflySpot: CGPoint {
        CGPoint(x: 64 + 20 * sin(time * 0.7), y: 18 + 8 * sin(time * 1.9))
    }

    private func butterfly(in context: GraphicsContext, at spot: CGPoint) {
        let flap = 0.35 + 0.65 * abs(sin(time * 2 * .pi * 2.5))
        for side: CGFloat in [-1, 1] {
            let upper = 4.2 * flap, lower = 3 * flap
            context.fill(Path(ellipseIn: CGRect(x: side < 0 ? spot.x - upper : spot.x, y: spot.y - 4, width: upper, height: 4.4)),
                         with: .color(Self.blue))
            context.fill(Path(ellipseIn: CGRect(x: side < 0 ? spot.x - lower : spot.x, y: spot.y - 0.4, width: lower, height: 3.4)),
                         with: .color(Self.blue.opacity(0.8)))
        }
        context.fill(Path(roundedRect: CGRect(x: spot.x - 0.5, y: spot.y - 3, width: 1, height: 5.5), cornerRadius: 0.5),
                     with: .color(Color(white: 0.9)))
    }

    // Ball

    /// The ball it tosses up and catches (in its own box), and where its hand is.
    private func tossedBall(at t: TimeInterval) -> (ball: CGPoint, hand: CGPoint) {
        let p = t.truncatingRemainder(dividingBy: 1.5) / 1.5
        let flight = CGFloat(min(max((p - 0.12) / 0.76, 0), 1))
        // The hand dips to throw, and to catch.
        let hand = CGPoint(x: 31, y: 29 + 2.5 * max(0, cos(p * 2 * .pi)))
        let ball = CGPoint(x: hand.x + 2 + 6 * sin(flight * .pi), y: hand.y - 3 - 20 * 4 * flight * (1 - flight))
        return (ball, hand)
    }

    private func ball(in context: GraphicsContext, at center: CGPoint) {
        context.fill(Path(ellipseIn: CGRect(x: center.x - 2.8, y: center.y - 2.8, width: 5.6, height: 5.6)),
                     with: .color(Oyl.hatOrange))
        context.fill(Path(ellipseIn: CGRect(x: center.x - 1.9, y: center.y - 1.9, width: 1.6, height: 1.6)),
                     with: .color(.white.opacity(0.55)))
    }

    // Dozing

    /// Z's drifting up and away as it sleeps.
    private func snores(in context: GraphicsContext) {
        for index in 0..<3 {
            let phase = CGFloat((time / 3.6 + Double(index) / 3).truncatingRemainder(dividingBy: 1))
            let side = 2.4 + 3 * phase
            let corner = CGPoint(x: 42 + 26 * phase, y: 21 - 16 * phase)
            var z = Path()
            z.move(to: corner)
            z.addLine(to: CGPoint(x: corner.x + side, y: corner.y))
            z.addLine(to: CGPoint(x: corner.x, y: corner.y + side))
            z.addLine(to: CGPoint(x: corner.x + side, y: corner.y + side))
            var faded = context
            faded.opacity *= Double(sin(phase * .pi))
            faded.stroke(z, with: .color(.white.opacity(0.85)),
                         style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
    }

    // Waving

    static func heart(in context: GraphicsContext, at center: CGPoint, size s: CGFloat = 3) {
        let pink = GraphicsContext.Shading.color(Color(red: 1, green: 0.42, blue: 0.52))
        for dx in [-0.45 * s, 0.45 * s] {
            context.fill(Path(ellipseIn: CGRect(x: center.x + dx - 0.55 * s, y: center.y - 0.55 * s, width: 1.1 * s, height: 1.1 * s)),
                         with: pink)
        }
        var point = Path()
        point.move(to: CGPoint(x: center.x - 0.95 * s, y: center.y + 0.15 * s))
        point.addLine(to: CGPoint(x: center.x + 0.95 * s, y: center.y + 0.15 * s))
        point.addLine(to: CGPoint(x: center.x, y: center.y + 1.25 * s))
        point.closeSubpath()
        context.fill(point, with: pink)
    }

    // Reading

    /// An open book held up in front, a page turning now and then.
    private func book(in context: GraphicsContext, at t: TimeInterval) {
        context.fill(Path(roundedRect: CGRect(x: 16.5, y: 25.5, width: 17, height: 9.6), cornerRadius: 1.2), with: .color(Self.blue))
        for x in [17.5, 25.3] as [CGFloat] {
            context.fill(Path(CGRect(x: x, y: 26.2, width: 7.2, height: 8.2)), with: .color(Self.paper))
            for row in 0..<3 {
                context.fill(Path(CGRect(x: x + 1.2, y: 28 + CGFloat(row) * 2, width: 4.8, height: 0.9)),
                             with: .color(Color(white: 0.55)))
            }
        }
        let turning = t.truncatingRemainder(dividingBy: 3.5)
        if turning < 0.5 {
            let width = 7.2 * cos(turning / 0.5 * .pi)
            context.fill(Path(CGRect(x: min(25, 25 + width), y: 26.2, width: abs(width), height: 8.2)),
                         with: .color(Color(white: 0.8)))
        }
    }

    /// Reading an audiobook, it stops now and then to think it over: 0 reading, 1 lost in
    /// thought. Every 11 s, for 4 of them.
    private var pondering: CGFloat {
        Self.during(time.truncatingRemainder(dividingBy: 11), 6.5, 10.5, ease: 0.6)
    }

    /// What it's thinking over, as far as `showing` (0...1): a thought cloud rising from its
    /// head in puffs, the book's cover in it (or, with none, an ellipsis).
    private func musings(_ image: NSImage?, in space: GraphicsContext, showing: CGFloat) {
        guard showing > 0.01 else { return }
        var faded = space
        faded.opacity *= Double(showing)
        // All of it drawn together and then faded, so its circles run together into one cloud.
        faded.drawLayer { context in
            let puffs: [(CGFloat, CGFloat, CGFloat)] = [(43, 14, 1.3), (47.5, 9.5, 1.9)]
            let cloud: [(CGFloat, CGFloat, CGFloat)] = [(55, 14, 5.5), (61, 9.5, 6.5), (68.5, 10.5, 6), (72, 16, 5), (63, 17.5, 6)]
            let shapes = (puffs + cloud).map { Self.circle(CGPoint(x: $0.0, y: $0.1), $0.2) }
            // Outlined all round first, so on a light menu bar it shows, and then filled over.
            if let outline { for shape in shapes { context.stroke(shape, with: .color(outline), lineWidth: 1.4) } }
            for shape in shapes { context.fill(shape, with: .color(Color(white: 0.94))) }
            let box = CGRect(x: 57.5, y: 8, width: 11, height: 11)
            if let image {
                var art = context
                art.clip(to: Path(roundedRect: box, cornerRadius: 1.6))
                art.draw(Image(nsImage: image), in: box)
            } else {
                for index in 0..<3 {
                    context.fill(Self.circle(CGPoint(x: box.minX + 1.5 + CGFloat(index) * 4, y: box.midY), 1.1), with: .color(Color(white: 0.4)))
                }
            }
        }
    }

    // Sipping

    /// How far it's lifted its mug to drink, 0...1: a sip every 4 s.
    private func sipping(at t: TimeInterval) -> CGFloat {
        Self.during(t.truncatingRemainder(dividingBy: 4), 2.3, 3.7, ease: 0.4)
    }

    private func mugHand(at t: TimeInterval) -> CGPoint {
        Self.mix(CGPoint(x: 31, y: 30), CGPoint(x: 23.5, y: 27), sipping(at: t))
    }

    /// A mug of something hot, steaming while it isn't drinking.
    private func mug(in context: GraphicsContext, at t: TimeInterval) {
        let hand = mugHand(at: t)
        let cup = CGRect(x: hand.x - 1.5, y: hand.y - 5.5, width: 5.5, height: 6.2)
        context.stroke(Path(ellipseIn: CGRect(x: cup.maxX - 1.6, y: cup.minY + 1.2, width: 3.6, height: 3.4)),
                       with: .color(Self.blue), lineWidth: 1.2)
        context.fill(Path(roundedRect: cup, cornerRadius: 1.2), with: .color(Self.blue))
        guard sipping(at: t) < 0.2 else { return }
        for index in 0..<2 {
            let x = cup.minX + 1.5 + CGFloat(index) * 2.5, sway = 2 * sin(time * 3 + Double(index) * 2)
            var steam = Path()
            steam.move(to: CGPoint(x: x, y: cup.minY - 1))
            steam.addCurve(to: CGPoint(x: x, y: cup.minY - 8),
                           control1: CGPoint(x: x + sway, y: cup.minY - 3.5), control2: CGPoint(x: x - sway, y: cup.minY - 6))
            context.stroke(steam, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        }
    }

    // Dancing

    /// Music notes floating up and away as it dances.
    private func notes(in context: GraphicsContext, from start: CGPoint = CGPoint(x: 50, y: 36), rise: CGFloat = 24) {
        for index in 0..<2 {
            let phase = CGFloat((time / 2.6 + Double(index) / 2).truncatingRemainder(dividingBy: 1))
            let head = CGPoint(x: start.x + 30 * phase, y: start.y - rise * phase + 2 * sin(phase * 9))
            var faded = context
            faded.opacity *= Double(sin(phase * .pi))
            faded.fill(Path(ellipseIn: CGRect(x: head.x - 2, y: head.y - 1.5, width: 4, height: 3)), with: .color(.white))
            var stem = Path()
            stem.move(to: CGPoint(x: head.x + 1.6, y: head.y - 0.4))
            stem.addLine(to: CGPoint(x: head.x + 1.6, y: head.y - 8))
            stem.addQuadCurve(to: CGPoint(x: head.x + 4.8, y: head.y - 4), control: CGPoint(x: head.x + 4.6, y: head.y - 6.6))
            faded.stroke(stem, with: .color(.white), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Oyl's own jobs

/// One of Oyl's own jobs for an Oyl, besides running an agent.
enum OylDuty: Equatable {
    /// In headphones, by the song's cover and a little visualizer, bopping its head to the beat;
    /// with the lyrics showing, singing along into a microphone too. For an audiobook, reading
    /// it instead, looking up now and then to think it over.
    case music(cover: NSImage?, listening: Listening)

    /// How it takes what's playing.
    enum Listening: Equatable {
        case dj, singing, reading
    }
    /// By a clock filling in as time goes, deepening to blue.
    case timer(ReminderTimer)
    /// Sea green and jittery, on energy drinks; with a stopwatch for a set time, or binoculars when
    /// it's watching for an app to quit.
    case awake(AwakeManager.Mode)
    /// Grey and slumped by an empty battery; perking up, plugged in, as it fills.
    case battery(PowerStatus)
    /// In its pajamas with a candle, then in bed.
    case bedtime(BedtimeStage)
    /// Holding up the selfie just taken.
    case selfie(NSImage)
    /// Taking notes on a meeting for an app (Granola) that's listening in: a notepad in one hand,
    /// scribbling away with the other, looking up now and then at what's being said.
    case notes(app: String)

    /// Its color for the job, if not white.
    func skin(at date: Date) -> Color? {
        switch self {
        case .music:
            return nil
        case .timer(let timer):
            let gone = 1 - timer.fractionLeft(at: date)
            return Oyl.timer(gone)
        case .awake:
            return Oyl.seafoam
        case .battery(.tired):
            return Oyl.tired
        case .battery(.recharging(let percent)):
            // Greening up as it fills.
            let full = CGFloat(min(max(Double(percent) / Double(PowerWatcher.recovered), 0), 1))
            return Color(red: 0.8 - 0.2 * full, green: 0.82 + 0.11 * full, blue: 0.86 - 0.18 * full)
        case .bedtime, .selfie:
            return nil
        case .notes:
            return Oyl.sage
        }
    }
}

extension Oyl {
    static let noteYellow = Color(red: 1, green: 0.86, blue: 0.36)
    /// Taking notes: a sage Oyl, its notepad bound in green.
    static let sage = Color(red: 0.8, green: 0.9, blue: 0.72)
    static let notesGreen = Color(red: 0.42, green: 0.72, blue: 0.36)
    /// A timer's blue: clear of staying awake's sea green and Claude's orange.
    static let timerBlue = Color(red: 0.28, green: 0.56, blue: 1)

    /// A timer's Oyl, `gone` (0...1) of the way through: white, deepening to blue.
    static func timer(_ gone: Double) -> Color {
        Color(red: 0.96 - 0.66 * gone, green: 0.96 - 0.38 * gone, blue: 0.96 + 0.04 * gone)
    }
    static let tired = Color(red: 0.8, green: 0.82, blue: 0.86)
    static let pajamas = Color(red: 0.74, green: 0.66, blue: 1)
}

extension OylDrawing {
    /// At one of the app's own jobs: Oyl on the left, as at work, its things to the right.
    func perform(_ duty: OylDuty) {
        let date = Date(timeIntervalSinceReferenceDate: time)
        var pose = restingPose()
        var x: CGFloat = 6
        switch duty {
        case .music(_, .reading):
            // Sat with the book, lowering it a little to think.
            Self.sit(&pose)
            let musing = pondering
            pose.hands = (CGPoint(x: 18, y: 31 + 3 * musing), CGPoint(x: 32, y: 31 + 3 * musing))
            pose.look = Self.mix(CGPoint(x: 0.15 + 0.3 * sin(time * 1.3), y: 0.9), CGPoint(x: 0.65, y: -0.45), musing)
        case .music(_, let listening):
            pose = self.pose(for: .dance, at: 0)
            if listening == .singing { pose.hands.1 = CGPoint(x: 23, y: 26) }  // the mic at its mouth
        case .timer(let timer):
            pose.look = CGPoint(x: 0.9, y: 0.2)  // at the clock
            if !timer.isRunning {
                Self.sit(&pose)
            } else if timer.fractionLeft(at: date) < 0.1 {
                // Nearly time: hopping, arms up.
                pose.lift += abs(sin(time * .pi * 2.4)) * 4
                pose.hands = (CGPoint(x: 9, y: 24), CGPoint(x: 31, y: 24))
            } else {
                // Tapping its foot.
                pose.feet.1 = CGPoint(x: 31, y: 37 - 2.5 * max(0, sin(time * 2 * .pi * 1.4)))
            }
        case .awake(let mode):
            pose.lid = 0.08  // wide awake
            x += 0.6 * sin(time * 53) + 0.4 * sin(time * 31)  // can't keep still
            if case .whileRunning = mode {
                pose.hands = (CGPoint(x: 13, y: 21), CGPoint(x: 27, y: 21))  // binoculars up
                pose.look = CGPoint(x: 0.6 * sin(time * 0.8), y: 0)
            } else {
                pose.hands.1 = canHand
                if case .until = mode { pose.hands.0 = CGPoint(x: 9, y: 27) }  // its stopwatch
            }
        case .battery(.tired):
            // Slumped, lids heavy, breathing slow.
            Self.sit(&pose)
            pose.lid = 0.62
            pose.squash = 0.96 + 0.02 * sin(time * 2 * .pi / 5)
            pose.hands = (CGPoint(x: 13, y: 35), CGPoint(x: 27, y: 35))
            pose.look = CGPoint(x: 0.3, y: 0.7)
            pose.eyesClosed = time.truncatingRemainder(dividingBy: 4) < 0.9  // nodding off
        case .battery(.recharging(let percent)):
            // Perkier as it fills, holding the cable.
            pose.lid = 0.5 - 0.35 * CGFloat(min(Double(percent) / Double(PowerWatcher.recovered), 1))
            pose.lift += abs(sin(time * .pi * 1.2)) * 1.2
            pose.hands.1 = CGPoint(x: 32, y: 30)
            pose.look = CGPoint(x: 0.9, y: 0.3)
        case .bedtime(.candle):
            pose.lid = 0.5
            pose.hands.1 = CGPoint(x: 31, y: 29)
            pose.look = CGPoint(x: 0.5 * sin(time * 0.4), y: 0.2)
            pose.eyesClosed = time.truncatingRemainder(dividingBy: 9) < 1.2  // a yawn
        case .bedtime(let stage):
            // In bed: asleep, or sat up waving at you to come too.
            Self.sit(&pose)
            if stage == .remind {
                pose.lid = 0.2
                pose.hands.1 = CGPoint(x: 33 + 2 * sin(time * 2 * .pi * 1.6), y: 15)
                pose.look = CGPoint(x: 0, y: 0.3)
            } else {
                pose.eyesClosed = true
                pose.squash = 1 + 0.04 * sin(time * 2 * .pi / 4.5)
            }
        case .selfie:
            pose.hands = (CGPoint(x: 31, y: 31), CGPoint(x: 37, y: 31))
            pose.look = CGPoint(x: 0, y: 0.35)  // at you, proud
        case .notes:
            // Its pad held up, scribbling away, and now and then looking up at what's being said.
            pose.hands = (Self.padHand, pencil)
            pose.look = Self.mix(CGPoint(x: 0.55, y: 0.7), CGPoint(x: 0.95, y: -0.2), listening)
        }
        let space = self.space
        let body = body(in: space, at: x, pose: pose)
        drawOyl(in: body, pose: pose, hat: false)
        switch duty {
        case .music(let image, .reading):
            let musing = pondering
            var held = body
            held.translateBy(x: 0, y: 3 * musing)
            book(in: held, at: musing > 0 ? 1 : time)  // no page turning while it thinks
            musings(image, in: space, showing: musing)
        case .music(let image, let listening):
            headphones(in: headContext(in: body, pose: pose))
            if listening == .singing { microphone(in: body, hand: pose.hands.1) }
            cover(image, in: space, at: CGRect(x: 50, y: 10, width: 34, height: 34))
            visualizer(in: space, at: CGRect(x: 87, y: 20, width: 12, height: 24))
        case .timer(let timer):
            clock(in: space, at: CGPoint(x: 70, y: 28), radius: 11, timer: timer, date: date)
        case .awake(let mode):
            awakeProps(in: body, mode: mode, pose: pose)
            buzz(in: space, around: x)
        case .battery(let status):
            battery(in: space, status: status)
            if case .recharging = status { cable(in: space, from: CGPoint(x: x + pose.hands.1.x, y: 3 - pose.lift + pose.hands.1.y)) }
        case .bedtime(.candle):
            pajamas(in: body, pose: pose)
            candle(in: body, hand: pose.hands.1)
        case .bedtime(let stage):
            bed(in: space, under: body, pose: pose)
            if stage == .bed { snores(in: space) }
        case .selfie(let image):
            polaroid(in: space, at: CGRect(x: 43, y: 3, width: 28, height: 33), image: image)
            sparkles(in: space)
        case .notes:
            notepad(in: body, writing: writing, pencil: pose.hands.1)
            hearing(in: space)
        }
    }

    /// Walking along the menu bar, carrying its things.
    func walk(facingRight: Bool, hat: Bool, carrying duty: OylDuty?) {
        var pose = pose(for: .idle, walking: true, surfing: false)
        switch duty {
        case .music(_, .reading)?:
            // Its nose in the book.
            pose.hands = (CGPoint(x: 18, y: 31), CGPoint(x: 32, y: 31))
            pose.look = CGPoint(x: 0.3, y: 0.9)
        case .music(_, let listening)?:
            pose.hands.0 = CGPoint(x: 5, y: 31)  // reaching back for the string
            if listening == .singing { pose.hands.1 = CGPoint(x: 23, y: 26) }  // and the mic at its mouth
        case .awake(let mode)?:
            pose.lid = 0.08
            if case .whileRunning = mode { pose.hands = (CGPoint(x: 13, y: 21), CGPoint(x: 27, y: 21)) }
        case .battery(.tired)?:
            pose.lid = 0.62
            pose.lift -= 1.5  // dragging its feet
        case .bedtime?:
            pose.lid = 0.5
        case .notes?:
            pose.hands.0 = Self.padHand
        default:
            break
        }
        let body = body(in: space, at: 30, pose: pose, mirrored: !facingRight)
        drawOyl(in: body, pose: pose, hat: hat)
        switch duty {
        case .music(_, .reading)?:
            book(in: body, at: time)
        case .music(let image, let listening)?:
            headphones(in: headContext(in: body, pose: pose))
            if listening == .singing { microphone(in: body, hand: pose.hands.1) }
            // Its cover and visualizer dragged along the bar behind it on a string, bumping as they
            // go (past the edges of its drawing, which on the menu bar is all one canvas).
            let behind: CGFloat = facingRight ? -1 : 1
            let hand = CGPoint(x: 50 + behind * (20 - pose.hands.0.x), y: 3 - pose.lift + pose.hands.0.y)
            let bump = abs(sin(time * pace * 2 * .pi * 1.8)) * 0.8
            let near = hand.x + behind * 5
            let box = CGRect(x: facingRight ? near - 34 : near, y: 10 - bump, width: 34, height: 34)
            cover(image, in: space, at: box)
            visualizer(in: space, at: CGRect(x: facingRight ? box.minX - 15 : box.maxX + 3, y: 20 - bump, width: 12, height: 24))
            let corner = CGPoint(x: facingRight ? box.maxX : box.minX, y: box.minY + 8)
            var string = Path()
            string.move(to: hand)
            string.addQuadCurve(to: corner, control: CGPoint(x: (hand.x + corner.x) / 2, y: max(hand.y, corner.y) + 3))
            space.stroke(string, with: .color(Color(white: 0.3)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        case .timer(let timer)?:
            clock(in: body, at: CGPoint(x: pose.hands.1.x + 2, y: pose.hands.1.y - 3.5), radius: 4.5, timer: timer,
                  date: Date(timeIntervalSinceReferenceDate: time))
        case .awake(let mode)?:
            awakeProps(in: body, mode: mode, pose: pose)
        case .bedtime?:
            pajamas(in: body, pose: pose)
            candle(in: body, hand: pose.hands.1)
        case .selfie(let image)?:
            polaroid(in: body, at: CGRect(x: pose.hands.1.x - 3, y: pose.hands.1.y - 13, width: 11, height: 13), image: image)
        case .notes?:
            notepad(in: body, writing: 2.6, pencil: nil)
        case .battery?, nil:
            break
        }
    }

    /// Its job's done: jumping for joy, arms up, eyes shut tight. It's at the top of the screen,
    /// so it crouches between hops rather than jumping out of sight.
    func cheer(hat: Bool, since: TimeInterval, length: TimeInterval) {
        var pose = restingPose()
        let hop = abs(sin(min(since / length, 1) * 3 * .pi))  // three of them
        pose.lift = -4 + 7 * hop
        pose.squash = 0.9 + 0.14 * hop
        pose.hands = (CGPoint(x: 6, y: 15 + 5 * (1 - hop)), CGPoint(x: 34, y: 15 + 5 * (1 - hop)))
        pose.eyesClosed = true
        drawOyl(in: body(in: space, at: 30, pose: pose), pose: pose, hat: hat)
    }

    /// Going: waving goodbye at you, `wave` (0…1) through it.
    func goodbye(hat: Bool, wave: Double) {
        var pose = restingPose()
        let up = Self.during(wave, 0, 1, ease: 0.2)
        pose.hands.1 = Self.mix(pose.hands.1, CGPoint(x: 36 + 3 * sin(wave * 2 * .pi * 2.5), y: 15), up)
        pose.look = Self.mix(.zero, CGPoint(x: 0, y: 0.3), up)
        drawOyl(in: body(in: space, at: 30, pose: pose), pose: pose, hat: hat)
    }

    /// Going: springing up off the bar, `hop` (0…1) how far up, crouching between. (It's at the
    /// top of the screen, as cheering, so it springs no higher than the bar.)
    func hopOff(hat: Bool, hop: CGFloat) {
        var pose = Pose()
        pose.lift = -3 + 6 * hop
        pose.squash = 0.86 + 0.2 * hop
        pose.hands = (CGPoint(x: 9, y: 25 + 6 * (1 - hop)), CGPoint(x: 31, y: 25 + 6 * (1 - hop)))
        if hop > 0.3 { pose.feet = (CGPoint(x: 16, y: 42), CGPoint(x: 24, y: 42)) }
        drawOyl(in: body(in: space, at: 30, pose: pose), pose: pose, hat: hat)
    }

    // The song

    /// Headphones over its spikes: the band arched across the top of its head, a cup either side.
    private func headphones(in head: GraphicsContext) {
        var band = Path()
        band.addArc(center: CGPoint(x: 20, y: 16), radius: 13, startAngle: .degrees(190), endAngle: .degrees(350), clockwise: false)
        if let outline { head.stroke(band, with: .color(outline), style: StrokeStyle(lineWidth: 4, lineCap: .round)) }
        head.stroke(band, with: .color(Color(white: 0.32)), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        for x: CGFloat in [5.5, 29.5] {
            let cup = Path(roundedRect: CGRect(x: x, y: 12.5, width: 5, height: 9.5), cornerRadius: 2.2)
            if let outline { head.stroke(cup, with: .color(outline), lineWidth: 1.4) }
            head.fill(cup, with: .color(Color(white: 0.17)))
            head.fill(Path(roundedRect: CGRect(x: x + 1.2, y: 14.3, width: 2.6, height: 5.9), cornerRadius: 1.2),
                      with: .color(Color(white: 0.42)))
        }
    }

    /// The song's cover, or where there's none, a record.
    private func cover(_ image: NSImage?, in context: GraphicsContext, at box: CGRect) {
        let shape = Path(roundedRect: box, cornerRadius: box.width * 0.12)
        if let image {
            var art = context
            art.clip(to: shape)
            art.draw(Image(nsImage: image), in: box)
        } else {
            context.fill(shape, with: .color(Color(white: 0.2)))
            let center = CGPoint(x: box.midX, y: box.midY)
            context.fill(Self.circle(center, box.width * 0.38), with: .color(Color(white: 0.07)))
            context.fill(Self.circle(center, box.width * 0.11), with: .color(Oyl.hatOrange))
        }
        context.stroke(shape, with: .color(.white.opacity(0.25)), lineWidth: box.width * 0.04)
    }

    /// A little visualizer: four bars, bass to treble, rising with the song (or, until its sound
    /// comes through, on their own).
    private func visualizer(in context: GraphicsContext, at box: CGRect) {
        let live = bars.count == 4 && bars.contains { $0 > 0.01 }
        let width = box.width / (4 + 3 * 0.7)
        for index in 0..<4 {
            let level = live ? CGFloat(bars[index]) : CGFloat(0.3 + 0.25 * sin(time * (5 + Double(index)) + Double(index) * 1.7))
            let height = max(width, box.height * min(max(level, 0), 1))
            let bar = Path(roundedRect: CGRect(x: box.minX + CGFloat(index) * width * 1.7, y: box.maxY - height, width: width, height: height),
                           cornerRadius: width / 2)
            // Outlined like Oyl on the menu bar, so they show on a light one too.
            if let outline { context.stroke(bar, with: .color(outline), lineWidth: 1.4) }
            context.fill(bar, with: .color(.white.opacity(0.9)))
        }
    }

    // Clock

    /// An alarm clock, the time that's gone filled in blue around its face.
    private func clock(in context: GraphicsContext, at center: CGPoint, radius r: CGFloat, timer: ReminderTimer, date: Date) {
        let gone = 1 - timer.fractionLeft(at: date)
        let metal = Color(white: 0.42)
        for side: CGFloat in [-1, 1] {
            context.fill(Self.circle(CGPoint(x: center.x + side * r * 0.62, y: center.y - r * 0.9), r * 0.34), with: .color(metal))
            var leg = Path()
            leg.move(to: CGPoint(x: center.x + side * r * 0.45, y: center.y + r * 0.8))
            leg.addLine(to: CGPoint(x: center.x + side * r * 0.72, y: center.y + r * 1.2))
            context.stroke(leg, with: .color(metal), style: StrokeStyle(lineWidth: r * 0.16, lineCap: .round))
        }
        context.fill(Self.circle(center, r), with: .color(Color(white: 0.95)))
        if gone > 0 {
            var wedge = Path()
            wedge.move(to: center)
            wedge.addArc(center: center, radius: r * 0.86, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * gone),
                         clockwise: false)
            wedge.closeSubpath()
            context.fill(wedge, with: .color(Oyl.timerBlue.opacity(0.85)))
        }
        context.stroke(Self.circle(center, r), with: .color(metal), lineWidth: r * 0.16)
        hand(in: context, at: center, angle: CGFloat((gone - 0.25) * 2 * .pi), length: r * 0.72, width: r * 0.12)
    }

    private func hand(in context: GraphicsContext, at center: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat) {
        var hand = Path()
        hand.move(to: center)
        hand.addLine(to: CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
        context.stroke(hand, with: .color(Self.ink), style: StrokeStyle(lineWidth: width, lineCap: .round))
        context.fill(Self.circle(center, width), with: .color(Self.ink))
    }

    // Notepad

    /// Where it holds its notepad up, in front of it.
    private static let padHand = CGPoint(x: 25, y: 35)
    /// The pad tipped back a little, as it's held.
    private static let padTilt = -8 * CGFloat.pi / 180
    private static let padLines = 4

    /// How much it's written on the page: a line at a time, then a fresh page (with a pause
    /// while it looks up, every so often).
    private var writing: Double {
        (time * 0.85).truncatingRemainder(dividingBy: Double(Self.padLines) + 1.2)
    }

    /// 0...1, looking up from its notes at what's being said, every seven seconds or so.
    private var listening: CGFloat {
        Self.during(time.truncatingRemainder(dividingBy: 7.3), 4.6, 6.2, ease: 0.35)
    }

    /// A point on the pad (from its top left, as written on), where it is in its 40 × 44 box.
    private static func onPad(_ point: CGPoint) -> CGPoint {
        CGPoint(x: padHand.x + point.x * cos(padTilt) - point.y * sin(padTilt),
                y: padHand.y + point.x * sin(padTilt) + point.y * cos(padTilt))
    }

    /// Where its pencil is: along the line it's on, wobbling as it writes.
    private var pencil: CGPoint {
        let line = min(Int(writing), Self.padLines - 1)
        let along = Double(line) < writing.rounded(.down) ? 1 : writing - Double(line)
        let width = line == Self.padLines - 1 ? 6.5 : 9.5
        let tip = Self.onPad(CGPoint(x: -0.2 + 1.8 + width * along, y: -13 + 4.8 + CGFloat(line) * 2.8 + 0.8 * sin(time * 31)))
        return CGPoint(x: tip.x + 2.4, y: tip.y + 3.6 * (1 - listening))
    }

    /// The notepad held up, bound in green, its lines written in as it goes; and with `pencil`,
    /// the pencil in its other hand.
    private func notepad(in context: GraphicsContext, writing: Double, pencil: CGPoint?) {
        var pad = context
        pad.translateBy(x: Self.padHand.x, y: Self.padHand.y)
        pad.rotate(by: .radians(Self.padTilt))
        let sheet = CGRect(x: -2, y: -13, width: 13.5, height: 16)
        pad.fill(Path(roundedRect: sheet, cornerRadius: 1.5), with: .color(Self.paper))
        pad.fill(Path(roundedRect: CGRect(x: sheet.minX, y: sheet.minY, width: sheet.width, height: 2.8), cornerRadius: 1.2),
                 with: .color(Oyl.notesGreen))
        for row in 0..<Self.padLines {
            let filled = min(max(writing - Double(row), 0), 1)
            guard filled > 0 else { continue }
            let width = (row == Self.padLines - 1 ? 6.5 : 9.5) * filled
            pad.fill(Path(CGRect(x: sheet.minX + 1.8, y: sheet.minY + 4.8 + CGFloat(row) * 2.8, width: width, height: 0.9)),
                     with: .color(Color(white: 0.38)))
        }
        guard let pencil else { return }
        // Held in its hand, its point on the paper (lifted while it listens).
        let tip = CGPoint(x: pencil.x - 2.4, y: pencil.y - 3.6)
        var stick = Path()
        stick.move(to: CGPoint(x: pencil.x + 1.6, y: pencil.y + 1.8))
        stick.addLine(to: tip)
        context.stroke(stick, with: .color(Oyl.noteYellow), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
        context.fill(Path(ellipseIn: CGRect(x: tip.x - 0.8, y: tip.y - 0.8, width: 1.6, height: 1.6)), with: .color(Color(white: 0.25)))
    }

    /// What's being said, coming in from the right: rings of sound spreading its way, one after
    /// another.
    private func hearing(in context: GraphicsContext) {
        let center = CGPoint(x: 88, y: 24)
        for ring in 0..<3 {
            let phase = CGFloat((time / 1.8 + Double(ring) / 3).truncatingRemainder(dividingBy: 1))
            let radius = 3 + 11 * phase
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(140), endAngle: .degrees(220), clockwise: false)
            context.stroke(arc, with: .color(.white.opacity(0.75 * Double(sin(phase * .pi)))),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        context.fill(Path(ellipseIn: CGRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2)),
                     with: .color(.white.opacity(0.5)))
    }

    // Energy drink

    /// Where its hand is with the can: up for a swig every 3 s or so.
    private var canHand: CGPoint {
        let swig = Self.during(time.truncatingRemainder(dividingBy: 3.2), 1.8, 2.8, ease: 0.25)
        return Self.mix(CGPoint(x: 31, y: 30), CGPoint(x: 24, y: 25), swig)
    }

    /// The can (and a stopwatch for a set time), or binoculars when watching for an app to quit.
    private func awakeProps(in context: GraphicsContext, mode: AwakeManager.Mode, pose: Pose) {
        if case .whileRunning = mode {
            for eye in [CGPoint(x: 14.9, y: 18), CGPoint(x: 25.1, y: 18)] {
                context.fill(Self.circle(eye, 4.1), with: .color(Color(white: 0.18)))
                context.fill(Self.circle(eye, 2.6), with: .color(Self.blue.opacity(0.85)))
                context.fill(Self.circle(CGPoint(x: eye.x - 0.9, y: eye.y - 0.9), 0.8), with: .color(.white.opacity(0.8)))
            }
            context.fill(Path(CGRect(x: 18.5, y: 16.8, width: 3, height: 2.4)), with: .color(Color(white: 0.18)))
            return
        }
        can(in: context, hand: pose.hands.1)
        if case .until = mode {
            // A stopwatch, its hand going round.
            let center = CGPoint(x: pose.hands.0.x - 0.5, y: pose.hands.0.y - 3.5)
            context.fill(Path(CGRect(x: center.x - 0.7, y: center.y - 5.4, width: 1.4, height: 1.6)), with: .color(Color(white: 0.6)))
            context.fill(Self.circle(center, 3.8), with: .color(Color(white: 0.95)))
            context.stroke(Self.circle(center, 3.8), with: .color(AwakePage.tint), lineWidth: 0.9)
            hand(in: context, at: center, angle: CGFloat(time.truncatingRemainder(dividingBy: 5) / 5 * 2 * .pi - .pi / 2),
                 length: 2.8, width: 0.55)
        }
    }

    /// An energy drink, with a lightning bolt on it.
    private func can(in context: GraphicsContext, hand: CGPoint) {
        let can = CGRect(x: hand.x - 1.2, y: hand.y - 7.5, width: 4.6, height: 8.5)
        context.fill(Path(roundedRect: can, cornerRadius: 1), with: .color(Color(white: 0.16)))
        context.fill(Path(CGRect(x: can.minX, y: can.minY + 0.8, width: can.width, height: 0.8)), with: .color(Color(white: 0.7)))
        var bolt = Path()
        bolt.move(to: CGPoint(x: can.midX + 0.9, y: can.minY + 2.4))
        bolt.addLine(to: CGPoint(x: can.midX - 0.9, y: can.midY + 0.8))
        bolt.addLine(to: CGPoint(x: can.midX + 0.6, y: can.midY + 0.8))
        bolt.addLine(to: CGPoint(x: can.midX - 0.9, y: can.maxY - 1))
        context.stroke(bolt, with: .color(AwakePage.tint), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
    }

    /// Little lines buzzing either side of its head.
    private func buzz(in context: GraphicsContext, around x: CGFloat) {
        guard Int(time * 5) % 2 == 0 else { return }
        for (edge, out) in [(x - 2, CGFloat(-1)), (x + 42, 1)] {
            var lines = Path()
            lines.move(to: CGPoint(x: edge, y: 13))
            lines.addLine(to: CGPoint(x: edge + out * 2.5, y: 10))
            lines.move(to: CGPoint(x: edge, y: 18))
            lines.addLine(to: CGPoint(x: edge + out * 3, y: 18))
            context.stroke(lines, with: .color(Oyl.seafoam), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    fileprivate static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    }
}

// MARK: - Battery, bedtime, selfies and songs

extension OylDrawing {
    /// The battery beside it: low and red, or filling green with a bolt.
    private func battery(in context: GraphicsContext, status: PowerStatus) {
        let shell = CGRect(x: 56, y: 22, width: 22, height: 12)
        context.stroke(Path(roundedRect: shell, cornerRadius: 2.5), with: .color(Color(white: 0.75)), lineWidth: 1.4)
        context.fill(Path(roundedRect: CGRect(x: shell.maxX + 0.8, y: shell.midY - 2.5, width: 2, height: 5), cornerRadius: 0.8),
                     with: .color(Color(white: 0.75)))
        let inner = shell.insetBy(dx: 2, dy: 2)
        switch status {
        case .tired(let percent):
            let blink = Int(time * 1.5) % 2 == 0 ? 1.0 : 0.45
            context.fill(Path(roundedRect: CGRect(x: inner.minX, y: inner.minY, width: max(inner.width * CGFloat(percent) / 100, 1.5),
                                                  height: inner.height), cornerRadius: 1),
                         with: .color(Color(red: 1, green: 0.36, blue: 0.32).opacity(blink)))
        case .recharging(let percent):
            // Filling, a shimmer running along it.
            let level = CGFloat(percent) / 100
            context.fill(Path(roundedRect: CGRect(x: inner.minX, y: inner.minY, width: inner.width * level, height: inner.height),
                              cornerRadius: 1), with: .color(Color(red: 0.4, green: 0.88, blue: 0.5)))
            let shimmer = CGFloat(time.truncatingRemainder(dividingBy: 1.4) / 1.4) * inner.width * level
            context.fill(Path(CGRect(x: inner.minX + shimmer - 1, y: inner.minY, width: 2, height: inner.height)), with: .color(.white.opacity(0.5)))
            var bolt = Path()
            bolt.move(to: CGPoint(x: shell.midX + 1.6, y: shell.minY + 1.4))
            bolt.addLine(to: CGPoint(x: shell.midX - 2.2, y: shell.midY + 0.6))
            bolt.addLine(to: CGPoint(x: shell.midX + 0.6, y: shell.midY + 0.6))
            bolt.addLine(to: CGPoint(x: shell.midX - 1.6, y: shell.maxY - 1.4))
            context.stroke(bolt, with: .color(Oyl.noteYellow), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
    }

    /// The charging cable, from its hand round to the battery.
    private func cable(in context: GraphicsContext, from hand: CGPoint) {
        var cable = Path()
        cable.move(to: hand)
        cable.addCurve(to: CGPoint(x: 56, y: 28), control1: CGPoint(x: hand.x + 6, y: 46), control2: CGPoint(x: 48, y: 40))
        context.stroke(cable, with: .color(Color(white: 0.7)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }

    /// Striped pajamas, and a droopy nightcap.
    private func pajamas(in context: GraphicsContext, pose: Pose) {
        let stripe = Oyl.pajamas
        for (hip, foot) in [(CGPoint(x: 17, y: 33), pose.feet.0), (CGPoint(x: 23, y: 33), pose.feet.1)] {
            var leg = Path()
            leg.move(to: hip)
            leg.addLine(to: CGPoint(x: hip.x + (foot.x - hip.x) * 0.75, y: hip.y + (foot.y - hip.y) * 0.75))
            context.stroke(leg, with: .color(stripe), style: StrokeStyle(lineWidth: 3.8, lineCap: .round))
        }
        let belly = Path(ellipseIn: CGRect(x: 14, y: 24, width: 12, height: 11))
        context.fill(belly, with: .color(stripe.opacity(0.55)))
        var stripes = context
        stripes.clip(to: belly)
        for row in 0..<4 {
            stripes.fill(Path(CGRect(x: 13, y: 25 + CGFloat(row) * 2.8, width: 14, height: 1.2)), with: .color(stripe))
        }
        var cap = Path()
        cap.move(to: CGPoint(x: 10.5, y: 8.4))
        cap.addQuadCurve(to: CGPoint(x: 26, y: 3), control: CGPoint(x: 15, y: -2))
        cap.addQuadCurve(to: CGPoint(x: 35, y: 12), control: CGPoint(x: 33, y: 2))
        cap.addQuadCurve(to: CGPoint(x: 29.5, y: 8.6), control: CGPoint(x: 31, y: 8))
        cap.closeSubpath()
        context.fill(cap, with: .color(stripe))
        context.fill(Path(roundedRect: CGRect(x: 9.6, y: 7.4, width: 20.8, height: 2.8), cornerRadius: 1.4), with: .color(.white.opacity(0.9)))
        context.fill(Self.circle(CGPoint(x: 35, y: 12.5), 1.9), with: .color(.white))
    }

    /// A candle in its hand, flickering, with a warm glow round it.
    private func candle(in context: GraphicsContext, hand: CGPoint) {
        let flicker = CGFloat(0.85 + 0.15 * sin(time * 17) * sin(time * 7.3))
        let flame = CGPoint(x: hand.x + 1, y: hand.y - 10)
        context.fill(Self.circle(flame, 10 * flicker), with: .radialGradient(
            Gradient(colors: [Oyl.noteYellow.opacity(0.55), Oyl.noteYellow.opacity(0)]), center: flame, startRadius: 0, endRadius: 10 * flicker))
        context.fill(Path(roundedRect: CGRect(x: hand.x - 3, y: hand.y - 1, width: 8, height: 2), cornerRadius: 1), with: .color(Color(white: 0.55)))
        context.fill(Path(CGRect(x: hand.x - 0.4, y: hand.y - 8, width: 2.8, height: 7.5)), with: .color(Color(white: 0.97)))
        var drop = Path()
        drop.move(to: CGPoint(x: flame.x, y: flame.y - 4.4 * flicker))
        drop.addQuadCurve(to: CGPoint(x: flame.x, y: flame.y + 2), control: CGPoint(x: flame.x + 3.2, y: flame.y))
        drop.addQuadCurve(to: CGPoint(x: flame.x, y: flame.y - 4.4 * flicker), control: CGPoint(x: flame.x - 3.2, y: flame.y))
        context.fill(drop, with: .color(Color(red: 1, green: 0.62, blue: 0.2)))
        context.fill(Self.circle(CGPoint(x: flame.x, y: flame.y + 0.4), 0.9), with: .color(Oyl.noteYellow))
    }

    /// A bed: headboard behind, a pillow, and a quilt pulled up over its middle (drawn over
    /// `body`, so it covers it).
    private func bed(in space: GraphicsContext, under body: GraphicsContext, pose: Pose) {
        let wood = Color(red: 0.62, green: 0.45, blue: 0.3)
        space.fill(Path(roundedRect: CGRect(x: 1, y: 22, width: 6, height: 26), cornerRadius: 2), with: .color(wood))
        space.fill(Path(roundedRect: CGRect(x: 56, y: 32, width: 4, height: 16), cornerRadius: 1.5), with: .color(wood))
        space.fill(Path(roundedRect: CGRect(x: 4, y: 38, width: 54, height: 7), cornerRadius: 2), with: .color(Color(white: 0.9)))
        var quilt = Path(roundedRect: CGRect(x: 10, y: 30.5, width: 48, height: 12), cornerRadius: 4)
        quilt.addEllipse(in: CGRect(x: 30, y: 28.5, width: 18, height: 8))  // its feet under it
        space.fill(quilt, with: .color(Oyl.pajamas))
        for column in 0..<4 {
            space.fill(Path(CGRect(x: 14 + CGFloat(column) * 11, y: 31, width: 1, height: 11)), with: .color(.white.opacity(0.35)))
        }
        // Its nightcap, still on.
        var cap = Path()
        cap.move(to: CGPoint(x: 10.5, y: 8.4))
        cap.addQuadCurve(to: CGPoint(x: 26, y: 3), control: CGPoint(x: 15, y: -2))
        cap.addQuadCurve(to: CGPoint(x: 35, y: 12), control: CGPoint(x: 33, y: 2))
        cap.addQuadCurve(to: CGPoint(x: 29.5, y: 8.6), control: CGPoint(x: 31, y: 8))
        cap.closeSubpath()
        body.fill(cap, with: .color(Oyl.pajamas))
        body.fill(Self.circle(CGPoint(x: 35, y: 12.5), 1.9), with: .color(.white))
    }

    /// The selfie, in a polaroid.
    private func polaroid(in context: GraphicsContext, at frame: CGRect, image: NSImage) {
        var tilted = context
        tilted.translateBy(x: frame.midX, y: frame.midY)
        tilted.rotate(by: .degrees(4 * sin(time * 1.4)))
        tilted.translateBy(x: -frame.midX, y: -frame.midY)
        tilted.fill(Path(roundedRect: frame, cornerRadius: 1.5), with: .color(.white))
        let photo = CGRect(x: frame.minX + frame.width * 0.08, y: frame.minY + frame.width * 0.08,
                           width: frame.width * 0.84, height: frame.height * 0.7)
        var inside = tilted
        inside.clip(to: Path(photo))
        let size = image.size
        let fill = max(photo.width / max(size.width, 1), photo.height / max(size.height, 1))
        inside.draw(Image(nsImage: image), in: CGRect(x: photo.midX - size.width * fill / 2, y: photo.midY - size.height * fill / 2,
                                                       width: size.width * fill, height: size.height * fill))
    }

    private func sparkles(in context: GraphicsContext) {
        for (index, spot) in [CGPoint(x: 78, y: 8), CGPoint(x: 40, y: 6), CGPoint(x: 80, y: 30)].enumerated() {
            let twinkle = CGFloat(max(0, sin(time * 3 + Double(index) * 2.1)))
            guard twinkle > 0.05 else { continue }
            var star = Path()
            let r = 2.6 * twinkle
            star.move(to: CGPoint(x: spot.x, y: spot.y - r))
            star.addQuadCurve(to: CGPoint(x: spot.x + r, y: spot.y), control: spot)
            star.addQuadCurve(to: CGPoint(x: spot.x, y: spot.y + r), control: spot)
            star.addQuadCurve(to: CGPoint(x: spot.x - r, y: spot.y), control: spot)
            star.addQuadCurve(to: CGPoint(x: spot.x, y: spot.y - r), control: spot)
            context.fill(star, with: .color(Oyl.noteYellow))
        }
    }

    /// A microphone at its mouth.
    private func microphone(in context: GraphicsContext, hand: CGPoint) {
        var handle = Path()
        handle.move(to: CGPoint(x: hand.x + 1, y: hand.y + 3))
        handle.addLine(to: CGPoint(x: hand.x - 1.5, y: hand.y - 2))
        context.stroke(handle, with: .color(Color(white: 0.2)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        context.fill(Self.circle(CGPoint(x: hand.x - 2.2, y: hand.y - 3.4), 2.3), with: .color(Color(white: 0.55)))
        for row in 0..<2 {
            context.fill(Path(CGRect(x: hand.x - 4, y: hand.y - 4.2 + CGFloat(row) * 1.4, width: 3.6, height: 0.5)),
                         with: .color(Color(white: 0.3)))
        }
    }
}

extension AgentSession {
    /// Its Oyl's hat: Claude's orange always; another agent's own color (or Muse's black) while
    /// it's at work; else none.
    var cap: Color? {
        if isClaude { return Oyl.hatOrange }
        return activity == .idle || activity == .done ? nil : hat ?? Oyl.museBlack
    }
}
