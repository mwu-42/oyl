import AppKit
import ApplicationServices
import Combine
import SwiftUI
import os

// Four fingers up (or right Shift twice): your desktops and fullscreen apps in a list, in the order
// they're in, each by its name (a fullscreen app's by its app's, as the menu bar's label names them)
// with the icons of the apps on it. Click one to go straight to it (Option-click an app's icon on it to
// quit that app); right-click one to rename it; drag
// one onto another to group them, under a heading that folds them away (see `SpaceGroups`). (They
// can't be put in another order from here: macOS keeps that in the Dock, and short of turning System
// Integrity Protection off, only Mission Control can change it, by dragging.) macOS's own
// four-finger swipe up has to be off for four fingers up to be Oyl's: see `MissionControlSwipe`.

// MARK: - Four fingers on the trackpad

/// A four-finger swipe up or down, as `SwipeRecognizer` makes it out of the trackpad's frames.
enum DesktopSwipe: Equatable {
    /// Begun, upward or downward.
    case began(up: Bool)
    /// How far it's gone the way it began: 0 to 1 is the whole way (it can go past, or back).
    case moved(Double)
    /// Let go: how far it got, and how fast it was going the way it began (whole ways a second).
    case ended(Double, speed: Double)
    /// A fifth finger came down: not a swipe of these after all.
    case cancelled
}

/// Makes four-finger swipes up and down out of the trackpad's frames. Four fingers down, then
/// moving mostly up or down (across is the system's, between Spaces), and they're followed as they
/// go; it's over as soon as one lifts, and nothing more's made of them till they're all off; with
/// more down than that at any time, nothing's made of them either till they're all off (so the
/// three left as four lift unevenly are never a swipe of three). (Three are left to the system
/// but for two things: seeing Mission Control's swipe begin, and three down putting the
/// desktops' list away, as four down do.)
struct SwipeRecognizer {
    /// How many fingers (four for Oyl's own; three to see Mission Control's swipe begin, and three
    /// down to put the list away).
    static let fingers = 4
    let count: Int

    init(fingers: Int = Self.fingers) { count = fingers }
    /// How far up or down, of the trackpad's height, is the whole way.
    static let travel = 0.16
    /// How far they go before it's decided which way.
    static let deciding = 0.02

    private enum Phase {
        case idle
        case watching(x: Double, y: Double)
        case swiping(up: Bool, from: Double, last: Double, at: Double, speed: Double)
        /// Over, or not a swipe of these: till every finger's off.
        case done
    }

    private var phase = Phase.idle

    /// A frame: how many fingers are touching, where they are on average (0 to 1, from the lower
    /// left), and when it was, in seconds. What's come of it.
    mutating func frame(touching: Int, x: Double, y: Double, at time: Double) -> [DesktopSwipe] {
        switch phase {
        case .idle:
            if touching == count {
                phase = .watching(x: x, y: y)
            } else if touching > count {
                phase = .done
            }
            return []
        case .watching(let startX, let startY):
            guard touching == count else {
                phase = touching == 0 ? .idle : .done
                return []
            }
            let across = x - startX, up = y - startY
            guard hypot(across, up) >= Self.deciding else { return [] }
            guard abs(up) > 1.4 * abs(across) else {
                phase = .done
                return []
            }
            phase = .swiping(up: up > 0, from: startY, last: y, at: time, speed: 0)
            return [.began(up: up > 0), .moved(Self.progress(up: up > 0, from: startY, to: y))]
        case .swiping(let upward, let start, let last, let at, var speed):
            if touching > count {
                phase = .done
                return [.cancelled]
            }
            guard touching == count else {
                phase = touching == 0 ? .idle : .done
                return [.ended(Self.progress(up: upward, from: start, to: last), speed: speed)]
            }
            let step = time - at
            if step > 0.001 {
                let now = (y - last) / Self.travel * (upward ? 1 : -1) / step
                speed = speed * 0.5 + now * 0.5
            }
            phase = .swiping(up: upward, from: start, last: y, at: step > 0.001 ? time : at, speed: speed)
            return [.moved(Self.progress(up: upward, from: start, to: y))]
        case .done:
            if touching == 0 { phase = .idle }
            return []
        }
    }

    private static func progress(up: Bool, from start: Double, to now: Double) -> Double {
        (now - start) / travel * (up ? 1 : -1)
    }
}

/// The trackpads' fingers, read straight from them (Apple's private multitouch framework, as
/// BetterTouchTool and MiddleClick read it, looked up at run time: if it's ever gone, there are
/// just no swipes), for four-finger swipes up and down. Each frame, on the trackpad's own thread,
/// only how many fingers are touching and where they are on average is looked at; only what
/// comes of them is passed on, to the main thread.
final class Trackpads: @unchecked Sendable {
    static let shared = Trackpads()

    /// Told of each swipe.
    @MainActor var swiped: (DesktopSwipe) -> Void = { _ in }
    /// Told as three fingers begin up (Mission Control's swipe, which macOS answers itself).
    @MainActor var threeUp: () -> Void = {}
    /// Told of each three-finger swipe up or down (three down put the desktops' list away).
    @MainActor var swipedThree: (DesktopSwipe) -> Void = { _ in }

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void

    private static let framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        framework.flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: type) }
    }
    private static let createList = symbol("MTDeviceCreateList", as: CreateList.self)
    private static let register = symbol("MTRegisterContactFrameCallback", as: Register.self)
    private static let unregister = symbol("MTUnregisterContactFrameCallback", as: Register.self)
    private static let startDevice = symbol("MTDeviceStart", as: Start.self)
    private static let stopDevice = symbol("MTDeviceStop", as: Stop.self)

    /// Each finger's record in a frame, and where in it what's read is: its state (4 while it's
    /// touching), and where it is, 0 to 1 across and up.
    static let stride = 96
    static let stateOffset = 20, xOffset = 32, yOffset = 36
    static let touchingState: Int32 = 4

    /// Whether the framework's there to read them with.
    static var isAvailable: Bool {
        createList != nil && register != nil && unregister != nil && startDevice != nil && stopDevice != nil
    }

    private let lock = NSLock()
    private var list: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var recognizer = SwipeRecognizer()
    private var three = SwipeRecognizer(fingers: 3)

    /// Every trackpad read, from now (each one there is now; `restart` finds any since).
    @MainActor
    func start() {
        guard Self.isAvailable, let createList = Self.createList, let register = Self.register, let startDevice = Self.startDevice else { return }
        let running = lock.withLock { !devices.isEmpty }
        guard !running, let array = createList()?.takeRetainedValue() else { return }
        var found: [UnsafeMutableRawPointer] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let device = CFArrayGetValueAtIndex(array, index) else { continue }
            found.append(UnsafeMutableRawPointer(mutating: device))
        }
        lock.withLock {
            list = array
            devices = found
            recognizer = SwipeRecognizer()
            three = SwipeRecognizer(fingers: 3)
        }
        for device in found {
            register(device, Self.frame)
            startDevice(device, 0)
        }
    }

    /// No longer read.
    @MainActor
    func stop() {
        let (stopping, kept) = lock.withLock { () -> ([UnsafeMutableRawPointer], CFArray?) in
            defer {
                devices = []
                list = nil
            }
            return (devices, list)
        }
        if let unregister = Self.unregister, let stopDevice = Self.stopDevice {
            for device in stopping {
                unregister(device, Self.frame)
                stopDevice(device)
            }
        }
        withExtendedLifetime(kept) {}
    }

    /// Read afresh: after the Mac wakes (its trackpads stop sending), or a trackpad comes or goes.
    @MainActor
    func restart() {
        let running = lock.withLock { !devices.isEmpty }
        guard running else { return }
        stop()
        start()
    }

    private static let frame: Callback = { _, touches, count, time, _ in
        Trackpads.shared.read(touches, count: Int(count), at: time)
        return 0
    }

    private func read(_ touches: UnsafeMutableRawPointer?, count: Int, at time: Double) {
        var touching = 0, x = 0.0, y = 0.0
        if let touches, (1...20).contains(count) {
            for index in 0..<count {
                let touch = touches + index * Self.stride
                guard touch.loadUnaligned(fromByteOffset: Self.stateOffset, as: Int32.self) == Self.touchingState else { continue }
                let across = Double(touch.loadUnaligned(fromByteOffset: Self.xOffset, as: Float.self))
                let up = Double(touch.loadUnaligned(fromByteOffset: Self.yOffset, as: Float.self))
                // (Anything else isn't a reading of where it is.)
                guard (-0.25...1.25).contains(across), (-0.25...1.25).contains(up) else { continue }
                touching += 1
                x += across
                y += up
            }
        }
        if touching > 0 {
            x /= Double(touching)
            y /= Double(touching)
        }
        let (swipes, threes) = lock.withLock {
            (recognizer.frame(touching: touching, x: x, y: y, at: time), three.frame(touching: touching, x: x, y: y, at: time))
        }
        if !threes.isEmpty {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if threes.contains(.began(up: true)) { Trackpads.shared.threeUp() }
                    for swipe in threes { Trackpads.shared.swipedThree(swipe) }
                }
            }
        }
        guard !swipes.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { for swipe in swipes { Trackpads.shared.swiped(swipe) } }
        }
    }
}

/// Whether macOS takes four fingers up for Mission Control itself: while its swipe's on (it is
/// till it's turned off in System Settings › Trackpad › More Gestures), it does, whether it's set to
/// three fingers or four (picking three there turns on four as well). While it does, four fingers
/// up are left to it. Oyl can turn the four-finger one off on its own, leaving Mission Control on
/// three: a setting System Settings doesn't show (picking three fingers there again turns it back on).
enum MissionControlSwipe {
    private static let trackpads = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
    private static let fourFingers = "TrackpadFourFingerVertSwipeGesture"
    /// The same, as the Mac keeps it for itself.
    private static let fourFingersHere = "com.apple.trackpad.fourFingerVertSwipeGesture"
    /// Reapplies the trackpad's settings, as System Settings does, so they take hold now.
    private static let activateSettings = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"

    static func isTheSystems() -> Bool {
        for domain in ["com.apple.dock"] + trackpads { CFPreferencesAppSynchronize(domain as CFString) }
        let on = CFPreferencesCopyAppValue("showMissionControlGestureEnabled" as CFString, "com.apple.dock" as CFString) as? Bool ?? true
        return on && fourFingerSwipe() == 2
    }

    /// Whether Mission Control's on three fingers: so four can be had without it losing its swipe.
    static func isOnThreeFingers() -> Bool { TrackpadSettings.read().swipesUpAndDown }

    /// 2 while four fingers up and down are Mission Control's and App Exposé's, 0 while they're no one's.
    private static func fourFingerSwipe() -> Int {
        for domain in trackpads {
            if let value = CFPreferencesCopyAppValue(fourFingers as CFString, domain as CFString) as? Int { return value }
        }
        return 2
    }

    /// Four fingers up (and down) taken from Mission Control, which keeps three; or given back.
    static func setFourFingers(free: Bool) {
        let value = NSNumber(value: free ? 0 : 2)
        for domain in trackpads {
            CFPreferencesSetAppValue(fourFingers as CFString, value, domain as CFString)
            CFPreferencesAppSynchronize(domain as CFString)
        }
        CFPreferencesSetValue(fourFingersHere as CFString, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                              kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: activateSettings)
            process.arguments = ["-u"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
        }
    }

    /// Where it's turned off.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

/// Going to another Space: as many presses of Mission Control's "Move left a space" or "Move right
/// a space" as it takes, its shortcuts as they're set (⌃← and ⌃→ out of the box).
enum SpaceKeys {
    struct Shortcut: Equatable {
        let key: CGKeyCode
        let flags: CGEventFlags
    }

    static let leftID = "79", rightID = "81"
    static let left = Shortcut(key: 123, flags: [.maskControl, .maskSecondaryFn])
    static let right = Shortcut(key: 124, flags: [.maskControl, .maskSecondaryFn])

    /// The shortcut, as `hotkeys` (the symbolic hotkeys' own list) has it; the usual, if it isn't
    /// there or says nothing; nil, if it's turned off.
    static func shortcut(_ id: String, in hotkeys: [String: Any]?, usual: Shortcut) -> Shortcut? {
        guard let entry = hotkeys?[id] as? [String: Any] else { return usual }
        if let enabled = entry["enabled"] as? Bool, !enabled { return nil }
        guard let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber], parameters.count == 3,
              parameters[1].intValue != 65535 else { return usual }
        return Shortcut(key: CGKeyCode(parameters[1].intValue), flags: CGEventFlags(rawValue: parameters[2].uint64Value))
    }

    static func hotkeys() -> [String: Any]? {
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        return CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
    }

    /// `steps` Spaces on (to the right), or back (to the left). False if the shortcut's turned off.
    @discardableResult
    static func go(_ steps: Int) -> Bool {
        guard steps != 0 else { return true }
        let hotkeys = hotkeys()
        guard let shortcut = steps > 0 ? shortcut(rightID, in: hotkeys, usual: right) : shortcut(leftID, in: hotkeys, usual: left) else {
            return false
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let source = CGEventSource(stateID: .hidSystemState)
            for step in 0..<abs(steps) {
                if step > 0 { Thread.sleep(forTimeInterval: 0.03) }
                Keystroke.post(shortcut.key, flags: shortcut.flags, source: source)
            }
        }
        return true
    }
}

// MARK: - Which apps are on which desktop

/// The apps with windows on each Space, as the window server has them: every app's ordinary
/// windows (not Oyl's, nor anything's that isn't an app in the Dock), each on the Space it's on. A
/// window on every Space is no one Space's.
enum SpaceApps {
    struct Window: Equatable {
        let pid: pid_t
        let spaces: [Int]
    }

    /// Each Space's apps, by its number, in the order their windows come (front first), each once.
    static func group(_ windows: [Window]) -> [Int: [pid_t]] {
        var apps: [Int: [pid_t]] = [:]
        for window in windows where window.spaces.count == 1 {
            let space = window.spaces[0]
            if apps[space]?.contains(window.pid) != true { apps[space, default: []].append(window.pid) }
        }
        return apps
    }

    private typealias ConnectionID = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    private static let connection = dlsym(defaultHandle, "CGSMainConnectionID").map { unsafeBitCast($0, to: ConnectionID.self) }
    private static let copySpaces = dlsym(defaultHandle, "CGSCopySpacesForWindows").map { unsafeBitCast($0, to: CopySpaces.self) }
    /// The Space showing, the others, and the user's: all of them.
    private static let everySpace: Int32 = 7

