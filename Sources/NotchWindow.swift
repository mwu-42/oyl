import AppKit
import Combine
import SwiftUI

enum Layout {
    static let expandedWidth: CGFloat = 440
    static let artSize: CGFloat = 94
    static let musicHeight: CGFloat = 8 + artSize + 22   // page content below the notch strip
    static let lyricsHeight: CGFloat = 74                // three lines of lyrics under the song
    static let activityHeight: CGFloat = 148
    static let awakeHeight: CGFloat = 124
    static let alertHeight: CGFloat = 72
    static let approvalHeight: CGFloat = 84
    static let timerRowHeight: CGFloat = 30
    static let maxVisibleTimers = 3
    static let oylRowHeight: CGFloat = 34
    static let maxVisibleOyls = 4
    static let chatsFooterHeight: CGFloat = 26
    static let oylSettingsHeight: CGFloat = 24
    static let fullscreenStripHeight: CGFloat = 28       // the tabs' row, under the menu bar's band
    static let popGrowth: CGFloat = 8                    // how far the closed notch pops on hover
    static let shadowPadding: CGFloat = 30
    static let stripPadding: CGFloat = 20                // left of the page tabs
    static let tabWidth: CGFloat = 26
    static let oylsTabWidth: CGFloat = 38                // wider, for Oyl

    /// What the page tabs need left of the hardware notch: padding, the tabs, then a gap.
    static var tabsWing: CGFloat {
        let count = CGFloat(NotchPage.allCases.count)
        return stripPadding + (count - 1) * tabWidth + oylsTabWidth + (count - 1) * 2 + 4 + 8
    }

    static func timersHeight(rows: Int) -> CGFloat {
        let visible = min(rows, maxVisibleTimers)
        let list = visible == 0 ? 20 : CGFloat(visible) * timerRowHeight + CGFloat(visible - 1) * 4
        return 6 + 28 + 10 + list + 16
    }

    static func oylsHeight(rows: Int) -> CGFloat {
        let visible = min(max(rows, 1), maxVisibleOyls)
        return 6 + CGFloat(visible) * oylRowHeight + CGFloat(visible - 1) * 6 + 18
    }
}

enum NotchMode {
    case idle      // nothing drawn; the hardware notch looks untouched
    case compact   // live activity on either side of the notch
    case expanded  // pages, shown while the pointer is over the notch (or a timer is ringing)
}

enum NotchPage: CaseIterable {
    case music, timers, awake, agents, activity
}

struct NotchMetrics: Equatable {
    var size: CGSize
    var centerX: CGFloat
    var hasNotch: Bool

    static let fallback = NotchMetrics(size: CGSize(width: 185, height: 32), centerX: 0, hasNotch: false)

    @MainActor
    init(screen: NSScreen) {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            size = CGSize(width: width, height: screen.safeAreaInsets.top)
            centerX = frame.minX + left.width + width / 2
            hasNotch = true
        } else {
            // No notch: draw a virtual one in the middle of the menu bar.
            let menuBarHeight = frame.maxY - screen.visibleFrame.maxY
            size = CGSize(width: Self.fallback.size.width, height: menuBarHeight > 0 ? menuBarHeight : 24)
            centerX = frame.midX
            hasNotch = false
        }
    }

    private init(size: CGSize, centerX: CGFloat, hasNotch: Bool) {
        self.size = size
        self.centerX = centerX
        self.hasNotch = hasNotch
    }
}

/// What the closed notch shows on each side, and how wide each side needs to be. Music puts
/// artwork left and bars right; a timer adds a ring left and its countdown right, like iOS.
/// (Oyls are out on the menu bar; see `WalkerOverlay`.)
struct CompactLayout {
    static let ringSize: CGFloat = 18
    static let gap: CGFloat = 8

    let showsMusic: Bool
    let timer: ReminderTimer?
    let art: CGFloat
    let inset: CGFloat

    init(notchHeight: CGFloat, showsMusic: Bool, timer: ReminderTimer?) {
        self.showsMusic = showsMusic
        self.timer = timer
        art = max(notchHeight - 12, 16)
        inset = (notchHeight - art) / 2 + 3
    }

