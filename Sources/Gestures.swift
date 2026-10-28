import AppKit
import AVFoundation
import CoreImage
import os
import Vision

/// Hand shapes Oyl recognizes on the camera.
enum HandGesture {
    case openPalm
    case pointLeft, pointRight
    case horns     // 🤟, horns with the thumb out: keeps the Mac awake
    case pinky     // just the little finger out: shows the lyrics; looked for only when there are some
    case pinch     // turned like a knob for volume; with the pinky up, dragged sideways to scrub through the song
    case peace     // takes a selfie
    case ok        // stops watching
    case thumbsUp  // approves an agent's request; looked for only while one is waiting
    case announce  // the thumb holding the ring finger down, the other three up: every Oyl says what it's doing
    case tiltLeft  // an open hand tipped over to the left: Oyls line up on the left (or come back)
    case tiltRight // tipped over to the right: Oyls walk off (or stop lining up)

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
            // The lyrics, and an Oyl on the menu bar singing them.
            toggleLyrics()
            singing = showsLyrics && nowPlaying.lyrics != nil
        case .pinch, .peace, .ok, .thumbsUp, .announce, .tiltLeft, .tiltRight:
            // Handled elsewhere: GestureWatcher has a pinch call turn(by:) or scrub(by:), peace
            // take a selfie, OK stop watching and a thumbs up approve; the Oyls on the menu bar
            // (NotchController) take the rest.
            break
        }
    }

    /// A pinch turned like a knob: clockwise is louder, and a quarter turn covers about half
    /// the range.
    func turn(by radians: Double) {
        let before = nowPlaying.volume
        nowPlaying.setVolume(before + radians * 0.35)
        // A tick every 10%, like pulling on the cover.
        if Int((before * 10).rounded()) != Int((nowPlaying.volume * 10).rounded()) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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
/// up an OK), and for a thumbs up while an agent waits for your OK. The camera, and so its green
/// light, is on only while watching. (macOS keeps the light on for at least three seconds after
/// the camera starts, however briefly it runs.)
@MainActor
final class GestureWatcher: ObservableObject {
    struct Sighting: Equatable {
        let id = UUID()
        let gesture: HandGesture
    }

    /// Selfies go in ~/Pictures/Oyl.
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
    /// The song has lyrics, so a pinky out (which shows them) is worth looking for.
    var lyricsAvailable = false { didSet { camera?.lookForPinky(lyricsAvailable) } }

    var onGesture: (HandGesture) -> Void = { _ in }
    /// Clockwise turns of a held pinch, in radians.
    var onTurn: (Double) -> Void = { _ in }
    /// A sideways pinch let go, with how far it went, in seconds.
    var onScrub: (Double) -> Void = { _ in }
    var onApprove: () -> Void = {}
    /// A selfie's been saved here.
    var onSelfie: (URL) -> Void = { _ in }

    private static let releaseTime = 0.4      // no shape counts once it's held this long, too
    private static let scrubPerWidth = 120.0  // seconds for a pinch dragged across the whole picture
    private static let favorPinch = 3.0       // after a pinch, how long another one comes easier

    private enum Grip { case knob, scrub }

    private var wanted = false
    private var cameraOff: DispatchWorkItem?
    private var candidate: HandGesture?
    private var candidateSince: TimeInterval = 0
    private var held: HandGesture?
    /// A raised hand's play or pause, waiting a moment in case the hand is on its way to
    /// tipping over (which mustn't play or pause too).
    private var pendingPalm: DispatchWorkItem?
    /// After a tilt, the hand has to come back upright (or go) before another tilt counts, and
    /// coming back upright isn't a raised hand.
    private var tiltArmed = true
    private var palmQuiet = false
    private var grip: Grip?                                // nil until the pinch is turned or dragged
    private var gripAnchor: (angle: Double, x: CGFloat)?  // nil while the fingers are apart
    private var pinchFavoredUntil: TimeInterval = 0
    /// Made when first needed, and let go half a minute after it stops, so the hand model and
    /// the camera's buffers don't sit in memory between uses.
    private var camera: HandCamera?
    private var cameraRelease: DispatchWorkItem?

    private func liveCamera() -> HandCamera {
        if let camera { return camera }
        let camera = HandCamera { [weak self] reading in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.saw(reading) }
            }
        }
        camera.lookForPinky(lyricsAvailable)
        self.camera = camera
        return camera
    }

    /// Watches while hovering or approving, and stops once neither is true.
    private func update() {
        if isEnabled && (hovering || approving) { watch() } else { stop() }
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
        pendingPalm?.cancel()
        pendingPalm = nil
        guard isWatching else { return }
        isWatching = false
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cameraOff = nil
                self.camera?.stop()
                let release = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { if self?.isWatching == false { self?.camera = nil } }
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
        if !isWatching { isWatching = true }
        liveCamera().start()
    }

    /// One camera frame's reading; nil when there's no hand or no shape Oyl knows.
    private func saw(_ reading: HandShape.Reading?) {
        guard isWatching else { return }
        let gesture = reading?.gesture
        let now = ProcessInfo.processInfo.systemUptime
        if gesture != candidate {
            candidate = gesture
            candidateSince = now
        }
        // A tilt that lasts (not one misread frame) means the raised hand was on its way over.
        if isTilt(candidate), now - candidateSince >= 0.15 {
            pendingPalm?.cancel()
            pendingPalm = nil
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
            palmQuiet = false
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
        // Without the pointer over the notch, the camera is only on for a thumbs up.
        switch gesture {
        case .thumbsUp:
            guard approving else { return }
            onApprove()
        case _ where !hovering:
            return
        case .ok:
            stop()
        case .peace:
            takeSelfie()
        case .pinch:
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            return  // moving it does the work, and the indicator shows it while held
        case .openPalm:
            // Back upright after a tilt: that's to allow the next tilt, not to play or pause.
            guard !palmQuiet else {
                tiltArmed = true
                return
            }
            armPalm(after: 0.5)
            return
        case .tiltLeft, .tiltRight:
            guard tiltArmed else { return }
            tiltArmed = false
            palmQuiet = true
            onGesture(gesture)
        default:
            onGesture(gesture)
        }
        acknowledge(gesture)
    }

    private func isTilt(_ gesture: HandGesture?) -> Bool { gesture == .tiltLeft || gesture == .tiltRight }

    /// The raised hand's play or pause, after `delay`, unless a tilt comes first (if one's just
    /// begun when it's due, it waits a little longer to see).
    private func armPalm(after delay: TimeInterval) {
        pendingPalm?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingPalm = nil
                guard self.hovering else { return }
                if self.isTilt(self.candidate) {
                    if ProcessInfo.processInfo.systemUptime - self.candidateSince < 0.15 { self.armPalm(after: 0.2) }
                    return
                }
                self.onGesture(.openPalm)
                self.acknowledge(.openPalm)
            }
        }
        pendingPalm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A tap of the trackpad, and the gesture's symbol shown for a moment.
    private func acknowledge(_ gesture: HandGesture) {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
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
        camera?.takePhoto(to: Self.selfies.appendingPathComponent("Selfie \(formatter.string(from: Date())).jpg")) { [weak self] url in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onSelfie(url) }
            }
        }
        Self.shutter?.stop()
        Self.shutter?.play()
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
    private let report: @Sendable (HandShape.Reading?) -> Void
    private let pictures = CIContext()
    /// Set at once from the main thread, so a stop that comes while the start is still queued
    /// keeps the camera from coming on at all.
    private let wanted = OSAllocatedUnfairLock(initialState: false)
    private var configured = false
    private var photoURL: URL?  // the next frame is saved here; frames queue only
    private var photoSaved: (@Sendable (URL) -> Void)?  // and then this is told; frames queue only
    private var lastRead: TimeInterval = 0  // frames queue only
    private var eagerUntil: TimeInterval?   // frames queue only: see captureOutput
    private let pinchFavoredUntil = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)
    private let pinkyWanted = OSAllocatedUnfairLock(initialState: false)

    init(report: @escaping @Sendable (HandShape.Reading?) -> Void) {
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
        }
        frames.async { self.eagerUntil = nil }
    }

    /// Saves the next frame as a JPEG.
    func takePhoto(to url: URL, saved: @escaping @Sendable (URL) -> Void) {
        frames.async {
            self.photoURL = url
            self.photoSaved = saved
        }
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
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frames)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Full quality, for selfies; the hand model scales frames down itself.
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        // Mirrored like a selfie, so pointing to your right points right in the picture.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let url = photoURL, let sRGB = CGColorSpace(name: CGColorSpace.sRGB) {
            photoURL = nil
            // Already mirrored, so it's the picture you'd see in a mirror.
            if (try? pictures.writeJPEGRepresentation(of: CIImage(cvPixelBuffer: image), to: url, colorSpace: sRGB, options: [:])) != nil {
                photoSaved?(url)
            }
            photoSaved = nil
        }
        // For the first second and a half, look at every frame and take a slightly less certain
        // hand, to catch a gesture made as the notch opens. After that, hands don't move fast
        // enough to need every frame: 25 a second is plenty.
        let now = ProcessInfo.processInfo.systemUptime
        let eagerUntil = self.eagerUntil ?? now + 1.5
        self.eagerUntil = eagerUntil
        let eager = now < eagerUntil
        guard eager || now - lastRead >= 1.0 / 25 - 0.005 else { return }
        lastRead = now
        try? VNImageRequestHandler(cvPixelBuffer: image, orientation: .up).perform([request])
        let aspect = CGFloat(CVPixelBufferGetWidth(image)) / CGFloat(max(CVPixelBufferGetHeight(image), 1))
        let favorPinch = now < pinchFavoredUntil.withLock { $0 }
        let pinky = pinkyWanted.withLock { $0 }
        let readings = request.results?.compactMap {
            HandShape.reading(of: $0, aspect: aspect, eager: eager, favorPinch: favorPinch, pinky: pinky)
        } ?? []
        // With both hands in view, the one held up nearer the camera is the one making the gesture.
        report(readings.max { $0.size < $1.size })
    }
}

