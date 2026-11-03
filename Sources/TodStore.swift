import CryptoKit
import Foundation
import SwiftUI

/// tod's lists and tasks, shared with tod (the owner's own to-do app): a task added from the
/// notch is in tod too, and one checked off in tod is done here. It works on tod's own
/// `data/state.json` and keeps every field it doesn't use (tod's layout, settings, subtasks…) just
/// as it found it. Each change is made on the latest copy of the file, then saved through tod's
/// server when that's running (so tod's backup, and its check for saves it hasn't seen, apply) or
/// straight to the file, keeping tod's backup rule, when it isn't. Edits made in tod show up here
/// within a moment.
@MainActor
final class TodStore: ObservableObject {
    /// One of tod's lists (a box on its canvas), or its brain dump.
    struct List: Identifiable, Equatable {
        let id: String
        let name: String
        let color: Color
        let isDump: Bool
        /// Its first lane (the brain dump's "Unsorted" folder), where new tasks go.
        let firstColumn: String
    }

    struct Task: Identifiable, Equatable {
        let id: String
        var listId: String
        var title: String
        var notes: String
        var due: String?          // "YYYY-MM-DD"
        var time: String?         // "HH:MM"
        /// A day to have it done by, roughly ("YYYY-MM-DD"): not a deadline, which `due` is, but
        /// an aim, which can slip. Oyl's own (tod keeps it, though it doesn't show it).
        var target: String?
        /// When it was last looked over and kept, if it has been (Oyl's own too).
        var kept: Date?
        var done: Bool
        var doneAt: Date?
        let createdAt: Date
        var order: Double         // its place in its lane, lowest first
        /// How often it comes back once it's done, if it does.
        var repeats: TodRepeat?
        /// Which of its list's lanes it's in, 0 for the first.
        fileprivate(set) var lane: Int

        /// When it's due, as a moment (end of the day if no time), for sorting and "what's next".
        var dueDate: Date? {
            let day = (due ?? "").split(separator: "-").compactMap { Int($0) }
            guard day.count == 3 else { return nil }
            let clock = (time ?? "").split(separator: ":").compactMap { Int($0) }
            let (hour, minute, second) = clock.count == 2 ? (clock[0], clock[1], 0) : (23, 59, 59)
            return Boards.calendar.date(from: DateComponents(year: day[0], month: day[1], day: day[2],
                                                             hour: hour, minute: minute, second: second))
        }
    }

    /// A change Oyl made to a task, once it's saved: no `before` for one it added, no `after` for
    /// one it deleted.
    struct Change {
        let before: Task?
        let after: Task?
    }

    @Published private(set) var lists: [List] = []     // as laid out on tod's canvas, the brain dump last
    @Published private(set) var tasks: [Task] = []     // all of them, done too, by list, lane and order
    @Published private(set) var isAvailable = false    // tod found, and its data read
    /// What's wrong, if tod's data can't be read or a change couldn't be saved.
    @Published private(set) var trouble: String?
    /// Told of each change Oyl makes to a task once it's saved (for the calendar to follow).
    var onChange: ((Change) -> Void)?

    /// tod's first day of the week (0 Sunday, 1 Monday), for reading "next week" and "next fri".
    var weekStart: Int { boards?.weekStart ?? 1 }

    /// How long a task checked off in tod waits before it comes back: tod offers to undo it for
    /// six seconds.
    static let grace: TimeInterval = 10

    private let givenRoot: URL?
    private let givenPort: Int?
    private var disk: Disk?
    private var boards: Boards?       // tod's data as last read or saved, with changes being saved on top
    private var rev = ""              // which save of the file that is
    private var saving = 0            // changes sent to the disk and not yet saved
    private var stuck: String?        // the save a change last failed on: nothing comes back till a newer one
    private var seen: [Int] = []      // the file's signature when it was last read
    private var watcher: DispatchSourceFileSystemObject?
    private var soon: Timer?          // reads the file just after it changes
    private var later: Timer?         // for the next task that comes back
    private var poll: Timer?

    /// `root` is tod's folder. Nil finds it, and tod's server's port, from the tod app
    /// (`TodRoot` and `TodPort` in ~/Applications/tod.app); given a folder, it saves through a
    /// server only if it's given that server's `port`.
    init(root: URL? = nil, port: Int? = nil) {
        givenRoot = root
        givenPort = port
        find()
        // In case the folder's watch misses something (a file written over in place, the folder
        // made again), or tod turns up later.
        poll = Self.timer(after: 3, repeats: true) { [weak self] in self?.check() }
    }

