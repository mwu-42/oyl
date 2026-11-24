import AppKit
import Combine

/// A sound when a Claude's done: one as it finishes its turn (it was at work, and now it's done),
/// another as it starts waiting for you (a permission, a question, a plan to look over). Each place
/// a Claude runs (VS Code, Terminal, the Claude app, Cowork…) can have its own (see `ChimeSettings`):
/// one of Oyl's own low, round tones (see `ChimeTone`), one of macOS's, any sound file put in
/// Oyl's sounds folder, or none. Not for one you're looking at already (its app in front, and in an
/// editor, its folder's window), not while Oyl's off, not for one first seen already done or waiting
/// (as Oyl starts), and never more than one a second and a half, however many finish together. On
/// the Agents settings, off to begin with.
@MainActor
final class AgentChimes {
    enum Kind: Equatable {
        case done, waiting
    }

    private var last: [String: AgentActivity] = [:]
    private var lastChime = Date.distantPast
    static let apart: TimeInterval = 1.5

    /// What `from` becoming `to` sounds like, if anything: done after being at work; waiting, newly.
    nonisolated static func chime(from old: AgentActivity?, to new: AgentActivity) -> Kind? {
        guard let old, old != new else { return nil }
        if new == .waiting { return .waiting }
        if old.priority == 2, new == .done || new == .idle { return .done }
        return nil
    }

    /// Editors with a window for each folder, its name in the window's title.
    static let editors = ["VS Code", "Cursor", "Windsurf"]

