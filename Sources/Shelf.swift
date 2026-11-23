import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The shelf, in Oyl's Dock: the latest screenshots and screen recordings as they're taken,
/// whatever's just been saved or downloaded, what Claude Code's just written or edited, and files
/// dropped on it or made by converting, all in one row, newest first, each there to be dragged out
/// into another app (or turned into another format first; see `Converter`). Each of the three can
/// be turned off.
///
/// Screenshots are the files in the folder screenshots go to (the Desktop, unless it's been
/// changed) that macOS has marked as screen captures, so nothing else there shows up as one. What's
/// been saved is what's newest in Downloads, where what comes by AirDrop goes, and downloads from a
/// browser, and attachments saved out of Messages (and what's been saved since into the folders in
/// it, two deep, as an app exports into a folder of its own there); what's come from elsewhere onto
/// the Desktop (an attachment dragged out of Messages, say); and what's been saved into Photos from
/// Messages and the like (see `SavedPhotos`). Not what's still downloading. Claude's are what its
/// hooks say it's written or edited (see `ClaudeFiles`). Watching starts the first time the shelf's
/// opened, since reading these asks permission, and from launch after that.
@MainActor
final class Shelf: ObservableObject {
    struct Item: Identifiable, Equatable {
        enum Kind: String, CaseIterable {
            /// Saved into a folder it watches, or (`photo`) into Photos, and copied out of there;
            /// or (`claude`) written or edited by Claude Code.
            case screenshot, recording, saved, photo, claude, dropped, converted
        }

        /// Where one came from, as its color on the shelf says.
        enum Origin: CaseIterable {
            case download, claude, screenshot
        }

        let url: URL
        let kind: Kind
        let date: Date
        var id: URL { url }

        var isCapture: Bool { kind == .screenshot || kind == .recording }
        /// Found where it watches, rather than put there.
        var isWatched: Bool { isCapture || kind == .saved || kind == .photo || kind == .claude }

        /// Nothing, for what was dropped on it or made there.
        var origin: Origin? {
            switch kind {
            case .screenshot, .recording: return .screenshot
            case .saved, .photo: return .download
            case .claude: return .claude
            case .dropped, .converted: return nil
            }
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    /// Items being converted, and what into.
    @Published private(set) var converting: [URL: FileFormat] = [:]
    /// What went wrong converting an item, said on it for a few seconds.
    @Published private(set) var failures: [URL: String] = [:]
    /// The file just made, picked out for a moment.
    @Published private(set) var fresh: URL?
    /// Picked out (clicked, shift-clicked through, ⌘-clicked), to drag out or act on together.
    @Published private(set) var selection: Set<URL> = []
    /// Where a shift-click picks out through from: the last one clicked.
    private var anchor: URL?
    /// The folders it watches that it couldn't read: permission to them was turned down.
    @Published private(set) var blocked: [URL] = []
    /// What each screenshot and recording shows, in a few words (see `ScreenshotLabeler`), by
    /// path: empty for one there was nothing to go by in. Kept across launches, so each is only
    /// looked at once.
    @Published private(set) var labels: [String: String]

    /// The most of each of screenshots and what's been saved, and of Claude's.
    nonisolated static let shownWatched = 12
    nonisolated static let shownClaude = 8
    nonisolated static let keptMost = 12
    /// Still downloading, under these: Safari's, Chrome's (and the like), Firefox's, Opera's.
    nonisolated private static let unfinished: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]

    /// A folder it watches, and what counts there.
    struct Watched: Equatable {
        let folder: URL
        /// Screenshots and recordings.
        var captures = false
        /// What's been saved there (and, `onlyReceived`, only what came from elsewhere).
        var saved = false
        var onlyReceived = false
        /// How far into the folders in it what's saved there is looked for.
        var depth = 0
    }

