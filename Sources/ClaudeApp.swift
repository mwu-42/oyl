import AppKit
import ApplicationServices

/// Chats (and Cowork) in the Claude desktop app, which unlike Claude Code have no hooks. This reads
/// the app's window through Accessibility, which you allow once: while Claude writes a reply the
/// window has a "Stop" button, and while it waits for your OK, Allow and Deny buttons, which this
/// can press for you.
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
    private var webArea: (window: AXUIElement, area: AXUIElement)?
    private var searchWorks = true
    private var lastWalk = Date.distantPast
    private var walked: [(element: AXUIElement, label: String)] = []
    private var last: Chat?
    private var approvalButtons: (allow: AXUIElement, deny: AXUIElement)?

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
            self.webArea = nil
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

    /// Presses the app's own Allow (or Deny) for the request it's showing.
    func respond(allow: Bool) {
        queue.async { [weak self] in
            guard let self, let buttons = self.approvalButtons else { return }
            AXUIElementPerformAction(allow ? buttons.allow : buttons.deny, kAXPressAction as CFString)
            self.approvalButtons = nil
            self.check()
        }
    }

    private func check() {
        guard let app else { return }
        let windows = Self.elements(app, kAXWindowsAttribute)
        var writing: String?
        approvalButtons = nil
        for window in windows {
            if approvalButtons == nil { approvalButtons = self.approvalButtons(in: window) }
            if writing == nil, isWriting(in: window) { writing = Self.text(window, kAXTitleAttribute) ?? "" }
        }
        let title = writing ?? windows.first.flatMap { Self.text($0, kAXTitleAttribute) } ?? ""
        let chat = Chat(pid: pid, title: Self.chatName(title), isWriting: writing != nil, needsApproval: approvalButtons != nil)
        guard chat != last else { return }
        last = chat
        report(chat)
    }

    /// The app's Allow and Deny buttons, when it's asking to use a tool: "Allow once" over
    /// "Always allow", so pressing it here never grants more than one use.
    private func approvalButtons(in window: AXUIElement) -> (allow: AXUIElement, deny: AXUIElement)? {
        guard let area = webArea(in: window) else { return nil }
        let allows = buttons(in: area, matching: "Allow")
        let label = { (button: AXUIElement) in Self.label(of: button).lowercased() }
        guard let allow = allows.first(where: { label($0) == "allow once" })
                ?? allows.first(where: { label($0) == "allow" }) else { return nil }
        // Only a pair that sits together, the way a permission prompt shows them, not an Allow
        // and a Deny from different corners of the window.
        let near = Self.ancestors(of: allow, levels: 3)
        let denies = buttons(in: area, matching: "Deny") + buttons(in: area, matching: "Don't allow")
        guard let deny = denies.first(where: { button in
            Self.ancestors(of: button, levels: 3).contains { candidate in near.contains { CFEqual($0, candidate) } }
        }) else { return nil }
        return (allow, deny)
    }

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
        guard let area = webArea(in: window) else { return false }
        return buttons(in: area, matching: "Stop").contains { Self.label(of: $0).localizedCaseInsensitiveContains("stop") }
    }

    /// Buttons whose label has `text` in it. Asks the app to search, the way VoiceOver jumps
    /// between buttons (Chromium answers it itself, in one call); without that, walks the page,
    /// but only every few seconds and only so far.
    private func buttons(in area: AXUIElement, matching text: String) -> [AXUIElement] {
        if searchWorks {
            let predicate: [String: Any] = ["AXSearchKey": "AXButtonSearchKey", "AXSearchText": text,
                                            "AXResultsLimit": 8, "AXDirection": "AXDirectionNext"]
            var result: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(area, "AXUIElementsForSearchPredicate" as CFString,
                                                                   predicate as CFDictionary, &result)
            if error == .success {
                return ((result as? [AXUIElement]) ?? []).filter(Self.isButton)
            }
            if error == .invalidUIElement {
                webArea = nil
                return []
            }
            searchWorks = false
        }
        if Date().timeIntervalSince(lastWalk) > 4 {
            lastWalk = Date()
            var found: [(element: AXUIElement, label: String)] = []
            var budget = 3000
            _ = Self.find(in: area, budget: &budget) { element in
                if Self.isButton(element) { found.append((element, Self.label(of: element))) }
                return false
            }
            walked = found
        }
        return walked.filter { $0.label.localizedCaseInsensitiveContains(text) }.map(\.element)
    }

    /// The window's web content, found once and kept.
    private func webArea(in window: AXUIElement) -> AXUIElement? {
        if let webArea, CFEqual(webArea.window, window) { return webArea.area }
        var budget = 400
        guard let area = Self.find(in: window, budget: &budget, where: { Self.text($0, kAXRoleAttribute) == "AXWebArea" })
        else { return nil }
        webArea = (window, area)
        return area
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
