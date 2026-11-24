import AppKit
import Combine
import os

/// Claude's 5-hour limit window started early: each morning at a time you set (7:00 to begin
/// with), a one-word prompt sent through Claude Code's own command, on your subscription, so the
/// window starts then and resets five hours on, sooner in the day than if it began with your first
/// real prompt. Haiku answers it, so it takes as little of the limit as anything can. It runs in a
/// folder of Oyl's own with no tools, no MCP servers, no hooks and nothing saved, so it isn't a
/// session anywhere (nor an agent Oyl). On the Agents settings, off to begin with; ‹ and › move
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
                MainActor.assumeIsolated { self?.check() }
            },
            NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            },
        ]
        following = Features.shared.follow(.morningClaude) { [weak self] _ in self?.check() }
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

    private func send() {
        guard !sending else { return }
        sending = true
        let now = Date()
        let tried = defaults.object(forKey: Self.triedKey) as? Date
        // A new morning: its tries counted afresh.
        if tried.map({ $0 < Self.moment(on: now, minutes: minutes) }) ?? true { triedToday = 0 }
        triedToday += 1
        defaults.set(now, forKey: Self.triedKey)
        let folder = Self.folder()
        DispatchQueue.global(qos: .utility).async {
            let result = Self.ask(in: folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finished(result) }
            }
        }
    }

    private func finished(_ result: Result<Void, Failure>) {
        sending = false
        switch result {
        case .success:
            sent = Date()
            failed = nil
            defaults.set(sent, forKey: Self.sentKey)
            defaults.removeObject(forKey: Self.failedKey)
            Self.log.notice("Claude's window started early")
        case .failure(let why):
            failed = why.said
            defaults.set(why.said, forKey: Self.failedKey)
            Self.log.notice("Claude's morning prompt didn't go: \(why.said, privacy: .public)")
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

    /// Where Claude Code's command is: linked into ~/.local/bin by its installer, or Homebrew's.
    nonisolated static func tool(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let places = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                      home.appendingPathComponent(".claude/local/claude").path]
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Oyl's own folder for it, with nothing in it for Claude Code to read.
    nonisolated static func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let folder = home.appendingPathComponent("Library/Application Support/nott/morning", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// What it's run with: print mode, Haiku, no tools, no MCP servers, no hooks, nothing saved.
    nonisolated static let arguments = ["-p", prompt, "--model", "haiku", "--tools", "", "--strict-mcp-config",
                                        "--settings", #"{"disableAllHooks":true}"#, "--no-session-persistence"]

    /// The prompt sent, and answered (or why not), off the main thread.
    nonisolated static func ask(in folder: URL, tool: URL? = tool(), patience: TimeInterval = patience) -> Result<Void, Failure> {
        guard let tool else { return .failure(Failure(said: "Claude Code's command isn't installed")) }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(Failure(said: "Claude Code couldn't be run"))
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + patience, execute: watchdog)
        final class Said: @unchecked Sendable { var data = Data() }
        let said = Said()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .utility).async {
            said.data = errors.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        let answer = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        reading.wait()
        watchdog.cancel()
        guard process.terminationReason == .exit else { return .failure(Failure(said: "it took too long")) }
        guard process.terminationStatus == 0 else {
            let why = String(decoding: said.data.isEmpty ? answer : said.data, as: UTF8.self)
                .split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? "Claude Code said no"
            return .failure(Failure(said: why.isEmpty ? "Claude Code said no" : why))
        }
        return .success(())
    }
}
