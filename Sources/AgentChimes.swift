import AppKit
import Combine
import os

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
    /// The Claudes that last finished (or began waiting for you) out of sight, as a sound would say
    /// (sounds on or not), the latest last, each once: the latest still running is what holding
    /// Option brings up (see `latest(among:)`).
    private var recent: [AgentSession] = []
    static let apart: TimeInterval = 1.5
    static let remembered = 8

    /// The latest Claude to have finished (or begun waiting) that's still running, as it is now
    /// among `sessions`: one that's quit has nothing to bring up (opening its folder would only
    /// open it afresh), so the one before it, if that's still running.
    func latest(among sessions: [AgentSession]) -> AgentSession? {
        Self.pick(recent, current: sessions) { pid in kill(pid, 0) == 0 || errno != ESRCH }
    }

    /// Of `recent` (the latest last), the latest still running, as it is in `current`: by its
    /// process, if it's known, else by its being in `current` still.
    nonisolated static func pick(_ recent: [AgentSession], current: [AgentSession], isRunning: (Int32) -> Bool) -> AgentSession? {
        for old in recent.reversed() {
            let now = current.first { $0.id == old.id }
            let session = now ?? old
            if session.pid > 0 ? isRunning(session.pid) : now != nil { return session }
        }
        return nil
    }

    /// What `from` becoming `to` sounds like, if anything: done after being at work; waiting, newly.
    nonisolated static func chime(from old: AgentActivity?, to new: AgentActivity) -> Kind? {
        guard let old, old != new else { return nil }
        if new == .waiting { return .waiting }
        if old.priority == 2, new == .done || new == .idle { return .done }
        return nil
    }

    /// Editors with a window for each folder, its name in the window's title.
    nonisolated static let editors = ["VS Code", "Cursor", "Windsurf"]

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
    static func focusedTitle(of pid: pid_t) -> String? {
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
        SeenDesks.shared.sessions = claudes
        SeenDesks.shared.look(at: now)
        let heard = claudes.compactMap { session in Self.chime(from: before[session.id], to: session.activity).map { ($0, session) } }
        guard !heard.isEmpty else { return }
        // Waiting for you says more than done.
        // None for one you're looking at already (its app in front, and in an editor, its window).
        let unseen = heard.filter { !Self.isInFront($0.1) }
        guard let (kind, session) = unseen.first(where: { $0.0 == .waiting }) ?? unseen.first else { return }
        recent.removeAll { $0.id == session.id }
        recent.append(session)
        if recent.count > Self.remembered { recent.removeFirst(recent.count - Self.remembered) }
        guard Feature.agentSounds.isOn, !isOff, now.timeIntervalSince(lastChime) >= Self.apart else { return }
        lastChime = now
        // Its desktop's sound, if it has one and the desktop can be told; else its app's. Either
        // way, the desktop it came from's marked in the desktops' list (see `DeskChimes`).
        // Its desktop as its app's windows say, else where it was last seen (see `SeenDesks`).
        let source = Self.source(of: session), midnight = theme == .midnight
        let pid = (session.pid > 0 ? AgentWindow.hostApp(of: session.pid) : nil)?.processIdentifier
        let deskSounds = ChimeSettings.shared.hasDeskSounds
        if !deskSounds { ChimeSettings.shared.voice(for: source).play(kind, midnight: midnight) }
        DispatchQueue.global(qos: .userInitiated).async {
            let number = pid.flatMap { SessionDesk.space(of: session, app: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let found = number.flatMap(SessionDesk.desktop)
                    if let found { SeenDesks.shared.remember(session, on: found) }
                    let space = found ?? SeenDesks.shared.desk(of: session)
                    if deskSounds {
                        let desk = space.flatMap { ChimeSettings.shared.desk($0) }
                        (desk ?? ChimeSettings.shared.voice(for: source)).play(kind, midnight: midnight)
                    }
                    let how = found != nil ? "by its app's windows" : space != nil ? "where it was last seen" : "not found"
                    Self.log.notice("A sound for a Claude in \(source, privacy: .public): its desktop \(how, privacy: .public)")
                    if let space { DeskChimes.shared.rang(space, kind) }
                }
            }
        }
    }

    private static let log = Logger(subsystem: "local.nott", category: "chimes")
}

/// Where each Claude was last seen: the desktop you were on while you were looking at it (its app
/// in front, and in an editor, its folder's window), by the session and by its app and folder.
/// For a sound whose desktop its app's windows can't tell (an editor's windows on several, whose
/// titles can't be read without Screen Recording, and whose windows on other Spaces accessibility
/// doesn't see), so the desktops' list can still mark where it came from, and where agents are at
/// work. Looked at every couple of seconds as the Claudes change, and as you go to another app or
/// Space, with either the sounds or the list on; kept across Oyl's relaunches (for a fortnight),
/// so they're not lost each time it starts again.
@MainActor
final class SeenDesks {
    static let shared = SeenDesks()
    static let every: TimeInterval = 2
    static let most = 200

