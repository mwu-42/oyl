import AppKit
import Combine
import SwiftUI

/// Everything in Oyl that can be turned off, each remembered (all on to begin with). A few older
/// settings keep their own places (the Oyls on the bar, the Dock, the mirror, the lyrics…; see
/// `SettingsPage`), but everything else is here. Read from anywhere: they're kept in the user's
/// defaults, which any thread may ask.
enum Feature: String, CaseIterable, Sendable {
    // The notch's pages (the Oyls' is always there: the settings are on it).
    case musicPage, timersPage, awakePage, activityPage, ideasPage, logPage
    /// The notch asking each day what you got done, for the work log.
    case checkIn
    /// The trackpad's tap as the notch pops, opens, and takes a gesture.
    case haptics
    /// Wispr Flow's listening, in the closed notch, and its button.
    case wisprFlow
    /// The music's sound analyzed, for the visualizer and the beat.
    case visualizer
    /// The song's name a click away from its player.
    case songTitleOpensPlayer

    // What Oyls come out for.
    case musicOyl, timerOyls, awakeOyl, batteryOyl, selfieOyl, hangoutOyl, agentOyls

    // Agents (and each of the radar's own, by its ID; see `AgentRadar`).
    case claudeCode
    /// Claude Code's requests answered from the notch, rather than where it runs.
    case approvals
    case claudeChats, cowork
    /// Looking for apps that talk to an AI service, to offer to watch them.
    case discovery

    // Hand gestures, each.
    case palmGesture, pointGesture, pinchGesture, peaceGesture, hornsGesture, pinkyGesture, thumbsUpGesture,
         oylsGesture, rockGesture

    // Keys.
    case screenshotTaps, offTaps, songKeys, missionControl
    /// Control and option together: the camera on for the gestures for a moment, or (twice) till
    /// they're tapped twice again.
    case cameraKeys
    case approveTap
    /// Command-period: the emoji picker, from any app, as on Windows.
    case emojiKey

    // The Dock's shelf, and what's on it: screenshots, what's been saved, and what Claude Code's
    // written or edited.
    case shelf, screenshotsShelf, savedShelf, claudeShelf, labelScreenshots, hidesMacDock
    /// Apps asking for you marked along the bottom edge, rather than bouncing in the macOS Dock.
    case attentionMarks

    case openAtLogin

    var key: String { "feature." + rawValue }

    var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// What a gesture does, if it can be turned off.
    init?(_ gesture: HandGesture) {
        switch gesture {
        case .openPalm: self = .palmGesture
        case .pointLeft, .pointRight: self = .pointGesture
        case .pinch: self = .pinchGesture
        case .peace: self = .peaceGesture
        case .horns: self = .hornsGesture
        case .pinky: self = .pinkyGesture
        case .thumbsUp: self = .thumbsUpGesture
        case .announce, .tiltLeft, .tiltRight: self = .oylsGesture
        case .rock: self = .rockGesture
        case .ok, .fist: return nil
        }
    }
}

/// Turns features on and off, and says when one has.
@MainActor
final class Features: ObservableObject {
    static let shared = Features()

    /// Each feature as it's turned on or off.
    let changed = PassthroughSubject<(Feature, Bool), Never>()

    func isOn(_ feature: Feature) -> Bool { feature.isOn }

    func set(_ feature: Feature, _ on: Bool) {
        guard on != feature.isOn else { return }
        objectWillChange.send()
        UserDefaults.standard.set(on, forKey: feature.key)
        changed.send((feature, on))
    }

    func toggle(_ feature: Feature) { set(feature, !feature.isOn) }

    /// Calls `action` with whether `feature`'s on: now, and whenever that changes.
    func follow(_ feature: Feature, _ action: @escaping @MainActor (Bool) -> Void) -> AnyCancellable {
        action(feature.isOn)
        return changed
            .filter { $0.0 == feature }
            .sink { change in MainActor.assumeIsolated { action(change.1) } }
    }
}

/// The trackpad's taps, unless they're turned off.
enum Haptics {
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern,
                        performanceTime: NSHapticFeedbackManager.PerformanceTime = .now) {
        guard Feature.haptics.isOn else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: performanceTime)
    }
}

/// Oyl's name, and what it stands for.
enum Motto {
    static let name = "Oyl"
    static let words = "Own your life"
}
