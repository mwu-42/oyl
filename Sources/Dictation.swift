import Accelerate
import AppKit
import AVFoundation
import CoreAudio
import SwiftUI

/// Wispr Flow, the dictation app, in the notch: whether it's listening (however it was started),
/// and starting and stopping its hands-free dictation from the open notch. It's seen listening
/// through Core Audio, which knows which apps have the microphone open, and told to start and stop
/// through links of its own (`wispr-flow://start-hands-free` and `…/stop-hands-free`;
/// undocumented, so a later version could drop them). While it listens, Oyl reads your voice's
/// level off the microphone too, if it's been allowed to, for the closed notch to show.
@MainActor
final class Dictation: ObservableObject {
    nonisolated static let bundleID = "com.electron.wispr-flow"
    /// The orange macOS shows for a microphone in use.
    static let tint = Color(red: 1, green: 0.62, blue: 0.04)

    /// Wispr Flow's on this Mac.
    @Published private(set) var isAvailable = Dictation.installed
    /// It's taking down what you say.
    @Published private(set) var isListening = false
    /// Your voice, 0...1, while it is, or nil without the microphone. Not published: it's read
    /// as it's drawn.
    private(set) var level: Float?

    private lazy var watch = MicWatch(bundleID: Self.bundleID) { [weak self] listening in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.heard(listening) }
        }
    }
    private var meter: VoiceMeter?

    init() {
        watch.start()
    }

    private static var installed: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Starts its hands-free dictation, or stops it. The first time, Oyl asks for the microphone
    /// (for your voice's level) before it starts, rather than in the middle of your talking.
    func toggle() {
        isAvailable = Self.installed
        guard isAvailable else { return }
        let start = !isListening
        if start, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.send(start: true) }
                }
            }
            return
        }
        send(start: start)
    }

    /// Without bringing it forward, so what it types goes where you were.
    private func send(start: Bool) {
        guard let url = URL(string: "wispr-flow://" + (start ? "start-hands-free" : "stop-hands-free")) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
    }

    /// Oyl's resting (the lid's shut, or it's switched off): your voice isn't read.
    var resting = false {
        didSet { if resting != oldValue { updateMeter() } }
    }

    private func heard(_ listening: Bool) {
        guard listening != isListening else { return }
        isListening = listening
        updateMeter()
    }

    /// The meter's on while Wispr Flow listens, unless Oyl's resting.
    private func updateMeter() {
        if isListening, !resting, meter == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            meter = VoiceMeter { [weak self] loudness in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.hear(loudness) }
                }
            }
            level = meter == nil ? nil : 0
        } else if !isListening || resting {
            meter?.stop()
            meter = nil
            level = nil
        }
    }

    /// Quick to rise with your voice, slower to fall back.
    private func hear(_ loudness: Float) {
        guard let level, meter != nil else { return }
        self.level = level + (loudness - level) * (loudness > level ? 0.6 : 0.2)
    }
}

/// An app's processes (Wispr Flow's, Granola's), each watched for when it takes the microphone,
/// and the list of them watched for when they come and go. Only touched on its queue.
final class MicWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "oyl.MicWatch")
    private let bundleID: String
    private let changed: @Sendable (Bool) -> Void
    private var watched: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listening: Bool?

    private static var processList = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                                mElement: kAudioObjectPropertyElementMain)
    private static var input = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)

    /// `changed` hears whether any of the app's processes (`bundleID`, and its helpers) has the
    /// microphone, as that changes, on its queue.
    init(bundleID: String, changed: @escaping @Sendable (Bool) -> Void) {
        self.bundleID = bundleID
        self.changed = changed
    }

    private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            var address = Self.processList
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            self.listener = listener
            rescan()
        }
    }

    /// Stops listening, saying it's off the microphone if it was on.
    func stop() {
        queue.async { [self] in
            if let listener {
                var address = Self.processList
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
                self.listener = nil
            }
            for (object, block) in watched {
                var address = Self.input
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            }
            watched = [:]
            if listening == true { changed(false) }
            listening = nil
        }
    }

    /// Picks up any new process of its, lets go of those gone, and says whether it's listening.
    private func rescan() {
        let found = Set(AudioProcess.objects(matching: bundleID))
        for (object, block) in watched where !found.contains(object) {
            var address = Self.input
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            watched[object] = nil
        }
        for object in found where watched[object] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.report() }
            var address = Self.input
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr { watched[object] = block }
        }
        report()
    }

    private func report() {
        let now = watched.keys.contains(where: AudioProcess.isTakingInput)
        guard now != listening else { return }
        listening = now
        changed(now)
    }
}

/// The microphone's loudness, 0...1, a few dozen times a second, from a tap on its input.
private final class VoiceMeter {
    private let engine = AVAudioEngine()

    init?(loudness: @escaping @Sendable (Float) -> Void) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let rms = vDSP.rootMeanSquare(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            // From a quiet room to speaking up close.
            let decibels = 20 * log10(max(rms, 1e-7))
            loudness(min(max((decibels + 55) / 40, 0), 1))
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return nil
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
