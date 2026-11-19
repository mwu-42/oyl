import AppKit
import CoreAudio
import IOKit.ps
import IOKit.pwr_mgt
import ObjectiveC.runtime

/// Keeps the Mac awake for a while, like Amphetamine: two hours unless told otherwise, until
/// stopped, for a set time, or while an app is open. It keeps running with the lid closed too:
/// then, with no other screen on, the screen and the keyboard's light go off (and come back as
/// they were when the lid opens), the speakers can be muted and Low Power Mode put on, and Oyl
/// rests everything that's only there to be seen. It stops by itself on battery at 20%, if the
/// battery can't be read, or if the Mac gets critically hot. A session carries on if Oyl's back
/// within ten minutes of quitting (restarted, updated, crashed); meanwhile the Mac sleeps as usual,
/// and if Oyl's gone without putting things back, `Watchdog` does.
@MainActor
final class AwakeManager: ObservableObject {
    enum Mode: Equatable {
        case indefinitely
        case until(Date)
        case whileRunning(bundleID: String, name: String)
    }

    /// Why it stopped by itself, and when.
    struct Stopped: Equatable {
        let reason: String
        let at: Date
    }

    static let batteryFloor = 20
    /// Below this on battery (with Low Power Mode on for it), Low Power Mode's put on.
    static let lowPowerFloor = 40
    /// The longest it'll stay awake for a set time.
    static let longest: TimeInterval = 24 * 3600
    /// How long it stays awake when not told how long.
    static let usual: TimeInterval = 2 * 3600
    /// How soon Oyl has to be back after quitting for a session to carry on.
    static let resumeWithin: TimeInterval = 10 * 60
    /// How long the lid has to stay down before it counts as shut: one only just down may be on its
    /// way back up, or bouncing at the angle it's sensed at.
    static let shutAfter: TimeInterval = 2
    /// How often it checks on things while it's on: lid sleep still off, the battery (that IOKit's
    /// gone quiet about), and the screen's brightness while you're at it.
    static let checkEvery: TimeInterval = 30

    /// nil while the Mac sleeps as usual.
    @Published private(set) var mode: Mode?
    /// How long it was set to stay awake, for a set time.
    @Published private(set) var length: TimeInterval?
    @Published var displayMaySleep: Bool {
        didSet { defaults.set(displayMaySleep, forKey: "awake.displayMaySleep"); apply() }
    }
    @Published var stopOnLowBattery: Bool {
        didSet { defaults.set(stopOnLowBattery, forKey: "awake.stopOnLowBattery"); batteryMisses = 0 }
    }
    /// The Mac's own speakers quiet while the lid's shut (headphones and the like aren't touched).
    @Published var muteWhenShut: Bool {
        didSet { defaults.set(muteWhenShut, forKey: "awake.muteWhenShut"); checkSpeakers() }
    }
    /// Low Power Mode while the lid's shut, the battery's under `lowPowerFloor` or the Mac's
    /// running hot. Needs `LowPower`'s helper, set up (with your password) as it's turned on.
    @Published private(set) var lowPowerWhenShut: Bool
    @Published private(set) var lidHelperInstalled = LidSleep.isInstalled
    @Published private(set) var installingHelper = false
    @Published private(set) var lowPowerHelperInstalled = LowPower.isInstalled
    @Published private(set) var installingLowPower = false
    /// The lid's down and no other screen's on: nothing on screen can be seen.
    @Published private(set) var isShut = false
    /// The last time it stopped by itself (the battery, the heat), till it's started again.
    @Published private(set) var stopped: Stopped?

    private let defaults = UserDefaults.standard
    private var assertion: IOPMAssertionID?
    private var assertionKeepsDisplay = false
    /// When the assertion lets go by itself (a set time's end), if it does.
    private var assertionEnds: Date?
    /// Stops a set time when it's up, by the clock on the wall (so not late after the Mac's slept).
    private lazy var endAlarm = WallClockAlarm { [weak self] in self?.stop() }
    private var checkTimer: Timer?
    private var shutCheck: Timer?
    private var powerSource: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?
    /// Reads of the battery in a row that couldn't say how full it is, and when the last was.
    private var batteryMisses = 0
    private var lastMiss = Date.distantPast
    /// The screen's and the keyboard's brightness, as last read while you were using them.
    private var sample = BrightnessSample()
    private let lid = Lid()

