import AppKit
import ApplicationServices
import os

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
    /// Checks in a row its windows weren't seen (one's a flicker, as a swipe settles).
    private var misses = 0
    /// When the Dock last said they're up: another app in front or another Space just then is
    /// their own doing as they come up, not their end (they're over then only if they're not up).
    private var shownAt: Date?
    nonisolated static let settling: TimeInterval = 0.6

    private static let log = Logger(subsystem: "local.nott", category: "mission-control")

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
        for (name, reason) in [(NSWorkspace.activeSpaceDidChangeNotification, "another Space"),
                               (NSWorkspace.didActivateApplicationNotification, "another app in front")] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.over(by: reason) }
            }
        }
    }

    private func watchDock() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        end("watching the Dock afresh")
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
            if !isShowing { Self.log.notice("The Dock says \(name, privacy: .public)") }
            begin()
        } else if name == Self.gone {
            end("the Dock says it's gone")
        }
    }

    /// Whether something that happened `since` the Dock said they're up is their own doing, as
    /// they come up.
    nonisolated static func isSettling(since shown: Date?, now: Date = Date()) -> Bool {
        shown.map { now.timeIntervalSince($0) < settling } ?? false
    }

    /// Another app in front, or another Space: over, unless it's as they come up, when they're
    /// only over if, once they've settled, they aren't up.
    private func over(by reason: String) {
        guard isShowing else { return }
        guard Self.isSettling(since: shownAt), let shownAt else {
            end(reason)
            return
        }
        let wait = max(Self.settling - Date().timeIntervalSince(shownAt), 0.05)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isShowing, self.shownAt == shownAt else { return }
                if self.isUp() {
                    Self.log.notice("\(reason, privacy: .public) as it came up: still up")
                } else {
                    self.end("\(reason), and it's not up")
                }
            }
        }
    }

    /// Whether it's up now, as its windows or its row say.
    private func isUp() -> Bool {
        if Self.dockWindowsUp() { return true }
        guard let dock = dock?.processIdentifier else { return false }
        return MissionControlRow.isOpen(dock: dock)
    }

    private func begin() {
        sawWindows = false
        misses = 0
        if !isShowing { shownAt = Date() }
        isShowing = true
        checking?.invalidate()
        checking = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Self.dockWindowsUp() {
                    self.sawWindows = true
                    self.misses = 0
                } else if self.sawWindows {
                    self.misses += 1
                    if self.misses >= 2 { self.end("its windows are gone") }
                }
            }
        }
    }

    private func end(_ reason: String) {
        checking?.invalidate()
        checking = nil
        if isShowing {
            let after = shownAt.map { String(format: "%.2f s", Date().timeIntervalSince($0)) } ?? "?"
            Self.log.notice("Gone after \(after, privacy: .public): \(reason, privacy: .public)")
        }
        shownAt = nil
        isShowing = false
    }

    /// The Dock's windows over everything else, as it shows the desktops: any of its own on
    /// screen above the desktop's, other than the Dock itself.
    nonisolated static func dockWindowsUp() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        return windows.contains { window in
            guard window[kCGWindowOwnerName as String] as? String == "Dock", let layer = window[kCGWindowLayer as String] as? Int else { return false }
            return layer > 0 && layer != dock
        }
    }
}
