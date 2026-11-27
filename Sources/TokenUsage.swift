import Foundation

/// How many tokens Claude Code has been using, and what they'd cost at Anthropic's API prices
/// (see `ClaudePrice`), added up from the transcripts it keeps for each of your accounts (see
/// `ClaudeAccount`: ~/.claude/projects, ~/.claude-personal/projects), over the last 30 days (as
/// long as Claude Code keeps them, to begin with): today hour by hour and each day, account by
/// account. Read every 30 seconds while the usage page is open (and not at all otherwise), and
/// only what was written since the last look.
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
        /// The folders Claude Code's worked in, today and in the last five hours (for the commits'
        /// timeline to find their repositories, see `CommitTimeline`).
        var folders: [String] = []
        /// What they'd have cost at API prices, in dollars (cache reads included): today, in the
        /// last five hours, and today by hour of the day.
        var spentToday = 0.0
        var spentLastFiveHours = 0.0
        var hourlySpend = [Double](repeating: 0, count: 24)
        /// Some of today's came from a model with no price known, so isn't in what's spent.
        var unpriced = false
        /// Each account's, by its `ClaudeAccount.id`.
        var accounts: [String: Series] = [:]
    }

    /// How many days back are kept, today's the last of them.
    nonisolated static let days = 30

    /// One account's: today by hour, and each of the last 30 days (oldest first, today last); its
    /// tokens (input, output and cache writes), its output alone, and what they'd cost.
    struct Series: Equatable {
        var hourly = [Int](repeating: 0, count: 24)
        var hourlyOutput = [Int](repeating: 0, count: 24)
        var hourlySpend = [Double](repeating: 0, count: 24)
        var daily = [Int](repeating: 0, count: TokenUsage.days)
        var dailyOutput = [Int](repeating: 0, count: TokenUsage.days)
        var dailySpend = [Double](repeating: 0, count: TokenUsage.days)
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

/// Follows the transcript files and keeps the usage that still counts towards the last 30 days or
/// the last five hours. Only used on its queue.
final class TranscriptReader: @unchecked Sendable {
    private struct Entry {
        let time: Date
        let tokens: Int  // input, output and cache writes
        let output: Int
        let cacheReads: Int
        let project: String
        let account: String
        /// In dollars, at API prices; nil for a model with no price known.
        let cost: Double?
        /// Where it was working, in full (if the transcript says).
        var folder: String? = nil
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
                /// The cache writes by how long they're kept, which are priced differently.
                struct CacheCreation: Decodable {
                    var ephemeral5mInputTokens: Int?
                    var ephemeral1hInputTokens: Int?
                }
                var inputTokens: Int?
                var outputTokens: Int?
                var cacheCreationInputTokens: Int?
                var cacheReadInputTokens: Int?
                var cacheCreation: CacheCreation?
                /// "fast" for fast mode, which costs twice as much.
                var speed: String?
                /// Web searches, which cost by the search.
                struct ServerToolUse: Decodable {
                    var webSearchRequests: Int?
                }
                var serverToolUse: ServerToolUse?
            }
            var id: String?
            var model: String?
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

    /// Each account's folder of transcripts, Claude Code's own first.
    private let roots: () -> [(account: String, folder: URL)]

    init(roots: @escaping () -> [(account: String, folder: URL)] = TranscriptReader.accounts) {
        self.roots = roots
    }

    /// Every account's projects folder (see `ClaudeAccount`).
    static func accounts() -> [(account: String, folder: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ClaudeAccount.all(home: home).map { account in
            (account.id, (account.folder ?? home.appendingPathComponent(".claude")).appendingPathComponent("projects", isDirectory: true))
        }
    }

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

    func refresh(now: Date = Date(), calendar: Calendar = .current) -> TokenUsage.Totals {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: 1 - TokenUsage.days, to: today) ?? today
        // Anything older counts neither in the days kept nor in the last five hours.
        let cutoff = min(first, now.addingTimeInterval(-Self.fiveHours))

        var followed: [String: Position] = [:]
        for transcript in transcripts() {
            followed[transcript.path] = follow(transcript.path, project: transcript.project, account: transcript.account,
                                               cutoff: cutoff)
        }
        positions = followed
        entries.removeAll { $0.time < cutoff }
        counted = counted.filter { $0.value >= cutoff }

        var totals = TokenUsage.Totals()
        totals.hour = calendar.component(.hour, from: now)
        let window = now.addingTimeInterval(-Self.fiveHours)
        var projects: [String: Int] = [:]
        for entry in entries {
            if entry.time >= window {
                totals.lastFiveHours += entry.tokens
                totals.spentLastFiveHours += entry.cost ?? 0
            }
            var series = totals.accounts[entry.account] ?? TokenUsage.Series()
            if let back = calendar.dateComponents([.day], from: calendar.startOfDay(for: entry.time), to: today).day,
               (0..<TokenUsage.days).contains(back) {
                let day = TokenUsage.days - 1 - back
                series.daily[day] += entry.tokens
                series.dailyOutput[day] += entry.output
                series.dailySpend[day] += entry.cost ?? 0
            }
            if entry.time >= today {
                let hour = calendar.component(.hour, from: entry.time)
                series.hourly[hour] += entry.tokens
                series.hourlyOutput[hour] += entry.output
                series.hourlySpend[hour] += entry.cost ?? 0
            }
            totals.accounts[entry.account] = series
            guard entry.time >= today else { continue }
            let hour = calendar.component(.hour, from: entry.time)
            totals.today += entry.tokens
            totals.outputToday += entry.output
            totals.cacheReadsToday += entry.cacheReads
            totals.hourly[hour] += entry.tokens
            totals.spentToday += entry.cost ?? 0
            totals.hourlySpend[hour] += entry.cost ?? 0
            if entry.cost == nil { totals.unpriced = true }
            projects[entry.project, default: 0] += entry.tokens
        }
        // Ties go to the first name, so the pick doesn't flicker between refreshes.
        totals.busiestProject = projects.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        totals.folders = Array(Set(entries.compactMap(\.folder))).sorted()
        return totals
    }

    /// Every account's every transcript, subagents' included, with the name of the project folder
    /// it's in and whose it is; the first made, first (see `count`).
    private func transcripts() -> [(path: String, project: String, account: String)] {
        var found: [(path: String, project: String, account: String, born: Int)] = []
        for (account, root) in roots() {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { continue }
            let depth = root.pathComponents.count
            for case let url as URL in walker {
                if url.pathExtension == "jsonl" {
                    let components = url.pathComponents
                    guard components.count > depth + 1 else { continue }
                    var info = stat()
                    let born = stat(url.path, &info) == 0 ? info.st_birthtimespec.tv_sec : 0
                    found.append((url.path, Self.project(folder: components[depth]), account, born))
                } else if url.lastPathComponent == "tool-results" || url.lastPathComponent == "memory" {
                    walker.skipDescendants()
                }
            }
        }
        return found.sorted { $0.born < $1.born }.map { ($0.path, $0.project, $0.account) }
    }

    /// Claude Code names a project's folder after its path, slashes as dashes: "-Users-x-Foo".
    private static func project(folder: String) -> String {
        folder.split(separator: "-").last.map(String.init) ?? folder
    }

    /// Reads whatever was added to the file since last time and returns where to pick up next.
    private func follow(_ path: String, project: String, account: String, cutoff: Date) -> Position? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let size = UInt64(info.st_size), inode = UInt64(info.st_ino)
        var position: Position
        if let known = positions[path], known.inode == inode, known.offset <= size {
            position = known
        } else {
            // New to us, or shrunk or swapped for another file: start it over. One left alone since
            // before the days kept has nothing that counts, so only what's added from now on gets read.
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            position = Position(inode: inode, offset: modified < cutoff ? size : 0)
        }
        if size > position.offset {
            position.offset = read(path, from: position.offset, project: project, account: account, cutoff: cutoff)
        }
        return position
    }

    /// Takes in the whole lines from `offset` on, a megabyte at a time, and returns the offset
    /// after the last one. A line still being written is left for next time.
    private func read(_ path: String, from offset: UInt64, project: String, account: String, cutoff: Date) -> UInt64 {
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
                    let used = pending.withUnsafeBytes { take($0, project: project, account: account, cutoff: cutoff) }
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
    private func take(_ buffer: UnsafeRawBufferPointer, project: String, account: String, cutoff: Date) -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        var start = 0
        while start < buffer.count, let newline = memchr(base + start, 0x0A, buffer.count - start) {
            let end = base.distance(to: UnsafeRawPointer(newline))
            // Most lines are prompts, tool output and the like; only replies carry usage.
            if memmem(base + start, end - start, Self.marker, Self.marker.count) != nil {
                let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: end - start,
                                deallocator: .none)
                count(line, project: project, account: account, cutoff: cutoff)
            }
            start = end + 1
        }
        return start
    }

    private func count(_ data: Data, project: String, account: String, cutoff: Date) {
        guard let line = try? decoder.decode(Line.self, from: data), line.type == "assistant",
              let message = line.message, let usage = message.usage,
              let stamp = line.timestamp, let time = dates.date(from: stamp) ?? wholeSecondDates.date(from: stamp),
              time >= cutoff else { return }
        let output = usage.outputTokens ?? 0
        let input = usage.inputTokens ?? 0
        let writes = usage.cacheCreationInputTokens ?? 0
        let tokens = input + output + writes
        let cacheReads = usage.cacheReadInputTokens ?? 0
        guard tokens + cacheReads > 0 else { return }
        // The writes kept an hour cost more than those kept five minutes; any not broken down are
        // taken for five minutes'.
        let hour = min(usage.cacheCreation?.ephemeral1hInputTokens ?? 0, writes)
        let searches = Double(usage.serverToolUse?.webSearchRequests ?? 0) * ClaudePrice.perSearch
        let cost = message.model.flatMap(ClaudePrice.of(model:)).map {
            $0.cost(input: input, output: output, fiveMinuteWrites: writes - hour, hourWrites: hour, reads: cacheReads,
                    fast: usage.speed == "fast") + searches
        }
        // A reply is written out again as it streams in; count it once. And once only across the
        // accounts: one chat copied to the other (claude-swap does) is the same replies again,
        // counted for the account whose file of it was made first (they're read in that order).
        // shortcut: a chat swapped back and forth goes by its newest copy's age, if it ever matters
        // keep which account first saw each reply.
        if let id = message.id {
            let key = id + " " + (line.requestId ?? "")
            guard counted[key] == nil else { return }
            counted[key] = time
        }
        let folder = line.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
        entries.append(Entry(time: time, tokens: tokens, output: output, cacheReads: cacheReads,
                             project: folder.isEmpty || folder == "/" ? project : folder, account: account, cost: cost,
                             folder: line.cwd.flatMap { $0.hasPrefix("/") && $0 != "/" ? $0 : nil }))
    }
}

