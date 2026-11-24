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
        // Its desktop's sound, if it has one and the desktop can be told; else its app's.
        let source = Self.source(of: session), midnight = theme == .midnight
        guard let pid = (session.pid > 0 ? AgentWindow.hostApp(of: session.pid) : nil)?.processIdentifier,
              ChimeSettings.shared.hasDeskSounds else {
            ChimeSettings.shared.voice(for: source).play(kind, midnight: midnight)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let number = SessionDesk.space(of: session, app: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let desk = number.flatMap(SessionDesk.desktop).flatMap { ChimeSettings.shared.desk($0) }
                    (desk ?? ChimeSettings.shared.voice(for: source)).play(kind, midnight: midnight)
                }
            }
        }
    }
}

/// A sound to be played: one of Oyl's tones, one of macOS's, a file in the sounds folder, or none.
struct ChimeVoice: Equatable, Identifiable {
    let id: String
    let name: String

    /// Oyl's own, each low and round, done rising: Ember (the first, and the usual), a warm low
    /// tone; Hearth, lower and longer, a hum; Driftwood, knocked wood; Lantern, a soft bell;
    /// Moonrise, a little higher and slow to come in; Pebble, short and plucked; Low Tide, low,
    /// swelling in; Ripple, four quick notes up.
    static let round = ChimeVoice(id: "tone:round", name: "Ember")
    static let silent = ChimeVoice(id: "none", name: "Silent")
    static let tones = [round, ChimeVoice(id: "tone:hum", name: "Hearth"), ChimeVoice(id: "tone:wood", name: "Driftwood"),
                        ChimeVoice(id: "tone:bell", name: "Lantern"), ChimeVoice(id: "tone:moonrise", name: "Moonrise"),
                        ChimeVoice(id: "tone:pebble", name: "Pebble"), ChimeVoice(id: "tone:tide", name: "Low Tide"),
                        ChimeVoice(id: "tone:ripple", name: "Ripple")]

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

/// Which sound each place a Claude runs has, and each desktop that's been given its own (from the
/// desktops' list): kept in the defaults, with the places seen so far (in
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

    static let desksKey = "chimes.desks"

    @Published private(set) var sources: [String]
    @Published private(set) var voices: [String: String]
    /// Desktops' own sounds, by what they're kept under (see `SpaceGroups.keys`).
    @Published private(set) var desks: [String: String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sources = defaults.stringArray(forKey: Self.sourcesKey) ?? []
        voices = defaults.dictionary(forKey: Self.voicesKey) as? [String: String] ?? [:]
        desks = defaults.dictionary(forKey: Self.desksKey) as? [String: String] ?? [:]
    }

    var hasDeskSounds: Bool { !desks.isEmpty }

    /// A desktop's own sound, if it has one.
    func desk(_ space: CurrentSpace, among all: [ChimeVoice] = ChimeVoice.all()) -> ChimeVoice? {
        SpaceGroups.keys(of: space).lazy.compactMap { self.desks[$0] }.first.flatMap { id in all.first { $0.id == id } }
    }

