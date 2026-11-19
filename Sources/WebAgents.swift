import AppKit
import ApplicationServices

/// Agents that work in a browser tab, which (like the Claude app's chats) have no hooks: Meta's
/// Muse, at muse.ai, ChatGPT, Gemini and the rest the radar has (see `AgentRadar`), and any site
/// you've added. Its tab's found by asking the browser which of its tabs are on the site
/// (Chrome and the browsers built like it, and Safari; macOS asks the first time whether Oyl may);
/// and while it's the tab showing in its window, its page is read through Accessibility, as the
/// Claude app's window is (see `ClaudeAppChats`): working while it offers to stop or pause what
/// it's doing, or to let you take over, and what the page says is changing (Muse leaves its Stop
/// up once it's finished, its page still); wanting you while it asks you to approve or confirm
/// something. Every window showing it is read (a chat in one, a side chat in another); one's
/// working only for so long, as answering you takes: offering to stop for longer, it's at a
/// task of its own in the background (Muse keeps them, on a schedule), not answering. In a tab
/// behind others, it's as it was last seen, for as long.
///
/// Kept light: every couple of seconds, on its own queue, one question to each browser that's
/// open; the page is read only while it's showing, a few searches the browser answers itself.
final class WebAgents: @unchecked Sendable {
    struct Site: Equatable, Sendable {
        let host: String
        let name: String
        /// Its Oyl's hat, as "#rrggbb".
        var hat: String?
    }

    struct Agent: Equatable, Sendable {
        let host: String
        let name: String
        let hat: String?
        /// The browser it's in.
        let pid: pid_t
        let browser: String
        let isWorking: Bool
        let needsYou: Bool
    }

    private struct Browser {
        let id: String
        let name: String
        /// Safari's tab's `current tab`; the rest, Chrome's `active tab`.
        let safari: Bool
    }

    static func isBrowser(_ bundleID: String) -> Bool { browsers.contains { $0.id == bundleID } }

    /// The address of the tab showing in the browser's front window, if it'll say.
    static func frontTab(of bundleID: String) -> String? {
        guard let browser = browsers.first(where: { $0.id == bundleID }) else { return nil }
        let source = """
            tell application id "\(browser.id)"
                if (count of windows) is 0 then return ""
                return URL of \(browser.safari ? "current tab" : "active tab") of front window
            end tell
            """
        var error: NSDictionary?
        let address = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        return error == nil ? address : nil
    }

    private static let browsers = [
        Browser(id: "com.google.Chrome", name: "Chrome", safari: false),
        Browser(id: "com.apple.Safari", name: "Safari", safari: true),
        Browser(id: "company.thebrowser.Browser", name: "Arc", safari: false),
        Browser(id: "com.microsoft.edgemac", name: "Edge", safari: false),
        Browser(id: "com.brave.Browser", name: "Brave", safari: false),
    ]

    private static let working = ["Stop", "Pause", "Take over", "Take control"]
    private static let asking = ["Approve", "Confirm", "Allow"]
    /// Working longer than this on one page, it's at something of its own in the background.
    static let answering: TimeInterval = 5 * 60
    /// Offering to stop with nothing on the page changing for this long, it's done.
    static let quiet: TimeInterval = 60

    private let queue = DispatchQueue(label: "oyl.WebAgents", qos: .utility)
    private let report: @Sendable ([Agent]) -> Void
    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var sites: [Site] = []
    private var scripts: [String: NSAppleScript] = [:]
    /// Browsers that wouldn't let Oyl ask, and when, so they're asked again only now and then.
    private var refused: [String: Date] = [:]
    /// Each agent as last seen, by browser and site.
    private var seen: [String: Agent] = [:]
    /// Since when each of its pages (by address) has been working, and which are asking.
    private var workingSince: [String: Date] = [:]
    private var askingPages: Set<String> = []
    /// What each page working said (see `signature`), and when that last changed.
    private var said: [String: (signature: Int, changed: Date)] = [:]
    private var last: [Agent] = []

    /// `report` gets the agents whenever they change, on `queue`.
    init(report: @escaping @Sendable ([Agent]) -> Void) {
        self.report = report
    }

