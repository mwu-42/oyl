import AppKit
import EventKit
import SwiftUI

/// One of today's events, for the calendar bar.
struct DayEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
    /// All day, or longer than a day: shown apart from the rest, as a ribbon and a tag.
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
}

/// The coming week's events from the Mac's calendars (an account's show up once it's added in
/// Internet Accounts), leaving out the Stanford and TreeHacks ones. All-day and multi-day events
/// come too, to be shown in the background.
@MainActor
final class DayCalendar: ObservableObject {
    @Published private(set) var events: [DayEvent] = []
    /// Why there's nothing to show, if there isn't.
    @Published private(set) var note: String?
    /// Calendars left off, by name.
    nonisolated static let skipped = ["stanford", "treehacks"]

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

    /// The Calendar app, or if it can't show anything yet, the setting it needs: calendar access,
    /// or an account in Internet Accounts.
    func openSomewhere() {
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        } else if note != nil {
            open("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")
        } else {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
                                               configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    private func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    /// The week's events from the Mac's calendars.
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
            note = "Add a calendar in Internet Accounts"
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
                         isBackground: event.isAllDay || event.endDate.timeIntervalSince(event.startDate) > 20 * 3600)
            }
            .sorted { $0.start < $1.start }
        if found != events { events = found }
        note = nil
    }
}
