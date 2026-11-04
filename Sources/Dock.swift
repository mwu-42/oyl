import AppKit

/// What Oyl's Dock shows: what the macOS Dock does (Finder, the apps kept in it, any other apps
/// that are open, its folders) but the Trash, read from the Dock's own settings so the two match,
/// at the Dock's own icon size.
@MainActor
final class DockApps: ObservableObject {
    struct Item: Identifiable, Equatable {
        enum Kind {
            case app, folder
        }

        /// The app's bundle identifier, or the path.
        let id: String
        let url: URL
        let name: String
        let kind: Kind
        var isRunning = false
        var isActive = false
        var isHidden = false
    }

    /// First, always, as in the macOS Dock.
    static let finder = "com.apple.finder"

    /// Finder, then the apps kept in the Dock, then other apps that are open.
    @Published private(set) var apps: [Item] = []
    /// Folders kept in the Dock.
    @Published private(set) var others: [Item] = []
    /// How big the Dock's icons are set to be.
    @Published private(set) var tile: CGFloat = 48
    /// Apps opened from here, hopping until they're up.
    @Published private(set) var launching: Set<String> = []
    /// Each app's glyph, for Oyl's own look for its icon (see `DockGlyphs`): Finder's a magnifying
    /// glass, a folder's a folder, the rest lifted off their icons, each once, off the main thread.
    /// None for one with no one glyph on it: it keeps its icon.
    @Published private(set) var glyphs: [String: DockGlyph] = [:]
    private var lifted: Set<String> = []

