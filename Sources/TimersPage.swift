import SwiftUI

struct TimersPage: View {
    @ObservedObject var timers: TimerStore
    @ObservedObject var state: NotchState
    @StateObject private var draft = LocalState("")
    /// The timer being changed, if one is.
    @StateObject private var editing = LocalState<TimerEdit?>(nil)
    /// The timer being given more time, and how much's been typed so far.
    @StateObject private var adding = LocalState<(id: UUID, text: String)?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bell.fill")
                    .notchSymbol(size: 11, weight: .semibold)
                    .foregroundStyle(.white)
                ReminderField(text: $draft.value, placeholder: "Remind me to…   e.g. “10m stretch” or “inf email prof”",
                              onSubmit: submit, onCancel: cancel)
                if !draft.value.isEmpty {
                    Image(systemName: "return")
                        .notchSymbol(size: 10, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(.white.opacity(state.isEditing && editing.value == nil ? 0.14 : 0.08)))

            if timers.timers.isEmpty {
                Text("Type a time and a reminder, like “25m laundry” (or “inf” to keep it till done), then Return.")
                    .notchFont(size: 11)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(height: 20)
            } else if state.timerRowsHeight <= state.timerListHeight + 0.5 {
                rows
                    .padding(.horizontal, -6)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) { rows }
                        .frame(height: state.timerListHeight)
                        .padding(.horizontal, -6)
                        // To a timer picked out by clicking its Oyl, if it's out of sight.
                        .onAppear { DispatchQueue.main.async { scroll(proxy) } }
                        .onChange(of: state.pickedTimer) { _, _ in scroll(proxy) }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .overlay(alignment: .top) {
            if let add = adding.value, let timer = timers.timers.first(where: { $0.id == add.id }) {
                TimerAddCard(timer: timer, text: Binding { adding.value?.text ?? "" } set: { adding.value?.text = $0 },
                             add: { timers.extend(timer.id, by: $0); stopAdding() }, cancel: stopAdding)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .animation(NotchView.open, value: timers.timers.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: adding.value?.id)
        // The keyboard's gone back to another app: a timer being changed stays as it was.
        .onChange(of: state.isEditing) { _, typing in
            if !typing {
                editing.value = nil
                adding.value = nil
            }
        }
        // Its timer's gone off, or been called off.
        .onChange(of: timers.timers.map(\.id)) { _, ids in
            if let add = adding.value, !ids.contains(add.id) { adding.value = nil }
        }
    }

    private func stopAdding() {
        adding.value = nil
        state.resignKeyboard()
    }

    /// Soonest done at the top. Sorted again each second, since a running timer can come to have
    /// less left than a paused one.
    private var rows: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let sorted = timers.soonestFirst(at: context.date)
            VStack(spacing: 4) {
                ForEach(sorted) { timer in
                    TimerRow(timer: timer, timers: timers, editing: $editing.value, add: {
                        editing.value = nil
                        adding.value = (timer.id, "")
                    }) { state.resignKeyboard() }
                        // Lit up for a moment when its Oyl's clicked on the menu bar, the light a
                        // little past its edges (the list's widened to match, so nothing moves).
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.white.opacity(state.pickedTimer == timer.id ? 0.14 : 0)))
                        .animation(.easeOut(duration: 0.35), value: state.pickedTimer)
                        .id(timer.id)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(NotchView.open, value: sorted.map(\.id))
        }
        // As tall as they stand, a long name wrapped, for the page to fit them.
        .background(GeometryReader { Color.clear.preference(key: RowsHeight.self, value: $0.size.height) })
        .onPreferenceChange(RowsHeight.self) { height in
            let count = timers.timers.count
            if let last = state.timerRowsMeasure, last.count == count, abs(last.height - height) < 0.5 { return }
            state.timerRowsMeasure = (count, height)
        }
    }

    private struct RowsHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let picked = state.pickedTimer else { return }
        withAnimation(NotchView.open) { proxy.scrollTo(picked, anchor: .center) }
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

/// A timer being changed: which, what's typed for it so far, and the time it was put up with
/// (leaving that be keeps the time it really has left).
struct TimerEdit {
    let id: UUID
    var text: String
    let shown: TimeInterval?
    /// The time, at the start, picked out to type over.
    let time: NSRange
}

/// A timer or reminder. Click its name or its time to change either: it turns into a field with
/// its time left and its name, typed as you would to set it.
struct TimerRow: View {
    let timer: ReminderTimer
    @ObservedObject var timers: TimerStore
    @Environment(\.notchTheme) private var theme
    /// The timer being changed, if any: one at a time.
    @Binding var editing: TimerEdit?
    /// Asks how much more time to give it.
    let add: () -> Void
    /// Gives the keyboard back.
    let finish: () -> Void

