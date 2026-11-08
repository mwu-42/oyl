import Foundation

/// What Claude Code's lately written or edited, as its hooks tell once each Write, Edit or
/// NotebookEdit is done (see `AgentInbox.wrote`): for the shelf, newest first, each file once,
/// kept across launches. Not its own files (in ~/.claude), what it only scribbles in a temporary
/// folder, or what's inside a repository's .git.
@MainActor
final class ClaudeFiles {
    static let shared = ClaudeFiles()
    /// How many it remembers; the shelf shows the latest few that are still there.
    static let most = 40

    struct File: Equatable {
        let path: String
        let date: Date
    }

    private(set) var recent: [File]
    /// Told of each one noted.
    var changed: () -> Void = {}
    private let defaults: UserDefaults
    static let key = "shelf.claude.files"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.array(forKey: Self.key) as? [[String: Any]] ?? []
        recent = saved.compactMap { entry in
            guard let path = entry["path"] as? String, let date = entry["date"] as? Date else { return nil }
            return File(path: path, date: date)
        }
    }

    /// Claude's just written or edited the file at `path`.
    func note(_ path: String, at date: Date = Date()) {
        guard Self.counts(path) else { return }
        let path = (path as NSString).standardizingPath
        recent.removeAll { $0.path == path }
        recent.insert(File(path: path, date: date), at: 0)
        recent = Array(recent.prefix(Self.most))
        defaults.set(recent.map { ["path": $0.path, "date": $0.date] as [String: Any] }, forKey: Self.key)
        changed()
    }

    /// One that belongs on the shelf: a whole path, and not Claude's own, a temporary one or in a .git.
    nonisolated static func counts(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let path = (path as NSString).standardizingPath
        let skipped = [home + "/.claude/", "/tmp/", "/private/tmp/", "/private/var/", "/var/folders/", (NSTemporaryDirectory() as NSString).standardizingPath + "/"]
        return !skipped.contains { path.hasPrefix($0) } && !path.contains("/.git/")
    }
}
