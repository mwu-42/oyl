import AppKit

/// Quick taps of one modifier key on its own (control twice takes a screenshot, three times
/// switches Oyl off), or of a few pressed together (control and option, for the camera): a tap is
/// the key (all of them) pressed and let go within `longest`, with no other modifier with it, and
/// each comes within `gap` of the last. A key or a click in between starts the count
/// again, so typing, shortcuts and Oyl's own Mission Control keys (control and an arrow, posted by
/// the hand pointer) never count. The most taps that mean anything are told at once; fewer, once
/// they're over (no more having come within `gap`), so two never count on the way to three.
struct ModifierTaps {
    static let press: TimeInterval = 0.35
    static let gap: TimeInterval = 0.5

    let key: NSEvent.ModifierFlags
    let most: Int
    /// The longest a tap's held: `press`, or a little longer for keys pressed together.
    let longest: TimeInterval
    /// Taps so far.
    private(set) var count = 0
    private var pressedAt: TimeInterval?
    private var releasedAt = -TimeInterval.infinity
    private var held = false

    init(_ key: NSEvent.ModifierFlags, most: Int, longest: TimeInterval = Self.press) {
        self.key = key
        self.most = most
        self.longest = longest
    }

    /// The modifier keys are now `flags`, at `time` (seconds since the Mac started, as events
    /// have it): `most`, if that let go of the last of that many taps.
    mutating func changed(_ flags: NSEvent.ModifierFlags, at time: TimeInterval) -> Int? {
        let keys = flags.intersection([.shift, .control, .option, .command, .function])
        let down = keys.contains(key)
        defer { held = down }
        guard keys.subtracting(key).isEmpty else {
            interrupted()
            return nil
        }
        if down, !held {
            if time - releasedAt > Self.gap { count = 0 }
            pressedAt = time
            return nil
        }
        guard !down, held, let pressedAt else { return nil }
        self.pressedAt = nil
        guard time - pressedAt <= longest else {
            count = 0
            return nil
        }
        count += 1
        releasedAt = time
        guard count == most else { return nil }
        count = 0
        return most
    }

    /// At `time`: how many taps there were, once they're over and if there were any; told once.
    mutating func settled(at time: TimeInterval) -> Int? {
        guard count > 0, pressedAt == nil, time - releasedAt > Self.gap else { return nil }
        defer { count = 0 }
        return count
    }

    /// A key or a click: the taps so far don't count.
    mutating func interrupted() {
        count = 0
        pressedAt = nil
    }
}

/// Listens for `ModifierTaps` everywhere: over other apps (which needs Oyl allowed in Privacy &
/// Security's Accessibility, as the hand pointer does) and its own windows. Each count of taps
/// does what `actions` has for it, once they're over (or at once, the most); and `each` is told
/// of every tap as it's let go, with how many so far.
@MainActor
final class TapWatcher {
    private var taps: ModifierTaps
    private let actions: [Int: @MainActor () -> Void]
    private let each: (@MainActor (Int) -> Void)?
    private var monitors: [Any] = []
    private var settling: Timer?

    init(_ key: NSEvent.ModifierFlags, longest: TimeInterval = ModifierTaps.press, each: (@MainActor (Int) -> Void)? = nil,
         actions: [Int: @MainActor () -> Void]) {
        taps = ModifierTaps(key, most: actions.keys.max() ?? 1, longest: longest)
        self.actions = actions
        self.each = each
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let heard = { [weak self] (event: NSEvent) in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type != .flagsChanged {
                    self.taps.interrupted()
                    return
                }
                let before = self.taps.count
                let most = self.taps.changed(event.modifierFlags, at: event.timestamp)
                if self.taps.count > before || most != nil { self.each?(most ?? self.taps.count) }
                if let most {
                    self.actions[most]?()
                } else {
                    self.settleLater()
                }
            }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: heard) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            heard(event)
            return event
        }) {
            monitors.append(monitor)
        }
    }

    /// A key the watchers don't hear (one an event tap's kept for itself): the taps so far don't
    /// count.
    func interrupt() {
        taps.interrupted()
    }

    /// Fewer taps than the most count once no more come.
    private func settleLater() {
        settling?.invalidate()
        settling = Timer.scheduledTimer(withTimeInterval: ModifierTaps.gap + 0.02, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let count = self.taps.settled(at: ProcessInfo.processInfo.systemUptime) else { return }
                self.actions[count]?()
            }
        }
    }
}

/// A key pressed with modifiers, posted as if typed. The modifier keys go down first and up
/// after, as by hand: a key posted only carrying their flags leaves the system thinking they're
/// held, so every click after it is a control-click (a context menu) till a real key's pressed.
enum Keystroke {
    private static let modifierKeys: [(flag: CGEventFlags, key: CGKeyCode)] = [
        (.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59),
    ]

    static func post(_ code: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        let modifiers = modifierKeys.filter { flags.contains($0.flag) }
        var held: CGEventFlags = []
        for modifier in modifiers {
            held.insert(modifier.flag)
            post(modifier.key, down: true, flags: held)
        }
        post(code, down: true, flags: flags)
        post(code, down: false, flags: flags)
        for modifier in modifiers.reversed() {
            held.remove(modifier.flag)
            post(modifier.key, down: false, flags: held)
        }
    }
}

/// A picture of part of the screen, as ⇧⌘4 takes it: by pressing the Mac's own shortcut for it
/// (whatever it's been set to in Keyboard settings), so it's saved where, as and with the
/// thumbnail macOS's are. With the shortcut turned off, macOS's `screencapture` takes it the same
/// way instead, which needs Oyl allowed Screen Recording.
enum AreaScreenshot {
    static func take() {
        if let shortcut = shortcut() {
            Keystroke.post(shortcut.code, flags: shortcut.flags, source: CGEventSource(stateID: .hidSystemState))
            return
        }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // Picked out by hand, saved as the screenshot settings say.
        capture.arguments = ["-i", "-p"]
        try? capture.run()
    }

    /// "Save picture of selected area as a file" in Keyboard settings' Screenshots shortcuts: ⇧⌘4
    /// until it's changed, nil if it's been turned off.
    private static func shortcut() -> (code: CGKeyCode, flags: CGEventFlags)? {
        let standard: (code: CGKeyCode, flags: CGEventFlags) = (21, [.maskShift, .maskCommand])
        let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        guard let entry = (hotkeys as? [String: Any])?["30"] as? [String: Any] else { return standard }
        if let enabled = entry["enabled"] as? Bool, !enabled { return nil }
        guard let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [Int], parameters.count == 3,
              parameters[1] >= 0, parameters[1] < 0xFFFF else { return standard }
        let flags = CGEventFlags(rawValue: UInt64(parameters[2])).intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        return (CGKeyCode(parameters[1]), flags)
    }
}
