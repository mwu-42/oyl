import AppKit
import AVFoundation
import Combine
import CoreImage
import os
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// Hand shapes Oyl recognizes on the camera.
enum HandGesture {
    case openPalm
    case pointLeft, pointRight
    case horns     // 🤟, horns with the thumb out: keeps the Mac awake
    case pinky     // just the little finger out, the thumb in: shows the lyrics; looked for only when there are some
    case pinch     // turned like a knob for volume; with the pinky up, dragged sideways to scrub through the song
    case peace     // takes a selfie
    case ok        // stops watching
    case thumbsUp  // approves an agent's request; looked for only while one is waiting
    case announce  // the thumb holding the ring finger down, the other three up: every Oyl says what it's doing
    case tiltLeft  // that same hand tipped over to the left: Oyls dash left and line up (or come back)
    case tiltRight // tipped over to the right: Oyls dash off to the right (or stop lining up)
    case rock      // the rock sign, the thumb and little finger out: in Midnight Oyl, makes the hand the pointer, or a hand again (see `PointerMode`)
    case fist      // does nothing, but is told apart from the rest (and lets go of the pointer's press)

    var symbol: String {
        switch self {
        case .openPalm: return "hand.raised.fill"
        case .pointLeft: return "hand.point.left.fill"
        case .pointRight: return "hand.point.right.fill"
        case .pinch: return "hand.pinch.fill"
        case .thumbsUp: return "hand.thumbsup.fill"
        // There are no symbols for these shapes; these say what they do.
        case .horns: return AwakePage.symbol
        case .pinky: return "quote.bubble.fill"
        case .peace: return "camera.fill"
        case .ok: return "video.slash.fill"
        case .announce: return "megaphone.fill"
        case .tiltLeft: return "arrow.left.to.line"
        case .tiltRight: return "eye.circle.fill"
        case .rock: return "cursorarrow.rays"
        case .fist: return "hand.raised.slash.fill"
        }
    }

    /// What Midnight Oyl's tracking display calls it.
    var name: String {
        switch self {
        case .openPalm: return "open palm"
        case .pointLeft: return "point left"
        case .pointRight: return "point right"
        case .horns: return "horns"
        case .pinky: return "pinky"
        case .pinch: return "pinch"
        case .peace: return "peace"
        case .ok: return "ok"
        case .thumbsUp: return "thumbs up"
        case .announce: return "announce"
        case .tiltLeft: return "tilt left"
        case .tiltRight: return "tilt right"
        case .rock: return "rock"
        case .fist: return "fist"
        }
    }

    /// How long the shape has to be held before it counts. A pinch is a knob, so it grabs
    /// quickly; OK ends watching, so it asks for a slightly longer hold, and a selfie a longer one
    /// still, so it isn't taken by a passing hand.
    var holdTime: TimeInterval {
        switch self {
        case .pinch: return 0.25
        case .ok: return 0.45
        case .peace: return 0.9
        case .tiltLeft, .tiltRight: return 0.5
        default: return 0.4
        }
    }
}

extension NotchState {
    /// What each gesture does.
    func perform(_ gesture: HandGesture) {
        switch gesture {
        case .openPalm:
            // A raised hand stops the alarm if one's ringing; otherwise it plays or pauses.
            if timers.ringing != nil { timers.dismissRinging() } else { nowPlaying.togglePlayPause() }
        case .pointRight:
            nowPlaying.next()
        case .pointLeft:
            nowPlaying.previous()
        case .horns:
            if awake.isActive { awake.stop() } else { awake.startUsual() }
        case .pinky:
            // The lyrics, and the music Oyl on the menu bar singing them.
            toggleLyrics()
        case .pinch, .peace, .ok, .thumbsUp, .announce, .tiltLeft, .tiltRight, .rock, .fist:
            // Handled elsewhere: GestureWatcher has a pinch call turn(by:) or scrub(by:), peace
            // take a selfie, OK stop watching, a thumbs up approve and the rock sign make the hand
            // the pointer; the Oyls on the menu bar (NotchController) take the rest.
            break
        }
    }

    /// A pinch turned like a knob: clockwise is louder, and a quarter turn covers about half
    /// the range.
    func turn(by radians: Double) {
        let output = nowPlaying.output
        let before = output.volume
        output.set(before + radians * 0.35)
        // A tick every 10%, like pulling on the cover.
        if Int((before * 10).rounded()) != Int((output.volume * 10).rounded()) {
            Haptics.perform(.alignment, performanceTime: .now)
        }
    }

    /// A pinch dragged sideways and let go: jump that far through the song.
    func scrub(by seconds: Double) {
        guard let track = nowPlaying.track else { return }
        let target = nowPlaying.position(at: Date()) + seconds
        nowPlaying.seek(to: min(max(target, 0), max(track.duration - 1, 0)))
    }
}

/// Watches the camera for hand gestures while the pointer is over the open notch (until you hold
/// up an OK), and for a thumbs up while an agent waits for your OK. In Midnight Oyl, the rock 'n'
/// roll sign (the thumb and little finger out) makes the hand the pointer, all over the screen,
/// until it's made again (see `PointerMode`). The camera, and so its green light, is on only while
/// watching. (macOS keeps the light on for at least three seconds after the camera starts, however
/// briefly it runs.)
@MainActor
final class GestureWatcher: ObservableObject {
    struct Sighting: Equatable {
        let id = UUID()
        let gesture: HandGesture
    }

