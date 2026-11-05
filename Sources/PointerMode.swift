import AppKit
import os
import SwiftUI

/// Midnight Oyl's pointer (manus mode): the rock 'n' roll sign (the thumb and little finger out,
/// the rest curled) held a moment makes your hand the pointer, all over the screen, and held again
/// makes it a hand again. The pointer goes where your index fingertip goes, the middle of the
/// camera's picture standing for the whole screen; bringing the index tip to the thumb's presses,
/// and holding them together holds the button down, so moving drags and two quick pinches are a
/// double click; the thumb to the middle tip instead, the index held out clear of it, is the right
/// button. Two fingers held together, side by side, are two on a trackpad: moving, they scroll.
/// Three swipe, across between Spaces and up and
/// down for Mission Control, as the trackpad's set to. Flicked from the wrist, two scroll the
/// way they went, the page gliding on, and three swipe (see `Flicker`). Both hands held up pinching zoom, the way a
/// trackpad's pinch does: drawn apart, in, and together, out. Meanwhile no other gesture counts, and the
/// camera stays on, reading every frame, even once the band's closed; it's put down by the rock
/// sign, by resting the pointer a moment on the dial in the top bar, by no hand for ten seconds, or
/// by leaving Midnight Oyl. Your hand is drawn round the pointer as a small constellation
/// (`PointerFigure`), the dial left of the band's page (`PointerDial`).
///
/// The pieces: `RockSign` watches for the sign; `PointerHand` works out where the pointer goes,
/// when it's pressed and what two or three fingers do, from what the camera saw (`HandPose`), and
/// tells `PointerEvents`, which `SystemPointer` makes real; `PointerMode` holds them together, with
/// the overlay that draws the hand and the dial.
@MainActor
final class PointerMode {
    private(set) var isOn = false
    /// Told when it's put down by itself (no hand for a while, or the pointer rested on the dial),
    /// not when it's asked to end.
    var ended: () -> Void = {}

    /// With no hand this long, the pointer's put down.
    static let forgetAfter: TimeInterval = 10
    /// Asked for once each time Oyl's opened, the first time the pointer's picked up.
    private static var askedForAccess = false

    /// Each hand its own pointer, the two sharing the one cursor; and both pinching, zooming.
    private let hands = [PointerHand(), PointerHand()]
    private let system = SystemPointer()
    private lazy var cursor = SharedCursor(system)
    private var slots = HandSlots()
    private var zoom = PinchZoom()
    private let hider = CursorHider()
    private var overlay: PointerOverlay?
    private var ticker: Timer?
    /// The screen the hands point over, in the global coordinates events take: from the top left
    /// of the main screen, down.
    private var screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private var lastSeen: TimeInterval = 0
    /// When the trackpad (or a mouse) last moved the cursor, rather than a hand.
    private var trackpadMoved = -TimeInterval.infinity

    /// Picks the pointer up, with `pose` (the hand that made the sign) to start it from.
    func start(with pose: HandPose?, at time: TimeInterval) {
        guard !isOn else { return }
        isOn = true
        lastSeen = time
        for hand in hands {
            hand.reset()
            hand.tuning.doubleClickTime = max(NSEvent.doubleClickInterval, 0.5)
        }
        cursor.reset()
        zoom.reset()
        slots.reset()
        trackpadMoved = -.infinity
        // Posting a mouse's events takes the Accessibility permission. Without it, the pointer's
        // moved another way, and nothing's pressed.
        system.canPost = CGPreflightPostEventAccess()
        if !system.canPost, !Self.askedForAccess {
            Self.askedForAccess = true
            system.canPost = CGRequestPostEventAccess()
        }
        system.trackpad = TrackpadSettings.read()
        let overlay = self.overlay ?? PointerOverlay()
        self.overlay = overlay
        findScreen()
        overlay.begin(needsAccess: !system.canPost)
        take(pose.map { [$0] } ?? [], at: time)
        PointerFeed.shared.shown = system.canPost ? .on : .needsAccess
        // The hands' figures stand in for the cursor.
        hider.hide()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Puts the pointer down, letting go of anything it's holding.
    func end() {
        guard isOn else { return }
        isOn = false
        ticker?.invalidate()
        ticker = nil
        let now = ProcessInfo.processInfo.systemUptime
        for (index, hand) in hands.enumerated() { hand.letGo(at: now, to: cursor.events(for: index)) }
        hider.show()
        PointerFeed.shared.shown = .off
        PointerFeed.shared.shape = .pointing
        // The window goes once its flourish is over, unless it's been picked up again meanwhile.
        overlay?.finish { [weak self, weak overlay] in
            guard let self, !self.isOn, self.overlay === overlay else { return }
            self.overlay = nil
        }
    }

    /// One camera frame: the hands in it.
    func take(_ found: [HandPose], at time: TimeInterval) {
        guard isOn else { return }
        // Where the cursor is: moved since the hands last put it somewhere, the trackpad's moved it.
        // Then it shows, and the hands leave it be a moment.
        let mouse = NSEvent.mouseLocation, top = NSScreen.screens.first?.frame.maxY ?? 0
        let pointer = CGPoint(x: mouse.x, y: top - mouse.y)
        if let placed = cursor.placed, time - placed.time > 0.02, hypot(pointer.x - placed.point.x, pointer.y - placed.point.y) > 8 {
            trackpadMoved = time
            cursor.found(at: pointer, at: time)
            hider.show()
        }
        cursor.isHeldOff = time - trackpadMoved < 0.8

        let poses = slots.assign(found, at: time)
        if poses.contains(where: { $0 != nil }) { lastSeen = time }
        let zoomed = zoom.take(poses[0], poses[1], pressed: hands.contains(where: \.pressed), tuning: hands[0].tuning)
        if zoomed != 0 { system.zoom(by: zoomed) }
        for (index, hand) in hands.enumerated() {
            hand.suspended = zoom.isOn
            // Resting on the dial puts the hands down; it doesn't click there.
            hand.restsElsewhere = hand.location.map { overlay?.isOnDial($0) ?? false } ?? false
            hand.take(poses[index], other: poses[1 - index], at: time, on: screen, to: cursor.events(for: index))
            overlay?.update(index, poses[index], at: hand.location, pressed: hand.pressed, shape: zoom.isOn ? .zooming : hand.shape,
                            swiped: hand.swiped, zoomed: zoomed == 0 ? nil : zoomed, resting: hand.resting != nil,
                            restClicked: hand.restClicked, time: time)
        }
        PointerFeed.shared.shape = zoom.isOn ? .zooming : hands[cursor.owner ?? 0].shape
        if !cursor.isHeldOff, let placed = cursor.placed, placed.time > trackpadMoved { hider.hide() }
        // The pointer (worked by a hand, or the trackpad) resting on the dial a moment puts it down.
        if overlay?.rest(pointer, at: time) == true {
            end()
            ended()
        }
    }

    /// Once a second: puts the pointer down if no hand's been seen in a while (or the camera's
    /// stopped sending frames), and checks whether Accessibility's been allowed since, and where
    /// the screen is.
    private func tick() {
        guard isOn else { return }
        if ProcessInfo.processInfo.systemUptime - lastSeen > Self.forgetAfter {
            end()
            ended()
            return
        }
        let could = system.canPost
        system.canPost = CGPreflightPostEventAccess()
        if system.canPost != could {
            overlay?.needsAccess(!system.canPost)
            PointerFeed.shared.shown = system.canPost ? .on : .needsAccess
        }
        findScreen()
    }

    /// The screen with the notch, which the camera's at the top of; failing that, the one the
    /// pointer's on.
    private func findScreen() {
        let mouse = NSEvent.mouseLocation
        guard let target = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let primary = NSScreen.screens.first?.frame.maxY ?? target.frame.maxY
        screen = CGRect(x: target.frame.minX, y: primary - target.frame.maxY, width: target.frame.width, height: target.frame.height)
        // The dial's in the top bar, just left of the band's page (as wide as its tabs make it;
        // Midnight Oyl has no camera tab), clear of them.
        let notch = NotchMetrics(screen: target)
        let page = max(Layout.expandedWidth, notch.size.width + 2 * Layout.tabsWing(tabs: 5))
        let dial = CGPoint(x: notch.centerX - page / 2 - 30, y: screen.minY + notch.size.height / 2)
        overlay?.cover(target.frame, global: screen, scale: target.backingScaleFactor, dial: dial)
    }
}

/// Which hand's which, from frame to frame: each found the nearest where one was last seen (the
/// two placed as near as they can be, between them), a new one in the free place.
struct HandSlots {
    private var last: [(anchor: CGPoint, time: TimeInterval)?] = [nil, nil]

    mutating func reset() { last = [nil, nil] }

    mutating func assign(_ found: [HandPose], at time: TimeInterval) -> [HandPose?] {
        func gap(_ hand: HandPose, _ slot: Int) -> CGFloat {
            guard let seen = last[slot], time - seen.time < 1 else { return 2 }
            return hypot((hand.anchor.x - seen.anchor.x) * hand.aspect, hand.anchor.y - seen.anchor.y)
        }
        var hands: [HandPose?] = [nil, nil]
        if found.count == 1 {
            hands[gap(found[0], 0) <= gap(found[0], 1) ? 0 : 1] = found[0]
        } else if found.count > 1 {
            let (one, other) = (found[0], found[1])
            hands = gap(one, 0) + gap(other, 1) <= gap(one, 1) + gap(other, 0) ? [one, other] : [other, one]
        }
        for (slot, hand) in hands.enumerated() {
            if let hand { last[slot] = (hand.anchor, time) }
        }
        return hands
    }
}

/// Both hands held up pinching zoom, the way a trackpad's pinch does: drawn apart, in a step each
/// time they're `zoomStep` times as far apart as they took hold, and together, out; till either
/// lets go. (Not while a hand's pressed, dragging something.)
struct PinchZoom {
    private(set) var isOn = false
    /// Frames running both have been pinching; how far apart they took hold (over their palms'
    /// size), how far since (smoothed), the steps zoomed, and frames running either's let go.
    private var both = 0
    private var from: CGFloat = 1
    private var spread: CGFloat = 1
    private var steps = 0
    private var letGo = 0

    mutating func reset() { self = PinchZoom() }

    /// One frame's two hands (nil where one isn't), the steps zoomed this frame (in positive),
    /// 0 for none.
    mutating func take(_ one: HandPose?, _ other: HandPose?, pressed: Bool, tuning: PointerTuning) -> Int {
        guard isOn else {
            guard let one, let other, !pressed, min(one.size, other.size) >= max(one.size, other.size) * tuning.otherHand,
                  Self.pinching(one, tuning), Self.pinching(other, tuning) else {
                both = 0
                return 0
            }
            both += 1
            guard both >= tuning.zoomFrames else { return 0 }
            isOn = true
            from = Self.spread(one, other)
            spread = from
            steps = 0
            letGo = 0
            return 0
        }
        guard let one, let other, Self.holding(one, tuning), Self.holding(other, tuning) else {
            letGo += 1
            if letGo >= tuning.zoomLetGo {
                isOn = false
                both = 0
            }
            return 0
        }
        letGo = 0
        spread += (Self.spread(one, other) - spread) * 0.5
        // Past the middle of the next step, with some to spare, so it doesn't chatter at an edge.
        let level = log(spread / max(from, 0.01)) / log(tuning.zoomStep)
        var step = 0
        while level > CGFloat(steps + step) + 0.6 { step += 1 }
        while level < CGFloat(steps + step) - 0.6 { step -= 1 }
        steps += step
        return step
    }

    /// The tips together, not in a fist's shape.
    private static func pinching(_ hand: HandPose, _ tuning: PointerTuning) -> Bool {
        (hand.pinch.map { $0 < tuning.press } ?? false) && (hand.reach.map { $0 > tuning.reach } ?? false) && hand.gesture != .fist
    }

    private static func holding(_ hand: HandPose, _ tuning: PointerTuning) -> Bool {
        hand.pinch.map { $0 < tuning.release } ?? false
    }

    /// How far apart two hands are, over their palms' size (so it's the same near or far).
    private static func spread(_ one: HandPose, _ other: HandPose) -> CGFloat {
        hypot((one.anchor.x - other.anchor.x) * one.aspect, one.anchor.y - other.anchor.y) / max((one.size + other.size) / 2, 0.01)
    }
}

/// The one cursor the two hands share. It goes with whichever is doing something: a hand pressed
/// (dragging) or scrolling keeps it; otherwise the other takes it by moving while this one's been
/// still a moment, or by pressing, scrolling or resting to click, the cursor going to it first so
/// that happens where it is. While one holds the button down, or scrolls, the other can't.
@MainActor
final class SharedCursor {
    /// Where the events go: the system's own (`SystemPointer`).
    private let system: PointerEvents
    /// The hand that has the cursor.
    private(set) var owner: Int?
    /// Where the cursor was last put (by a hand, or found moved by the trackpad), and when.
    private(set) var placed: (point: CGPoint, time: TimeInterval)?
    /// The trackpad's just moved the cursor: the hands leave it be (they can still press).
    var isHeldOff = false
    /// Each hand's pointer, when it last moved, whether it's holding the button or scrolling, and
    /// whether its press or scroll was kept from the system (the other had it).
    private var at: [CGPoint?] = [nil, nil]
    private var moved: [TimeInterval] = [-.infinity, -.infinity]
    private var busy = [false, false]
    private var pressKept = [false, false]
    private var scrollKept = [false, false]
    private lazy var hands = [Hand(0, self), Hand(1, self)]

    /// How long the hand with the cursor has to be still for the other to take it by moving.
    static let handOff: TimeInterval = 0.3

    init(_ system: PointerEvents) { self.system = system }

    func events(for hand: Int) -> PointerEvents { hands[hand] }

    func reset() {
        owner = nil
        placed = nil
        isHeldOff = false
        at = [nil, nil]
        moved = [-.infinity, -.infinity]
        busy = [false, false]
        pressKept = [false, false]
        scrollKept = [false, false]
    }

    /// The trackpad's moved the cursor there.
    func found(at point: CGPoint, at time: TimeInterval) { placed = (point, time) }

    /// One hand's events, passed on (or not) to the system's.
    @MainActor
    final class Hand: PointerEvents {
        private let index: Int
        private unowned let cursor: SharedCursor

        init(_ index: Int, _ cursor: SharedCursor) {
            self.index = index
            self.cursor = cursor
        }

        func move(to point: CGPoint, holding button: CGMouseButton?, clicks: Int) {
            cursor.move(index, to: point, holding: button, clicks: clicks)
        }

        func press(_ button: CGMouseButton, at point: CGPoint, clicks: Int) { cursor.press(index, button, at: point, clicks: clicks) }
        func release(_ button: CGMouseButton, at point: CGPoint, clicks: Int) { cursor.release(index, button, at: point, clicks: clicks) }
        func scroll(by delta: CGVector, phase: ScrollPhase) { cursor.scroll(index, by: delta, phase: phase) }
        func swipe(_ direction: SwipeDirection) { cursor.system.swipe(direction) }
        func zoom(by steps: Int) { cursor.system.zoom(by: steps) }
    }

