import SwiftUI

/// Every Oyl out on the menu bar and what it's up to, then agents taking a break and timers that
/// have gone off, resting. Click one to go to it: an agent to where it's working, the others to
/// their page; a timer that's gone off runs again. Under them, the Oyls' settings, then the
/// calendar bar's (Gargoyle's alone). In Midnight Oyl each is its moyl.
struct OylsPage: View {
    @ObservedObject var state: NotchState
    @Environment(\.notchTheme) private var theme
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var timers: TimerStore
    @ObservedObject var awake: AwakeManager
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var bedtime: Bedtime

    var body: some View {
        VStack(spacing: 0) {
            list
            settings
            if agents.offersChats { chatsFooter }
        }
    }

    /// The Oyls' settings, then the calendar bar's, then the notch's look: only those that do
    /// something in this look.
    private var settings: some View {
        let midnight = state.theme == .midnight
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 16) {
                option(midnight ? "Moyls" : "Oyls on the bar", isOn: state.oylsVisible) { state.oylsVisible.toggle() }
                // Moyls are only ever up in the band's sky, so there's no bar behind them to dim;
                // and Midnight Oyl shows the camera always, so it has no camera page to turn on.
                if !midnight {
                    option("Dim the bar", isOn: state.dimsMenuBar) { state.dimsMenuBar.toggle() }
                }
                option(midnight ? "Bedtime Moyl" : "Bedtime Oyl", isOn: bedtime.isEnabled) { bedtime.isEnabled.toggle() }
                option("Countdowns", isOn: state.showsCountdowns) { state.showsCountdowns.toggle() }
                if !midnight {
                    option("Mirror", isOn: state.showsMirror) { state.showsMirror.toggle() }
                }
            }
            // The calendar bar is Gargoyle's alone.
            if !midnight {
                HStack(spacing: 16) {
                    option("Calendar bar", isOn: state.showsCalendar) { state.showsCalendar.toggle() }
                }
            }
            HStack(spacing: 16) {
                option("Midnight Oyl", isOn: midnight) { state.theme = midnight ? .standard : .midnight }
                // Staying open on display (as clicking its moon does): Midnight Oyl's alone.
                if midnight {
                    option("Stay open", isOn: state.isPinned) { state.isPinned.toggle() }
                }
                option("Oyl's Dock", isOn: state.showsDock) { state.showsDock.toggle() }
                Spacer(minLength: 0)
                // Quits, and stays off (not opening at login) till it's opened again.
                Button { Quitting.turnOff(awake) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "power")
                            .notchSymbol(size: 11, weight: .semibold)
                        Text("Turn off Oyl")
                            .notchFont(size: 11, weight: .medium)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .help("Quit Oyl and keep it from opening at login, till you open it again. To switch it off for a while instead, tap control three times")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .frame(height: Layout.oylSettingsHeight(rows: state.oylSettingsRows), alignment: .top)
    }

