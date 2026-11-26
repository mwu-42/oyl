import AppKit
import Combine
import os

/// How much of Claude's 5-hour limit window is used, for the usage page: Claude Code's own
/// `/usage`, which it answers itself in a second or two (no prompt, no model: it asks Anthropic for
/// the plan's usage, as it signs in), read every few minutes ("Current session: 87% used · resets
/// Nov 23 at 11:09pm"), for each of your accounts (see `ClaudeAccount`), one after another. Read
/// again soon after an agent's done, when the Mac wakes, and as a window resets; not while Oyl's
/// resting. Should what an account's comes back ever stop being a usage report, it's asked only
/// once an hour (in case `/usage` ever became a prompt, which would spend some).
@MainActor
final class ClaudeLimit: ObservableObject {
    static let shared = ClaudeLimit()

    struct Reading: Equatable {
        /// Of the window, 0 to 100 (or more, once it's gone over).
        let percent: Int
        /// When the window resets, if it was said.
        let resets: Date?
        /// When it was read.
        let at: Date

        /// Still the window's: not past its reset.
        func isCurrent(at now: Date) -> Bool { resets.map { $0 > now } ?? (now.timeIntervalSince(at) < 5 * 3600) }
    }

    /// Your accounts, Claude Code's own first; and each one's window, by its `id`.
    @Published private(set) var accounts: [ClaudeAccount] = [.default]
    @Published private(set) var readings: [String: Reading] = [:]
    /// Claude Code's own account's (the one started early each morning, see `MorningStart`).
    @Published private(set) var reading: Reading?

    /// How many rows the usage page has for them: one an account (for its height, see `Layout`).
    nonisolated static var rows: Int { counted.withLock { $0 } }
    private nonisolated static let counted = OSAllocatedUnfairLock(initialState: 1)

    /// Read while it's shown anywhere: on the usage page, or on the bar.
    static var isWanted: Bool { Feature.claudeLimit.isOn || Feature.claudeLimitBar.isOn }

    /// How often it's read, and how soon again after something's happened.
    static let every: TimeInterval = 3 * 60
    static let soonest: TimeInterval = 30
    nonisolated static let backedOff: TimeInterval = 3600

    var isResting = false {
        didSet { if isResting != oldValue { isResting ? stop() : schedule(in: 1) } }
    }

    private var timer: Timer?
    private var asking = false
    private var lastAsked: Date?
    /// An account's, by its `id`: how many times running it hasn't said, and when it was last
    /// asked.
    private var misread: [String: Int] = [:]
    private var askedEach: [String: Date] = [:]
    private var observers: [Any] = []
    private var following: AnyCancellable?
    private static let log = Logger(subsystem: "local.nott", category: "claude-limit")

