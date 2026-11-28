import AppKit
import ApplicationServices
import Combine
import SwiftUI
import os

/// Windows snapped into place as they're dragged (on a desktop: a fullscreen app's can't be): once
/// a window's on the move and the pointer comes up near the top of the screen, three places to drop
/// it come up just under the notch, the left half, the middle and the right half; over one, where
/// the window will go is shown, and letting go there puts it there (the middle keeps its size, as
/// far as the screen has room). macOS's own tiling at the screen's edges and its menu bar is left
/// as it is: these are under the menu bar, so they never meet. In Oyl's look black pieces of the
/// notch with each place drawn in white, the preview a pale pane; in Midnight Oyl's patches of
/// night with each engraved in silver, the preview a wash of moonlight. Through Accessibility
/// (which Oyl has), asked off the main thread, so an app that's hung never holds Oyl up. Not while
/// Oyl's off or resting, or the desktops' list is up. Snapping windows, in the Keys section.
@MainActor
final class WindowSnap {
    static let shared = WindowSnap()

    enum Place: String, CaseIterable {
        case left, center, right
    }

    // MARK: Where things go (Cocoa's coordinates, the primary screen's bottom-left at 0, 0)

    nonisolated static let targetSize = CGSize(width: 76, height: 48)
    nonisolated static let targetGap: CGFloat = 10
    /// How far under the top of the visible frame (the menu bar's foot) the row is.
    nonisolated static let targetDrop: CGFloat = 12
    /// How near the top the pointer comes before they're shown.
    nonisolated static let nearTop: CGFloat = 150

    /// The three places' targets: a row under the notch (the screen's middle), left to right.
    nonisolated static func targets(in visible: CGRect, middle: CGFloat) -> [(place: Place, rect: CGRect)] {
        let width = 3 * targetSize.width + 2 * targetGap
        let top = visible.maxY - targetDrop
        return Place.allCases.enumerated().map { index, place in
            (place, CGRect(x: middle - width / 2 + CGFloat(index) * (targetSize.width + targetGap), y: top - targetSize.height,
                           width: targetSize.width, height: targetSize.height))
        }
    }

    /// The place whose target `point` is over (a little room round each).
    nonisolated static func place(at point: CGPoint, in targets: [(place: Place, rect: CGRect)]) -> Place? {
        targets.first { $0.rect.insetBy(dx: -targetGap / 2, dy: -8).contains(point) }?.place
    }

    /// Whether `point` is near enough the top of `visible` for the targets to come up.
    nonisolated static func isNearTop(_ point: CGPoint, of visible: CGRect) -> Bool {
        point.y >= visible.maxY - nearTop && point.x >= visible.minX && point.x <= visible.maxX
    }

    /// Where a window now at `window` goes, in `visible`: a half of it, or its middle (as big as
    /// it is, as far as there's room).
    nonisolated static func frame(for place: Place, window: CGRect, in visible: CGRect) -> CGRect {
        switch place {
        case .left: return CGRect(x: visible.minX, y: visible.minY, width: (visible.width / 2).rounded(.down), height: visible.height)
        case .right:
            let width = (visible.width / 2).rounded(.down)
            return CGRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
        case .center:
            let size = CGSize(width: min(window.width, visible.width), height: min(window.height, visible.height))
            return CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        }
    }

