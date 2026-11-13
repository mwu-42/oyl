import AppKit
import Combine
import CoreMedia
import ScreenCaptureKit
import SwiftUI

/// Picture in picture for any window: a live copy of it, small, kept up over every desktop and
/// every fullscreen app (the browsers' own picture in picture doesn't come over another app's
/// fullscreen Space), wherever the window itself is: on another desktop, in its own fullscreen
/// Space, or under other windows. ⌃⌥P puts the window in front into it (again, puts it away), or
/// right-click an open app in Oyl's Dock for one of its windows. One at a time.
///
/// It's drawn from the window by ScreenCaptureKit (so Oyl has to be allowed Screen Recording; till
/// it is, it says so, and a click opens the setting), at only as many pixels as it's shown at (more
/// zoomed in), thirty frames a second, while it's up. Drag it anywhere; drag a corner to make it
/// bigger or smaller, or an edge to change its shape (the window then fills it, what's over cropped
/// off). Pinch, or ⌘-scroll, to zoom in on part of the window (a video on a page, say), scroll to
/// move about it, and a two-finger double tap zooms in or back out; Fit puts it back as it was.
/// Double-click it, or its arrow, to go to the window; × puts it away. It comes up where and as
/// big as the last one was, and goes once the window's closed, Oyl's switched off, or the feature
/// is; it's out of the way in Mission Control.
///
/// In Oyl's look, it's the window's picture with rounded corners and a shadow, its buttons coming
/// up over the top on a plain ease as the pointer comes over it. In Midnight Oyl's it has no edge:
/// the picture fades out into the desktop all round, a glint twinkling at its top right and motes
/// of starlight drifting round its edge, its buttons traced in silver (× at its top left, its arrow
/// at the bottom right, the app's name in small capitals by it); it comes in out of a blur and
/// goes back into one.
@MainActor
final class PictureInPicture {
    /// The one Oyl has, for the Dock's menus.
    private(set) static weak var shared: PictureInPicture?

    private let state: NotchState
    private var session: PiPSession?
    private var cancellables = Set<AnyCancellable>()

    init(state: NotchState) {
        self.state = state
        Self.shared = self
        state.$theme
            .sink { [weak self] theme in MainActor.assumeIsolated { self?.session?.theme = theme } }
            .store(in: &cancellables)
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &cancellables)
        Features.shared.follow(.pictureInPicture) { [weak self] on in
            if !on { self?.close() }
        }
        .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.keepOnScreen() }
        }
    }

    /// The window that's in it, if one is.
    var window: PiPWindow? { session?.window }

    /// `window` in it, in place of any other.
    func show(_ window: PiPWindow) {
        guard Feature.pictureInPicture.isOn, !state.isOff else { return }
        session?.close()
        let session = PiPSession(window: window, theme: state.theme)
        session.onClosed = { [weak self, weak session] in
            if let session, self?.session === session { self?.session = nil }
        }
        self.session = session
        session.isAway = state.isViewingDesktops
        session.start()
    }

    /// ⌃⌥P: the window in front into it, or (if it's that one already) put away. Whether there was
    /// one to do it to.
    func toggleFront() -> Bool {
        guard let front = PiPWindows.front() else {
            guard session != nil else { return false }
            close()
            return true
        }
        if session?.window.id == front.id { close() } else { show(front) }
        return true
    }

    func close() { session?.close() }

    private func update() {
        if state.isOff { close() }
        session?.isAway = state.isViewingDesktops
    }
}

// MARK: - Windows

/// A window that can go into picture in picture.
struct PiPWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    /// Its title, if the app gives it one (and Oyl's allowed Screen Recording, to read it).
    let title: String
    /// Where it is, in the window server's points (down from the top of the main screen).
    let bounds: CGRect
}

enum PiPWindows {
    /// Any smaller is an app's odd bit (a palette, a tooltip), not a window to watch.
    static let smallest = CGSize(width: 120, height: 90)

