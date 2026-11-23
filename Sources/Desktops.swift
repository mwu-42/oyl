import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

// Three fingers up: Oyl's own view of your desktops, in place of Mission Control's. Along the top
// are your desktops and fullscreen apps, in order, each with its name; under them the windows of
// the one you're on, spread out from where they are. It comes up with your fingers and settles as
// they lift; click a desktop to go to it, or a window to bring it to the front. macOS's own swipe
// has to be off (or moved to four fingers) for three fingers up to be Oyl's: see `MissionControlSwipe`.

// MARK: - Three fingers on the trackpad

/// A three-finger swipe up or down, as `SwipeRecognizer` makes it out of the trackpad's frames.
enum DesktopSwipe: Equatable {
    /// Begun, upward or downward.
    case began(up: Bool)
    /// How far it's gone the way it began: 0 to 1 is the whole way (it can go past, or back).
    case moved(Double)
    /// Let go: how far it got, and how fast it was going the way it began (whole ways a second).
    case ended(Double, speed: Double)
    /// A fourth finger came down: not a swipe of these after all.
    case cancelled
}

/// Makes three-finger swipes up and down out of the trackpad's frames. Three fingers down, then
/// moving mostly up or down (across is the system's, between Spaces), and they're followed as they
/// go; it's over as soon as one lifts, and nothing more's made of them till they're all off.
struct SwipeRecognizer {
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
            if touching == 3 { phase = .watching(x: x, y: y) }
            return []
        case .watching(let startX, let startY):
            guard touching == 3 else {
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
            if touching > 3 {
                phase = .done
                return [.cancelled]
            }
            guard touching == 3 else {
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
/// just no swipes), for three-finger swipes up and down. Each frame, on the trackpad's own thread,
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

/// Whether macOS takes three fingers up for Mission Control itself: its swipe is on (it is till
/// it's turned off in System Settings › Trackpad › More Gestures) and on three fingers. While it
/// is, three fingers up are left to it.
enum MissionControlSwipe {
    static func isTheSystems() -> Bool {
        for domain in ["com.apple.dock", "com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
            CFPreferencesAppSynchronize(domain as CFString)
        }
        let on = CFPreferencesCopyAppValue("showMissionControlGestureEnabled" as CFString, "com.apple.dock" as CFString) as? Bool ?? true
        return on && TrackpadSettings.read().swipesUpAndDown
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

// MARK: - Pictures of each desktop

/// A picture of each desktop as it was when you were last on it, kept here only (never on disk),
/// for the desktops' row: taken a moment after you get to one, every couple of minutes while you
/// stay, and as the desktops come up.
@MainActor
final class DesktopSnapshots {
    private(set) var pictures: [String: NSImage] = [:]
    private var later: DispatchWorkItem?
    private var refresh: Timer?
    private var observer: Any?
    /// Not while nothing on the screens can be seen (the lid's shut), or Oyl's off.
    var isResting = false

    static let width: CGFloat = 640

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.arrived() }
        }
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.take(inBackground: true) } }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
        arrived()
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        refresh?.invalidate()
        refresh = nil
        later?.cancel()
        pictures = [:]
    }

    /// On a desktop just come to: its picture once it's settled there.
    private func arrived() {
        later?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { _ = Task { await self?.take(inBackground: true) } }
        }
        later = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// The desktop showing on the screen with the pointer (or `screen`), as it is now, without
    /// Oyl's own windows. Only with Screen Recording allowed (it isn't asked for here); and in the
    /// background (as you get to one, and now and then), only once three fingers up are Oyl's.
    @discardableResult
    func take(on screen: NSScreen? = nil, inBackground: Bool = false) async -> NSImage? {
        guard !isResting, CGPreflightScreenCaptureAccess() else { return nil }
        if inBackground, MissionControlSwipe.isTheSystems() { return nil }
        let pointer = NSEvent.mouseLocation
        guard let screen = screen ?? NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main,
              let key = Spaces.current(on: screen)?.key,
              let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == number }) else { return nil }
        let oyl = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(Self.width)
        configuration.height = Int((Self.width * CGFloat(display.height) / CGFloat(max(display.width, 1))).rounded())
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingApplications: oyl, exceptingWindows: []),
            configuration: configuration) else { return nil }
        // Still on the same desktop, or it's not this one's picture.
        guard Spaces.current(on: screen)?.key == key else { return nil }
        let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        pictures[key] = picture
        return picture
    }
}

