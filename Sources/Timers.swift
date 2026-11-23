import AppKit

struct ReminderTimer: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    var duration: TimeInterval
    var endDate: Date?                    // set while running
    var pausedRemaining: TimeInterval?    // set while paused

    var isRunning: Bool { endDate != nil }
    var title: String { label.isEmpty ? "Timer" : label }

    func remaining(at date: Date) -> TimeInterval {
        if let endDate { return max(endDate.timeIntervalSince(date), 0) }
        return pausedRemaining ?? duration
    }

    /// Fraction still left, 1 → 0, for the countdown ring.
    func fractionLeft(at date: Date) -> Double {
        duration > 0 ? remaining(at: date) / duration : 0
    }

    static func format(_ seconds: TimeInterval) -> String {
        // Round up like iOS: a timer shows 0:01 until it actually finishes.
        let total = Int((seconds - 0.001).rounded(.up))
        let clamped = max(total, 0)
        if (clamped + 59) / 60 >= 24 * 60 {
            // A day or more (once rounded up), days and hours (rounded up too): "6d 23h".
            let hours = (clamped + 3599) / 3600
            return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
        }
        if clamped >= 3600 {
            // Past an hour, just hours and minutes (rounded up too).
            let minutes = (clamped + 59) / 60
            return String(format: "%d:%02d", minutes / 60, minutes % 60)
        }
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }
}

/// A timer that's gone off. Its Oyl rests on the Oyls page for a day.
struct ExpiredTimer: Identifiable, Codable, Equatable {
    let id: UUID
    let label: String
    let duration: TimeInterval
    let ended: Date

    var title: String { label.isEmpty ? "Timer" : label }
}

/// Reminder timers. They survive relaunches, and one that ended while Oyl wasn't running rings
/// as soon as it starts again. They go off by the clock on the wall (see `WallClockAlarm`), so
/// one that spans a night still rings on time.
@MainActor
final class TimerStore: ObservableObject {
    @Published private(set) var timers: [ReminderTimer] = []
    /// The finished timer currently being announced in the notch.
    @Published private(set) var ringing: ReminderTimer?
    /// Timers that have gone off, latest first: the last ten, from the past day.
    @Published private(set) var history: [ExpiredTimer] = []

    /// The one timer held on the closed notch, if one's been picked (remembered across launches;
    /// let go of when it's gone).
    @Published private(set) var focused: UUID?

    /// One of toyl's countdowns, as toyl's file has it (see `TodStore.toylTimers`).
    struct Mirrored: Equatable {
        let id: UUID
        let label: String
        let duration: TimeInterval
        let endDate: Date?
        let pausedRemaining: TimeInterval?
        /// toyl asks for it to be held on the notch.
        let pin: Bool
        /// Already marked as showing here.
        let shown: Bool
    }

    /// What's been done here to one of toyl's timers, for toyl's file.
    enum MirroredChange {
        case shown(UUID)
        case changed(ReminderTimer)
        /// Stopped or gone off, after running this long.
        case stopped(UUID, worked: TimeInterval)
    }

    /// Told what's done here to one of toyl's timers.
    var onMirroredChange: ((MirroredChange) -> Void)?
    /// Starts a new timer somewhere else (toyl, while it's here: one timer system), its id if it
    /// did; nil, and it's started here.
    var startsElsewhere: ((_ duration: TimeInterval, _ label: String, _ pin: Bool) -> UUID?)?
    /// How long a timer runs when it's not said (toyl's half hour, while it's toyl's); nil, and a
    /// time has to be said.
    var usualLength: () -> TimeInterval? = { nil }
    /// Which of `timers` are toyl's (kept in toyl's file, not here), and which of those have gone
    /// off here and wait for toyl's file to let go of them.
    private var mirrored: Set<UUID> = []
    private var rangMirrored: Set<UUID> = []

