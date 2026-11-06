import AppKit
import CoreGraphics
import os

/// One thing you said you got done, for one project, in your own words.
struct LogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    /// The check-in it came from.
    let message: UUID
    /// The day it's for: its midnight (a check-in before four in the morning is for the day before).
    let day: Date
    let written: Date
    /// Its project's #tag, in lowercase, without the #.
    let tag: String
    let text: String
}

/// A check-in as it was typed, whole.
struct LogMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let written: Date
    let day: Date
    let text: String
}

/// A project: a #tag, and the log's tab for it.
struct LogProject: Codable, Identifiable, Equatable {
    var id: String { tag }
    let tag: String
    /// As it was first typed ("CS229" for #CS229).
    var name: String
    let started: Date
}

/// What the on-device model wrote, and a hash of what it wrote it from, so it's only written
/// again once that changes.
struct LogSynthesis: Codable, Equatable {
    var text: String
    var made: Date
    var from: UInt64
}

/// A check-in's message, taken apart into what it says for each project: each sentence (or line)
/// goes to the #tags it starts with, or has in it; one with none, to those of the one before it
/// (or, at the start, after it). "#tag:" starts a new part wherever it is. The #s come out of the
/// words: a tag a sentence starts or ends with goes, one in the middle stays as its word.
enum CheckInParser {
    struct Part: Equatable {
        var tag: String
        /// The tag as typed, for a new project's name.
        var name: String
        var text: String
    }

    /// A message with no tag at all goes here.
    static let general = (tag: "general", name: "General")

    /// "#oyl", "#CS229", "#side-project": a letter first, so "#3" and "C#" aren't tags.
    static let tagPattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_#&/])#(\p{L}(?:[\p{L}\p{N}_-]*[\p{L}\p{N}])?)"#)
    /// Words a tag at the end of a sentence is part of it after ("wrote the essay for #cs229"),
    /// so it stays.
    private static let connectors: Set<String> = ["a", "an", "the", "for", "in", "on", "to", "into", "onto", "with", "at", "of",
                                                  "about", "from", "and", "or", "my", "our", "your", "their", "his", "her", "its",
                                                  "this", "that", "by", "via", "using", "see"]
    private static let yesterdayPattern = try! NSRegularExpression(pattern: #"(?<!\S)/yesterday(?!\S)"#, options: [.caseInsensitive])

    /// `text` without any "/yesterday" in it, and whether there was one (it's for the day before).
    static func forYesterday(_ text: String) -> (text: String, yesterday: Bool) {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        guard yesterdayPattern.firstMatch(in: text, range: whole) != nil else { return (text, false) }
        return (yesterdayPattern.stringByReplacingMatches(in: text, range: whole, withTemplate: " "), true)
    }

    private struct Tag {
        let range: NSRange
        let key: String
        let name: String
    }

    private struct Unit {
        let text: String
        let line: Int
        var tags: [(key: String, name: String)]
    }

    static func parse(_ message: String) -> [Part] {
        var units: [Unit] = []
        for (number, line) in message.components(separatedBy: .newlines).enumerated() {
            for piece in sentences(in: line) {
                let (text, tags) = clean(piece)
                units.append(Unit(text: text, line: number, tags: tags))
            }
        }
        // Untagged sentences go with the ones before them, or at the start, the first tagged.
        var current = units.first { !$0.tags.isEmpty }?.tags ?? [(general.tag, general.name)]
        for index in units.indices {
            if units[index].tags.isEmpty { units[index].tags = current } else { current = units[index].tags }
        }
        // One run of sentences for the same tags is one part.
        var runs: [Unit] = []
        for unit in units where !unit.text.isEmpty {
            if let last = runs.last, last.tags.map(\.key) == unit.tags.map(\.key) {
                runs[runs.count - 1] = Unit(text: last.text + (last.line == unit.line ? " " : "\n") + unit.text, line: unit.line,
                                            tags: last.tags)
            } else {
                runs.append(unit)
            }
        }
        return runs.flatMap { run in run.tags.map { Part(tag: $0.key, name: $0.name, text: run.text) } }
    }

    /// The tags in `text`, in order, each once.
    static func tags(in text: String) -> [(key: String, name: String)] {
        var seen = Set<String>()
        return found(in: text).compactMap { seen.insert($0.key).inserted ? ($0.key, $0.name) : nil }
    }

    private static func found(in text: String) -> [Tag] {
        let source = text as NSString
        return tagPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard match.range(at: 1).location != NSNotFound else { return nil }
            let name = source.substring(with: match.range(at: 1))
            return Tag(range: match.range, key: name.lowercased(), name: name)
        }
    }

