import AppKit
import Combine

// MARK: - Players

/// The native players Oyl can read and control (same set NotchBox supports).
enum Player: String, CaseIterable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var bundleID: String { rawValue }

    var name: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Distributed notifications each player posts when the track or play state changes.
    var notificationNames: [String] {
        switch self {
        case .music: return ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"]
        case .spotify: return ["com.spotify.client.PlaybackStateChanged"]
        }
    }

    /// Returns {state, title, artist, album, duration (s), position (s), track id, artwork url}.
    /// Every script checks `is running` first so polling never relaunches a player that just quit.
    var statusScript: String {
        switch self {
        case .music:
            return """
            if application id "com.apple.Music" is running then
                tell application id "com.apple.Music"
                    with timeout of 3 seconds
                        set s to player state as text
                        if s is "stopped" then return {s}
                        try
                            set t to current track
                            return {s, name of t, artist of t, album of t, duration of t, player position, persistent ID of t, ""}
                        end try
                        return {s}
                    end timeout
                end tell
            end if
            return {"stopped"}
            """
        case .spotify:
            return """
            if application id "com.spotify.client" is running then
                tell application id "com.spotify.client"
                    with timeout of 3 seconds
                        set s to player state as text
                        if s is "stopped" then return {s}
                        try
                            set t to current track
                            return {s, name of t, artist of t, album of t, (duration of t) / 1000, player position, id of t, artwork url of t}
                        end try
                        return {s}
                    end timeout
                end tell
            end if
            return {"stopped"}
            """
        }
    }

    static let musicArtworkScript = """
    if application id "com.apple.Music" is running then
        tell application id "com.apple.Music"
            with timeout of 5 seconds
                try
                    return raw data of artwork 1 of current track
                end try
            end timeout
        end tell
    end if
    return ""
    """

    func script(_ command: String) -> String {
        """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)" to \(command)
        end if
        """
    }
}