    /// Each of `pid`'s ordinary windows: its number, its title (if the window server says, as it does
    /// with Screen Recording allowed), and the Spaces it's on. Off the main thread.
    static func windows(of pid: pid_t) -> [(number: CGWindowID, title: String?, spaces: [Int])] {
        guard let connection, let copySpaces else { return [] }
        let id = connection()
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0, info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let box = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: box as CFDictionary), frame.width >= 50, frame.height >= 50 else { return nil }
            let spaces = copySpaces(id, everySpace, [NSNumber(value: number)] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []
            return (number, info[kCGWindowName as String] as? String, spaces.map(\.intValue))
        }
    }

    /// The Spaces window `number` is on.
    static func spaces(ofWindow number: CGWindowID) -> [Int] {
        guard let connection, let copySpaces else { return [] }
        return (copySpaces(connection(), everySpace, [NSNumber(value: number)] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []).map(\.intValue)
    }

    /// As they are now (a few milliseconds: off the main thread).
    static func read() -> [Int: [pid_t]] {
        guard let connection, let copySpaces else { return [:] }
        let id = connection(), own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var isApp: [pid_t: Bool] = [:]
        let windows = list.compactMap { info -> Window? in
            guard info[kCGWindowLayer as String] as? Int == 0, let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let box = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: box as CFDictionary), frame.width >= 50, frame.height >= 50 else { return nil }
            if isApp[pid] == nil { isApp[pid] = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular }
            guard isApp[pid] == true else { return nil }
            let spaces = copySpaces(id, everySpace, [NSNumber(value: number)] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []
            return Window(pid: pid, spaces: spaces.map(\.intValue))
        }
        return group(windows)
    }
}

// MARK: - Going straight to a Space

/// Going to another Space at once, with no slide: each step a swipe across, as the trackpad's own
/// comes to the Dock, posted so fast it's over before it's begun (as InstantSpaceSwitcher does on
/// macOS 26). Where that can't be (macOS 27 wants more of it; or Accessibility isn't allowed), or
/// it hasn't got there a moment later, Mission Control's move-a-space shortcuts take it the rest of
/// the way. If the swipes ever go the wrong way, that's remembered, and they go the other way after.
enum InstantSpaces {
    static let backwardKey = "desktops.swipesBackward"

    /// Whether this Mac's Dock takes them.
    static var canSwipe: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion <= 26 && AXIsProcessTrusted() }

    /// From the Space at `from` to the one at `to`, on `screen`.
    @MainActor
    static func go(from: Int, to target: Int, on screen: NSScreen) {
        let steps = target - from
        guard steps != 0 else { return }
        guard canSwipe else {
            if !SpaceKeys.go(steps) { NSSound.beep() }
            return
        }
        let backward = UserDefaults.standard.bool(forKey: backwardKey)
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<abs(steps) { swipe(right: (steps > 0) != backward, velocity: 2000 * Double(abs(steps))) }
        }
        // Got there? If not, the rest of the way by the shortcuts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard let display = FullscreenSpace.display(for: screen),
                  let now = Spaces.all(in: display, boot: Spaces.bootTime, appName: { _ in nil }).current, now != target else { return }
            if now != from, (now - from).signum() != steps.signum() { UserDefaults.standard.set(!backward, forKey: backwardKey) }
            if !SpaceKeys.go(target - now) { NSSound.beep() }
        }
    }

    /// One swipe across, began, moved and ended, toward the Space on the right (or the left).
    private static func swipe(right: Bool, velocity: Double) {
        let sign: Double = right ? 1 : -1
        for phase: Int64 in [1, 2, 4] {
            guard let event = CGEvent(source: nil) else { continue }
            event.setIntegerValueField(field(55), value: 30)  // the Dock's own event
            event.setIntegerValueField(field(110), value: 23)  // a dock swipe
            event.setIntegerValueField(field(132), value: phase)
            event.setDoubleValueField(field(124), value: sign * 0.000016)  // how far it's gone
            event.setIntegerValueField(field(123), value: 1)  // across
            event.setDoubleValueField(field(129), value: sign * velocity)
            event.setDoubleValueField(field(130), value: sign * velocity)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private static func field(_ number: UInt32) -> CGEventField { unsafeBitCast(number, to: CGEventField.self) }
}

// MARK: - Groups

/// The groups you've put desktops in, kept in the defaults: each its name, whether it's folded,
/// and its desktops, by what their names are kept under (a fullscreen app's by its window too, so
/// it's still in when it leaves fullscreen and comes back, a new Space each time). They're only
/// this list's: the Spaces stay in macOS's own order, which only Mission Control can change.
struct SpaceGroups {
    static let key = "spaces.groups"
    /// The most desktops kept in them: past that, fullscreen apps' windows' go first (they're the
    /// ones that don't last).
    static let most = 300

    struct Group: Equatable {
        let id: String
        var name: String
        var folded: Bool
        var members: [String]
    }

    var defaults = UserDefaults.standard

    var all: [Group] {
        (defaults.array(forKey: Self.key) as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else { return nil }
            return Group(id: id, name: name, folded: entry["folded"] as? Bool ?? false, members: entry["members"] as? [String] ?? [])
        }
    }

    private func save(_ groups: [Group]) {
        var groups = groups.filter { !$0.members.isEmpty }
        // Too many kept: the oldest fullscreen windows' let go of.
        var over = groups.reduce(0) { $0 + $1.members.count } - Self.most
        for index in groups.indices where over > 0 {
            let windows = groups[index].members.filter { $0.hasPrefix("window:") }.prefix(over)
            groups[index].members.removeAll { windows.contains($0) }
            over -= windows.count
        }
        groups = groups.filter { !$0.members.isEmpty }
        defaults.set(groups.map { ["id": $0.id, "name": $0.name, "folded": $0.folded, "members": $0.members] as [String: Any] }, forKey: Self.key)
    }

    /// What a Space is kept under: its own, and a fullscreen app's window's.
    static func keys(of space: CurrentSpace) -> [String] { [space.key] + (space.window.map { [$0] } ?? []) }

    /// The group `space` is in, among `groups`.
    static func group(of space: CurrentSpace, in groups: [Group]) -> Group? {
        let keys = Self.keys(of: space)
        return groups.first { $0.members.contains(where: keys.contains) }
    }

    /// A new group of `space` and `other` (each out of any it was in), called "group" (or "group
    /// 2", and so on, if that's taken): its id.
    @discardableResult
    func make(_ space: CurrentSpace, with other: CurrentSpace) -> String { make([other, space]) }

    /// A new group of `spaces` (each out of any it was in), named as above: its id.
    @discardableResult
    func make(_ spaces: [CurrentSpace]) -> String {
        var groups = Self.without(spaces, in: all)
        let names = Set(groups.map { $0.name.lowercased() })
        let name = names.contains("group") ? (2...).lazy.map { "group \($0)" }.first { !names.contains($0) }! : "group"
        let id = UUID().uuidString
        groups.append(Group(id: id, name: name, folded: false, members: spaces.flatMap(Self.keys)))
        save(groups)
        return id
    }

    /// `space` put in the group `id` (out of any other).
    func put(_ space: CurrentSpace, in id: String) {
        var groups = Self.without([space], in: all)
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].members += Self.keys(of: space)
        save(groups)
    }

    /// `space` on its own again.
    func takeOut(_ space: CurrentSpace) { save(Self.without([space], in: all)) }

    /// The group `id` done away with, its desktops on their own again.
    func ungroup(_ id: String) { save(all.filter { $0.id != id }) }

    func rename(_ id: String, to name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SpaceNames.longest))
        guard !name.isEmpty else { return }
        save(all.map { group in
            var group = group
            if group.id == id { group.name = name }
            return group
        })
    }

    func fold(_ id: String, _ folded: Bool) {
        save(all.map { group in
            var group = group
            if group.id == id { group.folded = folded }
            return group
        })
    }

    /// Whether `group`'s desktops are now all one: every desktop of it there still is (by what it
    /// was kept under) made part of one fullscreen Space of several (`combined`, each such Space's
    /// keys: its own, each window's, and the Spaces they came from), at least two of them.
    nonisolated static func isCombined(_ group: Group, into combined: [Set<String>], present: Set<String>) -> Bool {
        combined.contains { together in
            let inside = group.members.filter { together.contains($0) }
            // What's in no Space now (a window's from before a restart) doesn't count against it.
            let elsewhere = group.members.filter { !together.contains($0) && present.contains($0) }
            return elsewhere.isEmpty && inside.count >= 2
        }
    }

    /// Groups whose desktops have all been combined into one fullscreen Space: done away with (a
    /// group of one isn't one). Their ids.
    @discardableResult
    func dissolveCombined(_ combined: [Set<String>], present: Set<String>) -> [String] {
        let groups = all
        let gone = groups.filter { Self.isCombined($0, into: combined, present: present) }.map(\.id)
        if !gone.isEmpty { save(groups.filter { !gone.contains($0.id) }) }
        return gone
    }

    /// The groups looked over on every screen, and any that's been combined into one done away
    /// with (as desktops are put together in Mission Control, or a window's tiled into another's).
    @MainActor
    static func tidy() {
        let store = SpaceGroups()
        guard !store.all.isEmpty else { return }
        var combined: [Set<String>] = [], present = Set<String>()
        for screen in NSScreen.screens {
            guard let display = FullscreenSpace.display(for: screen) else { continue }
            let all = Spaces.all(in: display, boot: Spaces.bootTime) { NSRunningApplication(processIdentifier: $0)?.localizedName }
            for space in all.spaces { present.formUnion(keys(of: space)) }
            combined += Spaces.combined(in: display, boot: Spaces.bootTime)
        }
        for together in combined { present.formUnion(together) }
        store.dissolveCombined(combined, present: present)
    }

    private static func without(_ spaces: [CurrentSpace], in groups: [Group]) -> [Group] {
        let keys = Set(spaces.flatMap(Self.keys))
        return groups.map { group in
            var group = group
            group.members.removeAll { keys.contains($0) }
            return group
        }
    }
}

// MARK: - What's shown

@MainActor
final class DesktopsModel: ObservableObject {
    struct App: Identifiable, Equatable {
        let id: pid_t
        let name: String
        let icon: NSImage?
        /// Whether Option-clicking it quits it (never Oyl, or the Finder: see `canQuit`).
        var quittable = true
    }

    struct Desk: Identifiable, Equatable {
        /// What its name's kept under (see `CurrentSpace.key`).
        let id: String
        var name: String
        /// What it's called by itself: "desktop 2", or a fullscreen app's name.
        let standard: String
        let isFullscreen: Bool
        let isCurrent: Bool
        /// Front first; a fullscreen app's own first of all.
        var apps: [App] = []
        /// The group it's in (see `SpaceGroups`), if any.
        var group: String?

        /// A desktop still called by its number: what's on it says more, so its apps are named too.
        var namesApps: Bool { !isFullscreen && name == standard && !apps.isEmpty }
    }

    /// Desktops put together under a name, in this list only (macOS keeps them in its own order).
    struct Group: Identifiable, Equatable {
        /// What it's kept under (see `SpaceGroups`).
        let id: String
        var name: String
        /// Just its heading shown, its desktops tucked away under it.
        var folded: Bool
    }

    /// A line of the list: a group's heading (with the desktops in it), or a desktop.
    enum Item: Identifiable, Equatable {
        case heading(Group, desks: [Desk])
        case desk(Desk, grouped: Bool)

        var id: String {
            switch self {
            case .heading(let group, _): return DesktopsModel.headingID(group.id)
            case .desk(let desk, _): return desk.id
            }
        }
    }

    /// What a heading's known by in the list (picked, renamed), apart from the desktops.
    nonisolated static func headingID(_ group: String) -> String { "group:" + group }

    /// What letting go of a desktop being dragged does.
    enum Regroup: Equatable {
        /// Put in a new group with the one it's let go on.
        case with(desk: String, other: String)
        /// Put in a group (let go on its heading, or on a desktop in it).
        case into(desk: String, group: String)
        /// Taken out of its group (let go off the list).
        case out(desk: String)
        /// A group done away with, its desktops back on their own.
        case ungroup(group: String)
        /// A new group of these (shift-clicked from one to another), each out of any it was in.
        case gather(desks: [String])
    }

    /// How far up it's come: 0 is gone, 1 all the way up.
    @Published var progress: Double = 0
    /// Following the fingers (so no easing), rather than settling.
    @Published var interactive = true
    /// In the Spaces' own order.
    @Published var desks: [Desk] = []
    /// Every group there is (some may have none of these desktops in them).
    @Published var groups: [Group] = []
    @Published var size = CGSize(width: 1440, height: 900)
    @Published var theme = NotchTheme.standard
    @Published var hovered: String?
    /// Picked with the arrow keys.
    @Published var selected: String?
    /// Being renamed, and what's been typed.
    @Published var renaming: String?
    @Published var draft = ""
    /// The desktop being dragged, and where the pointer is, in the list (see `DesktopsRows.space`).
    @Published var dragging: String?
    @Published var dragShift = CGSize.zero
    @Published var dragAt: CGPoint?
    /// A drag's just ended: the click that ends it isn't a pick.
    var justDragged = false
    /// Where each line is in the window (top-left first), as last laid out: for what's under a
    /// right-click, which needn't have been pointed at first.
    var lineFrames: [String: CGRect] = [:]

    /// The line at `point` in the window (top-left first), if one's there.
    func line(at point: CGPoint) -> String? {
        let shown = Set(items.map(\.id))
        return lineFrames.first { shown.contains($0.key) && $0.value.contains(point) }?.key
    }
    /// The desktop whose sound's being picked (see `DeskSoundPicker`), while sounds are on.
    @Published var picking: String?
    /// Whether a desktop's sound can be picked here (sounds are on).
    @Published var picksSounds = false
    /// The time over the list (with it on).
    @Published var showsClock = true
    /// Midnight's sky: which of its stars are joined into constellations this time (new each time
    /// the list comes up, see `DesktopsSky`), and when it came up, for them to be drawn in from.
    @Published var sky = DesktopsSky.Opening(seed: 7, at: .distantPast)
    /// The desktops a sound's just come from (see `DeskChimes`): which, and when.
    @Published var rang: [String: DeskChimes.Rang] = [:]

    /// When the newest of them came.
    var newestRang: Date? { rang.values.map(\.at).max() }

    /// How many agents are at work on each desktop (by its key), as their windows (or, for a
    /// Claude, where it was last seen) say.
    @Published var atWork: [String: Int] = [:]

    /// A group's, folded: how many are at work on its desktops.
    func atWork(inGroup id: String) -> Int {
        desks.filter { $0.group == id }.reduce(0) { $0 + (atWork[$1.id] ?? 0) }
    }

    /// A group's, folded: the latest of its desktops'.
    func rang(inGroup id: String) -> DeskChimes.Rang? {
        desks.filter { $0.group == id }.compactMap { rang[$0.id] }.max { $0.at < $1.at }
    }

    /// Each desktop's own sound's name, for its row.
    @Published var soundNames: [String: String] = [:]
    var soundChoices: () -> [ChimeVoice] = { [] }
    var soundOf: (String) -> ChimeVoice? = { _ in nil }
    var chooseSound: (String, ChimeVoice?) -> Void = { _, _ in }
    var hearSound: (ChimeVoice) -> Void = { _ in }
    /// What a desktop with none of its own sounds like: its app's, or everywhere else's.
    var fallbackSound: String = ChimeVoice.round.name

