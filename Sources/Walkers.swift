import AppKit
import Combine
import SwiftUI

/// Oyls out on the menu bar, one for each thing Oyl's up to: an agent at work, a song (sung
/// along to, once you've asked for the lyrics), a timer or reminder, staying awake, a low
/// battery, a late night, a selfie just taken; with none of those, Oyl on his own, hanging out.
/// They come out from the notch, wander anywhere along the bar, stopping a while at each spot to
/// get on with their job, and walk off the nearer edge once it's done (jumping for joy first if
/// it's work they finished). Walking past the notch they dash across it in half a second, fading
/// out and back in rather than vanishing behind it. They never stop on top of each other, or on
/// the clock. Click one and it says what it's for, hops, and moves out of the way; an agent's
/// takes you to where it's working, a selfie's opens the picture, the song's opens the notch to
/// the music, and a timer's to the timers, that one picked out. Tipping your hand left sends
/// them dashing left to line up; tipping it right flings them off to the right (each undoes the
/// other, and they come back the way they went).
///
/// With the dimming setting on, the menu bar goes 80% black behind them, in a fullscreen app as
/// well, so they stand out from its text.
///
/// Right of the notch is the calendar bar (unless it's turned off): events sliding in from the
/// right and off to the left as the time passes (long empty stretches squeezed, so what's next is
/// always on it), with an Oyl (unless that's turned off) standing at now doing whatever the event
/// on now is, or, with nothing else on today, peering ahead with a magnifying glass.
///
/// In Midnight Oyl they're moyls, little planets (see `Moyl`), and float rather than walk: easing
/// off and drifting to a stop, each circling slowly round where it's got to as an orrery's planet
/// does, swinging side to side and dipping nearer and back, and bobbing as it goes. Past the notch
/// they go behind it, as a planet passes behind another. What they say is set in Midnight's type
/// on a soft patch of night, with no edge to it; a moyl whose work is done flares like a nova
/// before it drifts off. While Midnight's band is open it covers the whole bar, and they fade away
/// under it (and aren't drawn) until it's gone. The calendar bar is Gargoyle's alone.
///
/// They all get a see-through window of their own along the top of the screen, above the menu
/// bar and under the notch, reaching a little below the bar for what they say. It takes the
/// pointer only while it's over an Oyl or the calendar.
@MainActor
final class WalkerOverlay {
    nonisolated static let speed: CGFloat = 46                // points a second
    static let stay: ClosedRange<TimeInterval> = 8...18       // at each spot
    /// Moyls float this much slower than Oyls walk, and stay longer at each spot.
    nonisolated static let floating: CGFloat = 0.6
    static let floatingStay: ClosedRange<TimeInterval> = 14...30
    nonisolated static let cheer: TimeInterval = 1.8          // jumping for joy, before walking off
    /// How much of the calendar bar has gone by.
    nonisolated static let past: CGFloat = 0.2
    /// How long walking across the notch takes.
    nonisolated static let crossing: TimeInterval = 0.5
    /// Room under the menu bar for speech bubbles.
    static let below: CGFloat = 64
    /// How long Oyls flung to the left stay lined up there.
    static let parked: TimeInterval = 180
    /// How fast they dash when flung, and trot back after.
    nonisolated static let dash: CGFloat = speed * 10
    nonisolated static let trot: CGFloat = 2.2

    let walkers = Walkers()
    /// An agent's Oyl was clicked.
    var onReveal: (AgentSession) -> Void = { _ in }
    /// A selfie's Oyl was clicked.
    var onSelfie: (URL) -> Void = { _ in }
    /// An Oyl with a page of its own in the notch was clicked: the song's, a timer's.
    var onOpen: (Walker.Job) -> Void = { _ in }
    /// The calendar bar was clicked.
    var onCalendar: () -> Void = {}
    /// What an Oyl would say it's doing.
    var describe: (Walker.Job) -> String = { _ in "" } {
        didSet { walkers.describe = describe }
    }

    private let panel: NSPanel
    /// Where the closed notch is along the bar (the calendar goes right of it), and how much of
    /// the bar the notch covers now: more while it's open. That's what Oyls skip across, fade
    /// out under, and don't stop at.
    private var notch: ClosedRange<CGFloat> = 0...0
    private var covered: ClosedRange<CGFloat> = 0...0
    /// Where the menu bar's clock is, if it can be found.
    private var clock: ClosedRange<CGFloat>?
    private var planner: Timer?
    private var ticks = 0
    private var isShown = true
    /// Lined up on the left (by a tilt to the left) until then.
    private var linedUpUntil = Date.distantPast
    /// Coming back after being flung off to the right: in from the right, not the notch.
    private var returningFromRight = false
    /// In a fullscreen app, they never take the pointer: the menu bar slides down over them and
    /// has to see the pointer leave to slide back up. (Clicks on them still count; see
    /// `clickedThrough(at:)`.)
    var inFullscreen = false {
        didSet { if inFullscreen { panel.ignoresMouseEvents = true } }
    }
    /// The menu bar goes dark behind them whenever they're out.
    var dimsBar = false {
        didSet { updateDim() }
    }
    /// None of them takes the pointer, till it next moves over one: Mission Control's up.
    func letPointerThrough() {
        panel.ignoresMouseEvents = true
        if walkers.hovered != nil { walkers.hovered = nil }
    }
    /// Nothing on screen can be seen (the lid's shut): the Oyls aren't drawn or moved on, and
    /// carry on from wherever they'd be by then once they're back.
    var isResting = false {
        didSet {
            guard isResting != oldValue else { return }
            if isResting {
                planner?.invalidate()
                planner = nil
                hidePanel()
            } else {
                show()
            }
        }
    }
    /// Their countdowns, all the time; off, only in their last three minutes.
    var showsCountdowns = true {
        didSet { if showsCountdowns != walkers.allCountdowns { walkers.allCountdowns = showsCountdowns } }
    }
    /// The calendar bar's out at all.
    var showsCalendar = true {
        didSet {
            guard showsCalendar != oldValue else { return }
            layOutCalendar()
            show()
        }
    }
    /// Which look they're in: Oyls in Gargoyle, moyls in Midnight Oyl. Those on their way when it
    /// changes carry on from where they are, at the new look's pace.
    var theme = NotchTheme.standard {
        didSet {
            guard theme != oldValue else { return }
            walkers.theme = theme
            let now = Date()
            for index in walkers.list.indices {
                let walker = walkers.list[index]
                walkers.list[index].floats = floats
                guard walker.isWalking(at: now) else { continue }
                // Stopped where it is, in the old look's stride, to set off again in the new one's.
                walkers.list[index].from = walker.middle(at: now)
                walkers.list[index].leaves = now
                let stay = walker.moves == .distantFuture ? TimeInterval.infinity : walker.moves.timeIntervalSince(walker.arrives)
                let dashing = walker.speed > Self.speed * 3
                move(&walkers.list[index], to: walker.to, at: now, speed: dashing ? walker.speed : walker.leaving ? leavingSpeed : nil,
                     stay: stay)
            }
            layOutCalendar()
            show()
        }
    }
    /// Midnight Oyl's band, while it's open, over the whole bar. The moyls fly off the bar into
    /// its sky as it blooms and float there, clear of its page, its moon and its planisphere's hub
    /// and well above its foot (and where the page grows over one, it moves), until the band goes
    /// and they fly back up onto the bar. Their window rises over the band's meanwhile, as deep as
    /// it, taking the pointer only over them as ever; hovered, one shows its ring of words, and
    /// clicked, it goes to its page. Any there's no room for up there fade away under the band.
    var band: BandSky? {
        didSet {
            guard band != oldValue else { return }
            let now = Date()
            if let band { skyDepth = band.size.height }
            if (band == nil) != (oldValue == nil) {
                walkers.bandChanged = now
                walkers.underBand = band != nil
                walkers.hovered = nil
                panel.ignoresMouseEvents = true
                updateDim()
            }
            if oldValue == nil {
                sendUp(at: now)
            } else if band == nil {
                // Back down onto the bar (landing in `tick`).
                for index in walkers.list.indices where walkers.list[index].sky != nil && walkers.list[index].sky?.down == nil {
                    walkers.list[index].sky?.down = now
                }
            } else {
                respot(at: now)
            }
            updatePause()
            updateLively(at: now)
        }
    }

    var isUnderBand: Bool { band != nil }
    /// Their window's up over the band's, as deep as the band's sky, while any are up in it.
    private var aloft = false
    private var skyDepth: CGFloat = 0
    private var screen: NSScreen?

    /// How much room a moyl takes in the sky: its ring's, when it's hovered.
    private func skyRoom(for walker: Walker) -> CGFloat {
        2 * (MoylSprite.ringRadius(for: describe(walker.job.named), height: bar) + Walker.ringLetters)
    }

    var isLinedUp: Bool { linedUpUntil > Date() }

    /// Moyls, floating; or Oyls, walking.
    private var floats: Bool { theme == .midnight }

    /// How far one and its things reach either side of its middle while it's at its job.
    private var reach: (left: CGFloat, right: CGFloat) {
        floats ? Walker.floatingReach(height: bar) : Walker.reach(height: bar)
    }

