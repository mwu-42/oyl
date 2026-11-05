import AppKit
import ApplicationServices
import os

/// Chats (and Cowork) in the Claude desktop app, which unlike Claude Code have no hooks. This reads
/// the app's window through Accessibility, which you allow once: while Claude writes a reply the
/// window has a "Stop" button, and while it waits for your OK, Allow and Deny buttons, which this
/// can press for you. A task waiting on you that isn't the one showing says so in the sidebar
/// ("Awaiting …", "Needs …" by its name), which is always there: it's opened to be answered.
///
/// Kept light: it runs only while the app is open and access is allowed, checks once a second
/// on its own queue, asks the app to find the button itself (one call; walking the window
/// would be thousands), and gives up on any call after a quarter second, so a stalled Claude
/// can't hold anything up.
final class ClaudeAppChats: @unchecked Sendable {
    static let bundleID = "com.anthropic.claudefordesktop"

    struct Chat: Equatable, Sendable {
        let pid: pid_t
        let title: String
        let isWriting: Bool
        let needsApproval: Bool
        /// Tasks in the sidebar waiting on you, other than the one whose prompt is showing.
        var waiting: [Waiting] = []
    }

    /// A task in the app's sidebar that says it's waiting on you: its name, and what it says.
    struct Waiting: Equatable, Sendable {
        let name: String
        let status: String
    }

    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    /// Shows macOS's prompt, which leads to Privacy & Security › Accessibility.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private let queue = DispatchQueue(label: "oyl.ClaudeApp", qos: .utility)
    private let report: @Sendable (Chat?) -> Void
    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var app: AXUIElement?
    private var pid: pid_t = 0
    /// Each window's web content, found every so often (see `webAreas`).
    private var webAreas: [(window: AXUIElement, areas: [AXUIElement], at: Date)] = []
    private var searchWorks = true
    private var lastWalk = Date.distantPast
    private var walked: [(element: AXUIElement, label: String)] = []
    /// What approval-like buttons were last seen that weren't a prompt's pair, so each is logged once.
    private var unpaired: [String] = []
    private var last: Chat?
    private var approvalButtons: (allow: AXUIElement, deny: AXUIElement)?
    /// The sidebar's entries for the tasks waiting on you, by name, to open.
    private var entries: [String: AXUIElement] = [:]
    /// Each status a waiting task's been seen with, logged once.
    private var statuses: Set<String> = []

    /// `report` gets the app's state whenever it changes, nil once the app quits; on `queue`.
    init(report: @escaping @Sendable (Chat?) -> Void) {
        self.report = report
    }

