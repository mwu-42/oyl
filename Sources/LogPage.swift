import SwiftUI

extension Layout {
    /// The log page: a field three lines tall, the projects' tags under it (and what tod has
    /// done today, if anything), today's entries, then the way to the document.
    static let logFieldHeight: CGFloat = 54
    static let logChipsHeight: CGFloat = 22
    static let logRowHeight: CGFloat = 20
    static let maxVisibleLogRows = 3
    static let logFooterHeight: CGFloat = 18

    static func logHeight(today: Int, suggestions: Bool) -> CGFloat {
        var height = 6 + logFieldHeight + 8 + logChipsHeight
        if suggestions { height += 6 + logChipsHeight }
        if today > 0 { height += 8 + 14 + CGFloat(min(today, maxVisibleLogRows)) * logRowHeight }
        return height + 8 + logFooterHeight + 12
    }
}

extension WorkLog {
    /// What the field asks, a different way each day.
    static let prompts = ["What did you get done today?", "What moved forward today?",
                          "What did you finish, fix or figure out today?", "What did today's work come to?",
                          "What would you want to remember about today's work?"]

    func prompt(at date: Date = Date()) -> String {
        let day = calendar.ordinality(of: .day, in: .era, for: day(of: date)) ?? 0
        return Self.prompts[day % Self.prompts.count]
    }

    /// What tod has had done today, to put in a check-in with a click: each with its list's #tag
    /// (not the brain dump's), at most four.
    @MainActor
    func fromTod(_ tod: TodStore, at now: Date = Date()) -> [(id: String, text: String)] {
        guard tod.isAvailable else { return [] }
        // Done the same day as now is done in the same day's span, a test far quicker than working
        // out the start of each one's day (this goes over every task tod has, and it's asked as
        // the pointer moves over the open notch).
        guard let today = calendar.dateInterval(of: .day, for: now.addingTimeInterval(-Self.turn)) else { return [] }
        let lists = Dictionary(tod.lists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let filed = Set(entries(on: now).map(\.text))
        return tod.tasks
            .filter { task in
                guard task.done, let done = task.doneAt?.addingTimeInterval(-Self.turn) else { return false }
                return done >= today.start && done < today.end
            }
            .sorted { ($0.doneAt ?? now) > ($1.doneAt ?? now) }
            .compactMap { task in
                let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, !filed.contains(where: { $0.localizedCaseInsensitiveContains(title) }) else { return nil }
                let tag = lists[task.listId].flatMap { $0.isDump ? nil : Self.tag(for: $0.name) }
                return (task.id, tag.map { "#\($0) \(title)" } ?? title)
            }
            .prefix(4).map { $0 }
    }

    /// A list's name as a #tag: its letters and digits, run together ("Side Project" → SideProject).
    static func tag(for name: String) -> String? {
        let tag = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        guard let first = tag.unicodeScalars.first, CharacterSet.letters.contains(first) else { return nil }
        return tag
    }
}

/// The work log's page: what you got done today, typed as you'd say it, a #tag starting each
/// project's part ("#oyl shipped the dock delay. #cs229 finished pset 3"), filed into the log
/// with Return (⌥↩ for a new line; Tab finishes a tag). Under it, your projects' tags (click one
/// to start its part; right-click to open its tab of the log), what tod has had done today, and
/// what's been filed today (× takes one back out). Then the way to the document. In Midnight Oyl
/// it's engraved, without a box, and drifts in.
struct LogPage: View {
    @ObservedObject var log: WorkLog
    @ObservedObject var state: NotchState
    @ObservedObject var tod: TodStore

    var body: some View {
        LogLayout(log: log, suggestions: log.fromTod(tod), editing: state.isEditing, resign: state.resignKeyboard)
    }
}

/// The log page itself, given what tod's had done today, whether its field has the keyboard, and
/// how to give it back.
struct LogLayout: View {
    @ObservedObject var log: WorkLog
    let suggestions: [(id: String, text: String)]
    let editing: Bool
    let resign: () -> Void
    @StateObject private var draft = LocalState("")
    @StateObject private var focus = LocalState(0)
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let midnight = theme == .midnight
        let today = log.entries()
        VStack(alignment: .leading, spacing: 0) {
            field
            projects
                .padding(.top, 8)
                .modifier(IdeaDrift(order: 1, on: midnight))
            if !suggestions.isEmpty {
                fromTod(suggestions)
                    .padding(.top, 6)
                    .modifier(IdeaDrift(order: 2, on: midnight))
            }
            if !today.isEmpty {
                filed(today)
                    .padding(.top, 8)
                    // Off to one side, in Midnight Oyl.
                    .padding(.leading, midnight ? 14 : 0)
            }
            footer
                .padding(.top, 8)
                .modifier(IdeaDrift(order: 4, on: midnight))
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .animation(NotchView.open, value: today.map(\.id))
    }

