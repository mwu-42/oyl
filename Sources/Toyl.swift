import AppKit
import Combine
import SwiftUI

/// toyl's own command (`toyl`, its app's binary), for the few things Oyl hands it so they're read
/// exactly as toyl reads them (an idea typed into the ideas page, say). Always run on the list Oyl
/// is showing (its folder given as `TOYL_HOME`), with `--json`, off nothing but the moment it
/// takes (about 20 ms), and given up on after a few seconds.
enum ToylCommand {
    /// Where it is: linked into `~/.local/bin`, or inside toyl's app.
    nonisolated static func tool(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let places = [home.appendingPathComponent(".local/bin/toyl").path,
                      home.appendingPathComponent("Applications/toyl.app/Contents/MacOS/toyl").path,
                      "/Applications/toyl.app/Contents/MacOS/toyl"]
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// `toyl <arguments>` on the list in `folder`: what it answered (a JSON object), or nil if it
    /// isn't there, failed, or took longer than `patience`.
    nonisolated static func run(_ arguments: [String], in folder: URL, tool: URL? = tool(),
                                patience: TimeInterval = 3) -> [String: Any]? {
        guard let tool else { return nil }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TOYL_HOME"] = folder.path
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + patience, execute: watchdog)
        let answer = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
    }

    /// An idea jotted into toyl's ideas, read as toyl reads it: its id, or nil if it couldn't be.
    /// (A line starting with "-" would be taken for an option, so it isn't sent.)
    nonisolated static func idea(_ text: String, in folder: URL, tool: URL? = tool()) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("-") else { return nil }
        return run(["idea", "--json", text], in: folder, tool: tool)?["id"] as? String
    }
}

/// Reminders for toyl's tasks that have a day and a time: when the time comes, the notch opens
/// with a chime to say so (as the projects outline's reminders do, which toyl's list stands in
/// for), to put off ten minutes, see, or check off. Not for a task tied to a calendar event
/// (that's the calendar's, and the owner wants no reminders for those), one put away in a list
/// toyl's archived, or one that's done. One missed while Oyl wasn't running still rings once it
/// is, if it's within twelve hours. What's been seen, and put off, is kept here (by task and its
/// time, so a task given a new time rings again), never in toyl's file.
@MainActor
final class ToylReminders: ObservableObject {
    struct Ringing: Equatable {
        let id: String
        let title: String
        /// "YYYY-MM-DD" and "HH:MM", as it was when it rang.
        let due: String
        let time: String
        /// The list it's in, if it's not the inbox (or for a Canvas assignment, its course).
        let list: String?
        /// From an email or Canvas: the mark it carries (see `TodStore.Task.mark`).
        let mark: String?

        /// Which reminder it is: the task at this time.
        var stamp: String { Self.stamp(id: id, due: due, time: time) }

        static func stamp(id: String, due: String, time: String) -> String { "\(id) \(due) \(time)" }
    }

    /// A task whose time has come, the notch open to say so, till it's seen to.
    @Published private(set) var ringing: Ringing?

    /// How long after its time a missed one still rings.
    static let missedWithin: TimeInterval = 12 * 3600

    let tod: TodStore
    /// Played as a reminder goes off.
    var chime: () -> Void = { NSSound(named: NSSound.Name("Glass"))?.play() }
    private let defaults: UserDefaults
    /// The reminders seen (by stamp), and those put off till when.
    private var seen: [String: Date]
    private var snoozed: [String: Date]
    private var clock: Timer?
    private var watching: AnyCancellable?