    private func option(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .notchSymbol(size: 11, weight: .semibold)
                    .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.4))
                Text(title)
                    .notchFont(size: 11, weight: .medium)
                    .foregroundStyle(.white.opacity(isOn ? 0.9 : 0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private var list: some View {
        let rows = state.oylRows
        return Group {
            if state.oylRowCount <= Layout.maxVisibleOyls {
                self.rows(rows)
            } else {
                let visible = CGFloat(Layout.maxVisibleOyls)
                ScrollView(.vertical, showsIndicators: false) { self.rows(rows) }
                    .frame(height: visible * Layout.oylRowHeight + (visible - 1) * 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .animation(NotchView.open, value: rows.map(\.id) + timers.history.map(\.id.uuidString))
    }

    /// Chats in the Claude app need Accessibility; this asks for it.
    private var chatsFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.fill")
                .notchSymbol(size: 10, weight: .semibold)
                .foregroundStyle(theme.tint(Oyl.hatOrange))
            Text("Show chats from the Claude app too")
                .notchFont(size: 11)
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 8)
            Button(action: agents.allowChats) {
                Text("Allow")
                    .notchFont(size: 11, weight: .semibold)
                    .padding(.horizontal, 10)
                    .frame(height: 20)
                    .notchPill(Oyl.hatOrange, text: .black)
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 24)
        .frame(height: Layout.chatsFooterHeight, alignment: .top)
    }

    private func rows(_ rows: [Walker.Job]) -> some View {
        VStack(spacing: 6) {
            ForEach(rows, id: \.id) { job in
                Button { open(job) } label: { row(for: job) }
                    .buttonStyle(AgentRowStyle())
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            ForEach(timers.history) { expired in
                Button { timers.start(duration: expired.duration, label: expired.label) } label: { expiredRow(expired) }
                    .buttonStyle(AgentRowStyle())
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// A timer that's gone off: its Oyl, done and resting, gone all the way to blue as a
    /// timer's is by the end. Clicking runs it again.
    private func expiredRow(_ expired: ExpiredTimer) -> some View {
        // Kept a day, so if not today, yesterday.
        let day = Calendar.current.isDateInToday(expired.ended) ? "" : "yesterday "
        return OylRow(title: expired.title, tag: ReminderParser.spell(expired.duration).text,
                      subtitle: "Went off \(day)at \(expired.ended.formatted(date: .omitted, time: .shortened)). Click to run it again") {
            Oyl(activity: .done, skin: Oyl.timer(1))
        }
    }

    private func open(_ job: Walker.Job) {
        let page: NotchPage
        switch job {
        case .agent(let session):
            agents.reveal(session)
            return
        case .selfie(let selfie):
            NSWorkspace.shared.open(selfie.url)
            return
        case .hangout, .battery, .bedtime:
            return
        case .music: page = .music
        case .timer: page = .timers
        case .awake: page = .awake
        }
        withAnimation(NotchView.open) { state.page = page }
    }

    @ViewBuilder private func row(for job: Walker.Job) -> some View {
        switch job {
        case .agent(let session):
            AgentRow(session: session)
        case .music(let cover, let listening):
            // An audiobook's often a show's episode, with no artist: by the show, then.
            let by = nowPlaying.track.map { $0.artist.isEmpty && listening == .reading ? $0.album : $0.artist } ?? ""
            OylRow(title: nowPlaying.track?.title ?? "Music", tag: listening == .reading ? "Reading" : listening == .singing ? "Singing" : "DJ",
                   subtitle: by) {
                Oyl(duty: .music(cover: cover, listening: listening))
            }
        case .timer(let timer) where timer.isEndless:
            OylRow(title: timer.title, subtitle: "Out until it's done") { Oyl(duty: .timer(timer)) }
        case .timer(let timer):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                OylRow(title: timer.title, subtitle: (timer.isRunning ? "" : "Paused · ")
                       + "\(ReminderTimer.format(timer.remaining(at: context.date))) left") {
                    Oyl(duty: .timer(timer))
                }
            }
        case .awake:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                OylRow(title: "Amphetamine", subtitle: awakeStatus(at: context.date)) { Oyl(duty: .awake(awake.mode ?? .indefinitely)) }
            }
        case .hangout:
            OylRow(title: "Oyl", subtitle: "Hanging out, nothing else going on") { Oyl(hangingOut: true) }
        case .battery(let status):
            switch status {
            case .tired(let percent):
                OylRow(title: "Battery", subtitle: "Running low, \(percent)%. Plug in!") { Oyl(duty: .battery(status)) }
            case .recharging(let percent):
                OylRow(title: "Battery", subtitle: "Recharging, \(percent)%") { Oyl(duty: .battery(status)) }
            }
        case .bedtime(let stage):
            OylRow(title: "Bedtime", subtitle: stage == .candle ? "Up past midnight, with a candle"
                   : stage == .bed ? "In bed since 1 am" : "Telling you to go to bed") { Oyl(duty: .bedtime(stage)) }
        case .selfie(let selfie):
            OylRow(title: "Selfie", subtitle: "Just taken. Click to open it") { Oyl(duty: .selfie(selfie.image)) }
        }
    }

    /// A time today, or a day and time later.
    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.wide).hour().minute())
    }

    private func awakeStatus(at date: Date) -> String {
        switch awake.mode {
        case .until(let end)?: return "Keeping your Mac awake · \(ReminderTimer.format(end.timeIntervalSince(date))) left"
        case .whileRunning(_, let name)?: return "Keeping your Mac awake while \(name) is open"
        case .indefinitely?, nil: return "Keeping your Mac awake until you stop it"
        }
    }
}

struct AgentRow: View {
    let session: AgentSession
    @Environment(\.notchTheme) private var theme

    var body: some View {
        OylRow(title: session.project, tag: session.host, subtitle: session.summary,
               subtitleColor: session.activity == .waiting ? theme.tint(Oyl.hatOrange, urgent: true) : .white.opacity(0.55)) {
            Oyl(activity: session.activity, hat: session.cap != nil, hatColor: session.cap ?? Oyl.hatOrange, skin: Oyl.pastel(session.skin))
        } trailing: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.elapsed(since: session.since, now: context.date))
                    .notchFont(size: 11, weight: .medium, digits: true)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    static func elapsed(since date: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

/// A row on the Oyls page: the Oyl at its job, what it's doing, and anything else to the right.
struct OylRow<Icon: View, Trailing: View>: View {
    let title: String
    let tag: String?
    let subtitle: String
    let subtitleColor: Color
    let icon: Icon
    let trailing: Trailing

    init(title: String, tag: String? = nil, subtitle: String, subtitleColor: Color = .white.opacity(0.55),
         @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.tag = tag
        self.subtitle = subtitle
        self.subtitleColor = subtitleColor
        self.icon = icon()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 60, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .notchFont(size: 13, weight: .semibold)
                        .foregroundStyle(.white)
                    if let tag {
                        Text(tag)
                            .notchFont(size: 10, weight: .medium)
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                }
                Text(subtitle)
                    .notchFont(size: 11)
                    .foregroundStyle(subtitleColor)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: Layout.oylRowHeight)
    }
}

extension OylRow where Trailing == EmptyView {
    init(title: String, tag: String? = nil, subtitle: String, @ViewBuilder icon: () -> Icon) {
        self.init(title: title, tag: tag, subtitle: subtitle, icon: icon) { EmptyView() }
    }
}

/// Rows light up under a press, so they read as clickable without a button's chrome.
struct AgentRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(configuration.isPressed ? 0.12 : 0)))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Shown in place of the pages while an agent waits for your OK: Allow or Deny here, or a thumbs
/// up to the camera. Clicking the agent's side sends you to it to answer there instead.
struct ApprovalPage: View {
    let approval: Approval
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var gestures: GestureWatcher