    /// Open tasks, soonest due first (overdue first), then undated by their list and order.
    var open: [Task] {
        let open = tasks.filter { !$0.done }.map { ($0, $0.dueDate ?? .distantFuture) }
        return open.indices.sorted { i, j in
            open[i].1 != open[j].1 ? open[i].1 < open[j].1 : i < j
        }
        .map { open[$0].0 }
    }

    /// The next thing to do: the soonest open dated task due within a day (or overdue), if any.
    var next: Task? { next(at: Date()) }

    func next(at date: Date) -> Task? {
        guard let first = open.first, let due = first.dueDate, due <= date.addingTimeInterval(24 * 3600) else { return nil }
        return first
    }

    func list(_ id: String) -> List? { lists.first { $0.id == id } }

    /// Adds what's been typed: "essay #cs fri 5pm" is "essay", due Friday at 5 PM, in the list
    /// the tag picks ("💻 cs 106b"), or a new list called "cs" if none does; with no tag, the
    /// inbox. Nil if there's nothing to add, or no tod.
    @discardableResult
    func add(_ text: String) -> Task? {
        let parsed = TodQuick.parse(text, weekStart: weekStart)
        let listId = parsed.list.flatMap { TodQuick.list(for: $0, among: lists.map { (id: $0.id, name: $0.name) }) }
        return add(title: parsed.title, due: parsed.due, time: parsed.time, listId: listId, newList: listId == nil ? parsed.list : nil)
    }

