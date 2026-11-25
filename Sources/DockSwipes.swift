import AppKit
import ApplicationServices
import os

/// While the desktops' list is up, the Dock's swipes up and down are held back: three fingers up
/// (Mission Control) and down (App Exposé) don't open over it. Across, between Spaces, still goes
/// through, as do pinches. An event tap on the Dock's own events (the kind Oyl posts to go
/// straight to a Space, see `InstantSpaces`), which needs Oyl allowed in Accessibility; on a
/// thread of its own, so a swipe never waits on anything else Oyl's doing; and only on while the
/// list's up (and till a swipe it held back is over, so the Dock never sees half of one). A swipe
/// across, to another Space, puts the list away as it begins (`swipedAcross`): it'd be left up on
/// the Space it came from, out of sight, holding Mission Control back still.
final class DockSwipes: @unchecked Sendable {
    static let shared = DockSwipes()

    /// What's held back, event by event: a swipe up or down that begins while it's blocking, all
    /// of it, from its beginning to its end; nothing else.
    struct Gate {
        /// A Dock swipe, of the Dock's own events (as opposed to its pinches).
        static let dockSwipe: Int64 = 23
        static let vertical: Int64 = 2
        static let across: Int64 = 1
        static let began: Int64 = 1
        /// Ended, or called off.
        static let over: Int64 = 4 | 8

        private(set) var holding = false

        /// Whether this one's held back: its kind (a Dock swipe, or not), which way it goes,
        /// its phase, and whether a new one up or down is to be held back now.
        mutating func holds(kind: Int64, motion: Int64, phase: Int64, blocking: Bool) -> Bool {
            guard kind == Self.dockSwipe else { return false }
            // Each swipe decided as it begins (one whose end went missing is over by then).
            if phase == Self.began { holding = blocking && motion == Self.vertical }
            guard holding else { return false }
            if phase & Self.over != 0 { holding = false }
            return true
        }

        /// Whether this one's a swipe across beginning while the list's up: it's to go.
        static func swipesAway(kind: Int64, motion: Int64, phase: Int64, blocking: Bool) -> Bool {
            blocking && kind == dockSwipe && motion == across && phase == began
        }
    }

    /// Run (on the main thread) as a swipe across begins while the list's up.
    @MainActor var swipedAcross: () -> Void = {}

    /// The Dock's own events (kCGSEventDockControl).
    static let eventType: UInt32 = 30

    private let lock = NSLock()
    private var blocking = false
    private var gate = Gate()
    private var tap: CFMachPort?
    private var thread: Thread?

    private static let log = Logger(subsystem: "local.nott", category: "desktops")

    /// Swipes up and down held back from now (the list's up), or not (it's away).
    @MainActor
    func block(_ on: Bool) {
        lock.withLock { blocking = on }
        if on { install() }
        let (tap, holding) = lock.withLock { (self.tap, gate.holding) }
        guard let tap else { return }
        if on {
            CGEvent.tapEnable(tap: tap, enable: true)
        } else if !holding {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    /// Made the first time it's wanted (once Oyl's allowed in Accessibility).
    @MainActor
    private func install() {
        guard lock.withLock({ tap == nil }), AXIsProcessTrusted() else { return }
        let heard: CGEventTapCallBack = { _, type, event, _ in DockSwipes.shared.heard(type, event) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1) << CGEventMask(Self.eventType), callback: heard,
                                          userInfo: nil) else {
            Self.log.notice("Couldn't watch the Dock's swipes: Mission Control's can't be held back while the desktops' list is up")
            return
        }
        lock.withLock { self.tap = tap }
        let thread = Thread { [self] in
            guard let tap = lock.withLock({ self.tap }), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "Oyl's Dock swipes"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    private func heard(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turns a tap off if it's slow: on again, if it's still wanted.
            let (tap, wanted) = lock.withLock { (self.tap, blocking || gate.holding) }
            if let tap, wanted { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.eventType else { return Unmanaged.passUnretained(event) }
        let kind = event.getIntegerValueField(Self.field(110))
        let motion = event.getIntegerValueField(Self.field(123))
        let phase = event.getIntegerValueField(Self.field(132))
        let (held, up, wanted, tap) = lock.withLock { () -> (Bool, Bool, Bool, CFMachPort?) in
            let held = gate.holds(kind: kind, motion: motion, phase: phase, blocking: blocking)
            return (held, blocking, blocking || gate.holding, self.tap)
        }
        if kind == Gate.dockSwipe, phase == Gate.began {
            Self.log.notice("A swipe for the Dock began while the desktops' list was up (motion \(motion)): \(held ? "held back" : "let through", privacy: .public)")
        }
        if Gate.swipesAway(kind: kind, motion: motion, phase: phase, blocking: up) {
            DispatchQueue.main.async { MainActor.assumeIsolated { DockSwipes.shared.swipedAcross() } }
        }
        // The list's away and the swipe held back is over: off till it's up again.
        if !wanted, let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        return held ? nil : Unmanaged.passUnretained(event)
    }

    private static func field(_ number: UInt32) -> CGEventField { unsafeBitCast(number, to: CGEventField.self) }
}