    /// A desktop given its own sound (or, none, back to its app's).
    func setDesk(_ space: CurrentSpace, to voice: ChimeVoice?) {
        for key in SpaceGroups.keys(of: space) { desks[key] = voice?.id }
        // Too many: the oldest fullscreen windows' let go of.
        if desks.count > 300 { for key in desks.keys.filter({ $0.hasPrefix("window:") }).prefix(desks.count - 300) { desks[key] = nil } }
        defaults.set(desks, forKey: Self.desksKey)
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
/// gently and dying away. Done is three notes rising, a small ta-da; waiting two soft taps of one,
/// asking. Eight of them, each with a name (see `ChimeVoice.tones`). In Midnight Oyl's, softer still,
/// slower to fade, with a faint shimmer.
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

    /// `kind` in `style` (see `ChimeVoice.tones`). Done rises, D3, F♯3, A3, a small ta-da;
    /// waiting is two soft taps of A3, asking.
    nonisolated static func notes(_ kind: AgentChimes.Kind, style: String = "round", midnight: Bool) -> [Note] {
        let soft = midnight ? 1.7 : 1.0
        let shimmer = midnight ? [Overtone(ratio: 6, level: 0.05, fade: 0.6)] : []
        let pitches: [Double] = kind == .done ? (style == "ripple" ? [146.83, 164.81, 185.0, 220.0] : [146.83, 185.0, 220.0]) : [220.0, 220.0]
        func run(attack: Double, fade: Double, gap: Double, overtones: [Overtone], scale: Double = 1) -> [Note] {
            let gap = (kind == .done ? gap * 0.75 : gap) * (midnight ? 1.2 : 1)
            return pitches.enumerated().map { index, pitch in
                let last = index == pitches.count - 1
                return Note(pitch: pitch * scale, at: Double(index) * gap, level: 0.3 + 0.03 * Double(index),
                            attack: attack * soft, fade: fade * soft * (last ? 1.3 : 1), overtones: overtones + shimmer)
            }
        }
        switch style {
        case "hum":
            return run(attack: 0.04, fade: 0.22, gap: 0.2, overtones: [Overtone(ratio: 2, level: 0.12, fade: 0.6)], scale: 0.75)
        case "wood":
            return run(attack: 0.004, fade: 0.07, gap: 0.11,
                       overtones: [Overtone(ratio: 2, level: 0.35, fade: 0.5), Overtone(ratio: 3, level: 0.15, fade: 0.35)], scale: 1.5)
        case "bell":
            return run(attack: 0.006, fade: 0.4, gap: 0.17,
                       overtones: [Overtone(ratio: 2.76, level: 0.16, fade: 0.5), Overtone(ratio: 5.4, level: 0.05, fade: 0.3)], scale: 0.75)
        case "moonrise":
            return run(attack: 0.05, fade: 0.26, gap: 0.16, overtones: [Overtone(ratio: 2, level: 0.14, fade: 0.5)], scale: 1.12)
        case "pebble":
            return run(attack: 0.003, fade: 0.06, gap: 0.09, overtones: [Overtone(ratio: 2, level: 0.1, fade: 0.4)])
        case "tide":
            return run(attack: 0.09, fade: 0.3, gap: 0.22, overtones: [Overtone(ratio: 2, level: 0.18, fade: 0.55)], scale: 0.67)
        case "ripple":
            return run(attack: 0.006, fade: 0.1, gap: 0.085, overtones: [Overtone(ratio: 2, level: 0.2, fade: 0.45)])
        default:
            return run(attack: 0.012, fade: 0.2, gap: 0.13, overtones: [Overtone(ratio: 2, level: 0.22, fade: 0.45)])
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

/// Which desktop a Claude's on: its app's only one, if its windows are all on one; else, the one
/// with the window whose title names its folder (an editor's), as the window server says (with
/// Screen Recording allowed) or accessibility does. Nil if it can't be told.
enum SessionDesk {
    /// The Space's number (off the main thread).
    static func space(of session: AgentSession, app pid: pid_t) -> Int? {
        let windows = SpaceApps.windows(of: pid)
        let spaces = Set(windows.filter { $0.spaces.count == 1 }.map { $0.spaces[0] })
        if spaces.count == 1 { return spaces.first }
        guard !session.project.isEmpty else { return nil }
        if let window = windows.first(where: { $0.title.map { AgentChimes.title($0, names: session.project) } ?? false }),
           window.spaces.count == 1 {
            return window.spaces[0]
        }
        for (title, number) in titledWindows(pid) where AgentChimes.title(title, names: session.project) {
            let on = SpaceApps.spaces(ofWindow: number)
            if on.count == 1 { return on[0] }
        }
        return nil
    }

    /// The desktop with that number, on any screen.
    @MainActor
    static func desktop(_ number: Int) -> CurrentSpace? {
        for screen in NSScreen.screens {
            guard let display = FullscreenSpace.display(for: screen) else { continue }
            if let space = Spaces.all(in: display, boot: Spaces.bootTime, appName: { NSRunningApplication(processIdentifier: $0)?.localizedName })
                .spaces.first(where: { $0.id == number }) { return space }
        }
        return nil
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindow.self) }

    /// `pid`'s windows that accessibility can see, each title and number.
    private static func titledWindows(_ pid: pid_t) -> [(String, CGWindowID)] {
        guard let getWindow else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var title: CFTypeRef?
            var number: CGWindowID = 0
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success, let title = title as? String,
                  getWindow(window, &number) == .success, number != 0 else { return nil }
            return (title, number)
        }
    }
}
