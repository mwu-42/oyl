import AppKit
import Combine
import SwiftUI

/// How much of Claude's 5-hour limit window is left, on the menu bar just right of the notch (see
/// `ClaudeLimit` for the reading): "5h 81% left". In Oyl's look a piece of the notch in black, flared
/// into the top as the notch is, the figure in white (amber under 20% left, coral under 5%). In
/// Midnight Oyl's a patch of night with no edge, a moon in it that wanes as the window's used, the
/// figure in the Victorian face. With more than one account (see `ClaudeAccount`), each one's
/// that has a window going, one after another, each after its initial in its own color (the usage
/// page's for it, see `ClaudeWindowRow.hue`): "5h W 95%  P 98% left"; in Midnight's, a moon each,
/// in its color too. It never takes the pointer. Away while Oyl's off or resting, the
/// notch is open, Mission Control's up or Midnight's band is out, and when there's no window going.
/// On the Notch settings, off to begin with.
@MainActor
final class BarLimit {
    private let state: NotchState
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model = BarLimitModel()
    private var cancellables = Set<AnyCancellable>()
    private var going: DispatchWorkItem?
    private var accounts: [ClaudeAccount] = []
    private var readings: [String: ClaudeLimit.Reading] = [:]

    /// How far it reaches right of the notch while it's up (for the lyrics on the bar to keep clear).
    private(set) var reach: CGFloat = 0
    var reachChanged: () -> Void = {}