    private func move(_ hand: Int, to point: CGPoint, holding button: CGMouseButton?, clicks: Int) {
        at[hand] = point
        let now = ProcessInfo.processInfo.systemUptime
        moved[hand] = now
        if owner != hand {
            // The other has it: this one takes it once that one's been still a moment.
            if let owner, busy[owner] || now - moved[owner] < Self.handOff { return }
            owner = hand
        }
        guard !isHeldOff || button != nil else { return }
        placed = (point, now)
        system.move(to: point, holding: pressKept[hand] ? nil : button, clicks: clicks)
    }

    /// The hand's about to do something where it is: the cursor goes to it there, unless the
    /// other's holding the button down or scrolling.
    private func take(_ hand: Int) -> Bool {
        if owner == hand { return true }
        if let owner, busy[owner] { return false }
        owner = hand
        if let point = at[hand] {
            placed = (point, ProcessInfo.processInfo.systemUptime)
            system.move(to: point, holding: nil, clicks: 0)
        }
        return true
    }

    private func press(_ hand: Int, _ button: CGMouseButton, at point: CGPoint, clicks: Int) {
        at[hand] = point
        guard take(hand) else {
            pressKept[hand] = true
            return
        }
        busy[hand] = true
        placed = (point, ProcessInfo.processInfo.systemUptime)
        system.press(button, at: point, clicks: clicks)
    }

    private func release(_ hand: Int, _ button: CGMouseButton, at point: CGPoint, clicks: Int) {
        if pressKept[hand] {
            pressKept[hand] = false
            return
        }
        busy[hand] = false
        system.release(button, at: point, clicks: clicks)
    }

    private func scroll(_ hand: Int, by delta: CGVector, phase: ScrollPhase) {
        switch phase {
        case .touched:
            guard take(hand) else {
                scrollKept[hand] = true
                return
            }
            busy[hand] = true
        case .ended, .cancelled:
            if scrollKept[hand] {
                scrollKept[hand] = false
                return
            }
            busy[hand] = false
        case .began, .changed:
            if scrollKept[hand] { return }
        }
        system.scroll(by: delta, phase: phase)
    }
}

/// Hides the system's cursor while the hands are the pointer, their figures standing in for it. An
/// app in the background can only hide it once it's told the window server it sets the cursor
/// from the background too, a private setting (looked up as Oyl runs, so if it's ever gone, the
/// cursor's just left showing).
@MainActor
final class CursorHider {
    private var hidden = false

    private static let canHide: Bool = {
        typealias Connection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let all = dlopen(nil, RTLD_LAZY), let connection = dlsym(all, "_CGSDefaultConnection"),
              let set = dlsym(all, "CGSSetConnectionProperty") else { return false }
        let id = unsafeBitCast(connection, to: Connection.self)()
        return unsafeBitCast(set, to: SetProperty.self)(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }()

    func hide() {
        guard !hidden, Self.canHide else { return }
        hidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
    }

    func show() {
        guard hidden else { return }
        hidden = false
        CGDisplayShowCursor(CGMainDisplayID())
    }
}

// MARK: - The hand, as the camera sees it

/// The hand a pointer follows, read off one camera frame: the nearer hand, whatever shape it's
/// making (see `HandShape.pose`).
struct HandPose: Sendable {
    /// When the frame was read (`ProcessInfo.systemUptime`), and the picture's width over its height.
    var time: TimeInterval
    var aspect: CGFloat = 4.0 / 3
    /// The palm, 0...1 across and down the picture as it's shown (mirrored): between the index and
    /// middle knuckles, which hardly move as the fingers do. Scrolling and swiping go by it.
    var anchor: CGPoint
    /// The index fingertip, where the pointer is; nil if the model's unsure of it.
    var tip: CGPoint?
    /// How big the hand looks: wrist to knuckles, over the picture's height.
    var size: CGFloat
    /// The shape it reads as, if any.
    var gesture: HandGesture?
    /// How far apart the thumb and index tips are, over the palm's length; nil if the model's
    /// unsure of either. And the thumb and middle tips, for the right button, and how much nearer
    /// the thumb is the middle tip than that finger's last joint (on the tip, well ahead).
    var pinch: CGFloat?
    var middlePinch: CGFloat?
    var middleAhead: CGFloat?
    /// How far the index tip is from the wrist, over how far its knuckle is: past 1 it's reaching
    /// forward (to pinch), under it curled back into the palm. And the middle tip's.
    var reach: CGFloat?
    var middleReach: CGFloat?
    /// How many of the four fingers are uncurled, their tips back out past their middle joints.
    var uncurled = 0
    /// Two or three fingers (from the index) held out side by side, the rest curled, as they'd
    /// lie on a trackpad; 0 for any other shape.
    var together = 0
    /// Between the index and middle fingertips, where two or three held together end, as `anchor`
    /// is; nil if the model's unsure of either. A flick goes by them: flicked from the wrist, they
    /// sweep twice as far as the knuckles.
    var tips: CGPoint?
    /// In a fist's shape, if not surely one: its thumb could be on the index tip (see
    /// `HandShape.fistShape`).
    var fistLike = false
    /// Every joint the model found, for drawing.
    var joints: [HandTrack.Joint] = []

    /// The button the thumb's on, as `tuning` has it: the left on the index tip, the index reaching
    /// out to it (not curled right into the palm: seen from above, as the camera mostly sees a
    /// hand, a pinching index looks curled a little); the right on the middle tip, the middle
    /// reaching out to it, the thumb on the tip itself and the index held clear; nil for neither.
    func button(_ tuning: PointerTuning) -> CGMouseButton? {
        if let pinch, pinch < tuning.press, let reach, reach > tuning.reach { return .left }
        if let middlePinch, middlePinch < tuning.press, let middleAhead, middleAhead > tuning.middleAhead,
           let middleReach, middleReach > tuning.middleReach, let pinch, pinch > tuning.indexClear { return .right }
        return nil
    }
}

/// The rock 'n' roll sign (the thumb and little finger out) held a moment, which picks the pointer
/// up or puts it down. A frame or two the model misreads or loses doesn't break it; once it's
/// counted, the hand has to make another shape (or go) for a moment before it counts again.
struct RockSign {
    /// How long it's held to count; the longest lapse it can take, misread or lost; and how long
    /// the hand has to be out of it, once it's counted, to count again.
    static let hold: TimeInterval = 0.4
    static let lapse: TimeInterval = 0.15
    static let rest: TimeInterval = 0.3

    /// Since when it's been held, when it was last seen, and whether it's counted.
    private var since: TimeInterval?
    private var last = -TimeInterval.infinity
    private var counted = false

    mutating func reset() {
        since = nil
        last = -.infinity
        counted = false
    }

    /// One frame's hand (nil for none), read at `time`: true as it counts.
    mutating func take(_ pose: HandPose?, at time: TimeInterval) -> Bool {
        guard pose?.gesture == .rock else {
            if time - last > (counted ? Self.rest : Self.lapse) {
                since = nil
                counted = false
            }
            return false
        }
        if since == nil || time - last > Self.lapse { since = time }
        last = time
        guard !counted, let since, time - since >= Self.hold else { return false }
        counted = true
        return true
    }
}

// MARK: - Working the pointer

/// How the hand works the pointer.
struct PointerTuning {
    /// The part of the picture (0...1 across and down, as shown) that stands for the whole
    /// screen: its middle, `span` of its width, so the hand needn't reach the picture's edges. Its
    /// height's worked out from the screen's shape, so the pointer moves as far for a move up as
    /// for one across.
    var center = CGPoint(x: 0.5, y: 0.5)
    var span: CGFloat = 0.56
    /// The One Euro filter's settings, in screen points (see `OneEuroFilter`).
    var minCutoff = 0.35
    var beta = 0.004
    var derivativeCutoff = 1.0
    /// How far the smoothed hand has to move before the pointer follows, in points.
    var deadZone: CGFloat = 2.2
    /// The thumb and index tips nearer than `press` (over the palm's length), for `pressFrames`
    /// frames running, press; farther than `release` let go. The gap between keeps it from
    /// chattering.
    var press: CGFloat = 0.14
    var release: CGFloat = 0.25
    var pressFrames = 3
    /// The thumb on the middle tip instead is the right button: as near, with the index tip farther
    /// than `indexClear` from the thumb, the middle tip reaching out (`middleReach`, as `reach`),
    /// and the thumb on the tip itself, `middleAhead` nearer it than the finger's last joint (a
    /// pointing hand's thumb lies over the middle finger curled under it). It's held `rightFrames`
    /// frames longer than a pinch, being harder to make by accident.
    var indexClear: CGFloat = 0.4
    var middleReach: CGFloat = 0.7
    var middleAhead: CGFloat = 0.06
    var rightFrames = 2
    /// The index tip at least this far from the wrist, over its knuckle's distance, to press; a
    /// little short of it lets go. And no press this soon after a fist.
    var reach: CGFloat = 0.6
    var afterFist: TimeInterval = 0.3
    /// The fingertip moves as it goes to the thumb, so once the tips are closing in (by `closing`
    /// of the palm's length within `closingTime`, nearer than `near`), the pointer goes by the
    /// palm, the fingertip kept where it was from it; till they part, or come no nearer for `aimFor`.
    var closing: CGFloat = 0.08
    var closingTime: TimeInterval = 0.25
    var near: CGFloat = 0.6
    var aimFor: TimeInterval = 0.4
    /// While pressed, the pointer holds still until the hand's moved this far, so a click doesn't
    /// drag and lands where it was aimed. Let go, it goes on by the palm as the fingers part, till
    /// they're `parted` apart and done parting, or `settle` has passed; then it eases back to the
    /// fingertip over `ease`.
    var hold: CGFloat = 9
    var settle: TimeInterval = 0.5
    var parted: CGFloat = 0.45
    var ease: TimeInterval = 0.3
    /// How much of the hand's moving goes to taking up a difference between the pointer and the
    /// hand (scrolling leaves one, the pointer staying put), till it's gone.
    var catchUp: CGFloat = 0.5
    /// Two presses this close in time (from letting go of the first) and place are a double click.
    var doubleClickTime: TimeInterval = 0.5
    var doubleClickRadius: CGFloat = 16
    /// No hand this long, and a held press lets go.
    var lostHand: TimeInterval = 0.35
    /// Frames running two or three fingers have to be together to scroll or swipe, and in any
    /// other shape to stop.
    var shapeFrames = 2
    var unshapeFrames = 4
    /// Points scrolled for each the palm moves, how far it goes before it counts, and how fast (in
    /// points a second) it has to be going as the fingers part to glide on.
    var scrollGain: CGFloat = 1
    var scrollStart: CGFloat = 3
    var flingSpeed: CGFloat = 120
    /// How far three fingers go to swipe (of the screen's width across, of its height up or
    /// down), unless they're flicked.
    var swipe: CGFloat = 0.07
    /// A flick, two fingers or three, as a flick of the wrist sweeps their tips: a dart going
    /// `flickSpeed` screens (of its height) a second at its fastest and `flickReach` of one far,
    /// over within `flickTime` (from moving faster than `flickStill` screens a second to slowing
    /// back down). Then the hand coming back doesn't count, till the fingertip's held still
    /// (within `flickRestRadius`) for `flickRest`; another flick the same way does.
    var flickSpeed: CGFloat = 0.9
    var flickReach: CGFloat = 0.06
    var flickTime: TimeInterval = 0.35
    var flickStill: CGFloat = 0.25
    /// Turned at the wrist, away from how the fingers pointed as they came together, the
    /// fingertips sweeping round the palm (at least `pivotShare` of how far they went), a flick
    /// needn't be as quick as one of the whole hand: `pivotSpeed` screens a
    /// second at its fastest, `pivotReach` of one far, over within `pivotTime`. (A wrist turns a
    /// little slower than a hand darts; and a hand moved bodily, slowly, is a scroll.) And it has to
    /// have gone fairly straight there, at least `pivotStraight` of the way the fingertips wandered:
    /// the camera's jitter wanders, and a quick enough shiver could pass.
    var pivotShare: CGFloat = 0.35
    var pivotSpeed: CGFloat = 0.4
    var pivotReach: CGFloat = 0.06
    var pivotTime: TimeInterval = 0.55
    var pivotStraight: CGFloat = 0.5
    var flickRest: TimeInterval = 0.15
    var flickRestRadius: CGFloat = 8
    /// Resting the pointer clicks: held within `restRadius` for `restSettle`, then `restTime` more
    /// (a ring drawing on round the sight meanwhile). Then it has to move `rearm` off before
    /// resting clicks again.
    var restRadius: CGFloat = 10
    var restSettle: TimeInterval = 0.35
    var restTime: TimeInterval = 0.9
    var rearm: CGFloat = 28
    /// The other hand's held up (perhaps to zoom), not down at the keyboard, when it looks at least
    /// `otherHand` as big as this one. Then a press waits `zoomWait` frames longer, in case the
    /// other's pinching too, and doesn't come at all while its tips are nearer than `zoomBlock`.
    /// Both pinching for `zoomFrames` running zoom (see `PinchZoom`); either let go for `zoomLetGo`
    /// running stops it. Each step is the hands `zoomStep` times as far apart (or a step out, as near).
    var otherHand: CGFloat = 0.6
    var zoomWait = 4
    var zoomBlock: CGFloat = 0.35
    var zoomFrames = 2
    var zoomLetGo = 3
    var zoomStep: CGFloat = 1.15

    /// Where `spot`, in a picture `aspect` wide for its height, points to on `screen`; unless it's
    /// `kept` on it, perhaps off its edge (for how far a hand moves, not where it points).
    func place(_ spot: CGPoint, aspect: CGFloat, on screen: CGRect, kept: Bool = true) -> CGPoint {
        let height = min(span * aspect * screen.height / max(screen.width, 1), 0.95)
        var across = (spot.x - center.x) / span + 0.5, down = (spot.y - center.y) / height + 0.5
        if kept {
            across = min(max(across, 0), 1)
            down = min(max(down, 0), 1)
        }
        return CGPoint(x: screen.minX + across * (screen.width - 1), y: screen.minY + down * (screen.height - 1))
    }
}

/// The One Euro filter (Casiez, Roussel and Vogel, 2012), for a point: smoothed hard while it's
/// still, so it doesn't shiver, and less the faster it moves, so it doesn't lag. `minCutoff` is how
/// much it's smoothed at rest (in hertz; lower is steadier), `beta` how quickly that eases off with
/// speed (per point a second).
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var derivativeCutoff: Double
    private var last: (time: TimeInterval, value: CGPoint, speed: CGVector)?

    init(minCutoff: Double, beta: Double, derivativeCutoff: Double = 1) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func reset() { last = nil }

