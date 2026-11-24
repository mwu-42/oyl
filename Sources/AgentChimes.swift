import AppKit

/// A sound when a Claude's done: one as it finishes its turn (it was at work, and now it's done),
/// another as it starts waiting for you (a permission, a question, a plan to look over). Each look
/// its own: in Oyl's, Glass and Ping, as macOS has them; in Midnight Oyl's, softer, Submarine and
/// Purr. Not while Oyl's off, not for one first seen already done or waiting (as Oyl starts), and
/// never more than one a second and a half, however many finish together. On the Agents settings,
/// off to begin with.
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

    /// The sessions as they are now: a sound if one's just finished, or just begun waiting.
    func update(_ sessions: [AgentSession], theme: NotchTheme, isOff: Bool, at now: Date = Date()) {
        let before = last
        last = Dictionary(sessions.map { ($0.id, $0.activity) }, uniquingKeysWith: { _, latest in latest })
        guard Feature.agentSounds.isOn, !isOff, now.timeIntervalSince(lastChime) >= Self.apart else { return }
        let kinds = sessions.filter(\.isClaude).compactMap { Self.chime(from: before[$0.id], to: $0.activity) }
        // Waiting for you says more than done.
        guard let kind = kinds.contains(.waiting) ? .waiting : kinds.first else { return }
        lastChime = now
        Self.play(kind, theme: theme)
    }

    nonisolated static func sound(_ kind: Kind, theme: NotchTheme) -> String {
        switch (kind, theme == .midnight) {
        case (.done, false): return "Glass"
        case (.waiting, false): return "Ping"
        case (.done, true): return "Submarine"
        case (.waiting, true): return "Purr"
        }
    }

    static func play(_ kind: Kind, theme: NotchTheme) {
        NSSound(named: NSSound.Name(sound(kind, theme: theme)))?.play()
    }
}