    private let defaults: UserDefaults
    private let chime: () -> Void
    private let tap: () -> Void
    private var waiting: [ReminderTimer] = []  // finished timers queued behind `ringing`
    private lazy var alarm = WallClockAlarm { [weak self] in self?.reschedule() }
    private var chiming: Timer?
    private var chimePlays = 0
    private static let storageKey = "timers"
    private static let historyKey = "timers.history"

    /// `chime`: the sound a ringing timer makes, every couple of seconds; `tap`, the trackpad's
    /// with the first. (Other ones, and other defaults, for testing quietly.)
    init(defaults: UserDefaults = .standard,
         chime: @escaping () -> Void = { NSSound(named: NSSound.Name("Glass"))?.play() },
         tap: @escaping () -> Void = { Haptics.perform(.levelChange, performanceTime: .now) }) {
        self.defaults = defaults
        self.chime = chime
        self.tap = tap
        focused = defaults.string(forKey: "timers.focused").flatMap(UUID.init)
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([ReminderTimer].self, from: data) {
            // Reminders with no time on them are no more: any kept from before go.
            timers = saved.filter { $0.duration > 0 }
            if timers.count < saved.count { defaults.set(try? JSONEncoder().encode(timers), forKey: Self.storageKey) }
        }
        if let data = defaults.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([ExpiredTimer].self, from: data) {
            history = Self.recent(saved)
        }
        reschedule()
    }

    /// The timer held on the notch, if it's still here.
    var focusedTimer: ReminderTimer? { focused.flatMap { id in timers.first { $0.id == id } } }

    /// Holds `id` on the notch, in place of any other; or, if it's held already, lets it go.
    func focus(_ id: UUID) {
        hold(focused == id ? nil : id)
    }

    /// Holds `id` on the notch (letting go of any other), or with nil, none.
    private func hold(_ id: UUID?) {
        focused = id
        defaults.set(focused?.uuidString, forKey: "timers.focused")
    }

    /// The timer the open notch's strip shows: the one held on the notch, else the next one to
    /// finish, else a paused one.
    var next: ReminderTimer? {
        if let focusedTimer { return focusedTimer }
        return timers.filter(\.isRunning).min { $0.endDate! < $1.endDate! } ?? timers.first
    }

    /// The least time left first (a paused timer by what it has left); oldest first where they're
    /// level.
    func soonestFirst(at date: Date) -> [ReminderTimer] {
        timers.enumerated().sorted { a, b in
            let left = (a.element.remaining(at: date), b.element.remaining(at: date))
            return left.0 != left.1 ? left.0 < left.1 : a.offset < b.offset
        }
        .map(\.element)
    }

    /// Started, and with `pin`, held on the notch (in place of any other). With toyl, in toyl (see
    /// `startsElsewhere`): it shows here once toyl's file has it, which is at once.
    func start(duration: TimeInterval, label: String, pin: Bool = false) {
        guard duration > 0 else { return }
        if let startsElsewhere, startsElsewhere(min(duration, ReminderParser.longest), label, pin) != nil { return }
        let timer = ReminderTimer(id: UUID(), label: label, duration: duration,
                                  endDate: Date().addingTimeInterval(duration), pausedRemaining: nil)
        timers.append(timer)
        if pin { hold(timer.id) }
        changed()
    }

    func togglePause(_ id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        if timers[index].isRunning {
            timers[index].pausedRemaining = timers[index].remaining(at: now)
            timers[index].endDate = nil
        } else {
            timers[index].endDate = now.addingTimeInterval(timers[index].remaining(at: now))
            timers[index].pausedRemaining = nil
        }
        tellToyl(timers[index])
        changed()
    }

