import AppKit
import EventKit
import SwiftUI

/// What the calendar's Oyl does for an event.
enum CalendarActivity: Equatable {
    case computer, writing, reading, party, chat, eat, drive, draw, exercise, sleep

    /// From the event's title (and where it is, and which calendar it's on). Classes go by their
    /// course code: computing ones at a computer, math-like ones writing, the rest reading.
    static func of(title: String, location: String?, calendar: String) -> CalendarActivity? {
        let text = (title + " " + (location ?? "")).lowercased()
        func has(_ words: [String]) -> Bool {
            words.contains { text.range(of: #"\b\#($0)\b"#, options: .regularExpression) != nil }
        }
        if has(["breakfast", "brunch", "lunch", "dinner", "food", "eat", "eating", "meal", "boba", "coffee", "cafe", "coupa",
                "dessert", "snack", "picnic"]) { return .eat }
        if has(["drive", "driving", "uber", "lyft", "airport", "sfo", "sjc", "flight", "commute", "road trip", "caltrain", "bart"]) {
            return .drive
        }
        if has(["draw", "drawing", "art", "sketch", "paint", "painting", "design", "figma"]) { return .draw }
        if has(["gym", "workout", "run", "running", "lift", "lifting", "climb", "climbing", "swim", "yoga", "soccer",
                "basketball", "tennis", "practice", "pe", "dance practice"]) { return .exercise }
        if has(["sleep", "nap", "bed"]) { return .sleep }
        if has(["party", "pre", "dj", "rave", "frat", "revelry", "darty", "mixer", "formal", "kickback", "margs", "drinks",
                "bar", "concert", "halloween", "birthday", "bday"]) { return .party }
        if has(["study", "homework", "hw", "pset", "problem set", "exam", "midterm", "final", "quiz", "review"]) { return .writing }
        if has(["meeting", "all hands", "discussion", "sync", "1:1", "one on one", "office hours", "oh", "interview", "call",
                "standup", "board", "club", "chat", "catch up", "coffee chat"]) { return .chat }
        if has(["work", "shift", "job", "intern", "research", "lab", "hack", "hacking", "code", "coding"]) { return .computer }
        // A course code, like "cs 106b" or "math 61cm".
        if let match = text.range(of: #"\b([a-z]{2,5})\s?\d{1,3}[a-z]*\b"#, options: .regularExpression) {
            let department = String(text[match].prefix { $0.isLetter })
            if ["cs", "ee", "cme", "mse", "engr", "ds", "symsys"].contains(department) { return .computer }
            if ["math", "stats", "phys", "physics", "chem", "econ", "mathx"].contains(department) { return .writing }
            return .reading
        }
        return calendarHabits[calendar]
    }

    /// What's usually on each of your calendars, for events whose titles don't say.
    private static let calendarHabits: [String: CalendarActivity] = [
        "✩ a": .reading,  // classes
        "✩ e": .party,    // events
        "✩ g": .chat,     // getting together
        "✩ x": .chat,     // clubs
    ]
}

/// One of today's events, for the calendar bar.
struct DayEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
    let activity: CalendarActivity?
    /// All day, or longer than a day: shown faintly, behind the rest.
    let isBackground: Bool

    func isOn(at date: Date) -> Bool { start <= date && date < end }
}

extension Array where Element == DayEvent {
    /// The one on now, if any (the latest to start, if they overlap), not counting all-day ones.
    func current(at date: Date) -> DayEvent? {
        filter { !$0.isBackground && $0.isOn(at: date) }.max { $0.start < $1.start }
    }

    func next(after date: Date) -> DayEvent? {
        filter { !$0.isBackground && $0.start > date }.min { $0.start < $1.start }
    }

    /// With nothing on now and nothing else today, the next event (tomorrow or later), for the
    /// calendar's Oyl to look ahead to.
    func peekTarget(at date: Date) -> DayEvent? {
        guard current(at: date) == nil,
              !contains(where: { !$0.isBackground && $0.start > date && Calendar.current.isDate($0.start, inSameDayAs: date) })
        else { return nil }
        return next(after: date)
    }
}

/// The coming week's events from the Mac's calendars (where a Google account's calendars show up
/// once it's added in Internet Accounts), leaving out the Stanford and TreeHacks ones. All-day and
/// multi-day events come too, to be shown in the background.
@MainActor
final class DayCalendar: ObservableObject {
    @Published private(set) var events: [DayEvent] = []
    /// Why there's nothing to show, if there isn't.
    @Published private(set) var note: String?

    /// Calendars left off, by name.
    static let skipped = ["stanford", "treehacks"]

    private let store = EKEventStore()
    private var refresh: Timer?

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
        refresh = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            store.requestFullAccessToEvents { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.load() }
                }
            }
        default:
            load()
        }
    }

    func current(at date: Date) -> DayEvent? { events.current(at: date) }
    func next(after date: Date) -> DayEvent? { events.next(after: date) }
    func peekTarget(at date: Date) -> DayEvent? { events.peekTarget(at: date) }

    /// Google Calendar's day view in the browser, or if it can't show anything yet, the setting
    /// it needs: calendar access, or a Google account in Internet Accounts.
    func openSomewhere() {
        let address: String
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            address = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        } else if note != nil {
            address = "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension"
        } else {
            address = "https://calendar.google.com/calendar/r/day"
        }
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    private func load() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            events = []
            note = "Allow calendar access in Settings"
            return
        }
        let calendars = store.calendars(for: .event).filter { calendar in
            !Self.skipped.contains { calendar.title.lowercased().contains($0) }
        }
        guard !calendars.isEmpty else {
            events = []
            note = "Add Google in Internet Accounts"
            return
        }
        let now = Date()
        // A week ahead, so there's always a next event to look ahead to.
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(7 * 24 * 3600),
                                                 calendars: calendars)
        let found = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map { event in
                DayEvent(id: "\(event.calendarItemIdentifier) \(event.startDate.timeIntervalSince1970)",
                         title: event.title ?? "Busy", start: event.startDate, end: event.endDate,
                         color: Color(cgColor: event.calendar.cgColor),
                         activity: CalendarActivity.of(title: event.title ?? "", location: event.location, calendar: event.calendar.title),
                         isBackground: event.isAllDay || event.endDate.timeIntervalSince(event.startDate) > 20 * 3600)
            }
            .sorted { $0.start < $1.start }
        if found != events { events = found }
        note = nil
    }
}
