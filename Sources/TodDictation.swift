import Accelerate
import AppKit
import AVFoundation
import Speech
import SwiftUI

/// Oyl's own dictation, for the to-do list: what you say, taken down as you say it by the Mac's
/// speech recognition (on the Mac itself where it can be) through the microphone. It stops by
/// itself once you've stopped talking, hands over the words and lets go of the microphone;
/// nothing's kept. It asks for speech recognition and the microphone the first time it's
/// started, never before, and does nothing at all while it isn't listening.
@MainActor
final class TodDictation: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        /// The microphone's been let go; waiting a moment on the recognizer's last word.
        case finishing
        /// It can't listen, and what to do about it (`openSettings` opens where to do it).
        case unavailable(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// What's been said, as it's heard (redrawn at most ten times a second), and once it's over,
    /// the words handed over. Emptied when it starts again or is cancelled.
    @Published private(set) var transcript = ""
    var isListening: Bool { phase == .listening || phase == .finishing }
    /// Your voice, 0...1, while the microphone's open, else nil. Not published: it's read as it's
    /// drawn.
    private(set) var level: Float?
    /// The orange macOS shows for a microphone in use.
    static let tint = Color(red: 1, green: 0.62, blue: 0.04)
    /// Given what was said once it's over, if anything was.
    var onFinished: ((String) -> Void)?

    /// How long it waits for more once something's been said, and for anything at all at first;
    /// the longest it listens; how long it waits on the recognizer's last word once the
    /// microphone's let go (then it goes with what it has); and the least time between redraws.
    static let pause: TimeInterval = 1.8
    static let silence: TimeInterval = 6
    static let longest: TimeInterval = 90
    static let lastWord: TimeInterval = 2
    static let redraw: TimeInterval = 0.1

    private let ear: Ear
    private let clock: Clock
    private var session = 0          // each start's number, so a late word from an earlier one is ignored
    private var asking = false       // for speech recognition and the microphone, before listening
    private var said = Said()
    private var began = Date.distantPast
    private var lastNew: Date?       // when new words were last heard
    private var letGo: Date?         // when the microphone was let go
    private var shown = Date.distantPast
    private var unshown = false      // words heard but not yet in `transcript`
    /// Where `openSettings` goes: the settings for what's keeping it from listening.
    private(set) var settings = Trouble.speechDenied.settings

    /// The microphone and the Mac's speech recognizer, and the Mac's clock, unless tests stand in
    /// for them.
    init(ear: Ear? = nil, clock: Clock? = nil) {
        self.ear = ear ?? SpeechEar()
        self.clock = clock ?? SystemClock()
    }

    /// Starts listening, first asking for speech recognition and the microphone if it never has.
    /// `hints` are words it's likely to hear and might otherwise get wrong, like the lists' names.
    func start(hints: [String]) {
        guard !isListening, !asking else { return }
        session += 1
        let id = session
        asking = true
        if phase != .idle { phase = .idle }
        if !transcript.isEmpty { transcript = "" }
        ear.ask { [weak self] trouble in
            guard let self, self.asking, self.session == id else { return }
            self.asking = false
            if let trouble {
                self.cannot(trouble)
            } else {
                self.listen(hints: Self.phrases(hints), id)
            }
        }
    }

    /// Stops listening now, handing over what was said once the recognizer's had its last word
    /// (or at once, if it's already being waited on).
    func stop() {
        if asking {
            asking = false
            ear.stop()   // so the microphone isn't asked for once speech recognition's answered
            return
        }
        switch phase {
        case .listening: finish()
        case .finishing: end()
        default: break
        }
    }

    /// Stops and drops what was said.
    func cancel() {
        if isListening || asking { ear.stop() }
        asking = false
        level = nil
        if phase != .idle { phase = .idle }
        if !transcript.isEmpty { transcript = "" }
        wake()
    }

    func toggle(hints: [String]) {
        if isListening || asking {
            stop()
        } else {
            start(hints: hints)
        }
    }

    /// The settings that would let it listen: Privacy & Security's speech recognition or
    /// microphone, or Keyboard's dictation, or Sound's input.
    func openSettings() {
        if let url = URL(string: settings) { NSWorkspace.shared.open(url) }
    }

    // MARK: - listening

    private func listen(hints: [String], _ id: Int) {
        said = Said()
        lastNew = nil
        letGo = nil
        unshown = false
        shown = .distantPast
        began = clock.now
        if let trouble = ear.listen(hints: hints, heard: { [weak self] heard in self?.hear(heard, in: id) }) {
            cannot(trouble)
            return
        }
        phase = .listening
        level = 0
        wake()
    }

    private func hear(_ heard: Heard, in id: Int) {
        guard id == session, isListening else { return }
        let now = clock.now
        switch heard {
        case .words(let words, let closed):
            // A new reading of the same words (a comma, a capital) isn't more being said.
            if said.take(words, closed: closed), phase == .listening { lastNew = now }
            unshown = said.text != transcript
            show(at: now)
            wake()
        case .final(let words):
            said.take(words, closed: true)
            end()
        case .failed(let trouble):
            if let trouble, said.text.isEmpty { cannot(trouble) } else { end() }
        case .loudness(let loudness):
            guard phase == .listening, let level else { return }
            // Quick to rise with your voice, slower to fall back.
            self.level = level + (loudness - level) * (loudness > level ? 0.6 : 0.2)
        case .lost:
            if said.text.isEmpty { cannot(.lostMicrophone) } else { finish() }
        }
    }

    /// Lets go of the microphone, and gives the recognizer a moment for its last word.
    private func finish() {
        guard phase == .listening else { return }
        phase = .finishing
        letGo = clock.now
        level = nil
        ear.finish()
        wake()
    }

    /// Over: everything let go, and what was said handed over.
    private func end() {
        let words = said.text
        ear.stop()
        level = nil
        unshown = false
        phase = .idle
        wake()
        if transcript != words { transcript = words }
        if !words.isEmpty { onFinished?(words) }
    }

    private func cannot(_ trouble: Trouble) {
        ear.stop()
        level = nil
        unshown = false
        settings = trouble.settings
        phase = .unavailable(trouble.advice)
        wake()
    }

    private func show(at now: Date) {
        guard unshown, now >= shown + Self.redraw else { return }
        transcript = said.text
        shown = now
        unshown = false
    }

    /// When it ends by itself unless more is heard: after a pause once something's been said,
    /// or the silence before anything is, or after `longest` whatever's said; or once it's
    /// given the recognizer a moment for its last word.
    private var endsAt: Date? {
        switch phase {
        case .listening: return min(began + Self.longest, lastNew.map { $0 + Self.pause } ?? began + Self.silence)
        case .finishing: return (letGo ?? began) + Self.lastWord
        default: return nil
        }
    }

    /// Sets the one timer for whatever's next: words held back to show, or the end. None while
    /// it isn't listening.
    private func wake() {
        let next = [endsAt, unshown ? shown + Self.redraw : nil].compactMap { $0 }.min()
        clock.wake(at: isListening ? next : nil) { [weak self] in self?.woke() }
    }

    private func woke() {
        let now = clock.now
        show(at: now)
        if let endsAt, now >= endsAt {
            if phase == .listening { finish() } else { end() }
        }
        wake()
    }

    /// Hints as the recognizer can use them: the words of each (a list's emoji left out), each
    /// once, and no more than a hundred (Apple's limit for them being of use).
    static func phrases(_ hints: [String]) -> [String] {
        var seen = Set<String>()
        var phrases: [String] = []
        for hint in hints {
            let phrase = hint.split { !($0.isLetter || $0.isNumber || "'&+-./".contains($0)) }.joined(separator: " ")
            guard !phrase.isEmpty, seen.insert(phrase.lowercased()).inserted else { continue }
            phrases.append(phrase)
            if phrases.count == 100 { break }
        }
        return phrases
    }

    // MARK: - what it listens through

    /// What it listens through: the microphone and the Mac's speech recognizer, or in tests, a
    /// stand-in. What's heard comes back through `heard`, on the main thread.
    @MainActor
    protocol Ear: AnyObject {
        /// Whether it may listen, asking for speech recognition and the microphone the first
        /// time: nil if it may, else what to do about it. Stopped before then, it needn't answer.
        func ask(_ answer: @escaping @MainActor @Sendable (Trouble?) -> Void)
        /// Starts taking down what's said: nil once it has, else why it couldn't.
        func listen(hints: [String], heard: @escaping @MainActor @Sendable (Heard) -> Void) -> Trouble?
        /// Lets go of the microphone and asks the recognizer for its last word on what was said.
        func finish()
        /// Lets go of everything, and drops any asking still waiting on an answer: nothing more is
        /// heard, or asked.
        func stop()
    }

    /// The time, and a call back at a given time: the Mac's own clock, or in tests, a stand-in.
    @MainActor
    protocol Clock: AnyObject {
        /// Only ever goes forward, so no deadline can be put off by the clock going back; its dates
        /// are only measured against each other.
        var now: Date { get }
        /// Calls `wake` at `date`, instead of whatever it was going to call; nil calls nothing.
        func wake(at date: Date?, _ wake: @escaping @MainActor @Sendable () -> Void)
    }

    /// What's been heard.
    enum Heard: Equatable, Sendable {
        /// The recognizer's latest reading of what's being said; `closed` once it's moved on
        /// from this stretch of it.
        case words(String, closed: Bool)
        /// Its last word, after the microphone's let go (or when it's decided it's heard it all).
        case final(String)
        /// It stopped short: what to do about it, or nil if it just heard nothing.
        case failed(Trouble?)
        /// How loud the microphone is, 0...1.
        case loudness(Float)
        /// The microphone went away and couldn't be picked up again.
        case lost
    }

    /// What's keeping it from listening, as what to do about it, and the settings to do it in.
    struct Trouble: Equatable, Sendable {
        let advice: String
        let settings: String

        private static let privacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_"
        private static let keyboard = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        private static let sound = "x-apple.systempreferences:com.apple.Sound-Settings.extension"

        static let speechDenied = Trouble(advice: "Allow Oyl speech recognition in Privacy & Security",
                                          settings: privacy + "SpeechRecognition")
        static let speechRestricted = Trouble(advice: "Speech recognition is turned off on this Mac",
                                              settings: privacy + "SpeechRecognition")
        static let microphoneDenied = Trouble(advice: "Allow Oyl the microphone in Privacy & Security",
                                              settings: privacy + "Microphone")
        static let microphoneRestricted = Trouble(advice: "The microphone is turned off on this Mac",
                                                  settings: privacy + "Microphone")
        static let noMicrophone = Trouble(advice: "No microphone to listen with: plug one in and try again", settings: sound)
        static let lostMicrophone = Trouble(advice: "Lost the microphone: try again", settings: sound)
        static let dictationOff = Trouble(advice: "Turn on Dictation in Keyboard settings", settings: keyboard)
        static let notNow = Trouble(advice: "Speech recognition isn't available right now: try again soon", settings: keyboard)
        static let misheard = Trouble(advice: "Couldn't make that out: try again", settings: keyboard)

        /// Asking for either without saying why in Info.plist would end Oyl on the spot.
        static func undescribed(_ key: String) -> Trouble {
            Trouble(advice: "Oyl's Info.plist needs \(key) first", settings: privacy + "SpeechRecognition")
        }
    }

    /// What's been said, put together from the recognizer's readings. Each reading is usually all
    /// of it so far, but after a pause the recognizer can start afresh with only the newest words
    /// (saying it's moved on, or not), and then have its last word on just the stretch it moved on
    /// from: the stretches before are kept here, so nothing said is lost, or kept twice.
    struct Said: Equatable {
        private(set) var stretches: [String] = []   // the ones the recognizer's moved on from
        private(set) var current = ""               // the one it's on, as it last read it

        var text: String { (stretches + [current]).filter { !$0.isEmpty }.joined(separator: " ") }

        /// Takes in the recognizer's latest reading (`closed` once it's moved on from it), and says
        /// whether it has words the reading it follows hadn't: not just a comma or a capital.
        @discardableResult
        mutating func take(_ words: String, closed: Bool) -> Bool {
            let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
            var was = current
            if !Self.key(words).isEmpty {
                if current.isEmpty, closed, let from = readAgain(words) {
                    // What it had moved on from, read again: often its last word on a stretch.
                    was = stretches[from...].joined(separator: " ")
                    stretches.removeSubrange(from...)
                } else if !stretches.isEmpty, Self.begins(words, with: stretches.joined(separator: " ")) {
                    // All of it again, the earlier stretches too. Straight after one closes, it's
                    // more being said: the same words said again are still words said.
                    if !current.isEmpty { was = text }
                    stretches = []
                } else if Self.startsAfresh(words, after: current) {
                    stretches.append(current)
                }
                current = words
            }
            let new = Self.key(current) != Self.key(was)
            if closed, !current.isEmpty {
                stretches.append(current)
                current = ""
            }
            return new
        }

        /// Where the latest stretches that a reading closed straight off reads again begin, if it
        /// reads any again: those it begins with, or keeps two thirds of the letters of in order
        /// (of theirs or its own, whichever's more), and of those, the ones closest to it. Nil if
        /// it's a stretch of its own: "Call mom's doctor." after "Call mom." is, "Buy eggs and
        /// milk." after "By eggs an milk." isn't.
        private func readAgain(_ words: String) -> Int? {
            var closest: (from: Int, off: Int)?
            for from in stretches.indices {
                let those = stretches[from...].joined(separator: " ")
                let longer = max(Self.key(words).count, Self.key(those).count)
                let kept = Self.common(words, those).inOrder
                guard Self.begins(words, with: those) || kept * 3 >= longer * 2 else { continue }
                if longer - kept <= closest?.off ?? .max { closest = (from, longer - kept) }
            }
            return closest?.from
        }

        /// Whether a reading is a fresh start rather than a second thought on the last one.
        /// Second thoughts mostly change the last words, and readings grow; a fresh start comes
        /// in a word or two at a time, after a stretch of some length: fewer words, and either
        /// under half the letters, or (after four words or more) a different first word, unless
        /// the rest runs on much as before: a second thought running letters or numbers together
        /// ("A s a study night Friday", then "AASA study night Friday").
        static func startsAfresh(_ words: String, after last: String) -> Bool {
            let new = words.lowercased().split { !$0.isLetter && !$0.isNumber }
            let old = last.lowercased().split { !$0.isLetter && !$0.isNumber }
            guard new.count < old.count else { return false }
            if key(words).count * 2 < key(last).count { return true }
            return old.count >= 4 && new.first != old.first
                && common(words, last).run * 2 <= min(key(words).count, key(last).count)
        }

        /// Whether a reading begins with all of the earlier words, ending where a word of its own
        /// does: "Buy milk. Call" begins with "Buy milk.", "Call mom's" doesn't with "Call mom."
        static func begins(_ words: String, with earlier: String) -> Bool {
            let earlier = key(earlier)
            var start = ""
            for word in words.split(whereSeparator: \.isWhitespace) {
                start += key(String(word))
                if start == earlier { return true }
                if !earlier.hasPrefix(start) { return false }
            }
            return false
        }

        /// The letters and digits two readings have in common: the longest unbroken run of them
        /// (which readings that only happen to be alike rarely share), and how many in order, gaps
        /// and all (which second thoughts in a few places keep). The usual tables, a row at a time.
        static func common(_ one: String, _ other: String) -> (run: Int, inOrder: Int) {
            let one = Array(key(one).unicodeScalars), other = Array(key(other).unicodeScalars)
            var runs = [Int](repeating: 0, count: other.count + 1), inOrder = runs
            var longest = 0
            for letter in one {
                var (runBefore, inOrderBefore) = (0, 0)   // the row above, a letter back
                for (at, theirs) in other.enumerated() {
                    let (run, kept) = (runs[at + 1], inOrder[at + 1])
                    if letter == theirs {
                        runs[at + 1] = runBefore + 1
                        inOrder[at + 1] = inOrderBefore + 1
                    } else {
                        runs[at + 1] = 0
                        inOrder[at + 1] = max(inOrder[at], kept)
                    }
                    longest = max(longest, runs[at + 1])
                    (runBefore, inOrderBefore) = (run, kept)
                }
            }
            return (longest, inOrder[other.count])
        }

        /// Just the letters and digits, lowercased, for telling whether the words have changed.
        static func key(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
        }
    }
}