    /// Shift-clicked first: where what's grouped begins, once another's shift-clicked.
    @Published var anchor: String?

    /// Option's held: an app's icon clicked quits it, and each that can be is marked so.
    @Published var optionHeld = false

    /// How many desktops `app` has windows on (quitting it closes them all).
    func desktops(with app: pid_t) -> Int { desks.filter { $0.apps.contains { $0.id == app } }.count }

    /// "Quit Safari", or with it on more than one desktop, "Quit Code (on 3 desktops)".
    nonisolated static func quitSays(_ name: String, desktops: Int) -> String {
        "Quit \(name)" + (desktops > 1 ? " (on \(desktops) desktops)" : "")
    }

    /// Whether an app can be quit from here: never Oyl itself, or the Finder.
    nonisolated static func canQuit(_ pid: pid_t, bundle: String?) -> Bool {
        pid != ProcessInfo.processInfo.processIdentifier && bundle != "com.apple.finder"
    }

    var pick: (Desk) -> Void = { _ in }
    var quit: (App) -> Void = { _ in }
    var renamed: (Desk, String) -> Void = { _, _ in }
    var renamedGroup: (String, String) -> Void = { _, _ in }
    var regroup: (Regroup) -> Void = { _ in }
    var folded: (String, Bool) -> Void = { _, _ in }
    var dismiss: () -> Void = {}

    /// The list's lines: the desktops in the Spaces' order, each group's together under its
    /// heading where the first of them comes (folded, the heading alone).
    var items: [Item] { Self.arrange(desks, groups: groups) }

    nonisolated static func arrange(_ desks: [Desk], groups: [Group]) -> [Item] {
        let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<String>(), items: [Item] = []
        for desk in desks {
            guard let id = desk.group, let group = byId[id] else {
                items.append(.desk(desk, grouped: false))
                continue
            }
            guard placed.insert(id).inserted else { continue }
            let members = desks.filter { $0.group == id }
            items.append(.heading(group, desks: members))
            if !group.folded { items += members.map { .desk($0, grouped: true) } }
        }
        return items
    }

    /// How wide the list is, in this look.
    var listWidth: CGFloat { theme == .midnight ? 470 : 368 }

    /// How long it takes to settle, in this look: Oyl's a plain ease, Midnight's a slow drift.
    var settleTime: Double { theme == .midnight ? 0.55 : 0.26 }

    func settle(delay: Double = 0) -> Animation? {
        guard !interactive else { return nil }
        return theme == .midnight ? .timingCurve(0.45, 0, 0.25, 1, duration: settleTime).delay(delay)
            : .easeOut(duration: settleTime).delay(delay)
    }

    /// The row picked with the arrows changing.
    var shuffle: Animation { theme == .midnight ? .timingCurve(0.45, 0, 0.25, 1, duration: 0.42) : .easeOut(duration: 0.18) }

    /// A row's height, in this look, with room for them all on the screen.
    var rowHeight: CGFloat { rowHeight(for: items.count) }

    func rowHeight(for count: Int) -> CGFloat {
        let usual: CGFloat = theme == .midnight ? 38 : 30
        return min(usual, max(22, size.height * 0.62 / CGFloat(max(count, 1))))
    }

    // MARK: The keyboard

    /// The next or last line picked (the one you're on, to begin with: its group's heading, if
    /// it's folded away).
    func select(by step: Int) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        let picked = selected.flatMap { ids.firstIndex(of: $0) }
        let current = desks.first(where: \.isCurrent)
        let at = picked ?? current.flatMap { desk in
            ids.firstIndex(of: desk.id) ?? desk.group.flatMap { ids.firstIndex(of: Self.headingID($0)) }
        } ?? 0
        selected = ids[min(max(at + (picked == nil ? 0 : step), 0), ids.count - 1)]
    }

    /// The group picked (its heading, or a desktop in it), if one is.
    var selectedGroup: Group? {
        guard let selected else { return nil }
        if let group = groups.first(where: { Self.headingID($0.id) == selected }) { return group }
        return items.lazy.compactMap { item -> Group? in
            guard case .desk(let desk, true) = item, desk.id == selected else { return nil }
            return self.groups.first { $0.id == desk.group }
        }.first
    }

    // MARK: Groups

    /// Whether a group's desktops aren't next to each other in macOS's own order (as Mission
    /// Control has them), so they can be dragged together there.
    func isSplit(_ group: String) -> Bool {
        let at = desks.indices.filter { desks[$0].group == group }
        guard let first = at.first, let last = at.last else { return false }
        return last - first + 1 != at.count
    }

    /// A group folded away under its heading, or opened out. A desktop picked in it, the heading's
    /// picked instead.
    func fold(_ id: String, _ folding: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].folded != folding else { return }
        if folding, let selected, desks.contains(where: { $0.id == selected && $0.group == id }) { self.selected = Self.headingID(id) }
        groups[index].folded = folding
        folded(id, folding)
    }

    /// What letting go of the one being dragged would do, where the pointer is now.
    var dropping: Regroup? {
        guard let dragging, let at = dragAt, let desk = desks.first(where: { $0.id == dragging }) else { return nil }
        return Self.drop(desk, at: at, items: items, rowHeight: rowHeight, width: listWidth)
    }

    /// Let go at `point` (in the list): on a heading, into that group; on a desktop in a group, into
    /// it too; on one on its own, a new group of the two; off the list, out of its group. Nothing
    /// if it's let go on itself, or where it already is.
    /// Let go between two lines (near the edge of one, rather than on it), as if putting it in
    /// another place: inside another group's run, into it; anywhere outside its own group's, out of
    /// it; inside its own, where it is.
    nonisolated static func drop(_ desk: Desk, at point: CGPoint, items: [Item], rowHeight: CGFloat, width: CGFloat) -> Regroup? {
        let across = point.x > -24 && point.x < width + 24
        let rows = point.y / max(rowHeight, 1)
        if across, rows > -0.5, rows < CGFloat(items.count) + 0.5, let gap = gap(at: point, items: items, rowHeight: rowHeight) {
            if let group = group(at: gap, in: items) { return desk.group == group ? nil : .into(desk: desk.id, group: group) }
            return isGrouped(desk, in: items) ? .out(desk: desk.id) : nil
        }
        let index = Int(rows.rounded(.down))
        let onList = across && items.indices.contains(index)
        switch onList ? items[index] : nil {
        case .heading(let group, _)?:
            return desk.group == group.id ? nil : .into(desk: desk.id, group: group.id)
        case .desk(let other, let grouped)?:
            guard other.id != desk.id else { return nil }
            if grouped, let group = other.group { return desk.group == group ? nil : .into(desk: desk.id, group: group) }
            return .with(desk: desk.id, other: other.id)
        case nil:
            return isGrouped(desk, in: items) ? .out(desk: desk.id) : nil
        }
    }

    nonisolated static func isGrouped(_ desk: Desk, in items: [Item]) -> Bool {
        items.contains { if case .heading(_, let members) = $0 { return members.contains { $0.id == desk.id } } else { return false } }
    }

    /// The gap between lines `point` is in (0 over the first, `items.count` under the last), if it's
    /// near a line's edge rather than on it.
    nonisolated static func gap(at point: CGPoint, items: [Item], rowHeight: CGFloat) -> Int? {
        let rows = point.y / max(rowHeight, 1)
        if rows < 0 { return 0 }
        let index = Int(rows.rounded(.down)), part = rows - CGFloat(index)
        if index >= items.count { return items.count }
        if part < 0.25 { return index }
        if part > 0.75 { return index + 1 }
        return nil
    }

    /// The group whose run the gap's inside (under its heading or between two of its desktops).
    nonisolated static func group(at gap: Int, in items: [Item]) -> String? {
        guard gap > 0, gap < items.count, case .desk(let below, true) = items[gap], let group = below.group else { return nil }
        switch items[gap - 1] {
        case .heading(let heading, _): return heading.id == group ? group : nil
        case .desk(let above, true): return above.group == group ? group : nil
        default: return nil
        }
    }

    /// The gap a line's drawn in while one's dragged there, as it'd be put there (out of its group,
    /// or into another's run).
    var dropGap: Int? {
        guard let dragging, let at = dragAt, desks.contains(where: { $0.id == dragging }), dropping != nil,
              at.x > -24, at.x < listWidth + 24 else { return nil }
        let rows = at.y / max(rowHeight, 1)
        guard rows > -0.5, rows < CGFloat(items.count) + 0.5 else { return nil }
        return Self.gap(at: at, items: items, rowHeight: rowHeight)
    }

    /// The line letting go would put it with (lit while it's dragged over).
    var dropTarget: String? {
        switch dropping {
        case .with(_, let other)?: return other
        case .into(_, let group)?: return Self.headingID(group)
        default: return nil
        }
    }

    /// What letting go would do, said under the list while dragging; what a shift-click would
    /// group, once one's been shift-clicked; and how to group, before there are any groups.
    var dropHint: String? {
        func named(_ id: String) -> String { groups.first { $0.id == id }?.name ?? "the group" }
        guard let dragging else {
            if anchor != nil {
                let count = spannedDesks.count
                return count > 1 ? "shift-click to group these \(count)" : "shift-click another to group everything between"
            }
            return groups.isEmpty || !desks.contains(where: { $0.group != nil }) ? "drag one onto another, or shift-click two, to group them" : nil
        }
        switch dropping {
        case .with(_, let other)?: return "let go to group it with “\(desks.first { $0.id == other }?.name ?? "that one")”"
        case .into(_, let group)?: return "let go to put it in “\(named(group))”"
        case .out?:
            let from = desks.first { $0.id == dragging }?.group.map(named) ?? "its group"
            return "let go to take it out of “\(from)”"
        default: return desks.first(where: { $0.id == dragging })?.group == nil ? "onto another to group them" : "off the list to take it out"
        }
    }

    // MARK: Shift-clicking

    /// The lines from `from` to `to`, either way round, in the list's order.
    nonisolated static func lines(from: String, to: String, in items: [Item]) -> ArraySlice<Item> {
        guard let a = items.firstIndex(where: { $0.id == from }), let b = items.firstIndex(where: { $0.id == to }) else { return [] }
        return items[min(a, b)...max(a, b)]
    }

    /// The desktops on those lines, in order: a heading among them brings all of its own.
    nonisolated static func span(from: String, to: String, in items: [Item]) -> [Desk] {
        var seen = Set<String>(), desks: [Desk] = []
        for item in lines(from: from, to: to, in: items) {
            switch item {
            case .heading(_, let members): desks += members.filter { seen.insert($0.id).inserted }
            case .desk(let desk, _): if seen.insert(desk.id).inserted { desks.append(desk) }
            }
        }
        return desks
    }

    /// The lines lit as what a shift-click on the one pointed at would group (just the one
    /// shift-clicked, till another's pointed at).
    var spanned: Set<String> {
        guard let anchor, dragging == nil else { return [] }
        guard let hovered, hovered != anchor else { return [anchor] }
        let lines = Self.lines(from: anchor, to: hovered, in: items).map(\.id)
        return lines.isEmpty ? [anchor] : Set(lines)
    }

    private var spannedDesks: [Desk] {
        guard let anchor, let hovered, hovered != anchor else { return [] }
        return Self.span(from: anchor, to: hovered, in: items)
    }

    /// Shift-clicked: the first marks where it begins; the next makes a group of everything
    /// between them (named straight away), unless that's a group already, just as it is. The
    /// same one again: not marked any more.
    func shiftClicked(_ id: String) {
        guard let anchor else {
            finishRenaming(keeping: true)
            self.anchor = id
            selected = id
            return
        }
        self.anchor = nil
        let desks = Self.span(from: anchor, to: id, in: items)
        guard anchor != id, desks.count > 1 else { return }
        let ids = Set(desks.map(\.id))
        if let group = desks[0].group, desks.allSatisfy({ $0.group == group }),
           !self.desks.contains(where: { $0.group == group && !ids.contains($0.id) }) { return }
        selected = nil
        regroup(.gather(desks: desks.map(\.id)))
    }

    // MARK: Dragging

    /// Done dragging: what letting go there does, done.
    func drop() {
        let change = dropping
        dragging = nil
        dragShift = .zero
        dragAt = nil
        if let change { regroup(change) }
    }

    // MARK: Renaming

    func startRenaming(_ desk: Desk) {
        draft = desk.name
        renaming = desk.id
    }

    func startRenaming(group id: String) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        draft = group.name
        renaming = Self.headingID(id)
    }

    /// Right-clicked on a line (`id`, the one pointed at): a desktop's or a group's name, to
    /// type over. Whether there was one to rename.
    @discardableResult
    func renameLine(_ id: String?) -> Bool {
        guard let id, dragging == nil else { return false }
        if renaming == id { return true }
        finishRenaming(keeping: true)
        anchor = nil
        if let desk = desks.first(where: { $0.id == id }) {
            startRenaming(desk)
        } else if let group = groups.first(where: { Self.headingID($0.id) == id }) {
            startRenaming(group: group.id)
        } else {
            return false
        }
        return true
    }

    /// Done typing: what's been typed kept (`keeping`), or not. A group's left as it was if
    /// nothing's typed.
    func finishRenaming(keeping: Bool) {
        guard let id = renaming else { return }
        renaming = nil
        guard keeping else { return }
        if let desk = desks.first(where: { $0.id == id }) {
            if draft != desk.name { renamed(desk, draft) }
        } else if let index = groups.firstIndex(where: { Self.headingID($0.id) == id }) {
            let name = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SpaceNames.longest))
            guard !name.isEmpty, name != groups[index].name else { return }
            groups[index].name = name
            renamedGroup(groups[index].id, name)
        }
    }
}

/// The desktops, in a list. In Oyl's look it's a plain black card in the middle of the screen, a
/// little way down, each row a name (the one you're on in bold, with a dot), the names of the apps
/// on a desktop still called by its number, and their icons; a row pointed at is lit (right-click it
/// to rename it); a group's heading a small bold name after a chevron, its desktops in under it. In
/// Midnight Oyl's the
/// screen goes to night (stars twinkling over ink), and the list's set off to the left, with no
/// title, the names in Superclarendon strung down a line of stars that bows out and
/// back, the one you're on lit by a glint; they drift in one after another out of a blur, and a
/// group's heading is a little constellation, its desktops further along the line.
struct DesktopsView: View {
    @ObservedObject var model: DesktopsModel

