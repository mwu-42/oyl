import Combine
import Foundation

/// Your commits today, hour by hour, for the stats page, as Claude's tokens are: from the git
/// repositories Claude Code's worked in (each folder's, as its transcripts say, remembered once
/// seen, so one worked on by hand afterwards still counts). Only yours (by the repository's own
/// `user.email`), on its local branches, unpushed ones too. Read while the page is up, once a
/// minute, off the main thread; git only read (`git log`, optional locks off), never written.
@MainActor
final class CommitTimeline: ObservableObject {
    static let shared = CommitTimeline()

    struct Totals: Equatable {
        var hourly = [Int](repeating: 0, count: 24)
        var hour = 0
        var today = 0
        var lastFiveHours = 0
        /// The repository with the most today (its folder's name).
        var busiest: String?
        var repositories = 0
    }

    @Published private(set) var totals: Totals?

    static let reposKey = "commits.repos"
    static let most = 24
    static let every: TimeInterval = 60

    private let defaults: UserDefaults
    private var timer: Timer?
    private var reading = false
    private var watching = 0
    private var following: AnyCancellable?
    /// Folders already looked at for their repository.
    private var looked = Set<String>()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The repositories it reads, as remembered.
    var repositories: [String] { defaults.stringArray(forKey: Self.reposKey) ?? [] }

    /// The page is up (or not): read now, and once a minute while it is.
    func start() {
        watching += 1
        guard watching == 1 else { return }
        following = TokenUsage.shared.$totals
            .compactMap { $0?.folders }
            .removeDuplicates()
            .sink { [weak self] folders in MainActor.assumeIsolated { self?.learn(folders) } }
        read()
        let timer = Timer(timeInterval: Self.every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        watching = max(watching - 1, 0)
        guard watching == 0 else { return }
        timer?.invalidate()
        timer = nil
        following = nil
    }

    /// Folders Claude Code's worked in: each one's repository remembered, if it's in one.
    private func learn(_ folders: [String]) {
        let fresh = folders.filter { !looked.contains($0) }
        guard !fresh.isEmpty else { return }
        looked.formUnion(fresh)
        DispatchQueue.global(qos: .utility).async {
            let roots = fresh.compactMap(Self.root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.remember(roots) }
            }
        }
    }

    func remember(_ roots: [String]) {
        var known = repositories
        let new = roots.filter { !known.contains($0) }
        guard !new.isEmpty else { return }
        known = Array((new + known).prefix(Self.most))
        defaults.set(known, forKey: Self.reposKey)
        read()
    }

    private func read() {
        guard !reading else { return }
        reading = true
        let repositories = self.repositories
        let now = Date()
        let since = min(Calendar.current.startOfDay(for: now), now.addingTimeInterval(-5 * 3600))
        DispatchQueue.global(qos: .utility).async {
            let commits = repositories.flatMap { root in
                Self.commits(in: root, since: since).map { (repo: (root as NSString).lastPathComponent, time: $0) }
            }
            let totals = Self.tally(commits, repositories: repositories.count, now: now)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.reading = false
                    if totals != self.totals { self.totals = totals }
                }
            }
        }
    }

    // MARK: Reading git

    /// The commits made at or after `since`: by hour of today, today's and the last five hours',
    /// and the repository with the most today.
    nonisolated static func tally(_ commits: [(repo: String, time: Date)], repositories: Int, now: Date,
                                  calendar: Calendar = .current) -> Totals {
        var totals = Totals()
        totals.hour = calendar.component(.hour, from: now)
        totals.repositories = repositories
        let today = calendar.startOfDay(for: now), window = now.addingTimeInterval(-5 * 3600)
        var repos: [String: Int] = [:]
        for commit in commits where commit.time <= now {
            if commit.time >= window { totals.lastFiveHours += 1 }
            guard commit.time >= today else { continue }
            totals.today += 1
            totals.hourly[calendar.component(.hour, from: commit.time)] += 1
            repos[commit.repo, default: 0] += 1
        }
        totals.busiest = repos.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        return totals
    }

    /// The repository `folder`'s in, if it's in one.
    nonisolated static func root(_ folder: String) -> String? {
        guard FileManager.default.fileExists(atPath: folder),
              let said = git(["-C", folder, "rev-parse", "--show-toplevel"]) else { return nil }
        let root = said.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    /// Your commits in `root` since `since`, on its local branches: when each was made.
    nonisolated static func commits(in root: String, since: Date) -> [Date] {
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        let email = git(["-C", root, "config", "user.email"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var arguments = ["-C", root, "log", "--branches", "--since=@\(Int(since.timeIntervalSince1970))", "--format=%ct"]
        if !email.isEmpty { arguments.append("--author=" + NSRegularExpression.escapedPattern(for: email)) }
        return (git(arguments) ?? "").split(whereSeparator: \.isNewline).compactMap { line in
            Double(line.trimmingCharacters(in: .whitespaces)).map { Date(timeIntervalSince1970: $0) }
        }
    }

    /// `git <arguments>`: what it printed, or nil if it failed (or took more than a few seconds).
    nonisolated static func git(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
