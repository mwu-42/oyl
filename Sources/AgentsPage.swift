import SwiftUI

/// Every Oyl out on the menu bar and what it's up to, then agents taking a break, and the
/// calendar's Oyl. Click one to go to it: an agent to where it's working, the others to their
/// page. Under them, whether the Oyls are out at all, and the bedtime Oyl.
struct OylsPage: View {
    @ObservedObject var state: NotchState
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var timers: TimerStore
    @ObservedObject var awake: AwakeManager
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var calendar: DayCalendar
    @ObservedObject var bedtime: Bedtime

    var body: some View {
        VStack(spacing: 0) {
            list
            settings
            if agents.offersChats { chatsFooter }
        }
    }

    private var settings: some View {
        HStack(spacing: 16) {
            option("Oyls on the menu bar", isOn: state.oylsVisible) { state.oylsVisible.toggle() }
            option("Dim the bar under them", isOn: state.dimsMenuBar) { state.dimsMenuBar.toggle() }
            option("Bedtime Oyl", isOn: bedtime.isEnabled) { bedtime.isEnabled.toggle() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(height: Layout.oylSettingsHeight, alignment: .top)
    }

    private func option(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.4))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(isOn ? 0.9 : 0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private var list: some View {
        let rows = state.oylRows
        return Group {
            // The calendar's row comes after these, so it counts too.
            if rows.count + 1 <= Layout.maxVisibleOyls {
                self.rows(rows)
            } else {
                let visible = CGFloat(Layout.maxVisibleOyls)
                ScrollView(.vertical, showsIndicators: false) { self.rows(rows) }
                    .frame(height: visible * Layout.oylRowHeight + (visible - 1) * 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .animation(NotchView.open, value: rows.map(\.id))
    }

    /// Chats in the Claude app need Accessibility; this asks for it.
    private var chatsFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Oyl.hatOrange)
            Text("Show chats from the Claude app too")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 8)
            Button(action: agents.allowChats) {
                Text("Allow")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .frame(height: 20)
                    .background(Capsule().fill(Oyl.hatOrange))
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
            Button(action: calendar.openSomewhere) { calendarRow }
                .buttonStyle(AgentRowStyle())
        }
    }

    /// The calendar bar's Oyl: what's on now, and what's next.
    private var calendarRow: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let current = calendar.current(at: context.date), next = calendar.next(after: context.date)
            let peek = calendar.peekTarget(at: context.date)
            OylRow(title: current?.title ?? "Free", tag: "Calendar",
                   subtitle: calendar.note ?? next.map { "Next: \($0.title), \(Self.when($0.start))" } ?? "Nothing coming up") {
                if let activity = current?.activity {
                    Oyl(attending: activity)
                } else if peek != nil {
                    Oyl(peeking: true)
                } else {
                    Oyl(hangingOut: true)
                }
            }
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
        case .music, .singer: page = .music
        case .timer: page = .timers
        case .awake: page = .awake
        }
        withAnimation(NotchView.open) { state.page = page }
    }

    @ViewBuilder private func row(for job: Walker.Job) -> some View {
        switch job {
        case .agent(let session):
            AgentRow(session: session)
        case .music:
            OylRow(title: nowPlaying.track?.title ?? "Music", tag: "DJ", subtitle: nowPlaying.track?.artist ?? "") {
                Oyl(duty: .music)
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
        case .singer:
            OylRow(title: "Singing along", tag: "Lyrics", subtitle: nowPlaying.track?.title ?? "") { Oyl(duty: .singer) }
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

    var body: some View {
        OylRow(title: session.project, tag: session.host, subtitle: session.summary,
               subtitleColor: session.activity == .waiting ? Oyl.hatOrange : .white.opacity(0.55)) {
            Oyl(activity: session.activity, hat: true, skin: Oyl.pastel(session.skin))
        } trailing: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.elapsed(since: session.since, now: context.date))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    if let tag {
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
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
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                            if let host = approval.host {
                                Text(host)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .padding(.horizontal, 5)
                                    .frame(height: 15)
                                    .background(Capsule().fill(.white.opacity(0.1)))
                            }
                        }
                        Text(approval.action)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                        if let detail = approval.detail {
                            Text(detail)
                                .font(.system(size: 10.5, design: .monospaced))
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
                    pill("Deny", foreground: .white, background: .white.opacity(0.14)) {
                        agents.answer(approval, allow: false)
                    }
                    pill("Allow", foreground: .black, background: Oyl.hatOrange) {
                        agents.answer(approval, allow: true)
                    }
                }
                if gestures.isWatching {
                    Label("or a thumbs up", systemImage: "hand.thumbsup.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private func pill(_ title: String, foreground: Color, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}
