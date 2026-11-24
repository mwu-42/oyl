import AppKit
import Darwin

/// What comes by AirDrop shown on the shelf, in Oyl's Dock, rather than in a Finder window (which,
/// over a full-screen app, takes you off to a desktop to show it). AirDrop (macOS's `sharingd`)
/// shows what it's saved by asking AppKit to, and AppKit asks the app named as Finder's stand-in
/// (`NSFileViewer`, in the asking app's settings) if one is, and Finder if not: so Oyl's named
/// there, in AirDrop's own settings only, and every other app's "Show in Finder" is still
/// Finder's. What it's asked to show comes to Oyl as files to open (see `AppDelegate`): the Dock
/// comes up with the shelf open and them picked out on it (see `DockController.present`); when it
/// can't (Oyl's off, or the files aren't on the shelf), Finder shows them, as ever.
///
/// Named while Oyl's Dock, its shelf, Downloads on it and this are on; not once one's off, or
/// Oyl's quit (not for a moment, as `MacDock` isn't). AppKit reads the stand-in once, the first
/// time it's asked, and keeps it: so AirDrop's restarted (it starts again by itself, at once) if
/// it began before Oyl was named; and Oyl no longer named, AirDrop may still ask Oyl till it next
/// starts, which passes them on to Finder (opened just for that, if it's been quit, and going
/// again).
@MainActor
enum AirDropReveal {
    nonisolated static let sharingd = "com.apple.sharingd" as CFString
    nonisolated static let viewerKey = "NSFileViewer" as CFString
    /// When Oyl was named, to tell whether AirDrop's started since.
    nonisolated static let namedAtKey = "airDrop.namedAt"
    /// Your own stand-in for AirDrop, if you'd one, kept to be put back; "unset" if not.
    nonisolated static let keptKey = "airDrop.kept"
    nonisolated private static let unset = "unset"

    /// Shows what AirDrop's saved, if it can: the Dock's, once it's there.
    private static var show: (([URL]) -> Bool)?
    /// Asked to show before the Dock was there (Oyl opened to show them).
    private static var waiting: [URL] = []

    nonisolated static var ours: String { Bundle.main.bundleIdentifier ?? "local.nott" }

    /// Whether Oyl's what AirDrop has show what it saves (in `domain`, its settings).
    nonisolated static func isNamed(in domain: CFString = sharingd, as id: String = ours) -> Bool {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(viewerKey, domain) as? String == id
    }

    /// Oyl named (`on`) or not, as what AirDrop has show what it saves: what you'd there kept (in
    /// `store`) and put back. Whether that changed anything. AirDrop's restarted, once named, if
    /// it began before (see above).
    @discardableResult
    nonisolated static func name(_ on: Bool, in domain: CFString = sharingd, as id: String = ours,
                                 keeping store: UserDefaults = .standard) -> Bool {
        CFPreferencesAppSynchronize(domain)
        let current = CFPreferencesCopyAppValue(viewerKey, domain)
        let isOurs = current as? String == id
        if on {
            guard !isOurs else { return false }
            store.set(current ?? unset as CFPropertyList, forKey: keptKey)
            store.set(Date(), forKey: namedAtKey)
            set(id as CFString, in: domain)
        } else {
            let kept = store.object(forKey: keptKey)
            store.removeObject(forKey: keptKey)
            store.removeObject(forKey: namedAtKey)
            // One you've set meanwhile is left alone.
            guard isOurs else { return false }
            set((kept as? String) == unset ? nil : kept as? CFPropertyList, in: domain)
        }
        return true
    }

    nonisolated private static func set(_ value: CFPropertyList?, in domain: CFString) {
        CFPreferencesSetAppValue(viewerKey, value, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// Named, or not, as the Dock has it; AirDrop restarted if it's to take it in.
    static func follow(_ on: Bool) {
        name(on)
        if on { restartIfStale() }
    }

    /// Oyl's quitting: no longer named, unless it's only for a moment.
    static func quitting(forGood: Bool) {
        if forGood { name(false) }
    }

    /// AirDrop started again if it began before Oyl was named, so it takes it in.
    static func restartIfStale() {
        guard isNamed(), let named = UserDefaults.standard.object(forKey: namedAtKey) as? Date else { return }
        for process in processes(named: "sharingd") where process.started < named {
            kill(process.pid, SIGTERM)
        }
    }

    /// Yours running under `name`, and when each started.
    nonisolated static func processes(named name: String) -> [(pid: pid_t, started: Date)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).compactMap { info in
            var comm = info.kp_proc.p_comm
            let named = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard named == name else { return nil }
            let start = info.kp_proc.p_starttime
            return (info.kp_proc.p_pid, Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000))
        }
    }

    // MARK: Asked to show

    /// Asked to show `urls` (by AirDrop: Oyl opens nothing else).
    static func asked(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let show else {
            waiting += urls
            return
        }
        if !show(urls) { toFinder(urls) }
    }

    /// The Dock's there to show them: and, once it's settled, what was asked before it was.
    static func ready(_ show: @escaping ([URL]) -> Bool) {
        self.show = show
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                let asked = waiting
                waiting = []
                if !asked.isEmpty { self.asked(asked) }
            }
        }
    }

    /// Opened only to show some, and no longer named (Oyl had been quit, but AirDrop hadn't
    /// started since): Finder shows them, and Oyl can go again.
    static func openedOnlyToShow() -> Bool {
        guard !waiting.isEmpty, !isNamed() else { return false }
        toFinder(waiting)
        waiting = []
        return true
    }

    /// In Finder, as AirDrop would have (never back to Oyl: only Oyl's own settings say who
    /// AppKit asks here, and Oyl's never named there).
    static func toFinder(_ urls: [URL]) {
        guard UserDefaults.standard.string(forKey: viewerKey as String) != ours else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