    /// Adds a task at the top of its list's first lane: in `listId` if there's such a list, else
    /// in a new list called `newList` (or the one already called that), else the inbox. A time
    /// with no day is today, as in tod. Nil if the title's empty, or there's no tod.
    @discardableResult
    func add(title: String, due: String?, time: String?, listId: String?, newList: String? = nil,
             notes: String = "", repeats: TodRepeat? = nil, target: String? = nil) -> Task? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, boards != nil else { return nil }
        let now = Date(), id = Boards.uid(), ms = Boards.ms(now)
        let due = due ?? (time == nil ? nil : Boards.day(now))
        let made = newList.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { name -> (id: String, name: String)? in name.isEmpty ? nil : (Boards.uid(), name) }
        change {
            $0.add(id, title: title, notes: notes, due: due, time: time, repeats: repeats, list: listId, or: made, at: ms)
            if let target { $0.update(id, Patch(set: ["target": target]), today: Boards.day(now), at: ms) }
        }
        return tasks.first { $0.id == id }
    }

    /// Checks a task off, or back on. A repeating one comes back, due its next time.
    func toggle(_ id: String) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        edit(id) { $0.done = !task.done }
    }

    /// Changes a task to what's been typed for it, read as `add` reads it: its title, day and
    /// time (no day or time if none's typed), and its list if there's a #tag. Tags alone only
    /// move it.
    func edit(_ id: String, to text: String) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        let parsed = TodQuick.parse(text, weekStart: weekStart)
        var changed = task
        if !parsed.title.isEmpty {
            changed.title = parsed.title
            changed.due = parsed.due
            changed.time = parsed.time
        }
        var newList: String?
        if let tag = parsed.list {
            if let listId = TodQuick.list(for: tag, among: lists.map { (id: $0.id, name: $0.name) }) {
                changed.listId = listId
            } else {
                newList = tag
            }
        }
        save(task, as: changed, newList: newList)
    }

    /// Changes a task as `change` says, as in `edit(id) { $0.repeats = .weekly }`. Checking it
    /// off is as `toggle` does it, and a new list puts it at the top of that list's first lane.
    func edit(_ id: String, _ change: (inout Task) -> Void) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        var changed = task
        change(&changed)
        save(task, as: changed)
    }

    func delete(_ id: String) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        change { $0.remove(id) }
    }

    // MARK: - changes

    /// Just what changed, so a field tod changed meanwhile isn't put back.
    private func save(_ task: Task, as changed: Task, newList: String? = nil) {
        var patch = Patch()
        if changed.title != task.title { patch.set["title"] = changed.title }
        if changed.notes != task.notes { patch.set["notes"] = changed.notes }
        if changed.due != task.due { patch.set["due"] = changed.due ?? NSNull() }
        if changed.time != task.time { patch.set["time"] = changed.time ?? NSNull() }
        if changed.target != task.target {
            if let target = changed.target { patch.set["target"] = target } else { patch.removed.append("target") }
        }
        if changed.kept != task.kept {
            if let kept = changed.kept { patch.set["kept"] = Boards.ms(kept) } else { patch.removed.append("kept") }
        }
        if changed.order != task.order { patch.set["order"] = Boards.number(changed.order) }
        if changed.repeats != task.repeats {
            if let repeats = changed.repeats { patch.set["repeat"] = repeats.rawValue } else { patch.removed.append("repeat") }
        }
        if changed.listId != task.listId { patch.list = changed.listId }
        if let newList { patch.newList = (Boards.uid(), newList) }
        if changed.done != task.done { patch.done = changed.done }
        guard !patch.set.isEmpty || !patch.removed.isEmpty || patch.list != nil || patch.newList != nil || patch.done != nil
        else { return }
        let now = Date(), today = Boards.day(now), ms = Boards.ms(now)
        change { $0.update(task.id, patch, today: today, at: ms) }
    }

    /// Makes a change here at once, then again on the latest copy of tod's data as it's saved
    /// (so nothing tod saved meanwhile is lost), and tells `onChange` once it is.
    private func change(_ edit: @escaping (inout Boards) -> Void) {
        guard var boards, let disk else { return }
        edit(&boards)
        self.boards = boards
        show()
        saving += 1
        disk.queue.async { [weak self] in
            let saved = disk.save(edit)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.saved(saved) } }
        }
    }

    private func saved(_ saved: Saved) {
        saving -= 1
        if let trouble = saved.trouble {
            say(trouble)
            stuck = saved.rev
            // Back to what's really there.
            if saving == 0 { rev = ""; reload() }
            return
        }
        say(nil)
        stuck = nil
        if saving == 0, let boards = saved.boards {
            self.boards = boards
            rev = saved.rev
            show()
        }
        for change in saved.changes { onChange?(change) }
        if saving == 0 { bringBack() }
    }

    /// Brings back each repeating task that's done and hasn't come back yet: checked off before
    /// Oyl saw it come back, or in tod (once tod's stopped offering to undo it).
    private func bringBack() {
        later?.invalidate()
        later = nil
        guard let boards, saving == 0, stuck == nil else { return }
        let now = Date()
        var wait: Date?
        for (id, doneAt) in boards.unrepeated {
            let ready = (doneAt ?? .distantPast).addingTimeInterval(Self.grace)
            if ready > now {
                wait = min(wait ?? ready, ready)
                continue
            }
            let next = Boards.uid(), today = Boards.day(now), ms = Boards.ms(now)
            change { $0.repeatNext(after: id, as: next, today: today, at: ms) }
        }
        if let wait {
            later = Self.timer(after: wait.timeIntervalSinceNow) { [weak self] in self?.bringBack() }
        }
    }

    // MARK: - reading

    /// Finds tod's data and reads it.
    private func find() {
        guard let (root, port) = givenRoot.map({ ($0, givenPort) }) ?? Self.installed() else {
            return loaded(.trouble("Can't find tod"))
        }
        let disk = Disk(root: root, port: port)
        self.disk = disk
        watch()
        seen = disk.signature()
        loaded(disk.read())
    }

    /// tod's folder and its server's port, from the tod app.
    private static func installed() -> (URL, Int?)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for apps in [home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")] {
            guard let data = try? Data(contentsOf: apps.appendingPathComponent("tod.app/Contents/Info.plist")),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let root = info["TodRoot"] as? String else { continue }
            let port = (info["TodPort"] as? NSNumber)?.intValue ?? (info["TodPort"] as? String).flatMap { Int($0) } ?? 5280
            return (URL(fileURLWithPath: root, isDirectory: true), port)
        }
        return nil
    }

    private func check() {
        guard let disk else { return find() }
        if watcher == nil { watch() }
        if disk.signature() != seen { reload() }
    }

    /// Watches tod's data folder: each save replaces the file whole, which changes the folder.
    private func watch() {
        guard let disk else { return }
        let folder = Darwin.open(disk.folder.path, O_EVTONLY)
        guard folder >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: [.write, .delete, .rename], queue: .main)
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let watcher = self.watcher else { return }
                // The folder itself went: it's watched again once it's back.
                if !watcher.data.isDisjoint(with: [.delete, .rename]) {
                    watcher.cancel()
                    self.watcher = nil
                }
                // A save is a few changes in a row: read once they've settled.
                self.soon?.invalidate()
                self.soon = Self.timer(after: 0.2) { [weak self] in self?.reload() }
            }
        }
        watcher.setCancelHandler { close(folder) }
        watcher.resume()
        self.watcher = watcher
    }

    private func reload() {
        guard let disk else { return }
        seen = disk.signature()
        disk.queue.async { [weak self] in
            let loaded = disk.read()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.loaded(loaded) } }
        }
    }

    private func loaded(_ loaded: Loaded) {
        // A change on its way to the disk brings newer data when it's saved.
        guard saving == 0 else { return }
        switch loaded {
        case .found(let boards, let rev):
            guard rev != self.rev || self.boards == nil else { return }
            self.boards = boards
            self.rev = rev
            // A change that couldn't be saved is still news until the file moves on.
            if stuck != rev { stuck = nil }
            if stuck == nil { say(nil) }
        case .trouble(let trouble):
            boards = nil
            rev = ""
            say(trouble)
        }
        show()
        bringBack()
    }

    private func show() {
        let lists = boards?.lists ?? []
        let rank = Dictionary(lists.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tasks = (boards?.tasks ?? []).sorted { a, b in
            (rank[a.listId] ?? lists.count, a.lane, a.order, a.createdAt, a.id)
                < (rank[b.listId] ?? lists.count, b.lane, b.order, b.createdAt, b.id)
        }
        if lists != self.lists { self.lists = lists }
        if tasks != self.tasks { self.tasks = tasks }
        if isAvailable != (boards != nil) { isAvailable = boards != nil }
    }

    private func say(_ trouble: String?) {
        if trouble != self.trouble { self.trouble = trouble }
    }

    private static func timer(after seconds: TimeInterval, repeats: Bool = false, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: max(seconds, 0.01), repeats: repeats) { _ in MainActor.assumeIsolated { action() } }
        timer.tolerance = repeats ? 1 : 0.05
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: - tod's data

    /// What to change about a task: fields to set and to take off, a list to move it to (at the
    /// top of that list's first lane), and done or not.
    private struct Patch {
        var set: [String: Any] = [:]
        var removed: [String] = []
        var list: String?
        var newList: (id: String, name: String)?
        var done: Bool?
        /// The id the next of it gets, if it repeats and this checks it off.
        var next = Boards.uid()
    }

    /// tod's saved data, all of it: whatever Oyl doesn't change is carried along as it was read.
    private struct Boards {
        var json: [String: Any]

        init?(_ data: Data) {
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], json["lists"] is [Any]
            else { return nil }
            self.json = json
        }

        /// As JSON: laid out for reading when it's written to the file, compact for tod's server
        /// (which lays it out itself). Keys sorted both ways, so each save keeps the same order
        /// (tod breaks ties in a lane by it).
        func data(laidOut: Bool) -> Data? {
            try? JSONSerialization.data(withJSONObject: json, options: laidOut ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys])
        }

        func isSame(as other: Boards) -> Bool { NSDictionary(dictionary: json).isEqual(to: other.json) }

        var weekStart: Int { ((json["settings"] as? [String: Any])?["weekStart"] as? NSNumber)?.intValue ?? 1 }

        // MARK: reading

        private var listEntries: [[String: Any]] { (json["lists"] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }
        private var taskEntries: [String: [String: Any]] {
            (json["tasks"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
        }

        /// Each list's lanes, by its id (the first list with an id, if two share one, as in tod).
        private var lanes: [String: [(id: String, name: String)]] {
            var lanes: [String: [(id: String, name: String)]] = [:]
            for list in listEntries {
                guard let id = list["id"] as? String, lanes[id] == nil else { continue }
                lanes[id] = (list["columns"] as? [Any] ?? []).compactMap { column in
                    (column as? [String: Any]).flatMap { column in
                        (column["id"] as? String).map { ($0, column["name"] as? String ?? "") }
                    }
                }
            }
            return lanes
        }

        /// Row by row as they're laid out on tod's canvas, then any it hasn't placed yet, and the
        /// brain dump (which isn't on the canvas) last.
        var lists: [List] {
            let layout = json["layout"] as? [String: Any] ?? [:]
            var seen: Set<String> = []
            let placed = listEntries.enumerated().compactMap { index, entry -> (List, [Double])? in
                guard let id = entry["id"] as? String, seen.insert(id).inserted else { return nil }
                let isDump = id == "dump" || entry["kind"] as? String == "dump"
                let spot = layout[id] as? [String: Any]
                let x = (spot?["x"] as? NSNumber)?.doubleValue, y = (spot?["y"] as? NSNumber)?.doubleValue
                let place: [Double] = isDump ? [2, 0, 0] : (x != nil && y != nil ? [0, y!, x!] : [1, 0, 0])
                let color = isDump ? "#8c8c8c" : (Self.hex(entry["color"]) ?? Self.palette[0])
                let first = ((entry["columns"] as? [Any])?.first as? [String: Any])?["id"] as? String ?? ""
                let list = List(id: id, name: entry["name"] as? String ?? "", color: Self.color(color), isDump: isDump, firstColumn: first)
                return (list, place + [Double(index)])
            }
            return placed.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
        }

        var tasks: [Task] {
            let lanes = self.lanes
            return taskEntries.map { Self.task($1, id: $0, lanes: lanes) }
        }

        func task(_ id: String) -> Task? { taskEntries[id].map { Self.task($0, id: id, lanes: lanes) } }

        private static func task(_ entry: [String: Any], id: String, lanes: [String: [(id: String, name: String)]]) -> Task {
            var listId = entry["listId"] as? String ?? "inbox"
            // As tod does with a task whose list is gone.
            if lanes[listId] == nil { listId = "inbox" }
            let lane = (entry["columnId"] as? String).flatMap { column in lanes[listId]?.firstIndex { $0.id == column } } ?? 0
            return Task(id: id, listId: listId, title: entry["title"] as? String ?? "", notes: entry["notes"] as? String ?? "",
                        due: text(entry["due"]), time: text(entry["time"]), target: text(entry["target"]), kept: moment(entry["kept"]),
                        done: entry["done"] as? Bool ?? false,
                        doneAt: moment(entry["doneAt"]), createdAt: moment(entry["createdAt"]) ?? .distantPast,
                        order: (entry["order"] as? NSNumber)?.doubleValue ?? 0,
                        repeats: (entry["repeat"] as? String).flatMap(TodRepeat.init(rawValue:)), lane: lane)
        }

        /// Repeating tasks that are done and haven't come back yet, and when they were done.
        var unrepeated: [(id: String, doneAt: Date?)] {
            taskEntries.compactMap { id, task in
                task["done"] as? Bool == true && task["repeated"] as? Bool != true
                    && (task["repeat"] as? String).flatMap(TodRepeat.init(rawValue:)) != nil ? (id, Self.moment(task["doneAt"])) : nil
            }
        }

        /// The tasks that are different in `after`: changed ones first, then added ones.
        func changes(to after: Boards) -> [Change] {
            let old = taskEntries, new = after.taskEntries
            let changes = Set(old.keys).union(new.keys).sorted().compactMap { id -> Change? in
                if let a = old[id], let b = new[id], NSDictionary(dictionary: a).isEqual(to: b) { return nil }
                let change = Change(before: task(id), after: after.task(id))
                // (Not for a field Oyl doesn't show, like "repeated".)
                return change.before == change.after ? nil : change
            }
            return changes.filter { $0.before != nil } + changes.filter { $0.before == nil }
        }

        // MARK: changing

        mutating func add(_ id: String, title: String, notes: String, due: String?, time: String?, repeats: TodRepeat?,
                          list listId: String?, or newList: (id: String, name: String)?, at ms: Int) {
            guard self[task: id] == nil else { return }
            let list = file(into: listId, or: newList, at: ms) ?? inbox()
            let lane = firstLane(of: list)
            var task: [String: Any] = [
                "id": id, "listId": list, "columnId": lane, "title": title, "notes": notes, "due": due ?? NSNull(),
                "time": time ?? NSNull(), "subtasks": [Any](), "done": false, "doneAt": NSNull(), "createdAt": ms,
                "order": topOrder(in: lane),
            ]
            if let repeats { task["repeat"] = repeats.rawValue }
            self[task: id] = task
        }

        mutating func update(_ id: String, _ patch: Patch, today: String, at ms: Int) {
            guard var task = self[task: id] else { return }
            for (key, value) in patch.set { task[key] = value }
            for key in patch.removed { task[key] = nil }
            if let list = file(into: patch.list, or: patch.newList, at: ms), list != task["listId"] as? String {
                let lane = firstLane(of: list)
                task["listId"] = list
                task["columnId"] = lane
                task["order"] = topOrder(in: lane, except: id)
            }
            self[task: id] = task
            if let done = patch.done {
                setDone(id, done, at: ms)
                if done { repeatNext(after: id, as: patch.next, today: today, at: ms) }
            }
        }

        mutating func remove(_ id: String) {
            self[task: id] = nil
        }

        private mutating func setDone(_ id: String, _ done: Bool, at ms: Int) {
            guard var task = self[task: id], task["done"] as? Bool ?? false != done else { return }
            task["done"] = done
            task["doneAt"] = done ? ms : NSNull()
            self[task: id] = task
        }

        /// Once a repeating task's done, the next of it: due its next time, the same otherwise
        /// (subtasks unticked), at the top of its lane, or of its list's first if it's in a lane
        /// called Done. The done one's marked "repeated" in the same save, so it only ever comes
        /// back once, whichever Oyl (or relaunch of it) sees it first.
        mutating func repeatNext(after id: String, as newId: String, today: String, at ms: Int) {
            guard var task = self[task: id], task["done"] as? Bool == true, task["repeated"] as? Bool != true,
                  let repeats = (task["repeat"] as? String).flatMap(TodRepeat.init(rawValue:)) else { return }
            task["repeated"] = true
            self[task: id] = task
            // Already back: tod put the done one back as it was, before it was marked.
            guard !taskEntries.values.contains(where: { $0["repeatOf"] as? String == id }), self[task: newId] == nil else { return }
            let lanes = self.lanes
            var list = task["listId"] as? String ?? ""
            if lanes[list] == nil { list = inbox() }
            var lane = task["columnId"] as? String ?? ""
            let name = lanes[list]?.first { $0.id == lane }?.name
            if name == nil || name!.trimmingCharacters(in: .whitespaces).lowercased() == "done" { lane = firstLane(of: list) }
            // From when it was due, else (no day, or one that doesn't read) from today.
            let due = Self.text(task["due"])
            var next = repeats.next(after: due ?? today, today: today)
            if next == due { next = repeats.next(after: today, today: today) }
            let subtasks = (task["subtasks"] as? [Any] ?? []).map { item -> Any in
                guard var subtask = item as? [String: Any] else { return item }
                subtask["id"] = Self.uid()
                subtask["done"] = false
                return subtask
            }
            self[task: newId] = [
                "id": newId, "listId": list, "columnId": lane, "title": task["title"] ?? "", "notes": task["notes"] ?? "",
                "due": next, "time": task["time"] ?? NSNull(), "subtasks": subtasks, "done": false, "doneAt": NSNull(),
                "createdAt": ms, "order": topOrder(in: lane), "repeat": repeats.rawValue, "repeatOf": id,
            ]
        }

        private subscript(task id: String) -> [String: Any]? {
            get { (json["tasks"] as? [String: Any])?[id] as? [String: Any] }
            set {
                var tasks = json["tasks"] as? [String: Any] ?? [:]
                tasks[id] = newValue
                json["tasks"] = tasks
            }
        }

        /// The list to file into: `listId` if it's there, else a list called `newList` (made if
        /// there isn't one by that name), else none.
        private mutating func file(into listId: String?, or newList: (id: String, name: String)?, at ms: Int) -> String? {
            if let listId, lanes[listId] != nil { return listId }
            guard let newList else { return nil }
            if let same = listEntries.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(newList.name) == .orderedSame }),
               let id = same["id"] as? String { return id }
            // As tod's createList makes one; tod gives it a spot on the canvas when it loads it.
            let used = Set(listEntries.compactMap { Self.hex($0["color"]) })
            let color = Self.palette.first { !used.contains($0) } ?? Self.palette[listEntries.count % Self.palette.count]
            let columns = ["To do", "In progress", "Done"].map { ["id": Self.uid(), "name": $0] }
            json["lists"] = (json["lists"] as? [Any] ?? []) + [["id": newList.id, "name": newList.name, "color": color,
                                                                  "columns": columns, "createdAt": ms] as [String: Any]]
            if let order = json["order"] as? [Any] { json["order"] = order + [newList.id] }
            return newList.id
        }

        /// The inbox, put back as tod does if it's gone.
        private mutating func inbox() -> String {
            if lanes["inbox"] == nil {
                let inbox: [String: Any] = ["id": "inbox", "name": "Inbox", "color": "#5a5a5a", "columns": [["id": Self.uid(), "name": "Inbox"]]]
                json["lists"] = [inbox] + (json["lists"] as? [Any] ?? [])
            }
            return "inbox"
        }

        /// A list's first lane, made as tod would if it has none.
        private mutating func firstLane(of listId: String) -> String {
            var lists = json["lists"] as? [Any] ?? []
            guard let index = lists.firstIndex(where: { ($0 as? [String: Any])?["id"] as? String == listId }),
                  var list = lists[index] as? [String: Any] else { return "" }
            let columns = list["columns"] as? [Any] ?? []
            if let first = (columns.first as? [String: Any])?["id"] as? String { return first }
            guard columns.isEmpty else { return "" }
            let lane = Self.uid()
            list["columns"] = [["id": lane, "name": "To do"]]
            lists[index] = list
            json["lists"] = lists
            return lane
        }

        /// Above everything in the lane, as tod puts a new task.
        private func topOrder(in lane: String, except id: String? = nil) -> Any {
            let orders = taskEntries.filter { $0.key != id && $0.value["columnId"] as? String == lane }
                .map { ($0.value["order"] as? NSNumber)?.doubleValue ?? 0 }
            return Self.number(orders.isEmpty ? 0 : orders.min()! - 1)
        }

        // MARK: values

        /// tod's palette, for a new list's color.
        static let palette = ["#3b5bdb", "#2f9bd6", "#14958a", "#4c9a6a", "#7a9a2e", "#d19a1c",
                              "#e8772e", "#c8553d", "#d6457a", "#9b4dca", "#6c5ce7", "#5a5a5a"]

        static let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .autoupdatingCurrent
            return calendar
        }()

        /// A new id, made the way tod makes them.
        static func uid() -> String {
            let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
            return String((0..<7).map { _ in digits.randomElement()! }) + String(String(ms(Date()), radix: 36).suffix(3))
        }

        static func ms(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded(.down)) }

        static func day(_ date: Date) -> String {
            let day = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!)
        }

        /// Whole numbers as whole numbers, as tod writes them.
        static func number(_ value: Double) -> Any {
            value == value.rounded() && abs(value) < 1e15 ? Int(value) : value
        }

        private static func text(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        private static func moment(_ value: Any?) -> Date? {
            (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }

        /// "#rrggbb", lowercased, if it is one (as tod's `hexColor`).
        private static func hex(_ value: Any?) -> String? {
            guard let text = (value as? String)?.lowercased(), text.count == 7, text.hasPrefix("#"),
                  text.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
            return text
        }

        private static func color(_ hex: String) -> Color {
            let value = Int(hex.dropFirst(), radix: 16) ?? 0
            return Color(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
        }
    }

    // MARK: - the disk

    private enum Loaded {
        case found(Boards, rev: String)
        case trouble(String)
    }

    /// How a change went: what's saved now and which save of the file that is, or why not
    /// (and which save it was tried on).
    private struct Saved {
        var boards: Boards?
        var rev: String
        var changes: [Change] = []
        var trouble: String?
    }

    /// tod's data file, and tod's server if it's running: read and saved off the main thread,
    /// one thing at a time.
    private final class Disk: Sendable {
        let folder: URL
        let file: URL
        let backup: URL
        let port: Int?
        let queue = DispatchQueue(label: "Oyl.tod", qos: .userInitiated)
        private let session: URLSession

        init(root: URL, port: Int?) {
            folder = root.appendingPathComponent("data", isDirectory: true)
            file = folder.appendingPathComponent("state.json")
            backup = folder.appendingPathComponent("state.backup.json")
            self.port = port
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3
            configuration.connectionProxyDictionary = [:]
            session = URLSession(configuration: configuration)
        }

        /// Changes whenever the file does, whether it's replaced or written over.
        func signature() -> [Int] {
            var info = stat()
            guard stat(file.path, &info) == 0 else { return [] }
            return [Int(truncatingIfNeeded: info.st_ino), Int(info.st_size), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
        }

        func read() -> Loaded {
            guard let raw = try? Data(contentsOf: file) else { return .trouble("Can't find tod's data") }
            guard let boards = Boards(raw) else { return .trouble("tod's data can't be read") }
            return .found(boards, rev: Self.rev(raw))
        }

        /// Makes `edit` on the file as it is now and saves it. Other Oyls wait their turn (a lock
        /// on the folder); a save tod makes meanwhile is caught by its server, and the change is
        /// made again on that, after a moment's wait (a little longer each time, and never quite
        /// the same, so two can't keep colliding).
        func save(_ edit: (inout Boards) -> Void) -> Saved {
            let lock = Darwin.open(folder.path, O_RDONLY)
            guard lock >= 0 else { return Saved(rev: "", trouble: "Can't find tod's data") }
            defer { close(lock) }    // which unlocks it
            flock(lock, LOCK_EX)
            var rev = ""
            // How long to keep asking a server that's there but slow to answer.
            let deadline = Date().addingTimeInterval(15)
            for attempt in 0..<12 {
                if attempt > 0 { Thread.sleep(forTimeInterval: min(0.01 * pow(2, Double(attempt - 1)), 0.25) * .random(in: 0.5...1.5)) }
                guard let raw = try? Data(contentsOf: file) else { return Saved(rev: "", trouble: "Can't find tod's data") }
                rev = Self.rev(raw)
                guard var boards = Boards(raw) else { return Saved(rev: rev, trouble: "tod's data can't be read") }
                let before = boards
                edit(&boards)
                guard !boards.isSame(as: before) else { return Saved(boards: boards, rev: rev) }
                switch boards.data(laidOut: false).map({ send($0, base: rev) }) ?? .failed("Couldn't save to tod") {
                case .saved(let saved):
                    return Saved(boards: boards, rev: saved, changes: before.changes(to: boards))
                case .conflict:
                    continue
                case .unanswered:
                    // It may be in the middle of a save of tod's that would land on top of a
                    // write here, or still make this one: ask it again rather than write the file.
                    if Date() < deadline { continue }
                    return Saved(rev: rev, trouble: "Couldn't save to tod: its server isn't answering")
                case .failed(let trouble):
                    return Saved(rev: rev, trouble: trouble)
                case .noServer:
                    // Only on the file the change was made on: it may have moved on while the
                    // server was asked.
                    guard (try? Data(contentsOf: file)) == raw else { continue }
                    guard let body = boards.data(laidOut: true) else { return Saved(rev: rev, trouble: "Couldn't save to tod") }
                    do {
                        try write(body, replacing: raw)
                    } catch {
                        return Saved(rev: rev, trouble: "Couldn't save to tod: \(error.localizedDescription)")
                    }
                    return Saved(boards: boards, rev: Self.rev(body), changes: before.changes(to: boards))
                }
            }
            return Saved(rev: rev, trouble: "Couldn't save to tod: it kept changing")
        }

        private enum Sent {
            case saved(rev: String)
            case conflict
            case noServer
            case unanswered      // there, but no answer (slow, stopped, or gone mid-save)
            case failed(String)
        }

        /// The server's answer, filled in before `done` is signalled and read after.
        private final class Reply: @unchecked Sendable {
            var data: Data?
            var response: HTTPURLResponse?
            var error: Error?
        }

        /// Through tod's server, if it's running: it keeps tod's backup, and refuses the save if
        /// the file's moved on from `base`.
        private func send(_ body: Data, base: String) -> Sent {
            guard let port, let url = URL(string: "http://localhost:\(port)/api/state") else { return .noServer }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.httpBody = body
            request.setValue("1", forHTTPHeaderField: "X-tod")
            request.setValue(base, forHTTPHeaderField: "X-tod-base")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let reply = Reply()
            let done = DispatchSemaphore(value: 0)
            session.dataTask(with: request) { data, response, error in
                reply.data = data
                reply.response = response as? HTTPURLResponse
                reply.error = error
                done.signal()
            }
            .resume()
            done.wait()
            guard let response = reply.response else {
                // Nothing listening: tod's not running.
                let refused: [URLError.Code] = [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
                return (reply.error as? URLError).map { refused.contains($0.code) } == true ? .noServer : .unanswered
            }
            // Something that isn't tod.
            guard response.value(forHTTPHeaderField: "Server")?.hasPrefix("tod/") == true else { return .noServer }
            switch response.statusCode {
            case 200:
                return .saved(rev: response.value(forHTTPHeaderField: "X-tod-rev") ?? Self.rev(body))
            case 409:
                return .conflict
            default:
                let answer = reply.data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                return .failed("Couldn't save to tod: " + (answer?["error"] as? String ?? "its server answered \(response.statusCode)"))
            }
        }

        /// Straight to the file, replaced whole as tod's server does it, keeping tod's backup:
        /// the file as it was, at most every ten minutes.
        private func write(_ body: Data, replacing old: Data) throws {
            let backedUp = (try? FileManager.default.attributesOfItem(atPath: backup.path))?[.modificationDate] as? Date
            if backedUp.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                try old.write(to: backup, options: .atomic)
            }
            try body.write(to: file, options: .atomic)
        }

        /// tod's name for a save of the file: the start of its SHA-256.
        static func rev(_ data: Data) -> String {
            SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        }
    }
}
