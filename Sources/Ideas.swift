import SwiftUI

// Ideas to come back to: tod's brain dump, worked from the notch (and the phone). Every idea is
// one of three kinds, and comes back when it should:
//
// - **Due**: a deadline (tod's own `due`): it can't slip, so it's always in sight, soonest first,
//   counting down, and marked once it's late.
// - **By**: an aim, a day to have it done by, roughly (Oyl's `target`, kept in tod's data): it
//   can slip. It stays out of the way till its week comes, then comes up; past it, it says it's
//   slipped, and can be put off a week or a month.
// - **Someday**: no date at all. A month after it was jotted (or last kept), it asks if it's
//   still wanted: kept, given a month, or done with.
//
// Deadlines and aims are kept apart so the aims don't make the deadlines easy to ignore (as
// Amazing Marvin's due and end dates are, and Todoist's deadlines and dates); the aims come back
// as a tickler file's do, and the undated are looked over monthly, as a bullet journal's are.

/// What a line typed into the ideas field means: "essay due fri" is due Friday; "learn to make
/// pasta in a month or so" is aimed at a month from now; "sauna" is for someday. Deadlines are
/// read as tod reads them ("due", or a day on its own: "fri 5pm", "dec 5", "tomorrow"); aims are
/// a while off ("in 3 weeks", "next month", "early dec"), or any day said loosely ("by fri",
/// "around the 5th", "next week-ish", "~dec 1").
struct IdeaQuick: Equatable {
    let title: String
    let due: String?      // "YYYY-MM-DD", a deadline
    let time: String?     // "HH:MM"
    let target: String?   // "YYYY-MM-DD", an aim
    /// "HH:MM", said with the aim ("by fri 5pm"): for toyl, which takes an aim as a deadline.
    var targetTime: String? = nil