    /// toyl's countdowns, shown and rung here as Oyl's own are: each one toyl has is added or
    /// brought up to date, and one toyl no longer has goes. (One held by toyl is held on the
    /// notch the first time it's seen.) What's done to them here goes back to toyl's file.
    func mirror(_ incoming: [Mirrored]) {
        let ids = Set(incoming.map(\.id))
        var changedAny = false
        let gone = timers.filter { mirrored.contains($0.id) && !ids.contains($0.id) }
        if !gone.isEmpty {
            timers.removeAll { gone.contains($0) }
            changedAny = true
        }
        mirrored.formIntersection(ids)
        rangMirrored.formIntersection(ids)
        var unmarked: [UUID] = []
        for item in incoming where !rangMirrored.contains(item.id) {
            let timer = ReminderTimer(id: item.id, label: item.label, duration: item.duration, endDate: item.endDate,
                                      pausedRemaining: item.endDate == nil ? (item.pausedRemaining ?? item.duration) : nil)
            if let index = timers.firstIndex(where: { $0.id == item.id }) {
                if timers[index] != timer {
                    timers[index] = timer
                    changedAny = true
                }
            } else {
                timers.append(timer)
                mirrored.insert(item.id)
                changedAny = true
                if item.pin { hold(item.id) }
            }
            if !item.shown { unmarked.append(item.id) }
        }
        if changedAny { changed() }
        // After this pass, not in the middle of it (saving it changes what comes in).
        if !unmarked.isEmpty {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { for id in unmarked { self?.onMirroredChange?(.shown(id)) } }
            }
        }
    }

    /// toyl's file told of a change made here to one of its timers.
    private func tellToyl(_ timer: ReminderTimer) {
        guard mirrored.contains(timer.id) else { return }
        onMirroredChange?(.changed(timer))
    }

    /// Changes a timer to what's been typed for it: its label, and its time unless that's still
    /// the `shown` one it was put up for editing with (then it keeps the time it really has left).
    /// A paused timer stays paused. "/pin" holds it on the notch.
    func edit(_ id: UUID, to text: String, shown: TimeInterval?) {
        guard let index = timers.firstIndex(where: { $0.id == id }),
              !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let parsed = ReminderParser.parse(text)
        var timer = timers[index]
        timer.label = parsed.label
        if let duration = parsed.duration, duration != shown {
            let paused = !timer.isRunning
            timer.duration = duration
            timer.endDate = paused ? nil : Date().addingTimeInterval(duration)
            timer.pausedRemaining = paused ? duration : nil
        }
        timers[index] = timer
        if parsed.pin { hold(id) }
        tellToyl(timer)
        changed()
    }

    /// More time on a timer: on the clock if it's running, on what's left if it's paused. What it
    /// was set for grows by as much, so its ring fills back up to match. Never past the longest a
    /// timer can run.
    func extend(_ id: UUID, by seconds: TimeInterval) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        let left = timers[index].remaining(at: Date())
        let added = min(seconds, ReminderParser.longest - left)
        guard added > 0 else { return }
        timers[index].duration += added
        if let end = timers[index].endDate {
            timers[index].endDate = end.addingTimeInterval(added)
        } else {
            timers[index].pausedRemaining = left + added
        }
        tellToyl(timers[index])
        changed()
    }

    func cancel(_ id: UUID) {
        if mirrored.contains(id), let timer = timers.first(where: { $0.id == id }) {
            mirrored.remove(id)
            onMirroredChange?(.stopped(id, worked: max(timer.duration - timer.remaining(at: Date()), 0)))
        }
        timers.removeAll { $0.id == id }
        changed()
    }

    func dismissRinging() {
        stopChime()
        ringing = waiting.isEmpty ? nil : waiting.removeFirst()
        if ringing != nil { startChime() }
    }

    func snoozeRinging(minutes: Double = 1) {
        if let ringing { start(duration: minutes * 60, label: ringing.label) }
        dismissRinging()
    }

    private func changed() {
        // toyl's are kept in toyl's file, and come back from there.
        let data = try? JSONEncoder().encode(timers.filter { !mirrored.contains($0.id) })
        defaults.set(data, forKey: Self.storageKey)
        if let focused, !timers.contains(where: { $0.id == focused }) {
            self.focused = nil
            defaults.removeObject(forKey: "timers.focused")
        }
        reschedule()
    }

    /// Rings any that have finished, and sets the alarm for the next to finish.
    private func reschedule() {
        let now = Date()
        let finished = timers.filter { ($0.endDate ?? .distantFuture) <= now }
        if !finished.isEmpty {
            for timer in finished where mirrored.contains(timer.id) {
                rangMirrored.insert(timer.id)
                onMirroredChange?(.stopped(timer.id, worked: timer.duration))
            }
            timers.removeAll { finished.contains($0) }
            remember(finished, at: now)
            changed()
            ring(finished)
            return
        }
        alarm.set(timers.compactMap(\.endDate).min())
    }

    /// Into the history, when each went off (a while ago, for one that ended while Oyl wasn't
    /// running).
    private func remember(_ finished: [ReminderTimer], at now: Date) {
        let expired = finished.map { ExpiredTimer(id: $0.id, label: $0.label, duration: $0.duration, ended: $0.endDate ?? now) }
        history = Self.recent(expired.sorted { $0.ended > $1.ended } + history)
        defaults.set(try? JSONEncoder().encode(history), forKey: Self.historyKey)
    }

    private static func recent(_ history: [ExpiredTimer]) -> [ExpiredTimer] {
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        return Array(history.filter { $0.ended > dayAgo }.prefix(10))
    }

    private func ring(_ finished: [ReminderTimer]) {
        waiting += finished
        guard ringing == nil else { return }
        ringing = waiting.removeFirst()
        startChime()
    }

    private func startChime() {
        stopChime()
        chimePlays = 0
        playChime()
        tap()
        chiming = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playChime() }
        }
    }

    private func playChime() {
        chimePlays += 1
        chime()
        // Repeat a few times like an iOS timer, then go quiet; the notch keeps showing it.
        if chimePlays >= 6 { stopChime() }
    }

    private func stopChime() {
        chiming?.invalidate()
        chiming = nil
    }
}