// MARK: - What's shown

@MainActor
final class DesktopsModel: ObservableObject {
    struct Space: Identifiable, Equatable {
        let id: String
        let name: String
        let isFullscreen: Bool
        let isCurrent: Bool
        var picture: NSImage?
        /// A fullscreen app's icon, for before there's a picture.
        var icon: NSImage?
    }

    struct Window: Identifiable, Equatable {
        let id: CGWindowID
        let pid: pid_t
        let title: String
        let app: String
        /// Where it is on the screen, from its top left.
        let frame: CGRect
        var icon: NSImage?
        var picture: CGImage?
    }

    /// How far up it's come: 0 is the screen as it is, 1 all the way up.
    @Published var progress: Double = 0
    /// Following the fingers (so no easing), rather than settling.
    @Published var interactive = true
    @Published var spaces: [Space] = []
    /// Back to front.
    @Published var windows: [Window] = []
    @Published var size = CGSize(width: 1440, height: 900)
    /// The desktop picture behind it all.
    @Published var backdrop: NSImage?
    @Published var theme = NotchTheme.standard
    @Published var hoveredSpace: String?
    @Published var hoveredWindow: CGWindowID?
    /// The window picked, kept on top as the rest go back.
    @Published var chosen: CGWindowID?
    /// Screen Recording isn't allowed, so there are no pictures.
    @Published var needsPermission = false

    var pick: (Space) -> Void = { _ in }
    var choose: (Window) -> Void = { _ in }
    var dismiss: () -> Void = {}

    /// How long it takes to settle, in this look: Oyl's a plain ease, Midnight's a slow drift.
    var settleTime: Double { theme == .midnight ? 0.55 : 0.28 }

    func settle(delay: Double = 0) -> Animation? {
        guard !interactive else { return nil }
        return theme == .midnight ? .timingCurve(0.45, 0, 0.25, 1, duration: settleTime).delay(delay)
            : .easeOut(duration: settleTime).delay(delay)
    }
}

/// Where everything goes, for a screen `size` big: the desktops' row along the top (in Midnight
/// Oyl, along an arc, its highest point off to the left of the middle), and the windows spread
/// out under it.
struct DesktopsLayout {
    let size: CGSize
    let tiles: [CGRect]
    let windows: [CGRect]
    /// The row's height, all of it.
    let stripHeight: CGFloat

    init(size: CGSize, spaces: Int, windows frames: [CGRect], midnight: Bool) {
        self.size = size
        let aspect = size.width / max(size.height, 1)
        let rowWidth = size.width - 80
        var height = min(size.height * 0.12, 120)
        let gap: CGFloat = midnight ? 30 : 20
        // Narrower if they'd run off the sides.
        if spaces > 0 {
            let width = (rowWidth - CGFloat(spaces - 1) * gap) / CGFloat(spaces)
            height = min(height, width / aspect)
        }
        let width = height * aspect
        let total = CGFloat(spaces) * width + CGFloat(max(spaces - 1, 0)) * gap
        let top: CGFloat = midnight ? 34 : 28
        let lift: CGFloat = midnight ? height * 0.22 : 0
        tiles = (0..<spaces).map { index in
            let x = (size.width - total) / 2 + CGFloat(index) * (width + gap)
            // Midnight's arc: highest 40% of the way along, falling away either side.
            let along = spaces > 1 ? Double(index) / Double(spaces - 1) : 0.4
            let y = top + lift * CGFloat(pow((along - 0.4) / 0.6, 2))
            return CGRect(x: x, y: y, width: width, height: height)
        }
        stripHeight = top + height + lift + 34
        let area = CGRect(x: 56, y: stripHeight + 24, width: size.width - 112, height: size.height - stripHeight - 24 - 48)
        windows = Self.spread(frames, in: area, gap: midnight ? 40 : 28)
    }