struct Track: Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double

    /// An audiobook rather than a song, by the look of it: one that says so (on Spotify, often a
    /// show's episode, like "Frankenstein | Audiobook by Mary Shelley" from "Classic Audiobooks
    /// Collection"), or a Spotify chapter, or an episode titled as one.
    var isAudiobook: Bool {
        if id.hasPrefix("spotify:audiobook:") || id.hasPrefix("spotify:chapter:") { return true }
        let words = "\(title) \(album)".lowercased()
        if ["audiobook", "audio book", "abridged", "narrated by"].contains(where: words.contains) { return true }
        return id.hasPrefix("spotify:episode:") && title.range(of: #"\bchapter\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Whether Spotify's really playing on this Mac, by what it says and what's heard of it. It can go
/// on saying a song's playing here while it's playing on another device (Spotify Connect: from the
/// phone, say), the song it says long gone; so it's taken at its word only while its sound's been
/// heard in the last few seconds, or for those few seconds after it says it's started (or a new
/// song has) or it's told to do something, while its sound starts.
struct Earshot {
    /// How long it can say it's playing without being heard.
    static let silence: TimeInterval = 5

    private(set) var heard = Date.distantPast
    /// What it last said: playing or not, and which song.
    private(set) var saysPlaying = false
    private var track: String?

    /// It says it's `playing` `track`, `sounding` (or not) at `now`: is it playing here?
    mutating func says(_ playing: Bool, track: String?, sounding: Bool, at now: Date = Date()) -> Bool {
        if playing, !saysPlaying || track != self.track { heard = now }
        saysPlaying = playing
        self.track = track
        return playing && hears(sounding, at: now)
    }

    /// It's `sounding` (or not) at `now`, between askings: is it still heard?
    mutating func hears(_ sounding: Bool, at now: Date = Date()) -> Bool {
        if sounding { heard = now }
        return now.timeIntervalSince(heard) < Self.silence
    }

    /// It's been told to do something: a moment for its sound to start.
    mutating func told(at now: Date = Date()) { heard = now }

    /// It's quit.
    mutating func forget() {
        saysPlaying = false
        track = nil
    }
}

struct PlayerStatus: Sendable {
    var isPlaying: Bool
    var track: Track?
    var position: Double
    var artworkURL: URL?

    static func parse(_ list: NSAppleEventDescriptor) -> PlayerStatus? {
        guard list.numberOfItems >= 1 else { return nil }
        func text(_ index: Int) -> String {
            guard let item = list.atIndex(index), !item.isMissingValue else { return "" }
            return item.stringValue ?? ""
        }
        func number(_ index: Int) -> Double {
            guard let item = list.atIndex(index), !item.isMissingValue else { return 0 }
            return item.doubleValue
        }

        var status = PlayerStatus(isPlaying: text(1) == "playing", track: nil, position: 0, artworkURL: nil)
        let title = text(2)
        guard list.numberOfItems >= 8, !title.isEmpty else { return status }

        let artist = text(3), album = text(4), id = text(7)
        status.track = Track(id: id.isEmpty ? "\(title)|\(artist)|\(album)" : id,
                             title: title, artist: artist, album: album, duration: number(5))
        status.position = number(6)
        status.artworkURL = URL(string: text(8))
        return status
    }
}

private extension NSAppleEventDescriptor {
    /// AppleScript's `missing value` arrives as typeType 'type' holding 'msng'.
    var isMissingValue: Bool { descriptorType == 0x7479_7065 && typeCodeValue == 0x6D73_6E67 }
}

// MARK: - AppleScript

/// Runs AppleScript off the main thread. Scripts run one at a time, in submission order, so a
/// status query sent after a command always sees that command's result.
final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "oyl.AppleScript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:]

    func run<T: Sendable>(_ source: String, cache: Bool = true,
                          _ transform: @escaping @Sendable (NSAppleEventDescriptor) -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.execute(source, cache: cache).flatMap(transform))
            }
        }
    }

    func send(_ source: String, cache: Bool) {
        queue.async { _ = self.execute(source, cache: cache) }
    }

    private func execute(_ source: String, cache: Bool) -> NSAppleEventDescriptor? {
        guard let script = compiled[source] ?? NSAppleScript(source: source) else { return nil }
        if cache { compiled[source] = script }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

// MARK: - Now playing

@MainActor
final class NowPlaying: ObservableObject {
    @Published private(set) var player: Player?
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: NSColor = .white
    /// A few of the artwork's colors, the most of it first (Midnight Oyl's galaxy under the wave).
    @Published private(set) var palette: [NSColor] = []
    /// The song's synced lyrics; nil while they're being looked up, or when there are none.
    @Published private(set) var lyrics: Lyrics?
    // Playback position is reported once a second; views interpolate from this anchor.
    @Published private(set) var anchorPosition: Double = 0
    @Published private(set) var anchorDate = Date()

    let spectrum = AudioSpectrum()
    /// The Mac's volume, which the notch's volume controls turn (rather than the player's own).
    let output = SystemVolume()

    private static let restartsAfter = 10.0  // seconds in, after which ⏮ restarts the song

    private let runner = ScriptRunner()
    private var notificationObserver: DistributedObserver?
    private var timer: Timer?
    private var ticks = 0
    private var refreshing = false
    private var refreshQueued = false
    private var lastCommand = Date.distantPast
    private var emptyPolls = 0
    private var lastActive: Player?
    private var artworkKey: String?
    private var artworkTask: Task<Void, Never>?
    private var artworkCache: [String: NSImage] = [:]
    private var lyricsTask: Task<Void, Never>?
    private var lyricsCache: [String: Lyrics?] = [:]  // nil: looked up, and none
    private var analyzing: AnyCancellable?
    /// Whether Spotify's playing here, or only says so (playing on another device).
    private var spotify = Earshot()

    init() {
        // The visualizer turned on or off: its sound's analyzed, or not, straight away.
        analyzing = Features.shared.changed
            .filter { $0.0 == .visualizer }
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.spectrum.follow(self.isPlaying && Feature.visualizer.isOn ? self.player : nil)
                }
            }
        notificationObserver = DistributedObserver { [weak self] name, userInfo in
            let playing = (userInfo?["Player State"] as? String) == "Playing"
            MainActor.assumeIsolated {
                guard let self else { return }
                if playing, let player = Player.allCases.first(where: { $0.notificationNames.contains(name) }) {
                    self.lastActive = player
                }
                self.refresh()
            }
        }
        notificationObserver?.observe(Player.allCases.flatMap(\.notificationNames))

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
        refresh()
    }

    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        var position = anchorPosition
        if isPlaying { position += date.timeIntervalSince(anchorDate) }
        if track.duration > 0 { position = min(position, track.duration) }
        return max(position, 0)
    }

    // MARK: Controls

    func togglePlayPause() {
        guard let player else { return }
        setAnchor(position(at: Date()))
        isPlaying.toggle()
        spectrum.follow(isPlaying && Feature.visualizer.isOn ? player : nil)
        // What the button shows, not a toggle: Spotify can say it's playing a song that's really
        // playing on another device, which toggling would pause there.
        perform(isPlaying ? "play" : "pause", on: player)
    }

    func next() {
        guard let player else { return }
        spectrum.easeNextChange()
        perform("next track", on: player)
    }

    /// Back to the start of the song, or to the song before if this one's only just begun.
    func previous() {
        guard let player else { return }
        guard position(at: Date()) <= Self.restartsAfter else {
            seek(to: 0)
            return
        }
        spectrum.easeNextChange()
        // Spotify's `previous track` restarts a song that's a few seconds in, so start it from 0.
        if player == .spotify { perform("set player position to 0", on: player) }
        perform("previous track", on: player)
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        setAnchor(seconds)
        spectrum.easeNextChange()
        perform(String(format: "set player position to %.2f", seconds), on: player, cache: false)
    }

    /// The player that's playing, brought to the front.
    func showPlayer() {
        guard let player, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    private func perform(_ command: String, on player: Player, cache: Bool = true) {
        lastCommand = Date()
        if player == .spotify { spotify.told() }
        runner.send(player.script(command), cache: cache)
        refresh()
    }

    // MARK: Polling

    /// The song is on screen, where its progress bar and lyrics follow the position closely.
    var onScreen = false {
        didSet { if onScreen, !oldValue { refresh() } }
    }

    /// Nothing that shows the song can be seen (the lid's shut): the player's asked about it only
    /// now and then, and its sound isn't analyzed.
    var resting = false {
        didSet {
            spectrum.resting = resting
            if !resting, oldValue { refresh() }
        }
    }

    private func tick() {
        ticks += 1
        // Notifications cover track and play-state changes; polling keeps the position honest.
        // Asking the player costs more than anything else here, so it's once a second only while
        // the song's on screen, every few seconds otherwise, less often still with nothing playing,
        // and only twice a minute with nothing to be seen at all.
        let every = resting ? 30 : isPlaying ? (onScreen ? 1 : 5) : 8
        if ticks % every == 0 { refresh() }
        // Spotify saying it's playing, listened for between askings: gone quiet here (its playing
        // moved to another device), or heard again (moved back).
        if player == .spotify, spotify.saysPlaying, !resting,
           spotify.hears(AudioProcess.isMakingSound(Player.spotify.bundleID)) != isPlaying {
            refresh()
        }
    }

    func refresh() {
        guard !refreshing else {
            refreshQueued = true
            return
        }
        let running = Player.allCases.filter(\.isRunning)
        guard !running.isEmpty else {
            apply([:])
            return
        }

        refreshing = true
        let startedAt = Date()
        Task {
            var statuses: [Player: PlayerStatus] = [:]
            for player in running {
                statuses[player] = await runner.run(player.statusScript) { PlayerStatus.parse($0) }
            }
            refreshing = false
            // A poll that started before a command would undo its optimistic update.
            if startedAt >= lastCommand {
                apply(statuses)
            } else {
                refreshQueued = true
            }
            if refreshQueued {
                refreshQueued = false
                refresh()
            }
        }
    }

    private func apply(_ statuses: [Player: PlayerStatus]) {
        var statuses = statuses
        // Spotify's playing only if it's heard here.
        if var status = statuses[.spotify] {
            status.isPlaying = spotify.says(status.isPlaying, track: status.track?.id,
                                            sounding: status.isPlaying && AudioProcess.isMakingSound(Player.spotify.bundleID))
            statuses[.spotify] = status
        } else if !Player.spotify.isRunning {
            spotify.forget()
        }
        let order = [player, lastActive].compactMap { $0 } + Player.allCases
        let chosen = order.first { statuses[$0]?.track != nil && statuses[$0]?.isPlaying == true }
            ?? order.first { statuses[$0]?.track != nil }

        guard let chosen, let status = statuses[chosen], let newTrack = status.track else {
            // Players can report "no track" for a moment between songs.
            emptyPolls += 1
            if statuses.isEmpty || emptyPolls >= 2 { clear() }
            return
        }
        emptyPolls = 0
        if status.isPlaying { lastActive = chosen }

        let predicted = position(at: Date())
        let trackChanged = chosen != player || newTrack.id != track?.id
        let stateChanged = status.isPlaying != isPlaying

        if chosen != player { player = chosen }
        if newTrack != track { track = newTrack }
        if stateChanged { isPlaying = status.isPlaying }
        if trackChanged || stateChanged || abs(predicted - status.position) > (status.isPlaying ? 1.5 : 0.25) {
            setAnchor(status.position)
        }
        if trackChanged {
            loadArtwork(for: chosen, track: newTrack, url: status.artworkURL)
            loadLyrics(for: newTrack)
            // Covers skips made in the player itself, and one song running into the next.
            spectrum.easeNextChange()
        }
        spectrum.follow(isPlaying && Feature.visualizer.isOn ? chosen : nil)
    }

    private func clear() {
        spectrum.follow(nil)
        guard player != nil || track != nil else { return }
        artworkTask?.cancel()
        artworkKey = nil
        lyricsTask?.cancel()
        lyrics = nil
        player = nil
        track = nil
        isPlaying = false
        artwork = nil
        accent = .white
        palette = []
    }

    private func setAnchor(_ position: Double) {
        anchorPosition = position
        anchorDate = Date()
    }

    // MARK: Lyrics

    /// Looked up once per song, as it starts, so it's known up front whether there are any.
    private func loadLyrics(for track: Track) {
        guard lyrics?.trackID != track.id else { return }
        lyricsTask?.cancel()
        lyrics = nil
        if let cached = lyricsCache[track.id] {
            lyrics = cached
            return
        }
        lyricsTask = Task {
            let found = await Lyrics.fetch(track)
            guard !Task.isCancelled, self.track?.id == track.id else { return }
            if lyricsCache.count > 200 { lyricsCache.removeAll() }
            lyricsCache[track.id] = .some(found)
            lyrics = found
        }
    }

    // MARK: Artwork

    private func loadArtwork(for player: Player, track: Track, url: URL?) {
        let key = player.rawValue + "|" + track.id
        guard key != artworkKey else { return }
        artworkKey = key
        artworkTask?.cancel()
        if let cached = artworkCache[key] {
            setArtwork(cached)
            return
        }

        artworkTask = Task {
            var data: Data?
            switch player {
            case .spotify:
                if let url { data = try? await URLSession.shared.data(from: url).0 }
            case .music:
                data = await runner.run(Player.musicArtworkScript) { $0.data.count > 64 ? $0.data : nil }
            }
            guard !Task.isCancelled, artworkKey == key else { return }
            let image = data.flatMap(NSImage.init(data:))
            if let image {
                if artworkCache.count > 40 { artworkCache.removeAll() }
                artworkCache[key] = image
            }
            setArtwork(image)
        }
    }

    private func setArtwork(_ image: NSImage?) {
        artwork = image
        accent = image.flatMap(ArtworkPalette.accent) ?? .white
        palette = image.map { ArtworkPalette.palette(of: $0) } ?? []
    }
}

