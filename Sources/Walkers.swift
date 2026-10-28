import AppKit
import SwiftUI

/// Oyls out on the menu bar, one for each thing Oyl's up to: an agent at work, a song (and
/// one singing it, once you've asked for the lyrics), a timer or reminder, staying awake, a low
/// battery, a late night, a selfie just taken; with none of those, Oyl on his own, hanging out.
/// They come out from the notch, wander anywhere along the bar, stopping a while at each spot to
/// get on with their job, and walk off the nearer edge once it's done (jumping for joy first if
/// it's work they finished). Walking past the notch they dash across it in half a second rather
/// than disappear behind it for long. They never stop on top of each other. Click one and it
/// says what it's for, hops, and moves out of the way; an agent's takes you to where it's
/// working, a selfie's opens the picture. Tipping your hand left lines them up on the left;
/// tipping it right sends them off (each undoes the other).
///
/// With the dimming setting on, the menu bar goes 80% black behind them while the pointer's on
/// it, so they stand out from its text.
///
/// Right of the notch is the calendar bar: events sliding in from the right and off to the left
/// as the time passes (long empty stretches squeezed, so what's next is always on it), with an Oyl
/// standing at now doing whatever the event on now is, or, with nothing else on today, peering
/// ahead with a magnifying glass.
///
/// They all get a see-through window of their own along the top of the screen, above the menu
/// bar and under the notch, reaching a little below the bar for what they say. It takes the
/// pointer only while it's over an Oyl or the calendar.
@MainActor
final class WalkerOverlay {
    nonisolated static let speed: CGFloat = 46                // points a second
    static let stay: ClosedRange<TimeInterval> = 8...18       // at each spot
    nonisolated static let cheer: TimeInterval = 1.8          // jumping for joy, before walking off
    /// How much of the calendar bar has gone by.
    nonisolated static let past: CGFloat = 0.2
    /// How long walking across the notch takes.
    nonisolated static let crossing: TimeInterval = 0.5
    /// Room under the menu bar for speech bubbles.
    static let below: CGFloat = 64
    /// How long Oyls flung to the left stay lined up there.
    static let parked: TimeInterval = 180

    let walkers = Walkers()
    /// An agent's Oyl was clicked.
    var onReveal: (AgentSession) -> Void = { _ in }
    /// A selfie's Oyl was clicked.
    var onSelfie: (URL) -> Void = { _ in }
    /// The calendar bar was clicked.
    var onCalendar: () -> Void = {}
    /// What an Oyl would say it's doing, and what the calendar's would.
    var describe: (Walker.Job) -> String = { _ in "" }
    var describeCalendar: () -> String = { "" }

    private let panel: NSPanel
    /// Where the notch is along the bar, which Oyls skip past and don't stop at.
    private var notch: ClosedRange<CGFloat> = 0...0
    private var planner: Timer?
    private var ticks = 0
    private var isShown = true
    /// Counts announcements, so a new one cuts off the rest of the last.
    private var announcing = 0
    /// Lined up on the left (by a tilt to the left) until then.
    private var linedUpUntil = Date.distantPast
    /// The menu bar goes dark behind them while the pointer's on it.
    var dimsBar = false {
        didSet { if !dimsBar, walkers.dimmed { walkers.dimmed = false } }
    }

