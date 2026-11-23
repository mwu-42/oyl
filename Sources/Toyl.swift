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

    /// A task added as toyl's quick add reads it (into the inbox, unless the line names a list):
    /// its id, or nil if it couldn't be.
    nonisolated static func add(_ text: String, in folder: URL, tool: URL? = tool()) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("-") else { return nil }
        return run(["add", "--json", text], in: folder, tool: tool)?["id"] as? String
    }

    /// An idea jotted into toyl's ideas, read as toyl reads it: its id, or nil if it couldn't be.
    /// (A line starting with "-" would be taken for an option, so it isn't sent.)
    nonisolated static func idea(_ text: String, in folder: URL, tool: URL? = tool()) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("-") else { return nil }
        return run(["idea", "--json", text], in: folder, tool: tool)?["id"] as? String
    }
}