    static func parse(_ input: String, now: Date = Date(), weekStart: Int = 1) -> IdeaQuick {
        // "#" is only ever text here: tod's quick add would take it for a list.
        var text = replacing(spaces, in: input.replacingOccurrences(of: "#", with: Self.hash), with: " ")
        var due: String?, time: String?, target: String?, targetTime: String?
        let hasDue = matches(dueWord, in: text)
        if hasDue {
            // The deadline first, so "due next week" isn't taken for an aim.
            text = replacing(dueWord, in: text, with: " ")
            let hard = TodQuick.parse(text, now: now, weekStart: weekStart)
            due = hard.due
            time = hard.time
            text = hard.title
            (target, targetTime) = takeAimTimed(&text, now: now, weekStart: weekStart).map { ($0.day, $0.time) } ?? (nil, nil)
        } else {
            (target, targetTime) = takeAimTimed(&text, now: now, weekStart: weekStart).map { ($0.day, $0.time) } ?? (nil, nil)
            let hard = TodQuick.parse(text, now: now, weekStart: weekStart)
            due = hard.due
            time = hard.time
            text = hard.title
        }
        let title = replacing(spaces, in: text, with: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:-–—")))
            .replacingOccurrences(of: Self.hash, with: "#")
        return IdeaQuick(title: title, due: due, time: time, target: target, targetTime: targetTime)
    }

    /// "Today" … "Fri" … "Dec 5", as tod says a day, for a deadline; and its time, if it has one.
    static func describe(due: String, time: String?, now: Date = Date()) -> String {
        let day = TodQuick.describe(due: due, now: now)
        return time.map { day + " " + TodQuick.describe(time: $0) } ?? day
    }

    /// An aim, said as loosely as it was meant: "by Fri" within the week, else "early Dec",
    /// "mid Dec", "late Dec" ("late Dec 2027" in another year).
    static func describe(target: String, now: Date = Date()) -> String {
        guard let day = date(target) else { return target }
        let today = calendar.startOfDay(for: now)
        let ahead = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        if (0...6).contains(ahead) {
            switch ahead {
            case 0: return "by today"
            case 1: return "by tomorrow"
            default: return "by " + weekdayName.string(from: day)
            }
        }
        let parts = calendar.dateComponents([.year, .day], from: day)
        let part = parts.day! <= 10 ? "early" : parts.day! <= 20 ? "mid" : "late"
        let month = monthName.string(from: day)
        let year = parts.year == calendar.component(.year, from: now) ? "" : " \(parts.year!)"
        return "\(part) \(month)\(year)"
    }

    // MARK: - aims

    /// Takes the first aim out of `text`, if there's one: its day.
    static func takeAim(_ text: inout String, now: Date, weekStart: Int) -> String? {
        takeAimTimed(&text, now: now, weekStart: weekStart)?.day
    }

    /// The first aim, with the time said with it ("by fri 5pm"), if one was.
    static func takeAimTimed(_ text: inout String, now: Date, weekStart: Int) -> (day: String, time: String?)? {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        // A while off ("in a month or so", "next week", "early dec"): an aim, said loosely or not.
        for match in horizon.matches(in: text, range: whole) {
            guard let day = resolve(match, in: ns, now: now, weekStart: weekStart) else { continue }
            text = ns.replacingCharacters(in: match.range, with: " ")
            return (day, nil)
        }
        // A day said loosely: "by fri", "around the 5th", "~dec 1", "tomorrow-ish".
        for match in loose.matches(in: text, range: whole) {
            let after = ns.substring(from: match.range.location + match.range.length)
            let words = after.split(separator: " ", omittingEmptySubsequences: true).prefix(3).map(String.init)
            for count in stride(from: words.count, through: 1, by: -1) {
                let phrase = words.prefix(count).joined(separator: " ")
                let read = TodQuick.parse(phrase.replacingOccurrences(of: Self.hash, with: ""), now: now, weekStart: weekStart)
                guard let due = read.due, Self.isOnlyADay(read.title, phrase) else { continue }
                let span = (after as NSString).range(of: phrase)
                guard span.location != NSNotFound else { continue }
                var end = match.range.location + match.range.length + span.location + span.length
                if let tail = trailingSoft.firstMatch(in: text, range: NSRange(location: end, length: whole.length - end)),
                   tail.range.location == end {
                    end += tail.range.length
                }
                text = ns.replacingCharacters(in: NSRange(location: match.range.location, length: end - match.range.location), with: " ")
                return (due, read.time)
            }
        }
        // A day with a loose ending: "fri-ish", "dec 5 or so".
        if let tail = trailingSoft.firstMatch(in: text, range: whole) {
            let before = ns.substring(to: tail.range.location)
            let words = before.split(separator: " ", omittingEmptySubsequences: true).suffix(3).map(String.init)
            for count in stride(from: words.count, through: 1, by: -1) {
                let phrase = words.suffix(count).joined(separator: " ")
                let read = TodQuick.parse(phrase.replacingOccurrences(of: Self.hash, with: ""), now: now, weekStart: weekStart)
                guard let due = read.due, Self.isOnlyADay(read.title, phrase), before.hasSuffix(phrase) || before.hasSuffix(phrase + " ") else { continue }
                let start = (before as NSString).range(of: phrase, options: .backwards).location
                guard start != NSNotFound else { continue }
                text = ns.replacingCharacters(in: NSRange(location: start, length: tail.range.location + tail.range.length - start), with: " ")
                return (due, read.time)
            }
        }
        return nil
    }

    /// What's left of `phrase` once tod's read its day (`title`) is nothing: tod keeps the whole
    /// line as the title when there'd be none.
    private static func isOnlyADay(_ title: String, _ phrase: String) -> Bool {
        let left = title.trimmingCharacters(in: .whitespaces)
        return left.isEmpty || left.caseInsensitiveCompare(phrase.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// The day a horizon means: a span from today ("in 3 weeks"), the end of this or next week
    /// or month, or a part of a month ("early dec" the 7th, "mid" the 15th, "late" its last day;
    /// "by dec" its 1st, "dec" its 15th).
    private static func resolve(_ match: NSTextCheckingResult, in text: NSString, now: Date, weekStart: Int) -> String? {
        func group(_ name: String) -> String? {
            let range = match.range(withName: name)
            return range.location == NSNotFound ? nil : text.substring(with: range).lowercased()
        }
        let today = calendar.startOfDay(for: now)
        if let unit = group("unit"), let amount = group("amount").map(Self.amount) {
            // A span only with a word to say it's one ("in 3 weeks", "2 weeks or so"): "review 3
            // months of statements" and "plan 2 weeks of meals" are counts, not days.
            let said = text.substring(with: match.range).lowercased()
            guard said.range(of: #"^(?:by|in|within|around|about|roughly|sometime|aim(?:ing)?\s+for|~)\b|^~|(?:or\s+so|ish)$"#,
                             options: .regularExpression) != nil else { return nil }
            let component: Calendar.Component = unit.hasPrefix("day") ? .day : unit.hasPrefix("week") ? .weekOfYear : .month
            return calendar.date(byAdding: component, value: amount, to: today).map(day)
        }
        if let which = group("which"), let span = group("span") {
            let next = which.contains("next")
            if span.hasPrefix("weekend") {
                let sunday = (1 - calendar.component(.weekday, from: today) + 7) % 7
                return calendar.date(byAdding: .day, value: sunday + (next ? 7 : 0), to: today).map(day)
            }
            if span.hasPrefix("week") {
                // The last day of this week (or next), as tod's weeks start.
                let weekday = calendar.component(.weekday, from: today) - 1
                let toStart = (weekStart - weekday + 7) % 7
                return calendar.date(byAdding: .day, value: (toStart == 0 ? 7 : toStart) - 1 + (next ? 7 : 0), to: today).map(day)
            }
            guard let month = calendar.date(byAdding: .month, value: next ? 1 : 0, to: today),
                  let last = calendar.range(of: .day, in: .month, for: month)?.count else { return nil }
            var parts = calendar.dateComponents([.year, .month], from: month)
            parts.day = last
            return calendar.date(from: parts).map(day)
        }
        if let name = group("month"), let number = months.firstIndex(where: { name.hasPrefix($0) }) {
            let part = group("part")
            let by = group("by") != nil
            // A month on its own only with a word to say it's one ("by may", "in march", "early
            // june"): "may" and "march" are words too.
            let said = text.substring(with: match.range).lowercased()
            guard part != nil || said.range(of: #"^(?:by|in|around|about|roughly|sometime|aim(?:ing)?\s+for|~)"#, options: .regularExpression) != nil
            else { return nil }
            var parts = DateComponents(year: calendar.component(.year, from: today), month: number + 1, day: 1)
            guard let first = calendar.date(from: parts), let length = calendar.range(of: .day, in: .month, for: first)?.count else { return nil }
            switch part {
            case let part? where part.hasPrefix("early"): parts.day = 7
            case let part? where part.hasPrefix("mid"): parts.day = 15
            case .some: parts.day = length
            case nil: parts.day = by ? 1 : 15
            }
            guard var date = calendar.date(from: parts) else { return nil }
            // A month that's over: next year's. This month: this one (not before today).
            let monthEnd = calendar.date(from: DateComponents(year: parts.year, month: number + 1, day: length)) ?? date
            if monthEnd < today, let later = calendar.date(byAdding: .year, value: 1, to: date) {
                date = later
            } else if date < today {
                date = today
            }
            return day(date)
        }
        return nil
    }

    private static func amount(_ word: String) -> Int {
        let word = word.trimmingCharacters(in: .whitespaces)
        if let number = Int(word) { return number }
        if word.contains("couple") { return 2 }
        if word.contains("few") { return 3 }
        if word.contains("several") { return 4 }
        return ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                "ten": 10][word] ?? 1
    }

    // MARK: - patterns

    private static let hash = "\u{FF03}"
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let softBefore = #"(?:by|around|about|roughly|sometime|within|aim(?:ing)?\s+for|~)"#
    private static let softAfter = #"(?:\s+or\s+so|(?:\s+|-)ish)"#

    /// A horizon, a while off, with whatever loose words go with it.
    private static let horizon = pattern(
        #"(?:(?<by>\bby)\s+|\b(?:around|about|roughly|sometime|aim(?:ing)?\s+for|in)\s+|~\s*)*"#
        + #"(?:"#
        + #"(?:\b(?:in|within)\s+)?(?:about\s+|roughly\s+)?(?<amount>\b(?:\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|(?:a\s+)?couple(?:\s+of)?|(?:a\s+)?few|several))\s+(?<unit>(?:week|month)s?|days?(?=\s+or\s+so|(?:\s+|-)ish))\b"#
        + #"|\b(?:the\s+)?(?:end\s+of\s+)?(?:the\s+)?(?<which>this|next|end\s+of\s+(?:the|this)?|end\s+of\s+next)\s*(?<span>weekend|week|month)\b"#
        + #"|\b(?<part>early|mid|late|end\s+of)?\s*-?\s*(?<month>jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b(?!\s*\d)"#
        + #")"# + softAfter + "?")

    /// A loose word before a day: "by", "around", "~"…
    private static let loose = pattern(#"(?:\b(?:by|around|about|roughly|sometime|aim(?:ing)?\s+for)\b|~)\s*"#)
    /// A loose ending after one: "or so", "-ish".
    private static let trailingSoft = pattern(softAfter + #"\b"#)
    private static let dueWord = pattern(#"\bdue(?:\s+(?:by|on|before))?\b"#)
    private static let spaces = pattern(#"\s+"#)

    private static func pattern(_ source: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    // MARK: - days

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    static func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year!)-" + String(format: "%02d-%02d", parts.month!, parts.day!)
    }

    static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static let weekdayName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    private static let monthName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()
}

/// The ideas in order, each where it belongs: due, soonest first (late ones first of all); aims
/// coming up within the week (slipped ones first); aims further off, soonest first; then
/// someday, the ones asking to be looked over first, then newest first.
enum IdeaBoard {
    struct Row: Identifiable, Equatable {
        enum Kind: String, CaseIterable, Codable {
            case due, soon, later, someday

            var title: String {
                switch self {
                case .due: return "Due"
                case .soon: return "Coming up"
                case .later: return "Later"
                case .someday: return "Someday"
                }
            }
        }

        let id: String
        let title: String
        let kind: Kind
        /// When, as it's said: "Fri 5 PM", "2 days late", "by Fri", "slipped 3 days", "mid Dec";
        /// or, for someday, nothing, or "still want it?" once it's been a month.
        let label: String
        /// Past its deadline, or slipped past its aim.
        let overdue: Bool
        /// Undated, and not looked at for a month.
        let stale: Bool
        /// Pulled into toyl from an email or Canvas: the mark it carries (see `TodStore.Task.mark`).
        var mark: String?
    }

    /// How far ahead an aim comes up, and how long an undated idea goes before it asks.
    static let comingUp = 7
    static let stale: TimeInterval = 30 * 86_400

    /// `aims`: whether there are any (tod's ideas have them, toyl's don't: with toyl, one with
    /// only an aim is undated, as toyl shows it).
    static func rows(_ ideas: [TodStore.Task], now: Date = Date(), aims: Bool = true) -> [Row] {
        let calendar = IdeaQuick.calendar, today = calendar.startOfDay(for: now)
        func daysFromToday(_ text: String) -> Int? {
            IdeaQuick.date(text).flatMap { calendar.dateComponents([.day], from: today, to: $0).day }
        }
        func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }
        var placed: [(row: Row, key: Double)] = []
        for idea in ideas where !idea.done {
            if let due = idea.due {
                let late = idea.dueDate.map { $0 < now } ?? false
                let ahead = daysFromToday(due) ?? 0
                let label = late && ahead < 0 ? "\(days(-ahead)) late" : IdeaQuick.describe(due: due, time: idea.time, now: now)
                placed.append((Row(id: idea.id, title: idea.title, kind: .due, label: label, overdue: late, stale: false, mark: idea.mark),
                               idea.dueDate?.timeIntervalSince1970 ?? 0))
            } else if aims, let target = idea.target, let ahead = daysFromToday(target) {
                let kind: Row.Kind = ahead < comingUp ? .soon : .later
                let label = ahead < 0 ? "slipped \(days(-ahead))" : IdeaQuick.describe(target: target, now: now)
                placed.append((Row(id: idea.id, title: idea.title, kind: kind, label: label, overdue: ahead < 0, stale: false,
                                   mark: idea.mark), Double(ahead)))
            } else {
                let since = idea.kept ?? idea.createdAt
                let stale = now.timeIntervalSince(since) > stale
                placed.append((Row(id: idea.id, title: idea.title, kind: .someday, label: stale ? "still want it?" : "", overdue: false,
                                   stale: stale, mark: idea.mark),
                               (stale ? -1e12 : 0) - idea.createdAt.timeIntervalSince1970))
            }
        }
        let order = Row.Kind.allCases
        return placed.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.row.kind != y.row.kind { return order.firstIndex(of: x.row.kind)! < order.firstIndex(of: y.row.kind)! }
            return x.key != y.key ? x.key < y.key : a.offset < b.offset
        }
        .map(\.element.row)
    }

    /// How tall `rows` stand on the page: each kind under its heading (with none, room for the hint).
    static func height(of rows: [Row]) -> CGFloat {
        guard !rows.isEmpty else { return 30 }
        return CGFloat(rows.count) * Layout.ideaRowHeight + CGFloat(Set(rows.map(\.kind)).count) * Layout.ideaHeaderHeight
    }

    /// The day an aim's put off to: `days` past it, or past today if it's slipped (or there's none).
    static func putOff(_ target: String?, by days: Int, now: Date = Date()) -> String {
        let calendar = IdeaQuick.calendar, today = calendar.startOfDay(for: now)
        let from = max(target.flatMap(IdeaQuick.date) ?? today, today)
        let unit: Calendar.Component = days >= 28 ? .month : .day
        return IdeaQuick.day(calendar.date(byAdding: unit, value: unit == .month ? days / 28 : days, to: from) ?? from)
    }
}

extension TodStore {
    /// The brain dump's ideas, open ones and done, as tod keeps them. With toyl, its ideas as toyl
    /// shows them: its ideas list (the brain dump), and what's put off for someday from any list
    /// that isn't put away.
    var ideas: [Task] {
        guard let dump = lists.first(where: \.isDump) else { return [] }
        guard source == .toyl else { return tasks.filter { $0.listId == dump.id } }
        let away = Set(lists.filter(\.isArchived).map(\.id))
        return tasks.filter { $0.listId == dump.id || ($0.someday && !away.contains($0.listId)) }
    }

    /// Ideas can have aims (a day to have one done by, roughly): tod's can, toyl's can't (toyl
    /// reads "by fri" as a deadline).
    var hasAims: Bool { source != .toyl }

    /// Jots an idea down, and its id; nil if there's nothing to add, or no list. With toyl, through
    /// toyl's own command (`toyl idea`), so it's read just as toyl reads it; else (or if toyl's
    /// command isn't there or fails) into the brain dump, read as `IdeaQuick` reads it, an aim
    /// taken as a deadline for toyl.
    @discardableResult
    func addIdea(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let folder = toylFolder, let id = ToylCommand.idea(text, in: folder) {
            // Seen at once, so its screenshot can go with it.
            readNow()
            return id
        }
        let idea = IdeaQuick.parse(text, weekStart: weekStart)
        guard let dump = lists.first(where: \.isDump) else { return nil }
        if !hasAims {
            // An aim's a deadline here, at the time said with it ("by fri 5pm"), if one was.
            let time = idea.due == nil ? idea.targetTime ?? idea.time : idea.time
            return add(title: idea.title, due: idea.due ?? idea.target, time: time, listId: dump.id)?.id
        }
        return add(title: idea.title, due: idea.due, time: idea.time, listId: dump.id, target: idea.target)?.id
    }

    /// An idea's aim put off `days` (a week, or a month), or given one if it's undated.
    func putOff(_ id: String, by days: Int) {
        edit(id) { task in
            task.target = IdeaBoard.putOff(task.target, by: days)
            task.kept = Date()
        }
    }

    /// An undated idea kept another month.
    func keep(_ id: String) {
        edit(id) { $0.kept = Date() }
    }
}

// MARK: - The page

/// The ideas page: a field to jot one down (with its deadline or aim, if it has one, in the same
/// line), or a screenshot to jot one about (its camera), and the ideas under it, each where it
/// belongs (see `IdeaBoard`), to check off, put off a week or a month, or keep; one about a
/// screenshot has it small by its title. In Midnight Oyl the rows drift in one after another, an
/// aim's when in the flourish's italic and a deadline's in Bodoni's figures.
struct IdeasPage: View {
    @ObservedObject var tod: TodStore
    @ObservedObject var state: NotchState

    var body: some View {
        IdeasLayout(tod: tod, draft: state.ideaDraft, pictures: state.ideaPictures, editing: state.isEditing,
                    listHeight: state.ideaListHeight, resign: state.resignKeyboard, takeShot: state.takeIdeaShot,
                    projects: state.showsProjects ? state.projects : nil)
    }
}

/// The ideas page itself, given what's being jotted, the ideas' screenshots, whether its field
/// has the keyboard, how tall its list may stand before it scrolls, how to give the keyboard
/// back, and how to take a screenshot for an idea.
struct IdeasLayout: View {
    @ObservedObject var tod: TodStore
    @ObservedObject var draft: IdeaDraft
    @ObservedObject var pictures: IdeaPictures
    let editing: Bool
    let listHeight: CGFloat
    let resign: () -> Void
    var takeShot: () -> Void = {}
    /// Your projects, if they're on: an idea tagged with one's #name goes into it, and any idea
    /// can be made a project of its own.
    var projects: ProjectStore?
    @StateObject private var focus = LocalState(0)
    @Environment(\.notchTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let rows = IdeaBoard.rows(tod.ideas, now: context.date, aims: tod.hasAims)
            VStack(alignment: .leading, spacing: 10) {
                field
                if !tod.isAvailable {
                    hint(tod.source == .toyl ? "toyl's list can't be read just now. It's back as soon as it can be."
                         : "tod isn't here yet: Oyl keeps ideas in tod's brain dump. Open tod once, then come back.")
                } else if rows.isEmpty {
                    hint(tod.hasAims ? "Jot down anything to come back to. “due fri” is a deadline; “by next month” or “in a month or so” is an aim; nothing’s for someday."
                         : "Jot down anything to come back to: toyl's ideas. “fri” or “by next month” is a deadline; nothing’s for someday. (In toyl, “?” makes one.)")
                } else if IdeaBoard.height(of: rows) <= listHeight + 0.5 {
                    list(rows)
                } else {
                    ScrollView(.vertical, showsIndicators: false) { list(rows) }
                        .frame(height: listHeight)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .animation(NotchView.open, value: rows.map(\.id))
        }
        .onAppear {
            takeKeyboard()
            // Screenshots whose ideas are gone from the list go too.
            if tod.isAvailable, !tod.tasks.isEmpty { pictures.prune(keeping: Set(tod.tasks.map(\.id))) }
        }
        .onChange(of: draft.wantsKeyboard) { _, _ in takeKeyboard() }
    }

    /// Back from a screenshot: straight to the keyboard, for what the idea is.
    private func takeKeyboard() {
        guard draft.wantsKeyboard else { return }
        draft.wantsKeyboard = false
        focus.value += 1
    }

    private var field: some View {
        let shot = draft.shot.flatMap { _ in draft.shotImage }
        return HStack(spacing: 8) {
            if let shot {
                ShotChip(image: shot, drop: draft.drop)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else {
                Image(systemName: "lightbulb.fill")
                    .notchSymbol(size: 11, weight: .semibold)
                    .foregroundStyle(.white)
            }
            ReminderField(text: $draft.text,
                          placeholder: (shot == nil ? "Dump an idea…   " : "What's the idea?   ")
                              + (tod.hasAims ? "“due fri”, “by next month”, “in a month or so”" : "“fri”, “by next month”, or nothing"),
                          onSubmit: submit, onCancel: cancel, focus: focus.value)
            if !draft.text.isEmpty {
                Image(systemName: "return")
                    .notchSymbol(size: 10, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.4))
            }
            if tod.isAvailable {
                Button(action: takeShot) {
                    Image(systemName: "camera.viewfinder")
                        .notchSymbol(size: 12, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .help(shot == nil ? "Screenshot something to jot an idea about" : "Take another screenshot instead")
            }
        }
        .padding(.leading, shot == nil ? 12 : 4)
        .padding(.trailing, tod.isAvailable ? 8 : 12)
        .frame(height: 28)
        .background(Capsule().fill(.white.opacity(editing ? 0.14 : 0.08)))
        .animation(.easeOut(duration: 0.25), value: draft.shot)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .notchFont(size: 11)
            .foregroundStyle(.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func list(_ rows: [IdeaBoard.Row]) -> some View {
        let kinds = IdeaBoard.Row.Kind.allCases.filter { kind in rows.contains { $0.kind == kind } }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                Text(kind.title.uppercased())
                    .notchFont(size: 9, weight: .semibold, role: theme == .midnight ? .label : nil)
                    .tracking(theme == .midnight ? 0 : 0.8)
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(height: Layout.ideaHeaderHeight, alignment: .bottomLeading)
                    .modifier(IdeaDrift(order: index * 3, on: theme == .midnight))
                ForEach(Array(rows.filter { $0.kind == kind }.enumerated()), id: \.element.id) { offset, row in
                    let picture = pictures.url(for: row.id).flatMap { url in pictures.thumbnail(for: row.id).map { (url, $0) } }
                    IdeaRow(row: row, picture: picture, done: { tod.toggle(row.id) },
                            putOff: tod.hasAims ? { tod.putOff(row.id, by: $0) } : nil,
                            keep: { tod.keep(row.id) }, makeProject: projects.map { projects in { makeProject(row, in: projects) } })
                        .modifier(IdeaDrift(order: index * 3 + offset + 1, on: theme == .midnight))
                }
            }
        }
    }

    private func submit() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // "#oyl …", with Oyl one of your projects: into it, not the brain dump.
        if let projects, let tag = ProjectQuick.parse(text, idea: true).tag, projects.project(for: tag) != nil,
           projects.ideaForProject(text, shot: draft.handOver()) != nil {
            Haptics.perform(.alignment)
            draft.text = ""
            return
        }
        if let idea = tod.addIdea(text) {
            if let shot = draft.handOver() { pictures.keep(shot, for: idea) }
            Haptics.perform(.alignment)
            // Kept in the field for the next one: ideas come in runs.
            draft.text = ""
        }
    }

    private func cancel() {
        draft.text = ""
        draft.drop()
        resign()
    }

    /// The idea a project of its own (its screenshot with it), and checked off in tod's brain dump.
    private func makeProject(_ row: IdeaBoard.Row, in projects: ProjectStore) {
        let project = projects.newProject(named: row.title)
        if let url = pictures.url(for: row.id), let kept = projects.keep(url, for: project.id) {
            projects.edit(project.id) { $0.shot = kept }
        }
        Haptics.perform(.alignment)
        tod.toggle(row.id)
    }
}

/// The screenshot an idea being jotted is about, at the head of the field: pointed at, an × to
/// let go of it.
private struct ShotChip: View {
    let image: NSImage
    let drop: () -> Void
    @StateObject private var hover = LocalState(false)

    var body: some View {
        Button(action: drop) {
            IdeaShot(image: image, width: 32, height: 20)
                .overlay {
                    if hover.value {
                        Image(systemName: "xmark")
                            .notchSymbol(size: 8, weight: .bold)
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 20)
                            .background(.black.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover.value = $0 }
        .animation(.easeOut(duration: 0.15), value: hover.value)
        .help("Let go of the screenshot")
    }
}

/// An idea: a ring to check it off, its screenshot if it's about one (a click opens it; it can
/// be dragged out, into a chat), its title, and when (or, pointed at, what can be done about
/// when: put off a week or a month, or kept).
private struct IdeaRow: View {
    let row: IdeaBoard.Row
    var picture: (url: URL, image: NSImage)?
    let done: () -> Void
    /// Put off a week or a month (given an aim): not for toyl's, which have none.
    let putOff: ((Int) -> Void)?
    let keep: () -> Void
    var makeProject: (() -> Void)?
    @StateObject private var hover = LocalState(false)
    @StateObject private var checked = LocalState(false)
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let midnight = theme == .midnight
        HStack(spacing: 8) {
            Button {
                checked.value = true
                Haptics.perform(.levelChange)
                // A moment to see it checked before it goes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { done() }
            } label: {
                Image(systemName: checked.value ? "checkmark.circle.fill" : "circle")
                    .notchSymbol(size: 12, weight: .regular)
                    .foregroundStyle(.white.opacity(checked.value ? 0.9 : 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Done")
            if let picture {
                Button { NSWorkspace.shared.open(picture.url) } label: {
                    IdeaShot(image: picture.image)
                        .opacity(checked.value ? 0.5 : 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .onDrag { NSItemProvider(contentsOf: picture.url) ?? NSItemProvider() }
                .help("Open the screenshot")
            }
            if let mark = row.mark {
                Image(systemName: mark)
                    .notchSymbol(size: 8.5, weight: .semibold)
                    .foregroundStyle(.white.opacity(checked.value ? 0.3 : 0.5))
                    .help(mark == "envelope" ? "From an email, pulled in by toyl"
                          : mark == "calendar" ? "From a class on your calendar, brought in by toyl" : "An assignment from Canvas, brought in by toyl")
            }
            Text(row.title)
                .notchFont(size: 12)
                .foregroundStyle(.white.opacity(checked.value ? 0.4 : 0.9))
                .strikethrough(checked.value, color: .white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if hover.value, (row.kind != .due && (putOff != nil || row.stale)) || makeProject != nil {
                HStack(spacing: 10) {
                    if let makeProject { action("Project", makeProject) }
                    if row.stale { action("Keep", keep) }
                    if row.kind != .due, let putOff {
                        action(row.kind == .someday && !row.stale ? "In a week" : "+1 wk") { putOff(7) }
                        action(row.kind == .someday && !row.stale ? "A month" : "+1 mo") { putOff(28) }
                    }
                }
                .transition(.opacity)
            } else if !row.label.isEmpty {
                label
            }
        }
        .frame(height: Layout.ideaRowHeight)
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .animation(.easeOut(duration: 0.15), value: hover.value)
        .animation(.easeOut(duration: 0.2), value: checked.value)
        .opacity(midnight || !checked.value ? 1 : 0.8)
    }

    private var label: some View {
        let midnight = theme == .midnight
        let soft = row.kind == .soon || row.kind == .later || row.stale
        let late = Color(red: 1, green: 0.5, blue: 0.45)
        return Group {
            if midnight && soft {
                Text(row.label).font(Midnight.flourish(11))
            } else {
                Text(row.label).notchFont(size: 10.5, weight: row.kind == .due ? .semibold : .regular, digits: true)
            }
        }
        .foregroundStyle(row.overdue ? (midnight ? Midnight.fringeRed : late) : .white.opacity(row.kind == .due ? 0.75 : 0.45))
        .lineLimit(1)
    }

    private func action(_ title: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(title)
                .notchFont(size: 10.5, weight: .semibold)
                .foregroundStyle(.white.opacity(0.8))
        }
        .buttonStyle(PressableStyle())
    }
}

/// In Midnight Oyl, each row drifts in after the one before, out of a blur.
struct IdeaDrift: ViewModifier {
    let order: Int
    let on: Bool
    @StateObject private var shown = LocalState(false)

    func body(content: Content) -> some View {
        let hidden = on && !shown.value
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: hidden ? 3 : 0)
            .offset(x: hidden ? -6 : 0)
            .onAppear {
                guard on else { return }
                withAnimation(.easeOut(duration: 0.4).delay(0.05 + Double(min(order, 12)) * 0.035)) { shown.value = true }
            }
    }
}