    /// Windows spread out to fill `area` without overlapping, as big as they can be (never bigger
    /// than they are), each as it's shaped, in rows: as many rows as makes them biggest, the rows in
    /// order of where they are up the screen, and along each, of where they are across.
    static func spread(_ frames: [CGRect], in area: CGRect, gap: CGFloat) -> [CGRect] {
        let count = frames.count
        guard count > 0, area.width > 0, area.height > 0 else { return frames }
        var best: (rows: Int, scale: [CGFloat], covered: CGFloat)?
        for rows in 1...count {
            let columns = Int((Double(count) / Double(rows)).rounded(.up))
            let cellWidth = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            guard cellWidth > 20, cellHeight > 20 else { continue }
            let scales = frames.map { min(cellWidth / max($0.width, 1), cellHeight / max($0.height, 1), 1) }
            let covered = zip(frames, scales).reduce(0) { $0 + $1.0.width * $1.0.height * $1.1 * $1.1 }
            if best.map({ covered > $0.covered + 0.5 }) ?? true { best = (rows, scales, covered) }
        }
        guard let best else { return frames }
        let columns = Int((Double(count) / Double(best.rows)).rounded(.up))
        let cellWidth = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (area.height - gap * CGFloat(best.rows - 1)) / CGFloat(best.rows)
        // Top to bottom into rows, then each row left to right.
        let byHeight = frames.indices.sorted { frames[$0].midY != frames[$1].midY ? frames[$0].midY < frames[$1].midY : $0 < $1 }
        var placed = frames
        for row in 0..<best.rows {
            let start = row * columns
            guard start < count else { break }
            let members = byHeight[start..<min(start + columns, count)].sorted { frames[$0].midX < frames[$1].midX }
            // A short last row, in the middle.
            let rowWidth = CGFloat(members.count) * cellWidth + CGFloat(members.count - 1) * gap
            let left = area.minX + (area.width - rowWidth) / 2
            for (column, index) in members.enumerated() {
                let scale = best.scale[index]
                let size = CGSize(width: frames[index].width * scale, height: frames[index].height * scale)
                let cell = CGRect(x: left + CGFloat(column) * (cellWidth + gap), y: area.minY + CGFloat(row) * (cellHeight + gap),
                                  width: cellWidth, height: cellHeight)
                placed[index] = CGRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height)
            }
        }
        return placed
    }

    static func between(_ from: CGRect, _ to: CGRect, _ amount: Double) -> CGRect {
        let t = CGFloat(min(max(amount, 0), 1))
        return CGRect(x: from.minX + (to.minX - from.minX) * t, y: from.minY + (to.minY - from.minY) * t,
                      width: from.width + (to.width - from.width) * t, height: from.height + (to.height - from.height) * t)
    }
}

/// The desktops and the windows, in Oyl's look or Midnight Oyl's.
///
/// In Oyl's look it's Mission Control's own arrangement: your desktop picture, dimmed, behind a dark
/// row of your desktops (the one you're on ringed in white, the one pointed at lifted and lit), and
/// the windows on rounded pictures with a shadow, a name on a pill under the one pointed at; it all
/// settles on a plain ease. In Midnight Oyl's it's the night: stars twinkling over ink, your
/// desktops strung along an arc as a constellation, each a soft-edged picture with no frame, the
/// one you're on in a pool of moonlight with a glint at its corner, and the windows' pictures
/// soft-edged too, drifting into place one after another, their names in Midnight's faces.
struct DesktopsView: View {
    @ObservedObject var model: DesktopsModel