    /// The Claudes as they last were.
    var sessions: [AgentSession] = []
    static let lasts: TimeInterval = 14 * 24 * 3600
    static let storeKey = "seenDesks"

    /// Each one's desktop, as it's kept (see `SpaceGroups.keys`), and when it was seen there.
    private(set) var seen: [String: (keys: [String], at: Date)] = [:]
    private var lastLooked = Date.distantPast
    private var observers: [Any] = []
    /// Where it's kept (none, in a test).
    private let store: UserDefaults?

    init(store: UserDefaults? = .standard, now: Date = Date()) {
        self.store = store
        for (name, value) in store?.dictionary(forKey: Self.storeKey) ?? [:] {
            guard let value = value as? [String: Any], let keys = value["keys"] as? [String], !keys.isEmpty,
                  let at = value["at"] as? Double, now.timeIntervalSince1970 - at < Self.lasts else { continue }
            seen[name] = (keys, Date(timeIntervalSince1970: at))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification].map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Once what's in front has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    MainActor.assumeIsolated { self?.look(at: Date(), now: true) }
                }
            }
        }
    }

    /// What each's kept under: the session, and its app and folder.
    nonisolated static func names(of session: AgentSession) -> [String] {
        ["session:" + session.id] + (session.project.isEmpty ? [] : ["place:\(session.host ?? "")|\(session.project)"])
    }

    /// The Claudes you're looking at now, if any: their desktop's the one you're on.
    func look(at date: Date, now: Bool = false) {
        guard Feature.agentSounds.isOn || Feature.desktopsView.isOn, now || date.timeIntervalSince(lastLooked) >= Self.every else { return }
        lastLooked = date
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let here = sessions.filter { $0.pid > 0 && AgentWindow.hostApp(of: $0.pid)?.processIdentifier == front }
        guard !here.isEmpty else { return }
        // The one whose folder the window in front names (its title read the once); in an app with
        // no such title, its one Claude, if it has only one.
        let title = AgentChimes.focusedTitle(of: front)
        let looking = Self.looking(at: here, title: title)
        guard !looking.isEmpty, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main,
              let space = Spaces.current(on: screen) else { return }
        for session in looking { remember(session, on: space, at: date) }
    }

    /// Of the Claudes in the app in front, the ones being looked at, as the title of its window in
    /// front says: those whose folder it names; failing that, outside an editor (whose windows are
    /// each a folder's), its only Claude.
    nonisolated static func looking(at here: [AgentSession], title: String?) -> [AgentSession] {
        let named = here.filter { session in
            guard let title, !session.project.isEmpty else { return false }
            return AgentChimes.title(title, names: session.project)
        }
        if !named.isEmpty { return named }
        guard here.count == 1, let only = here.first, !AgentChimes.editors.contains(only.host ?? "") else { return [] }
        return [only]
    }

    func remember(_ session: AgentSession, on space: CurrentSpace, at date: Date = Date()) {
        let keys = SpaceGroups.keys(of: space)
        // Already known there, and lately: nothing to keep.
        let known = Self.names(of: session).allSatisfy { seen[$0]?.keys == keys && date.timeIntervalSince(seen[$0]!.at) < 60 }
        for name in Self.names(of: session) { seen[name] = (keys, date) }
        if seen.count > Self.most {
            for (name, _) in seen.sorted(by: { $0.value.at < $1.value.at }).prefix(seen.count - Self.most) { seen[name] = nil }
        }
        if !known { save() }
    }

    private func save() {
        store?.set(seen.mapValues { ["keys": $0.keys, "at": $0.at.timeIntervalSince1970] as [String: Any] }, forKey: Self.storeKey)
    }

    /// What the desktop `session` was last seen on is kept under: by the session, else by its app
    /// and folder.
    func keys(of session: AgentSession) -> [String]? {
        Self.names(of: session).lazy.compactMap { self.seen[$0]?.keys }.first
    }

    /// Where `session` was last seen, if that desktop's still there: by the session, else by its
    /// app and folder.
    func desk(of session: AgentSession) -> CurrentSpace? {
        guard let keys = keys(of: session) else { return nil }
        for screen in NSScreen.screens {
            guard let display = FullscreenSpace.display(for: screen) else { continue }
            let spaces = Spaces.all(in: display, boot: Spaces.bootTime) { NSRunningApplication(processIdentifier: $0)?.localizedName }.spaces
            if let space = spaces.first(where: { SpaceGroups.keys(of: $0).contains(where: keys.contains) }) { return space }
        }
        return nil
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

    /// `kind` in `style` (see `ChimeVoice.tones`): each its own tune as well as its own sound, done
    /// always rising and waiting asking, all low (none over E4).
    /// - Ember: D3 F♯3 A3, up a major chord; waiting, two taps of A3.
    /// - Hearth: C3 to G3, a slow fifth; waiting, G3 then C4, opening up.
    /// - Driftwood: E3 B3 E4, knocked; waiting, E4 knocked twice.
    /// - Lantern: G3 to D4, a bell's fifth; waiting, D4 rung twice.
    /// - Moonrise: D3 A3 D4, up an octave slowly; waiting, A3 up to D4.
    /// - Pebble: C4 to E4, two plucks; waiting, three quick taps of G3.
    /// - Low Tide: A2 E3 A3, swelling; waiting, E3 rising to A3.
    /// - Ripple: D3 E3 F♯3 A3, quick; waiting, F♯3 A3 F♯3 A3.
    nonisolated static func notes(_ kind: AgentChimes.Kind, style: String = "round", midnight: Bool) -> [Note] {
        let soft = midnight ? 1.7 : 1.0
        let shimmer = midnight ? [Overtone(ratio: 6, level: 0.05, fade: 0.6)] : []
        let done = kind == .done
        func run(_ pitches: [Double], attack: Double, fade: Double, gap: Double, overtones: [Overtone]) -> [Note] {
            let gap = gap * (midnight ? 1.2 : 1)
            return pitches.enumerated().map { index, pitch in
                let last = index == pitches.count - 1
                return Note(pitch: pitch, at: Double(index) * gap, level: 0.3 + 0.03 * Double(min(index, 3)),
                            attack: attack * soft, fade: fade * soft * (last ? 1.3 : 1), overtones: overtones + shimmer)
            }
        }
        let warm = [Overtone(ratio: 2, level: 0.22, fade: 0.45)]
        switch style {
        case "hum":
            return run(done ? [130.81, 196.0] : [196.0, 261.63], attack: 0.04, fade: 0.26, gap: done ? 0.24 : 0.2,
                       overtones: [Overtone(ratio: 2, level: 0.12, fade: 0.6)])
        case "wood":
            return run(done ? [164.81, 246.94, 329.63] : [329.63, 329.63], attack: 0.004, fade: 0.07, gap: 0.1,
                       overtones: [Overtone(ratio: 2, level: 0.35, fade: 0.5), Overtone(ratio: 3, level: 0.15, fade: 0.35)])
        case "bell":
            return run(done ? [196.0, 293.66] : [293.66, 293.66], attack: 0.006, fade: 0.4, gap: 0.2,
                       overtones: [Overtone(ratio: 2.76, level: 0.16, fade: 0.5), Overtone(ratio: 5.4, level: 0.05, fade: 0.3)])
        case "moonrise":
            return run(done ? [146.83, 220.0, 293.66] : [220.0, 293.66], attack: 0.05, fade: 0.26, gap: 0.17,
                       overtones: [Overtone(ratio: 2, level: 0.14, fade: 0.5)])
        case "pebble":
            return run(done ? [261.63, 329.63] : [196.0, 196.0, 196.0], attack: 0.003, fade: 0.06, gap: done ? 0.1 : 0.08,
                       overtones: [Overtone(ratio: 2, level: 0.1, fade: 0.4)])
        case "tide":
            return run(done ? [110.0, 164.81, 220.0] : [164.81, 220.0], attack: 0.09, fade: 0.3, gap: 0.22,
                       overtones: [Overtone(ratio: 2, level: 0.18, fade: 0.55)])
        case "ripple":
            return run(done ? [146.83, 164.81, 185.0, 220.0] : [185.0, 220.0, 185.0, 220.0], attack: 0.006, fade: 0.1, gap: 0.085,
                       overtones: [Overtone(ratio: 2, level: 0.2, fade: 0.45)])
        default:
            return run(done ? [146.83, 185.0, 220.0] : [220.0, 220.0], attack: 0.012, fade: 0.2, gap: done ? 0.1 : 0.13, overtones: warm)
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

/// Where a sound just came from: the desktop each was for, and which (done, or waiting for you),
/// for the desktops' list to mark. Each's let go of once you go to that desktop, or after a quarter
/// of an hour.
@MainActor
final class DeskChimes: ObservableObject {
    static let shared = DeskChimes()
    static let lasts: TimeInterval = 15 * 60

    struct Rang: Equatable {
        /// What its desktop's kept under (see `SpaceGroups.keys`).
        let keys: [String]
        let kind: AgentChimes.Kind
        let at: Date
    }

    @Published private(set) var all: [Rang] = []
    private var observer: Any?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main,
                      let space = Spaces.current(on: screen) else { return }
                self.visited(space)
            }
        }
    }

    /// A sound's just played for a Claude on `space`.
    func rang(_ space: CurrentSpace, _ kind: AgentChimes.Kind, at now: Date = Date()) {
        let keys = SpaceGroups.keys(of: space)
        all.removeAll { $0.keys.contains(where: keys.contains) || now.timeIntervalSince($0.at) > Self.lasts }
        all.append(Rang(keys: keys, kind: kind, at: now))
    }

    /// The latest sound for `space`, if one's played there in the last quarter hour.
    func latest(for space: CurrentSpace, at now: Date = Date()) -> Rang? {
        let keys = SpaceGroups.keys(of: space)
        return all.last { $0.keys.contains(where: keys.contains) && now.timeIntervalSince($0.at) <= Self.lasts }
    }

    /// Gone to: seen to.
    func visited(_ space: CurrentSpace) {
        let keys = SpaceGroups.keys(of: space)
        all.removeAll { $0.keys.contains(where: keys.contains) }
    }
}

