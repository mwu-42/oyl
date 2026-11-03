import AppKit
import SwiftUI

/// The open notch in Midnight Oyl: the band. It runs out of the notch along the menu bar, across
/// the whole top of the screen, and falls into a band of dark glass with the sky engraved on it,
/// its foot flowing and dissolving into the desktop. Under the notch, the usual strip and page, in
/// Midnight's type; across the sky, the hands the camera sees, as a constellation (the camera
/// itself isn't shown, but it's on while the band's up, for the gestures); on the right,
/// the moon, which tells the time (new at midnight, full at noon) and holds the band open until
/// it's clicked again. How deep it is follows the
/// page: the page, and some sky.
struct MidnightNotch: View {
    @ObservedObject var state: NotchState
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var timers: TimerStore
    @ObservedObject var awake: AwakeManager
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var bedtime: Bedtime
    let gestures: GestureWatcher
    let stats: SystemStats

    @StateObject private var opening = BloomOpening()

    /// For NotchView to take it away with: a quick wilt, the bloom folding back up into the notch
    /// as it fades. (It blooms by itself once it's there, so coming in needs nothing.)
    static let transition = AnyTransition.asymmetric(
        insertion: .identity,
        removal: .modifier(active: Wilting(amount: 1), identity: Wilting(amount: 0)).animation(Midnight.wilt))

    /// How many bands are up. A new one can open while the last is still wilting, and the camera
    /// (for the gestures, and the hands' constellation) stays on until both have gone.
    private static var showing = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            BloomGlass(bloom: opening.bloom, reach: opening.reach, size: state.bloomSize, notch: state.metrics.size,
                       page: BloomLayout(state: state, size: state.bloomSize, reach: opening.reach).page)
                .allowsHitTesting(false)
            MidnightBloom(state: state, nowPlaying: nowPlaying, timers: timers, awake: awake, agents: agents,
                          bedtime: bedtime, gestures: gestures, stats: stats, opening: opening)
        }
        // A bloom that's wilting after the look's changed keeps its type.
        .environment(\.notchTheme, .midnight)
        .onAppear {
            Self.showing += 1
            gestures.displaying = true
            opening.start(reach: state.bloomReach)
        }
        .onDisappear {
            Self.showing = max(Self.showing - 1, 0)
            if Self.showing == 0 { gestures.displaying = false }
        }
        .onChange(of: state.bloomReach) { _, reach in opening.reach(reach) }
    }
}

/// The band opening: how far it's spread and fallen, how far the page has come in (once it's
/// mostly open), and how far down it reaches, growing (or folding) from the last reach when the
/// page changes.
@MainActor
final class BloomOpening: ObservableObject {
    @Published private(set) var bloom = 0.0
    @Published private(set) var reveal = 0.0
    @Published private(set) var reach = MidnightArch.full
    /// The reach before the last change, and how far through growing from it (1 at rest): the
    /// room between the two is where the backdrop draws new rings and stars on.
    @Published private(set) var grownFrom = MidnightArch.full
    @Published private(set) var growth = 1.0
    private var target = MidnightArch.full

    /// Blooms straight to the page's reach.
    func start(reach: CGFloat) {
        guard bloom == 0 else { return }
        target = reach
        self.reach = reach
        grownFrom = reach
        withAnimation(Midnight.bloom) { bloom = 1 }
        withAnimation(.easeOut(duration: 0.6).delay(0.5)) { reveal = 1 }
    }

    /// Grows down to a taller page on the bloom's spring, or folds up to a shorter one, quicker.
    func reach(_ reach: CGFloat) {
        guard reach != target else { return }
        let from = target
        target = reach
        var outright = Transaction()
        outright.disablesAnimations = true
        withTransaction(outright) {
            grownFrom = from
            growth = 0
        }
        withAnimation(reach > from ? Midnight.bloom : Midnight.fold) {
            self.reach = reach
            growth = 1
        }
    }
}

