import AppKit
import Combine
import SwiftUI

/// Oyl's Dock: along the bottom of the screen, in the notch's look, over the macOS Dock (which
/// hides itself, and comes up behind it, covered). Like the notch, it comes up as the pointer
/// reaches it (the bottom edge, under where it'd be) and goes once the pointer's left it (with
/// some room round it and a moment's grace, more with a shelf up; see `nearArea`). Click an
/// app to open it or switch to it, right-click for the rest; the shelf (the latest screenshots,
/// and files kept to convert or drag out) is a tile past the apps, opening over the bar, with
/// another next to it for what's just been saved. Which icon the pointer's on is worked out from
/// where it is, every move, so none is ever left lifted.
@MainActor
final class DockController {
    private let panel = NotchPanel()
    private let model = DockModel()
    private let apps = DockApps()
    private let state: NotchState
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var closing: DispatchWorkItem?
    /// The pointer's at the bottom edge: it comes up if it's still there in a moment (see `dwell`).
    private var opening: DispatchWorkItem?
    /// Faded away while something's dragged off the shelf to elsewhere.
    private var fadedForDrag = false
    private var cancellables = Set<AnyCancellable>()

    init(state: NotchState) {
        self.state = state
        // Over the macOS Dock, under everything else.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        // Told of every move over it too, not only over other apps' windows.
        panel.acceptsMouseMovedEvents = true
        let host = DockHostingView(rootView: DockView(model: model, apps: apps, shelf: state.shelf, saved: state.saved))
        host.sizingOptions = []
        panel.contentView = host
        model.toggleShelf = { [weak self] in self?.toggleShelf($0) }
        ShelfDrag.shared.moved = { [weak self] point in self?.shelfDragMoved(to: point) }
        ShelfDrag.shared.ended = { [weak self] point in self?.shelfDragEnded(at: point) }

        state.$theme.sink { [weak self] theme in
            self?.model.theme = theme
            if self?.model.isOpen == true { self?.fit() }
        }.store(in: &cancellables)
        state.$isOff.sink { [weak self] off in
            if off { self?.close() }
        }.store(in: &cancellables)
        // Mission Control's up: it has the screen.
        state.$isViewingDesktops.sink { [weak self] viewing in
            if viewing { self?.close() }
        }.store(in: &cancellables)
        state.$showsDock.sink { [weak self] shown in
            if !shown { self?.close() }
        }.store(in: &cancellables)
        // The macOS Dock kept down while this one's up for it (see `MacDock`).
        state.$showsDock.combineLatest(state.$isOff, Features.shared.changed.filter { $0.0 == .hidesMacDock }.map { _ in () }
            .prepend(()))
            .receive(on: RunLoop.main)
            .sink { shown, off, _ in
                MainActor.assumeIsolated { MacDock.keep(down: shown && !off && Feature.hidesMacDock.isOn) }
            }
            .store(in: &cancellables)
        // A shelf turned off goes from the bar (and stops watching), its card with it.
        Features.shared.changed
            .filter { $0.0 == .screenshotsShelf || $0.0 == .savedShelf }
            .sink { [weak self] change in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let shelf = change.0 == .savedShelf ? state.saved : state.shelf
                    if !change.1 {
                        shelf.stopWatching()
                        if self.model.shelving == shelf.source { self.toggleShelf(shelf.source) }
                    }
                    self.apps.objectWillChange.send()
                    if self.model.isOpen { self.fit() }
                }
            }
            .store(in: &cancellables)
        // An app opening or quitting changes its width; one quit some other way isn't asked about.
        apps.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let quitting = self.model.quitting, !self.apps.apps.contains(where: { $0.id == quitting && $0.isRunning }),
                   !self.apps.others.contains(where: { $0.id == quitting && $0.isRunning }) {
                    self.model.quitting = nil
                }
                if self.model.isOpen { self.fit() }
            }
        }.store(in: &cancellables)
        // A click anywhere else is a no to quitting.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.model.quitting = nil }
        }) {
            monitors.append(monitor)
        }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.panel { self.pressedOn = true }
            }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    /// Pressed on it, and not let go yet: it stays up wherever the pointer's got to meanwhile.
    private var pressedOn = false
    private var isPressed: Bool {
        if pressedOn, NSEvent.pressedMouseButtons & 1 == 0 { pressedOn = false }
        return pressedOn
    }

    private var canOpen: Bool { state.showsDock && !state.isOff && !state.isResting && !state.isViewingDesktops }

    private func pointerMoved() {
        guard canOpen else { return }
        let location = NSEvent.mouseLocation
        if model.isOpen {
            let over = isOver(location)
            hover(at: location)
            // Asking about quitting an app is over once the pointer's gone right away from it.
            if model.quitting != nil, !panel.frame.insetBy(dx: -8, dy: -8).contains(location) { model.quitting = nil }
            if isNear(location) || model.isKept || isPressed {
                closing?.cancel()
                closing = nil
            } else {
                scheduleClose()
            }
            // Off it, clicks go through to what's under it.
            let takes = over || model.isKept
            if panel.ignoresMouseEvents == takes { panel.ignoresMouseEvents = !takes }
            return
        }
        // Reaching the bottom edge in the middle of the screen (see `calls`) and staying a moment,
        // as the Dock comes up: mid-drag too, as the Dock does, to be dropped on.
        guard Self.callingScreen(at: location) != nil else {
            opening?.cancel()
            opening = nil
            return
        }
        guard opening == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.opening = nil
                guard self.canOpen, !self.model.isOpen, let screen = Self.callingScreen(at: NSEvent.mouseLocation) else { return }
                self.open(on: screen)
            }
        }
        opening = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: work)
    }

    /// How much of the screen's width, in the middle, the bottom edge brings the Dock up along.
    nonisolated static let reach: CGFloat = 0.4
    /// How long the pointer stays there first: only just, so passing over it on the way to a
    /// corner, or to something low down, doesn't bring it up.
    nonisolated static let dwell: TimeInterval = 0.15

    /// The screen whose bottom edge the pointer's calling the Dock up at, if it is.
    private static func callingScreen(at location: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }.flatMap { calls(location, on: $0.frame) ? $0 : nil }
    }

    /// Whether the pointer at `location` calls the Dock up on the screen `frame`: at its bottom edge,
    /// within the middle `reach` of it, so the corners (and the rest of the edge) are left alone.
    nonisolated static func calls(_ location: NSPoint, on frame: NSRect) -> Bool {
        location.y <= frame.minY + 1 && abs(location.x - frame.midX) <= frame.width * reach / 2
    }

    /// The icon under the pointer, if any: each one's own width and half the gap either side.
    private func hover(at location: NSPoint) {
        guard let screen else { return }
        let layout = DockLayout(apps: apps, screenWidth: screen.frame.width)
        let x = location.x - (screen.frame.midX - layout.size.width / 2)
        var hovered: String?
        if location.y - screen.frame.minY <= layout.size.height + 4 {
            let ids = DockView.ids(apps)
            let reach = DockLayout.spacing / 2
            if let index = layout.frames.firstIndex(where: { x >= $0.minX - reach && x < $0.maxX + reach }), index < ids.count {
                hovered = ids[index]
            }
        }
        if model.hovered != hovered { model.hovered = hovered }
    }

    private func open(on screen: NSScreen) {
        self.screen = screen
        model.screenWidth = screen.frame.width
        model.calledFrom = NSEvent.mouseLocation.x - screen.frame.midX
        apps.reload()
        fit()
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = false
        model.isOpen = true
        hover(at: NSEvent.mouseLocation)
        Haptics.perform(.levelChange, performanceTime: .now)
    }

    /// Off it, it waits a moment (see `grace`) in case the pointer's coming back.
    private func scheduleClose() {
        guard closing == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.closing = nil
                guard let self, !self.model.isKept, !self.isPressed, !self.isNear(NSEvent.mouseLocation) else { return }
                self.close()
            }
        }
        closing = work
        let grace = Self.grace(shelving: model.isShelving, sinceLetGo: model.letGo.map { Date().timeIntervalSince($0) })
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
    }

    /// How long the pointer can be off it before it goes: a moment, longer with a shelf up (being
    /// used), and longer still just after a menu or the file picker's gone, which may have left
    /// the pointer off it.
    nonisolated static func grace(shelving: Bool, sinceLetGo: TimeInterval?) -> TimeInterval {
        max(shelving ? 0.5 : 0.3, 1.2 - (sinceLetGo ?? .infinity))
    }

    private func close() {
        closing?.cancel()
        closing = nil
        model.quitting = nil
        model.shelving = nil
        model.isOpen = false
        model.hovered = nil
        panel.ignoresMouseEvents = true
    }

    /// A shelf, over the bar (in place of the other, if that's up), or put away again: the panel
    /// only shrinks back once it's gone back into its tile (or the sky's settled), so neither's cut off.
    private func toggleShelf(_ source: Shelf.Source) {
        model.quitting = nil
        model.shelving = model.shelving == source ? nil : source
        guard !model.isShelving else {
            fit()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.isOpen, !self.model.isShelving else { return }
                self.fit()
            }
        }
    }

    /// Something dragged off the shelf: once it's off the Dock, the Dock fades away so whatever's
    /// under it can take the drop, and comes back if it's brought back over (to be dropped on an
    /// app, say).
    private func shelfDragMoved(to point: NSPoint) {
        let over = isOver(point)
        guard fadedForDrag == over else { return }
        fadedForDrag = !over
        panel.ignoresMouseEvents = !over
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = over ? 1 : 0
        }
    }

    /// Dropped off the Dock, it goes (out of sight), and is back as it was once it has.
    private func shelfDragEnded(at point: NSPoint) {
        fadedForDrag = false
        guard !isOver(point) else {
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
            return
        }
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !ShelfDrag.shared.isDragging else { return }
                self.panel.alphaValue = 1
            }
        }
    }

    /// The panel along the bottom: as wide as the bar and the room either side of it, and, with the
    /// shelf up, tall enough for it too.
    private func fit() {
        guard let screen = screen ?? NSScreen.main else { return }
        let midnight = model.theme == .midnight
        var size = DockLayout(apps: apps, screenWidth: screen.frame.width).window(midnight: midnight)
        // Midnight Oyl's sky reaches right across the foot of the screen, as its band does the top.
        if midnight { size.width = screen.frame.width }
        if model.isShelving {
            size.width = max(size.width, model.cardWidth + 2 * DockLayout.sideRoom(midnight: midnight))
            size.height += ShelfCard.height + DockLayout.cardGap
        }
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// The bar on screen, and a little round it.
    private func barRect() -> NSRect {
        guard let screen else { return .zero }
        let size = DockLayout(apps: apps, screenWidth: screen.frame.width).size
        let above: CGFloat = model.theme == .midnight ? DockLayout.starRoom : 0
        return NSRect(x: screen.frame.midX - size.width / 2 - 8, y: screen.frame.minY - 1,
                      width: size.width + 16, height: size.height + above + 9)
    }

    /// Over the bar, or the shelf that's up over it.
    private func isOver(_ location: NSPoint) -> Bool {
        barRect().contains(location) || (model.isShelving && cardRect().contains(location))
    }

    /// Near enough to stay up (see `nearArea`).
    private func isNear(_ location: NSPoint) -> Bool {
        Self.nearArea(bar: barRect(), card: model.isShelving ? cardRect() : nil).contains(location)
    }

    /// Where the pointer can go with it staying up: the bar and a way round it; with a shelf up,
    /// the bar, the card and everything between (beside the bar, under the card, too), and further
    /// round them, so a slip off an edge or past the card's top while using it doesn't put it away.
    /// (Clicks there still go through to what's under it.)
    nonisolated static func nearArea(bar: NSRect, card: NSRect?) -> NSRect {
        guard let card else { return NSRect(x: bar.minX - 18, y: bar.minY, width: bar.width + 36, height: bar.height + 18) }
        let both = bar.union(card)
        return NSRect(x: both.minX - 36, y: both.minY, width: both.width + 72, height: both.height + 32)
    }

    /// Where the shelf's card is.
    private func cardRect() -> NSRect {
        guard let screen else { return .zero }
        let bar = DockLayout(apps: apps, screenWidth: screen.frame.width).size
        return NSRect(x: screen.frame.midX - model.cardWidth / 2, y: screen.frame.minY + bar.height,
                      width: model.cardWidth, height: ShelfCard.height + DockLayout.cardGap)
    }
}