    let countdownWidth: CGFloat = 46  // "59:59", or "72:00" for hours and minutes

    var isEmpty: Bool { !showsMusic && timer == nil }

    var wing: CGFloat {
        var left: CGFloat = 0, right: CGFloat = 0
        if showsMusic {
            left += art
            right += art
        }
        if timer != nil {
            left += (left > 0 ? Self.gap : 0) + Self.ringSize
            right += (right > 0 ? Self.gap : 0) + countdownWidth
        }
        return inset + max(left, right) + 10
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var metrics = NotchMetrics.fallback
    @Published var isHovering = false   // opened by the pointer
    @Published var isPopped = false     // pointer resting on the closed notch
    @Published var isEditing = false    // a text field has the keyboard
    @Published var isHeld = false       // a menu is open, so stay open
    @Published var page = NotchPage.music
    @Published var inFullscreen = false  // a fullscreen app is in front
    @Published var showsLyrics = false {  // under the song, when it has some
        didSet { if !showsLyrics { singing = false } }  // and its singer goes with them
    }
    @Published var singing = false       // an Oyl on the menu bar singing the lyrics
    @Published var selfie: Selfie?       // just taken: its Oyl holds it up for a bit
    /// Oyls (and the calendar bar) on the menu bar at all.
    @Published var oylsVisible = UserDefaults.standard.object(forKey: "oyls.visible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(oylsVisible, forKey: "oyls.visible") }
    }
    /// The menu bar goes 80% black behind the Oyls while the pointer's on it.
    @Published var dimsMenuBar = UserDefaults.standard.bool(forKey: "oyls.dimsMenuBar") {
        didSet { UserDefaults.standard.set(dimsMenuBar, forKey: "oyls.dimsMenuBar") }
    }

    let nowPlaying: NowPlaying
    let timers: TimerStore
    let awake: AwakeManager
    let agents: AgentMonitor
    let calendar: DayCalendar
    let power: PowerWatcher
    let bedtime: Bedtime
    /// Gives the keyboard back to the app you were using. Set by the controller.
    var resignKeyboard: () -> Void = {}
    private var forwarding: AnyCancellable?

    init(nowPlaying: NowPlaying, timers: TimerStore, awake: AwakeManager, agents: AgentMonitor, calendar: DayCalendar,
         power: PowerWatcher, bedtime: Bedtime) {
        self.nowPlaying = nowPlaying
        self.timers = timers
        self.awake = awake
        self.agents = agents
        self.calendar = calendar
        self.power = power
        self.bedtime = bedtime
        // The battery's Oyl is on the Oyls page, which redraws with this.
        forwarding = power.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// A timer's gone off or it's two in the morning: the notch pops open to say so.
    var isAlerting: Bool { timers.ringing != nil || bedtime.reminding }

    var mode: NotchMode {
        if !agents.approvals.isEmpty || isAlerting || isHovering || isEditing || isHeld { return .expanded }
        return compact.isEmpty ? .idle : .compact
    }

    /// Open for a timer that's done (or bedtime), rather than for the pointer.
    var isAnnouncing: Bool { isAlerting && !isHovering && agents.approvals.isEmpty }

    var compact: CompactLayout {
        CompactLayout(notchHeight: metrics.size.height,
                      showsMusic: nowPlaying.track != nil && nowPlaying.isPlaying,
                      timer: timers.next)
    }

    /// What Oyls are out on the menu bar for: each agent at work, the song (and singing it),
    /// each timer and reminder, staying awake, a low battery, a late night, a selfie; or with
    /// none of those, just to hang out.
    var oylJobs: [Walker.Job] {
        var jobs: [Walker.Job] = agents.working.map { .agent($0) }
        if nowPlaying.track != nil && nowPlaying.isPlaying {
            jobs.append(.music)
            if singing && nowPlaying.lyrics != nil { jobs.append(.singer) }
        }
        jobs += timers.timers.map { .timer($0) }
        if let mode = awake.mode { jobs.append(.awake(mode)) }
        if let status = power.status { jobs.append(.battery(status)) }
        if let stage = bedtime.stage { jobs.append(.bedtime(stage)) }
        if let selfie { jobs.append(.selfie(selfie)) }
        return jobs.isEmpty ? [.hangout] : jobs
    }

    /// Oyls whose work is done, as opposed to called off: agents that have finished, timers that
    /// have gone off, reminders ticked off. They cheer before they go.
    var finishedOyls: Set<String> {
        var finished = Set(agents.sessions.filter { $0.activity == .done }.map { "agent \($0.id)" })
        if let ringing = timers.ringing { finished.insert("timer \(ringing.id)") }
        for id in timers.resolved { finished.insert("timer \(id)") }
        if power.recharged { finished.insert("battery") }
        return finished
    }

    /// The Oyls page: every Oyl that's out, then agents taking a break.
    var oylRows: [Walker.Job] {
        let working = Set(agents.working.map(\.id))
        return oylJobs + agents.sessions.filter { !working.contains($0.id) }.map { .agent($0) }
    }

    var expandedWidth: CGFloat { max(Layout.expandedWidth, metrics.size.width + 2 * Layout.tabsWing) }

    /// The open notch's width. A timer's alarm, which has no tabs to fit, pops out 15% smaller
    /// than the notch would be with every tab standard width (Oyl's is wider).
    var openWidth: CGFloat {
        // (Bedtime's has more to say, so it keeps the full width.)
        guard timers.ringing != nil && agents.approvals.isEmpty else { return expandedWidth }
        return ((expandedWidth - 2 * (Layout.oylsTabWidth - Layout.tabWidth)) * 0.85).rounded()
    }

    /// Height of the open notch below the strip beside the hardware notch.
    var contentHeight: CGFloat {
        if !agents.approvals.isEmpty { return Layout.approvalHeight }
        if isAlerting { return Layout.alertHeight }
        switch page {
        case .music: return Layout.musicHeight + (showsLyrics && nowPlaying.lyrics != nil ? Layout.lyricsHeight : 0)
        case .timers: return Layout.timersHeight(rows: timers.timers.count)
        case .awake: return Layout.awakeHeight
        case .agents:
            // The calendar's Oyl has a row too, and the settings go under them all.
            return Layout.oylsHeight(rows: oylRows.count + 1) + Layout.oylSettingsHeight
                + (agents.offersChats ? Layout.chatsFooterHeight : 0)
        case .activity: return Layout.activityHeight
        }
    }

    /// Size of the notch body, excluding the flared top corners.
    func size(for mode: NotchMode) -> CGSize {
        let notch = metrics.size
        let pop = isPopped ? Layout.popGrowth : 0
        switch mode {
        case .idle:
            return CGSize(width: notch.width + pop, height: notch.height + pop)
        case .compact:
            return CGSize(width: notch.width + 2 * compact.wing + pop, height: notch.height + pop)
        case .expanded:
            return CGSize(width: openWidth, height: headerHeight + contentHeight)
        }
    }

    /// From the top of the open notch to its page: the strip beside the hardware notch with the
    /// tabs in it. In a fullscreen app that strip is left to the menu bar, which slides down over
    /// it, so the tabs get a row of their own below.
    var headerHeight: CGFloat {
        metrics.size.height + (inFullscreen ? Layout.fullscreenStripHeight : 0)
    }

    static func topRadius(_ mode: NotchMode) -> CGFloat {
        switch mode {
        case .idle: return 0
        case .compact: return 5
        case .expanded: return 11
        }
    }

    static func bottomRadius(_ mode: NotchMode) -> CGFloat {
        switch mode {
        case .idle: return 8
        case .compact: return 10
        case .expanded: return 22
        }
    }

    var windowSize: CGSize {
        let tallest = max(Layout.musicHeight + Layout.lyricsHeight, Layout.awakeHeight, Layout.alertHeight,
                          Layout.timersHeight(rows: Layout.maxVisibleTimers),
                          Layout.oylsHeight(rows: Layout.maxVisibleOyls) + Layout.oylSettingsHeight + Layout.chatsFooterHeight)
        return CGSize(width: expandedWidth + 2 * (Self.topRadius(.expanded) + Layout.shadowPadding),
                      height: metrics.size.height + Layout.fullscreenStripHeight + tallest + Layout.shadowPadding)
    }
}

final class NotchPanel: NSPanel {
    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .darkAqua)
    }

