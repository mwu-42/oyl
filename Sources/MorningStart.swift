import AppKit
import Combine
import os

/// Claude's 5-hour limit window started early: each morning at a time you set (7:00 to begin
/// with), a one-word prompt sent through Claude Code's own command, on your subscription, so the
/// window starts then and resets five hours on, sooner in the day than if it began with your first
/// real prompt. Haiku answers it, so it takes as little of the limit as anything can. It runs in a
/// folder of Oyl's own with no tools, no MCP servers, no hooks and nothing saved, so it isn't a
/// session anywhere (nor an agent Oyl): see `ClaudeCode`. On the Agents settings, off to begin with; ‹ and › move
/// the time a quarter of an hour.
///
/// The Mac has to be awake for it: missed while it sleeps (or before Oyl's open), it's sent when it
/// can, as long as that's within `grace` of the time; tried again a few minutes on if it fails, a
/// few times at most.
@MainActor
final class MorningStart: ObservableObject {
    static let shared = MorningStart()

    static let minutesKey = "morning.minutes"
    static let triedKey = "morning.tried"
    static let sentKey = "morning.sent"
    static let failedKey = "morning.failed"
    /// 7:00, to begin with.
    static let usualMinutes = 7 * 60
    /// How late it's still worth sending, after the time.
    nonisolated static let grace: TimeInterval = 4 * 3600
    /// How long it's let take, and how long before it's tried again (`tries` times a morning).
    nonisolated static let patience: TimeInterval = 90
    static let retry: TimeInterval = 5 * 60
    static let tries = 3
    /// What's sent: as little as there can be, and an answer as short.
    nonisolated static let prompt = "Reply with just the word: ok"

    /// When it's sent, in minutes after midnight.
    @Published private(set) var minutes: Int
    /// The last time it went, and why the last try didn't, if it didn't.
    @Published private(set) var sent: Date?
    @Published private(set) var failed: String?

