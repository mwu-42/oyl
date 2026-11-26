import Foundation

/// Claude Code's own command (`claude`), run by Oyl for the few things it asks of it: the
/// morning's prompt (see `MorningStart`) and how much of the 5-hour window is used (see
/// `ClaudeLimit`). Always in print mode, in a folder of Oyl's own with nothing in it, with no
/// tools, no MCP servers, no hooks (so Oyl's own don't take it for a session) and nothing saved;
/// on your subscription, as Claude Code signs in (so never `--bare`, which wouldn't); and as
/// whichever of your accounts it's asked of (see `ClaudeAccount`).
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

    /// What it's run with: Oyl's own, as `account` (its folder for CLAUDE_CONFIG_DIR, or none for
    /// Claude Code's own), and no colors.
    nonisolated static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment,
                                        account: ClaudeAccount = .default) -> [String: String] {
        var environment = base
        environment["NO_COLOR"] = "1"
        environment["CLAUDE_CONFIG_DIR"] = account.folder?.path
        return environment
    }

    /// `claude -p <line>`, off the main thread, as `account`: what it said (and its status), or
    /// why it couldn't be asked.
    nonisolated static func run(_ line: String, account: ClaudeAccount = .default, in folder: URL = folder(), tool: URL? = tool(),
                                patience: TimeInterval = 90) -> Result<Output, Failure> {
        guard let tool else { return .failure(.missing) }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments(line)
        process.currentDirectoryURL = folder
        process.environment = environment(account: account)
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

/// One of the Claude accounts Claude Code's signed in to on this Mac, each with a 5-hour window
/// of its own: Claude Code's own (~/.claude, as it is with CLAUDE_CONFIG_DIR unset), and each
/// other one set up beside it in a folder of its own, ~/.claude-<name>, that Claude Code's run
/// with CLAUDE_CONFIG_DIR set to (as `claude-personal` is).
struct ClaudeAccount: Hashable, Sendable, Identifiable {
    /// "work", "personal".
    let name: String
    /// Its folder, for CLAUDE_CONFIG_DIR: none for Claude Code's own.
    let folder: URL?

    var id: String { folder?.path ?? "" }
    var isDefault: Bool { folder == nil }
    /// "W", "P": for the bar, beside what's left of its window.
    var initial: String { String(name.prefix(1)).uppercased() }

    /// Claude Code's own, called (beside the others) what it is here: `claude-work`'s.
    nonisolated static let defaultName = "work"
    nonisolated static let `default` = ClaudeAccount(name: defaultName, folder: nil)

    /// Claude Code's own, then each other one there's a folder for that's signed in (its
    /// `.claude.json` says whose it is), by name.
    nonisolated static func all(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ClaudeAccount] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let prefix = ".claude-"
        let others = entries.filter { $0.hasPrefix(prefix) && $0.count > prefix.count }.sorted().compactMap { entry -> ClaudeAccount? in
            let folder = home.appendingPathComponent(entry, isDirectory: true)
            guard isSignedIn(folder) else { return nil }
            return ClaudeAccount(name: String(entry.dropFirst(prefix.count)), folder: folder)
        }
        return [.default] + others
    }

    /// Whether Claude Code's signed in in `folder`: its `.claude.json` has the account in it.
    nonisolated static func isSignedIn(_ folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(".claude.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return false }
        return !account.isEmpty
    }
}