    /// Where a sentence ends: a full stop (or ! ? ;) and a space. (Cutting too often does no harm:
    /// sentences for the same tags are run back together.)
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"(?<=[.!?;…])\s+"#)

    /// A line's sentences, and a new one at each "#tag:".
    private static func sentences(in line: String) -> [String] {
        let source = line as NSString
        var pieces: [String] = [], at = 0
        for match in sentenceEnd.matches(in: line, range: NSRange(location: 0, length: source.length)) {
            pieces.append(source.substring(with: NSRange(location: at, length: match.range.location - at)))
            at = match.range.location + match.range.length
        }
        pieces.append(source.substring(from: at))
        return pieces.flatMap { piece -> [String] in
            let source = piece as NSString
            let starts = found(in: piece).map(\.range).filter { range in
                let after = range.location + range.length
                return range.location > 0 && after < source.length && source.character(at: after) == UInt16(UInt8(ascii: ":"))
            }
            var cuts = [0] + starts.map(\.location) + [source.length]
            cuts = Array(Set(cuts)).sorted()
            return zip(cuts, cuts.dropFirst()).map { source.substring(with: NSRange(location: $0, length: $1 - $0)) }
        }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A sentence's words without the tags it starts or ends with (or the #s of those in the
    /// middle), and its tags.
    private static func clean(_ piece: String) -> (String, [(key: String, name: String)]) {
        let source = piece as NSString
        let tags = found(in: piece)
        guard !tags.isEmpty else { return (tidy(piece), []) }
        // Where the words start: past the tags (and commas, colons and dashes) at the front.
        let gap = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",:;–—-"))
        func isGap(_ range: NSRange) -> Bool {
            source.substring(with: range).unicodeScalars.allSatisfy { gap.contains($0) }
        }
        var start = 0
        var leading = Set<Int>()
        for (index, tag) in tags.enumerated() {
            guard isGap(NSRange(location: start, length: tag.range.location - start)) else { break }
            leading.insert(index)
            start = tag.range.location + tag.range.length
        }
        // And where they end: before the tags at the back (but not its full stop).
        let ending = CharacterSet(charactersIn: ".!?…)\"”'’")
        var end = source.length
        while end > start, let scalar = UnicodeScalar(source.character(at: end - 1)),
              ending.contains(scalar) || CharacterSet.whitespaces.contains(scalar) { end -= 1 }
        let stop = source.substring(with: NSRange(location: end, length: source.length - end))
            .trimmingCharacters(in: .whitespaces)
        var trailing = Set<Int>()
        var back = end
        for (index, tag) in tags.enumerated().reversed() where !leading.contains(index) {
            guard tag.range.location + tag.range.length <= back,
                  isGap(NSRange(location: tag.range.location + tag.range.length, length: back - tag.range.location - tag.range.length))
            else { break }
            trailing.insert(index)
            back = tag.range.location
        }
        // Unless they're what the sentence is about: after "for", "in", "(" and the like.
        let before = source.substring(with: NSRange(location: start, length: max(back - start, 0)))
            .trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty, before.hasSuffix("(") || connectors.contains(before.split(separator: " ").last.map { $0.lowercased() } ?? "") {
            trailing = []
            back = end
        }
        var words = ""
        var at = start
        for (index, tag) in tags.enumerated() where !leading.contains(index) && !trailing.contains(index) {
            words += source.substring(with: NSRange(location: at, length: tag.range.location - at)) + tag.name
            at = tag.range.location + tag.range.length
        }
        words += source.substring(with: NSRange(location: at, length: max(back - at, 0)))
        let trimmed = words.trimmingCharacters(in: gap.union(.whitespacesAndNewlines))
        var seen = Set<String>()
        let keys = tags.compactMap { seen.insert($0.key).inserted ? (key: $0.key, name: $0.name) : nil }
        return (trimmed.isEmpty ? "" : tidy(trimmed + stop), keys)
    }

    private static func tidy(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}

/// Writes the log's syntheses: a month of a project's days told as one story, and the story of
/// the whole project from its months. (Apple's on-device model, in `LogWriter`; something made
/// up, in a test.)
protocol LogWriting: Sendable {
    var isAvailable: Bool { get }
    /// How much (in characters) can go in at once.
    var budget: Int { get }
    /// `days` ("Tue, Nov 3: …"), as one paragraph, carrying on from `earlier` (the same month's
    /// days before these, already told) if there is one.
    func chapter(project: String, month: String, days: [String], earlier: String?) async -> String?
    /// The story so far, from `chapters` ("November 2026: …"), carrying on from `earlier`.
    func story(project: String, chapters: [String], earlier: String?) async -> String?
}

