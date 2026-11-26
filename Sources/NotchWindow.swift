import AppKit
import Combine
import SwiftUI

enum Layout {
    static let expandedWidth: CGFloat = 440
    static let artSize: CGFloat = 94
    static let musicHeight: CGFloat = 8 + artSize + 22   // page content below the notch strip
    static let lyricsHeight: CGFloat = 74                // three lines of lyrics under the song
    /// (With a row under Claude's tokens for what they'd cost, and one for its 5-hour window.)
    static var activityHeight: CGFloat { 172 + (Feature.claudeLimit.isOn ? 24 : 0) + (Feature.commitTimeline.isOn ? 24 : 0) }
    /// The system's part of it, over Claude's rows.
    static let activitySystemHeight: CGFloat = 172 - 22 - 24
    /// GitHub's grid, under them (and the gap over it): a row of months, then seven of days.
    static let githubHeight: CGFloat = 54
    static var activityWithGitHub: CGFloat { activityHeight + 8 + githubHeight }
    static let mirrorSize = CGSize(width: 240, height: 180)  // the camera's 4:3, about the size it's taken at
    static var mirrorHeight: CGFloat { 8 + mirrorSize.height + 16 }
    static let awakeHeight: CGFloat = 146
    static let alertHeight: CGFloat = 72
    static let timerRowHeight: CGFloat = 30
    static let maxVisibleTimers = 3                      // at least; as many as fit (see `timerRowsFit`)
    static let oylRowHeight: CGFloat = 34
    static let maxVisibleOyls = 4
    static let chatsFooterHeight: CGFloat = 26
    // The settings page: its sections, then its settings two to a row, then the motto.
    static let settingsChipsHeight: CGFloat = 22
    static let settingsGap: CGFloat = 8
    static let settingsRowHeight: CGFloat = 22
    static let settingsRowsFit = 7
    static let settingsMottoHeight: CGFloat = 26
    /// The rows a phone's pairing card takes on the settings page.
    static let pairingRows = 5
    /// The ideas page: an idea's row, the heading over each kind, and as many rows as show before
    /// they scroll.
    static let ideaRowHeight: CGFloat = 24
    static let ideaHeaderHeight: CGFloat = 18
    static let maxVisibleIdeaRows = 6
    static func ideasHeight(list: CGFloat) -> CGFloat { 6 + 28 + 10 + list + 14 }
    static func settingsRows(_ rows: Int) -> CGFloat { CGFloat(rows) * settingsRowHeight }
    static func settingsHeight(rows: Int) -> CGFloat {
        6 + settingsChipsHeight + settingsGap + settingsRows(min(rows, settingsRowsFit)) + settingsMottoHeight + 12
    }
    /// The Oyls tab's settings: the Oyls' row, then the look's.
    static func oylSettingsHeight(rows: Int) -> CGFloat { 22 * CGFloat(rows) }
    static let fullscreenStripHeight: CGFloat = 28       // the tabs' row, under the menu bar's band
    static let popGrowth: CGFloat = 8                    // how far the closed notch pops on hover
    static let shadowPadding: CGFloat = 30
    static let stripPadding: CGFloat = 20                // left of the page tabs
    static let tabWidth: CGFloat = 26
    static let oylsTabWidth: CGFloat = 38                // wider, for Oyl

    /// What `count` page tabs need left of the hardware notch: padding, the tabs, then a gap.
    static func tabsWing(tabs count: Int) -> CGFloat {
        let count = CGFloat(count)
        return stripPadding + (count - 1) * tabWidth + oylsTabWidth + (count - 1) * 2 + 4 + 8
    }

    /// The Timers page, its list `list` tall.
    static func timersHeight(list: CGFloat) -> CGFloat { 6 + 28 + 10 + list + 16 }

