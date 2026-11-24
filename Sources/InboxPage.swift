import AppKit
import SwiftUI

extension TodStore {
    /// The inbox's open tasks, in its order: the newest at the top.
    var inbox: [Task] { tasks.filter { $0.listId == "inbox" && !$0.done } }

    /// A task put into the inbox (its id); nil if there's nothing to add, or no list. With toyl,
    /// through toyl's own quick add (`toyl add`), so it's read just as toyl reads it ("essay fri
    /// 5pm", "#cs" for a list, "~30m", " // a note"), a slash word first making something else
    /// ("/list groceries", "/timer 25m"), or toyl saying no to it ("/list" with no name); else (or
    /// if toyl's command isn't there or broke) as `TodQuick` reads it, into tod's inbox (or the list
    /// its #tag names), a slash word and all.
    @discardableResult
    func addToInbox(_ text: String) -> ToylCommand.Added? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let folder = toylFolder, let added = ToylCommand.add(text, in: folder) {
            // Seen at once: a task at the top of the list under the field, a timer on the notch.
            if case .refused = added {} else { readNow() }
            return added
        }
        return add(text).map { .task($0.id) }
    }
}

/// The inbox page: a field to put a task straight into the inbox (toyl's, with toyl here, else
/// tod's), and under it what's in the inbox, the newest at the top, each with a ring to check it
/// off and when it's due. In Midnight Oyl it's engraved, its rows drifting in one after another.
struct InboxPage: View {
    @ObservedObject var tod: TodStore
    @ObservedObject var state: NotchState

    var body: some View {
        InboxLayout(tod: tod, draft: state.inboxDraft, editing: state.isEditing, listHeight: state.inboxListHeight,
                    resign: state.resignKeyboard)
    }
}

/// The inbox page itself, given what's being typed, whether its field has the keyboard, how tall
/// its list may stand before it scrolls, and how to give the keyboard back.
struct InboxLayout: View {
    @ObservedObject var tod: TodStore
    @ObservedObject var draft: LocalState<String>
    let editing: Bool
    let listHeight: CGFloat
    let resign: () -> Void
    @Environment(\.notchTheme) private var theme
    /// What the last line came to, said under the field for a moment: something a slash word made
    /// ("Made the list “groceries”"), or toyl's no.
    @StateObject private var said = LocalState<Said?>(nil)

    /// What's said, and whether it's toyl's no.
    struct Said: Equatable {
        let text: String
        let no: Bool
        let at: Date
    }

    /// With nothing in it, room for the hint.
    static func height(rows: Int) -> CGFloat { rows == 0 ? 30 : CGFloat(rows) * Layout.ideaRowHeight }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let tasks = tod.inbox
            VStack(alignment: .leading, spacing: 10) {
                field
                if let said = said.value {
                    hint(said.text)
                        .foregroundStyle(.white.opacity(said.no ? 0.75 : 0.55))
                        .transition(.opacity)
                }
                if !tod.isAvailable {
                    hint(tod.source == .toyl ? "toyl's list can't be read just now. It's back as soon as it can be."
                         : "Oyl adds to toyl's inbox, or tod's. Install one, and its inbox is here.")
                } else if tasks.isEmpty {
                    hint(tod.source == .toyl
                         ? "Nothing in the inbox. Type a task and Return: “essay fri 5pm”, “#cs” to put it in a list, or “/list groceries” to make one."
                         : "Nothing in the inbox. Type a task and Return: “essay fri 5pm”, or “#cs” to put it in a list.")
                } else if Self.height(rows: tasks.count) <= listHeight + 0.5 {
                    list(tasks, now: context.date)
                } else {
                    ScrollView(.vertical, showsIndicators: false) { list(tasks, now: context.date) }
                        .frame(height: listHeight)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .animation(NotchView.open, value: tasks.map(\.id))
            .animation(.easeOut(duration: 0.2), value: said.value)
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill")
                .notchSymbol(size: 11, weight: .semibold)
                .foregroundStyle(.white)
            ReminderField(text: $draft.value, placeholder: "Add to the inbox…   “essay fri 5pm”, “#cs”",
                          onSubmit: submit, onCancel: cancel)
            if !draft.value.isEmpty {
                Image(systemName: "return")
                    .notchSymbol(size: 10, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Capsule().fill(.white.opacity(editing ? 0.14 : 0.08)))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .notchFont(size: 11)
            .foregroundStyle(.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func list(_ tasks: [TodStore.Task], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tasks.enumerated()), id: \.element.id) { offset, task in
                InboxRow(task: task, now: now) { tod.toggle(task.id) }
                    .modifier(IdeaDrift(order: offset, on: theme == .midnight))
            }
        }
    }

    private func submit() {
        let text = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let added = tod.addToInbox(text) else {
            NSSound.beep()
            return
        }
        say(added)
        // toyl's no: the line's kept, to be put right.
        if case .refused = added {
            NSSound.beep()
            return
        }
        Haptics.perform(.alignment)
        // Kept open for the next one: tasks come in runs.
        draft.value = ""
    }

    /// What it came to, under the field for a few seconds (a task says nothing: it's in the list).
    private func say(_ added: ToylCommand.Added) {
        guard let text = added.said else {
            said.value = nil
            return
        }
        var no = false
        if case .refused = added { no = true }
        let shown = Said(text: text, no: no, at: Date())
        said.value = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [said] in
            if said.value == shown { said.value = nil }
        }
    }

    private func cancel() {
        draft.value = ""
        resign()
    }
}

/// A task in the inbox: a ring to check it off, its mark if it came from an email or Canvas, its
/// title, and when it's due ("Fri 5 PM", "2 days late").
private struct InboxRow: View {
    let task: TodStore.Task
    let now: Date
    let done: () -> Void
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
            if let mark = task.mark {
                Image(systemName: mark)
                    .notchSymbol(size: 8.5, weight: .semibold)
                    .foregroundStyle(.white.opacity(checked.value ? 0.3 : 0.5))
                    .help(mark == "envelope" ? "From an email, pulled in by toyl" : "An assignment from Canvas, brought in by toyl")
            }
            Text(task.title)
                .notchFont(size: 12)
                .foregroundStyle(.white.opacity(checked.value ? 0.4 : 0.9))
                .strikethrough(checked.value, color: .white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if let when {
                Text(when.text)
                    .notchFont(size: 10.5, weight: .semibold, digits: true)
                    .foregroundStyle(when.late ? (midnight ? Midnight.fringeRed : Color(red: 1, green: 0.5, blue: 0.45)) : .white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .frame(height: Layout.ideaRowHeight)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: checked.value)
        .opacity(midnight || !checked.value ? 1 : 0.8)
    }

    /// When it's due, as the ideas page says a deadline, and whether that's gone by.
    private var when: (text: String, late: Bool)? {
        guard let due = task.due else { return nil }
        let late = task.dueDate.map { $0 < now } ?? false
        let calendar = IdeaQuick.calendar
        let days = IdeaQuick.date(due).flatMap { calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: $0).day } ?? 0
        if late, days < 0 { return (days == -1 ? "1 day late" : "\(-days) days late", true) }
        return (IdeaQuick.describe(due: due, time: task.time, now: now), late)
    }
}