    /// The sites to look for.
    func watch(_ sites: [Site]) {
        queue.async { [weak self] in self?.sites = sites }
    }

    /// Looks while access is allowed (and there's a site to look for); stops, with none, once it
    /// isn't.
    func follow(allowed: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let allowed = allowed && !self.sites.isEmpty
            guard allowed != (self.timer != nil) else { return }
            self.timer?.cancel()
            self.timer = nil
            guard allowed else {
                self.seen = [:]
                self.publish([])
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 2, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Brings its tab forward, in its browser.
    static func show(_ host: String, in browser: String) {
        guard let info = browsers.first(where: { $0.name == browser }) else { return }
        let select = info.safari ? "set current tab of w to t" : "set active tab index of w to i"
        let source = """
            tell application id "\(info.id)"
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        if URL of t contains "\(host)" then
                            \(select)
                            set index of w to 1
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    private func check() {
        var found: [String: Agent] = [:]
        // Each tab's address read the once a look, not again for every site and every pass.
        var hosts: [String: String?] = [:]
        func on(_ site: Site, _ address: String) -> Bool {
            let host: String?
            if let known = hosts[address] { host = known } else { host = Self.host(of: address); hosts[address] = .some(host) }
            return Self.isOn(site, host: host)
        }
        for browser in Self.browsers {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.id).first,
                  Date().timeIntervalSince(refused[browser.id] ?? .distantPast) > 60,
                  let windows = tabs(in: browser) else { continue }
            for site in sites {
                let showing = windows.filter { on(site, $0.showing) }
                guard !showing.isEmpty || windows.contains(where: { $0.all.contains { on(site, $0) } }) else { continue }
                let key = "\(browser.id) \(site.host)"
                if !showing.isEmpty {
                    for page in read(site, in: app.processIdentifier, titled: showing.map(\.title)) {
                        let address = Self.page(page.address)
                        var working = page.working
                        if let signature = page.signature {
                            if said[address]?.signature != signature { said[address] = (signature, Date()) }
                            working = Date().timeIntervalSince(said[address]?.changed ?? Date()) < Self.quiet
                        } else {
                            said[address] = nil
                        }
                        if working {
                            if workingSince[address] == nil { workingSince[address] = Date() }
                        } else {
                            workingSince[address] = nil
                        }
                        if page.asking { askingPages.insert(address) } else { askingPages.remove(address) }
                    }
                }
                // Pages no longer open anywhere are forgotten.
                let pages = Set(windows.flatMap(\.all).filter { on(site, $0) }.map(Self.page))
                workingSince = workingSince.filter { pages.contains($0.key) }
                said = said.filter { pages.contains($0.key) }
                askingPages = askingPages.filter { pages.contains($0) }
                let working = pages.contains { workingSince[$0].map { Date().timeIntervalSince($0) < Self.answering } ?? false }
                found[key] = Agent(host: site.host, name: site.name, hat: site.hat, pid: app.processIdentifier, browser: browser.name,
                                   isWorking: working, needsYou: pages.contains { askingPages.contains($0) })
            }
        }
        seen = found
        publish(found.values.sorted { ($0.browser, $0.host) < ($1.browser, $1.host) })
    }

    private func publish(_ agents: [Agent]) {
        guard agents != last else { return }
        last = agents
        report(agents)
    }

    /// Each of the browser's windows: its title, the tab showing in it, and all its tabs; nil if
    /// it won't say.
    private func tabs(in browser: Browser) -> [(title: String, showing: String, all: [String])]? {
        let showing = browser.safari ? "current tab" : "active tab"
        let source = """
            if application id "\(browser.id)" is running then
                tell application id "\(browser.id)"
                    set found to {}
                    repeat with w in windows
                        try
                            set end of found to {name of w, URL of \(showing) of w, URL of tabs of w}
                        end try
                    end repeat
                    return found
                end tell
            end if
            return {}
            """
        guard let script = scripts[browser.id] ?? NSAppleScript(source: source) else { return nil }
        scripts[browser.id] = script
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil {
            // Not allowed to ask it (or it's busy): not for a while.
            refused[browser.id] = Date()
            return nil
        }
        var windows: [(title: String, showing: String, all: [String])] = []
        for index in stride(from: 1, through: result.numberOfItems, by: 1) {
            guard let window = result.atIndex(index), window.numberOfItems >= 3 else { continue }
            let all = window.atIndex(3).map { list in
                stride(from: 1, through: list.numberOfItems, by: 1).compactMap { list.atIndex($0)?.stringValue }
            } ?? []
            windows.append((window.atIndex(1)?.stringValue ?? "", window.atIndex(2)?.stringValue ?? "", all))
        }
        return windows
    }

    /// A page's address as both the browser's scripting and its accessibility say it: no
    /// fragment, no trailing slash.
    static func page(_ address: String) -> String {
        var page = address.split(separator: "#", maxSplits: 1).first.map(String.init) ?? address
        while page.hasSuffix("/") { page.removeLast() }
        return page
    }

    private static func isOn(_ site: Site, _ address: String) -> Bool {
        isOn(site, host: host(of: address))
    }

    private static func host(of address: String) -> String? { URL(string: address)?.host?.lowercased() }

    private static func isOn(_ site: Site, host: String?) -> Bool {
        guard let host else { return false }
        return host == site.host || host.hasSuffix("." + site.host)
    }

    /// The site's page in each of the browser's windows (`titled`) showing it: its address,
    /// whether it offers to stop (and if so, what it says, in short), and whether it's asking.
    private func read(_ site: Site, in pid: pid_t, titled titles: [String])
        -> [(address: String, working: Bool, signature: Int?, asking: Bool)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var pages: [(address: String, working: Bool, signature: Int?, asking: Bool)] = []
        for window in ButtonReader.windows(of: app) {
            let title = Self.text(window, kAXTitleAttribute) ?? ""
            guard titles.contains(where: { !$0.isEmpty && title.hasPrefix($0) }) else { continue }
            var budget = 600
            guard let area = ButtonReader.find(in: window, budget: &budget, where: { element, role in
                role == "AXWebArea" && Self.isOn(site, Self.address(of: element))
            }) else { continue }
            let working = Self.working.contains { !Self.buttons(in: area, matching: $0).isEmpty }
            let asking = Self.asking.contains { !Self.buttons(in: area, matching: $0).isEmpty }
            pages.append((Self.address(of: area), working, working ? Self.signature(of: area) : nil, asking))
        }
        return pages
    }

    // MARK: Accessibility

    /// What the page says, in short: its text, hashed, read from its end (where the newest is) for
    /// as far as a budget goes, so a long chat costs no more than a short one.
    private static func signature(of area: AXUIElement) -> Int {
        var hasher = Hasher(), budget = 800
        func walk(_ element: AXUIElement) {
            guard budget > 0 else { return }
            budget -= 1
            let (role, children) = ButtonReader.roleAndChildren(element)
            if role == kAXStaticTextRole { hasher.combine(text(element, kAXValueAttribute)) }
            for child in children.reversed() where budget > 0 { walk(child) }
        }
        walk(area)
        return hasher.finalize()
    }

    private static func address(of area: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(area, "AXURL" as CFString, &value) == .success, let value else { return "" }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! URL).absoluteString }
        return value as? String ?? ""
    }

    /// Buttons whose label has `text` in it, as the browser finds them itself. (Muse's Stop is
    /// by its message box while it works, and gone once it's done.)
    private static func buttons(in area: AXUIElement, matching text: String) -> [AXUIElement] {
        let predicate: [String: Any] = ["AXSearchKey": "AXButtonSearchKey", "AXSearchText": text, "AXResultsLimit": 8,
                                        "AXDirection": "AXDirectionNext"]
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(area, "AXUIElementsForSearchPredicate" as CFString,
                                                         predicate as CFDictionary, &result) == .success else { return [] }
        return ((result as? [AXUIElement]) ?? []).filter { label(of: $0).localizedCaseInsensitiveContains(text) }
    }

    private static func label(of element: AXUIElement) -> String {
        [text(element, kAXDescriptionAttribute), text(element, kAXTitleAttribute)]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    private static func text(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