    // Only the reminder field asks for key status (becomesKeyOnlyIfNeeded), and the panel is
    // non-activating, so clicking buttons never takes the keyboard from the app you're in.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Sit over the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Whether a screen is showing a fullscreen app's Space. There's no public way to ask (the
/// system presentation options only describe Oyl's own app), so this uses the private call window
/// managers like yabai use, looked up at run time: if it ever goes away, the answer is just no.
enum FullscreenSpace {
    private typealias ConnectionID = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    private static let connection = dlsym(defaultHandle, "CGSMainConnectionID").map { unsafeBitCast($0, to: ConnectionID.self) }
    private static let copySpaces = dlsym(defaultHandle, "CGSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopySpaces.self) }
    private static let fullscreenType = 4

    /// Under a millisecond after the first call.
    static func isShowing(on screen: NSScreen) -> Bool {
        guard let connection, let copySpaces,
              let displays = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return false }
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let uuid = number.flatMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
            .map { CFUUIDCreateString(nil, $0) as String }
        // With "Displays have separate Spaces" off, there's one entry for all of them.
        let display = displays.first { $0["Display Identifier"] as? String == uuid } ?? (displays.count == 1 ? displays.first : nil)
        let current = display?["Current Space"] as? [String: Any]
        return current?["type"] as? Int == fullscreenType
    }
}

final class NotchHostingView: NSHostingView<NotchView> {
    // The panel is rarely key, so the first click has to reach the controls directly.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the overlay panel and decides when it pops and opens. Hover is tracked with event
/// monitors rather than tracking areas so the panel can ignore clicks outside the notch.
@MainActor
final class NotchController {
    private let panel = NotchPanel()
    private let state: NotchState
    private let gestures: GestureWatcher
    private let walkers = WalkerOverlay()
    private let stats = SystemStats()
    private var screen: NSScreen?
    private var pointerInside = false
    private var hoverWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    /// Things Oyls are to say once the open notch is out of the way (gestures are made over it).
    private var whenClosed: [() -> Void] = []

