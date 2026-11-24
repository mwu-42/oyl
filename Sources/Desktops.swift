import AppKit
import ApplicationServices
import SwiftUI

// Four fingers up (or right Shift twice): your desktops and fullscreen apps in a list, in the order
// they're in, each by its name (a fullscreen app's by its app's, as the menu bar's label names them)
// with the icons of the apps on it. Click one to go straight to it; point at one to rename it.
// (They can't be put in another order from here: macOS keeps that in the Dock, and short of turning
// System Integrity Protection off, only Mission Control can change it, by dragging.) macOS's own
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
/// go; it's over as soon as one lifts, and nothing more's made of them till they're all off. (Three
/// are left alone: they're Mission Control's, and the hand pointer's.)
struct SwipeRecognizer {
    /// How many fingers.
    static let fingers = 4
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
            if touching == Self.fingers { phase = .watching(x: x, y: y) }
            return []
        case .watching(let startX, let startY):
            guard touching == Self.fingers else {
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
            if touching > Self.fingers {
                phase = .done
                return [.cancelled]
            }
            guard touching == Self.fingers else {
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
        let swipes = lock.withLock { recognizer.frame(touching: touching, x: x, y: y, at: time) }
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

// MARK: - What's shown

@MainActor
final class DesktopsModel: ObservableObject {
    struct App: Identifiable, Equatable {
        let id: pid_t
        let name: String
        let icon: NSImage?
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

        /// A desktop still called by its number: what's on it says more, so its apps are named too.
        var namesApps: Bool { !isFullscreen && name == standard && !apps.isEmpty }
    }

    /// How far up it's come: 0 is gone, 1 all the way up.
    @Published var progress: Double = 0
    /// Following the fingers (so no easing), rather than settling.
    @Published var interactive = true
    /// In the Spaces' own order.
    @Published var desks: [Desk] = []
    @Published var size = CGSize(width: 1440, height: 900)
    @Published var theme = NotchTheme.standard
    @Published var hovered: String?
    /// Picked with the arrow keys.
    @Published var selected: String?
    /// Being renamed, and what's been typed.
    @Published var renaming: String?
    @Published var draft = ""

    var pick: (Desk) -> Void = { _ in }
    var renamed: (Desk, String) -> Void = { _, _ in }
    var dismiss: () -> Void = {}

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
    var rowHeight: CGFloat {
        let usual: CGFloat = theme == .midnight ? 38 : 30
        return min(usual, max(22, size.height * 0.62 / CGFloat(max(desks.count, 1))))
    }

    // MARK: The keyboard

    /// The next or last row picked (the one you're on, to begin with).
    func select(by step: Int) {
        guard !desks.isEmpty else { return }
        let at = desks.firstIndex { $0.id == selected } ?? desks.firstIndex(where: \.isCurrent) ?? 0
        selected = desks[min(max(at + (selected == nil ? 0 : step), 0), desks.count - 1)].id
    }

    // MARK: Renaming

    func startRenaming(_ desk: Desk) {
        draft = desk.name
        renaming = desk.id
    }

    /// Done typing: what's been typed kept (`keeping`), or not.
    func finishRenaming(keeping: Bool) {
        guard let id = renaming else { return }
        renaming = nil
        if keeping, let desk = desks.first(where: { $0.id == id }), draft != desk.name { renamed(desk, draft) }
    }
}

/// The desktops, in a list. In Oyl's look it's a plain black card in the middle of the screen, a
/// little way down, each row a name (the one you're on in bold, with a dot), the names of the apps
/// on a desktop still called by its number, and their icons; a row pointed at is lit, with a pencil
/// to rename it. In Midnight Oyl's the
/// screen goes to night (stars twinkling over ink), and the list's set off to the left under its
/// title in a flourish, the names in Superclarendon strung down a line of stars that bows out and
/// back, the one you're on lit by a glint; they drift in one after another out of a blur.
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
                DesktopsStars(size: model.size)
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
        VStack(alignment: .leading, spacing: 4) {
            DesktopsRows(model: model)
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.84)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.09)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .opacity(shown)
        .offset(y: (1 - shown) * 16)
        .animation(model.settle(), value: model.progress)
        .frame(width: model.size.width, alignment: .top)
        .padding(.top, model.size.height * 0.24)
    }
}

/// Midnight's: off to the left of the middle, under its title.
private struct MidnightDesks: View {
    @ObservedObject var model: DesktopsModel