/// Distributed notifications must be delivered immediately: AppKit suspends them while the app
/// is inactive, and an accessory app like this one is never active.
private final class DistributedObserver: NSObject {
    private let handler: (String, [AnyHashable: Any]?) -> Void

    init(handler: @escaping (String, [AnyHashable: Any]?) -> Void) {
        self.handler = handler
    }

    func observe(_ names: [String]) {
        for name in names {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(receive(_:)), name: Notification.Name(name),
                object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    @objc private func receive(_ notification: Notification) {
        handler(notification.name.rawValue, notification.userInfo)
    }
}

// MARK: - Artwork color

enum ArtworkPalette {
    /// A bright color pulled from the artwork, used to tint the spectrum and glow.
    static func accent(of image: NSImage) -> NSColor? {
        guard let pixels = pixels(of: image, side: 12) else { return nil }

        // Weight vivid pixels heavily so a colorful detail wins over a dull background.
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let maxComponent = max(r, g, b), minComponent = min(r, g, b)
            let saturation = maxComponent > 0 ? (maxComponent - minComponent) / maxComponent : 0
            let weight = pow(saturation * maxComponent, 2) + 0.01
            red += r * weight
            green += g * weight
            blue += b * weight
            total += weight
        }

        return brightened(NSColor(srgbRed: red / total, green: green / total, blue: blue / total, alpha: 1))
    }

    /// A few of the artwork's colors, up to `count`, the most of it first: its vivid pixels
    /// gathered by hue (twelve round the wheel, weighed as `accent` weighs them), each gathering's
    /// average, brightened as the accent is. Hues next to one taken, or too slight to see, are
    /// passed over; a gray cover gives just its accent.
    static func palette(of image: NSImage, count: Int = 4) -> [NSColor] {
        guard let pixels = pixels(of: image, side: 16) else { return [] }
        var hues = [(red: Double, green: Double, blue: Double, weight: Double)](repeating: (0, 0, 0, 0), count: 12)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation > 0.15, brightness > 0.15 else { continue }
            let weight = pow(Double(saturation * brightness), 2), slot = Int(hue * 12) % 12
            hues[slot].red += r * weight
            hues[slot].green += g * weight
            hues[slot].blue += b * weight
            hues[slot].weight += weight
        }
        let total = hues.map(\.weight).reduce(0, +)
        var taken: [Int] = []
        for slot in hues.indices.sorted(by: { hues[$0].weight > hues[$1].weight }) where hues[slot].weight > total * 0.05 {
            guard !taken.contains(where: { min(abs($0 - slot), 12 - abs($0 - slot)) <= 1 }) else { continue }
            taken.append(slot)
            if taken.count == count { break }
        }
        let colors = taken.map { slot in
            let hue = hues[slot]
            return brightened(NSColor(srgbRed: hue.red / hue.weight, green: hue.green / hue.weight, blue: hue.blue / hue.weight, alpha: 1))
        }
        if colors.isEmpty, let accent = accent(of: image) { return [accent] }
        return colors
    }

    /// Bright enough to show on the black, and not quite at full saturation.
    private static func brightened(_ color: NSColor) -> NSColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return NSColor(hue: hue, saturation: min(saturation, 0.8), brightness: max(brightness, 0.85), alpha: 1)
    }

    /// The artwork shrunk to `side` pixels square, as RGBA bytes.
    private static func pixels(of image: NSImage, side: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }
}