    init() {
        displayMaySleep = defaults.bool(forKey: "awake.displayMaySleep")
        stopOnLowBattery = defaults.object(forKey: "awake.stopOnLowBattery") as? Bool ?? true
        muteWhenShut = defaults.object(forKey: "awake.muteWhenShut") as? Bool ?? true
        lowPowerWhenShut = defaults.bool(forKey: "awake.lowPowerWhenShut") && LowPower.isInstalled

        // A crash or force quit can leave lid sleep off, or Low Power Mode on. Put them back,
        // unless the session's still on.
        let resumed = Self.saved(in: defaults)
        if resumed == nil {
            if defaults.bool(forKey: "awake.lidSleepDisabled"), LidSleep.set(disabled: false) {
                defaults.set(false, forKey: "awake.lidSleepDisabled")
            }
            if defaults.bool(forKey: "awake.lowPowerOn"), LowPower.set(false) {
                defaults.set(false, forKey: "awake.lowPowerOn")
            }
            defaults.removeObject(forKey: "awake.deadline")
        }
        // Or the screen and keyboard dark, or the speakers muted, under the lid.
        if !lid.isClosed { restoreLid() }
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

    /// A set time, `extra` longer (as long as 24 hours from now, at most), or with none running,
    /// one started for `extra`. Not one with no set end (false).
    @discardableResult
    func extend(by extra: TimeInterval) -> Bool {
        guard extra > 0 else { return false }
        switch mode {
        case nil:
            start(.until(Date().addingTimeInterval(min(extra, Self.longest))))
        case .until(let end):
            let later = min(end.addingTimeInterval(extra), Date().addingTimeInterval(Self.longest))
            start(.until(later), length: (length ?? end.timeIntervalSinceNow) + later.timeIntervalSince(end))
        default:
            return false
        }
        return true
    }

    /// `length`: how long a set time was set to be, when it's carried on from before.
    private func start(_ mode: Mode, length: TimeInterval?) {
        if case .whileRunning(let bundleID, _) = mode,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return }
        self.mode = mode
        stopped = nil
        if case .until(let end) = mode { self.length = length ?? end.timeIntervalSinceNow.rounded() } else { self.length = nil }
        save()
        if !lidHelperInstalled { installLidHelper() }
        if case .until(let end) = mode { endAlarm.set(end) } else { endAlarm.set(nil) }
        if checkTimer == nil {
            // And lid sleep checked: the lid could close any time.
            let timer = Timer(timeInterval: Self.checkEvery, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apply()
                    self.sampleBrightness()
                    self.checkBattery()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            checkTimer = timer
        }
        watchPower()
        sampleBrightness()
        apply()
        // Already shut (started from the phone, say, or carried on from before): dark at once.
        if isShut { dim() }
        checkSpeakers()
        checkBattery()
        checkHeat()
    }

    func stop() {
        stop(because: nil)
    }

    /// Stopped by itself, for `reason` ("your Mac got too hot"), or by hand (nil).
    private func stop(because reason: String?) {
        // As it was, for whenever it's next woken.
        restoreLid()
        mode = nil
        length = nil
        stopped = reason.map { Stopped(reason: $0, at: Date()) }
        save()
        endAlarm.set(nil)
        checkTimer?.invalidate()
        checkTimer = nil
        shutCheck?.invalidate()
        shutCheck = nil
        unwatchPower()
        batteryMisses = 0
        apply()
        checkLowPower()
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

    /// Low Power Mode on or off for it; turned on the first time, the password setup that lets it
    /// (and off again if that's cancelled).
    func setLowPower(_ on: Bool) {
        guard on, !LowPower.isInstalled else {
            lowPowerWhenShut = on
            defaults.set(on, forKey: "awake.lowPowerWhenShut")
            checkLowPower()
            return
        }
        guard !installingLowPower else { return }
        installingLowPower = true
        LowPower.install { [weak self] installed in
            guard let self else { return }
            self.installingLowPower = false
            self.lowPowerHelperInstalled = installed
            if installed { self.setLowPower(true) }
        }
    }

    private func apply() {
        let active = mode != nil

        // Idle sleep: a power assertion, released as soon as the session ends. (With the lid
        // shut, the screen may sleep regardless.) For a set time, it lets go by itself at the end
        // too, so even an Oyl that's hung can't keep the Mac up past it.
        let keepDisplay = !displayMaySleep && !isShut
        var ends: Date?
        if case .until(let end) = mode { ends = end }
        if let assertion, !active || keepDisplay != assertionKeepsDisplay || ends != assertionEnds {
            IOPMAssertionRelease(assertion)
            self.assertion = nil
        }
        if active, assertion == nil, let id = Self.assertion(keepingDisplay: keepDisplay, until: ends) {
            assertion = id
            assertionKeepsDisplay = keepDisplay
            assertionEnds = ends
        }
        // The end, where the watchdog can see it (in case Oyl's hung past it).
        if let ends { defaults.set(ends.timeIntervalSinceReferenceDate, forKey: "awake.deadline") } else {
            defaults.removeObject(forKey: "awake.deadline")
        }

        // Lid closed: macOS sleeps on lid close regardless of assertions, so this needs pmset.
        // Checked against the setting itself, in case something's put it back meanwhile; and only
        // what Oyl turned off is turned back on.
        if active, lidHelperInstalled, !LidSleep.isDisabled {
            if LidSleep.set(disabled: true) { defaults.set(true, forKey: "awake.lidSleepDisabled") }
        } else if !active, defaults.bool(forKey: "awake.lidSleepDisabled") {
            if LidSleep.set(disabled: false) { defaults.set(false, forKey: "awake.lidSleepDisabled") }
        }
        // Off for Oyl (this time, or carried on from before a crash): watched in case Oyl goes.
        if active, defaults.bool(forKey: "awake.lidSleepDisabled") { Watchdog.start() }
    }

    /// A power assertion against idle sleep (the system's, or the screen's too), letting go by
    /// itself at `until` if that's given.
    static func assertion(keepingDisplay: Bool, until: Date?) -> IOPMAssertionID? {
        var properties: [String: Any] = [
            kIOPMAssertionTypeKey: keepingDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                : kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionLevelKey: IOPMAssertionLevel(kIOPMAssertionLevelOn),
            kIOPMAssertionNameKey: "Oyl is keeping your Mac awake",
        ]
        if let until {
            properties[kIOPMAssertionTimeoutKey] = max(Int(until.timeIntervalSinceNow.rounded(.up)), 1)
            properties[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionTurnOff
        }
        var id = IOPMAssertionID(0)
        return IOPMAssertionCreateWithProperties(properties as CFDictionary, &id) == kIOReturnSuccess ? id : nil
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

    // MARK: The lid

    /// Whether the lid's shut with no other screen on; if it just was (and has stayed down a
    /// moment), while kept awake, the screen and keyboard go dark (and the speakers quiet), and
    /// when it opens, they come straight back.
    private func checkShut(settled: Bool = false) {
        let shut = lid.isClosed && !NSScreen.screens.contains { !BuiltInScreen.isBuiltIn($0) }
        if shut, !isShut, !settled {
            guard shutCheck == nil else { return }
            let timer = Timer(timeInterval: Self.shutAfter, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.shutCheck = nil
                    self?.checkShut(settled: true)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            shutCheck = timer
            return
        }
        shutCheck?.invalidate()
        shutCheck = nil
        guard shut != isShut else {
            if !lid.isClosed { restoreLid() }
            return
        }
        isShut = shut
        apply()
        if shut, isActive {
            dim()
        } else if !shut {
            restoreLid()
            // Its screen woken (with sleep off, macOS may leave that to the next key pressed).
            if isActive { BuiltInScreen.wake() }
        }
        checkSpeakers()
        checkLowPower()
    }

    /// The screen and the keyboard's light all the way down, then the screen asleep: with sleep
    /// off, macOS no longer does it as the lid shuts. Each one's brightness is kept, saved, to put
    /// back: as it was last read while you were using it, not as it is now, which auto-brightness
    /// will have dimmed as the lid came down.
    private func dim() {
        if defaults.object(forKey: "awake.dimmedFrom") == nil, let level = sample.display ?? BuiltInScreen.brightness, level > 0 {
            defaults.set(level, forKey: "awake.dimmedFrom")
            BuiltInScreen.brightness = 0
        }
        if defaults.object(forKey: "awake.keyboardFrom") == nil, let level = sample.keyboard ?? KeyboardLight.brightness, level > 0 {
            defaults.set(level, forKey: "awake.keyboardFrom")
            KeyboardLight.brightness = 0
        }
        BuiltInScreen.sleep()
    }

    /// Everything the lid's shutting changed, put back: the screen's and keyboard's brightness,
    /// and the speakers if they were muted for it.
    private func restoreLid() {
        if let level = defaults.object(forKey: "awake.dimmedFrom") as? Double {
            BuiltInScreen.brightness = Float(level)
            sample.display = Float(level)
            defaults.removeObject(forKey: "awake.dimmedFrom")
        }
        if let level = defaults.object(forKey: "awake.keyboardFrom") as? Double {
            KeyboardLight.brightness = Float(level)
            sample.keyboard = Float(level)
            defaults.removeObject(forKey: "awake.keyboardFrom")
        }
        if defaults.bool(forKey: "awake.mutedSpeakers") {
            if Speakers.isMuted == true { Speakers.setMuted(false) }
            defaults.set(false, forKey: "awake.mutedSpeakers")
        }
    }

    /// The screen's and keyboard's brightness, read while they're sure to be as you set them: the
    /// lid open, something touched in the last half minute (before macOS's idle dimming starts),
    /// the screen awake and the keyboard's light not held down by macOS.
    private func sampleBrightness() {
        guard !lid.isClosed, BrightnessSample.idleSeconds < 30 else { return }
        if defaults.object(forKey: "awake.dimmedFrom") == nil, !BuiltInScreen.isAsleep, let level = BuiltInScreen.brightness, level > 0 {
            sample.display = level
        }
        if defaults.object(forKey: "awake.keyboardFrom") == nil, !KeyboardLight.isHeldDown, let level = KeyboardLight.brightness {
            sample.keyboard = level
        }
    }

    /// The speakers muted while it's on with the lid shut (if they're to be), and back as they
    /// were otherwise; only ones Oyl muted are unmuted.
    private func checkSpeakers() {
        let mute = isActive && isShut && muteWhenShut
        let muted = defaults.bool(forKey: "awake.mutedSpeakers")
        if mute, !muted, Speakers.isMuted == false {
            if Speakers.setMuted(true) { defaults.set(true, forKey: "awake.mutedSpeakers") }
        } else if !mute, muted {
            if Speakers.isMuted == true { Speakers.setMuted(false) }
            defaults.set(false, forKey: "awake.mutedSpeakers")
        }
    }

    // MARK: Power and heat

    /// The battery heard of as it changes (IOKit tells of every percent), and the heat as it does.
    private func watchPower() {
        if powerSource == nil,
           let source = IOPSNotificationCreateRunLoopSource({ context in
               guard let context else { return }
               let awake = Unmanaged<AwakeManager>.fromOpaque(context).takeUnretainedValue()
               MainActor.assumeIsolated { awake.checkBattery() }
           }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
        if thermalObserver == nil {
            thermalObserver = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkHeat() }
            }
        }
    }

    private func unwatchPower() {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
    }

    /// On battery at the floor, it stops; and with a battery it can't read twice running (half a
    /// minute apart at least: one can be a hiccup), as the floor can't be kept to it either.
    private func checkBattery() {
        guard isActive else { return }
        switch Battery.status() {
        case .none:
            batteryMisses = 0
        case .level(let percent, let onBattery):
            batteryMisses = 0
            if stopOnLowBattery, onBattery, percent <= Self.batteryFloor {
                stop(because: "battery down to \(percent)%")
                return
            }
        case .unreadable(let onBattery):
            if Date().timeIntervalSince(lastMiss) >= Self.checkEvery - 1 {
                batteryMisses += 1
                lastMiss = Date()
            }
            if stopOnLowBattery, onBattery, batteryMisses >= 2 {
                stop(because: "couldn't read the battery")
                return
            }
        }
        checkLowPower()
    }

    /// Critically hot, it stops (whatever it's set to); seriously, Low Power Mode's put on.
    private func checkHeat() {
        guard isActive else { return }
        if ProcessInfo.processInfo.thermalState == .critical {
            stop(because: "your Mac got too hot")
            return
        }
        checkLowPower()
    }

    /// Whether Low Power Mode's wanted now: it's on, Low Power Mode's to be used, and the lid's
    /// shut, the battery's low or the Mac's hot.
    private var wantsLowPower: Bool {
        guard isActive, lowPowerWhenShut, lowPowerHelperInstalled else { return false }
        if isShut || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return true }
        if case .level(let percent, true) = Battery.status() { return percent < Self.lowPowerFloor }
        return false
    }

    /// Low Power Mode (on battery) put on as it's wanted, if it's off; and off again once nothing
    /// wants it, if Oyl put it on. One you have on yourself is left as it is.
    private func checkLowPower() {
        let ours = defaults.bool(forKey: "awake.lowPowerOn")
        let wanted = wantsLowPower
        if wanted, !ours, LowPower.batterySetting() == false {
            if LowPower.set(true) {
                defaults.set(true, forKey: "awake.lowPowerOn")
                Watchdog.start()
            }
        } else if !wanted, ours {
            if LowPower.set(false) { defaults.set(false, forKey: "awake.lowPowerOn") }
        } else if ours {
            Watchdog.start()
        }
    }
}

/// The screen's and the keyboard's brightness as last read while you were using them.
struct BrightnessSample {
    var display: Float?
    var keyboard: Float?

    /// Seconds since a key, the mouse or the trackpad was last touched (no permission needed).
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: UInt32.max)!)
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
        SudoRule.install(path: rulePath, commands: ["/usr/bin/pmset -a disablesleep 1", "/usr/bin/pmset -a disablesleep 0"],
                         prompt: "Oyl needs your password once to keep your Mac running with the lid closed.",
                         completion: completion)
    }
}

