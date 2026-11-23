import AppKit
import SwiftUI

/// What the projects page lists: what's pressing (tasks due within the week, or late, soonest
/// first) and what's waiting in Unsorted to be filed (newest first).
enum ProjectBoard {
    struct Row: Identifiable, Equatable {
        enum Section: String, CaseIterable {
            case pressing, unsorted

            var title: String { self == .pressing ? "Pressing" : "Unsorted" }
        }

        let id: String
        let section: Section
        let kind: ProjectNode.Kind
        let title: String
        /// The project it's in, if it's in one.
        let project: String?
        /// When it's due, as tod says it ("Fri 5 PM"), or how late it is.
        let label: String
        let late: Bool
        let hasShot: Bool
    }

    @MainActor
    static func rows(_ store: ProjectStore, now: Date = Date()) -> [Row] {
        let today = Calendar.current.startOfDay(for: now)
        let pressing = store.pressing(within: 7, now: now).map { task, project -> Row in
            let late = task.dueDate.map { $0 < now } ?? false
            let day = task.due.flatMap(IdeaQuick.date)
            let behind = day.flatMap { Calendar.current.dateComponents([.day], from: $0, to: today).day } ?? 0
            let label = late && behind > 0 ? (behind == 1 ? "1 day late" : "\(behind) days late")
                : IdeaQuick.describe(due: task.due ?? "", time: task.time, now: now)
            return Row(id: task.id, section: .pressing, kind: task.kind, title: task.title, project: project?.title, label: label,
                       late: late, hasShot: task.shot != nil)
        }
        let unsorted = store.inbox.filter { !$0.done }.reversed().map { node in
            Row(id: node.id, section: .unsorted, kind: node.kind, title: node.title.isEmpty ? "Screenshot" : node.title, project: nil,
                label: node.due.map { IdeaQuick.describe(due: $0, time: node.time, now: now) } ?? "", late: false, hasShot: node.shot != nil)
        }
        return pressing + unsorted
    }

    /// How tall `rows` stand: each section under its heading (with none, room for the hint).
    static func height(of rows: [Row]) -> CGFloat {
        guard !rows.isEmpty else { return 44 }
        return CGFloat(rows.count) * Layout.ideaRowHeight + CGFloat(Set(rows.map(\.section)).count) * Layout.ideaHeaderHeight
    }
}

/// The projects page: a field to put something straight into a project ("#oyl fix the dock fri
/// 5pm"; a task, or with the bulb lit or "?" first an idea), or a screenshot (its camera), and
/// under it what's pressing and what's waiting in Unsorted. The button at its end opens the whole
/// outline (see `ProjectsWindow`).
struct ProjectsPage: View {
    @ObservedObject var projects: ProjectStore
    @ObservedObject var state: NotchState

    var body: some View {
        ProjectsLayout(projects: projects, draft: state.projectDraft, editing: state.isEditing, listHeight: state.projectListHeight,
                       resign: state.resignKeyboard, takeShot: state.takeProjectShot, open: state.openProjects)
    }
}

