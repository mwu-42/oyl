import AppKit
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac awake for a while, like Amphetamine: two hours unless told otherwise, until
/// stopped, for a set time, or while an app is open. It keeps running with the lid closed too.
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

    private let defaults = UserDefaults.standard
    private var assertion: IOPMAssertionID?
    private var assertionKeepsDisplay = false
    private var endTimer: Timer?
    private var batteryTimer: Timer?

    init() {
        displayMaySleep = defaults.bool(forKey: "awake.displayMaySleep")
        stopOnLowBattery = defaults.object(forKey: "awake.stopOnLowBattery") as? Bool ?? true

        // A crash or force quit can leave lid sleep off. Put it back.
        if defaults.bool(forKey: "awake.lidSleepDisabled") {
            LidSleep.set(disabled: false)
            defaults.set(false, forKey: "awake.lidSleepDisabled")
        }

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
        if case .whileRunning(let bundleID, _) = mode,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return }
        self.mode = mode
        if case .until(let end) = mode { length = end.timeIntervalSinceNow.rounded() } else { length = nil }
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
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkBattery() }
            }
        }
        apply()
        checkBattery()
    }

    func stop() {
        mode = nil
        length = nil
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

        // Idle sleep: a power assertion, released as soon as the session ends.
        let keepDisplay = !displayMaySleep
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
        let disableLidSleep = active && lidHelperInstalled
        if disableLidSleep != defaults.bool(forKey: "awake.lidSleepDisabled"), LidSleep.set(disabled: disableLidSleep) {
            defaults.set(disableLidSleep, forKey: "awake.lidSleepDisabled")
        }
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
