import AppKit
import ApplicationServices

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
    /// Apps asking for you (see `AppAttention`), by id, the first to ask first: looked for while
    /// `watchAttention` has it.
    @Published private(set) var asking: [String] = []
    private var attentionTimer: Timer?
    /// The apps in the bar that are open, by process, and the one in front, as of the last launch,
    /// quit or switch: so looking for who's asking reads only theirs, never asking macOS about
    /// every process each time (in a running app, that's a round trip to LaunchServices for each).
    private var openApps: [(pid: pid_t, id: String)] = []
    private var frontID: String?

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
        let unique = Self.unique(folders)
        if unique != others { others = unique }
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
        // However many of an app are open (another instance of it, say), it's one icon: lit if any
        // is in front, dimmed only if they're all hidden.
        var shown = kept.map { item -> Item in
            var item = item
            let open = running.filter { Self.matches($0, item) }
            item.isRunning = !open.isEmpty
            item.isActive = front.map(open.contains) ?? false
            item.isHidden = !open.isEmpty && open.allSatisfy(\.isHidden)
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
            guard !shown.contains(where: { $0.id == id }) else { continue }
            if let icon = app.icon { icons[id] = icon }
            let open = extra.filter { ($0.bundleIdentifier ?? $0.bundleURL?.path) == id }
            shown.append(Item(id: id, url: url, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                              kind: .app, isRunning: true, isActive: front.map(open.contains) ?? false,
                              isHidden: open.allSatisfy(\.isHidden)))
        }
        // Each icon's its own (SwiftUI lays them out by id): one kept in the Dock twice is shown once.
        shown = Self.arranged(Self.unique(shown), by: order)
        if shown != apps { apps = shown }
        let id = { (app: NSRunningApplication) in shown.first { Self.matches(app, $0) }?.id }
        openApps = running.compactMap { app in id(app).map { (app.processIdentifier, $0) } }
        frontID = front.flatMap(id)
        if !asking.isEmpty { checkAttention() }
        liftGlyphs()
        let up = Set(shown.filter(\.isRunning).map(\.id))
        if !launching.isDisjoint(with: up) { launching.subtract(up) }
    }

    private func liftGlyphs() {
        for item in apps + others where !lifted.contains(item.id) {
            lifted.insert(item.id)
            let bundle = item.kind == .app ? Bundle(url: item.url)?.bundleIdentifier : nil
            // Some drawn rather than lifted: Finder's a magnifying glass, a folder a folder, Chrome
            // Google's G, Outlook its icon's open envelope, outlined, and an app with no icon of its own a star
            // with its first letter in it.
            let drawn: DockGlyph?? = switch (item.kind, bundle) {
            case (.folder, _): DockGlyphs.symbol("folder")
            case (_, Self.finder): DockGlyphs.symbol("magnifyingglass")
            case (_, "com.google.Chrome"): DockGlyphs.googleG()
            case (_, "com.microsoft.Outlook"): DockGlyphs.envelope()
            case (.app, _) where !Self.hasOwnIcon(item.url): DockGlyphs.starLetter(item.name)
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

    /// Apps asking for you looked for (`on`) twice a second, so none is missed (one asking for the
    /// Dock's one bounce does for about a second); or not, and none are.
    func watchAttention(_ on: Bool) {
        guard on != (attentionTimer != nil) else { return }
        attentionTimer?.invalidate()
        attentionTimer = nil
        guard on, AppAttention.canTell else {
            if !asking.isEmpty { asking = [] }
            return
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAttention() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        attentionTimer = timer
        checkAttention()
    }

    /// Who's asking, of the apps in the bar: one stays till it's gone to or quits.
    private func checkAttention() {
        guard attentionTimer != nil else { return }
        let now = openApps.filter { AppAttention.asks($0.pid) }.map(\.id)
        let asking = AppAttention.asking(before: asking, now: now, open: Set(openApps.map(\.id)), front: frontID)
        if asking != self.asking { self.asking = asking }
    }

    /// Whether the app at `url` has an icon of its own (else macOS shows the plain one apps get):
    /// the icon file its bundle names, or the asset catalog it names one in.
    nonisolated static func hasOwnIcon(_ url: URL) -> Bool {
        guard let bundle = Bundle(url: url), let resources = bundle.resourceURL else { return true }
        let files = FileManager.default
        if let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, !file.isEmpty {
            let named = resources.appendingPathComponent(file)
            if files.fileExists(atPath: named.path) || files.fileExists(atPath: named.appendingPathExtension("icns").path) { return true }
        }
        if bundle.object(forInfoDictionaryKey: "CFBundleIconName") != nil,
           files.fileExists(atPath: resources.appendingPathComponent("Assets.car").path) { return true }
        return false
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

    /// The first of them, if there's more than one.
    private func running(_ item: Item) -> NSRunningApplication? { instances(of: item).first }

    /// Every one of it that's open's process.
    func processes(of item: Item) -> Set<pid_t> { Set(instances(of: item).map(\.processIdentifier)) }

    /// Every one of it that's open.
    private func instances(of item: Item) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { Self.matches($0, item) }
    }

    private static func matches(_ app: NSRunningApplication, _ item: Item) -> Bool {
        app.bundleIdentifier == item.id || app.bundleURL?.standardizedFileURL == item.url.standardizedFileURL
    }

    /// Each item once, the first of any with the same id.
    nonisolated static func unique(_ items: [Item]) -> [Item] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Hidden (all of it that's open) or shown again.
    func hide(_ item: Item) {
        let open = instances(of: item)
        let hidden = !open.isEmpty && open.allSatisfy(\.isHidden)
        for app in open { _ = hidden ? app.unhide() : app.hide() }
    }

    /// Every one of it that's open, quit.
    func quit(_ item: Item) {
        for app in instances(of: item) { _ = app.terminate() }
    }

    /// Whether it can be quit from here: an app that's open, but not Finder, which macOS keeps open.
    func canQuit(_ item: Item) -> Bool { item.kind == .app && item.isRunning && item.id != Self.finder }

    /// Another window of an open app (a ⌘-click), as its own New Window makes one (see
    /// `NewWindow`), brought forward with it; for an app without, a new instance of it. One that
    /// isn't open, or a folder, is just opened.
    func openAnother(_ item: Item) {
        guard item.kind == .app, item.isRunning, let app = running(item) else { return open(item) }
        let pid = app.processIdentifier, url = item.url
        // Asking its menus can take a moment.
        DispatchQueue.global(qos: .userInitiated).async {
            let made = NewWindow.make(in: pid)
            DispatchQueue.main.async {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = !made
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
            }
        }
    }
}

/// A new window of an app, as its own menus make one: the first New Window in them (New Finder
/// Window, say, but never a private or incognito one, or a tab), along the menu bar past the
/// Apple menu, pressed through Accessibility.
enum NewWindow {
    /// What a menu item that makes one says.
    static func makes(_ title: String) -> Bool {
        let title = title.lowercased()
        return title.hasPrefix("new ") && title.split(separator: " ").contains("window")
            && !["private", "incognito", "tab"].contains(where: title.contains)
    }

    /// Makes one in app `pid`: false if it has no such item (or Oyl isn't allowed in Accessibility).
    static func make(in pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        for title in ButtonReader.elements(bar as! AXUIElement, kAXChildrenAttribute).dropFirst() {
            guard let menu = ButtonReader.elements(title, kAXChildrenAttribute).first, let item = item(in: menu) else { continue }
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
        return false
    }

    /// The menu's item that makes one, if it has one; one that opens a menu of its own (Terminal's
    /// New Window, of its profiles), that menu's first.
    private static func item(in menu: AXUIElement) -> AXUIElement? {
        guard let item = ButtonReader.elements(menu, kAXChildrenAttribute).first(where: {
            makes(ButtonReader.text($0, kAXTitleAttribute) ?? "") && isEnabled($0)
        }) else { return nil }
        guard let submenu = ButtonReader.elements(item, kAXChildrenAttribute).first else { return item }
        return ButtonReader.elements(submenu, kAXChildrenAttribute).first {
            !(ButtonReader.text($0, kAXTitleAttribute) ?? "").isEmpty && isEnabled($0)
        }
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success else { return true }
        return (value as? Bool) ?? true
    }
}
