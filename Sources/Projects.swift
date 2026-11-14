import AppKit
import SwiftUI

// Projects: everything you've got going, as an outline of text, kept by Oyl itself (tod is left
// as it is). Areas (a class, a job: ongoing) and projects (something with an end) hold
// subprojects, assignments and tasks (with subtasks), ideas, notes and screenshots, nested as
// deep as they go, each line one `ProjectNode`. As other tools have it:
//
// - **Captured from anywhere, filed as it's typed** (Akiflow's and Things' quick entry, Tana's "no
//   inbox"): the notch's projects page takes "#oyl fix the dock fri 5pm" straight into the Oyl
//   project, due Friday at 5; "?" first makes it an idea; the camera adds a screenshot. Without a
//   #project it waits in Unsorted to be filed (Linear's triage).
// - **Pressing, not prioritized**: what's due soonest across every project comes first; a task
//   with a time reminds you then, the notch popping open to say so.
// - **Ideas become projects** (GTD's someday/maybe): any idea can be made a project, and a
//   project can be put off to Someday.
// - **The outline** (Workflowy's, OmniFocus's): its own window, a project opened to its page, its
//   lines typed and indented as in any outliner (see `ProjectsWindow`).

/// One line of the outline: an area, a project, a task, an idea or a note, and what's under it.
/// Any line can carry a screenshot.
struct ProjectNode: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case area, project, task, idea, note

        /// Holds work: listed beside the outline, and what a #tag files into.
        var isProject: Bool { self == .area || self == .project }

        var name: String {
            switch self {
            case .area: return "Area"
            case .project: return "Project"
            case .task: return "Task"
            case .idea: return "Idea"
            case .note: return "Note"
            }
        }
    }

    var id = UUID().uuidString
    var kind: Kind
    var title: String
    var notes = ""
    /// "YYYY-MM-DD", and "HH:MM" (a task with a time reminds you then).
    var due: String?
    var time: String?
    var done = false
    var doneAt: Date?
    var created = Date()
    /// Its lines folded away in the outline.
    var collapsed = false
    /// A project put off: an idea for one, for some day.
    var someday = false
    /// Its screenshot's file, in the projects' folder.
    var shot: String?
    /// When its reminder last went off, so it doesn't again (till its time's changed).
    var reminded: Date?
    var children: [ProjectNode] = []

    init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }

    /// When it's due: at its time, or the end of its day.
    var dueDate: Date? { Self.moment(due, time) }

    static func moment(_ due: String?, _ time: String?, calendar: Calendar = .current) -> Date? {
        let day = (due ?? "").split(separator: "-").compactMap { Int($0) }
        guard day.count == 3 else { return nil }
        let clock = (time ?? "").split(separator: ":").compactMap { Int($0) }
        let (hour, minute, second) = clock.count == 2 ? (clock[0], clock[1], 0) : (23, 59, 59)
        return calendar.date(from: DateComponents(year: day[0], month: day[1], day: day[2], hour: hour, minute: minute, second: second))
    }

    /// "YYYY-MM-DD" and "HH:MM" for `date`.
    static func stamp(_ date: Date, calendar: Calendar = .current) -> (due: String, time: String) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return (String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!),
                String(format: "%02d:%02d", parts.hour!, parts.minute!))
    }

    /// Its #tag: its name's letters and digits, run together ("CS 229" is #cs229).
    var handle: String { ProjectQuick.handle(title) }
}

extension ProjectNode: Codable {
    private enum Keys: String, CodingKey {
        case id, kind, title, notes, due, time, done, doneAt, created, collapsed, someday, shot, reminded, children
    }

