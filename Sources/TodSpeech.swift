import Foundation

/// One to-do heard in what was said.
struct SpokenTask: Equatable {
    var title: String            // lowercase, as the user writes them; never empty
    var due: String?             // "YYYY-MM-DD"
    var time: String?            // "HH:MM"
    var listId: String?          // the tod list it was filed in: named, tagged or clearly meant
    var newList: String?         // a #tag that names no list yet (the caller makes it), as said
    var repeats: TodRepeat?
    var heard: String            // the stretch of speech it came from, as heard
    /// What each reading made of it, quoting what was heard: "“next weekend night” → sat nov 7,
    /// 8 pm", "“for cs” → 💻 cs 106b", "“someday” → no date". They go into the calendar event's
    /// explanation, so dates are spelled out rather than "tomorrow".
    var reasons: [String]
}

/// What was said to the to-do list, read as to-dos. Speech runs on, so "remind me to do laundry
/// next weekend night and also cs assignment 5 due friday" is two tasks: laundry on Sat Nov 7 at
/// 8 PM, and the assignment in 💻 cs 106b, due Friday. Dates and times go through tod's own
/// grammar (`TodQuick`), so a task said means what it would typed, plus what people say but don't
/// type: times of day ("tonight"), far-off dates ("by january"), "someday" for no date at all,
/// and repeats ("every sunday").
enum TodSpeech {
    /// The to-dos in a transcript, in the order they were said. `lists` are tod's (a list named or
    /// tagged is filed into; the Inbox gets the rest, by the caller); `weekStart` is tod's setting
    /// (1: Monday), for "next week" and "end of the week".
    static func tasks(from transcript: String, lists: [(id: String, name: String)], now: Date = Date(),
                      weekStart: Int = 1) -> [SpokenTask] {
        let clock = Clock(now: now, weekStart: weekStart)
        let known = Known.all(lists)
        var tasks: [SpokenTask] = []
        var lastMade = 0    // how many tasks the last stretch made
        // A stretch with nothing to do in it, only a when or a where ("for treehacks:", "tomorrow."),
        // sets it for the ones that follow. Said last, it's an afterthought for the task(s) before
        // ("vc packet. for treehacks."), and if neither takes it, it's a task of its own after all.
        var header: (task: SpokenTask, notes: [Note], at: Int, used: Bool)?
        // A word or few before a colon, and nothing else ("idea:", "groceries:"), labels the task
        // said after it: "idea: a wallpaper series". With nothing after, it's a task itself.
        var label: SpokenTask?
        func add(_ made: [SpokenTask]) {
            tasks += made
            lastMade = made.count
        }
        func keepLabel() {
            if let pending = label { add([pending]) }
            label = nil
        }
        func keepUnused() {
            guard let unused = header, !unused.used else { return }
            if unused.at > 0, unused.at == tasks.count {
                var lent = false
                for k in (unused.at - lastMade)..<unused.at {
                    if lend(unused.task, unused.notes, to: &tasks[k]) { lent = true }
                }
                if lent { return }
            }
            tasks.insert(unused.task, at: unused.at)
            if unused.at == tasks.count - 1 { lastMade = 1 }
        }
        for (stretch, beforeColon) in stretches(of: transcript) {
            var reading = Reading(stretch, clock: clock, lists: known)
            reading.read()
            guard reading.saysAnything else { continue }
            let title = reading.title()
            if title.isEmpty {
                keepLabel()
                // Headers in a row add up: "tomorrow. for treehacks. vc packet."
                let read = reading.task(title: fallback(stretch), under: header.map { ($0.task, $0.notes) })
                if read.inherited { header?.used = true }
                keepUnused()
                header = (read.task, read.notes, tasks.count, false)
                continue
            }
            var made: [SpokenTask] = []
            for one in reading.eachDay() {
                let read = one.task(title: title, under: header.map { ($0.task, $0.notes) })
                made.append(read.task)
                if read.inherited { header?.used = true }
            }
            if beforeColon, reading.readNothing, title.split(separator: " ").count <= 3 {
                keepLabel()
                label = made[0]
                continue
            }
            if let pending = label {
                for k in made.indices {
                    made[k].title = pending.title + ": " + made[k].title
                    made[k].heard = pending.heard + ": " + made[k].heard
                }
                label = nil
            }
            add(made)
        }
        keepLabel()
        keepUnused()
        return tasks
    }

    /// Gives a task what an afterthought says, if the task said none of it itself.
    private static func lend(_ header: SpokenTask, _ notes: [Note], to task: inout SpokenTask) -> Bool {
        let hasList = header.listId != nil || header.newList != nil
        let hasDay = header.due != nil
        let noDay = !hasDay && notes.contains { $0.kind == .undated }
        let saysDay = task.due != nil || task.repeats != nil || task.reasons.contains { $0.contains("→ no date") }
        guard hasList || hasDay || noDay, !(hasList && (task.listId != nil || task.newList != nil)),
              !((hasDay || noDay) && saysDay) else { return false }
        if hasList {
            task.listId = header.listId
            task.newList = header.newList
        }
        if hasDay {
            task.due = header.due
            task.time = header.time
            task.repeats = header.repeats
        }
        task.reasons += notes.map(\.text)
        return true
    }