    init(state: NotchState) {
        self.state = state
        // With the Oyls: over the menu bar, under the notch (so Midnight's band comes over it).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: BarLimitView(model: model))
        host.sizingOptions = []
        panel.contentView = host

        Publishers.CombineLatest(ClaudeLimit.shared.$accounts, ClaudeLimit.shared.$readings)
            .receive(on: RunLoop.main)
            .sink { [weak self] accounts, readings in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.accounts = accounts
                    self.readings = readings
                    self.update()
                }
            }
            .store(in: &cancellables)
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &cancellables)
        state.$theme
            .sink { [weak self] theme in MainActor.assumeIsolated { self?.model.theme = theme; self?.update() } }
            .store(in: &cancellables)
        Features.shared.follow(.claudeLimitBar) { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private var wanted: Bool {
        guard Feature.claudeLimitBar.isOn, !model.windows.isEmpty else { return false }
        return !state.isOff && !state.isResting && !state.isViewingDesktops && !state.isBlooming && state.mode != .expanded
    }

    private func update() {
        let windows = BarLimitView.windows(of: accounts, readings: readings, now: Date())
        if model.windows != windows { model.windows = windows }
        let wanted = self.wanted
        if wanted {
            going?.cancel()
            going = nil
            place()
            if !panel.isVisible {
                panel.orderFrontRegardless()
                EverySpace.rejoin(panel)
            }
            if !model.shown { withAnimation(BarLimitView.ease(model.theme)) { model.shown = true } }
        } else if model.shown || panel.isVisible {
            if model.shown { withAnimation(BarLimitView.ease(model.theme)) { model.shown = false } }
            guard going == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.model.shown else { return }
                self.going = nil
                self.panel.orderOut(nil)
            }
            going = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        let reach = wanted ? BarLimitView.width(model) + 8 : 0
        if reach != self.reach {
            self.reach = reach
            reachChanged()
        }
    }

    /// Just right of the notch, as deep as it is.
    private func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
        let metrics = state.metrics
        let height = metrics.size.height
        if model.height != height { model.height = height }
        let width = BarLimitView.width(model)
        let frame = NSRect(x: metrics.centerX + metrics.size.width / 2 + 6, y: screen.frame.maxY - height, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

@MainActor
final class BarLimitModel: ObservableObject {
    @Published var windows: [BarLimitView.Window] = []
    @Published var theme = NotchTheme.standard
    @Published var shown = false
    @Published var height: CGFloat = 32
}

struct BarLimitView: View {
    @ObservedObject var model: BarLimitModel

    /// One account's window on the bar: its initial, if it's one of several; its place among them
    /// (for its color); and what's read.
    struct Window: Equatable, Identifiable {
        var initial: String? = nil
        var mark = 0
        let reading: ClaudeLimit.Reading
        var id: Int { mark }
    }

    /// The current window of each of `accounts` that has one, in order, each with its initial if
    /// there's more than one account.
    static func windows(of accounts: [ClaudeAccount], readings: [String: ClaudeLimit.Reading], now: Date) -> [Window] {
        let several = accounts.count > 1
        return accounts.enumerated().compactMap { index, account in
            guard let reading = readings[account.id], reading.isCurrent(at: now) else { return nil }
            return Window(initial: several ? account.initial : nil, mark: index, reading: reading)
        }
    }

    /// What's left of the window, 0 to 100.
    static func left(_ reading: ClaudeLimit.Reading) -> Int { max(0, 100 - reading.percent) }

    /// "81% left".
    static func says(_ reading: ClaudeLimit.Reading) -> String { "\(left(reading))% left" }

    /// "81% left"; or, named: "W 95%  P 98% left".
    static func says(_ windows: [Window]) -> String {
        guard windows.contains(where: { $0.initial != nil }) else { return windows.first.map { says($0.reading) } ?? "100% left" }
        return windows.map { ($0.initial.map { $0 + " " } ?? "") + "\(left($0.reading))%" }.joined(separator: "  ") + " left"
    }

    /// White, amber under 20% left, coral under 5% (paler in Midnight's).
    static func tint(_ left: Int, theme: NotchTheme) -> Color {
        let color = left < 5 ? Color(red: 1, green: 0.48, blue: 0.42) : left < 20 ? Color(red: 1, green: 0.76, blue: 0.36) : .white
        return theme.tint(color)
    }

    /// An account's color, for its initial (and its moon, in Midnight's): the usage page's for it.
    static func hue(_ window: Window, theme: NotchTheme) -> Color {
        ClaudeWindowRow.color(window.mark, theme: theme)
    }

    /// How wide it is: its words, and room round them (and another moon's, for each window more).
    static func width(_ model: BarLimitModel) -> CGFloat {
        let midnight = model.theme == .midnight
        let font = midnight ? NSFont(name: "Superclarendon-Regular", size: 12) ?? .systemFont(ofSize: 12) : .systemFont(ofSize: 12, weight: .semibold)
        let words = says(model.windows)
        let text = (words as NSString).size(withAttributes: [.font: font]).width
        let more = CGFloat(max(model.windows.count - 1, 0))
        return ceil(text + (midnight ? 52 + 16 * more : 40 + 4 * more))
    }

    static func ease(_ theme: NotchTheme) -> Animation {
        theme == .midnight ? .timingCurve(0.45, 0, 0.25, 1, duration: 0.45) : .easeOut(duration: 0.2)
    }

    var body: some View {
        let midnight = model.theme == .midnight
        let windows = model.windows
        let named = windows.contains { $0.initial != nil }
        HStack(spacing: 5) {
            if !midnight {
                Text("5h")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            if named {
                ForEach(windows) { window in
                    HStack(spacing: 3) {
                        Text(window.initial ?? "")
                            .font(midnight ? Midnight.font(.heading, size: 10, weight: .regular) : .system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Self.hue(window, theme: model.theme))
                        if midnight { moon(window, color: Self.hue(window, theme: model.theme)) }
                        figure("\(Self.left(window.reading))%", left: Self.left(window.reading))
                    }
                    .padding(.trailing, 2)
                }
                Text("left")
                    .font(midnight ? Midnight.font(.heading, size: 11, weight: .regular) : .system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(midnight ? Midnight.bone.opacity(0.8) : .white.opacity(0.45))
            } else if let window = windows.first {
                // Full while there's plenty left, waning as it's used.
                if midnight { moon(window, color: Midnight.silver) }
                figure(Self.says(window.reading), left: Self.left(window.reading))
            }
        }
        .padding(.horizontal, midnight ? 14 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if midnight {
                // A patch of night with no edge, fading out past the words.
                RadialGradient(colors: [Midnight.ink.opacity(0.92), Midnight.ink.opacity(0)], center: .center, startRadius: 4,
                               endRadius: max(model.height, 40))
                    .scaleEffect(x: 1.6, y: 1)
            } else {
                NotchShape(topRadius: 5, bottomRadius: 8).fill(Color.black)
            }
        }
        .opacity(model.shown ? 1 : 0)
        .offset(x: model.shown ? 0 : -8)
        .blur(radius: midnight && !model.shown ? 4 : 0)
        .animation(Self.ease(model.theme), value: windows.map { Self.left($0.reading) })
        .environment(\.notchTheme, model.theme)
    }

    /// Full while there's plenty left, waning as it's used.
    private func moon(_ window: Window, color: Color) -> some View {
        WaxingMoon(fraction: Double(Self.left(window.reading)) / 100)
            .fill(color.opacity(0.9))
            .background(Circle().strokeBorder(color.opacity(0.28), lineWidth: 0.75))
            .frame(width: 11, height: 11)
    }

    private func figure(_ words: String, left: Int) -> some View {
        let midnight = model.theme == .midnight
        return Text(words)
            .font(midnight ? Midnight.font(.heading, size: 12, weight: .regular) : .system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(midnight && left >= 20 ? Midnight.white.opacity(0.88) : Self.tint(left, theme: model.theme))
            .lineLimit(1)
            .contentTransition(.numericText(value: Double(left)))
    }
}