    /// `rows` timers' rows, each one line high (a long name wraps onto more); with none, the hint.
    static func timerRows(_ rows: Int) -> CGFloat {
        rows == 0 ? 20 : CGFloat(rows) * timerRowHeight + CGFloat(rows - 1) * 4
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

enum NotchPage {
    case music, timers, ideas, inbox, awake, agents, activity, mirror
    /// Every setting, from the Oyls page (or a right-click on the notch); it has no tab.
    case settings
}

struct NotchMetrics: Equatable {
    var size: CGSize
    var centerX: CGFloat
    var hasNotch: Bool
    /// From the top of the screen down to the Dock (or the bottom), for the open notch to grow into.
    var room: CGFloat
    /// The screen's width, which Midnight Oyl's bloom has to fit in.
    var screenWidth: CGFloat

    static let fallback = NotchMetrics(size: CGSize(width: 185, height: 32), centerX: 0, hasNotch: false, room: 600,
                                       screenWidth: 1440)

    @MainActor
    init(screen: NSScreen) {
        let frame = screen.frame
        room = frame.maxY - screen.visibleFrame.minY
        screenWidth = frame.width
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

    private init(size: CGSize, centerX: CGFloat, hasNotch: Bool, room: CGFloat, screenWidth: CGFloat) {
        self.size = size
        self.centerX = centerX
        self.hasNotch = hasNotch
        self.room = room
        self.screenWidth = screenWidth
    }
}

/// What the closed notch shows on each side, and how wide each side needs to be: while Wispr Flow
/// takes down what you say, a microphone left and your voice right. (The song, timers, agents and
/// the rest are Oyls out on the menu bar; see `WalkerOverlay`.)
/// What the right Shift's camera sees, for the closed notch: the shape, once it's steady, and the
/// gesture it's just acted on.
struct GestureWatch: Equatable {
    var seen: HandGesture?
    var acted: HandGesture?
}

struct CompactLayout {
    let dictating: Bool
    /// The timer held on the notch, while nothing's being dictated.
    let focus: ReminderTimer?
    /// The right Shift held, the camera on: what it sees (over a held timer, while nothing's
    /// being dictated).
    let watch: GestureWatch?
    let art: CGFloat
    let inset: CGFloat

    init(notchHeight: CGFloat, dictating: Bool, focus: ReminderTimer? = nil, watch: GestureWatch? = nil) {
        self.dictating = dictating
        self.watch = dictating ? nil : watch
        self.focus = dictating || watch != nil ? nil : focus
        art = max(notchHeight - 12, 16)
        inset = (notchHeight - art) / 2 + 3
    }

    var isEmpty: Bool { !dictating && focus == nil && watch == nil }

    /// How far it reaches either side of the notch: for a timer, room for its name and its time;
    /// for what the camera sees, a symbol of its shape and one of what it does.
    var wing: CGFloat { watch != nil ? Self.watchWing : focus != nil ? Self.timerWing : inset + (isEmpty ? 0 : art) + 10 }
    static let timerWing: CGFloat = 70
    static let watchWing: CGFloat = 40
}

@MainActor
final class NotchState: ObservableObject {
    @Published var metrics = NotchMetrics.fallback
    @Published var isHovering = false   // opened by the pointer
    @Published var isPopped = false     // pointer resting on the closed notch
    @Published var isEditing = false    // a text field has the keyboard
    @Published var isHeld = false       // a menu is open, so stay open
    @Published var isRevealing = false  // opened by a click on an Oyl, for a moment
    @Published var isResting = false    // the lid's shut with no other screen, or Oyl's off: nothing's drawn
    @Published var isOff = false        // switched off by three taps of control, till three more
    @Published var isViewingDesktops = false  // Mission Control's up: the top of the screen is its
    @Published var isTakingShot = false  // an area's being picked out for an idea's screenshot: out of the way
    /// The right Shift's held, the camera on for gestures: what it sees, on the closed notch.
    @Published var watching: GestureWatch?
    /// The timer to pick out on its page: its Oyl on the menu bar was just clicked.
    @Published var pickedTimer: UUID?
    @Published var page = NotchPage.music
    /// How tall the timers' rows stand, and for how many: a long name wraps, so they're measured
    /// as they're laid out (see `TimersPage`).
    @Published var timerRowsMeasure: (count: Int, height: CGFloat)?
    /// The settings' section showing.
    @Published var settingsSection = SettingsSection.notch
    /// What could be watched as an agent in the app in front (its tab's site, in a browser),
    /// worked out as the pointer comes to the notch.
    @Published var front: RadarAgent?
    @Published var inFullscreen = false  // a fullscreen app is in front
    /// The lyrics: under the song in the notch (and, with `showsLyricsClosed`, on the menu bar),
    /// for every song that has some, until they're turned off (a song without any in between just
    /// shows none). Remembered across launches.
    @Published var showsLyrics = UserDefaults.standard.bool(forKey: "music.lyrics") {
        didSet { UserDefaults.standard.set(showsLyrics, forKey: "music.lyrics") }
    }
    /// The lyrics on the menu bar too, in either look: in Oyl's, sung line by line by the music
    /// Oyl (off, it DJs instead); in Midnight Oyl's, beside the closed notch (see `ClosedLyrics`).
    /// Off at first.
    @Published var showsLyricsClosed = UserDefaults.standard.bool(forKey: "music.lyricsClosed") {
        didSet { UserDefaults.standard.set(showsLyricsClosed, forKey: "music.lyricsClosed") }
    }
    @Published var selfie: Selfie?       // just taken: its Oyl holds it up for a bit
    /// Oyls (and the calendar bar) on the menu bar at all.
    @Published var oylsVisible = UserDefaults.standard.object(forKey: "oyls.visible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(oylsVisible, forKey: "oyls.visible") }
    }
    /// The menu bar goes 80% black behind the Oyls, fullscreen app or not.
    @Published var dimsMenuBar = UserDefaults.standard.bool(forKey: "oyls.dimsMenuBar") {
        didSet { UserDefaults.standard.set(dimsMenuBar, forKey: "oyls.dimsMenuBar") }
    }
    /// The look: Oyl's own, or Midnight Oyl (see `Midnight`). Remembered.
    @Published var theme = NotchTheme(rawValue: UserDefaults.standard.string(forKey: "notch.theme") ?? "") ?? .standard {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "notch.theme")
            if theme != .midnight { isPinned = false }
            // Midnight Oyl has no camera page: it shows the hands, always, and no picture.
            if theme == .midnight, page == .mirror { page = .music }
        }
    }
    /// Oyl's own Dock along the bottom, over the macOS Dock (see `DockController`).
    @Published var showsDock = UserDefaults.standard.object(forKey: "dock.shown") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsDock, forKey: "dock.shown") }
    }
    /// Midnight Oyl held open, to be looked at (its moon clicked), till it's clicked again.
    @Published var isPinned = false
    /// The mirror's tab, a camera preview, among the notch's pages.
    @Published var showsMirror = UserDefaults.standard.object(forKey: "notch.mirror") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsMirror, forKey: "notch.mirror")
            if !showsMirror, page == .mirror { page = .agents }
        }
    }
    /// The Oyls' countdowns beside them, all the time; off, only in their last three minutes.
    @Published var showsCountdowns = UserDefaults.standard.object(forKey: "oyls.countdowns") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsCountdowns, forKey: "oyls.countdowns") }
    }

    let nowPlaying: NowPlaying
    let timers: TimerStore
    let awake: AwakeManager
    let agents: AgentMonitor
    let power: PowerWatcher
    let bedtime: Bedtime
    let dictation: Dictation
    /// Apps taking notes (Granola), each with an Oyl writing it down.
    let notes = NoteTakers()
    /// The hand gestures, for their settings. Set by the controller.
    weak var gestures: GestureWatcher?
    /// Recent screenshots, and what's just been saved, and files kept on either to convert or drag out.
    let shelf = Shelf()
    /// Gives the keyboard back to the app you were using. Set by the controller.
    var resignKeyboard: () -> Void = {}
    /// Takes a screenshot for the idea being jotted. Set by the controller.
    var takeIdeaShot: () -> Void = {}
    /// What's being jotted on the ideas page, kept while the notch is closed, and the screenshots
    /// ideas are about.
    let ideaDraft = IdeaDraft()
    let ideaPictures = IdeaPictures()
    /// Your projects, as an outline (see `ProjectStore`), in a window of its own (right-click the
    /// notch: Projects…), and how to open it (at a line, if it's given). Set by the controller.
    let projects = ProjectStore()
    var openProjects: (String?) -> Void = { _ in }
    /// What's being typed into the inbox page, kept while the notch is closed.
    let inboxDraft = LocalState("")
    /// The phone remote: the notch worked from a phone's browser (see `PhoneRemote`).
    private(set) lazy var phone = PhoneRemote(controls: NotchPhoneControls(state: self))
    /// tod's lists and tasks (its brain dump's the ideas page), shared with tod; or, with toyl
    /// here and its setting on, toyl's (see `TodStore.source`).
    let tod = TodStore()
    private var todForwarding: AnyCancellable?
    private var timerMirroring: AnyCancellable?
    private var sourceSwitch: AnyCancellable?
    private var projectsForwarding: AnyCancellable?
    private var forwarding: AnyCancellable?
    private var phoneForwarding: AnyCancellable?

    init(nowPlaying: NowPlaying, timers: TimerStore, awake: AwakeManager, agents: AgentMonitor,
         power: PowerWatcher, bedtime: Bedtime, dictation: Dictation) {
        self.nowPlaying = nowPlaying
        self.timers = timers
        self.awake = awake
        self.agents = agents
        self.power = power
        self.bedtime = bedtime
        self.dictation = dictation
        // The battery's Oyl is on the Oyls page, which redraws with this; dictating changes the
        // closed notch.
        forwarding = Publishers.Merge4(power.objectWillChange, dictation.objectWillChange, Features.shared.objectWillChange,
                                       AgentRadar.shared.objectWillChange.merge(with: notes.objectWillChange))
            .sink { [weak self] _ in self?.objectWillChange.send() }
        // toyl's timers on the notch too, and what's done to them here back in toyl's file.
        timerMirroring = tod.$toylTimers.sink { [weak self] mirrored in
            MainActor.assumeIsolated { self?.timers.mirror(mirrored) }
        }
        timers.onMirroredChange = { [weak self] change in self?.tod.saveToylTimer(change) }
        // With toyl, one timer system: new ones start in toyl (a half hour if no time's said),
        // and show here from toyl's file.
        timers.startsElsewhere = { [weak self] duration, label, pin in
            self?.tod.startToylTimer(duration: duration, label: label, pin: pin)
        }
        timers.usualLength = { [weak self] in self?.usesToyl == true ? 30 * 60 : nil }
        // The outline's reminders are for the outline, which toyl's list stands in for.
        projects.isReminding = { [weak self] in self?.usesToyl != true }
        // A page turned off while it's showing: to Oyl's own. toyl's setting turned on or off:
        // its list, or tod's.
        pageSwitch = Features.shared.changed
            .sink { [weak self] change in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if change.0 == .useToyl { self.tod.lookAgain() }
                    if !self.shows(self.page) { self.page = .agents }
                }
            }
        // toyl's list come or gone: the outline goes or comes back.
        sourceSwitch = tod.$source.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !self.shows(self.page) { self.page = .agents }
                    self.onSourceChange()
                }
            }
        }
    }

    /// toyl's list is the one in use (toyl's here, with its setting on): it stands in for Oyl's
    /// own projects outline, timers and to-dos.
    var usesToyl: Bool { tod.source == .toyl }

    /// The projects outline (its window, and its reminders): Oyl's own, so not while it's toyl's.
    var showsProjects: Bool { Feature.projectsPage.isOn && !usesToyl }

    /// Told when the list in use changes (to put away the outline's window). Set by the controller.
    var onSourceChange: () -> Void = {}

    private var pageSwitch: AnyCancellable?

    /// Starts the phone remote, if it's on, and redraws the settings as it changes.
    func startPhone() {
        phoneForwarding = phone.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // The ideas and inbox pages' heights go by what's on them.
        todForwarding = tod.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // An outline reminder opens the notch.
        projectsForwarding = projects.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// The ideas' rows as tall as they stand (each kind under its heading), and as much of that as
    /// shows before they scroll; with none, room for the hint.
    ///
    /// It's asked on every move of the pointer while the notch is open (for where it reaches), and
    /// making the rows to measure them (their dates said, sorted) takes about a millisecond with a
    /// couple of hundred ideas. So it's kept till tod's lists or ideas change, or the day does
    /// (which is all that sorts them into coming up and later).
    var ideaRowsHeight: CGFloat {
        let day = IdeaQuick.calendar.startOfDay(for: Date())
        if let kept = ideaHeight, kept.day == day, kept.tasks == tod.tasks, kept.lists == tod.lists { return kept.height }
        let height = IdeaBoard.height(of: IdeaBoard.rows(tod.ideas, aims: tod.hasAims))
        ideaHeight = (tod.tasks, tod.lists, day, height)
        return height
    }
    private var ideaHeight: (tasks: [TodStore.Task], lists: [TodStore.List], day: Date, height: CGFloat)?

    var ideaListHeight: CGFloat {
        min(ideaRowsHeight, CGFloat(Layout.maxVisibleIdeaRows) * Layout.ideaRowHeight + 2 * Layout.ideaHeaderHeight)
    }

    /// The inbox page's list: its open tasks, as far as they show before they scroll.
    var inboxListHeight: CGFloat {
        min(InboxLayout.height(rows: tod.inbox.count), CGFloat(Layout.maxVisibleIdeaRows) * Layout.ideaRowHeight)
    }

    /// The pages with tabs, in order: Oyl's own (always), then those turned on, then the settings
    /// (always).
    var tabs: [NotchPage] {
        [.agents, .music, .timers, .ideas, .inbox, .awake, .activity, .mirror, .settings].filter(shows)
    }

    /// Whether `page` is one of the notch's now (Oyl's and the settings always are).
    func shows(_ page: NotchPage) -> Bool {
        switch page {
        case .agents, .settings: return true
        case .music: return Feature.musicPage.isOn
        case .timers: return Feature.timersPage.isOn
        case .ideas: return Feature.ideasPage.isOn
        case .inbox: return Feature.inboxPage.isOn
        case .awake: return Feature.awakePage.isOn
        case .activity: return Feature.activityPage.isOn
        case .mirror: return showsMirrorTab
        }
    }

    /// A timer's gone off, a task's time has come, or it's two in the morning: the notch pops open
    /// to say so.
    var isAlerting: Bool {
        timers.ringing != nil || bedtime.reminding || (showsProjects && projects.ringing != nil)
    }

    var mode: NotchMode {
        if isAlerting || isHovering || isEditing || isHeld || isRevealing { return .expanded }
        // Midnight Oyl pinned open, on display (but not over Mission Control's desktops).
        if isPinned && theme == .midnight && !isViewingDesktops && !isTakingShot { return .expanded }
        return closedMode
    }

    /// What the notch is when it isn't open.
    var closedMode: NotchMode { compact.isEmpty ? .idle : .compact }

    /// Open in Midnight Oyl: bloomed far down the screen, in place of the black open notch.
    var isBlooming: Bool { theme == .midnight && mode == .expanded }

    /// Midnight Oyl's band: the screen's whole width, edge to edge over the menu bar (the panel's
    /// centered on the notch, which is the screen's middle), and as deep as it ever goes, or as
    /// the screen has room for.
    var bloomSize: CGSize {
        CGSize(width: metrics.screenWidth, height: min(Midnight.bandDepth, metrics.room - 20))
    }

    /// How far down Midnight Oyl's band reaches for what it's showing, in points from the top of
    /// the screen: the page, and some sky under it, so a short page makes a shallow band and a
    /// tall one a deep one; and further, while the lyrics float in that sky. Never past `bloomSize`.
    var bloomReach: CGFloat { bloomReach(page: headerHeight + contentHeight) }

    /// `bloomReach`, with the page's height (`headerHeight + contentHeight`) already worked out.
    func bloomReach(page height: CGFloat) -> CGFloat {
        let sky = Midnight.sky + (floatsLyrics ? Midnight.lyricsSky : 0)
        return min(max(height + sky, Midnight.shallowest), bloomSize.height)
    }

    /// Open for a timer that's done (or bedtime), rather than for the pointer.
    var isAnnouncing: Bool { isAlerting && !isHovering }

    var compact: CompactLayout {
        CompactLayout(notchHeight: metrics.size.height, dictating: dictation.isListening && Feature.wisprFlow.isOn,
                      focus: Feature.timersPage.isOn ? timers.focusedTimer : nil, watch: watching)
    }

    /// What Oyls are out on the menu bar for: each agent at work, the song (sung along to),
    /// each timer and reminder, staying awake, a low battery, a late night, a selfie; or with
    /// none of those, just to hang out.
    var oylJobs: [Walker.Job] {
        // Each kind turned off stays in.
        var jobs: [Walker.Job] = Feature.agentOyls.isOn ? agents.working.map { .agent($0) } : []
        if let track = nowPlaying.track, nowPlaying.isPlaying, Feature.musicOyl.isOn {
            // It sings along (in Oyl's look, line by line on the bar) only with the lyrics on the bar;
            // a moyl's rings glint while there are lyrics, its lyrics beside the notch being their own.
            let sings = showsLyrics && nowPlaying.lyrics != nil && (theme == .midnight || showsLyricsClosed)
            let listening: OylDuty.Listening = track.isAudiobook ? .reading : sings ? .singing : .dj
            jobs.append(.music(cover: nowPlaying.artwork, listening: listening))
        }
        if Feature.timerOyls.isOn { jobs += timers.timers.map { .timer($0) } }
        jobs += notes.taking.map { .notes($0) }
        if let mode = awake.mode, Feature.awakeOyl.isOn { jobs.append(.awake(mode)) }
        if let status = power.status, Feature.batteryOyl.isOn { jobs.append(.battery(status)) }
        if let stage = bedtime.stage { jobs.append(.bedtime(stage)) }
        if let selfie, Feature.selfieOyl.isOn { jobs.append(.selfie(selfie)) }
        return jobs.isEmpty && Feature.hangoutOyl.isOn ? [.hangout] : jobs
    }

    /// Oyls whose work is done, as opposed to called off: agents that have finished, timers that
    /// have gone off. They cheer before they go.
    var finishedOyls: Set<String> {
        var finished = Set(agents.sessions.filter { $0.activity == .done }.map { "agent \($0.id)" })
        if let ringing = timers.ringing { finished.insert("timer \(ringing.id)") }
        if power.recharged { finished.insert("battery") }
        return finished
    }

    /// The Oyls page: every Oyl that's out, then agents taking a break.
    var oylRows: [Walker.Job] {
        let working = Set(agents.working.map(\.id))
        return oylJobs + agents.sessions.filter { !working.contains($0.id) }.map { .agent($0) }
    }

    /// How many rows the Oyls page has: those, then timers that have gone off, and the calendar's.
    var oylRowCount: Int { oylRows.count + timers.history.count }
    /// A line under the Oyls page: asking to read the Claude app's chats, or offering to watch an
    /// app that seems to use AI.
    var hasOylsFooter: Bool { agents.offersChats || !AgentRadar.shared.suggestions.isEmpty }
    /// Midnight Oyl has no calendar bar, so no row of its settings.
    var oylSettingsRows: Int { 2 }

    var expandedWidth: CGFloat { max(Layout.expandedWidth, metrics.size.width + 2 * Layout.tabsWing(tabs: tabs.count)) }

    /// The open notch's width. A timer's alarm, which has no tabs to fit, pops out 15% smaller
    /// than the notch would be with every tab standard width (Oyl's is wider).
    var openWidth: CGFloat {
        // (Bedtime's has more to say, so it keeps the full width.)
        guard timers.ringing != nil else { return expandedWidth }
        return ((expandedWidth - 2 * (Layout.oylsTabWidth - Layout.tabWidth)) * 0.85).rounded()
    }

    /// Height of the open notch below the strip beside the hardware notch.
    var contentHeight: CGFloat {
        if isAlerting { return Layout.alertHeight }
        switch page {
        case .music:
            // (In Midnight Oyl the lyrics float in the sky under the page instead; see `bloomReach`.)
            return Layout.musicHeight + (showsLyrics && nowPlaying.lyrics != nil && theme != .midnight ? Layout.lyricsHeight : 0)
        case .timers: return Layout.timersHeight(list: timerListHeight)
        case .ideas: return Layout.ideasHeight(list: ideaListHeight)
        case .inbox: return Layout.ideasHeight(list: inboxListHeight)
        case .awake: return Layout.awakeHeight
        case .agents:
            // The settings go under them all.
            return Layout.oylsHeight(rows: oylRowCount) + Layout.oylSettingsHeight(rows: oylSettingsRows)
                + (hasOylsFooter ? Layout.chatsFooterHeight : 0)
        case .activity: return Feature.githubGrid.isOn ? Layout.activityWithGitHub : Layout.activityHeight
        case .mirror: return Layout.mirrorHeight
        case .settings:
            let rows = (SettingsPage.items(settingsSection, state: self).count + 1) / 2
            // Pairing a phone, its card in their place, big enough for its code to be scanned.
            return Layout.settingsHeight(rows: SettingsPage.showsPairing(self) ? max(rows, Layout.pairingRows) : rows)
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
            if theme == .midnight { return bloomSize }
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

    /// How many timers the Timers page shows before the rest scroll: as many as there's room for
    /// between the notch and the Dock, and three at least. In Midnight Oyl's band, which is kept
    /// shallow, just the three.
    var timerRowsFit: Int {
        if theme == .midnight { return Layout.maxVisibleTimers }
        let around = headerHeight + Layout.timersHeight(list: 0) + Layout.shadowPadding + 12
        return max(Layout.maxVisibleTimers, Int((metrics.room - around + 4) / (Layout.timerRowHeight + 4)))
    }

    /// The timers' rows as tall as they stand (as last measured, for as many as there are now),
    /// up to `timerRowsFit` one-line rows' worth: past that, they scroll.
    var timerRowsHeight: CGFloat {
        let count = timers.timers.count
        guard let measure = timerRowsMeasure, measure.count == count, count > 0 else { return Layout.timerRows(count) }
        return measure.height
    }

    var timerListHeight: CGFloat { min(timerRowsHeight, Layout.timerRows(max(timerRowsFit, 1))) }

    var windowSize: CGSize {
        let tallest = max(Layout.musicHeight + Layout.lyricsHeight, Layout.awakeHeight, Layout.alertHeight, Layout.mirrorHeight,
                          Layout.activityWithGitHub,
                          Layout.timersHeight(list: max(timerListHeight, Layout.timerRows(Layout.maxVisibleTimers))),
                          Layout.oylsHeight(rows: Layout.maxVisibleOyls) + Layout.oylSettingsHeight(rows: 3) + Layout.chatsFooterHeight,
                          Layout.settingsHeight(rows: Layout.settingsRowsFit),
                          Layout.ideasHeight(list: CGFloat(Layout.maxVisibleIdeaRows) * Layout.ideaRowHeight + 2 * Layout.ideaHeaderHeight))
        let size = CGSize(width: expandedWidth + 2 * (Self.topRadius(.expanded) + Layout.shadowPadding),
                          height: metrics.size.height + Layout.fullscreenStripHeight + tallest + Layout.shadowPadding)
        guard theme == .midnight else { return size }
        // The band, the screen's width, and the room under it for what spills past its foot.
        let bloom = bloomSize
        return CGSize(width: max(size.width, bloom.width + 2 * Midnight.overflow.side),
                      height: max(size.height, bloom.height + max(Layout.shadowPadding, Midnight.overflow.below)))
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
        canHide = false
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditKeys.perform(event) || super.performKeyEquivalent(with: event)
    }
}

/// Cut, copy, paste, select all, undo and redo, from the keyboard, and Command-period for the
/// emoji picker (as `KeyTap` brings it up in other apps). They're the Edit menu's, and Oyl has no
/// menu bar, so nothing would answer them: they're sent to whatever's typing instead.
@MainActor
enum EditKeys {
    static func perform(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.type == .keyDown, modifiers == .command || modifiers == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shifted = modifiers.contains(.shift)
        let action: Selector
        switch key {
        case "x" where !shifted: action = #selector(NSText.cut(_:))
        case "c" where !shifted: action = #selector(NSText.copy(_:))
        case "v" where !shifted: action = #selector(NSText.paste(_:))
        case "a" where !shifted: action = #selector(NSText.selectAll(_:))
        case "z": action = shifted ? Selector(("redo:")) : Selector(("undo:"))
        case "." where !shifted && Feature.emojiKey.isOn: action = #selector(NSApplication.orderFrontCharacterPalette(_:))
        default: return false
        }
        return NSApp.sendAction(action, to: nil, from: nil)
    }
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
    static let fullscreenType = 4

    /// Under a millisecond after the first call.
    static func isShowing(on screen: NSScreen) -> Bool {
        let current = display(for: screen)?["Current Space"] as? [String: Any]
        return current?["type"] as? Int == fullscreenType
    }

    /// `screen`'s Spaces as the window server lists them: "Current Space", the one showing, and
    /// "Spaces", all of them in order, each with its "type" (0 a desktop, 4 a fullscreen app's),
    /// "ManagedSpaceID", "uuid" and (a fullscreen app's) "pid" and "fs_wid", its window.
    static func display(for screen: NSScreen) -> [String: Any]? {
        guard let connection, let copySpaces,
              let displays = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let uuid = number.flatMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
            .map { CFUUIDCreateString(nil, $0) as String }
        // With "Displays have separate Spaces" off, there's one entry for all of them.
        return displays.first { $0["Display Identifier"] as? String == uuid } ?? (displays.count == 1 ? displays.first : nil)
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
    private let closedLyrics: ClosedLyrics
    private var dock: DockController?
    private var spaceLabel: SpaceLabel?
    private var pictureInPicture: PictureInPicture?
    /// Four fingers up: the desktops in a list (see `DesktopsViewer`), while it's on.
    private var desktops: DesktopsViewer?
    /// The outline of every project, once it's been opened.
    private var projectsWindow: ProjectsWindowController?
    private var controlTaps: TapWatcher?
    private var commandTaps: TapWatcher?
    private var shiftTaps: TapWatcher?
    private var shiftHold: HoldWatcher?
    private var optionHold: HoldWatcher?
    private var keyTap: KeyTap?
    private var cameraTaps: TapWatcher?
    private var missionControl: MissionControl?
    /// What's left of Claude's 5-hour window, on the bar beside the notch.
    private var barLimit: BarLimit?
    /// Your desktops' groups, marked over Mission Control while it's open.
    private let missionGroups = MissionGroups()
    /// A sound as a Claude finishes, or starts waiting for you.
    private let chimes = AgentChimes()
    /// The lid's shut with no other screen on.
    private var isShut = false
    private let stats = SystemStats()
    private var screen: NSScreen?
    private var pointerInside = false
    private var hoverWork: DispatchWorkItem?
    private var revealWork: DispatchWorkItem?
    private var shrinking: DispatchWorkItem?
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    /// Things Oyls are to say once the open notch is out of the way (gestures are made over it).
    private var whenClosed: [() -> Void] = []

    init(nowPlaying: NowPlaying, timers: TimerStore, awake: AwakeManager, agents: AgentMonitor) {
        state = NotchState(nowPlaying: nowPlaying, timers: timers, awake: awake, agents: agents,
                           power: PowerWatcher(), bedtime: Bedtime(), dictation: Dictation())
        state.startPhone()
        gestures = GestureWatcher()
        closedLyrics = ClosedLyrics(nowPlaying: nowPlaying)

        let hostingView = NotchHostingView(rootView: NotchView(state: state, nowPlaying: nowPlaying, timers: timers,
                                                               awake: awake, agents: agents, bedtime: state.bedtime,
                                                               gestures: gestures, stats: stats))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        // The Oyls' settings before any are sent out (the sinks below keep them up to date):
        // hidden, none come out at launch, and any wanted meanwhile wait till they're called back.
        // In Midnight Oyl they're moyls.
        walkers.theme = state.theme
        walkers.setShown(state.oylsVisible)
        walkers.dimsBar = state.dimsMenuBar
        walkers.showsCountdowns = state.showsCountdowns
        // A sound as a Claude finishes, or starts waiting for you (with it turned on).
        agents.$sessions
            .sink { [weak self] sessions in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.chimes.update(sessions, theme: self.state.theme, isOff: self.state.isOff)
                }
            }
            .store(in: &cancellables)
        // Claude's 5-hour window (on the usage page), read again soon once a Claude that was
        // working is done.
        agents.$sessions
            .map { $0.filter { $0.isClaude && $0.activity.priority > 1 }.count }
            .removeDuplicates()
            .scan((0, 0)) { ($0.1, $1) }
            .sink { counts in
                MainActor.assumeIsolated { if counts.1 < counts.0 { ClaudeLimit.shared.nudge() } }
            }
            .store(in: &cancellables)
        // The desktops' list's marks of agents at work, kept up as they start and stop.
        agents.$sessions
            .map { $0.filter { AgentLife.isAtIt($0.activity) }.map(\.id) }
            .removeDuplicates()
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.desktops?.agentsChanged() } }
            .store(in: &cancellables)
        updateScreen()
        panel.orderFrontRegardless()
        state.resignKeyboard = { [weak self] in self?.resignKeyboard() }
        state.takeIdeaShot = { [weak self] in self?.takeShot(for: .ideas) }
        state.openProjects = { [weak self] id in self?.openProjects(at: id) }
        // toyl's list in use: the outline's window goes (and can't be opened) till it isn't.
        state.onSourceChange = { [weak self] in
            guard let self, self.state.usesToyl else { return }
            self.projectsWindow?.close()
        }
        state.gestures = gestures
        dock = DockController(state: state)
        spaceLabel = SpaceLabel(state: state)
        barLimit = BarLimit(state: state)
        // The lyrics on the bar keep clear of it.
        barLimit?.reachChanged = { [weak self] in
            guard let self, let screen = self.screen else { return }
            self.showClosedLyrics(on: screen)
        }
        spaceLabel?.onSpan = { [weak self] span in self?.walkers.keepClear = span }
        pictureInPicture = PictureInPicture(state: state)
        Features.shared.follow(.desktopsView) { [weak self] _ in self?.followDesktops() }
            .store(in: &cancellables)
        Features.shared.follow(.desktopsKey) { [weak self] _ in self?.followDesktops() }
            .store(in: &cancellables)

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
        // On another Space: each of Oyl's windows that's to be on every one, on this one too (see
        // `EverySpace`), whether it's up now or not.
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { EverySpace.rejoinAll() }
        }
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
        // In a fullscreen app the Oyls never take the pointer, so a click on one is caught on its way
        // through instead.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                // Not a click on Mission Control's desktops, wherever an Oyl was standing, or
                // picking out an area for a screenshot.
                guard let self, !self.state.isViewingDesktops, !self.state.isTakingShot else { return }
                self.walkers.clickedThrough(at: NSEvent.mouseLocation)
            }
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
                    self?.fitPanel()
                    if let self {
                        self.state.nowPlaying.onScreen = self.state.mode == .expanded && self.state.page == .music
                    }
                    self?.closeIfAbandoned()
                }
            }
            .store(in: &cancellables)

        gestures.onGesture = { [weak self] gesture in
            guard let self else { return }
            // The Oyls on the menu bar's own gestures (the moyls', in Midnight Oyl); the rest are the
            // notch's.
            switch gesture {
            case .announce: self.onceClosed { [weak self] in self?.walkers.announce() }
            // Tipped left lines them up, tipped right sends them off; each undoes the other.
            case .tiltLeft:
                if self.state.oylsVisible { self.walkers.fling() } else { self.state.oylsVisible = true }
            case .tiltRight:
                if self.walkers.isLinedUp { self.walkers.scatter() } else { self.state.oylsVisible = false }
            // A flick of the wrist: up, the desktops' list, as four fingers up; down, put away.
            case .flickUp:
                guard !self.state.isOff else { return }
                self.desktops?.open()
            case .flickDown:
                self.desktops?.putAway()
            default: self.state.perform(gesture)
            }
        }
        // The right Shift's camera: what it sees, and what it's just done, on the closed notch.
        Publishers.CombineLatest3(gestures.$heldAwake, gestures.$seen, gestures.$sighting)
            .receive(on: RunLoop.main)
            .sink { [weak self] held, seen, sighting in
                MainActor.assumeIsolated {
                    let watch = held ? GestureWatch(seen: seen, acted: sighting?.gesture) : nil
                    if self?.state.watching != watch { self?.state.watching = watch }
                }
            }
            .store(in: &cancellables)
        // A selfie: an Oyl holds it up (you, not your screen beside you in the file), and pops it
        // up big under the menu bar for a moment.
        gestures.onSelfie = { [weak self] url, image in
            guard let self else { return }
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
        // In Midnight Oyl, two fists make the hand the pointer; leaving it puts the pointer down.
        state.$theme
            .removeDuplicates()
            .sink { [weak self] theme in
                MainActor.assumeIsolated { self?.gestures.midnight = theme == .midnight }
            }
            .store(in: &cancellables)
        // A pinky out shows the lyrics, so it's only looked for when the song has some.
        nowPlaying.$lyrics
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] available in
                MainActor.assumeIsolated { self?.gestures.lyricsAvailable = available }
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
        // Oyls in Gargoyle, moyls in Midnight Oyl.
        state.$theme
            .removeDuplicates()
            .sink { [weak self] theme in
                MainActor.assumeIsolated {
                    self?.walkers.theme = theme
                    self?.projectsWindow?.theme = theme
                    self?.desktops?.theme = theme
                    self?.missionGroups.theme = theme
                    ScreenshotHold.shared.theme = theme
                }
            }
            .store(in: &cancellables)
        // Midnight Oyl's shader takes a moment to compile, so it's done ahead of the first bloom.
        state.$theme
            .filter { $0 == .midnight }
            .sink { _ in MainActor.assumeIsolated { MidnightBackdrop.prepare() } }
            .store(in: &cancellables)
        state.$dimsMenuBar
            .sink { [weak self] dims in
                MainActor.assumeIsolated { self?.walkers.dimsBar = dims }
            }
            .store(in: &cancellables)
        // The lid's shut with no other screen on: nothing Oyl draws can be seen, so it rests.
        awake.$isShut
            .removeDuplicates()
            .sink { [weak self] shut in
                MainActor.assumeIsolated {
                    self?.isShut = shut
                    self?.rest()
                }
            }
            .store(in: &cancellables)
        // Control on its own three times: Oyl off, or back on. Once, then pressed again and held:
        // Midnight Oyl, or back to Oyl's look.
        controlTaps = TapWatcher(.control, held: { [weak self] in
            guard let self, !self.state.isOff, Feature.themeKey.isOn else { return }
            let toMidnight = self.state.theme != .midnight
            self.state.theme = toMidnight ? .midnight : .standard
            ThemeChime.swapped(toMidnight: toMidnight)
        }, actions: [
            3: { [weak self] in
                // Turned off, the taps can still switch Oyl back on.
                guard let self, self.state.isOff || Feature.offTaps.isOn else { return }
                self.switchOff(!self.state.isOff)
            },
        ])
        // Command on its own twice, either one, quickly (the second pressed within a quarter of a
        // second of letting go of the first): a screenshot of part of the screen (as ⇧⌘4), but
        // not while Oyl's off.
        commandTaps = TapWatcher(.command, gap: ModifierTaps.commandGap, actions: [
            2: { [weak self] in
                guard self?.state.isOff == false, Feature.screenshotTaps.isOn else { return }
                AreaScreenshot.take()
            },
        ])
        // The right Shift key on its own twice, quickly: the desktops' list, as four fingers up
        // bring it (or put away, if it's up).
        shiftTaps = TapWatcher(.shift, side: ModifierTaps.rightShift, gap: ModifierTaps.shiftGap, actions: [
            2: { [weak self] in
                guard let self, !self.state.isOff, Feature.desktopsKey.isOn else { return }
                self.desktops?.toggle()
            },
        ])
        missionControl = MissionControl { [weak self] showing in
            self?.viewDesktops(showing && Feature.missionControl.isOn)
            if self?.state.isOff == false { self?.missionGroups.showing(showing) }
            // The desktops' list still up as it goes: in front again, in case it's out of sight.
            if !showing { self?.desktops?.refront() }
        }
        // Three fingers up (Mission Control's swipe): its row's looked for at once, in case the
        // Dock's word of it is late, or never comes.
        Trackpads.shared.threeUp = { [weak self] in
            // (Not while the desktops' list is up: three fingers up are held back then.)
            guard let self, !self.state.isOff, self.desktops?.isUp != true else { return }
            self.missionGroups.expect()
        }
        // The right Shift key held a moment on its own: the camera on, quietly, for the gestures,
        // wherever the pointer is, while it's held and for 3 s after.
        shiftHold = HoldWatcher(.shift, side: ModifierTaps.rightShift, after: 0.5, began: { [weak self] in
            guard let self, !self.state.isOff, Feature.shiftCamera.isOn else { return }
            self.gestures.holdAwake(true)
        }, ended: { [weak self] in
            self?.gestures.holdAwake(false)
        })
        // Option (either one) held a moment on its own: the Claude that last finished (or began
        // waiting for you), as its sound would have told, brought up.
        optionHold = HoldWatcher(.option, after: 0.5, began: { [weak self] in
            guard let self, !self.state.isOff, Feature.optionLatest.isOn, let latest = self.chimes.latest else { return }
            let session = self.state.agents.sessions.first { $0.id == latest.session.id } ?? latest.session
            Haptics.perform(.alignment)
            // Straight to its desktop, with no slide through the rest, nothing rearranged.
            LatestClaude.go(to: session) { [weak self] in self?.state.agents.reveal(session) }
        }, ended: {})
        // Control and Option on their own: the camera on, quietly, for the gestures, wherever the
        // pointer is, for 3 s (as soon as they're let go); twice, kept on till they're tapped
        // twice again.
        cameraTaps = TapWatcher([.control, .option], longest: 0.6, each: { [weak self] taps in
            guard let self, taps == 1, !self.state.isOff, Feature.cameraKeys.isOn else { return }
            self.gestures.wake(for: 3)
        }, actions: [
            2: { [weak self] in
                guard let self, !self.state.isOff, Feature.cameraKeys.isOn || self.gestures.keptAwake else { return }
                self.gestures.toggleAwake()
            },
        ])
        // Control-Option and an arrow: the next song, or the one before, while there's one on.
        // Command-period: the emoji picker, in the app you're in (Oyl's own notch, when it has
        // the keyboard, answers it itself).
        keyTap = KeyTap(skip: { [weak self] forward in
            // (Not a tap of control and option, for the camera.)
            self?.cameraTaps?.interrupt()
            guard let self, !self.state.isOff, Feature.songKeys.isOn, self.state.nowPlaying.player != nil else { return false }
            if forward { self.state.nowPlaying.next() } else { self.state.nowPlaying.previous() }
            return true
        }, emoji: { [weak self] in
            guard let self else { return false }
            return !self.state.isOff && Feature.emojiKey.isOn && NSApp.keyWindow == nil
        }, pictureInPicture: { [weak self] in
            // Control-Option-P: the window in front into picture in picture, or put away.
            self?.cameraTaps?.interrupt()
            guard let self, !self.state.isOff, Feature.pictureInPicture.isOn else { return false }
            return self.pictureInPicture?.toggleFront() ?? false
        })
        state.$showsCountdowns
            .sink { [weak self] shows in
                MainActor.assumeIsolated { self?.walkers.showsCountdowns = shows }
            }
            .store(in: &cancellables)
        walkers.onReveal = { agents.reveal($0) }
        walkers.onSelfie = { NSWorkspace.shared.open($0) }
        walkers.onOpen = { [weak self] job in self?.reveal(job) }
        walkers.describe = { [weak self] job in self?.describe(job) ?? "" }
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
        castOyls()
    }

    /// The desktops' list, while four fingers up or right Shift twice brings it (either's on):
    /// the trackpads read only while four fingers up do.
    private func followDesktops() {
        guard Feature.desktopsView.isOn || Feature.desktopsKey.isOn else {
            desktops?.stop()
            desktops = nil
            return
        }
        if desktops == nil {
            let viewer = DesktopsViewer()
            viewer.theme = state.theme
            viewer.isResting = state.isResting
            viewer.isAllowed = { [weak self] in
                guard let self else { return false }
                return !self.state.isOff && !self.state.isResting
            }
            viewer.working = { [weak self] in self?.state.agents.working ?? [] }
            viewer.start()
            desktops = viewer
        }
        desktops?.readTrackpads(Feature.desktopsView.isOn)
    }

    /// Stops drawing the notch and the Oyls, watching the camera, reading your voice, analyzing
    /// the music and asking the player about it so often, or starts again: while the lid's shut
    /// with no other screen on, or Oyl's switched off.
    private func rest() {
        let resting = isShut || state.isOff
        guard resting != state.isResting else { return }
        state.isResting = resting
        if resting {
            // Nobody's over it now, whatever the pointer last did.
            hoverWork?.cancel()
            pointerInside = false
            gestures.hovering = false
            close()
        }
        walkers.isResting = resting
        ClaudeLimit.shared.isResting = resting
        desktops?.isResting = resting
        gestures.isSuspended = resting
        state.nowPlaying.resting = resting
        state.dictation.resting = resting
        state.notes.resting = resting
        if resting { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        if resting { closedLyrics.hideNow() }
    }

    /// Three taps of control switch Oyl off, or back on. Off, it's put away, closing first if it's
    /// open, and listens only for the taps: the Mac's let sleep (as quitting does). Timers carry
    /// on, and still chime. Either way it blinks, the
    /// closed notch popping out and back, so the taps are seen to have been heard.
    private func switchOff(_ off: Bool) {
        guard off != state.isOff else { return }
        state.isOff = off
        guard off else {
            rest()
            blink()
            return
        }
        state.awake.stop()
        state.isPinned = false
        hoverWork?.cancel()
        revealWork?.cancel()
        let wasOpen = state.mode == .expanded
        pointerInside = false
        gestures.hovering = false
        close()
        // Midnight's band takes the longest to go.
        if wasOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.8, Midnight.closingDuration + 0.1)) { [weak self] in
                MainActor.assumeIsolated { self?.rest() }
            }
        } else {
            blink { [weak self] in self?.rest() }
        }
    }

    /// As Oyl quits: the projects saved now, not the moment after an edit they'd otherwise wait.
    func quitting() {
        state.projects.flush()
    }

    /// The outline of every project, in its own window, up where you are (at the line `id`, if
    /// it's given), in the look Oyl's in.
    private func openProjects(at id: String?) {
        guard state.showsProjects else { return }
        let window = projectsWindow ?? ProjectsWindowController(store: state.projects)
        projectsWindow = window
        window.theme = state.theme
        state.projects.weekStart = state.tod.weekStart
        window.show(id)
    }

    /// The closed notch pops out, as under the pointer, and back in; then `done`.
    private func blink(then done: @escaping @MainActor () -> Void = {}) {
        state.isPopped = true
        Haptics.perform(.generic, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.pointerInside { self.state.isPopped = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    MainActor.assumeIsolated { done() }
                }
            }
        }
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
            return "Just hanging out. Own your life!"
        case .agent(let session):
            return "\(session.project): \(session.summary)"
        case .music(_, .singing):
            return walkers.walkers.lyricLine(now).map { "♪ \($0)" } ?? "♪ La la la"
        case .music(_, .reading):
            return state.nowPlaying.track.map { track in
                let artist = state.nowPlaying.artist(of: track)
                return "Reading \(track.title)" + (artist.isEmpty ? "" : ", by \(artist)")
            } ?? "Reading"
        case .music:
            return state.nowPlaying.track.map { "♪ \($0.title), by \(state.nowPlaying.artist(of: $0))" } ?? "♪"
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
        case .notes(let app):
            return "Taking notes for \(app)…"
        }
    }

    /// Sends Oyls out on the menu bar for what's going on, or calls them back.
    private func castOyls() {
        guard let screen else { return }
        showClosedLyrics(on: screen)
        // The closed notch (and what's beside it), which the calendar goes right of; and what the
        // notch covers right now, open or closed, which Oyls skip across and don't stop behind.
        let closed = state.mode == .expanded ? (state.compact.isEmpty ? NotchMode.idle : .compact) : state.mode
        func span(_ mode: NotchMode) -> ClosedRange<CGFloat> {
            let width = state.size(for: mode).width + 2 * NotchState.topRadius(mode)
            return (state.metrics.centerX - width / 2)...(state.metrics.centerX + width / 2)
        }
        let middle = state.metrics.centerX
        // Midnight's band covers the whole bar: the moyls fly up off it into the band's sky (keeping
        // to the closed notch's gap on the bar meanwhile), clear of its page and its moon.
        walkers.cast(state.oylJobs, completed: state.finishedOyls, on: screen, notch: span(closed),
                     covered: span(state.isBlooming ? closed : state.mode))
        if state.isBlooming && !state.isResting {
            let size = state.bloomSize, reach = state.bloomReach
            let layout = BloomLayout(state: state, size: size, reach: reach)
            walkers.band = BandSky(size: size, reach: reach, page: layout.page, moon: layout.moon.center, moonRadius: layout.moon.radius,
                                   top: state.metrics.size.height, left: middle - size.width / 2 - screen.frame.minX,
                                   lyrics: layout.lyrics)
        } else {
            walkers.band = nil
        }
        walkers.inFullscreen = state.inFullscreen
    }

    /// Midnight's lyrics in the menu bar's strip by the closed notch, while they're wanted there
    /// (or, for a song without, its constellation), fading out while the song's paused.
    private func showClosedLyrics(on screen: NSScreen) {
        let playing = state.nowPlaying
        closedLyrics.show(wanted: state.wantsLyricsByNotch, paused: state.wouldShowLyricsByNotch && !playing.isPlaying,
                          lyrics: playing.lyrics?.trackID == playing.track?.id ? playing.lyrics : nil, seed: playing.track?.id ?? "", on: screen, metrics: state.metrics,
                          beside: max(state.compact.isEmpty ? 0 : state.compact.wing, barLimit?.reach ?? 0),
                          opened: state.mode == .expanded || state.theme != .midnight)
    }

    private func updateScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
        self.screen = screen
        let metrics = NotchMetrics(screen: screen)
        if state.metrics != metrics { state.metrics = metrics }

        fitPanel(now: true)
        castOyls()
    }

    /// The panel, as big as the tallest page could be now, which grows with the timers: grown at
    /// once, and shrunk once the page has (or Midnight's band has folded away), so it's never cut
    /// off mid-animation.
    private func fitPanel(now: Bool = false) {
        guard let screen else { return }
        let size = state.windowSize
        guard size != panel.frame.size else { return }
        let frame = NSRect(x: state.metrics.centerX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        shrinking?.cancel()
        shrinking = nil
        if now || size.height >= panel.frame.height {
            panel.setFrame(frame, display: true)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state.windowSize == size else { return }
                self.panel.setFrame(frame, display: true)
            }
        }
        shrinking = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.8, Midnight.closingDuration + 0.1), execute: work)
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

    /// Mission Control (or App Exposé, or Show Desktop) is up, the notch over the desktops along
    /// the top: so it closes and lets the pointer through, the Oyls do too, and Oyl's Dock stays
    /// down (see `DockController`), till it's gone.
    private func viewDesktops(_ viewing: Bool) {
        state.isViewingDesktops = viewing
        guard viewing else { return }
        hoverWork?.cancel()
        pointerInside = false
        gestures.hovering = false
        close()
        panel.ignoresMouseEvents = true
        walkers.letPointerThrough()
    }

    /// A screenshot for an idea, from the ideas page's camera: the notch closes out of the way and
    /// stays closed (the pointer let through, and Oyl's Dock kept down) while an area's picked out,
    /// as ⇧⌘4 has you, then opens on the page again, the picture at the head of the field, which
    /// takes the keyboard for what the idea is. Called off with Escape, it's back to the field as
    /// it was.
    private func takeShot(for page: NotchPage) {
        guard !state.isTakingShot else { return }
        let draft = state.ideaDraft
        state.isTakingShot = true
        hoverWork?.cancel()
        pointerInside = false
        gestures.hovering = false
        close()
        panel.ignoresMouseEvents = true
        // Once it's closed, so it's not in the picture (Midnight's band, once it's folded away).
        DispatchQueue.main.asyncAfter(deadline: .now() + (state.theme == .midnight ? Midnight.closingDuration : 0.35)) { [weak self] in
            MainActor.assumeIsolated {
                IdeaPictures.take { shot in
                    guard let self else { return }
                    self.state.isTakingShot = false
                    if let shot { draft.attach(shot) }
                    self.state.page = page
                    draft.wantsKeyboard = true
                    self.state.isRevealing = true
                    self.updatePassThrough(at: NSEvent.mouseLocation)
                    // Open while it's typed in; otherwise, as a revealed page is, for a moment.
                    self.revealWork?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, !self.pointerInside else { return }
                            self.state.isRevealing = false
                        }
                    }
                    self.revealWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
                }
            }
        }
    }

    private func pointerMoved(released: Bool) {
        guard !state.isOff, !state.isResting, !state.isViewingDesktops, !state.isTakingShot else { return }
        let rect = hoverRect()
        let location = NSEvent.mouseLocation
        walkers.pointerMoved(to: location)
        var inside = rect.contains(location) && (!state.isBlooming || isOverBand(location))
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
            lookAtFront()
            // Like Atoll: the closed notch pops right away, then opens after a short rest.
            if state.mode != .expanded {
                state.isPopped = true
                Haptics.perform(.generic, performanceTime: .now)
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

    /// What's in front, to be offered as an agent on the notch's right-click and in the settings:
    /// the app you were in (Oyl never takes its place), or in a browser, the site its tab's on.
    private func lookAtFront() {
        let app = NSWorkspace.shared.frontmostApplication
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let front = AgentRadar.front(app: app)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self?.state.front != front { self?.state.front = front }
                }
            }
        }
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
        let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func open() {
        guard pointerInside, !state.isHovering else { return }
        // Midnight Oyl held open on display is open already: the pointer's just passing over it.
        if !(state.isPinned && state.theme == .midnight) {
            // Land on the page that has something to show (settings are only for when they're
            // asked for).
            if state.page == .settings || !state.shows(state.page) {
                state.page = .agents
            } else if state.page == .music && state.nowPlaying.track == nil && state.shows(.timers) {
                state.page = .timers
            } else if state.page == .timers && state.timers.timers.isEmpty && state.nowPlaying.track != nil && state.shows(.music) {
                state.page = .music
            }
            Haptics.perform(.levelChange, performanceTime: .now)
        }
        state.isHovering = true
        // Opening the notch watches the camera for hand gestures, until an OK or the pointer leaves.
        gestures.hovering = true
    }

    /// Leaving the notch closes it, even mid-typing: the keyboard goes back to the window you
    /// were in.
    private func close() {
        guard !pointerInside else { return }
        // Only what's changing: each set re-renders the notch and runs everything watching it.
        if state.isPopped { state.isPopped = false }
        if state.isEditing { resignKeyboard() }
        if state.isHovering { state.isHovering = false }
        if state.isRevealing { state.isRevealing = false }
    }

    /// Opens the notch to the page of an Oyl clicked on the menu bar (a timer's, picked out on
    /// it), for a few seconds, or for as long as the pointer then spends over it.
    private func reveal(_ job: Walker.Job) {
        switch job {
        case .music where state.shows(.music):
            state.page = .music
            state.pickedTimer = nil
        case .timer(let timer) where state.shows(.timers):
            state.page = .timers
            state.pickedTimer = timer.id
        default:
            return
        }
        state.isRevealing = true
        revealWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.pickedTimer = nil
                // Unless the pointer's gone to it; then it closes as it leaves.
                if !self.pointerInside { self.state.isRevealing = false }
            }
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
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

    /// The visible notch shape in screen coordinates. (Midnight Oyl's bloom has no flared corners.)
    private func hoverRect() -> NSRect {
        guard let screen else { return .zero }
        let mode = state.mode
        var size = state.size(for: mode)
        if !state.isBlooming {
            size.width += 2 * NotchState.topRadius(mode)
            if mode == .expanded { size.height += 6 }
        }
        // +1 so the very top row of pixels counts as inside.
        return NSRect(x: state.metrics.centerX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height + 1)
    }

    /// Whether the pointer's over Midnight Oyl's open band, for staying open: not all its sky
    /// (it reaches right across the screen, and would be hard to leave) but its page, as big as
    /// the open notch, and a little round it; and the moon, to be clicked, and the way over to it.
    private func isOverBand(_ location: NSPoint) -> Bool {
        guard let screen else { return false }
        let top = screen.frame.maxY
        // (Each worked out the once: this is asked on every move of the pointer while it's open.)
        let height = state.headerHeight + state.contentHeight, width = state.openWidth
        let side = NotchState.topRadius(.expanded) + Self.bandMargin
        let page = NSRect(x: state.metrics.centerX - width / 2 - side, y: top - height - Self.bandMargin,
                          width: width + 2 * side, height: height + Self.bandMargin + 1)
        if page.contains(location) { return true }
        let size = state.bloomSize
        let moon = MidnightBackdrop.moon(in: size, reach: state.bloomReach(page: height))
        let center = NSPoint(x: state.metrics.centerX - size.width / 2 + moon.center.x, y: top - moon.center.y)
        let radius = moon.radius + 12
        if hypot(location.x - center.x, location.y - center.y) <= radius { return true }
        let way = NSRect(x: min(page.maxX, center.x), y: center.y - radius, width: abs(center.x - page.maxX), height: 2 * radius)
        return way.contains(location)
    }

    /// How much further than the open notch Midnight Oyl's page stays open for, round it.
    private static let bandMargin: CGFloat = 16
}