    /// Selfies go in ~/Pictures/Oyl: you, and beside you your screen as it was.
    static let selfies = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Oyl", isDirectory: true)
    /// A soft chime rather than a shutter's clack.
    private static let shutter = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/siri/jbl_confirm.caf",
        byReference: true)

    /// The toggle at the top right of the open notch. Off, the camera never turns on.
    @Published var isEnabled = UserDefaults.standard.object(forKey: "gestures.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "gestures.enabled")
            if !isEnabled { endPointing() }
            update()
        }
    }
    @Published private(set) var isWatching = false
    /// A pinch is held and working the volume (or hasn't been moved yet).
    @Published private(set) var isTurning = false
    /// How far a sideways pinch has scrubbed, in seconds, while it's held.
    @Published private(set) var scrubOffset: Double?
    /// The gesture just acted on, shown for a moment.
    @Published private(set) var sighting: Sighting?

    /// The pointer is over the open notch: all gestures count.
    var hovering = false { didSet { if hovering != oldValue { update() } } }
    /// An agent is waiting for your OK: a thumbs up counts, wherever the pointer is.
    var approving = false { didSet { if approving != oldValue { update() } } }
    /// The mirror's showing: the camera's on for it, gestures or no (and read for them only when
    /// they're on).
    var mirroring = false {
        didSet {
            guard mirroring != oldValue else { return }
            // The camera's picture is fed only while something shows it: the mirror. (Midnight
            // Oyl reads the hands but shows no picture.)
            preview?.connection?.isEnabled = mirroring
            update()
        }
    }
    /// Midnight Oyl's band is open: with gestures on, the camera's on for it, read for hands
    /// whatever, for the hands' constellation (acted on only when gestures count). With them off,
    /// it stays off, so nothing's looked for, the rock sign neither.
    var displaying = false {
        didSet {
            guard displaying != oldValue else { return }
            update()
        }
    }
    /// Oyl's resting (the lid's shut, or it's switched off): the camera stays off whatever's
    /// wanted, and the hand's put down as the pointer.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended { endPointing() }
            update()
        }
    }
    /// An OK was held up with the bloom open: gestures stop counting, but the camera stays on for
    /// the bloom, until watching starts afresh.
    private var dismissed = false
    /// The camera's picture, for the mirror (or Midnight Oyl's bloom) to show, once it's been set
    /// up.
    @Published private(set) var preview: AVCaptureVideoPreviewLayer?
    /// The song has lyrics, so a pinky out (which shows them) is worth looking for.
    var lyricsAvailable = false { didSet { camera?.lookForPinky(lyricsAvailable) } }
    /// Midnight Oyl is the look, so the rock sign makes the hand the pointer. Switching away puts
    /// the pointer down.
    var midnight = false {
        didSet {
            guard midnight != oldValue else { return }
            if !midnight { endPointing() }
        }
    }

    var onGesture: (HandGesture) -> Void = { _ in }
    /// Clockwise turns of a held pinch, in radians.
    var onTurn: (Double) -> Void = { _ in }
    /// A sideways pinch let go, with how far it went, in seconds.
    var onScrub: (Double) -> Void = { _ in }
    var onApprove: () -> Void = {}
    /// A selfie's been saved here (you and your screen), and the camera's picture of you, for
    /// its Oyl to hold up.
    var onSelfie: (URL, NSImage) -> Void = { _, _ in }

    private static let releaseTime = 0.4      // no shape counts once it's held this long, too
    private static let scrubPerWidth = 120.0  // seconds for a pinch dragged across the whole picture
    private static let favorPinch = 3.0       // after a pinch, how long another one comes easier

    private enum Grip { case knob, scrub }

    private var wanted = false
    private var cameraOff: DispatchWorkItem?
    private var candidate: HandGesture?
    private var candidateSince: TimeInterval = 0
    private var held: HandGesture?
    /// The announce shape's announcement, waiting a moment in case the hand is on its way to
    /// tipping over (a tilt, which mustn't announce too).
    private var pendingAnnounce: DispatchWorkItem?
    /// After a tilt, the hand has to come back upright (or go) before another tilt counts, and
    /// coming back upright doesn't announce.
    private var tiltArmed = true
    private var announceQuiet = false
    private var grip: Grip?                                // nil until the pinch is turned or dragged
    private var gripAnchor: (angle: Double, x: CGFloat)?  // nil while the fingers are apart
    private var pinchFavoredUntil: TimeInterval = 0
    /// Made when first needed, and let go half a minute after it stops, so the hand model and
    /// the camera's buffers don't sit in memory between uses.
    private var camera: HandCamera?
    private var cameraRelease: DispatchWorkItem?
    /// The hand as the pointer, and the rock sign that turns it on and off.
    private let pointer: PointerMode
    private var rock = RockSign()
    /// Just after the pointer's put down: the shape the hand's in then doesn't act, only the next.
    private var quietUntil: TimeInterval = 0

    private var pointerSwitch: AnyCancellable?

    init() {
        pointer = PointerMode()
        // No hand for a while: it's put down by itself.
        pointer.ended = { [weak self] in self?.pointerEnded() }
        // Turned off with the pointer in hand: it's put down.
        pointerSwitch = Features.shared.changed
            .filter { $0 == (.rockGesture, false) }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.endPointing() } }
    }

    private func liveCamera() -> HandCamera {
        if let camera { return camera }
        let camera = HandCamera { [weak self] reading, hands, time in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.saw(reading, hands, at: time) }
            }
        }
        camera.lookForPinky(lyricsAvailable)
        camera.read(reading || showingHands || pointer.isOn)
        camera.display(showingHands)
        camera.point(pointer.isOn)
        camera.previewReady = { [weak self] preview in
            MainActor.assumeIsolated {
                guard let self else { return }
                preview.connection?.isEnabled = self.mirroring
                self.preview = preview
            }
        }
        self.camera = camera
        return camera
    }

    /// Gestures count: they're on, and the pointer's over the open notch or an OK's wanted.
    private var reading: Bool { isEnabled && (hovering || approving) }

    /// The band's up to show the hands in, and gestures are on.
    private var showingHands: Bool { displaying && isEnabled }

    /// Watches while hovering or approving (or with the mirror up, the band open with gestures on
    /// or the hand the pointer), and stops once none is true, or Oyl's resting.
    private func update() {
        let pointing = pointer.isOn
        camera?.read(reading || showingHands || pointing)
        camera?.display(showingHands)
        camera?.point(pointing)
        if !isSuspended && (reading || mirroring || showingHands || pointing) { watch() } else { stop() }
    }

    /// The rock sign counts: in Midnight Oyl, with gestures on, while the band's up or the pointer's
    /// in hand (wherever it's pointing then).
    private var rockCounts: Bool {
        midnight && isEnabled && Feature.rockGesture.isOn && !dismissed && (pointer.isOn || displaying || hovering)
    }

    /// The hand becomes the pointer: what it was doing as a gesture is let go, and the camera stays
    /// on, reading every frame, until it's put down.
    private func startPointing(with pose: HandPose?, at time: TimeInterval) {
        hold(nil)
        candidate = nil
        pendingAnnounce?.cancel()
        pendingAnnounce = nil
        pointer.start(with: pose, at: time)
        update()
    }

    private func endPointing() {
        guard pointer.isOn else { return }
        pointer.end()
        pointerEnded()
    }

    /// The pointer's down: gestures pick up again once the hand's made a new shape, and the camera
    /// goes back to its usual rules.
    private func pointerEnded() {
        quietUntil = ProcessInfo.processInfo.systemUptime + 1.2
        candidate = nil
        hold(nil)
        update()
    }

    /// Starts the camera, asking for it the first time.
    private func watch() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized || status == .notDetermined, HandCamera.device != nil else { return }
        wanted = true
        if status == .authorized {
            begin()
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Only if it's still wanted by the time you answer.
                    guard granted, let self, self.wanted else { return }
                    self.begin()
                }
            }
        }
    }

    /// Stops acting on gestures now, and turns the camera off after `delay`. Watching again
    /// sooner picks up at once, without waiting for the camera to start.
    func stop(after delay: TimeInterval = 0) {
        wanted = false
        hold(nil)
        pendingAnnounce?.cancel()
        pendingAnnounce = nil
        guard isWatching else { return }
        isWatching = false
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cameraOff = nil
                self.camera?.stop()
                let release = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        if self?.isWatching == false {
                            self?.camera = nil
                            self?.preview = nil
                        }
                    }
                }
                self.cameraRelease = release
                DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: release)
            }
        }
        cameraOff = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func begin() {
        cameraOff?.cancel()
        cameraOff = nil
        cameraRelease?.cancel()
        cameraRelease = nil
        candidate = nil
        hold(nil)
        dismissed = false
        if !isWatching { isWatching = true }
        liveCamera().start()
    }

    /// One camera frame's reading, nil when there's no hand or no shape Oyl knows; and the hands as
    /// a pointer would follow them, the nearer first; read at `time`.
    private func saw(_ reading: HandShape.Reading?, _ hands: [HandPose], at time: TimeInterval) {
        guard isWatching else { return }
        let pose = hands.first
        // The rock sign picks the pointer up, or puts it down.
        if rockCounts {
            if rock.take(pose, at: time) {
                if pointer.isOn { endPointing() } else { startPointing(with: pose, at: time) }
                return
            }
        } else {
            rock.reset()
        }
        // With the pointer in hand, nothing else the hand does counts.
        if pointer.isOn {
            pointer.take(hands, at: time)
            return
        }
        guard self.reading, !dismissed else { return }
        let gesture = reading?.gesture
        let now = ProcessInfo.processInfo.systemUptime
        if gesture != candidate {
            candidate = gesture
            candidateSince = now
        }
        // Just after the pointer's put down, the shape the hand's in (the sign that put it down,
        // or the hand opening after) is taken as held without acting.
        if now < quietUntil {
            if candidate != held { hold(candidate) }
            return
        }
        // A tilt that lasts (not one misread frame) means the hand was on its way over.
        if isTilt(candidate), now - candidateSince >= 0.15 {
            pendingAnnounce?.cancel()
            pendingAnnounce = nil
        }
        // A shape has to settle before it counts, so passing through one on the way to another
        // (or a single misread frame) does nothing. Lowering the hand settles on nil, which is
        // how the same gesture acts twice. Just after a pinch, another one settles sooner.
        let holdTime = candidate == .pinch && now < pinchFavoredUntil ? 0.12 : candidate?.holdTime ?? Self.releaseTime
        if candidate != held, now - candidateSince >= holdTime {
            hold(candidate)
            if let held { fire(held) }
        }
        if held == .pinch, hovering {
            if let reading, reading.gesture == .pinch { follow(reading) } else { gripAnchor = nil }
        }
    }

    private func hold(_ gesture: HandGesture?) {
        if held == .pinch, gesture != .pinch {
            if let scrubOffset { onScrub(scrubOffset) }
            pinchFavoredUntil = ProcessInfo.processInfo.systemUptime + Self.favorPinch
            camera?.favorPinch(until: pinchFavoredUntil)
        }
        held = gesture
        grip = nil
        gripAnchor = nil
        if gesture == nil {
            // The hand's gone: start afresh.
            tiltArmed = true
            announceQuiet = false
        }
        if scrubOffset != nil { scrubOffset = nil }
        let turning = gesture == .pinch && hovering
        if isTurning != turning { isTurning = turning }
    }

    /// Follows the held pinch. Turned, it's a volume knob; with the pinky up and dragged
    /// sideways, it scrubs through the song, and jumps there when let go (the pinky keeps a
    /// knob that drifts sideways from scrubbing). Parting the fingers, even for a moment, lets go
    /// of it, so you can move your hand back and grab again to keep going, as you would with a
    /// real knob.
    private func follow(_ reading: HandShape.Reading) {
        guard Feature.pinchGesture.isOn else { return }
        guard var anchor = gripAnchor else {
            gripAnchor = (reading.angle, reading.x)
            return
        }
        let turned = remainder(reading.angle - anchor.angle, 2 * .pi)
        let moved = reading.x - anchor.x
        if grip == nil {
            if reading.pinky {
                guard abs(moved) > 0.04 else { return }
                grip = .scrub
                if isTurning { isTurning = false }
            } else if abs(turned) > 0.12 {
                grip = .knob
            } else {
                return
            }
        }
        switch grip {
        case .knob:
            // Eased, and wobbles of a degree or so ignored, so a still hand leaves the volume be.
            guard abs(turned) > 0.02 else { return }
            let step = turned * 0.5
            anchor.angle += step
            // The picture is mirrored, so a clockwise turn as you see it lowers the angle.
            onTurn(-step)
        case .scrub:
            anchor.x = reading.x
            scrubOffset = (scrubOffset ?? 0) + Double(moved) * Self.scrubPerWidth
        case nil:
            break
        }
        gripAnchor = anchor
    }

    private func fire(_ gesture: HandGesture) {
        // One that's been turned off does nothing.
        if let feature = Feature(gesture), !feature.isOn { return }
        // Without the pointer over the notch, the camera is only on for a thumbs up.
        switch gesture {
        case .thumbsUp:
            guard approving else { return }
            onApprove()
        case _ where !hovering:
            return
        case .ok:
            // The bloom shows the camera always, so with it open, only the gestures stop.
            if displaying { dismissed = true } else { stop() }
        case .peace:
            takeSelfie()
        case .pinch:
            Haptics.perform(.levelChange, performanceTime: .now)
            return  // moving it does the work, and the indicator shows it while held
        case .announce:
            // Back upright after a tilt: that's to allow the next tilt, not to announce.
            guard !announceQuiet else {
                tiltArmed = true
                return
            }
            armAnnounce(after: 0.3)
            return
        case .tiltLeft, .tiltRight:
            guard tiltArmed else { return }
            tiltArmed = false
            announceQuiet = true
            onGesture(gesture)
        case .rock, .fist:
            return  // the rock sign's seen to in `saw`; a fist does nothing
        default:
            onGesture(gesture)
        }
        acknowledge(gesture)
    }

    private func isTilt(_ gesture: HandGesture?) -> Bool { gesture == .tiltLeft || gesture == .tiltRight }

    /// The announcement, after `delay`, unless a tilt comes first (if one's just begun when it's
    /// due, it waits a little longer to see).
    private func armAnnounce(after delay: TimeInterval) {
        pendingAnnounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingAnnounce = nil
                guard self.hovering else { return }
                if self.isTilt(self.candidate) {
                    if ProcessInfo.processInfo.systemUptime - self.candidateSince < 0.15 { self.armAnnounce(after: 0.2) }
                    return
                }
                self.onGesture(.announce)
                self.acknowledge(.announce)
            }
        }
        pendingAnnounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A tap of the trackpad, and the gesture's symbol shown for a moment.
    private func acknowledge(_ gesture: HandGesture) {
        Haptics.perform(.levelChange, performanceTime: .now)
        let sighting = Sighting(gesture: gesture)
        self.sighting = sighting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                if self?.sighting == sighting { self?.sighting = nil }
            }
        }
    }

    private func takeSelfie() {
        try? FileManager.default.createDirectory(at: Self.selfies, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = Self.selfies.appendingPathComponent("Selfie \(formatter.string(from: Date())).jpg")
        // The screen's taken right away, as it is at the shutter; the camera's a moment later.
        let screen = Task { await SelfieFile.screenshot() }
        camera?.takePhoto { [weak self] photo in
            Task { @MainActor in
                let shot = await screen.value
                let saved = await Task.detached(priority: .userInitiated) { SelfieFile.save(photo, beside: shot, to: url) }.value
                if saved { self?.onSelfie(url, NSImage(cgImage: photo, size: .zero)) }
            }
        }
        Self.shutter?.stop()
        Self.shutter?.play()
    }
}