// MARK: - the real thing

/// The microphone and the Mac's speech recognizer (in the Mac's language if it has one for it,
/// else American English), set up afresh each time it listens and let go of when it's done.
@MainActor
private final class SpeechEar: TodDictation.Ear {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    /// Also cancelled when the ear goes (with the dictation), wherever that happens.
    nonisolated(unsafe) private var task: SFSpeechRecognitionTask?
    private var microphone: Microphone?
    private var asked = 0   // each ask's number; stopping moves it on, so an answer still to come goes no further

    deinit {
        task?.cancel()
    }

    func ask(_ answer: @escaping @MainActor @Sendable (TodDictation.Trouble?) -> Void) {
        asked += 1
        let id = asked
        for key in ["NSSpeechRecognitionUsageDescription", "NSMicrophoneUsageDescription"]
        where Bundle.main.object(forInfoDictionaryKey: key) == nil {
            return answer(.undescribed(key))
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                let ear = self
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Stopped while this was up: then no asking for the microphone after it.
                        guard let ear, ear.asked == id else { return }
                        if status == .notDetermined { answer(.speechDenied) } else { ear.ask(answer) }
                    }
                }
            }
            return
        case .denied: return answer(.speechDenied)
        case .restricted: return answer(.speechRestricted)
        default: break
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                let ear = self
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let ear, ear.asked == id else { return }
                        answer(allowed ? nil : .microphoneDenied)
                    }
                }
            }
        case .denied: answer(.microphoneDenied)
        case .restricted: answer(.microphoneRestricted)
        default: answer(nil)
        }
    }

    func listen(hints: [String], heard: @escaping @MainActor @Sendable (TodDictation.Heard) -> Void) -> TodDictation.Trouble? {
        stop()
        guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { return .notNow }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = hints
        // On the Mac itself where it can be, so what's said doesn't leave it.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let task = recognizer.recognitionTask(with: request, resultHandler: Self.results(heard))
        guard let microphone = Microphone(feeding: request, heard: heard) else {
            task.cancel()
            return .noMicrophone
        }
        self.recognizer = recognizer
        self.request = request
        self.task = task
        self.microphone = microphone
        return nil
    }

    func finish() {
        microphone?.close()
        microphone = nil
        request?.endAudio()
    }

    func stop() {
        asked += 1
        microphone?.close()
        microphone = nil
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
    }

    /// The recognizer's readings, as what's heard, passed to the main thread.
    nonisolated private static func results(_ heard: @escaping @MainActor @Sendable (TodDictation.Heard) -> Void)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            var said: [TodDictation.Heard] = []
            if let result {
                let words = result.bestTranscription.formattedString
                said.append(result.isFinal ? .final(words) : .words(words, closed: result.speechRecognitionMetadata != nil))
            }
            if let error, result?.isFinal != true { said.append(.failed(trouble(error))) }
            guard !said.isEmpty else { return }
            let heardAll = said
            DispatchQueue.main.async {
                MainActor.assumeIsolated { heardAll.forEach(heard) }
            }
        }
    }

    /// Nil for hearing nothing, or for being stopped; else what to do.
    nonisolated private static func trouble(_ error: Error) -> TodDictation.Trouble? {
        let error = error as NSError
        switch (error.domain, error.code) {
        case ("kAFAssistantErrorDomain", 1110), ("kAFAssistantErrorDomain", 216), ("kAFAssistantErrorDomain", 203),
             ("kLSRErrorDomain", 301):
            return nil  // no speech, cancelled, or nothing to retry
        case ("kLSRErrorDomain", 201):
            return .dictationOff
        default:
            return error.localizedDescription.lowercased().contains("disabled") ? .dictationOff : .misheard
        }
    }
}