/// What a Claude model's tokens cost at Anthropic's API prices, in dollars a million tokens, as
/// its pricing page has them (November 2026). Cache writes are 1.25× the input price kept five
/// minutes and 2× kept an hour; cache reads 0.1× (0.05× on Claude Opus 5.5 and Sonnet 5.5,
/// 0.025× on Claude Fable and Mythos 5.1 and 5.2). Fast mode is twice the price, caching on top
/// of that; Claude Haiku 5.5 costs five times as much for a prompt over 100,000 tokens. Web
/// searches are $10 a thousand on top (fetching a page costs only its tokens). It's what
/// the same use would cost on the API: a subscription doesn't charge by the token.
struct ClaudePrice: Equatable, Sendable {
    let input: Double
    let output: Double
    /// Cache reads, as a fraction of the input price.
    var reads = 0.1
    /// A web search: $10 a thousand, whatever the model.
    static let perSearch = 0.01
    /// A prompt longer than this costs `longScale` times as much, all of it.
    var longPrompt: Int?
    var longScale = 1.0

    /// The price of the model `id` names, as a transcript has it ("claude-opus-5-5",
    /// "claude-sonnet-4-5-20250929", "claude-3-5-haiku-20241022", Bedrock's and Vertex's forms
    /// too). A version newer than any here is priced as the newest of its kind; nil for anything
    /// else (Claude Code's "<synthetic>", which has no usage anyway).
    static func of(model id: String) -> ClaudePrice? {
        let name = id.lowercased() as NSString
        let whole = NSRange(location: 0, length: name.length)
        var family: String, major: Int, minor: Int?
        if let match = current.firstMatch(in: name as String, range: whole) {
            family = name.substring(with: match.range(at: 1))
            major = Int(name.substring(with: match.range(at: 2))) ?? 0
            minor = match.range(at: 3).location == NSNotFound ? nil : Int(name.substring(with: match.range(at: 3)))
        } else if let match = older.firstMatch(in: name as String, range: whole) {
            major = Int(name.substring(with: match.range(at: 1))) ?? 0
            minor = match.range(at: 2).location == NSNotFound ? nil : Int(name.substring(with: match.range(at: 2)))
            family = name.substring(with: match.range(at: 3))
        } else {
            return nil
        }
        let version = major * 100 + (minor ?? 0)
        switch family {
        case "fable", "mythos":
            if version >= 502 || version < 500 { return ClaudePrice(input: 8, output: 40, reads: 0.025) }
            if version == 501 { return ClaudePrice(input: 10, output: 50, reads: 0.025) }
            return ClaudePrice(input: 10, output: 50)
        case "opus":
            if version >= 505 { return ClaudePrice(input: 4, output: 20, reads: 0.05) }
            if version >= 405 { return ClaudePrice(input: 5, output: 25) }
            return ClaudePrice(input: 15, output: 75)
        case "sonnet":
            if version >= 505 { return ClaudePrice(input: 2, output: 10, reads: 0.05) }
            if version >= 500 { return ClaudePrice(input: 2, output: 10) }
            return ClaudePrice(input: 3, output: 15)
        case "haiku":
            if version >= 505 { return ClaudePrice(input: 0.1, output: 0.5, longPrompt: 100_000, longScale: 5) }
            if version >= 405 { return ClaudePrice(input: 1, output: 5) }
            if version >= 305 { return ClaudePrice(input: 0.8, output: 4) }
            return ClaudePrice(input: 0.25, output: 1.25)
        default:
            return nil
        }
    }

