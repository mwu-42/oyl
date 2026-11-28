import AppKit

@main
enum OylApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // No Dock icon, no menu bar: the notch is the whole UI. Right-click it to quit.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var awake: AwakeManager?
    private var terminationSignal: DispatchSourceSignal?
    /// Quitting only for a moment: killed to be started again, or at logout or shut down.
    private var backSoon = false
    /// This copy's the one running (not a second, or opened only to pass AirDrop's files on).
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        guard others.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        // Opened only to show what AirDrop's saved, by an AirDrop that still asks Oyl, though Oyl's
        // been quit since (see `AirDropReveal`): Finder shows it, and Oyl goes again.
        if notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == false, AirDropReveal.openedOnlyToShow() {
            NSApp.terminate(nil)
            return
        }
        started = true
        // Open at login, unless that's turned off. Every launch checks, so it comes back if it was
        // taken out of Login Items, and registers again when the app has moved.
        LoginItem.apply()

        // Created only once we know this is the sole copy: it resets lid sleep left over from a crash.
        let awake = AwakeManager()
        self.awake = awake
        // Before the notch, so its window's sized for every account's row from the start.
        ClaudeLimit.shared.start()
        controller = NotchController(nowPlaying: NowPlaying(), timers: TimerStore(), awake: awake,
                                     agents: AgentMonitor())
        MorningStart.shared.start()
        ScreenshotHold.shared.start()
        WindowSnap.shared.start()

        // `kill`/`pkill` skip applicationWillTerminate; route them through it so a keep-awake
        // session never outlives the app (lid sleep especially). It carries on if Oyl's back soon.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.backSoon = true
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSignal = source
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.backSoon = true }
        }
    }

    /// AirDrop asking for what it's saved to be shown (see `AirDropReveal`): Oyl opens nothing else.
    func application(_ application: NSApplication, open urls: [URL]) {
        AirDropReveal.asked(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard started else { return }
        controller?.quitting()
        awake?.pause()
        MacDock.quitting(forGood: !backSoon)
        AirDropReveal.quitting(forGood: !backSoon)
        ScreenshotHold.shared.quitting(forGood: !backSoon)
    }
}