    /// Checks while the app (`pid`) is open and access is allowed; stops otherwise.
    func follow(_ pid: pid_t?, allowed: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let target = allowed ? pid : nil
            guard target != (self.timer == nil ? nil : self.pid) else { return }
            self.timer?.cancel()
            self.timer = nil
            self.app = nil
            self.webAreas = []
            guard let target else {
                if self.last != nil {
                    self.last = nil
                    self.report(nil)
                }
                return
            }
            self.pid = target
            let app = AXUIElementCreateApplication(target)
            AXUIElementSetMessagingTimeout(app, 0.25)
            // Electron apps only build the tree of their web content once asked to.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            self.app = app
            self.searchWorks = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(300))
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Presses the app's own Allow (or Deny) for the request it's showing; for a `task` waiting in
    /// the sidebar, opens it first and presses them once its prompt's up, or if none comes (a task
    /// wanting something else of you), leaves it open, `unanswered`.
    func respond(allow: Bool, task: String? = nil, unanswered: @escaping @Sendable () -> Void = {}) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let task else {
                guard let buttons = self.approvalButtons else { return }
                AXUIElementPerformAction(allow ? buttons.allow : buttons.deny, kAXPressAction as CFString)
                self.approvalButtons = nil
                self.check()
                return
            }
            guard let entry = self.entries[task] else { return unanswered() }
            AXUIElementPerformAction(entry, kAXPressAction as CFString)
            self.press(allow: allow, tries: 20, unanswered: unanswered)
        }
    }

    /// The app brought forward, on whatever it's showing.
    @MainActor
    static func bringForward() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    /// Opens a task waiting in the sidebar, to be answered there.
    func open(task: String) {
        queue.async { [weak self] in
            guard let entry = self?.entries[task] else { return }
            AXUIElementPerformAction(entry, kAXPressAction as CFString)
        }
    }

    /// Presses Allow (or Deny) once the prompt's up, looking every 0.15 s, `tries` more times.
    private func press(allow: Bool, tries: Int, unanswered: @escaping @Sendable () -> Void) {
        let windows = app.map(ButtonReader.windows(of:)) ?? []
        if let buttons = windows.lazy.compactMap({ self.approvalButtons(in: $0) }).first {
            AXUIElementPerformAction(allow ? buttons.allow : buttons.deny, kAXPressAction as CFString)
            approvalButtons = nil
            check()
            return
        }
        guard tries > 0 else { return unanswered() }
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.press(allow: allow, tries: tries - 1, unanswered: unanswered) }
    }

    private func check() {
        guard let app else { return }
        // Its main window too, when it's on a Space you're not on (a fullscreen one of its own).
        let windows = ButtonReader.windows(of: app)
        webAreas.removeAll { kept in !windows.contains { CFEqual($0, kept.window) } }
        var writing: String?
        var entries: [String: AXUIElement] = [:], waiting: [Waiting] = []
        approvalButtons = nil
        for window in windows {
            if approvalButtons == nil { approvalButtons = self.approvalButtons(in: window) }
            if writing == nil, isWriting(in: window) { writing = Self.text(window, kAXTitleAttribute) ?? "" }
            for found in waitingEntries(in: window) where entries[found.name] == nil {
                entries[found.name] = found.entry
                waiting.append(Waiting(name: found.name, status: found.status))
            }
        }
        self.entries = entries
        let title = Self.chatName(writing ?? windows.first.flatMap { Self.text($0, kAXTitleAttribute) } ?? "")
        // The one showing is asked about by its own prompt.
        if approvalButtons != nil { waiting.removeAll { $0.name == title } }
        let chat = Chat(pid: pid, title: title, isWriting: writing != nil, needsApproval: approvalButtons != nil, waiting: waiting)
        guard chat != last else { return }
        last = chat
        report(chat)
    }

    /// The app's Allow and Deny buttons, when it's asking to use a tool: "Allow once" over
    /// "Always allow", so pressing it here never grants more than one use.
    private func approvalButtons(in window: AXUIElement) -> (allow: AXUIElement, deny: AXUIElement)? {
        let areas = webAreas(in: window)
        guard !areas.isEmpty else { return nil }
        let allows = buttons(in: areas, matching: "Allow")
        let labels = allows.map { Self.label(of: $0) }
        guard let index = Self.allowOnce(labels) else {
            logUnpaired(labels)
            return nil
        }
        let allow = allows[index]
        // Only a pair that sits together, the way a permission prompt shows them, not an Allow
        // and a Deny from different corners of the window.
        let near = Self.ancestors(of: allow, levels: 4)
        let denies = Self.denials.flatMap { buttons(in: areas, matching: $0) }
        guard let deny = denies.first(where: { button in
            Self.ancestors(of: button, levels: 4).contains { candidate in near.contains { CFEqual($0, candidate) } }
        }) else {
            logUnpaired(labels + denies.map { Self.label(of: $0) })
            return nil
        }
        unpaired = []
        return (allow, deny)
    }

    /// What a prompt's no says.
    static let denials = ["Deny", "Don't allow", "Decline", "Reject"]

    /// How a sidebar task waiting on you says so, before its name.
    static let waitingWords = ["Awaiting", "Needs"]

    /// Whether a sidebar task's status (its icon's description: "Idle", "Awaiting …", "Needs …")
    /// says it's waiting on you.
    static func isWaiting(_ status: String) -> Bool {
        let status = status.lowercased()
        return waitingWords.contains { status.hasPrefix($0.lowercased()) }
    }

    /// The task called `label` ("Awaiting approval Plan the trip"), with its status said first:
    /// its name.
    static func taskName(_ label: String, status: String) -> String {
        guard label.hasPrefix(status) else { return label }
        return String(label.dropFirst(status.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The sidebar's tasks that say they're waiting on you: each entry a button holding its
    /// status's icon (described as the status) and then its name, found by asking the page for
    /// buttons that say so. Each status is logged the first time it's seen (just the status, never
    /// the task).
    private func waitingEntries(in window: AXUIElement) -> [(name: String, status: String, entry: AXUIElement)] {
        let areas = webAreas(in: window)
        guard !areas.isEmpty else { return [] }
        return Self.waitingWords.flatMap { buttons(in: areas, matching: $0) }.compactMap { entry in
            let parts = Self.elements(entry, kAXChildrenAttribute)
            guard parts.count == 2, Self.text(parts[0], kAXRoleAttribute) == kAXImageRole as String,
                  let status = Self.text(parts[0], kAXDescriptionAttribute), Self.isWaiting(status) else { return nil }
            let name = Self.taskName(Self.label(of: entry), status: status)
            guard !name.isEmpty else { return nil }
            if statuses.insert(status).inserted { Self.log.notice("A Claude app task waiting on you says: \(status, privacy: .public)") }
            return (name, status, entry)
        }
    }

    /// Which of a prompt's buttons, labelled `labels`, allows one use and no more: "Allow once"
    /// (with a shortcut after it, say), or a plain "Allow"; never "Always allow" or "Allow for
    /// this chat".
    static func allowOnce(_ labels: [String]) -> Int? {
        let words = labels.map { $0.lowercased().split { !$0.isLetter }.map(String.init) }
        return words.firstIndex { $0.starts(with: ["allow", "once"]) }
            ?? words.firstIndex { $0 == ["allow"] }
    }

    /// Approval-like buttons that weren't a prompt's pair, logged once each time they change (just
    /// the buttons' own short labels, never what the chat says), so a prompt the app's started
    /// labelling differently shows up (`log show --predicate 'subsystem == "local.nott"'`).
    private func logUnpaired(_ labels: [String]) {
        let short = labels.filter { $0.count <= 32 }
        guard !short.isEmpty, short != unpaired else { return }
        unpaired = short
        Self.log.notice("Claude app buttons not taken for a prompt: \(short.joined(separator: " | "), privacy: .public)")
    }

    private static let log = Logger(subsystem: "local.nott", category: "claude")

    private static func ancestors(of element: AXUIElement, levels: Int) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var current = element
        for _ in 0..<levels {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { break }
            current = value as! AXUIElement
            found.append(current)
        }
        return found
    }

    /// Whether the window has the "Stop" button that shows while a reply is being written.
    private func isWriting(in window: AXUIElement) -> Bool {
        let areas = webAreas(in: window)
        return !areas.isEmpty && buttons(in: areas, matching: "Stop").contains { Self.label(of: $0).localizedCaseInsensitiveContains("stop") }
    }

    /// Buttons whose label has `text` in it. Asks the app to search, the way VoiceOver jumps
    /// between buttons (Chromium answers it itself, in one call); without that, walks the page,
    /// but only every few seconds and only so far.
    private func buttons(in areas: [AXUIElement], matching text: String) -> [AXUIElement] {
        if searchWorks {
            let predicate: [String: Any] = ["AXSearchKey": "AXButtonSearchKey", "AXSearchText": text,
                                            "AXResultsLimit": 8, "AXDirection": "AXDirectionNext"]
            var found: [AXUIElement] = []
            for area in areas where searchWorks {
                var result: CFTypeRef?
                let error = AXUIElementCopyParameterizedAttributeValue(area, "AXUIElementsForSearchPredicate" as CFString,
                                                                       predicate as CFDictionary, &result)
                if error == .success {
                    found += ((result as? [AXUIElement]) ?? []).filter(Self.isButton)
                } else if error == .invalidUIElement {
                    webAreas = []
                    return []
                } else {
                    searchWorks = false
                }
            }
            if searchWorks { return found }
        }
        if Date().timeIntervalSince(lastWalk) > 4 {
            lastWalk = Date()
            var found: [(element: AXUIElement, label: String)] = []
            var budget = 3000
            for area in areas {
                _ = Self.find(in: area, budget: &budget) { element in
                    if Self.isButton(element) { found.append((element, Self.label(of: element))) }
                    return false
                }
            }
            walked = found
        }
        return walked.filter { $0.label.localizedCaseInsensitiveContains(text) }.map(\.element)
    }

    /// The window's web content: every web area in it, since the app's chat isn't in the first
    /// (that's its frame's), found again every so often in case another's come.
    private func webAreas(in window: AXUIElement) -> [AXUIElement] {
        if let kept = webAreas.first(where: { CFEqual($0.window, window) }), Date().timeIntervalSince(kept.at) < 10 {
            return kept.areas
        }
        var budget = 600
        var areas: [AXUIElement] = []
        _ = Self.find(in: window, budget: &budget) { element in
            if Self.text(element, kAXRoleAttribute) == "AXWebArea" { areas.append(element) }
            return false
        }
        webAreas.removeAll { CFEqual($0.window, window) }
        webAreas.append((window, areas, Date()))
        return areas
    }

    private static func isButton(_ element: AXUIElement) -> Bool {
        text(element, kAXRoleAttribute) == kAXButtonRole as String
    }

    private static func label(of element: AXUIElement) -> String {
        [text(element, kAXDescriptionAttribute), text(element, kAXTitleAttribute)]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    /// Depth first, visiting at most `budget` elements.
    private static func find(in element: AXUIElement, budget: inout Int,
                             where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard budget > 0 else { return nil }
        budget -= 1
        if matches(element) { return element }
        for child in elements(element, kAXChildrenAttribute) {
            if let found = find(in: child, budget: &budget, where: matches) { return found }
            if budget <= 0 { return nil }
        }
        return nil
    }

    /// "Planning a trip - Claude" → "Planning a trip"; just "Claude" → "Chat".
    private static func chatName(_ title: String) -> String {
        let name = title.hasSuffix(" - Claude") ? String(title.dropLast(" - Claude".count)) : title
        return name.isEmpty || name == "Claude" ? "Chat" : name
    }

    private static func text(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