/// Low Power Mode, put on (on battery) while the Mac's kept awake with the lid shut, the battery's
/// low or it's running hot, as Insomnia does: a shut Mac with sleep off otherwise runs at full
/// speed. `pmset -b lowpowermode` needs root, so as with lid sleep a one-time, password-protected
/// setup adds a sudoers rule allowing exactly `pmset -b lowpowermode 1` and `… 0` for this user.
/// To undo: `sudo rm /etc/sudoers.d/oyl-lowpower`.
enum LowPower {
    private static let rulePath = "/etc/sudoers.d/oyl-lowpower"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: rulePath) }

    /// Whether Low Power Mode's set on for when it's on battery (`pmset -g custom`), or nil if it
    /// can't be told.
    static func batterySetting() -> Bool? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "custom"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return batterySetting(in: String(decoding: output, as: UTF8.self))
    }

    /// The Battery Power section's `lowpowermode` in `pmset -g custom`'s answer.
    static func batterySetting(in output: String) -> Bool? {
        var onBattery = false
        for line in output.split(whereSeparator: \.isNewline) {
            if !line.hasPrefix(" "), line.hasSuffix(":") {
                onBattery = line.trimmingCharacters(in: .whitespaces) == "Battery Power:"
                continue
            }
            let words = line.split(separator: " ")
            guard onBattery, words.count == 2, words[0] == "lowpowermode" else { continue }
            return words[1] == "1" ? true : words[1] == "0" ? false : nil
        }
        return nil
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard isInstalled else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-b", "lowpowermode", on ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @MainActor
    static func install(completion: @escaping @MainActor (Bool) -> Void) {
        SudoRule.install(path: rulePath, commands: ["/usr/bin/pmset -b lowpowermode 1", "/usr/bin/pmset -b lowpowermode 0"],
                         prompt: "Oyl needs your password once to turn Low Power Mode on and off while it keeps your Mac awake.",
                         completion: completion)
    }
}