    // Every field optional, so the file can grow without an old one failing to read; a kind it
    // doesn't know is a task.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0 }.flatMap(Kind.init(rawValue:)) ?? .task
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        due = try c.decodeIfPresent(String.self, forKey: .due)
        time = try c.decodeIfPresent(String.self, forKey: .time)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        someday = try c.decodeIfPresent(Bool.self, forKey: .someday) ?? false
        shot = try c.decodeIfPresent(String.self, forKey: .shot)
        reminded = try c.decodeIfPresent(Date.self, forKey: .reminded)
        children = try c.decodeIfPresent([ProjectNode].self, forKey: .children) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(title, forKey: .title)
        if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
        try c.encodeIfPresent(due, forKey: .due)
        try c.encodeIfPresent(time, forKey: .time)
        if done { try c.encode(done, forKey: .done) }
        try c.encodeIfPresent(doneAt, forKey: .doneAt)
        try c.encode(created, forKey: .created)
        if collapsed { try c.encode(collapsed, forKey: .collapsed) }
        if someday { try c.encode(someday, forKey: .someday) }
        try c.encodeIfPresent(shot, forKey: .shot)
        try c.encodeIfPresent(reminded, forKey: .reminded)
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }
}

// MARK: - Reading a line

/// What a line typed into the projects page means: "#oyl fix the dock fri 5pm" is a task for the
/// Oyl project, due Friday at 5 PM (dates and times read as tod reads them, `TodQuick`); "?"
/// first, or the field set to ideas, makes it an idea, whose words are kept as they are, dates
/// and all. The first #tag picks the project; any others go.
struct ProjectQuick: Equatable {
    let title: String
    let tag: String?
    let kind: ProjectNode.Kind
    let due: String?
    let time: String?

    static func parse(_ input: String, idea: Bool = false, now: Date = Date(), weekStart: Int = 1) -> ProjectQuick {
        var text = input.trimmingCharacters(in: .whitespaces)
        var kind: ProjectNode.Kind = idea ? .idea : .task
        if text.hasPrefix("?") {
            kind = .idea
            text = String(text.dropFirst())
        }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let tag = TodQuick.tagPattern.firstMatch(in: text, range: whole).map { ns.substring(with: $0.range(at: 1)) }
        text = TodQuick.tagPattern.stringByReplacingMatches(in: text, range: whole, withTemplate: " ")
        guard kind == .task else {
            return ProjectQuick(title: tidy(text), tag: tag, kind: kind, due: nil, time: nil)
        }
        let read = dates(text, now: now, weekStart: weekStart)
        return ProjectQuick(title: read.title, tag: tag, kind: kind, due: read.due, time: read.time)
    }

    /// A task's day and time read out of its line, as tod reads them, its #s left as they are.
    static func dates(_ text: String, now: Date = Date(), weekStart: Int = 1) -> (title: String, due: String?, time: String?) {
        let read = TodQuick.read(text.replacingOccurrences(of: "#", with: hash), now: now, weekStart: weekStart)
        return (tidy(read.title).replacingOccurrences(of: hash, with: "#"), read.due, read.time)
    }

    /// What a line in the outline is typed as, by how it starts, as Markdown would have it: "? "
    /// an idea, "- " a note, "# " a project, "[] " a task; and the line without that.
    static func prefix(_ text: String) -> (kind: ProjectNode.Kind, rest: String)? {
        for (start, kind) in [("? ", ProjectNode.Kind.idea), ("- ", .note), ("# ", .project), ("[] ", .task), ("[ ] ", .task)]
        where text.hasPrefix(start) {
            return (kind, String(text.dropFirst(start.count)))
        }
        return nil
    }

    /// A name's #tag: its letters and digits, lowercased, run together.
    static func handle(_ name: String) -> String { TodQuick.words(name).joined() }

    /// The tag being typed just before the caret ("#cs2" in "essay #cs2"), without its "#".
    static func typingTag(_ before: String) -> String? {
        guard let hash = before.lastIndex(of: "#") else { return nil }
        let tag = before[before.index(after: hash)...]
        guard !tag.isEmpty, tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        if hash > before.startIndex, let previous = before[..<hash].last, previous.isLetter || previous.isNumber { return nil }
        return String(tag)
    }

