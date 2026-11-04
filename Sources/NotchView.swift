import ServiceManagement
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
        // In Midnight Oyl, open is the bloom, over the notch, which stays as it is closed. (With
        // the lid shut, there's no bloom either.)
        ZStack(alignment: .top) {
            notch(state.isBlooming ? state.closedMode : state.mode)
            if state.isBlooming && !state.isResting {
                MidnightNotch(state: state, nowPlaying: nowPlaying, timers: timers, awake: awake, agents: agents,
                              bedtime: bedtime, gestures: gestures, stats: stats)
                    .frame(width: state.bloomSize.width, height: state.bloomSize.height, alignment: .top)
                    // It blooms by itself as it comes, and wilts as it goes.
                    .transition(MidnightNotch.transition)
            }
        }
        .contextMenu {
            Text("\(Motto.name) · \(Motto.words)")
            Divider()
            // The app (or the site) in front, as an agent.
            if let front = state.front {
                let radar = AgentRadar.shared
                if radar.knows(front.id), radar.isOn(front) {
                    Button("Stop Watching \(front.name)") { radar.remove(front) }
                } else {
                    Button("Watch \(front.name) as an Agent") { radar.add(front) }
                }
                Divider()
            }
            Button("Settings…") {
                state.page = .settings
                state.isRevealing = true
            }
            Toggle("Midnight Oyl", isOn: Binding { state.theme == .midnight } set: { state.theme = $0 ? .midnight : .standard })
            Toggle("Oyl's Dock", isOn: $state.showsDock)
            Divider()
            Button("Quit Oyl") { Quitting.quit(awake) }
            Button("Turn Off Oyl") { Quitting.turnOff(awake) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The pages both looks share set their type and accents by it.
        .environment(\.notchTheme, state.theme)
    }

    /// Oyl's own notch: black, flared into the menu bar at the top, rounded at the bottom.
    private func notch(_ mode: NotchMode) -> some View {
        let size = state.size(for: mode)
        let topRadius = NotchState.topRadius(mode)
        let lifted = mode == .expanded || state.isPopped

        // Content is laid out at its final size and revealed by the growing clip shape. With the
        // lid shut, there's none (so none of it animates for no one).
        return ZStack(alignment: .top) {
            switch state.isResting ? .idle : mode {
            case .expanded:
                ExpandedNotch(state: state, nowPlaying: nowPlaying, timers: timers, awake: awake, agents: agents,
                              bedtime: bedtime, gestures: gestures, stats: stats)
                    .transition(Self.swap)
            case .compact:
                CompactNotch(layout: state.compact, size: size, notchWidth: state.metrics.size.width,
                             dictation: state.dictation, timers: timers)
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
        // Innermost wins when several change at once: opening/closing beats the pop.
        .animation(mode == .expanded ? (state.isAnnouncing ? Self.announce : Self.open) : Self.close, value: mode)
        .animation(Self.pop, value: state.isPopped)
        .animation(Self.open, value: size)
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
    let dictation: Dictation
    @ObservedObject var timers: TimerStore

    var body: some View {
        if let timer = layout.focus.flatMap({ focus in timers.timers.first { $0.id == focus.id } }) {
            HeldTimer(timer: timer, size: size, notchWidth: notchWidth)
        } else {
            dictating
        }
    }

    private var dictating: some View {
        HStack(spacing: 0) {
            if layout.dictating {
                Image(systemName: "mic.fill")
                    .notchSymbol(size: layout.art * 0.55, weight: .semibold)
                    .foregroundStyle(Dictation.tint)
                    .frame(width: layout.art, height: layout.art)
            }
            Spacer(minLength: notchWidth)
            if layout.dictating {
                VoiceBars(dictation: dictation, barWidth: 2.5, height: layout.art * 0.65)
                    .frame(width: layout.art)
            }
        }
        .padding(.horizontal, layout.inset)
        .frame(width: size.width, height: size.height)
    }
}

/// The timer held on the closed notch: its ring and name on the left, its time on the right (a
/// reminder with no time, its name there instead), ticking each second.
struct HeldTimer: View {
    let timer: ReminderTimer
    let size: CGSize
    let notchWidth: CGFloat
    @Environment(\.notchTheme) private var theme

    var body: some View {
        Countdown(timer: timer) { remaining, left in
            let tint = timer.isEndless ? theme.tint(Oyl.noteYellow) : timer.tint(fractionLeft: left, theme: theme)
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    if timer.isEndless {
                        Image(systemName: "infinity")
                            .notchSymbol(size: 10, weight: .bold)
                            .foregroundStyle(tint)
                            .frame(width: 14, height: 14)
                    } else {
                        TimerRing(fraction: left, lineWidth: theme == .midnight ? 1.25 : 2, color: tint)
                            .frame(width: 14, height: 14)
                        Text(timer.title)
                            .notchFont(size: 11, weight: .medium)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .frame(width: CompactLayout.timerWing - 12, alignment: .leading)
                Spacer(minLength: notchWidth)
                Text(timer.isEndless ? timer.title : ReminderTimer.format(remaining))
                    .notchFont(size: timer.isEndless ? 11 : 13, weight: timer.isEndless ? .medium : .semibold,
                               design: timer.isEndless ? .default : .rounded, digits: !timer.isEndless)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .frame(width: CompactLayout.timerWing - 12, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .frame(width: size.width, height: size.height)
        }
        .help("\(timer.title), held on the notch")
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
    @Environment(\.notchTheme) private var theme

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
                    PageTabs(page: $state.page, agent: agents.lead?.activity,
                             skin: agents.lead.map { Oyl.pastel($0.skin) } ?? Oyl.white, tabs: state.tabs)
                }
                Spacer(minLength: state.inFullscreen ? 16 : notch.width + 16)
                if timers.ringing == nil {
                    HStack(spacing: 6) {
                        if state.page != .timers, let next = timers.next {
                            Countdown(timer: next) { remaining, left in
                                let tint = next.tint(fractionLeft: left, theme: theme)
                                HStack(spacing: 5) {
                                    TimerRing(fraction: left, lineWidth: theme == .midnight ? 1.25 : 2, color: tint)
                                        .frame(width: 13, height: 13)
                                    Text(ReminderTimer.format(remaining))
                                        .notchFont(size: 12, weight: .semibold, design: .rounded, digits: true)
                                        .foregroundStyle(tint)
                                }
                            }
                        }
                        if state.page != .awake, awake.isActive {
                            Image(systemName: AwakePage.symbol)
                                .notchSymbol(size: 11, weight: .semibold)
                                .foregroundStyle(theme.tint(AwakePage.tint))
                        }
                        if state.dictation.isAvailable, Feature.wisprFlow.isOn { DictationToggle(dictation: state.dictation) }
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
                    case .ideas:
                        IdeasPage(tod: state.tod, state: state)
                            .transition(NotchView.swap)
                    case .awake:
                        AwakePage(awake: awake, state: state)
                            .transition(NotchView.swap)
                    case .agents:
                        OylsPage(state: state, nowPlaying: nowPlaying, timers: timers, awake: awake, agents: agents,
                                 bedtime: bedtime)
                            .transition(NotchView.swap)
                    case .activity:
                        ActivityPage(stats: stats)
                            .transition(NotchView.swap)
                    case .mirror:
                        MirrorPage(gestures: gestures)
                            .transition(NotchView.swap)
                    case .settings:
                        SettingsPage(state: state)
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
    /// What the lead agent is doing, if any is running; its tab acts it out.
    let agent: AgentActivity?
    let skin: Color
    /// Those turned on, Oyl's first and the settings last.
    let tabs: [NotchPage]
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let midnight = theme == .midnight
        return HStack(spacing: 2) {
            // Oyl's own tab, first, wide enough to see what he's up to; in Midnight Oyl, his moyl,
            // turning as the lead agent works.
            tab(.agents, width: Layout.oylsTabWidth) {
                Oyl(activity: agent ?? .idle, hat: agent != nil, skin: skin)
                    .frame(width: 36, height: 19)
                    .opacity(agent == nil && page != .agents ? 0.6 : 1)
            }
            if tabs.contains(.music) { tab(.music, symbol: "music.note") }
            if tabs.contains(.timers) { tab(.timers, symbol: "timer") }
            if tabs.contains(.ideas) { tab(.ideas, symbol: "lightbulb") }
            if tabs.contains(.awake) { tab(.awake, symbol: AwakePage.symbol) }
            if tabs.contains(.activity) { tab(.activity, symbol: "cpu") }
            if tabs.contains(.mirror) { tab(.mirror, symbol: "camera.fill") }
            tab(.settings, symbol: "gearshape")
        }
        .padding(2)
        // Midnight Oyl's is engraved: an outline, not a fill.
        .background(Capsule().fill(.white.opacity(midnight ? 0 : 0.08)))
        .overlay(Capsule().strokeBorder(Midnight.silver.opacity(midnight ? 0.22 : 0), lineWidth: 0.5))
    }

    /// All alike, unselected; staying awake has its own indicator at the other end of the strip.
    private func tab(_ target: NotchPage, symbol: String) -> some View {
        tab(target) {
            Image(systemName: symbol)
                .notchSymbol(size: 11, weight: .semibold)
                .foregroundStyle(page == target ? (theme == .midnight ? Midnight.white : Color.black)
                                 : Color.white.opacity(theme == .midnight ? 0.55 : 0.6))
        }
    }

    private func tab<Icon: View>(_ target: NotchPage, width: CGFloat = Layout.tabWidth,
                                  @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            withAnimation(NotchView.open) { page = target }
        } label: {
            icon()
                .frame(width: width, height: 20)
                // White Oyl would vanish on the usual white highlight. Midnight Oyl's is an
                // outline round a faint fill, so the icon stays white.
                .background(Capsule().fill(selection(target)))
                .overlay(Capsule().strokeBorder(Midnight.silver.opacity(theme == .midnight && page == target ? 0.7 : 0),
                                                lineWidth: 0.75))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private func selection(_ target: NotchPage) -> Color {
        guard page == target else { return .clear }
        if theme == .midnight { return Midnight.silver.opacity(0.14) }
        return .white.opacity(target == .agents ? 0.25 : 0.9)
    }
}

// MARK: - Pieces

/// Top right of the open notch: turns hand gestures on and off. It pulses while the camera
/// watches, and shows each gesture as it's acted on (a pinch for as long as it's held).
/// Wispr Flow's hands-free dictation, on and off: orange, pulsing, while it's listening (however
/// it was started).
struct DictationToggle: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        Button(action: dictation.toggle) {
            Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                .foregroundStyle(dictation.isListening ? Dictation.tint : .white.opacity(0.55))
                .symbolEffect(.pulse, isActive: dictation.isListening)
                .notchSymbol(size: 12, weight: .semibold)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(dictation.isListening ? "Stop Wispr Flow" : "Dictate with Wispr Flow")
    }
}

/// Your voice while Wispr Flow takes it down: bars rising and falling with it, each a little
/// differently, or without the microphone, swaying gently on their own.
struct VoiceBars: View {
    let dictation: Dictation
    var barWidth: CGFloat = 3
    var height: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let level = CGFloat(dictation.level ?? Float(0.35 + 0.15 * sin(time * 2.4)))
            HStack(alignment: .center, spacing: barWidth * 0.7) {
                ForEach(0..<4, id: \.self) { bar in
                    let sway = 0.55 + 0.45 * sin(time * (6 + 1.7 * Double(bar)) + 1.3 * Double(bar))
                    Capsule()
                        .fill(Dictation.tint)
                        .frame(width: barWidth, height: max(barWidth, height * min(level * CGFloat(sway) * 1.3, 1)))
                }
            }
        }
        .frame(width: barWidth * (4 + 3 * 0.7), height: height)
    }
}

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
            .notchFont(size: 12, weight: .semibold)
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
                        .notchSymbol(size: geometry.size.width * 0.42, weight: .medium)
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

/// Stands in for `@State`: the Command Line Tools SDK ships SwiftUI's `@State` macro without
/// its compiler plugin, so `@State` doesn't build outside Xcode.
/// Quitting Oyl, for now or for good.
@MainActor
enum Quitting {
    /// Quits, ending any keep-awake (it opens again at login).
    static func quit(_ awake: AwakeManager) {
        awake.stop()
        NSApp.terminate(nil)
    }

    /// Off altogether: quits, and leaves Login Items till it's opened again by hand (which puts it
    /// back).
    static func turnOff(_ awake: AwakeManager) {
        try? SMAppService.mainApp.unregister()
        quit(awake)
    }
}

final class LocalState<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