final class DockHostingView: NSHostingView<DockView> {
    // The panel's never key, so the first click has to reach the icons directly.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class DockModel: ObservableObject {
    @Published var isOpen = false
    @Published var theme = NotchTheme.standard
    /// The screen it's on's width, which it has to fit in.
    @Published var screenWidth: CGFloat = 1440
    /// Where the pointer brought it up, across from the screen's middle: the icons come up from
    /// there out, and Midnight Oyl's sky blooms out of it.
    @Published var calledFrom: CGFloat = 0
    /// The icon the pointer's on, which says its name.
    @Published var hovered: String?
    /// The shelf that's up over the bar, if one is.
    @Published var shelving: Shelf.Source?
    var isShelving: Bool { shelving != nil }
    /// An app being dragged along the bar to a new place, and how far it's been dragged.
    @Published var reordering: (id: String, offset: CGFloat)?
    /// A menu's up, or an app's being dragged: stay up.
    var isHeld = false {
        didSet { if oldValue, !isHeld { letGo = Date() } }
    }
    /// The app whose quitting's being asked about over its icon (an ⌥-click): stay up meanwhile.
    @Published var quitting: String? {
        didSet { if oldValue != nil, quitting == nil { letGo = Date() } }
    }
    /// Staying up, wherever the pointer is: held, or asking.
    var isKept: Bool { isHeld || quitting != nil }
    /// When it was last let go.
    private(set) var letGo: Date?
    var toggleShelf: (Shelf.Source) -> Void = { _ in }

