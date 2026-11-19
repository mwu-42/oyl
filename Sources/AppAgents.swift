import AppKit
import ApplicationServices

/// Agents in apps of their own, with no hooks: the ChatGPT app, Codex, Perplexity, and any app
/// you've added (see `AgentRadar`). As in the Claude app (see `ClaudeAppChats`) and a browser tab
/// (see `WebAgents`), their windows are read through Accessibility: nearly every one of them
/// offers to stop while it works, and asks you to approve, confirm or allow what it wants to do.
///
/// Kept light: only apps that are open, every couple of seconds, on its own queue; each window's
/// asked to find its buttons itself where it can (a web view can, in one call), and otherwise
/// walked only now and then, and only so far.
final class AppAgents: @unchecked Sendable {
    struct App: Equatable, Sendable {
        let bundleID: String
        let name: String
        var hat: String?
    }

    struct Agent: Equatable, Sendable {
        let bundleID: String
        let name: String
        let hat: String?
        let pid: pid_t
        /// Its front window's title, for what it's working on.
        let title: String
        let isWorking: Bool
        let needsYou: Bool
    }

    private let queue = DispatchQueue(label: "oyl.AppAgents", qos: .utility)
    private let report: @Sendable ([Agent]) -> Void
    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var apps: [App] = []
    private var readers: [pid_t: ButtonReader] = [:]
    private var last: [Agent] = []

    /// `report` gets the agents whenever they change, on `queue`.
    init(report: @escaping @Sendable ([Agent]) -> Void) {
        self.report = report
    }

    /// The apps to look for, while access is allowed.
    func follow(_ apps: [App], allowed: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.apps = allowed ? apps : []
            let looking = !self.apps.isEmpty
            guard looking != (self.timer != nil) else { return }
            self.timer?.cancel()
            self.timer = nil
            guard looking else {
                self.readers = [:]
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

    private func check() {
        var found: [Agent] = []
        var open: Set<pid_t> = []
        for app in apps {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first else { continue }
            let pid = running.processIdentifier
            open.insert(pid)
            let reader = readers[pid] ?? ButtonReader(pid: pid, electron: Self.isElectron(running))
            readers[pid] = reader
            let windows = reader.windows()
            var working = false, asking = false
            for window in windows {
                working = working || reader.has(in: window, any: ButtonReader.working)
                asking = asking || reader.has(in: window, any: ButtonReader.asking)
            }
            let title = windows.first.flatMap { ButtonReader.text($0, kAXTitleAttribute) } ?? ""
            found.append(Agent(bundleID: app.bundleID, name: app.name, hat: app.hat, pid: pid, title: title,
                               isWorking: working, needsYou: asking))
        }
        readers = readers.filter { open.contains($0.key) }
        publish(found)
    }

    private func publish(_ agents: [Agent]) {
        guard agents != last else { return }
        last = agents
        report(agents)
    }

    /// Built on Electron, which only builds the tree of its web content once asked to.
    private static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }
}

/// Finds an app's buttons by what they say, through Accessibility: asking a web view to search
/// for them itself (Chromium and WebKit answer in one call), and in a window that can't, walking
/// it, every few seconds at most and only so far. Every call gives up after a quarter second.
final class ButtonReader {
    /// Offered while an agent works, in any app or page.
    static let working = ["Stop", "Pause", "Take over", "Take control"]
    /// Asked while it wants you.
    static let asking = ["Approve", "Confirm", "Allow"]

    private let app: AXUIElement
    private var searches = true
    private var walked: [String: (at: Date, labels: [String])] = [:]

    init(pid: pid_t, electron: Bool) {
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if electron { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
    }

    func windows() -> [AXUIElement] { Self.windows(of: app) }

    /// An app's windows: those on this Space, which is all Accessibility lists, and its main and
    /// focused ones wherever they are (another app's fullscreen Space, say), which it still gives.
    static func windows(of app: AXUIElement) -> [AXUIElement] {
        var windows = elements(app, kAXWindowsAttribute)
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success, let value,
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let window = value as! AXUIElement
            if !windows.contains(where: { CFEqual($0, window) }) { windows.append(window) }
        }
        return windows
    }