/// What a selfie's saved as: the camera's picture and the screen's side by side, as one JPEG.
private enum SelfieFile {
    /// The screen under the pointer (the one with the notch, as you make the sign over it), as
    /// it is without Oyl's own windows over it. Nil if Screen Recording isn't allowed.
    @MainActor
    static func screenshot() async -> CGImage? {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let scale = screen.backingScaleFactor
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { return nil }
        let oyl = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingApplications: oyl, exceptingWindows: []),
            configuration: configuration)
    }

    /// You on the left and the screen on the right, the same height, on black: tall enough for
    /// the screen to read (up to 1440 pixels, or the camera's own height if that's more). Without
    /// a screenshot, just you.
    static func save(_ photo: CGImage, beside screen: CGImage?, to url: URL) -> Bool {
        let height = screen.map { max(photo.height, min($0.height, 1440)) } ?? photo.height
        func width(_ image: CGImage) -> Int { Int((Double(image.width) * Double(height) / Double(image.height)).rounded()) }
        let gap = screen == nil ? 0 : height / 60
        let total = width(photo) + gap + (screen.map(width) ?? 0)
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: total, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: total, height: height))
        context.draw(photo, in: CGRect(x: 0, y: 0, width: width(photo), height: height))
        if let screen {
            context.draw(screen, in: CGRect(x: width(photo) + gap, y: 0, width: width(screen), height: height))
        }
        guard let combined = context.makeImage(),
              let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(file, combined, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(file)
    }
}

