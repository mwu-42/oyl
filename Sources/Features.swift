import AppKit
import Combine
import SwiftUI

/// Everything in Oyl that can be turned off, each remembered (all on to begin with). A few older
/// settings keep their own places (the Oyls on the bar, the Dock, the mirror, the lyrics…; see
/// `SettingsPage`), but everything else is here. Read from anywhere: they're kept in the user's
/// defaults, which any thread may ask.
enum Feature: String, CaseIterable, Sendable {
    // The notch's pages (the Oyls' is always there: the settings are on it).
    case musicPage, timersPage, awakePage, activityPage, ideasPage, inboxPage, projectsPage
    /// GitHub's grid of your contributions, on the Activity page.
    case githubGrid
    /// With toyl installed (its list made), Oyl's to-dos, ideas, timers and projects are toyl's.
    case useToyl
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
    case claudeChats, cowork
    /// Looking for apps that talk to an AI service, to offer to watch them.
    case discovery

    // Hand gestures, each.
    case palmGesture, pointGesture, pinchGesture, peaceGesture, hornsGesture, pinkyGesture, oylsGesture,
         rockGesture

    // Keys.
    case screenshotTaps, offTaps, songKeys, missionControl
    /// Control and option together: the camera on for the gestures for a moment, or (twice) till
    /// they're tapped twice again.
    case cameraKeys
    /// Command-period: the emoji picker, from any app, as on Windows.
    case emojiKey

    // The Dock's shelf, and what's on it: screenshots, what's been saved, and what Claude Code's
    // written or edited.
    case shelf, screenshotsShelf, savedShelf, claudeShelf, labelScreenshots, hidesMacDock
    /// What comes by AirDrop shown on the shelf, not in a Finder window (see `AirDropReveal`).
    case airDropShelf
    /// Apps asking for you marked along the bottom edge, rather than bouncing in the macOS Dock.
    case attentionMarks

    /// The desktop you're on, named at the top left of the menu bar.
    case spaceLabel
    /// Picture in picture for any window, over every desktop: ⌃⌥P, or from Oyl's Dock.
    case pictureInPicture
    /// Four fingers up: the desktops in a list, to go to and rename.
    case desktopsView
    /// Right Shift twice: the same list.
    case desktopsKey

    case openAtLogin
    /// How much of Claude's 5-hour window is used, on the closed notch (see `ClaudeLimit`).
    case claudeLimit
    /// What's left of it, on the menu bar beside the notch (see `BarLimit`).
    case claudeLimitBar
    /// Your commits today, hour by hour, on the stats page (see `CommitTimeline`).
    case commitTimeline
    /// Your desktops' groups marked over macOS's Mission Control (see `MissionGroups`).
    case missionControlGroups
    /// A sound when a Claude's done, or waiting for you (see `AgentChimes`).
    case agentSounds
    /// A screenshot's thumbnail held for 10 s, as Oyl's own (see `ScreenshotHold`).
    case holdScreenshots
    /// Claude's 5-hour window started early, with a prompt each morning (see `MorningStart`).
    case morningClaude
    /// And another as each window ends, if none's going, till 2 AM.
    case claudeChain

    var key: String { "feature." + rawValue }

    var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? !Self.offToBegin.contains(self) }

    /// Off till they're turned on: what sends things in your name.
    static let offToBegin: Set<Feature> = [.morningClaude, .agentSounds, .holdScreenshots, .claudeLimitBar, .claudeChain]

    /// What a gesture does, if it can be turned off.
    init?(_ gesture: HandGesture) {
        switch gesture {
        case .openPalm: self = .palmGesture
        case .pointLeft, .pointRight: self = .pointGesture
        case .pinch: self = .pinchGesture
        case .peace: self = .peaceGesture
        case .horns: self = .hornsGesture
        case .pinky: self = .pinkyGesture
        case .announce, .tiltLeft, .tiltRight: self = .oylsGesture
        case .rock: self = .rockGesture
        case .ok, .fist, .thumbsUp: return nil
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