    /// `pids`' windows, on every Space, front to back (those on this one first).
    static func windows(of pids: Set<pid_t>) -> [PiPWindow] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return shown(list, pids: pids)
    }

    /// The window in front: the frontmost app's frontmost window here (never one of Oyl's).
    @MainActor
    static func front() -> PiPWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return shown(list, pids: [app.processIdentifier], onScreenOnly: true).first
    }

    /// Where `id` is now: nil once it's closed.
    static func bounds(of id: CGWindowID) -> CGRect? {
        // The window server wants its numbers as they are, not as CFNumbers.
        var value = UnsafeRawPointer(bitPattern: UInt(id))
        guard let ids = CFArrayCreate(nil, &value, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let info = list.first, info[kCGWindowNumber as String] as? Int == Int(id) else { return nil }
        return rect(info[kCGWindowBounds as String])
    }

    /// Those of `list` (the window server's, front to back) that are `pids`' windows to watch:
    /// ordinary ones, big enough, that can be captured. One out of sight (on another Space, or in
    /// the Dock) only if it has a name: apps keep windows out of sight that aren't any.
    static func shown(_ list: [[String: Any]], pids: Set<pid_t>, onScreenOnly: Bool = false) -> [PiPWindow] {
        list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int, let owner = info[kCGWindowOwnerPID as String] as? Int,
                  pids.contains(pid_t(owner)), info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  (info[kCGWindowSharingState as String] as? Int ?? 1) != 0,
                  let bounds = rect(info[kCGWindowBounds as String]),
                  bounds.width >= smallest.width, bounds.height >= smallest.height else { return nil }
            let title = info[kCGWindowName as String] as? String ?? ""
            let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            if !onScreen, onScreenOnly || title.isEmpty { return nil }
            return PiPWindow(id: CGWindowID(number), pid: pid_t(owner), title: title, bounds: bounds)
        }
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let bounds = value as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat? { (bounds[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
        guard let x = number("X"), let y = number("Y"), let width = number("Width"), let height = number("Height") else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// What it's called in a menu: its title, else the app's name and its place among them.
    static func menuTitle(of window: PiPWindow, at index: Int, app: String) -> String {
        window.title.isEmpty ? "\(app) \(index + 1)" : window.title
    }
}

// MARK: - Geometry

/// What part of the window's in the picture: the window fills it (any of it past the picture's
/// shape cropped off), zoomed in about `center`.
struct PiPFraming: Equatable {
    var zoom: CGFloat = 1
    /// What's in the picture's middle, across and down the window (0...1, from its top left).
    var center = CGPoint(x: 0.5, y: 0.5)

    static let deepest: CGFloat = 8

    /// The picture's points to each of the window's.
    static func scale(of source: CGSize, in size: CGSize, zoom: CGFloat) -> CGFloat {
        max(size.width / max(source.width, 1), size.height / max(source.height, 1)) * zoom
    }

    /// Kept to the window: never zoomed out past it, or moved off its edges.
    func clamped(source: CGSize, size: CGSize) -> PiPFraming {
        var framing = self
        framing.zoom = min(max(zoom, 1), Self.deepest)
        let scale = Self.scale(of: source, in: size, zoom: framing.zoom)
        let half = CGSize(width: size.width / (scale * max(source.width, 1)) / 2,
                          height: size.height / (scale * max(source.height, 1)) / 2)
        framing.center.x = half.width >= 0.5 ? 0.5 : min(max(center.x, half.width), 1 - half.width)
        framing.center.y = half.height >= 0.5 ? 0.5 : min(max(center.y, half.height), 1 - half.height)
        return framing
    }

    /// Where the whole of the window's picture goes, from the picture's top left (zoomed in, most
    /// of it past the picture's edges).
    func placement(source: CGSize, size: CGSize) -> CGRect {
        let scale = Self.scale(of: source, in: size, zoom: zoom)
        let width = source.width * scale, height = source.height * scale
        return CGRect(x: size.width / 2 - center.x * width, y: size.height / 2 - center.y * height, width: width, height: height)
    }

    /// Zoomed by `factor` about `point` (from the picture's top left), what's under it staying put.
    func zoomed(by factor: CGFloat, at point: CGPoint, source: CGSize, size: CGSize) -> PiPFraming {
        let before = placement(source: source, size: size)
        let under = CGPoint(x: (point.x - before.minX) / max(before.width, 1), y: (point.y - before.minY) / max(before.height, 1))
        var framing = self
        framing.zoom = min(max(zoom * factor, 1), Self.deepest)
        let scale = Self.scale(of: source, in: size, zoom: framing.zoom)
        let width = source.width * scale, height = source.height * scale
        framing.center = CGPoint(x: (size.width / 2 - point.x) / width + under.x, y: (size.height / 2 - point.y) / height + under.y)
        return framing.clamped(source: source, size: size)
    }

    /// The window moved `delta` of the picture's points under it, as a scroll moves what it scrolls.
    func panned(by delta: CGSize, source: CGSize, size: CGSize) -> PiPFraming {
        let scale = Self.scale(of: source, in: size, zoom: zoom)
        var framing = self
        framing.center.x -= delta.width / (max(source.width, 1) * scale)
        framing.center.y -= delta.height / (max(source.height, 1) * scale)
        return framing.clamped(source: source, size: size)
    }

    /// Where in the frame the window's picture is, ScreenCaptureKit having fitted it in, its shape
    /// kept and centered (0...1 of the frame, the same either way up).
    static func content(of source: CGSize, inFrame frame: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, frame.width > 0, frame.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let scale = min(frame.width / source.width, frame.height / source.height)
        let width = min(source.width * scale / frame.width, 1), height = min(source.height * scale / frame.height, 1)
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    /// How big a frame to ask ScreenCaptureKit for, in pixels: enough for the picture at its size
    /// and zoom (and a little more), never more than the window has, in its own shape.
    static func capture(source: CGSize, sourceScale: CGFloat, picture: CGSize, scale: CGFloat, zoom: CGFloat) -> CGSize {
        guard source.width > 0, source.height > 0 else { return CGSize(width: 64, height: 64) }
        let full = CGSize(width: source.width * sourceScale, height: source.height * sourceScale)
        let shown = Self.scale(of: source, in: picture, zoom: zoom) * scale * 1.15
        let largest: CGFloat = 4096
        let factor = min(1, shown / sourceScale, largest / max(full.width, full.height))
        return CGSize(width: max(64, (full.width * factor).rounded()), height: max(64, (full.height * factor).rounded()))
    }
}

/// Which sides of the picture a drag takes hold of: a corner, two (its shape kept); an edge, one.
struct PiPGrip: Equatable {
    var left = false, right = false, top = false, bottom = false

    var isEmpty: Bool { !(left || right || top || bottom) }
    var isCorner: Bool { (left || right) && (top || bottom) }

    static let edge: CGFloat = 8
    static let corner: CGFloat = 18

    /// At `point`, from the picture's top left.
    init(at point: CGPoint, in size: CGSize) {
        let nearLeft = point.x < Self.corner, nearRight = point.x > size.width - Self.corner
        let nearTop = point.y < Self.corner, nearBottom = point.y > size.height - Self.corner
        if (nearLeft || nearRight) && (nearTop || nearBottom) {
            left = nearLeft
            right = nearRight
            top = nearTop
            bottom = nearBottom
            return
        }
        left = point.x < Self.edge
        right = point.x > size.width - Self.edge
        top = point.y < Self.edge
        bottom = point.y > size.height - Self.edge
    }

    init(left: Bool = false, right: Bool = false, top: Bool = false, bottom: Bool = false) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    /// The frame (on screen, up being up) once `start`'s been dragged by `delta` (up being up):
    /// a corner keeps its shape, the opposite corner staying put; an edge moves alone.
    func resized(_ start: CGRect, by delta: CGSize, smallest: CGSize, largest: CGSize) -> CGRect {
        var frame = start
        if isCorner {
            let aspect = start.width / max(start.height, 1)
            let across = start.width + (right ? delta.width : -delta.width)
            let down = (start.height + (top ? delta.height : -delta.height)) * aspect
            let least = max(smallest.width, smallest.height * aspect), most = min(largest.width, largest.height * aspect)
            let width = min(max(abs(across - start.width) >= abs(down - start.width) ? across : down, least), max(most, least))
            frame.size = CGSize(width: width, height: width / aspect)
        } else {
            if left || right {
                frame.size.width = min(max(start.width + (right ? delta.width : -delta.width), smallest.width), largest.width)
            }
            if top || bottom {
                frame.size.height = min(max(start.height + (top ? delta.height : -delta.height), smallest.height), largest.height)
            }
        }
        frame.origin.x = left ? start.maxX - frame.width : start.minX
        frame.origin.y = bottom ? start.maxY - frame.height : start.minY
        return frame
    }
}

enum PiPPlacement {
    static let smallest = CGSize(width: 160, height: 90)
    static let inset: CGFloat = 20

    /// Where it can be on a screen: all of it, clear of the menu bar (or the notch's strip).
    @MainActor
    static func area(of screen: NSScreen) -> CGRect {
        let top = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY, 24)
        var area = screen.frame
        area.size.height -= top
        return area
    }

    /// The biggest it gets on a screen this size.
    static func largest(in area: CGRect) -> CGSize { CGSize(width: area.width * 0.8, height: area.height * 0.8) }

    /// The first frame for a window `aspect` wide to each point high: `width` wide (else a quarter
    /// of the screen's, within reason), with its middle at `middle` (0...1 across and up the area),
    /// else low on the right.
    static func first(aspect: CGFloat, width: CGFloat?, middle: CGPoint?, in area: CGRect) -> CGRect {
        let largest = largest(in: area)
        var size = CGSize(width: width ?? min(max(area.width * 0.24, 240), 480), height: 0)
        size.width = min(max(size.width, smallest.width), largest.width)
        size.height = size.width / max(aspect, 0.1)
        let tallest = min(largest.height, area.height * 0.5)
        if size.height > tallest {
            size.height = tallest
            size.width = max(size.height * aspect, smallest.width)
        }
        let origin = middle.map { CGPoint(x: area.minX + $0.x * area.width - size.width / 2, y: area.minY + $0.y * area.height - size.height / 2) }
            ?? CGPoint(x: area.maxX - inset - size.width, y: area.minY + inset)
        return kept(CGRect(origin: origin, size: size), within: area)
    }

    /// Moved (as little as it can be) to be all on `area`.
    static func kept(_ frame: CGRect, within area: CGRect) -> CGRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, area.minX), max(area.maxX - frame.width, area.minX))
        frame.origin.y = min(max(frame.minY, area.minY), max(area.maxY - frame.height, area.minY))
        return frame
    }
}