/// Your daily check-ins, each part filed under its project's #tag: the log Oyl keeps of your
/// work, in your own words, with a story for each project written on the Mac to tie its days
/// together (see `LogWriter`), and a document of it all, a tab to a project (see `WorkLogDoc`).
/// Once a day, at the hour you've set, the notch asks what you got done, until you've said, put
/// it off, or said not today.
@MainActor
final class WorkLog: ObservableObject {
    struct Saved: Codable, Equatable {
        var messages: [LogMessage] = []
        var entries: [LogEntry] = []
        var projects: [LogProject] = []
        /// By "tag 2026-11".
        var chapters: [String: LogSynthesis] = [:]
        /// By tag.
        var stories: [String: LogSynthesis] = [:]
        /// A day it was told not today.
        var skipped: Date?
    }

    @Published private(set) var saved: Saved
    /// It's past the hour and you haven't checked in: the notch asks.
    @Published private(set) var reminding = false
    /// The project whose story's being written, while one is.
    @Published private(set) var writing: String?
    /// The hour (0–23) the notch asks at. Remembered.
    @Published var hour: Int {
        didSet {
            store.set(hour, forKey: "log.hour")
            check()
        }
    }
    /// The look the document's in.
    var look: NotchTheme = .standard {
        didSet { if look != oldValue { writeDoc() } }
    }

    nonisolated static let log = Logger(subsystem: "Oyl", category: "worklog")
    /// The hours it can ask at, from the afternoon round to the small hours.
    static let hours = Array(16...23)
    /// When the log's day turns: four in the morning.
    nonisolated static let turn: TimeInterval = 4 * 3600
    /// Put off, it asks again in an hour.
    static let later: TimeInterval = 3600

    /// Where it keeps what you've said.
    let file: URL
    /// Where the document goes, and where it went if that couldn't be written.
    let docFolder: URL
    let fallbackFolder: URL
    private let writer: LogWriting?
    private let store: UserDefaults
    let calendar: Calendar
    private var snoozedUntil: Date?
    private var clock: Timer?
    private var synthesizing: Task<Void, Never>?
    private var again = false
    /// Where the document is, once it's been written.
    @Published private(set) var docURL: URL?

