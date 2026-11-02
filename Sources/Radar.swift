import AppKit
import Combine
import SwiftUI

/// An agent Oyl knows how to watch, and how it tells the agent's at work. Claude Code, the Claude
/// app's chats and its Cowork tasks have tells of their own (hooks, the app's window, transcripts;
/// see `AgentMonitor`), and are features rather than entries here.
struct RadarAgent: Codable, Equatable, Identifiable, Sendable {
    enum Tell: String, Codable, Sendable {
        /// A browser tab on `target` (a site's host): working while its page offers to stop, wanting
        /// you while it asks you to approve something (see `WebAgents`).
        case tab
        /// An app's windows (`target`, its bundle ID): the same, in its windows (see `AppAgents`).
        case window
        /// A program run in a terminal or an editor (`target`, its name): working while it's busy
        /// (see `ProcessAgents`).
        case process
        /// An app (`target`, its bundle ID) that listens in, taking notes while it has the
        /// microphone (see `NoteTakers`).
        case microphone
    }

    let name: String
    let tell: Tell
    let target: String
    /// Its Oyl's hat while it works, as "#rrggbb"; nil for black (Claude's are orange).
    var hat: String?
    /// Added by you, rather than one Oyl knew already.
    var added = false

    var id: String { tell.rawValue + ":" + target }

    var hatColor: Color? { hat.flatMap(Color.init(hex:)) }

    /// What it's called on the settings page: a site by its address, a program by its name.
    var title: String {
        switch tell {
        case .tab: return name == target ? name : "\(name) (web)"
        case .window, .microphone: return name
        case .process: return "\(name) (\(target))"
        }
    }
}

/// The agents Oyl watches: those it knows on any Mac, and any you've added (from the notch's
/// right-click, with an app or a site in front, or a suggestion `AgentDiscovery` made), each
/// turned on or off. Remembered.
@MainActor
final class AgentRadar: ObservableObject {
    static let shared = AgentRadar()

    /// Known on any Mac: agents and chats in a browser, apps, programs in a terminal, and note
    /// takers. Each is only looked for while it's there.
    nonisolated static let known: [RadarAgent] = [
        RadarAgent(name: "Muse", tell: .tab, target: "muse.ai"),
        RadarAgent(name: "ChatGPT", tell: .tab, target: "chatgpt.com", hat: "#10a37f"),
        RadarAgent(name: "Claude", tell: .tab, target: "claude.ai", hat: "#d97757"),
        RadarAgent(name: "Gemini", tell: .tab, target: "gemini.google.com", hat: "#4285f4"),
        RadarAgent(name: "Perplexity", tell: .tab, target: "perplexity.ai", hat: "#20808d"),
        RadarAgent(name: "Grok", tell: .tab, target: "grok.com"),
        RadarAgent(name: "Copilot", tell: .tab, target: "copilot.microsoft.com", hat: "#0078d4"),
        RadarAgent(name: "DeepSeek", tell: .tab, target: "chat.deepseek.com", hat: "#4d6bfe"),
        RadarAgent(name: "Le Chat", tell: .tab, target: "chat.mistral.ai", hat: "#fa520f"),
        RadarAgent(name: "Manus", tell: .tab, target: "manus.im"),
        RadarAgent(name: "Lovable", tell: .tab, target: "lovable.dev", hat: "#ff5c8a"),
        RadarAgent(name: "v0", tell: .tab, target: "v0.app"),
        RadarAgent(name: "Bolt", tell: .tab, target: "bolt.new", hat: "#1389fd"),
        RadarAgent(name: "Replit", tell: .tab, target: "replit.com", hat: "#f26207"),
        RadarAgent(name: "ChatGPT", tell: .window, target: "com.openai.chat", hat: "#10a37f"),
        RadarAgent(name: "Codex", tell: .window, target: "com.openai.codex", hat: "#10a37f"),
        RadarAgent(name: "Perplexity", tell: .window, target: "ai.perplexity.mac", hat: "#20808d"),
        RadarAgent(name: "Codex", tell: .process, target: "codex", hat: "#10a37f"),
        RadarAgent(name: "Gemini CLI", tell: .process, target: "gemini", hat: "#4285f4"),
        RadarAgent(name: "Aider", tell: .process, target: "aider", hat: "#14b014"),
        RadarAgent(name: "OpenCode", tell: .process, target: "opencode"),
        RadarAgent(name: "Goose", tell: .process, target: "goose"),
        RadarAgent(name: "Amp", tell: .process, target: "amp", hat: "#f34e3f"),
        RadarAgent(name: "Cursor Agent", tell: .process, target: "cursor-agent"),
        RadarAgent(name: "Crush", tell: .process, target: "crush", hat: "#6b50ff"),
        RadarAgent(name: "Qwen Code", tell: .process, target: "qwen", hat: "#615ced"),
        RadarAgent(name: "Copilot CLI", tell: .process, target: "copilot", hat: "#0078d4"),
        RadarAgent(name: "Granola", tell: .microphone, target: "com.granola.app"),
    ]