// MARK: - A window in it

@MainActor
final class PiPModel: ObservableObject {
    @Published var theme = NotchTheme.standard
    @Published var shown = false
    @Published var hovering = false
    /// Zoomed in, or made another shape than the window's: Fit puts it back.
    @Published var cropped = false
    /// Oyl isn't allowed Screen Recording.
    @Published var needsPermission = false
    @Published var pressed: PiPButton?
    @Published var app = ""
    @Published var title = ""
}

enum PiPButton {
    case close, back, fit

    /// Where it is on a picture `size` big, from its top left: in Oyl's look × top left and the
    /// arrow top right; in Midnight's × top left and the arrow at the bottom right, Fit beside it.
    static func rect(_ button: PiPButton, in size: CGSize, midnight: Bool) -> CGRect {
        let side: CGFloat = 24
        switch (button, midnight) {
        case (.close, false): return CGRect(x: 10, y: 10, width: side, height: side)
        case (.back, false): return CGRect(x: size.width - 10 - side, y: 10, width: side, height: side)
        case (.fit, false): return CGRect(x: size.width - 10 - 40, y: size.height - 10 - 22, width: 40, height: 22)
        case (.close, true): return CGRect(x: 14, y: 12, width: side, height: side)
        case (.back, true): return CGRect(x: size.width - 14 - side, y: size.height - 12 - side, width: side, height: side)
        case (.fit, true): return CGRect(x: size.width - 14 - side - 6 - 38, y: size.height - 12 - side + 1, width: 38, height: 22)
        }
    }
}

