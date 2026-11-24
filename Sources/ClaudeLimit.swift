import AppKit
import Combine
import os

/// How much of Claude's 5-hour limit window is used, for the usage page: Claude Code's own
/// `/usage`, which it answers itself in a second or two (no prompt, no model: it asks Anthropic for
/// the plan's usage, as it signs in), read every few minutes ("Current session: 87% used · resets
/// Nov 23 at 11:09pm"). Read again soon after an agent's done, when the Mac wakes, and as the
/// window resets; not while Oyl's resting. Should what comes back ever stop being a usage report,
/// it's asked only once an hour (in case `/usage` ever became a prompt, which would spend some).
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

    @Published private(set) var reading: Reading?

    /// How often it's read, and how soon again after something's happened.
    static let every: TimeInterval = 3 * 60
    static let soonest: TimeInterval = 30
    static let backedOff: TimeInterval = 3600

    var isResting = false {
        didSet { if isResting != oldValue { isResting ? stop() : schedule(in: 1) } }
    }

    private var timer: Timer?
    private var asking = false
    private var lastAsked: Date?
    private var misread = 0
    private var observers: [Any] = []
    private var following: AnyCancellable?
    private static let log = Logger(subsystem: "local.nott", category: "claude-limit")

    func start() {
        observers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule(in: 5) }
            },
        ]
        following = Features.shared.follow(.claudeLimit) { [weak self] on in
            guard let self else { return }
            if on { self.schedule(in: 1) } else {
                self.stop()
                self.reading = nil
            }
        }
    }

    /// Something's happened that may have used some (an agent's done): read again soon.
    func nudge() {
        guard Feature.claudeLimit.isOn, !isResting else { return }
        let since = lastAsked.map { Date().timeIntervalSince($0) } ?? .infinity
        schedule(in: max(Self.soonest - since, 2))
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(in seconds: TimeInterval) {
        guard Feature.claudeLimit.isOn, !isResting else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: max(seconds, 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.ask() }
        }
        timer.tolerance = min(max(seconds * 0.1, 1), 20)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func ask() {
        guard !asking, Feature.claudeLimit.isOn, !isResting else { return }
        asking = true
        lastAsked = Date()
        DispatchQueue.global(qos: .utility).async {
            let result = ClaudeCode.run("/usage", patience: 30)
            let read: Reading? = if case .success(let output) = result, output.status == 0 { Self.parse(output.said) } else { nil }
            let answered = if case .success(let output) = result { output.status == 0 } else { false }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.asked(read, answered: answered) }
            }
        }
    }

    private func asked(_ read: Reading?, answered: Bool) {
        asking = false
        let now = Date()
        if let read {
            misread = 0
            Self.log.info("Claude's 5-hour window: \(read.percent)% used")
            if read != reading { reading = read }
        } else if answered {
            // Answered, but not with a usage report (no window going, or something else entirely).
            misread += 1
            if reading?.isCurrent(at: now) != true { reading = nil }
            if misread == 2 { Self.log.notice("Claude Code's /usage didn't say how much of the window is used: asking hourly") }
        } else if reading?.isCurrent(at: now) != true {
            reading = nil
        }
        var next = misread >= 2 ? Self.backedOff : Self.every
        // Read again just after it resets.
        if let resets = reading?.resets, resets > now { next = min(next, resets.timeIntervalSince(now) + 15) }
        schedule(in: next)
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

    /// "87% of Claude's 5-hour window used · resets 11:09 PM", for the notch's hint.
    nonisolated static func describe(_ reading: Reading) -> String {
        let used = "\(reading.percent)% of Claude's 5-hour window used"
        guard let resets = reading.resets else { return used }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDate(resets, inSameDayAs: reading.at) ? .none : .short
        formatter.doesRelativeDateFormatting = true
        return used + " · resets " + formatter.string(from: resets).replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
