import AppKit
import Combine
import SwiftUI

/// The Space you're on (a desktop, or a fullscreen app's), as the window server tells it: what its
/// name's kept under, and what it's called till it's given one.
struct CurrentSpace: Equatable {
    /// Its own: "space:" and its UUID (the first desktop has none, so its number instead).
    let key: String
    /// A fullscreen app's window, which keeps its name when it leaves fullscreen and comes back
    /// (a new Space each time), till the Mac restarts.
    let window: String?
    /// "desktop 2", as Mission Control numbers them; a fullscreen app's, the app's name: in lower
    /// case, as names Oyl gives are (one you type is kept as you type it).
    let standard: String
    let isFullscreen: Bool
    /// The window server's number for it, and (a fullscreen app's) its app.
    var id = 0
    var pid: pid_t?
}

enum Spaces {
    /// The one showing on `screen`.
    @MainActor
    static func current(on screen: NSScreen) -> CurrentSpace? {
        FullscreenSpace.display(for: screen).flatMap { display in
            current(in: display, boot: bootTime) { NSRunningApplication(processIdentifier: $0)?.localizedName }
        }
    }

    /// The one showing, from a display's list (see `FullscreenSpace.display(for:)`): `boot` is when
    /// the Mac started, as window numbers only last till then; `appName` an app's name, by pid.
    static func current(in display: [String: Any], boot: Int, appName: (pid_t) -> String?) -> CurrentSpace? {
        guard let space = display["Current Space"] as? [String: Any] else { return nil }
        return self.space(space, in: display, boot: boot, appName: appName)
    }