    nonisolated static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Oyl/Work Log.json")
    }
    nonisolated static var defaultDocFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Oyl Work Log", isDirectory: true)
    }

    init(file: URL = WorkLog.defaultFile, docFolder: URL = WorkLog.defaultDocFolder, writer: LogWriting? = WorkLog.onDevice,
         store: UserDefaults = .standard, calendar: Calendar = .current, ticking: Bool = true) {
        self.file = file
        self.docFolder = docFolder
        fallbackFolder = file.deletingLastPathComponent().appendingPathComponent("Work Log", isDirectory: true)
        self.writer = writer
        self.store = store
        self.calendar = calendar
        hour = (store.object(forKey: "log.hour") as? Int).flatMap { Self.hours.contains($0) ? $0 : nil } ?? 21
        saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.workLog.decode(Saved.self, from: $0) } ?? Saved()
        let doc = [docFolder, fallbackFolder].map { $0.appendingPathComponent(WorkLogDoc.htmlName) }
        docURL = doc.first { FileManager.default.fileExists(atPath: $0.path) }
        guard ticking else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.check()
                // Anything left unwritten when Oyl last quit.
                self?.synthesizeSoon()
            }
        }
    }

    /// Apple's on-device model, where this Mac has it.
    nonisolated static var onDevice: LogWriting? {
        if #available(macOS 26, *) { return LogWriter() }
        return nil
    }

    // MARK: Checking in

    /// The log's day for `date`: its midnight, the day turning at four in the morning.
    func day(of date: Date) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(-Self.turn))
    }

    /// Files a check-in, each part under its project, and sets about the stories. "/yesterday"
    /// anywhere in it makes it the day before's. Returns what it filed (nothing, for nothing).
    @discardableResult
    func checkIn(_ text: String, at now: Date = Date()) -> [LogEntry] {
        let (words, yesterday) = CheckInParser.forYesterday(text)
        let parts = CheckInParser.parse(words)
        guard !parts.isEmpty else { return [] }
        var day = day(of: now)
        if yesterday { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        let message = LogMessage(id: UUID(), written: now, day: day, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        saved.messages.append(message)
        let entries = parts.map { LogEntry(id: UUID(), message: message.id, day: day, written: now, tag: $0.tag, text: $0.text) }
        saved.entries += entries
        for part in parts where !saved.projects.contains(where: { $0.tag == part.tag }) {
            saved.projects.append(LogProject(tag: part.tag, name: part.name, started: now))
        }
        changed()
        check(at: now)
        return entries
    }

    /// Takes an entry back out (a slip, or the wrong tag); a project with none left goes too.
    func remove(_ id: UUID) {
        guard let entry = saved.entries.first(where: { $0.id == id }) else { return }
        saved.entries.removeAll { $0.id == id }
        if !saved.entries.contains(where: { $0.message == entry.message }) { saved.messages.removeAll { $0.id == entry.message } }
        let tags = Set(saved.entries.map(\.tag))
        saved.projects.removeAll { !tags.contains($0.tag) }
        changed()
        check()
    }

    /// Asked, and put off for an hour (or, opening the page to answer, in case it's left).
    func putOff(at now: Date = Date()) {
        snoozedUntil = now.addingTimeInterval(Self.later)
        reminding = false
    }

    /// Not today: it doesn't ask again till tomorrow.
    func skipToday(at now: Date = Date()) {
        saved.skipped = day(of: now)
        save()
        reminding = false
    }

    /// Whether there's a check-in for the day `date` is in.
    func hasCheckedIn(at date: Date = Date()) -> Bool {
        let day = day(of: date)
        return saved.messages.contains { $0.day == day }
    }

    /// The time it asks, on the log's day for `date`.
    func askingTime(at date: Date) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day(of: date)) ?? date
    }

    /// Whether it'd ask now: on, past the hour, not checked in, put off or skipped.
    func isDue(at now: Date) -> Bool {
        guard Feature.checkIn.isOn, Feature.logPage.isOn, now >= askingTime(at: now) else { return false }
        if hasCheckedIn(at: now) || saved.skipped == day(of: now) { return false }
        return snoozedUntil.map { now >= $0 } ?? true
    }

    /// Asks (while you're at the Mac), or stops asking.
    func check(at now: Date = Date()) {
        let due = isDue(at: now)
        if !due {
            if reminding { reminding = false }
            return
        }
        if !reminding, Self.isUp { reminding = true }
    }

    /// Someone's at the Mac: it's been touched in the last five minutes.
    private static var isUp: Bool {
        let kinds: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
        let idle = kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
        return idle < 5 * 60
    }

    // MARK: What's there

    /// Projects, the latest worked on first.
    var projects: [LogProject] {
        let last = Dictionary(saved.entries.map { ($0.tag, $0.written) }, uniquingKeysWith: max)
        return saved.projects.sorted { (last[$0.tag] ?? $0.started) > (last[$1.tag] ?? $1.started) }
    }

    func project(_ tag: String) -> LogProject? { saved.projects.first { $0.tag == tag } }

    /// How many days a project has been worked on.
    func days(of tag: String) -> Int { Set(saved.entries.filter { $0.tag == tag }.map(\.day)).count }

    /// What's been filed for the day `date` is in, in order.
    func entries(on date: Date = Date()) -> [LogEntry] {
        let day = day(of: date)
        return saved.entries.filter { $0.day == day }
    }

    /// A tag that starts with what's been typed of one (the latest worked on, of those that do).
    func completion(of prefix: String) -> LogProject? {
        let typed = prefix.lowercased()
        guard !typed.isEmpty else { return nil }
        return projects.first { $0.tag.hasPrefix(typed) && $0.tag != typed }
    }

    // MARK: The stories

    /// A project's months ("2026-11"), oldest first.
    func months(of tag: String) -> [String] {
        Array(Set(saved.entries.filter { $0.tag == tag }.map { month(of: $0.day) })).sorted()
    }

    func month(of day: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: day)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// A month's days as they go in: "Tue, Nov 3: …", a day's entries run together.
    func dayLines(of tag: String, month: String) -> [String] {
        let entries = saved.entries.filter { $0.tag == tag && self.month(of: $0.day) == month }
        let days = Dictionary(grouping: entries, by: \.day).sorted { $0.key < $1.key }
        return days.map { day, entries in
            WorkLogDoc.dayTitle(day, calendar: calendar) + ": " + entries.map(\.text).joined(separator: " ")
        }
    }

    /// The month's name, "November 2026".
    func monthTitle(_ month: String) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) else { return month }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "LLLL yyyy"
        return format.string(from: date)
    }

    static func chapterKey(_ tag: String, _ month: String) -> String { "\(tag) \(month)" }

    /// What a chapter's made from, its hash.
    func chapterSource(_ tag: String, _ month: String) -> UInt64 {
        Self.hash([tag, month] + dayLines(of: tag, month: month))
    }

    /// What a story's made from: its chapters, as they are.
    func storyLines(of tag: String) -> [String] {
        months(of: tag).compactMap { month in
            saved.chapters[Self.chapterKey(tag, month)].map { monthTitle(month) + ": " + $0.text }
        }
    }

    /// Whatever's out of date, written again, one at a time, the latest worked on first; the
    /// document's written as each is done (and at once, for the words just filed).
    func synthesizeSoon() {
        guard let writer, writer.isAvailable else { return }
        if synthesizing != nil {
            again = true
            return
        }
        synthesizing = Task { [weak self] in
            while let self {
                self.again = false
                await self.synthesizeAll(with: writer)
                if !self.again { break }
            }
            self?.writing = nil
            self?.synthesizing = nil
        }
    }

    /// Waits for the stories being written (for a test).
    func finishWriting() async {
        while let task = synthesizing { await task.value }
    }

    private func synthesizeAll(with writer: LogWriting) async {
        for project in projects {
            let tag = project.tag
            for month in months(of: tag) {
                let key = Self.chapterKey(tag, month), source = chapterSource(tag, month)
                guard saved.chapters[key]?.from != source else { continue }
                writing = tag
                guard let text = await Self.told(dayLines(of: tag, month: month), budget: writer.budget, by: { days, earlier in
                    await writer.chapter(project: project.name, month: self.monthTitle(month), days: days, earlier: earlier)
                }) else { continue }
                // Changed meanwhile: it'll be written again.
                guard chapterSource(tag, month) == source else { continue }
                saved.chapters[key] = LogSynthesis(text: text, made: Date(), from: source)
                save()
                writeDoc()
            }
            let lines = storyLines(of: tag), source = Self.hash([tag] + lines)
            guard !lines.isEmpty, saved.stories[tag]?.from != source else { continue }
            writing = tag
            guard let text = await Self.told(lines, budget: writer.budget, by: { chapters, earlier in
                await writer.story(project: project.name, chapters: chapters, earlier: earlier)
            }), Self.hash([tag] + storyLines(of: tag)) == source else { continue }
            saved.stories[tag] = LogSynthesis(text: text, made: Date(), from: source)
            save()
            writeDoc()
        }
        writing = nil
    }

    /// `lines` told in as few goes as fit in `budget`, each carrying on from the last.
    static func told(_ lines: [String], budget: Int,
                     by write: ([String], String?) async -> String?) async -> String? {
        var earlier: String?
        for chunk in chunks(lines, budget: budget) {
            guard let told = await write(chunk, earlier) else { return nil }
            earlier = told
        }
        return earlier
    }

    /// `lines` in runs of at most `budget` characters (one that's longer, cut down to it).
    static func chunks(_ lines: [String], budget: Int) -> [[String]] {
        var chunks: [[String]] = [], current: [String] = [], size = 0
        for line in lines {
            let line = line.count > budget ? String(line.prefix(budget)) + "…" : line
            if size + line.count > budget, !current.isEmpty {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// FNV-1a, so it's the same from launch to launch (Swift's own hashes aren't).
    nonisolated static func hash(_ parts: [String]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\u{1F}").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: Keeping it

    private func changed() {
        // Stories of what's gone go too.
        let tags = Set(saved.entries.map(\.tag))
        let months = Set(saved.entries.map { Self.chapterKey($0.tag, month(of: $0.day)) })
        saved.chapters = saved.chapters.filter { months.contains($0.key) }
        saved.stories = saved.stories.filter { tags.contains($0.key) }
        save()
        writeDoc()
        synthesizeSoon()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.workLog.encode(saved).write(to: file, options: .atomic)
        } catch {
            Self.log.error("Couldn't keep the log: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The document, as it stands, into its folder in Documents (or, if that can't be written,
    /// Oyl's own); off the main thread, since the first time may ask for Documents.
    func writeDoc(now: Date = Date()) {
        let doc = WorkLogDoc(log: self, now: now)
        let html = doc.html(look: look), markdown = doc.markdown()
        let folders = [docFolder, fallbackFolder]
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let written = WorkLogDoc.write(html: html, markdown: markdown, into: folders)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let written, self?.docURL != written { self?.docURL = written }
                }
            }
        }
    }

    /// The document, at `tag`'s tab (or the overview), in the browser.
    func openDoc(at tag: String? = nil) {
        guard let docURL else {
            writeDoc()
            return
        }
        var parts = URLComponents(url: docURL, resolvingAgainstBaseURL: false)
        parts?.fragment = tag
        NSWorkspace.shared.open(parts?.url ?? docURL)
    }

    func revealDoc() {
        guard let docURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([docURL])
    }
}

extension JSONEncoder {
    static var workLog: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var workLog: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
