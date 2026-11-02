import Accelerate
import Combine
import CoreAudio
import Foundation

/// One analysis frame; every level is 0...1.
struct SpectrumFrame: Sendable {
    static let barCount = 4
    static let curveCount = 48

    var bars: [Float]   // closed notch: bass, low mids, high mids, treble
    var curve: [Float]  // open notch: log-spaced spectrum, 40 Hz to 16 kHz
    var hold: [Float]   // slower-falling outline of `curve`
    var pulse: Pulse?   // the beat, once there's a steady one

    static let silent = SpectrumFrame(bars: .init(repeating: 0, count: barCount),
                                      curve: .init(repeating: 0, count: curveCount),
                                      hold: .init(repeating: 0, count: curveCount))

    var peak: Float { max(bars.max() ?? 0, curve.max() ?? 0, hold.max() ?? 0) }
}

/// Live spectrum of the current player.
///
/// Uses a Core Audio process tap on the player's own output (no microphone, no screen
/// recording), and only while music is playing. macOS asks once for permission to capture
/// other apps' audio; if that's denied the tap delivers silence and `isLive` stays false, so the
/// view falls back to decorative motion.
@MainActor
final class AudioSpectrum: ObservableObject {
    /// Not @Published on purpose: frames arrive ~30 times a second and only the visualizer
    /// layers subscribe, so SwiftUI never re-renders for them.
    let frames = CurrentValueSubject<SpectrumFrame, Never>(.silent)
    @Published private(set) var isLive = false

    // Starting, stopping, skipping and seeking ease in and out rather than jump. The analyzer's
    // frames pass straight through, except just after a change, when they're smoothed for a
    // moment; once playback stops, the last frame decays to rest.
    private static let decayTime = 0.2    // time constant of the fall after stopping
    private static let easeTime = 0.3     // time constant right after a change…
    private static let settleTime = 0.8   // …relaxing to none over this long
    private static let gapTime = 0.25     // silence this long is a gap; the sound after it eases in