    /// All of a display's Spaces, in order (as ⌃← and ⌃→ go between them), and which is showing.
    static func all(in display: [String: Any], boot: Int, appName: (pid_t) -> String?) -> (spaces: [CurrentSpace], current: Int?) {
        let spaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space($0, in: display, boot: boot, appName: appName) }
        let showing = (display["Current Space"] as? [String: Any]).flatMap { number($0["ManagedSpaceID"]) }
        return (spaces, spaces.firstIndex { $0.id == showing })
    }

    /// One of a display's Spaces, as it's named and kept.
    private static func space(_ space: [String: Any], in display: [String: Any], boot: Int, appName: (pid_t) -> String?) -> CurrentSpace? {
        guard let id = number(space["ManagedSpaceID"]) else { return nil }
        let uuid = (space["uuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let key = "space:" + (uuid ?? "id\(id)")
        if number(space["type"]) == FullscreenSpace.fullscreenType {
            let window = number(space["fs_wid"]).map { "window:\(boot)-\($0)" }
            let pid = number(space["pid"]).map { pid_t($0) }
            let name = pid.flatMap(appName) ?? "Full Screen"
            return CurrentSpace(key: key, window: window, standard: name.lowercased(), isFullscreen: true, id: id, pid: pid)
        }
        let desktops = (display["Spaces"] as? [[String: Any]] ?? []).filter { number($0["type"]) != FullscreenSpace.fullscreenType }
        let index = desktops.firstIndex { number($0["ManagedSpaceID"]) == id }
        return CurrentSpace(key: key, window: nil, standard: (index.map { "Desktop \($0 + 1)" } ?? "Desktop").lowercased(),
                            isFullscreen: false, id: id)
    }

    private static func number(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    /// Each fullscreen Space made of several (apps put side by side, in Mission Control or by
    /// tiling a window into another's): everything those were kept under, its own key, each of its
    /// windows' (a fullscreen app's window key, see `CurrentSpace.window`), and the Spaces they
    /// came from.
    static func combined(in display: [String: Any], boot: Int) -> [Set<String>] {
        (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space in
            guard number(space["type"]) == FullscreenSpace.fullscreenType,
                  let tiles = (space["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]], tiles.count > 1 else { return nil }
            var keys = Set<String>()
            if let uuid = (space["uuid"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) { keys.insert("space:" + uuid) }
            else if let id = number(space["ManagedSpaceID"]) { keys.insert("space:id\(id)") }
            if let window = number(space["fs_wid"]) { keys.insert("window:\(boot)-\(window)") }
            for tile in tiles {
                if let window = number(tile["fs_wid"]) ?? number(tile["TileWindowID"]) { keys.insert("window:\(boot)-\(window)") }
                if let from = (tile["fromSpace"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) { keys.insert("space:" + from) }
            }
            return keys
        }
    }

    /// When the Mac started, in seconds since 1970.
    static let bootTime: Int = {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        return sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 ? Int(time.tv_sec) : 0
    }()
}

/// The names you've given Spaces, kept in the defaults.
struct SpaceNames {
    static let key = "spaces.names"
    /// The longest a name can be.
    static let longest = 40
    /// How many are kept: past that, fullscreen apps' windows' go first (they're the ones that
    /// don't last).
    static let most = 300

    var defaults = UserDefaults.standard

    private var all: [String: String] { defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:] }

    /// What `space` is called: the name it's been given, or its own.
    func name(of space: CurrentSpace) -> String {
        let all = self.all
        return all[space.key] ?? space.window.flatMap { all[$0] } ?? space.standard
    }

    /// Named `name`, trimmed (and cut to the longest); nothing, or its own name, puts its own back.
    func rename(_ space: CurrentSpace, to name: String) {
        var all = self.all
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.longest))
        let keys = [space.key] + (space.window.map { [$0] } ?? [])
        if name.isEmpty || name == space.standard {
            for key in keys { all[key] = nil }
        } else {
            for key in keys { all[key] = name }
        }
        if all.count > Self.most {
            for key in all.keys.filter({ $0.hasPrefix("window:") && !keys.contains($0) }).prefix(all.count - Self.most) {
                all[key] = nil
            }
        }
        defaults.set(all, forKey: Self.key)
    }
}

/// The desktop you're on, named at the top left of the menu bar, on the notch's screen: "desktop
/// 2" as Mission Control numbers them (a fullscreen app's Space, the app's name), in lower case,
/// or whatever you've called it, as you typed it. Click it to rename it: Return keeps what's typed
/// (nothing puts its own name back), Escape doesn't, and clicking anywhere else keeps it too. It's
/// up for 3 seconds on each desktop you go to (and as Oyl or it is turned on), then fades: longer
/// while the pointer's on it or it's being renamed, and for 3 seconds more once it's been renamed.
///
/// In Oyl's look it's a piece of the notch, in black, flush with the top and left of the screen,
/// its bottom corner rounded and its top flared into the edge as the notch's are; a new desktop's
/// name fades in over the last on a plain ease. In Midnight Oyl's it's a patch of night with no
/// edge, fading out past the name, a glint twinkling before it that flares as you go to another
/// desktop, the name coming in out of a blur.
///
/// On a desktop it sits over the Apple menu (and the app's, as far as it reaches), so a right-click
/// on it opens whichever of them is under it. In a fullscreen app it's in the black strip by the
/// notch, and the menu bar slides down over it as ever: it never takes the pointer there (the menu
/// bar has to see it leave to slide back up), so a click on it is caught on its way through, unless
/// the menu bar's down. Away while Oyl's off or resting, in Mission Control, under Midnight's band,
/// and when it's turned off on the Oyls tab. The Oyls on the bar keep off it.
@MainActor
final class SpaceLabel {
    private let panel = NotchPanel()
    private let model = SpaceLabelModel()
    private let host: SpaceLabelHostingView
    private let state: NotchState
    private let names = SpaceNames()
    private var space: CurrentSpace?
    /// The one being renamed, kept in case you go to another Space meanwhile.
    private var renaming: CurrentSpace?
    private var screen: NSScreen?
    private var isOn = Feature.spaceLabel.isOn
    /// Wanted up (it's still fading in or out a moment after).
    private var isUp = false
    /// In a fullscreen app: the menu bar's slid down over the strip (the pointer went up to the
    /// very top, and hasn't left the bar since).
    private var menuBarDown = false
    private var shrinking: DispatchWorkItem?
    private var going: DispatchWorkItem?
    /// Still in its first moments on this Space (it fades once they're over).
    private var lingering = true
    private var lingerWork: DispatchWorkItem?
    /// It could be up (it's on, Oyl's on, and the Space is known): coming to be, it lingers again.
    private var couldBeUp = false
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    /// How long it stays on each Space you go to.
    static let stays: TimeInterval = 3

    /// Where it is along the bar, from the screen's left, while it's up: for the Oyls to keep off.
    var onSpan: (ClosedRange<CGFloat>?) -> Void = { _ in }

    init(state: NotchState) {
        self.state = state
        host = SpaceLabelHostingView(rootView: SpaceLabelView(model: model, submit: {}, cancel: {}, ended: {}))
        host.sizingOptions = []
        panel.contentView = host
        // With the Oyls: over the menu bar, under the notch (so Midnight's band comes over it).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        host.rootView = SpaceLabelView(model: model,
                                       submit: { [weak self] in self?.finish(keeping: true) },
                                       cancel: { [weak self] in self?.finish(keeping: false) },
                                       ended: { [weak self] in self?.finish(keeping: true) })
        host.rightClicked = { [weak self] x in self?.openMenu(atX: x) }
        host.clicked = { [weak self] in self?.startRenaming() }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(keeping: true) }
        }
        state.$theme
            .sink { [weak self] theme in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.theme = theme
                    DispatchQueue.main.async { self.place() }
                }
            }
            .store(in: &cancellables)
        // Off, resting, Mission Control, Midnight's band opening (all the notch's).
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &cancellables)
        Features.shared.follow(.spaceLabel) { [weak self] on in
            self?.isOn = on
            self?.update()
        }
        .store(in: &cancellables)
        model.$draft
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { if self?.model.editing == true { self?.place() } } }
            .store(in: &cancellables)

        // In a fullscreen app it never takes the pointer, so its clicks are caught on their way
        // through; and where the pointer goes says whether the menu bar's slid down over it.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedThrough(at: NSEvent.mouseLocation) }
        }) {
            monitors.append(monitor)
        }
        refresh()
    }

    /// Which Space is showing, and so what it's called; and where the bar is.
    private func refresh() {
        screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
        let now = screen.flatMap(Spaces.current(on:))
        if now?.key != space?.key, model.editing { finish(keeping: true) }
        if now?.key != space?.key { linger() }
        if now != space {
            space = now
            menuBarDown = false
        }
        let name = now.map(names.name(of:)) ?? ""
        if name != model.name {
            if !model.name.isEmpty { model.changes += 1 }
            model.name = name
        }
        update()
        if isUp { DispatchQueue.main.async { [weak self] in self?.place() } }
    }

    /// Up, or away.
    private func update() {
        let could = isOn && space != nil && !state.isOff && !state.isResting
        if could, !couldBeUp { linger() }
        couldBeUp = could
        let wanted = could && (lingering || model.editing) && !state.isViewingDesktops && !state.isBlooming
        if !wanted, model.editing { finish(keeping: true) }
        let through = !wanted || (space?.isFullscreen == true && !model.editing)
        if panel.ignoresMouseEvents != through { panel.ignoresMouseEvents = through }
        guard wanted != isUp else { return }
        isUp = wanted
        if wanted {
            going?.cancel()
            going = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isUp else { return }
                self.place()
                if !self.panel.isVisible { self.panel.orderFrontRegardless() }
                if !self.model.shown { self.model.shown = true }
                self.place()
            }
        } else {
            model.shown = false
            onSpan(nil)
            guard going == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.model.shown else { return }
                self.going = nil
                self.panel.orderOut(nil)
            }
            going = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    /// Up for its few seconds again, from now.
    private func linger() {
        lingering = true
        lingerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lingerOver() }
        lingerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stays, execute: work)
    }

    /// Its seconds are up: it fades, unless it's being renamed or the pointer's on it (then once
    /// that's over).
    private func lingerOver() {
        lingerWork = nil
        let pointedAt = model.shown && panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
        guard !model.editing, !pointedAt else {
            let work = DispatchWorkItem { [weak self] in self?.lingerOver() }
            lingerWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            return
        }
        lingering = false
        update()
    }

    /// At the screen's top left, as deep as the menu bar, as wide as the name: grown at once, and
    /// shrunk once the last name's faded out, so it's never cut off.
    private func place() {
        guard let screen else { return }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let height = menuBar > 0 ? menuBar : max(screen.safeAreaInsets.top, 24)
        if model.height != height { model.height = height }
        let width = SpaceLabelView.width(of: model)
        if model.shown { onSpan(0...width) }
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: width, height: height)
        shrinking?.cancel()
        shrinking = nil
        guard frame != panel.frame else { return }
        let narrower = frame.width < panel.frame.width && panel.frame.origin == frame.origin && panel.frame.height == height
        guard narrower, !model.editing, panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.shrinking = nil
            self.panel.setFrame(frame, display: true)
        }
        shrinking = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    // MARK: Renaming

    private func startRenaming() {
        guard let space, !model.editing, model.shown else { return }
        renaming = space
        model.placeholder = space.standard
        model.draft = names.name(of: space)
        model.editing = true
        panel.ignoresMouseEvents = false
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    /// Done renaming: what's typed kept, or not.
    private func finish(keeping: Bool) {
        guard model.editing else { return }
        model.editing = false
        if keeping, let renaming { names.rename(renaming, to: model.draft) }
        renaming = nil
        // Typing goes back to the app you were using.
        if panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        panel.ignoresMouseEvents = space?.isFullscreen == true
        let name = space.map(names.name(of:)) ?? ""
        if name != model.name { model.name = name }
        // The new name's up a moment before it goes.
        linger()
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    // MARK: The pointer

    private func pointerMoved(to location: NSPoint) {
        guard space?.isFullscreen == true, let screen else { return }
        if location.y >= screen.frame.maxY - 1 {
            menuBarDown = true
        } else if location.y < screen.frame.maxY - model.height - 2 {
            menuBarDown = false
        }
    }

    /// A click seen on its way to another app: on it, in a fullscreen app (where it doesn't take
    /// the pointer), it's renamed, unless it's the menu bar that was clicked; anywhere else while
    /// it's being renamed, what's typed is kept.
    private func clickedThrough(at location: NSPoint) {
        let inside = panel.isVisible && panel.frame.insetBy(dx: 0, dy: -1).contains(location)
        if model.editing {
            if !inside { finish(keeping: true) }
            return
        }
        guard inside, space?.isFullscreen == true, !menuBarDown, !state.isViewingDesktops, !state.isTakingShot else { return }
        startRenaming()
    }

    /// The menu under `x` on the menu bar (the Apple menu, or the app's), opened through
    /// Accessibility, off the main thread (pressing one can wait till it's closed).
    private func openMenu(atX x: CGFloat) {
        guard let app = NSWorkspace.shared.menuBarOwningApplication else { return }
        let pid = app.processIdentifier, x = (screen?.frame.minX ?? 0) + x
        DispatchQueue.global(qos: .userInitiated).async {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 1)
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
                  CFGetTypeID(bar) == AXUIElementGetTypeID() else { return }
            for item in ButtonReader.elements(bar as! AXUIElement, kAXChildrenAttribute) {
                guard let frame = Self.frame(of: item), frame.minX <= x, x < frame.maxX else { continue }
                AXUIElementPerformAction(item, kAXPressAction as CFString)
                return
            }
        }
    }

    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}