/// Everything drawn in the band (all but the glass behind) at a given moment of its opening.
struct MidnightBloom: View {
    @ObservedObject var state: NotchState
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var timers: TimerStore
    @ObservedObject var awake: AwakeManager
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var bedtime: Bedtime
    let gestures: GestureWatcher
    let stats: SystemStats
    @ObservedObject var opening: BloomOpening

    @Environment(\.midnightWilt) private var wilt

    var body: some View {
        let size = state.bloomSize
        let reach = opening.reach
        let layout = BloomLayout(state: state, size: size, reach: reach)
        let open = opening.bloom * (1 - wilt)
        let shown = opening.reveal * (1 - min(wilt * 1.6, 1))
        let notch = state.metrics.size

        ZStack(alignment: .topLeading) {
            Backdrop(bloom: open, reach: reach, grownFrom: opening.grownFrom, growth: opening.growth,
                     lit: state.isPinned ? 1 : 0, size: size, notch: notch, page: layout.page)
                .animation(.easeInOut(duration: 0.6), value: state.isPinned)
                .allowsHitTesting(false)

            ZStack(alignment: .topLeading) {
                // The hardware notch, carried on into the glass: the black it all grows from.
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                    .fill(.black)
                    .frame(width: notch.width, height: notch.height)
                    .shadow(color: .black, radius: 9)
                    .position(x: size.width / 2, y: notch.height / 2)

                // A darker pool under the page, so its type reads over whatever's behind.
                EllipticalGradient(colors: [Midnight.ink.opacity(0.7), Midnight.ink.opacity(0)], center: .center,
                                   startRadiusFraction: 0.2, endRadiusFraction: 0.5)
                    .frame(width: layout.page.width * 1.25, height: layout.page.height * 1.6)
                    .position(x: layout.page.midX, y: layout.page.midY - layout.page.height * 0.1)
                    .opacity(shown)

                ExpandedNotch(state: state, nowPlaying: nowPlaying, timers: timers, awake: awake, agents: agents,
                              bedtime: bedtime, gestures: gestures, stats: stats)
                    // A net for anything not set through `notchFont`.
                    .fontDesign(.serif)
                    .foregroundStyle(Midnight.white)
                    .tint(Midnight.silver)
                    .frame(width: layout.page.width, height: layout.page.height, alignment: .top)
                    .opacity(shown)
                    .blur(radius: 10 * (1 - shown))
                    .offset(y: -8 * (1 - shown))
                    .position(x: layout.page.midX, y: layout.page.midY)

                // The words on the charts, which the shader doesn't set.
                ChartLabels(bloom: open, reach: reach, size: size, page: layout.page)
                    .allowsHitTesting(false)

                // The hands, a constellation across the sky.
                HandConstellation(size: size, reach: reach, page: layout.page, bloom: open)

                Moon(state: state, moon: layout.moon, reveal: shown)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(MidnightArch(bloom: open, notch: notch, reach: reach))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

// MARK: - Layout

/// Where things go in the band: the page at the top, under the notch; the moon on the right,
/// where the backdrop draws it.
struct BloomLayout {
    let size: CGSize
    let page: CGRect
    let moon: (center: CGPoint, radius: CGFloat)

    @MainActor
    init(state: NotchState, size: CGSize, reach: CGFloat) {
        self.size = size
        page = CGRect(x: (size.width - state.openWidth) / 2, y: 0, width: state.openWidth,
                      height: state.headerHeight + state.contentHeight)
        moon = MidnightBackdrop.moon(in: size, reach: min(reach, size.height))
    }
}

// MARK: - Glass

/// The backdrop as it animates, frame by frame (it's handed each step, not just the end).
private struct Backdrop: View, Animatable {
    var bloom: Double
    var reach: CGFloat
    let grownFrom: CGFloat
    var growth: Double
    var lit: Double
    let size: CGSize
    let notch: CGSize
    let page: CGRect

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
        // In the band's frame, so the plate lines up with the page and the moon, but spilling out
        // past it into the room the window leaves below.
        MidnightBackdrop(bloom: bloom, active: true, notch: notch, reach: reach, grownFrom: grownFrom, growth: growth,
                         lit: lit, overflow: Midnight.overflow, page: page)
            .frame(width: size.width, height: size.height)
    }
}

/// The glass as it animates (and wilts, and grows to the page).
private struct BloomGlass: View, Animatable {
    var bloom: Double
    var reach: CGFloat
    let size: CGSize
    let notch: CGSize
    let page: CGRect

    @Environment(\.midnightWilt) private var wilt

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(bloom, reach) }
        set {
            bloom = newValue.first
            reach = newValue.second
        }
    }

    var body: some View {
        Glass(bloom: bloom * (1 - wilt), reach: reach, size: size, notch: notch, page: page)
            .frame(width: size.width, height: size.height)
    }
}

/// The desktop behind, blurred and darkened, only where the plate always is, however its foot
/// flows, thinning out over a wide band toward where it can pinch up to; past that, out where it
/// swells and pinches, it's dark glass without the blur. (A mask that moved with the foot would
/// need drawing again a dozen times a second, and the window server's blur swapping its mask that
/// often is a risk of flicker; this one's drawn again only when the shape, or the page, changes.)
/// It's masked by an image, the one way the window server's blur takes one.
private struct Glass: NSViewRepresentable {
    let bloom: Double
    let reach: CGFloat
    let size: CGSize
    let notch: CGSize
    let page: CGRect

