import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The outline of every project, in its own window: on the left what's pressing, what's waiting
// in Unsorted, and your areas and projects (subprojects under them), then those put off to
// someday and those done; on the right the one that's open, its page: its name, its notes, and
// its lines, typed as in any outliner. Return starts the next line, Tab and Shift-Tab indent and
// outdent, ↑ and ↓ go between lines, ⌘⇧↑ and ⌘⇧↓ move one, ⌘↩ checks a task off, and Delete
// on an empty line takes it away. A line started "? " is an idea, "- " a note, "# " a project
// (a subproject, under another), "[] " a task; a task's day and time ("fri 5pm") are read out of
// it as it's finished. Screenshots come in by the camera, or dropped on the page.

/// What the window has open.
enum OutlineSelection: Hashable {
    case pressing, unsorted
    case node(String)
}

/// A line of the outline as it's shown: how deep it is, and whether it has lines under it.
struct OutlineRow: Identifiable, Equatable {
    let node: ProjectNode
    let depth: Int
    let hasChildren: Bool
    var id: String { node.id }

    /// `nodes` as they're shown, depth first, folded lines' children left out, and done ones
    /// unless `showsDone` (or they were done just now, so they're seen to be).
    static func rows(_ nodes: [ProjectNode], depth: Int = 0, showsDone: Bool, now: Date = Date()) -> [OutlineRow] {
        var rows: [OutlineRow] = []
        func add(_ nodes: [ProjectNode], _ depth: Int) {
            for node in nodes where showsDone || !node.done || now.timeIntervalSince(node.doneAt ?? .distantPast) < 600 {
                let shown = node.children.contains { showsDone || !$0.done || now.timeIntervalSince($0.doneAt ?? .distantPast) < 600 }
                rows.append(OutlineRow(node: node, depth: depth, hasChildren: shown))
                if !node.collapsed { add(node.children, depth + 1) }
            }
        }
        add(nodes, depth)
        return rows
    }
}

/// What a key in a line asks for.
enum OutlineKey {
    case newline, tab, backtab, up, down, moveUp, moveDown, deleteEmpty, escape
}

/// The window's state: what's open, which line has the keyboard (and which is to take it next),
/// the look, and whether it's on screen (the night sky only turns while it is).
@MainActor
final class OutlineModel: ObservableObject {
    struct FocusRequest: Equatable {
        let id: String
        let token: Int
    }

    @Published var selection: OutlineSelection = .pressing
    @Published private(set) var request: FocusRequest?
    @Published var showsDone = false
    @Published var showsFinished = false
    @Published var theme: NotchTheme = .standard
    @Published var isVisible = false
    /// The line being typed in, if any.
    var focused: String?
    let store: ProjectStore
    /// A project's last few check-ins from the work log, by its #tag: the day, and what was said.
    var logged: (String) -> [(day: String, text: String)] = { _ in [] }
    /// Takes a screenshot (the window out of the way meanwhile) for the line `id`, or a new one under `parent`.
    var shoot: (_ id: String?, _ parent: String?) -> Void = { _, _ in }
    private var token = 0

    init(store: ProjectStore) {
        self.store = store
    }

    /// The parent the open page's lines are under (`ProjectStore.inbox` for Unsorted).
    var root: String? {
        switch selection {
        case .pressing: return nil
        case .unsorted: return ProjectStore.inbox
        case .node(let id): return id
        }
    }

    func rows(under root: String?) -> [OutlineRow] {
        guard let root else { return [] }
        return OutlineRow.rows(store.children(of: root), showsDone: showsDone)
    }

    /// The line (or a page's title, "title:" and its id) to take the keyboard.
    func focus(_ id: String) {
        token += 1
        request = FocusRequest(id: id, token: token)
    }