    /// Whether you're looking at `session` already: the app it runs in is in front, and in an
    /// editor, the window in front is its folder's (VS Code's titles end with the folder's name).
    static func isInFront(_ session: AgentSession) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let app = (session.pid > 0 ? AgentWindow.hostApp(of: session.pid) : nil) ?? Self.app(named: session.host)
        guard let app, app.processIdentifier == front.processIdentifier else { return false }
        guard let host = session.host, editors.contains(host), !session.project.isEmpty else { return true }
        guard let title = focusedTitle(of: front.processIdentifier) else { return true }
        return Self.title(title, names: session.project)
    }

    /// Whether a window's title (as an editor's: "NotchView.swift — Oyl") names `folder`.
    nonisolated static func title(_ title: String, names folder: String) -> Bool {
        let parts = title.replacingOccurrences(of: " – ", with: " — ").replacingOccurrences(of: " - ", with: " — ")
            .components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.contains { $0.caseInsensitiveCompare(folder) == .orderedSame || $0.hasPrefix(folder + " ") || $0.hasPrefix(folder + " (") }
    }

    private static func app(named host: String?) -> NSRunningApplication? {
        let ids: [String: String] = ["VS Code": "com.microsoft.VSCode", "Terminal": "com.apple.Terminal", "iTerm": "com.googlecode.iterm2",
                                     "Ghostty": "com.mitchellh.ghostty", "Warp": "dev.warp.Warp-Stable", "Claude app": "com.anthropic.claudefordesktop",
                                     "Cowork": "com.anthropic.claudefordesktop"]
        guard let host, let id = ids[host] else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    /// The title of the window in front in `pid`'s app, through accessibility.
    private static func focusedTitle(of pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    /// Where a session's coming from, as its sound's chosen by: the app it runs in.
    nonisolated static func source(of session: AgentSession) -> String { session.host ?? "Claude Code" }

    /// The sessions as they are now: a sound if one's just finished, or just begun waiting.
    func update(_ sessions: [AgentSession], theme: NotchTheme, isOff: Bool, at now: Date = Date()) {
        let before = last
        last = Dictionary(sessions.map { ($0.id, $0.activity) }, uniquingKeysWith: { _, latest in latest })
        let claudes = sessions.filter(\.isClaude)
        for session in claudes { ChimeSettings.shared.saw(Self.source(of: session)) }
        guard Feature.agentSounds.isOn, !isOff, now.timeIntervalSince(lastChime) >= Self.apart else { return }
        let heard = claudes.compactMap { session in Self.chime(from: before[session.id], to: session.activity).map { ($0, session) } }
        // Waiting for you says more than done.
        // None for one you're looking at already (its app in front, and in an editor, its window).
        let unseen = heard.filter { !Self.isInFront($0.1) }
        guard let (kind, session) = unseen.first(where: { $0.0 == .waiting }) ?? unseen.first else { return }
        lastChime = now
        ChimeSettings.shared.voice(for: Self.source(of: session)).play(kind, midnight: theme == .midnight)
    }
}

/// A sound to be played: one of Oyl's tones, one of macOS's, a file in the sounds folder, or none.
struct ChimeVoice: Equatable, Identifiable {
    let id: String
    let name: String

    static let round = ChimeVoice(id: "tone:round", name: "Low round")
    static let silent = ChimeVoice(id: "none", name: "Silent")
    static let tones = [round, ChimeVoice(id: "tone:hum", name: "Hum"), ChimeVoice(id: "tone:wood", name: "Wood"),
                        ChimeVoice(id: "tone:bell", name: "Soft bell")]

    /// Oyl's sounds folder: any sound file put in it can be chosen.
    nonisolated static func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/nott/sounds", isDirectory: true)
    }

    static let fileTypes: Set = ["wav", "aif", "aiff", "caf", "mp3", "m4a"]

    /// Every one there is: Oyl's tones, then the sounds folder's, then macOS's, then none.
    nonisolated static func all(folder: URL = folder()) -> [ChimeVoice] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { fileTypes.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { ChimeVoice(id: "file:" + $0.lastPathComponent, name: $0.deletingPathExtension().lastPathComponent) }
        let system = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
            .filter { fileTypes.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
            .map { ChimeVoice(id: "system:" + $0, name: $0) }
        return tones + files + system + [silent]
    }

    /// Made once each, Oyl's tones.
    @MainActor private static var made: [String: NSSound] = [:]

    @MainActor
    func sound(_ kind: AgentChimes.Kind, midnight: Bool) -> NSSound? {
        if id.hasPrefix("tone:") {
            let key = "\(id)-\(kind)-\(midnight)"
            if let made = Self.made[key] { return made }
            let made = NSSound(data: ChimeTone.wav(ChimeTone.notes(kind, style: String(id.dropFirst(5)), midnight: midnight)))
            Self.made[key] = made
            return made
        }
        if id.hasPrefix("system:") { return NSSound(named: NSSound.Name(String(id.dropFirst(7)))) }
        if id.hasPrefix("file:") {
            return NSSound(contentsOf: Self.folder().appendingPathComponent(String(id.dropFirst(5))), byReference: true)
        }
        return nil
    }

    @MainActor
    func play(_ kind: AgentChimes.Kind, midnight: Bool) {
        guard let sound = sound(kind, midnight: midnight) else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}

/// Which sound each place a Claude runs has: kept in the defaults, with the places seen so far (in
/// the order they were), each shown on the Agents settings while sounds are on. One with none of
/// its own sounds as everywhere else does.
@MainActor
final class ChimeSettings: ObservableObject {
    static let shared = ChimeSettings()

    static let elsewhere = "Everywhere else"
    static let sourcesKey = "chimes.sources"
    static let voicesKey = "chimes.voices"
    /// The most places kept (the oldest let go of past it).
    static let most = 12

    @Published private(set) var sources: [String]
    @Published private(set) var voices: [String: String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sources = defaults.stringArray(forKey: Self.sourcesKey) ?? []
        voices = defaults.dictionary(forKey: Self.voicesKey) as? [String: String] ?? [:]
    }

    /// A place a Claude's been seen running in.
    func saw(_ source: String) {
        guard !sources.contains(source), source != Self.elsewhere else { return }
        sources.append(source)
        if sources.count > Self.most { sources.removeFirst(sources.count - Self.most) }
        defaults.set(sources, forKey: Self.sourcesKey)
    }

    /// Its own, if it has one (or it's everywhere else's).
    func own(_ source: String, among all: [ChimeVoice] = ChimeVoice.all()) -> ChimeVoice? {
        voices[source].flatMap { id in all.first { $0.id == id } }
    }

    /// The sound `source` plays: its own, else everywhere else's, else Oyl's low round one.
    func voice(for source: String, among all: [ChimeVoice] = ChimeVoice.all()) -> ChimeVoice {
        own(source, among: all) ?? own(Self.elsewhere, among: all) ?? .round
    }

    /// The next (or last) sound for `source`, played to hear it. A place's own can also be none of
    /// its own: as everywhere else.
    func step(_ source: String, by steps: Int, among all: [ChimeVoice] = ChimeVoice.all()) {
        // Nil: as everywhere else (only for a place, not everywhere else itself).
        let choices: [ChimeVoice?] = (source == Self.elsewhere ? [] : [nil]) + all.map { Optional($0) }
        let now = source == Self.elsewhere ? Optional(voice(for: source, among: all)) : own(source, among: all)
        let at = choices.firstIndex { $0?.id == now?.id } ?? 0
        let next = choices[((at + steps) % choices.count + choices.count) % choices.count]
        voices[source] = next?.id
        defaults.set(voices, forKey: Self.voicesKey)
    }

    /// What `source`'s row says it is.
    func says(_ source: String) -> String {
        if source != Self.elsewhere, own(source) == nil { return "as everywhere else" }
        return voice(for: source).name
    }
}

/// Oyl's own soft tones, made as sound (16-bit, mono), low: around D3 to A3. Each note mostly a
/// pure tone, with a little of its overtones over it that fade sooner (warm, not bright), coming in
/// gently and dying away. Done is two notes stepping down, settled; waiting two stepping up, as a
/// question does. Four of them: low round, a hum, wood, a soft bell. In Midnight Oyl's, softer
/// still, slower to fade, with a faint shimmer.
enum ChimeTone {
    struct Note: Equatable {
        /// Its pitch, in hertz; when it starts, in seconds; how loud, 0 to 1.
        let pitch: Double
        let at: Double
        let level: Double
        /// How long it takes to come in, and to die away (to about a third).
        var attack = 0.012
        var fade = 0.2
        /// Its overtones: how many times its pitch, how loud, and how soon they fade (of its own).
        var overtones: [Overtone] = [Overtone(ratio: 2, level: 0.22, fade: 0.45)]
    }

    struct Overtone: Equatable {
        let ratio: Double
        let level: Double
        let fade: Double
    }

    static let rate = 44_100

    /// `kind` in `style` ("round", "hum", "wood", "bell").
    nonisolated static func notes(_ kind: AgentChimes.Kind, style: String = "round", midnight: Bool) -> [Note] {
        let soft = midnight ? 1.7 : 1.0
        let shimmer = midnight ? [Overtone(ratio: 6, level: 0.05, fade: 0.6)] : []
        let (first, second): (Double, Double) = kind == .done ? (220, 164.81) : (146.83, 220)
        func two(attack: Double, fade: Double, gap: Double, overtones: [Overtone], down: Double = 1) -> [Note] {
            [Note(pitch: first * down, at: 0, level: 0.32, attack: attack * soft, fade: fade * soft, overtones: overtones + shimmer),
             Note(pitch: second * down, at: gap * (midnight ? 1.2 : 1), level: 0.36, attack: attack * soft, fade: fade * soft * 1.25,
                  overtones: overtones + shimmer)]
        }
        switch style {
        case "hum":
            // One long low note for done; two soft pulses of it for waiting.
            let note = Note(pitch: 146.83, at: 0, level: 0.4, attack: 0.05 * soft, fade: 0.42 * soft,
                            overtones: [Overtone(ratio: 2, level: 0.12, fade: 0.6)] + shimmer)
            guard kind == .waiting else { return [note] }
            return [Note(pitch: 146.83, at: 0, level: 0.32, attack: 0.04 * soft, fade: 0.16 * soft, overtones: note.overtones),
                    Note(pitch: 146.83, at: 0.22, level: 0.36, attack: 0.04 * soft, fade: 0.3 * soft, overtones: note.overtones)]
        case "wood":
            return two(attack: 0.004, fade: 0.07, gap: 0.11,
                       overtones: [Overtone(ratio: 2, level: 0.35, fade: 0.5), Overtone(ratio: 3, level: 0.15, fade: 0.35)], down: 1.5)
        case "bell":
            return two(attack: 0.006, fade: 0.45, gap: 0.18,
                       overtones: [Overtone(ratio: 2.76, level: 0.16, fade: 0.5), Overtone(ratio: 5.4, level: 0.05, fade: 0.3)], down: 0.75)
        default:
            return two(attack: 0.012, fade: 0.2, gap: 0.13, overtones: [Overtone(ratio: 2, level: 0.22, fade: 0.45)])
        }
    }

    /// The samples of `notes`, from -1 to 1.
    nonisolated static func samples(_ notes: [Note]) -> [Double] {
        // Long enough to die away (or 3 s at most), the last of it faded out.
        let length = min((notes.map { $0.at + $0.fade * 5 }.max() ?? 0) + 0.05, 3)
        var out = [Double](repeating: 0, count: Int(length * Double(rate)))
        for note in notes {
            let start = Int(note.at * Double(rate))
            guard start < out.count else { continue }
            for index in start..<out.count {
                let t = Double(index - start) / Double(rate)
                let rise = min(t / note.attack, 1)
                // Eased in, so it never clicks.
                let envelope = note.level * (rise * rise * (3 - 2 * rise)) * exp(-t / note.fade)
                guard envelope > 0.0001 || t < note.attack else { continue }
                let phase = 2 * Double.pi * note.pitch * t
                var value = sin(phase)
                for overtone in note.overtones {
                    value += overtone.level * exp(-t / (note.fade * overtone.fade)) * sin(overtone.ratio * phase)
                }
                out[index] += envelope * value
            }
        }
        // Faded out at the very end, and never past full.
        let tail = min(out.count, rate / 7)
        for index in 0..<tail { out[out.count - 1 - index] *= Double(index) / Double(tail) }
        return out.map { min(max($0, -1), 1) }
    }

    /// As a WAV file's bytes.
    nonisolated static func wav(_ notes: [Note]) -> Data {
        let pcm = samples(notes).map { Int16(($0 * Double(Int16.max)).rounded()) }
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count * 2))
        for sample in pcm { put(sample) }
        return data
    }
}
