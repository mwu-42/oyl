import AppKit

/// Quick taps of one modifier key on its own (command twice takes a screenshot, control three
/// times switches Oyl off; control once, then pressed again and held, swaps Oyl's look), or of a few pressed together (control and option, for the camera): a
/// tap is the key (all of them) pressed and let go within `longest`, with no other modifier with
/// it, and each pressed within `gap` of letting go of the last (Command's quicker than the rest).
/// A key or a click in between starts the count again, so typing, shortcuts and Oyl's own Mission
/// Control keys (control and an arrow, posted by the hand pointer) never count. The most taps that mean anything are told at once; fewer, once
/// they're over (no more having come within `gap`), so two never count on the way to three.
struct ModifierTaps {
    static let press: TimeInterval = 0.35
    static let usualGap: TimeInterval = 0.5
    /// Command's: two taps a screenshot only when they're quick, so pressing it twice on the way
    /// to a shortcut, thought better of, isn't one.
    static let commandGap: TimeInterval = 0.25

    let key: NSEvent.ModifierFlags
    /// For one side's key alone (the right Command): its own bit in the flags, and the other
    /// side's, which mustn't be down with it.
    let side: (this: UInt, other: UInt)?
    let most: Int
    /// The longest a tap's held: `press`, or a little longer for keys pressed together.
    let longest: TimeInterval
    /// The longest from letting go of one tap to pressing the next.
    let gap: TimeInterval
    /// Taps so far.
    private(set) var count = 0
    private var pressedAt: TimeInterval?
    private var releasedAt = -TimeInterval.infinity
    private var held = false

    /// The right Command key's bit in an event's flags, and the left's.
    static let rightCommand = (this: UInt(0x10), other: UInt(0x08))
    /// The right Shift key's, and the left's.
    static let rightShift = (this: UInt(0x04), other: UInt(0x02))
    /// Shift's: two taps quick enough not to be the start of typing a capital, thought better of.
    static let shiftGap: TimeInterval = 0.3

    init(_ key: NSEvent.ModifierFlags, side: (this: UInt, other: UInt)? = nil, most: Int, longest: TimeInterval = Self.press,
         gap: TimeInterval = Self.usualGap) {
        self.key = key
        self.side = side
        self.most = most
        self.longest = longest
        self.gap = gap
    }

    /// The modifier keys are now `flags`, at `time` (seconds since the Mac started, as events
    /// have it): `most`, if that let go of the last of that many taps.
    mutating func changed(_ flags: NSEvent.ModifierFlags, at time: TimeInterval) -> Int? {
        let keys = flags.intersection([.shift, .control, .option, .command, .function])
        var down = keys.contains(key)
        defer { held = down }
        if let side {
            down = down && flags.rawValue & side.this != 0
            if flags.rawValue & side.other != 0 {
                interrupted()
                return nil
            }
        }
        guard keys.subtracting(key).isEmpty else {
            interrupted()
            return nil
        }
        if down, !held {
            if time - releasedAt > gap { count = 0 }
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
        guard count > 0, pressedAt == nil, time - releasedAt > gap else { return nil }
        defer { count = 0 }
        return count
    }

    /// Pressed again after a tap (within `gap` of letting go of it) and still down: since when.
    var pressedAfterTap: TimeInterval? { count == 1 ? pressedAt : nil }

    /// At `time`: whether it's been pressed again after one tap and held `hold` since; told once
    /// (the taps then don't count, so letting go of it isn't one).
    mutating func heldAfterTap(at time: TimeInterval, for hold: TimeInterval) -> Bool {
        guard let since = pressedAfterTap, time - since >= hold else { return false }
        interrupted()
        return true
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
    /// Tapped once, then pressed again and held: what that does (as soon as it's held long enough).
    private let held: (@MainActor () -> Void)?
    private var holding: Timer?
    /// How long the second press is held for it: longer than any tap, so it's never one.
    static let hold: TimeInterval = 0.45

    init(_ key: NSEvent.ModifierFlags, side: (this: UInt, other: UInt)? = nil, longest: TimeInterval = ModifierTaps.press,
         gap: TimeInterval = ModifierTaps.usualGap, each: (@MainActor (Int) -> Void)? = nil,
         held: (@MainActor () -> Void)? = nil, actions: [Int: @MainActor () -> Void]) {
        taps = ModifierTaps(key, side: side, most: actions.keys.max() ?? 1, longest: longest, gap: gap)
        self.actions = actions
        self.each = each
        self.held = held
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let heard = { [weak self] (event: NSEvent) in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type != .flagsChanged {
                    self.taps.interrupted()
                    self.holding?.invalidate()
                    self.holding = nil
                    return
                }
                let before = self.taps.count
                let most = self.taps.changed(event.modifierFlags, at: event.timestamp)
                self.holdLater()
                if self.taps.count > before || most != nil { self.each?(most ?? self.taps.count) }
                if let most {
                    self.actions[most]?()
                } else if self.taps.count > 0 {
                    self.settleLater()
                } else {
                    // Nothing counted: there's nothing to settle (any wait set already would
                    // find none), so no timer for every other modifier pressed while typing.
                    self.settling?.invalidate()
                    self.settling = nil
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

    /// Pressed again after a tap: told if it's still down once it's been held long enough.
    private func holdLater() {
        holding?.invalidate()
        holding = nil
        guard held != nil, let since = taps.pressedAfterTap else { return }
        let wait = max(Self.hold - (ProcessInfo.processInfo.systemUptime - since), 0) + 0.01
        holding = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.taps.heldAfterTap(at: ProcessInfo.processInfo.systemUptime, for: Self.hold) else { return }
                self.settling?.invalidate()
                self.settling = nil
                self.held?()
            }
        }
    }

    /// Fewer taps than the most count once no more come.
    private func settleLater() {
        settling?.invalidate()
        settling = Timer.scheduledTimer(withTimeInterval: taps.gap + 0.02, repeats: false) { [weak self] _ in
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