    /// A line opened from elsewhere (the notch): its project's page, with it to type in.
    func reveal(_ id: String) {
        guard let node = store.node(id) else { return }
        if node.kind.isProject, store.place(of: id)?.parent != ProjectStore.inbox {
            selection = .node(id)
            focus("title:" + id)
            return
        }
        if store.place(of: id)?.parent == ProjectStore.inbox || store.path(to: id).first.map({ store.place(of: $0.id)?.parent == ProjectStore.inbox }) == true {
            selection = .unsorted
        } else if let project = store.project(of: id) {
            selection = .node(project.id)
        }
        // Unfolded down to it.
        for over in store.path(to: id) where over.collapsed { store.edit(over.id) { $0.collapsed = false } }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.focus(id) }
        }
    }

    /// A new project at the top (or a subproject under `parent`), open, its name to be typed.
    func newProject(under parent: String? = nil) {
        let project = store.newProject(named: "", under: parent)
        if parent == nil { selection = .node(project.id) }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.focus(parent == nil ? "title:" + project.id : project.id) }
        }
    }

    /// A new line at the end of the open page.
    func addLine() {
        guard let root else { return }
        let line = store.add(ProjectNode(kind: .task, title: ""), under: root)
        focus(line.id)
    }

    /// Return on a page's title: to its first line, or a new one.
    func titleReturn() {
        guard let root else { return }
        if let first = rows(under: root).first { focus(first.id) } else { addLine() }
    }

    /// What a key in the line `id` does, in the page whose lines are under `root`: whether it did
    /// anything.
    func key(_ key: OutlineKey, in id: String) -> Bool {
        guard let node = store.node(id) else { return false }
        let rows = rows(under: root)
        let index = rows.firstIndex { $0.id == id }
        switch key {
        case .newline:
            store.finishEditing(id)
            // An empty line comes out a level instead, as in any outliner.
            if node.title.isEmpty, node.children.isEmpty, store.outdent(id, floor: root) {
                refocus(id)
                return true
            }
            let next: ProjectNode.Kind = node.kind == .idea || node.kind == .note || node.kind == .task ? node.kind : .task
            let line = ProjectNode(kind: next, title: "")
            if !node.children.isEmpty, !node.collapsed {
                store.add(line, under: id, at: 0)
            } else if let place = store.place(of: id) {
                store.add(line, under: place.parent, at: place.index + 1)
            }
            focus(line.id)
            return true
        case .tab:
            store.finishEditing(id)
            if store.indent(id) { refocus(id) }
            return true
        case .backtab:
            store.finishEditing(id)
            if store.outdent(id, floor: root) { refocus(id) }
            return true
        case .up:
            if let index, index > 0 { focus(rows[index - 1].id) } else if case .node(let page) = selection { focus("title:" + page) }
            return true
        case .down:
            if let index, index + 1 < rows.count { focus(rows[index + 1].id) }
            return true
        case .moveUp, .moveDown:
            if store.shift(id, by: key == .moveUp ? -1 : 1) { refocus(id) }
            return true
        case .deleteEmpty:
            guard node.title.isEmpty, node.children.isEmpty, node.shot == nil else { return false }
            let before = index.flatMap { $0 > 0 ? rows[$0 - 1].id : nil }
            store.delete(id)
            if let before {
                focus(before)
            } else if case .node(let page) = selection {
                focus("title:" + page)
            }
            return true
        case .escape:
            store.finishEditing(id)
            NSApp.keyWindow?.makeFirstResponder(nil)
            return true
        }
    }

    /// ⌘↩ in a line: a task checked off (or not); anything else made a task.
    func toggleFocused() -> Bool {
        guard let id = focused, let node = store.node(id) else { return false }
        if node.kind == .task { store.toggle(id) } else { store.setKind(id, .task) }
        return true
    }

    /// The same line, back in the keyboard once it's been moved.
    private func refocus(_ id: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.focus(id) }
        }
    }

    /// Up a level: the open project's parent (or the projects' list).
    func back() {
        guard case .node(let id) = selection else { return }
        if let parent = store.path(to: id).last(where: { $0.kind.isProject }) { selection = .node(parent.id) } else { selection = .pressing }
    }
}

// MARK: - The window

@MainActor
final class ProjectsWindowController: NSObject, NSWindowDelegate {
    let model: OutlineModel
    private let store: ProjectStore
    private let workLog: WorkLog
    private var window: ProjectsWindow?

    init(store: ProjectStore, workLog: WorkLog) {
        self.store = store
        self.workLog = workLog
        model = OutlineModel(store: store)
        super.init()
        model.logged = { [weak workLog] handle in
            guard let workLog, !handle.isEmpty else { return [] }
            return workLog.saved.entries.filter { $0.tag == handle }.sorted { $0.day > $1.day }.prefix(5).map {
                (WorkLogDoc.dayTitle($0.day, calendar: workLog.calendar), $0.text)
            }
        }
        model.shoot = { [weak self] id, parent in self?.shoot(into: id, under: parent) }
    }

    var theme: NotchTheme {
        get { model.theme }
        set { if model.theme != newValue { model.theme = newValue } }
    }

    /// Up, in front, where you are (over a fullscreen app too), with `id` open if it's given.
    func show(_ id: String? = nil) {
        let window = self.window ?? make()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.isVisible = true
        if let id { model.reveal(id) }
    }

    private func make() -> ProjectsWindow {
        let window = ProjectsWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        window.title = "Projects"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 640, height: 420)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: ProjectsView(store: store, model: model))
        window.delegate = self
        window.model = model
        if !window.setFrameUsingName("Oyl Projects") { window.center() }
        window.setFrameAutosaveName("Oyl Projects")
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        store.flush()
        model.isVisible = false
        model.focused = nil
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        model.isVisible = window.isVisible && window.occlusionState.contains(.visible)
    }

    func windowDidResignKey(_ notification: Notification) {
        store.flush()
    }

    /// The window out of the way while an area's picked out, as ⇧⌘4 has you; then back, the
    /// screenshot on the line `id`, or on a new line under `parent` with its caption to type.
    private func shoot(into id: String?, under parent: String?) {
        guard let window else { return }
        window.orderOut(nil)
        IdeaPictures.take { [weak self] url in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            guard let url else { return }
            if let id, let name = self.store.keep(url, for: id) {
                self.store.edit(id) { $0.shot = name }
                self.model.focus(id)
            } else if let parent {
                var line = ProjectNode(kind: .note, title: "")
                guard let name = self.store.keep(url, for: line.id) else { return }
                line.shot = name
                self.store.add(line, under: parent)
                self.model.focus(line.id)
            }
        }
    }
}