@MainActor
private final class PiPSession {
    let window: PiPWindow
    var onClosed: () -> Void = {}
    var theme: NotchTheme {
        didSet {
            guard theme != oldValue else { return }
            model.theme = theme
            view.applyLook(midnight: theme == .midnight)
            panel.hasShadow = theme != .midnight
        }
    }
    /// Out of the way (Mission Control's up).
    var isAway = false {
        didSet {
            guard isAway != oldValue, model.shown, !closing else { return }
            if isAway { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        }
    }

    private let panel = NotchPanel()
    private let model = PiPModel()
    private let view: PiPPictureView
    private var stream: SCStream?
    private var frames: PiPFrames?
    /// The window's size, in points.
    private var source: CGSize
    private var framing = PiPFraming()
    /// It's the window's own shape (it hasn't been given another), so it follows the window's.
    private var followsShape = true
    private var captured = CGSize.zero
    private var watching: Timer?
    private var recapturing: DispatchWorkItem?
    private var closing = false
    private var revealed = false

    private static let saved = "pip.place"

    init(window: PiPWindow, theme: NotchTheme) {
        self.window = window
        self.theme = theme
        source = window.bounds.size
        view = PiPPictureView(model: model)
        model.theme = theme
        let app = NSRunningApplication(processIdentifier: window.pid)
        model.app = app?.localizedName ?? ""
        model.title = window.title
        panel.level = .floating
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.hasShadow = theme != .midnight
        panel.contentView = view
        view.applyLook(midnight: theme == .midnight)
        view.source = source
        view.onMove = { [weak self] frame in self?.panel.setFrame(frame, display: true) }
        view.onResize = { [weak self] frame, grip in self?.resize(to: frame, grip: grip) }
        view.onFraming = { [weak self] framing in self?.reframe(framing) }
        view.onDone = { [weak self] in self?.remember() }
        view.onButton = { [weak self] button in self?.pressed(button) }
        view.onDoubleClick = { [weak self] in self?.goToWindow() }
        view.onPermission = { Self.openPermission() }
        view.frameOnScreen = { [weak self] in self?.panel.frame ?? .zero }
        // Where the pointer's taking it: onto another screen, too.
        view.areaOnScreen = { [weak self] in
            let pointer = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? self?.screen else { return .zero }
            return PiPPlacement.area(of: screen)
        }
        panel.setFrame(firstFrame(), display: false)
    }

    /// The screen it's on (most of it), else the pointer's.
    private var screen: NSScreen {
        let frame = panel.frame, pointer = NSEvent.mouseLocation
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        if frame.width > 0, let screen = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(screen) > 0 { return screen }
        return NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func firstFrame() -> CGRect {
        let saved = UserDefaults.standard.array(forKey: Self.saved) as? [Double]
        let width = saved.flatMap { $0.count == 3 ? CGFloat($0[2]) : nil }
        let middle = saved.flatMap { $0.count == 3 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        return PiPPlacement.first(aspect: source.width / max(source.height, 1), width: width, middle: middle,
                                  in: PiPPlacement.area(of: screen))
    }

    /// Where it is and how big, for the next one.
    private func remember() {
        let area = PiPPlacement.area(of: screen), frame = panel.frame
        guard area.width > 0, area.height > 0 else { return }
        UserDefaults.standard.set([Double((frame.midX - area.minX) / area.width), Double((frame.midY - area.minY) / area.height),
                                   Double(frame.width)], forKey: Self.saved)
    }

    // MARK: Capturing

    func start() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard CGPreflightScreenCaptureAccess() else {
                // macOS asks (the first time), and it says what to do.
                CGRequestScreenCaptureAccess()
                self.model.needsPermission = true
                self.reveal()
                return
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard !self.closing else { return }
                guard let found = content.windows.first(where: { $0.windowID == self.window.id }) else {
                    self.close()
                    return
                }
                try await self.capture(found)
            } catch {
                guard !self.closing else { return }
                if (error as NSError).code == SCStreamError.userDeclined.rawValue {
                    self.model.needsPermission = true
                    self.reveal()
                } else {
                    self.close()
                }
            }
        }
        // Up once its first frame's in, or in a moment regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.reveal() }
        watching = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
    }

    private func capture(_ found: SCWindow) async throws {
        let frames = PiPFrames()
        frames.delivered = { [weak self] surface in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(surface.surface) } }
        }
        frames.stopped = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.close() } }
        }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: found), configuration: configuration(), delegate: frames)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: frames.queue)
        self.frames = frames
        self.stream = stream
        try await stream.startCapture()
    }

    private func configuration() -> SCStreamConfiguration {
        let size = PiPFraming.capture(source: source, sourceScale: NSScreen.screens.map(\.backingScaleFactor).max() ?? 2,
                                      picture: panel.frame.size, scale: screen.backingScaleFactor, zoom: framing.zoom)
        captured = size
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 4
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }

    /// Asked for again at the size it's shown at now, if that's changed much.
    private func recapture() {
        recapturing?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let stream = self.stream, !self.closing else { return }
            let wanted = PiPFraming.capture(source: self.source, sourceScale: NSScreen.screens.map(\.backingScaleFactor).max() ?? 2,
                                            picture: self.panel.frame.size, scale: self.screen.backingScaleFactor, zoom: self.framing.zoom)
            let change = abs(wanted.width - self.captured.width) / max(self.captured.width, 1)
            let shape = abs(wanted.width / wanted.height - self.captured.width / max(self.captured.height, 1))
            guard change > 0.12 || shape > 0.01 else { return }
            stream.updateConfiguration(self.configuration()) { _ in }
        }
        recapturing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func show(_ surface: IOSurface) {
        guard !closing else { return }
        view.show(surface, content: PiPFraming.content(of: source, inFrame: CGSize(width: IOSurfaceGetWidth(surface),
                                                                                    height: IOSurfaceGetHeight(surface))))
        reveal()
    }

    /// The window's still there (else it goes), and its size: followed if it's changed.
    private func watch() {
        guard !closing else { return }
        guard let bounds = PiPWindows.bounds(of: window.id), NSRunningApplication(processIdentifier: window.pid) != nil else {
            close()
            return
        }
        guard abs(bounds.width - source.width) > 0.5 || abs(bounds.height - source.height) > 0.5 else { return }
        source = bounds.size
        view.source = source
        if followsShape {
            // Its own shape still: the window's new one, as wide as it is, its middle where it was.
            var frame = panel.frame
            let height = frame.width * source.height / max(source.width, 1)
            frame.origin.y += (frame.height - height) / 2
            frame.size.height = height
            panel.setFrame(PiPPlacement.kept(frame, within: PiPPlacement.area(of: screen)), display: true)
        }
        reframe(framing)
        recapture()
    }

    // MARK: Up and away

    private func reveal() {
        guard !revealed, !closing else { return }
        revealed = true
        if !isAway { panel.orderFrontRegardless() }
        model.shown = true
        view.appear(midnight: theme == .midnight)
    }

    func close() {
        guard !closing else { return }
        closing = true
        watching?.invalidate()
        recapturing?.cancel()
        if let stream { stream.stopCapture { _ in } }
        stream = nil
        model.shown = false
        model.hovering = false
        // The window goes even if this does first (another's taken its place).
        let panel = self.panel
        let done = { [weak self] in
            panel.orderOut(nil)
            self?.onClosed()
        }
        if revealed, panel.isVisible { view.disappear(midnight: theme == .midnight, then: done) } else { done() }
    }

    func keepOnScreen() {
        let area = PiPPlacement.area(of: screen)
        panel.setFrame(PiPPlacement.kept(panel.frame, within: area), display: true)
    }

    // MARK: Its shape and what's in it

    private func resize(to frame: CGRect, grip: PiPGrip) {
        panel.setFrame(frame, display: true)
        if !grip.isCorner { followsShape = false }
        reframe(framing)
        recapture()
    }

    private func reframe(_ framing: PiPFraming) {
        self.framing = framing.clamped(source: source, size: panel.frame.size)
        view.framing = self.framing
        let cropped = self.framing.zoom > 1.01 || !followsShape
        if model.cropped != cropped { model.cropped = cropped }
        recapture()
    }

    private func pressed(_ button: PiPButton) {
        switch button {
        case .close: close()
        case .back: goToWindow()
        case .fit: fit()
        }
    }

    /// Back to the window's own shape, all of it.
    private func fit() {
        followsShape = true
        var frame = panel.frame
        let height = frame.width * source.height / max(source.width, 1)
        frame.origin.y += (frame.height - height) / 2
        frame.size.height = height
        let area = PiPPlacement.area(of: screen)
        let largest = PiPPlacement.largest(in: area)
        if frame.height > largest.height {
            frame.size = CGSize(width: largest.height * source.width / max(source.height, 1), height: largest.height)
        }
        panel.setFrame(PiPPlacement.kept(frame, within: area), display: true)
        reframe(PiPFraming())
        remember()
    }

    /// To the window: its app in front (macOS going to the Space it's on), and it raised.
    private func goToWindow() {
        let pid = window.pid, id = window.id
        NSRunningApplication(processIdentifier: pid)?.activate()
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1)
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            // Its windows are only listed once its Space is the one showing.
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
                if Self.raise(id, of: app) { return }
            }
        }
    }

    private nonisolated static func raise(_ id: CGWindowID, of app: AXUIElement) -> Bool {
        for window in ButtonReader.elements(app, kAXWindowsAttribute) {
            var number: CGWindowID = 0
            guard let windowNumber, windowNumber(window, &number) == .success, number == id else { continue }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            return true
        }
        return false
    }

    private typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    /// The window server's number for an Accessibility window (as every window switcher finds it).
    private nonisolated static let windowNumber: WindowNumber? = {
        guard let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let symbol = dlsym(services, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowNumber.self)
    }()

    static func openPermission() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A frame, handed from ScreenCaptureKit's queue to the main thread.
