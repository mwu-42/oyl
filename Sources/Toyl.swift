import Foundation

/// toyl's own command (`toyl`, its app's binary), for the few things Oyl hands it so they're read
/// exactly as toyl reads them (a task typed into the inbox page, an idea into the ideas page). Always run on the list Oyl
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

    /// What it said: what it answered (a JSON object), or why it wouldn't (its own message, as it
    /// says no to "/list" with no name).
    enum Answer {
        case answered([String: Any])
        case refused(String)
    }

    /// `toyl <arguments>` on the list in `folder`: what it answered (a JSON object), or nil if it
    /// isn't there, failed, or took longer than `patience`.
    nonisolated static func run(_ arguments: [String], in folder: URL, tool: URL? = tool(),
                                patience: TimeInterval = 3) -> [String: Any]? {
        guard case .answered(let object)? = ask(arguments, in: folder, tool: tool, patience: patience) else { return nil }
        return object
    }

    /// `toyl <arguments>` on the list in `folder`: what it answered, or why it wouldn't; nil if it
    /// isn't there, broke, or took longer than `patience`.
    nonisolated static func ask(_ arguments: [String], in folder: URL, tool: URL? = tool(),
                                patience: TimeInterval = 3) -> Answer? {
        guard let tool else { return nil }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TOYL_HOME"] = folder.path
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + patience, execute: watchdog)
        // What it says wrong, read alongside, so a long message can't hold it up.
        final class Said: @unchecked Sendable { var data = Data() }
        let said = Said()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            said.data = errors.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        let answer = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        reading.wait()
        watchdog.cancel()
        guard process.terminationReason == .exit else { return nil }
        guard process.terminationStatus == 0 else {
            return Self.refusal(String(decoding: said.data, as: UTF8.self)).map(Answer.refused)
        }
        return ((try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]).map(Answer.answered)
    }

    /// Its own "no", from what it wrote wrong ("toyl: a list needs a name: /list groceries"): the
    /// message, or nil for anything else (it broke, rather than said no).
    nonisolated static func refusal(_ said: String) -> String? {
        let line = said.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard line.hasPrefix("toyl: ") else { return nil }
        let message = String(line.dropFirst("toyl: ".count)).trimmingCharacters(in: .whitespaces)
        return message.isEmpty ? nil : message
    }

    /// What a line typed to add came to.
    enum Added: Equatable {
        /// A task (its id).
        case task(String)
        /// Something else a slash word first made ("/list groceries", "/timer 25m"): what it was
        /// ("list", "project", "group", "filter", "timer"), its id, and its name, if it has one.
        case made(String, id: String, name: String?)
        /// toyl said no (a slash word with nothing after it, "/event"), and why.
        case refused(String)

        /// What's said under the field once it's done (nothing for a task, which shows itself).
        var said: String? {
            switch self {
            case .task: return nil
            case .made(let kind, _, let name):
                let named = name.map { " “\($0)”" } ?? ""
                switch kind {
                case "timer": return "Timer started"
                case "filter": return "Made the filter\(named)"
                default: return "Made the \(kind)\(named)"
                }
            case .refused(let why):
                return why.prefix(1).uppercased() + why.dropFirst()
            }
        }
    }

    /// A line added as toyl's quick add reads it: a task (into the inbox, unless the line names a
    /// list), or, with a slash word first, what that makes (a list, a project, a group, a filter,
    /// a timer); or toyl's no. Nil if it couldn't be asked.
    nonisolated static func add(_ text: String, in folder: URL, tool: URL? = tool()) -> Added? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("-") else { return nil }
        switch ask(["add", "--json", text], in: folder, tool: tool) {
        case .answered(let object)?: return Self.added(object)
        case .refused(let why)?: return .refused(why)
        case nil: return nil
        }
    }

    /// What `toyl add --json` answered, read: `made` says it's something other than a task.
    nonisolated static func added(_ object: [String: Any]) -> Added? {
        guard let id = object["id"] as? String else { return nil }
        guard let made = object["made"] as? String else { return .task(id) }
        let name = (object["name"] as? String) ?? (object["query"] as? String)
        return .made(made, id: id, name: name?.isEmpty == true ? nil : name)
    }

    /// An idea jotted into toyl's ideas, read as toyl reads it: its id, or nil if it couldn't be.
    /// (A line starting with "-" would be taken for an option, so it isn't sent.)
    nonisolated static func idea(_ text: String, in folder: URL, tool: URL? = tool()) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("-") else { return nil }
        return run(["idea", "--json", text], in: folder, tool: tool)?["id"] as? String
    }
}