    var body: some View {
        let midnight = model.theme == .midnight
        ZStack(alignment: .topLeading) {
            veil(midnight: midnight)
                .opacity(min(max(model.progress, 0), 1))
                .animation(model.settle(), value: model.progress)
                .contentShape(Rectangle())
                .onTapGesture { model.dismiss() }
            if midnight { MidnightDesks(model: model) } else { PlainDesks(model: model) }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
        .environment(\.notchTheme, model.theme)
    }

    @ViewBuilder private func veil(midnight: Bool) -> some View {
        if midnight {
            ZStack {
                Midnight.ink.opacity(0.9)
                // Moonlight off to the upper right, as the band's sky has it.
                RadialGradient(colors: [Midnight.moonlight.opacity(0.09), .clear], center: UnitPoint(x: 0.78, y: 0.05), startRadius: 0,
                               endRadius: model.size.width * 0.6)
                DesktopsStars(size: model.size, opening: model.sky)
            }
        } else {
            Color.black.opacity(0.28)
        }
    }
}

/// Oyl's: the card, rising a little into place as it fades in.
private struct PlainDesks: View {
    @ObservedObject var model: DesktopsModel
    static let width: CGFloat = 380

    var body: some View {
        let shown = min(max(model.progress, 0), 1)
        VStack(spacing: 18) {
            // The time over it, the card where it always is.
            if model.showsClock { DesksClock() }
            card
        }
        .opacity(shown)
        .offset(y: (1 - shown) * 16)
        .animation(model.settle(), value: model.progress)
        .frame(width: model.size.width, alignment: .top)
        .padding(.top, max(model.size.height * 0.24 - (model.showsClock ? DesksClock.plainHeight + 18 : 0), 24))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            DesktopsRows(model: model)
            DesksHint(model: model)
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.84)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.09)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        // A desktop's sound being picked: beside the card.
        .overlay(alignment: .topTrailing) {
            if model.picking != nil {
                DeskSoundPicker(model: model)
                    .offset(x: DeskSoundPicker.width + 12)
                    .transition(.opacity)
            }
        }
    }
}

/// Midnight's: off to the left of the middle, the time over it, and no title.
private struct MidnightDesks: View {
    @ObservedObject var model: DesktopsModel

    var body: some View {
        let shown = min(max(model.progress, 0), 1)
        VStack(alignment: .leading, spacing: 16) {
            if model.showsClock {
                DesksClock()
                    .opacity(shown)
                    .offset(x: -(1 - shown) * 44)
                    .blur(radius: (1 - shown) * 6)
                    .animation(model.settle(delay: 0.05), value: model.progress)
                    .padding(.bottom, 6)
            }
            DesktopsRows(model: model)
            DesksHint(model: model)
                .opacity(shown)
                .animation(model.settle(delay: 0.2), value: model.progress)
        }
        .frame(width: 470, alignment: .leading)
        // A desktop's sound being picked: off to its right, under the sky.
        .overlay(alignment: .topTrailing) {
            if model.picking != nil {
                DeskSoundPicker(model: model)
                    .offset(x: DeskSoundPicker.width + 40, y: 36)
                    .transition(.modifier(active: FoldDrift(amount: 1), identity: FoldDrift(amount: 0)))
            }
        }
        .padding(.leading, model.size.width * 0.19)
        .padding(.top, max(model.size.height * 0.22 - (model.showsClock ? DesksClock.midnightHeight + 22 : 0), 24))
    }
}

/// The time, over the list (a fullscreen app keeps the menu bar's clock out of sight). In Oyl's
/// look, large over the card, the day under it; in Midnight Oyl's, in its Victorian face over the
/// title, off to the left as it is, the day in italic as it would be written ("tuesday, the 25th
/// of november"), its colon twinkling like a star. On the Mac's own clock, 12- or 24-hour.
struct DesksClock: View {
    @Environment(\.notchTheme) private var theme
    static let plainHeight: CGFloat = 66
    static let midnightHeight: CGFloat = 64

    /// Whether the Mac's clock is a 12-hour one.
    static var twelveHour: Bool { (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a") }

    /// "10", "42" and "PM"; on a 24-hour clock "22", "42" and none.
    static func time(_ date: Date, twelveHour: Bool, calendar: Calendar = .current) -> (hours: String, minutes: String, half: String?) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0, minutes = String(format: "%02d", parts.minute ?? 0)
        guard twelveHour else { return (String(format: "%02d", hour), minutes, nil) }
        return ("\(hour % 12 == 0 ? 12 : hour % 12)", minutes, hour < 12 ? calendar.amSymbol : calendar.pmSymbol)
    }

    /// "a.m." and "p.m.", as Midnight writes them.
    static func written(half: String) -> String {
        switch half.uppercased() {
        case "AM": return "a.m."
        case "PM": return "p.m."
        default: return half.lowercased()
        }
    }

    /// "tuesday, the 25th of november".
    static func written(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.weekday, .day, .month], from: date)
        let weekday = calendar.weekdaySymbols[((parts.weekday ?? 1) - 1) % 7].lowercased()
        let month = calendar.monthSymbols[((parts.month ?? 1) - 1) % 12].lowercased()
        let day = parts.day ?? 1
        return "\(weekday), the \(day)\(ordinal(day)) of \(month)"
    }

    /// "st", "nd", "rd" or "th".
    static func ordinal(_ day: Int) -> String {
        if (11...13).contains(day % 100) { return "th" }
        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    var body: some View {
        if theme == .midnight {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in midnight(timeline.date) }
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in plain(timeline.date) }
        }
    }

    private func plain(_ date: Date) -> some View {
        let time = Self.time(date, twelveHour: Self.twelveHour)
        return VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(time.hours):\(time.minutes)")
                    .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
                if let half = time.half {
                    Text(half)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .foregroundStyle(.white)
            Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
        .lineLimit(1)
        .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
        .frame(height: Self.plainHeight)
        .allowsHitTesting(false)
    }

    private func midnight(_ date: Date) -> some View {
        let time = Self.time(date, twelveHour: Self.twelveHour)
        // The colon twinkles, every two seconds.
        let twinkle = 0.5 + 0.5 * cos(date.timeIntervalSinceReferenceDate * .pi)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(time.hours)
                Text(":")
                    .foregroundStyle(Midnight.starlight)
                    .opacity(0.35 + 0.65 * twinkle)
                    .shadow(color: Midnight.starlight.opacity(0.7 * twinkle), radius: 4)
                Text(time.minutes)
                if let half = time.half {
                    Text(" " + Self.written(half: half))
                        .font(Midnight.italic(17))
                        .foregroundStyle(Midnight.silver.opacity(0.7))
                }
            }
            .font(Midnight.font(.heading, size: 40))
            .foregroundStyle(Midnight.white.opacity(0.92))
            Text(Self.written(date))
                .font(Midnight.italic(15))
                .foregroundStyle(Midnight.silver.opacity(0.62))
                .padding(.leading, 3)
        }
        .lineLimit(1)
        .fixedSize()
        .shadow(color: Midnight.moonlight.opacity(0.22), radius: 12)
        .frame(height: Self.midnightHeight, alignment: .leading)
        .allowsHitTesting(false)
    }
}

/// Under the list: how to group them, before there are any groups; while one's dragged, what
/// letting go would do.
private struct DesksHint: View {
    @ObservedObject var model: DesktopsModel
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let midnight = theme == .midnight, dragging = model.dragging != nil, said = model.dropHint != nil
        ZStack(alignment: .leading) {
            if let hint = model.dropHint {
                Text(hint)
                    .font(midnight ? Midnight.italic(12.5) : .system(size: 10.5))
                    .foregroundStyle(midnight ? Midnight.silver.opacity(dragging ? 0.72 : 0.42) : .white.opacity(dragging ? 0.6 : 0.34))
                    .lineLimit(1)
                    .id(hint)
                    .transition(midnight ? .modifier(active: FoldDrift(amount: 1), identity: FoldDrift(amount: 0)) : .opacity)
            }
        }
        .frame(height: said ? (midnight ? 20 : 16) : 0, alignment: .leading)
        .padding(.leading, midnight ? 44 : 10)
        .animation(midnight ? .timingCurve(0.45, 0, 0.25, 1, duration: 0.35) : .easeOut(duration: 0.15), value: model.dropHint)
        .allowsHitTesting(false)
    }
}

/// The lines. In Midnight Oyl's they bow out to the right and back, down a line of stars; a
/// group's desktops sit in under its heading.
/// Each line's frame in the window, top-left first.
private struct DeskLineFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct DesktopsRows: View {
    @ObservedObject var model: DesktopsModel
    @Environment(\.notchTheme) private var theme
    static let space = "desktops"

    var body: some View {
        let midnight = theme == .midnight, items = model.items, count = items.count, height = model.rowHeight(for: count)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let dragged = item.id == model.dragging
                line(item, height: height)
                    // Where it is on the screen, for a right-click on it (see `DesktopsModel.line(at:)`).
                    .background(GeometryReader { place in
                        Color.clear.preference(key: DeskLineFrames.self, value: [item.id: place.frame(in: .global)])
                    })
                    .padding(.leading, Self.inset(of: item, at: index, of: count, midnight: midnight))
                    .modifier(DeskDrift(model: model, index: index, count: count, on: midnight))
                    .offset(dragged ? model.dragShift : .zero)
                    .zIndex(dragged ? 1 : 0)
                    .transition(midnight ? .modifier(active: FoldDrift(amount: 1), identity: FoldDrift(amount: 0)) : .opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if let gap = model.dropGap {
                DeskGapLine(width: model.listWidth - (midnight ? 30 : 12), midnight: midnight)
                    .offset(x: midnight ? 24 : 6, y: CGFloat(gap) * height - 1)
                    .transition(.opacity)
                    .animation(model.shuffle, value: gap)
                    .allowsHitTesting(false)
            }
        }
        .background(alignment: .topLeading) {
            if midnight {
                // (Not through the one being dragged: it's off with the pointer.)
                DeskLine(points: items.enumerated().compactMap { index, item in
                    item.id == model.dragging ? nil
                        : CGPoint(x: Self.inset(of: item, at: index, of: count, midnight: true) + DeskRow.markerMiddle, y: (CGFloat(index) + 0.5) * height)
                })
                .trim(from: 0, to: min(max(model.progress, 0), 1))
                .stroke(Midnight.silver.opacity(0.2), style: StrokeStyle(lineWidth: 0.7, lineCap: .round, lineJoin: .round))
                .animation(model.settle(delay: 0.1), value: model.progress)
                .allowsHitTesting(false)
            }
        }
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(DeskLineFrames.self) { frames in
            MainActor.assumeIsolated { model.lineFrames = frames }
        }
    }

    @ViewBuilder private func line(_ item: DesktopsModel.Item, height: CGFloat) -> some View {
        switch item {
        case .heading(let group, let desks): DeskHeading(model: model, group: group, desks: desks, height: height)
        case .desk(let desk, let grouped): DeskRow(model: model, desk: desk, grouped: grouped, height: height)
        }
    }

    /// How far in a line sits: Midnight's bow, and a group's desktops in under its heading.
    static func inset(of item: DesktopsModel.Item, at index: Int, of count: Int, midnight: Bool) -> CGFloat {
        let grouped: Bool
        if case .desk(_, true) = item { grouped = true } else { grouped = false }
        return (midnight ? bow(index, of: count) : 0) + (grouped ? (midnight ? 24 : 16) : 0)
    }

    /// How far right the row at `index` sits, of `count`: furthest in the middle.
    static func bow(_ index: Int, of count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        return 30 * sin(.pi * (CGFloat(index) + 0.5) / CGFloat(count))
    }
}

/// A desktop's sound, picked from a list as an alarm's is on a phone: its app's (none of its own),
/// Oyl's named tones, the sounds folder's, or silent. Clicking one plays it and picks it, marked
/// with a check (in Midnight Oyl's, a glint). In Oyl's look a black card beside the list; in
/// Midnight's, the names in the heading face off to the right, under a line in italics.
private struct DeskSoundPicker: View {
    @ObservedObject var model: DesktopsModel
    @Environment(\.notchTheme) private var theme
    @StateObject private var hovered = LocalState<String?>(nil)
    static let width: CGFloat = 210

    var body: some View {
        let midnight = theme == .midnight, id = model.picking ?? ""
        let name = model.desks.first { $0.id == id }?.name ?? ""
        let own = model.soundOf(id)
        let choices: [ChimeVoice?] = [nil] + model.soundChoices().map { Optional($0) }
        VStack(alignment: .leading, spacing: midnight ? 2 : 0) {
            Text(midnight ? "the sound of \(name)" : "Sound for \(name)")
                .font(midnight ? Midnight.italic(14) : .system(size: 11, weight: .semibold))
                .foregroundStyle(midnight ? Midnight.silver.opacity(0.7) : .white.opacity(0.55))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.bottom, midnight ? 6 : 4)
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                row(choice, picked: choice?.id == own?.id, midnight: midnight)
            }
        }
        .padding(.vertical, midnight ? 4 : 8)
        .frame(width: Self.width, alignment: .leading)
        .background {
            if !midnight {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.86))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.09)))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            }
        }
    }

    private func row(_ choice: ChimeVoice?, picked: Bool, midnight: Bool) -> some View {
        let key = choice?.id ?? "app"
        let lit = hovered.value == key
        return HStack(spacing: 8) {
            ZStack {
                if picked {
                    if midnight {
                        FourPointStar().fill(Midnight.starlight).frame(width: 8, height: 8)
                            .shadow(color: Midnight.moonlight.opacity(0.6), radius: 3)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 12)
            Text(choice?.name ?? "Its app's sound")
                .font(midnight ? Midnight.font(.heading, size: 14.5, weight: picked ? .bold : .regular) : .system(size: 12.5, weight: picked ? .semibold : .regular))
                .foregroundStyle(midnight ? Midnight.white.opacity(picked || lit ? 1 : 0.7) : .white.opacity(picked || lit ? 1 : 0.8))
                .lineLimit(1)
                .offset(x: midnight && lit ? 3 : 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: midnight ? 24 : 24)
        .background(DeskHighlight(lit: lit).padding(.horizontal, midnight ? 0 : 4))
        .contentShape(Rectangle())
        .onHover { inside in hovered.value = inside ? key : (hovered.value == key ? nil : hovered.value) }
        .onTapGesture {
            guard let id = model.picking else { return }
            model.chooseSound(id, choice)
            if let choice { model.hearSound(choice) } else if let fallback = model.soundOf(id) ?? model.soundChoices().first { model.hearSound(fallback) }
        }
        .animation(.easeOut(duration: 0.12), value: lit)
    }
}

/// Where a dragged desktop would go, between two lines: in Oyl's look a white bar; in Midnight's,
/// a fine silver line, a star at its start.
private struct DeskGapLine: View {
    let width: CGFloat
    let midnight: Bool

    var body: some View {
        if midnight {
            HStack(spacing: 4) {
                FourPointStar().fill(Midnight.starlight).frame(width: 7, height: 7)
                    .shadow(color: Midnight.moonlight.opacity(0.6), radius: 3)
                Rectangle()
                    .fill(LinearGradient(colors: [Midnight.silver.opacity(0.8), Midnight.silver.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 0.8)
            }
            .frame(width: width, height: 7)
            .offset(y: -3)
        } else {
            Capsule().fill(Color.white.opacity(0.85)).frame(width: width, height: 2)
        }
    }
}

/// Midnight's lines folding away (or a hint giving way to the next): out of sight to the left,
/// into a blur.
private struct FoldDrift: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .offset(x: -24 * amount)
            .blur(radius: 4 * amount)
    }
}

/// Midnight's rows come in one after another, out of a blur from the left, and go the same way.
private struct DeskDrift: ViewModifier {
    @ObservedObject var model: DesktopsModel
    let index: Int
    let count: Int
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            let step = min(0.05, 0.3 / Double(max(count, 1)))
            let shown = min(max(model.progress * 1.3 - Double(index) * step, 0), 1)
            content
                .opacity(shown)
                .offset(x: -(1 - shown) * 36)
                .blur(radius: (1 - shown) * 4)
                .animation(model.settle(delay: Double(index) * 0.035), value: model.progress)
        } else {
            content
        }
    }
}