    private var player: Player?
    private var shown = SpectrumFrame.silent
    private var lastStep: TimeInterval = 0
    private var changedAt = -TimeInterval.infinity
    private var quietSince: TimeInterval? = -.infinity
    private var decay: Timer?
    private lazy var engine = TapEngine { [weak self] frame, audible in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.publish(frame, audible: audible) }
        }
    }

    /// Nothing that shows it can be seen (the lid's shut): the tap's off till it's back.
    var resting = false {
        didSet {
            guard resting != oldValue else { return }
            engine.follow(resting ? nil : player?.bundleID)
            if resting { startDecay() } else { changedAt = Self.now }
        }
    }

    /// Taps `player` while it's playing; pass nil to stop.
    func follow(_ player: Player?) {
        engine.follow(resting ? nil : player?.bundleID)
        guard player != self.player else { return }
        self.player = player
        changedAt = Self.now
        quietSince = -.infinity
        if player == nil { startDecay() }
    }

    /// The audio is about to jump (a skip or a seek): ease into whatever plays next.
    func easeNextChange() {
        changedAt = Self.now
    }

    private func publish(_ frame: SpectrumFrame, audible: Bool) {
        // Buffers can land just after playback stopped; the decay has taken over by then.
        guard player != nil else { return }
        let now = Self.now
        if audible {
            if let quietSince, now - quietSince >= Self.gapTime { changedAt = now }
            quietSince = nil
            if !isLive { isLive = true }
        } else if quietSince == nil {
            quietSince = now
        }
        decay?.invalidate()
        decay = nil
        step(toward: frame, at: now, time: easing(at: now))
        frames.send(shown)
        Beat.level = shown.bars[0]
        Beat.bars = shown.bars
        Beat.pulse = frame.pulse
    }

    /// Runs until the shown frame has fallen to rest, or the analyzer takes over again.
    private func startDecay() {
        guard decay == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.decayStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        decay = timer
    }

    private func decayStep() {
        let now = Self.now
        step(toward: .silent, at: now, time: max(easing(at: now), Self.decayTime))
        if shown.peak < 0.003 {
            shown = .silent
            decay?.invalidate()
            decay = nil
        }
        frames.send(shown)
        Beat.level = shown.bars[0]
        Beat.bars = shown.bars
        Beat.pulse = nil
    }

    private func easing(at now: TimeInterval) -> TimeInterval {
        Self.easeTime * max(0, 1 - (now - changedAt) / Self.settleTime)
    }

    /// Moves the shown frame toward `target`; `time` is the smoothing's time constant, 0 to jump.
    private func step(toward target: SpectrumFrame, at now: TimeInterval, time: TimeInterval) {
        let elapsed = min(max(now - lastStep, 0), 0.1)
        lastStep = now
        let amount = time > 0 ? Float(1 - exp(-elapsed / time)) : 1
        // The trailing outline falls a little slower, so it still trails the curve down.
        let holdAmount = time > 0 ? Float(1 - exp(-elapsed / (time * 1.5))) : 1
        for index in shown.bars.indices {
            shown.bars[index] += (target.bars[index] - shown.bars[index]) * amount
        }
        for index in shown.curve.indices {
            shown.curve[index] += (target.curve[index] - shown.curve[index]) * amount
            shown.hold[index] += (target.hold[index] - shown.hold[index]) * holdAmount
            shown.hold[index] = max(shown.hold[index], shown.curve[index])
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Starts and stops the tap. Runs on its own queue because the first start can block on the
/// permission prompt.
private final class TapEngine: @unchecked Sendable {
    private let control = DispatchQueue(label: "oyl.AudioTap")
    private let io = DispatchQueue(label: "oyl.AudioTap.IO", qos: .userInteractive)
    private let publish: @Sendable (SpectrumFrame, Bool) -> Void
    private var tap: ProcessTap?
    private var bundleID: String?
    private var processes: [AudioObjectID] = []
    private var failed = false
    private var checks = 0

    init(publish: @escaping @Sendable (SpectrumFrame, Bool) -> Void) {
        self.publish = publish
    }

    func follow(_ bundleID: String?) {
        control.async { self.update(bundleID) }
    }

    private func update(_ newBundleID: String?) {
        if newBundleID != bundleID {
            stop()
            bundleID = newBundleID
            failed = false
            checks = 0
        }
        guard let bundleID else { return }

        // While tapping, re-check every few calls in case the player moved its audio to a helper.
        checks += 1
        guard tap == nil || checks % 5 == 0 else { return }
        let found = AudioProcess.objects(matching: bundleID)
        guard !found.isEmpty, found != processes || (tap == nil && !failed) else { return }

        stop()
        processes = found
        tap = ProcessTap.start(processes: found, queue: io, publish: publish)
        failed = tap == nil
    }

    private func stop() {
        tap?.stop()
        tap = nil
    }
}

enum AudioProcess {
    /// Core Audio process objects whose bundle ID starts with `bundleID`, so helpers count too.
    static func objects(matching bundleID: String) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.filter { self.bundleID(of: $0)?.hasPrefix(bundleID) == true }.sorted()
    }

    /// Whether it has the microphone (or any input) open.
    static func isTakingInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// A private, unmuted tap on some processes, wrapped in an aggregate device so it can be read.
private final class ProcessTap {
    private let tapID: AudioObjectID
    private let aggregateID: AudioObjectID
    private let procID: AudioDeviceIOProcID

    private init(tapID: AudioObjectID, aggregateID: AudioObjectID, procID: AudioDeviceIOProcID) {
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.procID = procID
    }

    static func start(processes: [AudioObjectID], queue: DispatchQueue,
                      publish: @escaping @Sendable (SpectrumFrame, Bool) -> Void) -> ProcessTap? {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        func fail() -> ProcessTap? {
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            if aggregateID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyAggregateDevice(aggregateID) }
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        guard let format = format(of: tapID), format.mSampleRate > 0, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return fail() }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Oyl Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { return fail() }

        let analyzer = SpectrumAnalyzer(sampleRate: format.mSampleRate, publish: publish)
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, { _, input, _, _, _ in
            analyzer.process(input)
        }) == noErr, let procID, AudioDeviceStart(aggregateID, procID) == noErr else { return fail() }

        return ProcessTap(tapID: tapID, aggregateID: aggregateID, procID: procID)
    }

    func stop() {
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    private static func format(of tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }
}

/// Turns samples into a `SpectrumFrame` about 30 times a second. Only touched on the IO queue.
private final class SpectrumAnalyzer: @unchecked Sendable {
    private static let fftSize = 2048
    private static let log2n = vDSP_Length(11)
    private static let barEdges: [Double] = [40, 250, 1000, 4000, 12000]
    private static let curveLow = 40.0, curveHigh = 16000.0

    private let setup: FFTSetup
    private let window: [Float]
    private let barBands: [(low: Double, high: Double)]    // in FFT bins
    private let curveBands: [(low: Double, high: Double)]
    private let tilt: [Float]
    private let hop: Int
    private let publish: @Sendable (SpectrumFrame, Bool) -> Void
    private var samples: [Float] = []
    private var sinceAnalysis = 0

    private var loudnessPeak: Float = -30
    private var barPeaks = [Float](repeating: -120, count: SpectrumFrame.barCount)
    private var curvePeak: Float = -40
    private var frame = SpectrumFrame.silent
    private var beats: BeatTracker

    init(sampleRate: Double, publish: @escaping @Sendable (SpectrumFrame, Bool) -> Void) {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: Self.fftSize, isHalfWindow: false)
        let binWidth = sampleRate / Double(Self.fftSize)
        let lastBin = Double(Self.fftSize / 2 - 1)
        let bins = { (hz: Double) in min(max(hz / binWidth, 1), lastBin) }

        barBands = (0..<SpectrumFrame.barCount).map { (bins(Self.barEdges[$0]), bins(Self.barEdges[$0 + 1])) }
        let count = Double(SpectrumFrame.curveCount)
        let edge = { (index: Double) in Self.curveLow * pow(Self.curveHigh / Self.curveLow, index / count) }
        curveBands = (0..<SpectrumFrame.curveCount).map { (bins(edge(Double($0))), bins(edge(Double($0) + 1))) }
        // Music has far less energy up high; +4.5 dB per octave (around 1 kHz) levels it out,
        // the same slope analyzers like the one in the reference use.
        tilt = (0..<SpectrumFrame.curveCount).map { index in
            Float(4.5 * log2(sqrt(edge(Double(index)) * edge(Double(index) + 1)) / 1000))
        }
        hop = max(Self.fftSize / 2, Int(sampleRate / 30))
        beats = BeatTracker(sampleRate: sampleRate)
        self.publish = publish
        samples.reserveCapacity(Self.fftSize * 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func process(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        guard frames > 0 else { return }

        // Mix every channel of every buffer down to mono.
        let start = samples.count
        samples.append(contentsOf: repeatElement(0, count: frames))
        var channelCount = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            for channel in 0..<channels {
                for frame in 0..<count {
                    samples[start + frame] += data[frame * channels + channel]
                }
            }
            channelCount += channels
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for index in start..<samples.count { samples[index] *= scale }
        }
        // The beat goes out with the next frame.
        frame.pulse = beats.listen(to: samples[start...], at: Date().timeIntervalSinceReferenceDate)

        // Keep the latest window and analyze it every `hop` new samples (windows overlap).
        if samples.count > Self.fftSize { samples.removeFirst(samples.count - Self.fftSize) }
        sinceAnalysis += frames
        if samples.count == Self.fftSize, sinceAnalysis >= hop {
            sinceAnalysis = 0
            analyze(samples)
        }
    }

    private func analyze(_ window: [Float]) {
        let rms = vDSP.rootMeanSquare(window)
        let decibels = 20 * log10(max(rms, 1e-7))
        let silent = decibels < -60
        // Overall loudness, measured against the recent peak (auto-gain), sets how tall the
        // bars can get: they fill at any player volume, and quiet passages still sit lower.
        loudnessPeak = max(decibels, loudnessPeak - 0.03)
        let loudness = silent ? 0 : Self.clamp(1 - (loudnessPeak - decibels) / 24)
        let power = spectrum(of: window)

        for (index, band) in barBands.enumerated() {
            let level = 10 * log10(max(Self.power(power, band), 1e-12))
            barPeaks[index] = max(level, barPeaks[index] - 0.1)
            let shape = Self.clamp(1 - (barPeaks[index] - level) / 12)
            let target = loudness * (0.15 + 0.85 * shape)
            // Ease toward the target, quicker up than down: lively, without the flicker.
            frame.bars[index] += (target - frame.bars[index]) * (target > frame.bars[index] ? 0.6 : 0.22)
        }

        let raw = curveBands.indices.map { 10 * log10(max(Self.power(power, curveBands[$0]), 1e-12)) + tilt[$0] }
        curvePeak = max(raw.max() ?? -120, curvePeak - 0.2)
        for index in raw.indices {
            // Blend with neighbours so the curve reads as one smooth line.
            let smoothed = 0.25 * raw[max(index - 1, 0)] + 0.5 * raw[index] + 0.25 * raw[min(index + 1, raw.count - 1)]
            let target = silent ? 0 : Self.clamp((smoothed - (curvePeak - 40)) / 40)
            frame.curve[index] += (target - frame.curve[index]) * (target > frame.curve[index] ? 0.55 : 0.18)
            frame.hold[index] = max(frame.curve[index], frame.hold[index] - 0.012)
        }
        // Capture that was denied delivers pure silence, so this also tells the view it's live.
        publish(frame, !silent)
    }

    /// Power per FFT bin for one Hann-windowed block.
    private func spectrum(of block: [Float]) -> [Float] {
        let half = Self.fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        let windowed = vDSP.multiply(block, window)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        return power
    }

    /// Mean power across a band; bands narrower than one bin interpolate between neighbours.
    private static func power(_ power: [Float], _ band: (low: Double, high: Double)) -> Float {
        let first = Int(band.low.rounded(.up)), last = Int(band.high.rounded(.down))
        if last >= first {
            return power[first...last].reduce(0, +) / Float(last - first + 1)
        }
        let center = (band.low + band.high) / 2
        let index = Int(center)
        let fraction = Float(center - Double(index))
        return power[index] * (1 - fraction) + power[min(index + 1, power.count - 1)] * fraction
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
