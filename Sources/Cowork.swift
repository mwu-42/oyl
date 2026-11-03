import Foundation

/// Cowork's tasks in the Claude desktop app, each its own Oyl while it works and for a while
/// after, whether or not it's the one on screen (which is all `ClaudeAppChats` can see), and in
/// whichever of the app's accounts (each has its own folder: Claude, Claude-Work…). Cowork runs
/// Claude Code inside the app's own little machine, and each task's transcript is kept here, in
/// the account's folder: what it's doing is read off the end of it (a tool it's running, or a
/// turn it's finished), and what it's called off the task's own record beside it.
///
/// Kept light: it looks only while the app is open, every couple of seconds, on its own queue;
/// a task's record is read again only once it's changed, and of its transcript only the end.
final class CoworkTasks: @unchecked Sendable {
    struct Task: Equatable, Sendable {
        let id: String
        let title: String
        let activity: AgentActivity
        /// When its transcript last changed.
        let lastActivity: Date
    }

    /// Each account's tasks' folder: one for each of the app's folders (Claude, Claude-Work…).
    static var roots: [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { $0.lastPathComponent == "Claude" || $0.lastPathComponent.hasPrefix("Claude-") }
            .map { $0.appendingPathComponent("local-agent-mode-sessions", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    /// Shown for this long after it last did anything.
    static let lingers: TimeInterval = 15 * 60
    /// Still "working" this long after its transcript last changed: past that it's stalled (or
    /// waiting on something no one's answered), and only resting.
    static let stalls: TimeInterval = 10 * 60

    private let queue = DispatchQueue(label: "oyl.Cowork", qos: .utility)
    private let report: @Sendable ([Task]) -> Void
    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var records: [URL: (changed: Date, record: Record?)] = [:]
    private var transcripts: [URL: (changed: Date, state: State)] = [:]
    private var last: [Task] = []

    /// A task's own record: what it's called, and where its transcript is.
    struct Record: Equatable {
        let id: String
        let title: String
        let transcript: URL
    }

    /// Where its transcript left off.
    enum State: Equatable {
        case working(AgentActivity)
        case finished
    }

    /// `report` gets the tasks whenever they change, on `queue`.
    init(report: @escaping @Sendable ([Task]) -> Void) {
        self.report = report
    }

    /// Looks while the app's open (`running`); stops, with none, once it isn't.
    func follow(_ running: Bool) {
        queue.async { [weak self] in
            guard let self, running != (self.timer != nil) else { return }
            self.timer?.cancel()
            self.timer = nil
            guard running else {
                self.publish([])
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
        }
    }

    private func check() {
        let now = Date()
        var tasks: [Task] = []
        for url in Self.recordFiles() {
            guard let changed = Self.modified(url) else { continue }
            if records[url]?.changed != changed { records[url] = (changed, Self.record(at: url)) }
            guard let record = records[url]?.record, let written = Self.modified(record.transcript),
                  now.timeIntervalSince(written) < Self.lingers else { continue }
            if transcripts[record.transcript]?.changed != written {
                transcripts[record.transcript] = (written, Self.state(of: record.transcript))
            }
            let state = transcripts[record.transcript]?.state ?? .finished
            let activity: AgentActivity
            switch state {
            case .working(let doing) where now.timeIntervalSince(written) < Self.stalls: activity = doing
            default: activity = .idle
            }
            tasks.append(Task(id: record.id, title: record.title, activity: activity, lastActivity: written))
        }
        publish(tasks.sorted { $0.id < $1.id })
    }

    private func publish(_ tasks: [Task]) {
        guard tasks != last else { return }
        last = tasks
        report(tasks)
    }

    /// Every task's record, in every account's and workspace's folder.
    private static func recordFiles() -> [URL] {
        let files = FileManager.default
        var found: [URL] = []
        for account in roots.flatMap({ (try? files.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }) {
            for workspace in (try? files.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? files.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)) ?? []
                    where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    found.append(file)
                }
            }
        }
        return found
    }

    /// The record at `url`, unless it's been archived: its title (or, till it has one, the start
    /// of what it was asked), and its transcript, in its folder (named for its ID's first part).
    static func record(at url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = entry["sessionId"] as? String, let transcript = entry["cliSessionId"] as? String,
              entry["isArchived"] as? Bool != true else { return nil }
        let folder = String(id.dropFirst("local_".count).prefix(8))
        let asked = (entry["initialMessage"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(40)) }
        let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? asked ?? "Cowork"
        let path = url.deletingLastPathComponent().appendingPathComponent(folder)
            .appendingPathComponent(".claude/projects/session/\(transcript).jsonl")
        return Record(id: id, title: title, transcript: path)
    }

    /// Where the transcript at `url` leaves off: its last message, read from the end of it.
    static func state(of url: URL) -> State {
        tail(of: url).map(state(ofTail:)) ?? .finished
    }

    /// The end of a transcript (its last 64 KB), nil if it can't be read.
    static func tail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// From the end of a transcript: its last message (past the bookkeeping after it). One of
    /// Claude's that ends its turn has finished; one that calls a tool is at that tool; anything
    /// else (a prompt, a tool's result, a reply part written) is Claude thinking.
    static func state(ofTail tail: String) -> State {
        for line in tail.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant" else { continue }
            guard type == "assistant", let message = entry["message"] as? [String: Any] else { return .working(.thinking) }
            if message["stop_reason"] as? String == "end_turn" { return .finished }
            let content = message["content"] as? [[String: Any]] ?? []
            if let tool = content.last(where: { $0["type"] as? String == "tool_use" })?["name"] as? String {
                return .working(activity(for: tool))
            }
            return .working(.thinking)
        }
        return .finished
    }

    /// What a tool's call is, as Claude Code's hooks have it.
    static func activity(for tool: String) -> AgentActivity {
        switch tool {
        case "Bash", "BashOutput", "KillShell": return .running
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return .coding
        case "Read", "Grep", "Glob", "LS": return .reading
        case "WebFetch", "WebSearch": return .browsing
        case "Task", "Agent": return .delegating
        default: return tool.hasPrefix("mcp__") && tool.lowercased().contains("chrome") ? .browsing : .thinking
        }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