/// A sudoers rule letting this user run exactly `commands` as root without a password, set up
/// once with the user's password (macOS's own prompt, saying why).
enum SudoRule {
    @MainActor
    static func install(path: String, commands: [String], prompt: String, completion: @escaping @MainActor (Bool) -> Void) {
        let user = NSUserName()
        // The name goes into a shell command run as root; allow only plain account names.
        guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            completion(false)
            return
        }
        let rule = "\(user) ALL=(root) NOPASSWD: " + commands.joined(separator: ", ")
        // Written to a temp file and checked with visudo before it goes live.
        let shell = "tmp=$(/usr/bin/mktemp) && /bin/echo '\(rule)' > $tmp && /usr/sbin/visudo -cf $tmp > /dev/null"
            + " && /usr/sbin/chown root:wheel $tmp && /bin/chmod 0440 $tmp && /bin/mv $tmp \(path)"
        let source = """
        do shell script "\(shell)" with prompt "\(prompt)" with administrator privileges
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let installed = error == nil && FileManager.default.fileExists(atPath: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(installed) }
            }
        }
    }
}

/// Puts back what a keep-awake left behind if Oyl's gone without doing it itself (it crashed, was
/// force-quit, or hung past a set time's end), as Insomnia's recovery agent does: a shell started
/// alongside, the first time Oyl turns lid sleep off or Low Power Mode on, that waits for Oyl to
/// go. A minute after (unless Oyl's back by then), it turns lid sleep back on and Low Power Mode
/// off if Oyl's settings say Oyl changed them, and marks the session as paused then, so it only
/// carries on if Oyl's back within the usual ten minutes. While Oyl's running, it looks once a
/// minute for a set time ended over two minutes ago with lid sleep still off: Oyl hung. The
/// screen's brightness and the speakers come back when Oyl next starts.
enum Watchdog {
    @MainActor private static var started = false

    /// Its script: $1 Oyl's pid, $2 its settings' domain, $3 its process name, $4 what runs pmset
    /// as root (sudo), $5 seconds to wait for Oyl to be back, $6 seconds between looks at Oyl.
    static let script = #"""
    pid=$1 domain=$2 name=$3 sudo=$4 grace=$5 tick=$6
    ref=978307200
    flag() { [ "$(/usr/bin/defaults read "$domain" "$1" 2>/dev/null)" = 1 ]; }
    put_back() {
      done=1
      if flag awake.lidSleepDisabled; then
        "$sudo" -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 && /usr/bin/defaults write "$domain" awake.lidSleepDisabled -bool false || done=0
      fi
      if flag awake.lowPowerOn; then
        "$sudo" -n /usr/bin/pmset -b lowpowermode 0 >/dev/null 2>&1 && /usr/bin/defaults write "$domain" awake.lowPowerOn -bool false || done=0
      fi
      [ $done = 1 ]
    }
    looks=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
      /bin/sleep "$tick"
      looks=$((looks + 1))
      if [ $((looks % 12)) = 0 ] && flag awake.lidSleepDisabled; then
        raw=$(/usr/bin/defaults read "$domain" awake.deadline 2>/dev/null)
        case $raw in ''|*[!0-9.]*) deadline= ;; *) deadline=${raw%%.*} ;; esac
        now=$(( $(/bin/date +%s) - ref ))
        if [ -n "$deadline" ] && [ "$now" -gt $((deadline + 120)) ]; then put_back; fi
      fi
    done
    /bin/sleep "$grace"
    /usr/bin/pgrep -x "$name" >/dev/null && exit 0
    if flag awake.lidSleepDisabled || flag awake.lowPowerOn; then
      put_back
      if /usr/bin/defaults read "$domain" awake.session >/dev/null 2>&1 && ! /usr/bin/defaults read "$domain" awake.pausedAt >/dev/null 2>&1; then
        /usr/bin/defaults write "$domain" awake.pausedAt -int $(( $(/bin/date +%s) - ref ))
      fi
    fi
    exit 0
    """#

    /// Started, once per run of Oyl.
    @MainActor
    static func start() {
        guard !started, let domain = Bundle.main.bundleIdentifier else { return }
        started = true
        run(pid: getpid(), domain: domain, name: ProcessInfo.processInfo.processName, sudo: "/usr/bin/sudo", grace: 60, tick: 5)
    }

    @discardableResult
    static func run(pid: pid_t, domain: String, name: String, sudo: String, grace: Double, tick: Double) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "oyl-watchdog", String(pid), domain, name, sudo, String(grace), String(tick)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        return process
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

    /// Whether the built-in screen's asleep (when what it reads is the idle dimming, not yours).
    static var isAsleep: Bool { display.map { CGDisplayIsAsleep($0) != 0 } ?? false }

    /// The screen woken, as a key pressed would.
    static func wake() {
        var id = IOPMAssertionID(0)
        _ = IOPMAssertionDeclareUserActivity("Oyl: the lid's open" as CFString, kIOPMUserActiveLocal, &id)
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
    /// What the power sources say of the Mac's own battery.
    enum Reading: Equatable {
        /// No battery (a desktop).
        case none
        case level(percent: Int, onBattery: Bool)
        /// There is one, but how full it is can't be read.
        case unreadable(onBattery: Bool)
    }

    static func read() -> (percent: Int, onBattery: Bool)? {
        if case .level(let percent, let onBattery) = status() { return (percent, onBattery) }
        return nil
    }

    static func status() -> Reading {
        var sources: [[String: Any]]?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            sources = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        }
        return reading(of: sources, hasBattery: hasBattery, charger: charger)
    }

    /// The power sources' descriptions (nil if they couldn't be listed) as a reading. With no
    /// battery among them, whether there's one in the Mac at all is asked of its driver, and if
    /// there is, whether the charger's in; a charger that can't be told counts as out, so the
    /// floor's still kept to (by stopping) rather than the battery left to run down unwatched.
    static func reading(of sources: [[String: Any]]?, hasBattery: () -> Bool, charger: () -> Bool?) -> Reading {
        for description in sources ?? [] where description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return .unreadable(onBattery: onBattery) }
            return .level(percent: current * 100 / maximum, onBattery: onBattery)
        }
        guard hasBattery() else { return .none }
        return .unreadable(onBattery: !(charger() ?? false))
    }

    /// Whether the Mac has a battery, from its driver rather than the power sources.
    private static func hasBattery() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    /// Whether the charger's in, from the battery's driver; nil if it can't be told.
    private static func charger() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }
}

/// The built-in keyboard's light, through the private CoreBrightness class the brightness keys
/// use. Setting the screen dark doesn't turn it off, and with sleep off macOS doesn't either as
/// the lid shuts. The class is only used if each method it needs is there and takes and gives
/// what it did on the macOS it was tried on (Insomnia's check, by the methods' type encodings), so
/// a changed one is left alone rather than called wrongly; then the light just isn't touched.
enum KeyboardLight {
    @objc private protocol Client: NSObjectProtocol {
        @objc(copyKeyboardBacklightIDs) func copyKeyboardBacklightIDs() -> NSArray?
        @objc(isKeyboardBuiltIn:) func isKeyboardBuiltIn(_ id: UInt64) -> Bool
        @objc(brightnessForKeyboard:) func brightness(forKeyboard id: UInt64) -> Float
        @objc(setBrightness:forKeyboard:) func setBrightness(_ value: Float, forKeyboard id: UInt64) -> Bool
        @objc(isBacklightSuppressedOnKeyboard:) func isBacklightSuppressed(onKeyboard id: UInt64) -> Bool
        @objc(isBacklightDimmedOnKeyboard:) func isBacklightDimmed(onKeyboard id: UInt64) -> Bool
    }

    /// Each method's type encoding (offsets left out), as it was on macOS 26.
    static let encodings: [String: String] = [
        "copyKeyboardBacklightIDs": "@@:",
        "isKeyboardBuiltIn:": "B@:Q",
        "brightnessForKeyboard:": "f@:Q",
        "setBrightness:forKeyboard:": "B@:fQ",
        "isBacklightSuppressedOnKeyboard:": "B@:Q",
        "isBacklightDimmedOnKeyboard:": "B@:Q",
    ]
    /// Those it can't do without (the other two, if gone, just read as no).
    static let required = ["copyKeyboardBacklightIDs", "isKeyboardBuiltIn:", "brightnessForKeyboard:", "setBrightness:forKeyboard:"]

    /// Whether a class whose methods' encodings are `encoding(name)` (nil: no such method) is fit to use.
    static func fits(_ encoding: (String) -> String?) -> Bool {
        encodings.allSatisfy { name, expected in
            guard let found = encoding(name) else { return !required.contains(name) }
            return found.filter { !$0.isNumber } == expected
        }
    }

    private static let client: Client? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type,
              fits({ name in
                  class_getInstanceMethod(type, NSSelectorFromString(name)).flatMap(method_getTypeEncoding).map { String(cString: $0) }
              }) else { return nil }
        return unsafeBitCast(type.init(), to: Client.self)
    }()

    private static var keyboards: [UInt64] {
        guard let client else { return [] }
        return ((client.copyKeyboardBacklightIDs() as? [NSNumber]) ?? []).map(\.uint64Value).filter(client.isKeyboardBuiltIn)
    }

    /// 0...1, or nil with no light (or no way to it).
    static var brightness: Float? {
        get {
            guard let client, let first = keyboards.first else { return nil }
            return client.brightness(forKeyboard: first)
        }
        set {
            guard let newValue, let client else { return }
            for id in keyboards { _ = client.setBrightness(min(max(newValue, 0), 1), forKeyboard: id) }
        }
    }

    /// macOS holding it down itself (asleep with the screen, or idle-dimmed): what it reads then
    /// isn't what you set.
    static var isHeldDown: Bool {
        guard let client, let first = keyboards.first else { return false }
        let suppressed = client.responds(to: NSSelectorFromString("isBacklightSuppressedOnKeyboard:"))
            && client.isBacklightSuppressed(onKeyboard: first)
        let dimmed = client.responds(to: NSSelectorFromString("isBacklightDimmedOnKeyboard:"))
            && client.isBacklightDimmed(onKeyboard: first)
        return suppressed || dimmed
    }
}

/// The Mac's own speakers (not headphones, AirPods or a display's), muted while it's kept awake
/// shut, as Insomnia does: a shut Mac's chimes and autoplaying videos stay quiet.
enum Speakers {
    /// The built-in output that's the speakers: one whose data source, where it has one, is the
    /// internal speaker (on Macs where headphones plugged in are the same device).
    static var device: AudioObjectID? {
        for id in outputs() where transport(of: id) == kAudioDeviceTransportTypeBuiltIn {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            if AudioObjectHasProperty(id, &address) {
                var source: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
                guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &source) == noErr,
                      source == 0x6973_706B else { continue }  // 'ispk'
            }
            return id
        }
        return nil
    }

    private static var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                                mElement: kAudioObjectPropertyElementMain)

    /// Whether they're muted, or nil (none, or no mute to them).
    static var isMuted: Bool? {
        guard let device, AudioObjectHasProperty(device, &muteAddress) else { return nil }
        var muted: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Every audio device with somewhere to play.
    private static func outputs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr && size > 0
        }
    }

    private static func transport(of id: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr ? transport : 0
    }
}