    mutating func callAsFunction(_ value: CGPoint, at time: TimeInterval) -> CGPoint {
        guard let last else {
            self.last = (time, value, .zero)
            return value
        }
        let step = time - last.time
        guard step > 0 else { return last.value }
        func smoothing(_ cutoff: Double) -> CGFloat { CGFloat(1 / (1 + 1 / (2 * .pi * cutoff * step))) }
        let raw = CGVector(dx: (value.x - last.value.x) / step, dy: (value.y - last.value.y) / step)
        let eased = smoothing(derivativeCutoff)
        let speed = CGVector(dx: last.speed.dx + (raw.dx - last.speed.dx) * eased, dy: last.speed.dy + (raw.dy - last.speed.dy) * eased)
        let follow = smoothing(minCutoff + beta * Double(hypot(speed.dx, speed.dy)))
        let smooth = CGPoint(x: last.value.x + (value.x - last.value.x) * follow, y: last.value.y + (value.y - last.value.y) * follow)
        self.last = (time, smooth, speed)
        return smooth
    }
}

/// What the hand's doing with the pointer: pointing (and pressing); or, with two fingers held
/// together, scrolling, and three, swiping, as they would on a trackpad; or, both hands pinching,
/// zooming.
enum PointerShape: Sendable {
    case pointing, scrolling, swiping, zooming
}

/// Which way three fingers swiped.
enum SwipeDirection: Sendable {
    case left, right, up, down
}

/// Two fingers scrolling, as a trackpad tells it: down on it, moving, and lifted (going this fast,
/// to glide on), or lifted without having moved.
enum ScrollPhase {
    case touched, began, changed
    case ended(velocity: CGVector)
    case cancelled
}

/// Watching for a flick: a quick dart of two fingers or three, mostly from the wrist, that's over
/// almost as soon as it's begun, as a finger flicks a trackpad (or a phone) and lifts. Goes by the
/// fingertips as they're seen, every frame: smoothing them lags too far behind a dart, and the
/// knuckles hardly move as the wrist turns.
struct Flicker {
    var last: CGPoint
    var time: TimeInterval
    var velocity = CGVector.zero
    /// How far out to the side of the palm the fingertips were last (the wrist turned).
    var lastTurn: CGFloat = 0
    /// The move under way: where and when it started, how fast it's gone at its fastest, the
    /// farthest it's got, how far the wrist was turned at its start and there, and how far the
    /// fingertips have wandered on the way.
    private var move: (from: CGPoint, start: TimeInterval, peak: CGVector, far: CGPoint, turnedFrom: CGFloat, turned: CGFloat,
                       wandered: CGFloat)?

    /// How quickly the speed follows the fingertips: over about a frame at 30 a second, by the
    /// clock, so a camera slowed to 15 (in dim light, say) reads a flick as fast as it is.
    static let easing: TimeInterval = 0.036
    /// Flicks so far.
    private(set) var flicks = 0

    init(last: CGPoint, time: TimeInterval, lastTurn: CGFloat = 0) {
        self.last = last
        self.time = time
        self.lastTurn = lastTurn
    }

    var isMoving: Bool { move != nil }
    /// When the move under way started.
    var started: TimeInterval? { move?.start }
    /// How fast the move under way's gone at its fastest, and how far it's gone.
    var fastest: CGVector? { move?.peak }
    var going: CGVector? { move.map { CGVector(dx: $0.far.x - $0.from.x, dy: $0.far.y - $0.from.y) } }

    /// The move under way isn't one (the thumb's on its way to the tips, say, or just leaving
    /// them, which sweeps them aside as a turned wrist would).
    mutating func forget() {
        move = nil
    }

    /// The move under way may yet turn out a flick (it's not been going too long).
    func mayFlick(at time: TimeInterval, tuning: PointerTuning) -> Bool {
        guard let move else { return false }
        let gone = hypot(move.far.x - move.from.x, move.far.y - move.from.y)
        return time - move.start <= (Self.pivoted(move.turned - move.turnedFrom, gone, tuning) ? tuning.pivotTime : tuning.flickTime)
    }

    /// The fingertips went `gone` far, `turned` of it round the palm: mostly the wrist turning.
    private static func pivoted(_ turned: CGFloat, _ gone: CGFloat, _ tuning: PointerTuning) -> Bool {
        gone > 0 && abs(turned) >= tuning.pivotShare * gone
    }

    /// The fingertips at `time` (`turn` out to the side of the palm), on a screen `height` tall: a
    /// flick that's just ended, if one has: how far it went, and how fast at its fastest,
    /// straightened to across or up and down if it mostly went one way (a wrist's flick sweeps an
    /// arc).
    mutating func take(_ tips: CGPoint, turn: CGFloat = 0, at time: TimeInterval, tuning: PointerTuning, height: CGFloat)
        -> (gone: CGVector, velocity: CGVector)? {
        let step = time - self.time, previous = last, turnedBefore = lastTurn
        last = tips
        lastTurn = turn
        self.time = time
        guard step > 0 else { return nil }
        let follow = CGFloat(1 - exp(-step / Self.easing))
        velocity = CGVector(dx: velocity.dx + ((tips.x - previous.x) / step - velocity.dx) * follow,
                            dy: velocity.dy + ((tips.y - previous.y) / step - velocity.dy) * follow)
        let speed = hypot(velocity.dx, velocity.dy), moving = tuning.flickStill * height
        guard var move else {
            if speed > moving {
                self.move = (previous, time - step, velocity, tips, turnedBefore, turn, hypot(tips.x - previous.x, tips.y - previous.y))
            }
            return nil
        }
        move.wandered += hypot(tips.x - previous.x, tips.y - previous.y)
        if speed > hypot(move.peak.dx, move.peak.dy) { move.peak = velocity }
        if hypot(tips.x - move.from.x, tips.y - move.from.y) > hypot(move.far.x - move.from.x, move.far.y - move.from.y) {
            move.far = tips
            move.turned = turn
        }
        self.move = move
        // Slowed right down again, or turned back (as a wrist's flick does, at once): over.
        let peak = hypot(move.peak.dx, move.peak.dy)
        guard speed < max(moving, 0.35 * peak) || velocity.dx * move.peak.dx + velocity.dy * move.peak.dy < 0 else { return nil }
        self.move = nil
        let gone = CGVector(dx: move.far.x - move.from.x, dy: move.far.y - move.from.y)
        // (Turned away from how the fingers pointed as they came together: coming back, as a wrist
        // does after a flick, takes a dart.)
        let pivoted = Self.pivoted(move.turned - move.turnedFrom, hypot(gone.dx, gone.dy), tuning)
            && hypot(gone.dx, gone.dy) >= tuning.pivotStraight * move.wandered && abs(move.turned) > abs(move.turnedFrom)
        let (fastest, farthest, within) = pivoted ? (tuning.pivotSpeed, tuning.pivotReach, tuning.pivotTime)
            : (tuning.flickSpeed, tuning.flickReach, tuning.flickTime)
        guard peak >= fastest * height, hypot(gone.dx, gone.dy) >= farthest * height, time - move.start <= within else { return nil }
        flicks += 1
        if abs(gone.dx) > abs(gone.dy) * 1.3 { return (CGVector(dx: gone.dx, dy: 0), CGVector(dx: move.peak.dx, dy: 0)) }
        if abs(gone.dy) > abs(gone.dx) * 1.3 { return (CGVector(dx: 0, dy: gone.dy), CGVector(dx: 0, dy: move.peak.dy)) }
        return (gone, move.peak)
    }

    /// Which way three fingers flicked `gone` swipe: across or up and down, if mostly one way.
    static func direction(of gone: CGVector) -> SwipeDirection? {
        if gone.dx != 0, gone.dy == 0 { return gone.dx < 0 ? .left : .right }
        if gone.dy != 0, gone.dx == 0 { return gone.dy < 0 ? .up : .down }
        return nil
    }
}

/// Where the pointer's moves, presses, scrolls and swipes go, in global display coordinates (from
/// the top left of the main screen, down).
@MainActor
protocol PointerEvents: AnyObject {
    /// The pointer's moved there, holding `button` down (dragging) with the press's click count,
    /// or nothing.
    func move(to point: CGPoint, holding button: CGMouseButton?, clicks: Int)
    func press(_ button: CGMouseButton, at point: CGPoint, clicks: Int)
    func release(_ button: CGMouseButton, at point: CGPoint, clicks: Int)
    /// Two fingers have moved `delta` points, down and to the right positive.
    func scroll(by delta: CGVector, phase: ScrollPhase)
    func swipe(_ direction: SwipeDirection)
    /// Zoomed in (positive) or out by that many steps.
    func zoom(by steps: Int)
}

/// The pointer as the hand works it, frame by frame: where it goes on the screen, smoothed, and
/// when it's pressed, let go, dragged and double clicked, as a mouse is; and two or three fingers
/// held together scrolling or swiping, as they would on a trackpad. It only tells `events`, so it
/// can be tried out on made-up hands without touching the real pointer.
///
/// The pointer's at the index fingertip. That moves as it goes to the thumb, though, so once the
/// tips are closing in, the pointer goes by the palm instead (the knuckles hardly move as fingers
/// pinch), with the fingertip kept where it was from the palm as they started: there the press
/// goes, and from there the hand drags. Once the fingers have parted again, it eases back to the
/// fingertip, which is back where it was. And where the pointer's stayed put as the hand moved
/// (scrolling), the difference is taken up as the hand goes on moving, so it never jumps.
@MainActor
final class PointerHand {
    var tuning = PointerTuning() {
        didSet { filters = Filters(tuning) }
    }
    /// Where the pointer is; nil until there's been a hand.
    private(set) var location: CGPoint?
    private(set) var pressed = false
    /// The button pressed: the left for a pinch, or the right for the thumb on the middle tip.
    private(set) var button = CGMouseButton.left
    /// The press's click count: 1, or 2 for the second of a double click.
    private(set) var clicks = 0
    private(set) var shape = PointerShape.pointing
    /// Three fingers swiped, this frame.
    private(set) var swiped: SwipeDirection?
    /// Since when a rest's been counting towards a click (for the ring round the sight), and
    /// whether it clicked, this frame.
    private(set) var resting: TimeInterval?
    private(set) var restClicked = false
    /// The pointer's where resting is for something else (the dial), so it doesn't click there.
    var restsElsewhere = false
    /// Both hands are zooming: this one just follows, pressing and scrolling nothing, and once
    /// it's done its tips have to part before they press.
    var suspended = false
    private var needsOpen = false

    /// The fingertip and the palm, each smoothed.
    private struct Filters {
        var tip, palm: OneEuroFilter

        init(_ tuning: PointerTuning) {
            tip = OneEuroFilter(minCutoff: tuning.minCutoff, beta: tuning.beta, derivativeCutoff: tuning.derivativeCutoff)
            palm = tip
        }

        mutating func reset() {
            tip.reset()
            palm.reset()
        }
    }

    /// The tips closing in: when they were seen to, how far apart they were as they started, and
    /// how near they've come since, and when.
    private struct Closing {
        var time: TimeInterval
        var apart: CGFloat
        var nearest: CGFloat
        var closer: TimeInterval
    }

    /// Two fingers: where the palm was last and when, how far it's gone before it's moved far
    /// enough to scroll, and how fast it was going while they were together.
    private struct Scroll {
        var last: CGPoint
        var time: TimeInterval
        var moved = CGVector.zero
        var began = false
        var velocity = CGVector.zero
        /// Watching for a flick, by the fingertips as they're seen; and how far it's scrolled since
        /// the move that may be one began (the palm, smoothed, lags behind and goes less far than
        /// the fingertips: the rest is made up).
        var flicker: Flicker
        var sent = CGVector.zero
        /// Flicked, gliding on, the way it went: the hand coming back doesn't scroll, till it's
        /// held still. And lifted by a flick, so the next scroll touches down again first, which
        /// stops the glide.
        var coasting: CGVector?
        var lifted = false
    }

    private var filters: Filters
    private var bounds = CGRect.zero
    private var seen = -TimeInterval.infinity
    private var lastFrame = -TimeInterval.infinity
    /// The fingertip from the palm in the picture, as last seen, to stand in when it isn't; and the
    /// same for the fingertips held together (`HandPose.tips`).
    private var tipFromPalm = CGVector(dx: 0, dy: -0.1)
    private var tipsFromPalm = CGVector(dx: 0, dy: -0.1)
    /// Which way the fingers pointed (on the screen) as they took the shape they're in: a flick's
    /// across it.
    private var pointed = CGVector(dx: 0, dy: -1)
    /// How far out to the side of the palm the fingertips are, across that way, this frame: the
    /// wrist turned (a flick that turns it needn't be as quick).
    private var turned: CGFloat = 0
    /// Where the fingertip (smoothed) has stayed, give or take a little, and since when: held still
    /// a moment after a flick, the hand's done coming back.
    private var settled: (point: CGPoint, since: TimeInterval)?
    /// The fingertip from the palm on the screen, kept as the tips close in; and how far the
    /// pointer goes by it (1) rather than by the fingertip itself (0), easing off once they've parted.
    private var kept: CGVector?
    private var keeping: CGFloat = 0
    /// Whether the pointer's following the hand (scrolling, it isn't), where it was last, and the
    /// difference between them that's left to take up.
    private var following = false
    private var followed = CGPoint.zero
    private var offset = CGVector.zero
    /// The last few frames: the fingertip from the palm, and how far apart the tips were.
    private var recent: [(time: TimeInterval, reach: CGVector, pinch: CGFloat)] = []
    private var closing: Closing?
    /// Frames running the thumb's been on a tip (`gripping`'s button), waiting to press.
    private var meeting = 0
    private var gripping = CGMouseButton.left
    /// Frames running the hand's been a fist, and when it last was one.
    private var fists = 0
    private var lastFist = -TimeInterval.infinity
    /// Pressed, the pointer holds there till the hand's moved off from where it was.
    private var still: (point: CGPoint, from: CGPoint)?
    /// Just let go: till then at most, it goes on by the palm while the fingers part.
    private var parting: TimeInterval?
    private var lastPinch: CGFloat?
    /// The last press let go, for a double click.
    private var lastClick: (time: TimeInterval, point: CGPoint, clicks: Int, button: CGMouseButton)?
    /// How many fingers are held together (2 or 3, or 0 for neither), and for how many frames running.
    private var held = (together: 0, frames: 0)
    private var scrolling: Scroll?
    /// Three fingers: where the palm was as they came together, and whether they've gone far
    /// enough to swipe yet (and in which move: if it ends in a flick, that's the same swipe);
    /// watching for a flick, and the way the last swipe went: more flicks that way swipe on, but
    /// the hand coming back doesn't, till it's held still.
    private struct Swipe {
        var from: CGPoint
        var done = false
        var swept: TimeInterval?
        var flicker: Flicker
        var way: CGVector?
    }

    private var swiping: Swipe?
    /// Where the palm was as the fingers took the shape they're in (smoothed, and as it was seen),
    /// and their tips: a scroll or a swipe goes from there, so a flick counts from its start.
    private var shapedFrom: (smooth: CGPoint, seen: CGPoint, tips: CGPoint)?
    /// Resting: where the pointer's resting and since when; and where it was last clicked (or picked
    /// up), and whether it's moved off from there since, so resting can click again.
    private var rest: (point: CGPoint, since: TimeInterval)?
    private var restFrom: CGPoint?
    private var restArmed = false
    /// The other hand, held up as near as this one (not down at the keyboard), this frame.
    private var otherHeld: HandPose?

    init(tuning: PointerTuning = PointerTuning()) {
        self.tuning = tuning
        filters = Filters(tuning)
    }

