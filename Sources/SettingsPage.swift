import AppKit
import ServiceManagement
import SwiftUI

/// The settings' sections, along the top of their page.
enum SettingsSection: String, CaseIterable {
    case notch = "Notch", oyls = "Oyls", agents = "Agents", hands = "Hands", keys = "Keys", dock = "Dock", oyl = "Oyl"
}

/// One setting: on or off (or, for a few, a button), what it does, and for an agent you added,
/// a way to take it off the list.
struct SettingItem: Identifiable {
    let id: String
    let title: String
    /// What it does, said as it's pointed at; worked out only as it's shown, not each time the
    /// items are counted (which is on every move of the pointer, for the page's height, and the
    /// phone remote's asks the network for the Mac's addresses).
    var hint: String { says() }
    private let says: () -> String
    var isOn = false
    var action: () -> Void
    /// A button (Quit, Turn off…), not a switch.
    var isButton = false
    var remove: (() -> Void)?
    /// A value it has, moved down or up (‹ and ›, after its title): a time, say.
    var adjust: (down: () -> Void, up: () -> Void)?

    init(id: String, title: String, hint: @autoclosure @escaping () -> String, isOn: Bool = false,
         action: @escaping () -> Void, isButton: Bool = false, remove: (() -> Void)? = nil,
         adjust: (down: () -> Void, up: () -> Void)? = nil) {
        self.id = id
        self.title = title
        says = hint
        self.isOn = isOn
        self.action = action
        self.isButton = isButton
        self.remove = remove
        self.adjust = adjust
    }
}

/// Every setting there is, a section at a time, two to a row (each says what it does when
/// pointed at); past as many rows as fit, they scroll. Opened from the Oyls page, or a right-click
/// on the notch. Under them, what Oyl stands for.
struct SettingsPage: View {
    @ObservedObject var state: NotchState
    @ObservedObject var radar = AgentRadar.shared
    @ObservedObject var features = Features.shared
    @ObservedObject var morning = MorningStart.shared
    @ObservedObject var chimes = ChimeSettings.shared

    var body: some View {
        SettingsLayout(section: $state.settingsSection, items: Self.items(state.settingsSection, state: state),
                       card: Self.showsPairing(state) ? AnyView(PhonePairingCard(phone: state.phone)) : nil)
    }

    /// A phone's being paired, from the Oyl section: its card's showing in place of the settings.
    @MainActor
    static func showsPairing(_ state: NotchState) -> Bool {
        state.settingsSection == .oyl && state.phone.pairing != nil
    }

    // MARK: What's in each section