/// The camera and the hand-pose model. Starting the camera blocks, so it runs on its own queue;
/// frames arrive on another.
private final class HandCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static var device: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
    }

    private let control = DispatchQueue(label: "oyl.Gestures")
    private let frames = DispatchQueue(label: "oyl.Gestures.Frames", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let request = VNDetectHumanHandPoseRequest()
    private let report: @Sendable (HandShape.Reading?, [HandPose], TimeInterval) -> Void
    private let pictures = CIContext()
    /// Set at once from the main thread, so a stop that comes while the start is still queued
    /// keeps the camera from coming on at all.
    private let wanted = OSAllocatedUnfairLock(initialState: false)
    private var configured = false
    // Small frames are plenty for finding a hand; a selfie gets full size.
    private static let tracking = AVCaptureSession.Preset.vga640x480
    private var photoTaken: (@Sendable (CGImage) -> Void)?  // told the next settled frame; frames queue only
    private var photoSettling = 0  // frames to let go by at full size first; frames queue only
    private var lastRead: TimeInterval = 0  // frames queue only
    private var eagerUntil: TimeInterval?   // frames queue only: see captureOutput
    // Frames queue only: how long the hand model takes a frame, how many frames it reads a
    // second, and how busy the Mac is.
    private var modelTime: TimeInterval = 0
    private var rate = 0.0
    private var load = (busy: UInt64(0), total: UInt64(0), checked: TimeInterval(0), fraction: 0.0)
    private let pinchFavoredUntil = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)
    private let pinkyWanted = OSAllocatedUnfairLock(initialState: false)
    private let reading = OSAllocatedUnfairLock(initialState: true)
    private let displaying = OSAllocatedUnfairLock(initialState: false)
    private let pointing = OSAllocatedUnfairLock(initialState: false)

    /// Told of the mirror's picture once the camera's set up; on the main thread.
    var previewReady: (AVCaptureVideoPreviewLayer) -> Void = { _ in }

    /// `report` is told each frame read: the gesture, the hands as a pointer would follow them
    /// (the nearer first), and when.
    init(report: @escaping @Sendable (HandShape.Reading?, [HandPose], TimeInterval) -> Void) {
        self.report = report
        super.init()
        // Two, since your other hand is often in view too, on the keyboard or trackpad.
        request.maximumHandCount = 2
    }

    func start() {
        wanted.withLock { $0 = true }
        control.async {
            guard self.wanted.withLock({ $0 }) else { return }
            if !self.configured { self.configured = self.configure() }
            if self.configured, !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        wanted.withLock { $0 = false }
        control.async {
            if self.session.isRunning { self.session.stopRunning() }
            // After any frame still on its way, so the tracking display doesn't hold a hand
            // the camera no longer sees.
            self.frames.async { HandTrackFeed.shared.clear() }
        }
        frames.async { self.eagerUntil = nil }
    }

    /// Takes a picture: at full size, so the camera switches up for it (letting the picture
    /// settle a moment) and back down after.
    func takePhoto(taken: @escaping @Sendable (CGImage) -> Void) {
        control.async {
            self.use(.high)
            self.frames.async {
                self.photoTaken = taken
                self.photoSettling = 8
            }
        }
    }

    /// Control queue only.
    private func use(_ preset: AVCaptureSession.Preset) {
        guard configured, session.sessionPreset != preset, session.canSetSessionPreset(preset) else { return }
        session.beginConfiguration()
        session.sessionPreset = preset
        session.commitConfiguration()
    }

    /// Whether to read frames for hands at all: not while it's on just for the mirror.
    func read(_ reading: Bool) {
        self.reading.withLock { $0 = reading }
    }

    /// Whether Midnight Oyl's bloom is showing the tracking: then nearly every frame is read.
    func display(_ displaying: Bool) {
        self.displaying.withLock { $0 = displaying }
    }

    /// Whether the hand's the pointer: then every frame is read.
    func point(_ pointing: Bool) {
        self.pointing.withLock { $0 = pointing }
    }

    /// Whether to look for a pinky out at all.
    func lookForPinky(_ wanted: Bool) {
        pinkyWanted.withLock { $0 = wanted }
    }

    /// Until then, thumb and index tips count as pinched a little farther apart.
    func favorPinch(until time: TimeInterval) {
        pinchFavoredUntil.withLock { $0 = time }
    }

    private func configure() -> Bool {
        guard let device = Self.device, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        // Center Stage off, and Oyl's to say so, for Oyl alone (other apps keep it as they have
        // it): the camera's whole view, so a hand near its edges is still seen, and held still,
        // so where a hand is in the picture always means the same place in front of the Mac.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        let output = AVCaptureVideoDataOutput()
        // BGRA, which Midnight Oyl's camera draws straight from (the hand model and the selfie
        // take it as well as any).
        if output.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frames)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(Self.tracking) {
            session.sessionPreset = Self.tracking
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        // Mirrored like a selfie, so pointing to your right points right in the picture.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        // The mirror's picture: made here, once, off the main thread, where making it would stall
        // (it has to wait on the session), and kept for every time the mirror's opened.
        CATransaction.begin()
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        CATransaction.commit()
        DispatchQueue.main.async { self.previewReady(preview) }
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        autoreleasepool { look(at: sampleBuffer) }
    }

    private func look(at sampleBuffer: CMSampleBuffer) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Midnight Oyl's camera, if it's showing (it's skipped otherwise).
        CameraFrames.shared.publish(image)
        if let taken = photoTaken {
            if photoSettling > 0 {
                photoSettling -= 1
            } else {
                photoTaken = nil
                // Already mirrored, so it's the picture you'd see in a mirror.
                let picture = CIImage(cvPixelBuffer: image)
                if let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
                   let photo = pictures.createCGImage(picture, from: picture.extent, format: .RGBA8, colorSpace: sRGB) {
                    taken(photo)
                }
                control.async { self.use(Self.tracking) }
            }
        }
        guard reading.withLock({ $0 }) else { return }
        // For the first second and a half, look at every frame and take a slightly less certain
        // hand, to catch a gesture made as the notch opens (unless the Mac's busy). After that,
        // hands don't move fast enough to need every frame.
        let now = ProcessInfo.processInfo.systemUptime
        let eagerUntil = self.eagerUntil ?? now + 1.5
        self.eagerUntil = eagerUntil
        let interval = readingInterval(at: now)
        let eager = now < eagerUntil && load.fraction < 0.75
        guard eager || now - lastRead >= interval - 0.005 else { return }
        // Smoothed, and left as it was over a gap (the camera was off).
        if now - lastRead < 1 { rate += (1 / max(now - lastRead, 0.001) - rate) * (rate == 0 ? 1 : 0.15) }
        lastRead = now
        // Busy: just the one hand (unless the hand's the pointer, when two zoom).
        request.maximumHandCount = load.fraction > 0.75 && !pointing.withLock({ $0 }) ? 1 : 2
        let started = ProcessInfo.processInfo.systemUptime
        try? VNImageRequestHandler(cvPixelBuffer: image, orientation: .up).perform([request])
        let took = ProcessInfo.processInfo.systemUptime - started
        modelTime += (took - modelTime) * 0.1
        let aspect = CGFloat(CVPixelBufferGetWidth(image)) / CGFloat(max(CVPixelBufferGetHeight(image), 1))
        let favorPinch = now < pinchFavoredUntil.withLock { $0 }
        let pinky = pinkyWanted.withLock { $0 }
        // Each hand's joints, taken once for the gestures, the pointer and the tracking display.
        let hands = (request.results ?? []).compactMap { hand -> (joints: HandShape.Joints, certainty: Float)? in
            guard let points = try? hand.recognizedPoints(.all) else { return nil }
            return (points.mapValues { (location: $0.location, confidence: $0.confidence) }, hand.confidence)
        }
        let shapes = hands.map { hand in
            HandShape.reading(of: hand.joints, confidence: hand.certainty, aspect: aspect, eager: eager,
                              favorPinch: favorPinch, pinky: pinky)
        }
        // With both hands in view, the one held up nearer the camera is the one making the gesture.
        let nearest = zip(shapes, hands).compactMap { shape, hand in shape.map { (reading: $0, certainty: hand.certainty) } }
            .max { $0.reading.size < $1.reading.size }
        // And the hands as a pointer follows them, whatever shape they're in: the nearer first.
        let poses = zip(hands, shapes).compactMap { hand, shape in
            HandShape.pose(of: hand.joints, confidence: hand.certainty, aspect: aspect, gesture: shape?.gesture, time: now)
        }
        .sorted { $0.size > $1.size }
        report(nearest?.reading, poses, now)
        // And for Midnight Oyl's tracking display, every joint of every hand, gesture or no.
        let joints = hands.map { HandTrack.hand($0.joints) }
        HandTrackFeed.shared.publish(HandTrack(hands: joints.filter { !$0.isEmpty }, gesture: nearest?.reading.gesture.name,
                                               certainty: nearest?.certainty, modelTime: took, rate: rate,
                                               aspect: aspect, time: now))
    }

    /// How often to read a frame: 25 times a second, but less often when the hand model is slow
    /// on this Mac (it gets no more than a third of a core), when the Mac's busy, or when it's
    /// hot, so watching never bogs anything down. With Midnight Oyl's bloom showing the tracking,
    /// which is there to be watched, every frame the model keeps up with, unless the Mac's very
    /// busy or hot. With the hand the pointer, every frame the camera takes, unless the Mac's
    /// too hot to go on.
    private func readingInterval(at now: TimeInterval) -> TimeInterval {
        if now - load.checked > 2 { checkLoad(at: now) }
        if pointing.withLock({ $0 }) { return ProcessInfo.processInfo.thermalState == .critical ? 1.0 / 15 : 0 }
        var interval: TimeInterval
        if displaying.withLock({ $0 }) {
            interval = modelTime * 1.2
            if load.fraction > 0.9 { interval = max(interval, 1.0 / 12) }
        } else {
            interval = max(1.0 / 25, modelTime * 3)
            if load.fraction > 0.75 { interval = max(interval, 1.0 / 12) }
            if load.fraction > 0.9 { interval = max(interval, 1.0 / 6) }
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious: interval = max(interval, 1.0 / 8)
        case .critical: interval = max(interval, 1.0 / 4)
        default: break
        }
        return interval
    }

    /// How busy the Mac's cores have been, all told, since the last look: 0...1.
    private func checkLoad(at now: TimeInterval) {
        load.checked = now
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return }
        let ticks = info.cpu_ticks  // user, system, idle, nice
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3), total = busy + UInt64(ticks.2)
        if load.total > 0, total > load.total, busy >= load.busy {
            load.fraction = Double(busy - load.busy) / Double(total - load.total)
        }
        load.busy = busy
        load.total = total
    }
}