/// The line of stars Midnight's rows hang on.
private struct DeskLine: Shape {
    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

/// A desktop: its name, what's on it, and (pointed at, in a group) a way to take it out. Click it to
/// go there, right-click it to rename it; drag it onto another to group them.
private struct DeskRow: View {
    @ObservedObject var model: DesktopsModel
    let desk: DesktopsModel.Desk
    let grouped: Bool
    let height: CGFloat
    @FocusState private var typing: Bool
    @Environment(\.notchTheme) private var theme

    /// Where the star (or dot) before the name is, across.
    static let markerMiddle: CGFloat = 14
    static let mostIcons = 6

    private var renaming: Bool { model.renaming == desk.id }
    private var dragged: Bool { model.dragging == desk.id }
    /// Being dragged onto: letting go puts them together.
    /// Being dragged onto (letting go puts them together), or among what a shift-click would group.
    private var target: Bool { model.dropTarget == desk.id || model.spanned.contains(desk.id) }
    private var lit: Bool { dragged || target || model.dragging == nil && (model.hovered == desk.id || model.selected == desk.id) }
    /// Its own actions, pointed at or picked (not while one's dragged, or shift-clicked).
    private var showsActions: Bool {
        !renaming && model.dragging == nil && model.anchor == nil && (model.hovered == desk.id || model.selected == desk.id)
    }

    var body: some View {
        let midnight = theme == .midnight
        HStack(spacing: midnight ? 10 : 8) {
            marker(midnight: midnight)
            name(midnight: midnight)
            if desk.namesApps, !renaming { appNames(midnight: midnight) }
            if let working = model.atWork[desk.id], working > 0, !renaming { DeskAtWork(count: working) }
            if let rang = model.rang[desk.id], !renaming { DeskRangMark(rang: rang) }
            if let sound = model.soundNames[desk.id], !renaming {
                Text("♪ " + sound)
                    .font(midnight ? Midnight.italic(12) : .system(size: 10.5, weight: .medium))
                    .foregroundStyle(midnight ? Midnight.silver.opacity(0.5) : .white.opacity(0.38))
                    .lineLimit(1)
            }
            icons(midnight: midnight)
            Spacer(minLength: 8)
            if showsActions {
                if model.picksSounds {
                    DeskAction(word: "sound", symbol: "speaker.wave.2", help: "Its sound when a Claude's done here") {
                        withAnimation(model.shuffle) { model.picking = model.picking == desk.id ? nil : desk.id }
                    }
                }
                if grouped { takeOutButton(midnight: midnight) }
            }
        }
        .padding(.horizontal, midnight ? 6 : 10)
        .frame(height: height)
        .background(DeskHighlight(lit: lit, target: target, rang: model.rang[desk.id]?.kind,
                                  newest: model.rang[desk.id].map { $0.at == model.newestRang } ?? false))
        .scaleEffect(dragged ? (midnight ? 1.035 : 1.02) : 1, anchor: .leading)
        .shadow(color: dragged ? (midnight ? Midnight.moonlight.opacity(0.25) : .black.opacity(0.4)) : .clear, radius: dragged ? 10 : 0)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                model.hovered = desk.id
            } else {
                if model.hovered == desk.id { model.hovered = nil }
            }
        }
        .onTapGesture {
            guard !renaming, !model.justDragged else { return }
            if NSEvent.modifierFlags.contains(.shift) {
                withAnimation(model.shuffle) { model.shiftClicked(desk.id) }
                return
            }
            model.pick(desk)
        }
        .gesture(drag, including: renaming ? .subviews : .all)
        .animation(.easeOut(duration: 0.15), value: lit)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DesktopsRows.space))
            .onChanged { value in
                if model.dragging != desk.id {
                    model.finishRenaming(keeping: true)
                    model.anchor = nil
                    model.dragging = desk.id
                }
                model.dragShift = value.translation
                model.dragAt = value.location
            }
            .onEnded { _ in
                withAnimation(model.shuffle) { model.drop() }
                model.justDragged = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { model.justDragged = false }
            }
    }

    // MARK: Pieces

    @ViewBuilder private func marker(midnight: Bool) -> some View {
        if midnight {
            ZStack {
                if desk.isCurrent {
                    DesktopGlint()
                } else {
                    FourPointStar()
                        .fill(Midnight.starlight)
                        .frame(width: lit ? 8 : 6, height: lit ? 8 : 6)
                        .opacity(lit ? 0.95 : 0.5)
                }
            }
            .frame(width: 16, height: 16)
        } else {
            Circle()
                .fill(.white)
                .frame(width: 5, height: 5)
                .opacity(desk.isCurrent ? 0.9 : 0)
                .frame(width: 8)
        }
    }

    @ViewBuilder private func name(midnight: Bool) -> some View {
        let font = midnight ? Midnight.font(.heading, size: 18, weight: desk.isCurrent ? .bold : .regular)
            : .system(size: 13, weight: desk.isCurrent ? .semibold : .regular)
        if renaming {
            DeskNameField(model: model, font: font, typing: $typing)
        } else if midnight {
            Text(desk.name)
                .font(font)
                .foregroundStyle(Midnight.white.opacity(lit ? 1 : desk.isCurrent ? 0.95 : 0.7))
                .shadow(color: Midnight.moonlight.opacity(lit || desk.isCurrent ? 0.45 : 0), radius: 6)
                .offset(x: lit ? 4 : 0)
                .lineLimit(1)
        } else {
            Text(desk.name)
                .font(font)
                .foregroundStyle(.white.opacity(lit || desk.isCurrent ? 1 : 0.82))
                .lineLimit(1)
        }
    }

    private func appNames(midnight: Bool) -> some View {
        Text(desk.apps.prefix(3).map { $0.name.lowercased() }.joined(separator: ", "))
            .font(midnight ? Midnight.italic(12.5) : .system(size: 11.5))
            .foregroundStyle(midnight ? Midnight.silver.opacity(0.5) : .white.opacity(0.4))
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(-1)
    }

    private func icons(midnight: Bool) -> some View {
        // Marked on the row pointed at only, so the list isn't all ×s.
        DeskIcons(apps: desk.apps, lit: lit, most: Self.mostIcons, quits: model.optionHeld && lit, tapped: { app in
            guard !renaming, !model.justDragged else { return }
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) {
                withAnimation(model.shuffle) { model.shiftClicked(desk.id) }
            } else if flags.contains(.option), app.quittable {
                // Option-clicked: quit at once, as ⌘Q would.
                model.quit(app)
            } else {
                // Else as the row's own click.
                model.pick(desk)
            }
        }, says: { app in
            model.optionHeld && app.quittable ? "Option-click: " + DesktopsModel.quitSays(app.name, desktops: model.desktops(with: app.id)) : app.name
        })
        .offset(x: midnight && lit ? 4 : 0)
    }

    private func takeOutButton(midnight: Bool) -> some View {
        DeskAction(word: "take out", symbol: "minus.circle", help: "Take out of the group") {
            withAnimation(model.shuffle) { model.regroup(.out(desk: desk.id)) }
        }
    }
}

/// A group's heading: its name, and, folded, how many desktops are in it and their apps' icons;
/// pointed at, a way to do away with it (right-click it to rename it). Click it to fold the group away or open it
/// out; drag a desktop onto it to put it in. In Oyl's look, a small bold name after a chevron
/// that turns; in Midnight's, a little constellation and the name in italics, the desktops
/// drifting away into a blur as it folds.
private struct DeskHeading: View {
    @ObservedObject var model: DesktopsModel
    let group: DesktopsModel.Group
    let desks: [DesktopsModel.Desk]
    let height: CGFloat
    @FocusState private var typing: Bool
    @Environment(\.notchTheme) private var theme

    private var id: String { DesktopsModel.headingID(group.id) }
    private var renaming: Bool { model.renaming == id }
    private var target: Bool { model.dropTarget == id || model.spanned.contains(id) }
    private var lit: Bool { target || model.dragging == nil && (model.hovered == id || model.selected == id) }
    /// The one you're on is in it, folded out of sight.
    private var holdsCurrent: Bool { group.folded && desks.contains(where: \.isCurrent) }

    var body: some View {
        let midnight = theme == .midnight
        HStack(spacing: midnight ? 10 : 7) {
            marker(midnight: midnight)
            name(midnight: midnight)
            if group.folded, !renaming {
                Text(midnight ? "· \(desks.count)" : "\(desks.count)")
                    .font(midnight ? Midnight.italic(12.5) : .system(size: 10.5, weight: .medium))
                    .foregroundStyle(midnight ? Midnight.silver.opacity(0.5) : .white.opacity(0.38))
                DeskIcons(apps: apps, lit: lit, most: DeskRow.mostIcons, small: true)
                    .transition(.opacity)
            }
            if !renaming, model.isSplit(group.id) {
                // Its desktops apart in Mission Control: marked as it marks them there, dashed in amber.
                Path { path in
                    path.move(to: CGPoint(x: 1, y: 1))
                    path.addLine(to: CGPoint(x: 17, y: 1))
                }
                .stroke(MissionMark.amber(theme).opacity(midnight ? 0.85 : 1),
                        style: StrokeStyle(lineWidth: midnight ? 1.2 : 2, lineCap: .round, dash: midnight ? [1, 3.5] : [4, 3]))
                .frame(width: 18, height: 2)
                .help("Its desktops aren't next to each other in Mission Control")
            }
            // Folded: agents at work on its desktops, and a sound that's just come from one of them.
            if group.folded, !renaming, model.atWork(inGroup: group.id) > 0 { DeskAtWork(count: model.atWork(inGroup: group.id)) }
            if group.folded, !renaming, let rang = model.rang(inGroup: group.id) { DeskRangMark(rang: rang) }
            Spacer(minLength: 8)
            if !renaming, model.dragging == nil, model.anchor == nil, model.hovered == id || model.selected == id {
                DeskAction(word: "ungroup", symbol: "xmark", help: "Ungroup") {
                    withAnimation(model.shuffle) { model.regroup(.ungroup(group: group.id)) }
                }
            }
        }
        .padding(.horizontal, midnight ? 6 : 10)
        .frame(height: height)
        .background(DeskHighlight(lit: lit, target: target, rang: group.folded ? model.rang(inGroup: group.id)?.kind : nil,
                                  newest: group.folded && model.rang(inGroup: group.id).map { $0.at == model.newestRang } ?? false))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                model.hovered = id
            } else if model.hovered == id {
                model.hovered = nil
            }
        }
        .onTapGesture {
            guard !renaming, !model.justDragged else { return }
            withAnimation(model.shuffle) {
                if NSEvent.modifierFlags.contains(.shift) { model.shiftClicked(id) } else { model.fold(group.id, !group.folded) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: lit)
    }

    /// Its desktops' apps, each once.
    private var apps: [DesktopsModel.App] {
        var seen = Set<pid_t>()
        return desks.flatMap(\.apps).filter { seen.insert($0.id).inserted }
    }

    @ViewBuilder private func marker(midnight: Bool) -> some View {
        if midnight {
            DeskConstellation(gathered: group.folded, lit: lit, current: holdsCurrent)
                .frame(width: 16, height: 16)
        } else {
            HStack(spacing: 4) {
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
                    .opacity(holdsCurrent ? 0.9 : 0)
                    .frame(width: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(lit ? 0.75 : 0.45))
                    .rotationEffect(.degrees(group.folded ? 0 : 90))
                    .frame(width: 10)
            }
        }
    }

    @ViewBuilder private func name(midnight: Bool) -> some View {
        let font = midnight ? Midnight.italic(16) : .system(size: 11.5, weight: .semibold)
        if renaming {
            DeskNameField(model: model, font: font, typing: $typing)
        } else if midnight {
            Text(group.name)
                .font(font)
                .tracking(0.4)
                .foregroundStyle((lit ? Midnight.white : Midnight.silver).opacity(lit ? 1 : 0.78))
                .shadow(color: Midnight.moonlight.opacity(lit || holdsCurrent ? 0.4 : 0), radius: 6)
                .offset(x: lit ? 4 : 0)
                .lineLimit(1)
        } else {
            Text(group.name)
                .font(font)
                .tracking(0.3)
                .foregroundStyle(.white.opacity(lit ? 0.92 : 0.62))
                .lineLimit(1)
        }
    }
}

/// What a desktop or a group's renamed in: Return keeps it, Escape doesn't.
private struct DeskNameField: View {
    @ObservedObject var model: DesktopsModel
    let font: Font
    var typing: FocusState<Bool>.Binding
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let midnight = theme == .midnight
        TextField("", text: $model.draft)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(midnight ? Midnight.white : .white)
            .focused(typing)
            .onSubmit { model.finishRenaming(keeping: true) }
            .onAppear { DispatchQueue.main.async { typing.wrappedValue = true } }
            .frame(width: midnight ? 240 : 200)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(midnight ? AnyShapeStyle(LinearGradient(colors: [Midnight.moonlight.opacity(0.14), .clear],
                                                                  startPoint: .leading, endPoint: .trailing))
                                 : AnyShapeStyle(Color.white.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: midnight ? 2 : 5, style: .continuous))
    }
}

/// The icons of the apps on a desktop (or in a group), and how many more.
private struct DeskIcons: View {
    let apps: [DesktopsModel.App]
    let lit: Bool
    let most: Int
    var small = false
    /// Option's held: each that can be quit marked with an ×.
    var quits = false
    /// Clicked, one of them (a desktop's row's own, not a group's heading's), and what each says
    /// pointed at.
    var tapped: ((DesktopsModel.App) -> Void)? = nil
    var says: ((DesktopsModel.App) -> String)? = nil
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let midnight = theme == .midnight
        let side: CGFloat = (midnight ? 17 : 16) - (small ? 3 : 0)
        // More room between them while they're marked, for the marks.
        HStack(spacing: (midnight ? 4 : 3) + (quits ? 6 : 0)) {
            ForEach(apps.prefix(most)) { app in
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: side, height: side)
                        .saturation(midnight ? 0.55 : 1)
                        .opacity(midnight ? (lit ? 0.95 : 0.72) : small ? 0.85 : 1)
                        .overlay(alignment: .topTrailing) {
                            if quits, app.quittable { QuitMark(midnight: midnight).offset(x: 3, y: -3).transition(.scale.combined(with: .opacity)) }
                        }
                        .animation(midnight ? .easeInOut(duration: 0.3) : .easeOut(duration: 0.12), value: quits)
                        .help(says?(app) ?? app.name)
                        .contentShape(Rectangle())
                        .onTapGesture { tapped?(app) }
                        .allowsHitTesting(tapped != nil)
                }
            }
            if apps.count > most {
                Text("+\(apps.count - most)")
                    .font(midnight ? Midnight.italic(11) : .system(size: 10.5, weight: .medium))
                    .foregroundStyle(midnight ? Midnight.silver.opacity(0.5) : .white.opacity(0.45))
                    .fixedSize()
            }
        }
    }
}

