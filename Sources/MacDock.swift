import AppKit

/// The macOS Dock kept down while Oyl's own is on: told to wait for ever before it comes up at the
/// bottom edge (its `autohide-delay`, which it only reads as it starts, so it's restarted for it),
/// so it never shows from under Oyl's, wherever along the edge the pointer goes. Your own setting
/// is kept, and put back (the Dock restarted again) once Oyl's Dock is off, Oyl's switched off, or
/// it's quit. Not when it's quit for a moment (killed to be started again, or at logout or shut
/// down), since it'll be back, which spares the Dock a restart, and a flash, each time. Set to show
/// all the time (⌥⌘D), the Dock shows anyway.
@MainActor
enum MacDock {
    nonisolated private static let dock = "com.apple.dock" as CFString
    private static let delayKey = "autohide-delay" as CFString
    /// How long it waits: as good as for ever.
    static let forever: Double = 1000
    /// Your own delay, kept while it's Oyl's; "unset" if you'd none.
    private static let keptKey = "macDock.delay"
    private static let unset = "unset"

    /// Kept down (`down`), or as you had it: restarting the Dock only if that changes anything.
    /// (Its settings' `domain`, where yours is kept and how it's restarted are for a test to give.)
    static func keep(down: Bool, domain: CFString = dock, keeping store: UserDefaults = .standard,
                     restart: () -> Void = restart) {
        CFPreferencesAppSynchronize(domain)
        let current = CFPreferencesCopyAppValue(delayKey, domain) as? Double
        let kept = store.object(forKey: keptKey)
        if down {
            guard current != forever else { return }
            store.set(current.map { $0 as Any } ?? unset, forKey: keptKey)
            set(forever, in: domain)
        } else {
            guard let kept, current == forever else {
                store.removeObject(forKey: keptKey)
                return
            }
            set(kept as? Double, in: domain)
            store.removeObject(forKey: keptKey)
        }
        restart()
    }

    /// Oyl's quitting: as you had it, unless it's only for a moment.
    static func quitting(forGood: Bool) {
        guard forGood else { return }
        keep(down: false)
    }

    private static func set(_ delay: Double?, in domain: CFString) {
        CFPreferencesSetAppValue(delayKey, delay.map { NSNumber(value: $0) }, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// Its delay as set in `domain`, if one is.
    static func delay(in domain: CFString = dock) -> Double? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(delayKey, domain) as? Double
    }

    /// The Dock reads its settings as it starts; it's started again at once when it's gone.
    nonisolated private static func restart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
}
