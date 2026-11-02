import AppKit
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac awake for a while, like Amphetamine: two hours unless told otherwise, until
/// stopped, for a set time, or while an app is open. It keeps running with the lid closed too:
/// then, with no other screen on, the screen's dimmed all the way and put to sleep (and brought
/// back as it was when the lid opens), and Oyl rests everything that's only there to be seen. A
/// session carries on if Oyl's back within ten minutes of quitting (restarted, updated, crashed);
/// meanwhile the Mac sleeps as usual.
@MainActor
final class AwakeManager: ObservableObject {
    enum Mode: Equatable {
        case indefinitely
        case until(Date)
        case whileRunning(bundleID: String, name: String)
    }

    static let batteryFloor = 20
    /// The longest it'll stay awake for a set time.
    static let longest: TimeInterval = 24 * 3600
    /// How long it stays awake when not told how long.
    static let usual: TimeInterval = 2 * 3600
    /// How soon Oyl has to be back after quitting for a session to carry on.
    static let resumeWithin: TimeInterval = 10 * 60

    /// nil while the Mac sleeps as usual.
    @Published private(set) var mode: Mode?
    /// How long it was set to stay awake, for a set time.
    @Published private(set) var length: TimeInterval?
    @Published var displayMaySleep: Bool {
        didSet { defaults.set(displayMaySleep, forKey: "awake.displayMaySleep"); apply() }
    }
    @Published var stopOnLowBattery: Bool {
        didSet { defaults.set(stopOnLowBattery, forKey: "awake.stopOnLowBattery") }
    }
    @Published private(set) var lidHelperInstalled = LidSleep.isInstalled
    @Published private(set) var installingHelper = false
    /// The lid's down and no other screen's on: nothing on screen can be seen.
    @Published private(set) var isShut = false

    private let defaults = UserDefaults.standard
    private var assertion: IOPMAssertionID?
    private var assertionKeepsDisplay = false
    private var endTimer: Timer?
    private var batteryTimer: Timer?
    private let lid = Lid()