/// On an app's icon while Option's held: an Option-click quits it. In Oyl's look a small dark disc
/// with a white ×; in Midnight's a little patch of night with a silver one.
private struct QuitMark: View {
    let midnight: Bool

    var body: some View {
        ZStack {
            Circle().fill(midnight ? Midnight.ink.opacity(0.92) : Color(white: 0.16))
            Circle().strokeBorder(midnight ? Midnight.silver.opacity(0.55) : Color.white.opacity(0.75), lineWidth: midnight ? 0.5 : 0.75)
            Image(systemName: "xmark")
                .font(.system(size: 5.5, weight: .heavy))
                .foregroundStyle(midnight ? Midnight.silver : .white)
        }
        .frame(width: 10, height: 10)
    }
}

/// A line's own action, shown while it's pointed at: a word in Midnight's italics, an icon in Oyl's.
private struct DeskAction: View {
    let word: String
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.notchTheme) private var theme

    var body: some View {
        Button(action: action) {
            if theme == .midnight {
                Text(word)
                    .font(Midnight.italic(12))
                    .foregroundStyle(Midnight.silver.opacity(0.6))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .transition(.opacity)
    }
}

/// A line lit: pointed at or picked, or (brighter) being dragged onto; and a sound's just come from
/// it, in its own color under that (amber for a Claude waiting for you, mint for one done), with
/// a bar at its edge in Oyl's look, the newest breathing. In Midnight's, washes of light with no
/// edge, fading in from the left, off to the right, and above and below: moonlight for the line
/// lit, the sound's own color (amber, or starlight) for where it came from.
private struct DeskHighlight: View {
    let lit: Bool
    var target = false
    /// A sound's just come from it: which.
    var rang: AgentChimes.Kind? = nil
    /// The newest sound's in the list: it breathes, to catch the eye.
    var newest = false
    @Environment(\.notchTheme) private var theme

    /// Where a sound's come from, in its own color.
    static func tint(_ kind: AgentChimes.Kind, theme: NotchTheme) -> Color {
        if kind == .waiting { return MissionMark.amber(theme) }
        return theme == .midnight ? Midnight.starlight : Color(red: 0.5, green: 0.9, blue: 0.68)
    }

    var body: some View {
        let midnight = theme == .midnight
        ZStack(alignment: .leading) {
            if let rang {
                let tint = Self.tint(rang, theme: theme)
                DeskBreathing(on: newest) { breath in
                    if midnight {
                        Self.wash(tint, strength: (rang == .waiting ? 0.36 : 0.2) * breath)
                    } else {
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(tint.opacity((rang == .waiting ? 0.2 : 0.14) * breath))
                            Capsule()
                                .fill(tint.opacity(min(0.95 * breath, 1)))
                                .frame(width: 3)
                                .padding(.vertical, 7)
                                .padding(.leading, 2)
                        }
                    }
                }
            }
            if midnight {
                Self.wash(Midnight.moonlight, strength: target ? 0.24 : lit ? 0.13 : 0)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(target ? 0.17 : lit ? 0.09 : 0))
            }
        }
    }

    private static func wash(_ color: Color, strength: Double) -> some View {
        LinearGradient(stops: [.init(color: .clear, location: 0),
                               .init(color: color.opacity(strength), location: 0.08),
                               .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
            .mask(LinearGradient(colors: [.clear, .white, .clear], startPoint: .top, endPoint: .bottom))
            .padding(.vertical, -4)
    }
}

/// Breathing, slowly brighter and back (or steady, while it's not to).
private struct DeskBreathing<Content: View>: View {
    let on: Bool
    @ViewBuilder let content: (Double) -> Content

    /// How bright it is at `time`: 0.75 to 1.2, every 1.6 s.
    static func breath(at time: TimeInterval) -> Double { 0.975 + 0.225 * sin(time * 2 * .pi / 1.6) }

    var body: some View {
        if on {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                content(Self.breath(at: timeline.date.timeIntervalSinceReferenceDate))
            }
        } else {
            content(1)
        }
    }
}

/// Beside a desktop's name, while a sound's just come from it: in Oyl's look a bell (waiting for
/// you, in amber) or a check (done); in Midnight's, a glint twinkling, pale amber for waiting.
struct DeskRangMark: View {
    let rang: DeskChimes.Rang
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let waiting = rang.kind == .waiting
        Group {
            if theme == .midnight {
                // The same marks as Oyl's look (a check, or a bell), in starlight, a star twinkling at
                // the tip.
                let tint = DeskHighlight.tint(rang.kind, theme: theme)
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
                    let twinkle = 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * (waiting ? 3.2 : 1.8))
                    ZStack {
                        if waiting {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(tint)
                        } else {
                            DeskCheck()
                                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                .frame(width: 10, height: 8)
                        }
                        FourPointStar()
                            .fill(tint)
                            .frame(width: 3 + 3 * twinkle, height: 3 + 3 * twinkle)
                            .opacity(0.5 + 0.5 * twinkle)
                            .rotationEffect(.degrees(twinkle * 15))
                            .offset(x: 6.5, y: -5.5)
                    }
                    .shadow(color: tint.opacity(0.35 + 0.35 * twinkle), radius: 3)
                }
                .frame(width: 18, height: 14)
            } else {
                Image(systemName: waiting ? "bell.fill" : "checkmark.circle.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(DeskHighlight.tint(rang.kind, theme: theme))
            }
        }
        .help(Self.says(rang))
    }

    static func says(_ rang: DeskChimes.Rang, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(rang.at) / 60)
        let when = minutes < 1 ? "just now" : minutes == 1 ? "a minute ago" : "\(minutes) minutes ago"
        return rang.kind == .waiting ? "A Claude here is waiting for you (\(when))" : "A Claude here finished (\(when))"
    }
}

/// Beside a desktop's name while agents are at work on it: in Oyl's look a dot in Claude's orange,
/// breathing, with how many if more than one; in Midnight's a little moon going round, pale gold,
/// the count in italic.
struct DeskAtWork: View {
    let count: Int
    @Environment(\.notchTheme) private var theme

    static let orange = Color(red: 0.93, green: 0.55, blue: 0.36)

    var body: some View {
        let midnight = theme == .midnight
        let tint = midnight ? Color(red: 1, green: 0.8, blue: 0.52) : Self.orange
        HStack(spacing: 3) {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                if midnight {
                    // A moon round a faint ring, once every two seconds.
                    let angle = t * .pi
                    ZStack {
                        Circle().strokeBorder(tint.opacity(0.35), lineWidth: 0.7)
                        Circle().fill(tint.opacity(0.5)).frame(width: 2.5, height: 2.5)
                        Circle().fill(tint).frame(width: 4.5, height: 4.5)
                            .offset(x: 5.5 * cos(angle), y: 5.5 * sin(angle))
                            .shadow(color: tint.opacity(0.8), radius: 2.5)
                    }
                    .frame(width: 12, height: 12)
                } else {
                    let breath = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.4))
                    Circle().fill(tint.opacity(breath)).frame(width: 6, height: 6)
                        .shadow(color: tint.opacity(0.6 * breath), radius: 2.5)
                }
            }
            .frame(width: midnight ? 15 : 11, height: midnight ? 15 : 11)
            if count > 1 {
                Text("\(count)")
                    .font(midnight ? Midnight.italic(11) : .system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint.opacity(0.9))
            }
        }
        .help(count == 1 ? "An agent's at work here" : "\(count) agents at work here")
    }
}

/// A check, as a pen draws it: down to the left, then a long stroke up to the right.
struct DeskCheck: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// Midnight's mark for a group: three stars, a little constellation, drawn in close as it folds
/// (and twinkling, folded, when the one you're on is in it).
private struct DeskConstellation: View {
    let gathered: Bool
    let lit: Bool
    let current: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !current)) { timeline in
            let twinkle = current ? 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 1.7) : 0
            let spread: CGFloat = gathered ? 0.7 : 1
            let stars: [(CGPoint, CGFloat)] = [(CGPoint(x: -4.5, y: -3.5), 5.5), (CGPoint(x: 4.5, y: -1), 4.5), (CGPoint(x: -0.5, y: 5), 4)]
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 8 + stars[0].0.x * spread, y: 8 + stars[0].0.y * spread))
                    for star in stars.dropFirst() { path.addLine(to: CGPoint(x: 8 + star.0.x * spread, y: 8 + star.0.y * spread)) }
                }
                .stroke(Midnight.silver.opacity(lit ? 0.45 : 0.25), lineWidth: 0.6)
                ForEach(0..<stars.count, id: \.self) { index in
                    FourPointStar()
                        .fill(Midnight.starlight)
                        .frame(width: stars[index].1 * (1 + 0.35 * twinkle), height: stars[index].1 * (1 + 0.35 * twinkle))
                        .offset(x: stars[index].0.x * spread, y: stars[index].0.y * spread)
                        .opacity(lit || current ? 0.95 : 0.6)
                }
            }
            .frame(width: 16, height: 16)
            .shadow(color: Midnight.moonlight.opacity(current ? 0.5 : 0), radius: 4)
            .animation(.timingCurve(0.45, 0, 0.25, 1, duration: 0.42), value: gathered)
        }
        .allowsHitTesting(false)
    }
}

/// A four-pointed glint before the desktop you're on, twinkling.
private struct DesktopGlint: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            let twinkle = 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 1.7)
            FourPointStar()
                .fill(Midnight.starlight)
                .frame(width: 10 + 4 * twinkle, height: 10 + 4 * twinkle)
                .opacity(0.7 + 0.3 * twinkle)
                .rotationEffect(.degrees(twinkle * 12))
                .shadow(color: Midnight.moonlight.opacity(0.6), radius: 4)
        }
        .allowsHitTesting(false)
    }
}

/// Midnight's sky behind the desktops: its stars, where they always are, each twinkling at its own
/// pace, and a few constellations of the bright ones close together, new each time the list comes
/// up. Each's grown from a star picked at random, out to one of the two nearest it hasn't got yet
/// (the nearest, mostly) that's close enough to one it has, four to seven stars long (three, if
/// there aren't more near), its lines never crossing another's, and kept a little apart from the
/// rest; none where the list's own column is, where they'd run through its names. As the list
/// comes up they're drawn in, one after another and line by line, a spark at each line's tip, each
/// star brightening as its line reaches it; then they breathe.
enum DesktopsSky {
    struct Star: Equatable {
        let point: CGPoint
        let base: Double
        let rate: Double
        let phase: Double
    }

    /// From a star a constellation had to the next it took in.
    struct Line: Equatable {
        let from: Int
        let to: Int
    }

    struct Constellation: Equatable {
        /// Its stars, by their places in the sky's, the one it grew from first, then each as it was
        /// taken in.
        var stars: [Int]
        /// In the order they're drawn: each line to the star after it in `stars`.
        var lines: [Line]
    }

    /// The sky as the list came up: which constellations (by `seed`), and when.
    struct Opening: Equatable {
        let seed: UInt64
        let at: Date
    }

    nonisolated static let count = 160
    /// How many constellations, at most.
    nonisolated static let most = 6
    /// How many stars each wants.
    nonisolated static let sizes = 4...7
    /// Bright enough to be in one.
    nonisolated static let brightest = 0.5

