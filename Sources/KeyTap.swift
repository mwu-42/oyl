import AppKit
import ApplicationServices

/// Keys from any app, taken before the app in front gets them, so it doesn't act on them too (an
/// event tap, which needs Oyl allowed in Accessibility, as the hand pointer does).
///
/// Control-Option-→ for the next song, Control-Option-← for the one before (or back to the start
/// of this one, as the previous button does). Nothing on the Mac uses them (VS Code only, to move
/// by part of a word), and they're only taken when there's a song to skip: otherwise they go
/// through as ever.
///
/// Command-period for the emoji picker, as the Windows key and period bring it up on Windows: by
/// pressing the Mac's own shortcut for it (Control-Command-Space, Emoji & Symbols in any app's
/// Edit menu), so it comes up at the caret wherever you're typing: in every app, terminals and
/// code editors too (in place of their own Command-period, which stops what's running, or offers
/// fixes). Not in Oyl's own notch, which brings the picker up itself (`EditKeys`).
///
/// Control-Option-P for picture in picture: the window in front into it, or put away (see
/// `PictureInPicture`); only taken when there's one to do it to.
@MainActor
final class KeyTap {
    nonisolated static let left: Int64 = 123
    nonisolated static let right: Int64 = 124
    nonisolated private static let space: CGKeyCode = 49

    /// Skips forward (true) or back, saying whether it did.
    private let skip: @MainActor (_ forward: Bool) -> Bool
    /// Whether Command-period's for the emoji picker now.
    private let emoji: @MainActor () -> Bool
    /// Picture in picture for the window in front, saying whether it was.
    private let pictureInPicture: @MainActor () -> Bool
    private var tap: CFMachPort?
    private var retrying: Timer?
    /// The key whose press was taken, so its letting go is too.
    private var taken: Int64?

    init(skip: @escaping @MainActor (_ forward: Bool) -> Bool, emoji: @escaping @MainActor () -> Bool,
         pictureInPicture: @escaping @MainActor () -> Bool) {
        self.skip = skip
        self.emoji = emoji
        self.pictureInPicture = pictureInPicture
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

    /// Whether a key pressed is Command-period: its period wherever the keyboard's layout has it,
    /// with Command and nothing else held.
    nonisolated static func isEmojiKey(_ characters: String?, flags: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == .maskCommand && characters == "."
    }

    /// Whether a key pressed is Control-Option-P: its P wherever the keyboard's layout has it, with
    /// Control and Option and nothing else held.
    nonisolated static func isPictureInPictureKey(_ characters: String?, flags: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == [.maskControl, .maskAlternate]
            && characters?.lowercased() == "p"
    }

    /// The emoji picker up in the app in front, at its caret, as its Edit menu's Emoji & Symbols
    /// has it: Control-Command-Space pressed for it, Command (still held) and all.
    static func pickEmoji() {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: space, keyDown: down) else { return }
            event.flags = [.maskControl, .maskCommand]
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func install() {
        guard AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let heard: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let keys = Unmanaged<KeyTap>.fromOpaque(context).takeUnretainedValue()
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
            // Held down, it goes the once.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                if code == taken { return nil }
            } else if let forward = Self.direction(code: code, flags: event.flags), skip(forward) {
                taken = code
                return nil
            } else if event.flags.contains(.maskCommand),
                      Self.isEmojiKey(NSEvent(cgEvent: event)?.charactersIgnoringModifiers, flags: event.flags), emoji() {
                taken = code
                Self.pickEmoji()
                return nil
            } else if event.flags.contains([.maskControl, .maskAlternate]),
                      Self.isPictureInPictureKey(NSEvent(cgEvent: event)?.charactersIgnoringModifiers, flags: event.flags),
                      pictureInPicture() {
                taken = code
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