    /// Accessibility's frame for a Cocoa one (its origin the primary screen's top-left, down as
    /// it goes), and back: the same both ways.
    nonisolated static func flipped(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Whether a window that was at `start` and is at `now` is being moved (not resized: from its
    /// left edge or top, a resize moves it too).
    nonisolated static func isMove(from start: CGRect, to now: CGRect) -> Bool {
        abs(now.width - start.width) < 1 && abs(now.height - start.height) < 1
            && (abs(now.minX - start.minX) >= 2 || abs(now.minY - start.minY) >= 2)
    }

    // MARK: Following a drag

    /// Whether it can be used now (Oyl on, not resting, the desktops' list away). Set by the controller.
    var isAllowed: () -> Bool = { true }
    var theme = NotchTheme.standard {
        didSet { if theme != model.theme { model.theme = theme } }
    }

    /// A window, as Accessibility has it, to hand to its queue.
    private final class Window: @unchecked Sendable {
        let element: AXUIElement
        let app: String
        let start: CGRect
        init(element: AXUIElement, app: String, start: CGRect) { (self.element, self.app, self.start) = (element, app, start) }
    }

    private let queue = DispatchQueue(label: "oyl.WindowSnap", qos: .userInteractive)
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model = WindowSnapModel()
    private var monitor: Any?
    private var timer: Timer?
    private var downAt: CGPoint?
    private var window: Window?
    private var looking = false
    private var checking = false
    private var moving = false
    private var screen: NSScreen?
    private static let log = Logger(subsystem: "local.nott", category: "window-snap")

    private init() {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: WindowSnapView(model: model))
        host.sizingOptions = []
        panel.contentView = host
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.pressed() }
        }
    }

    /// A click somewhere else: followed while it's held (as a window's dragged, the window server
    /// may keep the drags themselves from anyone watching, so the pointer's looked at instead).
    private func pressed() {
        guard Feature.windowSnapping.isOn, isAllowed(), AXIsProcessTrusted() else { return }
        reset()
        downAt = NSEvent.mouseLocation
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            letGo(at: point)
            return
        }
        guard let downAt else { return }
        if window == nil {
            // Gone a little way: what's being dragged, if it's a window.
            guard !looking, hypot(point.x - downAt.x, point.y - downAt.y) >= 4 else { return }
            looking = true
            let at = Self.flipped(CGRect(origin: downAt, size: .zero), primaryHeight: Self.primaryHeight).origin
            queue.async {
                let found = Self.window(at: at)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.downAt == downAt else { return }
                        self.window = found
                        // Nothing to snap: done with this drag.
                        if found == nil { self.stopFollowing() }
                    }
                }
            }
        } else if !moving, let window {
            guard !checking else { return }
            checking = true
            queue.async {
                let now = Self.frame(of: window.element)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.checking = false
                        guard self.window === window, let now, Self.isMove(from: window.start, to: now) else { return }
                        self.moving = true
                        Self.log.notice("A window of \(window.app, privacy: .public) being dragged")
                    }
                }
            }
        } else if moving {
            follow(point)
        }
    }

    /// On the move: the targets up as the pointer nears the top, and the one it's over lit.
    private func follow(_ point: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return }
        let visible = screen.visibleFrame
        let near = Self.isNearTop(point, of: visible)
        if screen != self.screen {
            self.screen = screen
            if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        }
        let targets = Self.targets(in: visible, middle: screen.frame.midX)
        let place = near ? Self.place(at: point, in: targets) : nil
        let local = { (rect: CGRect) in
            CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        if near, !panel.isVisible {
            model.targets = targets.map { ($0.place, local($0.rect)) }
            panel.orderFrontRegardless()
            EverySpace.rejoin(panel, on: screen)
        }
        let preview = place.flatMap { place in window.map { local(Self.frame(for: place, window: Self.flipped($0.start, primaryHeight: Self.primaryHeight), in: visible)) } }
        withAnimation(theme == .midnight ? .easeInOut(duration: 0.35) : .easeOut(duration: 0.15)) {
            if model.shown != near { model.shown = near }
            if model.hovered != place { model.hovered = place }
            if model.preview != preview { model.preview = preview }
        }
    }

    /// Let go: over a target, the window put there.
    private func letGo(at point: CGPoint) {
        defer { stopFollowing() }
        guard moving, let window, let screen, let place = model.hovered else { return }
        let visible = screen.visibleFrame
        let start = Self.flipped(window.start, primaryHeight: Self.primaryHeight)
        let target = Self.flipped(Self.frame(for: place, window: start, in: visible), primaryHeight: Self.primaryHeight)
        Self.log.notice("A window of \(window.app, privacy: .public) snapped to the \(place.rawValue, privacy: .public)")
        // A moment on, once the app's done with the drag itself.
        queue.asyncAfter(deadline: .now() + 0.05) { Self.set(window.element, to: target) }
    }

    private func stopFollowing() {
        timer?.invalidate()
        timer = nil
        let wasShown = panel.isVisible
        withAnimation(theme == .midnight ? .easeInOut(duration: 0.4) : .easeOut(duration: 0.15)) {
            model.shown = false
            model.hovered = nil
            model.preview = nil
        }
        if wasShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.timer == nil else { return }
                self.panel.orderOut(nil)
            }
        }
        reset()
    }

    private func reset() {
        downAt = nil
        window = nil
        looking = false
        checking = false
        moving = false
    }

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    // MARK: Accessibility (on its queue)

    /// The standard window at `point` (Accessibility's coordinates) of an app that isn't Oyl, and
    /// not in fullscreen: where it is, and whose.
    private nonisolated static func window(at point: CGPoint) -> Window? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != getpid() else { return nil }
        AXUIElementSetMessagingTimeout(hit, 0.25)
        let window: AXUIElement
        if string(hit, kAXRoleAttribute) == kAXWindowRole as String {
            window = hit
        } else {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &value) == .success, let value,
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            window = value as! AXUIElement
        }
        guard string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String else { return nil }
        var full: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &full) == .success, (full as? Bool) == true { return nil }
        guard let start = frame(of: window) else { return nil }
        return Window(element: window, app: NSRunningApplication(processIdentifier: pid)?.localizedName ?? "an app", start: start)
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Where `window` is, in Accessibility's coordinates.
    private nonisolated static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// `window` put at `frame`: its size, where it goes, and its size again, as an app can keep one
    /// from fitting the other (one whose size can't be set is only moved).
    private nonisolated static func set(_ window: AXUIElement, to frame: CGRect) {
        var origin = frame.origin, extent = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let size = AXValueCreate(.cgSize, &extent) else { return }
        var settable: DarwinBoolean = false
        let sizes = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
        if sizes { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size) }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        if sizes { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size) }
    }
}