final class ProjectsWindow: NSWindow {
    weak var model: OutlineModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command, let key = event.charactersIgnoringModifiers {
            switch key {
            case "w":
                performClose(nil)
                return true
            case "\r":
                if MainActor.assumeIsolated({ model?.toggleFocused() }) == true { return true }
            case "[":
                MainActor.assumeIsolated { model?.back() }
                return true
            case "n":
                MainActor.assumeIsolated { model?.newProject() }
                return true
            default:
                break
            }
        }
        return MainActor.assumeIsolated { EditKeys.perform(event) } || super.performKeyEquivalent(with: event)
    }
}

// MARK: - The views

struct ProjectsView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var model: OutlineModel

    var body: some View {
        let midnight = model.theme == .midnight
        HStack(spacing: 0) {
            ProjectsSidebar(store: store, model: model)
                .frame(width: 236)
            ProjectsMain(store: store, model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 28)
        .background { ProjectsBackdrop(midnight: midnight, turning: model.isVisible) }
        .environment(\.notchTheme, model.theme)
        .foregroundStyle(midnight ? Midnight.white : .white)
        .tint(midnight ? Midnight.silver : .white)
        .animation(.easeInOut(duration: 0.25), value: model.selection)
    }
}

/// Behind it all: in Oyl's look, plain black; in Midnight Oyl's, the night, deeper toward the
/// bottom left, a pole high on the right that the stars wheel slowly round, rings engraved round
/// it, the stars twinkling, and now and then one shooting.
struct ProjectsBackdrop: View {
    let midnight: Bool
    let turning: Bool

    var body: some View {
        if midnight {
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !turning)) { context in
                Canvas { context2, size in
                    Self.draw(&context2, size: size, time: context.date.timeIntervalSinceReferenceDate)
                }
            }
            .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    static func draw(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.13), Midnight.ink]),
            startPoint: CGPoint(x: size.width, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
        let pole = CGPoint(x: size.width * 0.82, y: size.height * 0.12)
        // The rings round the pole, engraved, fading out down the plate.
        for ring in 1...5 {
            let radius = CGFloat(ring) * 110
            let circle = Path(ellipseIn: CGRect(x: pole.x - radius, y: pole.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(circle, with: .color(Midnight.silver.opacity(0.05 - Double(ring) * 0.006)), lineWidth: 0.5)
        }
        // The stars, wheeling slowly round it (once in two hours), each twinkling at its own pace.
        let turn = time.truncatingRemainder(dividingBy: 7200) / 7200 * 2 * .pi
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let reach = hypot(size.width, size.height)
        for _ in 0..<150 {
            let angle = next() * 2 * .pi + turn
            let distance = pow(next(), 0.7) * reach
            let point = CGPoint(x: pole.x + cos(angle) * distance, y: pole.y + sin(angle) * distance)
            let magnitude = next(), phase = next() * 2 * .pi, pace = 0.4 + next() * 1.6
            guard rect.insetBy(dx: -4, dy: -4).contains(point) else { continue }
            let twinkle = 0.55 + 0.45 * sin(time * pace + phase)
            let radius = 0.4 + magnitude * magnitude * 1.3
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(Midnight.white.opacity((0.18 + 0.5 * magnitude) * twinkle)))
        }
        // Now and then, one shooting across, high up.
        let period = 17.0, into = time.truncatingRemainder(dividingBy: period)
        if into < 1.1 {
            let which = floor(time / period)
            let start = CGPoint(x: size.width * (0.25 + 0.5 * abs(sin(which * 12.9898))), y: size.height * (0.08 + 0.2 * abs(sin(which * 78.233))))
            let t = into / 1.1
            let head = CGPoint(x: start.x - 220 * t, y: start.y + 70 * t)
            let tail = CGPoint(x: head.x + 60, y: head.y - 19)
            var streak = Path()
            streak.move(to: tail)
            streak.addLine(to: head)
            context.stroke(streak, with: .linearGradient(Gradient(colors: [Midnight.white.opacity(0), Midnight.white.opacity(0.7 * sin(.pi * t))]),
                                                         startPoint: tail, endPoint: head), lineWidth: 1)
        }
    }
}

// MARK: The sidebar

