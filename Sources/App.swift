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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        guard others.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        // Open at login, unless that's turned off. Every launch checks, so it comes back if it was
        // taken out of Login Items, and registers again when the app has moved.
        LoginItem.apply()

        // Created only once we know this is the sole copy: it resets lid sleep left over from a crash.
        let awake = AwakeManager()
        self.awake = awake
        controller = NotchController(nowPlaying: NowPlaying(), timers: TimerStore(), awake: awake,
                                     agents: AgentMonitor())

        // `kill`/`pkill` skip applicationWillTerminate; route them through it so a keep-awake
        // session never outlives the app (lid sleep especially). It carries on if Oyl's back soon.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        awake?.pause()
    }
}