    /// Starts afresh (nothing's pressed or scrolling: let go first).
    func reset() {
        location = nil
        pressed = false
        button = .left
        clicks = 0
        shape = .pointing
        swiped = nil
        filters.reset()
        seen = -.infinity
        lastFrame = -.infinity
        kept = nil
        keeping = 0
        following = false
        offset = .zero
        recent.removeAll()
        closing = nil
        meeting = 0
        fists = 0
        lastFist = -.infinity
        still = nil
        parting = nil
        lastPinch = nil
        lastClick = nil
        held = (0, 0)
        scrolling = nil
        swiping = nil
        settled = nil
        turned = 0
        otherHeld = nil
        suspended = false
        needsOpen = false
        shapedFrom = nil
        resting = nil
        restClicked = false
        rest = nil
        restFrom = nil
        restArmed = false
    }

    /// One frame's hand (nil for none), and the other if it's in view, read at `time`, pointing over
    /// `screen`.
    func take(_ pose: HandPose?, other: HandPose? = nil, at time: TimeInterval, on screen: CGRect, to events: PointerEvents) {
        swiped = nil
        restClicked = false
        bounds = screen
        guard let pose else {
            meeting = 0
            // Resting clicks only with the hand there, pointing.
            rest = nil
            resting = nil
            // The model often drops a frame or two; a hand gone longer lets go of what it held.
            if time - seen > tuning.lostHand {
                closing = nil
                if pressed { release(at: time, to: events) }
                if shape != .pointing { become(.pointing, at: time, to: events) }
            }
            return
        }
        // Back after a while: smoothed afresh, so the pointer doesn't sweep over from where it was.
        if time - seen > tuning.lostHand * 2 {
            filters.reset()
            recent.removeAll()
            kept = nil
            keeping = 0
            following = false
        }
        seen = time

        // Where the fingertip and the palm point on the screen, smoothed.
        if let tip = pose.tip { tipFromPalm = CGVector(dx: tip.x - pose.anchor.x, dy: tip.y - pose.anchor.y) }
        let tipSpot = pose.tip ?? CGPoint(x: pose.anchor.x + tipFromPalm.dx, y: pose.anchor.y + tipFromPalm.dy)
        let tip = filters.tip(tuning.place(tipSpot, aspect: pose.aspect, on: screen), at: time)
        let seenPalm = tuning.place(pose.anchor, aspect: pose.aspect, on: screen)
        let palm = filters.palm(seenPalm, at: time)
        // The fingertips held together as the wrist swings them, as they're seen, for a flick: the
        // palm, and how far out to the side of it they are, across the way the fingers pointed as
        // they took their shape (not along it, as they curl in to let go, or nod toward the
        // camera). Perhaps off the screen's edge: only how far it goes counts.
        if let tips = pose.tips { tipsFromPalm = CGVector(dx: tips.x - pose.anchor.x, dy: tips.y - pose.anchor.y) }
        let tipsSpot = pose.tips ?? CGPoint(x: pose.anchor.x + tipsFromPalm.dx, y: pose.anchor.y + tipsFromPalm.dy)
        let freePalm = tuning.place(pose.anchor, aspect: pose.aspect, on: screen, kept: false)
        let seenTips = tuning.place(tipsSpot, aspect: pose.aspect, on: screen, kept: false)
        let out = CGVector(dx: seenTips.x - freePalm.x, dy: seenTips.y - freePalm.y)
        if shape == .pointing, pose.together != held.together, hypot(out.dx, out.dy) > 1 {
            pointed = CGVector(dx: out.dx / hypot(out.dx, out.dy), dy: out.dy / hypot(out.dx, out.dy))
        }
        let aside = out.dx * -pointed.dy + out.dy * pointed.dx
        let swing = CGPoint(x: freePalm.x - pointed.dy * aside, y: freePalm.y + pointed.dx * aside)
        turned = aside
        if let still = settled, hypot(tip.x - still.point.x, tip.y - still.point.y) <= tuning.flickRestRadius {} else {
            settled = (tip, time)
        }

        fists = pose.gesture == .fist ? fists + 1 : 0
        if fists > 0 || pose.fistLike { lastFist = time }

        // Both hands zooming (see `PinchZoom`): it only follows the fingertip.
        otherHeld = other.flatMap { $0.size >= pose.size * tuning.otherHand ? $0 : nil }
        if suspended {
            if pressed { release(at: time, to: events) }
            if shape != .pointing { become(.pointing, at: time, to: events) }
            needsOpen = true
            closing = nil
            meeting = 0
            rest = nil
            resting = nil
            kept = nil
            go(to: follow(tip), to: events)
            lastFrame = time
            return
        }

        // Two or three fingers held together a few frames scroll or swipe, and any other shape a
        // few frames stops them; not while a press is held or on its way.
        held = pose.together == held.together ? (held.together, held.frames + 1) : (pose.together, 1)
        if held.frames == 1 { shapedFrom = (palm, seenPalm, swing) }
        if !pressed, closing == nil, meeting == 0 {
            if shape == .pointing, held.together >= 2, held.frames >= tuning.shapeFrames {
                // A swipe goes by the palm as it's seen: smoothing it lags too far behind a sweep.
                let from = held.together == 2 ? shapedFrom?.smooth : shapedFrom?.seen
                become(held.together == 2 ? .scrolling : .swiping, at: time, palm: from ?? palm, tips: shapedFrom?.tips ?? seenTips,
                       to: events)
            } else if shape != .pointing, held.together != (shape == .scrolling ? 2 : 3), held.frames >= tuning.unshapeFrames {
                become(.pointing, at: time, to: events)
            }
        }

        if shape == .swiping {
            swipe(seenPalm, tips: swing, at: time, to: events)
        } else {
            point(pose, tip: tip, palm: palm, tips: swing, at: time, to: events)
        }
        restOn(at: time, to: events)
        lastFrame = time
    }

    /// Lets go of whatever it's holding: a press, or a scroll.
    func letGo(at time: TimeInterval, to events: PointerEvents) {
        if pressed { release(at: time, to: events) }
        if shape != .pointing { become(.pointing, at: time, to: events) }
    }

    /// Pointing (the pointer at the fingertip) or scrolling (the pointer staying put), and the
    /// tips meeting to press.
    private func point(_ pose: HandPose, tip: CGPoint, palm: CGPoint, tips: CGPoint, at time: TimeInterval, to events: PointerEvents) {
        // The thumb on the index tip or the middle one (see `HandPose.button`), never in a fist's
        // shape or just after a fist, whose thumb can lie near the tips. Pressed, it lets go as the
        // thumb leaves the tip it pressed with, or that finger curls right in, or a fist's lasted a
        // few frames (one misread mustn't end a drag). Just after zooming, the tips have to part first.
        if needsOpen, (pose.pinch ?? 1) > tuning.release { needsOpen = false }
        let grip = time - lastFist > tuning.afterFist && !needsOpen ? pose.button(tuning) : nil
        let together = grip != nil
        let (gap, out, least) = pressed && button == .right
            ? (pose.middlePinch, pose.middleReach, tuning.middleReach) : (pose.pinch, pose.reach, tuning.reach)
        let apart = (gap.map { $0 > tuning.release } ?? false) || (out.map { $0 < least - 0.15 } ?? false) || fists >= 3
        let reach = CGVector(dx: tip.x - palm.x, dy: tip.y - palm.y)

        // The tips closing in: the fingertip's kept where it was from the palm as they started.
        // If they part again, or come no nearer for a moment, it eases back to the fingertip.
        if let pinch = pose.pinch {
            recent.append((time, reach, pinch))
            recent.removeAll { time - $0.time > 0.5 }
            let widest = recent.filter { time - $0.time <= tuning.closingTime + 0.001 }.map(\.pinch).max() ?? pinch
            if !pressed, closing == nil, pinch < tuning.near, widest - pinch >= tuning.closing {
                var start = recent.count - 1
                while start > 0, time - recent[start - 1].time <= tuning.closingTime + 0.1,
                      recent[start - 1].pinch >= recent[start].pinch - 0.02 {
                    start -= 1
                }
                // Still kept from the press before (the first of a double click), it stays.
                if kept == nil { kept = recent[start].reach }
                closing = Closing(time: time, apart: recent[start].pinch, nearest: pinch, closer: time)
            } else if var closed = closing, !together, meeting == 0 {
                if pinch < closed.nearest - 0.01 {
                    closed.nearest = pinch
                    closed.closer = time
                    closing = closed
                }
                if pinch > closed.apart - 0.05 || time - closed.closer > tuning.aimFor { closing = nil }
            }
        }
        // Together too slowly to see them closing in: kept from here on.
        if !pressed, together, kept == nil { kept = reach }

        // Pressed, or about to be, or parting: going by the palm. After, easing back to the fingertip.
        let stillParting = parting.map { until in
            time < until && ((pose.pinch ?? 0) < tuning.parted || (pose.pinch ?? 0) - (lastPinch ?? 0) > 0.02)
        } ?? false
        if pressed || closing != nil || together || stillParting {
            keeping = kept == nil ? 0 : 1
        } else {
            parting = nil
            if kept != nil {
                keeping -= CGFloat(min(time - lastFrame, 0.1) / tuning.ease)
                if keeping <= 0 {
                    kept = nil
                    keeping = 0
                }
            }
        }
        lastPinch = pose.pinch
        var source = tip
        if let kept {
            let byPalm = CGPoint(x: palm.x + kept.dx, y: palm.y + kept.dy), share = keeping * keeping * (3 - 2 * keeping)
            source = CGPoint(x: tip.x + (byPalm.x - tip.x) * share, y: tip.y + (byPalm.y - tip.y) * share)
        }

        if pressed {
            var next = follow(source)
            if let held = still {
                if hypot(source.x - held.from.x, source.y - held.from.y) > tuning.hold { still = nil } else { next = held.point }
            }
            go(to: next, to: events)
            if apart { release(at: time, to: events) }
            return
        }

        // Scrolling, the pointer stays put.
        let next = shape == .pointing ? follow(source) : nil
        if let grip {
            meeting = grip == gripping ? meeting + 1 : 1
            gripping = grip
            // The other hand held up too: it may be about to pinch as well, to zoom, so the press
            // waits a little, and doesn't come while it is.
            let other = otherHeld.map { ($0.pinch ?? 1) < tuning.zoomBlock ? Int?.none : tuning.zoomWait } ?? 0
            let frames = tuning.pressFrames + (grip == .right ? tuning.rightFrames : 0)
            if let wait = other, meeting >= frames + wait {
                press(grip, at: next ?? location ?? source, met: closing?.time ?? time, from: source, to: events)
                return
            }
        } else {
            meeting = 0
        }
        if let next { go(to: next, to: events) }
        // The palm scrolls, but not while the thumb's on its way to a fingertip (to click) or just
        // leaving it, or the fingers are changing shape (unless they're darting off, which blurs them).
        if shape == .scrolling {
            let blurred = scrolling?.flicker.isMoving == true
            scroll(palm, tips: tips, at: time, holding: closing != nil || meeting > 0 || stillParting
                   || (held.together != 2 && held.frames > 1 && !blurred), to: events)
        }
    }

    /// Where the pointer goes for the hand at `raw` (smoothed, on the screen): there, but for what's
    /// left of a difference between them, which is taken up as the hand moves (not as it holds
    /// still, when the pointer would creep); and only past the dead zone.
    private func follow(_ raw: CGPoint) -> CGPoint {
        if !following {
            offset = location.map { CGVector(dx: $0.x - raw.x, dy: $0.y - raw.y) } ?? .zero
            following = true
        } else {
            let left = hypot(offset.dx, offset.dy), moved = hypot(raw.x - followed.x, raw.y - followed.y) - 0.8
            if left > 0, moved > 0 {
                let keep = max(left - moved * tuning.catchUp, 0) / left
                offset = CGVector(dx: offset.dx * keep, dy: offset.dy * keep)
            }
        }
        followed = raw
        let wanted = CGPoint(x: min(max(raw.x + offset.dx, bounds.minX), bounds.maxX - 1),
                             y: min(max(raw.y + offset.dy, bounds.minY), bounds.maxY - 1))
        guard let location else { return wanted }
        let off = hypot(wanted.x - location.x, wanted.y - location.y)
        guard off > tuning.deadZone else { return location }
        let follow = (off - tuning.deadZone) / off
        return CGPoint(x: location.x + (wanted.x - location.x) * follow, y: location.y + (wanted.y - location.y) * follow)
    }

    private func go(to point: CGPoint, to events: PointerEvents) {
        if let location, hypot(point.x - location.x, point.y - location.y) < 0.5 { return }
        location = point
        events.move(to: point, holding: pressed ? button : nil, clicks: clicks)
    }

    private func press(_ button: CGMouseButton, at point: CGPoint, met: TimeInterval, from source: CGPoint, to events: PointerEvents) {
        var point = point
        // Soon after the last, in the same spot: a double click (or a triple), where the first was.
        if let last = lastClick, last.button == button, met - last.time <= tuning.doubleClickTime,
           hypot(point.x - last.point.x, point.y - last.point.y) <= tuning.doubleClickRadius {
            clicks = last.clicks + 1
            point = last.point
        } else {
            clicks = 1
        }
        go(to: point, to: events)
        pressed = true
        self.button = button
        events.press(button, at: point, clicks: clicks)
        still = (point, source)
        meeting = 0
        closing = nil
        recent.removeAll()
    }

    private func release(at time: TimeInterval, to events: PointerEvents) {
        guard pressed else { return }
        let point = location ?? .zero
        pressed = false
        events.release(button, at: point, clicks: clicks)
        lastClick = (time, point, clicks, button)
        still = nil
        parting = time + tuning.settle
        disarmRest()
    }

    /// Resting: once the pointer's been still a moment, and a while more, it clicks there. Then it
    /// has to move off before resting clicks again (and it has to have moved since it was picked
    /// up, or last did something else).
    private func restOn(at time: TimeInterval, to events: PointerEvents) {
        guard let location else { return }
        if let from = restFrom {
            if !restArmed, hypot(location.x - from.x, location.y - from.y) > tuning.rearm { restArmed = true }
        } else {
            restFrom = location
        }
        let can = restArmed && shape == .pointing && !pressed && closing == nil && meeting == 0 && parting == nil && !restsElsewhere
        guard can, let spot = rest, hypot(location.x - spot.point.x, location.y - spot.point.y) <= tuning.restRadius else {
            rest = can ? (location, time) : nil
            resting = nil
            return
        }
        if resting == nil, time - spot.since >= tuning.restSettle { resting = time }
        guard let began = resting, time - began >= tuning.restTime else { return }
        events.press(.left, at: location, clicks: 1)
        events.release(.left, at: location, clicks: 1)
        lastClick = (time, location, 1, .left)
        restClicked = true
        disarmRest()
    }

    private func disarmRest() {
        rest = nil
        resting = nil
        restArmed = false
        restFrom = location
    }