private struct ProjectsSidebar: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var model: OutlineModel
    @StateObject private var showsResting = LocalState(false)

    var body: some View {
        let midnight = model.theme == .midnight
        let all = store.projects(includingResting: true)
        let active = store.projects()
        let activeIDs = Set(active.map(\.node.id))
        let someday = all.filter { !activeIDs.contains($0.node.id) && $0.node.someday && !$0.node.done }
        let done = all.filter { !activeIDs.contains($0.node.id) && $0.node.done }
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                Text(midnight ? "Projects" : "PROJECTS")
                    .font(midnight ? Midnight.flourish(20) : .system(size: 11, weight: .semibold))
                    .tracking(midnight ? 0 : 0.8)
                    .foregroundStyle(.white.opacity(midnight ? 0.9 : 0.45))
                    .padding(.horizontal, 12)
                    .padding(.bottom, midnight ? 10 : 8)
                    .offset(x: midnight ? 6 : 0)
                row(.pressing, title: "Pressing", symbol: midnight ? "sparkles" : "flame")
                row(.unsorted, title: "Unsorted", symbol: "tray")
                section("Areas & projects") {
                    Button { model.newProject() } label: {
                        Image(systemName: "plus")
                            .notchSymbol(size: 10, weight: .bold)
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .help("New project (⌘N)")
                }
                if active.isEmpty {
                    Text("None yet: + for one, or “#name” in the notch.")
                        .notchFont(size: 11)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                ForEach(active, id: \.node.id) { entry in
                    row(.node(entry.node.id), title: entry.node.title.isEmpty ? "Untitled" : entry.node.title,
                        symbol: ProjectGlyph.symbol(entry.node.kind), depth: entry.depth, node: entry.node)
                }
                if !someday.isEmpty || !done.isEmpty {
                    section(showsResting.value ? "Someday & done" : "Someday & done (\(someday.count + done.count))") {
                        Button { showsResting.value.toggle() } label: {
                            Image(systemName: "chevron.right")
                                .notchSymbol(size: 9, weight: .bold)
                                .rotationEffect(.degrees(showsResting.value ? 90 : 0))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 20, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                    }
                    if showsResting.value {
                        ForEach(someday + done, id: \.node.id) { entry in
                            row(.node(entry.node.id), title: entry.node.title.isEmpty ? "Untitled" : entry.node.title,
                                symbol: entry.node.done ? "checkmark.circle" : "moon.zzz", node: entry.node)
                                .opacity(0.7)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .background {
            if !midnight {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.05))
                    .padding(.leading, 10)
                    .padding(.bottom, 10)
            } else {
                // A pool of deeper night under the list, no edge to it.
                LinearGradient(colors: [Midnight.ink.opacity(0.75), Midnight.ink.opacity(0)], startPoint: .leading, endPoint: .trailing)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsResting.value)
    }

    private func section<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(title.uppercased())
                .notchFont(size: 9.5, weight: .semibold, role: model.theme == .midnight ? .label : nil)
                .tracking(model.theme == .midnight ? 0 : 0.8)
                .foregroundStyle(.white.opacity(0.42))
            Spacer()
            accessory()
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    private func row(_ selection: OutlineSelection, title: String, symbol: String, depth: Int = 0, node: ProjectNode? = nil) -> some View {
        let midnight = model.theme == .midnight
        let selected = model.selection == selection
        return Button { model.selection = selection } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .notchSymbol(size: 11, weight: .semibold)
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
                    .frame(width: 16)
                Text(title)
                    .notchFont(size: 12.5, weight: selected && !midnight ? .semibold : .regular)
                    .foregroundStyle(.white.opacity(selected ? 1 : midnight ? 0.68 : 0.78))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10 + CGFloat(depth) * 14)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background {
                if selected {
                    if midnight {
                        // Moonlight pooled behind it, no edge.
                        EllipticalGradient(colors: [Midnight.moonlight.opacity(0.16), Midnight.moonlight.opacity(0)],
                                           center: UnitPoint(x: 0.3, y: 0.5), startRadiusFraction: 0, endRadiusFraction: 0.6)
                    } else {
                        Capsule().fill(.white.opacity(0.12))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            if let node { ProjectMenu(store: store, model: model, node: node) }
        }
    }
}

// MARK: The page

private struct ProjectsMain: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var model: OutlineModel

    var body: some View {
        Group {
            switch model.selection {
            case .pressing:
                PressingPage(store: store, model: model)
            case .unsorted:
                OutlinePage(store: store, model: model, node: nil)
            case .node(let id):
                if let node = store.node(id) {
                    OutlinePage(store: store, model: model, node: node)
                } else {
                    PressingPage(store: store, model: model)
                }
            }
        }
        .id(model.selection)
        .transition(.opacity)
    }
}

/// A project's page (or Unsorted's, with no `node`): where it is, its name, its notes, its lines,
/// and its last check-ins from the work log. Screenshots and pictures dropped on it come in as lines.
private struct OutlinePage: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var model: OutlineModel
    let node: ProjectNode?
    @StateObject private var dropping = LocalState(false)

    var body: some View {
        let midnight = model.theme == .midnight
        let root = node?.id ?? ProjectStore.inbox
        let rows = model.rows(under: root)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            OutlineRowView(row: row, store: store, model: model)
                                .id(row.id)
                                .modifier(IdeaDrift(order: index, on: midnight))
                        }
                        Button(action: model.addLine) {
                            HStack(spacing: 8) {
                                Image(systemName: "plus")
                                    .notchSymbol(size: 10, weight: .bold)
                                    .frame(width: 18)
                                Text(rows.isEmpty ? "Add a line   (? an idea, - a note, # a subproject)" : "Add a line")
                                    .notchFont(size: 12)
                            }
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(height: 28)
                            .padding(.leading, 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                    }
                    .padding(.top, 8)
                    if let node { logged(node) }
                }
                .padding(.leading, midnight ? 44 : 32)
                .padding(.trailing, midnight ? 60 : 32)
                .padding(.bottom, 40)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.request) { _, request in
                guard let request, rows.contains(where: { $0.id == request.id }) else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(request.id, anchor: nil) }
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: Binding(get: { dropping.value }, set: { dropping.value = $0 })) { providers in
            Self.pictures(from: providers) { urls in store.addPictures(urls, under: root) }
            return true
        }
        .overlay {
            if dropping.value {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.05))
                    .overlay(Text("Drop to add to \(node.map { $0.title.isEmpty ? "this project" : $0.title } ?? "Unsorted")")
                        .notchFont(size: 13, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.7)))
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var header: some View {
        let midnight = model.theme == .midnight
        if let node {
            let path = store.path(to: node.id)
            VStack(alignment: .leading, spacing: 8) {
                // Where it is.
                HStack(spacing: 4) {
                    ForEach(path) { over in
                        Button { model.selection = .node(over.id) } label: {
                            Text(over.title.isEmpty ? "Untitled" : over.title)
                                .notchFont(size: 11)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .buttonStyle(PressableStyle())
                        Image(systemName: "chevron.right")
                            .notchSymbol(size: 8, weight: .bold)
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    Text(node.kind.name.uppercased())
                        .notchFont(size: 9.5, weight: .semibold, role: midnight ? .label : nil)
                        .tracking(midnight ? 0 : 0.8)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(height: 16)
                OutlineField(id: "title:" + node.id, text: node.title, placeholder: node.kind == .area ? "Area name" : "Project name",
                             font: OutlineFonts.title(midnight), model: model,
                             onChange: { store.retitle(node.id, $0) },
                             onKey: { key in
                                 if key == .newline || key == .down { model.titleReturn(); return true }
                                 if key == .escape { NSApp.keyWindow?.makeFirstResponder(nil); return true }
                                 return false
                             })
                    .frame(height: midnight ? 40 : 34)
                if midnight {
                    // An engraved rule under the name, off to one side, fading out.
                    LinearGradient(colors: [Midnight.silver.opacity(0.45), Midnight.silver.opacity(0)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 300, height: 0.5)
                        .offset(x: 18)
                }
                controls(node)
                TextField("Notes", text: Binding(get: { store.node(node.id)?.notes ?? "" },
                                                 set: { text in store.edit(node.id) { $0.notes = text } }),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .font(midnight ? Midnight.italic(12.5) : .system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 4)
            }
            .padding(.top, 10)
            .padding(.bottom, 10)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unsorted")
                    .font(midnight ? Midnight.flourish(30) : .system(size: 26, weight: .bold))
                Text("What you put down in the notch without a #project. File each into one from its menu (⋯, or a right-click), or make an idea a project of its own.")
                    .notchFont(size: 12)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 26)
            .padding(.bottom, 10)
        }
    }

    private func controls(_ node: ProjectNode) -> some View {
        HStack(spacing: 14) {
            toggle(node.kind == .area ? "Area" : "Project", symbol: ProjectGlyph.symbol(node.kind), on: false) {
                store.setKind(node.id, node.kind == .area ? .project : .area)
            }
            .help(node.kind == .area ? "An area: ongoing, like a class (click for a project)" : "A project: it ends (click for an area)")
            toggle("Someday", symbol: "moon.zzz", on: node.someday) { store.edit(node.id) { $0.someday.toggle() } }
                .help("Put off for some day: out of Pressing, under Someday")
            toggle("Done", symbol: "checkmark.circle", on: node.done) { store.toggle(node.id) }
            toggle("Screenshot", symbol: "camera.viewfinder", on: false) { model.shoot(nil, node.id) }
                .help("Screenshot something into this project, as ⇧⌘4 does")
            toggle(model.showsDone ? "Hide done" : "Show done", symbol: "eye", on: model.showsDone) { model.showsDone.toggle() }
            Spacer()
        }
    }

    private func toggle(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .notchSymbol(size: 10, weight: .semibold)
                Text(title)
                    .notchFont(size: 11, weight: .semibold)
            }
            .foregroundStyle(.white.opacity(on ? 0.95 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder private func logged(_ node: ProjectNode) -> some View {
        let entries = model.logged(node.handle)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("LOGGED  #\(node.handle)")
                    .notchFont(size: 9.5, weight: .semibold, role: model.theme == .midnight ? .label : nil)
                    .tracking(model.theme == .midnight ? 0 : 0.8)
                    .foregroundStyle(.white.opacity(0.42))
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(entry.day)
                            .notchFont(size: 10.5, digits: true)
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: 92, alignment: .leading)
                        Text(entry.text)
                            .notchFont(size: 12)
                            .foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 26)
        }
    }

    /// The pictures among what was dropped (files, or images dragged straight from a browser,
    /// saved first), on the main thread.
    static func pictures(from providers: [NSItemProvider], then add: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        let kinds: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp", "bmp", "pdf"]
        for provider in providers {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, kinds.contains(url.pathExtension.lowercased()) {
                        lock.lock(); urls.append(url); lock.unlock()
                    }
                    group.leave()
                }
            } else {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                    if let data {
                        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Oyl idea \(UUID().uuidString).png")
                        if (try? data.write(to: file)) != nil {
                            lock.lock(); urls.append(file); lock.unlock()
                        }
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { add(urls) }
        }
    }
}

/// Everything with a day, across every project: late, today, tomorrow, the week, later. Click
/// a line's project to open it there.
private struct PressingPage: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var model: OutlineModel

    var body: some View {
        let midnight = model.theme == .midnight
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let groups = Self.groups(store.pressing(within: nil, now: context.date), now: context.date)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pressing")
                        .font(midnight ? Midnight.flourish(30) : .system(size: 26, weight: .bold))
                        .padding(.top, 26)
                    Text(groups.isEmpty ? "Nothing with a day yet. Give a task one as you type it (“essay fri 5pm”): a time reminds you then, from the notch."
                         : "Every task with a day, across your projects, the soonest first.")
                        .notchFont(size: 12)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 6)
                        .padding(.bottom, 12)
                    ForEach(Array(groups.enumerated()), id: \.element.title) { index, group in
                        Text(group.title.uppercased())
                            .notchFont(size: 9.5, weight: .semibold, role: midnight ? .label : nil)
                            .tracking(midnight ? 0 : 0.8)
                            .foregroundStyle(group.late ? (midnight ? Midnight.fringeRed : Color(red: 1, green: 0.5, blue: 0.45)) : .white.opacity(0.42))
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                            .modifier(IdeaDrift(order: index * 4, on: midnight))
                        ForEach(Array(group.tasks.enumerated()), id: \.element.node.id) { offset, entry in
                            PressingRow(node: entry.node, project: entry.project, store: store, model: model, now: context.date)
                                .modifier(IdeaDrift(order: index * 4 + offset + 1, on: midnight))
                        }
                    }
                }
                .padding(.leading, midnight ? 44 : 32)
                .padding(.trailing, 32)
                .padding(.bottom, 40)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    static func groups(_ tasks: [(node: ProjectNode, project: ProjectNode?)], now: Date)
        -> [(title: String, late: Bool, tasks: [(node: ProjectNode, project: ProjectNode?)])] {
        let calendar = Calendar.current, today = calendar.startOfDay(for: now)
        var order: [String] = []
        var grouped: [String: [(node: ProjectNode, project: ProjectNode?)]] = [:]
        for task in tasks {
            let day = task.node.due.flatMap(IdeaQuick.date) ?? today
            let ahead = calendar.dateComponents([.day], from: today, to: day).day ?? 0
            let late = (task.node.dueDate ?? now) < now
            let title = late ? "Late" : ahead <= 0 ? "Today" : ahead == 1 ? "Tomorrow" : ahead < 7 ? "This week" : "Later"
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(task)
        }
        return order.map { ($0, $0 == "Late", grouped[$0] ?? []) }
    }
}

private struct PressingRow: View {
    let node: ProjectNode
    let project: ProjectNode?
    @ObservedObject var store: ProjectStore
    @ObservedObject var model: OutlineModel
    let now: Date

    var body: some View {
        let midnight = model.theme == .midnight
        let late = (node.dueDate ?? now) < now
        HStack(spacing: 10) {
            TaskRing(done: node.done, midnight: midnight) { store.toggle(node.id) }
            Text(node.title)
                .notchFont(size: 13.5)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            if let project {
                Button { model.reveal(node.id) } label: {
                    Text(project.title)
                        .notchFont(size: 11.5)
                        .foregroundStyle(.white.opacity(0.42))
                }
                .buttonStyle(PressableStyle())
                .help("Open it in \(project.title)")
            }
            Spacer(minLength: 8)
            if node.time != nil {
                Image(systemName: "bell")
                    .notchSymbol(size: 9.5, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.4))
            }
            Text(IdeaQuick.describe(due: node.due ?? "", time: node.time, now: now))
                .notchFont(size: 11.5, weight: .semibold, digits: true)
                .foregroundStyle(late ? (midnight ? Midnight.fringeRed : Color(red: 1, green: 0.5, blue: 0.45)) : .white.opacity(0.7))
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.reveal(node.id) }
    }
}