    /// What's left of a stretch that's nothing but a date or a list: the words as heard.
    private static func fallback(_ heard: String) -> String {
        heard.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: stops)
    }

    // MARK: - stretches

    /// What was said, cut into the stretches that are each one to-do: sentences, cut again where
    /// a new one clearly starts ("and also", "then", "and remind me to"), but not at a plain "and"
    /// ("buy eggs and milk"); each with whether it ended at a colon ("idea: …").
    private static func stretches(of transcript: String) -> [(text: String, beforeColon: Bool)] {
        var text = transcript.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "\n", with: ". ")
        // "5 p.m. Then…" ends a sentence at the time; "5 p.m. tomorrow" doesn't.
        text = replacing(meridiemThenSentence, in: text, with: "$1m.$2")
        text = replacing(dottedMeridiem, in: text, with: "$1m")
        // Spelled out: "P.W.R." and "P W R" are "PWR".
        text = squeeze(dottedLetters, in: text) { $0.replacingOccurrences(of: ".", with: "") }
        text = squeeze(spacedCapitals, in: text) { $0.replacingOccurrences(of: " ", with: "") }

        var pieces: [(String, Bool)] = []
        for (sentence, colon) in sentences(of: text) {
            let ns = sentence as NSString
            var start = 0
            let cuts = boundaries.flatMap { $0.matches(in: sentence, range: whole(sentence)) }
                .sorted { $0.range.location < $1.range.location }
            for match in cuts where match.range.location >= start && isBoundary(match, in: ns) {
                let piece = ns.substring(with: NSRange(location: start, length: match.range.location - start))
                // "Oil, remind me to…": Oyl's name goes with what's said to it, as its lead-in.
                if address.firstMatch(in: piece, range: whole(piece)) != nil { continue }
                pieces.append((piece, false))
                start = match.range.location + match.range.length
            }
            pieces.append((ns.substring(from: start), colon))
        }
        return pieces.map { ($0.0.trimmingCharacters(in: stops), $0.1) }.filter { !$0.0.isEmpty }
    }

    private static func sentences(of text: String) -> [(text: String, colon: Bool)] {
        let ns = text as NSString
        var result: [(String, Bool)] = []
        var start = 0
        for match in sentenceEnd.matches(in: text, range: whole(text)) {
            let end = ns.substring(with: match.range)
            let before = ns.substring(to: match.range.location)
            let lastWord = before.split(whereSeparator: { $0 == " " }).last.map { $0.lowercased() } ?? ""
            if end.hasPrefix("."), abbreviations.contains(lastWord) { continue }
            result.append((ns.substring(with: NSRange(location: start, length: match.range.location - start)), end == ":"))
            start = match.range.location + match.range.length
        }
        result.append((ns.substring(from: start), false))
        return result
    }

    /// Whether a connective really starts a new to-do: "then" isn't one in "by then", "plus" isn't
    /// in "a plus" or "c plus plus", and "also" isn't in "i also need to" (that's one lead-in).
    private static func isBoundary(_ match: NSTextCheckingResult, in sentence: NSString) -> Bool {
        let word = sentence.substring(with: match.range(at: 2)).lowercased()
        let before = sentence.substring(to: match.range.location).lowercased()
            .split(whereSeparator: { $0 == " " }).last.map { String($0).trimmingCharacters(in: stops) }
        let after = sentence.substring(from: match.range.location + match.range.length).lowercased()
            .split(whereSeparator: { $0 == " " }).first.map { String($0).trimmingCharacters(in: stops) }
        let commaBefore = sentence.substring(with: match.range).hasPrefix(",")
        let andBefore = match.range(at: 1).location != NSNotFound
        if after == nil && !word.hasPrefix("another") { return false }
        switch word {
        case "also":
            return commaBefore || andBefore || !["i", "we", "you", "to", "can", "could", "would", "will", "should", "i'll",
                                                "i'd", "i'm", "we'll", "me", "please", "must", "gotta", "and"].contains(before ?? "")
        case "then":
            return andBefore || commaBefore || !["by", "until", "till", "since", "before", "from", "than", "after", "just",
                                                "back", "now", "and"].contains(before ?? "")
        case "plus":
            return after != "plus" && before != "plus" && (before.map { $0.count > 1 } ?? true) && !plusWords.contains(after ?? "")
        default:
            return true
        }
    }

    // MARK: - one stretch

    /// What a word was read as, once it's out of the title.
    fileprivate enum Use { case filler, list, date, repeats, undated }

    fileprivate struct Word {
        var said: String     // as heard, punctuation and all
        var text: String     // lowercase, what's matched ("five thirty" → "5:30")
        var use: Use?        // nil while it's part of the title
    }

    /// A pattern's match among the words still unread.
    fileprivate struct Hit {
        let groups: [String?]
        let words: [Int]
        let before: String?   // the unread word just before, bare
        let after: String?    // and just after
        let closed: Bool      // nothing follows it in the same breath
        func group(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
        /// Nothing follows, or only something that isn't more of the same noun ("for stack", "for
        /// stack by friday", but not "mint gum").
        var free: Bool { closed || after.map(TodSpeech.isFree) ?? true }
    }

    fileprivate struct Note {
        enum Kind { case list, date, repeats, undated }
        let kind: Kind
        let at: Int
        let text: String
    }

    /// Spoken times of day: "in the morning" (9 AM), "tonight" (8 PM, and today), and when each is
    /// over, past which "in the morning" means tomorrow's.
    fileprivate struct Period {
        let hour: Int
        let ends: Int          // minutes into the day
        let today: Bool        // said as today's: "tonight", "this morning"
        let meridiem: String?  // what an hour said with it means: "at 8 tonight" is 8 PM
    }

    fileprivate struct Rhythm {
        let kind: TodRepeat
        var weekday: Int?      // 0 is Sunday
        var monthDay: Int?     // 0 for the last day
        var period: Period?
        /// More days it's on ("every tuesday and friday"): tod repeats on one, so each is a task.
        var others: [Int] = []
    }

    /// One stretch of speech, read into a task: its words are taken out of the title as they're
    /// read as filler, a list, a date or a repeat.
    fileprivate struct Reading {
        var words: [Word]
        let heard: String
        let clock: Clock
        let lists: [Known]

        var list: (id: String?, new: String?)?
        var rhythm: Rhythm?
        var period: Period?
        var horizon: String?      // "by january", "end of the week"
        var soon = false          // "asap", "now"
        var todDue: String?       // nil if tod only read a time
        var todTime: String?
        var undated = false
        var notes: [Note] = []

        init(_ heard: String, clock: Clock, lists: [Known]) {
            self.heard = heard
            self.clock = clock
            self.lists = lists
            words = heard.split(whereSeparator: { $0 == " " || $0 == "\t" }).map {
                Word(said: String($0), text: String($0).lowercased(), use: nil)
            }
        }

        var saysAnything: Bool {
            words.contains { $0.use != .filler } || list != nil || rhythm != nil
        }

        /// Nothing read but the title: no list, date, repeat or "no date".
        var readNothing: Bool {
            list == nil && rhythm == nil && period == nil && horizon == nil && !soon && todDue == nil && todTime == nil && !undated
        }

        /// The reading once for each day of a repeat said on several ("every tuesday and friday").
        func eachDay() -> [Reading] {
            guard let rhythm, !rhythm.others.isEmpty else { return [self] }
            return ([rhythm.weekday] + rhythm.others.map(Optional.some)).map { day in
                var one = self
                one.rhythm?.weekday = day
                one.rhythm?.others = []
                return one
            }
        }

        mutating func read() {
            rewrite()
            takeAll(TodSpeech.hesitation, as: .filler)
            dropAddCommand(asked: dropLeadIns())
            readTags()
            if take(TodSpeech.genericList, as: .filler) != nil { dropAddVerb() }
            readRhythm()
            readHorizon()
            readSoon()
            readPeriod()
            readListPhrase()
            readTod()
            readOrdinalDay()
            takeDangling()
            readUndated()
            dropLeadIns()
            if list == nil { readImplicitList() }
        }

        // MARK: words

        /// The words still unread, as one line, and where each sits in it.
        func line() -> (text: String, spans: [(range: NSRange, word: Int)]) {
            var text = ""
            var spans: [(NSRange, Int)] = []
            for (i, word) in words.enumerated() where word.use == nil && !word.text.isEmpty {
                if !text.isEmpty { text += " " }
                let start = (text as NSString).length
                text += word.text
                spans.append((NSRange(location: start, length: (word.text as NSString).length), i))
            }
            return (text, spans)
        }

        /// The first match of `pattern` among the unread words that `accept` agrees to; its words
        /// are marked as `use`.
        @discardableResult
        mutating func take(_ pattern: NSRegularExpression, as use: Use, where accept: (Hit) -> Bool = { _ in true }) -> Hit? {
            let (text, spans) = line()
            let ns = text as NSString
            for match in pattern.matches(in: text, range: whole(text)) {
                let covered = spans.indices.filter { NSIntersectionRange(spans[$0].range, match.range).length > 0 }
                guard let first = covered.first, let last = covered.last else { continue }
                let groups = (0..<match.numberOfRanges).map {
                    match.range(at: $0).location == NSNotFound ? nil : ns.substring(with: match.range(at: $0))
                }
                let lastText = words[spans[last].word].text
                let hit = Hit(groups: groups, words: covered.map { spans[$0].word },
                              before: first > 0 ? bare(words[spans[first - 1].word].text) : nil,
                              after: last + 1 < spans.count ? bare(words[spans[last + 1].word].text) : nil,
                              closed: last + 1 == spans.count || endsBreath(lastText))
                if accept(hit) {
                    for i in hit.words { words[i].use = use }
                    return hit
                }
            }
            return nil
        }

        /// Every match of `pattern` among the unread words, in one go ("um" said a hundred times).
        mutating func takeAll(_ pattern: NSRegularExpression, as use: Use) {
            let (text, spans) = line()
            var k = 0
            for match in pattern.matches(in: text, range: whole(text)) {
                while k < spans.count, NSMaxRange(spans[k].range) <= match.range.location { k += 1 }
                var j = k
                while j < spans.count, spans[j].range.location < NSMaxRange(match.range) {
                    words[spans[j].word].use = use
                    j += 1
                }
            }
        }

        /// Spoken numbers where they're times or counts tod reads ("at five thirty" → "at 5:30",
        /// "in a couple of days" → "in 2 days"), each rewrite merged into one word. Only whole
        /// words are rewritten, so the "by 11" of "by 11:59" or "by 11/1" is left for tod.
        mutating func rewrite() {
            for (pattern, make) in TodSpeech.rewrites {
                var changed = true
                while changed {
                    changed = false
                    let (text, spans) = line()
                    let ns = text as NSString
                    // From the end, so the words before each match stay where they are.
                    for match in pattern.matches(in: text, range: whole(text)).reversed() {
                        let covered = spans.indices.filter { NSIntersectionRange(spans[$0].range, match.range).length > 0 }
                        guard let first = covered.first, let last = covered.last,
                              TodSpeech.onlyPunctuation(ns, from: spans[first].range.location, to: match.range.location),
                              TodSpeech.onlyPunctuation(ns, from: NSMaxRange(match.range), to: NSMaxRange(spans[last].range))
                        else { continue }
                        let indices = covered.map { spans[$0].word }
                        let groups = (0..<match.numberOfRanges).map {
                            match.range(at: $0).location == NSNotFound ? nil : ns.substring(with: match.range(at: $0))
                        }
                        let after = last + 1 < spans.count ? bare(words[spans[last + 1].word].text) : nil
                        let closed = after == nil || endsBreath(words[indices.last!].text)
                        guard let replacement = make(groups, closed ? nil : after),
                              replacement != indices.map({ words[$0].text }).joined(separator: " ") else { continue }
                        let tail = String(words[indices.last!].text.reversed().prefix { ",;:.!?".contains($0) }.reversed())
                        words[indices[0]] = Word(said: indices.map { words[$0].said }.joined(separator: " "),
                                                 text: replacement + tail, use: nil)
                        for i in indices.dropFirst().reversed() { words.remove(at: i) }
                        changed = true
                    }
                }
            }
        }

        /// The words, as heard, lowercase and without the punctuation around them.
        func said(_ indices: [Int]) -> String {
            indices.sorted().map { words[$0].said }.joined(separator: " ").lowercased()
                .replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: TodSpeech.stops)
        }

        /// A quote of the words, with "…" where others came between: “tomorrow … at 5”.
        func quote(_ indices: [Int]) -> String {
            var runs: [[Int]] = []
            for i in indices.sorted() {
                if let last = runs.last?.last, last + 1 == i {
                    runs[runs.count - 1].append(i)
                } else {
                    runs.append([i])
                }
            }
            return "“" + runs.map(said).joined(separator: " … ") + "”"
        }

        mutating func note(_ kind: Note.Kind, _ indices: [Int], _ text: String) {
            notes.append(Note(kind: kind, at: indices.min() ?? 0, text: quote(indices) + " → " + text))
        }

        func unread() -> [Int] { words.indices.filter { words[$0].use == nil } }

        // MARK: filler

        /// "Remind me to", "okay so", "can you" and the like at the start, and "please" or
        /// "thanks" at the end. True if one asked something of Oyl ("can you", "please").
        @discardableResult
        mutating func dropLeadIns() -> Bool {
            var asked = false
            while let hit = take(TodSpeech.leadIn, as: .filler) {
                let said = hit.group(0)?.lowercased() ?? ""
                asked = asked || said.contains("you") || said.hasPrefix("please") || said.hasPrefix("go ahead")
            }
            while take(TodSpeech.trailing, as: .filler) != nil {}
            take(TodSpeech.onlyFiller, as: .filler)
            return asked
        }

        /// "Add" and "put", once "to my list" has gone: "add milk to my list" is "milk".
        mutating func dropAddVerb(_ verbs: Set<String> = ["add", "put", "throw", "stick", "write", "jot"]) {
            guard let first = unread().first, verbs.contains(bare(words[first].text)) else { return }
            words[first].use = .filler
        }

        /// "Add" said to Oyl rather than as part of the task: "can you add get boba", "add call
        /// mom". "Add milk" said bare stays as it is.
        mutating func dropAddCommand(asked: Bool) {
            let open = unread()
            guard open.count >= 2, bare(words[open[0]].text) == "add", !endsBreath(words[open[0]].text),
                  asked || TodSpeech.taskVerbs.contains(bare(words[open[1]].text)) else { return }
            words[open[0]].use = .filler
        }

        // MARK: lists

        /// "#cs" or "hashtag cs": the list it names (by tod's own tag rule), or a new one. Every tag
        /// leaves the title and the first decides, as when typed. Words that go on to finish a
        /// list's name go with it ("#cs 106b"), and so does a "for" before it.
        mutating func readTags() {
            while let hit = take(TodSpeech.tag, as: .list) {
                guard list == nil, let tag = hit.group(1)?.lowercased() else { continue }
                var taken = hit.words
                var following: [Int] = []
                if !endsBreath(words[hit.words.last!].text) {
                    for i in unread() where i > hit.words.last! && following.count < 5 {
                        following.append(i)
                        if endsBreath(words[i].text) { break }
                    }
                }
                func run(_ count: Int) -> [String] { [tag] + following.prefix(count).map { bare(words[$0].text) } }
                // The whole name said out ("#cs 106b"), then tod's tag rule, then a name in spoken
                // numbers ("hashtag one oh six b").
                let whole = stride(from: following.count, through: 1, by: -1).first {
                    TodSpeech.named(run($0), among: lists)?.score == 3
                }
                let spoken = stride(from: following.count, through: 1, by: -1).first {
                    (TodSpeech.named(run($0), among: lists)?.score ?? 0) >= 2
                }
                if let count = whole, let match = TodSpeech.named(run(count), among: lists) {
                    list = (match.list.id, nil)
                    taken += following.prefix(count)
                } else if let id = TodQuick.list(for: tag, among: lists.map { (id: $0.id, name: $0.name) }) {
                    list = (id, nil)
                } else if let count = spoken, let match = TodSpeech.named(run(count), among: lists) {
                    list = (match.list.id, nil)
                    taken += following.prefix(count)
                } else {
                    list = (nil, tag)
                }
                for i in taken { words[i].use = .list }
                // "for #cs", "#cs list"
                if let before = unread().last(where: { $0 < hit.words.first! }), hit.words.first! - before <= 2 {
                    var lead = [before]
                    if ["my", "the", "our"].contains(bare(words[before].text)),
                       let prep = unread().last(where: { $0 < before }) { lead.insert(prep, at: 0) }
                    if TodSpeech.prepositions.contains(bare(words[lead[0]].text)) && !endsBreath(words[lead.last!].text) {
                        for i in lead { words[i].use = .list }
                        taken += lead
                    }
                }
                if let next = unread().first(where: { $0 > taken.max()! }), TodSpeech.listWords.contains(bare(words[next].text)),
                   !endsBreath(words[taken.max()!].text) {
                    words[next].use = .list
                    taken.append(next)
                }
                let name = list?.id.flatMap { id in lists.first { $0.id == id }?.name }
                note(.list, taken, name ?? "new list \(tag)")
            }
        }

        /// "for cs", "on my misc list", "for my cs 106b class", "for 106B": a list's name after a
        /// preposition, which leaves the title. The name has to end the phrase ("for mint", not
        /// "for mint condition" or "for the treehacks website", which are filed in passing), and
        /// all of it that's said goes ("for cs 106", not "for cs" and a stray "106"). A name that's
        /// an ordinary word after "the" needs "list" ("on the stack" is a pile), and isn't what's
        /// looked or shopped for ("look for mint"); "to" needs "my" or "list" unless the name is
        /// made up ("go to college" stays put).
        mutating func readListPhrase() {
            guard list == nil else { return }
            let open = unread()
            for (n, i) in open.enumerated() {
                let prep = bare(words[i].text)
                guard TodSpeech.prepositions.contains(prep), !endsBreath(words[i].text) else { continue }
                let verb = n > 0 && !endsBreath(words[open[n - 1]].text) ? bare(words[open[n - 1]].text) : nil
                var start = n + 1
                var determiner: Int?
                if start < open.count, ["my", "the", "our"].contains(bare(words[open[start]].text)), !endsBreath(words[open[start]].text) {
                    determiner = open[start]
                    start += 1
                }
                for count in stride(from: min(6, open.count - start), through: 1, by: -1) {
                    let run = Array(open[start..<(start + count)])
                    if run.dropLast().contains(where: { endsBreath(words[$0].text) }) { continue }
                    let said = run.map { bare(words[$0].text) }
                    guard let match = TodSpeech.named(said, among: lists) else { continue }
                    let nextIndex = start + count
                    var listWord: Int?
                    if nextIndex < open.count, TodSpeech.listWords.contains(bare(words[open[nextIndex]].text)), !endsBreath(words[run.last!].text) {
                        listWord = open[nextIndex]
                    }
                    let followerIndex = nextIndex + (listWord == nil ? 0 : 1)
                    let closed = followerIndex >= open.count || endsBreath(words[listWord ?? run.last!].text)
                    let free = closed || {
                        let follower = bare(words[open[followerIndex]].text)
                        let more = listWord == nil && match.list.squashed.hasPrefix(TodSpeech.squash(said + [follower]))
                        return TodSpeech.isFree(follower) && !more
                    }()
                    let det = determiner.map { bare(words[$0].text) }
                    if det == "the" && listWord == nil && !match.telling { continue }
                    if prep == "to" && !["my", "our"].contains(det ?? "") && listWord == nil && !match.telling { continue }
                    if prep == "for" && listWord == nil && !match.telling && TodSpeech.lookFor.contains(verb ?? "") { continue }
                    if listWord == nil && !free { continue }
                    let taken = [i] + (determiner.map { [$0] } ?? []) + run + (listWord.map { [$0] } ?? [])
                    for w in taken { words[w].use = .list }
                    list = (match.list.id, nil)
                    note(.list, taken, match.list.name)
                    // "Put … in my brain dump", but not "write an email to my cs class".
                    if ["to", "on", "onto", "into", "in"].contains(prep) { dropAddVerb(["add", "put", "throw", "stick"]) }
                    return
                }
            }
        }

        /// A list named in passing, without a preposition, keeping its words: "treehacks vc packet"
        /// and "cs assignment" (names no one says by accident, or misheard: "tree hack"), "math
        /// homework" and "mint open house" (ordinary words, so only right before schoolwork or club
        /// words: "buy mint gum", "the stack of dishes" and "dump stuff" stay unfiled). The Inbox
        /// isn't filed into this way: it's where unfiled tasks go anyway.
        mutating func readImplicitList() {
            let open = unread()
            var best: (list: Known, strength: Int, at: Int, words: [Int])?
            for (n, i) in open.enumerated() {
                for count in stride(from: min(6, open.count - n), through: 1, by: -1) {
                    let run = Array(open[n..<(n + count)])
                    if run.dropLast().contains(where: { endsBreath(words[$0].text) }) { continue }
                    let squashed = TodSpeech.squash(run.map { bare(words[$0].text) })
                    guard squashed.count >= 2 else { continue }
                    for known in lists where known.id != "inbox" {
                        var strength = 0
                        var taken = run
                        if squashed == known.squashed && (count > 1 || known.words.count > 1 || known.telling.contains(squashed)) {
                            strength = 3
                        } else if known.telling.contains(squashed) && squashed.contains(where: \.isLetter) {
                            strength = 2
                        } else if count <= 2, known.misheard(squashed, oneWord: count == 1) {
                            strength = 2
                        } else if count == 1, squashed.count >= 3, known.stands.contains(squashed) {
                            if open.count == 1 {
                                // The name alone ("math:"), to head what follows.
                                strength = 1
                            } else if !endsBreath(words[i].text), let more = schoolwork(after: n, in: open) {
                                strength = 1
                                taken = Array(open[n...more])
                            }
                        }
                        if strength > 0, best.map({ strength > $0.strength }) ?? true {
                            best = (known, strength, i, taken)
                        }
                    }
                }
            }
            guard let best else { return }
            list = (best.list.id, nil)
            note(.list, best.words, best.list.name)
            // Nothing but the name ("misc:"): it heads what follows.
            if best.words == open && (best.strength >= 2 || open.count == 1) {
                for i in best.words { words[i].use = .list }
            }
        }

        /// Where the schoolwork or club words after the `n`th open word end, if they follow it:
        /// "homework", "class project", "open house".
        func schoolwork(after n: Int, in open: [Int]) -> Int? {
            var next = n + 1
            if next < open.count, ["class", "club"].contains(bare(words[open[next]].text)) { next += 1 }
            guard next < open.count else { return nil }
            let word = bare(words[open[next]].text)
            if TodSpeech.schoolwork.contains(word) { return next }
            if next + 1 < open.count, !endsBreath(words[open[next]].text),
               TodSpeech.schoolworkPairs.contains(word + " " + bare(words[open[next + 1]].text)) { return next + 1 }
            return nil
        }

        // MARK: dates

        /// "Every sunday", "daily", "every other week", "on the 1st of every month".
        mutating func readRhythm() {
            for rule in TodSpeech.rhythms {
                guard let hit = take(rule.pattern, as: .repeats, where: { !rule.bare || $0.free }),
                      let made = rule.make(hit) else { continue }
                rhythm = made
                notes.append(Note(kind: .repeats, at: hit.words.min()!, text: quote(hit.words) + " → " + made.kind.phrase))
                return
            }
        }

        /// Far-off and broad: "by january", "late november", "end of the month", "next year",
        /// "this week"; and "this quarter", which is long term, so no date.
        mutating func readHorizon() {
            let clock = self.clock
            for rule in TodSpeech.horizons {
                if let hit = take(rule.pattern, as: .date, where: { rule.make($0, clock) != nil }) {
                    if let day = rule.make(hit, clock), !day.isEmpty {
                        horizon = day
                    } else {
                        for i in hit.words { words[i].use = .undated }
                        undated = true
                        note(.undated, hit.words, "no date, long term")
                    }
                    return
                }
            }
        }

        /// "Asap", "right now", "immediately": today.
        mutating func readSoon() {
            if take(TodSpeech.soon, as: .date, where: { hit in
                hit.group(0) != "now" || !["for", "from", "by", "until", "till", "since", "than", "right"].contains(hit.before ?? "")
                    && hit.after != "that"
            }) != nil {
                soon = true
            }
        }

        /// "Tonight", "in the morning", "friday night", "end of day", "lunchtime". A bare "night"
        /// or "morning" counts only after a day ("next weekend night"), so "game night" is a title.
        mutating func readPeriod() {
            for rule in TodSpeech.periods {
                var found: Period?
                if take(rule.pattern, as: .date, where: { hit in
                    found = rule.make(hit)
                    return found != nil
                }) != nil {
                    period = found
                    return
                }
            }
        }

        /// What tod's own quick add reads in what's left: the words it took are the date.
        mutating func readTod() {
            var tokens: [(word: Int, text: String)] = []
            for (i, word) in words.enumerated() where word.use == nil {
                for part in word.text.split(separator: " ") { tokens.append((i, String(part))) }
            }
            let source = tokens.map(\.text).joined(separator: " ")
            guard !source.isEmpty else { return }
            let parsed = TodQuick.parse(source, now: clock.now, weekStart: clock.weekStart)
            guard parsed.due != nil || parsed.time != nil else { return }
            todTime = parsed.time
            // With nothing but a date, tod gives the whole line back as the title.
            let kept = parsed.title == source
                ? Array(repeating: nil, count: tokens.count)
                : TodSpeech.align(tokens.map(\.text), parsed.title.split(separator: " ").map(String.init))
            var taken: Set<Int> = []
            var left: [Int: [String]] = [:]
            for (k, token) in tokens.enumerated() {
                if let text = kept[k] {
                    left[token.word, default: []].append(text)
                } else if token.text.contains(where: { $0.isLetter || $0.isNumber }) {
                    taken.insert(token.word)
                }
            }
            // A time alone ("at 9am") is put on today by tod; that's no day said, so a repeat
            // can still start at its next turn.
            if taken.contains(where: { !TodSpeech.timeOnly(words[$0].text) }) { todDue = parsed.due }
            for i in Set(tokens.map(\.word)) {
                if taken.contains(i) {
                    words[i].use = .date
                } else if let parts = left[i] {
                    words[i].text = parts.joined(separator: " ")
                } else {
                    words[i].use = .filler
                }
            }
        }

        /// "The 1st" when tod finds no day for it, as late in December (its months don't roll
        /// into the new year there): the coming 1st.
        mutating func readOrdinalDay() {
            guard todDue == nil, horizon == nil, !soon else { return }
            let clock = self.clock
            var found: String?
            if take(TodSpeech.ordinalDay, as: .date, where: { hit in
                found = hit.group(1).flatMap { Int($0) }.flatMap(clock.coming)
                return found != nil
            }) != nil {
                horizon = found
            }
        }

        /// "Due", "by", "starting" and the like, left in front of a date tod took the rest of.
        mutating func takeDangling() {
            var changed = true
            while changed {
                changed = false
                for i in words.indices where words[i].use == .date {
                    guard let before = words[..<i].lastIndex(where: { $0.use != .filler }),
                          words[before].use == nil, !endsBreath(words[before].text) else { continue }
                    let word = bare(words[before].text)
                    if TodSpeech.dangling.contains(word) || (bare(words[i].text) == "due" && ["it's", "its", "is", "that's", "which"].contains(word)) {
                        words[before].use = .date
                        changed = true
                    }
                }
            }
        }

        /// "Someday", "eventually", "no rush": no date, on purpose. "Long term" and "one day" only
        /// where they say when, not what: "long-term parking" and "a car for one day" are titles,
        /// but "one day visit japan" isn't.
        mutating func readUndated() {
            while let hit = take(TodSpeech.undatedWords, as: .undated, where: { hit in
                let said = hit.group(0)?.lowercased() ?? ""
                // "sometime" before a date is just part of it.
                if said == "sometime" { return hit.closed || !(hit.after.map(TodSpeech.isFree) ?? false) }
                if said.hasPrefix("long") { return hit.free && !TodSpeech.counted.contains(hit.before ?? "") }
                if said.hasPrefix("one") || said.hasPrefix("some ") {
                    return (hit.before == nil || hit.free) && !TodSpeech.counted.contains(hit.before ?? "")
                }
                return true
            }) {
                if !undated && todDue == nil && todTime == nil && horizon == nil && !soon && period == nil && rhythm == nil {
                    note(.undated, hit.words, "no date")
                }
                undated = true
            }
        }

        // MARK: the task

        func title() -> String {
            var title = words.filter { $0.use == nil }.map(\.text).joined(separator: " ")
            title = replacing(TodSpeech.emptyBrackets, in: title, with: " ")
            title = replacing(TodSpeech.loosePunctuation, in: title, with: " ")
            title = replacing(TodSpeech.spaceRuns, in: title, with: " ")
            var changed = true
            while changed {
                let before = title
                title = title.trimmingCharacters(in: TodSpeech.stops.union(CharacterSet(charactersIn: "–-\"“”")))
                // Not "so" or "plus" in front ("so much laundry", "plus size jacket"), or "plus"
                // behind ("an a plus").
                for joiner in ["and", "but", "then", "also", "or", "&", "to"] where title.hasPrefix(joiner + " ") {
                    title.removeFirst(joiner.count + 1)
                }
                for joiner in ["and", "but", "so", "also", "or", "&"] where title.hasSuffix(" " + joiner) {
                    title.removeLast(joiner.count + 1)
                }
                changed = title != before
            }
            return title
        }

        /// The task, its date settled: tod's reading first, then the broad ones; a time of day fills
        /// in the time; a repeat with no date starts at its next turn; and a stretch with no date
        /// or list of its own takes the header's.
        func task(title: String, under header: (task: SpokenTask, notes: [Note])? = nil)
            -> (task: SpokenTask, notes: [Note], inherited: Bool) {
            // A stretch says its own day, or takes the header's (and then can still say the time).
            let ownsDay = todDue != nil || horizon != nil || soon || rhythm != nil || undated || period?.today == true
            let inherits = !ownsDay && header?.task.due != nil ? header : nil
            var due = todDue ?? horizon ?? (soon ? clock.todayText : nil) ?? inherits?.task.due
            var time = todTime ?? (period == nil ? inherits?.task.time : nil)
            var notes = notes
            let dateWords = words.indices.filter { words[$0].use == .date }
            let saidWeekday = dateWords.contains { TodSpeech.weekdayNames[bare(words[$0].text)] != nil }
            let saidMeridiem = dateWords.contains { words[$0].text.range(of: #"\d\s?(a|p)\.?m?\.?\b|\b(a|p)\.?m\.?\b|noon|midnight|midday"#, options: .regularExpression) != nil }

            let period = self.period ?? rhythm?.period
            var afterMidnight = false
            if let period {
                let night = period.hour >= 20 && period.ends == 24 * 60
                let saidMidnight = dateWords.contains { words[$0].text.contains("midnight") }
                if night, let shown = time, let hour = Int(shown.prefix(2)),
                   (shown == "00:00" && saidMidnight) || (!saidMeridiem && (hour == 12 || (13...16).contains(hour))) {
                    // "12 tonight" and "midnight tonight" end the day, not noon or its start; "12:30
                    // tonight" and "1 tonight" (tod's 1 PM) are after it.
                    if shown == "00:00" || shown == "12:00" {
                        time = "23:59"
                    } else {
                        time = pad(hour % 12) + shown.dropFirst(2)
                        afterMidnight = true
                    }
                } else if let shown = time, !saidMeridiem, let meridiem = period.meridiem, var hour = Int(shown.prefix(2)) {
                    if meridiem == "am" && hour > 12 { hour -= 12 }
                    if meridiem == "pm" && hour < 12 { hour += 12 }
                    time = pad(hour) + shown.dropFirst(2)
                } else if time == nil {
                    let hourText = pad(period.hour) + ":00"
                    let passed = clock.minutes >= period.hour * 60
                    let over = clock.minutes >= period.ends
                    if rhythm != nil {
                        time = hourText
                    } else if due == nil {
                        if !passed {
                            (due, time) = (clock.todayText, hourText)
                        } else if period.today || !over {
                            due = clock.todayText
                        } else {
                            (due, time) = (clock.text(clock.today, adding: 1), hourText)
                        }
                    } else if due == clock.todayText {
                        if !passed {
                            time = hourText
                        } else if over && saidWeekday && !period.today && todDue != nil {
                            (due, time) = (clock.text(clock.today, adding: 7), hourText)
                        }
                    } else {
                        time = hourText
                    }
                }
                // An hour said with a time of day and no day ("at 9 in the morning") is the next
                // one, so tomorrow's once today's has gone by. "Tonight" is today's all the same.
                if let shown = time, todTime != nil, due == nil, rhythm == nil, !period.today, !afterMidnight, shown <= clock.clockText {
                    due = clock.text(clock.today, adding: 1)
                }
                if afterMidnight, rhythm == nil {
                    due = clock.text(due.flatMap(clock.parse) ?? clock.today, adding: 1)
                }
            }
            var startedBy: String?
            if let rhythm {
                if let weekday = rhythm.weekday {
                    if let said = due.flatMap(clock.parse) {
                        due = clock.text(said, adding: (weekday - clock.weekday(of: said) + 7) % 7)
                    } else {
                        var ahead = (weekday - clock.weekday + 7) % 7
                        if ahead == 0 && time.map({ $0 <= clock.clockText }) == true { ahead = 7 }
                        due = clock.text(clock.today, adding: ahead)
                        startedBy = due
                    }
                } else if due == nil {
                    let early = time.map { $0 > clock.clockText } ?? true
                    if let day = rhythm.monthDay {
                        due = clock.monthDay(day, early: early)
                    } else if rhythm.kind == .weekdays {
                        var day = clock.today
                        if !early { day = clock.adding(day, 1) }
                        while [0, 6].contains(clock.weekday(of: day)) { day = clock.adding(day, 1) }
                        due = clock.text(day)
                    } else {
                        due = early ? clock.todayText : rhythm.kind.next(after: clock.todayText)
                    }
                    startedBy = due
                }
            }

            if time != nil && due == nil { due = clock.todayText }

            if let due, !dateWords.isEmpty, startedBy == nil {
                notes.append(Note(kind: .date, at: dateWords.min()!, text: quote(dateWords) + " → " + clock.describe(due, time)))
            }
            if let startedBy, let index = notes.firstIndex(where: { $0.kind == .repeats }) {
                let words = words.indices.filter { self.words[$0].use == .repeats || self.words[$0].use == .date }
                notes[index] = Note(kind: .repeats, at: notes[index].at,
                                    text: quote(words) + " → " + rhythm!.kind.phrase + ", from " + clock.describe(startedBy, time))
            }

            var task = SpokenTask(title: title, due: due, time: time, listId: list?.id, newList: list?.new,
                                  repeats: rhythm?.kind ?? inherits?.task.repeats, heard: heard, reasons: [])
            var inherited: [Note] = []
            var took = inherits != nil
            if let header, list == nil, header.task.listId != nil || header.task.newList != nil {
                task.listId = header.task.listId
                task.newList = header.task.newList
                inherited += header.notes.filter { $0.kind == .list }
                took = true
            }
            if let inherits { inherited += inherits.notes.filter { $0.kind == .date || $0.kind == .repeats } }
            // "Long term: learn piano": the header's "no date", for a stretch that says no day.
            if let header, !ownsDay, due == nil, header.task.due == nil, header.notes.contains(where: { $0.kind == .undated }) {
                inherited += header.notes.filter { $0.kind == .undated }
                took = true
            }
            let all = inherited.sorted { $0.at < $1.at } + notes.sorted { $0.at < $1.at }
            task.reasons = all.map(\.text)
            return (task, all, took)
        }
    }

    // MARK: - lists

    /// A tod list, by the words of its name.
    fileprivate struct Known {
        let id: String
        let name: String
        let words: [String]       // "💻 cs 106b" → ["cs", "106b"]
        let squashed: String      // "cs106b"
        /// Words that name it on their own: made up ("treehacks", "cs", "misc") or with digits in
        /// ("106b", "61cm"). "mint" and "stack" are English, so aren't.
        let telling: Set<String>
        /// Words that stand for it said alone: the telling ones, a one-word name ("mint"), and a
        /// course's subject ("math" of "math 61cm"). Not one word of a name that's all English:
        /// "my brain" isn't Brain dump.
        let stands: Set<String>
        /// Every run of its words, squashed: "cs", "106b", "cs106b".
        let parts: [String]

        static func all(_ lists: [(id: String, name: String)]) -> [Known] {
            let named = lists.map { (id: $0.id, name: $0.name, words: TodSpeech.nameWords($0.name)) }
            let english = English.contains(Set(named.flatMap(\.words).filter { $0.allSatisfy(\.isLetter) }))
            return named.map { list in
                let telling = Set(list.words.filter { word in
                    word.count >= 2 && word.contains(where: \.isLetter) && (word.contains(where: \.isNumber) || !english.contains(word))
                })
                var stands = telling
                if list.words.count == 1 {
                    stands.formUnion(list.words)
                } else if list.words.contains(where: { $0.contains(where: \.isNumber) }) {
                    stands.formUnion(list.words.filter { $0.allSatisfy(\.isLetter) })
                }
                return Known(id: list.id, name: list.name, words: list.words, squashed: list.words.joined(), telling: telling,
                             stands: stands, parts: TodSpeech.contiguous(list.words))
            }
        }

        /// Whether a word is a misheard or cut-off form of one of its words ("treehack", "tree hack"
        /// run together: most of the word), or one of its made-up words said as a plural ("aasas"),
        /// and not English itself ("tree" isn't one).
        func misheard(_ key: String, oneWord: Bool) -> Bool {
            guard key.count >= 4, !key.contains(where: \.isNumber) else { return false }
            let near = words.contains { word in
                (word.count > key.count && word.hasPrefix(key) && key.count * 3 >= word.count * 2)
                    || (oneWord && telling.contains(word) && (key == word + "s" || key == word + "es"))
            }
            return near && English.contains([key]).isEmpty
        }
    }

    /// The list a run of spoken words names, and how surely: 3 the whole name ("cs 106b", "tree
    /// hacks"), 2 a word or more of it ("cs", "106B", "one oh six b", "computer science") or its
    /// start ("math 61"), 1 a misheard or cut-off form ("treehack"). `telling` when it can't be an
    /// ordinary word said in passing. The first list wins a tie.
    fileprivate static func named(_ run: [String], among lists: [Known]) -> (list: Known, score: Int, telling: Bool)? {
        let key = squash(run)
        guard key.count >= 2, !(run.count == 1 && notNames.contains(run[0])) else { return nil }
        let digits = key.contains(where: \.isNumber)
        var best: (Known, Int, Bool)?
        for list in lists {
            var score = 0
            var telling = digits
            if key == list.squashed {
                score = 3
                telling = telling || run.count > 1 || list.words.count > 1 || list.telling.contains(key)
            } else if let part = list.parts.first(where: { $0 == key }), digits || list.stands.contains(part) || !list.words.contains(part) {
                score = 2
                telling = telling || list.telling.contains(part) || list.words.contains { list.telling.contains($0) && part.contains($0) }
            } else if let first = list.words.first, key.count > first.count, list.squashed.hasPrefix(key) {
                score = 2
            } else if run.count <= 2, list.misheard(key, oneWord: run.count == 1) {
                score = 1
                telling = true
            }
            if score > (best?.1 ?? 0) { best = (list, score, telling) }
        }
        return best.map { (list: $0.0, score: $0.1, telling: $0.2) }
    }

    /// Every run of a name's words, squashed: ["cs", "106b"] → "cs", "106b", "cs106b".
    fileprivate static func contiguous(_ words: [String]) -> [String] {
        var runs: [String] = []
        for start in words.indices {
            for end in start..<words.count { runs.append(words[start...end].joined()) }
        }
        return runs
    }

    /// Spoken words run together the way a list name is: number words as digits ("one oh six b"
    /// → "106b", "sixty one cm" → "61cm") and a few long forms short ("computer science" → "cs").
    fileprivate static func squash(_ run: [String]) -> String {
        var parts: [String] = []
        var i = 0
        let digits = run.contains { numberWords[$0] != nil && $0 != "oh" && $0 != "o" } || run.contains { Int($0) != nil }
        while i < run.count {
            let word = run[i].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if let value = numberWords[word], digits || (word != "oh" && word != "o") {
                if value >= 20, value % 10 == 0, i + 1 < run.count, let unit = numberWords[run[i + 1]], (1...9).contains(unit) {
                    parts.append(String(value + unit))
                    i += 2
                    continue
                }
                if i + 1 < run.count, run[i + 1] == "hundred" {
                    var total = value * 100
                    i += 2
                    if i < run.count, run[i] == "and" { i += 1 }
                    if i < run.count, let tens = numberWords[run[i]], tens >= 10 || tens > 0 {
                        total += tens
                        i += 1
                        if tens >= 20, tens % 10 == 0, i < run.count, let unit = numberWords[run[i]], (1...9).contains(unit) {
                            total += unit
                            i += 1
                        }
                    }
                    parts.append(String(total))
                    continue
                }
                parts.append(String(value))
            } else {
                parts.append(word.filter { $0.isLetter || $0.isNumber })
            }
            i += 1
        }
        var key = parts.joined()
        for (long, short) in [("computerscience", "cs"), ("compsci", "cs"), ("mathematics", "math"), ("maths", "math")] where key.hasPrefix(long) {
            key = short + key.dropFirst(long.count)
        }
        return key
    }

    /// A name's words, lowercase with accents gone, and emoji and punctuation left out (as
    /// `TodQuick` reads them for tags).
    private static func nameWords(_ name: String) -> [String] {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Which of these words are ordinary English ones, by the Mac's own word list. Read once per
    /// word and remembered; with no word list, every word counts as English, so lists named with
    /// plain words are only filed into when they're named outright.
    private enum English {
        private static let lock = NSLock()
        private static var known: [String: Bool] = [:]

        static func contains(_ asked: Set<String>) -> Set<String> {
            lock.lock()
            defer { lock.unlock() }
            let missing = asked.filter { known[$0] == nil }
            if !missing.isEmpty {
                var found: Set<String> = []
                if let data = try? Data(contentsOf: URL(fileURLWithPath: "/usr/share/dict/words"), options: .alwaysMapped) {
                    let wanted = Set(missing.map { Array($0.utf8) })
                    let lengths = Set(wanted.map(\.count))
                    data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                        var start = 0
                        for i in 0...bytes.count where i == bytes.count || bytes[i] == 10 {
                            if lengths.contains(i - start) {
                                let line = Array(bytes[start..<i])
                                if wanted.contains(line) { found.insert(String(decoding: line, as: UTF8.self)) }
                            }
                            start = i + 1
                        }
                    }
                    for word in missing { known[word] = found.contains(word) }
                } else {
                    for word in missing { known[word] = true }
                }
            }
            return asked.filter { known[$0] == true }
        }
    }

    // MARK: - tod's title, lined up

    /// Which of the words tod kept for the title (and as what: "mom," may come back "mom"), and
    /// so which it took as the date. Of the ways to line them up, the one where what it took is in
    /// the fewest pieces. Each title word is one of the words in order, so only the few ways that
    /// leave out `n - m` of them are tried, and a long run-on stays quick.
    fileprivate static func align(_ source: [String], _ title: [String]) -> [String?] {
        let n = source.count, m = title.count
        guard m <= n else { return source }
        let width = n - m + 1
        let never = Int.max / 4
        // Lining up source[i...] with title[(i - k)...], k words left out so far; r is 1 if the
        // word before was left out.
        func at(_ i: Int, _ k: Int, _ r: Int) -> Int { (i * width + k) * 2 + r }
        var cost = [Int](repeating: never, count: (n + 1) * width * 2)
        cost[at(n, n - m, 0)] = 0
        cost[at(n, n - m, 1)] = 0
        func options(_ i: Int, _ k: Int, _ r: Int) -> [(cost: Int, kept: String?, k: Int, r: Int)] {
            let word = source[i], j = i - k
            var result: [(Int, String?, Int, Int)] = []
            if j < m && word == title[j] { result.append((cost[at(i + 1, k, 0)], title[j], k, 0)) }
            if j < m && word != title[j] && word.contains(title[j]) { result.append((cost[at(i + 1, k, 0)] + 1, title[j], k, 0)) }
            if k + 1 < width {
                if !word.contains(where: { $0.isLetter || $0.isNumber }) {
                    result.append((cost[at(i + 1, k + 1, r)], nil, k + 1, r))
                } else {
                    result.append((cost[at(i + 1, k + 1, 1)] + (r == 1 ? 0 : 2), nil, k + 1, 1))
                }
            }
            return result
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for k in 0...min(i, n - m) where i - k <= m {
                for r in 0...1 { cost[at(i, k, r)] = options(i, k, r).map(\.cost).min() ?? never }
            }
        }
        // They can't be lined up (never seen): leave every word in the title.
        guard cost[at(0, 0, 0)] < never else { return source }
        var kept: [String?] = []
        var k = 0, r = 0
        for i in 0..<n {
            guard let best = options(i, k, r).min(by: { $0.cost < $1.cost }) else { return source }
            kept.append(best.kept)
            (k, r) = (best.k, best.r)
        }
        return kept
    }

    // MARK: - days

    /// Today, here, for working out dates: days are counted at noon in a fixed zone, so daylight
    /// saving can't move one.
    fileprivate struct Clock {
        let now: Date
        let weekStart: Int
        let today: Date
        let minutes: Int          // into the day
        let weekday: Int          // 0 is Sunday
        let year: Int, month: Int, day: Int

        static let utc: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }()

        init(now: Date, weekStart: Int) {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = .autoupdatingCurrent
            let parts = local.dateComponents([.year, .month, .day, .hour, .minute], from: now)
            self.now = now
            self.weekStart = weekStart
            year = parts.year!
            month = parts.month!
            day = parts.day!
            minutes = parts.hour! * 60 + parts.minute!
            today = Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
            weekday = Self.utc.component(.weekday, from: today) - 1
        }

        var todayText: String { text(today) }
        /// The day this week started.
        var weekStartDay: Date { adding(today, -((weekday - weekStart + 7) % 7)) }
        var clockText: String { pad(minutes / 60) + ":" + pad(minutes % 60) }

        func adding(_ date: Date, _ days: Int) -> Date { Self.utc.date(byAdding: .day, value: days, to: date)! }
        func text(_ date: Date, adding days: Int = 0) -> String {
            let parts = Self.utc.dateComponents([.year, .month, .day], from: adding(date, days))
            return "\(parts.year!)-\(pad(parts.month!))-\(pad(parts.day!))"
        }
        func weekday(of date: Date) -> Int { Self.utc.component(.weekday, from: date) - 1 }

        func parse(_ text: String) -> Date? {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return date(parts[0], parts[1], parts[2])
        }

        /// The day, if it's a real one; day 0 is the month's last.
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date? {
            let y = year + (month - 1).floorDivided(by: 12), m = (month - 1).floorModulo(12) + 1
            if day == 0 { return Self.utc.date(from: DateComponents(year: y, month: m + 1, day: 0, hour: 12)) }
            guard let date = Self.utc.date(from: DateComponents(year: y, month: m, day: day, hour: 12)),
                  Self.utc.component(.day, from: date) == day else { return nil }
            return date
        }

        /// The coming `monthDay` (0: the last day), today counting if it's `early` enough still;
        /// the 31st in a shorter month is its last day.
        func monthDay(_ monthDay: Int, early: Bool) -> String {
            for ahead in 0...12 {
                let last = Self.utc.component(.day, from: date(year, month + ahead, 0)!)
                let target = monthDay == 0 ? last : min(monthDay, last)
                let candidate = date(year, month + ahead, target)!
                if candidate > today || (candidate == today && early) { return text(candidate) }
            }
            return todayText
        }

        /// The next `day` of a month, today counting, in the months that have it.
        func coming(_ day: Int) -> String? {
            guard (1...31).contains(day) else { return nil }
            for ahead in 0...3 {
                if let date = date(year, month + ahead, day), date >= today { return text(date) }
            }
            return nil
        }

        /// "sat nov 7, 8 pm"; the year too if it isn't this one ("fri jan 1, 2027").
        func describe(_ due: String, _ time: String?) -> String {
            guard let date = parse(due) else { return due }
            let parts = Self.utc.dateComponents([.year, .month, .day, .weekday], from: date)
            var text = TodSpeech.dayNames[parts.weekday! - 1] + " " + TodSpeech.monthNames[parts.month! - 1] + " \(parts.day!)"
            if parts.year! != year { text += ", \(parts.year!)" }
            if let time { text += ", " + TodSpeech.describe(time: time) }
            return text
        }
    }

    /// "8 pm", "8:30 am", "noon", "midnight".
    fileprivate static func describe(time: String) -> String {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return time }
        if parts == [12, 0] { return "noon" }
        if parts == [0, 0] { return "midnight" }
        let hour = parts[0] % 12 == 0 ? 12 : parts[0] % 12
        return (parts[1] == 0 ? "\(hour)" : "\(hour):\(pad(parts[1]))") + (parts[0] < 12 ? " am" : " pm")
    }

    fileprivate static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    fileprivate static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    // MARK: - what's said

    fileprivate static let stops = CharacterSet(charactersIn: " \t,.;:!?…")

    /// A word without the punctuation around it.
    fileprivate static func bare(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?…()[]\"“”"))
    }

    /// Whether the word ends a breath: a comma or a stop after it.
    fileprivate static func endsBreath(_ text: String) -> Bool {
        text.last.map { ",;:.!?…)".contains($0) } ?? false
    }

    /// Whether the text between two places is only punctuation, or nothing.
    fileprivate static func onlyPunctuation(_ text: NSString, from start: Int, to end: Int) -> Bool {
        start >= end || text.substring(with: NSRange(location: start, length: end - start)).allSatisfy { "\"“”'‘’([)].,;:!?…".contains($0) }
    }

    /// Words that can follow a list's name or a time of day without being more of the same noun:
    /// dates, times and joining words.
    fileprivate static func isFree(_ word: String) -> Bool {
        freeWords.contains(word) || weekdayNames[word] != nil || monthIndex[word] != nil || word.first?.isNumber == true
            || word.hasPrefix("#")
    }

    private static let freeWords: Set<String> = [
        "at", "by", "on", "in", "for", "due", "this", "next", "tomorrow", "tmrw", "today", "tonight", "before", "until",
        "till", "every", "each", "and", "or", "then", "also", "please", "starting", "from", "around", "after", "asap",
        "sometime", "someday", "eventually", "whenever", "weekly", "daily", "monthly", "yearly", "annually", "thanks",
        "noon", "midnight", "end", "early", "late", "mid", "right", "now", "the", "@", "hashtag", "list", "class",
    ]

    fileprivate static let weekdayNames: [String: Int] = [
        "sunday": 0, "sun": 0, "monday": 1, "mon": 1, "tuesday": 2, "tue": 2, "tues": 2, "wednesday": 3, "wed": 3,
        "weds": 3, "thursday": 4, "thu": 4, "thur": 4, "thurs": 4, "friday": 5, "fri": 5, "saturday": 6, "sat": 6,
    ]

    private static let monthIndex: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5, "june": 6,
        "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9, "october": 10, "oct": 10,
        "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    private static let numberWords: [String: Int] = [
        "zero": 0, "oh": 0, "o": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let ordinals: [String: Int] = {
        let words = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh",
                     "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth",
                     "twentieth"]
        var result: [String: Int] = [:]
        for (i, word) in words.enumerated() { result[word] = i + 1 }
        for (i, word) in words.prefix(9).enumerated() {
            result["twenty-" + word] = 21 + i
            result["twenty " + word] = 21 + i
        }
        result["thirtieth"] = 30
        result["thirty-first"] = 31
        result["thirty first"] = 31
        return result
    }()

    /// Prepositions a list's name follows: "for cs", "on my misc list".
    fileprivate static let prepositions: Set<String> = ["for", "in", "on", "to", "under", "into", "onto"]
    /// Words after a list's name that are part of naming it: "my cs class", "the misc list". Not
    /// "board": "the aasa board" is its officers.
    fileprivate static let listWords: Set<String> = ["list", "lists", "class", "course", "club", "stuff", "things", "tasks",
                                                     "todos", "to-dos", "folder"]
    /// Verbs whose "for" says what's wanted, not whose it is: "look for mint", "apply for college".
    fileprivate static let lookFor: Set<String> = ["look", "looking", "shop", "shopping", "search", "searching", "hunt",
                                                   "ask", "asking", "pay", "apply", "applying", "wait", "waiting", "check",
                                                   "go", "reach", "vote", "save", "saving", "cook", "care"]
    /// Words that aren't a list's name on their own, whatever the lists are called.
    private static let notNames: Set<String> = ["my", "the", "a", "an", "our", "this", "that", "it", "me", "i", "you",
                                                "list", "class", "now", "then", "and", "to", "do", "of"]
    /// What follows a course or club named with an ordinary word, when it's meant: "math homework",
    /// "mint meeting".
    fileprivate static let schoolwork: Set<String> = [
        "homework", "hw", "pset", "psets", "problem", "problems", "assignment", "assignments", "reading", "readings",
        "essay", "essays", "paper", "papers", "draft", "drafts", "midterm", "midterms", "final", "finals", "exam", "exams",
        "quiz", "quizzes", "test", "tests", "lecture", "lectures", "section", "lab", "labs", "project", "projects",
        "presentation", "meeting", "meetings", "notes", "study", "review", "event", "events", "practice", "rehearsal",
        "board", "ad", "ads", "social", "packet", "deadline", "deadlines", "discussion", "worksheet", "report", "slides",
        "gbm", "sync", "standup", "interview", "interviews", "workshop", "reflection", "response", "journal", "retreat",
        "merch", "newsletter", "stuff", "things", "tasks", "todos", "class", "club", "pitch", "pitches",
    ]
    /// What a to-do starts with, so an "add" before one was said to Oyl: "add call mom".
    fileprivate static let taskVerbs: Set<String> = [
        "get", "buy", "call", "email", "text", "do", "make", "pick", "go", "finish", "submit", "start", "read", "pay", "book",
        "schedule", "clean", "send", "take", "check", "review", "study", "work", "look", "find", "set", "fix", "return",
        "order", "reply", "sign", "apply", "renew", "cancel", "print", "meet", "ask", "tell", "bring", "grab", "pack", "watch",
        "practice", "prep", "prepare", "update", "follow", "plan", "write", "visit", "see", "try", "learn", "register", "wash",
        "drop", "turn", "respond", "message", "dm", "remember", "talk", "post", "draft", "edit", "fill", "file", "move",
    ]
    /// Two-word ones: "mint open house", "math office hours".
    fileprivate static let schoolworkPairs: Set<String> = ["open house", "office hours", "info session", "all hands",
                                                           "group chat", "general meeting", "problem set"]
    /// Whether a word tod took is only part of a time: "at", "9am", "5:30", "pm", "noon" (or one
    /// rewritten as such: "at five" is "at 5").
    fileprivate static func timeOnly(_ text: String) -> Bool {
        text.split(separator: " ").allSatisfy { part in
            let word = bare(String(part))
            return ["at", "@", "from", "to", "noon", "midday", "midnight", "am", "pm", "a.m.", "p.m.", "a.m", "p.m", "-", "–"].contains(word)
                || word.range(of: #"^@?\d{1,2}(:\d{2})?([ap]\.?m?\.?)?([-–]\d{1,2}(:\d{2})?([ap]\.?m?\.?)?)?$"#, options: .regularExpression) != nil
        }
    }

    /// Words left in front of a date: "due friday", "starting next week".
    fileprivate static let dangling: Set<String> = ["due", "by", "on", "before", "until", "till", "for", "at", "this",
                                                    "starting", "beginning", "from", "around", "sometime"]

    // MARK: - patterns

    /// A phrase on its own: not inside a longer word.
    private static func phrase(_ body: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}'#])(?:"# + body + #")(?![\p{L}\p{N}'])"#, options: [.caseInsensitive])
    }

    private static func pattern(_ source: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }

    fileprivate static func whole(_ text: String) -> NSRange { NSRange(location: 0, length: (text as NSString).length) }

    fileprivate static func replacing(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: whole(text), withTemplate: template)
    }

    private static func squeeze(_ pattern: NSRegularExpression, in text: String, _ change: (String) -> String) -> String {
        let ns = NSMutableString(string: text)
        for match in pattern.matches(in: text, range: whole(text)).reversed() {
            ns.replaceCharacters(in: match.range, with: change(ns.substring(with: match.range)))
        }
        return ns as String
    }

    private static let meridiemThenSentence = try! NSRegularExpression(pattern: #"(?<=\d|\d )([AaPp])\.\s?[Mm]\.(\s+[A-Z])"#)
    private static let dottedMeridiem = try! NSRegularExpression(pattern: #"(?<=\d|\d )([AaPp])\.\s?[Mm]\.?(?![\p{L}])"#)
    private static let dottedLetters = try! NSRegularExpression(pattern: #"(?<![\p{L}.])(?:[A-Za-z]\.){2,}(?![\p{L}])"#)
    private static let spacedCapitals = try! NSRegularExpression(pattern: #"(?<![\p{L}])(?!I )[A-Z](?: [A-Z](?![\p{L}'])){1,}"#)
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[.!?;:…]+(?=\s|$)|\s+[-–—]+\s+(?=[A-Z])"#)
    private static let abbreviations: Set<String> = ["dr", "mr", "mrs", "ms", "st", "vs", "jr", "sr", "prof", "mt", "ft",
                                                     "e.g", "i.e"].reduce(into: []) { $0.insert($1); $0.insert($1 + ".") }

    /// Where a new to-do starts mid-sentence: group 1 is an "and" before it, if there was one, and
    /// group 2 the word that starts it.
    private static let boundaries: [NSRegularExpression] = [
        pattern(#"(?:,\s*|\s+)(?:(and)\s+)?(also|then|plus)(?![\p{L}\p{N}'])(?:\s*,)?"#),
        pattern(#"(?:,\s*|\s+)(?:(and)\s+)?(after that|afterwards|oh,? and|oh also|one more thing)(?![\p{L}\p{N}'])(?:\s*[,:])?"#),
        pattern(#"(?:,\s*|\s+)(?:(and)\s+)?(another one)(?=\s*[,:]|\s+is\b)(?:\s+is)?(?:\s*[,:])?"#),
        pattern(#"(?:,\s*|\s+)(?:(and)\s+)?(next|secondly|second|thirdly|third|finally|lastly)(?=\s*,)(?:\s*,)?"#),
        pattern(#"\s+(and)\s+(next|finally|lastly)(?!\s+(?:week|weekend|month|year|time|semester|quarter|term|mon|tue|wed|thu|fri|sat|sun|day|morning|night|to|up)\b)(?![\p{L}\p{N}'])(?:\s*,)?"#),
        pattern(#"(?:,\s*|\s+(?=and\s)|\s+(?=but\s))(?:(and|but)\s+)?()(?=(?:remind me|i need to|i have to|i've got to|i got to|i gotta|i should|i want to|i wanna|i must|i also need|i also have|don't forget|do not forget|don't let me forget|make sure|remember to|we need to|i'll need to|i'd like to|add a task|add a to-?do|can you|could you|please remind|please add|i'm gonna|i'm going to)(?![\p{L}\p{N}']))"#),
    ]

    /// Oyl's name said to it, and nothing else: "hey oyl", "oil".
    private static let address = pattern(#"^\s*(?:(?:hey|hi|yo|okay|ok),?\s+)?(?:oyl|oil|oy|oi)\s*$"#)

    /// "Um", "uh" and the like, anywhere.
    fileprivate static let hesitation = phrase(#"u+h+m*|u+m+|e+r+m+|h+m+|mm+|mhm|ah+"#)

    /// The ways a to-do gets started out loud, at the start of a stretch.
    /// Oyl's name misheard ("hey oil", "okay boil,") counts only where it can't be the task's own
    /// first word: "okay, boil water" and "oil, vinegar and salt" are to-dos.
    fileprivate static let leadIn = pattern(#"^(?:"# + [
        #"(?:hey|hi|yo),?\s+(?:oyl|oil|oy|oi|boil)"#, #"(?:okay|ok),?\s+(?:oyl|(?:oil|oy|oi|boil)(?=[,.!?]))"#, #"oyl(?=,)"#,
        #"oil(?=,\s*(?:remind|i|i'm|i've|add|please|can|could|make|don't|put|set|new|we|let's|okay|ok|so)(?![\p{L}\p{N}']))"#,
        #"remind me(?: that| to)?(?: i| we)?(?: also)?(?: really)? (?:need to|have to|got to|gotta|should|must|ought to)"#,
        #"remind me (?:that|to|about|of)"#, #"remind me"#, #"(?:i should |i need to |please )?remember to"#,
        #"don't let me forget (?:to|about)"#, #"(?:don't|do not) forget (?:to|about)"#, #"(?:don't|do not) forget"#,
        #"make sure(?: that)?(?: i| we)?(?: also)?(?: need to| have to| to)?"#,
        #"(?:i|we) (?:also )?(?:really )?(?:still )?(?:need to|have to|got to|ought to|want to|'d like to|would like to|'ve got to|have got to|will need to|'ll need to|'m going to|am going to|'m supposed to|am supposed to|plan to|must|should|gotta|wanna|'m gonna|am gonna|gonna|'ll|will)"#,
        #"(?:i|we)'(?:ve got to|d like to|ll need to|m going to|m supposed to|m gonna|ll)"#,
        #"(?:need to|have to|got to|gotta|ought to)"#,
        #"(?:can|could|would|will) you(?: please)?(?: also)?"#, #"please"#, #"pls"#, #"plz"#,
        #"(?:go ahead and |please )?add (?:a |an )?(?:new )?(?:task|to-?do|todo|to do|reminder|item)(?: to| for| that says| saying| called)?"#,
        #"new (?:task|to-?do|todo|reminder)"#, #"(?:set|make) a (?:reminder|note) (?:to|for|that)"#,
        #"(?:write|jot|note) down"#, #"note to self"#, #"let's"#, #"let me (?:think|see)"#,
        #"let me(?=\s+(?:add|put|write|jot|note|remember)\b)"#, #"go ahead and"#,
        #"okay so"#, #"ok so"#, #"alright so"#, #"all right so"#, #"okay"#, #"ok"#, #"alright"#, #"all right"#,
        #"so(?!\s+(?:much|many|far|long|called|good|bad)\b)"#, #"oh"#, #"well(?=,)"#, #"yeah"#, #"yes"#, #"and"#, #"but"#,
        #"also"#, #"then"#, #"plus(?!\s+"# + plusNouns + #"\b)"#, #"next(?=,|\s+(?:i|we|remind|don't|make|please|let's)\b)"#,
        #"first(?=,|\s+(?:i|we|remind|don't|make|please|let's)\b)"#, #"second(?=,)"#, #"third(?=,)"#, #"finally"#, #"lastly"#, #"another one(?: is)?"#,
        #"one more(?: thing)?(?: is)?"#, #"i think"#, #"i guess"#, #"maybe"#,
    ].joined(separator: "|") + #")(?![\p{L}\p{N}'])[\s,:;.!?-]*"#)

    /// What "plus" is part of, not a new to-do: "plus size", "disney plus membership".
    fileprivate static let plusWords: Set<String> = ["size", "sized", "one", "ones", "sign", "signs", "minus", "ultra",
                                                     "membership", "subscription"]
    private static let plusNouns = "(?:" + plusWords.sorted().joined(separator: "|") + ")"

    /// "Please", "thanks" and the like, at the end.
    fileprivate static let trailing = pattern(#"(?:^|(?<=[\s,]))(?:please|pls|thanks|thank you(?: so much)?|thank you very much|for me|if you can|if possible|okay|ok|that's it|that's all|real quick)[\s.!?,]*$"#)

    /// A stretch that's nothing but filler: "okay.", "that's it.", "i".
    fileprivate static let onlyFiller = pattern(#"^(?:reminder|reminders|note|task|to-?do|todo|to do|new task|thanks|thank you|okay|ok|that's it|that's all|that's everything|done|nothing else|never ?mind|so|yeah|alright|cool|great|i|we|you|i'll|i'd|i'm|we'll|me|oyl|hey oyl|hey|um|uh|(?:here's|here is|here are|this is)(?: (?:my|the|a|some))?(?: (?:list|to-?do list|todo list|tasks|to-?dos|todos|things|reminders))?)[\s.!?,]*$"#)

    /// "To my list", "on my to-do list", "to tod": the list of to-dos itself, not one of tod's.
    fileprivate static let genericList = phrase(#"(?:to|on|onto|in|into)\s+(?:my|the)\s+(?:to-?do\s+|todo\s+|to\s+do\s+|task\s+|tasks\s+|reminders\s+)?lists?|(?:to|on|in)\s+(?:my|the)\s+(?:to-?dos|todos|tasks|reminders)|(?:to|on|in)\s+tod"#)

    /// "#cs", "hashtag cs" (macOS writes the word out).
    fileprivate static let tag = pattern(#"(?<![\p{L}\p{M}\p{N}_#/&])(?:#|hashtag\s+|hash\s+tag\s+)([\p{L}\p{M}\p{N}_\-]*[\p{L}\p{N}][\p{L}\p{M}\p{N}_\-]*)"#)

    private static let hourWord = #"(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d{1,2})"#
    private static let minuteWords = #"(o'?\s?clock|oh\s+(?:one|two|three|four|five|six|seven|eight|nine)|ten|fifteen|twenty(?:[\s-](?:five))?|thirty(?:[\s-](?:five))?|forty(?:[\s-](?:five))?|fifty(?:[\s-](?:five))?)"#

    /// Spoken numbers rewritten so tod reads them: an hour said in words ("at five thirty" →
    /// "at 5:30", "seven pm" → "7 pm"), "five o'clock" → "at 5", a bare hour before "in the morning",
    /// and "in a couple of days", "in half an hour".
    fileprivate static let rewrites: [(NSRegularExpression, (_ groups: [String?], _ next: String?) -> String?)] = [
        (phrase(#"in\s+(?:a\s+)?half\s+(?:an?\s+)?hour"#), { _, _ in "in 30 minutes" }),
        (phrase(#"in\s+(a\s+couple(?:\s+of)?|a\s+few|several)\s+(days?|weeks?|months?|hours?|minutes?)"#), { g, _ in
            let count = g[1]!.contains("couple") ? 2 : g[1]!.contains("few") ? 3 : 4
            return "in \(count) " + g[2]!
        }),
        // "A week from today" is tod's "in 1 week"; from tomorrow, a day more.
        (phrase(#"(an?|one|two|three|four|five|six|seven|eight|nine|ten|\d{1,2})\s+(days?|weeks?|months?)\s+from\s+(today|now|tomorrow|tmrw)"#), { g, _ in
            let said = g[1]!.lowercased()
            guard let count = said.hasPrefix("a") ? 1 : Int(said) ?? numberWords[said], count > 0 else { return nil }
            let unit = g[2]!.lowercased()
            guard ["tomorrow", "tmrw"].contains(g[3]!.lowercased()) else { return "in \(count) " + unit }
            guard !unit.hasPrefix("month") else { return nil }
            return "in \((unit.hasPrefix("week") ? count * 7 : count) + 1) days"
        }),
        (phrase(#"(?:(at|@|around|by)\s+)?"# + hourWord + #"\s+o'?\s?clock"#), { g, _ in
            guard let hour = clockHour(g[2]!) else { return nil }
            return (g[1] ?? "at") + " \(hour)"
        }),
        // "around five" and "by 5" mean at 5 as much as "at five" does.
        (phrase(#"(at|@|around|by)\s+"# + hourWord + #"(?:\s+"# + minuteWords + #")?(?:\s*(am|pm|a\.m\.|p\.m\.))?"#), { g, next in
            let lead = g[1]!.lowercased()
            guard let hour = clockHour(g[2]!), g[2]!.first?.isLetter == true || g[3] != nil || lead == "around" || lead == "by"
            else { return nil }
            // "At one point", "by two people": a count, not a time.
            guard g[4] != nil || g[3] != nil || !notTimes.contains(next ?? "") else { return nil }
            return "at " + clock(hour, g[3]) + (g[4].map { " " + $0.replacingOccurrences(of: ".", with: "") } ?? "")
        }),
        (phrase(hourWord + #"(?:\s+"# + minuteWords + #")?\s*(am|pm)"#), { g, _ in
            guard let hour = clockHour(g[1]!), g[1]!.first?.isLetter == true || g[2] != nil else { return nil }
            return clock(hour, g[2]) + " " + g[3]!
        }),
        (phrase(#"(?<!at\s)(?<!@\s)(?<!by\s)(?<!around\s)"# + #"(\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)(?:\s+"# + minuteWords + #")?(?=\s+(?:in\s+the\s+(?:morning|afternoon|evening)|at\s+night|tonight))"#), { g, _ in
            guard let hour = clockHour(g[1]!) else { return nil }
            return "at " + clock(hour, g[2])
        }),
    ]

    /// Words after "at five" that make it a count: "at one point", "by two votes".
    private static let notTimes: Set<String> = ["point", "points", "time", "times", "of", "people", "votes", "percent",
                                                "places", "guys", "more", "less", "or", "to", "days", "weeks", "months",
                                                "years", "hours", "minutes", "dollars", "bucks", "items", "things"]

    private static func clockHour(_ word: String) -> Int? {
        guard let hour = Int(word) ?? numberWords[word.lowercased()], (1...12).contains(hour) else { return nil }
        return hour
    }

    /// "5", or "5:30" with the minutes said.
    private static func clock(_ hour: Int, _ minutes: String?) -> String {
        guard let minutes = minutes?.lowercased(), !minutes.contains("clock") else { return "\(hour)" }
        let parts = minutes.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        var value = 0
        for part in parts where part != "oh" { value += numberWords[part] ?? 0 }
        return "\(hour):" + pad(value)
    }

    fileprivate static let emptyBrackets = try! NSRegularExpression(pattern: #"\( *\)|\[ *\]"#)
    fileprivate static let loosePunctuation = try! NSRegularExpression(pattern: #"(^| )[.,;:!?]+(?= |$)"#)
    fileprivate static let spaceRuns = try! NSRegularExpression(pattern: #"\s+"#)

    // MARK: repeats

    private static let weekday = #"(sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tues|tue|wed|weds|thurs|thur|thu|fri|sat)"#
    private static let weekdays = #"(sundays|mondays|tuesdays|wednesdays|thursdays|fridays|saturdays)"#
    private static let partOfDay = #"(morning|afternoon|evening|night)"#

    private static func dayIndex(_ name: String?) -> Int? {
        guard let name = name?.lowercased() else { return nil }
        return weekdayNames[name] ?? weekdayNames[String(name.dropLast())]
    }

    /// Weekly on the days said, in the order said: "every tuesday and friday" is on both, but
    /// "every monday or tuesday" only the first.
    private static func onDays(_ hit: Hit, period: String?) -> Rhythm {
        let said = hit.group(0)?.lowercased() ?? ""
        var days: [Int] = []
        for word in said.split(whereSeparator: { !$0.isLetter }) {
            if let day = dayIndex(String(word)), !days.contains(day) { days.append(day) }
        }
        if said.range(of: #"\bor\b"#, options: .regularExpression) != nil { days = Array(days.prefix(1)) }
        return Rhythm(kind: .weekly, weekday: days.first, period: repeatPeriod(period), others: Array(days.dropFirst()))
    }

    fileprivate static func repeatPeriod(_ word: String?) -> Period? {
        switch word?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "s")) {
        case "morning": return Period(hour: 9, ends: 12 * 60, today: false, meridiem: "am")
        case "afternoon": return Period(hour: 15, ends: 18 * 60, today: false, meridiem: "pm")
        case "evening": return Period(hour: 18, ends: 22 * 60, today: false, meridiem: "pm")
        case "night", "nightly": return Period(hour: 20, ends: 24 * 60, today: false, meridiem: "pm")
        default: return nil
        }
    }

    fileprivate struct RhythmRule {
        let pattern: NSRegularExpression
        let bare: Bool                       // said bare ("weekly"), so only when nothing more of a noun follows
        let make: (Hit) -> Rhythm?
    }

    fileprivate static let rhythms: [RhythmRule] = [
        RhythmRule(pattern: phrase(#"(?:every|each)\s+(?:other|second|alternate)\s+"# + weekday + #"(?:\s+"# + partOfDay + ")?"), bare: false) {
            Rhythm(kind: .biweekly, weekday: dayIndex($0.group(1)), period: repeatPeriod($0.group(2)))
        },
        RhythmRule(pattern: phrase(#"(?:every|each)\s+(?:other|second|alternate)\s+week|every\s+(?:2|two)\s+weeks|every\s+fortnight|every\s+14\s+days"#), bare: false) { _ in
            Rhythm(kind: .biweekly)
        },
        RhythmRule(pattern: phrase(#"bi-?weekly|fortnightly"#), bare: true) { _ in Rhythm(kind: .biweekly) },
        RhythmRule(pattern: phrase(#"(?:on\s+)?the\s+(\d{1,2}(?:st|nd|rd|th)|"# + ordinalPattern + #"|last\s+day)\s+of\s+(?:every|each)\s+month|(?:every|each)\s+month\s+on\s+the\s+(\d{1,2}(?:st|nd|rd|th)|"# + ordinalPattern + #"|last\s+day)"#), bare: false) { hit in
            guard let day = ordinalValue(hit.group(1) ?? hit.group(2)) else { return nil }
            return Rhythm(kind: .monthly, monthDay: day)
        },
        RhythmRule(pattern: phrase(#"(?:every|each)\s+"# + weekday + #"(?:\s*(?:,|and|&|or)\s*"# + weekday + #")*(?:\s+"# + partOfDay + ")?"), bare: false) {
            onDays($0, period: $0.groups.last ?? nil)
        },
        RhythmRule(pattern: phrase(#"on\s+"# + weekdays + #"(?:\s*(?:,|and|&)\s*"# + weekdays + #")*(?:\s+"# + partOfDay + "s?)?"), bare: false) {
            onDays($0, period: $0.groups.last ?? nil)
        },
        RhythmRule(pattern: phrase(weekdays + #"(?:\s*(?:,|and|&)\s*"# + weekdays + #")*(?:\s+"# + partOfDay + "s?)?"), bare: true) {
            onDays($0, period: $0.groups.last ?? nil)
        },
        RhythmRule(pattern: phrase(#"(?:every|each)\s+(?:single\s+)?(?:weekday|work\s?day|working\s+day|business\s+day)(?:\s+"# + partOfDay + #")?|on\s+weekdays|mondays?\s+(?:through|thru|to)\s+fridays?"#), bare: false) {
            Rhythm(kind: .weekdays, period: repeatPeriod($0.group(1)))
        },
        RhythmRule(pattern: phrase(#"weekdays"#), bare: true) { _ in Rhythm(kind: .weekdays) },
        RhythmRule(pattern: phrase(#"(?:every|each)\s+weekend|on\s+weekends"#), bare: false) { _ in Rhythm(kind: .weekly, weekday: 6) },
        RhythmRule(pattern: phrase(#"weekends"#), bare: true) { _ in Rhythm(kind: .weekly, weekday: 6) },
        RhythmRule(pattern: phrase(#"(?:every|each)\s+(?:single\s+)?"# + partOfDay), bare: false) {
            Rhythm(kind: .daily, period: repeatPeriod($0.group(1)))
        },
        RhythmRule(pattern: phrase(#"(?:every|each)\s+(?:single\s+)?day(?:\s+(?:in\s+the\s+|at\s+)?"# + partOfDay + #")?|once\s+a\s+day|every\s+24\s+hours"#), bare: false) {
            Rhythm(kind: .daily, period: repeatPeriod($0.group(1)))
        },
        RhythmRule(pattern: phrase(#"everyday|daily|nightly"#), bare: true) {
            Rhythm(kind: .daily, period: $0.group(0)?.lowercased() == "nightly" ? repeatPeriod("night") : nil)
        },
        RhythmRule(pattern: phrase(#"(?:every|each)\s+week|once\s+a\s+week|every\s+7\s+days"#), bare: false) { _ in Rhythm(kind: .weekly) },
        RhythmRule(pattern: phrase(#"weekly"#), bare: true) { _ in Rhythm(kind: .weekly) },
        RhythmRule(pattern: phrase(#"(?:every|each)\s+month|once\s+a\s+month"#), bare: false) { _ in Rhythm(kind: .monthly) },
        RhythmRule(pattern: phrase(#"monthly"#), bare: true) { _ in Rhythm(kind: .monthly) },
        RhythmRule(pattern: phrase(#"(?:every|each)\s+year|once\s+a\s+year|every\s+12\s+months|annually"#), bare: false) { _ in Rhythm(kind: .yearly) },
        RhythmRule(pattern: phrase(#"yearly"#), bare: true) { _ in Rhythm(kind: .yearly) },
    ]

    private static let ordinalPattern = #"(?:twenty|thirty)[\s-](?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth)|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|thirteenth|fourteenth|fifteenth|sixteenth|seventeenth|eighteenth|nineteenth|twentieth|thirtieth"#

    /// "1st", "first", "last day" (0).
    private static func ordinalValue(_ text: String?) -> Int? {
        guard let text = text?.lowercased() else { return nil }
        if text.hasPrefix("last") { return 0 }
        if let value = Int(text.prefix { $0.isNumber }), (1...31).contains(value) { return value }
        return ordinals[text.replacingOccurrences(of: "  ", with: " ")]
    }

    // MARK: broad dates

    fileprivate struct HorizonRule {
        let pattern: NSRegularExpression
        /// The day ("" for none on purpose), or nil to pass the match by.
        let make: (Hit, Clock) -> String?
    }

    private static let month = #"(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\.?"#

    fileprivate static let horizons: [HorizonRule] = [
        HorizonRule(pattern: phrase(#"(?:(?:by|before|until|till)\s+)?(?:the\s+)?end\s+of\s+(?:the\s+|this\s+)?(?:quarter|semester|term|school\s+year)|(?:sometime\s+|later\s+)?this\s+(?:quarter|semester|term)"#)) { _, _ in "" },
        HorizonRule(pattern: phrase(#"(?:the\s+)?week\s+after\s+next"#)) { _, c in
            c.text(c.adding(c.weekStartDay, 14))
        },
        // "A week from friday": the coming friday, and a week on.
        HorizonRule(pattern: phrase(#"(an?|one|two|three|four|five|six|\d)\s+(days?|weeks?)\s+from\s+(?:this\s+)?"# + weekday)) { hit, c in
            let said = hit.group(1)!.lowercased()
            guard let count = said.hasPrefix("a") ? 1 : Int(said) ?? numberWords[said], let day = dayIndex(hit.group(3)) else { return nil }
            let coming = c.adding(c.today, (day - c.weekday + 7) % 7)
            return c.text(coming, adding: hit.group(2)!.lowercased().hasPrefix("week") ? count * 7 : count)
        },
        HorizonRule(pattern: phrase(#"(?:(?:by|before|until|till)\s+)?(?:the\s+)?end\s+of\s+next\s+week|late\s+next\s+week"#)) { _, c in
            c.text(c.adding(c.weekStartDay, 7), adding: (5 - c.weekStart + 7) % 7)
        },
        HorizonRule(pattern: phrase(#"early\s+next\s+week|(?:the\s+)?(?:beginning|start)\s+of\s+next\s+week"#)) { _, c in
            c.text(c.adding(c.weekStartDay, 7))
        },
        HorizonRule(pattern: phrase(#"(?:(?:by|before|until|till)\s+)?(?:the\s+)?end\s+of\s+(?:the\s+|this\s+)?week|(?:sometime\s+|later\s+)?this\s+week"#)) { _, c in
            let friday = c.adding(c.weekStartDay, (5 - c.weekStart + 7) % 7)
            return friday >= c.today ? c.text(friday) : c.text(c.weekStartDay, adding: 6)
        },
        HorizonRule(pattern: phrase(#"(?:(?:sometime|some\s+time)\s+)?(?:(?:by|before|until|till|in|at)\s+)?(?:(early|mid|late)[\s-]+|(?:the\s+)?(beginning|start|middle|end)\s+of\s+)?next\s+month"#)) { hit, c in
            c.text(c.date(c.year, c.month + 1, partDay(hit.group(1) ?? hit.group(2)))!)
        },
        HorizonRule(pattern: phrase(#"(?:(?:by|before|until|till)\s+)?(?:the\s+)?end\s+of\s+(?:the\s+|this\s+)?month|month\s+end|(?:sometime\s+|later\s+)?this\s+month"#)) { _, c in
            c.text(c.date(c.year, c.month, 0)!)
        },
        HorizonRule(pattern: phrase(#"(?:(?:sometime|some\s+time)\s+)?(?:(?:by|before|until|till|in)\s+)?(?:(early|mid|late)[\s-]+|(?:the\s+)?(beginning|start|middle|end)\s+of\s+)?next\s+year"#)) { hit, c in
            let part = hit.group(1) ?? hit.group(2)
            let month = ["mid": 7, "middle": 7, "late": 10, "end": 12][part?.lowercased() ?? ""] ?? 1
            return c.text(c.date(c.year + 1, month, month == 12 ? 31 : 1)!)
        },
        HorizonRule(pattern: phrase(#"(?:(?:by|before|until|till)\s+)?(?:the\s+)?end\s+of\s+(?:the\s+|this\s+)?year|(?:by\s+)?year\s+end|(?:sometime\s+|later\s+)?this\s+year"#)) { _, c in
            c.text(c.date(c.year, 12, 31)!)
        },
        // "by january", "early november", "the end of december", "sometime in march": a month and
        // no day (with a day, tod reads it).
        HorizonRule(pattern: phrase(#"(?:(sometime|some\s+time)\s+)?(?:(in|by|before|until|till|around|during|this|next|starting|beginning|from)\s+)?(?:(early|mid|late)[\s-]+|(?:the\s+)?(beginning|start|middle|end)\s+of\s+)?(?:(in|by|during)\s+)?"# + month + #"(?!\s*-?\d)(?!\s+(?:the\s+)?\d)"#)) { hit, c in
            let prefix = [hit.group(1), hit.group(2), hit.group(3), hit.group(4), hit.group(5)].compactMap { $0?.lowercased() }
            guard !prefix.isEmpty, let month = monthIndex[hit.group(6)!.lowercased()] else { return nil }
            let part = hit.group(3) ?? hit.group(4)
            var year = c.year
            if month < c.month || (prefix.contains("next") && month <= c.month) { year += 1 }
            var day = c.date(year, month, partDay(part))!
            if prefix.contains("before") { day = c.adding(c.date(year, month, 1)!, -1) }
            return c.text(max(day, c.today))
        },
    ]

    /// The day a part of a month means: early 1st, mid 15th, late 20th, end the last (0).
    private static func partDay(_ part: String?) -> Int {
        switch part?.lowercased() {
        case "mid", "middle": return 15
        case "late": return 20
        case "end": return 0
        default: return 1
        }
    }

    /// "On the 1st", "by the 5th".
    fileprivate static let ordinalDay = phrase(#"(?:(?:on|by|due|for|until|before)\s+)?(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)"#)

    fileprivate static let soon = phrase(#"as\s+soon\s+as\s+(?:possible|you\s+can|i\s+can)|asap|right\s+now|right\s+away|immediately|straight\s+away|now"#)

    // MARK: times of day

    fileprivate struct PeriodRule {
        let pattern: NSRegularExpression
        let make: (Hit) -> Period?
    }

    fileprivate static let periods: [PeriodRule] = [
        PeriodRule(pattern: phrase(#"late\s+(?:tonight|tonite)|late\s+at\s+night"#)) { _ in
            Period(hour: 22, ends: 24 * 60, today: true, meridiem: "pm")
        },
        PeriodRule(pattern: phrase(#"tonight|tonite"#)) { _ in Period(hour: 20, ends: 24 * 60, today: true, meridiem: "pm") },
        PeriodRule(pattern: phrase(#"(?:(?:by|at|before)\s+)?(?:the\s+)?(?:end\s+of\s+(?:the\s+)?(?:work\s?|business\s+)?day|end\s+of\s+today|eod|cob|close\s+of\s+business)"#)) { _ in
            Period(hour: 17, ends: 24 * 60, today: true, meridiem: nil)
        },
        PeriodRule(pattern: phrase(#"(?:(?:at|by|around|before)\s+)?(?:lunchtime|lunch\s+time)|(?:at|by|around|before)\s+lunch"#)) { _ in
            Period(hour: 12, ends: 14 * 60, today: false, meridiem: nil)
        },
        PeriodRule(pattern: phrase(#"(?:(?:at|by|around|before)\s+)?(?:dinnertime|dinner\s+time)"#)) { _ in
            Period(hour: 18, ends: 21 * 60, today: false, meridiem: nil)
        },
        PeriodRule(pattern: phrase(#"first\s+thing(?:\s+in\s+the\s+morning)?"#)) { _ in
            Period(hour: 9, ends: 12 * 60, today: false, meridiem: "am")
        },
        PeriodRule(pattern: phrase(#"(early|late)\s+in\s+the\s+(morning|afternoon|evening)"#)) { hit in
            shade(repeatPeriod(hit.group(2)), hit.group(1), today: false)
        },
        PeriodRule(pattern: phrase(#"(?:(in\s+the|this|at|by|during\s+the|around)\s+)?(?:(early|late)\s+)?(morning|afternoon|evening|night)"#)) { hit in
            let marker = hit.group(1)?.lowercased()
            let said = marker != nil || weekdayNames[hit.before ?? ""] != nil
                || ["tomorrow", "tmrw", "tmr", "tomorow", "tommorow", "today", "weekend", "tonight"].contains(hit.before ?? "")
                || (hit.group(2) != nil && hit.free)
            guard said, marker != "at" || hit.group(3)?.lowercased() == "night" else { return nil }
            return shade(repeatPeriod(hit.group(3)), hit.group(2), today: marker == "this")
        },
    ]

    /// A part of the day said earlier or later in it: "early morning" 7, "late night" 10.
    private static func shade(_ period: Period?, _ shade: String?, today: Bool) -> Period? {
        guard let period else { return nil }
        var hour = period.hour
        switch (shade?.lowercased(), period.hour) {
        case ("early", 9): hour = 7
        case ("late", 9): hour = 11
        case ("early", 15): hour = 13
        case ("late", 15): hour = 16
        case ("early", 18): hour = 17
        case ("late", 18): hour = 20
        case ("early", 20): hour = 19
        case ("late", 20): hour = 22
        default: break
        }
        return Period(hour: hour, ends: period.ends, today: today, meridiem: period.meridiem)
    }

    /// "Someday", "eventually", "no rush": no date on purpose.
    fileprivate static let undatedWords = phrase(#"someday|some\s+day|eventually|at\s+(?:some|one)\s+point|(?<!in\s)(?<!a\s)one\s+day|long[\s-]?term|in\s+the\s+long\s+run|whenever(?:\s+i\s+(?:can|get\s+(?:a|the)\s+chance|have\s+time))?|when\s+i\s+(?:have\s+(?:the\s+)?time|get\s+(?:a|the)\s+chance|can)|no\s+rush|no\s+deadline|no\s+due\s+date|in\s+the\s+(?:near\s+)?future|sometime"#)
    /// Words before "one day" that make it a length of time: "for one day", "every one day".
    fileprivate static let counted: Set<String> = ["for", "per", "the", "every", "each", "that", "this", "only", "just",
                                                   "within", "than", "about", "over", "under", "first", "last", "next", "of"]
}

private func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

private extension Int {
    func floorDivided(by d: Int) -> Int { self >= 0 ? self / d : (self - d + 1) / d }
    func floorModulo(_ d: Int) -> Int { ((self % d) + d) % d }
}
