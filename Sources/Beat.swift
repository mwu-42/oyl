import Foundation

/// The song's beat, for Oyls to bop to. Set by `AudioSpectrum` as frames arrive; read while
/// drawing, so nothing re-renders for it.
@MainActor
enum Beat {
    /// The bass level the visualizer shows, 0...1.
    static var level: Float = 0
    /// Its four bars, bass to treble, for the music Oyl's little visualizer.
    static var bars: [Float] = []
    /// The beat itself, while the music has a steady one.
    static var pulse: Pulse?

    /// Where `time` is in the beat, counting from any one of them: the whole part says which
    /// beat, the fraction how far through it. Nil without a steady beat.
    static func position(at time: TimeInterval) -> Double? {
        pulse.map { (time - $0.beat) / $0.period }
    }
}

/// The music's beat: how long each one lasts, and when one fell (as
/// `Date.timeIntervalSinceReferenceDate`); the rest fall every `period` either side.
struct Pulse: Sendable, Equatable {
    var period: TimeInterval
    var beat: TimeInterval
}

/// Finds the beat in the music as it plays: how sharply the sound jumps, a hundred times a
/// second, in four bands (the kick drum counting most), the tempo those jumps repeat at over the
/// last few seconds, and where the beats fall, kept steady from moment to moment. Only touched on
/// the audio tap's queue.
struct BeatTracker {
    /// How far back it listens, and the tempos it looks for, in beats a minute.
    private static let span: TimeInterval = 6
    private static let tempos = 70.0...180.0
    /// Moments a second it measures.
    private static let rate = 100.0