    /// The asking agent's own pastel.
    private var skin: Color {
        agents.sessions.first { $0.id == approval.session }.map { Oyl.pastel($0.skin) } ?? Oyl.white
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { agents.answerInApp(approval) } label: {
                HStack(spacing: 12) {
                    Oyl(activity: .waiting, hat: true, skin: skin)
                        .frame(width: 76, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(approval.project)
                                .notchFont(size: 13, weight: .semibold)
                                .foregroundStyle(.white)
                            if let host = approval.host {
                                Text(host)
                                    .notchFont(size: 10, weight: .medium)
                                    .foregroundStyle(.white.opacity(0.5))
                                    .padding(.horizontal, 5)
                                    .frame(height: 15)
                                    .background(Capsule().fill(.white.opacity(0.1)))
                            }
                        }
                        Text(approval.action)
                            .notchFont(size: 12)
                            .foregroundStyle(.white.opacity(0.8))
                        if let detail = approval.detail {
                            Text(detail)
                                .notchFont(size: 10.5, design: .monospaced)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Answer in \(approval.host ?? "the app")")
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 8) {
                    pill("Deny", foreground: .white, background: .white.opacity(0.14), bright: false) {
                        agents.answer(approval, allow: false)
                    }
                    pill("Allow", foreground: .black, background: Oyl.hatOrange) {
                        agents.answer(approval, allow: true)
                    }
                }
                if gestures.isWatching {
                    Label("or a thumbs up", systemImage: "hand.thumbsup.fill")
                        .notchFont(size: 10, weight: .medium)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private func pill(_ title: String, foreground: Color, background: Color, bright: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .notchFont(size: 13, weight: .semibold)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .notchPill(background, text: foreground, bright: bright, urgent: true)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}
