import SwiftUI

struct TimersPage: View {
    @ObservedObject var timers: TimerStore
    @ObservedObject var state: NotchState
    @StateObject private var draft = LocalState("")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                ReminderField(text: $draft.value, placeholder: "Remind me to…   e.g. “10m stretch” or “inf email prof”",
                              onSubmit: submit, onCancel: cancel)
                if !draft.value.isEmpty {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(.white.opacity(state.isEditing ? 0.14 : 0.08)))

            if timers.timers.isEmpty {
                Text("Type a time and a reminder, like “25m laundry” (or “inf” to keep it till done), then Return.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(height: 20)
            } else if timers.timers.count <= Layout.maxVisibleTimers {
                rows
            } else {
                let visible = CGFloat(Layout.maxVisibleTimers)
                ScrollView(.vertical, showsIndicators: false) { rows }
                    .frame(height: visible * Layout.timerRowHeight + (visible - 1) * 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .animation(NotchView.open, value: timers.timers.map(\.id))
    }

    private var rows: some View {
        VStack(spacing: 4) {
            ForEach(timers.timers) { timer in
                TimerRow(timer: timer, timers: timers)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func submit() {
        let parsed = ReminderParser.parse(draft.value)
        if parsed.endless {
            timers.startEndless(label: parsed.label)
        } else if let duration = parsed.duration {
            timers.start(duration: duration, label: parsed.label)
        } else {
            NSSound.beep()
            return
        }
        finish()
    }

    private func cancel() {
        finish()
    }

    private func finish() {
        draft.value = ""
        state.resignKeyboard()
    }
}

struct TimerRow: View {
    let timer: ReminderTimer
    @ObservedObject var timers: TimerStore

    var body: some View {
        if timer.isEndless {
            // No time on it: there until it's ticked off.
            HStack(spacing: 10) {
                Image(systemName: "infinity")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Oyl.noteYellow)
                    .frame(width: 20, height: 20)
                Text(timer.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                RoundButton(symbol: "checkmark", tint: Oyl.noteYellow) {
                    timers.resolve(timer.id)
                }
                RoundButton(symbol: "xmark", tint: .white) {
                    timers.cancel(timer.id)
                }
            }
            .frame(height: Layout.timerRowHeight)
        } else {
            countdown
        }
    }

    private var countdown: some View {
        Countdown(timer: timer) { remaining, left in
            HStack(spacing: 10) {
                TimerRing(fraction: left, lineWidth: 2.5, color: timer.tint(fractionLeft: left))
                    .frame(width: 20, height: 20)
                Text(timer.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(ReminderTimer.format(remaining))
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(timer.tint(fractionLeft: left))
                RoundButton(symbol: timer.isRunning ? "pause.fill" : "play.fill", tint: timer.tint(fractionLeft: left)) {
                    timers.togglePause(timer.id)
                }
                RoundButton(symbol: "xmark", tint: .white) {
                    timers.cancel(timer.id)
                }
            }
        }
        .frame(height: Layout.timerRowHeight)
    }
}

/// Shown in place of the pages when a timer finishes, until it's stopped or snoozed.
struct AlertPage: View {
    let timer: ReminderTimer
    @ObservedObject var timers: TimerStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "alarm.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.orange)
                .modifier(Ringing())
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.orange.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Time's up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(timer.label.isEmpty ? "\(Self.describe(timer.duration)) timer" : timer.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            pill("+1 min", foreground: .white, background: .white.opacity(0.14)) { timers.snoozeRinging() }
            pill("Stop", foreground: .black, background: .orange) { timers.dismissRinging() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func pill(_ title: String, foreground: Color, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private static func describe(_ duration: TimeInterval) -> String {
        let minutes = Int((duration / 60).rounded())
        if duration < 60 { return "\(Int(duration))-second" }
        if minutes < 60 { return "\(minutes)-minute" }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 24 { return rest == 0 ? "\(hours)-hour" : "\(hours) h \(rest) min" }
        let days = hours / 24, hoursOver = hours % 24
        if hoursOver == 0 && rest == 0 { return "\(days)-day" }
        return "\(days) d" + (hoursOver > 0 ? " \(hoursOver) h" : "") + (rest > 0 ? " \(rest) min" : "")
    }
}

extension ReminderTimer {
    /// White when it starts, warming to orange as its time runs out; dim while paused.
    func tint(fractionLeft: Double) -> Color {
        guard isRunning else { return .white.opacity(0.5) }
        let gone = min(max(1 - fractionLeft, 0), 1)
        return Color(red: 1, green: 1 - 0.416 * gone, blue: 1 - gone)
    }
}

/// The alarm bounces while it rings (pulses on macOS 14, which can't repeat a bounce).
private struct Ringing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.symbolEffect(.bounce, options: .repeating)
        } else {
            content.symbolEffect(.pulse)
        }
    }
}

/// Re-renders once a second, on the countdown's own second boundaries, so the digits flip
/// exactly when they should and nothing redraws in between.
struct Countdown<Content: View>: View {
    let timer: ReminderTimer
    @ViewBuilder let content: (_ remaining: TimeInterval, _ fractionLeft: Double) -> Content

    var body: some View {
        if let end = timer.endDate {
            let aligned = end.addingTimeInterval(-max(end.timeIntervalSinceNow, 0).rounded(.up))
            TimelineView(.periodic(from: aligned, by: 1)) { context in
                content(timer.remaining(at: context.date), timer.fractionLeft(at: context.date))
            }
        } else {
            content(timer.remaining(at: Date()), timer.fractionLeft(at: Date()))
        }
    }
}

/// Depleting ring, like the iOS timer live activity.
struct TimerRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 2.5
    var color: Color = .orange

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

struct RoundButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(tint.opacity(0.2)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// An AppKit text field, because it's the one view allowed to make the notch panel key
/// (`needsPanelToBecomeKey`). Typing there doesn't activate Oyl or move the menu bar.
struct ReminderField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> KeyField {
        let field = KeyField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.38),
            .font: NSFont.systemFont(ofSize: 13),
        ])
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: KeyField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ReminderField

        init(_ parent: ReminderField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

final class KeyField: NSTextField {
    override var needsPanelToBecomeKey: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        (currentEditor() as? NSTextView)?.insertionPointColor = .white
        return became
    }
}