// MARK: A line

/// A line of the outline: folded or not, its mark (a ring to check a task off; a project's opens
/// it), its screenshot if it has one, its words to type in, and when it's due; pointed at, a menu
/// of what can be done with it.
private struct OutlineRowView: View {
    let row: OutlineRow
    @ObservedObject var store: ProjectStore
    @ObservedObject var model: OutlineModel
    @StateObject private var hover = LocalState(false)

    var body: some View {
        let node = row.node
        let midnight = model.theme == .midnight
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.depth) * 22, height: 1)
            Button { store.edit(node.id) { $0.collapsed.toggle() } } label: {
                Image(systemName: "chevron.right")
                    .notchSymbol(size: 8.5, weight: .bold)
                    .rotationEffect(.degrees(node.collapsed ? 0 : 90))
                    .foregroundStyle(.white.opacity(row.hasChildren ? (hover.value || node.collapsed ? 0.6 : 0.25) : 0))
                    .frame(width: 12, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(!row.hasChildren)
            mark(node, midnight: midnight)
            if let image = store.thumbnail(node), let url = store.shotURL(node) {
                Button { NSWorkspace.shared.open(url) } label: {
                    IdeaShot(image: image, width: 46, height: 29).contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .help("Open the screenshot")
            }
            OutlineField(id: node.id, text: node.title, placeholder: Self.placeholder(node.kind),
                         font: OutlineFonts.line(midnight, kind: node.kind), dim: node.done, model: model,
                         onChange: { store.retitle(node.id, $0) },
                         onKey: { model.key($0, in: node.id) },
                         onEnd: { store.finishEditing(node.id) })
                .frame(height: 24)
            if node.collapsed, row.hasChildren {
                Text("\(node.children.count) more")
                    .notchFont(size: 10.5)
                    .foregroundStyle(.white.opacity(0.35))
            }
            if let due = node.due {
                let late = (node.dueDate ?? .distantFuture) < Date() && !node.done
                HStack(spacing: 4) {
                    if node.time != nil {
                        Image(systemName: "bell").notchSymbol(size: 9, weight: .semibold)
                    }
                    Text(IdeaQuick.describe(due: due, time: node.time))
                        .notchFont(size: 11, weight: .semibold, digits: true)
                }
                .foregroundStyle(late ? (midnight ? Midnight.fringeRed : Color(red: 1, green: 0.5, blue: 0.45)) : .white.opacity(0.55))
            }
            Menu {
                ProjectMenu(store: store, model: model, node: node)
            } label: {
                Image(systemName: "ellipsis")
                    .notchSymbol(size: 11, weight: .bold)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // (A menu draws its label its own way: it's the menu that fades.)
            .opacity(hover.value ? 1 : 0)
        }
        .frame(minHeight: 30)
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .contextMenu { ProjectMenu(store: store, model: model, node: node) }
        .animation(.easeOut(duration: 0.15), value: hover.value)
    }

    @ViewBuilder private func mark(_ node: ProjectNode, midnight: Bool) -> some View {
        switch node.kind {
        case .task:
            TaskRing(done: node.done, midnight: midnight) { store.toggle(node.id) }
        case .project, .area:
            Button { model.selection = .node(node.id) } label: {
                Group {
                    if midnight {
                        FourPointStar()
                            .fill(Midnight.silver.opacity(0.85))
                            .frame(width: node.kind == .area ? 12 : 10, height: node.kind == .area ? 12 : 10)
                    } else {
                        Image(systemName: node.kind == .area ? "square.stack.fill" : "folder.fill")
                            .notchSymbol(size: 11, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help("Open \(node.title.isEmpty ? "it" : node.title)")
        case .idea:
            Image(systemName: midnight ? "moon.stars" : "lightbulb")
                .notchSymbol(size: 11, weight: .semibold)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 18)
        case .note:
            Image(systemName: "minus")
                .notchSymbol(size: 9, weight: .bold)
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 18)
        }
    }

    static func placeholder(_ kind: ProjectNode.Kind) -> String {
        switch kind {
        case .task: return "A task (“essay fri 5pm”)"
        case .idea: return "An idea"
        case .note: return "A note"
        case .project: return "A subproject"
        case .area: return "An area"
        }
    }
}

/// A task's ring: in Oyl's look, the notch's; in Midnight Oyl's, an engraved ring that becomes
/// a star once it's done.
private struct TaskRing: View {
    let done: Bool
    let midnight: Bool
    let toggle: () -> Void

    var body: some View {
        Button {
            Haptics.perform(.levelChange)
            toggle()
        } label: {
            Group {
                if midnight {
                    if done {
                        Image(systemName: "sparkle")
                            .notchSymbol(size: 12, weight: .semibold)
                            .foregroundStyle(Midnight.white)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    } else {
                        Circle().strokeBorder(Midnight.silver.opacity(0.7), lineWidth: 0.8).frame(width: 12, height: 12)
                    }
                } else {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .notchSymbol(size: 13, weight: .regular)
                        .foregroundStyle(.white.opacity(done ? 0.9 : 0.55))
                }
            }
            .frame(width: 18, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .animation(midnight ? .spring(response: 0.4, dampingFraction: 0.6) : .easeOut(duration: 0.15), value: done)
        .help(done ? "Not done after all" : "Done (⌘↩)")
    }
}

/// A four-pointed star, Midnight Oyl's mark for a project.
struct FourPointStar: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2, w = r * 0.28
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
        path.closeSubpath()
        return path
    }
}

/// What can be done with a line (or a project in the list): what kind it is, a reminder, where
/// it goes, its screenshot, and taking it away.
private struct ProjectMenu: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var model: OutlineModel
    let node: ProjectNode

    var body: some View {
        if node.kind.isProject {
            Button("Open") { model.selection = .node(node.id) }
            Button("New Subproject") { model.newProject(under: node.id) }
            Divider()
        }
        if node.kind == .idea {
            Button("Make It a Project") { store.makeProject(node.id) }
        }
        Menu("Make It") {
            ForEach(ProjectNode.Kind.allCases, id: \.self) { kind in
                Button(kind.name + (kind == node.kind ? "  ✓" : "")) { store.setKind(node.id, kind) }
            }
        }
        Menu("Remind Me") {
            let now = Date()
            Button("In an Hour") { remind(now.addingTimeInterval(3600)) }
            Button("This Evening, 6 PM") { remind(Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now) }
            Button("Tomorrow Morning, 9 AM") {
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
                remind(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
            }
            if node.due != nil {
                Divider()
                Button("No Day") { store.setDue(node.id, due: nil, time: nil) }
            }
        }
        Menu("Move To") {
            let parent = store.place(of: node.id)?.parent
            if parent != ProjectStore.inbox {
                Button("Unsorted") { store.move(node.id, to: ProjectStore.inbox) }
            }
            if node.kind.isProject, parent != nil {
                Button("The Top") { store.move(node.id, to: nil) }
            }
            Divider()
            // Anywhere but itself and what's under it (gathered once, not each project's path
            // looked up through the whole outline).
            let under = store.node(node.id)?.idsUnder ?? []
            ForEach(store.projects().filter { $0.node.id != node.id && !under.contains($0.node.id) },
                    id: \.node.id) { entry in
                Button(String(repeating: "    ", count: entry.depth) + (entry.node.title.isEmpty ? "Untitled" : entry.node.title)) {
                    store.move(node.id, to: entry.node.id)
                }
            }
        }
        Divider()
        if store.shotURL(node) != nil {
            Button("Open Screenshot") { if let url = store.shotURL(node) { NSWorkspace.shared.open(url) } }
        }
        Button(node.shot == nil ? "Add a Screenshot…" : "Replace the Screenshot…") { model.shoot(node.id, nil) }
        if node.kind.isProject {
            Button(node.someday ? "Back from Someday" : "Put Off to Someday") { store.edit(node.id) { $0.someday.toggle() } }
            Button(node.done ? "Not Done" : "Done") { store.toggle(node.id) }
        }
        Divider()
        Button("Delete") { delete() }
    }

    private func remind(_ at: Date) {
        if node.kind != .task { store.setKind(node.id, .task) }
        let stamp = ProjectNode.stamp(at)
        store.setDue(node.id, due: stamp.due, time: stamp.time)
    }

    /// A line with lines under it (or a project) asks first.
    private func delete() {
        if !node.children.isEmpty || node.kind.isProject {
            let alert = NSAlert()
            alert.messageText = "Delete \(node.title.isEmpty ? "this" : "“\(node.title)”")\(node.children.isEmpty ? "" : " and everything in it")?"
            alert.informativeText = "This can't be undone."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if model.selection == .node(node.id) { model.selection = .pressing }
        store.delete(node.id)
    }
}

// MARK: - Typing in a line

/// The faces lines are typed in: the system's in Oyl's look; in Midnight Oyl's, Georgia for the
/// lines (a project's in Superclarendon) and Superclarendon's light italic for a page's name.
enum OutlineFonts {
    static func title(_ midnight: Bool) -> NSFont {
        midnight ? NSFont(name: "Superclarendon-LightItalic", size: 30) ?? .systemFont(ofSize: 28) : .systemFont(ofSize: 26, weight: .bold)
    }

    static func line(_ midnight: Bool, kind: ProjectNode.Kind) -> NSFont {
        let project = kind.isProject
        if midnight {
            return NSFont(name: project ? "Superclarendon-Regular" : "Georgia", size: project ? 13.5 : 14.5) ?? .systemFont(ofSize: 14)
        }
        return .systemFont(ofSize: 13.5, weight: project ? .semibold : .regular)
    }
}

/// A line's words, typed straight into it: its keys go to the outline (`OutlineKey`), and it
/// takes the keyboard when the outline asks it to.
struct OutlineField: NSViewRepresentable {
    let id: String
    let text: String
    let placeholder: String
    let font: NSFont
    var dim = false
    @ObservedObject var model: OutlineModel
    let onChange: (String) -> Void
    let onKey: (OutlineKey) -> Bool
    var onEnd: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> OutlineTextField {
        let field = OutlineTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.stringValue = text
        style(field)
        return field
    }

    func updateNSView(_ field: OutlineTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        style(field)
        if let request = model.request, request.id == id, request.token != context.coordinator.token {
            context.coordinator.token = request.token
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                if field.currentEditor() == nil, !window.makeFirstResponder(field) { return }
                field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            }
        }
    }

    private func style(_ field: OutlineTextField) {
        let color = NSColor.white.withAlphaComponent(dim ? 0.4 : 0.92)
        if field.font != font { field.font = font }
        if field.textColor != color { field.textColor = color }
        if field.placeholderAttributedString?.string != placeholder || field.placeholderAttributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont != font {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.25), .font: font,
            ])
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OutlineField
        var token = 0

        init(_ parent: OutlineField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.model.focused = parent.id
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.model.focused == parent.id { parent.model.focused = nil }
            parent.onEnd()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let key: OutlineKey?
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): key = .newline
            case #selector(NSResponder.insertTab(_:)): key = .tab
            case #selector(NSResponder.insertBacktab(_:)): key = .backtab
            case #selector(NSResponder.moveUp(_:)): key = .up
            case #selector(NSResponder.moveDown(_:)): key = .down
            case #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)): key = .moveUp
            case #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)): key = .moveDown
            case #selector(NSResponder.deleteBackward(_:)): key = textView.string.isEmpty ? .deleteEmpty : nil
            case #selector(NSResponder.cancelOperation(_:)): key = .escape
            default: key = nil
            }
            guard let key else { return false }
            return parent.onKey(key)
        }
    }
}

final class OutlineTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        (currentEditor() as? NSTextView)?.insertionPointColor = .white
        return became
    }
}

