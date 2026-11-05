import AppKit
import Combine
import SwiftUI

/// A request for your OK (Claude Code wanting to run something, the Claude app to use a tool) as a
/// small card in the screen's bottom right corner, rather than the notch opening for it: who's
/// asking and what, Deny and Allow (a thumbs up allows too, while the camera's looking for one),
/// and a click on the rest to answer it in the app instead. The first asked is shown, with how many
/// more are waiting. In Oyl's look a black card like the notch, the asking Oyl on it; in
/// Midnight's a patch of night with no edge, a star glinting for the agent among a few twinkling
/// specks, coming up out of a blur. On every Space, over fullscreen apps too, and away while Oyl
/// rests.
@MainActor
final class ApprovalCorner {
    private let panel = NotchPanel()
    private let model = ApprovalCornerModel()
    private let host: ApprovalCornerHostingView
    private let agents: AgentMonitor
    private let state: NotchState
    private var going: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    /// From the screen's edges to the card's.
    static let margin: CGFloat = 16
    /// Round the card inside its window, for its shadow (or its night's soft edge).
    static let room: CGFloat = 14

    init(state: NotchState, agents: AgentMonitor, gestures: GestureWatcher) {
        self.state = state
        self.agents = agents
        host = ApprovalCornerHostingView(rootView: ApprovalCornerView(model: model, agents: agents, gestures: gestures))
        host.sizingOptions = []
        panel.contentView = host
        // Over other windows (fullscreen ones too), under the notch and the menu bar's.
        panel.level = .statusBar
        panel.ignoresMouseEvents = false

        agents.$approvals
            .receive(on: RunLoop.main)
            .sink { [weak self] approvals in MainActor.assumeIsolated { self?.update(approvals) } }
            .store(in: &cancellables)
        state.$theme
            .sink { [weak self] theme in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.theme = theme
                    if self.model.approval != nil { DispatchQueue.main.async { self.place() } }
                }
            }
            .store(in: &cancellables)
        state.$isResting
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update(agents.approvals) } }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.model.approval != nil { self?.place() } }
        }
    }

    private func update(_ approvals: [Approval]) {
        guard let first = approvals.first, !state.isResting else {
            hide()
            return
        }
        going?.cancel()
        going = nil
        let coming = !model.shown
        if model.approval != first { model.approval = first }
        // Sized once the card's been laid out for it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.approval == first else { return }
            self.place()
            guard coming else { return }
            self.panel.orderFrontRegardless()
            self.model.shown = true
        }
    }

    private func hide() {
        guard model.shown || model.approval != nil, going == nil else { return }
        model.shown = false
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.shown else { return }
            self.going = nil
            self.panel.orderOut(nil)
            self.model.approval = nil
        }
        going = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// In the bottom right corner of the notch's screen, clear of the macOS Dock if it's showing.
    private func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let area = screen.visibleFrame
        let inset = Self.margin - Self.room
        let frame = NSRect(x: area.maxX - inset - size.width, y: area.minY + inset, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

final class ApprovalCornerHostingView: NSHostingView<ApprovalCornerView> {
    // The panel's never key, so the first click has to reach the buttons directly.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ApprovalCornerModel: ObservableObject {
    /// The request shown, kept while the card goes.
    @Published var approval: Approval?
    @Published var shown = false
    @Published var theme = NotchTheme.standard
}

struct ApprovalCornerView: View {
    @ObservedObject var model: ApprovalCornerModel
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var gestures: GestureWatcher

    var body: some View {
        if let approval = model.approval {
            let midnight = model.theme == .midnight
            // The asking agent's own pastel.
            let skin = agents.sessions.first { $0.id == approval.session }.map { Oyl.pastel($0.skin) } ?? Oyl.white
            ApprovalCard(approval: approval, more: max(agents.approvals.count - 1, 0), skin: skin, watching: gestures.isWatching,
                         answer: { [agents] in agents.answer(approval, allow: $0) }, answerInApp: { [agents] in agents.answerInApp(approval) })
                .padding(ApprovalCorner.room)
                .modifier(CornerReveal(shown: model.shown ? 1 : 0, midnight: midnight))
                .animation(model.shown ? (midnight ? .easeOut(duration: 0.55) : NotchView.open) : .easeIn(duration: 0.3), value: model.shown)
                .environment(\.notchTheme, model.theme)
        }
    }
}

/// The card coming and going, `shown` from 0 to 1: in Oyl's look rising up into the corner on the
/// notch's spring; in Midnight's out of a blur, drifting up a little.
private struct CornerReveal: ViewModifier {
    let shown: Double
    let midnight: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(midnight ? 0.94 + 0.06 * shown : 0.9 + 0.1 * shown, anchor: .bottomTrailing)
            .opacity(shown)
            .blur(radius: midnight ? 10 * (1 - shown) : 0)
            .offset(y: (midnight ? 10 : 16) * (1 - shown))
    }
}