/// The microphone, through an audio engine tapping its input: the sound goes to the recognizer,
/// and how loud it is to the meter. If the input changes under it (a headset plugged in or taken
/// out), it picks up the new one, or if it can't, gives up and says so. Touched only on the main
/// thread, apart from its tap.
private final class Microphone: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let heard: @MainActor @Sendable (TodDictation.Heard) -> Void
    private var change: NSObjectProtocol?
    private var format: AVAudioFormat?   // what the recognizer's been given, kept to the first input's
    private var reopened = 0

    init?(feeding request: SFSpeechAudioBufferRecognitionRequest, heard: @escaping @MainActor @Sendable (TodDictation.Heard) -> Void) {
        self.request = request
        self.heard = heard
        guard open() else { return nil }
    }

    deinit {
        close()
    }

    /// A new engine each time: one whose input has changed can go on giving the old one's format.
    private func open() -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        let request = request, heard = heard
        let converter = SoundConverter(to: self.format ?? format)
        // The input's own format (nil), so a tap never asks for one the hardware hasn't got.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            if let sound = converter.convert(buffer) { request.append(sound) }
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let rms = vDSP.rootMeanSquare(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            // From a quiet room to speaking up close.
            let decibels = 20 * log10(max(rms, 1e-7))
            let loudness = min(max((decibels + 55) / 40, 0), 1)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { heard(.loudness(loudness)) }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
        self.engine = engine
        self.format = self.format ?? format
        change = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                        queue: .main) { [weak self] _ in
            self?.reopen()
        }
        return true
    }

    /// After the input's changed: the engine's stopped itself, so it starts again on the new
    /// input. A few times at most, in case it keeps changing.
    private func reopen() {
        guard engine != nil else { return }
        close()
        reopened += 1
        if reopened <= 5, open() { return }
        MainActor.assumeIsolated { heard(.lost) }
    }

    /// Lets go of it: the tap off and the engine stopped, so macOS's orange dot goes too.
    func close() {
        if let change { NotificationCenter.default.removeObserver(change) }
        change = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

/// The sound in the format the recognizer was first given, whatever the input gives now: one
/// request is best kept to one format, and a new input (a headset's) can have another. Sound
/// already in it goes straight through. Touched only on the audio thread of the tap it's in.
final class SoundConverter {
    let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to format: AVAudioFormat) {
        self.format = format
    }

    /// Nil if there was nothing to convert, or it couldn't be.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
        }
        guard let converter, buffer.frameLength > 0 else { return nil }
        let frames = (Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames) + 64) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            // This buffer, then nothing for now: the converter keeps its place for the next.
            if given {
                state.pointee = .noDataNow
                return nil
            }
            given = true
            state.pointee = .haveData
            return buffer
        }
        return status != .error && out.frameLength > 0 ? out : nil
    }
}

extension TodDictation {
    /// The Mac's clock, with one timer at most. Its time is how long the Mac's been up, which
    /// only goes forward: setting the Mac's clock back while it's listening can't keep the
    /// microphone open past `longest`.
    @MainActor
    final class SystemClock: Clock {
        private var timer: Timer?

        var now: Date { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) }

        func wake(at date: Date?, _ wake: @escaping @MainActor @Sendable () -> Void) {
            timer?.invalidate()
            timer = nil
            guard let date else { return }
            // In so long from now, not at a date on the Mac's clock, which can be set back.
            let timer = Timer(timeInterval: max(date.timeIntervalSince(now), 0), repeats: false) { _ in
                MainActor.assumeIsolated { wake() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
}