    /// One reply's cost, in dollars.
    func cost(input: Int, output: Int, fiveMinuteWrites: Int, hourWrites: Int, reads cacheReads: Int, fast: Bool = false) -> Double {
        var scale = fast ? 2.0 : 1.0
        if let longPrompt, input + fiveMinuteWrites + hourWrites + cacheReads > longPrompt { scale *= longScale }
        let prompt = Double(input) + Double(fiveMinuteWrites) * 1.25 + Double(hourWrites) * 2 + Double(cacheReads) * reads
        return scale * (prompt * self.input + Double(output) * self.output) / 1_000_000
    }

    /// "claude-opus-5-5", "claude-haiku-4-5-20251001", "anthropic.claude-sonnet-4-6",
    /// "claude-opus-4-1@20250805": a digit, then one or two (a date's eight aren't a version, so
    /// "claude-3-5-sonnet-20241022" is left to the older form).
    private static let current = try! NSRegularExpression(pattern: #"(opus|sonnet|haiku|fable|mythos)-(\d)(?:-(\d{1,2}))?(?!\d)"#)
    /// The Claude 3 family's: "claude-3-7-sonnet-20250219", "claude-3-opus-20240229".
    private static let older = try! NSRegularExpression(pattern: #"claude-(\d)(?:-(\d))?-(opus|sonnet|haiku)"#)
}
