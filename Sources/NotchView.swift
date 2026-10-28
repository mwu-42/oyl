import SwiftUI

struct NotchView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var timers: TimerStore
    @ObservedObject var awake: AwakeManager
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var bedtime: Bedtime
    let gestures: GestureWatcher
    let stats: SystemStats

    // Atoll's timing: a bouncy pop on hover, critically damped springs to open and close, and
    // content that swaps with a blur.
    static let pop = Animation.bouncy.speed(1.2)
    static let open = Animation.spring(response: 0.31, dampingFraction: 1)
    static let close = Animation.spring(response: 0.45, dampingFraction: 1)
    /// A timer that's done pops the notch out on its own, with a bounce, so it's noticed.
    static let announce = Animation.spring(response: 0.5, dampingFraction: 0.6)
    static let swap = AnyTransition(.blurReplace).animation(.interactiveSpring(dampingFraction: 1.2))

    var body: some View {
        let mode = state.mode
        let size = state.size(for: mode)
        let topRadius = NotchState.topRadius(mode)
        let lifted = mode == .expanded || state.isPopped

        // Content is laid out at its final size and revealed by the growing clip shape.
        ZStack(alignment: .top) {
            switch mode {
            case .expanded:
                ExpandedNotch(state: state, nowPlaying: nowPlaying, timers: timers, awake: awake, agents: agents,
                              bedtime: bedtime, gestures: gestures, stats: stats)
                    .transition(Self.swap)
            case .compact:
                CompactNotch(layout: state.compact, size: size, notchWidth: state.metrics.size.width,
                             nowPlaying: nowPlaying)
                    .transition(Self.swap)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: size.width + 2 * topRadius, height: size.height, alignment: .top)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: NotchState.bottomRadius(mode)))
        // Shadow only while lifted (popped or open).
        .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: lifted ? (mode == .expanded ? 14 : 6) : 0, y: lifted ? 4 : 0)
        .opacity(mode == .idle && !state.isPopped ? 0 : 1)
        .contextMenu {
            Button("Quit Oyl") { NSApp.terminate(nil) }
        }
        // Innermost wins when several change at once: opening/closing beats the pop.
        .animation(mode == .expanded ? (state.isAnnouncing ? Self.announce : Self.open) : Self.close, value: mode)
        .animation(Self.pop, value: state.isPopped)
        .animation(Self.open, value: size)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Flat top with flared corners that blend into the menu bar, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = topRadius
        let bottom = max(0, min(bottomRadius, rect.height - top, (rect.width - 2 * top) / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                          control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addArc(tangent1End: CGPoint(x: rect.minX + top, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), radius: bottom)
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX - top, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), radius: bottom)
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Closed