/// Clicks on it, as they come (it's never key till it's being renamed).
final class SpaceLabelHostingView: NSHostingView<SpaceLabelView> {
    var clicked: () -> Void = {}
    /// Right-clicked this far along it.
    var rightClicked: (CGFloat) -> Void = { _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Into the field, while it's being renamed; else, it's to be.
        if rootView.model.editing {
            super.mouseDown(with: event)
        } else {
            clicked()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !rootView.model.editing else { return super.rightMouseDown(with: event) }
        rightClicked(convert(event.locationInWindow, from: nil).x)
    }
}

@MainActor
final class SpaceLabelModel: ObservableObject {
    @Published var name = ""
    @Published var shown = false
    @Published var editing = false
    @Published var draft = ""
    /// Its own name, which nothing typed puts back.
    @Published var placeholder = ""
    @Published var theme = NotchTheme.standard
    /// The menu bar's.
    @Published var height: CGFloat = 24
    /// Counts each move to another Space, for Midnight's glint to flare.
    @Published var changes = 0
}

struct SpaceLabelView: View {
    @ObservedObject var model: SpaceLabelModel
    let submit: () -> Void
    let cancel: () -> Void
    let ended: () -> Void

    /// In from the screen's edge (past its rounded corner), and out past the name.
    static let lead: CGFloat = 14
    static let trail: CGFloat = 12
    /// Oyl's look: the flare into the top edge, and the bottom corner's round.
    static let flare: CGFloat = 6
    static let corner: CGFloat = 9
    /// Midnight's: how far its night fades out past the name.
    static let fade: CGFloat = 24
    static let widest: CGFloat = 280