/// Goes off at a time on the clock on the wall.
///
/// A `Timer` (like `DispatchTime`) counts only the time the Mac's been awake, so one set for 14
/// hours goes off late by however long the Mac slept in between. That includes the seconds at a
/// time it naps overnight, hundreds of times a night with the lid shut or the screen off, which
/// add up to minutes. This alarm is set by the wall clock instead (a strict dispatch timer on wall
/// time), and checked again the moment the Mac wakes or its clock is changed, and every half
/// minute besides. So it goes off on time while the Mac's awake, and as soon as it wakes if it was
/// asleep then.
@MainActor
final class WallClockAlarm {
    /// When it's set to go off, if it is.
    private(set) var date: Date?
    private let action: @MainActor () -> Void
    nonisolated(unsafe) private var source: DispatchSourceTimer?
    nonisolated(unsafe) private var backstop: Timer?
    nonisolated(unsafe) private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
        let workspace = NSWorkspace.shared.notificationCenter
        let woken = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification]
        let watched = woken.map { (workspace, $0) } + [(NotificationCenter.default, .NSSystemClockDidChange)]
        observers = watched.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(rearming: true) }
            })
        }
    }

    deinit {
        source?.cancel()
        backstop?.invalidate()
        observers.forEach { $0.0.removeObserver($0.1) }
    }

    /// Sets it to go off at `date` (at once, if that's gone by), in place of whenever it was set
    /// for; or, with nil, not at all.
    func set(_ date: Date?) {
        self.date = date
        arm()
    }

    private func arm() {
        source?.cancel()
        source = nil
        guard let date else {
            backstop?.invalidate()
            backstop = nil
            return
        }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(wallDeadline: .now() + max(date.timeIntervalSinceNow, 0), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.check(rearming: true) }
        }
        timer.resume()
        source = timer
        if backstop == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(rearming: false) }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            backstop = timer
        }
    }

    /// Goes off if its time has come. If not and `rearming`, it's set again by the clock as it is
    /// now (for a wake, a changed clock, or a dispatch timer that fired a moment early).
    private func check(rearming: Bool) {
        guard let date else { return }
        if date <= Date() {
            set(nil)
            action()
        } else if rearming {
            arm()
        }
    }
}