/// Reads a gesture off the hand's joints. It only compares distances between joints, never
/// absolute sizes, so it works near or far from the camera.
enum HandShape {
    /// One hand's joints as the model found them: where (0...1 up from the bottom left of the
    /// picture) and how sure it is of each.
    typealias Joints = [VNHumanHandPoseObservation.JointName: (location: CGPoint, confidence: Float)]

    struct Reading: Sendable {
        let gesture: HandGesture
        /// The little finger's up (a pinch with it up scrubs rather than turns).
        var pinky = false
        /// Which way the hand points in the picture (wrist to knuckles), in radians
        /// counterclockwise from the right; turning a pinch turns this.
        let angle: Double
        /// How big the hand looks (wrist to knuckles), so the nearer of two hands wins.
        let size: CGFloat
        /// Where the thumb and index tips are across the picture, 0...1, left to right as you
        /// see it; dragging a pinch moves this.
        let x: CGFloat
    }

    /// A hand's `joints`, which the model is `confidence` sure is a hand at all. `eager` accepts
    /// a hand Vision is a little less sure of; `favorPinch` judges a pinch a little more loosely;
    /// `pinky` looks for a pinky out, which only matters when there are lyrics.
    static func reading(of joints: Joints, confidence: Float, aspect: CGFloat, eager: Bool = false,
                        favorPinch: Bool = false, pinky: Bool = false) -> Reading? {
        guard confidence > (eager ? 0.4 : 0.5) else { return nil }
        // Vision measures 0...1 along each side of the picture; square that up so distances compare.
        // A joint counts if the model's at least `sure` of it.
        func point(_ name: VNHumanHandPoseObservation.JointName, sure: Float? = nil) -> CGPoint? {
            guard let joint = joints[name], joint.confidence > sure ?? (eager ? 0.22 : 0.3) else { return nil }
            return CGPoint(x: joint.location.x * aspect, y: joint.location.y)
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        guard let wrist = point(.wrist), let middleMCP = point(.middleMCP), let indexMCP = point(.indexMCP),
              let littleMCP = point(.littleMCP), let thumbMP = point(.thumbMP), let thumbIP = point(.thumbIP),
              let thumbTip = point(.thumbTip) else { return nil }
        let palm = distance(wrist, middleMCP)
        // Someone far behind you isn't giving commands.
        guard palm > 0.06 else { return nil }
        let angle = Double(atan2(middleMCP.y - wrist.y, middleMCP.x - wrist.x))

        // The thumb standing clear of the hand, not lying along it.
        let thumbOut = distance(thumbTip, littleMCP) > distance(thumbIP, littleMCP) * 1.1
            && distance(thumbTip, indexMCP) > palm * 0.45

        if isFist(fistShape({ point($0, sure: $1) })) {
            return Reading(gesture: .fist, angle: angle, size: palm, x: thumbTip.x / aspect)
        }

        // The rock sign: the thumb and little finger out, the other three curled, the hand facing
        // the camera (edge on, its knuckles bunched, a thumb tucked in looks out). Curled under,
        // the tips are hidden, so the model's least sure of them; its guesses are taken.
        func curled(_ middle: VNHumanHandPoseObservation.JointName, _ tip: VNHumanHandPoseObservation.JointName) -> Bool {
            guard let middle = point(middle, sure: 0.1), let tip = point(tip, sure: 0.1) else { return false }
            return distance(tip, wrist) < distance(middle, wrist)
        }
        if thumbOut, distance(indexMCP, littleMCP) > palm * 0.38, let littlePIP = point(.littlePIP), let littleTip = point(.littleTip),
           distance(littleTip, wrist) > distance(littlePIP, wrist) * 1.1,
           curled(.indexPIP, .indexTip), curled(.middlePIP, .middleTip), curled(.ringPIP, .ringTip) {
            return Reading(gesture: .rock, angle: angle, size: palm, x: thumbTip.x / aspect)
        }

        guard let indexTip = point(.indexTip) else { return nil }
        let x = (thumbTip.x + indexTip.x) / 2 / aspect
        let reading = { (gesture: HandGesture) in Reading(gesture: gesture, angle: angle, size: palm, x: x) }

        // A finger is out when its tip is farther from the wrist than its middle knuckle is.
        func isOut(_ knuckle: VNHumanHandPoseObservation.JointName, _ tip: VNHumanHandPoseObservation.JointName) -> Bool? {
            guard let knuckle = point(knuckle), let tip = point(tip) else { return nil }
            return distance(tip, wrist) > distance(knuckle, wrist) * 1.1
        }
        guard let index = isOut(.indexPIP, .indexTip), let middle = isOut(.middlePIP, .middleTip),
              let ring = isOut(.ringPIP, .ringTip), let little = isOut(.littlePIP, .littleTip) else { return nil }

        let tipsApart = distance(thumbTip, indexTip) / palm
        // OK: the index curled round to meet the thumb, the other three fingers up. A relaxed
        // open hand can bring the tips close too, but its index stays out, so the touch can be
        // judged loosely.
        if middle, ring, little, !index, tipsApart < 0.28 {
            return reading(.ok)
        }
        // A pinch: thumb and index tips together, the index reaching forward to meet it (in a
        // fist it curls back past its own knuckle instead).
        if tipsApart < (favorPinch ? 0.18 : 0.13), distance(indexTip, wrist) > distance(indexMCP, wrist),
           !(middle && ring && little) {
            var pinch = reading(.pinch)
            pinch.pinky = little && !ring
            return pinch
        }

        // How far out the little finger reaches against its middle knuckle: the announce shape
        // and a selfie's V differ only by it, so each wants it clearly up or clearly down.
        let littleReach = point(.littleTip).flatMap { tip in
            point(.littlePIP).map { distance(tip, wrist) / max(distance($0, wrist), 0.0001) }
        } ?? 1.1
        switch (index, middle, ring, little) {
        case (true, true, true, true):
            return reading(.openPalm)
        case (true, true, false, true):
            // The thumb holding the ring finger down, the rest up. Upright, it's the announce
            // shape; tipped well over to one side, it's turned that way (the picture's mirrored,
            // so left is your left). In between counts as neither.
            guard littleReach > 1.25 else { return nil }
            let tilt = remainder(angle - .pi / 2, 2 * .pi)
            guard abs(tilt) < 2.3 else { return nil }  // upside down
            if tilt > 0.6 { return reading(.tiltLeft) }
            if tilt < -0.6 { return reading(.tiltRight) }
            return abs(tilt) < 0.4 ? reading(.announce) : nil
        case (true, true, false, false):
            // A V, the two fingers clearly apart, so two fingers that happen to be out don't
            // take a picture, and the little finger clearly down.
            guard littleReach < 1.02, let middleTip = point(.middleTip), distance(indexTip, middleTip) > palm * 0.3 else { return nil }
            return reading(.peace)
        case (true, false, false, true):
            return thumbOut ? reading(.horns) : nil
        case (false, false, false, true):
            // (With the thumb out, and the hand facing the camera, it's the rock sign, above.)
            return pinky ? reading(.pinky) : nil
        case (true, false, false, false):
            let dx = indexTip.x - indexMCP.x, dy = indexTip.y - indexMCP.y
            if abs(dx) > abs(dy) * 1.2 { return reading(dx > 0 ? .pointRight : .pointLeft) }
            return nil
        case (false, false, false, false):
            // A fist with the thumb standing clear of it (not lying along it). Pointing up, within
            // 45° of upright, it's a thumbs up; pointing back over your shoulder, to your left,
            // within 45° of level, it's the left hand's point left.
            guard thumbOut else { return nil }
            let dx = thumbTip.x - thumbMP.x, dy = thumbTip.y - thumbMP.y
            if dy > 0, abs(dy) > abs(dx) { return reading(.thumbsUp) }
            return dx < 0 && abs(dx) > abs(dy) ? reading(.pointLeft) : nil
        default:
            return nil
        }
    }

    /// A fist's shape: every finger curled right round, its tip back inside its own knuckle and
    /// its middle joint; the thumb's tip turned in over the fingers or lying along them (no farther
    /// from the little finger's knuckle than the thumb's own last joint is, where a thumbs up's
    /// stands out past it) and resting on them; and the hand facing the camera, its knuckles
    /// spread across the picture (edge on, a thumb pointing at the camera looks tucked). Curled
    /// under, the tips are hidden, so the model's least sure of them; its guesses are taken.
    /// Nothing else has it: every other shape has a finger out, the thumb clear of the hand, or the
    /// index reaching forward past its knuckle to pinch.
    ///
    /// A pinch seen from above, though, with the other fingers curled, can look like one whose
    /// thumb is on the index tip; but its index reaches out past the middle finger's to meet the
    /// thumb. So with the shape, this gives how far the thumb's tip is from the index tip, and how
    /// much farther out the index tip reaches than the middle one (over the palm's length, and
    /// their knuckles' reach); nil without it. `point` finds a joint the model's sure enough of
    /// (as sure as it's given, or the usual).
    private static func fistShape(_ point: (VNHumanHandPoseObservation.JointName, Float?) -> CGPoint?)
        -> (apart: CGFloat, indexAhead: CGFloat)? {
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        guard let wrist = point(.wrist, nil), let middleMCP = point(.middleMCP, nil), let indexMCP = point(.indexMCP, nil),
              let littleMCP = point(.littleMCP, nil), let thumbIP = point(.thumbIP, nil),
              let thumbTip = point(.thumbTip, nil), let indexTip = point(.indexTip, 0.1) else { return nil }
        let palm = distance(wrist, middleMCP)
        let fingers: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName,
                       VNHumanHandPoseObservation.JointName)] =
            [(.indexMCP, .indexPIP, .indexTip), (.middleMCP, .middlePIP, .middleTip),
             (.ringMCP, .ringPIP, .ringTip), (.littleMCP, .littlePIP, .littleTip)]
        // How far out each tip reaches against its knuckle, if it's curled back inside its middle joint.
        let reaches = fingers.map { knuckle, middle, tip -> CGFloat? in
            guard let knuckle = point(knuckle, 0.1), let middle = point(middle, 0.1), let tip = point(tip, 0.1),
                  distance(tip, wrist) < distance(middle, wrist) else { return nil }
            return distance(tip, wrist) / max(distance(knuckle, wrist), 0.0001)
        }
        guard reaches.allSatisfy({ ($0 ?? 1) < 1 }), let index = reaches[0], let middle = reaches[1],
              distance(thumbTip, littleMCP) < distance(thumbIP, littleMCP) * 0.95,
              distance(indexMCP, littleMCP) > palm * 0.38,
              [.indexMCP, .indexPIP, .indexDIP, .middleMCP, .middlePIP, .middleDIP, .ringPIP]
                .compactMap({ point($0, 0.1) }).contains(where: { distance(thumbTip, $0) < palm * 0.32 }) else { return nil }
        return (distance(thumbTip, indexTip) / palm, index - middle)
    }

    /// A fist: in its shape, the thumb clear of the index tip, or if it's near, the index curled
    /// as far as the middle finger.
    private static func isFist(_ shape: (apart: CGFloat, indexAhead: CGFloat)?) -> Bool {
        guard let shape else { return false }
        return shape.apart > 0.12 && (shape.apart > 0.25 || shape.indexAhead < 0.15)
    }

    /// The hand as a pointer follows it, whatever shape it's making (`gesture`, if it reads as
    /// one), read at `time`; nil if it's too far off, or the model's unsure of its palm.
    static func pose(of joints: Joints, confidence: Float, aspect: CGFloat, gesture: HandGesture?,
                     time: TimeInterval) -> HandPose? {
        guard confidence > 0.4 else { return nil }
        func point(_ name: VNHumanHandPoseObservation.JointName, sure: Float = 0.3) -> CGPoint? {
            guard let joint = joints[name], joint.confidence > sure else { return nil }
            return CGPoint(x: joint.location.x * aspect, y: joint.location.y)
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        guard let wrist = point(.wrist), let indexMCP = point(.indexMCP), let middleMCP = point(.middleMCP) else { return nil }
        let palm = distance(wrist, middleMCP)
        guard palm > 0.06 else { return nil }
        // Back in the picture's own terms: across, and down.
        func shown(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x / aspect, y: 1 - point.y) }
        // Between the index and middle knuckles, nearer the index's: the fingertips move, but the
        // knuckles hardly do.
        let anchor = shown(CGPoint(x: indexMCP.x * 0.65 + middleMCP.x * 0.35, y: indexMCP.y * 0.65 + middleMCP.y * 0.35))
        let indexTip = point(.indexTip, sure: 0.2), thumbTip = point(.thumbTip, sure: 0.2)
        let pinch = indexTip.flatMap { index in thumbTip.map { distance($0, index) / palm } }
        let middleTip = point(.middleTip, sure: 0.2)
        let middlePinch = middleTip.flatMap { middle in thumbTip.map { distance($0, middle) / palm } }
        // How much farther the thumb tip is from the middle finger's last joint than from its tip:
        // on the tip, well ahead; lying over the finger curled under it, as a pointing hand's does,
        // behind.
        let middleAhead = middleTip.flatMap { middle in thumbTip.flatMap { thumb in
            point(.middleDIP, sure: 0.2).map { (distance(thumb, $0) - distance(thumb, middle)) / palm }
        } }
        let reach = indexTip.map { distance($0, wrist) / max(distance(indexMCP, wrist), 0.0001) }
        let middleReach = middleTip.map { distance($0, wrist) / max(distance(middleMCP, wrist), 0.0001) }
        // In a fist's shape, the index curled as far as the middle finger: a fist, though its
        // thumb may be on the index tip (see `fistShape`).
        let fistLike = fistShape({ point($0, sure: $1 ?? 0.3) }).map { $0.indexAhead < 0.08 } ?? false
        // How far out each finger reaches: its tip from the wrist, over its middle joint's.
        let fingers: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] =
            [(.indexPIP, .indexTip), (.middlePIP, .middleTip), (.ringPIP, .ringTip), (.littlePIP, .littleTip)]
        let reaches = fingers.map { middle, tip -> CGFloat? in
            guard let middle = point(middle), let tip = point(tip) else { return nil }
            return distance(tip, wrist) / max(distance(middle, wrist), 0.0001)
        }
        // Uncurled: the tip back out past the middle joint.
        let uncurled = reaches.filter { ($0 ?? 0) > 1 }.count
        // Two or three fingers held out side by side, as they'd lie on a trackpad: clearly out,
        // their tips together (a V's are as far out, but spread), the rest curled (or hidden,
        // curled under), and the thumb well away from them (a pinch with the middle finger lying
        // along the index isn't two fingers on a trackpad).
        let out = reaches.map { ($0 ?? 0) > 1.1 }, curled = reaches.map { ($0 ?? 0) < 1 }
        func beside(_ a: VNHumanHandPoseObservation.JointName, _ b: VNHumanHandPoseObservation.JointName) -> Bool {
            guard let a = point(a), let b = point(b) else { return false }
            return distance(a, b) < palm * 0.3
        }
        var together = 0
        if out[0], out[1], curled[3], beside(.indexTip, .middleTip), (pinch ?? 1) > 0.5 {
            if curled[2] {
                together = 2
            } else if out[2], beside(.middleTip, .ringTip) {
                together = 3
            }
        }
        return HandPose(time: time, aspect: aspect, anchor: anchor, tip: indexTip.map(shown), size: palm,
                        gesture: gesture, pinch: pinch, middlePinch: middlePinch, middleAhead: middleAhead, reach: reach, middleReach: middleReach, uncurled: uncurled, together: together,
                        fistLike: fistLike, joints: HandTrack.hand(joints))
    }
}