    private static let hash = "\u{FF03}"

    private static func tidy(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:-–—")))
    }
}

// MARK: - The outline, worked on

private extension Array where Element == ProjectNode {
    func node(_ id: String) -> ProjectNode? {
        for node in self {
            if node.id == id { return node }
            if let found = node.children.node(id) { return found }
        }
        return nil
    }

    /// The node holding `id` (`parent`, at this level) and where it is among its siblings.
    func place(of id: String, parent: String? = nil) -> (parent: String?, index: Int)? {
        for (index, node) in enumerated() {
            if node.id == id { return (parent, index) }
            if let found = node.children.place(of: id, parent: node.id) { return found }
        }
        return nil
    }

    @discardableResult
    mutating func edit(_ id: String, _ change: (inout ProjectNode) -> Void) -> Bool {
        for index in indices {
            if self[index].id == id {
                change(&self[index])
                return true
            }
            if self[index].children.edit(id, change) { return true }
        }
        return false
    }

    mutating func take(_ id: String) -> ProjectNode? {
        if let index = firstIndex(where: { $0.id == id }) { return remove(at: index) }
        for index in indices {
            if let taken = self[index].children.take(id) { return taken }
        }
        return nil
    }

    /// `node` among `parent`'s children (or at this level), at `index` (or the end).
    @discardableResult
    mutating func put(_ node: ProjectNode, under parent: String?, at index: Int?) -> Bool {
        guard let parent else {
            insert(node, at: Swift.min(Swift.max(index ?? count, 0), count))
            return true
        }
        return edit(parent) { $0.children.insert(node, at: Swift.min(Swift.max(index ?? $0.children.count, 0), $0.children.count)) }
    }

    /// Every node, depth first, with the nodes over it.
    func walk(_ path: [ProjectNode] = [], _ visit: (ProjectNode, [ProjectNode]) -> Void) {
        for node in self {
            visit(node, path)
            node.children.walk(path + [node], visit)
        }
    }
}

/// Your projects, kept in Oyl's own folder (a copy of the file as it was at launch beside it),
/// saved a moment after each change. Unsorted (`inbox`) holds what was captured without a
/// #project. Screenshots are kept beside it, named for their lines.
@MainActor
final class ProjectStore: ObservableObject {
    struct Saved: Codable, Equatable {
        var version = 1
        var items: [ProjectNode] = []
        var inbox: [ProjectNode] = []

        init(items: [ProjectNode], inbox: [ProjectNode]) {
            self.items = items
            self.inbox = inbox
        }