    var cardWidth: CGFloat { min(560, screenWidth - 80) }
}

/// Where everything goes in the bar: the Dock's own icon size (unless that won't fit the screen),
/// the apps, a gap with a line in it, then the two shelves and the folders.
struct DockLayout: Equatable {
    static let spacing: CGFloat = 6
    static let padding: CGFloat = 14
    static let separator: CGFloat = 17
    static let above: CGFloat = 9
    /// The running lights go here, under the icons.
    static let below: CGFloat = 14
    /// How far over the bar Midnight Oyl's sky still counts as over it, for the pointer.
    static let starRoom: CGFloat = 8
    /// Room over the bar for an app's name, and either side for the shadow; in Midnight Oyl's,
    /// over it for the night to thin out into, and the motes to rise into, without being cut off
    /// (its sky reaches right across the screen anyway).
    static func headroom(midnight: Bool) -> CGFloat { midnight ? 84 : 46 }
    static func sideRoom(midnight: Bool) -> CGFloat { midnight ? 72 : 30 }
    /// Between the bar and the shelf's card.
    static let cardGap: CGFloat = 12

    let tile: CGFloat
    let size: CGSize
    /// Each icon's place, left to right, from the bar's top left.
    let frames: [CGRect]
    /// The middle of the gap before `firstOther`, where its line goes.
    let separatorX: CGFloat?

    init(tiles: Int, firstOther: Int, tile: CGFloat, screenWidth: CGFloat) {
        let count = max(tiles, 1)
        let fixed = 2 * Self.padding + (Self.separator - Self.spacing) + CGFloat(count - 1) * Self.spacing
        let fit = (screenWidth - 2 * Self.sideRoom(midnight: true) - 40 - fixed) / CGFloat(count)
        let tile = max(min(tile, fit), 24).rounded()
        var x = Self.padding, frames: [CGRect] = [], separatorX: CGFloat?
        for index in 0..<count {
            if index == firstOther, index > 0 {
                separatorX = x - Self.spacing + Self.separator / 2
                x += Self.separator - Self.spacing
            }
            frames.append(CGRect(x: x, y: Self.above, width: tile, height: tile))
            x += tile + Self.spacing
        }
        self.tile = tile
        self.frames = frames
        self.separatorX = separatorX
        size = CGSize(width: x - Self.spacing + Self.padding, height: tile + Self.above + Self.below)
    }

    @MainActor
    init(apps: DockApps, screenWidth: CGFloat) {
        self.init(tiles: DockView.shelves.count + apps.apps.count + apps.others.count, firstOther: apps.apps.count, tile: apps.tile,
                  screenWidth: screenWidth)
    }

    func window(midnight: Bool) -> CGSize {
        CGSize(width: size.width + 2 * Self.sideRoom(midnight: midnight), height: size.height + Self.headroom(midnight: midnight))
    }
}

// MARK: - The bar

