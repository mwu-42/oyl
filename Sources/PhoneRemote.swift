import AppKit
import Combine
import CoreImage
import CryptoKit
import SwiftUI

/// The phone remote: a page your phone's browser opens, on the same Wi-Fi as the Mac (or from
/// anywhere, with Tailscale running on both: see `PhoneNetwork`), showing
/// what the notch does and working it from there: the agents, and Claude Code's requests to
/// allow or deny; the song; the timers; keeping the Mac awake. Off till it's turned on (on the
/// settings' Oyl section), and then only for a phone that's been paired: by scanning a code the
/// notch shows (or typing its six digits), which leaves a long key on the phone, as a cookie,
/// that every request after has to carry. Oyl keeps only the key's hash, and forgets every phone
/// when asked. The server (`PhoneServer`) answers devices beside the Mac alone, and each request
/// only when it's sent to the Mac by name (not some other site's, pointed here); one that changes
/// anything has to say it's the remote's own page's.
@MainActor
final class PhoneRemote: ObservableObject {
    /// A code being shown to pair a phone with: till when, how many wrong tries it's had, and the
    /// phone it's just paired, if it has.
    struct Pairing: Equatable {
        var code: String
        var until: Date
        var tries = 0
        var paired: String?

        var isSpent: Bool { tries >= PhoneRemote.triesAllowed }
    }

    /// Where the remote's remembered: whether it's on, its port, and its phones.
    struct Store {
        var load: () -> (on: Bool, port: UInt16?, devices: [PhoneDevice])
        var save: (_ on: Bool, _ port: UInt16, _ devices: [PhoneDevice]) -> Void

        static let defaults = Store(load: {
            let defaults = UserDefaults.standard
            let devices = defaults.data(forKey: "phone.devices").flatMap { try? JSONDecoder().decode([PhoneDevice].self, from: $0) }
            return (defaults.bool(forKey: "phone.on"), (defaults.object(forKey: "phone.port") as? Int).map { UInt16(clamping: $0) },
                    devices ?? [])
        }, save: { on, port, devices in
            let defaults = UserDefaults.standard
            defaults.set(on, forKey: "phone.on")
            defaults.set(Int(port), forKey: "phone.port")
            defaults.set(try? JSONEncoder().encode(devices), forKey: "phone.devices")
        })
    }

    @Published private(set) var isOn: Bool
    @Published private(set) var pairing: Pairing?
    /// The pairing address as a QR code, each module a pixel.
    @Published private(set) var pairingPicture: CGImage?
    @Published private(set) var devices: [PhoneDevice]
    @Published private(set) var status: PhoneServer.Status?
    /// The Mac's name on its tailnet, while Tailscale's running here (looked up now and then).
    @Published private(set) var tailnetName: String?
    /// The port it listens on, kept so a phone's bookmark goes on working.
    private(set) var port: UInt16

    static let defaultPort: UInt16 = 47640
    static let pairingTime: TimeInterval = 5 * 60
    nonisolated static let triesAllowed = 5
    static let cookie = "oyl"

    let controls: PhoneControls
    private let store: Store
    private let serves: Bool
    private var server: PhoneServer?
    private var saved = Date.distantPast
    /// When each phone was last seen, by its key's hash: kept into `devices` as they're saved (at
    /// most once a minute), so a phone's every look doesn't redraw the notch.
    private var lastSeen: [String: Date] = [:]
    private var endPairing: DispatchWorkItem?
    private var tailnetCheck: Timer?

    /// `serves`: listens (off, for trying it out without the network).
    init(controls: PhoneControls, store: Store = .defaults, serves: Bool = true) {
        self.controls = controls
        self.store = store
        self.serves = serves
        let loaded = store.load()
        isOn = loaded.on
        port = loaded.port ?? Self.defaultPort
        devices = loaded.devices
        if isOn { start() }
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if on {
            start()
        } else {
            stop()
            stopPairing()
        }
        save()
    }

    /// A new code to pair a phone with, shown for five minutes (and the remote on, if it wasn't).
    func pair(at now: Date = Date()) {
        setOn(true)
        endPairing?.cancel()
        pairing = Pairing(code: String(format: "%06d", Int.random(in: 0..<1_000_000)), until: now.addingTimeInterval(Self.pairingTime))
        pairingPicture = pairingAddress.flatMap(Self.qrCode)
        lookForTailnet()
    }

