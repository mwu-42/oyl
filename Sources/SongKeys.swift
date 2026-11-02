import AppKit
import ApplicationServices

/// Control-Option-→ for the next song, Control-Option-← for the one before (or back to the start
/// of this one, as the previous button does), from any app. Nothing on the Mac uses them (VS Code
/// only, to move by part of a word). They're taken before the app in front gets them, so it doesn't
/// act on them too (an event tap, which needs Oyl allowed in Accessibility, as the hand pointer
/// does); but only when there's a song to skip: otherwise they go through as ever.
@MainActor
final class SongKeys {
    nonisolated static let left: Int64 = 123
    nonisolated static let right: Int64 = 124

    /// Skips forward (true) or back, saying whether it did.
    private let skip: @MainActor (_ forward: Bool) -> Bool
    private var tap: CFMachPort?
    private var retrying: Timer?
    /// The arrow whose press was taken, so its letting go is too.
    private var taken: Int64?

    init(skip: @escaping @MainActor (_ forward: Bool) -> Bool) {
        self.skip = skip
        install()
        // Until Accessibility's allowed.
        retrying = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tap == nil else { return }
                self.install()
            }
        }
    }

    /// Which way a key pressed goes, if it's one of these: an arrow, with Control and Option and
    /// nothing else held (the arrows come marked as the keypad's and fn's too).
    nonisolated static func direction(code: Int64, flags: CGEventFlags) -> Bool? {
        guard code == left || code == right,
              flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == [.maskControl, .maskAlternate]
        else { return nil }
        return code == right
    }

    private func install() {
        guard AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let heard: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let keys = Unmanaged<SongKeys>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { keys.heard(type, event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: heard,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        self.tap = tap
    }

    /// What goes on to the app in front: nil, for what's taken.
    private func heard(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a tap off if it's slow, or while a password's typed: on again.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyUp where code == taken:
            taken = nil
            return nil
        case .keyDown:
            // Held down, it skips the once.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                if code == taken { return nil }
            } else if let forward = Self.direction(code: code, flags: event.flags), skip(forward) {
                taken = code
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