struct DockView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var apps: DockApps
    let shelf: Shelf
    let saved: Shelf

    static let shelfID = "oyl.shelf"
    static let savedID = "oyl.saved"
    /// Going, it slides down no faster than the macOS Dock behind it hides, so that one's never
    /// seen. (And without fading, which would show it through.)
    static let close = Animation.easeInOut(duration: 0.45)

    /// The shelves turned on, in the bar past its line.
    @MainActor
    static var shelves: [Shelf.Source] {
        [Shelf.Source.screenshots, .saved].filter { $0 == .saved ? Feature.savedShelf.isOn : Feature.screenshotsShelf.isOn }
    }

    /// What's in the bar, left to right, as `DockLayout.frames` places it.
    @MainActor
    static func ids(_ apps: DockApps) -> [String] {
        apps.apps.map(\.id) + shelves.map { $0 == .saved ? savedID : shelfID } + apps.others.map(\.id)
    }

    var body: some View {
        let midnight = model.theme == .midnight
        let layout = DockLayout(apps: apps, screenWidth: model.screenWidth)
        ZStack(alignment: .bottom) {
            if midnight {
                MidnightDockSky(open: model.isOpen, bar: layout.size, width: model.screenWidth, from: model.calledFrom,
                                card: model.isOpen && model.isShelving ? CGSize(width: model.cardWidth, height: ShelfCard.height) : nil)
            }
            VStack(spacing: DockLayout.cardGap) {
                Spacer(minLength: 0)
                if model.isOpen, let source = model.shelving {
                    let shown = source == .saved ? saved : shelf
                    ShelfCard(shelf: shown, width: model.cardWidth, hold: { [model] in model.isHeld = $0 })
                        .id(source)
                        .transition(Self.bloom(midnight: midnight, from: anchor(of: source, in: layout)))
                        // Looking at its folder asks to the first time (see `Shelf`).
                        .onAppear { shown.watch() }
                }
                if model.isOpen {
                    // Each icon comes up in its turn, out from the pointer (see `Arriving`): in
                    // Midnight Oyl, into the sky as its bloom reaches it. They go as it wilts.
                    DockBar(model: model, apps: apps, shelf: shelf, saved: saved)
                        .transition(midnight ? .asymmetric(insertion: .identity, removal: .opacity.combined(with: .offset(y: 10)))
                                    : .move(edge: .bottom))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(model.isOpen ? NotchView.open : Self.close, value: model.isOpen)
            .animation(Self.shelfMotion(midnight: midnight, coming: model.isShelving), value: model.shelving)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.notchTheme, model.theme)
    }

    /// A shelf's card coming up out of its tile, or going back into it: in Oyl's look, growing out
    /// of it as the notch opens; in Midnight Oyl's, coming in out of a blur as the sky grows up
    /// round it (see `MidnightDockSky`), as the band's page does.
    static func bloom(midnight: Bool, from tile: UnitPoint) -> AnyTransition {
        guard midnight else { return .scale(scale: 0.06, anchor: tile).combined(with: .opacity) }
        return .modifier(active: SkyReveal(shown: 0, from: tile), identity: SkyReveal(shown: 1, from: tile))
    }

    /// Coming, on the notch's spring (Midnight Oyl's a moment later, once the sky's growing);
    /// going, quicker.
    static func shelfMotion(midnight: Bool, coming: Bool) -> Animation {
        switch (midnight, coming) {
        case (false, true): return NotchView.open
        case (false, false): return .spring(response: 0.26, dampingFraction: 1)
        case (true, true): return .easeOut(duration: 0.5).delay(0.12)
        case (true, false): return Midnight.wilt
        }
    }

    /// How fast the icons come up one after another in Oyl's look, in points a second along the bar.
    static let wave: CGFloat = 6000

    /// How long after the Dock's called up the icon at `point` (in a bar of `bar`'s size, from its
    /// top left) comes up: in Oyl's look, in a quick wave out from where the pointer brought it up
    /// (`from`, across from the screen's middle), the nearest first; in Midnight Oyl's, as the
    /// sky's bloom reaches it from there (just before its front).
    static func arrival(at point: CGPoint, bar: CGSize, from: CGFloat, screenWidth: CGFloat, midnight: Bool) -> Double {
        guard midnight else { return Double(abs(point.x - (bar.width / 2 + from)) / wave) }
        let reach = MidnightDockSky.reach(bar: bar, card: nil)
        // In the sky, measured up from the foot of the screen.
        let sky = CGPoint(x: point.x + (screenWidth - bar.width) / 2, y: bar.height - point.y)
        let fraction = MidnightBackdrop.arrival(at: sky, in: CGSize(width: screenWidth, height: reach), reach: reach,
                                                bloomFrom: screenWidth / 2 + from)
        return Midnight.dockBloomTime(0.9 * fraction)
    }

    /// Where a shelf's tile is, as a point on its card (off its foot, over the bar): the card's
    /// as wide as it likes, and both are in the middle.
    private func anchor(of source: Shelf.Source, in layout: DockLayout) -> UnitPoint {
        let index = apps.apps.count + (Self.shelves.firstIndex(of: source) ?? 0)
        guard index < layout.frames.count, model.cardWidth > 0 else { return .bottom }
        let tile = layout.frames[index]
        return UnitPoint(x: 0.5 + (tile.midX - layout.size.width / 2) / model.cardWidth,
                         y: 1 + (DockLayout.cardGap + tile.midY) / ShelfCard.height)
    }
}

/// A shelf's card in Midnight Oyl's Dock, `shown` from 0 to 1: out of a blur, rising a little
/// and spreading from toward its tile as it comes.
private struct SkyReveal: ViewModifier {
    let shown: Double
    let from: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.9 + 0.1 * shown, anchor: from)
            .opacity(shown)
            .blur(radius: 10 * (1 - shown))
            .offset(y: 8 * (1 - shown))
    }
}

private struct DockBar: View {
    @ObservedObject var model: DockModel
    @ObservedObject var apps: DockApps
    let shelf: Shelf
    let saved: Shelf
    @Environment(\.notchTheme) private var theme
    /// Come up: just after it's appeared, each icon then coming up in its turn.
    @StateObject private var up = LocalState(false)