    func stopPairing() {
        endPairing?.cancel()
        pairing = nil
        pairingPicture = nil
    }

    /// Every phone forgotten: each has to be paired again.
    func forget() {
        devices = []
        save()
    }

    /// Tailscale's running here: a phone reaches the Mac by it, from any network.
    var overTailscale: Bool { !PhoneNetwork.tailnetAddresses().isEmpty }

    /// Where a phone opens the remote: with Tailscale running, by the Mac's name on its tailnet
    /// (which works from anywhere, the same Wi-Fi too); otherwise by its name on the network.
    /// Either stays put as its addresses change; failing a name, an address.
    var address: String {
        let tailnet = PhoneNetwork.tailnetAddresses()
        var host = tailnet.isEmpty ? PhoneNetwork.localName ?? PhoneNetwork.addresses().first { !$0.ipv6 }?.text ?? "localhost"
            : tailnetName ?? (tailnet.first { !$0.ipv6 } ?? tailnet[0]).text
        if host.contains(":") { host = "[\(host)]" }
        return "http://\(host.lowercased()):\(port)"
    }

    /// The address with the code on it, for the phone's camera.
    var pairingAddress: String? { pairing.map { "\(address)/pair?code=\($0.code)" } }

    /// Asks Tailscale for the Mac's name on its tailnet (off the main thread), for the address
    /// and the names requests may come to; and the pairing code again, if it's changed.
    private func lookForTailnet() {
        guard serves else { return }
        DispatchQueue.global(qos: .utility).async {
            let name = PhoneNetwork.askTailscale()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard name != self.tailnetName else { return }
                    self.tailnetName = name
                    if self.pairing?.paired == nil, self.pairing != nil { self.pairingPicture = self.pairingAddress.flatMap(Self.qrCode) }
                }
            }
        }
    }

    private func start() {
        guard serves, server == nil else { return }
        lookForTailnet()
        let check = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.lookForTailnet() } }
        RunLoop.main.add(check, forMode: .common)
        tailnetCheck = check
        status = .starting
        let server = PhoneServer(respond: { [weak self] request in
            self?.respond(to: request) ?? .text(404, "Not here")
        }, status: { [weak self] status in
            guard let self else { return }
            self.status = status
            if case let .listening(port) = status, port != self.port {
                self.port = port
                self.save()
            }
        })
        self.server = server
        server.start(port: port)
    }

    private func stop() {
        server?.stop()
        server = nil
        status = nil
        tailnetCheck?.invalidate()
        tailnetCheck = nil
    }

    private func save() {
        for index in devices.indices {
            if let seen = lastSeen[devices[index].hash] { devices[index].seen = seen }
        }
        lastSeen = [:]
        store.save(isOn, port, devices)
        saved = Date()
    }

    // MARK: Answering

    /// The answer to `request`, sent to one of `hosts` (the Mac's names: see `PhoneNetwork.hostNames`).
    func respond(to request: PhoneRequest, at now: Date = Date(), hosts: Set<String>? = nil) -> PhoneResponse {
        // Sent to the Mac by name, not to some other site's that's been pointed here.
        guard let host = request.host, (hosts ?? PhoneNetwork.hostNames(tailnetName: tailnetName)).contains(host) else {
            return .text(421, "Not here")
        }
        switch (request.method, request.path) {
        case ("GET", "/"):
            return PhoneResponse(status: 200, type: "text/html; charset=utf-8", body: Data(PhonePage.html.utf8))
        case ("GET", "/app.js"):
            return PhoneResponse(status: 200, type: "text/javascript; charset=utf-8", body: Data(PhonePage.script.utf8))
        case ("GET", "/manifest.json"):
            return PhoneResponse(status: 200, type: "application/manifest+json", body: Data(PhonePage.manifest.utf8))
        case ("GET", "/icon.png"):
            return PhoneResponse(status: 200, type: "image/png", body: PhonePage.icon)
        case ("GET", "/pair"):
            // From the code's picture, scanned.
            guard let key = pair(code: request.query["code"], from: request.headers["user-agent"], at: now) else {
                return .redirect("/?unpaired=1")
            }
            return .redirect("/", headers: ["Set-Cookie": Self.setCookie(key)])
        case ("POST", "/api/pair"):
            guard isOwnPage(request, hosts: hosts) else { return .text(403, "Not from the remote") }
            let code = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["code"] as? String
            guard let key = pair(code: code, from: request.headers["user-agent"], at: now) else {
                return .json(["error": pairing == nil ? "No phone's being paired: ask for a code on the Mac" : "That's not the code"], status: 403)
            }
            var response = PhoneResponse.json(["paired": true])
            response.headers["Set-Cookie"] = Self.setCookie(key)
            return response
        case ("GET", "/api/state"):
            guard known(request, at: now) else { return .json(["error": "unpaired"], status: 401) }
            return .json(controls.snapshot())
        case ("GET", "/api/art"):
            guard known(request, at: now) else { return .text(401, "Unpaired") }
            guard let art = controls.artwork() else { return .text(404, "No cover") }
            return PhoneResponse(status: 200, type: "image/jpeg", body: art)
        case ("POST", "/api/do"):
            guard isOwnPage(request, hosts: hosts) else { return .text(403, "Not from the remote") }
            guard known(request, at: now) else { return .json(["error": "unpaired"], status: 401) }
            guard let action = PhoneAction(request.body) else { return .json(["error": "Not something it does"], status: 400) }
            guard controls.perform(action) else { return .json(["error": "That's gone"], status: 404) }
            return .json(controls.snapshot())
        case (_, "/"), (_, "/app.js"), (_, "/pair"), (_, "/api/pair"), (_, "/api/state"), (_, "/api/art"), (_, "/api/do"):
            return .text(405, "Not that way")
        default:
            return .text(404, "Not here")
        }
    }

    /// A request that changes something came from the remote's own page: only its script sends
    /// this header, which another site's page can't without asking first (and isn't let), and
    /// from where it was opened, if it says.
    private func isOwnPage(_ request: PhoneRequest, hosts: Set<String>?) -> Bool {
        guard request.headers["x-oyl"] == "1", request.headers["content-type"]?.hasPrefix("application/json") == true else { return false }
        guard let origin = request.headers["origin"] else { return true }
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return (hosts ?? PhoneNetwork.hostNames(tailnetName: tailnetName)).contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    /// The request carries a paired phone's key: and that phone's been seen now.
    private func known(_ request: PhoneRequest, at now: Date) -> Bool {
        guard let key = request.cookie(Self.cookie) else { return false }
        let hash = Self.hash(key)
        guard devices.contains(where: { $0.hash == hash }) else { return false }
        lastSeen[hash] = now
        if now.timeIntervalSince(saved) > 60 { save() }
        return true
    }

    /// `code` tried, from a phone that says it's `agent`: its new key if it's right.
    private func pair(code: String?, from agent: String?, at now: Date) -> String? {
        guard var pairing, pairing.paired == nil, !pairing.isSpent, now < pairing.until, let code else { return nil }
        let tried = Array(code.filter(\.isNumber).utf8), wanted = Array(pairing.code.utf8)
        // Compared all the way through, so how long it takes says nothing about how near it was.
        guard tried.count == wanted.count, zip(tried, wanted).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            pairing.tries += 1
            self.pairing = pairing
            return nil
        }
        let key = Self.newKey()
        let name = Self.name(of: agent)
        devices.append(PhoneDevice(hash: Self.hash(key), name: name, paired: now, seen: now))
        save()
        pairing.paired = name
        self.pairing = pairing
        // The card says so a moment, then goes.
        let end = DispatchWorkItem { [weak self] in self?.stopPairing() }
        endPairing = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: end)
        return key
    }

    static func setCookie(_ key: String) -> String {
        "\(cookie)=\(key); Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict"
    }

    static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 256 random bits, for the phone to keep.
    static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// What a phone's called, from what its browser says it is.
    static func name(of agent: String?) -> String {
        guard let agent else { return "Phone" }
        if agent.contains("iPhone") { return "iPhone" }
        if agent.contains("iPad") { return "iPad" }
        if agent.contains("Android") { return "Android phone" }
        return "Phone"
    }

    /// `text` as a QR code, each module a pixel (draw it without smoothing): the modules opaque,
    /// between them clear, to be drawn in whatever color the look has.
    static func qrCode(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage,
              let mask = CIFilter(name: "CIMaskToAlpha", parameters: [kCIInputImageKey: code.applyingFilter("CIColorInvert")])?.outputImage
        else { return nil }
        return CIContext().createCGImage(mask, from: code.extent)
    }
}

