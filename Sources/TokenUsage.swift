import Foundation

/// How many tokens Claude Code has been using, added up from the transcripts it keeps in
/// ~/.claude/projects. Read every 30 seconds while the Activity page is open (and not at all
/// otherwise), and only what was written since the last look.
@MainActor
final class TokenUsage: ObservableObject {
    struct Totals: Equatable {
        /// Input, output and cache writes. Cache reads are cheap re-reads, so they're kept apart.
        var today = 0
        var lastFiveHours = 0  // Claude's usage limits run in five-hour windows
        var outputToday = 0
        var cacheReadsToday = 0
        var hourly = [Int](repeating: 0, count: 24)  // today, by hour of the day
        var hour = 0                                  // the hour it is now
        var busiestProject: String?                   // the most tokens today
    }

    static let shared = TokenUsage()

    /// Nil until the transcripts have been read once.
    @Published private(set) var totals: Totals?

    private static let interval = 30.0
    private let reader = TranscriptReader()
    private let queue = DispatchQueue(label: "oyl.TokenUsage", qos: .utility)
    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        queue.async { [weak self, reader] in
            let totals = reader.refresh()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.totals != totals else { return }
                    self.totals = totals
                }
            }
        }
    }
}

/// Follows the transcript files and keeps the usage that still counts towards today or the last
/// five hours. Only used on its queue.
private final class TranscriptReader: @unchecked Sendable {
    private struct Entry {
        let time: Date
        let tokens: Int  // input, output and cache writes
        let output: Int
        let cacheReads: Int
        let project: String
    }

    /// How far into a file has been read, and which file that was, to notice it being replaced.
    private struct Position {
        var inode: UInt64
        var offset: UInt64
    }