private struct PiPSurface: @unchecked Sendable {
    let surface: IOSurface
}

/// ScreenCaptureKit's frames, as they come.
private final class PiPFrames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "oyl.PictureInPicture", qos: .userInteractive)
    var delivered: (PiPSurface) -> Void = { _ in }
    var stopped: () -> Void = {}

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
              let buffer = sampleBuffer.imageBuffer, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        delivered(PiPSurface(surface: surface))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { stopped() }
}

// MARK: - Its view

/// The picture (a layer showing ScreenCaptureKit's frames as they come), what's over it, and the
/// pointer on it: dragging, resizing, zooming, scrolling, and its buttons (which are drawn by
/// `PiPOverlay`, and pressed here).
final class PiPPictureView: NSView {
    let model: PiPModel
    var onMove: (CGRect) -> Void = { _ in }
    var onResize: (CGRect, PiPGrip) -> Void = { _, _ in }
    var onFraming: (PiPFraming) -> Void = { _ in }
    var onDone: () -> Void = {}
    var onButton: (PiPButton) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onPermission: () -> Void = {}
    var frameOnScreen: () -> CGRect = { .zero }
    var areaOnScreen: () -> CGRect = { .zero }

    var source = CGSize(width: 16, height: 9) { didSet { needsLayout = true } }
    var framing = PiPFraming() { didSet { if framing != oldValue { needsLayout = true } } }

    /// Grows and fades in and out, on its own, in a view whose layers are Oyl's (not AppKit's).
    private let stageView = NSView()
    let stage = CALayer()
    private let picture = CALayer()
    private let frameLayer = CALayer()
    private let feather = CALayer()
    private let overlay: PiPOverlayHost
    private var midnight = false

    private var drag: (start: NSPoint, frame: CGRect, grip: PiPGrip, moved: Bool)?
    private var tracking: NSTrackingArea?

    static let corner: CGFloat = 12
    static let featherWidth: CGFloat = 16