    var body: some View {
        let midnight = model.theme == .midnight
        let layout = DesktopsLayout(size: model.size, spaces: model.spaces.count, windows: model.windows.map(\.frame), midnight: midnight)
        let progress = model.progress
        ZStack(alignment: .topLeading) {
            backdrop(midnight: midnight)
                .opacity(min(max(progress, 0), 1))
                .animation(model.settle(), value: progress)
                .contentShape(Rectangle())
                .onTapGesture { model.dismiss() }
            ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                windowTile(window, to: layout.windows.indices.contains(index) ? layout.windows[index] : window.frame, index: index,
                           midnight: midnight)
            }
            strip(layout, midnight: midnight)
                .offset(y: -(1 - min(max(progress, 0), 1)) * (layout.stripHeight + 20))
                .opacity(min(max(progress, 0), 1))
                .animation(model.settle(), value: progress)
            if model.needsPermission {
                Text("Allow Oyl in Screen Recording (System Settings › Privacy & Security) for pictures of your windows and desktops")
                    .notchFont(size: 12, weight: .medium)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(midnight ? 0 : 0.5)))
                    .frame(width: model.size.width)
                    .position(x: model.size.width / 2, y: model.size.height - 40)
                    .opacity(progress)
            }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
        .environment(\.notchTheme, model.theme)
    }

    // MARK: Behind

    @ViewBuilder private func backdrop(midnight: Bool) -> some View {
        if midnight {
            ZStack {
                Midnight.ink.opacity(0.94)
                // Moonlight off to the upper right, as the band's sky has it.
                RadialGradient(colors: [Midnight.moonlight.opacity(0.1), .clear], center: UnitPoint(x: 0.78, y: 0.05), startRadius: 0,
                               endRadius: model.size.width * 0.6)
                DesktopsStars(size: model.size)
            }
        } else if let backdrop = model.backdrop {
            ZStack {
                Image(nsImage: backdrop)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: model.size.width, height: model.size.height)
                    .clipped()
                Color.black.opacity(0.28)
            }
        } else {
            Color.black.opacity(0.88)
        }
    }

    // MARK: The desktops

    private func strip(_ layout: DesktopsLayout, midnight: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if midnight {
                constellation(layout)
            } else {
                Color.black.opacity(0.35)
                    .frame(width: model.size.width, height: layout.stripHeight)
            }
            ForEach(Array(model.spaces.enumerated()), id: \.element.id) { index, space in
                if layout.tiles.indices.contains(index) {
                    spaceTile(space, in: layout.tiles[index], midnight: midnight)
                }
            }
        }
    }

    /// Midnight's: the desktops joined in order by a line of stars over them, a star over each.
    private func constellation(_ layout: DesktopsLayout) -> some View {
        Canvas { context, _ in
            let points = layout.tiles.map { CGPoint(x: $0.midX, y: $0.minY - 12) }
            var line = Path()
            for (index, point) in points.enumerated() {
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(Midnight.starlight.opacity(0.22)), lineWidth: 0.6)
            for point in points {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2)),
                             with: .color(Midnight.starlight.opacity(0.75)))
            }
        }
        .frame(width: model.size.width, height: layout.stripHeight + 10)
        .allowsHitTesting(false)
    }

    private func spaceTile(_ space: DesktopsModel.Space, in frame: CGRect, midnight: Bool) -> some View {
        let hovered = model.hoveredSpace == space.id
        let shape = RoundedRectangle(cornerRadius: midnight ? 5 : 7, style: .continuous)
        return VStack(spacing: 7) {
            ZStack {
                if let picture = space.picture {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    (midnight ? Midnight.ink : Color.black).opacity(0.8)
                    if let icon = space.icon {
                        Image(nsImage: icon).resizable().frame(width: frame.height * 0.42, height: frame.height * 0.42)
                    } else if let backdrop = model.backdrop, !space.isFullscreen {
                        Image(nsImage: backdrop).resizable().aspectRatio(contentMode: .fill).opacity(0.7)
                    }
                }
            }
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .modifier(Feathered(on: midnight, shape: shape))
            .background {
                if midnight && (space.isCurrent || hovered) {
                    RadialGradient(colors: [Midnight.moonlight.opacity(space.isCurrent ? 0.32 : 0.18), .clear], center: .center, startRadius: 0,
                                   endRadius: frame.width * 0.8)
                        .frame(width: frame.width * 1.7, height: frame.height * 2)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if !midnight {
                    shape.strokeBorder(.white.opacity(space.isCurrent ? 0.95 : hovered ? 0.55 : 0), lineWidth: space.isCurrent ? 2.5 : 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if midnight && space.isCurrent { DesktopGlint().offset(x: 7, y: -7) }
            }
            .shadow(color: .black.opacity(midnight ? 0 : 0.35), radius: 8, y: 3)
            Text(space.name)
                .notchFont(size: midnight ? 12.5 : 11.5, weight: space.isCurrent ? .semibold : .medium)
                .foregroundStyle((midnight ? Midnight.white : Color.white).opacity(space.isCurrent || hovered ? 0.95 : 0.65))
                .lineLimit(1)
                .frame(width: frame.width + 24)
        }
        .scaleEffect(hovered ? 1.05 : 1)
        .animation(midnight ? .easeInOut(duration: 0.35) : .easeOut(duration: 0.15), value: hovered)
        .contentShape(Rectangle())
        .onHover { model.hoveredSpace = $0 ? space.id : (model.hoveredSpace == space.id ? nil : model.hoveredSpace) }
        .onTapGesture { model.pick(space) }
        .help(space.isCurrent ? "\(space.name): where you are" : "Go to \(space.name)")
        .position(x: frame.midX, y: frame.minY + frame.height / 2 + 13)
    }

    // MARK: The windows

    private func windowTile(_ window: DesktopsModel.Window, to target: CGRect, index: Int, midnight: Bool) -> some View {
        let progress = model.progress
        let frame = DesktopsLayout.between(window.frame, target, progress)
        let hovered = model.hoveredWindow == window.id && progress > 0.95
        let shape = RoundedRectangle(cornerRadius: midnight ? 6 : 9, style: .continuous)
        // Midnight's drift in one after another (not while following the fingers).
        let delay = midnight && !model.interactive ? Double(min(index, 8)) * 0.035 : 0
        return ZStack {
            if let picture = window.picture {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                (midnight ? Midnight.ink : Color(white: 0.12)).opacity(0.85)
                if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: min(64, frame.width * 0.3), height: min(64, frame.width * 0.3))
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(shape)
        .modifier(Feathered(on: midnight, shape: shape))
        .overlay {
            if !midnight { shape.strokeBorder(.white.opacity(hovered ? 0.9 : 0), lineWidth: 2) }
        }
        .background {
            if midnight && hovered {
                RadialGradient(colors: [Midnight.moonlight.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: frame.width * 0.75)
                    .frame(width: frame.width * 1.5, height: frame.height * 1.5)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(midnight ? 0 : 0.45 * min(progress * 2, 1)), radius: 14, y: 6)
        .overlay(alignment: .bottom) {
            // Just inside its foot, so it's over nothing else.
            if hovered {
                windowName(window, midnight: midnight)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .opacity(window.picture == nil && progress < 0.05 ? 0 : 1)
        .scaleEffect(hovered ? 1.02 : 1)
        .contentShape(Rectangle())
        .onHover { on in model.hoveredWindow = on ? window.id : (model.hoveredWindow == window.id ? nil : model.hoveredWindow) }
        .onTapGesture { model.choose(window) }
        .position(x: frame.midX, y: frame.midY)
        .zIndex(model.chosen == window.id ? 100 : Double(index))
        .animation(model.settle(delay: delay), value: progress)
        .animation(midnight ? .easeInOut(duration: 0.3) : .easeOut(duration: 0.15), value: hovered)
        .animation(.easeOut(duration: 0.2), value: window.picture == nil)
    }

    private func windowName(_ window: DesktopsModel.Window, midnight: Bool) -> some View {
        HStack(spacing: 6) {
            if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
            Text(window.title.isEmpty || window.title == window.app ? window.app : "\(window.app) — \(window.title)")
                .notchFont(size: 11.5, weight: .medium)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(midnight ? AnyShapeStyle(Midnight.ink.opacity(0.85)) : AnyShapeStyle(Color.black.opacity(0.65))))
        .fixedSize()
    }
}

/// Midnight's pictures have no edge: they fade out over their last few points. Oyl's are clipped
/// to their rounded shape.
private struct Feathered<S: Shape>: ViewModifier {
    let on: Bool
    let shape: S

    func body(content: Content) -> some View {
        if on {
            content.mask(shape.fill(.white).padding(4).blur(radius: 4))
        } else {
            content.clipShape(shape)
        }
    }
}

/// A four-pointed glint at the corner of the desktop you're on, twinkling.
private struct DesktopGlint: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            let twinkle = 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 1.7)
            FourPointStar()
                .fill(Midnight.starlight)
                .frame(width: 11 + 4 * twinkle, height: 11 + 4 * twinkle)
                .opacity(0.65 + 0.35 * twinkle)
                .rotationEffect(.degrees(twinkle * 12))
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

/// Over everything, on whichever Space is showing; it takes the keyboard (for Escape) without
/// bringing Oyl to the front.
final class DesktopsPanel: NSPanel {
    var dismiss: () -> Void = {}

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

    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func keyDown(with event: NSEvent) {
        // Escape, as anywhere.
        if event.keyCode == 53 { dismiss() } else { super.keyDown(with: event) }
    }
}

final class DesktopsHostingView: NSHostingView<DesktopsView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Three fingers up brings it up, following them; let go most of the way (or quickly), it's up,
/// else it goes back down. Three fingers down, Escape, or a click on its background puts it away.
@MainActor
final class DesktopsViewer {
    let model = DesktopsModel()
    private let panel = DesktopsPanel()
    private let snapshots = DesktopSnapshots()
    private var screen: NSScreen?
    /// The Spaces as they were when it came up, and the one showing.
    private var spaces: [CurrentSpace] = []
    private var current: Int?
    /// Up at all: coming up, up, or going.
    private(set) var isUp = false
    /// A swipe being followed, and which way.
    private var following: Bool?
    private var hiding: DispatchWorkItem?
    private var loading: Task<Void, Never>?
    private var observers: [Any] = []
    private var askedPermission = false
    /// Whether it can come up now (not while Oyl's off, or nothing can be seen).
    var isAllowed: () -> Bool = { true }

    var theme = NotchTheme.standard {
        didSet { if theme != model.theme { model.theme = theme } }
    }

    var isResting = false {
        didSet {
            snapshots.isResting = isResting
            if isResting, isUp { hide() }
        }
    }

    init() {
        let host = DesktopsHostingView(rootView: DesktopsView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.dismiss = { [weak self] in self?.close() }
        model.dismiss = { [weak self] in self?.close() }
        model.pick = { [weak self] space in self?.go(to: space) }
        model.choose = { [weak self] window in self?.bringForward(window) }
    }

    /// Reading the trackpads, and keeping pictures of the desktops.
    func start() {
        Trackpads.shared.swiped = { [weak self] swipe in self?.swiped(swipe) }
        Trackpads.shared.start()
        snapshots.start()
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Trackpads.shared.restart() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Trackpads.shared.restart() }
            },
            // Swiped across to another Space while it's up: that one's windows.
            workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isUp, self.following == nil, self.hiding == nil else { return }
                    self.load(fresh: true)
                }
            },
        ]
    }

    func stop() {
        Trackpads.shared.stop()
        snapshots.stop()
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
            settle(open: up ? went : !went)
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

    /// Down and away, then `then`.
    func close(then: (() -> Void)? = nil) {
        guard isUp else { return }
        following = nil
        settle(open: false)
        if let then { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { then() } }
    }

    private func hideAfterSettling() {
        cancelHiding()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hiding = work
        DispatchQueue.main.asyncAfter(deadline: .now() + model.settleTime + 0.35, execute: work)
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
        model.chosen = nil
        model.hoveredSpace = nil
        model.hoveredWindow = nil
        model.windows = []
        model.backdrop = NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
        panel.setFrame(screen.frame, display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        isUp = true
        load(fresh: false)
    }

    private func hide() {
        cancelHiding()
        loading?.cancel()
        loading = nil
        following = nil
        panel.orderOut(nil)
        isUp = false
        model.windows = []
        model.progress = 0
    }

    /// The Spaces, and the windows of the one showing (pictures as they come).
    private func load(fresh: Bool) {
        guard let screen else { return }
        readSpaces(on: screen)
        loading?.cancel()
        loading = Task { @MainActor [weak self] in
            guard let self else { return }
            guard CGPreflightScreenCaptureAccess() else {
                if !self.askedPermission {
                    self.askedPermission = true
                    CGRequestScreenCaptureAccess()
                }
                self.model.needsPermission = true
                await self.loadWindowsWithoutPictures(on: screen)
                return
            }
            self.model.needsPermission = false
            await self.loadWindows(on: screen)
            // The desktop you're on, as it is now.
            if await self.snapshots.take(on: screen) != nil, !Task.isCancelled { self.readSpaces(on: screen) }
        }
    }

    private func readSpaces(on screen: NSScreen) {
        guard let display = FullscreenSpace.display(for: screen) else {
            spaces = []
            current = nil
            model.spaces = []
            return
        }
        let all = Spaces.all(in: display, boot: Spaces.bootTime) { NSRunningApplication(processIdentifier: $0)?.localizedName }
        spaces = all.spaces
        current = all.current
        let names = SpaceNames()
        model.spaces = all.spaces.enumerated().map { index, space in
            DesktopsModel.Space(id: space.key, name: names.name(of: space), isFullscreen: space.isFullscreen,
                                isCurrent: index == all.current, picture: snapshots.pictures[space.key],
                                icon: space.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon })
        }
    }

    /// The windows showing on `screen`'s Space, back to front, in screen points from its top left.
    private func loadWindows(on screen: NSScreen) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true), !Task.isCancelled else {
            return await loadWindowsWithoutPictures(on: screen)
        }
        let bounds = Self.bounds(of: screen)
        let order = Self.frontToBack()
        let own = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.filter { window in
            guard window.windowLayer == 0, window.isOnScreen, let app = window.owningApplication, app.processID != own,
                  !Self.skipped.contains(app.bundleIdentifier), window.frame.width >= 60, window.frame.height >= 40 else { return false }
            return window.frame.intersection(bounds).width > window.frame.width * 0.5
        }
        .sorted { (order[$0.windowID] ?? .max) > (order[$1.windowID] ?? .max) }
        model.windows = windows.map { window in
            let app = window.owningApplication
            return DesktopsModel.Window(id: window.windowID, pid: app?.processID ?? 0, title: window.title ?? "",
                                        app: app?.applicationName ?? "",
                                        frame: window.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
                                        icon: app.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon })
        }
        let scale = screen.backingScaleFactor
        await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for window in windows {
                group.addTask {
                    let configuration = SCStreamConfiguration()
                    let longest = max(window.frame.width, window.frame.height) * scale
                    let shrink = min(1, 1400 / max(longest, 1))
                    configuration.width = max(Int(window.frame.width * scale * shrink), 1)
                    configuration.height = max(Int(window.frame.height * scale * shrink), 1)
                    configuration.showsCursor = false
                    configuration.ignoreShadowsSingleWindow = true
                    let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                           configuration: configuration)
                    return (window.windowID, image)
                }
            }
            for await (id, image) in group {
                guard !Task.isCancelled, let image, let index = model.windows.firstIndex(where: { $0.id == id }) else { continue }
                model.windows[index].picture = image
            }
        }
    }

    /// Without Screen Recording: where the windows are, from the window list, with their apps' icons.
    private func loadWindowsWithoutPictures(on screen: NSScreen) async {
        let bounds = Self.bounds(of: screen)
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.compactMap { info -> DesktopsModel.Window? in
            guard info[kCGWindowLayer as String] as? Int == 0, let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let box = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: box as CFDictionary),
                  frame.width >= 60, frame.height >= 40, frame.intersection(bounds).width > frame.width * 0.5 else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            guard !Self.skipped.contains(app?.bundleIdentifier ?? "") else { return nil }
            return DesktopsModel.Window(id: id, pid: pid, title: info[kCGWindowName as String] as? String ?? "",
                                        app: app?.localizedName ?? "", frame: frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
                                        icon: app?.icon)
        }
        model.windows = windows.reversed()
    }

    /// The system's own windows over everything, not a desktop's.
    private static let skipped: Set<String> = ["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
                                               "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.screencaptureui"]

    /// A screen's frame as the window server has it: from the top left of the main screen, down.
    static func bounds(of screen: NSScreen) -> CGRect {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return number.map { CGDisplayBounds($0) } ?? screen.frame
    }

    /// Each window on screen's place, front first.
    private static func frontToBack() -> [CGWindowID: Int] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (index, info) in list.enumerated() {
            if let id = info[kCGWindowNumber as String] as? CGWindowID { order[id] = index }
        }
        return order
    }

    // MARK: Going somewhere

    private func go(to space: DesktopsModel.Space) {
        guard let target = spaces.firstIndex(where: { $0.key == space.id }), let current, target != current else {
            close()
            return
        }
        close {
            if !SpaceKeys.go(target - current) { NSSound.beep() }
        }
    }

    /// The window to the front: its app, and it raised (as picture in picture goes to its window).
    private func bringForward(_ window: DesktopsModel.Window) {
        model.chosen = window.id
        let pid = window.pid, id = window.id
        close {
            NSRunningApplication(processIdentifier: pid)?.activate()
            DispatchQueue.global(qos: .userInitiated).async {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 1)
                for element in ButtonReader.elements(app, kAXWindowsAttribute) {
                    var number: CGWindowID = 0
                    guard let windowNumber = PiPWindows.windowNumber, windowNumber(element, &number) == .success, number == id else { continue }
                    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                    break
                }
            }
        }
    }
}