    var body: some View {
        let shown = min(max(model.progress, 0), 1)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                FourPointStar()
                    .fill(Midnight.starlight)
                    .frame(width: 9, height: 9)
                Text("the desktops")
                    .font(Midnight.flourish(19))
                    .foregroundStyle(Midnight.silver.opacity(0.72))
            }
            .opacity(shown)
            .offset(x: -(1 - shown) * 30)
            .blur(radius: (1 - shown) * 4)
            .animation(model.settle(), value: model.progress)
            DesktopsRows(model: model)
        }
        .frame(width: 470, alignment: .leading)
        .padding(.leading, model.size.width * 0.19)
        .padding(.top, model.size.height * 0.22)
    }
}

/// The rows. In Midnight Oyl's they bow out to the right and back, down a line of stars.
private struct DesktopsRows: View {
    @ObservedObject var model: DesktopsModel
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let midnight = theme == .midnight, height = model.rowHeight, count = model.desks.count
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.desks.enumerated()), id: \.element.id) { index, desk in
                DeskRow(model: model, desk: desk, height: height)
                    .padding(.leading, midnight ? Self.bow(index, of: count) : 0)
                    .modifier(DeskDrift(model: model, index: index, count: count, on: midnight))
            }
        }
        .background(alignment: .topLeading) {
            if midnight {
                DeskLine(points: (0..<count).map { CGPoint(x: Self.bow($0, of: count) + DeskRow.markerMiddle, y: (CGFloat($0) + 0.5) * height) })
                    .trim(from: 0, to: min(max(model.progress, 0), 1))
                    .stroke(Midnight.silver.opacity(0.2), style: StrokeStyle(lineWidth: 0.7, lineCap: .round, lineJoin: .round))
                    .animation(model.settle(delay: 0.1), value: model.progress)
                    .allowsHitTesting(false)
            }
        }
    }

    /// How far right the row at `index` sits, of `count`: furthest in the middle.
    static func bow(_ index: Int, of count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        return 30 * sin(.pi * (CGFloat(index) + 0.5) / CGFloat(count))
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

/// A desktop: its name, what's on it, and (pointed at) a way to rename it. Click it to go there.
private struct DeskRow: View {
    @ObservedObject var model: DesktopsModel
    let desk: DesktopsModel.Desk
    let height: CGFloat
    @FocusState private var typing: Bool
    @Environment(\.notchTheme) private var theme

    /// Where the star (or dot) before the name is, across.
    static let markerMiddle: CGFloat = 14
    static let mostIcons = 6

    private var renaming: Bool { model.renaming == desk.id }
    private var lit: Bool { model.hovered == desk.id || model.selected == desk.id }

    var body: some View {
        let midnight = theme == .midnight
        HStack(spacing: midnight ? 10 : 8) {
            marker(midnight: midnight)
            name(midnight: midnight)
            if desk.namesApps, !renaming { appNames(midnight: midnight) }
            icons(midnight: midnight)
            Spacer(minLength: 8)
            if lit, !renaming { renameButton(midnight: midnight) }
        }
        .padding(.horizontal, midnight ? 6 : 10)
        .frame(height: height)
        .background(highlight(midnight: midnight))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                model.hovered = desk.id
            } else if model.hovered == desk.id {
                model.hovered = nil
            }
        }
        .onTapGesture {
            guard !renaming else { return }
            model.pick(desk)
        }
        .animation(.easeOut(duration: 0.15), value: lit)
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
            TextField("", text: $model.draft)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(midnight ? Midnight.white : .white)
                .focused($typing)
                .onSubmit { model.finishRenaming(keeping: true) }
                .onAppear { DispatchQueue.main.async { typing = true } }
                .frame(width: midnight ? 240 : 200)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(midnight ? AnyShapeStyle(LinearGradient(colors: [Midnight.moonlight.opacity(0.14), .clear],
                                                                      startPoint: .leading, endPoint: .trailing))
                                     : AnyShapeStyle(Color.white.opacity(0.12)),
                            in: RoundedRectangle(cornerRadius: midnight ? 2 : 5, style: .continuous))
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
        let side: CGFloat = midnight ? 17 : 16
        return HStack(spacing: midnight ? 4 : 3) {
            ForEach(desk.apps.prefix(Self.mostIcons)) { app in
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: side, height: side)
                        .saturation(midnight ? 0.55 : 1)
                        .opacity(midnight ? (lit ? 0.95 : 0.72) : 1)
                        .help(app.name)
                }
            }
            if desk.apps.count > Self.mostIcons {
                Text("+\(desk.apps.count - Self.mostIcons)")
                    .font(midnight ? Midnight.italic(11) : .system(size: 10.5, weight: .medium))
                    .foregroundStyle(midnight ? Midnight.silver.opacity(0.5) : .white.opacity(0.45))
            }
        }
        .offset(x: midnight && lit ? 4 : 0)
    }

    private func renameButton(midnight: Bool) -> some View {
        Button { model.startRenaming(desk) } label: {
            if midnight {
                Text("rename")
                    .font(Midnight.italic(12))
                    .foregroundStyle(Midnight.silver.opacity(0.6))
            } else {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help("Rename")
        .transition(.opacity)
    }

    @ViewBuilder private func highlight(midnight: Bool) -> some View {
        if midnight {
            // A wash of moonlight with no edge: fading in from the left, off to the right, and above and below.
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Midnight.moonlight.opacity(lit ? 0.13 : 0), location: 0.08),
                                   .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                .mask(LinearGradient(colors: [.clear, .white, .clear], startPoint: .top, endPoint: .bottom))
                .padding(.vertical, -4)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(lit ? 0.09 : 0))
        }
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

/// Midnight's sky behind the desktops: stars twinkling, each at its own pace.
private struct DesktopsStars: View {
    let size: CGSize

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                var seed: UInt64 = 7
                func next() -> Double {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return Double(seed >> 11) / Double(1 << 53)
                }
                for _ in 0..<160 {
                    let x = next() * size.width, y = next() * size.height
                    let base = 0.3 + next() * 0.8, rate = 0.4 + next() * 1.6, phase = next() * 2 * .pi
                    let twinkle = 0.5 + 0.5 * sin(time * rate + phase)
                    let radius = base * (0.7 + 0.5 * twinkle)
                    var star = context
                    star.opacity = 0.15 + 0.55 * twinkle * base
                    star.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)),
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

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { escape() }

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
/// else it goes back down. Right Shift twice brings it up too. Four fingers down, right Shift
/// twice, Escape, or a click off the list puts it away; a click on a desktop, at once, as you go
/// straight there.
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
    /// A swipe being followed, and which way.
    private var following: Bool?
    private var hiding: DispatchWorkItem?
    private var readingApps: Task<Void, Never>?
    private var observers: [Any] = []
    /// Whether it can come up now (not while Oyl's off, or nothing can be seen).
    var isAllowed: () -> Bool = { true }

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
        model.dismiss = { [weak self] in self?.close() }
        model.pick = { [weak self] desk in self?.close(goingTo: desk) }
        model.renamed = { [weak self] desk, name in self?.rename(desk, to: name) }
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
            // Swiped across to another Space while it's up: that one's the one you're on.
            workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isUp, self.following == nil, self.hiding == nil else { return }
                    self.load()
                }
            },
        ]
    }

    /// Four fingers up (and down) read off the trackpads, or not.
    func readTrackpads(_ on: Bool) {
        if on {
            Trackpads.shared.swiped = { [weak self] swipe in self?.swiped(swipe) }
            Trackpads.shared.start()
        } else {
            Trackpads.shared.stop()
        }
    }

    /// Up, as four fingers up bring it (settling at once, on the look's own ease); or, up already,
    /// away. Right Shift twice.
    func toggle() {
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
            if up, !isUp || hiding != nil, isAllowed(), !MissionControlSwipe.isTheSystems() {
                following = true
                if !isUp { show() } else { cancelHiding() }
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

    private func settle(open: Bool) {
        model.interactive = false
        model.progress = open ? 1 : 0
        if open {
            cancelHiding()
        } else {
            hideAfterSettling()
        }
    }

    /// Escape: a name being typed left as it was; else away.
    private func escape() {
        if model.renaming != nil {
            model.finishRenaming(keeping: false)
        } else {
            close()
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
        model.desks = []
        panel.setFrame(screen.frame, display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        isUp = true
        load()
    }

    private func hide() {
        hiding?.cancel()
        hiding = nil
        readingApps?.cancel()
        readingApps = nil
        following = nil
        panel.orderOut(nil)
        isUp = false
        model.progress = 0
        model.renaming = nil
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
        model.desks = all.spaces.enumerated().map { index, space in
            DesktopsModel.Desk(id: space.key, name: names.name(of: space), standard: space.standard, isFullscreen: space.isFullscreen,
                               isCurrent: index == all.current, apps: before[space.key] ?? [])
        }
    }

    /// Each desktop's apps, by the Spaces' numbers: a fullscreen app's own first.
    private func fill(_ apps: [Int: [pid_t]]) {
        var known: [pid_t: DesktopsModel.App] = [:]
        func app(_ pid: pid_t) -> DesktopsModel.App? {
            if let found = known[pid] { return found }
            guard let running = NSRunningApplication(processIdentifier: pid) else { return nil }
            let made = DesktopsModel.App(id: pid, name: running.localizedName ?? "", icon: running.icon)
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

    /// ↑ and ↓ pick a row, Return goes to it.
    private func pressed(_ event: NSEvent) -> Bool {
        guard model.renaming == nil else { return false }
        switch event.keyCode {
        case 126:
            withAnimation(model.shuffle) { model.select(by: -1) }
        case 125:
            withAnimation(model.shuffle) { model.select(by: 1) }
        case 36, 76:
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