    /// Whether the window has a button that says any of `labels`, as a word of its own ("Stop",
    /// "Stop generating", but not "Nonstop").
    func has(in window: AXUIElement, any labels: [String]) -> Bool {
        if searches {
            let area = webArea(in: window) ?? window
            var supported = false
            for label in labels {
                guard let found = search(area, label) else { continue }
                supported = true
                if found.contains(where: { Self.says(Self.label(of: $0), label) }) { return true }
            }
            if supported { return false }
            searches = false
        }
        let key = Self.text(window, kAXTitleAttribute) ?? ""
        if Date().timeIntervalSince(walked[key]?.at ?? .distantPast) > 4 {
            var labels: [String] = []
            var budget = 2500
            _ = Self.find(in: window, budget: &budget) { element, role in
                if role == kAXButtonRole as String { labels.append(Self.label(of: element)) }
                return false
            }
            walked[key] = (Date(), labels)
        }
        return walked[key]?.labels.contains { found in labels.contains { Self.says(found, $0) } } ?? false
    }

    /// Buttons matching `text`, as the window finds them; nil if it can't search.
    private func search(_ element: AXUIElement, _ text: String) -> [AXUIElement]? {
        let predicate: [String: Any] = ["AXSearchKey": "AXButtonSearchKey", "AXSearchText": text, "AXResultsLimit": 8,
                                        "AXDirection": "AXDirectionNext"]
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXUIElementsForSearchPredicate" as CFString,
                                                         predicate as CFDictionary, &result) == .success else { return nil }
        return (result as? [AXUIElement]) ?? []
    }

    private func webArea(in window: AXUIElement) -> AXUIElement? {
        var budget = 400
        return Self.find(in: window, budget: &budget) { _, role in role == "AXWebArea" }
    }

    /// `label` says `word` as a word (or words) of its own, any case.
    static func says(_ label: String, _ word: String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter }.map(String.init)
        let wanted = word.lowercased().split(separator: " ").map(String.init)
        guard !wanted.isEmpty, words.count >= wanted.count else { return false }
        return (0...(words.count - wanted.count)).contains { Array(words[$0..<$0 + wanted.count]) == wanted }
    }

    static func label(of element: AXUIElement) -> String {
        [text(element, kAXDescriptionAttribute), text(element, kAXTitleAttribute), text(element, kAXHelpAttribute)]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    /// Depth first, visiting at most `budget` elements, each told with its role (asked for with
    /// its children, in the one round trip to the app).
    static func find(in element: AXUIElement, budget: inout Int, where matches: (AXUIElement, String?) -> Bool) -> AXUIElement? {
        guard budget > 0 else { return nil }
        budget -= 1
        let (role, children) = roleAndChildren(element)
        if matches(element, role) { return element }
        for child in children {
            if let found = find(in: child, budget: &budget, where: matches) { return found }
            if budget <= 0 { return nil }
        }
        return nil
    }

    private static let roleAndChildrenNames = [kAXRoleAttribute, kAXChildrenAttribute] as CFArray

    /// An element's role and its children, asked of its app together: each a round trip (most of
    /// what walking an app's windows costs, on both sides), and a walk asks both of every element.
    /// If the app won't answer the two at once, they're asked one at a time, as they always were.
    static func roleAndChildren(_ element: AXUIElement) -> (role: String?, children: [AXUIElement]) {
        var values: CFArray?
        let asked = AXUIElementCopyMultipleAttributeValues(element, roleAndChildrenNames, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        if asked == .success, let both = values as? [AnyObject], both.count == 2 {
            // (One it hasn't comes back as an error in its place: no role, no children.)
            return (both[0] as? String, both[1] as? [AXUIElement] ?? [])
        }
        // Gone: it has neither, however it's asked.
        if asked == .invalidUIElement { return (nil, []) }
        return (text(element, kAXRoleAttribute), elements(element, kAXChildrenAttribute))
    }

    static func text(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