    var isLinedUp: Bool { linedUpUntil > Date() }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = FirstClickHostingView(rootView: WalkersView(walkers: walkers) { [weak self] point in
            MainActor.assumeIsolated { self?.clicked(at: point) }
        })
        host.sizingOptions = []
        panel.contentView = host
    }

    private var bar: CGFloat { walkers.barHeight }

    /// Who should be out: newcomers come out of the notch, Oyls whose job is over walk off (those
    /// in `completed` cheering first), and any called back before they're gone turn around.
    /// `notch` is in screen coordinates.
    func cast(_ jobs: [Walker.Job], completed: Set<String>, on screen: NSScreen, notch: ClosedRange<CGFloat>) {
        place(on: screen)
        guard isShown else { return }
        let notch = (notch.lowerBound - screen.frame.minX)...(notch.upperBound - screen.frame.minX)
        if notch != self.notch {
            self.notch = notch
            layOutCalendar()
        }
        let now = Date()
        var list = walkers.list
        let wanted = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in list.indices {
            if let job = wanted[list[index].id] {
                let settling = job.staysPut && !list[index].job.staysPut
                list[index].job = job
                if list[index].leaving {
                    list[index].leaving = false
                    list[index].cheered = nil
                    plan(&list[index], at: now, among: list)
                } else if settling {
                    // Into bed where it stands (once it gets there).
                    list[index].moves = .distantFuture
                }
            } else if !list[index].leaving {
                leave(&list[index], at: now, cheering: completed.contains(list[index].id))
            }
        }
        for job in jobs where !list.contains(where: { $0.id == job.id }) {
            var walker = Walker(job: job, at: (notch.lowerBound + notch.upperBound) / 2, since: now)
            plan(&walker, at: now, among: list)
            list.append(walker)
        }
        if list != walkers.list { walkers.list = list }
        show()
    }

    /// Today's events, for the calendar bar; `note` says why there are none, if there's a reason.
    func showCalendar(_ events: [DayEvent], note: String?) {
        if events != walkers.events { walkers.events = events }
        if note != walkers.calendarNote { walkers.calendarNote = note }
        layOutCalendar()
        show()
    }

    /// Shows them all (they come out again once cast), or sends them off the nearer edge at a
    /// run, calendar and all, and then hides.
    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        linedUpUntil = .distantPast
        walkers.away = !shown
        if shown {
            show()
            return
        }
        let now = Date()
        for index in walkers.list.indices {
            leave(&walkers.list[index], at: now, cheering: false, speed: Self.speed * 5)
        }
        walkers.sayings = [:]
        walkers.dimmed = false
        panel.ignoresMouseEvents = true
    }

    /// A speech bubble under Oyl `id` ("calendar" for the calendar's), for `seconds`, starting
    /// after `delay`.
    func say(_ text: String, as id: String, for seconds: TimeInterval, after delay: TimeInterval = 0, image: NSImage? = nil) {
        let from = Date().addingTimeInterval(delay)
        walkers.sayings[id] = Saying(text: text, image: image, from: from, until: from.addingTimeInterval(seconds))
    }

    /// Every Oyl says what it's doing, one after another from left to right, so each can be read
    /// (each saying it as its turn comes, so it's up to date).
    func announce() {
        let now = Date()
        var speakers = walkers.list.filter { !$0.leaving }.map { (x: $0.middle(at: now), id: $0.id) }
        if let strip = walkers.calendar { speakers.append((Walkers.now(in: strip), "calendar")) }
        announcing += 1
        let round = announcing
        for (turn, speaker) in speakers.sorted(by: { $0.x < $1.x }).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(turn) * 2.2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isShown, round == self.announcing else { return }
                    if speaker.id == "calendar" {
                        if self.walkers.calendar != nil { self.say(self.describeCalendar(), as: "calendar", for: 2.6) }
                    } else if let walker = self.walkers.list.first(where: { $0.id == speaker.id && !$0.leaving }) {
                        self.say(self.describe(walker.job), as: walker.id, for: 2.6)
                    }
                }
            }
        }
    }

    /// Done lining up: everyone off to wander again.
    func scatter() {
        let now = Date()
        linedUpUntil = .distantPast
        for index in walkers.list.indices where !walkers.list[index].leaving {
            plan(&walkers.list[index], at: now, among: walkers.list)
        }
    }

    /// Every Oyl off to the left, lined up: grouped by what it's for, oldest first in each group.
    /// They stay a few minutes before wandering off again.
    func fling() {
        let now = Date(), reach = Walker.reach(height: bar)
        linedUpUntil = now.addingTimeInterval(Self.parked)
        var x = 6 + reach.left
        var last: Int?
        let order = walkers.list.indices.filter { !walkers.list[$0].leaving }.sorted {
            (walkers.list[$0].job.group, walkers.list[$0].created) < (walkers.list[$1].job.group, walkers.list[$1].created)
        }
        for index in order {
            let group = walkers.list[index].job.group
            if let last, last != group { x += 14 }
            last = group
            // Round the notch and the calendar rather than lining up behind them.
            for range in blocked.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.overlaps((x - reach.left - 6)...(x + reach.right + 6)) {
                x = range.upperBound + reach.left + 6
            }
            guard x <= panel.frame.width - reach.right - 4 else {
                plan(&walkers.list[index], at: now, among: walkers.list)
                continue
            }
            move(&walkers.list[index], to: x, at: now, speed: Self.speed * 6, stay: Self.parked)
            // Room for it, its things and its label, however long that is.
            let scale = bar / 50, walker = walkers.list[index]
            let label = walker.labelWidth(at: now).map { walker.labelOffset(height: bar) + $0 + 6 } ?? 0
            x += max(100 * scale + 6, label)
        }
    }

    /// Takes the pointer only while it's over an Oyl or the calendar, so the menu bar works
    /// everywhere else.
    func pointerMoved(to location: NSPoint) {
        guard isShown, panel.isVisible, panel.frame.contains(location) else {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            if walkers.dimmed { walkers.dimmed = false }
            return
        }
        let point = CGPoint(x: location.x - panel.frame.minX, y: panel.frame.maxY - location.y)
        let dim = dimsBar && point.y <= bar
        if dim != walkers.dimmed { walkers.dimmed = dim }
        let over = walker(at: point) != nil || walkers.calendar?.contains(point) == true
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    private func show() {
        guard isShown, !walkers.list.isEmpty || walkers.calendar != nil else { return }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if planner == nil {
            planner = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    /// Along the top of the screen: the menu bar, and room under it for what they say.
    private func place(on screen: NSScreen) {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let height = menuBar > 0 ? menuBar : max(screen.safeAreaInsets.top, 24)
        if height != walkers.barHeight { walkers.barHeight = height }
        if screen.frame.width != walkers.barWidth { walkers.barWidth = screen.frame.width }
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height - Self.below, width: screen.frame.width,
                           height: height + Self.below)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    /// The calendar bar: right of the notch, up to the menu bar's icons, as room allows.
    private func layOutCalendar() {
        guard panel.frame.width > 0 else { return }
        let left = notch.upperBound + 10
        let room = Self.menuBarIcons(after: panel.frame.minX + left, on: panel.frame) - panel.frame.minX - 10 - left
        // Too little room left of the icons: no bar, rather than one over them.
        let frame = room >= 120 ? CGRect(x: left, y: 0, width: min(room, 420), height: bar) : nil
        if frame != walkers.calendar { walkers.calendar = frame }
        // A bed the notch or the bar has grown over gets moved.
        let now = Date()
        for index in walkers.list.indices
        where walkers.list[index].job.staysPut && !walkers.list[index].leaving && !isClear(walkers.list[index].to) {
            plan(&walkers.list[index], at: now, among: walkers.list)
        }
    }

    /// Where the menu bar's icons start, right of `x`, on the screen whose top `frame` runs along
    /// (in screen coordinates; the window list measures down from the main screen's top).
    private static func menuBarIcons(after x: CGFloat, on frame: NSRect) -> CGFloat {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let status = Int(CGWindowLevelForKey(.statusWindow))
        let top = Double((NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY)
        let starts = windows.compactMap { window -> CGFloat? in
            guard window[kCGWindowLayer as String] as? Int == status,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  let y = bounds["Y"], abs(y - top) < 1, let start = bounds["X"],
                  CGFloat(start) > x, CGFloat(start) < frame.maxX else { return nil }
            return CGFloat(start)
        }
        return starts.min() ?? .greatestFiniteMagnitude
    }

    /// Moves on those that have stayed long enough, lets go of those that have walked off, and
    /// clears what's been said.
    private func tick() {
        let now = Date()
        var list = walkers.list
        list.removeAll { $0.leaving && now >= $0.arrives }
        for index in list.indices where !list[index].leaving && now >= list[index].moves {
            plan(&list[index], at: now, among: list)
        }
        if list != walkers.list { walkers.list = list }
        if walkers.sayings.values.contains(where: { $0.until <= now }) {
            walkers.sayings = walkers.sayings.filter { $0.value.until > now }
        }
        // An Oyl may have walked out from under the pointer, or under it.
        pointerMoved(to: NSEvent.mouseLocation)
        // Menu bar icons come and go.
        ticks += 1
        if ticks % 20 == 0 { layOutCalendar() }
        guard list.isEmpty, walkers.calendar == nil || !isShown else { return }
        planner?.invalidate()
        planner = nil
        panel.orderOut(nil)
    }

    /// The notch, for an Oyl's middle: it skips straight across.
    private var gap: ClosedRange<CGFloat> {
        let half = 22 * bar / 50 + 3
        return (notch.lowerBound - half)...(notch.upperBound + half)
    }

    /// Off to a new spot, from wherever it is now, after `delay`; or, in bed, nowhere.
    private func plan(_ walker: inout Walker, at now: Date, among others: [Walker], after delay: TimeInterval = 0) {
        if walker.job.staysPut {
            // Into bed where it is, if it can be seen there; else it walks out to a spot first.
            let here = walker.middle(at: now)
            let free = isClear(here) && !Self.crowds(here, walker, others, reach: Walker.reach(height: bar))
            move(&walker, to: free ? here : spot(for: walker, among: others), at: now, after: delay, stay: .infinity)
            return
        }
        move(&walker, to: spot(for: walker, among: others), at: now, after: delay)
    }

    private func move(_ walker: inout Walker, to spot: CGFloat, at now: Date, after delay: TimeInterval = 0,
                      speed: CGFloat? = nil, stay: TimeInterval? = nil) {
        let speed = speed ?? walker.job.speed
        let here = walker.middle(at: now)
        walker.gap = gap
        walker.from = here
        walker.to = spot
        // Quick steps, but no quicker than 10 frames a second can show.
        walker.pace = min(speed / Self.speed, 2.5)
        walker.crossing = speed * CGFloat(Self.crossing)
        walker.leaves = now.addingTimeInterval(delay)
        walker.arrives = walker.leaves.addingTimeInterval(TimeInterval(walker.distance / speed))
        let stay = stay ?? .random(in: Self.stay)
        walker.moves = stay.isFinite ? walker.arrives.addingTimeInterval(stay) : .distantFuture
    }

    /// Off the nearer edge of the screen.
    private func leave(_ walker: inout Walker, at now: Date, cheering: Bool, speed: CGFloat? = nil) {
        let here = walker.middle(at: now), width = panel.frame.width, past = Walker.width(height: bar)
        walker.leaving = true
        walker.cheered = cheering ? now : nil
        move(&walker, to: here < width / 2 ? -past : width + past, at: now, after: cheering ? Self.cheer : 0,
             speed: speed, stay: .infinity)
    }

    /// Where Oyls don't stop: the notch and the calendar.
    private var blocked: [ClosedRange<CGFloat>] {
        [notch] + (walkers.calendar.map { [$0.minX...$0.maxX] } ?? [])
    }

    /// Whether an Oyl at its job at `x` would be in the clear: on screen, its things and label
    /// clear of the notch and the calendar.
    private func isClear(_ x: CGFloat) -> Bool {
        let reach = Walker.reach(height: bar)
        guard x >= reach.left + 4, x <= panel.frame.width - reach.right - 4 else { return false }
        let span = (x - reach.left - 6)...(x + reach.right + 6)
        return !blocked.contains { $0.overlaps(span) }
    }

    /// Somewhere along the bar with room for it, its things and its label: clear of the notch,
    /// the calendar and the edges, and never where another is (or is headed). Picked at random
    /// from all such places; if there are none, the one with the most room.
    private func spot(for walker: Walker, among others: [Walker]) -> CGFloat {
        let width = panel.frame.width, reach = Walker.reach(height: bar)
        let low = reach.left + 4, high = max(width - reach.right - 4, low + 1)
        var free: [CGFloat] = [], best = low, bestRoom = -CGFloat.infinity
        for x in stride(from: low, through: high, by: 6) where isClear(x) {
            let room = Self.room(at: x, for: walker, among: others)
            if room >= reach.left + reach.right + 8 { free.append(x) }
            if room > bestRoom {
                best = x
                bestRoom = room
            }
        }
        return free.randomElement() ?? best
    }

    /// How far it is from `x` to the nearest other Oyl's spot.
    private static func room(at x: CGFloat, for walker: Walker, among others: [Walker]) -> CGFloat {
        others.filter { $0.id != walker.id && !$0.leaving }.map { abs($0.to - x) }.min() ?? .infinity
    }

    /// Whether at `x` it would be on top of another.
    private static func crowds(_ x: CGFloat, _ walker: Walker, _ others: [Walker], reach: (left: CGFloat, right: CGFloat)) -> Bool {
        room(at: x, for: walker, among: others) < reach.left + reach.right + 8
    }

    /// The one whose body is at `point`, in the panel (top left origin).
    private func walker(at point: CGPoint) -> Walker? {
        let now = Date()
        return walkers.list.last { !$0.leaving && $0.hitBox(at: now, height: bar).contains(point) }
    }

    private func clicked(at point: CGPoint) {
        let now = Date()
        if let walker = walker(at: point), let index = walkers.list.firstIndex(of: walker) {
            switch walker.job {
            case .agent(let session): onReveal(session)
            case .selfie(let selfie): onSelfie(selfie.url)
            default: break
            }
            say(describe(walker.job), as: walker.id, for: 3)
            walkers.list[index].poked = now
            // Then off out of the way, in case it was over something (bed and all).
            if walker.job.staysPut {
                move(&walkers.list[index], to: spot(for: walker, among: walkers.list), at: now, after: 0.7, stay: .infinity)
            } else {
                plan(&walkers.list[index], at: now, among: walkers.list, after: 0.7)
            }
        } else if let strip = walkers.calendar, strip.contains(point) {
            if Walkers.calendarOyl(in: strip).contains(point) {
                walkers.calendarPoked = now
                say(describeCalendar(), as: "calendar", for: 4)
            } else {
                onCalendar()
            }
        }
    }
}

/// A selfie just taken, for its Oyl to hold up.
struct Selfie: Equatable {
    let url: URL
    let image: NSImage

    static func == (a: Selfie, b: Selfie) -> Bool { a.url == b.url }
}

/// Something an Oyl's saying, in a bubble under the menu bar, from `from` till `until`.
struct Saying: Equatable {
    let text: String
    let image: NSImage?
    let from: Date
    let until: Date

    func isShowing(at date: Date) -> Bool { from <= date && date < until }
}

/// An Oyl out on the menu bar.
struct Walker: Identifiable, Equatable {
    /// What it's out for.
    enum Job: Equatable {
        case hangout
        case agent(AgentSession)
        case music
        case singer
        case timer(ReminderTimer)
        case awake(AwakeManager.Mode)
        case battery(PowerStatus)
        case bedtime(BedtimeStage)
        case selfie(Selfie)

        var id: String {
            switch self {
            case .hangout: return "hangout"
            case .agent(let session): return "agent \(session.id)"
            case .music: return "music"
            case .singer: return "singer"
            case .timer(let timer): return "timer \(timer.id)"
            case .awake: return "awake"
            case .battery: return "battery"
            case .bedtime: return "bedtime"
            case .selfie(let selfie): return "selfie \(selfie.url.lastPathComponent)"
            }
        }

        var duty: OylDuty? {
            switch self {
            case .hangout, .agent: return nil
            case .music: return .music
            case .singer: return .singer
            case .timer(let timer): return .timer(timer)
            case .awake(let mode): return .awake(mode)
            case .battery(let status): return .battery(status)
            case .bedtime(let stage): return .bedtime(stage)
            case .selfie(let selfie): return .selfie(selfie.image)
            }
        }

        var hat: Bool {
            if case .agent = self { return true }
            return false
        }

        /// For lining them up: like with like.
        var group: Int {
            switch self {
            case .agent: return 0
            case .timer: return 1
            case .awake: return 2
            case .music: return 3
            case .singer: return 4
            case .battery: return 5
            case .bedtime: return 6
            case .selfie: return 7
            case .hangout: return 8
            }
        }

        /// The one on energy drinks hurries.
        var speed: CGFloat {
            if case .awake = self { return WalkerOverlay.speed * 1.8 }
            return WalkerOverlay.speed
        }

        /// In bed, it doesn't wander.
        var staysPut: Bool {
            if case .bedtime(let stage) = self { return stage != .candle }
            return false
        }

        /// At something with things to its right, so it stands left of the middle of its drawing.
        var atWork: Bool {
            if case .agent(let session) = self { return OylDrawing.props.contains(session.activity) }
            return true
        }

        func skin(at date: Date) -> Color {
            if case .agent(let session) = self { return Oyl.pastel(session.skin) }
            return duty?.skin(at: date) ?? Oyl.white
        }
    }

    var job: Job
    var id: String { job.id }
    let created: Date
    // Its stroll: it sets off from `from` at `leaves`, gets to `to` at `arrives`, and stays
    // there until `moves`. Both are where its body's middle is along the bar.
    var from: CGFloat
    var to: CGFloat
    var leaves: Date
    var arrives: Date
    var moves: Date
    /// How fast it's going, against a usual walk: it steps quicker.
    var pace: CGFloat = 1
    /// The notch, which it dashes across in `crossing` points' worth of walking.
    var gap: ClosedRange<CGFloat>?
    var crossing: CGFloat = 0
    var leaving = false
    /// When it started jumping for joy, its work done.
    var cheered: Date?
    var poked: Date?

    init(job: Job, at x: CGFloat, since date: Date) {
        self.job = job
        created = date
        from = x
        to = x
        leaves = date
        arrives = date
        moves = date
    }

    /// How far it walks, not counting the notch.
    var distance: CGFloat { abs(fold(to) - fold(from)) }

    func middle(at date: Date) -> CGFloat {
        guard date > leaves else { return from }
        guard date < arrives else { return to }
        let start = fold(from), end = fold(to)
        return unfold(start + (end - start) * CGFloat(date.timeIntervalSince(leaves) / arrives.timeIntervalSince(leaves)))
    }

    /// Along the bar with the notch squeezed down to `crossing` points, and back.
    private func fold(_ x: CGFloat) -> CGFloat {
        guard let gap, gap.upperBound > gap.lowerBound else { return x }
        let width = gap.upperBound - gap.lowerBound
        if x <= gap.lowerBound { return x }
        if x >= gap.upperBound { return x - width + crossing }
        return gap.lowerBound + (x - gap.lowerBound) / width * crossing
    }

    private func unfold(_ x: CGFloat) -> CGFloat {
        guard let gap, gap.upperBound > gap.lowerBound else { return x }
        let width = gap.upperBound - gap.lowerBound
        if x <= gap.lowerBound { return x }
        if x >= gap.lowerBound + crossing { return x + width - crossing }
        return gap.lowerBound + (x - gap.lowerBound) / max(crossing, 0.001) * width
    }

    func isWalking(at date: Date) -> Bool { date > leaves && date < arrives }

    func isCheering(at date: Date) -> Bool {
        guard let cheered else { return false }
        return date >= cheered && date <= leaves
    }

    /// Its drawing (100 × 50), placed so Oyl itself is at `middle(at:)`.
    func frame(at date: Date, height: CGFloat) -> CGRect {
        let scale = height / 50
        let middle = (isWalking(at: date) || isCheering(at: date) || !job.atWork ? 50 : 26) * scale
        return CGRect(x: self.middle(at: date) - middle, y: 0, width: 100 * scale, height: height)
    }

    /// Just Oyl.
    func body(at date: Date, height: CGFloat) -> CGRect {
        let scale = height / 50
        return CGRect(x: middle(at: date) - 20 * scale, y: 3 * scale, width: 40 * scale, height: 44 * scale)
    }

    /// What can be clicked: Oyl, and a timer's clock and countdown (or a reminder's note) beside it.
    func hitBox(at date: Date, height: CGFloat) -> CGRect {
        let body = body(at: date, height: height)
        guard case .timer(let timer) = job, !isWalking(at: date), !isCheering(at: date) else { return body }
        let scale = height / 50, frame = frame(at: date, height: height)
        let label = CGRect(x: labelX(at: date, height: height), y: (height - 17) / 2, width: labelWidth(at: date) ?? 0, height: 17)
        guard !timer.isEndless else { return body.union(label) }
        return body.union(CGRect(x: frame.minX + 57 * scale, y: 15 * scale, width: 26 * scale, height: 26 * scale)).union(label)
    }

    /// How wide its label is, padding and all.
    func labelWidth(at date: Date) -> CGFloat? {
        label(at: date).map {
            ($0.text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)]).width + 12
        }
    }

    /// Where its label starts at its job, from the left of its drawing.
    func labelOffset(height: CGFloat) -> CGFloat {
        let scale = height / 50
        switch job {
        case .timer(let timer) where !timer.isEndless: return 84 * scale
        case .battery: return 84 * scale
        default: return 50 * scale
        }
    }

    static func width(height: CGFloat) -> CGFloat { 100 * height / 50 }

    /// How far it and its things reach either side of its middle while it's at its job, with
    /// room for a label.
    static func reach(height: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let scale = height / 50
        return (26 * scale, 74 * scale + 40)
    }

    func draw(_ drawing: OylDrawing, at date: Date) {
        if let cheered, isCheering(at: date) {
            drawing.cheer(hat: job.hat, since: date.timeIntervalSince(cheered), length: WalkerOverlay.cheer)
            return
        }
        if isWalking(at: date) {
            drawing.walk(facingRight: to >= from, hat: job.hat, carrying: job.duty)
            return
        }
        switch job {
        case .hangout:
            drawing.hangOut(music: false)
        case .agent(let session):
            drawing.draw(session.activity, hat: true, walking: false, surfing: false)
        default:
            if let duty = job.duty { drawing.perform(duty) }
        }
    }

    /// Its countdown (or what it's for), shown beside it, and in what color.
    func label(at date: Date) -> (text: String, color: Color)? {
        guard !leaving else { return nil }
        switch job {
        case .timer(let timer) where timer.isEndless:
            return (timer.label.isEmpty ? "∞" : String(timer.label.prefix(20)), Oyl.noteYellow)
        case .timer(let timer):
            let left = timer.remaining(at: date)
            return ((timer.isRunning ? "" : "paused ") + ReminderTimer.format(left),
                    timer.tint(fractionLeft: timer.fractionLeft(at: date)))
        case .awake(.until(let end)):
            return (ReminderTimer.format(end.timeIntervalSince(date)), AwakePage.tint)
        case .awake(.whileRunning(_, let name)):
            return ("watching \(name)", AwakePage.tint)
        case .battery(.tired(let percent)):
            return ("\(percent)%", Color(red: 1, green: 0.45, blue: 0.4))
        case .battery(.recharging(let percent)):
            return ("\(percent)%", Color(red: 0.45, green: 0.9, blue: 0.55))
        default:
            return nil
        }
    }

    /// Where its label starts: past its things while it's at its job, else just past it.
    func labelX(at date: Date, height: CGFloat) -> CGFloat {
        if isWalking(at: date) || isCheering(at: date) { return body(at: date, height: height).maxX + 2 }
        return frame(at: date, height: height).minX + labelOffset(height: height)
    }
}

final class Walkers: ObservableObject {
    @Published var list: [Walker] = []
    /// The menu bar's height and width; Oyls are drawn as tall, and talk below it.
    @Published var barHeight: CGFloat = 34
    @Published var barWidth: CGFloat = 0
    /// What they're saying, by Oyl ("calendar" for the calendar's).
    @Published var sayings: [String: Saying] = [:]
    /// The menu bar's dark behind them.
    @Published var dimmed = false
    /// Sent off: the calendar fades away as they go.
    @Published var away = false
    /// The calendar bar, in the panel, and the events for it.
    @Published var calendar: CGRect?
    @Published var events: [DayEvent] = []
    @Published var calendarNote: String?
    var calendarPoked: Date?
    /// The line being sung right now, for the singing Oyl.
    var lyricLine: (Date) -> String? = { _ in nil }

    /// Where the calendar's Oyl stands: at now, a fifth of the way along.
    static func now(in strip: CGRect) -> CGFloat { strip.minX + strip.width * WalkerOverlay.past }



    static func calendarOyl(in strip: CGRect) -> CGRect {
        let scale = strip.height / 50
        return CGRect(x: now(in: strip) - 20 * scale, y: 3 * scale, width: 40 * scale, height: 44 * scale)
    }

    func current(at date: Date) -> DayEvent? { events.current(at: date) }
    func next(after date: Date) -> DayEvent? { events.next(after: date) }
}

/// The first click on a window that isn't key goes straight to what's under it.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The calendar bar underneath (redrawn now and then; it only creeps along), the Oyls on top,
/// each in a canvas of its own so only the little bits that move get redrawn, and what they're
/// saying below the bar.
private struct WalkersView: View {
    @ObservedObject var walkers: Walkers
    let onClick: (CGPoint) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.8)
                .frame(height: walkers.barHeight)
                .opacity(walkers.dimmed ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: walkers.dimmed)
            if let strip = walkers.calendar {
                CalendarBar(events: walkers.events, note: walkers.calendarNote)
                    .frame(width: strip.width, height: strip.height)
                    .offset(x: strip.minX, y: strip.minY)
                    .opacity(walkers.away ? 0 : 1)
                    .animation(.easeOut(duration: 0.6), value: walkers.away)
            }
            // 10 a second: smooth enough for a little walk, and easy on the CPU.
            TimelineView(.animation(minimumInterval: 1.0 / 10)) { context in
                sprites(height: walkers.barHeight, at: context.date)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { onClick($0.location) })
    }

    private func sprites(height: CGFloat, at date: Date) -> some View {
        let scale = height / 50, beat = CGFloat(max(Beat.level - 0.3, 0) / 0.7)
        let time = date.timeIntervalSinceReferenceDate
        return ZStack(alignment: .topLeading) {
            // The calendar's Oyl, at now, doing what's on, or looking ahead to what's next.
            if let strip = walkers.calendar, !walkers.away {
                let middle = Walkers.now(in: strip)
                let current = walkers.current(at: date), next = walkers.events.peekTarget(at: date)
                Canvas { canvas, size in
                    var place = canvas
                    Self.hop(&place, poked: walkers.calendarPoked, body: CGRect(x: 6 * scale, y: 3 * scale, width: 40 * scale, height: 44 * scale),
                             at: date)
                    let drawing = OylDrawing(canvas: place, size: size, time: time, beat: beat, skin: Oyl.white, outline: Oyl.menuBarOutline)
                    if let activity = current?.activity {
                        drawing.attend(activity)
                    } else if next != nil {
                        drawing.peek()
                    } else {
                        drawing.hangOut(music: false)
                    }
                }
                .frame(width: 100 * scale, height: height)
                .offset(x: middle - 26 * scale)
                if let saying = walkers.sayings["calendar"], saying.isShowing(at: date) {
                    bubble(saying.text, image: nil, under: middle, height: height)
                }
            }
            ForEach(walkers.list) { walker in
                let frame = walker.frame(at: date, height: height)
                let body = walker.body(at: date, height: height)
                Canvas { canvas, size in
                    var place = canvas
                    Self.hop(&place, poked: walker.poked, body: body.offsetBy(dx: -frame.minX, dy: 0), at: date)
                    walker.draw(OylDrawing(canvas: place, size: size, time: time, beat: beat, skin: walker.job.skin(at: date),
                                           outline: Oyl.menuBarOutline, pace: Double(walker.pace)), at: date)
                }
                .frame(width: frame.width, height: height)
                .offset(x: frame.minX)
                // Its countdown, following it about.
                if let label = walker.label(at: date) {
                    Text(label.text)
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(label.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .fixedSize()
                        .frame(height: height)
                        .offset(x: walker.labelX(at: date, height: height))
                }
                // What it's saying; the singer, the line being sung.
                if let saying = walkers.sayings[walker.id], saying.isShowing(at: date) {
                    bubble(saying.text, image: saying.image, under: body.midX, height: height)
                } else if case .singer = walker.job, !walker.leaving {
                    bubble("♪ " + (walkers.lyricLine(date) ?? "…"), image: nil, under: body.midX, height: height)
                }
            }
        }
    }

    /// A speech bubble hanging just below the menu bar, its tail up to the Oyl at `x`; it opens
    /// to the left instead near the right edge of the screen.
    @ViewBuilder
    private func bubble(_ text: String, image: NSImage?, under x: CGFloat, height: CGFloat) -> some View {
        let leftward = x > walkers.barWidth - 270
        SpeechBubble(text: text, image: image, tailOnRight: leftward)
            .frame(width: leftward ? x + 14 : nil, alignment: .trailing)
            .offset(x: leftward ? 0 : max(x - 14, 4), y: height + 1)
    }

    /// Poked: a little hop, and a heart by its head.
    private static func hop(_ place: inout GraphicsContext, poked: Date?, body: CGRect, at date: Date) {
        guard let poked else { return }
        let progress = date.timeIntervalSince(poked) / 1.2
        guard progress < 1 else { return }
        var heart = place
        heart.opacity = 1 - progress
        OylDrawing.heart(in: heart, at: CGPoint(x: body.maxX, y: body.minY + body.height * (0.3 - 0.25 * progress)),
                         size: body.height * 0.1)
        place.translateBy(x: 0, y: -sin(progress * .pi) * body.height * 0.1)
    }
}