    private var folders: [Watched] = []
    private var watchers: [DispatchSourceFileSystemObject] = []
    /// For the folders looked into: changes anywhere under them.
    private var deepWatcher: FolderEvents?
    private var photos: SavedPhotos?
    /// What's been saved into Photos, copied out.
    private var fromPhotos: [Item] = []
    private var scanning: DispatchWorkItem?
    /// And again a little after.
    private var rescanning: DispatchWorkItem?
    /// What's in the folders it watches.
    private var watched: [Item] = []
    private var kept: [Item]
    /// What's been taken off the shelf from there (it stays where it is), the latest last, and
    /// when: one saved again since is back.
    private var hidden: [String]
    private var hiddenAt: [String: Date]
    private var loading: Set<URL> = []
    /// What each thumbnail was made of: the file as of then, so one saved over is made again.
    private var thumbnailDates: [URL: Date] = [:]
    private var sharing: NSSharingService?
    /// Waiting to be labeled, newest first; one's labeled at a time.
    private var unlabeled: [Item] = []
    private var labeling: URL?
    /// Screenshots and recordings taken since then are renamed to their labels as soon as they
    /// have them, if they've still the names macOS gave them (older ones only when asked).
    private let renamingSince: Date

    init() {
        let defaults = UserDefaults.standard
        Self.merge(defaults)
        let saved = defaults.array(forKey: Self.key("kept")) as? [[String: Any]] ?? []
        kept = saved.compactMap { entry in
            guard let path = entry["path"] as? String, let kind = (entry["kind"] as? String).flatMap(Item.Kind.init) else { return nil }
            return Item(url: URL(fileURLWithPath: path), kind: kind, date: entry["date"] as? Date ?? .distantPast)
        }
        let hidden = defaults.stringArray(forKey: Self.key("hidden")) ?? []
        var hiddenAt = defaults.dictionary(forKey: Self.key("hiddenAt")) as? [String: Date] ?? [:]
        // Taken off before they were dated: as of now, so only what's saved from now on is back.
        let undated = hidden.filter { hiddenAt[$0] == nil }
        if !undated.isEmpty {
            for path in undated { hiddenAt[path] = Date() }
            defaults.set(hiddenAt, forKey: Self.key("hiddenAt"))
        }
        self.hidden = hidden
        self.hiddenAt = hiddenAt
        labels = defaults.dictionary(forKey: Self.key("labels")) as? [String: String] ?? [:]
        if defaults.object(forKey: "shelf.renamingSince") == nil { defaults.set(Date(), forKey: "shelf.renamingSince") }
        renamingSince = defaults.object(forKey: "shelf.renamingSince") as? Date ?? Date()
        ClaudeFiles.shared.changed = { [weak self] in self?.refresh() }
        if defaults.bool(forKey: Self.key("watching")), isOn { watch(asking: false) }
        refresh()
        // Copies of what was sent off, a day or more ago (see `SendOff`).
        DispatchQueue.global(qos: .utility).async { SendOff.sweep() }
    }

    /// Where its settings are kept: the screenshots' shelf's, as they always were.
    nonisolated static func key(_ name: String) -> String { "shelf.\(name)" }

    /// There were two shelves once, the screenshots' and what's been saved's: the second's kept
    /// files, what was taken off it, its labels and whether it was watching are put in with the
    /// first's, once.
    nonisolated static func merge(_ defaults: UserDefaults) {
        let old = { (name: String) in "shelf.saved.\(name)" }
        guard ["kept", "hidden", "labels", "watching"].contains(where: { defaults.object(forKey: old($0)) != nil }) else { return }
        let entries = (defaults.array(forKey: key("kept")) as? [[String: Any]] ?? []) + (defaults.array(forKey: old("kept")) as? [[String: Any]] ?? [])
        var paths = Set<String>()
        let kept = entries.filter { ($0["path"] as? String).map { paths.insert($0).inserted } ?? false }
            .sorted { ($0["date"] as? Date ?? .distantPast) > ($1["date"] as? Date ?? .distantPast) }
        defaults.set(Array(kept.prefix(keptMost)), forKey: key("kept"))
        let hidden = (defaults.stringArray(forKey: key("hidden")) ?? []) + (defaults.stringArray(forKey: old("hidden")) ?? [])
        defaults.set(Array(hidden.suffix(200)), forKey: key("hidden"))
        var labels = defaults.dictionary(forKey: key("labels")) as? [String: String] ?? [:]
        labels.merge(defaults.dictionary(forKey: old("labels")) as? [String: String] ?? [:]) { first, _ in first }
        defaults.set(labels, forKey: key("labels"))
        if defaults.bool(forKey: old("watching")) { defaults.set(true, forKey: key("watching")) }
        ["kept", "hidden", "labels", "watching"].forEach { defaults.removeObject(forKey: old($0)) }
    }