    /// Every agent, known first, then yours.
    @Published private(set) var all: [RadarAgent] = []
    /// Apps and programs that seem to use AI, to offer to watch (see `AgentDiscovery`).
    @Published private(set) var suggestions: [RadarAgent] = []
    private var added: [RadarAgent]
    private var off: Set<String>
    /// Suggestions turned down, never made again.
    private var declined: Set<String>

    private static let addedKey = "radar.added", offKey = "radar.off", declinedKey = "radar.declined"

    private init() {
        let defaults = UserDefaults.standard
        added = defaults.data(forKey: Self.addedKey).flatMap { try? JSONDecoder().decode([RadarAgent].self, from: $0) } ?? []
        off = Set(defaults.stringArray(forKey: Self.offKey) ?? [])
        declined = Set(defaults.stringArray(forKey: Self.declinedKey) ?? [])
        all = Self.known + added
    }

    /// Those turned on.
    var watching: [RadarAgent] { all.filter { !off.contains($0.id) } }

    func watching(_ tell: RadarAgent.Tell) -> [RadarAgent] { watching.filter { $0.tell == tell } }

    func isOn(_ agent: RadarAgent) -> Bool { !off.contains(agent.id) }

    /// Whether it's on the list at all, on or off.
    func knows(_ id: String) -> Bool { all.contains { $0.id == id } }

    func set(_ agent: RadarAgent, on: Bool) {
        guard on != isOn(agent) else { return }
        if on { off.remove(agent.id) } else { off.insert(agent.id) }
        UserDefaults.standard.set(Array(off).sorted(), forKey: Self.offKey)
        all = Self.known + added
    }

    /// On the list, and on (a suggestion taken, too).
    func add(_ agent: RadarAgent) {
        suggestions.removeAll { $0.id == agent.id }
        if !knows(agent.id) {
            var agent = agent
            agent.added = true
            added.append(agent)
            saveAdded()
        }
        set(agent, on: true)
        all = Self.known + added
    }

    /// Off the list: only yours can go (one Oyl knows is turned off instead).
    func remove(_ agent: RadarAgent) {
        guard added.contains(where: { $0.id == agent.id }) else {
            set(agent, on: false)
            return
        }
        added.removeAll { $0.id == agent.id }
        off.remove(agent.id)
        UserDefaults.standard.set(Array(off).sorted(), forKey: Self.offKey)
        saveAdded()
        all = Self.known + added
    }

    /// Offered to be watched, unless it's known or was turned down.
    func suggest(_ agent: RadarAgent) {
        guard !knows(agent.id), !declined.contains(agent.id), !suggestions.contains(where: { $0.id == agent.id }) else { return }
        suggestions.append(agent)
    }

    func decline(_ agent: RadarAgent) {
        suggestions.removeAll { $0.id == agent.id }
        declined.insert(agent.id)
        UserDefaults.standard.set(Array(declined).sorted(), forKey: Self.declinedKey)
    }

    /// Everything a suggestion can't be: known, turned down, or already offered.
    /// (And what each known one is, so an app watched one way isn't offered to be watched another.)
    var unsuggestable: Set<String> {
        Set(all.map(\.id) + all.map(\.target)).union(declined).union(suggestions.map(\.id))
    }

    private func saveAdded() {
        UserDefaults.standard.set(try? JSONEncoder().encode(added), forKey: Self.addedKey)
    }

    // MARK: What's in front

    /// What could be watched in the app in front: the site its tab's on, if it's a browser, or
    /// the app; nil for Oyl, the Finder, the Claude app (watched already) and editors (whose
    /// windows can't be read without turning on their screen reader support). Asks the browser
    /// for its tab, so it's slow: off the main thread.
    nonisolated static func front(app: NSRunningApplication?) -> RadarAgent? {
        guard let app, let id = app.bundleIdentifier, app.processIdentifier != getpid() else { return nil }
        if WebAgents.isBrowser(id) {
            guard let address = WebAgents.frontTab(of: id), let url = URL(string: address), var host = url.host?.lowercased(),
                  url.scheme == "https" || url.scheme == "http" else { return nil }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if let known = known.first(where: { $0.tell == .tab && (host == $0.target || host.hasSuffix("." + $0.target)) }) {
                return known
            }
            return RadarAgent(name: host, tell: .tab, target: host)
        }
        guard !unwatchableApps.contains(id), !id.hasPrefix("com.apple."), app.activationPolicy == .regular else { return nil }
        if let known = known.first(where: { ($0.tell == .window || $0.tell == .microphone) && $0.target == id }) { return known }
        return RadarAgent(name: app.localizedName ?? id, tell: .window, target: id)
    }

    /// Apps never watched by their windows: the Claude app (watched its own way), and editors
    /// built on VS Code, which change how they behave once their windows are read.
    nonisolated static let unwatchableApps: Set = [
        ClaudeAppChats.bundleID, "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
    ]
}

extension Color {
    /// "#rrggbb".
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