    final class Coordinator {
        var drawn: (bloom: Double, reach: CGFloat, size: CGSize, notch: CGSize, page: CGRect)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if let drawn = context.coordinator.drawn, drawn.bloom == bloom, drawn.reach == reach, drawn.size == size,
           drawn.notch == notch, drawn.page == page { return }
        context.coordinator.drawn = (bloom, reach, size, notch, page)
        view.maskImage = MidnightArch(bloom: bloom, notch: notch, reach: reach).glassMask(in: size, page: page)
    }
}

// MARK: - Wilting

private struct WiltKey: EnvironmentKey {
    static let defaultValue = 0.0
}

extension EnvironmentValues {
    /// How far the bloom has wilted on its way out: 0 until it goes.
    var midnightWilt: Double {
        get { self[WiltKey.self] }
        set { self[WiltKey.self] = newValue }
    }
}

/// Going, the bloom runs backwards, quickly: the silhouette folds back up toward the notch, the
/// frame undraws, and the lot fades.
struct Wilting: ViewModifier, Animatable {
    var amount: Double

    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.midnightWilt, amount)
            .opacity(1 - amount * amount)
    }
}

// MARK: - The charts' words

/// What the backdrop's charts say, set in Midnight's engraved capitals (a shader can't set type):
/// the planisphere's hours, XII to XI twice round, coming in clockwise from XII as it opens; and
/// CYGNUS by its cross, under the page. Where the plate dissolves, as its foot flows, they go with
/// it (looked at again 15 times a second, which is plenty for a foot that moves as slowly as it
/// does).
private struct ChartLabels: View, Animatable {
    var bloom: Double
    var reach: CGFloat
    let size: CGSize
    let page: CGRect

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(bloom, reach) }
        set {
            bloom = newValue.first
            reach = newValue.second
        }
    }

    private static let hours = ["XII", "I", "II", "III", "IIII", "V", "VI", "VII", "VIII", "IX", "X", "XI"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
            labels(at: MidnightBackdrop.clock)
        }
    }

    private func labels(at time: Double) -> some View {
        Canvas { context, _ in
            func plate(at point: CGPoint) -> Double {
                MidnightBackdrop.presence(at: point, in: size, reach: reach, page: page, overflow: Midnight.overflow,
                                          bloom: bloom, time: time)
            }
            let shown = Self.easeOut((bloom - 0.25) / 0.5)
            let center = MidnightBackdrop.planisphere(in: size, reach: reach)
            for index in 0..<24 where Double(index) / 24 < shown {
                let angle = -Double.pi / 2 + Double(index) / 24 * 2 * .pi
                let at = CGPoint(x: center.x + 132 * CGFloat(cos(angle)), y: center.y + 132 * CGFloat(sin(angle)))
                let shown = plate(at: at)
                guard shown > 0.01 else { continue }
                var glyph = context
                glyph.opacity = shown
                glyph.translateBy(x: at.x, y: at.y)
                glyph.rotate(by: .radians(angle + .pi / 2))
                glyph.draw(Text(Self.hours[index % 12]).font(Midnight.smallCaps(6)).tracking(0.4)
                    .foregroundStyle(Midnight.white.opacity(0.7)), at: .zero, anchor: .center)
            }
            let cygnus = min(max((bloom - 0.6) / 0.4, 0), 1)
            if cygnus > 0 {
                let albireo = MidnightBackdrop.cygnus(in: size, reach: reach)
                let at = CGPoint(x: albireo.x + 34, y: albireo.y - 44)
                let shown = plate(at: CGPoint(x: at.x + 15, y: at.y))
                context.draw(Text("CYGNUS").font(Midnight.smallCaps(6.5)).tracking(1.5)
                    .foregroundStyle(Midnight.white.opacity(0.6 * cygnus * shown)),
                             at: at, anchor: .leading)
            }
        }
    }

    private static func easeOut(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return 1 - pow(1 - t, 3)
    }
}