    /// Two fingers moving: they scroll as far as the palm goes (past the dead zone, so a hand held
    /// still doesn't shiver the page), once it's gone far enough to count. Flicked, they scroll as
    /// far as their tips went, and the page glides on, as a trackpad's does once a flicking finger
    /// lifts; the hand coming back is let be.
    private func scroll(_ palm: CGPoint, tips: CGPoint, at time: TimeInterval, holding: Bool, to events: PointerEvents) {
        guard var scroll = scrolling else { return }
        defer { scrolling = scroll }
        let wasMoving = scroll.flicker.isMoving
        var flick = scroll.flicker.take(tips, turn: turned, at: time, tuning: tuning, height: bounds.height)
        // Held, no move's a flick: the thumb at the tips moves them as a flick would.
        if holding, scroll.coasting == nil {
            scroll.flicker.forget()
            flick = nil
        }
        if !wasMoving, scroll.flicker.isMoving { scroll.sent = .zero }
        let off = hypot(palm.x - scroll.last.x, palm.y - scroll.last.y), past = max(off - tuning.deadZone, 0) / max(off, 0.001)
        let next = CGPoint(x: scroll.last.x + (palm.x - scroll.last.x) * past, y: scroll.last.y + (palm.y - scroll.last.y) * past)
        let delta = CGVector(dx: (next.x - scroll.last.x) * tuning.scrollGain, dy: (next.y - scroll.last.y) * tuning.scrollGain)
        let step = time - scroll.time
        scroll.last = next
        scroll.time = time
        if let way = scroll.coasting {
            // Flicked again the same way: on again. Otherwise, coming back, nothing, till it's held
            // still a moment.
            if let flick, flick.velocity.dx * way.dx + flick.velocity.dy * way.dy > 0 {
                self.flick(flick, to: events)
                scroll.coasting = flick.velocity
            } else if heldStill(at: time) {
                scroll.coasting = nil
                scroll.began = false
                scroll.moved = .zero
                scroll.velocity = .zero
            }
            return
        }
        guard !holding else { return }
        if step > 0 {
            scroll.velocity = CGVector(dx: scroll.velocity.dx + (delta.dx / step - scroll.velocity.dx) * 0.7,
                                       dy: scroll.velocity.dy + (delta.dy / step - scroll.velocity.dy) * 0.7)
        }
        if let flick {
            // What the palm held back, then gliding on.
            if scroll.began {
                let rest = CGVector(dx: flick.gone.dx * tuning.scrollGain - scroll.sent.dx, dy: flick.gone.dy * tuning.scrollGain - scroll.sent.dy)
                if hypot(rest.dx, rest.dy) > 0.5 { events.scroll(by: rest, phase: .changed) }
                events.scroll(by: .zero, phase: .ended(velocity: glide(flick.velocity)))
            } else {
                self.flick(flick, to: events, touching: scroll.lifted)
            }
            scroll.began = true
            scroll.lifted = true
            scroll.coasting = flick.velocity
            return
        }
        if scroll.began {
            if hypot(delta.dx, delta.dy) > 0.05 {
                events.scroll(by: delta, phase: .changed)
                scroll.sent = CGVector(dx: scroll.sent.dx + delta.dx, dy: scroll.sent.dy + delta.dy)
            }
        } else {
            scroll.moved = CGVector(dx: scroll.moved.dx + delta.dx, dy: scroll.moved.dy + delta.dy)
            if hypot(scroll.moved.dx, scroll.moved.dy) > tuning.scrollStart {
                scroll.began = true
                // Coming back from a flick's glide: down on the trackpad again, which stops it.
                if scroll.lifted { events.scroll(by: .zero, phase: .touched) }
                scroll.lifted = false
                events.scroll(by: scroll.moved, phase: .began)
                scroll.sent = CGVector(dx: scroll.sent.dx + scroll.moved.dx, dy: scroll.sent.dy + scroll.moved.dy)
            }
        }
    }

    /// A flick on its own (the first, from still, or another after it): a scroll as far as it went,
    /// lifted at once to glide on; `touching` first, which stops the glide that's going.
    private func flick(_ flick: (gone: CGVector, velocity: CGVector), to events: PointerEvents, touching: Bool = true) {
        if touching { events.scroll(by: .zero, phase: .touched) }
        events.scroll(by: CGVector(dx: flick.gone.dx * tuning.scrollGain, dy: flick.gone.dy * tuning.scrollGain), phase: .began)
        events.scroll(by: .zero, phase: .ended(velocity: glide(flick.velocity)))
    }

    /// A flick's speed, as the page glides on at.
    private func glide(_ velocity: CGVector) -> CGVector {
        CGVector(dx: velocity.dx * tuning.scrollGain, dy: velocity.dy * tuning.scrollGain)
    }

    /// The fingertip's been held still a moment: done coming back from a flick.
    private func heldStill(at time: TimeInterval) -> Bool {
        settled.map { time - $0.since >= tuning.flickRest } ?? false
    }

    /// Three fingers moving: once they've gone far enough one way, a swipe that way (one each time
    /// they're held together, as on a trackpad); or flicked that way, from the wrist, as soon as
    /// the flick's done, and again for each flick more that way. The hand coming back doesn't
    /// swipe back, till it's been held still a moment.
    private func swipe(_ palm: CGPoint, tips: CGPoint, at time: TimeInterval, to events: PointerEvents) {
        guard var swipe = swiping else { return }
        defer { swiping = swipe }
        if swipe.way != nil, heldStill(at: time) { swipe.way = nil }
        let move = swipe.flicker.started
        if let flick = swipe.flicker.take(tips, turn: turned, at: time, tuning: tuning, height: bounds.height) {
            let onward = swipe.way.map { flick.gone.dx * $0.dx + flick.gone.dy * $0.dy > 0 } ?? true
            if onward, move == nil || move != swipe.swept, let direction = Flicker.direction(of: flick.gone) {
                swipe.done = true
                swipe.way = flick.gone
                swiped = direction
                events.swipe(direction)
            }
            return
        }
        // Still three (but for a frame lost to a blurred flick).
        guard !swipe.done, held.together == 3 || held.frames <= 1 else { return }
        let width = max(bounds.width, 1), height = max(bounds.height, 1)
        let across = (palm.x - swipe.from.x) / width, down = (palm.y - swipe.from.y) / height
        let direction: SwipeDirection
        if abs(across) > tuning.swipe, abs(across) > abs(down) * 1.3 {
            direction = across < 0 ? .left : .right
        } else if abs(down) > tuning.swipe, abs(down) > abs(across) * 1.3 {
            direction = down < 0 ? .up : .down
        } else {
            return
        }
        swipe.done = true
        swipe.swept = swipe.flicker.started
        swipe.way = CGVector(dx: palm.x - swipe.from.x, dy: palm.y - swipe.from.y)
        swiped = direction
        events.swipe(direction)
    }

    /// Starts pointing, scrolling (from the palm at `palm`, the fingertips at `tips`) or swiping,
    /// finishing what the last shape was doing: a scroll's lifted, gliding on if it was going fast.
    private func become(_ new: PointerShape, at time: TimeInterval, palm: CGPoint? = nil, tips: CGPoint? = nil,
                        to events: PointerEvents) {
        if let scroll = scrolling, scroll.coasting == nil {
            // Darting off as the fingers part (blurred, as a flick does): as far as it's gone, what
            // smoothing held back made up, and gliding on at its fastest.
            let darting = scroll.flicker.mayFlick(at: time, tuning: tuning) ? scroll.flicker.fastest : nil
            var began = scroll.began
            if darting != nil, let gone = scroll.flicker.going {
                let total = CGVector(dx: gone.dx * tuning.scrollGain, dy: gone.dy * tuning.scrollGain)
                let rest = began ? CGVector(dx: total.dx - scroll.sent.dx, dy: total.dy - scroll.sent.dy) : total
                if hypot(rest.dx, rest.dy) > (began ? 0.5 : tuning.scrollStart) {
                    events.scroll(by: rest, phase: began ? .changed : .began)
                    began = true
                }
            }
            if began {
                let velocity = darting.map(glide) ?? scroll.velocity
                let fast = hypot(velocity.dx, velocity.dy) > tuning.flingSpeed
                events.scroll(by: .zero, phase: .ended(velocity: fast ? velocity : .zero))
            } else {
                events.scroll(by: .zero, phase: .cancelled)
            }
        }
        scrolling = nil
        swiping = nil
        shape = new
        closing = nil
        meeting = 0
        parting = nil
        kept = nil
        keeping = 0
        recent.removeAll()
        disarmRest()
        // Whatever comes next picks up from where the pointer is.
        following = false
        guard let palm else { return }
        switch new {
        case .scrolling:
            scrolling = Scroll(last: palm, time: time, flicker: Flicker(last: tips ?? palm, time: time, lastTurn: turned))
            events.scroll(by: .zero, phase: .touched)
        case .swiping:
            swiping = Swipe(from: palm, flicker: Flicker(last: tips ?? palm, time: time, lastTurn: turned))
        case .pointing, .zooming:
            break
        }
    }
}

/// The real pointer: the system's own mouse, scroll and key events, posted at the HID level, as a
/// mouse's or a trackpad's would be. That takes the Accessibility permission (`canPost`); without
/// it, the pointer's warped there instead, which doesn't (apps don't see it move till something
/// else happens, and nothing can be pressed, scrolled or swiped).
@MainActor
final class SystemPointer: PointerEvents {
    var canPost = false
    /// What this Mac's trackpad does with three fingers, and which way it scrolls.
    var trackpad = TrackpadSettings()
    private let source = CGEventSource(stateID: .hidSystemState)
    /// A scroll goes out in whole points, what's left over carried on to the next.
    private var leftOver = CGVector.zero
    /// A scroll let go while it's moving glides on, slowing, as a trackpad's does.
    private var glide: (velocity: CGVector, last: TimeInterval, begun: Bool)?
    private var glider: Timer?
    /// Mission Control or an app's windows, if a swipe's lately shown them: a swipe the other way
    /// goes back.
    private var shown: (swipe: SwipeDirection, at: TimeInterval)?

    /// How long a glide takes to slow by e, about as long as a trackpad's, and the fastest it starts.
    static let glideTime: TimeInterval = 0.42
    static let fastestGlide: CGFloat = 7000

    private static let leftArrow: CGKeyCode = 123, rightArrow: CGKeyCode = 124, downArrow: CGKeyCode = 125, upArrow: CGKeyCode = 126
    private static let equals: CGKeyCode = 24, minus: CGKeyCode = 27
    /// The modifier keys a shortcut's pressed with. Fn only rides along as a flag: pressed alone,
    /// it can start dictation or bring up the emoji picker.
    /// Each click and shortcut it posts, with its modifier flags (`log show --predicate
    /// 'subsystem == "local.nott"'`).
    private static let log = Logger(subsystem: "local.nott", category: "manus")

    func move(to point: CGPoint, holding button: CGMouseButton?, clicks: Int) {
        guard canPost else {
            CGWarpMouseCursorPosition(point)
            return
        }
        switch button {
        case .left?: post(.leftMouseDragged, at: point, button: .left, clicks: clicks)
        case .right?: post(.rightMouseDragged, at: point, button: .right, clicks: clicks)
        default: post(.mouseMoved, at: point, button: .left, clicks: 0)
        }
    }

    func press(_ button: CGMouseButton, at point: CGPoint, clicks: Int) {
        if canPost { post(button == .right ? .rightMouseDown : .leftMouseDown, at: point, button: button, clicks: clicks) }
    }

    func release(_ button: CGMouseButton, at point: CGPoint, clicks: Int) {
        if canPost { post(button == .right ? .rightMouseUp : .leftMouseUp, at: point, button: button, clicks: clicks) }
    }

    func scroll(by delta: CGVector, phase: ScrollPhase) {
        guard canPost else { return }
        switch phase {
        case .touched:
            // Fingers on the trackpad stop a glide.
            stopGliding()
            leftOver = .zero
            post(scroll: .zero, phase: .mayBegin)
        case .began:
            post(scroll: delta, phase: .began)
        case .changed:
            post(scroll: delta, phase: .changed)
        case let .ended(velocity):
            post(scroll: .zero, phase: .ended)
            if velocity != .zero { startGliding(velocity) }
        case .cancelled:
            post(scroll: .zero, phase: .cancelled)
        }
    }

    /// Three fingers swiping, as this Mac's trackpad has them: across, to the next Space (or
    /// full-screen app) the way they drag it in from; up, Mission Control; down, the app's windows;
    /// and the other way, back from either. Through Mission Control's own shortcuts, as they're
    /// set out of the box.
    func swipe(_ direction: SwipeDirection) {
        guard canPost else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = shown, now - last.at > 30 { shown = nil }
        switch direction {
        case .left, .right:
            guard trackpad.swipesAcross else { return }
            key(direction == .left ? Self.rightArrow : Self.leftArrow)
            shown = nil
        case .up, .down:
            guard trackpad.swipesUpAndDown else { return }
            if let last = shown {
                // The other way, back out (its own shortcut puts it away); the same way, it's up.
                if last.swipe != direction {
                    key(last.swipe == .up ? Self.upArrow : Self.downArrow)
                    shown = nil
                }
            } else {
                key(direction == .up ? Self.upArrow : Self.downArrow)
                shown = (direction, now)
            }
        }
    }

    /// Zooming, as two hands draw apart or together: the app in front's own zoom, a step at a time
    /// (Command and = or -, which nearly every app that zooms takes, as Zoom In and Zoom Out).
    func zoom(by steps: Int) {
        guard canPost else { return }
        for _ in 0..<abs(steps) { key(steps > 0 ? Self.equals : Self.minus, flags: .maskCommand) }
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clicks: Int) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        if clicks > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)) }
        // A left click is never a control-click, which is a context menu: that's the right button's.
        let carried = event.flags
        if button == .left { event.flags.remove(.maskControl) }
        if type == .leftMouseDown || type == .rightMouseDown {
            Self.log.notice("\(button == .right ? "right" : "left", privacy: .public) down ×\(clicks) at \(Int(point.x)),\(Int(point.y)), flags \(carried.rawValue, format: .hex)")
        }
        event.post(tap: .cghidEventTap)
    }

    /// A trackpad's scroll of `delta` points the way the fingers went (scrolling naturally, the
    /// page goes with them; otherwise, the other way), in its phase, or its glide's.
    private func post(scroll delta: CGVector, phase: CGScrollPhase? = nil, glide: CGMomentumScrollPhase = .none) {
        let way: CGFloat = trackpad.natural ? 1 : -1
        leftOver = CGVector(dx: leftOver.dx + delta.dx * way, dy: leftOver.dy + delta.dy * way)
        let across = Int32(leftOver.dx.rounded(.towardZero)), down = Int32(leftOver.dy.rounded(.towardZero))
        leftOver = CGVector(dx: leftOver.dx - CGFloat(across), dy: leftOver.dy - CGFloat(down))
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: down, wheel2: across,
                                  wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(glide.rawValue))
        event.post(tap: .cghidEventTap)
    }

    /// A key pressed with `flags`: by default control and an arrow, as Mission Control's shortcuts
    /// have them (with fn, as an arrow key carries it). See `Keystroke`.
    private func key(_ code: CGKeyCode, flags: CGEventFlags = [.maskControl, .maskSecondaryFn]) {
        Keystroke.post(code, flags: flags, source: source)
        Self.log.notice("key \(code) with flags \(flags.rawValue, format: .hex), then \(CGEventSource.flagsState(.hidSystemState).rawValue, format: .hex) held")
    }

    private func startGliding(_ velocity: CGVector) {
        stopGliding()
        let speed = hypot(velocity.dx, velocity.dy), cut = min(Self.fastestGlide / max(speed, 1), 1)
        glide = (CGVector(dx: velocity.dx * cut, dy: velocity.dy * cut), ProcessInfo.processInfo.systemUptime, false)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.glideOn() }
        }
        RunLoop.main.add(timer, forMode: .common)
        glider = timer
    }

    private func glideOn() {
        guard var glide else { return }
        let now = ProcessInfo.processInfo.systemUptime, step = now - glide.last
        let slowed = CGFloat(exp(-step / Self.glideTime))
        glide.velocity = CGVector(dx: glide.velocity.dx * slowed, dy: glide.velocity.dy * slowed)
        glide.last = now
        guard hypot(glide.velocity.dx, glide.velocity.dy) > 12 else {
            stopGliding()
            return
        }
        post(scroll: CGVector(dx: glide.velocity.dx * step, dy: glide.velocity.dy * step), glide: glide.begun ? .continuous : .begin)
        glide.begun = true
        self.glide = glide
    }

    /// Stops a glide, saying it's over.
    private func stopGliding() {
        glider?.invalidate()
        glider = nil
        if glide?.begun == true { post(scroll: .zero, glide: .end) }
        glide = nil
    }
}