struct ProjectsLayout: View {
    @ObservedObject var projects: ProjectStore
    @ObservedObject var draft: IdeaDraft
    let editing: Bool
    let listHeight: CGFloat
    let resign: () -> Void
    var takeShot: () -> Void = {}
    var open: (String?) -> Void = { _ in }
    @StateObject private var focus = LocalState(0)
    @Environment(\.notchTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let rows = ProjectBoard.rows(projects, now: context.date)
            VStack(alignment: .leading, spacing: 10) {
                field
                if let problem = projects.problem {
                    hint(problem)
                } else if rows.isEmpty {
                    hint("Type a #project and what to do: “#oyl fix the dock fri 5pm” (a time reminds you then). “?” first, or the bulb, makes it an idea. Without a #project it waits in Unsorted. The outline’s behind the button at the end.")
                } else if ProjectBoard.height(of: rows) <= listHeight + 0.5 {
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
        .onAppear(perform: takeKeyboard)
        .onChange(of: draft.wantsKeyboard) { _, _ in takeKeyboard() }
    }

    private var isIdea: Bool { draft.asIdea || draft.text.hasPrefix("?") }

    private func takeKeyboard() {
        guard draft.wantsKeyboard else { return }
        draft.wantsKeyboard = false
        focus.value += 1
    }

    private var field: some View {
        let shot = draft.shot.flatMap { _ in draft.shotImage }
        let idea = isIdea
        return HStack(spacing: 8) {
            if let shot {
                IdeaShot(image: shot, width: 32, height: 20)
                    .onTapGesture { draft.drop() }
                    .help("Let go of the screenshot")
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            Button { draft.asIdea.toggle() } label: {
                Image(systemName: idea ? "lightbulb.fill" : "checkmark.circle")
                    .notchSymbol(size: 11, weight: .semibold)
                    .foregroundStyle(.white.opacity(idea ? 1 : 0.75))
                    .frame(width: 14, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help(idea ? "An idea (click for a task)" : "A task (click for an idea)")
            ReminderField(text: $draft.text,
                          placeholder: shot != nil ? "What's it for?   “#oyl the dock's shadow”"
                              : idea ? "Spitball an idea…   “#oyl what if the moon…”" : "Add to a project…   “#oyl fix the dock fri 5pm”",
                          onSubmit: submit, onCancel: cancel, focus: focus.value, complete: complete)
            if !draft.text.isEmpty {
                Image(systemName: "return")
                    .notchSymbol(size: 10, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.4))
            }
            button("camera.viewfinder", help: shot == nil ? "Screenshot something for a project" : "Take another screenshot instead",
                   action: takeShot)
            button("list.bullet.indent", help: "Open the outline of every project") { open(nil) }
        }
        .padding(.leading, shot == nil ? 10 : 4)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(Capsule().fill(.white.opacity(editing ? 0.14 : 0.08)))
        .animation(.easeOut(duration: 0.25), value: draft.shot)
        .animation(.easeOut(duration: 0.2), value: idea)
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .notchSymbol(size: 12, weight: .semibold)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }

    /// Tab finishes the #project being typed.
    private func complete(_ before: String) -> String? {
        guard let typed = ProjectQuick.typingTag(before), let tag = projects.completion(of: typed) else { return nil }
        return String(tag.dropFirst(ProjectQuick.handle(typed).count)) + " "
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .notchFont(size: 11)
            .foregroundStyle(.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func list(_ rows: [ProjectBoard.Row]) -> some View {
        let sections = ProjectBoard.Row.Section.allCases.filter { section in rows.contains { $0.section == section } }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                Text(section.title.uppercased())
                    .notchFont(size: 9, weight: .semibold, role: theme == .midnight ? .label : nil)
                    .tracking(theme == .midnight ? 0 : 0.8)
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(height: Layout.ideaHeaderHeight, alignment: .bottomLeading)
                    .modifier(IdeaDrift(order: index * 3, on: theme == .midnight))
                ForEach(Array(rows.filter { $0.section == section }.enumerated()), id: \.element.id) { offset, row in
                    ProjectRow(row: row, projects: projects, open: open)
                        .modifier(IdeaDrift(order: index * 3 + offset + 1, on: theme == .midnight))
                }
            }
        }
    }

    private func submit() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || draft.shot != nil else { return }
        let shot = draft.handOver()
        if projects.capture(text, idea: draft.asIdea, shot: shot) != nil {
            Haptics.perform(.alignment)
            // Ready for the next: things come in runs.
            draft.text = ""
        } else if let shot {
            draft.attach(shot)
        }
    }

    private func cancel() {
        draft.text = ""
        draft.drop()
        resign()
    }
}

/// A line on the projects page: a ring to check a task off (an idea's bulb, a note's lines), its
/// screenshot small if it has one, its title and project, and when; pointed at, what can be done
/// with it: filed into a project (from Unsorted), made a project (an idea), or opened in the outline.
private struct ProjectRow: View {
    let row: ProjectBoard.Row
    @ObservedObject var projects: ProjectStore
    let open: (String?) -> Void
    @StateObject private var hover = LocalState(false)
    @StateObject private var checked = LocalState(false)
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let midnight = theme == .midnight
        HStack(spacing: 8) {
            leading
            if row.hasShot, let node = projects.node(row.id), let image = projects.thumbnail(node), let url = projects.shotURL(node) {
                Button { NSWorkspace.shared.open(url) } label: {
                    IdeaShot(image: image).contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .help("Open the screenshot")
            }
            (Text(row.title).foregroundColor(.white.opacity(checked.value ? 0.4 : 0.9))
                + Text(row.project.map { "  \($0)" } ?? "").foregroundColor(.white.opacity(0.38)))
                .notchFont(size: 12)
                .strikethrough(checked.value, color: .white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if hover.value {
                HStack(spacing: 10) {
                    if row.section == .unsorted { fileMenu }
                    if row.kind == .idea { action("Project") { projects.makeProject(row.id) } }
                    action("Open") { open(row.id) }
                }
                .transition(.opacity)
            } else if !row.label.isEmpty {
                Text(row.label)
                    .notchFont(size: 10.5, weight: .semibold, digits: true)
                    .foregroundStyle(row.late ? (midnight ? Midnight.fringeRed : Color(red: 1, green: 0.5, blue: 0.45)) : .white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .frame(height: Layout.ideaRowHeight)
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .animation(.easeOut(duration: 0.15), value: hover.value)
        .animation(.easeOut(duration: 0.2), value: checked.value)
    }

    @ViewBuilder private var leading: some View {
        switch row.kind {
        case .task:
            Button {
                checked.value = true
                Haptics.perform(.levelChange)
                // A moment to see it checked before it goes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { projects.toggle(row.id) }
            } label: {
                Image(systemName: checked.value ? "checkmark.circle.fill" : "circle")
                    .notchSymbol(size: 12, weight: .regular)
                    .foregroundStyle(.white.opacity(checked.value ? 0.9 : 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Done")
        default:
            Image(systemName: ProjectGlyph.symbol(row.kind))
                .notchSymbol(size: 10.5, weight: .semibold)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 12)
        }
    }

    private var fileMenu: some View {
        Menu {
            ForEach(projects.projects(), id: \.node.id) { entry in
                Button(String(repeating: "    ", count: entry.depth) + entry.node.title) {
                    projects.move(row.id, to: entry.node.id)
                }
            }
        } label: {
            Text("File")
                .notchFont(size: 10.5, weight: .semibold)
                .foregroundStyle(.white.opacity(0.8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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

/// Each kind of line's mark, where it's an SF Symbol.
enum ProjectGlyph {
    static func symbol(_ kind: ProjectNode.Kind) -> String {
        switch kind {
        case .area: return "square.stack"
        case .project: return "folder"
        case .task: return "circle"
        case .idea: return "lightbulb"
        case .note: return "text.alignleft"
        }
    }
}

// MARK: - Reminders

/// A task's time come: the notch pops open to say so (in both looks), till it's put off ten
/// minutes, seen, or done.
struct ProjectAlert: View {
    let task: ProjectNode
    @ObservedObject var projects: ProjectStore

    static let bell = ReminderAlert.bell

    var body: some View {
        let project = projects.project(of: task.id)?.title
        let when = task.time.map(TodQuick.describe(time:)) ?? ""
        ReminderAlert(title: task.title, detail: [project, when].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                      snooze: { projects.snoozeRinging(minutes: 10) }, dismiss: { projects.dismissRinging() },
                      finish: { projects.finishRinging() })
    }
}