// MARK: - The moon

/// Over the backdrop's moon, low on the right: the inscription round its top, and its dial, which
/// holds the bloom open. Clicked, it pins it until it's clicked again: the lamp lit, the dial
/// turning and the inscription warm (the backdrop draws those, from `lit`). Hovered and not
/// pinned, a faint ring round it.
private struct Moon: View {
    @ObservedObject var state: NotchState
    let moon: (center: CGPoint, radius: CGFloat)
    let reveal: Double

    @StateObject private var hover = Hovering()

    var body: some View {
        let radius = moon.radius
        let side = 2 * (radius * 67 / 58 + 16)
        let pinned = state.isPinned
        ZStack {
            Inscription(radius: radius * 67 / 58, lit: pinned)
                .opacity(reveal)
                .animation(.easeInOut(duration: 0.6), value: pinned)
            Circle()
                .stroke(Midnight.silver, lineWidth: 0.6)
                .frame(width: 2 * (radius + 4), height: 2 * (radius + 4))
                .opacity(!pinned && hover.isOn ? 0.45 : 0)
                .animation(.easeInOut(duration: 0.25), value: hover.isOn)
                .allowsHitTesting(false)
            Circle()
                .fill(.clear)
                .frame(width: 2 * radius, height: 2 * radius)
                .contentShape(Circle())
                .onTapGesture { state.isPinned.toggle() }
                .onHover { hover.isOn = $0 }
                .help(pinned ? "Let Midnight Oyl close" : "Keep Midnight Oyl open")
        }
        .frame(width: side, height: side)
        .position(moon.center)
    }
}

private final class Hovering: ObservableObject {
    @Published var isOn = false
}

/// "MIDNIGHT ✦ OYL" in spaced engraved capitals round the top of the moon's dial, like the
/// letters round a seal: silver, or starlight while it's `lit` (pinned). Drawn once, and again
/// only when that changes.
private struct Inscription: View {
    let radius: CGFloat
    let lit: Bool

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let color = lit ? Midnight.starlight : Midnight.silver
            let letters = Array("MIDNIGHT ✦ OYL").map { letter in
                context.resolve(Text(String(letter)).font(Midnight.smallCaps(10.5)).foregroundStyle(color))
            }
            let spacing: CGFloat = 2.4
            let widths = letters.map { $0.measure(in: CGSize(width: 100, height: 100)).width }
            let length = widths.reduce(0, +) + spacing * CGFloat(widths.count - 1)
            var along = -length / 2
            for index in letters.indices {
                let angle = -Double.pi / 2 + Double((along + widths[index] / 2) / radius)
                along += widths[index] + spacing
                var glyph = context
                glyph.translateBy(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
                glyph.rotate(by: .radians(angle + .pi / 2))
                glyph.draw(letters[index], at: .zero, anchor: .center)
            }
        }
        .shadow(color: (lit ? Midnight.starlight : Midnight.moonlight).opacity(lit ? 0.45 : 0.2), radius: lit ? 5 : 3)
        .allowsHitTesting(false)
    }
}