    func start() {
        found(ClaudeAccount.all())
        observers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule(in: 5) }
            },
        ]
        following = Features.shared.changed
            .filter { $0.0 == .claudeLimit || $0.0 == .claudeLimitBar }
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if Self.isWanted { self.schedule(in: 1) } else {
                        self.stop()
                        self.readings = [:]
                        self.reading = nil
                    }
                }
            }
        schedule(in: 1)
    }

    /// The current window of each account that has one, in order (Claude Code's own first).
    func current(at now: Date = Date()) -> [(account: ClaudeAccount, reading: Reading)] {
        accounts.compactMap { account in readings[account.id].flatMap { $0.isCurrent(at: now) ? (account, $0) : nil } }
    }

    /// Read now, whatever the settings, for Claude Code's own account (for the windows started
    /// one after another, see `MorningStart`): `done` told what it says, nil if it didn't say.
    func readNow(_ done: @escaping @MainActor (Reading?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = ClaudeCode.run("/usage", account: .default, patience: 30)
            let read: Reading? = if case .success(let output) = result, output.status == 0 { Self.parse(output.said) } else { nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let read { self.set(read, for: .default) }
                    done(read)
                }
            }
        }
    }

    /// Something's happened that may have used some (an agent's done): read again soon.
    func nudge() {
        guard Self.isWanted, !isResting else { return }
        let since = lastAsked.map { Date().timeIntervalSince($0) } ?? .infinity
        schedule(in: max(Self.soonest - since, 2))
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(in seconds: TimeInterval) {
        guard Self.isWanted, !isResting else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: max(seconds, 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.ask() }
        }
        timer.tolerance = min(max(seconds * 0.1, 1), 20)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private struct Asked {
        let account: ClaudeAccount
        let read: Reading?
        let answered: Bool
    }

    /// Whether the account with this `id` is left till the hour's up (it's twice not said).
    nonisolated static func isBackedOff(misread: Int, asked: Date?, now: Date) -> Bool {
        misread >= 2 && (asked.map { now.timeIntervalSince($0) < backedOff } ?? false)
    }

    private func ask() {
        guard !asking, Self.isWanted, !isResting else { return }
        asking = true
        let now = Date()
        lastAsked = now
        let misread = self.misread, askedEach = self.askedEach
        DispatchQueue.global(qos: .utility).async {
            let accounts = ClaudeAccount.all()
            let results = accounts.compactMap { account -> Asked? in
                guard !Self.isBackedOff(misread: misread[account.id] ?? 0, asked: askedEach[account.id], now: now) else { return nil }
                let result = ClaudeCode.run("/usage", account: account, patience: 30)
                let read: Reading? = if case .success(let output) = result, output.status == 0 { Self.parse(output.said) } else { nil }
                let answered = if case .success(let output) = result { output.status == 0 } else { false }
                return Asked(account: account, read: read, answered: answered)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.asked(accounts, results, at: now) }
            }
        }
    }

    private func asked(_ accounts: [ClaudeAccount], _ results: [Asked], at asked: Date) {
        asking = false
        found(accounts)
        let now = Date()
        for result in results {
            let account = result.account
            askedEach[account.id] = asked
            if let read = result.read {
                misread[account.id] = 0
                Self.log.info("Claude's 5-hour window (\(account.name, privacy: .public)): \(read.percent)% used")
                set(read, for: account)
            } else if result.answered {
                // Answered, but not with a usage report (no window going, or something else entirely).
                misread[account.id, default: 0] += 1
                if readings[account.id]?.isCurrent(at: now) != true { set(nil, for: account) }
                if misread[account.id] == 2 {
                    Self.log.notice("Claude Code's /usage didn't say how much of \(account.name, privacy: .public)'s window is used: asking hourly")
                }
            } else if readings[account.id]?.isCurrent(at: now) != true {
                set(nil, for: account)
            }
        }
        let resting = accounts.allSatisfy { Self.isBackedOff(misread: misread[$0.id] ?? 0, asked: askedEach[$0.id], now: now) }
        var next = resting ? Self.backedOff : Self.every
        // Read again just after one resets.
        if let resets = readings.values.compactMap(\.resets).filter({ $0 > now }).min() {
            next = min(next, resets.timeIntervalSince(now) + 15)
        }
        schedule(in: next)
    }

    /// The accounts there are now: any that's gone, its window forgotten.
    private func found(_ accounts: [ClaudeAccount]) {
        if accounts != self.accounts { self.accounts = accounts }
        Self.counted.withLock { $0 = max(accounts.count, 1) }
        let ids = Set(accounts.map(\.id))
        for id in readings.keys where !ids.contains(id) { readings[id] = nil }
    }

    private func set(_ read: Reading?, for account: ClaudeAccount) {
        if readings[account.id] != read { readings[account.id] = read }
        if account.isDefault, read != reading { reading = read }
    }

    // MARK: Reading what it says

    /// "Current session: 87% used · resets Nov 23 at 11:09pm (America/Los_Angeles)": 87, and when.
    /// Nil if it doesn't say.
    nonisolated static func parse(_ said: String, now: Date = Date()) -> Reading? {
        let ns = said as NSString
        guard let match = sessionLine.firstMatch(in: said, range: NSRange(location: 0, length: ns.length)),
              let percent = Int(ns.substring(with: match.range(at: 1))) else { return nil }
        func part(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        let zone = part(4).flatMap(TimeZone.init(identifier:)) ?? .current
        let resets = part(3).flatMap { resetDate(day: part(2), time: $0, zone: zone, now: now) }
        return Reading(percent: percent, resets: resets, at: now)
    }

    private nonisolated static let sessionLine = try! NSRegularExpression(
        pattern: #"Current session:\s*(\d{1,3})\s*%\s*used(?:[^\n]*?resets\s+(?:([A-Z][a-z]{2,8}\.?\s+\d{1,2})\s+at\s+)?(\d{1,2}(?::\d{2})?\s*[ap]\.?m\.?)(?:\s*\(([^)\n]+)\))?)?"#,
        options: [.caseInsensitive])

    /// "Nov 23" and "11:09pm" (or just the time, today's or else tomorrow's) in `zone`.
    nonisolated static func resetDate(day: String?, time: String, zone: TimeZone, now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let clock = time.lowercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = clock.contains(":") ? "h:mma" : "ha"
        guard let at = formatter.date(from: clock) else { return nil }
        let hm = calendar.dateComponents([.hour, .minute], from: at)
        if let day {
            formatter.dateFormat = "MMM d"
            guard let date = formatter.date(from: day.replacingOccurrences(of: ".", with: "")) else { return nil }
            let md = calendar.dateComponents([.month, .day], from: date)
            let year = calendar.component(.year, from: now)
            // The year it's nearest now (a reset's never far off).
            let candidates = [year - 1, year, year + 1].compactMap {
                calendar.date(from: DateComponents(year: $0, month: md.month, day: md.day, hour: hm.hour, minute: hm.minute))
            }
            return candidates.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
        }
        guard let today = calendar.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: now) else { return nil }
        return today > now.addingTimeInterval(-60) ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    // MARK: Saying it

    /// "87% used · resets 11:09 PM", for the usage page.
    nonisolated static func short(_ reading: Reading) -> String {
        let used = "\(reading.percent)% used"
        guard let resets = reading.resets else { return used }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDate(resets, inSameDayAs: reading.at) ? .none : .short
        formatter.doesRelativeDateFormatting = true
        return used + " · resets " + formatter.string(from: resets).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// "87% of Claude's 5-hour window used · resets 11:09 PM", for the notch's hint: of
    /// `account`'s ("87% of your personal account's 5-hour window used"), if it's one of several.
    nonisolated static func describe(_ reading: Reading, account: ClaudeAccount? = nil) -> String {
        let whose = account.map { "your \($0.name) account's" } ?? "Claude's"
        let used = "\(reading.percent)% of \(whose) 5-hour window used"
        guard let resets = reading.resets else { return used }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDate(resets, inSameDayAs: reading.at) ? .none : .short
        formatter.doesRelativeDateFormatting = true
        return used + " · resets " + formatter.string(from: resets).replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