    /// Every setting in `section` that does something in this look and on this Mac.
    @MainActor
    static func items(_ section: SettingsSection, state: NotchState) -> [SettingItem] {
        let midnight = state.theme == .midnight
        let oyl = midnight ? "Moyl" : "Oyl"
        func feature(_ feature: Feature, _ title: String, _ hint: String) -> SettingItem {
            SettingItem(id: feature.rawValue, title: title, hint: hint, isOn: feature.isOn) { Features.shared.toggle(feature) }
        }
        switch section {
        case .notch:
            var items = [
                feature(.musicPage, "Music page", "The song, its cover and controls"),
                SettingItem(id: "lyrics", title: "Lyrics", hint: midnight ? "Floating in the sky under the notch, from song to song"
                                : "Under the song, from song to song",
                            isOn: state.showsLyrics) { state.showsLyrics.toggle() },
                // The lyrics on the menu bar too, each look its own way.
                SettingItem(id: "lyricsClosed", title: "Lyrics on the bar",
                            hint: midnight ? "Beside the notch while it's closed too; a song without any, a constellation to its beat"
                                : "Sung line by line by the music Oyl on the menu bar; off, it DJs",
                            isOn: state.showsLyricsClosed) {
                    state.showsLyricsClosed.toggle()
                    // Turned on, they need the lyrics on to show at all.
                    if state.showsLyricsClosed { state.showsLyrics = true }
                },
            ]
            items += [
                feature(.visualizer, "Visualizer", "Listens to the music, for the wave and the beat"),
                feature(.songTitleOpensPlayer, "Song name opens player", "Click the song's name for Spotify or Music"),
                feature(.timersPage, "Timers page", "Timers and reminders"),
            ]
            // With toyl here, its setting; and while it's toyl's list, toyl's ideas and no outline.
            if TodStore.hasToyl {
                items.append(feature(.useToyl, "toyl in Oyl", "On: Oyl's to-dos, ideas, timers and lists are toyl's. Off: nothing of toyl's in Oyl, which goes back to its own (and tod's). Also on the notch's right-click"))
            }
            if state.usesToyl {
                items.append(feature(.inboxPage, "Inbox page", "Put a task in toyl's inbox, read as toyl reads it, and see what's there"))
            } else {
                items += [
                    feature(.inboxPage, "Inbox page", "Put a task in tod's inbox (“#name” for a list), and see what's there"),
                    feature(.projectsPage, "Projects outline", "Areas, projects and their tasks, ideas and screenshots, as an outline in its own window (right-click the notch: Projects…), with reminders"),
                ]
            }
            items += [
                feature(.awakePage, "Keep-awake page", "Keeping the Mac awake"),
                feature(.activityPage, "Computer page", "The processor, memory, network, battery and the Mac's temperature"),
                feature(.usagePage, "Usage page", "Claude Code's tokens and 5-hour windows, your commits and GitHub's grid"),
                feature(.githubGrid, "GitHub grid", "Your GitHub contributions this past year, on the usage page, read with GitHub's gh tool"),
                feature(.claudeLimit, "Claude's 5 hours", "On the usage page: how much of Claude's 5-hour limit window is used and when it resets, as Claude Code's /usage says, read every few minutes"),
                feature(.claudeLimitBar, "5 hours on the bar", "On the menu bar, just right of the notch: how much of Claude's 5-hour limit window is left (5h 81% left), amber under 20%"),
                feature(.commitTimeline, "Commits", "On the usage page: your commits today, hour by hour, from the git repositories Claude Code's worked in (yours only, unpushed ones too)"),
            ]
            if !midnight {
                items.append(SettingItem(id: "mirror", title: "Mirror", hint: "The camera, for a look at yourself before a call",
                                         isOn: state.showsMirror) { state.showsMirror.toggle() })
            }
            items.append(feature(.haptics, "Haptics", "A tap of the trackpad as the notch pops and opens"))
            if state.dictation.isAvailable {
                items.append(feature(.wisprFlow, "Wispr Flow", "When it's listening, in the notch, and its button"))
            }
            return items
        case .oyls:
            var items = [
                SettingItem(id: "oyls", title: midnight ? "Moyls" : "Oyls on the bar", hint: "Every \(oyl), out for what's going on",
                            isOn: state.oylsVisible) { state.oylsVisible.toggle() },
                SettingItem(id: "countdowns", title: "Countdowns", hint: "Beside timers' \(oyl)s all the time, not just at the end",
                            isOn: state.showsCountdowns) { state.showsCountdowns.toggle() },
            ]
            if !midnight {
                items.append(SettingItem(id: "dim", title: "Dim the bar", hint: "The menu bar goes dark behind the Oyls",
                                         isOn: state.dimsMenuBar) { state.dimsMenuBar.toggle() })
            }
            items += [
                feature(.spaceLabel, "Desktop's name", "Top left of the bar: the desktop you're on. Click it to rename it"),
                feature(.agentOyls, "Agents' \(oyl)s", "One for each agent at work"),
                feature(.musicOyl, "Music \(oyl)", "Dancing (or reading) to what's playing"),
                feature(.timerOyls, "Timers' \(oyl)s", "One for each timer and reminder"),
                feature(.awakeOyl, "Keep-awake \(oyl)", "On energy drinks while the Mac's kept awake"),
                feature(.batteryOyl, "Battery \(oyl)", "Tired when the battery's low"),
                SettingItem(id: "bedtime", title: "Bedtime \(oyl)", hint: "Up past midnight, then off to bed; at two, telling you to go too",
                            isOn: state.bedtime.isEnabled) { state.bedtime.isEnabled.toggle() },
                feature(.selfieOyl, "Selfie \(oyl)", "Holding up a selfie just taken"),
                feature(.hangoutOyl, "Hanging-out \(oyl)", "Out when nothing else is going on"),
            ]
            return items
        case .agents:
            var items = [
                feature(.claudeCode, "Claude Code", "In a terminal, an editor or the Claude app's Code tab"),
                feature(.claudeChats, "Claude app chats", "The chat showing in the Claude app"),
                feature(.cowork, "Cowork tasks", "Each of the Claude app's Cowork tasks"),
            ]
            let radar = AgentRadar.shared
            for agent in radar.all {
                items.append(SettingItem(id: agent.id, title: agent.title, hint: hint(for: agent), isOn: radar.isOn(agent),
                                         action: { radar.set(agent, on: !radar.isOn(agent)) },
                                         remove: agent.added ? { radar.remove(agent) } : nil))
            }
            for agent in radar.suggestions {
                items.append(SettingItem(id: "suggested " + agent.id, title: "\(agent.name)?",
                                         hint: "Seems to use AI. Click to watch it as an agent", action: { radar.add(agent) },
                                         remove: { radar.decline(agent) }))
            }
            items.append(feature(.discovery, "Find new agents", "Offer to watch apps that talk to an AI service"))
            items.append(feature(.agentSounds, "🔔 Sound when Claude's done",
                                 "A low, soft sound as a Claude finishes its turn (three notes rising), another as it starts waiting for you, for a permission or a question (two soft taps); each place it runs can have its own"))
            if Feature.agentSounds.isOn {
                // Each place a Claude's been seen running, and everywhere else: click to hear it, ‹ › for another.
                let chimes = ChimeSettings.shared
                // How loud: ‹ › by a tenth, clicked to hear it (as the first place's sound).
                let heard = { chimes.voice(for: chimes.sources.first ?? ChimeSettings.elsewhere).play(.done, midnight: midnight) }
                items.append(SettingItem(id: "chime volume", title: "🔊 Volume: \(chimes.volumeSaid)",
                                         hint: "How loud the sounds are, of the Mac's own volume: ‹ › a tenth quieter or louder, from 10% to 150% (past 100%, Oyl's own tones louder still; macOS's and the sounds folder's are at their loudest by then); click to hear it",
                                         action: heard, isButton: true,
                                         adjust: (down: {
                                             chimes.stepVolume(by: -1)
                                             heard()
                                         }, up: {
                                             chimes.stepVolume(by: 1)
                                             heard()
                                         })))
                for source in chimes.sources + [ChimeSettings.elsewhere] {
                    items.append(SettingItem(id: "chime " + source, title: "🔔 \(source): \(chimes.says(source))",
                                             hint: "Click to hear it; ‹ › for another: Oyl's tones, any sound file in its sounds folder, macOS's, or none",
                                             action: { chimes.voice(for: source).play(.done, midnight: midnight) }, isButton: true,
                                             adjust: (down: {
                                                 chimes.step(source, by: -1)
                                                 chimes.voice(for: source).play(.done, midnight: midnight)
                                             }, up: {
                                                 chimes.step(source, by: 1)
                                                 chimes.voice(for: source).play(.done, midnight: midnight)
                                             })))
                }
                items.append(SettingItem(id: "chime folder", title: "Sounds folder…",
                                         hint: "Any sound file put here (WAV, AIFF, MP3, M4A) can be a place's sound",
                                         action: {
                                             let folder = ChimeVoice.folder()
                                             try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                             NSWorkspace.shared.open(folder)
                                         }, isButton: true))
            }
            let morning = MorningStart.shared
            items.append(SettingItem(id: Feature.morningClaude.rawValue, title: "☀ Claude at \(morning.time)",
                                     hint: "Each morning at \(morning.time), a one-word prompt to Claude (Haiku, through Claude Code, on your plan) starts your 5-hour limit window, so it resets that much sooner. ‹ › change the time. The Mac has to be awake: missed while it sleeps, it's sent when it wakes, within 4 hours. " + morning.lastSaid,
                                     isOn: Feature.morningClaude.isOn, action: { Features.shared.toggle(.morningClaude) },
                                     adjust: (down: { morning.move(by: -1) }, up: { morning.move(by: 1) })))
            items.append(feature(.claudeChain, "↻ And as each one ends",
                                 "When a window ends with none going, another one-word prompt starts the next, till 2 AM: from \(morning.time), at \(morning.chainSaid) if you're not using Claude meanwhile (it waits for yours if you are)"))
            if let front = state.front, !radar.knows(front.id) {
                items.append(SettingItem(id: "front", title: "Watch \(front.name)", hint: "As an agent: \(hint(for: front))",
                                         action: { radar.add(front) }, isButton: true))
            }
            return items
        case .hands:
            let gestures = state.gestures
            var items = [
                SettingItem(id: "gestures", title: "Hand gestures", hint: "The camera watches for them while the notch is open",
                            isOn: gestures?.isEnabled ?? false) { gestures?.isEnabled.toggle() },
                feature(.palmGesture, "✋ Play or pause", "A raised hand (stops a timer that's ringing, too)"),
                feature(.pointGesture, "👉 Skip", "Point left or right for the song before or next"),
                feature(.pinchGesture, "🤏 Volume and scrub", "Pinch and twist; with the pinky up, drag to scrub"),
                feature(.peaceGesture, "✌️ Selfie", "Saved in Pictures, beside your screen"),
                feature(.hornsGesture, "🤟 Keep awake", "Keeps the Mac awake, or stops"),
                feature(.pinkyGesture, "Pinky: lyrics", "Shows the lyrics, and the music \(oyl) sings"),
                feature(.oylsGesture, "\(oyl)s' gestures", "Thumb on the ring finger: they say what they're doing; tip it to line them up or send them off"),
                feature(.flickGesture, "Flick: desktops", "A quick flick of the wrist, the fingers swung up: your desktops in a list, as four fingers up bring them; flicked down, put away"),
            ]
            if midnight {
                items.append(feature(.rockGesture, "🤘 Hand pointer", "The rock sign: your hands become the mouse"))
            }
            return items
        case .keys:
            var items = [
                feature(.screenshotTaps, "⌘⌘ Screenshot", "Command twice: a screenshot of part of the screen"),
                feature(.offTaps, "⌃⌃⌃ Switch off", "Control three times: Oyl off for a while, or back on"),
                feature(.themeKey, "⌃ ⌃ held: Other look", "Control once, then pressed again and held a moment: Midnight Oyl, or back to Oyl's look, from any app"),
                feature(.themeSound, "⌃ ⌃ held: its sound", "As the look swaps: moonrise into Midnight Oyl, daybreak back, both rising (and a tap of the trackpad, with Haptics on)"),
                feature(.songKeys, "⌃⌥← → Songs", "The song before, or the next, from any app"),
                feature(.emojiKey, "⌘. Emoji", "The emoji picker, from any app, as on Windows"),
                feature(.windowSnapping, "Snapping windows", "Drag a window up toward the notch: three places to drop it come up under it, the left half, the middle (as big as it is) and the right half, where it'll go shown as you're over one"),
                feature(.pictureInPicture, "⌃⌥P Picture in picture", "The window in front, kept up small over every desktop and fullscreen app (or right-click an app in Oyl's Dock); again to put it away"),
                feature(.desktopsClock, "Time in the desktops", "The time and the day, over the list of your desktops"),
                feature(.desktopsKey, "⇧⇧ Desktops", "The right Shift key twice, quickly: your desktops in a list, as four fingers up bring them (whatever macOS does with four fingers); twice again puts it away"),
                feature(.missionControlGroups, "Groups in Mission Control", "Over macOS's own Mission Control: each group of your desktops marked under its row, and a group whose desktops aren't next to each other marked split, to drag back together there"),
                feature(.shiftCamera, "⇧ held: Camera", "The right Shift key held a moment on its own: the camera on for gestures while it's held (even with them off on the notch), what it sees shown on the closed notch"),
                feature(.optionLatest, "⌥ held: Latest Claude", "Option (either one) held a moment on its own: straight to the Claude that last finished, or began waiting for you, with no slide through the desktops between"),
                feature(.cameraKeys, "⌃⌥ Camera", "Control and Option: the camera on for gestures for 3 s, wherever you are; twice, on till twice again"),
                feature(.missionControl, "Out of the way", "Of Mission Control and the desktops"),
                SettingItem(id: Feature.desktopsView.rawValue, title: "Four fingers up: desktops",
                            hint: !MissionControlSwipe.isTheSystems()
                                ? "Your desktops and fullscreen apps in a list, with the apps on each: click one to go straight there, right-click one to rename it, drag one onto another (or shift-click from one to another) to group them; four fingers down, Escape or a click puts it away"
                                : MissionControlSwipe.isOnThreeFingers()
                                ? "Your desktops in a list, to go to, rename and group. macOS opens Mission Control with four fingers too: free them (below) and Mission Control keeps three"
                                : "Your desktops in a list, to go to, rename and group. First set Mission Control's swipe to three fingers or off, in System Settings › Trackpad › More Gestures (turning this on opens it)",
                            isOn: Feature.desktopsView.isOn) {
                    Features.shared.toggle(.desktopsView)
                    // macOS answering four fingers up itself, and not something Oyl can change: where to change it.
                    if Feature.desktopsView.isOn, MissionControlSwipe.isTheSystems(), !MissionControlSwipe.isOnThreeFingers() {
                        MissionControlSwipe.openSettings()
                    }
                },
            ]
            if Feature.desktopsView.isOn, MissionControlSwipe.isTheSystems(), MissionControlSwipe.isOnThreeFingers() {
                items.append(SettingItem(id: "freeFourFingers", title: "Free four fingers",
                                         hint: "macOS's four-finger swipe up and down turned off, so four fingers up are Oyl's; Mission Control keeps three (picking three fingers in Trackpad settings again turns it back on)",
                                         action: { MissionControlSwipe.setFourFingers(free: true) }, isButton: true))
            }
            return items
        case .dock:
            return [
                SettingItem(id: "dock", title: "Oyl's Dock", hint: "Along the bottom, over the macOS Dock", isOn: state.showsDock) {
                    state.showsDock.toggle()
                },
                feature(.hidesMacDock, "Keep the macOS Dock down", "While Oyl's Dock is on, the macOS Dock never comes up at the bottom edge (your own setting's back once Oyl's is off, or Oyl's quit)"),
                feature(.attentionMarks, "Apps asking for you", "A small mark at the bottom edge, under its icon, till you go to it: no more bouncing"),
                feature(.shelf, "The shelf", "In the Dock: what's recent, to drag anywhere or convert"),
                feature(.screenshotsShelf, "Screenshots on it", "Your latest screenshots (light green)"),
                feature(.savedShelf, "Downloads on it", "What's just been downloaded, AirDropped or saved from a text (blue)"),
                feature(.airDropShelf, "AirDrops shown on it", "What comes by AirDrop: the Dock up, the shelf open and it picked out, not a Finder window (other apps' Show in Finder is still Finder's)"),
                feature(.claudeShelf, "Claude's files on it", "What Claude Code's just written or edited (orange)"),
                feature(.labelScreenshots, "Label screenshots", "Named for what's in them, read on the Mac"),
                feature(.holdScreenshots, "Screenshots held 10 s", "A screenshot's thumbnail kept up in the corner for 10 seconds, as Oyl's own (macOS's turned off meanwhile, so the file's saved at once): drag it where it's wanted, click it to open it, point at it to keep it"),
            ]
        case .oyl:
            var items = [
                SettingItem(id: "midnight", title: "Midnight Oyl", hint: "A celestial atlas, for looking at", isOn: midnight) {
                    state.theme = midnight ? .standard : .midnight
                },
            ]
            if midnight {
                items.append(SettingItem(id: "pinned", title: "Stay open", hint: "On display, as clicking the moon does",
                                         isOn: state.isPinned) { state.isPinned.toggle() })
            }
            items.append(SettingItem(id: Feature.openAtLogin.rawValue, title: "Open at login", hint: "Oyl starts with the Mac",
                                     isOn: Feature.openAtLogin.isOn) { LoginItem.set(!Feature.openAtLogin.isOn) })
            let phone = state.phone
            let paired = phone.devices.count
            items.append(SettingItem(id: "phone", title: "Phone remote",
                                     hint: phone.isOn ? "At \(phone.address)" + (phone.overTailscale ? ", over Tailscale" : " on this Wi-Fi")
                                         + (paired > 0 ? ", for \(paired) paired" : "")
                                         : "The notch from your phone's browser, on this Wi-Fi or over Tailscale: agents, music, timers, keep-awake",
                                     isOn: phone.isOn) { phone.setOn(!phone.isOn) })
            if phone.isOn {
                items.append(SettingItem(id: "pair", title: paired > 0 ? "Pair another phone" : "Pair a phone",
                                         hint: "A code to scan with its camera, good for five minutes", action: { phone.pair() }, isButton: true))
            }
            if paired > 0 {
                items.append(SettingItem(id: "forget", title: paired > 1 ? "Forget \(paired) phones" : "Forget the phone",
                                         hint: "Each has to be paired again", action: { phone.forget() }, isButton: true))
            }
            items += [
                SettingItem(id: "quit", title: "Quit Oyl", hint: "Till it's opened again, or the next login",
                            action: { Quitting.quit(state.awake) }, isButton: true),
                SettingItem(id: "off", title: "Turn off Oyl", hint: "Quits, and doesn't open at login till you open it again",
                            action: { Quitting.turnOff(state.awake) }, isButton: true),
            ]
            return items
        }
    }

