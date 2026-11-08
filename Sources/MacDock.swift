import AppKit

/// The macOS Dock kept down while Oyl's own is on: told to wait for ever before it comes up at the
/// bottom edge (its `autohide-delay`, which it only reads as it starts, so it's restarted for it),
/// so it never shows from under Oyl's, wherever along the edge the pointer goes. Your own setting
/// is kept, and put back (the Dock restarted again) once Oyl's Dock is off, Oyl's switched off, or
/// it's quit. Not when it's quit for a moment (killed to be started again, or at logout or shut
/// down), since it'll be back, which spares the Dock a restart, and a flash, each time. Set to show
/// all the time (⌥⌘D), the Dock shows anyway.
///
/// And its icons kept from bouncing (its `no-bouncing`) while Oyl's marks for apps asking for you
/// are up instead (see `AttentionMark`): that it reads each time one asks, so it's never restarted
/// for, and it's put back however Oyl quits.
@MainActor
enum MacDock {
    nonisolated private static let dock = "com.apple.dock" as CFString
    private static let delayKey = "autohide-delay" as CFString
    /// How long it waits: as good as for ever.
    static let forever: Double = 1000
    /// Your own delay, kept while it's Oyl's; "unset" if you'd none.
    private static let keptKey = "macDock.delay"
    private static let bouncingKey = "no-bouncing" as CFString
    /// Your own, kept while it's Oyl's.
    private static let keptBouncingKey = "macDock.noBouncing"
    private static let unset = "unset"

    /// Kept down (`down`), or as you had it: restarting the Dock only if that changes anything.
    /// (Its settings' `domain`, where yours is kept and how it's restarted are for a test to give.)
    static func keep(down: Bool, domain: CFString = dock, keeping store: UserDefaults = .standard,
                     restart: () -> Void = restart) {
        if hold(delayKey, at: NSNumber(value: forever), down, keptAs: keptKey, in: domain, keeping: store) { restart() }
    }

    /// Its icons kept from bouncing (`quiet`), or as you had them.
    static func quiet(_ quiet: Bool, domain: CFString = dock, keeping store: UserDefaults = .standard) {
        _ = hold(bouncingKey, at: kCFBooleanTrue, quiet, keptAs: keptBouncingKey, in: domain, keeping: store)
    }

    /// Oyl's quitting: as you had it, unless it's only for a moment; its icons bouncing again anyway.
    static func quitting(forGood: Bool) {
        quiet(false)
        guard forGood else { return }
        keep(down: false)
    }

    /// `key` set to `ours` (`on`), what you had there kept (in `store`, under `keptKey`) to be put
    /// back once it's not: whether that changed it. One you've set meanwhile is left alone.
    private static func hold(_ key: CFString, at ours: CFPropertyList, _ on: Bool, keptAs keptKey: String,
                             in domain: CFString, keeping store: UserDefaults) -> Bool {
        CFPreferencesAppSynchronize(domain)
        let current = CFPreferencesCopyAppValue(key, domain)
        let isOurs = current.map { CFEqual($0, ours) } ?? false
        let kept = store.object(forKey: keptKey)
        if on {
            guard !isOurs else { return false }
            store.set(current ?? unset as CFPropertyList, forKey: keptKey)
            set(key, to: ours, in: domain)
        } else {
            guard let kept, isOurs else {
                store.removeObject(forKey: keptKey)
                return false
            }
            set(key, to: (kept as? String) == unset ? nil : kept as CFPropertyList, in: domain)
            store.removeObject(forKey: keptKey)
        }
        return true
    }

    private static func set(_ key: CFString, to value: CFPropertyList?, in domain: CFString) {
        CFPreferencesSetAppValue(key, value, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// Its delay as set in `domain`, if one is.
    static func delay(in domain: CFString = dock) -> Double? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(delayKey, domain) as? Double
    }

    /// Whether its icons bounce, as `domain` has it.
    static func bounces(in domain: CFString = dock) -> Bool {
        CFPreferencesAppSynchronize(domain)
        return !(CFPreferencesCopyAppValue(bouncingKey, domain) as? Bool ?? false)
    }

    /// The Dock reads its settings as it starts; it's started again at once when it's gone.
    nonisolated private static func restart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
}