    init() {
        displayMaySleep = defaults.bool(forKey: "awake.displayMaySleep")
        stopOnLowBattery = defaults.object(forKey: "awake.stopOnLowBattery") as? Bool ?? true

        // A crash or force quit can leave lid sleep off. Put it back, unless the session's still on.
        let resumed = Self.saved(in: defaults)
        if resumed == nil, defaults.bool(forKey: "awake.lidSleepDisabled") {
            LidSleep.set(disabled: false)
            defaults.set(false, forKey: "awake.lidSleepDisabled")
        }
        // Or the screen dimmed under the lid.
        if !lid.isClosed { undim() }
        lid.onChange = { [weak self] in self?.checkShut() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkShut() }
        }
        checkShut()
        if let resumed { start(resumed.mode, length: resumed.length) }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, case .whileRunning(let watched, _) = self.mode, watched == bundleID else { return }
                self.stop()
            }
        }
    }

    var isActive: Bool { mode != nil }

    /// Two hours.
    func startUsual() {
        start(.until(Date().addingTimeInterval(Self.usual)))
    }

    func start(_ mode: Mode) {
        start(mode, length: nil)
    }

    /// `length`: how long a set time was set to be, when it's carried on from before.
    private func start(_ mode: Mode, length: TimeInterval?) {
        if case .whileRunning(let bundleID, _) = mode,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return }
        self.mode = mode
        if case .until(let end) = mode { self.length = length ?? end.timeIntervalSinceNow.rounded() } else { self.length = nil }
        save()
        if !lidHelperInstalled { installLidHelper() }
        endTimer?.invalidate()
        endTimer = nil
        if case .until(let end) = mode {
            let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
            RunLoop.main.add(timer, forMode: .common)
            endTimer = timer
        }
        if batteryTimer == nil {
            // And lid sleep checked: the lid could close any time.
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkBattery()
                    self?.apply()
                }
            }
        }
        apply()
        checkBattery()
    }

    func stop() {
        // As it was, for whenever it's next woken.
        undim()
        mode = nil
        length = nil
        save()
        endTimer?.invalidate()
        endTimer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        apply()
    }

    /// The one-time password setup that lets it keep running with the lid closed.
    private func installLidHelper() {
        guard !installingHelper else { return }
        installingHelper = true
        LidSleep.install { [weak self] installed in
            guard let self else { return }
            self.installingHelper = false
            self.lidHelperInstalled = installed
            if installed { self.apply() }
        }
    }

    private func apply() {
        let active = mode != nil

        // Idle sleep: a power assertion, released as soon as the session ends. (With the lid
        // shut, the screen may sleep regardless.)
        let keepDisplay = !displayMaySleep && !isShut
        if let assertion, !active || keepDisplay != assertionKeepsDisplay {
            IOPMAssertionRelease(assertion)
            self.assertion = nil
        }
        if active, assertion == nil {
            var id = IOPMAssertionID(0)
            let type = keepDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Oyl is keeping your Mac awake" as CFString, &id) == kIOReturnSuccess {
                assertion = id
                assertionKeepsDisplay = keepDisplay
            }
        }

        // Lid closed: macOS sleeps on lid close regardless of assertions, so this needs pmset.
        // Checked against the setting itself, in case something's put it back meanwhile; and only
        // what Oyl turned off is turned back on.
        if active, lidHelperInstalled, !LidSleep.isDisabled {
            if LidSleep.set(disabled: true) { defaults.set(true, forKey: "awake.lidSleepDisabled") }
        } else if !active, defaults.bool(forKey: "awake.lidSleepDisabled") {
            if LidSleep.set(disabled: false) { defaults.set(false, forKey: "awake.lidSleepDisabled") }
        }
    }

    /// Oyl's quitting: the Mac put back to sleeping as usual, but the session kept, to carry on if
    /// it's back soon.
    func pause() {
        let session = defaults.dictionary(forKey: "awake.session")
        stop()
        guard let session else { return }
        defaults.set(session, forKey: "awake.session")
        defaults.set(Date().timeIntervalSinceReferenceDate, forKey: "awake.pausedAt")
    }

    /// The session as it's kept between launches (nothing, with none).
    private func save() {
        switch mode {
        case nil:
            defaults.removeObject(forKey: "awake.session")
        case .indefinitely:
            defaults.set(["kind": "indefinitely"], forKey: "awake.session")
        case .until(let end):
            defaults.set(["kind": "until", "end": end.timeIntervalSinceReferenceDate, "length": length ?? 0], forKey: "awake.session")
        case .whileRunning(let bundleID, let name):
            defaults.set(["kind": "whileRunning", "bundleID": bundleID, "name": name], forKey: "awake.session")
        }
    }

    /// The session kept from before, if it's still to run: Oyl back soon enough (or crashed), and
    /// its end not yet come, or its app still open.
    private static func saved(in defaults: UserDefaults) -> (mode: Mode, length: TimeInterval?)? {
        let paused = defaults.object(forKey: "awake.pausedAt") as? Double
        defaults.removeObject(forKey: "awake.pausedAt")
        guard let session = defaults.dictionary(forKey: "awake.session") else { return nil }
        if let paused, Date().timeIntervalSinceReferenceDate - paused > resumeWithin {
            defaults.removeObject(forKey: "awake.session")
            return nil
        }
        switch session["kind"] as? String {
        case "indefinitely":
            return (.indefinitely, nil)
        case "until":
            guard let end = (session["end"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)), end > Date() else { break }
            return (.until(end), (session["length"] as? Double).flatMap { $0 > 0 ? $0 : nil })
        case "whileRunning":
            guard let bundleID = session["bundleID"] as? String, let name = session["name"] as? String,
                  !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { break }
            return (.whileRunning(bundleID: bundleID, name: name), nil)
        default:
            break
        }
        defaults.removeObject(forKey: "awake.session")
        return nil
    }

    /// Whether the lid's shut with no other screen on; if it just was, while kept awake, the
    /// screen goes dark, and when it opens, it comes back.
    private func checkShut() {
        let shut = lid.isClosed && !NSScreen.screens.contains { !BuiltInScreen.isBuiltIn($0) }
        guard shut != isShut else {
            if !lid.isClosed { undim() }
            return
        }
        isShut = shut
        apply()
        if shut, isActive {
            dim()
        } else if !shut {
            undim()
        }
    }

    /// The screen all the way down, then asleep. Its brightness is kept, saved, to put back.
    private func dim() {
        if defaults.object(forKey: "awake.dimmedFrom") == nil, let level = BuiltInScreen.brightness, level > 0 {
            defaults.set(level, forKey: "awake.dimmedFrom")
            BuiltInScreen.brightness = 0
        }
        BuiltInScreen.sleep()
    }

    private func undim() {
        guard let level = defaults.object(forKey: "awake.dimmedFrom") as? Double else { return }
        BuiltInScreen.brightness = Float(level)
        defaults.removeObject(forKey: "awake.dimmedFrom")
    }

    private func checkBattery() {
        guard stopOnLowBattery, let battery = Battery.read(), battery.onBattery,
              battery.percent <= Self.batteryFloor else { return }
        stop()
    }
}