struct CompactNotch: View {
    let layout: CompactLayout
    let size: CGSize
    let notchWidth: CGFloat
    @ObservedObject var nowPlaying: NowPlaying

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: CompactLayout.gap) {
                if layout.showsMusic {
                    ArtworkView(image: nowPlaying.artwork, cornerRadius: layout.art * 0.21)
                        .frame(width: layout.art, height: layout.art)
                }
                if let timer = layout.timer {
                    Countdown(timer: timer) { _, left in
                        TimerRing(fraction: left, lineWidth: 2.5, color: timer.tint(fractionLeft: left))
                    }
                    .frame(width: CompactLayout.ringSize, height: CompactLayout.ringSize)
                }
            }
            Spacer(minLength: notchWidth)
            HStack(spacing: CompactLayout.gap) {
                if layout.showsMusic {
                    SpectrumBars(spectrum: nowPlaying.spectrum, isPlaying: nowPlaying.isPlaying,
                                 color: nowPlaying.accent, barWidth: 2.5, height: layout.art * 0.65)
                        .frame(width: layout.art)
                }
                if let timer = layout.timer {
                    Countdown(timer: timer) { remaining, left in
                        Text(ReminderTimer.format(remaining))
                            .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(timer.tint(fractionLeft: left))
                    }
                    .frame(width: layout.countdownWidth, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, layout.inset)
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Open

struct ExpandedNotch: View {
    @ObservedObject var state: NotchState
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var timers: TimerStore
    @ObservedObject var awake: AwakeManager
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var bedtime: Bedtime
    let gestures: GestureWatcher
    let stats: SystemStats

    var body: some View {
        let notch = state.metrics.size
        let width = state.openWidth

        VStack(spacing: 0) {
            // In a fullscreen app the band beside the hardware notch is the menu bar's (it slides
            // down there), so the tabs' strip goes in a row below it.
            if state.inFullscreen {
                Color.clear.frame(width: width, height: notch.height)
            }
            // The strip beside the hardware notch: page tabs left; right, the next timer and the
            // awake indicator (unless their own page is showing), then the hand gestures toggle.
            HStack(spacing: 0) {
                if !state.isAlerting, agents.approvals.isEmpty {
                    PageTabs(page: $state.page, awake: awake.isActive, agent: agents.lead?.activity,
                             skin: agents.lead.map { Oyl.pastel($0.skin) } ?? Oyl.white)
                }
                Spacer(minLength: state.inFullscreen ? 16 : notch.width + 16)
                if timers.ringing == nil {
                    HStack(spacing: 6) {
                        if state.page != .timers, let next = timers.next {
                            Countdown(timer: next) { remaining, left in
                                HStack(spacing: 5) {
                                    TimerRing(fraction: left, lineWidth: 2, color: next.tint(fractionLeft: left))
                                        .frame(width: 13, height: 13)
                                    Text(ReminderTimer.format(remaining))
                                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                                        .foregroundStyle(next.tint(fractionLeft: left))
                                }
                            }
                        }
                        if state.page != .awake, awake.isActive {
                            Image(systemName: AwakePage.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AwakePage.tint)
                        }
                        GestureToggle(gestures: gestures)
                    }
                    .transition(.opacity)
                }
            }
            // A little tighter on the right, where an hour-long timer, the awake indicator and the
            // toggle all have to fit beside the notch.
            .padding(.leading, Layout.stripPadding)
            .padding(.trailing, 16)
            .frame(width: width, height: state.inFullscreen ? Layout.fullscreenStripHeight : notch.height)

            ZStack(alignment: .top) {
                if let approval = agents.approvals.first {
                    ApprovalPage(approval: approval, agents: agents, gestures: gestures)
                        .id(approval.id)
                        .transition(NotchView.swap)
                } else if let ringing = timers.ringing {
                    AlertPage(timer: ringing, timers: timers)
                        .transition(NotchView.swap)
                } else if bedtime.reminding {
                    BedtimeAlert(bedtime: bedtime)
                        .transition(NotchView.swap)
                } else {
                    switch state.page {
                    case .music:
                        MusicPage(nowPlaying: nowPlaying, state: state, hands: gestures)
                            .transition(NotchView.swap)
                    case .timers:
                        TimersPage(timers: timers, state: state)
                            .transition(NotchView.swap)
                    case .awake:
                        AwakePage(awake: awake, state: state)
                            .transition(NotchView.swap)
                    case .agents:
                        OylsPage(state: state, nowPlaying: nowPlaying, timers: timers, awake: awake, agents: agents,
                                 calendar: state.calendar, bedtime: bedtime)
                            .transition(NotchView.swap)
                    case .activity:
                        ActivityPage(stats: stats)
                            .transition(NotchView.swap)
                    }
                }
            }
            .frame(width: width, height: state.contentHeight, alignment: .top)
        }
        .frame(width: width, height: state.headerHeight + state.contentHeight, alignment: .top)
    }
}

struct PageTabs: View {
    @Binding var page: NotchPage
    let awake: Bool
    /// What the lead agent is doing, if any is running; its tab acts it out.
    let agent: AgentActivity?
    let skin: Color

    var body: some View {
        HStack(spacing: 2) {
            // Oyl's own tab, first, wide enough to see what he's up to.
            tab(.agents, width: Layout.oylsTabWidth) {
                Oyl(activity: agent ?? .idle, hat: agent != nil, skin: skin)
                    .frame(width: 36, height: 19)
                    .opacity(agent == nil && page != .agents ? 0.6 : 1)
            }
            tab(.music, symbol: "music.note")
            tab(.timers, symbol: "timer")
            tab(.awake, symbol: AwakePage.symbol, lit: awake ? AwakePage.tint : nil)
            tab(.activity, symbol: "cpu", lit: ActivityPage.tint.opacity(0.8))
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.08)))
    }

    /// `lit` tints an unselected tab: cyan while the Mac is kept awake, green for Activity.
    private func tab(_ target: NotchPage, symbol: String, lit: Color? = nil) -> some View {
        tab(target) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(page == target ? Color.black : lit ?? Color.white.opacity(0.6))
        }
    }

    private func tab<Icon: View>(_ target: NotchPage, width: CGFloat = Layout.tabWidth,
                                  @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            withAnimation(NotchView.open) { page = target }
        } label: {
            icon()
                .frame(width: width, height: 20)
                // White Oyl would vanish on the usual white highlight.
                .background(Capsule().fill(.white.opacity(page == target ? (target == .agents ? 0.25 : 0.9) : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Pieces

/// Top right of the open notch: turns hand gestures on and off. It pulses while the camera
/// watches, and shows each gesture as it's acted on (a pinch for as long as it's held).
struct GestureToggle: View {
    @ObservedObject var gestures: GestureWatcher

    var body: some View {
        Button { gestures.isEnabled.toggle() } label: {
            ZStack {
                if !gestures.isEnabled {
                    Image(systemName: "hand.raised.slash")
                        .foregroundStyle(.white.opacity(0.35))
                } else if let scrub = gestures.scrubOffset {
                    Image(systemName: scrub < 0 ? "gobackward" : "goforward")
                        .foregroundStyle(.white)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else if gestures.isTurning {
                    Image(systemName: HandGesture.pinch.symbol)
                        .foregroundStyle(.white)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else if let sighting = gestures.sighting {
                    Image(systemName: sighting.gesture.symbol)
                        .foregroundStyle(.white)
                        .id(sighting.id)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else if gestures.isWatching {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(.white.opacity(0.55))
                        .symbolEffect(.pulse)
                        .transition(.opacity)
                } else {
                    // On, but the camera's resting (after an OK, or without permission).
                    Image(systemName: "hand.raised")
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 16, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(gestures.isEnabled ? "Turn off hand gestures" : "Turn on hand gestures")
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: gestures.sighting)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: gestures.isTurning)
        .animation(.easeInOut(duration: 0.2), value: gestures.isWatching)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { geometry in
                    Image(systemName: "music.note")
                        .font(.system(size: geometry.size.width * 0.42, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: image.map(ObjectIdentifier.init))
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Thin capsule slider for the seek bar; thickens while dragged.
struct ScrubBar: View {
    let fraction: Double
    let onChanged: (Double) -> Void
    let onEnded: (Double) -> Void
    @StateObject private var dragging = LocalState(false)

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(max(fraction, 0), 1)
            let position = { (x: CGFloat) in min(max(x / geometry.size.width, 0), 1) }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(.white.opacity(dragging.value ? 1 : 0.85))
                    .frame(width: geometry.size.width * fraction)
            }
            .frame(height: dragging.value ? 7 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging.value = true
                        onChanged(position(value.location.x))
                    }
                    .onEnded { value in
                        onEnded(position(value.location.x))
                        dragging.value = false
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging.value)
        }
        .frame(height: 14)
    }
}

/// Stands in for `@State`: the Command Line Tools SDK ships SwiftUI's `@State` macro without
/// its compiler plugin, so `@State` doesn't build outside Xcode.
final class LocalState<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