    var body: some View {
        let midnight = model.theme == .midnight
        HStack(spacing: 7) {
            if midnight {
                SpaceGlint(changes: model.changes, running: model.shown)
                    .frame(width: 11, height: 11)
            }
            ZStack(alignment: .leading) {
                if model.editing {
                    ReminderField(text: $model.draft, placeholder: model.placeholder, onSubmit: submit, onCancel: cancel,
                                  selecting: NSRange(location: 0, length: (model.draft as NSString).length), onEnd: ended)
                        .frame(width: Self.fieldWidth(of: model), height: 18)
                } else {
                    Text(model.name)
                        .notchFont(size: 13)
                        .foregroundStyle(midnight ? Midnight.white : .white.opacity(0.9))
                        .shadow(color: midnight ? Midnight.moonlight.opacity(0.35) : .clear, radius: 3)
                        .lineLimit(1)
                        .frame(maxWidth: Self.widest, alignment: .leading)
                        .fixedSize()
                        .id(model.name)
                        .transition(midnight ? .asymmetric(insertion: .modifier(active: Blurred(amount: 1), identity: Blurred(amount: 0)),
                                                           removal: .modifier(active: Blurred(amount: 1), identity: Blurred(amount: 0)))
                                             : .opacity)
                }
            }
        }
        .padding(.leading, Self.lead)
        .padding(.trailing, midnight ? Self.fade : Self.trail + Self.flare)
        .frame(height: model.height)
        .background(backdrop(midnight: midnight))
        .contentShape(Rectangle())
        .opacity(model.shown ? 1 : 0)
        .animation(midnight ? .easeOut(duration: 0.6) : .easeInOut(duration: 0.25), value: model.name)
        .animation(midnight ? .easeOut(duration: 0.5) : .easeInOut(duration: 0.2), value: model.shown)
        .animation(.easeInOut(duration: 0.15), value: model.editing)
        .environment(\.notchTheme, model.theme)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// How wide it is, worked out from its type (its window can be wider, while a longer name
    /// fades out).
    @MainActor
    static func width(of model: SpaceLabelModel) -> CGFloat {
        let midnight = model.theme == .midnight
        let middle = model.editing ? fieldWidth(of: model) : min(measure(model.name, midnight: midnight) + 1, widest)
        return lead + (midnight ? 11 + 7 : 0) + middle + (midnight ? fade : trail + flare)
    }

    /// As wide as what's typed (or its own name, with nothing typed), as the field sets it.
    @MainActor
    static func fieldWidth(of model: SpaceLabelModel) -> CGFloat {
        let text = model.draft.isEmpty ? model.placeholder : model.draft
        return min(max(measure(text, midnight: model.theme == .midnight) + 10, 48), widest)
    }

    /// The name's type, as `notchFont(size: 13)` and the field set it: the system's, or Midnight's
    /// reading face.
    private static func measure(_ text: String, midnight: Bool) -> CGFloat {
        let font = midnight ? NSFont(name: "Georgia", size: 13 * 1.06) ?? .systemFont(ofSize: 13) : .systemFont(ofSize: 13)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    @ViewBuilder
    private func backdrop(midnight: Bool) -> some View {
        if midnight {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                // Solid under the name (whatever's on the menu bar under it), easing away past it.
                let start = max(0, (width - Self.fade) / width)
                LinearGradient(stops: [
                    .init(color: Midnight.ink, location: 0),
                    .init(color: Midnight.ink, location: start),
                    .init(color: Midnight.ink.opacity(0.55), location: start + (1 - start) * 0.4),
                    .init(color: Midnight.ink.opacity(0), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
        } else {
            SpaceTab(flare: Self.flare, corner: Self.corner)
                .fill(.black)
        }
    }
}

/// Oyl's look: a piece of the notch at the screen's top left, flush with the top and left edges,
/// its bottom right corner rounded and its top right flared into the top edge.
struct SpaceTab: Shape {
    var flare: CGFloat
    var corner: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let right = rect.maxX - flare
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + flare), control: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - corner))
        path.addQuadCurve(to: CGPoint(x: right - corner, y: rect.maxY), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A name coming in or going, in Midnight Oyl: out of a blur, drifting in from the left a little.
private struct Blurred: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: 6 * amount)
            .opacity(1 - amount)
            .offset(x: -5 * amount)
    }
}

/// Midnight Oyl's glint before the name, twinkling slowly; going to another Space, it flares.
private struct SpaceGlint: View {
    let changes: Int
    let running: Bool
    @StateObject private var flared = LocalState(Date.distantPast)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !running)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let since = context.date.timeIntervalSince(flared.value)
            // A flare: up quickly, and slowly back down.
            let flare = since < 0 || since > 1.6 ? 0 : (since < 0.25 ? since / 0.25 : 1 - (since - 0.25) / 1.35)
            let twinkle = 0.5 + 0.5 * sin(time * 1.3)
            Canvas { canvas, size in
                let reach = size.width / 2 * CGFloat(0.55 + 0.25 * twinkle + 0.45 * flare)
                let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                var star = canvas
                star.opacity = 0.55 + 0.3 * twinkle + 0.15 * flare
                star.addFilter(.shadow(color: Midnight.moonlight.opacity(0.5 + 0.4 * flare), radius: 2 + 3 * flare))
                star.fill(Sparkle(size: reach).path(in: CGRect(x: middle.x - reach, y: middle.y - reach, width: 2 * reach, height: 2 * reach)),
                          with: .color(Midnight.starlight))
            }
        }
        .onChange(of: changes) { flared.value = Date() }
    }
}