/// What this Mac's trackpad is set to do, for the hand to do the same: whether three fingers swipe
/// between Spaces and full-screen apps, and up for Mission Control, and whether scrolling's
/// natural (the page going the way the fingers do).
struct TrackpadSettings {
    var swipesAcross = true
    var swipesUpAndDown = true
    var natural = true

    /// As System Settings has them: the built-in trackpad's, or failing that a Magic Trackpad's.
    static func read() -> TrackpadSettings {
        func number(_ key: String) -> Int? {
            for domain in ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
                if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int { return value }
            }
            return nil
        }
        // 2 is these, with three fingers; otherwise they're off, or done with four.
        return TrackpadSettings(swipesAcross: (number("TrackpadThreeFingerHorizSwipeGesture") ?? 2) == 2,
                                swipesUpAndDown: (number("TrackpadThreeFingerVertSwipeGesture") ?? 2) == 2,
                                natural: UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true)
    }
}

/// Whether the hand's the pointer, and what it's doing, for the band's constellation to show (it
/// reads this as it draws).
final class PointerFeed: @unchecked Sendable {
    enum Shown: Sendable {
        case off, on
        /// On, but Accessibility isn't allowed, so it can't press.
        case needsAccess
    }

    static let shared = PointerFeed()

    private let state = OSAllocatedUnfairLock(initialState: (shown: Shown.off, shape: PointerShape.pointing))

    var shown: Shown {
        get { state.withLock { $0.shown } }
        set { state.withLock { $0.shown = newValue } }
    }

    var shape: PointerShape {
        get { state.withLock { $0.shape } }
        set { state.withLock { $0.shape = newValue } }
    }
}

// MARK: - Drawing it

/// The window the hands are drawn in, each round its pointer, and the dial in the top bar: over
/// the whole screen, over everything, and clear, so clicks go straight through it. Made when the
/// pointer's picked up and gone soon after it's put down. Each hand's figure comes as the hand
/// does, and goes once it's been gone a moment.
@MainActor
final class PointerOverlay {
    private let window: NSPanel
    private let root = CALayer()
    private let figures = [PointerFigure(), PointerFigure()]
    private let dial = PointerDial()
    /// Each figure's showing, and when its hand was last seen.
    private var showing = [false, false]
    /// Each hand not yet seen since the pointer was picked up: its figure's born, not just drawn on.
    private var unborn = [true, true]
    private var seen: [TimeInterval] = [0, 0]
    private var asking = false
    /// The screen, in global display coordinates; and where the pointer rests on the dial, from the
    /// top of the screen down to under it (so the pointer pushed up against the top finds it).
    private var screen = CGRect.zero
    private var dialSpot = CGRect.zero
    private var closing: DispatchWorkItem?

    /// A hand gone this long, its figure goes.
    static let lostAfter: TimeInterval = 1.2

    init() {
        // Made now, so it joins every Space (see `ClosedLyrics`).
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        // Hosting the figures' and the dial's layers, not drawing.
        let view = NSView()
        view.layer = root
        view.wantsLayer = true
        for figure in figures { root.addSublayer(figure.layer) }
        root.addSublayer(dial.layer)
        window.contentView = view
    }

    /// Covers `frame` (the screen, as windows measure it), which is `global` as events do, with the
    /// dial at `spot` (as events measure it too).
    func cover(_ frame: NSRect, global: CGRect, scale: CGFloat, dial spot: CGPoint) {
        screen = global
        if window.frame != frame { window.setFrame(frame, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for figure in figures {
            figure.layer.frame = CGRect(origin: .zero, size: frame.size)
            figure.scale = scale
        }
        dial.scale = scale
        let at = local(spot)
        dial.layer.position = CGPoint(x: at.x, y: frame.height - at.y)
        CATransaction.commit()
        dialSpot = CGRect(x: spot.x - 20, y: global.minY, width: 40, height: spot.y - global.minY + 16)
    }

    func begin(needsAccess: Bool) {
        closing?.cancel()
        closing = nil
        showing = [false, false]
        unborn = [true, true]
        asking = needsAccess
        window.orderFrontRegardless()
        dial.begin()
    }

    /// Hand `index` this frame (nil when it's not in view), its pointer at `point`, and what it's doing.
    func update(_ index: Int, _ pose: HandPose?, at point: CGPoint?, pressed: Bool, shape: PointerShape, swiped: SwipeDirection?,
                zoomed: Int?, resting: Bool, restClicked: Bool, time: TimeInterval) {
        let figure = figures[index]
        if pose != nil { seen[index] = time }
        if pose != nil, !showing[index], let point {
            showing[index] = true
            figure.begin(at: local(point), needsAccess: asking, born: unborn[index])
            unborn[index] = false
        } else if pose == nil, showing[index], time - seen[index] > Self.lostAfter {
            showing[index] = false
            figure.finish()
        }
        guard showing[index] else { return }
        figure.place(pose, at: point.map(local), pressed: pressed, shape: shape, swiped: swiped, zoomed: zoomed, resting: resting,
                     restClicked: restClicked)
    }

    /// Whether `point` (in global display coordinates) is on the dial.
    func isOnDial(_ point: CGPoint) -> Bool { dialSpot.contains(point) }

    func needsAccess(_ needed: Bool) {
        asking = needed
        for (figure, shown) in zip(figures, showing) where shown { figure.needsAccess(needed) }
    }

    /// The pointer's at `point` (in global display coordinates): true once it's rested on the dial
    /// long enough to put the hands down.
    func rest(_ point: CGPoint, at time: TimeInterval) -> Bool {
        dial.rest(dialSpot.contains(point), at: time)
    }

    /// The flourish for putting it down (each figure bursting), then the window goes, and `done`
    /// is told.
    func finish(then done: @escaping () -> Void) {
        for (figure, shown) in zip(figures, showing) where shown { figure.burst() }
        showing = [false, false]
        dial.finish()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.window.orderOut(nil)
                done()
            }
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PointerFigure.finishing, execute: work)
    }

    private func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - screen.minX, y: point.y - screen.minY) }
}

/// The hand as the pointer: a small constellation round it in the band's own look, a star at
/// each joint (the fingertips brightest, with glints; the knuckles and wrist next), fine dotted
/// lines between, silver-white on nothing, the index fingertip on the pointer. The hot spot is a
/// sight there, a ring with four ticks, that closes in and flares while pressed, and round which
/// a ring of dots draws on as the pointer rests (to click). It says what it's doing in signs, not
/// words, as a star atlas does: Gemini's (♊︎) by it while two fingers scroll, the triangle's (△)
/// while three swipe, each swipe a shooting star off the sight the way it went; zooming, the sun's
/// (☉), then ⊕ or ⊖ with each step, as its rings open out or close in; and a padlock while it
/// can't press for want of Accessibility. Picking the pointer up, its stars are born, out from the
/// wrist (each a faint cloud gathering in, motes falling into it, lit in a flash), the lines
/// drawing on between them, and a ring spreads from the sight; putting it down, each star flares
/// and bursts, faintly, throwing off a few sparks as a ring goes out. A hand coming back into view
/// meanwhile just draws on, and one lost fades. All of it Core Animation layers, moved as the hand
/// moves; only the lines are drawn afresh each frame.
///
/// `place` and the rest take points measured from the top left of the screen, down, as events do.
@MainActor
final class PointerFigure {
    /// The screen's worth: set its frame to the screen's.
    let layer = CALayer()
    /// The screen's scale, for the pictures and lines.
    var scale: CGFloat = 2 {
        didSet {
            guard scale != oldValue else { return }
            for part in [layer, body, under, lines, sight, flare, ring, dottedRing, streak, restRing, name, standing] { part.contentsScale = scale }
            (stars + cores + pictures).forEach { $0.contentsScale = scale }
            paint()
        }
    }

    /// How long putting it down takes, all told.
    static let finishing: TimeInterval = 1.6
    /// The palm's length (wrist to middle knuckle) as drawn, in points.
    static let palm: CGFloat = 38

    private let body = CALayer()
    /// The lines, and a faint dark bed under them, so they read over a light window too.
    private let under = CAShapeLayer()
    private let lines = CAShapeLayer()
    /// Each joint's star: where it is; in it, the star itself (born and burst, apart from the motes
    /// and clouds about it); and in that, its picture, twinkling.
    private var stars: [CALayer] = []
    private var cores: [CALayer] = []
    private var pictures: [CALayer] = []
    private let sight = CALayer()
    private let flare = CALayer()
    private let ring = CAShapeLayer()
    private let dottedRing = CAShapeLayer()
    /// Its name a moment, and what it needs, standing.
    private let name = CALayer()
    private let standing = CALayer()
    /// A swipe's shooting star.
    private let streak = CAShapeLayer()
    /// A rest counting towards a click: dots drawing on round the sight, from noon.
    private let restRing = CAShapeLayer()
    private var restShown = false

    /// Each joint, from the hot spot, in points (down positive), eased; nil where it isn't seen.
    private var shape = [CGPoint?](repeating: nil, count: TrackingReading.joints.count)
    private var at: CGPoint?
    private var pressed = false
    private var present = true
    private var asking = false
    /// What the hand's doing: pointing, scrolling or swiping.
    private var doing = PointerShape.pointing
    /// The sign it's showing by it, if any.
    private var marked: String?
    /// The fingertip from the palm, as last seen, to hang the figure from when it isn't.
    private var tipFromPalm = CGVector(dx: 0, dy: -0.1)

