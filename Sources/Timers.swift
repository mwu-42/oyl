import AppKit

struct ReminderTimer: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    var duration: TimeInterval
    var endDate: Date?                    // set while running
    var pausedRemaining: TimeInterval?    // set while paused
    var endless: Bool?                    // no time on it: there until it's marked done

    var isRunning: Bool { endDate != nil }
    var isEndless: Bool { endless == true }
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
        if clamped >= 3600 {
            // Past an hour, just hours and minutes (rounded up too).
            let minutes = (clamped + 59) / 60
            return String(format: "%d:%02d", minutes / 60, minutes % 60)
        }
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }
}

/// Reminder timers. They survive relaunches, and one that ended while Oyl wasn't running rings
/// as soon as it starts again.
@MainActor
final class TimerStore: ObservableObject {
    @Published private(set) var timers: [ReminderTimer] = []
    /// The finished timer currently being announced in the notch.
    @Published private(set) var ringing: ReminderTimer?
    /// Endless reminders marked done (their Oyls cheer before they go).
    @Published private(set) var resolved: Set<UUID> = []

    private var waiting: [ReminderTimer] = []  // finished timers queued behind `ringing`
    private var completion: Timer?
    private var chime: Timer?
    private var chimePlays = 0
    private static let storageKey = "timers"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([ReminderTimer].self, from: data) {
            timers = saved
        }
        reschedule()
    }

    /// The timer the closed notch shows: the next one to finish, else a paused one.
    var next: ReminderTimer? {
        timers.filter(\.isRunning).min { $0.endDate! < $1.endDate! } ?? timers.first { !$0.isEndless }
    }

    func start(duration: TimeInterval, label: String) {
        guard duration > 0 else { return }
        timers.append(ReminderTimer(id: UUID(), label: label, duration: duration,
                                    endDate: Date().addingTimeInterval(duration), pausedRemaining: nil))
        changed()
    }

    /// A reminder with no time on it: its Oyl stays out on the menu bar until it's done.
    func startEndless(label: String) {
        timers.append(ReminderTimer(id: UUID(), label: label, duration: 0, endDate: nil, pausedRemaining: nil, endless: true))
        changed()
    }

    /// Marks an endless reminder done.
    func resolve(_ id: UUID) {
        resolved.insert(id)
        cancel(id)
    }

    func togglePause(_ id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }), !timers[index].isEndless else { return }
        let now = Date()
        if timers[index].isRunning {
            timers[index].pausedRemaining = timers[index].remaining(at: now)
            timers[index].endDate = nil
        } else {
            timers[index].endDate = now.addingTimeInterval(timers[index].remaining(at: now))
            timers[index].pausedRemaining = nil
        }
        changed()
    }

    func cancel(_ id: UUID) {
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
        let data = try? JSONEncoder().encode(timers)
        UserDefaults.standard.set(data, forKey: Self.storageKey)
        reschedule()
    }

    private func reschedule() {
        completion?.invalidate()
        completion = nil
        let now = Date()
        let finished = timers.filter { ($0.endDate ?? .distantFuture) <= now }
        if !finished.isEmpty {
            timers.removeAll { finished.contains($0) }
            changed()
            ring(finished)
            return
        }
        guard let end = timers.compactMap(\.endDate).min() else { return }
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        }
        RunLoop.main.add(timer, forMode: .common)
        completion = timer
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
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        chime = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playChime() }
        }
    }

    private func playChime() {
        chimePlays += 1
        NSSound(named: NSSound.Name("Glass"))?.play()
        // Repeat a few times like an iOS timer, then go quiet; the notch keeps showing it.
        if chimePlays >= 6 { stopChime() }
    }

    private func stopChime() {
        chime?.invalidate()
        chime = nil
    }
}

/// Reads a duration out of free text, so "10m stretch" or "tea 4 min" both work.
enum ReminderParser {
    /// The longest a timer can run.
    static let longest: TimeInterval = 3 * 24 * 3600

    private static let unitPattern = try! NSRegularExpression(
        pattern: #"(\d+(?:[.,]\d+)?)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#,
        options: [.caseInsensitive])
    private static let numberPattern = try! NSRegularExpression(pattern: #"\b(\d+(?:[.,]\d+)?)\b"#)
    private static let endlessPattern = try! NSRegularExpression(pattern: #"(?:\binf(?:inite)?\b|∞)"#, options: [.caseInsensitive])

    /// "inf" (or "∞") instead of a time makes it endless.
    static func parse(_ text: String) -> (duration: TimeInterval?, label: String, endless: Bool) {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        if endlessPattern.firstMatch(in: text, range: whole) != nil {
            let label = endlessPattern.stringByReplacingMatches(in: text, range: whole, withTemplate: " ")
            return (nil, label.split(whereSeparator: \.isWhitespace).joined(separator: " "), true)
        }
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
        return (total > 0 ? min(total, longest) : nil, words.joined(separator: " "), false)
    }

    private static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}