/// What an Oyl says: a line or two of text (or a picture), its tail pointing up.
private struct SpeechBubble: View {
    let text: String
    let image: NSImage?
    let tailOnRight: Bool

    private static let fill = Color.black.opacity(0.8)

    var body: some View {
        VStack(alignment: tailOnRight ? .trailing : .leading, spacing: 0) {
            Tail().fill(Self.fill)
                .frame(width: 10, height: 5)
                .padding(.horizontal, 9)
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(4)
                } else {
                    Capped(width: 240) {
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                }
            }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Self.fill))
        }
        .fixedSize()
    }

    /// No wider than `width`, wrapping to fit, but no wider than it needs to be either.
    private struct Capped: SwiftUI.Layout {
        let width: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
            subviews.first?.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? width, width), height: nil)) ?? .zero
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    private struct Tail: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

/// Today along a line: what's gone by on the left fifth, dimmed, what's coming up to the right,
/// each event in its calendar's color with its name and time; all-day and multi-day events
/// faintly behind them all.
private struct CalendarBar: View {
    let events: [DayEvent]
    let note: String?

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            Canvas { canvas, size in
                draw(in: canvas, size: size, at: context.date)
            }
        }
    }

    private func draw(in canvas: GraphicsContext, size: CGSize, at date: Date) {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: 2)
        let shape = Path(roundedRect: bounds, cornerRadius: bounds.height / 2)
        canvas.fill(shape, with: .color(.black.opacity(0.6)))
        var inside = canvas
        inside.clip(to: shape)
        let timeline = Timeline(events: events, at: date)
        let now = bounds.minX + bounds.width * WalkerOverlay.past
        // Six hours along the bar where nothing's squeezed.
        let perSecond = bounds.width / CGFloat(6 * 3600)
        func x(_ moment: Date) -> CGFloat { now + CGFloat(timeline.offset(to: moment)) * perSecond }

        // A tick for each hour, top and bottom (bunched up where time's squeezed), and at
        // midnight a taller one with the day's name.
        if var hour = Calendar.current.dateInterval(of: .hour, for: date.addingTimeInterval(-2 * 3600))?.start {
            var hours = 0
            while x(hour) < bounds.maxX, hours < 24 * 8 {
                let tick = x(hour)
                if Calendar.current.component(.hour, from: hour) == 0 {
                    inside.fill(Path(CGRect(x: tick - 0.5, y: bounds.minY, width: 1, height: bounds.height)), with: .color(.white.opacity(0.3)))
                    let day = inside.resolve(Text(hour.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 7.5, weight: .semibold)).foregroundColor(.white.opacity(0.5)))
                    inside.draw(day, at: CGPoint(x: tick + 3, y: bounds.minY + 1), anchor: .topLeading)
                } else {
                    for y in [bounds.minY, bounds.maxY - 3] {
                        inside.fill(Path(CGRect(x: tick - 0.5, y: y, width: 1, height: 3)), with: .color(.white.opacity(0.25)))
                    }
                }
                hour.addTimeInterval(3600)
                hours += 1
            }
        }

        // All-day and multi-day events: faint bands behind, their names small along the bottom,
        // past the Oyl and one after another.
        let oylReach = 74 * size.height / 50
        var nextName = now + oylReach
        for event in events where event.isBackground {
            let left = max(x(event.start), bounds.minX), right = min(x(event.end), bounds.maxX)
            guard right > left else { continue }
            let band = CGRect(x: left, y: bounds.minY, width: right - left, height: bounds.height)
            inside.fill(Path(band), with: .color(event.color.opacity(0.16)))
            let name = inside.resolve(Text(event.title).font(.system(size: 7.5, weight: .medium)).foregroundColor(.white.opacity(0.4)))
            let nameX = max(left + 4, nextName)
            guard nameX + 8 < right else { continue }
            var label = inside
            label.clip(to: Path(band))
            label.draw(name, at: CGPoint(x: nameX, y: bounds.maxY - 2), anchor: .bottomLeading)
            nextName = nameX + name.measure(in: size).width + 8
        }

        // The events. The one on now has its name past the Oyl and its things.
        for event in events where !event.isBackground {
            let left = x(event.start), right = x(event.end)
            guard right > bounds.minX, left < bounds.maxX else { continue }
            let block = CGRect(x: left + 1, y: bounds.minY + 3, width: max(right - left - 2, 2), height: bounds.height - 6)
            let rounded = Path(roundedRect: block, cornerRadius: 5)
            inside.fill(rounded, with: .color(event.color.opacity(0.85)))
            var label = inside
            label.clip(to: rounded)
            let textX = event.isOn(at: date) ? max(block.minX + 5, now + oylReach) : block.minX + 5
            let title = label.resolve(Text(event.title).font(.system(size: 10, weight: .semibold)).foregroundColor(.white))
            let time = label.resolve(Text(Self.time.string(from: event.start))
                .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.8)))
            label.draw(title, at: CGPoint(x: textX, y: block.minY + 1.5), anchor: .topLeading)
            label.draw(time, at: CGPoint(x: textX, y: block.maxY - 1), anchor: .bottomLeading)
        }

        // What's gone by, dimmed, and the line at now.
        inside.fill(Path(CGRect(x: bounds.minX, y: bounds.minY, width: now - bounds.minX, height: bounds.height)),
                    with: .color(.black.opacity(0.35)))
        inside.fill(Path(CGRect(x: now - 0.5, y: bounds.minY, width: 1, height: bounds.height)), with: .color(.white.opacity(0.6)))

        if let note {
            let text = inside.resolve(Text(note).font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.6)))
            inside.draw(text, at: CGPoint(x: now + oylReach + 4, y: bounds.midY), anchor: .leading)
        }
    }
}