    private var kept: [Item] = []
    /// The apps as they've been dragged along Oyl's Dock (the macOS Dock keeps its own order):
    /// their ids, in order, those last shown first.
    private var order = UserDefaults.standard.stringArray(forKey: "dock.order") ?? []
    private var icons: [String: NSImage] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        reload()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            })
        }
    }

    /// Reads the Dock's settings again (for what's been kept in it or taken out since).
    func reload() {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        let size = CFPreferencesCopyAppValue("tilesize" as CFString, domain) as? Double ?? 48
        tile = CGFloat(min(max(size, 32), 80))
        let finder = Item(id: Self.finder, url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                          name: "Finder", kind: .app)
        kept = [finder] + Self.tiles(CFPreferencesCopyAppValue("persistent-apps" as CFString, domain)).filter { $0.kind == .app }
        let folders = Self.tiles(CFPreferencesCopyAppValue("persistent-others" as CFString, domain)).filter { $0.kind == .folder }
        if folders != others { others = folders }
        updateRunning()
    }

    /// The Dock's tiles as it stores them: a file tile for each app or folder (spacers and web
    /// links left out).
    private static func tiles(_ value: Any?) -> [Item] {
        (value as? [[String: Any]] ?? []).compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String,
                  let url = URL(string: string) ?? Optional(URL(fileURLWithPath: string)), url.isFileURL else { return nil }
            let type = tile["tile-type"] as? String
            let name = data["file-label"] as? String ?? url.deletingPathExtension().lastPathComponent
            if type == "directory-tile" { return Item(id: url.path, url: url, name: name, kind: .folder) }
            guard type == "file-tile", url.pathExtension == "app" else { return nil }
            return Item(id: data["bundle-identifier"] as? String ?? url.path, url: url, name: name, kind: .app)
        }
    }

    private func updateRunning() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let front = NSWorkspace.shared.frontmostApplication
        func find(_ item: Item) -> NSRunningApplication? {
            running.first { $0.bundleIdentifier == item.id || $0.bundleURL?.standardizedFileURL == item.url.standardizedFileURL }
        }
        var shown = kept.map { item -> Item in
            var item = item
            let app = find(item)
            item.isRunning = app != nil
            item.isActive = app != nil && app == front
            item.isHidden = app?.isHidden ?? false
            return item
        }
        let keptIDs = Set(kept.map(\.id)), keptURLs = Set(kept.map { $0.url.standardizedFileURL })
        let extra = running
            .filter { app in
                guard let url = app.bundleURL else { return false }
                return !keptIDs.contains(app.bundleIdentifier ?? "") && !keptURLs.contains(url.standardizedFileURL)
            }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        for app in extra {
            guard let url = app.bundleURL else { continue }
            let id = app.bundleIdentifier ?? url.path
            if let icon = app.icon { icons[id] = icon }
            shown.append(Item(id: id, url: url, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                              kind: .app, isRunning: true, isActive: app == front, isHidden: app.isHidden))
        }
        shown = Self.arranged(shown, by: order)
        if shown != apps { apps = shown }
        liftGlyphs()
        let up = Set(shown.filter(\.isRunning).map(\.id))
        if !launching.isDisjoint(with: up) { launching.subtract(up) }
    }

    private func liftGlyphs() {
        for item in apps + others where !lifted.contains(item.id) {
            lifted.insert(item.id)
            let bundle = item.kind == .app ? Bundle(url: item.url)?.bundleIdentifier : nil
            // Some drawn rather than lifted: Finder's a magnifying glass, a folder a folder, and
            // Chrome Google's G.
            let drawn: DockGlyph?? = switch (item.kind, bundle) {
            case (.folder, _): DockGlyphs.symbol("folder")
            case (_, Self.finder): DockGlyphs.symbol("magnifyingglass")
            case (_, "com.google.Chrome"): DockGlyphs.googleG()
            default: nil
            }
            if let drawn {
                if let drawn { glyphs[item.id] = drawn }
                continue
            }
            // Big enough for a letter on it to be lifted twice as fine.
            var rect = CGRect(x: 0, y: 0, width: DockGlyph.side * 2, height: DockGlyph.side * 2)
            guard let image = icon(for: item).cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
            // Canva's its C: the first letter of the name on its icon. Activity Monitor's its pulse,
            // without the grid behind it.
            let id = item.id, firstLetter = bundle == "com.canva.canvaeditor", brightest = bundle == "com.apple.ActivityMonitor"
            Task { @MainActor [weak self] in
                let glyph = await Task.detached(priority: .userInitiated) {
                    firstLetter ? DockGlyphs.liftFirstLetter(image) ?? DockGlyphs.lift(image)
                        : brightest ? DockGlyphs.liftBrightest(image) ?? DockGlyphs.lift(image) : DockGlyphs.lift(image)
                }.value
                if let glyph { self?.glyphs[id] = glyph }
            }
        }
    }

    /// In the order they've been dragged into: those that have been, in the places they take up
    /// between them, in that order; any others (just kept in the Dock, say) where the Dock has them.
    static func arranged(_ shown: [Item], by order: [String]) -> [Item] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let slots = shown.indices.filter { rank[shown[$0].id] != nil }
        let moved = slots.map { shown[$0] }.sorted { rank[$0.id, default: 0] < rank[$1.id, default: 0] }
        var arranged = shown
        for (slot, item) in zip(slots, moved) { arranged[slot] = item }
        return arranged
    }

    /// Moves an app to `index` among them, and remembers it there (and the rest where they are).
    func move(_ id: String, to index: Int) {
        var ids = apps.map(\.id)
        guard let from = ids.firstIndex(of: id) else { return }
        ids.insert(ids.remove(at: from), at: min(max(index, 0), ids.count))
        // Those not out now (open apps since quit) kept after them, for when they're back.
        order = ids + order.filter { !ids.contains($0) }
        UserDefaults.standard.set(order, forKey: "dock.order")
        updateRunning()
    }

    func icon(for item: Item) -> NSImage {
        if let icon = icons[item.id] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icons[item.id] = icon
        return icon
    }

    // MARK: Doing

    /// Opens (or switches to) an app, the way the Dock does: one that's open with no windows
    /// gets a new one. A folder opens in Finder.
    func open(_ item: Item) {
        guard item.kind == .app else {
            NSWorkspace.shared.open(item.url)
            return
        }
        if !item.isRunning {
            launching.insert(item.id)
            // In case it never says it's up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                MainActor.assumeIsolated { _ = self?.launching.remove(item.id) }
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: configuration) { _, _ in }
    }

    /// Files dropped on an app open in it.
    func drop(_ urls: [URL], on item: Item) -> Bool {
        guard item.kind == .app else { return false }
        if !item.isRunning { launching.insert(item.id) }
        NSWorkspace.shared.open(urls, withApplicationAt: item.url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        return true
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func running(_ item: Item) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == item.id || $0.bundleURL?.standardizedFileURL == item.url.standardizedFileURL
        }
    }

    func hide(_ item: Item) {
        guard let app = running(item) else { return }
        _ = app.isHidden ? app.unhide() : app.hide()
    }

    func quit(_ item: Item) {
        _ = running(item)?.terminate()
    }
}