extension HandTrack {
    /// Vision's joints and the names the tracking display (and `bones`) knows them by: the wrist,
    /// then each finger from its base out. Vision's own names are codes like "VNHLKTTIP".
    static let jointNames: [(VNHumanHandPoseObservation.JointName, String)] = [
        (.wrist, "wrist"),
        (.thumbCMC, "thumbCMC"), (.thumbMP, "thumbMP"), (.thumbIP, "thumbIP"), (.thumbTip, "thumbTip"),
        (.indexMCP, "indexMCP"), (.indexPIP, "indexPIP"), (.indexDIP, "indexDIP"), (.indexTip, "indexTip"),
        (.middleMCP, "middleMCP"), (.middlePIP, "middlePIP"), (.middleDIP, "middleDIP"), (.middleTip, "middleTip"),
        (.ringMCP, "ringMCP"), (.ringPIP, "ringPIP"), (.ringDIP, "ringDIP"), (.ringTip, "ringTip"),
        (.littleMCP, "littleMCP"), (.littlePIP, "littlePIP"), (.littleDIP, "littleDIP"), (.littleTip, "littleTip"),
    ]

    /// One hand's joints as Vision gives them (0...1 up from the bottom left), as the display
    /// wants them: named, measured down from the top left, in `jointNames`' order, and only the
    /// ones the model found. (The picture's already mirrored, so across stays as it is.)
    static func hand(_ points: [VNHumanHandPoseObservation.JointName: (location: CGPoint, confidence: Float)]) -> [Joint] {
        jointNames.compactMap { joint, name in
            guard let found = points[joint], found.confidence > 0 else { return nil }
            return Joint(name: name, point: CGPoint(x: found.location.x, y: 1 - found.location.y), confidence: found.confidence)
        }
    }
}
