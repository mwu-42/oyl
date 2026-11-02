import SwiftUI

struct AwakePage: View {
    @ObservedObject var awake: AwakeManager
    @ObservedObject var state: NotchState
    @StateObject private var draft = LocalState("")
    @Environment(\.notchTheme) private var theme

    // Amphetamine's pill, in green with a hint of blue.
    static let symbol = "pill.fill"
    static let tint = Color(red: 0.2, green: 0.88, blue: 0.68)

    /// Its green as this look shows it (pale celadon, in Midnight Oyl).
    private var tint: Color { theme.tint(Self.tint) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol)
                    .notchSymbol(size: 15, weight: .semibold)
                    .foregroundStyle(awake.isActive ? tint : Color.white.opacity(0.4))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill((awake.isActive ? tint : Color.white).opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(awake.isActive ? "Keeping your Mac awake" : "Sleeping as usual")
                        .notchFont(size: 13, weight: .semibold)
                        .foregroundStyle(.white)
                    status
                        .notchFont(size: 11)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if awake.isActive {
                    Button(action: awake.stop) {
                        Text("Stop")
                            .notchFont(size: 12, weight: .semibold)
                            .padding(.horizontal, 14)
                            .frame(height: 26)
                            .notchPill(Self.tint, text: .black)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }

            HStack(spacing: 6) {
                chip(symbol: "clock.fill", title: "2 hours", selected: awake.length == AwakeManager.usual, action: awake.startUsual)
                chip(symbol: "infinity", title: "Until I stop", selected: awake.mode == .indefinitely) {
                    awake.start(.indefinitely)
                }
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .notchSymbol(size: 10, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.6))
                    ReminderField(text: $draft.value, placeholder: "For… e.g. 2h", onSubmit: submit, onCancel: finish)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(.white.opacity(state.isEditing ? 0.14 : 0.08)))
                chip(symbol: "app.badge", title: appTitle, selected: isWatchingApp, action: chooseApp)
            }

            HStack(spacing: 16) {
                option("Screen may sleep", isOn: awake.displayMaySleep) { awake.displayMaySleep.toggle() }
                option("Stop at \(AwakeManager.batteryFloor)% battery", isOn: awake.stopOnLowBattery) {
                    awake.stopOnLowBattery.toggle()
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .animation(NotchView.open, value: awake.isActive)
    }

    @ViewBuilder private var status: some View {
        let lid = awake.lidHelperInstalled ? " · lid can be closed" : ""
        switch awake.mode {
        case nil:
            Text("Choose how long to stay awake")
        case .indefinitely:
            Text("Until you stop it" + lid)
        case .until(let end):
            let aligned = end.addingTimeInterval(-max(end.timeIntervalSinceNow, 0).rounded(.up))
            TimelineView(.periodic(from: aligned, by: 1)) { context in
                // The day too, once it's not today.
                let until = Calendar.current.isDateInToday(end)
                    ? end.formatted(date: .omitted, time: .shortened)
                    : end.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                Text("\(ReminderTimer.format(end.timeIntervalSince(context.date))) left · until " + until + lid)
            }
        case .whileRunning(_, let name):
            Text("While \(name) is open" + lid)
        }
    }

    private var isWatchingApp: Bool {
        if case .whileRunning = awake.mode { return true }
        return false
    }

    private var appTitle: String {
        if case .whileRunning(_, let name) = awake.mode { return name }
        return "While an app is open"
    }

    private func chip(symbol: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .notchSymbol(size: 10, weight: .semibold)
                Text(title)
                    .notchFont(size: 12, weight: .medium)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .notchPill(selected ? Self.tint : Color.white.opacity(0.08), text: selected ? Color.black : Color.white.opacity(0.8),
                       bright: selected)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .fixedSize()
    }

    private func option(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .notchSymbol(size: 11, weight: .semibold)
                    .foregroundStyle(isOn ? tint : Color.white.opacity(0.4))
                Text(title)
                    .notchFont(size: 11, weight: .medium)
                    .foregroundStyle(.white.opacity(isOn ? 0.9 : 0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func submit() {
        let parsed = ReminderParser.parse(draft.value)
        if parsed.endless {
            awake.start(.indefinitely)
            finish()
            return
        }
        guard let duration = parsed.duration else {
            NSSound.beep()
            return
        }
        awake.start(.until(Date().addingTimeInterval(min(duration, AwakeManager.longest))))
        finish()
    }

    private func finish() {
        draft.value = ""
        state.resignKeyboard()
    }

    /// A menu of open apps; staying awake ends when the chosen one quits.
    private func chooseApp() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0 != .current }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        let menu = NSMenu()
        for app in apps {
            guard let bundleID = app.bundleIdentifier else { continue }
            let name = app.localizedName ?? bundleID
            let item = ClosureMenuItem(title: name) { awake.start(.whileRunning(bundleID: bundleID, name: name)) }
            let icon = app.icon?.copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        // Keep the notch open while the menu is up; popUp returns once it closes.
        state.isHeld = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        state.isHeld = false
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}