    /// Looked for every 15 seconds, if `reminding`, and whenever toyl's tasks change.
    init(tod: TodStore, defaults: UserDefaults = .standard, reminding: Bool = true) {
        self.tod = tod
        self.defaults = defaults
        seen = defaults.dictionary(forKey: "toyl.reminded") as? [String: Date] ?? [:]
        snoozed = defaults.dictionary(forKey: "toyl.snoozed") as? [String: Date] ?? [:]
        guard reminding else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
        watching = tod.$tasks.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.check() } }
        }
    }

    deinit { clock?.invalidate() }

    /// Rings the earliest task whose time (or whose putting off) has come within the last twelve
    /// hours, if none is ringing; lets go of the one ringing if it's done, gone or moved.
    func check(now: Date = Date()) {
        guard tod.source == .toyl, tod.isAvailable else {
            if ringing != nil { ringing = nil }
            return
        }
        if let ringing {
            let task = tod.tasks.first { $0.id == ringing.id }
            guard let task, !task.done, task.due == ringing.due, task.time == ringing.time else {
                self.ringing = nil
                return check(now: now)
            }
            return
        }
        let away = Set(tod.lists.filter(\.isArchived).map(\.id))
        var soonest: (task: TodStore.Task, when: Date)?
        for task in tod.tasks where !task.done && !task.hasEvent && !away.contains(task.listId) {
            guard let due = task.due, let time = task.time, let at = task.dueDate else { continue }
            let stamp = Ringing.stamp(id: task.id, due: due, time: time)
            guard seen[stamp] == nil else { continue }
            let when = snoozed[stamp] ?? at
            guard when <= now, now.timeIntervalSince(when) < Self.missedWithin else { continue }
            if soonest.map({ when < $0.when }) ?? true { soonest = (task, when) }
        }
        guard let soonest, let due = soonest.task.due, let time = soonest.task.time else { return }
        let list = soonest.task.course ?? tod.list(soonest.task.listId).flatMap { $0.id == "inbox" || $0.isDump ? nil : $0.name }
        ringing = Ringing(id: soonest.task.id, title: soonest.task.title, due: due, time: time, list: list, mark: soonest.task.mark)
        chime()
    }

    /// The ringing one put off `minutes` (here, not in toyl: its time stays as it is).
    func snoozeRinging(minutes: Int, now: Date = Date()) {
        guard let ringing else { return }
        snoozed[ringing.stamp] = now.addingTimeInterval(TimeInterval(minutes * 60))
        self.ringing = nil
        save(now: now)
    }

    /// Seen: it won't ring again (unless it's given another time). The next, if one's waiting.
    func dismissRinging(now: Date = Date()) {
        guard let ringing else { return }
        seen[ringing.stamp] = now
        snoozed[ringing.stamp] = nil
        self.ringing = nil
        save(now: now)
        check(now: now)
    }

    /// The ringing one checked off in toyl.
    func finishRinging(now: Date = Date()) {
        guard let ringing else { return }
        seen[ringing.stamp] = now
        snoozed[ringing.stamp] = nil
        self.ringing = nil
        if tod.tasks.contains(where: { $0.id == ringing.id && !$0.done }) { tod.toggle(ringing.id) }
        save(now: now)
        check(now: now)
    }

    /// Kept for as long as they could matter: a few days.
    private func save(now: Date) {
        let keep = now.addingTimeInterval(-3 * 86_400)
        seen = seen.filter { $0.value > keep }
        snoozed = snoozed.filter { $0.value > keep }
        defaults.set(seen, forKey: "toyl.reminded")
        defaults.set(snoozed, forKey: "toyl.snoozed")
    }
}

/// A reminder, the notch open to say so: a bell, what it's for and when, and +10 min, OK and
/// Done. The projects outline's reminders and toyl's both.
struct ReminderAlert: View {
    let title: String
    /// What it's in and when: "cs 106b · 5 PM".
    let detail: String
    /// A mark before its title, if it has one: ✉ for an email's, 🎓 for an assignment's.
    var mark: String?
    let snooze: () -> Void
    let dismiss: () -> Void
    let finish: () -> Void
    @Environment(\.notchTheme) private var theme

    static let bell = Color(red: 1, green: 0.78, blue: 0.42)

    var body: some View {
        let bell = theme.tint(Self.bell, urgent: true)
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .notchSymbol(size: 18, weight: .semibold)
                .foregroundStyle(bell)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 34, height: 34)
                .background(Circle().fill(bell.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if let mark {
                        Image(systemName: mark)
                            .notchSymbol(size: 10, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text(title.isEmpty ? "A reminder" : title)
                        .notchFont(size: 13, weight: .semibold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(detail)
                    .notchFont(size: 10.5)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            pill("+10 min", foreground: .white, background: .white.opacity(0.14), bright: false, action: snooze)
            pill("OK", foreground: .white, background: .white.opacity(0.14), bright: false, action: dismiss)
            pill("Done", foreground: .black, background: Self.bell, action: finish)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func pill(_ title: String, foreground: Color, background: Color, bright: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .notchFont(size: 11.5, weight: .semibold)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .notchPill(background, text: foreground, bright: bright, urgent: true)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// One of toyl's tasks ringing (see `ToylReminders`).
struct ToylReminderAlert: View {
    let ringing: ToylReminders.Ringing
    @ObservedObject var reminders: ToylReminders

    var body: some View {
        ReminderAlert(title: ringing.title,
                      detail: [ringing.list, TodQuick.describe(time: ringing.time)].compactMap { $0 }.joined(separator: " · "),
                      mark: ringing.mark,
                      snooze: { reminders.snoozeRinging(minutes: 10) }, dismiss: { reminders.dismissRinging() },
                      finish: { reminders.finishRinging() })
    }
}