/// The right Option key held: straight to the Claude that last finished, by Oyl's own instant
/// switch (see `InstantSpaces`), with no slide through the desktops between and nothing rearranged
/// (macOS's own way there, activating its app, slides across every desktop between and, with
/// Spaces set to rearrange by recent use, moves them about); then its window brought to the front
/// where it is, so activating its app has nowhere to go. A desktop it can't tell (or one on another
/// screen) is left to `fallback`, the usual way.
@MainActor
enum LatestClaude {
    private static var arriving: (observer: Any, timeout: DispatchWorkItem)?

    static func go(to session: AgentSession, fallback: @escaping @MainActor () -> Void) {
        let host = session.host ?? "?"
        guard let pid = (session.pid > 0 ? AgentWindow.hostApp(of: session.pid) : nil)?.processIdentifier else {
            log.notice("Option held: a Claude in \(host, privacy: .public), its app not found: the usual way")
            return fallback()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let number = SessionDesk.space(of: session, app: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let found = number.flatMap(SessionDesk.desktop)
                    guard let space = found ?? SeenDesks.shared.desk(of: session),
                          let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main,
                          let display = FullscreenSpace.display(for: screen) else {
                        log.notice("Option held: a Claude in \(host, privacy: .public), its desktop not found: the usual way")
                        return fallback()
                    }
                    let all = Spaces.all(in: display, boot: Spaces.bootTime) { NSRunningApplication(processIdentifier: $0)?.localizedName }
                    let keys = SpaceGroups.keys(of: space)
                    guard let from = all.current,
                          let target = all.spaces.firstIndex(where: { SpaceGroups.keys(of: $0).contains(where: keys.contains) })
                    else {
                        log.notice("Option held: a Claude in \(host, privacy: .public), its desktop gone: the usual way")
                        return fallback()
                    }
                    let how = found != nil ? "by its windows" : "where last seen"
                    log.notice("Option held: a Claude in \(host, privacy: .public), \(how, privacy: .public), desktop \(target + 1)\(target == from ? " (here)" : "", privacy: .public)")
                    guard target != from else { return raise(session, pid: pid) }
                    InstantSpaces.go(from: from, to: target, on: screen)
                    whenThere { raise(session, pid: pid) }
                }
            }
        }
    }

    static let log = Logger(subsystem: "local.nott", category: "chimes")

    /// Once the Space has changed (or a moment's gone by, if it doesn't say).
    private static func whenThere(_ then: @escaping @MainActor () -> Void) {
        if let arriving {
            NSWorkspace.shared.notificationCenter.removeObserver(arriving.observer)
            arriving.timeout.cancel()
        }
        func done() {
            guard let arriving else { return }
            NSWorkspace.shared.notificationCenter.removeObserver(arriving.observer)
            arriving.timeout.cancel()
            Self.arriving = nil
            // Settled there first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { then() }
        }
        let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                                                         queue: .main) { _ in MainActor.assumeIsolated { done() } }
        let timeout = DispatchWorkItem { MainActor.assumeIsolated { done() } }
        arriving = (observer, timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: timeout)
    }

    /// Its window, of those its app has on the desktop you're on, as accessibility lists them: the
    /// one whose title names its folder, else the one in front.
    nonisolated static func window(among titles: [String?], folder: String) -> Int? {
        guard !titles.isEmpty else { return nil }
        if !folder.isEmpty, let named = titles.firstIndex(where: { $0.map { AgentChimes.title($0, names: folder) } ?? false }) { return named }
        return 0
    }

    /// Its window to the front here, then its app.
    private static func raise(_ session: AgentSession, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] {
            let titles = windows.map { window -> String? in
                var title: CFTypeRef?
                return AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success ? title as? String : nil
            }
            if let index = window(among: titles, folder: session.project) {
                AXUIElementSetAttributeValue(windows[index], kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(windows[index], kAXRaiseAction as CFString)
            }
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}