    private func key(_ name: String) -> String { Self.key(name) }

    /// The shelf is in the Dock (it can be turned off).
    var isOn: Bool { Feature.shelf.isOn }

    /// Turned off: its folders (and Photos) aren't watched, till it's back and opened again.
    func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers = []
        deepWatcher?.cancel()
        deepWatcher = nil
        folders = []
        photos?.stop()
        photos = nil
        fromPhotos = []
        scanning?.cancel()
        rescanning?.cancel()
    }

    /// One of what's on it turned on or off: what it watches changes to suit.
    func sourcesChanged() {
        if UserDefaults.standard.bool(forKey: key("watching")), isOn {
            if !Feature.savedShelf.isOn {
                photos?.stop()
                photos = nil
                fromPhotos = []
            }
            watch(asking: false)
        }
        if watchedFolders.isEmpty { watched = [] }
        refresh()
    }

    /// Watches its folders (again, if where screenshots go has changed), and for what's been saved,
    /// Photos too: asking to see it, if it hasn't yet, only once the shelf's opened (`asking`).
    func watch(asking: Bool = true) {
        guard isOn else { return }
        UserDefaults.standard.set(true, forKey: key("watching"))
        if Feature.savedShelf.isOn {
            if photos == nil {
                let photos = SavedPhotos()
                photos.changed = { [weak self] items in
                    self?.fromPhotos = items
                    self?.refresh()
                }
                self.photos = photos
            }
            photos?.start(asking: asking)
        }
        let folders = watchedFolders
        guard folders != self.folders else {
            scan()
            return
        }
        watchers.forEach { $0.cancel() }
        watchers = []
        deepWatcher?.cancel()
        // A folder looked into is told of changes anywhere under it, which watching it alone isn't.
        deepWatcher = FolderEvents(folders.filter { $0.depth > 0 }.map(\.folder)) { [weak self] in
            MainActor.assumeIsolated { self?.scanSoon() }
        }
        self.folders = folders
        for watched in folders where watched.depth == 0 {
            let descriptor = Darwin.open(watched.folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                                    queue: .main)
            watcher.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scanSoon() }
            }
            watcher.setCancelHandler { close(descriptor) }
            watcher.resume()
            watchers.append(watcher)
        }
        scan()
    }

    /// The folders it watches, for what's on: Downloads and the Desktop for what's been saved, and
    /// where screenshots go (the Desktop too, unless that's been changed: then it's looked at once,
    /// for both).
    var watchedFolders: [Watched] {
        Self.folders(screenshots: Feature.screenshotsShelf.isOn ? Self.screenshotFolder() : nil, saved: Feature.savedShelf.isOn,
                     home: FileManager.default.homeDirectoryForCurrentUser)
    }

    nonisolated static func folders(screenshots: URL?, saved: Bool, home: URL) -> [Watched] {
        var folders: [Watched] = []
        if saved {
            folders = [Watched(folder: home.appendingPathComponent("Downloads", isDirectory: true), saved: true, depth: 2),
                       Watched(folder: home.appendingPathComponent("Desktop", isDirectory: true), saved: true, onlyReceived: true)]
        }
        if let screenshots {
            let same = { (url: URL) in url.standardizedFileURL.path == screenshots.standardizedFileURL.path }
            if let index = folders.firstIndex(where: { same($0.folder) }) {
                folders[index].captures = true
            } else {
                folders.append(Watched(folder: screenshots, captures: true))
            }
        }
        return folders
    }

    /// Downloads, for showing in Finder.
    static var downloads: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true) }

    /// Where screenshots are saved: as set in the Screenshot app's options, or the Desktop.
    static func screenshotFolder() -> URL {
        let set = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        if let set, !set.isEmpty {
            let path = (set as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// A screenshot's written, then marked as one a moment later: looked for once things settle,
    /// and again a little after.
    private func scanSoon() {
        scanning?.cancel()
        rescanning?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        let again = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        scanning = work
        rescanning = again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: again)
    }

    private func scan() {
        let folders = folders
        guard !folders.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let keys = Self.fileKeys
            var found: [Item] = []
            var blocked: [URL] = []
            for watched in folders {
                do {
                    let urls = try FileManager.default.contentsOfDirectory(at: watched.folder, includingPropertiesForKeys: Array(keys),
                                                                           options: [.skipsHiddenFiles])
                    found += urls.compactMap { url -> Item? in
                        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                        return Self.item(url, values, in: watched)
                    }
                    if watched.saved, watched.depth > 0 { found += Self.savedInside(urls, depth: watched.depth) }
                } catch {
                    // Only what came onto the Desktop from elsewhere it can do without.
                    if watched.captures || !watched.onlyReceived { blocked.append(watched.folder) }
                }
            }
            found.sort { $0.date > $1.date }
            let captures = found.filter(\.isCapture).prefix(Self.shownWatched * 2)
            let saved = found.filter { !$0.isCapture }.prefix(Self.shownWatched * 2)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.blocked != blocked { self.blocked = blocked }
                    self.watched = Array(captures + saved)
                    self.refresh()
                }
            }
        }
    }

    /// What `item` reads of a file.
    nonisolated static let fileKeys: Set<URLResourceKey> = [.creationDateKey, .addedToDirectoryDateKey, .contentModificationDateKey,
                                                             .isRegularFileKey, .isDirectoryKey]

    /// One of a watched folder's files, if it's one the shelf has there: a screenshot or recording,
    /// or a file or folder that's done downloading (and, `onlyReceived`, came from elsewhere), as
    /// of when it got there or was saved over (see `savedDate`).
    nonisolated static func item(_ url: URL, _ values: URLResourceValues, in watched: Watched) -> Item? {
        if isScreenCapture(url) {
            guard watched.captures, values.isRegularFile == true else { return nil }
            let movie = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
            return Item(url: url, kind: movie ? .recording : .screenshot, date: values.creationDate ?? .distantPast)
        }
        guard watched.saved, values.isRegularFile == true || values.isDirectory == true, !unfinished.contains(url.pathExtension.lowercased()),
              !watched.onlyReceived || isReceived(url) else { return nil }
        return Item(url: url, kind: .saved, date: savedDate(values))
    }

    /// When a file got where it is, or was last saved over, whichever's later: saved over (Replace
    /// in a save panel, or saved again), it keeps when it was made and added, as macOS does for a
    /// safe save, and only its modification date moves on. Not a folder's, which moves on whenever
    /// anything in it does; nor a date still to come (unpacked from an archive made on a clock
    /// that was ahead).
    nonisolated static func savedDate(_ values: URLResourceValues, now: Date = Date()) -> Date {
        let came = values.addedToDirectoryDate ?? values.creationDate ?? .distantPast
        guard values.isRegularFile == true, let modified = values.contentModificationDate, modified <= now else { return came }
        return max(came, modified)
    }

    /// What's been saved into the folders among `entries` (a watched folder's), up to `depth` down:
    /// each file (or folder) added to its folder, or saved over, over a minute (`margin`) after
    /// that folder came there itself, so a folder unzipped or moved in whole shows as itself, not
    /// each file in it.
    /// Only so many are looked through, in case one's huge.
    nonisolated static func savedInside(_ entries: [URL], depth: Int, margin: TimeInterval = 60) -> [Item] {
        let keys = fileKeys.union([.isPackageKey])
        var found: [Item] = []
        var budget = 4000
        let now = Date()
        func added(_ values: URLResourceValues) -> Date { savedDate(values, now: now) }
        func look(in folder: URL, came: Date, level: Int) {
            guard budget > 0, let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                                           options: [.skipsHiddenFiles]) else { return }
            for url in contents {
                budget -= 1
                guard budget > 0 else { return }
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                let since = added(values)
                if since > came.addingTimeInterval(margin) {
                    if let item = item(url, values, in: Watched(folder: folder, saved: true)) { found.append(item) }
                } else if values.isDirectory == true, values.isPackage != true, level < depth {
                    look(in: url, came: since, level: level + 1)
                }
            }
        }
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true, values.isPackage != true else { continue }
            look(in: url, came: added(values), level: 1)
        }
        return found
    }

    /// macOS marks what it captures with an extended attribute; a screenshot renamed is still one.
    nonisolated static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    /// Come from elsewhere: macOS marks what's downloaded (by Messages, AirDrop or a browser) as
    /// it's saved, and a copy dragged out keeps the mark. (What an app that's kept to itself makes
    /// is marked too, but not as downloaded.)
    nonisolated static func isReceived(_ url: URL) -> Bool {
        var mark = [UInt8](repeating: 0, count: 256)
        let length = getxattr(url.path, "com.apple.quarantine", &mark, mark.count, 0, 0)
        guard length > 0, let text = String(bytes: mark.prefix(length), encoding: .utf8),
              let flags = text.split(separator: ";").first.flatMap({ UInt32($0, radix: 16) }) else { return false }
        return flags & 0x1 != 0
    }

    private func refresh() {
        let files = FileManager.default
        let claude = Feature.claudeShelf.isOn
            ? ClaudeFiles.shared.recent.map { Item(url: URL(fileURLWithPath: $0.path), kind: .claude, date: $0.date) }
                .filter { !Self.isHidden($0, hiddenAt) && files.fileExists(atPath: $0.url.path) }
            : []
        let all = Self.shown(claude: claude, watched: watched + fromPhotos, kept: kept.filter { files.fileExists(atPath: $0.url.path) },
                             hidden: hiddenAt)
        if all != items { items = all }
        let urls = Set(all.map(\.url))
        // What's gone from it isn't picked out any more.
        if !selection.isSubset(of: urls) { selection.formIntersection(urls) }
        if let anchor, !urls.contains(anchor) { self.anchor = nil }
        let current = thumbnails.filter { urls.contains($0.key) }
        if current.count != thumbnails.count { thumbnails = current }
        thumbnailDates = thumbnailDates.filter { urls.contains($0.key) }
        for item in all where thumbnails[item.url] == nil || thumbnailDates[item.url] != item.date { makeThumbnail(for: item) }
        unlabeled = all.filter { $0.isCapture && labels[$0.url.path] == nil && $0.url != labeling }
        labelNext()
    }

    /// What's on it, newest first: the latest few of each of screenshots, what's been saved and
    /// Claude's (not those taken off it, by path and when, unless they've been saved again since),
    /// and what's kept there; each once, as Claude's if it made it (in Downloads, say).
    nonisolated static func shown(claude: [Item], watched: [Item], kept: [Item], hidden: [String: Date]) -> [Item] {
        func latest(_ items: [Item], _ most: Int) -> [Item] {
            Array(items.filter { !isHidden($0, hidden) }.sorted { $0.date > $1.date }.prefix(most))
        }
        var seen = Set<String>()
        let all = latest(claude, shownClaude) + latest(watched.filter(\.isCapture), shownWatched)
            + latest(watched.filter { !$0.isCapture }, shownWatched) + kept
        return all.filter { seen.insert($0.url.standardizedFileURL.path).inserted }.sorted { $0.date > $1.date }
    }

    /// Taken off, and not saved again since.
    nonisolated static func isHidden(_ item: Item, _ hidden: [String: Date]) -> Bool {
        hidden[item.url.path].map { item.date <= $0 } ?? false
    }

    /// The label for an item, once there is one.
    func label(for item: Item) -> String? {
        labels[item.url.path].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Off the main thread, in the background, one at a time.
    private func labelNext() {
        guard labeling == nil, Feature.labelScreenshots.isOn, let item = unlabeled.first else { return }
        unlabeled.removeFirst()
        let url = item.url, movie = item.kind == .recording
        labeling = url
        Task { @MainActor [weak self] in
            let label = await Task.detached(priority: .utility) { await ScreenshotLabeler.label(for: url, movie: movie) }.value
            guard let self else { return }
            self.labeling = nil
            self.labels[url.path] = label ?? ""
            self.saveLabels()
            if label != nil, item.date >= self.renamingSince, Self.hasMacOSName(url), FileManager.default.fileExists(atPath: url.path) {
                self.renameToLabel(item)
            }
            self.labelNext()
        }
    }

    /// Only those still about, or that might be again (taken off the shelf), and not too many.
    private func saveLabels() {
        let files = FileManager.default
        if labels.count > 200 { labels = labels.filter { files.fileExists(atPath: $0.key) } }
        UserDefaults.standard.set(labels, forKey: key("labels"))
    }

    private func makeThumbnail(for item: Item) {
        let url = item.url, date = item.date
        guard !loading.contains(url) else { return }
        loading.insert(url)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 170, height: 112), scale: 2,
                                                   representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.loading.remove(url)
                    guard self.items.contains(where: { $0.url == url }) else { return }
                    self.thumbnails[url] = image ?? NSWorkspace.shared.icon(forFile: url.path)
                    self.thumbnailDates[url] = date
                }
            }
        }
    }

    // MARK: Picking out

    /// How a click picks one out: it alone; it and everything from the last clicked to it (shift);
    /// or it as well, or not any more (⌘).
    enum Picking {
        case only, through, toggle
    }

    func pick(_ item: Item, _ how: Picking) {
        (selection, anchor) = Self.picking(item.url, how, selection: selection, anchor: anchor, in: items.map(\.url))
    }

    /// What's picked out once `url` is clicked (`how`), and where a shift-click goes from next:
    /// shift-clicked, the far end stays where it was, for another; ⌘-clicked out, it stays where
    /// it was too (the last picked out).
    nonisolated static func picking(_ url: URL, _ how: Picking, selection: Set<URL>, anchor: URL?,
                                    in order: [URL]) -> (Set<URL>, URL?) {
        switch how {
        case .only:
            return ([url], url)
        case .through:
            return (through(from: anchor ?? url, to: url, in: order), anchor ?? url)
        case .toggle:
            return selection.contains(url) ? (selection.subtracting([url]), anchor) : (selection.union([url]), url)
        }
    }

    func clearSelection() {
        if !selection.isEmpty { selection = [] }
        anchor = nil
    }

    /// From `from` to `to` along `order`, both ends in it; just `to` if `from`'s not there.
    nonisolated static func through(from: URL, to: URL, in order: [URL]) -> Set<URL> {
        guard let start = order.firstIndex(of: from), let end = order.firstIndex(of: to) else { return [to] }
        return Set(order[min(start, end)...max(start, end)])
    }

    /// What something done to `item` is done to: everything picked out, if it's one of them, in
    /// the order they're on the shelf; or just it.
    func acting(on item: Item) -> [Item] { Self.acting(on: item, selection: selection, in: items) }

    nonisolated static func acting(on item: Item, selection: Set<URL>, in items: [Item]) -> [Item] {
        guard selection.contains(item.url), selection.count > 1 else { return [item] }
        return items.filter { selection.contains($0.url) }
    }

    /// Some at once, as each is alone.
    func remove(_ items: [Item]) { items.forEach(remove) }
    func trash(_ items: [Item]) { items.forEach(trash) }
    func convert(_ items: [Item], to format: FileFormat) { items.forEach { convert($0, to: format) } }
    func open(_ items: [Item]) { items.forEach(open) }

    /// The formats every one of `items` converts to.
    nonisolated static func formats(for items: [Item]) -> [FileFormat] {
        guard let first = items.first else { return [] }
        let shared = items.dropFirst().reduce(Set(Converter.formats(for: first.url))) { $0.intersection(Converter.formats(for: $1.url)) }
        return Converter.formats(for: first.url).filter(shared.contains)
    }

    // MARK: Keeping and taking off

    /// Files dropped on the shelf (or just made), newest first; the oldest go once there are too many.
    func keep(_ urls: [URL], as kind: Item.Kind = .dropped) {
        let showing = Set(items.map(\.url))
        for url in urls.map(\.standardizedFileURL) where kind == .converted || !showing.contains(url) {
            kept.removeAll { $0.url == url }
            kept.insert(Item(url: url, kind: kind, date: Date()), at: 0)
        }
        kept = Array(kept.prefix(Self.keptMost))
        saveKept()
        refresh()
    }

    /// Off the shelf. The file itself stays where it is.
    func remove(_ item: Item) {
        if item.isWatched {
            hidden.removeAll { $0 == item.url.path }
            hidden.append(item.url.path)
            hidden = Array(hidden.suffix(200))
            hiddenAt[item.url.path] = Date()
            let still = Set(hidden)
            hiddenAt = hiddenAt.filter { still.contains($0.key) }
            UserDefaults.standard.set(hidden, forKey: key("hidden"))
            UserDefaults.standard.set(hiddenAt, forKey: key("hiddenAt"))
        }
        kept.removeAll { $0.url == item.url }
        saveKept()
        refresh()
    }

    /// Into the Trash, and so off the shelf.
    func trash(_ item: Item) {
        // A copy out of Photos is only taken off: it's in Photos still.
        guard item.kind != .photo else {
            remove(item)
            return
        }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        } catch {
            fail(item.url, "Couldn't move it to the Trash")
            return
        }
        watched.removeAll { $0.url == item.url }
        remove(item)
    }

    // MARK: Sending off

    /// ⌘-dragged out (see `SendOff`): what's dragged, copies of them set aside, and what's done
    /// once it's let go. If it landed somewhere, the originals go into the Trash (one out of
    /// Photos is only taken off the shelf, as its Trash button does). If it landed nowhere, the
    /// copies go and everything's as it was. One that can't be set aside goes out as an ordinary
    /// drag and stays, and says so.
    func sendOff(_ items: [Item]) -> ShelfDrag.Outgoing {
        DispatchQueue.global(qos: .utility).async { SendOff.sweep() }
        var files: [(url: URL, image: NSImage?)] = [], going: [Item] = [], copies: [URL] = []
        for item in items {
            let image = thumbnails[item.url]
            // Oyl's own copy out of Photos: it isn't deleted, so it goes as it is.
            if item.kind == .photo {
                files.append((item.url, image))
                going.append(item)
                continue
            }
            guard let copy = SendOff.setAside(item.url) else {
                fail(item.url, "Couldn't set it aside to send off, so it's kept")
                files.append((item.url, image))
                continue
            }
            files.append((copy, image))
            going.append(item)
            copies.append(copy)
        }
        return ShelfDrag.Outgoing(files: files) { [weak self] landed in
            guard landed else {
                copies.forEach { SendOff.discard($0) }
                return
            }
            self?.trash(going)
            if !copies.isEmpty { SendOff.chime() }
            // And the copies go a day on, even if nothing more is sent off before then.
            DispatchQueue.global(qos: .utility).asyncAfter(wallDeadline: .now() + SendOff.kept + 60) { SendOff.sweep() }
        }
    }

    private func saveKept() {
        let entries: [[String: Any]] = kept.map { ["path": $0.url.path, "kind": $0.kind.rawValue, "date": $0.date] }
        UserDefaults.standard.set(entries, forKey: key("kept"))
    }

    // MARK: Converting

    /// Converts in the background; what it makes goes on the shelf, first, picked out for a moment.
    func convert(_ item: Item, to format: FileFormat) {
        guard converting[item.url] == nil else { return }
        converting[item.url] = format
        failures[item.url] = nil
        Task { @MainActor in
            do {
                let made = try await Converter.convert(item.url, to: format)
                converting[item.url] = nil
                keep([made], as: .converted)
                let shown = made.standardizedFileURL
                fresh = shown
                try? await Task.sleep(for: .seconds(3))
                if fresh == shown { fresh = nil }
            } catch {
                converting[item.url] = nil
                fail(item.url, (error as? LocalizedError)?.errorDescription ?? "Couldn't convert it")
            }
        }
    }

    private func fail(_ url: URL, _ reason: String) {
        failures[url] = reason
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                if self?.failures[url] == reason { self?.failures[url] = nil }
            }
        }
    }

    // MARK: Using

    func open(_ item: Item) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: Item) { reveal([item]) }

    /// In the Finder, picked out there too (not a copy out of Photos, which is Oyl's own).
    func reveal(_ items: [Item]) {
        let urls = items.filter { $0.kind != .photo }.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func airDrop(_ item: Item) { airDrop([item]) }

    /// To someone nearby: macOS's own AirDrop window comes up to pick who to.
    func airDrop(_ items: [Item]) {
        let urls = items.map(\.url)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return }
        // Held while its window's up.
        sharing = service
        // Oyl's never in front, and the window would come up behind whatever is.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    /// Still called what macOS called it: "Screenshot 2026-11-01 at 10.23.45 PM", say, or by the
    /// name screenshots have been set to have.
    private static func hasMacOSName(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        let custom = CFPreferencesCopyAppValue("name" as CFString, "com.apple.screencapture" as CFString) as? String
        return (["Screenshot", "Screen Shot", "Screen Recording"] + [custom].compactMap { $0 }).contains { name.hasPrefix($0 + " ") }
    }

    /// The file renamed to its label (and a number, if that's taken), where it is.
    func renameToLabel(_ item: Item) {
        guard let label = label(for: item) else { return }
        let name = label.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -").trimmingCharacters(in: .whitespaces)
        let folder = item.url.deletingLastPathComponent(), type = item.url.pathExtension
        func named(_ number: Int) -> URL {
            folder.appendingPathComponent(number == 1 ? name : "\(name) \(number)").appendingPathExtension(type)
        }
        var number = 1
        while FileManager.default.fileExists(atPath: named(number).path) { number += 1 }
        let renamed = named(number)
        do {
            try FileManager.default.moveItem(at: item.url, to: renamed)
        } catch {
            fail(item.url, "Couldn't rename it")
            return
        }
        // It's the same screenshot, still marked as one: everything about it goes with it.
        let moved = Item(url: renamed, kind: item.kind, date: item.date)
        labels[renamed.path] = labels.removeValue(forKey: item.url.path)
        thumbnails[renamed] = thumbnails.removeValue(forKey: item.url)
        thumbnailDates[renamed] = thumbnailDates.removeValue(forKey: item.url)
        watched = watched.map { $0.url == item.url ? moved : $0 }
        kept = kept.map { $0.url == item.url ? moved : $0 }
        saveLabels()
        saveKept()
        refresh()
    }

    func copy(_ item: Item) { copy([item]) }

    /// The files, to paste into a chat or a folder; one picture's pixels too, for apps that only
    /// take those.
    func copy(_ items: [Item]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let entries = items.map { item in
            let entry = NSPasteboardItem()
            entry.setString(item.url.absoluteString, forType: .fileURL)
            return entry
        }
        if items.count == 1, let item = items.first, Converter.kind(of: item.url) == .image,
           let image = NSImage(contentsOf: item.url), let tiff = image.tiffRepresentation {
            entries[0].setData(tiff, forType: .tiff)
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { entries[0].setData(png, forType: .png) }
        }
        pasteboard.writeObjects(entries)
    }
}