/// Lid-closed mode. macOS only skips sleeping on lid close with `pmset disablesleep 1`, which
/// needs root. A one-time, password-protected setup adds a sudoers rule allowing exactly
/// `pmset -a disablesleep 0` and `… 1` for this user, so Oyl can flip it without asking again.
/// To undo: `sudo rm /etc/sudoers.d/Oyl`.
enum LidSleep {
    private static let rulePath = "/etc/sudoers.d/nott"  // from the app's old name; already installed

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: rulePath) }

    /// Whether lid sleep's off now (`pmset -g`'s SleepDisabled), whoever turned it off.
    static var isDisabled: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }

    @discardableResult
    static func set(disabled: Bool) -> Bool {
        guard isInstalled else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @MainActor
    static func install(completion: @escaping @MainActor (Bool) -> Void) {
        let user = NSUserName()
        // The name goes into a shell command run as root; allow only plain account names.
        guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            completion(false)
            return
        }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        // Written to a temp file and checked with visudo before it goes live.
        let shell = "tmp=$(/usr/bin/mktemp) && /bin/echo '\(rule)' > $tmp && /usr/sbin/visudo -cf $tmp > /dev/null"
            + " && /usr/sbin/chown root:wheel $tmp && /bin/chmod 0440 $tmp && /bin/mv $tmp \(rulePath)"
        let source = """
        do shell script "\(shell)" with prompt "Oyl needs your password once to keep your Mac running with the lid closed." with administrator privileges
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let installed = error == nil && isInstalled
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(installed) }
            }
        }
    }
}

/// The lid, as the power manager tells of it closing and opening.
@MainActor
final class Lid {
    private(set) var isClosed = Lid.read()
    var onChange: () -> Void = {}

    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0
    /// The power manager's message that the lid's been opened or closed.
    private nonisolated static let clamshellChange: UInt32 = 0xE003_4100

    init() {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, message, _ in
            guard message == Lid.clamshellChange, let context else { return }
            let lid = Unmanaged<Lid>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                lid.isClosed = Lid.read()
                lid.onChange()
            }
        }, Unmanaged.passUnretained(self).toOpaque(), &notification)
    }

    private nonisolated static func read() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }
}

/// The built-in screen: its brightness, through the private calls brightness tools use (looked up
/// at run time; if they ever go away, it just isn't dimmed), and putting screens to sleep.
enum BuiltInScreen {
    private typealias Reader = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Writer = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let read = dlsym(framework, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Reader.self) }
    private static let write = dlsym(framework, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Writer.self) }

    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
    }

    private static var display: CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// 0...1, or nil if it can't be read.
    static var brightness: Float? {
        get {
            var level: Float = 0
            guard let display, let read, read(display, &level) == 0 else { return nil }
            return level
        }
        set {
            guard let newValue, let display, let write else { return }
            _ = write(display, newValue)
        }
    }

    /// Every screen to sleep now, as from a hot corner.
    static func sleep() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

enum Battery {
    static func read() -> (percent: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return (current * 100 / maximum, onBattery)
        }
        return nil
    }
}
