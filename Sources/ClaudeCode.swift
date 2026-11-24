import Foundation

/// Claude Code's own command (`claude`), run by Oyl for the few things it asks of it: the
/// morning's prompt (see `MorningStart`) and how much of the 5-hour window is used (see
/// `ClaudeLimit`). Always in print mode, in a folder of Oyl's own with nothing in it, with no
/// tools, no MCP servers, no hooks (so Oyl's own don't take it for a session) and nothing saved;
/// on your subscription, as Claude Code signs in (so never `--bare`, which wouldn't).
enum ClaudeCode {
    /// Where the command is: linked into ~/.local/bin by its installer, or Homebrew's.
    nonisolated static func tool(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let places = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                      home.appendingPathComponent(".claude/local/claude").path]
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Oyl's own folder to run it in, with nothing in it for Claude Code to read.
    nonisolated static func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let folder = home.appendingPathComponent("Library/Application Support/nott/claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `-p <line>`, and all that keeps it to itself: Haiku (should a line ever reach a model that
    /// isn't meant to), no tools, no MCP servers, no hooks, nothing saved.
    nonisolated static func arguments(_ line: String) -> [String] {
        ["-p", line, "--model", "haiku", "--tools", "", "--strict-mcp-config",
         "--settings", #"{"disableAllHooks":true}"#, "--no-session-persistence"]
    }

    struct Output {
        let status: Int32
        let said: String
        let wrong: String
    }

    enum Failure: Error, Equatable {
        case missing, unstartable, tooLong
    }

    /// `claude -p <line>`, off the main thread: what it said (and its status), or why it couldn't
    /// be asked.
    nonisolated static func run(_ line: String, in folder: URL = folder(), tool: URL? = tool(),
                                patience: TimeInterval = 90) -> Result<Output, Failure> {
        guard let tool else { return .failure(.missing) }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments(line)
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
            return .failure(.unstartable)
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + patience, execute: watchdog)
        // What it says wrong, read alongside, so a long message can't hold it up.
        final class Said: @unchecked Sendable { var data = Data() }
        let wrong = Said()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .utility).async {
            wrong.data = errors.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        let said = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        reading.wait()
        watchdog.cancel()
        guard process.terminationReason == .exit else { return .failure(.tooLong) }
        return .success(Output(status: process.terminationStatus, said: String(decoding: said, as: UTF8.self),
                               wrong: String(decoding: wrong.data, as: UTF8.self)))
    }
}