@MainActor
final class WindowSnapModel: ObservableObject {
    @Published var shown = false
    @Published var hovered: WindowSnap.Place?
    /// Where the window will go, and the targets, in the panel (top-left first).
    @Published var preview: CGRect?
    @Published var targets: [(place: WindowSnap.Place, rect: CGRect)] = []
    @Published var theme = NotchTheme.standard
}

/// The three targets, and where the window will go. In Oyl's look black pieces of the notch, each
/// with its place drawn in white, the one pointed at outlined; the preview a pale pane. In
/// Midnight Oyl's patches of night, each place engraved in silver, the one pointed at in
/// moonlight; the preview a wash of moonlight feathered into the desktop.
struct WindowSnapView: View {
    @ObservedObject var model: WindowSnapModel

    var body: some View {
        let midnight = model.theme == .midnight
        ZStack(alignment: .topLeading) {
            if let preview = model.preview {
                Group {
                    if midnight {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Midnight.moonlight.opacity(0.1))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Midnight.silver.opacity(0.45), lineWidth: 0.75))
                            .shadow(color: Midnight.moonlight.opacity(0.35), radius: 18)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5))
                    }
                }
                .frame(width: preview.width - 8, height: preview.height - 8)
                .offset(x: preview.minX + 4, y: preview.minY + 4)
                .transition(.opacity)
            }
            ForEach(model.targets, id: \.place) { target in
                SnapTarget(place: target.place, lit: model.hovered == target.place, midnight: midnight)
                    .frame(width: target.rect.width, height: target.rect.height)
                    .offset(x: target.rect.minX, y: target.rect.minY)
            }
            .opacity(model.shown ? 1 : 0)
            .offset(y: model.shown ? 0 : -8)
            .blur(radius: midnight && !model.shown ? 4 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// One target: a small screen, its place in it.
private struct SnapTarget: View {
    let place: WindowSnap.Place
    let lit: Bool
    let midnight: Bool

    var body: some View {
        ZStack {
            if midnight {
                // A patch of night with no edge: gone by the edges of the room it's given.
                EllipticalGradient(colors: [Midnight.ink.opacity(0.95), Midnight.ink.opacity(0.8), Midnight.ink.opacity(0)],
                                   center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                    .padding(-18)
            } else {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.black.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(lit ? 0.85 : 0.14), lineWidth: lit ? 1.5 : 0.75))
            }
            Canvas { context, size in
                let screen = CGRect(x: 14, y: 10, width: size.width - 28, height: size.height - 20)
                let line = midnight ? Midnight.silver.opacity(lit ? 0.95 : 0.6) : Color.white.opacity(lit ? 0.9 : 0.5)
                let fill = midnight ? Midnight.moonlight.opacity(lit ? 0.75 : 0.35) : Color.white.opacity(lit ? 0.95 : 0.6)
                context.stroke(Path(roundedRect: screen, cornerRadius: 3), with: .color(line), lineWidth: midnight ? 0.75 : 1)
                let inset = screen.insetBy(dx: 2.5, dy: 2.5)
                let part: CGRect
                switch place {
                case .left: part = CGRect(x: inset.minX, y: inset.minY, width: inset.width / 2 - 1, height: inset.height)
                case .right: part = CGRect(x: inset.midX + 1, y: inset.minY, width: inset.width / 2 - 1, height: inset.height)
                case .center: part = inset.insetBy(dx: inset.width * 0.22, dy: inset.height * 0.16)
                }
                context.fill(Path(roundedRect: part, cornerRadius: 1.5), with: .color(fill))
            }
        }
        .scaleEffect(lit ? 1.06 : 1)
        .shadow(color: midnight && lit ? Midnight.moonlight.opacity(0.5) : .clear, radius: 8)
        .animation(midnight ? .easeInOut(duration: 0.3) : .easeOut(duration: 0.12), value: lit)
    }
}