        // Any part missing is empty.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            items = try c.decodeIfPresent([ProjectNode].self, forKey: .items) ?? []
            inbox = try c.decodeIfPresent([ProjectNode].self, forKey: .inbox) ?? []
        }
    }

    /// The parent that means Unsorted.
    static let inbox = "inbox"

    @Published private(set) var items: [ProjectNode] = []
    @Published private(set) var inbox: [ProjectNode] = []
    /// A task whose time has come, the notch open to say so, till it's seen to.
    @Published private(set) var ringing: ProjectNode?
    /// What couldn't be read or saved, if anything.
    @Published private(set) var problem: String?
    /// tod's first day of the week (1 Monday), for reading "next week".
    var weekStart = 1
    /// Played as a reminder goes off.
    var chime: () -> Void = { NSSound(named: NSSound.Name("Glass"))?.play() }
    /// Where a deleted line's screenshot goes: the Trash. (A test gives its own.)
    var discard: (URL) -> Void = { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    let folder: URL
    var file: URL { folder.appendingPathComponent("Projects.json") }
    var shotsFolder: URL { folder.appendingPathComponent("Screenshots", isDirectory: true) }
    private var thumbnails: [String: NSImage] = [:]
    private var saving: DispatchWorkItem?
    private var clock: Timer?

    nonisolated static var ownFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oyl/Projects", isDirectory: true)
    }

    /// Reminders are looked for every 15 seconds, if `reminding`.
    init(folder: URL = ProjectStore.ownFolder, reminding: Bool = true) {
        self.folder = folder
        let files = FileManager.default
        if let data = try? Data(contentsOf: file) {
            if let saved = try? Self.decoder.decode(Saved.self, from: data) {
                items = saved.items
                inbox = saved.inbox
                let backup = folder.appendingPathComponent("Projects.backup.json")
                try? files.removeItem(at: backup)
                try? files.copyItem(at: file, to: backup)
            } else {
                // Kept aside, never written over.
                let aside = folder.appendingPathComponent("Projects (unreadable \(Int(Date().timeIntervalSince1970))).json")
                try? files.moveItem(at: file, to: aside)
                problem = "Oyl couldn't read your projects, so it put the file aside in its folder."
            }
        }
        guard reminding else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReminders() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.checkReminders() }
        }
    }

    // MARK: Looking

    func node(_ id: String) -> ProjectNode? { items.node(id) ?? inbox.node(id) }

    /// Where `id` is: its parent (nil at the top; `inbox` loose in Unsorted) and its place there.
    func place(of id: String) -> (parent: String?, index: Int)? {
        if let place = items.place(of: id) { return place }
        if let place = inbox.place(of: id) { return (place.parent ?? Self.inbox, place.index) }
        return nil
    }

    func children(of parent: String?) -> [ProjectNode] {
        switch parent {
        case nil: return items
        case Self.inbox?: return inbox
        case let id?: return node(id)?.children ?? []
        }
    }

    /// The nodes over `id`, the topmost first (none in Unsorted's top).
    func path(to id: String) -> [ProjectNode] {
        var path: [ProjectNode] = []
        var at = place(of: id)?.parent
        while let parent = at, parent != Self.inbox, let node = node(parent) {
            path.insert(node, at: 0)
            at = place(of: parent)?.parent
        }
        return path
    }

    /// The project (or area) `id` is in: the nearest over it.
    func project(of id: String) -> ProjectNode? { path(to: id).last { $0.kind.isProject } }

    /// Every area and project, in the outline's order, with how deep it is; those done, or put
    /// off to someday, only if asked for.
    func projects(includingResting: Bool = false) -> [(node: ProjectNode, depth: Int)] {
        var found: [(node: ProjectNode, depth: Int)] = []
        items.walk { node, path in
            guard node.kind.isProject, path.allSatisfy(\.kind.isProject) else { return }
            if !includingResting, node.done || node.someday || path.contains(where: { $0.done || $0.someday }) { return }
            found.append((node, path.count))
        }
        return found
    }

    /// The project `tag` files into, as a #list does in tod: its whole name, then a word of it
    /// starting with the tag, then the name run together containing it.
    func project(for tag: String) -> String? {
        TodQuick.list(for: tag, among: projects().map { (id: $0.node.id, name: $0.node.title) })
    }

    /// A project's #tag that starts with what's been typed of one.
    func completion(of typed: String) -> String? {
        let typed = ProjectQuick.handle(typed)
        guard !typed.isEmpty else { return nil }
        return projects().map(\.node.handle).first { $0.hasPrefix(typed) && $0 != typed }
    }

    /// Tasks not done with a day, soonest first (late ones first of all), and the project each is
    /// in: those within `days` of today, or all. Anything under a project that's done or put off
    /// is left out.
    func pressing(within days: Int? = 7, now: Date = Date()) -> [(node: ProjectNode, project: ProjectNode?)] {
        let horizon = days.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: Calendar.current.startOfDay(for: now)) }
        var found: [(node: ProjectNode, project: ProjectNode?, when: Date)] = []
        func look(_ nodes: [ProjectNode]) {
            nodes.walk { node, path in
                guard node.kind == .task, !node.done, let when = node.dueDate,
                      !path.contains(where: { $0.done || $0.someday }) else { return }
                if let horizon, when >= horizon { return }
                found.append((node, path.last { $0.kind.isProject }, when))
            }
        }
        look(items)
        look(inbox)
        return found.enumerated().sorted { a, b in
            a.element.when != b.element.when ? a.element.when < b.element.when : a.offset < b.offset
        }
        .map { ($0.element.node, $0.element.project) }
    }

    // MARK: Changing

    /// Changes the outline and Unsorted together, then saves them a moment later.
    private func change(_ make: (inout [ProjectNode], inout [ProjectNode]) -> Void) {
        var outline = items, loose = inbox
        make(&outline, &loose)
        if outline != items { items = outline }
        if loose != inbox { inbox = loose }
        saveSoon()
    }

    private static func put(_ node: ProjectNode, under parent: String?, at index: Int?,
                            _ outline: inout [ProjectNode], _ loose: inout [ProjectNode]) -> Bool {
        if parent == inbox { return loose.put(node, under: nil, at: index) }
        if let parent, loose.node(parent) != nil { return loose.put(node, under: parent, at: index) }
        return outline.put(node, under: parent, at: index)
    }

    /// `node` put under `parent` (nil: the top; `inbox`: Unsorted), at `index` or the end.
    @discardableResult
    func add(_ node: ProjectNode, under parent: String?, at index: Int? = nil) -> ProjectNode {
        change { outline, loose in _ = Self.put(node, under: parent, at: index, &outline, &loose) }
        return node
    }

    /// A new project (or area), at the top or under `parent`.
    @discardableResult
    func newProject(named name: String, kind: ProjectNode.Kind = .project, under parent: String? = nil) -> ProjectNode {
        add(ProjectNode(kind: kind, title: name), under: parent)
    }

    func edit(_ id: String, _ make: (inout ProjectNode) -> Void) {
        change { outline, loose in
            if !outline.edit(id, make) { loose.edit(id, make) }
        }
    }

    /// Its day and time (none for neither), reminding afresh.
    func setDue(_ id: String, due: String?, time: String?) {
        edit(id) { node in
            guard node.due != due || node.time != time else { return }
            node.due = due
            node.time = due == nil ? nil : time
            node.reminded = nil
        }
        if ringing?.id == id { ringing = nil }
    }

    /// Its title as typed: started "? ", "- ", "# " or "[] ", it becomes an idea, a note, a
    /// project or a task.
    func retitle(_ id: String, _ title: String) {
        edit(id) { node in
            if let typed = ProjectQuick.prefix(title) {
                node.kind = typed.kind
                node.title = typed.rest
            } else {
                node.title = title
            }
        }
    }

    /// A task's line finished: the day and time in it read out (and reminding afresh).
    func finishEditing(_ id: String, now: Date = Date()) {
        guard let node = node(id), node.kind == .task else { return }
        let read = ProjectQuick.dates(node.title, now: now, weekStart: weekStart)
        guard read.due != nil else { return }
        edit(id) { $0.title = read.title.isEmpty ? $0.title : read.title }
        setDue(id, due: read.due, time: read.time)
    }

    /// Gone, with everything under it (their screenshots to the Trash).
    func delete(_ id: String) {
        guard let gone = node(id) else { return }
        change { outline, loose in _ = outline.take(id) ?? loose.take(id) }
        [gone].walk { node, _ in
            if let shot = node.shot { discard(shotsFolder.appendingPathComponent(shot)) }
        }
        if ringing.map({ gone.children.node($0.id) != nil || $0.id == id }) == true { ringing = nil }
    }

    /// `id` moved under `parent` (nil: the top; `inbox`: Unsorted), at `index` or the end. Not
    /// into itself, and only areas and projects at the top.
    @discardableResult
    func move(_ id: String, to parent: String?, at index: Int? = nil) -> Bool {
        guard let node = node(id), parent != id else { return false }
        if let parent, parent != Self.inbox, self.node(parent) == nil || path(to: parent).contains(where: { $0.id == id }) { return false }
        if parent == nil, !node.kind.isProject { return false }
        var moved = false
        change { outline, loose in
            guard let taken = outline.take(id) ?? loose.take(id) else { return }
            moved = Self.put(taken, under: parent, at: index, &outline, &loose)
            if !moved { _ = outline.put(taken, under: nil, at: nil) }
        }
        return moved
    }

    /// Made the last line under the one before it.
    @discardableResult
    func indent(_ id: String) -> Bool {
        guard let place = place(of: id), place.index > 0 else { return false }
        let above = children(of: place.parent)[place.index - 1]
        guard move(id, to: above.id) else { return false }
        edit(above.id) { $0.collapsed = false }
        return true
    }

    /// Out from under its parent, to just after it; never out past `floor` (the project open in
    /// the outline), and only areas and projects out to the top.
    @discardableResult
    func outdent(_ id: String, floor: String? = nil) -> Bool {
        guard let parent = place(of: id)?.parent, parent != Self.inbox, parent != floor,
              let above = place(of: parent) else { return false }
        return move(id, to: above.parent, at: above.index + 1)
    }

    /// Up or down among its siblings.
    @discardableResult
    func shift(_ id: String, by offset: Int) -> Bool {
        guard let place = place(of: id) else { return false }
        let target = place.index + offset
        guard target >= 0, target < children(of: place.parent).count else { return false }
        change { outline, loose in
            guard let taken = outline.take(id) ?? loose.take(id) else { return }
            _ = Self.put(taken, under: place.parent, at: target, &outline, &loose)
        }
        return true
    }

    /// Done, or not done after all.
    func toggle(_ id: String, now: Date = Date()) {
        edit(id) { node in
            node.done.toggle()
            node.doneAt = node.done ? now : nil
        }
        if ringing?.id == id { ringing = nil }
    }

    func setKind(_ id: String, _ kind: ProjectNode.Kind) {
        edit(id) { $0.kind = kind }
    }

    /// An idea (or anything) made a project of its own; loose in Unsorted, it goes to the top.
    func makeProject(_ id: String) {
        edit(id) { node in
            node.kind = .project
            node.someday = false
            node.done = false
            node.doneAt = nil
        }
        if place(of: id)?.parent == Self.inbox { move(id, to: nil) }
    }

    // MARK: Capturing

    /// A line from the notch's projects page (an idea, if `idea`), with `shot` if a screenshot was
    /// taken for it, filed into its #project (a new one, if there's none by that name yet), or
    /// Unsorted. Nil if there's nothing to add.
    @discardableResult
    func capture(_ text: String, idea: Bool = false, shot: URL? = nil, now: Date = Date()) -> ProjectNode? {
        let quick = ProjectQuick.parse(text, idea: idea, now: now, weekStart: weekStart)
        guard !quick.title.isEmpty || shot != nil else { return nil }
        let parent = quick.tag.map { tag in project(for: tag) ?? newProject(named: tag).id } ?? Self.inbox
        var node = ProjectNode(kind: quick.title.isEmpty && shot != nil ? .note : quick.kind, title: quick.title)
        node.due = quick.due
        node.time = quick.time
        if let shot {
            guard let kept = keep(shot, for: node.id) else { return nil }
            node.shot = kept
        }
        return add(node, under: parent)
    }

    /// An idea from the ideas page whose #tag is one of your projects': into that project, its
    /// words kept as typed (the tag aside). Nil if no project has that tag.
    func ideaForProject(_ text: String, shot: URL?) -> ProjectNode? {
        let quick = ProjectQuick.parse(text, idea: true)
        guard let tag = quick.tag, let project = project(for: tag), !quick.title.isEmpty || shot != nil else { return nil }
        var node = ProjectNode(kind: .idea, title: quick.title)
        if let shot { node.shot = keep(shot, for: node.id) }
        return add(node, under: project)
    }

    // MARK: Screenshots

    /// `file` moved in as the screenshot for the line `id`: its name, or nil if it couldn't be.
    func keep(_ file: URL, for id: String) -> String? {
        let name = id + "." + (file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased())
        let files = FileManager.default, target = shotsFolder.appendingPathComponent(name)
        do {
            try files.createDirectory(at: shotsFolder, withIntermediateDirectories: true)
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            if file.path.hasPrefix(files.temporaryDirectory.path) || file.lastPathComponent.hasPrefix("Oyl idea ") {
                try files.moveItem(at: file, to: target)
            } else {
                // Dropped in from elsewhere: a copy, the original left where it was.
                try files.copyItem(at: file, to: target)
            }
        } catch {
            return nil
        }
        thumbnails[name] = nil
        return name
    }

    /// Images dropped on a project: each a note under `parent` (named for its file), with it.
    @discardableResult
    func addPictures(_ urls: [URL], under parent: String?) -> [ProjectNode] {
        urls.compactMap { url in
            var node = ProjectNode(kind: .note, title: url.deletingPathExtension().lastPathComponent)
            guard let kept = keep(url, for: node.id) else { return nil }
            node.shot = kept
            return add(node, under: parent)
        }
    }

    func shotURL(_ node: ProjectNode) -> URL? {
        node.shot.map { shotsFolder.appendingPathComponent($0) }
    }

    func thumbnail(_ node: ProjectNode) -> NSImage? {
        guard let name = node.shot else { return nil }
        if let made = thumbnails[name] { return made }
        guard let made = IdeaPictures.thumbnail(of: shotsFolder.appendingPathComponent(name), size: 240) else { return nil }
        thumbnails[name] = made
        return made
    }

    // MARK: Reminders

    /// A task with a time that's come (in the last 12 hours, so a long-gone one doesn't go off
    /// on its own) rings, one at a time.
    func checkReminders(now: Date = Date()) {
        guard ringing == nil else { return }
        var due: (node: ProjectNode, when: Date)?
        func look(_ nodes: [ProjectNode]) {
            nodes.walk { node, path in
                guard node.kind == .task, !node.done, node.time != nil, node.reminded == nil, let when = node.dueDate,
                      when <= now, now.timeIntervalSince(when) < 12 * 3600,
                      !path.contains(where: { $0.done || $0.someday }) else { return }
                if due.map({ when < $0.when }) ?? true { due = (node, when) }
            }
        }
        look(items)
        look(inbox)
        guard let due else { return }
        ringing = due.node
        chime()
    }

    /// The ringing task put off `minutes`.
    func snoozeRinging(minutes: Int, now: Date = Date()) {
        guard let task = ringing else { return }
        let later = ProjectNode.stamp(now.addingTimeInterval(TimeInterval(minutes * 60)))
        ringing = nil
        setDue(task.id, due: later.due, time: later.time)
    }

    /// Seen: it won't ring again (unless its time's changed). The next, if one's waiting.
    func dismissRinging(now: Date = Date()) {
        guard let task = ringing else { return }
        edit(task.id) { $0.reminded = now }
        ringing = nil
        checkReminders(now: now)
    }

    /// The ringing task done.
    func finishRinging(now: Date = Date()) {
        guard let task = ringing else { return }
        edit(task.id) { node in
            node.reminded = now
            node.done = true
            node.doneAt = now
        }
        ringing = nil
        checkReminders(now: now)
    }

    // MARK: Saving

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // As seconds since 2001 (the way Date keeps them), which read back exactly.
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private func saveSoon() {
        saving?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        saving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Saved now, if there's a change waiting.
    func flush() {
        guard let work = saving, !work.isCancelled else { return }
        work.cancel()
        save()
    }

    private func save() {
        saving = nil
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(Saved(items: items, inbox: inbox))
            try data.write(to: file, options: .atomic)
            if problem?.hasPrefix("Oyl couldn't save") == true { problem = nil }
        } catch {
            problem = "Oyl couldn't save your projects: \(error.localizedDescription)"
        }
    }
}