    /// Every star, where it always is (as it always was).
    nonisolated static func stars(in size: CGSize) -> [Star] {
        var seed: UInt64 = 7
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<count).map { _ in
            let x = next() * size.width, y = next() * size.height
            return Star(point: CGPoint(x: x, y: y), base: 0.3 + next() * 0.8, rate: 0.4 + next() * 1.6, phase: next() * 2 * .pi)
        }
    }

    /// How near two stars have to be to be joined: a little over the usual way between the bright ones.
    nonisolated static func reach(in size: CGSize, bright: Int) -> CGFloat {
        1.4 * (size.width * size.height / CGFloat(max(bright, 1))).squareRoot()
    }

    /// Across, where the list's column is (Midnight's, off to the left of the middle), and a margin.
    nonisolated static func clear(in size: CGSize) -> ClosedRange<CGFloat> {
        let left = size.width * 0.19
        return (left - 40)...(left + 470 + 50)
    }

    /// Whether two lines cross (meeting at an end isn't crossing).
    nonisolated static func crosses(_ a: (CGPoint, CGPoint), _ b: (CGPoint, CGPoint)) -> Bool {
        func side(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        let one = side(b.0, b.1, a.0), two = side(b.0, b.1, a.1), three = side(a.0, a.1, b.0), four = side(a.0, a.1, b.1)
        return (one > 0 && two < 0 || one < 0 && two > 0) && (three > 0 && four < 0 || three < 0 && four > 0)
    }

    /// This time's constellations, by `seed`.
    nonisolated static func constellations(of stars: [Star], in size: CGSize, seed: UInt64) -> [Constellation] {
        var state = seed
        func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        func distance(_ a: Int, _ b: Int) -> CGFloat { hypot(stars[a].point.x - stars[b].point.x, stars[a].point.y - stars[b].point.y) }
        let bright = stars.indices.filter { stars[$0].base >= brightest }
        let reach = reach(in: size, bright: bright.count)
        let clear = clear(in: size), inset = min(size.width, size.height) * 0.04
        let open = bright.filter { index in
            let point = stars[index].point
            return !clear.contains(point.x) && point.x > inset && point.x < size.width - inset && point.y > inset && point.y < size.height - inset
        }
        var taken = Set<Int>(), tried = Set<Int>()
        var drawn: [(CGPoint, CGPoint)] = []
        var all: [Constellation] = []
        // Not right by another's stars.
        func apart(_ index: Int) -> Bool { taken.allSatisfy { distance($0, index) >= reach * 0.55 } }
        while all.count < most {
            let free = open.filter { !taken.contains($0) && !tried.contains($0) && apart($0) }
            guard !free.isEmpty else { break }
            let start = free[min(Int(next() * Double(free.count)), free.count - 1)]
            tried.insert(start)
            let wanted = sizes.lowerBound + min(Int(next() * Double(sizes.count)), sizes.count - 1)
            var members = [start], lines: [Line] = [], segments: [(CGPoint, CGPoint)] = []
            while members.count < wanted {
                var options: [(star: Int, from: Int, distance: CGFloat)] = []
                for candidate in free where !members.contains(candidate) {
                    guard let near = members.map({ (from: $0, distance: distance($0, candidate)) }).min(by: { $0.distance < $1.distance }),
                          near.distance <= reach else { continue }
                    let segment = (stars[near.from].point, stars[candidate].point)
                    guard !(drawn + segments).contains(where: { crosses($0, segment) }) else { continue }
                    options.append((candidate, near.from, near.distance))
                }
                guard !options.isEmpty else { break }
                options.sort { $0.distance < $1.distance }
                let pick = options.count > 1 && next() < 0.35 ? options[1] : options[0]
                members.append(pick.star)
                lines.append(Line(from: pick.from, to: pick.star))
                segments.append((stars[pick.from].point, stars[pick.star].point))
            }
            // Too few near it to be one.
            guard members.count >= 3 else { continue }
            taken.formUnion(members)
            drawn += segments
            all.append(Constellation(stars: members, lines: lines))
        }
        return all
    }

    /// After the list's come up: when the first's first line begins, the next constellation after
    /// the one before, and each line after the one before in it; and how long each takes to draw.
    nonisolated static let first: TimeInterval = 0.45
    nonisolated static let between: TimeInterval = 0.32
    nonisolated static let each: TimeInterval = 0.24
    nonisolated static let drawing: TimeInterval = 0.42

    /// When a constellation's line begins to be drawn, after the list's come up.
    nonisolated static func begins(_ constellation: Int, line: Int) -> TimeInterval {
        first + between * Double(constellation) + each * Double(line)
    }

    /// When each joined star's lit, after the list's come up: the first of each as its first line
    /// sets out, each other as its line reaches it.
    nonisolated static func lit(_ constellations: [Constellation]) -> [Int: TimeInterval] {
        var lit: [Int: TimeInterval] = [:]
        for (index, constellation) in constellations.enumerated() {
            if let first = constellation.stars.first { lit[first] = begins(index, line: 0) }
            for (line, joined) in constellation.lines.enumerated() { lit[joined.to] = begins(index, line: line) + drawing }
        }
        return lit
    }

    /// 0 to 1, eased in and out.
    nonisolated static func eased(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Midnight's sky behind the desktops, as `DesktopsSky` lays it out.
private struct DesktopsStars: View {
    let size: CGSize
    let opening: DesktopsSky.Opening
    /// How far short of a star a line stops.
    private static let gap: CGFloat = 3.5

    var body: some View {
        let stars = DesktopsSky.stars(in: size)
        let constellations = DesktopsSky.constellations(of: stars, in: size, seed: opening.seed)
        let lit = DesktopsSky.lit(constellations)
        let at = opening.at.timeIntervalSinceReferenceDate
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let since = time - at
            Canvas { context, _ in
                // The lines first, under their stars.
                for (index, constellation) in constellations.enumerated() {
                    let breath = 0.78 + 0.22 * sin(time * 0.55 + Double(index) * 1.7)
                    for (number, line) in constellation.lines.enumerated() {
                        let drawn = DesktopsSky.eased((since - DesktopsSky.begins(index, line: number)) / DesktopsSky.drawing)
                        guard drawn > 0 else { continue }
                        let from = stars[line.from].point, to = stars[line.to].point
                        let length = hypot(to.x - from.x, to.y - from.y)
                        guard length > 2 * Self.gap else { continue }
                        let along = CGPoint(x: (to.x - from.x) / length, y: (to.y - from.y) / length)
                        let start = CGPoint(x: from.x + along.x * Self.gap, y: from.y + along.y * Self.gap)
                        let reach = (length - 2 * Self.gap) * drawn
                        let tip = CGPoint(x: start.x + along.x * reach, y: start.y + along.y * reach)
                        var path = Path()
                        path.move(to: start)
                        path.addLine(to: tip)
                        var stroke = context
                        stroke.opacity = 0.3 * breath
                        stroke.stroke(path, with: .color(Midnight.starlight), lineWidth: 0.75)
                        // A spark at its tip as it's drawn.
                        if drawn < 1 {
                            var spark = context
                            spark.opacity = 0.75 * (1 - drawn)
                            spark.fill(Path(ellipseIn: CGRect(x: tip.x - 1.2, y: tip.y - 1.2, width: 2.4, height: 2.4)), with: .color(Midnight.starlight))
                        }
                    }
                }
                for (index, star) in stars.enumerated() {
                    let twinkle = 0.5 + 0.5 * sin(time * star.rate + star.phase)
                    let glow = lit[index].map { DesktopsSky.eased((since - $0) / 0.5) } ?? 0
                    let radius = star.base * (0.7 + 0.5 * twinkle) * (1 + 0.45 * glow)
                    let x = star.point.x, y = star.point.y
                    if glow > 0 {
                        var halo = context
                        halo.opacity = 0.09 * glow
                        let around = radius * 3.2
                        halo.fill(Path(ellipseIn: CGRect(x: x - around, y: y - around, width: 2 * around, height: 2 * around)),
                                  with: .color(Midnight.starlight))
                    }
                    var dot = context
                    dot.opacity = min(0.15 + 0.55 * twinkle * star.base + 0.3 * glow, 1)
                    dot.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)),
                             with: .color(Midnight.starlight))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

// MARK: - The window it's in, and what it does

/// Over everything, on whichever Space is showing; it takes the keyboard (for Escape, the arrows
/// and Return, and renaming) without bringing Oyl to the front.
final class DesktopsPanel: NSPanel {
    var escape: () -> Void = {}
    /// A key it might want: whether it did.
    var pressed: (NSEvent) -> Bool = { _ in false }

    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    /// A right-click (or control-click): whether it was taken (a line renamed).
    var rightClicked: (NSEvent) -> Bool = { _ in false }
    /// The modifier keys, as they change while it's key.
    var flagsChanged: (NSEvent.ModifierFlags) -> Void = { _ in }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { escape() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged { flagsChanged(event.modifierFlags) }
        let right = event.type == .rightMouseDown || event.type == .leftMouseDown && event.modifierFlags.contains(.control)
        if right, rightClicked(event) { return }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            escape()
        } else if !pressed(event) {
            super.keyDown(with: event)
        }
    }
}

final class DesktopsHostingView: NSHostingView<DesktopsView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Four fingers up brings it up, following them; let go most of the way (or quickly), it's up,
/// else it goes back down. Right Shift twice brings it up too. Four fingers down (or three, as
/// App Exposé's held back while it's up), right Shift twice, Escape, or a click off the list puts
/// it away; a click on a desktop, at once, as you go straight there.
@MainActor
final class DesktopsViewer {
    let model = DesktopsModel()
    private let panel = DesktopsPanel()
    private var screen: NSScreen?
    /// The Spaces in their own order, as they were last read, and the one showing.
    private var spaces: [CurrentSpace] = []
    private var current: Int?
    /// Up at all: coming up, up, or going.
    private(set) var isUp = false
    private var shownAt = Date.distantPast
    /// A swipe being followed, and which way.
    private var following: Bool?
    /// The swipe followed is three fingers down.
    private var threeDown = false
    private var hiding: DispatchWorkItem?
    /// While it's up, it's looked for twice a second: out of sight, it isn't left up (see `watch`).
    private var watching: Timer?
    private var readingApps: Task<Void, Never>?
    private var observers: [Any] = []
    /// Whether it can come up now (not while Oyl's off, or nothing can be seen).
    var isAllowed: () -> Bool = { true }
    /// The agents at work now, to mark their desktops.
    var working: () -> [AgentSession] = { [] }
    private var readingAgents: Task<Void, Never>?
    private var rangWatch: AnyCancellable?

    var theme = NotchTheme.standard {
        didSet { if theme != model.theme { model.theme = theme } }
    }

    var isResting = false {
        didSet { if isResting, isUp { hide() } }
    }

    init() {
        let host = DesktopsHostingView(rootView: DesktopsView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.escape = { [weak self] in self?.escape() }
        panel.pressed = { [weak self] event in self?.pressed(event) ?? false }
        panel.rightClicked = { [weak self] event in
            guard let self else { return false }
            // The line under the click, as it's laid out (the one pointed at, if that's not known).
            let point = event.locationInWindow
            let height = self.panel.contentView?.bounds.height ?? self.panel.frame.height
            return self.model.renameLine(self.model.line(at: CGPoint(x: point.x, y: height - point.y)) ?? self.model.hovered)
        }
        model.dismiss = { [weak self] in self?.close() }
        model.pick = { [weak self] desk in self?.close(goingTo: desk) }
        model.quit = { [weak self] app in self?.quit(app) }
        panel.flagsChanged = { [weak self] flags in
            guard let self else { return }
            let held = flags.contains(.option)
            if held != self.model.optionHeld { self.model.optionHeld = held }
        }
        model.renamed = { [weak self] desk, name in self?.rename(desk, to: name) }
        model.renamedGroup = { id, name in SpaceGroups().rename(id, to: name) }
        model.folded = { id, folded in SpaceGroups().fold(id, folded) }
        model.regroup = { [weak self] change in self?.regroup(change) }
        model.soundChoices = { ChimeVoice.all().filter { !$0.id.hasPrefix("system:") } }
        model.soundOf = { [weak self] id in
            guard let space = self?.spaces.first(where: { $0.key == id }) else { return nil }
            return ChimeSettings.shared.desk(space)
        }
        model.chooseSound = { [weak self] id, voice in
            guard let self, let space = self.spaces.first(where: { $0.key == id }) else { return }
            ChimeSettings.shared.setDesk(space, to: voice)
            self.showSounds()
        }
        model.hearSound = { [weak self] voice in voice.play(.done, midnight: self?.model.theme == .midnight) }
        // A sound while it's up: its desktop marked at once.
        rangWatch = DeskChimes.shared.$all
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { if self?.isUp == true { self?.showRang() } } }
    }

    /// Watching for the Mac waking, the screens changing, and Spaces changing while it's up.
    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Trackpads.shared.restart() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Trackpads.shared.restart() }
            },
            // On another Space while it's up. Just up (four fingers up as the last swipe across
            // was still sliding), or coming up with the fingers: brought along to this one, as
            // it'd be left on the one slid away from. Up a while (gone to another desktop not by a
            // swipe across, which puts it away as it begins): away too. The same one still
            // (Mission Control come and gone): read again.
            workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.spaceChanged() }
            },
            // An app quit while it's up (from it, or anywhere): what's on each read again.
            workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isUp, self.hiding == nil else { return }
                    self.load()
                }
            },
        ]
        DockSwipes.shared.swipedAcross = { [weak self] in self?.swipedAway() }
    }

    /// Up this long, it's just up: a Space change is its coming up catching up, not your going.
    nonisolated static let justUp: TimeInterval = 1.5

    /// Whether a change of Space with it up puts it away (rather than bringing it along).
    nonisolated static func goesAway(moved: Bool, following: Bool, upFor: TimeInterval) -> Bool {
        moved && !following && upFor > justUp
    }

    private func spaceChanged() {
        guard isUp, hiding == nil else { return }
        let now = screen.flatMap { Spaces.current(on: $0) }
        let moved = now != nil && current.map { spaces.indices.contains($0) && spaces[$0].key != now?.key } ?? true
        let upFor = Date().timeIntervalSince(shownAt)
        if Self.goesAway(moved: moved, following: following != nil, upFor: upFor) {
            Self.log.notice("On another desktop with the desktops' list up: put away")
            hide()
            return
        }
        if moved {
            Self.log.notice("The desktops' list came up as the desktop changed (\(String(format: "%.2f", upFor), privacy: .public) s up): brought along to this one")
            panel.orderOut(nil)
            panel.orderFrontRegardless()
            EverySpace.rejoin(panel, on: screen)
            panel.makeKey()
        }
        load()
    }

    /// Swiped across to another desktop while it's up: away at once, as the swipe begins (it'd be
    /// left behind on this one, out of sight, holding Mission Control back still).
    private func swipedAway() {
        guard isUp else { return }
        Self.log.notice("Swiped across to another desktop: the desktops' list away")
        hide()
    }

    /// Four fingers up (and down) read off the trackpads, or not.
    func readTrackpads(_ on: Bool) {
        if on {
            Trackpads.shared.swiped = { [weak self] swipe in self?.swiped(swipe) }
            Trackpads.shared.swipedThree = { [weak self] swipe in self?.swipedThree(swipe) }
            Trackpads.shared.start()
        } else {
            Trackpads.shared.stop()
        }
    }

    /// Up, as four fingers up bring it (settling at once, on the look's own ease); or, up already,
    /// away. Right Shift twice.
    func toggle() {
        putAwayIfUnseen()
        if isUp, hiding == nil {
            close()
            return
        }
        guard isAllowed() else { return }
        if isUp { cancelHiding() } else { show() }
        // Drawn down first, then up from there.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isUp else { return }
            self.settle(open: true)
        }
    }

    /// Up, as four fingers up bring it (if it isn't already): a flick of the wrist up.
    func open() {
        putAwayIfUnseen()
        guard !isUp || hiding != nil else { return }
        toggle()
    }

    /// Away, if it's up: a flick of the wrist down.
    func putAway() {
        guard isUp, hiding == nil else { return }
        close()
    }

    func stop() {
        Trackpads.shared.stop()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        hide()
    }

    // MARK: Following the fingers

    private func swiped(_ swipe: DesktopSwipe) {
        switch swipe {
        case .began(let up):
            if up { putAwayIfUnseen() }
            if up, !isUp || hiding != nil, isAllowed(), !MissionControlSwipe.isTheSystems() {
                following = true
                if !isUp { show() } else { cancelHiding() }
                // (It couldn't be: nothing to follow them with.)
                if !isUp { following = nil }
            } else if !up, isUp, hiding == nil {
                following = false
            } else {
                following = nil
            }
        case .moved(let amount):
            guard let up = following else { return }
            model.interactive = true
            let clamped = min(max(amount, 0), 1.1)
            model.progress = up ? clamped : 1 - min(clamped, 1)
        case .ended(let amount, let speed):
            guard let up = following else { return }
            following = nil
            // Most of the way, or flicked; not if it was coming back as they lifted.
            let went = (amount > 0.35 || speed > 1.5) && speed > -0.8
            let open = up ? went : !went
            if !open { model.finishRenaming(keeping: true) }
            settle(open: open)
        case .cancelled:
            guard let up = following else { return }
            following = nil
            settle(open: !up)
        }
    }

    /// Three fingers down with it up: away, following them, as four fingers down put it (App
    /// Exposé, the Dock's own for three down, held back meanwhile: see `DockSwipes`). Three up, or
    /// three down with it away, are left to the system.
    private func swipedThree(_ swipe: DesktopSwipe) {
        if case .began(let up) = swipe {
            threeDown = !up && isUp && hiding == nil && following == nil
            guard threeDown else { return }
            Self.log.notice("Three fingers down with the desktops' list up: away with them")
        }
        guard threeDown else { return }
        switch swipe {
        case .ended, .cancelled: threeDown = false
        case .began, .moved: break
        }
        swiped(swipe)
    }

    /// Up, as far as it knows, but not to be seen (put away by something else meanwhile): taken
    /// as away, so four fingers up (which it leaves alone while it's up) and right Shift twice
    /// bring it up again rather than doing nothing.
    private func putAwayIfUnseen() {
        guard isUp, hiding == nil, following == nil, !isSeen else { return }
        Self.log.notice("The desktops' list was up but not to be seen: put away")
        hide()
    }

    private static let log = Logger(subsystem: "local.nott", category: "desktops")

    private func settle(open: Bool) {
        model.interactive = false
        model.progress = open ? 1 : 0
        if open {
            cancelHiding()
        } else {
            hideAfterSettling()
        }
    }

    /// Escape: a name being typed left as it was; a shift-click's mark taken off; else away.
    private func escape() {
        if model.renaming != nil {
            model.finishRenaming(keeping: false)
        } else if model.picking != nil {
            withAnimation(model.shuffle) { model.picking = nil }
        } else if model.anchor != nil {
            withAnimation(model.shuffle) { model.anchor = nil }
        } else {
            close()
        }
    }

    /// How long a quit app has to go before it's taken to be asking you something.
    nonisolated static let quitPatience: TimeInterval = 2

    /// An app quit from the list, as ⌘Q would: it may ask first (to save, say), under the list,
    /// so one still up a moment on is gone to. (Read again as it goes, see `start`.)
    private func quit(_ app: DesktopsModel.App) {
        guard let running = NSRunningApplication(processIdentifier: app.id),
              DesktopsModel.canQuit(app.id, bundle: running.bundleIdentifier) else { return }
        let desk = model.desks.first { $0.apps.contains { $0.id == app.id } }
        Self.log.notice("Quitting \(app.name, privacy: .public) from the desktops' list (on \(self.model.desktops(with: app.id)) desktops)")
        running.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitPatience) { [weak self] in
            guard let self, self.isUp, self.hiding == nil, !running.isTerminated, let desk else { return }
            Self.log.notice("\(app.name, privacy: .public) still up: gone to it, in case it's asking something")
            self.close(goingTo: desk)
        }
    }

    /// Away. With `desk` picked, gone at once (no easing out) and straight to it, with no slide.
    /// Otherwise down and away.
    func close(goingTo desk: DesktopsModel.Desk? = nil) {
        guard isUp, hiding == nil else { return }
        following = nil
        model.finishRenaming(keeping: true)
        guard let desk else {
            settle(open: false)
            return
        }
        let from = current, target = spaces.firstIndex { $0.key == desk.id }, screen = screen
        hide()
        if let from, let target, let screen { InstantSpaces.go(from: from, to: target, on: screen) }
    }

    private func hideAfterSettling() {
        cancelHiding()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hiding = work
        DispatchQueue.main.asyncAfter(deadline: .now() + model.settleTime + 0.3, execute: work)
    }

    private func cancelHiding() {
        hiding?.cancel()
        hiding = nil
    }

    // MARK: Up and down

    private func show() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        self.screen = screen
        cancelHiding()
        model.interactive = true
        model.progress = 0
        model.size = screen.frame.size
        model.hovered = nil
        model.selected = nil
        model.renaming = nil
        model.optionHeld = NSEvent.modifierFlags.contains(.option)
        model.desks = []
        model.showsClock = Feature.desktopsClock.isOn
        // Midnight's sky: new constellations each time it comes up, drawn in from now (at once,
        // with motion reduced).
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.sky = DesktopsSky.Opening(seed: .random(in: 1...UInt64.max), at: still ? .distantPast : Date())
        panel.setFrame(screen.frame, display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // On every Space, as it can have been left on just some, out of sight on the rest.
        EverySpace.rejoin(panel, on: screen)
        guard panel.isOnActiveSpace else {
            // Not to be seen here even so: not up at all, so three fingers up aren't held back.
            let on = SpaceApps.spaces(ofWindow: CGWindowID(max(panel.windowNumber, 0)))
            Self.log.notice("The desktops' list couldn't be put on this desktop (it's on \(on.count) of \(EverySpace.spaces(on: screen).count) Spaces): not up")
            panel.orderOut(nil)
            return
        }
        panel.makeKey()
        isUp = true
        shownAt = Date()
        // Three fingers up (or down) don't open Mission Control (or App Exposé) over it.
        DockSwipes.shared.block(true)
        Self.log.notice("The desktops' list up")
        watching?.invalidate()
        watching = Timer.scheduledTimer(withTimeInterval: Self.watchEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
        load()
    }

    /// Up still, as Mission Control (or the start of it, as a swipe's taken for its) closes: in front
    /// again, as it can be left out of sight on the Space it's come back to though it's still up.
    func refront() {
        guard isUp, hiding == nil else { return }
        Self.log.notice("Mission Control's gone with the desktops' list up: brought to the front again")
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        EverySpace.rejoin(panel, on: screen)
        panel.makeKey()
    }

    nonisolated static let watchEvery: TimeInterval = 0.5

    /// Up, but out of sight (not on the Space showing, however it came to be): put back on every
    /// Space and in front; out of sight still, away, as it's holding three fingers up back.
    private func watch() {
        guard isUp, hiding == nil, following == nil, !isSeen else { return }
        EverySpace.rejoin(panel, on: screen)
        panel.orderFrontRegardless()
        if isSeen {
            Self.log.notice("The desktops' list was up out of sight: brought back to this desktop")
        } else {
            Self.log.notice("The desktops' list was up out of sight and couldn't be brought back: put away")
            hide()
        }
    }

    private var isSeen: Bool { panel.isVisible && panel.isOnActiveSpace }

    private func hide() {
        hiding?.cancel()
        hiding = nil
        watching?.invalidate()
        watching = nil
        readingApps?.cancel()
        readingApps = nil
        readingAgents?.cancel()
        readingAgents = nil
        following = nil
        threeDown = false
        panel.orderOut(nil)
        if isUp { Self.log.notice("The desktops' list away") }
        isUp = false
        DockSwipes.shared.block(false)
        model.progress = 0
        model.renaming = nil
        model.dragging = nil
        model.dragAt = nil
        model.dragShift = .zero
        model.anchor = nil
        model.picking = nil
        model.optionHeld = false
    }

    /// The Spaces, then what's on each.
    private func load() {
        guard let screen else { return }
        readSpaces(on: screen)
        readingApps?.cancel()
        readingApps = Task { @MainActor [weak self] in
            let apps = await Task.detached(priority: .userInitiated) { SpaceApps.read() }.value
            guard let self, !Task.isCancelled else { return }
            self.fill(apps)
        }
        readAgents()
    }

    /// The agents again, as they've changed while the list's up.
    func agentsChanged() {
        guard isUp, hiding == nil, !spaces.isEmpty else { return }
        readAgents()
    }

    /// Which desktops agents are at work on, now (see `AgentLife`): by their app's windows (and
    /// then remembered as seen there), else (a Claude) where it was last seen.
    private func readAgents() {
        readingAgents?.cancel()
        let candidates = working().compactMap { session -> (AgentSession, pid_t)? in
            guard AgentLife.isAtIt(session.activity), session.pid > 0, let app = AgentWindow.hostApp(of: session.pid) else { return nil }
            return (session, app.processIdentifier)
        }
        guard !candidates.isEmpty else {
            if !model.atWork.isEmpty { model.atWork = [:] }
            Self.log.notice("Agents at work: none")
            return
        }
        readingAgents = Task { @MainActor [weak self] in
            let (sessions, numbers) = await Task.detached(priority: .userInitiated) { () -> ([(AgentSession, pid_t)], [Int?]) in
                let still = Set(AgentLife.atIt(candidates.map(\.0)).map(\.id))
                let sessions = candidates.filter { still.contains($0.0.id) }
                return (sessions, sessions.map { SessionDesk.space(of: $0.0, app: $0.1) })
            }.value
            guard let self, !Task.isCancelled else { return }
            var counts: [String: Int] = [:]
            var told: [String] = []
            for ((session, _), number) in zip(sessions, numbers) {
                let byWindows = number.flatMap { number in self.spaces.first { $0.id == number } }
                if let byWindows { SeenDesks.shared.remember(session, on: byWindows) }
                let seen = byWindows == nil ? SeenDesks.shared.keys(of: session).flatMap { keys in
                    self.spaces.first { SpaceGroups.keys(of: $0).contains(where: keys.contains) }
                } : nil
                let space = byWindows ?? seen
                if let space { counts[space.key, default: 0] += 1 }
                let index = space.flatMap { space in self.spaces.firstIndex { $0.key == space.key } }
                told.append("\(session.host ?? "?") \(session.activity.title): " + (byWindows != nil ? "by its windows" : seen != nil ? "where last seen" : "not found")
                            + (index.map { ", desktop \($0 + 1)" } ?? ""))
            }
            let dropped = candidates.count - sessions.count
            Self.log.notice("Agents at work: \(told.joined(separator: "; "), privacy: .public)\(dropped > 0 ? " (\(dropped) whose turn's over left out)" : "", privacy: .public)")
            if counts != self.model.atWork { self.model.atWork = counts }
        }
    }

    /// The Spaces as they are.
    private func readSpaces(on screen: NSScreen) {
        guard let display = FullscreenSpace.display(for: screen) else {
            spaces = []
            current = nil
            model.desks = []
            return
        }
        let all = Spaces.all(in: display, boot: Spaces.bootTime) { NSRunningApplication(processIdentifier: $0)?.localizedName }
        spaces = all.spaces
        current = all.current
        let names = SpaceNames()
        let before = Dictionary(model.desks.map { ($0.id, $0.apps) }, uniquingKeysWith: { first, _ in first })
        SpaceGroups.tidy()
        let groups = SpaceGroups().all
        model.groups = groups.map { DesktopsModel.Group(id: $0.id, name: $0.name, folded: $0.folded) }
        model.desks = all.spaces.enumerated().map { index, space in
            DesktopsModel.Desk(id: space.key, name: names.name(of: space), standard: space.standard, isFullscreen: space.isFullscreen,
                               isCurrent: index == all.current, apps: before[space.key] ?? [],
                               group: SpaceGroups.group(of: space, in: groups)?.id)
        }
        showSounds()
    }

    /// Each desktop's own sound, named on its row; and whether sounds are on to pick them.
    private func showSounds() {
        let all = ChimeVoice.all(), chimes = ChimeSettings.shared
        model.picksSounds = Feature.agentSounds.isOn
        model.fallbackSound = chimes.voice(for: ChimeSettings.elsewhere, among: all).name
        var names: [String: String] = [:]
        for space in spaces { if let voice = chimes.desk(space, among: all) { names[space.key] = voice.name } }
        model.soundNames = model.picksSounds ? names : [:]
        showRang()
    }

    /// Where a sound's just come from, marked on its row.
    private func showRang() {
        var rang: [String: DeskChimes.Rang] = [:]
        for space in spaces { if let latest = DeskChimes.shared.latest(for: space) { rang[space.key] = latest } }
        if rang != model.rang { model.rang = rang }
    }

    /// The groups as they're kept, shown again (the desktops as they were read).
    private func showGroups() {
        let groups = SpaceGroups().all
        let byKey = Dictionary(spaces.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        model.groups = groups.map { DesktopsModel.Group(id: $0.id, name: $0.name, folded: $0.folded) }
        model.desks = model.desks.map { desk in
            var desk = desk
            desk.group = byKey[desk.id].flatMap { SpaceGroups.group(of: $0, in: groups)?.id }
            return desk
        }
    }

    /// A desktop let go of in a group, a new one, or out of one; or a group done away with. A new
    /// group's named straight away.
    private func regroup(_ change: DesktopsModel.Regroup) {
        let store = SpaceGroups()
        func find(_ id: String) -> CurrentSpace? { spaces.first { $0.key == id } }
        var made: String?
        switch change {
        case .with(let desk, let other):
            guard let space = find(desk), let other = find(other) else { return }
            made = store.make(space, with: other)
        case .into(let desk, let group):
            guard let space = find(desk) else { return }
            store.put(space, in: group)
        case .out(let desk):
            guard let space = find(desk) else { return }
            store.takeOut(space)
        case .ungroup(let group):
            store.ungroup(group)
        case .gather(let desks):
            let found = desks.compactMap(find)
            guard found.count > 1 else { return }
            made = store.make(found)
        }
        withAnimation(model.shuffle) { showGroups() }
        if let made { model.startRenaming(group: made) }
    }

    /// Each desktop's apps, by the Spaces' numbers: a fullscreen app's own first.
    private func fill(_ apps: [Int: [pid_t]]) {
        var known: [pid_t: DesktopsModel.App] = [:]
        func app(_ pid: pid_t) -> DesktopsModel.App? {
            if let found = known[pid] { return found }
            guard let running = NSRunningApplication(processIdentifier: pid) else { return nil }
            let made = DesktopsModel.App(id: pid, name: running.localizedName ?? "", icon: running.icon,
                                         quittable: DesktopsModel.canQuit(pid, bundle: running.bundleIdentifier))
            known[pid] = made
            return made
        }
        let byKey = Dictionary(spaces.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        model.desks = model.desks.map { desk in
            guard let space = byKey[desk.id] else { return desk }
            var pids = apps[space.id] ?? []
            if let own = space.pid {
                pids.removeAll { $0 == own }
                pids.insert(own, at: 0)
            }
            var filled = desk
            filled.apps = pids.compactMap(app)
            return filled
        }
    }

    // MARK: The keyboard

    /// ↑ and ↓ pick a line, Return goes to it (or folds or opens out a group); ← folds the group
    /// picked, → opens it out.
    private func pressed(_ event: NSEvent) -> Bool {
        guard model.renaming == nil, model.dragging == nil else { return false }
        switch event.keyCode {
        case 126:
            withAnimation(model.shuffle) { model.select(by: -1) }
        case 125:
            withAnimation(model.shuffle) { model.select(by: 1) }
        case 123, 124:
            guard let group = model.selectedGroup else { return false }
            withAnimation(model.shuffle) { model.fold(group.id, event.keyCode == 123) }
        case 36, 76:
            if let group = model.groups.first(where: { DesktopsModel.headingID($0.id) == model.selected }) {
                withAnimation(model.shuffle) { model.fold(group.id, !group.folded) }
                return true
            }
            guard let desk = model.desks.first(where: { $0.id == model.selected }) else { close(); return true }
            close(goingTo: desk)
        default:
            return false
        }
        return true
    }

    // MARK: Renaming

    private func rename(_ desk: DesktopsModel.Desk, to name: String) {
        guard let space = spaces.first(where: { $0.key == desk.id }) else { return }
        let names = SpaceNames()
        names.rename(space, to: name)
        let named = names.name(of: space)
        if let index = model.desks.firstIndex(where: { $0.id == desk.id }) { model.desks[index].name = named }
    }
}