    var body: some View {
        let layout = DockLayout(apps: apps, screenWidth: model.screenWidth)
        let midnight = theme == .midnight
        let items = shownApps(in: layout) + apps.others
        let arriving = { (x: CGFloat, y: CGFloat) in
            Arriving(up: up.value, midnight: midnight, delay: DockView.arrival(at: CGPoint(x: x, y: y), bar: layout.size, from: model.calledFrom,
                                                                         screenWidth: model.screenWidth, midnight: midnight))
        }
        ZStack(alignment: .topLeading) {
            if let x = layout.separatorX, let first = layout.frames.first {
                Rectangle()
                    .fill((midnight ? Midnight.silver : Color.white).opacity(midnight ? 0.4 : 0.2))
                    .frame(width: midnight ? 0.6 : 1, height: layout.tile * 0.7)
                    .modifier(arriving(x, first.midY))
                    .position(x: x, y: first.midY)
            }
            // The apps; then past the line the shelves, and the rest after them.
            let shelfIndex = apps.apps.count
            let shelves = DockView.shelves
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let place = index < shelfIndex ? index : index + shelves.count
                if place < layout.frames.count {
                    let frame = layout.frames[place]
                    let held = model.reordering?.id == item.id
                    // Finder stays first, and the rest of the apps make way for the one dragged.
                    let movable = item.kind == .app && item.id != DockApps.finder && apps.apps.count > 2
                    DockTile(item: item, model: model, apps: apps, tile: layout.tile,
                             drag: movable ? { dragged(item, by: $0, in: layout) } : nil)
                        .modifier(arriving(frame.midX, frame.midY))
                        .position(x: held ? draggedX(in: layout) ?? frame.midX : frame.midX, y: frame.midY)
                        .zIndex(held ? 1 : 0)
                        .animation(held ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: place)
                }
            }
            ForEach(Array(shelves.enumerated()), id: \.element) { offset, source in
                if shelfIndex + offset < layout.frames.count {
                    let frame = layout.frames[shelfIndex + offset]
                    ShelfDockTile(model: model, shelf: source == .saved ? saved : shelf, tile: layout.tile)
                        .modifier(arriving(frame.midX, frame.midY))
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            // Asked over its icon (lifted meanwhile) before an app's quit, kept on the screen.
            if let index = items.firstIndex(where: { $0.id == model.quitting && $0.isRunning }) {
                let item = items[index], place = index < shelfIndex ? index : index + shelves.count
                if place < layout.frames.count {
                    let frame = layout.frames[place]
                    let room = midnight ? (model.screenWidth - layout.size.width) / 2 - 12 : DockLayout.sideRoom(midnight: false) - 6
                    let top = frame.minY - 3 - 0.1 * layout.tile - 6
                    Slid(x: frame.midX + room) {
                        DockQuitConfirm(name: item.name, quit: {
                            apps.quit(item)
                            model.quitting = nil
                        }, cancel: { model.quitting = nil })
                        .id(item.id)
                        .transition(midnight ? .modifier(active: SkyReveal(shown: 0, from: .bottom), identity: SkyReveal(shown: 1, from: .bottom))
                                    : .opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                    }
                    .frame(width: layout.size.width + 2 * room, height: 60)
                    .position(x: layout.size.width / 2, y: top - 30)
                    .zIndex(2)
                }
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: model.quitting)
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .background {
            // (Midnight Oyl's is the sky right across under it: see `MidnightDockSky`.)
            if !midnight { DockPlate() }
        }
        .onAppear { up.value = true }
    }
}

/// An icon coming up as the Dock does, `delay` after the first (see `DockView.arrival`): in Oyl's
/// look, popping up out of the plate, a little past its size and back, quickly; in Midnight Oyl's,
/// coming on out of a blur, rising a little, as the sky's bloom reaches it.
private struct Arriving: ViewModifier {
    let up: Bool
    let midnight: Bool
    let delay: Double

    func body(content: Content) -> some View {
        if midnight {
            content
                .blur(radius: up ? 0 : 6)
                .offset(y: up ? 0 : 6)
                .opacity(up ? 1 : 0)
                .animation(.easeOut(duration: 0.3).delay(delay), value: up)
        } else {
            content
                .scaleEffect(up ? 1 : 0.35, anchor: .bottom)
                .offset(y: up ? 0 : 12)
                .animation(.spring(response: 0.22, dampingFraction: 0.58).delay(delay), value: up)
                .opacity(up ? 1 : 0)
                .animation(.easeOut(duration: 0.06).delay(delay), value: up)
        }
    }
}

extension DockBar {
    /// The apps, the one being dragged moved to where it would go.
    private func shownApps(in layout: DockLayout) -> [DockApps.Item] {
        var shown = apps.apps
        if let target = target(in: layout), let from = shown.firstIndex(where: { $0.id == model.reordering?.id }) {
            shown.insert(shown.remove(at: from), at: target)
        }
        return shown
    }

    /// Where the app being dragged would go among the apps: the place it's nearest, never before
    /// Finder.
    private func target(in layout: DockLayout) -> Int? {
        guard let x = draggedX(in: layout), apps.apps.count > 2 else { return nil }
        let distance = { (index: Int) in abs(layout.frames[index].midX - x) }
        return (1..<apps.apps.count).min { distance($0) < distance($1) }
    }

    /// The app being dragged, under the pointer: along the apps, no further.
    private func draggedX(in layout: DockLayout) -> CGFloat? {
        guard let reordering = model.reordering, let from = apps.apps.firstIndex(where: { $0.id == reordering.id }),
              apps.apps.count < layout.frames.count else { return nil }
        let x = layout.frames[from].midX + reordering.offset
        return min(max(x, layout.frames[1].midX), layout.frames[apps.apps.count - 1].midX)
    }

    /// The pointer's gone `offset` across since an app was pressed and dragged, or (nil) it's been
    /// let go: it moves to where it was dropped, and stays there.
    private func dragged(_ item: DockApps.Item, by offset: CGFloat?, in layout: DockLayout) {
        guard let offset else {
            let target = target(in: layout)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                if let target { apps.move(item.id, to: target) }
                model.reordering = nil
            }
            model.isHeld = false
            return
        }
        model.isHeld = true
        model.reordering = (item.id, offset)
    }
}

/// Oyl's open notch, turned over: black, its corners flared into the screen's bottom edge,
/// rounded on top.
private struct DockPlate: View {
    var body: some View {
        let flare = NotchState.topRadius(.expanded)
        NotchShape(topRadius: flare, bottomRadius: NotchState.bottomRadius(.expanded))
            .rotation(.degrees(180))
            .fill(.black)
            .padding(.horizontal, -flare)
            .shadow(color: .black.opacity(0.5), radius: 14, y: -4)
    }
}

/// A shelf's button, past the line (what's on it is only on the shelf): the screenshots' first,
/// then what's just been saved. Click it for its shelf over the bar; drop files on it to keep them
/// there; right-click to choose some, or go to the folder it watches.
private struct ShelfDockTile: View {
    @ObservedObject var model: DockModel
    let shelf: Shelf
    let tile: CGFloat

    var body: some View {
        let source = shelf.source
        ButtonTile(symbol: source.symbol, name: source.title, tile: tile,
                   hovered: model.hovered == (source == .saved ? DockView.savedID : DockView.shelfID),
                   lit: model.shelving == source, click: { model.toggleShelf(source) }, menu: showMenu, drop: keep)
    }

    private func keep(_ urls: [URL]) -> Bool {
        shelf.keep(urls)
        if model.shelving != shelf.source { model.toggleShelf(shelf.source) }
        return true
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = model.shelving == shelf.source
        menu.addItem(ClosureMenuItem(title: open ? "Close" : "Open") { model.toggleShelf(shelf.source) })
        menu.addItem(ClosureMenuItem(title: "Choose Files to Keep…") {
            ShelfCard.choose(for: shelf) { model.isHeld = $0 }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Show \(shelf.source.folder)") {
            NSWorkspace.shared.open(shelf.watchedFolder)
        })
        model.isHeld = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        model.isHeld = false
    }
}

/// One of Oyl's own buttons in the bar: a symbol on a pale tile in Oyl's look, on a glow in
/// Midnight's (not a frame), brighter while what it opens is up; lifting a little and saying its
/// name when the pointer's on it.
private struct ButtonTile: View {
    let symbol: String
    let name: String
    let tile: CGFloat
    let hovered: Bool
    let lit: Bool
    let click: () -> Void
    var menu: () -> Void = {}
    var drop: (([URL]) -> Bool)?
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let midnight = theme == .midnight
        ZStack {
            if midnight {
                Circle()
                    .fill(RadialGradient(colors: [Midnight.moonlight.opacity(lit ? 0.32 : 0.2), .clear],
                                         center: .center, startRadius: 0, endRadius: tile * 0.45))
            } else {
                RoundedRectangle(cornerRadius: tile * 0.24, style: .continuous)
                    .fill(.white.opacity(lit ? 0.24 : 0.13))
                    .frame(width: tile * 0.88, height: tile * 0.88)
            }
            Image(systemName: symbol)
                .notchSymbol(size: tile * 0.36, weight: .semibold)
                .foregroundStyle(midnight ? Midnight.white : .white)
        }
        .frame(width: tile, height: tile)
        .scaleEffect(hovered ? 1.1 : 1, anchor: .bottom)
        .offset(y: hovered ? -3 : 0)
        .overlay(TileHandle(click: { _ in click() }, menu: menu, drop: drop))
        .overlay(alignment: .top) {
            if hovered && !lit {
                DockLabel(text: name).fixedSize().offset(y: -32).transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: hovered)
    }
}

/// One app or folder: its icon, lifting a little and saying its name when the pointer's
/// on it, with a light under it while it's open, hopping while it opens.
private struct DockTile: View {
    let item: DockApps.Item
    @ObservedObject var model: DockModel
    @ObservedObject var apps: DockApps
    let tile: CGFloat
    /// Told how far it's dragged along the bar, if it can be (see `TileHandle`).
    var drag: ((CGFloat?) -> Void)?
    @Environment(\.notchTheme) private var theme

    var body: some View {
        // Picked up, it stays lifted, as it does while its quitting's asked about; and no names
        // come up meanwhile.
        let asking = model.quitting == item.id
        let hovered = model.reordering == nil ? model.hovered == item.id || asking : model.reordering?.id == item.id
        Hop(active: apps.launching.contains(item.id), height: tile * 0.28) {
            Group {
                if let glyph = apps.glyphs[item.id] {
                    DockGlyphTile(glyph: glyph, tile: tile, hovered: hovered, active: item.isActive)
                } else {
                    // Until its glyph's lifted, or for one with none to lift: the icon as it is.
                    Image(nsImage: apps.icon(for: item))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: tile, height: tile)
                }
            }
            .opacity(item.isHidden ? 0.6 : 1)
        }
        .scaleEffect(hovered ? 1.1 : 1, anchor: .bottom)
        .offset(y: hovered ? -3 : 0)
        .frame(width: tile, height: tile)
        .overlay(TileHandle(click: clicked, menu: showMenu,
                            drop: item.kind == .folder ? nil : { apps.drop($0, on: item) }, drag: drag))
        .overlay(alignment: .bottom) {
            if item.isRunning { light.offset(y: DockLayout.below / 2 + 2) }
        }
        .overlay(alignment: .top) {
            if hovered && model.reordering == nil && !asking {
                DockLabel(text: item.name).fixedSize().offset(y: -32).transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: hovered)
    }

    /// A dot in Oyl's look, a glint in Midnight's: brighter for the app in front.
    @ViewBuilder private var light: some View {
        if theme == .midnight {
            Sparkle(size: item.isActive ? 4 : 3)
                .fill(item.isActive ? Midnight.starlight : Midnight.silver.opacity(0.75))
                .frame(width: 9, height: 9)
                .shadow(color: Midnight.moonlight.opacity(0.6), radius: 2)
        } else {
            Circle()
                .fill(.white.opacity(item.isActive ? 0.95 : 0.55))
                .frame(width: 4, height: 4)
        }
    }

    /// Clicked: opened; with ⌘, another window of it; with ⌥, quit, once you've said so over it.
    private func clicked(_ modifiers: NSEvent.ModifierFlags) {
        let command = modifiers.contains(.command), option = modifiers.contains(.option)
        if option, !command, apps.canQuit(item) {
            model.quitting = model.quitting == item.id ? nil : item.id
            return
        }
        model.quitting = nil
        if command, !option { apps.openAnother(item) } else { apps.open(item) }
    }

    private func showMenu() {
        model.quitting = nil
        let menu = NSMenu()
        switch item.kind {
        case .app where item.isRunning:
            menu.addItem(ClosureMenuItem(title: item.isHidden ? "Show" : "Hide") { apps.hide(item) })
            menu.addItem(ClosureMenuItem(title: "Show in Finder") { apps.reveal(item) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Quit") { apps.quit(item) })
        case .app, .folder:
            menu.addItem(ClosureMenuItem(title: "Open") { apps.open(item) })
            menu.addItem(ClosureMenuItem(title: "Show in Finder") { apps.reveal(item) })
        }
        // Stay up while it's up; popUp returns once it closes.
        model.isHeld = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        model.isHeld = false
    }
}

/// An icon's name, over it: on a black pill in Oyl's look; in Midnight's, engraved capitals on a
/// patch of night with no edge to it.
private struct DockLabel: View {
    let text: String
    @Environment(\.notchTheme) private var theme

    var body: some View {
        if theme == .midnight {
            Text(text.uppercased())
                .notchFont(size: 10, role: .label)
                .tracking(Midnight.tracking(.label, size: 10))
                .foregroundStyle(Midnight.white)
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 11).fill(Midnight.ink.opacity(0.9)).blur(radius: 4))
        } else {
            Text(text)
                .notchFont(size: 12, weight: .medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(.black.opacity(0.88)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
    }
}

/// Asked over an app's icon before it's quit (an ⌥-click): Quit it?, Cancel and Quit. On a black
/// pill in Oyl's look, as its name is; in Midnight's, engraved capitals on a patch of night with
/// no edge to it, coming in out of a blur. (Its buttons only say which was clicked.)
struct DockQuitConfirm: View {
    let name: String
    let quit: () -> Void
    let cancel: () -> Void
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let midnight = theme == .midnight
        HStack(spacing: 8) {
            Group {
                if midnight {
                    Text("QUIT \(name.uppercased())?")
                        .notchFont(size: 10, role: .label)
                        .tracking(Midnight.tracking(.label, size: 10))
                        .foregroundStyle(Midnight.white)
                } else {
                    Text("Quit \(name)?")
                        .notchFont(size: 12, weight: .medium)
                        .foregroundStyle(.white)
                }
            }
            .lineLimit(1)
            .padding(.leading, midnight ? 8 : 6)
            // In Midnight's, Cancel's just its word, in silver, with nothing round it.
            pill("Cancel", foreground: midnight ? Midnight.silver : .white, background: midnight ? .clear : .white.opacity(0.14),
                 bright: false, action: cancel)
            pill("Quit", foreground: .black, background: .white, action: quit)
        }
        .padding(4)
        .background {
            if midnight {
                RoundedRectangle(cornerRadius: 18).fill(Midnight.ink.opacity(0.92)).blur(radius: 5).padding(-4)
            } else {
                Capsule().fill(.black.opacity(0.9))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            }
        }
        .fixedSize()
    }

    private func pill(_ title: String, foreground: Color, background: Color, bright: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .notchFont(size: 12, weight: .semibold)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .notchPill(background, text: foreground, bright: bright)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Its one view at the foot of it, centered on `x`, slid along as far as it has to be to keep
/// inside it.
private struct Slid: SwiftUI.Layout {
    let x: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = view.sizeThatFits(.unspecified)
        let left = max(bounds.minX, min(bounds.minX + x - size.width / 2, bounds.maxX - size.width))
        view.place(at: CGPoint(x: left, y: bounds.maxY - size.height), proposal: ProposedViewSize(size))
    }
}

/// Up and down, like an app opening in the Dock, for as long as it's `active`.
private struct Hop<Content: View>: View {
    let active: Bool
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if active {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                content().offset(y: -abs(sin(t * .pi * 1.6)) * height)
            }
        } else {
            content()
        }
    }
}

/// Over an icon: a click (told the keys held with it), a right-click, and files dropped on it.
/// (AppKit's, so the first click lands even though the panel's never key, and the menu can hold
/// the bar up.)
private struct TileHandle: NSViewRepresentable {
    let click: (NSEvent.ModifierFlags) -> Void
    let menu: () -> Void
    /// Takes files dropped on it, if it takes any.
    let drop: (([URL]) -> Bool)?
    /// Pressed and dragged, it's told how far across the pointer's gone, and nil when it's let go
    /// (and it's no click); if it can be dragged.
    var drag: ((CGFloat?) -> Void)?

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.click = click
        view.showMenu = menu
        view.drop = drop
        view.drag = drag
    }

    final class HandleView: NSView {
        var click: (NSEvent.ModifierFlags) -> Void = { _ in }
        var showMenu: () -> Void = {}
        var drop: (([URL]) -> Bool)? {
            didSet {
                guard (drop == nil) != (oldValue == nil) else { return }
                if drop == nil { unregisterDraggedTypes() } else { registerForDraggedTypes([.fileURL]) }
            }
        }
        var drag: ((CGFloat?) -> Void)?
        private var pressed = false
        /// Where it was pressed, in the window, and whether it's been dragged off from there.
        private var pressedAt: NSPoint?
        private var dragging = false

        private func files(_ info: NSDraggingInfo) -> [URL] {
            info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            drop != nil && !files(sender).isEmpty ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = files(sender)
            guard let drop, !urls.isEmpty else { return false }
            return drop(urls)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            pressed = true
            pressedAt = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let drag, let pressedAt else { return }
            let across = event.locationInWindow.x - pressedAt.x
            if !dragging, abs(across) > 4 || abs(event.locationInWindow.y - pressedAt.y) > 4 {
                dragging = true
                pressed = false
            }
            if dragging { drag(across) }
        }

        override func mouseUp(with event: NSEvent) {
            if dragging {
                drag?(nil)
            } else if pressed, bounds.contains(convert(event.locationInWindow, from: nil)) {
                click(event.modifierFlags)
            }
            pressed = false
            dragging = false
            pressedAt = nil
        }

        override func rightMouseDown(with event: NSEvent) { showMenu() }
    }
}

// MARK: - Midnight Oyl's

/// Midnight Oyl's Dock's sky: the band turned over (see `MidnightBackdrop`), right across the foot
/// of the screen. It blooms out of the screen's foot where the pointer brought the Dock up, as the
/// band does out of the notch, and wilts back into it as the Dock goes. Its edge flows in slow
/// swells and lobes and dissolves into the desktop, never pinching in over the icons; the pole's
/// grid fans out from the middle; stars, star dust drifting, filaments and the drop of light spill
/// up out of it. Without the band's charts, which it's too shallow for. Under the icons, ink comes
/// up at once and is the last to go, so the macOS Dock coming up behind (or going) never shows.
/// With a shelf up, it grows on up round the shelf's card, new stars drawing on in the new room,
/// and settles back down as it goes.
private struct MidnightDockSky: View {
    let open: Bool
    /// The bar's size, and the screen's width.
    let bar: CGSize
    let width: CGFloat
    /// Where the pointer brought it up, across from the screen's middle.
    let from: CGFloat
    /// The shelf's card up over the bar, if there is one.
    let card: CGSize?
    @StateObject private var growing = SkyGrowth()

    /// How far over the bar (or the card) its edge rests, under the middle (a little lower out
    /// toward the screen's edges).
    static let over: CGFloat = 28

    /// How far up it reaches.
    static func reach(bar: CGSize, card: CGSize?) -> CGFloat {
        bar.height + over + (card.map { DockLayout.cardGap + $0.height } ?? 0)
    }

    var body: some View {
        let target = Self.reach(bar: bar, card: card)
        let reach = growing.reach > 0 ? growing.reach : target
        // Kept quiet, measured up from the bottom: the bar, and the card over it.
        var page = CGRect(x: (width - bar.width) / 2, y: 0, width: bar.width, height: bar.height)
        if let card {
            page = page.union(CGRect(x: (width - card.width) / 2, y: bar.height + DockLayout.cardGap,
                                     width: card.width, height: card.height))
        }
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Midnight.ink.opacity(0.9))
                .frame(width: bar.width, height: bar.height)
                .blur(radius: 12)
                .scaleEffect(open ? 1 : 0.3, anchor: UnitPoint(x: min(max(0.5 + from / max(bar.width, 1), 0), 1), y: 1))
                .opacity(open ? 1 : 0)
                .animation(open ? .easeOut(duration: 0.22) : DockView.close, value: open)
            // Spilling up into the room over it; the bar's place in it, measured up from the
            // bottom, kept quiet.
            MidnightBackdrop(bloom: open ? 1 : 0, active: open, notch: CGSize(width: 0, height: 10), reach: reach,
                             grownFrom: growing.grownFrom > 0 ? growing.grownFrom : reach, growth: growing.growth,
                             overflow: (side: 0, below: DockLayout.headroom(midnight: true) - Self.over),
                             page: page, flipped: true, charts: false, bloomFrom: width / 2 + from)
                .frame(width: width, height: reach)
                .animation(open ? Midnight.dockBloom : DockView.close, value: open)
        }
        .frame(width: width, height: reach, alignment: .bottom)
        .onAppear { growing.grow(to: target, with: nil) }
        .onChange(of: target) { _, target in
            growing.grow(to: target, with: !open ? DockView.close : target > growing.reach ? Midnight.dockBloom : Midnight.fold)
        }
    }
}