/// A phone paired with the remote, known by its key's hash (the key's only on the phone).
struct PhoneDevice: Codable, Equatable, Identifiable {
    var hash: String
    var name: String
    var paired: Date
    var seen: Date

    var id: String { hash }
}

/// Something the phone's asked for.
enum PhoneAction: Equatable {
    case allow(String), deny(String)
    case playPause, next, previous
    case startTimer(minutes: Double, label: String)
    case pauseTimer(UUID), cancelTimer(UUID), focusTimer(UUID), dismissRinging
    /// Kept awake that many hours, or (nil) till it's stopped; or let sleep.
    case awake(hours: Double?)
    case sleep
    /// An idea jotted down (read as the notch's ideas field reads it); one done, put off a week or
    /// a month, or kept another month.
    case addIdea(String)
    case ideaDone(String), putOff(String, days: Int), keepIdea(String)
    /// A check-in for the work log (read as the notch's log field reads it), or something filed
    /// today taken back out.
    case checkIn(String), unlog(UUID)

    /// From the remote's JSON: `{"do": "allow", "id": "…"}` and so on.
    init?(_ body: Data) {
        guard let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let verb = fields["do"] as? String else { return nil }
        let id = fields["id"] as? String
        switch verb {
        case "allow": guard let id else { return nil }; self = .allow(id)
        case "deny": guard let id else { return nil }; self = .deny(id)
        case "playPause": self = .playPause
        case "next": self = .next
        case "previous": self = .previous
        case "startTimer":
            guard let minutes = fields["minutes"] as? Double, minutes > 0, minutes <= 24 * 60 else { return nil }
            self = .startTimer(minutes: minutes, label: String((fields["label"] as? String ?? "").prefix(60)))
        case "pauseTimer": guard let uuid = id.flatMap(UUID.init) else { return nil }; self = .pauseTimer(uuid)
        case "cancelTimer": guard let uuid = id.flatMap(UUID.init) else { return nil }; self = .cancelTimer(uuid)
        case "focusTimer": guard let uuid = id.flatMap(UUID.init) else { return nil }; self = .focusTimer(uuid)
        case "dismissRinging": self = .dismissRinging
        case "awake":
            let hours = fields["hours"] as? Double
            if let hours, !(hours > 0 && hours <= 24) { return nil }
            self = .awake(hours: hours)
        case "sleep": self = .sleep
        case "addIdea":
            guard let text = (fields["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            self = .addIdea(String(text.prefix(300)))
        case "ideaDone": guard let id else { return nil }; self = .ideaDone(id)
        case "putOff":
            guard let id, let days = fields["days"] as? Int, days == 7 || days == 28 else { return nil }
            self = .putOff(id, days: days)
        case "keepIdea": guard let id else { return nil }; self = .keepIdea(id)
        case "checkIn":
            guard let text = (fields["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            self = .checkIn(String(text.prefix(4000)))
        case "unlog": guard let uuid = id.flatMap(UUID.init) else { return nil }; self = .unlog(uuid)
        default: return nil
        }
    }
}

/// What the remote shows, as its page gets it: times as seconds since 1970, by the Mac's clock
/// (`now`, so the phone can count down by its own).
struct PhoneSnapshot: Codable, Equatable {
    struct Request: Codable, Equatable {
        var id: String
        var project: String
        var action: String
        var detail: String?
        var host: String?
    }

    struct Agent: Codable, Equatable {
        var id: String
        var name: String
        var doing: String
        /// "waiting" (for you), "working", "done" or "idle".
        var state: String
        var host: String?
        var since: Double
        var claude: Bool
    }

    struct Music: Codable, Equatable {
        var player: String
        var title: String
        var artist: String
        var playing: Bool
        /// Changes with the cover, which is at /api/art; nil for none.
        var art: String?
        /// Seconds into the song at the snapshot's `now`, for the lyrics to keep time by.
        var position: Double = 0
        /// The song's synced lyrics, while they're on (as in the notch): each line's time and words.
        var lyrics: [Line]? = nil

        struct Line: Codable, Equatable {
            var t: Double
            var text: String
        }
    }

    struct Timer: Codable, Equatable {
        var id: String
        var title: String
        /// When it goes off, if it's running; how long it has left, if it's paused.
        var ends: Double?
        var left: Double?
        var duration: Double
        /// Held on the notch.
        var focused = false
    }

    struct Awake: Codable, Equatable {
        var on: Bool
        var until: Double?
        /// Kept awake while this app runs.
        var app: String?
    }

    /// An idea, where it belongs and when (see `IdeaBoard`).
    struct Idea: Codable, Equatable {
        var id: String
        var title: String
        /// "due", "soon", "later" or "someday".
        var kind: String
        var label: String
        var overdue: Bool
        var stale: Bool
    }

    /// The work log: its projects (the latest worked on first), what's been filed today, and
    /// whether the notch is asking for today's check-in.
    struct Log: Codable, Equatable {
        struct Project: Codable, Equatable {
            var tag: String
            var name: String
            var days: Int
        }

        struct Entry: Codable, Equatable {
            var id: String
            var name: String
            var text: String
        }

        var prompt: String
        var asking: Bool
        var projects: [Project]
        var today: [Entry]
    }

    var mac: String
    var look: String
    var now: Double
    /// The notch's pages that are on, of "music", "timers", "awake", "ideas" (with tod there)
    /// and "log".
    var pages: [String]
    var requests: [Request]
    var agents: [Agent]
    var music: Music?
    var timers: [Timer]
    var ringing: String?
    var awake: Awake
    var ideas: [Idea] = []
    var log: Log? = nil
}

/// What the remote works: the notch's own state, in the app (made up, to try it out).
@MainActor
protocol PhoneControls: AnyObject {
    func snapshot() -> PhoneSnapshot
    /// Whether it could: a request that's been answered meanwhile, say, can't be again.
    func perform(_ action: PhoneAction) -> Bool
    /// The song's cover, as a JPEG.
    func artwork() -> Data?
}

/// The remote working the notch's own state.
@MainActor
final class NotchPhoneControls: PhoneControls {
    unowned let state: NotchState
    private var cover: (art: String, jpeg: Data)?

    init(state: NotchState) {
        self.state = state
    }

    func snapshot() -> PhoneSnapshot {
        let now = Date()
        let agents = state.agents, playing = state.nowPlaying, timers = state.timers
        var pages = [(Feature.musicPage, "music"), (Feature.timersPage, "timers"), (Feature.awakePage, "awake")]
            .filter { $0.0.isOn }.map(\.1)
        if Feature.ideasPage.isOn, state.tod.isAvailable { pages.append("ideas") }
        if Feature.logPage.isOn { pages.append("log") }
        let log = state.workLog
        let logged = PhoneSnapshot.Log(prompt: log.prompt(at: now), asking: log.reminding,
                                       projects: log.projects.map { .init(tag: $0.tag, name: $0.name, days: log.days(of: $0.tag)) },
                                       today: log.entries(on: now).map { entry in
                                           .init(id: entry.id.uuidString, name: log.project(entry.tag)?.name ?? entry.tag, text: entry.text)
                                       })
        let music = playing.track.flatMap { track in
            playing.player.map { player in
                PhoneSnapshot.Music(player: player.name, title: track.title, artist: track.artist, playing: playing.isPlaying,
                                    art: playing.artwork == nil ? nil : String(track.id.hashValue, radix: 36),
                                    position: playing.position(at: now),
                                    lyrics: state.showsLyrics && playing.lyrics?.trackID == track.id
                                        ? playing.lyrics?.lines.map { .init(t: $0.time, text: $0.text) } : nil)
            }
        }
        var awake = PhoneSnapshot.Awake(on: state.awake.isActive)
        switch state.awake.mode {
        case let .until(end): awake.until = end.timeIntervalSince1970
        case let .whileRunning(_, name): awake.app = name
        case .indefinitely, nil: break
        }
        return PhoneSnapshot(
            mac: PhoneNetwork.computerName, look: state.theme == .midnight ? "midnight" : "standard", now: now.timeIntervalSince1970,
            pages: pages,
            requests: agents.approvals.map { .init(id: $0.id, project: $0.project, action: $0.action, detail: $0.detail, host: $0.host) },
            agents: agents.sessions.map { session in
                .init(id: session.id, name: session.project, doing: session.summary, state: Self.state(of: session.activity), host: session.host,
                      since: session.since.timeIntervalSince1970, claude: session.isClaude)
            },
            music: music,
            timers: timers.soonestFirst(at: now).map { timer in
                .init(id: timer.id.uuidString, title: timer.title, ends: timer.endDate?.timeIntervalSince1970,
                      left: timer.pausedRemaining, duration: timer.duration, focused: timer.id == timers.focused)
            },
            ringing: timers.ringing?.title, awake: awake,
            ideas: IdeaBoard.rows(state.tod.ideas, now: now).map { row in
                .init(id: row.id, title: row.title, kind: row.kind.rawValue, label: row.label, overdue: row.overdue, stale: row.stale)
            },
            log: Feature.logPage.isOn ? logged : nil)
    }

    private static func state(of activity: AgentActivity) -> String {
        switch activity.priority {
        case 3: return "waiting"
        case 2: return "working"
        case 1: return "done"
        default: return "idle"
        }
    }

    func perform(_ action: PhoneAction) -> Bool {
        switch action {
        case let .allow(id), let .deny(id):
            guard let approval = state.agents.approvals.first(where: { $0.id == id }) else { return false }
            if case .allow = action { state.agents.answer(approval, allow: true) } else { state.agents.answer(approval, allow: false) }
        case .playPause: state.nowPlaying.togglePlayPause()
        case .next: state.nowPlaying.next()
        case .previous: state.nowPlaying.previous()
        case let .startTimer(minutes, label):
            let (label, pin) = ReminderParser.unpinned(label)
            state.timers.start(duration: (minutes * 60).rounded(), label: label, pin: pin)
        case let .pauseTimer(id), let .cancelTimer(id), let .focusTimer(id):
            guard state.timers.timers.contains(where: { $0.id == id }) else { return false }
            switch action {
            case .pauseTimer: state.timers.togglePause(id)
            case .focusTimer: state.timers.focus(id)
            default: state.timers.cancel(id)
            }
        case .dismissRinging: state.timers.dismissRinging()
        case let .awake(hours):
            if let hours {
                state.awake.start(.until(Date().addingTimeInterval(min(hours * 3600, AwakeManager.longest))))
            } else {
                state.awake.start(.indefinitely)
            }
        case .sleep: state.awake.stop()
        case let .addIdea(text): return state.tod.addIdea(text) != nil
        case let .ideaDone(id), let .keepIdea(id), let .putOff(id, _):
            guard state.tod.ideas.contains(where: { $0.id == id && !$0.done }) else { return false }
            switch action {
            case let .putOff(_, days): state.tod.putOff(id, by: days)
            case .keepIdea: state.tod.keep(id)
            default: state.tod.toggle(id)
            }
        case let .checkIn(text): return !state.workLog.checkIn(text).isEmpty
        case let .unlog(id):
            guard state.workLog.saved.entries.contains(where: { $0.id == id }) else { return false }
            state.workLog.remove(id)
        }
        return true
    }

    func artwork() -> Data? {
        guard let track = state.nowPlaying.track, let image = state.nowPlaying.artwork else { return nil }
        let art = String(track.id.hashValue, radix: 36)
        if let cover, cover.art == art { return cover.jpeg }
        // At most 600 pixels across: plenty for a phone, quick over the air.
        let side = min(600, max(image.size.width, image.size.height))
        let scale = side / max(image.size.width, image.size.height, 1)
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        cover = (art, jpeg)
        return jpeg
    }
}