    var body: some View {
        if timer.isEndless {
            // No time on it: there until it's ticked off.
            HStack(spacing: 10) {
                Image(systemName: "infinity")
                    .notchSymbol(size: 12, weight: .bold)
                    .foregroundStyle(theme.tint(Oyl.noteYellow))
                    .frame(width: 20, height: 20)
                editable {
                    name
                    Spacer(minLength: 8)
                }
                hold
                RoundButton(symbol: "checkmark", tint: theme.tint(Oyl.noteYellow)) {
                    timers.resolve(timer.id)
                }
                RoundButton(symbol: "xmark", tint: .white) {
                    timers.cancel(timer.id)
                }
            }
            .frame(minHeight: Layout.timerRowHeight)
        } else {
            countdown
        }
    }

    /// Holds it on the closed notch (letting go of any other), or lets it go.
    private var hold: some View {
        let held = timers.focused == timer.id
        return RoundButton(symbol: held ? "pin.fill" : "pin", tint: held ? .white : .white.opacity(0.55)) {
            timers.focus(timer.id)
        }
        .help(held ? "Let go of the notch" : "Hold on the notch")
    }

    /// All of it, however long, wrapping onto as many lines as it takes.
    private var name: some View {
        Text(timer.title)
            .notchFont(size: 13, weight: .medium)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }

    private var countdown: some View {
        Countdown(timer: timer) { remaining, left in
            let tint = timer.tint(fractionLeft: left, theme: theme)
            HStack(spacing: 10) {
                TimerRing(fraction: left, lineWidth: theme == .midnight ? 1.25 : 2.5, color: tint)
                    .frame(width: 20, height: 20)
                editable {
                    name
                    Spacer(minLength: 8)
                    Text(ReminderTimer.format(remaining))
                        .notchFont(size: 16, weight: .semibold, design: .rounded, digits: true)
                        .foregroundStyle(tint)
                }
                hold
                RoundButton(symbol: "plus", tint: tint, action: add)
                    .help("More time")
                RoundButton(symbol: timer.isRunning ? "pause.fill" : "play.fill", tint: tint) {
                    timers.togglePause(timer.id)
                }
                RoundButton(symbol: "xmark", tint: .white) {
                    timers.cancel(timer.id)
                }
            }
        }
        .frame(minHeight: Layout.timerRowHeight)
    }