/// How far up Midnight Oyl's Dock's sky reaches: from what reach it last grew (or settled), and
/// how far through it's got (1 at rest), the room between being where new stars draw on, as the
/// band's do (see `BloomOpening`).
@MainActor
private final class SkyGrowth: ObservableObject {
    @Published private(set) var reach: CGFloat = 0
    @Published private(set) var grownFrom: CGFloat = 0
    @Published private(set) var growth = 1.0

    /// To `reach` with `animation`, or (nil) outright.
    func grow(to reach: CGFloat, with animation: Animation?) {
        guard reach != self.reach else { return }
        let from = self.reach
        var outright = Transaction()
        outright.disablesAnimations = true
        guard let animation, from > 0 else {
            withTransaction(outright) {
                self.reach = reach
                grownFrom = reach
                growth = 1
            }
            return
        }
        withTransaction(outright) {
            grownFrom = from
            growth = 0
        }
        withAnimation(animation) {
            self.reach = reach
            growth = 1
        }
    }
}

/// An app redrawn in the look's own way, from its glyph (see `DockGlyphs`): in Oyl's, white on a
/// pale tile, as Oyl's own buttons are; in Midnight's, traced in silver with no tile, glints
/// twinkling along its lines. Pointed at, it brightens and its glints come quicker and bigger;
/// the app in front is a little brighter than the rest.
struct DockGlyphTile: View {
    let glyph: DockGlyph
    let tile: CGFloat
    let hovered: Bool
    let active: Bool
    @Environment(\.notchTheme) private var theme