    private let defaults: UserDefaults
    private var timer: Timer?
    /// When the next window's to be looked at, as this one ends (see `chainCheck`).
    private var chainTimer: Timer?
    private var chainRetries = 0
    private var watchingWindow: AnyCancellable?
    private var observers: [Any] = []
    private var following: AnyCancellable?
    private var sending = false
    /// Tries this morning (reset each morning).
    private var triedToday = 0
    private static let log = Logger(subsystem: "local.nott", category: "morning")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        minutes = (defaults.object(forKey: Self.minutesKey) as? Int).map { min(max($0, 0), 24 * 60 - 15) } ?? Self.usualMinutes
        sent = defaults.object(forKey: Self.sentKey) as? Date
        failed = defaults.string(forKey: Self.failedKey)
    }

    // MARK: When

    /// Whether it's to be sent at `now`: past today's time (but not by more than `grace`), and not
    /// tried since.
    nonisolated static func isDue(now: Date, minutes: Int, tried: Date?, calendar: Calendar = .current) -> Bool {
        let at = moment(on: now, minutes: minutes, calendar: calendar)
        guard now >= at, now.timeIntervalSince(at) < grace else { return false }
        return tried.map { $0 < at } ?? true
    }

    /// The next time it's to be looked at after `now`: today's time if it's still to come, else
    /// tomorrow's.
    nonisolated static func next(after now: Date, minutes: Int, calendar: Calendar = .current) -> Date {
        let today = moment(on: now, minutes: minutes, calendar: calendar)
        if today > now { return today }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return moment(on: tomorrow, minutes: minutes, calendar: calendar)
    }

    nonisolated static func moment(on day: Date, minutes: Int, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }

    // MARK: Following the setting

    /// Watching the clock (and the Mac waking), while it's on.
    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.check()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self?.chainCheck() }
                }
            },
            NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            },
        ]
        following = Features.shared.follow(.morningClaude) { [weak self] _ in self?.check() }
        // A window going (yours, or one this started): looked at again just after it ends.
        watchingWindow = ClaudeLimit.shared.$reading
            .compactMap { $0?.resets }
            .removeDuplicates()
            .sink { [weak self] resets in
                MainActor.assumeIsolated { self?.chainAfter(resets) }
            }
        // As Oyl starts, or the Mac wakes: one might have ended meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.chainCheck() }
    }

    // MARK: One window after another

    /// The latest one's sent: 2 AM.
    nonisolated static let cutoff = 2 * 60
    /// Never two less than this apart, whatever's read.
    nonisolated static let apart: TimeInterval = 4.5 * 3600

    /// Whether `date` is in the day's hours for it: from the morning's time to the cutoff (past
    /// midnight, the next morning's side of it).
    nonisolated static func inHours(_ date: Date, from start: Int, until cutoff: Int = cutoff, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return cutoff <= start ? (minute >= start || minute <= cutoff) : (minute >= start && minute <= cutoff)
    }

    /// When they'd be sent in a day with nobody else starting one: every five hours from the
    /// morning's time, while it's before the cutoff (minutes after midnight, past 24 h the next day's).
    nonisolated static func chainTimes(from start: Int, until cutoff: Int = cutoff) -> [Int] {
        let end = cutoff <= start ? cutoff + 24 * 60 : cutoff
        return Array(stride(from: start, through: end, by: 5 * 60))
    }

    /// The chain's times, said: "7:00 AM, 12:00 PM, 5:00 PM, 10:00 PM".
    var chainSaid: String { Self.chainTimes(from: minutes).map { Self.describe($0 % (24 * 60)) }.joined(separator: ", ") }

    /// Looked at again just after the window ending at `resets` does.
    private func chainAfter(_ resets: Date) {
        guard Feature.claudeChain.isOn else { return }
        let at = max(resets.addingTimeInterval(30), Date().addingTimeInterval(5))
        if let fire = chainTimer?.fireDate, fire <= at, fire > Date() { return }
        chainTimer?.invalidate()
        let timer = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.chainCheck() }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        chainTimer = timer
    }

    /// A window's (likely) ended: in the day's hours, if none's going now, another's started.
    func chainCheck(now: Date = Date()) {
        chainTimer?.invalidate()
        chainTimer = nil
        guard Feature.claudeChain.isOn, !sending, Self.inHours(now, from: minutes) else { return }
        if let sent, now.timeIntervalSince(sent) < Self.apart { chainAfter(sent.addingTimeInterval(5 * 3600)); return }
        ClaudeLimit.shared.readNow { [weak self] reading in
            guard let self else { return }
            if let reading, reading.isCurrent(at: Date()), let resets = reading.resets {
                // Going already (you've been using it): after this one, then.
                self.chainAfter(resets)
            } else {
                self.send(chained: true)
            }
        }
    }

    /// Sent if it's due; then the clock set for the next time.
    func check(now: Date = Date()) {
        timer?.invalidate()
        timer = nil
        guard Feature.morningClaude.isOn else { return }
        let tried = defaults.object(forKey: Self.triedKey) as? Date
        if Self.isDue(now: now, minutes: minutes, tried: tried) || retrying(now: now, tried: tried) {
            send()
        }
        let next = Self.next(after: now, minutes: minutes)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Tried this morning and failed: again, once it's been a few minutes (a few times at most).
    private func retrying(now: Date, tried: Date?) -> Bool {
        guard failed != nil, let tried, triedToday > 0, triedToday < Self.tries else { return false }
        let at = Self.moment(on: now, minutes: minutes)
        return tried >= at && now.timeIntervalSince(at) < Self.grace && now.timeIntervalSince(tried) >= Self.retry
    }

    /// The time a quarter of an hour earlier (`by` -1) or later (1), within the day.
    func move(by steps: Int) {
        minutes = min(max(minutes + steps * 15, 0), 24 * 60 - 15)
        defaults.set(minutes, forKey: Self.minutesKey)
        check()
    }

    /// "7:00 AM", as the Mac writes times.
    var time: String { Self.describe(minutes) }

    nonisolated static func describe(_ minutes: Int) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let date = Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: minutes / 60, minute: minutes % 60)) ?? Date()
        return formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// What it last did, for the setting's hint.
    var lastSaid: String {
        if let failed { return "The last try didn't go: \(failed)." }
        guard let sent else { return "Not sent yet." }
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "Last sent \(formatter.string(from: sent).replacingOccurrences(of: "\u{202F}", with: " "))."
    }

    // MARK: Sending

    /// The prompt sent: the morning's (`chained` false), or one as a window ends.
    private func send(chained: Bool = false) {
        guard !sending else { return }
        sending = true
        let now = Date()
        if !chained {
            let tried = defaults.object(forKey: Self.triedKey) as? Date
            // A new morning: its tries counted afresh.
            if tried.map({ $0 < Self.moment(on: now, minutes: minutes) }) ?? true { triedToday = 0 }
            triedToday += 1
            defaults.set(now, forKey: Self.triedKey)
        }
        DispatchQueue.global(qos: .utility).async {
            let result = Self.ask()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finished(result, chained: chained) }
            }
        }
    }

    private func finished(_ result: Result<Void, Failure>, chained: Bool = false) {
        sending = false
        switch result {
        case .success:
            sent = Date()
            failed = nil
            chainRetries = 0
            defaults.set(sent, forKey: Self.sentKey)
            // When this window ends, read a moment from now (and till then, five hours on).
            if let sent { chainAfter(sent.addingTimeInterval(5 * 3600)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { ClaudeLimit.shared.readNow { _ in } }
            defaults.removeObject(forKey: Self.failedKey)
            Self.log.notice("Claude's window started early")
        case .failure(let why):
            failed = why.said
            defaults.set(why.said, forKey: Self.failedKey)
            Self.log.notice("Claude's morning prompt didn't go: \(why.said, privacy: .public)")
            // A window's: once more, a few minutes on.
            if chained {
                chainRetries += 1
                if chainRetries < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.retry) { [weak self] in
                        MainActor.assumeIsolated { self?.chainCheck() }
                    }
                }
                return
            }
            // Again in a few minutes, while there are tries left.
            if triedToday < Self.tries {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.retry + 5) { [weak self] in
                    MainActor.assumeIsolated { self?.check() }
                }
            }
        }
    }

    struct Failure: Error, Equatable {
        let said: String
    }

    /// What it's run with (see `ClaudeCode.arguments`).
    nonisolated static let arguments = ClaudeCode.arguments(prompt)

    /// The prompt sent, and answered (or why not), off the main thread.
    nonisolated static func ask(in folder: URL = ClaudeCode.folder(), tool: URL? = ClaudeCode.tool(),
                                patience: TimeInterval = patience) -> Result<Void, Failure> {
        switch ClaudeCode.run(prompt, in: folder, tool: tool, patience: patience) {
        case .failure(.missing): return .failure(Failure(said: "Claude Code's command isn't installed"))
        case .failure(.unstartable): return .failure(Failure(said: "Claude Code couldn't be run"))
        case .failure(.tooLong): return .failure(Failure(said: "it took too long"))
        case .success(let output):
            guard output.status == 0 else {
                let why = (output.wrong.isEmpty ? output.said : output.wrong)
                    .split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? ""
                return .failure(Failure(said: why.isEmpty ? "Claude Code said no" : why))
            }
            return .success(())
        }
    }
}