    // MARK: The field

    private var placeholder: String {
        let tags = log.projects.prefix(3).map { "#" + $0.name }
        let example = tags.isEmpty ? "Start each part with its #tag: “#oyl shipped the dock delay. #cs229 finished pset 3”"
            : tags.joined(separator: ", ") + (log.projects.count > 3 ? "…" : "")
        return log.prompt() + "   " + example
    }

    private var field: some View {
        let midnight = theme == .midnight
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "book.closed.fill")
                .notchSymbol(size: 11, weight: .semibold)
                .foregroundStyle(.white)
                .padding(.top, 9)
            ReminderField(text: $draft.value, placeholder: placeholder, onSubmit: submit, onCancel: cancel, lines: 3,
                          focus: focus.value, complete: complete)
                .padding(.top, 7)
                .frame(height: Layout.logFieldHeight - 6, alignment: .top)
            if !draft.value.isEmpty {
                Image(systemName: "return")
                    .notchSymbol(size: 10, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 9)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Layout.logFieldHeight, alignment: .top)
        .background {
            if midnight {
                // No box: a rule fading off under it, and a faint light where it's being written in.
                VStack(spacing: 0) {
                    Spacer()
                    LinearGradient(colors: [Midnight.silver.opacity(0.42), Midnight.silver.opacity(0.06), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 0.6)
                }
                .background(RadialGradient(colors: [Midnight.silver.opacity(editing ? 0.07 : 0.03), .clear],
                                           center: .leading, startRadius: 0, endRadius: 260))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(editing ? 0.14 : 0.08))
            }
        }
    }

    /// Tab, at "#oy": "l " (the latest project that starts so).
    private func complete(_ before: String) -> String? {
        guard let word = before.split(whereSeparator: \.isWhitespace).last, word.hasPrefix("#"),
              before.last.map({ !$0.isWhitespace }) ?? false,
              let project = log.completion(of: String(word.dropFirst())) else { return nil }
        return String(project.name.dropFirst(word.count - 1)) + " "
    }

    /// `text` on a line of its own at the end, and the keyboard back to it.
    private func add(_ text: String) {
        let current = draft.value.trimmingCharacters(in: .whitespaces)
        draft.value = current.isEmpty ? text : current + "\n" + text
        focus.value += 1
    }

    private func submit() {
        let text = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !log.checkIn(text).isEmpty else {
            NSSound.beep()
            return
        }
        Haptics.perform(.alignment)
        draft.value = ""
    }

    private func cancel() {
        draft.value = ""
        resign()
    }

    // MARK: Under it

    private var projects: some View {
        Group {
            if log.projects.isEmpty {
                Text("Your projects show here once you've #tagged them, a tab of the log each.")
                    .notchFont(size: 11)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            } else {
                sideways {
                    ForEach(log.projects) { project in
                        chip("#" + project.name, count: log.days(of: project.tag)) { add("#\(project.name) ") }
                            .help("Start #\(project.name)'s part (right-click to open its tab)")
                            .contextMenu {
                                Button("Open #\(project.name) in the Log") { log.openDoc(at: project.tag) }
                                Button("Add #\(project.name) to the Check-in") { add("#\(project.name) ") }
                            }
                    }
                }
            }
        }
        .frame(height: Layout.logChipsHeight)
    }

    private func fromTod(_ suggestions: [(id: String, text: String)]) -> some View {
        HStack(spacing: 6) {
            Text(theme == .midnight ? "from tod" : "FROM TOD")
                .notchFont(size: 9, weight: .semibold, role: theme == .midnight ? .label : nil)
                .foregroundStyle(.white.opacity(0.42))
            sideways {
                ForEach(suggestions, id: \.id) { suggestion in
                    chip("✓ " + suggestion.text, count: nil) { add(suggestion.text + ".") }
                        .help("Done in tod today: add it to the check-in")
                }
            }
        }
        .frame(height: Layout.logChipsHeight)
    }