/// Reads a duration out of free text, so "10m stretch" or "tea 4 min" both work.
enum ReminderParser {
    /// The longest a timer can run.
    static let longest: TimeInterval = 7 * 24 * 3600

    private static let unitPattern = try! NSRegularExpression(
        pattern: #"(\d+(?:[.,]\d+)?)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#,
        options: [.caseInsensitive])
    private static let numberPattern = try! NSRegularExpression(pattern: #"\b(\d+(?:[.,]\d+)?)\b"#)
    private static let pinPattern = try! NSRegularExpression(pattern: #"(?<!\S)/pin(?!\S)"#, options: [.caseInsensitive])
    private static let endlessPattern = try! NSRegularExpression(pattern: #"(?:\binf(?:inite)?\b|∞)"#, options: [.caseInsensitive])

    /// The time, the name, and whether "/pin" (anywhere in it) asks for it to be held on the notch.
    static func parse(_ text: String) -> (duration: TimeInterval?, label: String, pin: Bool) {
        let (text, pin) = unpinned(text)
        var label = text
        var total: TimeInterval = 0
        let source = text as NSString
        // Reversed so earlier ranges stay valid while later matches are cut out.
        for match in unitPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let unit = source.substring(with: match.range(at: 2)).lowercased()
            total += number(source.substring(with: match.range(at: 1)))
                * (unit.hasPrefix("d") ? 24 * 3600 : unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1)
            label = (label as NSString).replacingCharacters(in: match.range, with: " ")
        }
        // A bare number means minutes.
        if total == 0, let match = numberPattern.firstMatch(in: label, range: NSRange(location: 0, length: (label as NSString).length)) {
            total = number((label as NSString).substring(with: match.range(at: 1))) * 60
            label = (label as NSString).replacingCharacters(in: match.range, with: " ")
        }
        var words = label.split(whereSeparator: \.isWhitespace).map(String.init)
        // "call mom in 90s": drop the connector the duration leaves behind.
        if total > 0 {
            let connectors: Set = ["in", "for", "after"]
            while let last = words.last, connectors.contains(last.lowercased()) { words.removeLast() }
            while let first = words.first, connectors.contains(first.lowercased()) { words.removeFirst() }
        }
        return (total > 0 ? min(total, longest) : nil, words.joined(separator: " "), pin)
    }

    /// `text` without any "/pin" in it, and whether there was one.
    static func unpinned(_ text: String) -> (text: String, pin: Bool) {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        guard pinPattern.firstMatch(in: text, range: whole) != nil else { return (text, false) }
        let rest = pinPattern.stringByReplacingMatches(in: text, range: whole, withTemplate: " ")
        return (rest.split(whereSeparator: \.isWhitespace).joined(separator: " "), true)
    }

    /// "inf" (or "∞") instead of a time: for as long as it takes (staying awake till it's stopped).
    static func isEndless(_ text: String) -> Bool {
        endlessPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// A time as it'd be typed: "12m 34s", or past an hour "1h 5m" (rounded up, as the countdown
    /// shows it), and how long that reads back as.
    static func spell(_ seconds: TimeInterval) -> (text: String, duration: TimeInterval) {
        var total = max(Int((seconds - 0.001).rounded(.up)), 1)
        if total >= 3600 { total = (total + 59) / 60 * 60 }
        let parts = [(total / 86400, "d"), (total % 86400 / 3600, "h"), (total % 3600 / 60, "m"), (total % 60, "s")]
        return (parts.filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined(separator: " "), TimeInterval(total))
    }

    private static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}