    /// Where it listens for jumps, and how much each counts: the kick, the snare's body, the
    /// middle, and the snare's crack.
    private var filters: [Filter]
    private let weights: [Float] = [1, 0.6, 0.4, 0.5]
    private let block: Int                // samples a moment
    private let sampleRate: Double
    private let smoothing: Float          // of each band's energy, sample to sample
    private var filled = 0                // samples into this moment
    private var energy: [Float]           // per band, smoothed over about 10 ms
    private var loudest: [Float]          // lately, per band, to measure against
    private var previous: [Float] = []    // last moment's band levels
    private var onsets: [Float] = []      // how sharply each moment jumped, oldest first
    private var latest: TimeInterval = 0  // when the last moment ended
    private var moments = 0
    private var quiet = 0                 // silent moments in a row
    private var misses = 0                // tempo checks in a row that found none
    private var period: TimeInterval?
    private var candidate: TimeInterval?  // a different tempo, heard once
    private var beat: TimeInterval?

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        block = max(Int(sampleRate / Self.rate), 1)
        smoothing = Float(1 - exp(-1 / (sampleRate * 0.01)))
        filters = [.lowPass(150, sampleRate: sampleRate), .bandPass(150, 400, sampleRate: sampleRate),
                   .bandPass(400, 1500, sampleRate: sampleRate), .highPass(1500, sampleRate: sampleRate)]
        energy = .init(repeating: 0, count: filters.count)
        loudest = .init(repeating: 1e-9, count: filters.count)
    }

    /// The newest samples (mono), the last of them played at `now`: the beat, if it's found a
    /// steady one.
    mutating func listen(to samples: ArraySlice<Float>, at now: TimeInterval) -> Pulse? {
        var index = samples.startIndex
        for sample in samples {
            for band in filters.indices {
                let filtered = filters[band].run(sample)
                energy[band] += (filtered * filtered - energy[band]) * smoothing
            }
            filled += 1
            index += 1
            if filled == block {
                measure(endingAt: now - Double(samples.endIndex - index) / sampleRate)
                filled = 0
            }
        }
        guard let period, let beat else { return nil }
        return Pulse(period: period, beat: beat)
    }

    /// The moment just heard: how sharply it jumped, against the one before, in each band (as
    /// a share of how loud that band's been lately, so quiet noise barely counts). Each band's
    /// energy is smoothed first: measured raw, a held bass note's ripples like a beat.
    private mutating func measure(endingAt time: TimeInterval) {
        latest = time
        let levels = energy.indices.map { band -> Float in
            loudest[band] = max(energy[band], loudest[band] * 0.999)
            return log10(1 + 1000 * energy[band] / loudest[band])
        }
        let silent = energy.reduce(0, +) < 1e-6
        var jump: Float = 0
        if previous.count == levels.count, !silent {
            for band in levels.indices { jump += weights[band] * max(0, levels[band] - previous[band]) }
        }
        previous = levels
        // A gap, as between songs: start again with the next.
        quiet = silent ? quiet + 1 : 0
        if Double(quiet) > Self.rate / 2 {
            onsets = []
            lose()
            return
        }
        onsets.append(jump)
        if Double(onsets.count) > Self.span * Self.rate { onsets.removeFirst() }
        moments += 1
        if moments % Int(Self.rate / 2) == 0, Double(onsets.count) >= 3 * Self.rate { findTempo() }
        if let period { follow(period) }
    }

    /// The tempo: the beat length the jumps line up best with, a beat apart and two, a little in
    /// favor of about 120 a minute where a song could be counted either way.
    private mutating func findTempo() {
        let smoothed = Self.smoothed(onsets)
        let mean = smoothed.reduce(0, +) / Float(smoothed.count)
        let jumps = smoothed.map { max($0 - mean, 0) }
        func correlation(_ lag: Int) -> Float {
            guard lag < jumps.count else { return 0 }
            var sum: Float = 0
            for index in lag..<jumps.count { sum += jumps[index] * jumps[index - lag] }
            return sum / Float(jumps.count - lag)
        }
        // Jumps too small to be drums (a held note's slow swell) don't count.
        let itself = correlation(0)
        guard itself > 0.002 else { return miss() }
        let lags = Array(Int(Self.rate * 60 / Self.tempos.upperBound)...Int((Self.rate * 60 / Self.tempos.lowerBound).rounded(.up)))
        let scores = lags.map { lag -> Float in
            let tempo = Self.rate * 60 / Double(lag)
            return (correlation(lag) + 0.5 * correlation(2 * lag)) * Float(exp(-0.5 * pow(log2(tempo / 120), 2)))
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return miss() }
        // Only if it stands out, from the other tempos and against the jumps themselves: a
        // tune with no drums, its notes coming whenever, mostly doesn't.
        let median = scores.sorted()[scores.count / 2]
        guard scores[best] > 4 * median, scores[best] > 0.55 * itself else { return miss() }
        // Between whole frames, from the two either side.
        var lag = Double(lags[best])
        if best > 0, best < scores.count - 1 {
            let before = scores[best - 1], after = scores[best + 1]
            let bend = before - 2 * scores[best] + after
            if bend < 0 { lag += Double(0.5 * (before - after) / bend) }
        }
        settle(on: lag / Self.rate)
    }

    /// Takes up a tempo it's heard: eased toward, near the one it has; switched to, if it's
    /// heard a different one twice running.
    private mutating func settle(on heard: TimeInterval) {
        misses = 0
        guard let period else {
            period = heard
            return
        }
        if abs(heard - period) / period < 0.06 {
            self.period = period + (heard - period) * 0.2
            candidate = nil
        } else if let candidate, abs(heard - candidate) / candidate < 0.06 {
            self.period = heard
            self.candidate = nil
        } else {
            candidate = heard
        }
    }

    /// A couple of seconds without a steady beat, and it's lost it.
    private mutating func miss() {
        misses += 1
        if misses >= 4 { lose() }
    }

    private mutating func lose() {
        period = nil
        candidate = nil
        beat = nil
        misses = 0
    }

    /// Where the beats fall: where in a beat the last few beats' jumps line up best, the beat
    /// nudged a little toward that each moment so it keeps steady.
    private mutating func follow(_ period: TimeInterval) {
        let jumps = Self.smoothed(onsets), length = period * Self.rate
        let offsets = Int(length.rounded(.up))
        let scores = (0..<offsets).map { offset -> Float in
            var score: Float = 0, weight: Float = 1
            for count in 0..<8 {
                let index = jumps.count - 1 - offset - Int((Double(count) * length).rounded())
                guard index >= 0 else { break }
                score += jumps[index] * weight
                weight *= 0.8
            }
            return score
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return }
        var offset = Double(best)
        let before = scores[(best + offsets - 1) % offsets], after = scores[(best + 1) % offsets]
        let bend = before - 2 * scores[best] + after
        if bend < 0 { offset += Double(0.5 * (before - after) / bend) }
        // (Smoothing the energy makes each jump come a touch late.)
        let heard = latest - offset / Self.rate - 0.008
        var beat = self.beat ?? heard
        // How far off, in beats, from the nearest it had.
        var error = (heard - beat) / period
        error -= error.rounded()
        beat += error * period * 0.05
        beat += ((latest - beat) / period).rounded(.down) * period
        self.beat = beat
    }

    /// Softened a little, for timing that's a touch off.
    private static func smoothed(_ values: [Float]) -> [Float] {
        let taps: [Float] = [1, 2, 3, 2, 1]
        return values.indices.map { index in
            var sum: Float = 0, total: Float = 0
            for (tap, weight) in taps.enumerated() {
                let at = index + tap - 2
                guard values.indices.contains(at) else { continue }
                sum += values[at] * weight
                total += weight
            }
            return sum / total
        }
    }
}

/// A second-order filter (the audio cookbook's), for picking out a band.
private struct Filter {
    let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = Float(b0 / a0)
        self.b1 = Float(b1 / a0)
        self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0)
        self.a2 = Float(a2 / a0)
    }

    static func lowPass(_ frequency: Double, sampleRate: Double) -> Filter {
        let w = 2 * .pi * frequency / sampleRate, alpha = sin(w) / (2 * 0.7071), c = cos(w)
        return Filter(b0: (1 - c) / 2, b1: 1 - c, b2: (1 - c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    static func highPass(_ frequency: Double, sampleRate: Double) -> Filter {
        let w = 2 * .pi * frequency / sampleRate, alpha = sin(w) / (2 * 0.7071), c = cos(w)
        return Filter(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    static func bandPass(_ low: Double, _ high: Double, sampleRate: Double) -> Filter {
        let center = (low * high).squareRoot(), w = 2 * .pi * center / sampleRate
        let alpha = sin(w) / (2 * center / (high - low)), c = cos(w)
        return Filter(b0: alpha, b1: 0, b2: -alpha, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    mutating func run(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}