    init() {
        layer.masksToBounds = false
        layer.addSublayer(body)
        for (part, color, width) in [(under, NSColor(Midnight.ink).withAlphaComponent(0.4), 3.2),
                                     (lines, NSColor(Midnight.silver).withAlphaComponent(0.8), 1.1)] {
            part.fillColor = nil
            part.strokeColor = color.cgColor
            part.lineWidth = width
            part.lineCap = .round
            part.lineDashPattern = [0.01, 3]
            body.addSublayer(part)
        }
        for slot in TrackingReading.joints.indices {
            let star = CALayer()
            star.opacity = 0
            let core = CALayer()
            let picture = CALayer()
            core.addSublayer(picture)
            star.addSublayer(core)
            // Each twinkles a little, in its own time, as the band's do.
            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = 1
            twinkle.toValue = 0.78
            twinkle.duration = 1 / (0.7 + 0.12 * Double(slot % 7))
            twinkle.autoreverses = true
            twinkle.repeatCount = .infinity
            twinkle.timeOffset = Double(slot) * 0.37
            picture.add(twinkle, forKey: "twinkle")
            stars.append(star)
            cores.append(core)
            pictures.append(picture)
            body.addSublayer(star)
        }
        body.addSublayer(sight)
        flare.opacity = 0
        body.addSublayer(flare)
        // The flourish's rings, there only while they spread or close.
        for (part, dotted) in [(ring, false), (dottedRing, true)] {
            part.path = CGPath(ellipseIn: CGRect(x: -44, y: -44, width: 88, height: 88), transform: nil)
            part.fillColor = nil
            part.strokeColor = NSColor(Midnight.moonlight).withAlphaComponent(dotted ? 0.8 : 0.6).cgColor
            part.lineWidth = dotted ? 1.2 : 0.7
            if dotted {
                part.lineCap = .round
                part.lineDashPattern = [0.01, 4.5]
            }
            part.opacity = 0
            part.name = "flourish"
            layer.addSublayer(part)
        }
        let round = CGMutablePath()
        round.addArc(center: .zero, radius: 17, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        restRing.path = round
        restRing.fillColor = nil
        restRing.strokeColor = NSColor(Midnight.white).withAlphaComponent(0.9).cgColor
        restRing.lineWidth = 1.4
        restRing.lineCap = .round
        restRing.lineDashPattern = [0.01, 3.2]
        restRing.strokeEnd = 0
        body.addSublayer(restRing)
        streak.fillColor = nil
        streak.strokeColor = NSColor(Midnight.moonlight).withAlphaComponent(0.9).cgColor
        streak.lineWidth = 1.2
        streak.lineCap = .round
        streak.opacity = 0
        layer.addSublayer(streak)
        for label in [name, standing] {
            label.opacity = 0
            layer.addSublayer(label)
        }
        name.anchorPoint = CGPoint(x: 0, y: 0)
        standing.anchorPoint = CGPoint(x: 0, y: 1)
        paint()
    }

    /// The pictures, at the screen's scale.
    private func paint() {
        for (slot, star) in stars.enumerated() {
            let (radius, glint, light) = Self.look(of: slot)
            let (picture, size) = starPicture(radius: radius, glint: glint, light: light, scale: scale)
            star.bounds = CGRect(origin: .zero, size: size)
            cores[slot].frame = star.bounds
            pictures[slot].frame = star.bounds
            pictures[slot].contents = picture
        }
        let (picture, size) = starPicture(radius: 2.4, glint: 15, light: 1, scale: scale)
        flare.bounds = CGRect(origin: .zero, size: size)
        flare.contents = picture
        let side: CGFloat = 32
        sight.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        sight.contents = Self.bitmap(of: Canvas { canvas, size in
            Self.sight(at: CGPoint(x: size.width / 2, y: size.height / 2), in: canvas)
        }
        .frame(width: side, height: side), scale: scale)
        if asking { show(Self.askSymbol, on: standing) }
        if let marked { show(Self.sign(marked), on: name) }
    }

    /// A joint's star: the fingertips brightest, with glints; the knuckles and wrist next; the rest
    /// faint. A little smaller than the band's.
    private static func look(of slot: Int) -> (radius: CGFloat, glint: CGFloat, light: Double) {
        if TrackingReading.tips.contains(slot) { return (2.2, 8.5, 1) }
        if slot == 0 || TrackingReading.knuckles.contains(slot) { return (1.6, 4, 0.9) }
        return (1.15, 0, 0.72)
    }

    // MARK: Moving

    /// The hand (nil when there's none this frame), with its pointer at `point`, pressed or not,
    /// doing `shape`, and having just swiped, if it has.
    func place(_ pose: HandPose?, at point: CGPoint?, pressed: Bool, shape: PointerShape = .pointing,
               swiped: SwipeDirection? = nil, zoomed: Int? = nil, resting: Bool = false, restClicked: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let point { at = point }
        if pressed != self.pressed { press(pressed) }
        if let pose {
            reshape(pose)
            if !present { fade(to: 1, over: 0.2) }
        } else if present {
            // Lost a moment: it dims, as the band's does.
            fade(to: 0.35, over: 0.6)
        }
        present = pose != nil
        arrange()
        if shape != doing {
            doing = shape
            switch shape {
            case .scrolling: mark("\u{264A}\u{FE0E}")
            case .swiping: mark("\u{25B3}")
            case .zooming: mark("\u{2609}")
            case .pointing: mark(nil)
            }
        }
        if let swiped { shoot(swiped) }
        if restClicked {
            clickedByResting()
        } else if resting != restShown {
            restShown = resting
            if resting { windRest() } else { unwindRest() }
        }
        // Each step zoomed, the rings round the sight open out (in) or close in (out).
        if let zoomed {
            let out = zoomed > 0
            mark(out ? "\u{2295}" : "\u{2296}")
            spread(ring, from: out ? 0.35 : 1.25, to: out ? 1.25 : 0.35, peak: 0.7, turn: 0, duration: 0.5, delay: 0)
            spread(dottedRing, from: out ? 0.55 : 1.45, to: out ? 1.45 : 0.55, peak: 0.5, turn: out ? .pi / 8 : -.pi / 8, duration: 0.6, delay: 0.05)
        }
    }

    /// The joints, hung from the index fingertip, at a set size however near the hand is, eased a
    /// little.
    private func reshape(_ pose: HandPose) {
        let unit = Self.palm / max(pose.size, 0.01)
        if let tip = pose.tip { tipFromPalm = CGVector(dx: tip.x - pose.anchor.x, dy: tip.y - pose.anchor.y) }
        let origin = pose.tip ?? CGPoint(x: pose.anchor.x + tipFromPalm.dx, y: pose.anchor.y + tipFromPalm.dy)
        var seen = Set<Int>()
        for joint in pose.joints {
            guard let slot = TrackingReading.slots[joint.name] else { continue }
            seen.insert(slot)
            let target = CGPoint(x: (joint.point.x - origin.x) * pose.aspect * unit, y: (joint.point.y - origin.y) * unit)
            if let old = shape[slot], hypot(target.x - old.x, target.y - old.y) < 24 {
                shape[slot] = CGPoint(x: old.x + (target.x - old.x) * 0.6, y: old.y + (target.y - old.y) * 0.6)
            } else {
                shape[slot] = target
            }
            stars[slot].opacity = Float(Self.look(of: slot).light * (0.6 + 0.4 * Double(min(joint.confidence, 1))))
        }
        for slot in shape.indices where !seen.contains(slot) {
            shape[slot] = nil
            stars[slot].opacity = 0
        }
    }

    /// Everything where it goes, round the pointer.
    private func arrange() {
        guard let at else { return }
        let spot = place(at)
        for part in [sight, flare, ring, dottedRing, restRing] { part.position = spot }
        let points = shape.map { $0.map { place(CGPoint(x: at.x + $0.x, y: at.y + $0.y)) } }
        for (slot, point) in points.enumerated() {
            if let point { stars[slot].position = point }
        }
        // The lines, stopping short of each star, out from the wrist (so they draw on that way).
        let path = CGMutablePath()
        for (from, to) in TrackingReading.lines {
            guard let a = points[from], let b = points[to] else { continue }
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 7 else { continue }
            let unit = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
            path.move(to: CGPoint(x: a.x + unit.x * 3.5, y: a.y + unit.y * 3.5))
            path.addLine(to: CGPoint(x: b.x - unit.x * 3.5, y: b.y - unit.y * 3.5))
        }
        lines.path = path
        under.path = path

        // The name above and to the right of the figure, as a chart names its figures; what it
        // needs below the sight. Either goes to the left when there's no room to the right.
        let found = points.compactMap { $0 }
        let right = found.map(\.x).max() ?? spot.x, left = found.map(\.x).min() ?? spot.x
        let top = found.map(\.y).max() ?? spot.y
        let width = layer.bounds.width
        var x = right + 8
        if x + name.bounds.width > width - 8 { x = left - 8 - name.bounds.width }
        name.position = CGPoint(x: max(x, 8), y: min(top + 2, layer.bounds.height - name.bounds.height - 4))
        x = spot.x + 14
        if x + standing.bounds.width > width - 8 { x = spot.x - 14 - standing.bounds.width }
        standing.position = CGPoint(x: max(x, 8), y: max(spot.y - 14, standing.bounds.height + 4))
    }

    /// From the top-left measure the pointer uses to the layer's own (up from the bottom).
    private func place(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: layer.bounds.height - point.y) }

    private func press(_ pressed: Bool) {
        self.pressed = pressed
        let flash = CABasicAnimation(keyPath: "opacity")
        flash.fromValue = flare.presentation()?.opacity ?? flare.opacity
        flash.duration = pressed ? 0.1 : 0.25
        flare.opacity = pressed ? 1 : 0
        flare.add(flash, forKey: "opacity")
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = pressed ? 0.4 : 1
        grow.toValue = 1
        grow.duration = 0.18
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flare.add(grow, forKey: "grow")
        // The sight closes in while it's held.
        let close = CABasicAnimation(keyPath: "transform.scale")
        close.fromValue = sight.presentation()?.value(forKeyPath: "transform.scale") ?? (pressed ? 1 : 0.62)
        close.duration = 0.12
        sight.setValue(pressed ? 0.62 : 1, forKeyPath: "transform.scale")
        sight.add(close, forKey: "close")
    }

    private func fade(to opacity: Float, over duration: TimeInterval, after delay: TimeInterval = 0) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = body.presentation()?.opacity ?? body.opacity
        fade.duration = duration
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .backwards
        body.opacity = opacity
        body.add(fade, forKey: "fade")
    }

    // MARK: Flourishes

    /// Picking it up, at `point`: the figure draws itself on out from the wrist (its stars `born`,
    /// the pointer just picked up), a ring spreads from the sight, and its name's engraved by it a
    /// moment.
    func begin(at point: CGPoint?, needsAccess: Bool, born: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let point { at = point }
        layer.removeAllAnimations()
        body.removeAllAnimations()
        body.opacity = 1
        for part in [lines, under, sight] as [CALayer] { part.opacity = 1 }
        for core in cores {
            core.removeAllAnimations()
            core.opacity = 1
        }
        present = true
        doing = .pointing
        arrange()
        let now = CACurrentMediaTime()
        for (slot, star) in stars.enumerated() {
            let level = slot == 0 ? 0 : (slot - 1) % 4 + 1
            if born {
                bear(slot, from: now + 0.05 + Double(level) * 0.09)
                continue
            }
            let on = CABasicAnimation(keyPath: "opacity")
            on.fromValue = 0
            on.duration = 0.3
            on.beginTime = now + 0.12 + Double(level) * 0.08
            on.fillMode = .backwards
            star.add(on, forKey: "on")
        }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.duration = 0.55
        // Born, between the stars once they're lit.
        if born {
            draw.beginTime = now + 0.4
            draw.fillMode = .backwards
        }
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        lines.add(draw, forKey: "draw")
        under.add(draw, forKey: "draw")
        let arrive = CAAnimationGroup()
        arrive.animations = [Self.animation("transform.scale", from: 2.2, to: 1), Self.animation("opacity", from: 0, to: 1)]
        arrive.duration = 0.45
        arrive.timingFunction = CAMediaTimingFunction(name: .easeOut)
        sight.add(arrive, forKey: "arrive")
        spread(ring, from: 0.12, to: 1, peak: 0.75, turn: 0, duration: 0.9, delay: 0)
        spread(dottedRing, from: 0.3, to: 1.3, peak: 0.6, turn: .pi / 5, duration: 1.2, delay: 0.08)
        name.removeAllAnimations()
        name.opacity = 0
        marked = nil
        CATransaction.commit()
        self.needsAccess(needsAccess)
    }

    /// A star being born, from `start`: a faint cloud gathering in on where it'll be, motes falling
    /// into it, and the star lit in a flash as it collapses, settling to its own light.
    private func bear(_ slot: Int, from start: CFTimeInterval) {
        let star = stars[slot], core = cores[slot]
        let middle = CGPoint(x: star.bounds.midX, y: star.bounds.midY)
        let light = NSColor(Midnight.moonlight)
        let cloud = CAGradientLayer()
        cloud.type = .radial
        cloud.colors = [light.withAlphaComponent(0.36).cgColor, light.withAlphaComponent(0).cgColor]
        cloud.startPoint = CGPoint(x: 0.5, y: 0.5)
        cloud.endPoint = CGPoint(x: 1, y: 1)
        cloud.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
        cloud.position = middle
        cloud.opacity = 0
        star.insertSublayer(cloud, below: core)
        let gather = CAAnimationGroup()
        gather.animations = [Self.animation("transform.scale", from: 1.7, to: 0.15),
                             Self.keyframes("opacity", [0, 0.55, 0.45, 0], at: [0, 0.3, 0.75, 1])]
        gather.duration = 0.6
        gather.beginTime = start
        gather.timingFunction = CAMediaTimingFunction(name: .easeIn)
        cloud.add(gather, forKey: "gather")
        var made: [CALayer] = [cloud]
        let count = TrackingReading.tips.contains(slot) ? 4 : 3
        for index in 0..<count {
            let angle = Double(slot) * 2.39996 + Double(index) * 2 * .pi / Double(count)
            let distance = CGFloat(9 + 3 * ((slot + index) % 3))
            let from = CGPoint(x: middle.x + distance * cos(angle), y: middle.y + distance * sin(angle))
            let dot = mote(in: star, at: middle, below: core)
            let fall = CAAnimationGroup()
            fall.animations = [Self.animation("position", from: NSValue(point: from), to: NSValue(point: middle)),
                               Self.keyframes("opacity", [0, 0.8, 0.6, 0], at: [0, 0.3, 0.8, 1])]
            fall.duration = 0.5
            fall.beginTime = start + 0.03 * Double(index)
            fall.timingFunction = CAMediaTimingFunction(name: .easeIn)
            dot.add(fall, forKey: "fall")
            made.append(dot)
        }
        let lit = CAAnimationGroup()
        lit.animations = [Self.keyframes("transform.scale", [0.2, 0.2, 1.6, 1], at: [0, 0.55, 0.75, 1]),
                          Self.keyframes("opacity", [0, 0, 1, 1], at: [0, 0.5, 0.68, 1])]
        lit.duration = 0.8
        lit.beginTime = start
        lit.fillMode = .backwards
        core.add(lit, forKey: "born")
        Self.clear(made, after: start + 1 - CACurrentMediaTime())
    }

    /// Putting the pointer down: each star flares and bursts, faintly, throwing off a few sparks,
    /// as the lines and the sight fade and a ring goes out from it; then it's gone.
    func burst() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let now = CACurrentMediaTime()
        for part in [lines, under, sight] as [CALayer] {
            let fade = Self.animation("opacity", from: part.presentation()?.opacity ?? part.opacity, to: 0)
            fade.duration = 0.3
            part.opacity = 0
            part.add(fade, forKey: "fade")
        }
        var made: [CALayer] = []
        for (slot, star) in stars.enumerated() where star.opacity > 0 {
            let core = cores[slot]
            let middle = CGPoint(x: star.bounds.midX, y: star.bounds.midY)
            let start = now + Double(slot % 5) * 0.025
            core.removeAllAnimations()
            let flare = CAAnimationGroup()
            flare.animations = [Self.keyframes("transform.scale", [1, 1.9, 0.3], at: [0, 0.3, 1]),
                                Self.keyframes("opacity", [1, 1, 0], at: [0, 0.25, 1])]
            flare.duration = 0.5
            flare.beginTime = start
            flare.fillMode = .backwards
            core.opacity = 0
            core.add(flare, forKey: "burst")
            let count = TrackingReading.tips.contains(slot) ? 4 : 2
            for index in 0..<count {
                let angle = Double(slot) * 2.39996 + Double(index) * 2 * .pi / Double(count) + 0.4
                let distance = CGFloat(11 + 5 * ((slot + index) % 3))
                let to = CGPoint(x: middle.x + distance * cos(angle), y: middle.y + distance * sin(angle))
                let dot = mote(in: star, at: middle, below: core)
                let fly = CAAnimationGroup()
                fly.animations = [Self.animation("position", from: NSValue(point: middle), to: NSValue(point: to)),
                                  Self.animation("transform.scale", from: 1, to: 0.4),
                                  Self.keyframes("opacity", [0, 0.6, 0], at: [0, 0.15, 1])]
                fly.duration = 0.7
                fly.beginTime = start + 0.05
                fly.fillMode = .backwards
                fly.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dot.add(fly, forKey: "fly")
                made.append(dot)
            }
        }
        spread(ring, from: 0.25, to: 1.5, peak: 0.3, turn: 0, duration: 0.8, delay: 0.05)
        spread(dottedRing, from: 0.5, to: 1.8, peak: 0.22, turn: .pi / 6, duration: 1, delay: 0.1)
        fade(to: 0, over: 0.35, after: 0.75)
        mark(nil)
        needsAccess(false)
        CATransaction.commit()
        Self.clear(made, after: 1.2)
    }

    /// A mote of light, in `star` at `point`, under the star itself.
    private func mote(in star: CALayer, at point: CGPoint, below core: CALayer) -> CALayer {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 1.6, height: 1.6)
        dot.cornerRadius = 0.8
        dot.backgroundColor = NSColor(Midnight.starlight).cgColor
        dot.shadowColor = NSColor(Midnight.moonlight).cgColor
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 1.5
        dot.shadowOffset = .zero
        dot.position = point
        dot.opacity = 0
        dot.contentsScale = scale
        star.insertSublayer(dot, below: core)
        return dot
    }

    /// What a flourish made, gone once it's done with.
    private static func clear(_ layers: [CALayer], after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0)) {
            MainActor.assumeIsolated { layers.forEach { $0.removeFromSuperlayer() } }
        }
    }

    private static func keyframes(_ keyPath: String, _ values: [Any], at times: [NSNumber]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        return animation
    }

    /// Losing sight of the hand: the ring closes in on the sight as the figure fades, and the name
    /// says so.
    func finish() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade(to: 0, over: 0.7)
        spread(ring, from: 1.1, to: 0.1, peak: 0.7, turn: 0, duration: 0.75, delay: 0)
        spread(dottedRing, from: 1.4, to: 0.25, peak: 0.55, turn: -.pi / 5, duration: 0.9, delay: 0)
        mark(nil)
        needsAccess(false)
        CATransaction.commit()
    }

    /// Shows, or takes away, what it needs to press.
    func needsAccess(_ needed: Bool) {
        guard needed != asking else { return }
        asking = needed
        if needed { show(Self.askSymbol, on: standing) }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = standing.presentation()?.opacity ?? standing.opacity
        fade.duration = 0.4
        standing.opacity = needed ? 0.9 : 0
        standing.add(fade, forKey: "fade")
    }

    /// Wanting Accessibility to press: a padlock.
    private static var askSymbol: some View { symbol("lock") }

    /// The pointer resting: the ring of dots draws on round the sight as long as it takes to click.
    private func windRest() {
        let draw = Self.animation("strokeEnd", from: 0, to: 1)
        draw.duration = PointerTuning().restTime
        restRing.strokeEnd = 1
        restRing.opacity = 1
        restRing.add(draw, forKey: "draw")
    }

    /// Moved on before it clicked: the ring unwinds, quickly, from wherever it got to.
    private func unwindRest() {
        let undraw = Self.animation("strokeEnd", from: restRing.presentation()?.strokeEnd ?? restRing.strokeEnd, to: 0)
        undraw.duration = 0.25
        restRing.strokeEnd = 0
        restRing.add(undraw, forKey: "draw")
    }

    /// It clicked: the full ring spreads out and goes, and the sight's star flashes.
    private func clickedByResting() {
        restShown = false
        let spread = CAAnimationGroup()
        spread.animations = [Self.animation("transform.scale", from: 1, to: 1.6), Self.animation("opacity", from: 1, to: 0),
                             Self.animation("strokeEnd", from: 1, to: 1)]
        spread.duration = 0.45
        spread.timingFunction = CAMediaTimingFunction(name: .easeOut)
        restRing.strokeEnd = 0
        restRing.add(spread, forKey: "draw")
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 1, 0]
        flash.keyTimes = [0, 0.25, 1]
        flash.duration = 0.4
        flare.add(flash, forKey: "flash")
    }

    /// A swipe: a shooting star off the sight, the way the fingers went.
    private func shoot(_ direction: SwipeDirection) {
        guard let at else { return }
        let spot = place(at)
        // Up the layer is up the screen.
        let way: CGPoint
        switch direction {
        case .left: way = CGPoint(x: -1, y: 0)
        case .right: way = CGPoint(x: 1, y: 0)
        case .up: way = CGPoint(x: 0, y: 1)
        case .down: way = CGPoint(x: 0, y: -1)
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: spot.x + way.x * 16, y: spot.y + way.y * 16))
        path.addLine(to: CGPoint(x: spot.x + way.x * 110, y: spot.y + way.y * 110))
        streak.path = path
        // The head races out, the tail after it, and it's gone.
        let head = Self.animation("strokeEnd", from: 0, to: 1)
        head.duration = 0.32
        head.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let tail = Self.animation("strokeStart", from: 0, to: 1)
        tail.beginTime = 0.1
        tail.duration = 0.45
        tail.fillMode = .backwards
        tail.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let light = CAKeyframeAnimation(keyPath: "opacity")
        light.values = [0, 0.95, 0.7, 0]
        light.keyTimes = [0, 0.1, 0.6, 1]
        let group = CAAnimationGroup()
        group.animations = [head, tail, light]
        group.duration = 0.55
        streak.opacity = 0
        streak.add(group, forKey: "shoot")
    }

    /// A ring growing (or shrinking) from `from` to `to` times its size, turning `turn`, brightening
    /// to `peak` and gone again.
    private func spread(_ part: CAShapeLayer, from: CGFloat, to: CGFloat, peak: Float, turn: Double, duration: TimeInterval, delay: TimeInterval) {
        let scale = Self.animation("transform.scale", from: from, to: to)
        let rotation = Self.animation("transform.rotation.z", from: 0, to: turn)
        let light = CAKeyframeAnimation(keyPath: "opacity")
        light.values = [0, peak, peak * 0.6, 0]
        light.keyTimes = [0, 0.18, 0.6, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, rotation, light]
        group.duration = duration
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        part.opacity = 0
        part.add(group, forKey: "spread")
    }

    /// `sign` engraved by the figure for as long as it's doing that (nil: none), coming on and
    /// going off softly.
    private func mark(_ sign: String?) {
        guard sign != marked else { return }
        marked = sign
        if let sign { show(Self.sign(sign), on: name) }
        let fade = Self.animation("opacity", from: name.presentation()?.opacity ?? name.opacity, to: sign == nil ? 0 : 0.92)
        fade.duration = sign == nil ? 0.5 : 0.2
        name.opacity = sign == nil ? 0 : 0.92
        name.add(fade, forKey: "fade")
        arrange()
    }

    private func show(_ picture: some View, on label: CALayer) {
        guard let image = Self.bitmap(of: picture, scale: scale) else { return }
        label.contents = image
        label.contentsScale = scale
        label.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    private static func animation(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    // MARK: Pictures

    /// An astronomical sign, engraved in light, as a star chart marks its figures.
    static func sign(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .light, design: .serif))
            .foregroundStyle(Midnight.white.opacity(0.92))
            .shadow(color: Midnight.ink.opacity(0.9), radius: 2)
            .padding(4)
            .fixedSize()
    }

    /// A symbol, engraved the same way.
    static func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .light))
            .foregroundStyle(Midnight.white.opacity(0.9))
            .shadow(color: Midnight.ink.opacity(0.9), radius: 2)
            .padding(4)
            .fixedSize()
    }

    /// The stars' pictures, by size and scale (kept with the figure, so they go when it does).
    private var starPictures: [String: (CGImage?, CGSize)] = [:]

    /// A faint pool of the night's ink under something drawn in light, so it reads over a light
    /// window as well as a dark one (where it can't be seen).
    static func shade(at point: CGPoint, radius: CGFloat, in canvas: GraphicsContext) {
        canvas.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)),
                    with: .radialGradient(Gradient(colors: [Midnight.ink.opacity(0.5), Midnight.ink.opacity(0)]),
                                          center: point, startRadius: 0, endRadius: radius))
    }

    /// The pointer's hot spot: a fine ring with four ticks out from it, and a pinprick at its
    /// middle, over a faint shade.
    private static func sight(at point: CGPoint, in canvas: GraphicsContext) {
        shade(at: point, radius: 15, in: canvas)
        var sight = Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
        for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 2) {
            sight.move(to: CGPoint(x: point.x + cos(angle) * 8.5, y: point.y + sin(angle) * 8.5))
            sight.addLine(to: CGPoint(x: point.x + cos(angle) * 12, y: point.y + sin(angle) * 12))
        }
        canvas.stroke(sight, with: .color(Midnight.ink.opacity(0.45)), lineWidth: 2.4)
        canvas.stroke(sight, with: .color(Midnight.white.opacity(0.9)), lineWidth: 0.85)
        canvas.fill(Path(ellipseIn: CGRect(x: point.x - 0.9, y: point.y - 0.9, width: 1.8, height: 1.8)), with: .color(Midnight.white))
    }

    /// The band's star (`HandSky.star`), as a picture, over a faint shade.
    private func starPicture(radius: CGFloat, glint: CGFloat, light: Double, scale: CGFloat) -> (CGImage?, CGSize) {
        let key = "\(radius) \(glint) \(light) \(scale)"
        if let picture = starPictures[key] { return picture }
        let side = ((max(radius * 4.5, glint) + 1) * 2).rounded(.up)
        let image = Self.bitmap(of: Canvas { canvas, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            Self.shade(at: center, radius: radius * 4, in: canvas)
            HandSky.star(at: center, radius: radius, glint: glint, light: light, in: canvas)
        }
        .frame(width: side, height: side), scale: scale)
        let picture = (image, CGSize(width: side, height: side))
        starPictures[key] = picture
        return picture
    }

    /// `view` drawn into a bitmap at `scale`, laid out as Core Animation shows one.
    static func bitmap(of view: some View, scale: CGFloat) -> CGImage? {
        var image: CGImage?
        ImageRenderer(content: view).render { size, render in
            let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
            guard width > 0, height > 0, let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            context.scaleBy(x: scale, y: scale)
            render(context)
            image = context.makeImage()
        }
        return image
    }
}