    init(nowPlaying: NowPlaying, timers: TimerStore, awake: AwakeManager, agents: AgentMonitor) {
        state = NotchState(nowPlaying: nowPlaying, timers: timers, awake: awake, agents: agents, calendar: DayCalendar(),
                           power: PowerWatcher(), bedtime: Bedtime())
        gestures = GestureWatcher()

        let hostingView = NotchHostingView(rootView: NotchView(state: state, nowPlaying: nowPlaying, timers: timers,
                                                               awake: awake, agents: agents, bedtime: state.bedtime,
                                                               gestures: gestures, stats: stats))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        updateScreen()
        panel.orderFrontRegardless()
        state.resignKeyboard = { [weak self] in self?.resignKeyboard() }

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScreen() }
        }
        // Fullscreen apps come and go with Spaces and with switching apps.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFullscreen() }
            }
        }
        updateFullscreen()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyStatusChanged() }
            }
        }

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            let released = event.type == .leftMouseUp
            MainActor.assumeIsolated { self?.pointerMoved(released: released) }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            let released = event.type == .leftMouseUp
            MainActor.assumeIsolated { self?.pointerMoved(released: released) }
            return event
        }) {
            monitors.append(monitor)
        }

        // Music, timers, agents and pages all change the notch's shape, and so where the hover
        // target is.
        Publishers.Merge6(nowPlaying.objectWillChange, timers.objectWillChange, awake.objectWillChange,
                          agents.objectWillChange, state.objectWillChange, state.bedtime.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self, self.state.mode != .expanded, !self.whenClosed.isEmpty {
                        let pending = self.whenClosed
                        self.whenClosed = []
                        pending.forEach { $0() }
                    }
                    self?.pointerMoved(released: false)
                    if let self {
                        self.state.nowPlaying.onScreen = self.state.mode == .expanded && self.state.page == .music
                    }
                    self?.closeIfAbandoned()
                }
            }
            .store(in: &cancellables)

        gestures.onGesture = { [weak self] gesture in
            guard let self else { return }
            // The Oyls on the menu bar's own gestures; the rest are the notch's.
            switch gesture {
            case .announce: self.onceClosed { [weak self] in self?.walkers.announce() }
            // Tipped left lines them up, tipped right sends them off; each undoes the other.
            case .tiltLeft:
                if self.state.oylsVisible { self.walkers.fling() } else { self.state.oylsVisible = true }
            case .tiltRight:
                if self.walkers.isLinedUp { self.walkers.scatter() } else { self.state.oylsVisible = false }
            default: self.state.perform(gesture)
            }
        }
        // A selfie: an Oyl holds it up, and pops it up big under the menu bar for a moment.
        gestures.onSelfie = { [weak self] url in
            guard let self, let image = NSImage(contentsOf: url) else { return }
            let selfie = Selfie(url: url, image: image)
            self.state.selfie = selfie
            self.castOyls()
            // The picture pops up once the notch closes and it can be seen; the Oyl stays a while after.
            self.onceClosed { [weak self] in
                // Unless another's been taken since.
                guard let self, self.state.selfie == selfie else { return }
                self.walkers.say("Nice one!", as: Walker.Job.selfie(selfie).id, for: 6, image: image)
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                    MainActor.assumeIsolated {
                        if self?.state.selfie == selfie { self?.state.selfie = nil }
                    }
                }
            }
        }
        gestures.onTurn = { [weak self] in self?.state.turn(by: $0) }
        gestures.onScrub = { [weak self] in self?.state.scrub(by: $0) }
        gestures.onApprove = { [weak agents] in
            guard let agents, let approval = agents.approvals.first else { return }
            agents.answer(approval, allow: true)
        }
        // A pinky out shows the lyrics, so it's only looked for when the song has some.
        nowPlaying.$lyrics
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] available in
                MainActor.assumeIsolated { self?.gestures.lyricsAvailable = available }
            }
            .store(in: &cancellables)
        // An agent waiting for your OK opens the notch, and the camera looks for a thumbs up.
        agents.$approvals
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] waiting in
                MainActor.assumeIsolated { self?.gestures.approving = waiting }
            }
            .store(in: &cancellables)
        // Oyls on the menu bar come and go with what the app's up to.
        Publishers.MergeMany([nowPlaying.objectWillChange, timers.objectWillChange, awake.objectWillChange,
                              agents.objectWillChange, state.objectWillChange, state.power.objectWillChange,
                              state.bedtime.objectWillChange].map { $0.eraseToAnyPublisher() })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.castOyls() }
            }
            .store(in: &cancellables)
        state.$oylsVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                MainActor.assumeIsolated {
                    self?.walkers.setShown(visible)
                    // Back out of the notch.
                    if visible { DispatchQueue.main.async { self?.castOyls() } }
                }
            }
            .store(in: &cancellables)
        state.$dimsMenuBar
            .sink { [weak self] dims in
                MainActor.assumeIsolated { self?.walkers.dimsBar = dims }
            }
            .store(in: &cancellables)
        walkers.onReveal = { agents.reveal($0) }
        walkers.onSelfie = { NSWorkspace.shared.open($0) }
        walkers.describe = { [weak self] job in self?.describe(job) ?? "" }
        walkers.describeCalendar = { [weak self] in self?.describeCalendar() ?? "" }
        walkers.walkers.lyricLine = { [weak nowPlaying] date in
            guard let nowPlaying, let lyrics = nowPlaying.lyrics else { return nil }
            // A touch early, as in the notch, so a line's up as it's sung.
            let position = nowPlaying.position(at: date) + 0.25
            return lyrics.lines.last { $0.time <= position }?.text
        }
        // The bedtime Oyl says what it's up to as the night goes on.
        state.bedtime.onStage = { [weak self] stage in
            let line: String
            switch stage {
            case .candle: line = "Still up? It's past midnight…"
            case .bed: line = "I'm off to bed. Night night!"
            case .remind: line = "It's 2 am. Time for bed!"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.walkers.say(line, as: "bedtime", for: 10) }
            }
        }
        // The calendar bar, and clicking it: to Google Calendar, or to what it needs to work.
        let calendar = state.calendar
        calendar.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.walkers.showCalendar(calendar.events, note: calendar.note) }
            }
            .store(in: &cancellables)
        walkers.showCalendar(calendar.events, note: calendar.note)
        walkers.onCalendar = { calendar.openSomewhere() }
        castOyls()
    }

    /// Runs `action` now if the notch is closed, else as soon as it closes.
    private func onceClosed(_ action: @escaping () -> Void) {
        if state.mode == .expanded { whenClosed.append(action) } else { action() }
    }

    /// What an Oyl says it's doing, when clicked or asked to.
    private func describe(_ job: Walker.Job) -> String {
        let now = Date()
        switch job {
        case .hangout:
            return "Just hanging out"
        case .agent(let session):
            return "\(session.project): \(session.summary)"
        case .music:
            return state.nowPlaying.track.map { "♪ \($0.title), by \($0.artist)" } ?? "♪"
        case .singer:
            return walkers.walkers.lyricLine(now).map { "♪ \($0)" } ?? "♪ La la la"
        case .timer(let timer) where timer.isEndless:
            return timer.label.isEmpty ? "A reminder, until it's done" : "Reminder: \(timer.label)"
        case .timer(let timer):
            return "\(timer.title): \(ReminderTimer.format(timer.remaining(at: now))) left" + (timer.isRunning ? "" : ", paused")
        case .awake(.until(let end)):
            return "Keeping your Mac awake, \(ReminderTimer.format(end.timeIntervalSince(now))) to go"
        case .awake(.whileRunning(_, let name)):
            return "Keeping your Mac awake while \(name) is open"
        case .awake(.indefinitely):
            return "Keeping your Mac awake till you stop me"
        case .battery(.tired(let percent)):
            return "So tired… the battery's at \(percent)%"
        case .battery(.recharging(let percent)):
            return "Recharging, \(percent)%"
        case .bedtime(.candle):
            return "It's past midnight…"
        case .bedtime(.bed):
            return "Zzz… I'm in bed"
        case .bedtime(.remind):
            return "Go to bed!"
        case .selfie:
            return "Nice selfie! Click to see it"
        }
    }

    private func describeCalendar() -> String {
        let calendar = state.calendar, now = Date()
        if let current = calendar.current(at: now) {
            return "\(current.title), till \(current.end.formatted(date: .omitted, time: .shortened))"
        }
        if let next = calendar.next(after: now) {
            let when = Calendar.current.isDateInToday(next.start)
                ? next.start.formatted(date: .omitted, time: .shortened)
                : next.start.formatted(.dateTime.weekday(.wide).hour().minute())
            return "Next: \(next.title), \(when)"
        }
        return calendar.note ?? "Nothing coming up"
    }

    /// Sends Oyls out on the menu bar for what's going on, or calls them back.
    private func castOyls() {
        guard let screen else { return }
        // They don't stop behind the closed notch (and what's beside it).
        let mode = state.mode == .expanded ? (state.compact.isEmpty ? NotchMode.idle : .compact) : state.mode
        let width = state.size(for: mode).width + 2 * NotchState.topRadius(mode)
        let middle = state.metrics.centerX
        walkers.cast(state.oylJobs, completed: state.finishedOyls, on: screen, notch: (middle - width / 2)...(middle + width / 2))
    }

    private func updateScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
        self.screen = screen
        let metrics = NotchMetrics(screen: screen)
        if state.metrics != metrics { state.metrics = metrics }

        let size = state.windowSize
        panel.setFrame(NSRect(x: metrics.centerX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        castOyls()
    }

    /// Whether a fullscreen app is in front: then the notch's tabs move down a row, and the
    /// pointer goes through to the menu bar along the top (see `updatePassThrough`).
    private func updateFullscreen() {
        let fullscreen = screen.map(FullscreenSpace.isShowing(on:)) ?? false
        if state.inFullscreen != fullscreen { state.inFullscreen = fullscreen }
    }

    /// The panel takes the pointer while it's over the notch, except, in a fullscreen app, along
    /// the top band. There the menu bar slides down when the pointer reaches the top, and follows
    /// the pointer to know when to slide back up; if the notch caught it, the bar never saw it
    /// leave and stayed down.
    private func updatePassThrough(at location: NSPoint) {
        let inBand = state.inFullscreen && location.y > (screen?.frame.maxY ?? 0) - state.metrics.size.height
        let ignores = !pointerInside || inBand
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    private func pointerMoved(released: Bool) {
        let rect = hoverRect()
        let location = NSEvent.mouseLocation
        walkers.pointerMoved(to: location)
        var inside = rect.contains(location)
        // Coming in, the pointer has to reach the top half of the closed notch, so passing just
        // under it doesn't open it. Once in, all of it counts.
        if inside, !pointerInside, state.mode != .expanded {
            inside = location.y >= rect.midY
            if inside { updateFullscreen() }
        }
        // Don't open while something is dragged across the notch, or close (or stop taking the
        // pointer) mid-drag.
        let dragging = !released && NSEvent.pressedMouseButtons != 0
        guard inside != pointerInside else {
            if !dragging { updatePassThrough(at: location) }
            return
        }
        if dragging { return }

        pointerInside = inside
        updatePassThrough(at: location)
        hoverWork?.cancel()
        if inside {
            // Like Atoll: the closed notch pops right away, then opens after a short rest.
            if state.mode != .expanded {
                state.isPopped = true
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
            // Back over a notch that hadn't closed yet.
            if state.isHovering { gestures.hovering = true }
            schedule(after: 0.3) { [weak self] in self?.open() }
        } else {
            // Gestures only count while the pointer is over the open notch, and the camera goes
            // off as soon as it leaves.
            gestures.hovering = false
            schedule(after: 0.15) { [weak self] in self?.close() }
        }
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
        let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func open() {
        guard pointerInside, !state.isHovering else { return }
        // Land on the page that has something to show.
        if state.page == .music && state.nowPlaying.track == nil {
            state.page = .timers
        } else if state.page == .timers && state.timers.timers.isEmpty && state.nowPlaying.track != nil {
            state.page = .music
        }
        state.isHovering = true
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        // Opening the notch watches the camera for hand gestures, until an OK or the pointer leaves.
        gestures.hovering = true
    }

    /// Leaving the notch closes it, even mid-typing: the keyboard goes back to the window you
    /// were in.
    private func close() {
        guard !pointerInside else { return }
        state.isPopped = false
        if state.isEditing { resignKeyboard() }
        state.isHovering = false
    }

    /// A menu or text field kept the notch open after the pointer left; close once it's done.
    private func closeIfAbandoned() {
        guard state.isHovering, !pointerInside, !state.isEditing, !state.isHeld,
              NSEvent.pressedMouseButtons == 0 else { return }
        close()
    }

    private func keyStatusChanged() {
        state.isEditing = panel.isKeyWindow
        // Finished typing after the pointer already left: close now.
        if !state.isEditing && !pointerInside {
            state.isPopped = false
            state.isHovering = false
        }
    }

    private func resignKeyboard() {
        guard panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        // Ordering out drops key status, so typing goes back to the app you were using.
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// The visible notch shape in screen coordinates.
    private func hoverRect() -> NSRect {
        guard let screen else { return .zero }
        let mode = state.mode
        var size = state.size(for: mode)
        size.width += 2 * NotchState.topRadius(mode)
        if mode == .expanded { size.height += 6 }
        // +1 so the very top row of pixels counts as inside.
        return NSRect(x: state.metrics.centerX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height + 1)
    }
}
