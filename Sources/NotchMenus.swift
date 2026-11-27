import SwiftUI

// Settings where they're about, a right-click away: each part of the notch (a page, a tab, the
// 5-hour row on the stats page…) has a menu of the switches for what's there, and Settings… for
// the rest, opened on the section they're in. Everything's still on the settings page too.

/// Opens the settings page on a section (set by the notch for everything in it).
struct OpenSettingsKey: EnvironmentKey {
    static let defaultValue: @MainActor (SettingsSection) -> Void = { _ in }
}

extension EnvironmentValues {
    var openSettings: @MainActor (SettingsSection) -> Void {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

/// A setting's switch in a right-click menu, ticked while it's on.
struct FeatureToggle: View {
    let feature: Feature
    let title: String
    @ObservedObject private var features = Features.shared

    init(_ feature: Feature, _ title: String) {
        self.feature = feature
        self.title = title
    }

    var body: some View {
        Toggle(title, isOn: Binding(get: { features.isOn(feature) }, set: { features.set(feature, $0) }))
    }
}

private struct SettingsMenu<Items: View>: ViewModifier {
    let section: SettingsSection
    let items: Items
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.contextMenu {
            items
            Divider()
            Button("Settings…") { openSettings(section) }
        }
    }
}

extension View {
    /// Right-click: the switches for what's here, then Settings… (opened on `section`) for the rest.
    func settingsMenu<Items: View>(_ section: SettingsSection, @ViewBuilder _ items: () -> Items) -> some View {
        modifier(SettingsMenu(section: section, items: items()))
    }
}

/// Each page's own: the switches of what's on it.
struct PageMenu {
    /// The page's own feature, if it can be turned off (its tab goes with it).
    static func feature(of page: NotchPage) -> Feature? {
        switch page {
        case .music: return .musicPage
        case .timers: return .timersPage
        case .inbox: return .inboxPage
        case .awake: return .awakePage
        case .activity: return .activityPage
        case .usage: return .usagePage
        case .agents, .mirror, .settings: return nil
        }
    }

    static func name(of page: NotchPage) -> String {
        switch page {
        case .music: return "Music"
        case .timers: return "Timers"
        case .inbox: return "Inbox"
        case .awake: return "Awake"
        case .activity: return "Computer"
        case .usage: return "Usage"
        case .agents: return "Oyls"
        case .mirror: return "Mirror"
        case .settings: return "Settings"
        }
    }
}