/// Who's asking and what, Deny and Allow.
struct ApprovalCard: View {
    let approval: Approval
    /// How many more are waiting after it.
    let more: Int
    /// The asking agent's color.
    let skin: Color
    /// The camera's looking for a thumbs up.
    let watching: Bool
    /// Allowed (true) or denied.
    let answer: (Bool) -> Void
    /// To be answered in the app itself, which is brought up.
    let answerInApp: () -> Void
    @Environment(\.notchTheme) private var theme

    static let width: CGFloat = 300

    var body: some View {
        let midnight = theme == .midnight
        VStack(alignment: .leading, spacing: 8) {
            Button(action: answerInApp) {
                HStack(alignment: .top, spacing: 10) {
                    if midnight {
                        AskingStar(color: theme.tint(skin))
                            .frame(width: 26, height: 26)
                    } else {
                        Oyl(activity: .waiting, hat: true, skin: skin)
                            .frame(width: 44, height: 22)
                            .padding(.top, 2)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if midnight {
                                Text(approval.project.uppercased())
                                    .notchFont(size: 10, role: .label)
                                    .tracking(Midnight.tracking(.label, size: 10))
                                    .foregroundStyle(Midnight.white)
                            } else {
                                Text(approval.project)
                                    .notchFont(size: 12.5, weight: .semibold)
                                    .foregroundStyle(.white)
                            }
                            if let host = approval.host {
                                Text(host)
                                    .notchFont(size: 9.5, weight: .medium)
                                    .foregroundStyle((midnight ? Midnight.silver : .white).opacity(0.55))
                                    .padding(.horizontal, midnight ? 0 : 5)
                                    .frame(height: 15)
                                    .background(Capsule().fill(.white.opacity(midnight ? 0 : 0.1)))
                            }
                            Spacer(minLength: 0)
                            if more > 0 {
                                Text("+\(more)")
                                    .notchFont(size: 10, weight: .semibold, digits: true)
                                    .foregroundStyle((midnight ? Midnight.silver : .white).opacity(0.6))
                            }
                        }
                        Text(approval.action)
                            .notchFont(size: 11.5)
                            .foregroundStyle((midnight ? Midnight.white : .white).opacity(0.8))
                        if let detail = approval.detail {
                            Text(detail)
                                .notchFont(size: 10, design: .monospaced)
                                .foregroundStyle((midnight ? Midnight.silver : .white).opacity(0.5))
                                .truncationMode(.middle)
                        }
                    }
                    .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Answer in \(approval.host ?? "the app")")
            HStack(spacing: 8) {
                if watching {
                    Label("or a thumbs up", systemImage: "hand.thumbsup.fill")
                        .notchFont(size: 9.5, weight: .medium)
                        .foregroundStyle((midnight ? Midnight.silver : .white).opacity(0.45))
                }
                Spacer(minLength: 0)
                // In Midnight's, Deny's just its word, in silver, with nothing round it.
                pill("Deny", foreground: midnight ? Midnight.silver : .white, background: midnight ? .clear : .white.opacity(0.14),
                     bright: false) { answer(false) }
                pill("Allow", foreground: .black, background: Oyl.hatOrange) { answer(true) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Self.width)
        .background {
            if midnight {
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(Midnight.ink.opacity(0.94)).blur(radius: 7)
                    CornerSpecks()
                }
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
            }
        }
    }

    private func pill(_ title: String, foreground: Color, background: Color, bright: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .notchFont(size: 12, weight: .semibold)
                .padding(.horizontal, 13)
                .frame(height: 24)
                .notchPill(background, text: foreground, bright: bright, urgent: true)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Midnight Oyl's asking agent: a glint in its color, breathing in and out as it waits, its rays
/// slowly turning.
private struct AskingStar: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = 0.5 + 0.5 * sin(t * 2.4)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [color.opacity(0.35 + 0.25 * breath), .clear], center: .center, startRadius: 0, endRadius: 13))
                Sparkle(size: 8 + 2.5 * breath)
                    .fill(Midnight.starlight)
                    .rotationEffect(.degrees(t * 6))
                    .shadow(color: color.opacity(0.8), radius: 3)
            }
        }
    }
}

/// A few faint specks of light twinkling over the card's night, each on its own beat.
private struct CornerSpecks: View {
    private static let specks: [(x: CGFloat, y: CGFloat, size: CGFloat, beat: Double)] = [
        (0.08, 0.2, 1.4, 1.3), (0.31, 0.88, 1.1, 1.9), (0.57, 0.12, 1.2, 1.1), (0.72, 0.74, 1.5, 2.3),
        (0.9, 0.3, 1.0, 1.6), (0.46, 0.5, 0.9, 2.7), (0.97, 0.9, 1.2, 1.4),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                for (index, speck) in Self.specks.enumerated() {
                    let glow = 0.25 + 0.75 * max(0, sin(t * speck.beat + Double(index) * 1.7))
                    let center = CGPoint(x: speck.x * size.width, y: speck.y * size.height)
                    let r = speck.size
                    canvas.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                                with: .color(Midnight.starlight.opacity(0.55 * glow)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
