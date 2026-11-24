import Foundation

/// A line typed to add to toyl's list, read for its days as toyl's own quick add reads them (its
/// `Quick`), for when Oyl adds it itself, toyl's command not being there or having broken: TickTick's
/// shorthand said in full first ("td", "tmr", "eow", "in 3d", see `Shorthand`), and "yd" or
/// "yesterday" toyl's own; a deadline said with "due", else a day said loosely ("by fri", "next
/// week", "end of the month"), which toyl takes as when it's due, as it has no aims; then tod's
/// reading. A time alone that's already gone by today ("9am" said at 6 pm) is tomorrow's. The
/// #list is Oyl's own, as `TodQuick` reads it.
enum ToylQuick {
    static func parse(_ input: String, now: Date = Date(), weekStart: Int = 1) -> TodQuick {
        let ns = input as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let tag = TodQuick.tagPattern.firstMatch(in: input, range: whole).map { ns.substring(with: $0.range(at: 1)) }
        var text = TodQuick.tagPattern.stringByReplacingMatches(in: input, range: whole, withTemplate: " ")
        text = Shorthand.spelledOut(text)
        let saidYesterday = cut(Shorthand.yesterday, from: &text)
        let yesterday = cut(Shorthand.yesterdayShort, from: &text) || saidYesterday

        let today = day(now)
        var due: String?, time: String?, read = false
        // Only a time was said (tod makes that today).
        var timeOnly = false
        if matches(dueWord, in: text) {
            // "due" only goes when a day comes with it ("find out when rent is due" keeps it).
            let stripped = replacing(dueWord, in: text, with: " ")
            let hard = TodQuick.read(stripped, now: now, weekStart: weekStart)
            if hard.due != nil || hard.time != nil {
                (due, time) = (hard.due, hard.time)
                text = consumed(hard, from: stripped) ? "" : hard.title
                if due == nil { due = IdeaQuick.takeAim(&text, now: now, weekStart: weekStart) }
                timeOnly = hard.time != nil && hard.due == today && !matches(todayWord, in: stripped)
                read = true
            }
        }
        if !read {
            let aim = IdeaQuick.takeAimTimed(&text, now: now, weekStart: weekStart)
            let before = text
            let hard = TodQuick.read(text, now: now, weekStart: weekStart)
            (due, time) = (hard.due, hard.time)
            text = consumed(hard, from: before) ? "" : hard.title
            let timeAlone = hard.time != nil && hard.due == today && !matches(todayWord, in: before)
            timeOnly = timeAlone && aim == nil
            if let aim {
                if let aimTime = aim.time, time == nil {
                    // "by fri 5pm": that day, at that time.
                    (due, time) = (aim.day, aimTime)
                } else if timeAlone || due == nil {
                    // "5pm by fri": the aim's day, at that time; "by fri": that day.
                    due = aim.day
                }
            } else if timeAlone, !yesterday, let said = time, let at = moment(today, said), at < now {
                // "9am" said at 6pm: tomorrow's, not late the moment it's made.
                due = adding(1, to: today)
            }
        }
        // "yd", "yesterday 3pm": yesterday (late already: for what's owed).
        if yesterday, due == nil || timeOnly { due = adding(-1, to: today) }
        var title = tidy(text)
        if title.isEmpty { title = tidy(TodQuick.tagPattern.stringByReplacingMatches(in: input, range: whole, withTemplate: " ")) }
        return TodQuick(title: title, due: due, time: time, list: tag)
    }

    // MARK: - Pieces

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    private static func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    private static func adding(_ days: Int, to day: String) -> String? {
        date(day).flatMap { calendar.date(byAdding: .day, value: days, to: $0) }.map(Self.day)
    }

    private static func moment(_ day: String, _ time: String) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let noon = date(day) else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: noon)
    }

    /// Nothing but a day or a time was said: tod's reading gives the line back whole as the title.
    private static func consumed(_ read: (title: String, due: String?, time: String?), from before: String) -> Bool {
        (read.due != nil || read.time != nil) && tidy(read.title) == tidy(before)
    }

    static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:-–—·")))
    }

    private static func pattern(_ text: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: text, options: [.caseInsensitive])
    }

    private static let todayWord = pattern(#"\b(?:today|tonight|tod|this\s+(?:morning|afternoon|evening))\b"#)
    private static let dueWord = pattern(#"\bdue(?:\s+(?:by|on|before))?\b"#)

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    /// Takes every match out; whether there was one.
    private static func cut(_ pattern: NSRegularExpression, from text: inout String) -> Bool {
        guard matches(pattern, in: text) else { return false }
        text = replacing(pattern, in: text, with: " ")
        return true
    }
}

/// Days said the quick way, as TickTick (and toyl) take them: `td`, `tmr`, `yd`, `nw`, `eow`, `in
/// 3d`. Each becomes the words the shared reading knows ("today", "next week", "in 3 days");
/// yesterday, which tod doesn't know, is toyl's own. The two-letter ones count only in lower case,
/// so "TD Bank" and "NW corner" stay as they are. (toyl's `Shorthand`, rule for rule: keep the two
/// in step.)
enum Shorthand {
    /// A whole word: nothing but a space (or the line's start) before it, no letter after.
    private static func word(_ words: String, caseSensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}#~/@_\x{E000}-])(?:"# + words + #")(?![\p{L}\p{N}_])"#,
                                 options: caseSensitive ? [] : [.caseInsensitive])
    }

    private static let rules: [(NSRegularExpression, String)] = [
        (word("td", caseSensitive: true), "today"),
        (word("tdy|2day|eod"), "today"),
        (word("tmro|tmrow|tmmrw|2moro|2morrow|2mrw"), "tomorrow"),
        (word("nw", caseSensitive: true), "next week"),
        (word("nm", caseSensitive: true), "next month"),
        (word("nxt"), "next"),
        (word("eonw"), "end of next week"),
        (word("eow"), "end of the week"),
        (word("eonm"), "end of next month"),
        (word("eom"), "end of the month"),
        (word("wknd|wkend"), "weekend"),
        (try! NSRegularExpression(pattern: #"\b(next|this)\s+wk\b"#, options: [.caseInsensitive]), "$1 week"),
        (try! NSRegularExpression(pattern: #"\bin\s+(\d{1,3})\s?(?:d|dy|dys)\b"#, options: [.caseInsensitive]), "in $1 days"),
        (try! NSRegularExpression(pattern: #"\bin\s+(\d{1,3})\s?(?:w|wk|wks)\b"#, options: [.caseInsensitive]), "in $1 weeks"),
        (try! NSRegularExpression(pattern: #"\bin\s+(\d{1,3})\s?(?:mo|mos|mth|mths)\b"#, options: [.caseInsensitive]), "in $1 months"),
    ]

    /// Yesterday, said in full or short ("due yesterday", "yday").
    static let yesterday = word(#"(?:(?:due|on|by|for|since)\s+)?(?:yesterday|yday|yest|ystd)"#)
    static let yesterdayShort = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}#~/@_\x{E000}-])(?:(?:[Dd]ue|[Oo]n|[Bb]y|[Ff]or)\s+)?yd(?![\p{L}\p{N}_])"#)

    /// The line with its shorthand said in full.
    static func spelledOut(_ text: String) -> String {
        var out = text
        for (pattern, template) in rules {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: template)
        }
        return out
    }
}