    var body: some View {
        if theme == .midnight { traced } else { plain }
    }

    private var plain: some View {
        ZStack {
            RoundedRectangle(cornerRadius: tile * 0.24, style: .continuous)
                .fill(.white.opacity(hovered ? 0.2 : 0.13))
                .frame(width: tile * 0.88, height: tile * 0.88)
            Image(decorative: glyph.mask, scale: 1)
                .resizable()
                .interpolation(.high)
                .opacity(0.95)
        }
        .frame(width: tile, height: tile)
    }

    private var traced: some View {
        let lit = hovered ? 1.0 : active ? 0.82 : 0.64
        return ZStack {
            Image(decorative: glyph.mask, scale: 1)
                .resizable()
                .interpolation(.high)
                .colorMultiply(Midnight.silver)
                .opacity(0.06 + 0.08 * lit)
            Image(decorative: glyph.outline, scale: 1)
                .resizable()
                .interpolation(.high)
                .colorMultiply(Midnight.white)
                .opacity(lit)
                .shadow(color: Midnight.moonlight.opacity(0.3 + 0.4 * lit), radius: hovered ? 3 : 1.5)
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                Canvas { canvas, size in
                    glints(in: canvas, size: size, time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: tile, height: tile)
        .animation(.easeOut(duration: 0.25), value: hovered)
    }

    /// The glints along its lines, each twinkling in its own time.
    private func glints(in canvas: GraphicsContext, size: CGSize, time: TimeInterval) {
        let speed = hovered ? 3.4 : 1.2, scale = tile / 48
        for (index, spot) in glyph.sparkles.enumerated() {
            let twinkle = max(0, sin(time * speed + Double(index) * 2.39))
            guard twinkle > 0.05 else { continue }
            let reach = CGFloat(hovered ? 3.6 : 2.4) * CGFloat(twinkle) * (index % 3 == 0 ? 1.35 : 1) * scale
            let center = CGPoint(x: spot.x * size.width, y: spot.y * size.height)
            var star = canvas
            star.opacity = (hovered ? 1 : 0.75) * twinkle
            star.fill(Sparkle(size: reach).path(in: CGRect(x: center.x - reach, y: center.y - reach, width: 2 * reach, height: 2 * reach)),
                      with: .color(Midnight.starlight))
        }
    }
}

/// A four-pointed glint, long up and down, its sides drawn in.
struct Sparkle: Shape {
    var size: CGFloat

    func path(in rect: CGRect) -> Path {
        let point = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        let waist = size * 0.14
        path.move(to: CGPoint(x: point.x, y: point.y - size))
        path.addQuadCurve(to: CGPoint(x: point.x + size * 0.62, y: point.y), control: CGPoint(x: point.x + waist, y: point.y - waist))
        path.addQuadCurve(to: CGPoint(x: point.x, y: point.y + size), control: CGPoint(x: point.x + waist, y: point.y + waist))
        path.addQuadCurve(to: CGPoint(x: point.x - size * 0.62, y: point.y), control: CGPoint(x: point.x - waist, y: point.y + waist))
        path.addQuadCurve(to: CGPoint(x: point.x, y: point.y - size), control: CGPoint(x: point.x - waist, y: point.y - waist))
        path.closeSubpath()
        return path
    }
}