    private static func hint(for agent: RadarAgent) -> String {
        switch agent.tell {
        case .tab: return "At \(agent.target), in the browser"
        case .window: return "Its windows, while one offers to stop"
        case .process: return "Run as “\(agent.target)”, while it's busy"
        case .microphone: return "Taking notes while it has the microphone"
        }
    }
}

/// The settings page's look: its sections along the top, the section's settings two to a row
/// (scrolling past as many as fit), and the motto under them.
struct SettingsLayout: View {
    @Binding var section: SettingsSection
    let items: [SettingItem]
    /// Shown in the settings' place (a phone's pairing card).
    var card: AnyView?
    @Environment(\.notchTheme) private var theme
    @Namespace private var chips

    var body: some View {
        let rows = (items.count + 1) / 2
        VStack(alignment: .leading, spacing: 0) {
            sections
                .frame(height: Layout.settingsChipsHeight)
                .padding(.bottom, Layout.settingsGap)
            Group {
                if let card {
                    card
                } else if rows <= Layout.settingsRowsFit {
                    grid
                } else {
                    ScrollView(.vertical, showsIndicators: false) { grid }
                }
            }
            .frame(height: Layout.settingsRows(card == nil ? min(rows, Layout.settingsRowsFit)
                       : max(min(rows, Layout.settingsRowsFit), Layout.pairingRows)), alignment: .top)
            .id(section.rawValue + (card == nil ? "" : " pairing"))
            .transition(NotchView.swap)
            motto
                .frame(maxWidth: .infinity)
                .frame(height: Layout.settingsMottoHeight, alignment: .bottom)
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .animation(NotchView.open, value: section)
    }

    private var sections: some View {
        let midnight = theme == .midnight
        return HStack(spacing: 4) {
            ForEach(SettingsSection.allCases, id: \.self) { each in
                let chosen = section == each
                Button {
                    withAnimation(NotchView.open) { section = each }
                } label: {
                    Text(each.rawValue)
                        .notchFont(size: 11, weight: .semibold)
                        .foregroundStyle(chosen ? (midnight ? Midnight.white : .black) : .white.opacity(midnight ? 0.55 : 0.6))
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background {
                            if chosen {
                                Capsule()
                                    .fill(midnight ? Midnight.silver.opacity(0.14) : .white.opacity(0.9))
                                    .overlay(Capsule().strokeBorder(Midnight.silver.opacity(midnight ? 0.7 : 0), lineWidth: 0.75))
                                    .matchedGeometryEffect(id: "chip", in: chips)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            Spacer(minLength: 0)
        }
    }

    /// Two to a row, the columns half the page each.
    private var grid: some View {
        let pairs = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(pairs.enumerated()), id: \.element.first!.id) { row, pair in
                HStack(spacing: 12) {
                    ForEach(pair) { item in
                        SettingRow(item: item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                }
                .frame(height: Layout.settingsRowHeight)
                .modifier(Cascade(row: row, on: theme == .midnight))
            }
        }
    }

    /// What Oyl stands for: in Oyl's own look, quietly; in Midnight Oyl's, engraved, in its flourish.
    private var motto: some View {
        HStack(spacing: 6) {
            Text(Motto.name.uppercased())
                .notchFont(size: 9.5, weight: .bold)
                .tracking(theme == .midnight ? 0 : 1.2)
            Text(theme == .midnight ? "·" : "—")
                .notchFont(size: 10)
            Text(Motto.words)
                .font(theme == .midnight ? Midnight.flourish(11.5) : .system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(.white.opacity(theme == .midnight ? 0.62 : 0.4))
    }
}

/// In Midnight Oyl, a section's rows drift in one after another, out of a blur, as it comes up.
private struct Cascade: ViewModifier {
    let row: Int
    let on: Bool
    @StateObject private var shown = LocalState(false)

    func body(content: Content) -> some View {
        let hidden = on && !shown.value
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: hidden ? 3 : 0)
            .offset(x: hidden ? -6 : 0)
            .onAppear {
                guard on else { return }
                withAnimation(.easeOut(duration: 0.4).delay(0.06 + Double(row) * 0.04)) { shown.value = true }
            }
    }
}

/// A setting: a switch (or a button), and for one you added, an × to take it off the list.
struct SettingRow: View {
    let item: SettingItem
    @Environment(\.notchTheme) private var theme

    var body: some View {
        if item.id == "midnight" {
            // Unlike the others, for it changes the whole look.
            HStack(spacing: 0) {
                ThemeSwitch(midnight: item.isOn, title: item.title, flip: item.action)
                    .help(item.hint)
                Spacer(minLength: 0)
            }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 5) {
            Button(action: item.action) {
                HStack(spacing: 5) {
                    Image(systemName: item.isButton ? "arrow.right.circle" : item.isOn ? "checkmark.circle.fill" : "circle")
                        .notchSymbol(size: 11, weight: .semibold)
                        .foregroundStyle(item.isOn ? Color.white : Color.white.opacity(item.isButton ? 0.6 : 0.4))
                    Text(item.title)
                        .notchFont(size: 11, weight: .medium)
                        .foregroundStyle(.white.opacity(item.isOn ? 0.9 : item.isButton ? 0.75 : 0.55))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help(item.hint)
            if let adjust = item.adjust {
                HStack(spacing: 0) {
                    stepper("chevron.left", help: "Earlier", action: adjust.down)
                    stepper("chevron.right", help: "Later", action: adjust.up)
                }
            }
            if let remove = item.remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .notchSymbol(size: 8, weight: .bold)
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .help("Take it off the list")
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.15), value: item.isOn)
    }

    private func stepper(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .notchSymbol(size: 8, weight: .bold)
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }
}

/// Opening at login, as a login item.
@MainActor
enum LoginItem {
    static func set(_ on: Bool) {
        Features.shared.set(.openAtLogin, on)
        apply()
    }

    /// Registered if it's to open at login (and again when the app has moved, since Login Items
    /// remembers where it was), unregistered if not.
    static func apply() {
        let path = Bundle.main.bundlePath
        let defaults = UserDefaults.standard
        guard Feature.openAtLogin.isOn else {
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            return
        }
        let moved = defaults.string(forKey: "loginItemPath") != path
        guard moved || SMAppService.mainApp.status != .enabled else { return }
        do {
            if moved { try? SMAppService.mainApp.unregister() }
            try SMAppService.mainApp.register()
            defaults.set(path, forKey: "loginItemPath")
        } catch {
            NSLog("Oyl couldn't add itself to Login Items: \(error)")
        }
    }
}

/// Pairing a phone with the remote: the code for its camera (or its six digits, to type at the
/// address), and how long it's good for; then which phone it paired. In Midnight Oyl the code's
/// on a pale ground with no edge to it, an engraved ring turning slowly round it.
struct PhonePairingCard: View {
    @ObservedObject var phone: PhoneRemote
    @Environment(\.notchTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .center, spacing: 18) {
                picture
                    .frame(width: 104, height: 104)
                words(at: context.date)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var midnight: Bool { theme == .midnight }

    @ViewBuilder private var picture: some View {
        if phone.pairing?.paired != nil {
            Image(systemName: "checkmark.circle")
                .notchSymbol(size: 44, weight: .light)
                .foregroundStyle(.white.opacity(0.9))
        } else if let code = phone.pairingPicture {
            ZStack {
                if midnight {
                    TurningRing()
                        .frame(width: 104, height: 104)
                }
                Image(decorative: code, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(midnight ? Midnight.ink : .black)
                    .frame(width: 76, height: 76)
                    .padding(8)
                    .background {
                        if midnight {
                            RoundedRectangle(cornerRadius: 14).fill(Midnight.white).blur(radius: 2.5)
                        } else {
                            RoundedRectangle(cornerRadius: 10).fill(.white)
                        }
                    }
            }
        }
    }

    @ViewBuilder private func words(at now: Date) -> some View {
        let soft = Color.white.opacity(midnight ? 0.62 : 0.55)
        VStack(alignment: .leading, spacing: 3) {
            if let pairing = phone.pairing {
                if let paired = pairing.paired {
                    Text("Paired with your \(paired)").notchFont(size: 13, weight: .semibold).foregroundStyle(.white)
                    Text("Add it to the Home Screen to keep it at hand").notchFont(size: 10.5).foregroundStyle(soft)
                } else if pairing.isSpent || now >= pairing.until {
                    Text(pairing.isSpent ? "Too many wrong codes" : "The code's run out").notchFont(size: 13, weight: .semibold)
                        .foregroundStyle(.white)
                    HStack(spacing: 14) {
                        Button("New code") { phone.pair() }
                        Button("Done") { phone.stopPairing() }
                    }
                    .buttonStyle(PressableStyle())
                    .notchFont(size: 11, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.8))
                } else {
                    Text("Pair your phone").notchFont(size: 13, weight: .semibold).foregroundStyle(.white)
                    Text(phone.overTailscale ? "Scan this with its camera, Tailscale on, or open" : "Scan this with its camera, on this Wi-Fi, or open")
                        .notchFont(size: 10.5).foregroundStyle(soft)
                    Text(phone.address).notchFont(size: 10.5, design: .monospaced).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
                    Text(pairing.code.prefix(3) + " " + pairing.code.suffix(3))
                        .notchFont(size: 22, weight: .semibold, digits: true)
                        .foregroundStyle(.white)
                    HStack(spacing: 10) {
                        Text("Good for " + Self.left(pairing.until.timeIntervalSince(now))).notchFont(size: 10.5, digits: true)
                            .foregroundStyle(soft)
                        Button("Cancel") { phone.stopPairing() }
                            .buttonStyle(PressableStyle())
                            .notchFont(size: 10.5, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
        }
    }

    private static func left(_ seconds: TimeInterval) -> String {
        let seconds = max(Int(seconds.rounded(.up)), 0)
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// An engraved ring, ticked like a planisphere's rim, turning once a minute.
private struct TurningRing: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60) / 60
            Circle()
                .stroke(Midnight.silver.opacity(0.32), style: StrokeStyle(lineWidth: 0.6, dash: [1, 3.2]))
                .padding(1)
                .rotationEffect(.degrees(turn * 360))
        }
    }
}