/// Drags out of the shelf, as the files themselves. The Dock listens in, to get out of the way
/// of wherever they're going (see `DockController`).
@MainActor
final class ShelfDrag: NSObject, NSDraggingSource {
    static let shared = ShelfDrag()

    /// Where the pointer's got to, in screen coordinates.
    var moved: (NSPoint) -> Void = { _ in }
    /// Where it was let go.
    var ended: (NSPoint) -> Void = { _ in }
    /// Whether a point on the screen is on the shelf's own card, where nothing it drags lands.
    var isOnShelf: (NSPoint) -> Bool = { _ in false }
    private(set) var isDragging = false
    /// For a drag that sends what's dragged off (see `SendOff`): what's done once it's let go,
    /// told whether it landed anywhere.
    private var after: (@MainActor (Bool) -> Void)?

    /// What a drag out takes: the files, each with its picture, and, if it's sending them off,
    /// what's done once it's let go.
    struct Outgoing {
        var files: [(url: URL, image: NSImage?)]
        var after: (@MainActor (Bool) -> Void)?
    }

    /// The drag about to begin sends what it takes off, `after` done once it's let go.
    func sendingOff(_ after: (@MainActor (Bool) -> Void)?) { self.after = after }

    /// The drag's over: whatever it was sending off is seen to, once.
    func finish(landed: Bool) {
        let after = self.after
        self.after = nil
        after?(landed)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Into Oyl's own Dock too: onto an app there.
        context == .outsideApplication ? [.copy, .generic] : .copy
    }

    /// ⌘ is how a drag that sends things off began, and it's likely held still. Held at the drop,
    /// it would otherwise narrow what the drag can do to a "generic" drop, which some apps
    /// (Oyl's own Dock among them) won't take.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { after != nil }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        isDragging = true
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        moved(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        ended(screenPoint)
        finish(landed: operation != [] && !isOnShelf(screenPoint))
    }
}

/// Changes anywhere under some folders, as FSEvents tells of them (a file saved into a folder in
/// one, which watching the folder itself doesn't hear), a moment's worth at a time, on the main
/// queue.
final class FolderEvents {
    private var stream: FSEventStreamRef?
    private let changed: () -> Void

    init?(_ folders: [URL], changed: @escaping () -> Void) {
        self.changed = changed
        guard !folders.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                                           copyDescription: nil)
        let told: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderEvents>.fromOpaque(info).takeUnretainedValue().changed()
        }
        guard let stream = FSEventStreamCreate(nil, told, &context, folders.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func cancel() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { cancel() }
}