    /// Its name (and time), clicked to change it; or, while it's being changed, the field.
    @ViewBuilder
    private func editable<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        if let edit = editing, edit.id == timer.id {
            HStack(spacing: 8) {
                ReminderField(text: Binding { editing?.text ?? edit.text } set: { editing?.text = $0 },
                              placeholder: "A time and a name, e.g. “15m stretch”", onSubmit: save, onCancel: stopEditing,
                              selecting: edit.time, onEnd: {
                                  // Clicked away, into the other field.
                                  if editing?.id == timer.id { editing = nil }
                              })
                Image(systemName: "return")
                    .notchSymbol(size: 10, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(.white.opacity(0.14)))
        } else {
            Button(action: startEditing) {
                HStack(spacing: 10) { label() }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Up for changing as it'd be typed: its time left (or "inf") then its name, with the time
    /// picked out.
    private func startEditing() {
        let spelled = timer.isEndless ? nil : ReminderParser.spell(timer.remaining(at: Date()))
        let time = spelled?.text ?? "inf"
        editing = TimerEdit(id: timer.id, text: timer.label.isEmpty ? time : "\(time) \(timer.label)", shown: spelled?.duration,
                            time: NSRange(location: 0, length: (time as NSString).length))
    }

    private func save() {
        if let edit = editing { timers.edit(timer.id, to: edit.text, shown: edit.shown) }
        stopEditing()
    }

    private func stopEditing() {
        editing = nil
        finish()
    }
}

/// Shown in place of the pages when a timer finishes, until it's stopped or snoozed.
struct AlertPage: View {
    let timer: ReminderTimer
    @ObservedObject var timers: TimerStore
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let alarm = theme.tint(Color.orange, urgent: true)
        HStack(spacing: 12) {
            Image(systemName: "alarm.fill")
                .notchSymbol(size: 20, weight: .semibold)
                .foregroundStyle(alarm)
                .modifier(Ringing())
                .frame(width: 34, height: 34)
                .background(Circle().fill(alarm.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Time's up")
                    .notchFont(size: 13, weight: .semibold)
                    .foregroundStyle(.white)
                Text(timer.label.isEmpty ? "\(Self.describe(timer.duration)) timer" : timer.label)
                    .notchFont(size: 10.5)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            pill("+1 min", foreground: .white, background: .white.opacity(0.14), bright: false) { timers.snoozeRinging(minutes: 1) }
            pill("+5 min", foreground: .white, background: .white.opacity(0.14), bright: false) { timers.snoozeRinging(minutes: 5) }
            pill("Stop", foreground: .black, background: .orange) { timers.dismissRinging() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func pill(_ title: String, foreground: Color, background: Color, bright: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .notchFont(size: 11.5, weight: .semibold)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .notchPill(background, text: foreground, bright: bright, urgent: true)
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
    /// White when it starts, deepening to blue as its time runs out (to pale ice, in Midnight
    /// Oyl); dim while paused.
    func tint(fractionLeft: Double, theme: NotchTheme = .standard) -> Color {
        guard isRunning else { return .white.opacity(0.5) }
        let gone = min(max(1 - fractionLeft, 0), 1)
        return theme.tint(Color(red: 1 - 0.72 * gone, green: 1 - 0.44 * gone, blue: 1))
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
    @Environment(\.notchTheme) private var theme

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(theme == .midnight ? 0.2 : 0.25), lineWidth: lineWidth)
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
                .notchSymbol(size: 10, weight: .bold)
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
    /// Takes the keyboard as soon as it's up, with this much of the text picked out.
    var selecting: NSRange?
    /// The keyboard's gone to another field, or back to another app.
    var onEnd: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> KeyField {
        let field = KeyField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        setFont(of: field, for: context.environment.notchTheme)
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        if let selecting {
            // Once it's in the window, with its text.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let window = field.window else { return }
                    window.makeKey()
                    guard window.makeFirstResponder(field) else { return }
                    let all = NSRange(location: 0, length: (field.stringValue as NSString).length)
                    field.currentEditor()?.selectedRange = NSIntersectionRange(selecting, all)
                }
            }
        }
        return field
    }

    func updateNSView(_ field: KeyField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        setFont(of: field, for: context.environment.notchTheme)
    }

    /// The system's in Oyl's own look; Midnight Oyl's reading face (Georgia) in its.
    private func setFont(of field: KeyField, for theme: NotchTheme) {
        let font = theme == .midnight ? NSFont(name: "Georgia", size: 13 * 1.06) ?? .systemFont(ofSize: 13) : .systemFont(ofSize: 13)
        guard field.font != font else { return }
        field.font = font
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.38),
            .font: font,
        ])
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ReminderField

        init(_ parent: ReminderField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Pasted lines run on, one after another.
            if field.stringValue.rangeOfCharacter(from: .newlines) != nil {
                field.stringValue = field.stringValue.components(separatedBy: .newlines).joined(separator: " ")
            }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEnd()
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

/// Popped up over the timers by a timer's +: how much more to give it, typed as a time ("5m",
/// "1h 30m", or a bare number for minutes) or picked from the usual few. It goes onto what the
/// timer was set for as well as what it has left, so its ring fills back up to match.
private struct TimerAddCard: View {
    let timer: ReminderTimer
    @Binding var text: String
    let add: (TimeInterval) -> Void
    let cancel: () -> Void
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let midnight = theme == .midnight
        let typed = ReminderParser.parse(text).duration
        let tint = theme.tint(Color.orange)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .notchSymbol(size: 9, weight: .bold)
                        .foregroundStyle(tint)
                    ReminderField(text: $text, placeholder: "How much more for \(timer.title)? e.g. 5m, 1h 30m",
                                  onSubmit: submit, onCancel: cancel, selecting: NSRange(location: 0, length: 0))
                    if typed != nil {
                        Image(systemName: "return")
                            .notchSymbol(size: 10, weight: .semibold)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(.white.opacity(midnight ? 0.06 : 0.12)))
                .overlay(Capsule().strokeBorder(Midnight.silver.opacity(midnight ? 0.35 : 0), lineWidth: 0.6))
                ForEach([1, 5, 15], id: \.self) { minutes in
                    Button { add(Double(minutes) * 60) } label: {
                        Text("+\(minutes)m")
                            .notchFont(size: 11, weight: .semibold, digits: true)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .notchPill(.white.opacity(0.12), text: .white, bright: false)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .notchSymbol(size: 9, weight: .bold)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(summary(adding: typed, at: context.date))
                    .notchFont(size: 10.5, digits: true)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .background {
            let shape = RoundedRectangle(cornerRadius: midnight ? 4 : 16, style: .continuous)
            shape.fill(midnight ? Midnight.ink.opacity(0.94) : Color(white: 0.12))
                .overlay(shape.strokeBorder(midnight ? Midnight.silver.opacity(0.5) : .white.opacity(0.08), lineWidth: midnight ? 0.6 : 1))
                .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
        }
    }

    /// What it's set for and has left, and, with a time typed, what they'll be.
    private func summary(adding typed: TimeInterval?, at date: Date) -> String {
        let total = timer.duration, left = timer.remaining(at: date)
        guard let typed else { return "Set for \(ReminderTimer.format(total)), \(ReminderTimer.format(left)) left: both grow by what you add" }
        let added = min(typed, ReminderParser.longest - left)
        return "Set for \(ReminderTimer.format(total)) → \(ReminderTimer.format(total + added)), "
            + "\(ReminderTimer.format(left)) left → \(ReminderTimer.format(left + added))"
    }

    private func submit() {
        guard let typed = ReminderParser.parse(text).duration else {
            NSSound.beep()
            return
        }
        add(typed)
    }
}