    /// Off the bar: at a walk, or (a moyl) a little quicker than it floats about.
    private var leavingSpeed: CGFloat? { floats ? Self.speed : nil }

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
        // Not hidden when the app is (Hide Others, say) or goes to the back.
        panel.hidesOnDeactivate = false
        panel.canHide = false
        let host = FirstClickHostingView(rootView: WalkersView(walkers: walkers) { [weak self] point in
            MainActor.assumeIsolated { self?.clicked(at: point) }
        })
        host.sizingOptions = []
        // Midnight's moyls over the Oyls' view, which takes their clicks too.
        let content = NSView()
        for view in [host, MoylsView(walkers: walkers)] as [NSView] {
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
        }
        panel.contentView = content
    }

    private var bar: CGFloat { walkers.barHeight }

    /// Who should be out: newcomers come out of the notch, Oyls whose job is over walk off (those
    /// in `completed` cheering first), and any called back before they're gone turn around.
    /// `notch` is the closed notch and `covered` what the notch covers now, both in screen
    /// coordinates.
    func cast(_ jobs: [Walker.Job], completed: Set<String>, on screen: NSScreen, notch: ClosedRange<CGFloat>,
              covered: ClosedRange<CGFloat>) {
        place(on: screen)
        let notch = (notch.lowerBound - screen.frame.minX)...(notch.upperBound - screen.frame.minX)
        if notch != self.notch {
            self.notch = notch
            layOutCalendar()
        }
        let covered = (covered.lowerBound - screen.frame.minX)...(covered.upperBound - screen.frame.minX)
        if covered != self.covered {
            self.covered = covered
            regap()
        }
        // Hidden: any wanted meanwhile wait till they're called back, then come in with the rest.
        guard isShown else { return }
        let now = Date()
        var list = walkers.list
        // Back from being flung off to the right: in from there, one after another, at a trot.
        let returning = returningFromRight
        returningFromRight = false
        let wanted = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in list.indices {
            if let job = wanted[list[index].id] {
                let settling = job.staysPut && !list[index].job.staysPut
                list[index].job = job
                if list[index].leaving {
                    list[index].leaving = false
                    list[index].cheered = nil
                    list[index].popping = nil
                    if returning {
                        move(&list[index], to: spot(for: list[index], among: list), at: now, speed: pace(of: job) * Self.trot,
                             stay: job.staysPut ? .infinity : nil)
                    } else {
                        plan(&list[index], at: now, among: list)
                    }
                } else if settling {
                    // Into bed where it stands (once it gets there).
                    list[index].moves = .distantFuture
                }
            } else if !list[index].leaving {
                leave(&list[index], at: now, cheering: completed.contains(list[index].id))
            }
        }
        let entrance = returning ? panel.frame.width + Walker.width(height: bar) : (covered.lowerBound + covered.upperBound) / 2
        for (turn, job) in jobs.filter({ job in !list.contains(where: { $0.id == job.id }) }).enumerated() {
            var walker = Walker(job: job, at: entrance, since: now)
            if returning {
                move(&walker, to: spot(for: walker, among: list), at: now, after: Double(turn) * 0.4, speed: pace(of: job) * Self.trot,
                     stay: job.staysPut ? .infinity : nil)
            } else {
                plan(&walker, at: now, among: list)
            }
            list.append(walker)
        }
        if list != walkers.list { walkers.list = list }
        // Newcomers while the band's open come out of the notch up into its sky.
        if band != nil { sendUp(at: now) }
        updateLively(at: now)
        show()
    }

    /// Today's events, for the calendar bar; `note` says why there are none, if there's a reason.
    func showCalendar(_ events: [DayEvent], note: String?) {
        if events != walkers.events { walkers.events = events }
        if note != walkers.calendarNote { walkers.calendarNote = note }
        layOutCalendar()
        show()
    }

    /// Shows them all (they come out again once cast: from the right if they were flung off
    /// there), or flings them all off to the right, calendar fading with them, and then hides.
    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        updateDim()
        linedUpUntil = .distantPast
        walkers.away = !shown
        if shown {
            returningFromRight = true
            show()
            return
        }
        let now = Date(), offRight = panel.frame.width + Walker.width(height: bar)
        for index in walkers.list.indices {
            walkers.list[index].leaving = true
            walkers.list[index].cheered = nil
            walkers.list[index].popping = nil
            move(&walkers.list[index], to: offRight, at: now, speed: Self.dash, stay: .infinity)
        }
        walkers.sayings = [:]
        panel.ignoresMouseEvents = true
    }

    /// Dark behind them while they're out, with the setting on (but not in Midnight, whose moyls
    /// are only in the band's sky).
    private func updateDim() {
        let dim = dimsBar && isShown && !isUnderBand && walkers.theme != .midnight
        if dim != walkers.dimmed { walkers.dimmed = dim }
    }

    /// A speech bubble under Oyl `id`, for `seconds`, starting
    /// after `delay`.
    func say(_ text: String, as id: String, for seconds: TimeInterval, after delay: TimeInterval = 0, image: NSImage? = nil) {
        let from = Date().addingTimeInterval(delay)
        walkers.sayings[id] = Saying(text: text, image: image, from: from, until: from.addingTimeInterval(seconds))
    }

    /// Every Oyl says what it's doing, for six seconds: all of them at once, left to right a
    /// beat apart (their bubbles laid out so none overlap; see `BubbleLayout`). In Midnight Oyl,
    /// each moyl is wreathed in a ring of words instead (see `wreathe`).
    func announce() {
        guard !floats else {
            wreathe()
            return
        }
        let now = Date()
        let speakers = walkers.list.filter { !$0.leaving }.map { (x: $0.middle(at: now), id: $0.id, text: describe($0.job)) }
        for (turn, speaker) in speakers.sorted(by: { $0.x < $1.x }).enumerated() {
            say(speaker.text, as: speaker.id, for: 6, after: Double(turn) * 0.12)
        }
    }

    /// Midnight Oyl's announcing, for `length`: each moyl dips a little below the bar, so all of
    /// it shows, in a ring of words going all the way round it saying what it's for (see
    /// `MoylsView`); and they float apart first, so no two rings overlap or go behind the notch.
    private func wreathe(for length: TimeInterval = 6) {
        let now = Date()
        let order = walkers.list.indices.filter { !walkers.list[$0].leaving && walkers.list[$0].sky == nil }
            .sorted { walkers.list[$0].middle(at: now) < walkers.list[$1].middle(at: now) }
        // Each ring as big as its words need, and the room it takes, soft backing and all.
        let radii = order.map { MoylSprite.ringRadius(for: describe(walkers.list[$0].job.named), height: bar) }
        let halves = radii.map { $0 + MoylSprite.ringBacking }
        let widest = halves.max() ?? 0
        let segments = [widest...(covered.lowerBound - widest), (covered.upperBound + widest)...(panel.frame.width - widest)]
        let spots = Self.spread(order.map { walkers.list[$0].middle(at: now) }, halves: halves, gap: 4, in: segments)
        for (turn, (index, x)) in zip(order, spots).enumerated() {
            let from = now.addingTimeInterval(Double(turn) * 0.12)
            if abs(x - walkers.list[index].middle(at: now)) > 1 || walkers.list[index].isWalking(at: now) {
                move(&walkers.list[index], to: x, at: now, speed: Self.speed * 2.5, stay: length + 0.6)
            } else {
                walkers.list[index].moves = max(walkers.list[index].moves, now.addingTimeInterval(length + 0.6))
            }
            walkers.list[index].ring = Walker.Ring(from: from, until: from.addingTimeInterval(length), radius: radii[turn])
        }
        updateLively(at: now)
    }

    /// `xs` (in order) moved apart so none of them comes within `gap` of the next, each taking
    /// `halves` either side, and each as near where it was as it can be, within `segments` (left
    /// to right, apart from each other): any that won't fit in the one they're nearest go into
    /// the one next along; where even that's not enough, they share it evenly.
    static func spread(_ xs: [CGFloat], halves: [CGFloat], gap: CGFloat, in segments: [ClosedRange<CGFloat>]) -> [CGFloat] {
        let segments = segments.filter { $0.upperBound >= $0.lowerBound }
        guard !segments.isEmpty, !xs.isEmpty, halves.count == xs.count else { return xs }
        func distance(_ x: CGFloat, _ segment: ClosedRange<CGFloat>) -> CGFloat {
            max(segment.lowerBound - x, x - segment.upperBound, 0)
        }
        /// Whether `members` fit in `segment`, side by side.
        func fits(_ members: [Int], _ segment: Int) -> Bool {
            let needed = zip(members, members.dropFirst()).reduce(0) { $0 + halves[$1.0] + halves[$1.1] + gap }
            return needed <= segments[segment].upperBound - segments[segment].lowerBound
        }
        var groups = Array(repeating: [Int](), count: segments.count)
        for (index, x) in xs.enumerated() {
            groups[segments.indices.min { distance(x, segments[$0]) < distance(x, segments[$1]) }!].append(index)
        }
        for _ in xs.indices {
            var moved = false
            for group in segments.indices where !fits(groups[group], group) {
                if group + 1 < segments.count, let last = groups[group].last, fits([last] + groups[group + 1], group + 1) {
                    groups[group + 1].insert(groups[group].removeLast(), at: 0)
                    moved = true
                } else if group > 0, let first = groups[group].first, fits(groups[group - 1] + [first], group - 1) {
                    groups[group - 1].append(groups[group].removeFirst())
                    moved = true
                }
            }
            if !moved { break }
        }
        var out = xs
        for (group, members) in groups.enumerated() where !members.isEmpty {
            let segment = segments[group]
            func apart(_ index: Int) -> CGFloat { halves[members[index - 1]] + halves[members[index]] + gap }
            var placed = members.map { min(max(xs[$0], segment.lowerBound), segment.upperBound) }
            for index in placed.indices.dropFirst() { placed[index] = max(placed[index], placed[index - 1] + apart(index)) }
            placed[placed.count - 1] = min(placed[placed.count - 1], segment.upperBound)
            for index in placed.indices.reversed().dropFirst() { placed[index] = min(placed[index], placed[index + 1] - apart(index + 1)) }
            if placed[0] < segment.lowerBound {
                // Too many even so: spaced evenly, overlapping as little as they can.
                let step = placed.count > 1 ? (segment.upperBound - segment.lowerBound) / CGFloat(placed.count - 1) : 0
                placed = placed.indices.map { segment.lowerBound + CGFloat($0) * step }
            }
            for (member, x) in zip(members, placed) { out[member] = x }
        }
        return out
    }

    /// Every moyl not up in the band's sky already (or on its way back down) up into it, each to
    /// the clear spot nearest under where it is, a beat apart.
    private func sendUp(at now: Date) {
        guard let band, floats else { return }
        var taken = walkers.list.compactMap { walker in walker.sky.flatMap { $0.down == nil ? ($0.spot, $0.room) : nil } }
        let order = walkers.list.indices.filter { !walkers.list[$0].leaving && (walkers.list[$0].sky == nil || walkers.list[$0].sky?.down != nil) }
            .sorted { walkers.list[$0].middle(at: now) < walkers.list[$1].middle(at: now) }
        for (turn, index) in order.enumerated() {
            let walker = walkers.list[index], room = skyRoom(for: walker)
            guard let spot = band.spot(under: walker.middle(at: now), room: room, avoiding: taken) else { continue }
            taken.append((spot, room))
            // On its way back down: up again from where it's got to.
            let from = walker.sky != nil ? walker.place(at: now, height: bar).center : nil
            walkers.list[index].sky = Walker.Sky(spot: spot, room: room, from: from,
                                                 moved: now.addingTimeInterval(from == nil ? Double(turn) * 0.06 : 0))
        }
        if walkers.list.contains(where: { $0.sky != nil }) { rise() }
    }

    /// The band's grown or shrunk (a new page): any it's now over move to another clear spot.
    private func respot(at now: Date) {
        guard let band else { return }
        var taken = walkers.list.compactMap { walker in walker.sky.flatMap { $0.down == nil ? ($0.spot, $0.room) : nil } }
        for index in walkers.list.indices {
            guard let sky = walkers.list[index].sky, sky.down == nil, !band.isClear(sky.spot, room: sky.room) else { continue }
            taken.removeAll { $0.0 == sky.spot }
            let here = walkers.list[index].place(at: now, height: bar).center
            guard let spot = band.spot(under: sky.spot.x, room: sky.room, avoiding: taken) else {
                taken.append((sky.spot, sky.room))
                continue
            }
            taken.append((spot, sky.room))
            walkers.list[index].sky = Walker.Sky(spot: spot, room: sky.room, from: here, moved: now)
        }
        sendUp(at: now)
    }

    /// Their window up over the band's, as deep as it, while they're in its sky; and back down.
    private func rise() {
        guard !aloft else { return }
        aloft = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        if let screen { place(on: screen) }
    }

    private func land() {
        guard aloft else { return }
        aloft = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        if let screen { place(on: screen) }
    }

    /// Done lining up: everyone off to wander again.
    func scatter() {
        let now = Date()
        linedUpUntil = .distantPast
        for index in walkers.list.indices where !walkers.list[index].leaving {
            plan(&walkers.list[index], at: now, among: walkers.list)
        }
        updateLively(at: now)
    }

    /// Every Oyl off to the left, lined up: grouped by what it's for, oldest first in each group.
    /// They stay a few minutes before wandering off again.
    func fling() {
        let now = Date(), reach = self.reach
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
            move(&walkers.list[index], to: x, at: now, speed: Self.dash, stay: Self.parked)
            // Room for it, its things and its label, however long that is.
            let scale = bar / 50, walker = walkers.list[index]
            if floats {
                // A moyl's middle to its next's: its orbit and rings, and its label past them.
                let half = Walker.floatingHalfWidth(height: bar)
                x += max(2 * half + 14, walker.labelWidth(at: now, allCountdowns: showsCountdowns).map { 2 * half + $0 + 10 } ?? 0)
                continue
            }
            let label = walker.labelWidth(at: now, allCountdowns: showsCountdowns).map { walker.labelOffset(height: bar) + $0 + 6 } ?? 0
            x += max(100 * scale + 6, label)
        }
        updateLively(at: now)
    }

    /// The open notch reaches to `right` (screen coordinates), or nil when it's closed: the
    /// calendar bar slides clear of it meanwhile.
    func notchOpen(to right: CGFloat?) {
        var nudge: CGFloat = 0
        if let right, let strip = walkers.calendar {
            nudge = max(0, min(right - panel.frame.minX + 8 - strip.minX, panel.frame.width - 4 - strip.maxX))
        }
        if nudge != walkers.calendarNudge { walkers.calendarNudge = nudge }
    }

    /// Takes the pointer only while it's over an Oyl or the calendar, so the menu bar works
    /// everywhere else.
    func pointerMoved(to location: NSPoint) {
        // The very top row counts too: there the pointer's right on the panel's top edge.
        let frame = panel.frame
        guard isShown, panel.isVisible, (frame.minX...frame.maxX).contains(location.x),
              (frame.minY...frame.maxY).contains(location.y) else {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            if walkers.hovered != nil { walkers.hovered = nil }
            return
        }
        guard !inFullscreen else { return }
        let point = CGPoint(x: location.x - panel.frame.minX, y: panel.frame.maxY - location.y)
        let hit = walker(at: point)
        let over = hit != nil || walkers.calendarFrame?.contains(point) == true
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        // Up in the band's sky, the one under the pointer shows its ring of words.
        let hovered = isUnderBand ? hit?.id : nil
        if hovered != walkers.hovered { walkers.hovered = hovered }
    }

    /// A click seen on its way to another app: in a fullscreen app, where the Oyls don't take the
    /// pointer, one on an Oyl or the calendar still counts. It reaches what's under them too,
    /// usually the black band by the notch (or the menu bar, if it's slid down).
    func clickedThrough(at location: NSPoint) {
        let frame = panel.frame
        guard inFullscreen, isShown, !isResting, !isUnderBand, panel.isVisible,
              (frame.minX...frame.maxX).contains(location.x), (frame.minY...frame.maxY).contains(location.y) else { return }
        clicked(at: CGPoint(x: location.x - frame.minX, y: frame.maxY - location.y))
    }

    private func show() {
        guard isShown, !isResting, !walkers.list.isEmpty || walkers.calendar != nil else { return }
        if !panel.isVisible { showPanel() }
        if planner == nil {
            planner = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    /// Along the top of the screen: the menu bar, and room under it for what they say (or, while
    /// they're up in Midnight's band's sky, as deep as the band).
    private func place(on screen: NSScreen) {
        self.screen = screen
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let height = menuBar > 0 ? menuBar : max(screen.safeAreaInsets.top, 24)
        if height != walkers.barHeight { walkers.barHeight = height }
        if screen.frame.width != walkers.barWidth { walkers.barWidth = screen.frame.width }
        let below = aloft ? max(Self.below, skyDepth - height) : Self.below
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height - below, width: screen.frame.width,
                           height: height + below)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    /// The calendar bar: right of the notch, up to the menu bar's icons, as room allows. And the
    /// clock, last of the icons, which Oyls keep off.
    private func layOutCalendar() {
        guard panel.frame.width > 0 else { return }
        let items = Self.menuBarIcons(on: panel.frame).map {
            (name: $0.name, span: ($0.span.lowerBound - panel.frame.minX)...($0.span.upperBound - panel.frame.minX))
        }
        let left = notch.upperBound + 10
        let room = (items.map(\.span.lowerBound).filter { $0 > left }.min() ?? .greatestFiniteMagnitude) - 10 - left
        // Turned off, in Midnight Oyl (it's Gargoyle's), or too little room left of the icons: no
        // bar, rather than one over them.
        let frame = showsCalendar && !floats && room >= 120 ? CGRect(x: left, y: 0, width: min(room, 420), height: bar) : nil
        if frame != walkers.calendar { walkers.calendar = frame }
        // By name if the system says, else the last one: the clock always is.
        clock = (items.first(where: { $0.name == "Clock" }) ?? items.last)?.span
        // One the notch, the bar or the clock has come over moves out of the way.
        let now = Date()
        for index in walkers.list.indices where !walkers.list[index].leaving && !isClear(walkers.list[index].to) {
            plan(&walkers.list[index], at: now, among: walkers.list)
        }
    }

    /// The menu bar's icons, left to right, on the screen whose top `frame` runs along, with
    /// their names if the system gives them out (in screen coordinates; the window list measures
    /// down from the main screen's top). On macOS 26 they're only listed among all windows, not
    /// among those on screen.
    private static func menuBarIcons(on frame: NSRect) -> [(name: String?, span: ClosedRange<CGFloat>)] {
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let status = Int(CGWindowLevelForKey(.statusWindow))
        let top = Double((NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY)
        return windows.compactMap { window -> (name: String?, span: ClosedRange<CGFloat>)? in
            guard window[kCGWindowLayer as String] as? Int == status,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  let y = bounds["Y"], abs(y - top) < 1, let start = bounds["X"], let width = bounds["Width"], width > 0,
                  CGFloat(start) >= frame.minX, CGFloat(start) < frame.maxX else { return nil }
            return (window[kCGWindowName as String] as? String, CGFloat(start)...CGFloat(start + width))
        }
        .sorted { $0.span.lowerBound < $1.span.lowerBound }
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
        // Landed back on the bar from the band's sky; rings that are over.
        for index in list.indices {
            if band == nil, let down = list[index].sky?.down, now.timeIntervalSince(down) >= Walker.landing { list[index].sky = nil }
            if let ring = list[index].ring, ring.until < now { list[index].ring = nil }
        }
        if list != walkers.list { walkers.list = list }
        if band == nil, aloft, !list.contains(where: { $0.sky != nil }) { land() }
        if walkers.sayings.values.contains(where: { $0.until <= now }) {
            walkers.sayings = walkers.sayings.filter { $0.value.until > now }
        }
        // An Oyl may have walked out from under the pointer, or under it.
        pointerMoved(to: NSEvent.mouseLocation)
        // Menu bar icons come and go.
        ticks += 1
        if ticks % 20 == 0 { layOutCalendar() }
        updatePause()
        updateLively(at: now)
        guard list.isEmpty, walkers.calendar == nil || !isShown else {
            // Taken down from outside while they're out: back up.
            if isShown, !isResting, !panel.isVisible { showPanel() }
            return
        }
        planner?.invalidate()
        planner = nil
        hidePanel()
    }

    /// Their window up, or down; nothing's drawn while it's down. (A window that's down still
    /// ticks its timelines unless they're paused.)
    private func showPanel() {
        panel.orderFrontRegardless()
        updatePause()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        updatePause()
    }

    /// Nothing's drawn while their window's down, or once the moyls have faded away under
    /// Midnight's band.
    private func updatePause() {
        let faded = isUnderBand && !walkers.list.contains { $0.sky != nil }
            && Date().timeIntervalSince(walkers.bandChanged) > Walkers.fadeUnder
        let paused = !panel.isVisible || faded
        if paused != walkers.paused { walkers.paused = paused }
    }

    /// Moyls are moved more often while any is on its way somewhere (or about to be), flaring,
    /// twinkling from a click, or fading under the band or back out: smoother, then, for what
    /// moves most.
    private func updateLively(at now: Date) {
        guard floats else { return }
        let lively = walkers.list.contains { walker in
            // On its way somewhere on the bar, about to be, or in or out of the sky.
            walker.isWalking(at: now.addingTimeInterval(0.5)) || walker.isWalking(at: now) || walker.flare(at: now) > 0
                || walker.popping != nil
                || walker.poked.map { now.timeIntervalSince($0) < 1.2 } == true
                || walker.ring.map { now.timeIntervalSince($0.from) < 1 || $0.until.timeIntervalSince(now) < 1 } == true
                || walker.sky.map { sky in
                    sky.down != nil || now.timeIntervalSince(sky.moved) < (sky.from == nil ? Walker.flight : Walker.shift) + 0.2
                } == true
        } || now.timeIntervalSince(walkers.bandChanged) < Walkers.fadeUnder + 1
        if lively != walkers.lively { walkers.lively = lively }
    }

    /// The notch as it is now, for an Oyl's middle: it skips straight across.
    private var gap: ClosedRange<CGFloat> {
        let half = 22 * bar / 50 + 3
        return (covered.lowerBound - half)...(covered.upperBound + half)
    }

    /// The notch has opened or closed: Oyls on their way carry on to where they were going (from
    /// where they are, skipping its new size), and those standing fade under it.
    private func regap() {
        let now = Date()
        for index in walkers.list.indices {
            let walker = walkers.list[index]
            guard walker.isWalking(at: now) else {
                walkers.list[index].gap = gap
                continue
            }
            let stay = walker.moves == .distantFuture ? TimeInterval.infinity : walker.moves.timeIntervalSince(walker.arrives)
            move(&walkers.list[index], to: walker.to, at: now, speed: walker.speed, stay: stay)
        }
    }

    /// Off to a new spot, from wherever it is now, after `delay`; or, in bed, nowhere.
    private func plan(_ walker: inout Walker, at now: Date, among others: [Walker], after delay: TimeInterval = 0) {
        if walker.job.staysPut {
            // Into bed where it is, if it can be seen there; else it walks out to a spot first.
            let here = walker.middle(at: now)
            let free = isClear(here) && !Self.crowds(here, walker, others, reach: reach)
            walk(&walker, to: free ? here : spot(for: walker, among: others), among: others, at: now, after: delay, stay: .infinity)
            return
        }
        walk(&walker, to: spot(for: walker, among: others), among: others, at: now, after: delay)
    }

    /// Off to `spot`, but never so as to walk along with another, the two looking like one (two
    /// coming out of the notch together, say, or one slowly overtaking another): a moment
    /// later, a little quicker or slower, or off somewhere else, whichever's first clear of them;
    /// passing one going the other way is only a moment. Failing all those, whichever's least
    /// alongside.
    private func walk(_ walker: inout Walker, to spot: CGFloat, among others: [Walker], at now: Date,
                      after delay: TimeInterval = 0, stay: TimeInterval? = nil) {
        let pace = pace(of: walker.job), apart = self.apart
        var spots = [spot]
        for _ in 0..<2 where !walker.job.staysPut { spots.append(self.spot(for: walker, among: others)) }
        var ways: [Walker] = []
        for spot in spots {
            for wait in Self.waits {
                for speed in [pace, pace * 1.2, pace * 0.82] {
                    var way = walker
                    move(&way, to: spot, at: now, after: delay + wait, speed: speed, stay: stay)
                    ways.append(way)
                }
            }
        }
        walker = Self.clearest(ways, among: others, apart: apart, allowed: Self.passing * TimeInterval(apart / pace), from: now) ?? walker
    }

    /// The first of `ways` (each the same Oyl, set off a different way) that's alongside the
    /// others for no longer than `allowed`; else whichever's least.
    nonisolated static func clearest(_ ways: [Walker], among others: [Walker], apart: CGFloat, allowed: TimeInterval,
                                     from now: Date) -> Walker? {
        var best: (way: Walker, alongside: TimeInterval)?
        for way in ways {
            let alongside = alongside(way, among: others, apart: apart, from: now)
            if alongside <= allowed { return way }
            if alongside < best?.alongside ?? .infinity { best = (way, alongside) }
        }
        return best?.way
    }

    /// Waiting this long before setting off, to be clear of the others.
    private static let waits: [TimeInterval] = [0, 0.7, 1.3, 2, 3]
    /// Passing one going the other way takes a moment: this many times as long as walking its
    /// width would.
    nonisolated static let passing: TimeInterval = 1.4

    /// How far apart two Oyls (or moyls) must be not to look like one.
    private var apart: CGFloat { floats ? Walker.moylRadius(height: bar) * 4.6 : 48 * bar / 50 }

    /// How long `walker`, on its way, is within `apart` of another also on its way (anywhere but
    /// under the notch, where neither's seen).
    nonisolated static func alongside(_ walker: Walker, among others: [Walker], apart: CGFloat, from now: Date) -> TimeInterval {
        let start = max(now, walker.leaves), end = walker.arrives, step: TimeInterval = 0.1
        guard end > start else { return 0 }
        var total: TimeInterval = 0
        for other in others where other.id != walker.id && !other.leaving && other.arrives > start && other.leaves < end {
            var date = max(start, other.leaves)
            let stop = min(end, other.arrives)
            while date < stop {
                let x = walker.middle(at: date), theirs = other.middle(at: date)
                if abs(x - theirs) < apart, walker.gap.map({ !$0.contains(x) && !$0.contains(theirs) }) ?? true { total += step }
                date = date.addingTimeInterval(step)
            }
        }
        return total
    }

    private func move(_ walker: inout Walker, to spot: CGFloat, at now: Date, after delay: TimeInterval = 0,
                      speed: CGFloat? = nil, stay: TimeInterval? = nil) {
        let speed = speed ?? pace(of: walker.job)
        let here = walker.middle(at: now)
        walker.floats = floats
        walker.gap = gap
        walker.speed = speed
        walker.from = here
        walker.to = spot
        // Quick steps, but no quicker than 10 frames a second can show.
        walker.pace = min(speed / Self.speed, 2.5)
        // A moyl takes its time behind the notch, as a planet passing behind another.
        walker.crossing = speed * CGFloat(speed > Self.speed * 3 ? 0.12 : floats ? Self.crossing * 3 : Self.crossing)
        walker.leaves = now.addingTimeInterval(delay)
        walker.arrives = walker.leaves.addingTimeInterval(TimeInterval(walker.distance / speed))
        let stay = stay ?? .random(in: floats ? Self.floatingStay : Self.stay)
        walker.moves = stay.isFinite ? walker.arrives.addingTimeInterval(stay) : .distantFuture
    }

    /// How fast one goes about its job: an Oyl's walk, or a moyl's float.
    private func pace(of job: Walker.Job) -> CGFloat {
        job.speed * (floats ? Self.floating : 1)
    }

    /// Done here: where it stands, it waves goodbye, hops twice and goes in a puff (jumping for
    /// joy first, if its work's done); a moyl bows, bobs twice and scatters into stardust.
    private func leave(_ walker: inout Walker, at now: Date, cheering: Bool) {
        let here = walker.middle(at: now)
        walker.leaving = true
        walker.cheered = cheering ? now : nil
        walker.from = here
        walker.to = here
        walker.leaves = now.addingTimeInterval(cheering ? Self.cheer : 0)
        walker.popping = walker.leaves
        walker.arrives = walker.leaves.addingTimeInterval(Walker.popLength)
        walker.moves = .distantFuture
    }

    /// Where Oyls don't stop: the notch, with the stretch beside it where they'd still be partly
    /// faded (so none is left standing there half see-through), the calendar and the clock. Each
    /// is kept clear of an Oyl's whole reach, its things and label and all.
    private var blocked: [ClosedRange<CGFloat>] {
        let reach = self.reach, gap = self.gap
        // As far as an Oyl's reach goes either side of a middle that's just faded all the way in.
        let notch = min(covered.lowerBound, gap.lowerBound - Walker.fade + reach.right + 6)
            ... max(covered.upperBound, gap.upperBound + Walker.fade - reach.left - 6)
        return [notch] + (walkers.calendar.map { [$0.minX...$0.maxX] } ?? []) + (clock.map { [$0] } ?? [])
    }

    /// Whether an Oyl at its job at `x` would be in the clear: on screen, its things and label
    /// clear of the notch, the calendar and the clock.
    private func isClear(_ x: CGFloat) -> Bool {
        let reach = self.reach
        guard x >= reach.left + 4, x <= panel.frame.width - reach.right - 4 else { return false }
        let span = (x - reach.left - 6)...(x + reach.right + 6)
        return !blocked.contains { $0.overlaps(span) }
    }

    /// Somewhere along the bar with room for it, its things and its label: clear of the notch,
    /// the calendar, the clock and the edges, and never where another is (or is headed). Picked at random
    /// from all such places; if there are none, the one with the most room.
    private func spot(for walker: Walker, among others: [Walker]) -> CGFloat {
        let width = panel.frame.width, reach = self.reach
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

    /// The one whose body is at `point`, in the panel (top left origin). The rows above its
    /// head, up to the screen's edge, count as it too.
    private func walker(at point: CGPoint) -> Walker? {
        let now = Date(), point = Self.lowered(point, bar: bar)
        // (Moyls are only seen up in the band's sky; Oyls, while it's closed.)
        let onBar = band == nil && walkers.theme != .midnight
        return walkers.list.last {
            !$0.leaving && (onBar || $0.sky != nil) && $0.hitBox(at: now, height: bar, allCountdowns: showsCountdowns).contains(point)
        }
    }

    private static func lowered(_ point: CGPoint, bar: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: max(point.y, 4 * bar / 50))
    }

    private func clicked(at point: CGPoint) {
        let now = Date()
        if let walker = walker(at: point), let index = walkers.list.firstIndex(of: walker) {
            switch walker.job {
            case .agent(let session): onReveal(session)
            case .selfie(let selfie): onSelfie(selfie.url)
            case .music, .timer: onOpen(walker.job)
            default: break
            }
            say(describe(walker.job), as: walker.id, for: 3)
            walkers.list[index].poked = now
            updateLively(at: now)
            // Then off out of the way, in case it was over something (bed and all).
            if walker.job.staysPut {
                move(&walkers.list[index], to: spot(for: walker, among: walkers.list), at: now, after: 0.7, stay: .infinity)
            } else {
                plan(&walkers.list[index], at: now, among: walkers.list, after: 0.7)
            }
        } else if let strip = walkers.calendarFrame, strip.contains(point) {
            onCalendar()
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
        case music(cover: NSImage?, listening: OylDuty.Listening)
        case timer(ReminderTimer)
        case awake(AwakeManager.Mode)
        case battery(PowerStatus)
        case bedtime(BedtimeStage)
        case selfie(Selfie)
        /// An app (Granola) taking notes on what it hears, by its name.
        case notes(String)

        var id: String {
            switch self {
            case .hangout: return "hangout"
            case .agent(let session): return "agent \(session.id)"
            case .music: return "music"
            case .timer(let timer): return "timer \(timer.id)"
            case .awake: return "awake"
            case .battery: return "battery"
            case .bedtime: return "bedtime"
            case .selfie(let selfie): return "selfie \(selfie.url.lastPathComponent)"
            case .notes(let app): return "notes \(app)"
            }
        }

        var duty: OylDuty? {
            switch self {
            case .hangout, .agent: return nil
            case .music(let cover, let listening): return .music(cover: cover, listening: listening)
            case .timer(let timer): return .timer(timer)
            case .awake(let mode): return .awake(mode)
            case .battery(let status): return .battery(status)
            case .bedtime(let stage): return .bedtime(stage)
            case .selfie(let selfie): return .selfie(selfie.image)
            case .notes(let app): return .notes(app: app)
            }
        }

        /// Its hat, if it wears one (see `AgentSession.cap`).
        var cap: Color? {
            if case .agent(let session) = self { return session.cap }
            return nil
        }

        /// For lining them up: like with like.
        var group: Int {
            switch self {
            case .agent: return 0
            case .notes: return 4
            case .timer: return 1
            case .awake: return 2
            case .music: return 3
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
    /// How fast it's going, in points a second, and against a usual walk (it steps quicker).
    var speed = WalkerOverlay.speed
    var pace: CGFloat = 1
    /// The notch, which it dashes across in `crossing` points' worth of walking.
    var gap: ClosedRange<CGFloat>?
    var crossing: CGFloat = 0
    var leaving = false
    /// When it started its two hops, leaving, before it pops (see `popped(at:)`).
    var popping: Date?
    /// When it started jumping for joy, its work done.
    var cheered: Date?
    var poked: Date?
    /// A moyl, floating, rather than an Oyl walking.
    var floats = false
    /// Its own, 0...1, from what it's for: where in its little orbit it starts, and how it leans
    /// and turns, so no two keep step.
    let seed: Double
    /// A moyl's time in Midnight's band's sky, while the band's open (see `WalkerOverlay.band`).
    var sky: Sky?
    /// A moyl's ring of words round it, saying what it's for, while the moyls announce.
    var ring: Ring?

    /// Up off the bar into the band's sky, floating about `spot`, `room` across (its ring's, when
    /// it's hovered): since `moved`, from `from` (or from the bar, if that's nil); and since
    /// `down`, if it's set, back to the bar.
    struct Sky: Equatable {
        var spot: CGPoint
        var room: CGFloat
        var from: CGPoint?
        var moved: Date
        var down: Date?
    }

    /// From `from` till `until`, `radius` out (its letters' middle): easing in, and out again at
    /// the end.
    struct Ring: Equatable {
        let from: Date
        let until: Date
        let radius: CGFloat

        /// How much of it there is at `date`, 0...1.
        func shown(at date: Date) -> CGFloat {
            Walker.ease(min(date.timeIntervalSince(from), until.timeIntervalSince(date)) / 0.6)
        }
    }

    /// How long it takes to fly up off the bar into the sky (as the band blooms), from one spot
    /// in it to another, and back down onto the bar (as the band goes, quicker).
    static let flight: TimeInterval = 1.3, shift: TimeInterval = 1.2, landing: TimeInterval = 0.55

    /// 0 to 1, easing in and out, from `t` (0...1, clamped).
    static func ease(_ t: Double) -> CGFloat {
        let t = CGFloat(min(max(t, 0), 1))
        return t * t * (3 - 2 * t)
    }

    init(job: Job, at x: CGFloat, since date: Date) {
        self.job = job
        created = date
        from = x
        to = x
        leaves = date
        arrives = date
        moves = date
        // FNV-1a, which (unlike Swift's hashing) is the same from launch to launch.
        var hash: UInt32 = 2_166_136_261
        for byte in job.id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        seed = Double(hash) / Double(UInt32.max)
    }

    /// How far it walks, not counting the notch.
    var distance: CGFloat { abs(fold(to) - fold(from)) }

    func middle(at date: Date) -> CGFloat {
        guard date > leaves else { return from }
        guard date < arrives else { return to }
        var along = CGFloat(date.timeIntervalSince(leaves) / arrives.timeIntervalSince(leaves))
        // A moyl drifts off gently and eases to a stop.
        if floats { along = (1 - cos(along * .pi)) / 2 }
        let start = fold(from), end = fold(to)
        return unfold(start + (end - start) * along)
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

    func isWalking(at date: Date) -> Bool { popping == nil && date > leaves && date < arrives }

    /// Leaving: waving goodbye (a moyl bows), each of its two hops, and its pop after them.
    static let waveTime: TimeInterval = 1
    static let hopTime: TimeInterval = 0.32
    static let popTime: TimeInterval = 0.55
    static var popLength: TimeInterval { waveTime + 2 * hopTime + popTime }

    /// Leaving, once it's started: how far through waving goodbye it is (0…1), how high it is in
    /// its hop (0…1), and how far it's popped (0…1).
    func popped(at date: Date) -> (wave: Double, hop: CGFloat, pop: Double)? {
        guard let popping, date >= popping else { return nil }
        let since = date.timeIntervalSince(popping)
        guard since >= Self.waveTime else { return (since / Self.waveTime, 0, 0) }
        let hopping = since - Self.waveTime
        guard hopping < 2 * Self.hopTime else { return (1, 0, min((hopping - 2 * Self.hopTime) / Self.popTime, 1)) }
        let along = hopping.truncatingRemainder(dividingBy: Self.hopTime) / Self.hopTime
        return (1, CGFloat(sin(along * .pi)), 0)
    }

    /// Faded out at the notch, and in again as it comes clear of it; up in Midnight's sky, all
    /// there (but fading away there, if it's off, its job done).
    func visibility(at date: Date) -> Double {
        var shown = 1.0
        if let gap {
            let x = middle(at: date), clear = max(gap.lowerBound - x, x - gap.upperBound)
            shown = Double(min(max(clear / Self.fade, 0), 1))
        }
        guard let sky else { return shown }
        let aloft = Double(self.aloft(sky, at: date))
        shown += (1 - shown) * aloft
        if leaving, popping != nil {
            shown *= 1 - (popped(at: date)?.pop ?? 0)
        } else if leaving {
            shown *= max(0, 1 - date.timeIntervalSince(max(leaves, sky.moved)) / 1.5)
        }
        return shown
    }

    /// How far up into Midnight's sky it is: 0 on the bar (where a moyl's never seen), 1 up there.
    func inSky(at date: Date) -> CGFloat {
        sky.map { aloft($0, at: date) } ?? 0
    }

    /// How far up off the bar it is, into the sky: 0 on the bar, 1 up there.
    private func aloft(_ sky: Sky, at date: Date) -> CGFloat {
        let up = sky.from == nil ? Self.ease(date.timeIntervalSince(sky.moved) / Self.flight) : 1
        return up * (1 - (sky.down.map { Self.ease(date.timeIntervalSince($0) / Self.landing) } ?? 0))
    }

    /// How far clear of the notch it has to be to have faded all the way back in.
    static let fade: CGFloat = 16

    func isCheering(at date: Date) -> Bool {
        guard let cheered else { return false }
        return date >= cheered && date <= leaves
    }

    /// How bright a moyl's flaring, 0...1, its work done: up quickly, then dying away as it
    /// drifts off.
    func flare(at date: Date) -> Double {
        // Leaving: a soft glint as it bows, and a flash as it pops.
        if let popped = popped(at: date) {
            if popped.pop > 0 { return sin(popped.pop * .pi) }
            if popped.wave < 1 { return 0.22 * sin(popped.wave * .pi) }
        }
        guard let cheered, date >= cheered else { return 0 }
        let since = date.timeIntervalSince(cheered)
        return since < 0.35 ? since / 0.35 : max(0, 1 - (since - 0.35) / (WalkerOverlay.cheer + 1.6))
    }

    // MARK: A moyl's place

    /// How big a moyl's planet is on a bar `height` tall.
    static func moylRadius(height: CGFloat) -> CGFloat { height * 0.26 }

    /// Half how wide a moyl is, rings and moon and the swing of its orbit and all.
    static func floatingHalfWidth(height: CGFloat) -> CGFloat { moylRadius(height: height) * 2.1 + height * orbit }

    /// How far a moyl and its label reach either side of its middle, as `reach(height:)`.
    static func floatingReach(height: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let half = floatingHalfWidth(height: height)
        return (half + 2, half + 44)
    }

    /// How far a moyl swings either side, in its orbit, against the bar's height.
    private static let orbit: CGFloat = 0.2

    /// How far out a moyl's ring of words is at the least (its letters' middle line), just past
    /// its moon's orbit (see `MoylSprite.ringRadius(for:height:)`); and how far its letters reach
    /// past that.
    static func ringRadius(height: CGFloat) -> CGFloat { moylRadius(height: height) * 2.55 }
    static let ringLetters: CGFloat = 4
    static func ringReach(height: CGFloat) -> CGFloat { ringRadius(height: height) + ringLetters }

    /// Where a moyl's planet is. On the bar: at its middle along it, in a little orbit round it,
    /// seen all but edge on as an orrery's planets are (so it swings side to side, dipping nearer
    /// and back), and bobbing; dipped down, holding still, while its ring's round it, so all of the
    /// ring shows. Up in the sky: wandering slowly about its spot there, having swooped down off
    /// the bar to it (and up again after, as the band goes). `near` is how near: -1 at the back of
    /// its orbit, 1 at the front. A click sends it up in a little hop.
    func place(at date: Date, height: CGFloat) -> (center: CGPoint, near: CGFloat) {
        let time = date.timeIntervalSinceReferenceDate
        let angle = 2 * .pi * (time / (34 + 22 * seed) + seed)
        let bob = sin(2 * .pi * (time / (5.5 + 2 * seed) + 3 * seed))
        let swing = height * Self.orbit
        var center = CGPoint(x: middle(at: date) + swing * CGFloat(cos(angle)),
                             y: height / 2 + swing * 0.3 * CGFloat(sin(angle)) + height * 0.035 * CGFloat(bob))
        if let ring {
            center.y += (ring.radius + Self.ringLetters + 3 - center.y) * ring.shown(at: date)
        }
        if let sky {
            let wandering = Self.wander(sky.spot, seed: seed, at: date)
            let up = Self.ease(date.timeIntervalSince(sky.moved) / (sky.from == nil ? Self.flight : Self.shift))
            var aloft = sky.from.map { Self.mix($0, wandering, x: up, y: up) } ?? Self.swoop(center, wandering, up)
            if let down = sky.down { aloft = Self.swoop(aloft, center, Self.ease(date.timeIntervalSince(down) / Self.landing)) }
            center = aloft
        }
        if let poked {
            let hop = date.timeIntervalSince(poked) / 0.7
            if hop > 0 && hop < 1 { center.y -= CGFloat(sin(hop * .pi)) * Self.moylRadius(height: height) * 0.45 }
        }
        // Leaving: a bow, and its two hops, before it pops.
        if let popped = popped(at: date) {
            center.y += CGFloat(sin(popped.wave * .pi)) * Self.moylRadius(height: height) * 0.3
            center.y -= popped.hop * Self.moylRadius(height: height) * 0.7
        }
        return (center, CGFloat(sin(angle)))
    }

    /// Drifting slowly about `spot` among the stars, each its own way.
    private static func wander(_ spot: CGPoint, seed: Double, at date: Date) -> CGPoint {
        let time = date.timeIntervalSinceReferenceDate
        return CGPoint(x: spot.x + 16 * CGFloat(sin(2 * .pi * time / (23 + 9 * seed) + 6 * seed)),
                       y: spot.y + 9 * CGFloat(sin(2 * .pi * time / (17 + 7 * seed) + 4 * seed)))
    }

    /// From `a` to `b`, `t` of the way, falling (or rising) first and going across after, so it
    /// swoops rather than slides.
    private static func swoop(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        mix(a, b, x: t, y: 1 - (1 - t) * (1 - t))
    }

    private static func mix(_ a: CGPoint, _ b: CGPoint, x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * x, y: a.y + (b.y - a.y) * y)
    }

    /// Its drawing (100 × 50), placed so Oyl itself is at `middle(at:)`.
    func frame(at date: Date, height: CGFloat) -> CGRect {
        let scale = height / 50
        let middle = (isWalking(at: date) || isCheering(at: date) || popping != nil || !job.atWork ? 50 : 26) * scale
        return CGRect(x: self.middle(at: date) - middle, y: 0, width: 100 * scale, height: height)
    }

    /// Just Oyl; or a moyl's planet, rings and moon, and the rows above it to the screen's edge.
    func body(at date: Date, height: CGFloat) -> CGRect {
        if floats {
            // (In the sky, just round it.)
            let center = place(at: date, height: height).center, r = Self.moylRadius(height: height)
            let top = sky == nil ? 0 : center.y - 1.6 * r
            return CGRect(x: center.x - 2.1 * r, y: top, width: 4.2 * r, height: center.y + 1.6 * r - top)
        }
        let scale = height / 50
        return CGRect(x: middle(at: date) - 20 * scale, y: 3 * scale, width: 40 * scale, height: 44 * scale)
    }

    /// What can be clicked: Oyl, and a timer's clock and countdown (or a reminder's note) beside
    /// it; a moyl, and its label.
    func hitBox(at date: Date, height: CGFloat, allCountdowns: Bool = true) -> CGRect {
        var box = body(at: date, height: height)
        if floats {
            guard let width = labelWidth(at: date, allCountdowns: allCountdowns) else { return box }
            let middle = place(at: date, height: height).center.y
            return box.union(CGRect(x: labelX(at: date, height: height), y: middle - 8.5, width: width, height: 17))
        }
        guard case .timer(let timer) = job, !isWalking(at: date), !isCheering(at: date) else { return box }
        let scale = height / 50, frame = frame(at: date, height: height)
        if !timer.isEndless { box = box.union(CGRect(x: frame.minX + 57 * scale, y: 15 * scale, width: 26 * scale, height: 26 * scale)) }
        guard let width = labelWidth(at: date, allCountdowns: allCountdowns) else { return box }
        return box.union(CGRect(x: labelX(at: date, height: height), y: (height - 17) / 2, width: width, height: 17))
    }

    /// How wide its label is, padding and all.
    func labelWidth(at date: Date, allCountdowns: Bool = true) -> CGFloat? {
        label(at: date, allCountdowns: allCountdowns).map {
            let font = floats ? Self.moylLabelFont : NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            return ($0.text as NSString).size(withAttributes: [.font: font]).width + (floats ? LabelPictures.midnightPadding : 12)
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

    /// What a moyl's label is set in (see `LabelPictures`), for measuring it.
    private static let moylLabelFont = NSFont(name: "BodoniSvtyTwoITCTT-Bold", size: 10.8)
        ?? NSFont(name: "Didot-Bold", size: 10.8) ?? .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    /// A countdown's last stretch, when it shows even with countdowns hidden.
    static let lastMinutes: TimeInterval = 3 * 60

    /// How far it and its things reach either side of its middle while it's at its job, with
    /// room for a label.
    static func reach(height: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let scale = height / 50
        return (26 * scale, 74 * scale + 40)
    }

    func draw(_ drawing: OylDrawing, at date: Date) {
        var drawing = drawing
        drawing.cap = job.cap ?? Oyl.hatOrange
        if let cheered, isCheering(at: date) {
            drawing.cheer(hat: job.cap != nil, since: date.timeIntervalSince(cheered), length: WalkerOverlay.cheer)
            return
        }
        if isWalking(at: date) {
            drawing.walk(facingRight: to >= from, hat: job.cap != nil, carrying: job.duty)
            return
        }
        // Going: just Oyl, its things put down, waving goodbye and hopping off.
        if let popped = popped(at: date) {
            if popped.wave < 1 {
                drawing.goodbye(hat: job.cap != nil, wave: popped.wave)
            } else {
                drawing.hopOff(hat: job.cap != nil, hop: popped.hop)
            }
            return
        }
        if popping != nil {
            drawing.draw(.idle, hat: job.cap != nil, walking: false, surfing: false)
            return
        }
        switch job {
        case .hangout:
            drawing.hangOut(music: false)
        case .agent(let session):
            drawing.draw(session.activity, hat: session.cap != nil, walking: false, surfing: false)
        default:
            if let duty = job.duty { drawing.perform(duty) }
        }
    }

    /// Its countdown (or what it's for), shown beside it, and in what color.
    /// Without `allCountdowns`, a countdown shows only in its last three minutes (what isn't a
    /// time, a reminder's note or the battery, always does).
    func label(at date: Date, allCountdowns: Bool = true) -> (text: String, color: Color)? {
        guard !leaving else { return nil }
        switch job {
        case .timer(let timer) where timer.isEndless:
            return (timer.label.isEmpty ? "∞" : timer.label, Oyl.noteYellow)
        case .timer(let timer):
            let left = timer.remaining(at: date)
            guard allCountdowns || left < Self.lastMinutes else { return nil }
            // Its color in 2% steps, so it isn't redrawn every frame for a change no one could see.
            return ((timer.isRunning ? "" : "paused ") + ReminderTimer.format(left),
                    timer.tint(fractionLeft: (timer.fractionLeft(at: date) * 50).rounded() / 50))
        case .awake(.until(let end)):
            guard allCountdowns || end.timeIntervalSince(date) < Self.lastMinutes else { return nil }
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

    /// Where its label starts: past its things while it's at its job, else just past it (a
    /// moyl's, just past its rings and moon).
    func labelX(at date: Date, height: CGFloat) -> CGFloat {
        if floats || isWalking(at: date) || isCheering(at: date) { return body(at: date, height: height).maxX + 2 }
        return frame(at: date, height: height).minX + labelOffset(height: height)
    }
}

final class Walkers: ObservableObject {
    @Published var list: [Walker] = []
    /// The menu bar's height and width; Oyls are drawn as tall, and talk below it.
    @Published var barHeight: CGFloat = 34
    @Published var barWidth: CGFloat = 0
    /// What they're saying, by Oyl.
    @Published var sayings: [String: Saying] = [:]
    /// The menu bar's dark behind them.
    @Published var dimmed = false
    /// Countdowns beside them all the time, not just in their last three minutes.
    @Published var allCountdowns = true
    /// How far the calendar bar has slid right, clear of the open notch.
    @Published var calendarNudge: CGFloat = 0

    /// Where the calendar bar is now, nudge and all.
    var calendarFrame: CGRect? { calendar?.offsetBy(dx: calendarNudge, dy: 0) }
    /// Sent off: the calendar fades away as they go.
    @Published var away = false
    /// The calendar bar, in the panel, and the events for it.
    @Published var calendar: CGRect?
    @Published var events: [DayEvent] = []
    @Published var calendarNote: String?
    /// Pictures of their countdowns, as they're drawn.
    let labels = LabelPictures()
    /// Their window's off screen (resting, hidden, or with nothing out), or they've faded away
    /// under Midnight's band: nothing's drawn. It starts down.
    @Published var paused = true
    /// Oyls, or (in Midnight Oyl) moyls.
    @Published var theme = NotchTheme.standard
    /// Midnight's band is over them, since `bandChanged` (or was, till then).
    @Published var underBand = false
    var bandChanged = Date.distantPast
    /// Moyls are on the move (or flaring, or fading), so they're moved more often.
    @Published var lively = false
    /// The moyl under the pointer, up in Midnight's band's sky, which shows its ring of words.
    @Published var hovered: String?
    /// What an Oyl would say it's doing (see `WalkerOverlay.describe`): a moyl's ring says it.
    var describe: (Walker.Job) -> String = { _ in "" }
    /// The line being sung right now, for the music Oyl to sing along.
    var lyricLine: (Date) -> String? = { _ in nil }

    /// How long moyls take to fade away under Midnight's band as it opens.
    static let fadeUnder: TimeInterval = 0.45

    /// What an Oyl's saying now, if anything: what it's been asked, or the line it's singing.
    func saying(for walker: Walker, at date: Date) -> Saying? {
        if let saying = sayings[walker.id], saying.isShowing(at: date) { return saying }
        guard case .music(_, .singing) = walker.job, !walker.leaving else { return nil }
        return Saying(text: "♪ " + (lyricLine(date) ?? "…"), image: nil, from: date, until: date.addingTimeInterval(1))
    }

    func current(at date: Date) -> DayEvent? { events.current(at: date) }
    func next(after date: Date) -> DayEvent? { events.next(after: date) }
}

/// Midnight's band, open, as moyls floating in its sky see it: how big it is and how deep it
/// reaches, where its page and its moon are, and how far down the strip beside the notch goes,
/// in the band's points from its top left; and where its left is along their window.
struct BandSky: Equatable {
    let size: CGSize
    let reach: CGFloat
    let page: CGRect
    let moon: CGPoint
    let moonRadius: CGFloat
    let top: CGFloat
    let left: CGFloat

    /// How far up from the foot they keep: past where the band dissolves into the desktop.
    static let footClear: CGFloat = 64

    /// Whether a moyl `room` across could float at `point` (in their window): clear of the page,
    /// the moon's dial and its words, the planisphere's hub and the screen's edges, below the
    /// strip by the notch and well above the foot.
    func isClear(_ point: CGPoint, room: CGFloat) -> Bool {
        let point = CGPoint(x: point.x - left, y: point.y), half = room / 2
        guard point.x > half + 12, point.x < size.width - half - 12, point.y > top + half + 12,
              point.y < MidnightBackdrop.foot(atX: point.x, in: size, reach: reach) - half - Self.footClear,
              !page.insetBy(dx: -half - 20, dy: -half - 18).contains(point),
              hypot(point.x - moon.x, point.y - moon.y) > moonRadius * 67 / 58 + half + 16 else { return false }
        let hub = MidnightBackdrop.planisphere(in: size, reach: reach)
        return hypot(point.x - hub.x, point.y - hub.y) > 34 + half
    }

    /// The clear spot nearest under `x` (in their window) for a moyl `room` across, about halfway
    /// down the sky there, clear of the room each of `taken` takes; nil if there's none.
    func spot(under x: CGFloat, room: CGFloat, avoiding taken: [(CGPoint, CGFloat)]) -> CGPoint? {
        var best: CGPoint?, cost = CGFloat.infinity
        let high = top + room / 2 + 12
        for across in stride(from: CGFloat(0), through: size.width, by: 12) {
            let low = MidnightBackdrop.foot(atX: across, in: size, reach: reach) - room / 2 - Self.footClear
            let halfway = (high + low) / 2
            for down in stride(from: high, through: low, by: 12) {
                let point = CGPoint(x: left + across, y: down)
                let here = abs(point.x - x) + 0.6 * abs(down - halfway)
                guard here < cost, isClear(point, room: room),
                      taken.allSatisfy({ hypot($0.0.x - point.x, $0.0.y - point.y) >= (room + $0.1) / 2 + 8 }) else { continue }
                best = point
                cost = here
            }
        }
        return best
    }
}

/// Speech bubbles hung under the menu bar, laid out so none overlap: each as near as it can be
/// to where it hangs from its Oyl, slid sideways as far as it must be (its tail still over its
/// Oyl, and all of it on screen), the ones before it slid along too if that helps, or dropped to
/// the second row; or, if there's still no room, narrowed (its words cut short).
enum BubbleLayout {
    struct Bubble {
        let id: String
        /// Where its Oyl is, which its tail points at.
        let anchor: CGFloat
        let width: CGFloat
        /// Taking both rows' room: a picture, or two lines.
        var tall = false
        /// As narrow as it can be made.
        var narrowest: CGFloat = 90
    }

    struct Placed {
        let left: CGFloat
        let row: Int
        let width: CGFloat
    }

    /// How far a tail keeps in from a bubble's ends, and bubbles from each other and the
    /// screen's edges.
    static let tail: CGFloat = 13, gap: CGFloat = 6, margin: CGFloat = 4

    /// Where each of `bubbles` goes, on a screen `width` across, by id.
    static func layOut(_ bubbles: [Bubble], across width: CGFloat) -> [String: Placed] {
        struct Slot {
            let id: String
            var left: CGFloat
            let width: CGFloat
            let lowest: CGFloat
            let fixed: Bool
        }
        var rows: [[Slot]] = [[], []]
        var placed: [String: Placed] = [:]

        /// Where it'd go in `row` (at `forced`, if that's given), sliding those before it along if
        /// need be (and doing so), or nil if it won't go.
        func fit(_ id: String, anchor: CGFloat, width w: CGFloat, preferred: CGFloat, in row: Int, fixed: Bool,
                 at forced: CGFloat? = nil) -> CGFloat? {
            let lowest = max(margin, anchor - w + tail), highest = min(anchor - tail, width - margin - w)
            guard lowest <= highest else { return nil }
            let after = rows[row].last.map { $0.left + $0.width + gap } ?? -.infinity
            var left = forced ?? min(max(lowest, min(preferred, highest), after), highest)
            left = min(max(left, lowest), highest)
            if after > left {
                var slots = rows[row], next = left
                for index in slots.indices.reversed() {
                    let most = next - slots[index].width - gap
                    guard slots[index].left > most else { break }
                    guard !slots[index].fixed, most >= slots[index].lowest else { return nil }
                    slots[index].left = most
                    next = most
                }
                rows[row] = slots
            }
            rows[row].append(Slot(id: id, left: left, width: w, lowest: lowest, fixed: fixed))
            return left
        }

        for bubble in bubbles.sorted(by: { $0.anchor < $1.anchor }) {
            var w = bubble.width
            var done = false
            while !done {
                // Near the right edge, it opens to the left.
                let preferred = bubble.anchor > width - 270 ? bubble.anchor + 14 - w : bubble.anchor - 14
                if bubble.tall {
                    let saved = rows
                    if let left = fit(bubble.id, anchor: bubble.anchor, width: w, preferred: preferred, in: 0, fixed: true),
                       fit(bubble.id, anchor: bubble.anchor, width: w, preferred: left, in: 1, fixed: true, at: left) != nil {
                        done = true
                    } else {
                        rows = saved
                    }
                } else {
                    for row in 0..<rows.count where fit(bubble.id, anchor: bubble.anchor, width: w, preferred: preferred, in: row, fixed: false) != nil {
                        done = true
                        break
                    }
                }
                if !done {
                    guard w > bubble.narrowest else { break }
                    w = max(bubble.narrowest, w - 30)
                }
            }
            if !done {
                // No room anywhere: where it'd be alone, over whatever's there.
                let left = min(max(bubble.anchor - 14, margin), width - margin - w)
                placed[bubble.id] = Placed(left: left, row: 1, width: w)
            }
        }
        for (row, slots) in rows.enumerated() {
            for slot in slots where placed[slot.id] == nil || row == 0 {
                placed[slot.id] = Placed(left: slot.left, row: row, width: slot.width)
            }
        }
        return placed
    }
}

/// The Oyls' countdowns, each made into a picture once, when its text or color changes, and kept
/// while it's still on the bar; drawing a picture each frame costs far less than typesetting.
@MainActor
final class LabelPictures {
    static let scale: CGFloat = 2
    /// A moyl's, in Midnight Oyl: Bodoni's figures in their color paled, on a soft patch of
    /// night with no edge to it, `midnightPadding` wider than they are; past the patch, room for
    /// its softness (`midnightMargin` each side).
    nonisolated static let midnightPadding: CGFloat = 14
    nonisolated static let midnightMargin: CGFloat = 4
    private struct Key: Hashable {
        let text: String
        let color: Color
        let midnight: Bool
    }
    private var pictures: [Key: CGImage] = [:]
    private var used: Set<Key> = []

    nonisolated init() {}

    func image(_ text: String, color: Color, midnight: Bool = false) -> CGImage? {
        let key = Key(text: text, color: color, midnight: midnight)
        used.insert(key)
        if let picture = pictures[key] { return picture }
        // A moyl's is for a layer of its own (see `MoylsView`).
        let picture = midnight
            ? MoylSprite.bitmap(of: Text(text)
                .font(Midnight.numerals(10))
                .foregroundStyle(NotchTheme.midnight.tint(color))
                .padding(.horizontal, Self.midnightPadding / 2)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Midnight.ink.opacity(0.62)).blur(radius: 2.5))
                .padding(Self.midnightMargin))
            : Self.picture(of: Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.55))))
        pictures[key] = picture
        return picture
    }

    private static func picture(of view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }

    /// After a frame: lets go of those it didn't draw.
    func forgetUnused() {
        if pictures.count > used.count { pictures = pictures.filter { used.contains($0.key) } }
        used = []
    }
}

/// The first click on a window that isn't key goes straight to what's under it.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The calendar bar underneath (redrawn now and then; it only creeps along), the Oyls on top,
/// each in a canvas of its own so only the little bits that move get redrawn, and what they're
/// saying below the bar. In Midnight Oyl, only the bar's dimming: `MoylsView`, over this, has
/// the moyls (but this still takes their clicks).
private struct WalkersView: View {
    @ObservedObject var walkers: Walkers
    let onClick: (CGPoint) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            dim
                .opacity(walkers.dimmed ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: walkers.dimmed)
            if let strip = walkers.calendar {
                CalendarBar(events: walkers.events, note: walkers.calendarNote)
                    .frame(width: strip.width, height: strip.height)
                    .offset(x: strip.minX + walkers.calendarNudge, y: strip.minY)
                    .opacity(walkers.away ? 0 : 1)
                    .animation(.easeOut(duration: 0.6), value: walkers.away)
                    .animation(NotchView.open, value: walkers.calendarNudge)
            }
            if walkers.theme != .midnight {
                // 10 a second: smooth enough for a little walk, and easy on the CPU; while one's
                // going (cheering, waving, hopping off), 30.
                let going = walkers.list.contains { $0.popping != nil }
                TimelineView(.animation(minimumInterval: 1.0 / (going ? 30 : 10), paused: walkers.paused)) { context in
                    sprites(height: walkers.barHeight, at: context.date)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { onClick($0.location) })
    }

    /// The menu bar darkened behind them; in Midnight Oyl, fading out below it rather than
    /// stopping at an edge.
    @ViewBuilder private var dim: some View {
        if walkers.theme == .midnight {
            LinearGradient(stops: [.init(color: Midnight.ink.opacity(0.8), location: 0), .init(color: Midnight.ink.opacity(0.8), location: 0.7),
                                   .init(color: Midnight.ink.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: walkers.barHeight + 14)
        } else {
            Color.black.opacity(0.8)
                .frame(height: walkers.barHeight)
        }
    }

    private func sprites(height: CGFloat, at date: Date) -> some View {
        let beat = CGFloat(max(Beat.level - 0.3, 0) / 0.7)
        let time = date.timeIntervalSinceReferenceDate, beats = Beat.position(at: time), bars = Beat.bars
        return ZStack(alignment: .topLeading) {
            // Every Oyl, and its countdown following it about, in one canvas across the bar: laid
            // out once a frame, rather than a view each to move. The countdowns are pictures made
            // once each time one changes (a second at a time), not typeset 10 times a second.
            Canvas { canvas, _ in
                for walker in walkers.list {
                    let visibility = walker.visibility(at: date)
                    guard visibility > 0 else { continue }
                    let frame = walker.frame(at: date, height: height)
                    var place = canvas
                    place.translateBy(x: frame.minX, y: 0)
                    let popped = walker.popped(at: date)
                    let draw = { (context: inout GraphicsContext) in
                        let body = walker.body(at: date, height: height).offsetBy(dx: -frame.minX, dy: 0)
                        Self.hop(&context, poked: walker.poked, body: body, at: date)
                        if let popped { Self.popOut(&context, popped, body: body) }
                        walker.draw(OylDrawing(canvas: context, size: frame.size, time: time, beat: beat, skin: walker.job.skin(at: date),
                                               outline: Oyl.menuBarOutline, pace: Double(walker.pace), beats: beats, bars: bars), at: date)
                    }
                    // Fading at the notch (or gone in its puff), it fades as one (its outline doesn't
                    // show through it).
                    let shown = visibility * (1 - min((popped?.pop ?? 0) * 2.2, 1))
                    if shown < 1 {
                        place.opacity = shown
                        place.drawLayer { layer in draw(&layer) }
                    } else {
                        draw(&place)
                    }
                    if let popped, popped.pop > 0 {
                        var puff = canvas
                        puff.opacity = visibility
                        OylPuff.draw(in: puff, around: walker.body(at: date, height: height), popped.pop, color: walker.job.skin(at: date))
                    }
                    if let label = walker.label(at: date, allCountdowns: walkers.allCountdowns),
                       let image = walkers.labels.image(label.text, color: label.color) {
                        var tag = canvas
                        tag.opacity = visibility
                        tag.draw(Image(decorative: image, scale: LabelPictures.scale),
                                 at: CGPoint(x: walker.labelX(at: date, height: height), y: height / 2), anchor: .leading)
                    }
                }
                walkers.labels.forgetUnused()
            }
            .frame(width: walkers.barWidth, height: height)
            // What they're saying (the music Oyl, singing along, the line being sung), laid out so
            // none overlap; with more than one at once, a line each.
            let speakers = speakers(at: date, height: height)
            let lines = speakers.count > 1 ? 1 : 2
            let placed = BubbleLayout.layOut(speakers.map { $0.bubble(lines: lines) }, across: walkers.barWidth)
            ForEach(speakers, id: \.id) { speaker in
                if let spot = placed[speaker.id] {
                    SpeechBubble(text: speaker.saying.text, image: speaker.saying.image, tail: speaker.anchor - spot.left,
                                 width: spot.width, lines: lines)
                        .offset(x: spot.left, y: height + 1 + CGFloat(spot.row) * 27)
                }
            }
        }
    }

    /// Who's saying something now, and where each is: the calendar's Oyl, and every Oyl.
    private func speakers(at date: Date, height: CGFloat) -> [Speaker] {
        var speakers: [Speaker] = []
        for walker in walkers.list {
            if let saying = walkers.saying(for: walker, at: date) {
                speakers.append(Speaker(id: walker.id, anchor: walker.body(at: date, height: height).midX, saying: saying))
            }
        }
        return speakers
    }

    /// Someone saying something, and where they are along the bar.
    private struct Speaker {
        let id: String
        let anchor: CGFloat
        let saying: Saying

        /// Its bubble, for laying out: a picture, or its words in `lines` lines at most.
        func bubble(lines: Int) -> BubbleLayout.Bubble {
            guard saying.image == nil else {
                return BubbleLayout.Bubble(id: id, anchor: anchor, width: SpeechBubble.pictureWidth, tall: true,
                                           narrowest: SpeechBubble.pictureWidth)
            }
            let width = SpeechBubble.width(of: saying.text)
            return BubbleLayout.Bubble(id: id, anchor: anchor, width: width, tall: lines > 1 && width >= SpeechBubble.widest)
        }
    }


    /// Going: shrinking away into its puff. (Its hops are its own: it's at the top of the screen,
    /// so it springs no higher than the bar; see `OylDrawing.hopOff`.)
    private static func popOut(_ place: inout GraphicsContext, _ popped: (wave: Double, hop: CGFloat, pop: Double), body: CGRect) {
        guard popped.pop > 0 else { return }
        let shrunk = 1 - 0.85 * CGFloat(min(popped.pop * 2.2, 1))
        place.translateBy(x: body.midX, y: body.midY)
        place.scaleBy(x: shrunk, y: shrunk)
        place.translateBy(x: -body.midX, y: -body.midY)
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

/// An Oyl gone in a puff, leaving (see `WalkerOverlay.leave`).
enum OylPuff {
    /// Its puff, `pop` (0…1) through it: a little cloud billowing out where it was (wider than it's
    /// tall, to fit the bar), then thinning away, sparks of its color flying out of it.
    static func draw(in canvas: GraphicsContext, around body: CGRect, _ pop: Double, color: Color) {
        let w = body.width, grown = CGFloat(1 - pow(1 - pop, 3))
        let center = CGPoint(x: body.midX, y: body.midY + body.height * 0.08)
        var puffs = Path()
        for index in 0..<7 {
            let angle = Double(index) / 7 * 2 * .pi + 0.4
            let reach = w * (0.06 + 0.36 * grown)
            let spot = CGPoint(x: center.x + CGFloat(cos(angle)) * reach, y: center.y + CGFloat(sin(angle)) * reach * 0.45 - w * 0.08 * grown)
            let r = w * (0.12 + 0.15 * grown) * (index % 2 == 0 ? 1 : 0.8)
            puffs.addEllipse(in: CGRect(x: spot.x - r, y: spot.y - r, width: 2 * r, height: 2 * r))
        }
        let r = w * (0.14 + 0.12 * grown)
        puffs.addEllipse(in: CGRect(x: center.x - r, y: center.y - r - w * 0.06 * grown, width: 2 * r, height: 2 * r))
        var cloud = canvas
        cloud.opacity = pop < 0.3 ? 1 : 1 - (pop - 0.3) / 0.7
        // Outlined, then filled over: just the cloud's edge is left outlined. Thinning as one, so
        // the outlines inside it don't show through.
        cloud.drawLayer { layer in
            layer.stroke(puffs, with: .color(Oyl.menuBarOutline), lineWidth: w * 0.08)
            layer.fill(puffs, with: .color(Color(white: 0.95)))
        }
        var sparks = canvas
        sparks.opacity = 1 - pop
        for index in 0..<5 {
            let angle = Double(index) / 5 * 2 * .pi + 1.1
            let reach = w * (0.25 + 0.6 * grown)
            let spot = CGPoint(x: center.x + CGFloat(cos(angle)) * reach, y: center.y + CGFloat(sin(angle)) * reach * 0.5)
            let size = w * 0.11 * (1 - 0.4 * CGFloat(pop))
            var star = Path()
            for point in 0..<8 {
                let a = Double(point) * .pi / 4, out = point % 2 == 0 ? size : size * 0.32
                let p = CGPoint(x: spot.x + CGFloat(cos(a)) * out, y: spot.y + CGFloat(sin(a)) * out)
                if point == 0 { star.move(to: p) } else { star.addLine(to: p) }
            }
            star.closeSubpath()
            sparks.stroke(star, with: .color(Oyl.menuBarOutline), style: StrokeStyle(lineWidth: w * 0.04, lineJoin: .round))
            sparks.fill(star, with: .color(color))
        }
    }
}

/// What an Oyl says: a line or two of text (or a picture), its tail pointing up at `tail` (from
/// its left), `width` across at most (its words cut short to fit).
private struct SpeechBubble: View {
    let text: String
    let image: NSImage?
    let tail: CGFloat
    var width = SpeechBubble.widest
    var lines = 2

    private static let fill = Color.black.opacity(0.8)
    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// The widest a bubble of words gets (wrapping past that), and how wide one with a picture is.
    static let widest: CGFloat = 240 + 18
    static let pictureWidth: CGFloat = 72 + 8

    /// About how wide a bubble saying `text` comes out.
    static func width(of text: String) -> CGFloat {
        min((text as NSString).size(withAttributes: [.font: font]).width, widest - 18) + 18
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Tail().fill(Self.fill)
                .frame(width: 10, height: 5)
                .padding(.leading, min(max(tail - 5, 4), max(width - 14, 4)))
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(4)
                } else {
                    Capped(width: width - 18) {
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(lines)
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
    fileprivate struct Capped: SwiftUI.Layout {
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

/// The moyls, in Midnight Oyl: only ever seen up in the band's sky, never on the menu bar. Each
/// a `MoylSprite`, its label beside it and what it's saying hung under it, and while they
/// announce, or one's hovered, its ring of words round it. All Core Animation layers, moved ten
/// times a second (twenty while any is on its way, flaring or fading) rather than drawn anew each
/// time, which SwiftUI's timeline costs several times as much CPU for. Nothing's moved while no
/// moyl's in the sky. It takes no clicks: the Oyls' view underneath works out who was clicked.
@MainActor
final class MoylsView: NSView {
    private let walkers: Walkers
    /// The bar, counting up from the bottom: the moyls, their rings, their labels, then what
    /// they say.
    private let sky = CALayer(), moyls = CALayer(), wreaths = CALayer(), tags = CALayer(), talk = CALayer()
    private var sprites: [String: MoylSprite] = [:]
    private var rings: [String: CALayer] = [:]
    private var labels: [String: CALayer] = [:]
    private var sayings: [String: (patch: CALayer, line: CAGradientLayer)] = [:]
    /// How far each one's hovered ring has come in (or gone).
    private var hovers: [String: CGFloat] = [:]
    private let pictures = SayingPictures(), ringPictures = RingPictures()
    private var link: CADisplayLink?
    private var watching: AnyCancellable?
    private var frames = 0
    private var shown: Date?

    /// Frames a second: at rest, as often as Oyls walk (they only circle and bob, slowly); while
    /// any is on its way somewhere (or flaring or fading), twice that, those at rest still moved
    /// every other frame.
    static let rates: (resting: Float, lively: Float) = (10, 20)

    init(walkers: Walkers) {
        self.walkers = walkers
        super.init(frame: .zero)
        layer = sky
        wantsLayer = true
        for part in [moyls, wreaths, tags, talk] { sky.addSublayer(part) }
        watching = walkers.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    /// The window's grown down into the band's sky, or back: everything where it was on screen.
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        if walkers.theme == .midnight, !sprites.isEmpty { update(at: Date()) }
    }

    /// Frames start or stop, at the pace for what's going on, and one's shown now. Only while
    /// there's a moyl in the band's sky: on the bar, none are seen.
    private func refresh() {
        let midnight = walkers.theme == .midnight
        let running = midnight && window != nil && !walkers.paused && walkers.list.contains { $0.sky != nil }
        if running, link == nil {
            let link = displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        if let link {
            let rate = walkers.lively ? Self.rates.lively : Self.rates.resting
            if link.preferredFrameRateRange.preferred != rate {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: rate, preferred: rate)
            }
            link.isPaused = !running
        }
        sky.isHidden = !midnight
        if midnight { update(at: Date()) } else { clear() }
    }

    @objc private func step(_ link: CADisplayLink) {
        update(at: Date())
    }

    /// Every moyl where it is at `date`, with its ring, its label and what it's saying.
    func update(at date: Date) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let height = walkers.barHeight, top = bounds.height
        let time = date.timeIntervalSinceReferenceDate
        let beat = CGFloat(max(Beat.level - 0.3, 0) / 0.7), beats = Beat.position(at: time)
        let radius = Walker.moylRadius(height: height)
        let elapsed = CGFloat(min(max(shown.map { date.timeIntervalSince($0) } ?? 0, 0), 0.25))
        shown = date
        frames += 1
        let between = walkers.lively && frames % 2 == 0
        var out = Set<String>()
        var speakers: [(walker: Walker, saying: Saying, foot: CGPoint, visibility: Float)] = []
        for walker in walkers.list {
            out.insert(walker.id)
            let hovered = walkers.hovered == walker.id && walker.sky != nil
            let hover = Self.approach(hovers[walker.id] ?? 0, hovered ? 1 : 0, by: elapsed / 0.25)
            hovers[walker.id] = hover
            let ring = max(walker.ring?.shown(at: date) ?? 0, hover)
            let still = !walker.isWalking(at: date) && walker.flare(at: date) == 0 && (hover == 0 || hover == 1)
                && walker.poked.map({ date.timeIntervalSince($0) > 1.2 }) ?? true && walker.ring == nil && walker.sky?.down == nil
                && walker.sky.map { date.timeIntervalSince($0.moved) > Walker.flight } ?? true
            if between, sprites[walker.id] != nil, still { continue }
            let sprite = sprites[walker.id] ?? {
                let sprite = MoylSprite(seed: walker.seed)
                moyls.addSublayer(sprite.layer)
                sprites[walker.id] = sprite
                return sprite
            }()
            // Seen only as it comes down into the band's sky, and while it's up there.
            let shown = Double(walker.inSky(at: date))
            sprite.show(walker, at: date, height: height, top: top, beat: beat, beats: beats, shown: shown)
            let visibility = Float(walker.visibility(at: date) * shown), center = walker.place(at: date, height: height).center

            // Its ring of words, turning slowly, while it announces or it's hovered.
            let words = ring > 0.01 ? walkers.describe(walker.job.named) : ""
            if ring > 0.01,
               let image = ringPictures.image(words, radius: walker.ring?.radius ?? MoylSprite.ringRadius(for: words, height: height)) {
                let wreath = rings[walker.id] ?? add(to: wreaths, as: walker.id, in: &rings)
                if (wreath.contents as AnyObject?) !== image { wreath.contents = image }
                let size = CGSize(width: CGFloat(image.width) / LabelPictures.scale, height: CGFloat(image.height) / LabelPictures.scale)
                if wreath.bounds.size != size { wreath.bounds = CGRect(origin: .zero, size: size) }
                wreath.position = CGPoint(x: center.x, y: top - center.y)
                let grown = 0.86 + 0.14 * ring
                wreath.transform = CATransform3DScale(CATransform3DMakeRotation(-CGFloat(time / 60 * 2 * .pi), 0, 0, 1), grown, grown, 1)
                wreath.opacity = Float(ring) * visibility
                if wreath.isHidden { wreath.isHidden = false }
            } else if let wreath = rings[walker.id], !wreath.isHidden {
                wreath.isHidden = true
            }

            // Its countdown (or what it's for), just past its rings and moon (not while its ring of
            // words says it).
            if ring < 0.05, let label = walker.label(at: date, allCountdowns: walkers.allCountdowns),
               let image = walkers.labels.image(label.text, color: label.color, midnight: true) {
                let tag = labels[walker.id] ?? add(to: tags, as: walker.id, in: &labels)
                if (tag.contents as AnyObject?) !== image { tag.contents = image }
                let size = CGSize(width: CGFloat(image.width) / LabelPictures.scale, height: CGFloat(image.height) / LabelPictures.scale)
                if tag.bounds.size != size { tag.bounds = CGRect(origin: .zero, size: size) }
                tag.position = CGPoint(x: walker.labelX(at: date, height: height) - LabelPictures.midnightMargin + size.width / 2,
                                       y: top - center.y)
                if tag.opacity != visibility { tag.opacity = visibility }
                if tag.isHidden { tag.isHidden = false }
            } else if let tag = labels[walker.id], !tag.isHidden {
                tag.isHidden = true
            }

            // What it's saying (not while its ring's round it): up in the sky, hung just under it;
            // on the bar, laid out below once all are known.
            guard !between else { continue }
            if ring < 0.05, let saying = walkers.saying(for: walker, at: date) {
                speakers.append((walker, saying, CGPoint(x: center.x, y: center.y + radius * 1.15), visibility))
            } else if let parts = sayings[walker.id], !parts.patch.isHidden {
                parts.patch.isHidden = true
                parts.line.isHidden = true
            }
        }
        if !between { hang(speakers, height: height, top: top) }
        // Those gone from the bar.
        for (id, sprite) in sprites where !out.contains(id) {
            sprite.layer.removeFromSuperlayer()
            sprites[id] = nil
        }
        for layers in [\MoylsView.rings, \MoylsView.labels] {
            for (id, layer) in self[keyPath: layers] where !out.contains(id) {
                layer.removeFromSuperlayer()
                self[keyPath: layers][id] = nil
            }
        }
        for (id, parts) in sayings where !out.contains(id) {
            parts.patch.removeFromSuperlayer()
            parts.line.removeFromSuperlayer()
            sayings[id] = nil
        }
        hovers = hovers.filter { out.contains($0.key) }
        // (Not after a frame that skipped some: theirs would go too.)
        if !between {
            walkers.labels.forgetUnused()
            pictures.forgetUnused()
            ringPictures.forgetUnused()
        }
    }

    /// What they're saying, each hung from its moyl (whose foot's at `foot`) on a hairline: up in
    /// the band's sky, right under it; on the bar, below it, laid out so none overlap (see
    /// `BubbleLayout`), a line each when there's more than one.
    private func hang(_ speakers: [(walker: Walker, saying: Saying, foot: CGPoint, visibility: Float)], height: CGFloat, top: CGFloat) {
        let onBar = speakers.filter { $0.walker.sky == nil }
        let lines = onBar.count > 1 ? 1 : 2
        let placed = BubbleLayout.layOut(onBar.map { speaker in
            guard speaker.saying.image == nil else {
                return BubbleLayout.Bubble(id: speaker.walker.id, anchor: speaker.foot.x, width: MoylSaying.pictureWidth, tall: true,
                                           narrowest: MoylSaying.pictureWidth)
            }
            let width = MoylSaying.width(of: speaker.saying.text)
            return BubbleLayout.Bubble(id: speaker.walker.id, anchor: speaker.foot.x, width: width, tall: lines > 1 && width >= MoylSaying.widest)
        }, across: walkers.barWidth)
        let margin = MoylSaying.margin
        for speaker in speakers {
            let aloft = speaker.walker.sky != nil
            let spot = placed[speaker.walker.id]
            let width = spot?.width ?? MoylSaying.width(of: speaker.saying.text)
            guard let image = pictures.image(of: speaker.saying, lines: aloft ? 2 : lines, width: width) else { continue }
            let parts = sayings[speaker.walker.id] ?? {
                let parts = (patch: CALayer(), line: CAGradientLayer())
                parts.patch.contentsScale = LabelPictures.scale
                parts.line.colors = [Midnight.silver.opacity(0.5), Midnight.silver.opacity(0.05)].map { NSColor($0).cgColor }
                talk.addSublayer(parts.line)
                talk.addSublayer(parts.patch)
                sayings[speaker.walker.id] = parts
                return parts
            }()
            if (parts.patch.contents as AnyObject?) !== image { parts.patch.contents = image }
            let size = CGSize(width: CGFloat(image.width) / LabelPictures.scale, height: CGFloat(image.height) / LabelPictures.scale)
            let foot = speaker.foot
            let edge = aloft ? foot.y + 8 : height + 2 + CGFloat(spot?.row ?? 0) * 27
            let lead = aloft || spot?.row == 0 ? max(edge - foot.y - 1.5, 4) : 6
            let left = aloft ? min(max(foot.x - 14, 4), walkers.barWidth - 4 - (size.width - 2 * margin)) : spot?.left ?? foot.x - 14
            parts.patch.frame = flip(CGRect(x: left - margin, y: edge - margin, width: size.width, height: size.height), top: top)
            parts.line.frame = flip(CGRect(x: foot.x - 0.375, y: edge - lead, width: 0.75, height: lead), top: top)
            for part in [parts.patch, parts.line] {
                if part.opacity != speaker.visibility { part.opacity = speaker.visibility }
                if part.isHidden { part.isHidden = false }
            }
        }
    }

    /// `value` moved toward `target` by at most `step`.
    private static func approach(_ value: CGFloat, _ target: CGFloat, by step: CGFloat) -> CGFloat {
        value < target ? min(value + step, target) : max(value - step, target)
    }

    /// Gone back to Gargoyle: all of them let go.
    private func clear() {
        guard !sprites.isEmpty || !labels.isEmpty || !sayings.isEmpty || !rings.isEmpty else { return }
        for part in [moyls, wreaths, tags, talk] { part.sublayers = nil }
        sprites = [:]
        rings = [:]
        labels = [:]
        sayings = [:]
        hovers = [:]
    }

    private func add(to parent: CALayer, as id: String, in layers: inout [String: CALayer]) -> CALayer {
        let layer = CALayer()
        layer.contentsScale = LabelPictures.scale
        parent.addSublayer(layer)
        layers[id] = layer
        return layer
    }

    /// From the bar's top-left coordinates to its layer's, which count up from the bottom.
    private func flip(_ rect: CGRect, top: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension Walker.Job {
    /// As its ring of words names it: the song's, by the song rather than the line being sung.
    var named: Walker.Job {
        if case .music(let cover, .singing) = self { return .music(cover: cover, listening: .dj) }
        return self
    }
}

/// What moyls say, each made into a picture once and kept while it's still being said; the line
/// being sung, a picture for each line.
@MainActor
final class SayingPictures {
    private struct Key: Hashable {
        let text: String
        let image: ObjectIdentifier?
        let lines: Int
        let width: CGFloat
    }
    private var pictures: [Key: CGImage] = [:]
    private var used: Set<Key> = []

    /// `saying` in `lines` lines at most, its patch `width` across at most.
    func image(of saying: Saying, lines: Int, width: CGFloat) -> CGImage? {
        let key = Key(text: saying.text, image: saying.image.map(ObjectIdentifier.init), lines: lines, width: width.rounded())
        used.insert(key)
        if let picture = pictures[key] { return picture }
        let picture = MoylSprite.bitmap(of: MoylSaying(text: saying.text, image: saying.image, lines: lines, width: width))
        pictures[key] = picture
        return picture
    }

    /// After a frame: lets go of those it didn't show.
    func forgetUnused() {
        if pictures.count > used.count { pictures = pictures.filter { used.contains($0.key) } }
        used = []
    }
}

/// Moyls' rings of words, each made into a picture once, and kept while it's showing.
@MainActor
final class RingPictures {
    private struct Key: Hashable {
        let text: String
        let radius: CGFloat
    }
    private var pictures: [Key: CGImage] = [:]
    private var used: Set<Key> = []

    func image(_ text: String, radius: CGFloat) -> CGImage? {
        let key = Key(text: text, radius: radius)
        used.insert(key)
        if let picture = pictures[key] { return picture }
        let picture = MoylSprite.ring(text, radius: radius)
        pictures[key] = picture
        return picture
    }

    /// After a frame: lets go of those it didn't show.
    func forgetUnused() {
        if pictures.count > used.count { pictures = pictures.filter { used.contains($0.key) } }
        used = []
    }
}

/// What a moyl says, Midnight's way: a line or two of Georgia on a soft patch of night that fades
/// out all round (nothing in Midnight Oyl has an edge); a line it's singing, in italic. A picture
/// dissolves into the dark at its edges the same way. (`MoylsView` hangs it from the moyl on a
/// hairline.)
private struct MoylSaying: View {
    let text: String
    let image: NSImage?
    var lines = 2
    /// How wide its patch is at most (its words cut short to fit).
    var width = MoylSaying.widest

    /// Room round the patch for its softness, in a picture of it.
    static let margin: CGFloat = 9
    private static let font = NSFont(name: "Georgia", size: 11 * 1.06) ?? .systemFont(ofSize: 11)
    /// The widest a patch of words gets (wrapping past that), and how wide one with a picture is.
    static let widest: CGFloat = 240 + 24
    static let pictureWidth: CGFloat = 72 + 12

    /// About how wide a saying of `text` comes out, its patch and all.
    static func width(of text: String) -> CGFloat {
        min((text as NSString).size(withAttributes: [.font: font]).width, widest - 24) + 24
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 72, height: 48)
                    .mask(RoundedRectangle(cornerRadius: 8, style: .continuous).padding(2.5).blur(radius: 2.5))
                    .padding(6)
            } else {
                SpeechBubble.Capped(width: width - 24) {
                    Text(text)
                        .font(text.hasPrefix("♪") ? Midnight.italic(11) : Midnight.serif(11))
                        .foregroundStyle(Midnight.white.opacity(0.92))
                        .lineLimit(lines)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Midnight.ink.opacity(0.8)).padding(2).blur(radius: 5))
        .padding(Self.margin)
        .fixedSize()
    }
}

/// Today along a line: what's gone by on the left fifth, dimmed, what's coming up to the right,
/// each event in its calendar's color with its name and time; all-day and multi-day events as a
/// ribbon along its edge, named on outlined tags in the gaps between the rest.
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
        canvas.fill(shape, with: .color(.black.opacity(0.35)))
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

        // Names start just past the line at now.
        let oylReach: CGFloat = 5

        // All-day and multi-day events, unlike the rest: a ribbon in their color along the top
        // edge for as long as they last (one on at the same time as another goes along the
        // bottom), and their names on tags further down.
        let allDay = events.filter(\.isBackground).sorted { $0.start < $1.start }
        var laneEnds: [Date] = []
        for event in allDay {
            let lane = laneEnds.firstIndex { $0 <= event.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(event.end) } else { laneEnds[lane] = event.end }
            let left = max(x(event.start), bounds.minX), right = min(x(event.end), bounds.maxX)
            guard right > left else { continue }
            let ribbon = CGRect(x: left, y: lane % 2 == 0 ? bounds.minY : bounds.maxY - 2.5, width: right - left, height: 2.5)
            inside.fill(Path(ribbon), with: .color(event.color))
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

        // Each all-day event's name on a tag outlined in its color, in the first gap between
        // events past the Oyl while it's on: two to a gap, one above the other, or one on its own
        // in the middle (and none, where there's no room).
        let blocks = events.filter { !$0.isBackground }.map { x($0.start)...x($0.end) }
        var tags: [(event: DayEvent, name: GraphicsContext.ResolvedText, span: ClosedRange<CGFloat>, row: Int)] = []
        for event in allDay {
            let title = event.title.count > 22 ? String(event.title.prefix(21)) + "…" : event.title
            let name = inside.resolve(Text(title).font(.system(size: 7.5, weight: .semibold)).foregroundColor(.white.opacity(0.9)))
            let width = name.measure(in: size).width + 10
            let spots = (0...1).map { row in
                var spot = max(x(event.start), now + oylReach)
                let taken = blocks + tags.filter { $0.row == row }.map(\.span)
                for range in taken.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.overlaps(spot...(spot + width)) {
                    spot = range.upperBound + 4
                }
                return spot
            }
            let row = spots[1] < spots[0] ? 1 : 0
            guard spots[row] + width <= min(x(event.end), bounds.maxX - bounds.height / 2) else { continue }
            tags.append((event, name, spots[row]...(spots[row] + width), row))
        }
        for tag in tags {
            let paired = tags.contains { $0.row != tag.row && $0.span.overlaps(tag.span) }
            let middle = bounds.midY + (paired ? (tag.row == 0 ? -6.5 : 6.5) : 0)
            let box = CGRect(x: tag.span.lowerBound, y: middle - 6, width: tag.span.upperBound - tag.span.lowerBound, height: 12)
            let outline = Path(roundedRect: box, cornerRadius: 6)
            inside.fill(outline, with: .color(tag.event.color.opacity(0.3)))
            inside.stroke(outline, with: .color(tag.event.color), lineWidth: 1)
            inside.draw(tag.name, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
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