/// Where the hands are put down without the sign: a small sundial engraved in the top bar, just
/// left of the band's page, there while the hands are the pointer, its gnomon standing in it
/// pointing to noon. Resting the pointer on it a moment puts them down: the gnomon's shadow goes
/// round the dial, a ring of dots drawing on after it, and once it's come round, the dial flares
/// and goes. Moving off before then, it unwinds.
@MainActor
final class PointerDial {
    /// Placed by its middle.
    let layer = CALayer()
    var scale: CGFloat = 2 {
        didSet { if scale != oldValue { paint() } }
    }

    /// How long the pointer rests on it, and how bright it is meanwhile.
    static let dwell: TimeInterval = 1.1
    static let idle: Float = 0.62

    private let face = CALayer()
    private let shadow = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var restingSince: TimeInterval?

    init() {
        let side: CGFloat = 36, middle = CGPoint(x: side / 2, y: side / 2)
        layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        layer.opacity = 0
        for part in [face, shadow, ring] {
            part.frame = layer.bounds
            layer.addSublayer(part)
        }
        // The gnomon's shadow, from the middle out to the hours (up the layer is up the screen),
        // turning round it.
        let line = CGMutablePath()
        line.move(to: middle)
        line.addLine(to: CGPoint(x: middle.x, y: middle.y + 8.4))
        shadow.path = line
        shadow.strokeColor = NSColor(Midnight.moonlight).withAlphaComponent(0.85).cgColor
        shadow.lineWidth = 1
        shadow.lineCap = .round
        shadow.opacity = 0
        // The dots after it: from noon, clockwise.
        let round = CGMutablePath()
        round.addArc(center: middle, radius: 13, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        ring.path = round
        ring.fillColor = nil
        ring.strokeColor = NSColor(Midnight.white).withAlphaComponent(0.9).cgColor
        ring.lineWidth = 1.3
        ring.lineCap = .round
        ring.lineDashPattern = [0.01, 2.8]
        ring.strokeEnd = 0
        paint()
    }

    private func paint() {
        for part in [layer, face, shadow, ring] { part.contentsScale = scale }
        let side = layer.bounds.width
        face.contents = PointerFigure.bitmap(of: Canvas { canvas, size in
            Self.dial(at: CGPoint(x: size.width / 2, y: size.height / 2), in: canvas)
        }
        .frame(width: side, height: side), scale: scale)
    }

    /// Engraved on as the hands are picked up, turning in.
    func begin() {
        restingSince = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in [layer, ring, shadow] { part.removeAllAnimations() }
        ring.strokeEnd = 0
        shadow.opacity = 0
        layer.opacity = Self.idle
        let arrive = CAAnimationGroup()
        arrive.animations = [Self.animation("opacity", from: 0, to: Self.idle), Self.animation("transform.scale", from: 0.4, to: 1),
                             Self.animation("transform.rotation.z", from: 0.9, to: 0)]
        arrive.duration = 0.8
        arrive.beginTime = CACurrentMediaTime() + 0.3
        arrive.fillMode = .backwards
        arrive.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(arrive, forKey: "arrive")
        CATransaction.commit()
    }

    /// Whether the pointer's on it, at `time`: true once it's rested there long enough.
    func rest(_ on: Bool, at time: TimeInterval) -> Bool {
        guard on else {
            if restingSince != nil {
                restingSince = nil
                unwind()
            }
            return false
        }
        guard let since = restingSince else {
            restingSince = time
            wind()
            return false
        }
        return time - since >= Self.dwell
    }

    /// The pointer's come to rest on it: it brightens, and the shadow sets off round it, the dots
    /// after.
    private func wind() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade(layer, to: 1, over: 0.2)
        shadow.opacity = 1
        let turn = Self.animation("transform.rotation.z", from: 0, to: -2 * Double.pi)
        turn.duration = Self.dwell
        shadow.add(turn, forKey: "turn")
        let draw = Self.animation("strokeEnd", from: 0, to: 1)
        draw.duration = Self.dwell
        ring.strokeEnd = 1
        ring.add(draw, forKey: "draw")
        CATransaction.commit()
    }

    /// Moved off: it unwinds, quickly, from wherever it got to.
    private func unwind() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let reached = ring.presentation()?.strokeEnd ?? 0
        ring.strokeEnd = 0
        let undraw = Self.animation("strokeEnd", from: reached, to: 0)
        undraw.duration = 0.3
        ring.add(undraw, forKey: "draw")
        shadow.removeAnimation(forKey: "turn")
        fade(shadow, to: 0, over: 0.2)
        fade(layer, to: Self.idle, over: 0.4)
        CATransaction.commit()
    }

    /// The hand's put down: rested on, it flares and goes; put down some other way, it fades.
    func finish() {
        let rested = restingSince != nil
        restingSince = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if rested {
            let flare = CAAnimationGroup()
            flare.animations = [Self.animation("transform.scale", from: 1, to: 1.8),
                                Self.animation("opacity", from: layer.presentation()?.opacity ?? 1, to: 0)]
            flare.duration = 0.7
            flare.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.opacity = 0
            layer.add(flare, forKey: "flare")
        } else {
            fade(layer, to: 0, over: 0.5)
        }
        CATransaction.commit()
    }

    private func fade(_ part: CALayer, to opacity: Float, over duration: TimeInterval) {
        let fade = Self.animation("opacity", from: part.presentation()?.opacity ?? part.opacity, to: opacity)
        fade.duration = duration
        part.opacity = opacity
        part.add(fade, forKey: "fade")
    }

    private static func animation(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    /// The dial: a rim with the hours round it, the gnomon standing in it pointing to noon, over a
    /// faint shade, and a small star off to one side.
    static func dial(at center: CGPoint, in canvas: GraphicsContext) {
        PointerFigure.shade(at: center, radius: 17, in: canvas)
        let rim = Path(ellipseIn: CGRect(x: center.x - 9.5, y: center.y - 9.5, width: 19, height: 19))
        canvas.stroke(rim, with: .color(Midnight.ink.opacity(0.45)), lineWidth: 2.4)
        canvas.stroke(rim, with: .color(Midnight.silver.opacity(0.9)), lineWidth: 0.8)
        var hours = Path()
        for hour in 0..<12 {
            let angle = Double(hour) / 12 * 2 * .pi, inner: CGFloat = hour % 3 == 0 ? 5.6 : 7.3
            let out = CGPoint(x: sin(angle), y: -cos(angle))
            hours.move(to: CGPoint(x: center.x + out.x * inner, y: center.y + out.y * inner))
            hours.addLine(to: CGPoint(x: center.x + out.x * 8.7, y: center.y + out.y * 8.7))
        }
        canvas.stroke(hours, with: .color(Midnight.white.opacity(0.7)), lineWidth: 0.6)
        var gnomon = Path()
        gnomon.move(to: CGPoint(x: center.x - 1.4, y: center.y + 0.8))
        gnomon.addLine(to: CGPoint(x: center.x, y: center.y - 7.8))
        gnomon.addLine(to: CGPoint(x: center.x + 1.4, y: center.y + 0.8))
        gnomon.closeSubpath()
        canvas.fill(gnomon, with: .color(Midnight.white.opacity(0.95)))
        HandSky.star(at: CGPoint(x: center.x + 12.5, y: center.y - 10), radius: 0.8, glint: 4.5, light: 0.85, in: canvas)
    }
}
