import AppKit
import ApplicationServices

/// Whether you're viewing your desktops: Mission Control, App Exposé or Show Desktop, as the Dock
/// says when they come and go (its accessibility notifications, the ones window managers go by,
/// so Oyl has to be allowed in Accessibility). The Dock doesn't always say when they've gone, so
/// meanwhile its windows for them are looked for too, and a new Space or app in front means
/// they're over.
@MainActor
final class MissionControl {
    private(set) var isShowing = false {
        didSet { if isShowing != oldValue { changed(isShowing) } }
    }

    private static let shown = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"]
    private static let gone = "AXExposeExit"

    private let changed: @MainActor (Bool) -> Void
    private var observer: AXObserver?
    private var dock: NSRunningApplication?
    private var checking: Timer?
    private var retrying: Timer?
    /// Its windows for them have been seen this time, so once they're gone, so is it.
    private var sawWindows = false

    init(changed: @escaping @MainActor (Bool) -> Void) {
        self.changed = changed
        watchDock()
        // Until Accessibility's allowed, and whenever the Dock starts over.
        retrying = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.observer == nil || self.dock?.isTerminated != false else { return }
                self.watchDock()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            }
        }
    }

    private func watchDock() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        end()
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        var made: AXObserver?
        let heard: AXObserverCallback = { _, _, name, context in
            guard let context else { return }
            let watcher = Unmanaged<MissionControl>.fromOpaque(context).takeUnretainedValue()
            let name = name as String
            MainActor.assumeIsolated { watcher.heard(name) }
        }
        guard AXObserverCreate(dock.processIdentifier, heard, &made) == .success, let made else { return }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let added = (Self.shown + [Self.gone]).filter { AXObserverAddNotification(made, element, $0 as CFString, me) == .success }
        guard !added.isEmpty else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .commonModes)
        observer = made
        self.dock = dock
    }

    private func heard(_ name: String) {
        if Self.shown.contains(name) {
            begin()
        } else if name == Self.gone {
            end()
        }
    }

    private func begin() {
        sawWindows = false
        isShowing = true
        checking?.invalidate()
        checking = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Self.dockWindowsUp() {
                    self.sawWindows = true
                } else if self.sawWindows {
                    self.end()
                }
            }
        }
    }

    private func end() {
        checking?.invalidate()
        checking = nil
        isShowing = false
    }

    /// The Dock's windows over everything else, as it shows the desktops: any of its own on
    /// screen above the desktop's, other than the Dock itself.
    private static func dockWindowsUp() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        return windows.contains { window in
            guard window[kCGWindowOwnerName as String] as? String == "Dock", let layer = window[kCGWindowLayer as String] as? Int else { return false }
            return layer > 0 && layer != dock
        }
    }
}