    /// The little of a transcript line that matters here.
    private struct Line: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                var inputTokens: Int?
                var outputTokens: Int?
                var cacheCreationInputTokens: Int?
                var cacheReadInputTokens: Int?
            }
            var id: String?
            var usage: Usage?
        }
        var type: String?
        var message: Message?
        var requestId: String?
        var timestamp: String?
        var cwd: String?
    }

    private static let marker = Array("\"usage\"".utf8)
    private static let fiveHours: TimeInterval = 5 * 3600
    private static let twoDays: TimeInterval = 2 * 86_400

    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)
    private var positions: [String: Position] = [:]
    /// Replies already counted, with their times so the old ones can be forgotten.
    private var counted: [String: Date] = [:]
    private var entries: [Entry] = []
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    private let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let wholeSecondDates = ISO8601DateFormatter()

    func refresh() -> TokenUsage.Totals {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        // Anything older counts neither today nor in the last five hours.
        let cutoff = min(today, now.addingTimeInterval(-Self.fiveHours))

        var followed: [String: Position] = [:]
        for (path, project) in transcripts() {
            followed[path] = follow(path, project: project, cutoff: cutoff, now: now)
        }
        positions = followed
        entries.removeAll { $0.time < cutoff }
        counted = counted.filter { $0.value >= cutoff }

        var totals = TokenUsage.Totals()
        totals.hour = calendar.component(.hour, from: now)
        let window = now.addingTimeInterval(-Self.fiveHours)
        var projects: [String: Int] = [:]
        for entry in entries {
            if entry.time >= window { totals.lastFiveHours += entry.tokens }
            guard entry.time >= today else { continue }
            totals.today += entry.tokens
            totals.outputToday += entry.output
            totals.cacheReadsToday += entry.cacheReads
            totals.hourly[calendar.component(.hour, from: entry.time)] += entry.tokens
            projects[entry.project, default: 0] += entry.tokens
        }
        // Ties go to the first name, so the pick doesn't flicker between refreshes.
        totals.busiestProject = projects.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        return totals
    }

    /// Every transcript, subagents' included, with the name of the project folder it's in.
    private func transcripts() -> [(path: String, project: String)] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found: [(String, String)] = []
        let depth = root.pathComponents.count
        for case let url as URL in walker {
            if url.pathExtension == "jsonl" {
                let components = url.pathComponents
                guard components.count > depth + 1 else { continue }
                found.append((url.path, Self.project(folder: components[depth])))
            } else if url.lastPathComponent == "tool-results" || url.lastPathComponent == "memory" {
                walker.skipDescendants()
            }
        }
        return found
    }

    /// Claude Code names a project's folder after its path, slashes as dashes: "-Users-x-Foo".
    private static func project(folder: String) -> String {
        folder.split(separator: "-").last.map(String.init) ?? folder
    }

    /// Reads whatever was added to the file since last time and returns where to pick up next.
    private func follow(_ path: String, project: String, cutoff: Date, now: Date) -> Position? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let size = UInt64(info.st_size), inode = UInt64(info.st_ino)
        var position: Position
        if let known = positions[path], known.inode == inode, known.offset <= size {
            position = known
        } else {
            // New to us, or shrunk or swapped for another file: start it over. One left alone for
            // two days has nothing that counts, so only what's added from now on gets read.
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            position = Position(inode: inode, offset: modified < now.addingTimeInterval(-Self.twoDays) ? size : 0)
        }
        if size > position.offset {
            position.offset = read(path, from: position.offset, project: project, cutoff: cutoff)
        }
        return position
    }

    /// Takes in the whole lines from `offset` on, a megabyte at a time, and returns the offset
    /// after the last one. A line still being written is left for next time.
    private func read(_ path: String, from offset: UInt64, project: String, cutoff: Date) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? handle.close() }
        var next = offset
        var pending = Data()
        do {
            try handle.seek(toOffset: offset)
            while true {
                // The chunks are autoreleased, so let each go before reading the next.
                let more = try autoreleasepool {
                    guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                    pending.append(chunk)
                    let used = pending.withUnsafeBytes { take($0, project: project, cutoff: cutoff) }
                    next += UInt64(used)
                    pending = pending.subdata(in: pending.startIndex + used..<pending.endIndex)
                    return true
                }
                if !more { break }
            }
        } catch {}
        return next
    }

    /// Counts the usage on each whole line in the buffer and returns how many bytes those were.
    private func take(_ buffer: UnsafeRawBufferPointer, project: String, cutoff: Date) -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        var start = 0
        while start < buffer.count, let newline = memchr(base + start, 0x0A, buffer.count - start) {
            let end = base.distance(to: UnsafeRawPointer(newline))
            // Most lines are prompts, tool output and the like; only replies carry usage.
            if memmem(base + start, end - start, Self.marker, Self.marker.count) != nil {
                let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: end - start,
                                deallocator: .none)
                count(line, project: project, cutoff: cutoff)
            }
            start = end + 1
        }
        return start
    }

    private func count(_ data: Data, project: String, cutoff: Date) {
        guard let line = try? decoder.decode(Line.self, from: data), line.type == "assistant",
              let message = line.message, let usage = message.usage,
              let stamp = line.timestamp, let time = dates.date(from: stamp) ?? wholeSecondDates.date(from: stamp),
              time >= cutoff else { return }
        let output = usage.outputTokens ?? 0
        let tokens = (usage.inputTokens ?? 0) + output + (usage.cacheCreationInputTokens ?? 0)
        let cacheReads = usage.cacheReadInputTokens ?? 0
        guard tokens + cacheReads > 0 else { return }
        // A reply is written out again as it streams in; count it once.
        if let id = message.id {
            let key = id + " " + (line.requestId ?? "")
            guard counted[key] == nil else { return }
            counted[key] = time
        }
        let folder = line.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
        entries.append(Entry(time: time, tokens: tokens, output: output, cacheReads: cacheReads,
                             project: folder.isEmpty || folder == "/" ? project : folder))
    }
}