/// Where moments go along the calendar bar, as time from now. The hour before each event and
/// the event itself run at full speed; the empty stretches between are squeezed to a seventh
/// (more when the next thing's far off, so it's never more than a couple of hours' worth of bar
/// away), and it slides in from the right, quicker as it nears. What's gone by isn't squeezed.
struct Timeline {
    static let leadIn: TimeInterval = 3600
    static let farthest: TimeInterval = 2.5 * 3600

    let now: Date
    /// Where time runs at full speed: merged, in order.
    private let full: [(start: Date, end: Date)]
    private let squeeze: Double

    init(events: [DayEvent], at now: Date) {
        self.now = now
        var merged: [(start: Date, end: Date)] = []
        for event in events.filter({ !$0.isBackground && $0.end > now }).sorted(by: { $0.start < $1.start }) {
            let span = (start: event.start.addingTimeInterval(-Self.leadIn), end: event.end)
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        full = merged
        let wait = merged.first.map { $0.start.timeIntervalSince(now) } ?? 0
        squeeze = wait > 0 ? min(0.15, Self.farthest / wait) : 0.15
    }

    /// Seconds along the bar from now to `moment`.
    func offset(to moment: Date) -> TimeInterval {
        let elapsed = moment.timeIntervalSince(now)
        guard elapsed > 0 else { return elapsed }
        let unsqueezed = full.reduce(0.0) { total, span in
            total + max(0, min(span.end, moment).timeIntervalSince(max(span.start, now)))
        }
        return elapsed * squeeze + unsqueezed * (1 - squeeze)
    }
}