    init(model: PiPModel) {
        self.model = model
        overlay = PiPOverlayHost(rootView: PiPOverlay(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear
        stageView.layer = CALayer()
        stageView.wantsLayer = true
        stageView.layerUsesCoreImageFilters = true
        stageView.autoresizingMask = [.width, .height]
        addSubview(stageView)
        stage.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        stage.opacity = 0
        picture.masksToBounds = true
        picture.cornerCurve = .continuous
        frameLayer.contentsGravity = .resize
        picture.addSublayer(frameLayer)
        stage.addSublayer(picture)
        stageView.layer?.addSublayer(stage)
        overlay.sizingOptions = []
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func applyLook(midnight: Bool) {
        self.midnight = midnight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.cornerRadius = midnight ? 0 : Self.corner
        picture.backgroundColor = midnight ? NSColor(Midnight.ink).cgColor : NSColor.black.cgColor
        if midnight {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            feather.contents = Self.featherImage(feather: Self.featherWidth, scale: scale)
            feather.contentsScale = scale
            let side = Self.featherWidth * 2 + 2
            feather.contentsCenter = CGRect(x: Self.featherWidth / side, y: Self.featherWidth / side, width: 2 / side, height: 2 / side)
            picture.mask = feather
        } else {
            picture.mask = nil
        }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        stageView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.bounds = bounds
        stage.position = CGPoint(x: bounds.midX, y: bounds.midY)
        picture.frame = bounds
        feather.frame = bounds
        let placed = framing.placement(source: source, size: bounds.size)
        // From the top left to the layer's own (up being up).
        frameLayer.frame = CGRect(x: placed.minX, y: bounds.height - placed.maxY, width: placed.width, height: placed.height)
        CATransaction.commit()
        overlay.frame = bounds
    }

    func show(_ surface: IOSurface, content: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = surface
        frameLayer.contentsRect = content
        CATransaction.commit()
    }

    // MARK: Coming and going

    func appear(midnight: Bool) {
        let duration = midnight ? 0.6 : 0.25
        let timing = CAMediaTimingFunction(name: midnight ? .easeOut : .easeInEaseOut)
        animate(opacity: (0, 1), scale: (midnight ? 0.97 : 0.94, 1), blur: midnight ? (14, 0) : nil, duration: duration, timing: timing) {}
    }

    func disappear(midnight: Bool, then done: @escaping () -> Void) {
        let duration = midnight ? 0.45 : 0.2
        let timing = CAMediaTimingFunction(name: midnight ? .easeIn : .easeInEaseOut)
        animate(opacity: (1, 0), scale: (1, midnight ? 0.97 : 0.94), blur: midnight ? (0, 14) : nil, duration: duration, timing: timing, then: done)
    }

    private func animate(opacity: (Float, Float), scale: (CGFloat, CGFloat), blur: (CGFloat, CGFloat)?, duration: CFTimeInterval,
                         timing: CAMediaTimingFunction, then done: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timing)
        CATransaction.setCompletionBlock { [weak self] in
            if blur != nil, opacity.1 > 0 { self?.stage.filters = nil }
            done()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity.0
        fade.toValue = opacity.1
        stage.add(fade, forKey: "fade")
        stage.opacity = opacity.1
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = scale.0
        grow.toValue = scale.1
        stage.add(grow, forKey: "grow")
        stage.setValue(scale.1, forKeyPath: "transform.scale")
        if let blur, let filter = CIFilter(name: "CIGaussianBlur") {
            filter.name = "blur"
            filter.setValue(blur.1, forKey: kCIInputRadiusKey)
            stage.filters = [filter]
            let soften = CABasicAnimation(keyPath: "filters.blur.inputRadius")
            soften.fromValue = blur.0
            soften.toValue = blur.1
            stage.add(soften, forKey: "blur")
        }
        CATransaction.commit()
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { model.hovering = true }
    override func mouseExited(with event: NSEvent) { if drag == nil { model.hovering = false } }

    /// From the top left.
    private func point(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    private func button(at point: CGPoint) -> PiPButton? {
        let buttons: [PiPButton] = model.needsPermission ? [.close] : (model.cropped ? [.close, .back, .fit] : [.close, .back])
        return buttons.first { PiPButton.rect($0, in: bounds.size, midnight: midnight).insetBy(dx: -3, dy: -3).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = point(of: event)
        if let button = button(at: point) {
            model.pressed = button
            drag = nil
            return
        }
        drag = (NSEvent.mouseLocation, frameOnScreen(), PiPGrip(at: point, in: bounds.size), false)
    }

    override func mouseDragged(with event: NSEvent) {
        if let pressed = model.pressed {
            let inside = PiPButton.rect(pressed, in: bounds.size, midnight: midnight).insetBy(dx: -3, dy: -3).contains(point(of: event))
            if !inside { model.pressed = nil }
            return
        }
        guard var drag else { return }
        let now = NSEvent.mouseLocation
        let delta = CGSize(width: now.x - drag.start.x, height: now.y - drag.start.y)
        if !drag.moved, hypot(delta.width, delta.height) < 3 { return }
        drag.moved = true
        self.drag = drag
        let area = areaOnScreen()
        if drag.grip.isEmpty {
            onMove(PiPPlacement.kept(drag.frame.offsetBy(dx: delta.width, dy: delta.height), within: area))
        } else {
            var frame = drag.grip.resized(drag.frame, by: delta, smallest: PiPPlacement.smallest, largest: PiPPlacement.largest(in: area))
            frame = PiPPlacement.kept(frame, within: area)
            onResize(frame, drag.grip)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let pressed = model.pressed {
            model.pressed = nil
            if PiPButton.rect(pressed, in: bounds.size, midnight: midnight).insetBy(dx: -3, dy: -3).contains(point(of: event)) {
                onButton(pressed)
            }
            return
        }
        let moved = drag?.moved ?? false
        drag = nil
        if moved {
            onDone()
        } else if model.needsPermission {
            onPermission()
        } else if event.clickCount == 2 {
            onDoubleClick()
        }
        if !bounds.contains(convert(event.locationInWindow, from: nil)) { model.hovering = false }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !model.needsPermission else { return }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        let delta = CGSize(width: event.scrollingDeltaX * step, height: event.scrollingDeltaY * step)
        if event.modifierFlags.contains(.command) {
            onFraming(framing.zoomed(by: exp(delta.height * 0.01), at: point(of: event), source: source, size: bounds.size))
        } else {
            onFraming(framing.panned(by: delta, source: source, size: bounds.size))
        }
    }

    override func magnify(with event: NSEvent) {
        guard !model.needsPermission else { return }
        onFraming(framing.zoomed(by: 1 + event.magnification, at: point(of: event), source: source, size: bounds.size))
    }

    /// A two-finger double tap: in on where it's tapped, or (zoomed in) back out.
    override func smartMagnify(with event: NSEvent) {
        guard !model.needsPermission else { return }
        if framing.zoom > 1.01 {
            var framing = framing
            framing.zoom = 1
            onFraming(framing)
        } else {
            onFraming(framing.zoomed(by: 2.5, at: point(of: event), source: source, size: bounds.size))
        }
    }

    // MARK: Midnight's edge

    /// A patch of white whose edge fades out over `feather` points, all round (its corners
    /// rounded by the fade), to stretch over the picture as its mask, its middle stretching.
    static func featherImage(feather: CGFloat, scale: CGFloat) -> CGImage? {
        let side = Int(((feather * 2 + 2) * scale).rounded())
        guard side > 0, let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let reach = feather * scale, middle = CGFloat(side) / 2, half = scale
        for row in 0..<side {
            for column in 0..<side {
                let x = max(abs(CGFloat(column) + 0.5 - middle) - half, 0), y = max(abs(CGFloat(row) + 0.5 - middle) - half, 0)
                let t = max(0, min(1, 1 - hypot(x, y) / reach))
                let alpha = UInt8((t * t * (3 - 2 * t) * 255).rounded())
                let index = (row * side + column) * 4
                pixels[index] = alpha
                pixels[index + 1] = alpha
                pixels[index + 2] = alpha
                pixels[index + 3] = alpha
            }
        }
        return context.makeImage()
    }
}

/// What's over the picture never takes the pointer itself: the view under it does.
private final class PiPOverlayHost: NSHostingView<PiPOverlay> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Over the picture: its buttons as the pointer comes over it, and in Midnight Oyl its glint and
/// motes; or, till Oyl's allowed Screen Recording, what to do.
struct PiPOverlay: View {
    @ObservedObject var model: PiPModel

    var body: some View {
        let midnight = model.theme == .midnight
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                if midnight {
                    PiPStarlight(running: model.shown)
                }
                if model.needsPermission {
                    PiPPermission(midnight: midnight)
                        .frame(width: size.width, height: size.height)
                }
                Group {
                    if midnight { midnightControls(size) } else { standardControls(size) }
                }
                .opacity(model.hovering || model.needsPermission ? 1 : 0)
                .animation(midnight ? .easeOut(duration: 0.35) : .easeInOut(duration: 0.2), value: model.hovering)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .environment(\.notchTheme, model.theme)
    }

    // Oyl's: over a shade along the top, × and the arrow either end, the window's name between.
    @ViewBuilder
    private func standardControls(_ size: CGSize) -> some View {
        LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
            .frame(width: size.width, height: 48)
        if !model.needsPermission {
            Text(model.title.isEmpty ? model.app : model.title)
                .notchFont(size: 11, weight: .medium)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .frame(width: max(size.width - 2 * 44, 0))
                .offset(x: 44, y: 15)
        }
        standardButton("xmark", .close, size)
        if !model.needsPermission {
            standardButton("pip.exit", .back, size)
            if model.cropped {
                let rect = PiPButton.rect(.fit, in: size, midnight: false)
                Text("Fit")
                    .notchFont(size: 11, weight: .semibold)
                    .foregroundStyle(.black)
                    .frame(width: rect.width, height: rect.height)
                    .background(Capsule().fill(.white.opacity(model.pressed == .fit ? 0.7 : 0.9)))
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }

    private func standardButton(_ symbol: String, _ button: PiPButton, _ size: CGSize) -> some View {
        let rect = PiPButton.rect(button, in: size, midnight: false)
        return Image(systemName: symbol)
            .font(.system(size: button == .close ? 10 : 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: rect.width, height: rect.height)
            .background(Circle().fill(.white.opacity(model.pressed == button ? 0.32 : 0.18)))
            .offset(x: rect.minX, y: rect.minY)
    }

    // Midnight's: × traced at the top left; the arrow at the bottom right, Fit beside it, and
    // the app's name in small capitals along the bottom, each on a patch of night with no edge.
    @ViewBuilder
    private func midnightControls(_ size: CGSize) -> some View {
        let close = PiPButton.rect(.close, in: size, midnight: true)
        night(close.insetBy(dx: -4, dy: -4), opacity: 0.45)
        PiPGlyph(kind: .close, pressed: model.pressed == .close)
            .frame(width: close.width, height: close.height)
            .offset(x: close.minX, y: close.minY)
        if !model.needsPermission {
            let back = PiPButton.rect(.back, in: size, midnight: true)
            let name = (model.app.isEmpty ? model.title : model.app).uppercased()
            let nameWidth = max(back.minX - (model.cropped ? 52 : 8) - 18, 0)
            night(CGRect(x: 16, y: size.height - 40, width: size.width - 32, height: 32), opacity: 0.6)
            Text(name)
                .notchFont(size: 10, role: .label)
                .tracking(Midnight.tracking(.label, size: 10))
                .foregroundStyle(Midnight.white)
                .shadow(color: Midnight.moonlight.opacity(0.4), radius: 3)
                .lineLimit(1)
                .frame(width: nameWidth, alignment: .leading)
                .offset(x: 18, y: size.height - 30)
                .transition(.opacity)
            PiPGlyph(kind: .back, pressed: model.pressed == .back)
                .frame(width: back.width, height: back.height)
                .offset(x: back.minX, y: back.minY)
            if model.cropped {
                let fit = PiPButton.rect(.fit, in: size, midnight: true)
                Text("FIT")
                    .notchFont(size: 10, role: .label)
                    .tracking(Midnight.tracking(.label, size: 10))
                    .foregroundStyle(Midnight.white.opacity(model.pressed == .fit ? 0.6 : 1))
                    .shadow(color: Midnight.moonlight.opacity(0.5), radius: 3)
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
            }
        }
    }

    private func night(_ rect: CGRect, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: rect.height / 2)
            .fill(Midnight.ink.opacity(opacity))
            .blur(radius: 9)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }
}

/// Midnight's buttons, traced in silver, a glint by each that brightens as it's pressed.
private struct PiPGlyph: View {
    enum Kind { case close, back }
    let kind: Kind
    let pressed: Bool

    var body: some View {
        Canvas { context, size in
            let middle = CGPoint(x: size.width / 2, y: size.height / 2), reach = size.width * 0.22
            var path = Path()
            switch kind {
            case .close:
                path.move(to: CGPoint(x: middle.x - reach, y: middle.y - reach))
                path.addLine(to: CGPoint(x: middle.x + reach, y: middle.y + reach))
                path.move(to: CGPoint(x: middle.x + reach, y: middle.y - reach))
                path.addLine(to: CGPoint(x: middle.x - reach, y: middle.y + reach))
            case .back:
                // Out of the picture, up and to the right: an arrow, its head open.
                let low = CGPoint(x: middle.x - reach, y: middle.y + reach), high = CGPoint(x: middle.x + reach, y: middle.y - reach)
                path.move(to: low)
                path.addLine(to: high)
                path.move(to: CGPoint(x: high.x - reach * 1.1, y: high.y))
                path.addLine(to: high)
                path.addLine(to: CGPoint(x: high.x, y: high.y + reach * 1.1))
            }
            var lines = context
            lines.addFilter(.shadow(color: Midnight.moonlight.opacity(pressed ? 0.9 : 0.5), radius: pressed ? 4 : 2.5))
            lines.stroke(path, with: .color(Midnight.white.opacity(pressed ? 1 : 0.9)),
                         style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            let glint = CGPoint(x: middle.x + reach * 1.6, y: middle.y - reach * 1.6), spark = pressed ? 3.2 : 2.2
            var star = context
            star.addFilter(.shadow(color: Midnight.moonlight.opacity(0.7), radius: 2))
            star.fill(Sparkle(size: spark).path(in: CGRect(x: glint.x - spark, y: glint.y - spark, width: 2 * spark, height: 2 * spark)),
                      with: .color(Midnight.starlight))
        }
    }
}

/// Midnight Oyl's: a glint twinkling at its top right, a fainter one low on its left, and motes
/// of starlight drifting slowly round in the fading edge.
struct PiPStarlight: View {
    let running: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !running)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let inset = PiPPictureView.featherWidth * 0.45
                let path = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                let perimeter = 2 * (path.width + path.height)
                for index in 0..<7 {
                    let seed = Double(index)
                    // Round the edge, each its own speed and way round.
                    let speed = (5 + 3 * sin(seed * 2.3)) * (index % 3 == 1 ? -1 : 1)
                    var along = (seed * 0.37 + time * speed / Double(perimeter)).truncatingRemainder(dividingBy: 1)
                    if along < 0 { along += 1 }
                    let point = Self.point(along: CGFloat(along), of: path)
                    let twinkle = 0.5 + 0.5 * sin(time * (0.9 + seed * 0.21) + seed * 1.7)
                    let radius = 0.7 + 0.6 * CGFloat(twinkle) * (index % 2 == 0 ? 1 : 0.6)
                    var mote = context
                    mote.opacity = 0.2 + 0.55 * twinkle
                    mote.addFilter(.shadow(color: Midnight.moonlight.opacity(0.6), radius: 2))
                    mote.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)),
                              with: .color(Midnight.starlight))
                }
                let glints: [(CGPoint, CGFloat, Double)] = [
                    (CGPoint(x: size.width - 20, y: 16), 6, 0),
                    (CGPoint(x: 15, y: size.height * 0.62), 3.2, 2.1),
                ]
                for (point, size, phase) in glints {
                    let twinkle = 0.5 + 0.5 * sin(time * 1.2 + phase)
                    let reach = size * CGFloat(0.65 + 0.35 * twinkle)
                    var star = context
                    star.opacity = 0.5 + 0.45 * twinkle
                    star.addFilter(.shadow(color: Midnight.moonlight.opacity(0.6), radius: 3))
                    star.fill(Sparkle(size: reach).path(in: CGRect(x: point.x - reach, y: point.y - reach, width: 2 * reach, height: 2 * reach)),
                              with: .color(Midnight.starlight))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// `along` (0...1) the way round `rect`, from its top left, clockwise.
    static func point(along: CGFloat, of rect: CGRect) -> CGPoint {
        let perimeter = 2 * (rect.width + rect.height)
        var distance = along * perimeter
        if distance < rect.width { return CGPoint(x: rect.minX + distance, y: rect.minY) }
        distance -= rect.width
        if distance < rect.height { return CGPoint(x: rect.maxX, y: rect.minY + distance) }
        distance -= rect.height
        if distance < rect.width { return CGPoint(x: rect.maxX - distance, y: rect.maxY) }
        distance -= rect.width
        return CGPoint(x: rect.minX, y: rect.maxY - distance)
    }
}

/// Till Oyl's allowed Screen Recording: what to do, and a click opens the setting.
private struct PiPPermission: View {
    let midnight: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(midnight ? "OYL NEEDS SCREEN RECORDING" : "Oyl needs Screen Recording")
                .notchFont(size: midnight ? 11 : 13, weight: .semibold, role: midnight ? .label : nil)
                .tracking(midnight ? Midnight.tracking(.label, size: 11) : 0)
            Text("Click to allow it in System Settings, then reopen Oyl and try again")
                .notchFont(size: 11, role: midnight ? .body : nil)
                .opacity(0.75)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(midnight ? Midnight.white : .white)
        .shadow(color: midnight ? Midnight.moonlight.opacity(0.35) : .clear, radius: 3)
        .padding(.horizontal, 24)
    }
}