    /// In a row; past the page's width, scrolling sideways.
    private func sideways<Chips: View>(@ViewBuilder _ chips: () -> Chips) -> some View {
        let row = HStack(spacing: theme == .midnight ? 12 : 6) { chips() }
        return ViewThatFits(in: .horizontal) {
            row.frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
    }

    private func chip(_ title: String, count: Int?, action: @escaping () -> Void) -> some View {
        let midnight = theme == .midnight
        return Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .notchFont(size: 11, weight: .medium, role: midnight ? .body : nil)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .notchFont(size: 9.5, weight: .semibold, digits: true)
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
            .padding(.horizontal, midnight ? 2 : 9)
            .frame(height: 20)
            .background(Capsule().fill(.white.opacity(midnight ? 0 : 0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func filed(_ today: [LogEntry]) -> some View {
        let midnight = theme == .midnight
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(today.enumerated()), id: \.element.id) { index, entry in
                LogRow(entry: entry, name: log.project(entry.tag)?.name ?? entry.tag) { log.remove(entry.id) }
                    .modifier(IdeaDrift(order: index + 3, on: midnight))
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            Text(midnight ? "filed today" : "FILED TODAY")
                .notchFont(size: 9, weight: .semibold, role: midnight ? .label : nil)
                .tracking(midnight ? 0 : 0.8)
                .foregroundStyle(.white.opacity(0.42))
                .frame(height: 14, alignment: .topLeading)
            if today.count <= Layout.maxVisibleLogRows {
                rows
            } else {
                ScrollView(.vertical, showsIndicators: false) { rows }
                    .frame(height: CGFloat(Layout.maxVisibleLogRows) * Layout.logRowHeight)
            }
        }
    }

    private var footer: some View {
        let midnight = theme == .midnight
        return HStack(spacing: 12) {
            Button { log.openDoc() } label: {
                HStack(spacing: 4) {
                    Text(midnight ? "open the log" : "Open the log")
                        .notchFont(size: 11, weight: .semibold, role: midnight ? .label : nil)
                    Image(systemName: "arrow.up.right")
                        .notchSymbol(size: 8.5, weight: .bold)
                }
                .foregroundStyle(.white.opacity(0.8))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help("Every project, a tab each, in your browser (in Documents, in Oyl Work Log)")
            .contextMenu {
                Button("Show in Finder") { log.revealDoc() }
            }
            if let tag = log.writing, let project = log.project(tag) {
                WritingNote(name: project.name)
            }
            Spacer(minLength: 8)
        }
        .frame(height: Layout.logFooterHeight)
    }
}

/// "Writing Oyl's story…", while the on-device model is: in Midnight Oyl, a star twinkling by it.
private struct WritingNote: View {
    let name: String
    @Environment(\.notchTheme) private var theme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let glow = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 3)
            HStack(spacing: 4) {
                if theme == .midnight {
                    Text("✦").font(.system(size: 8)).foregroundStyle(Midnight.white.opacity(0.35 + 0.55 * glow))
                }
                Text("writing \(name)'s story…")
                    .notchFont(size: 10.5, role: theme == .midnight ? .body : nil)
                    .italic(theme == .midnight)
                    .foregroundStyle(.white.opacity(theme == .midnight ? 0.55 : 0.35 + 0.2 * glow))
                    .lineLimit(1)
            }
        }
    }
}

/// Something filed today: its tag, its words (on one line), and, pointed at, × to take it out.
private struct LogRow: View {
    let entry: LogEntry
    let name: String
    let remove: () -> Void
    @StateObject private var hover = LocalState(false)
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text("#" + name)
                .notchFont(size: 11, weight: .semibold, role: theme == .midnight ? .body : nil)
                .italic(theme == .midnight)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .fixedSize()
            Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                .notchFont(size: 12)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if hover.value {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .notchSymbol(size: 8, weight: .bold)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .help("Take it out of the log")
                .transition(.opacity)
            }
        }
        .frame(height: Layout.logRowHeight)
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .animation(.easeOut(duration: 0.15), value: hover.value)
    }
}