/// Reads a gesture off the hand's joints. It only compares distances between joints, never
/// absolute sizes, so it works near or far from the camera.
enum HandShape {
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

    /// `eager` accepts a hand Vision is a little less sure of; `favorPinch` judges a pinch a
    /// little more loosely; `pinky` looks for a pinky out, which only matters when there are lyrics.
    static func reading(of hand: VNHumanHandPoseObservation, aspect: CGFloat, eager: Bool = false,
                        favorPinch: Bool = false, pinky: Bool = false) -> Reading? {
        guard hand.confidence > (eager ? 0.4 : 0.5), let joints = try? hand.recognizedPoints(.all) else { return nil }
        // Vision measures 0...1 along each side of the picture; square that up so distances compare.
        func point(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let joint = joints[name], joint.confidence > (eager ? 0.22 : 0.3) else { return nil }
            return CGPoint(x: joint.location.x * aspect, y: joint.location.y)
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        guard let wrist = point(.wrist), let middleMCP = point(.middleMCP), let indexMCP = point(.indexMCP),
              let littleMCP = point(.littleMCP), let thumbMP = point(.thumbMP), let thumbIP = point(.thumbIP),
              let thumbTip = point(.thumbTip), let indexTip = point(.indexTip) else { return nil }
        let palm = distance(wrist, middleMCP)
        // Someone far behind you isn't giving commands.
        guard palm > 0.06 else { return nil }
        let angle = Double(atan2(middleMCP.y - wrist.y, middleMCP.x - wrist.x))
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

        // The thumb standing clear of the hand, not lying along it.
        let thumbOut = distance(thumbTip, littleMCP) > distance(thumbIP, littleMCP) * 1.1
            && distance(thumbTip, indexMCP) > palm * 0.45

        switch (index, middle, ring, little) {
        case (true, true, true, true):
            // Upright, it's a raised hand; tipped well over to one side, turned that way (the
            // picture's mirrored, so left is your left). In between counts as neither.
            let tilt = remainder(angle - .pi / 2, 2 * .pi)
            guard abs(tilt) < 2.3 else { return nil }  // upside down
            if tilt > 0.6 { return reading(.tiltLeft) }
            if tilt < -0.6 { return reading(.tiltRight) }
            return abs(tilt) < 0.4 ? reading(.openPalm) : nil
        case (true, true, false, true):
            // The thumb holding the ring finger down, the rest up.
            return reading(.announce)
        case (true, true, false, false):
            // A V, the two fingers clearly apart, so two fingers that happen to be out don't
            // take a picture.
            guard let middleTip = point(.middleTip), distance(indexTip, middleTip) > palm * 0.3 else { return nil }
            return reading(.peace)
        case (true, false, false, true):
            return thumbOut ? reading(.horns) : nil
        case (false, false, false, true):
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
}
