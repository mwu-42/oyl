import AppKit
import CoreGraphics
import SwiftUI

/// Where the bedtime Oyl is in its night.
enum BedtimeStage: Equatable {
    case candle  // midnight to one: up late in its pajamas, with a candle
    case bed     // one to two: tucked up in bed
    case remind  // two till five: sitting up in bed, telling you to go
}

/// An Oyl that notices you're still up past midnight: out in its pajamas with a candle from
/// midnight (while you're at the Mac), off to bed at one (saying so), and at two it pops the
/// notch open to tell you to go to bed. Off unless you turn it on, in the Oyls tab.
@MainActor
final class Bedtime: ObservableObject {
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "bedtime.enabled") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "bedtime.enabled")
            check()
        }
    }
    @Published private(set) var stage: BedtimeStage?
    /// It's two or later and you're still up: shown in the notch until you answer.
    @Published private(set) var reminding = false

    /// It moved on to `stage`, to say so.
    var onStage: (BedtimeStage) -> Void = { _ in }

    private var timer: Timer?
    private var snoozedUntil: Date?
    private var answeredNight: Date?  // the night (its midnight) you said you were going
    private var saidNight: Date?      // and the stages it's announced that night, once each
    private var said: Set<BedtimeStage> = []

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // Once whoever's listening for onStage is set up.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// "Going to bed": no more reminders tonight.
    func dismiss() {
        reminding = false
        snoozedUntil = nil
        answeredNight = Calendar.current.startOfDay(for: Date())
    }

    /// "15 more minutes".
    func snooze() {
        reminding = false
        snoozedUntil = Date().addingTimeInterval(15 * 60)
    }

    private func check() {
        let now = Date()
        let next: BedtimeStage?
        switch Calendar.current.component(.hour, from: now) {
        case 0: next = .candle
        case 1: next = .bed
        case 2..<5: next = .remind
        default: next = nil
        }
        let shown = isEnabled && Self.isUp ? next : nil
        let night = Calendar.current.startOfDay(for: now)
        if shown != stage {
            stage = shown
            // Said once a night, however often you step away and come back.
            if saidNight != night {
                saidNight = night
                said = []
            }
            if let shown, said.insert(shown).inserted { onStage(shown) }
        }
        guard shown == .remind else {
            if reminding { reminding = false }
            return
        }
        if !reminding, answeredNight != night, snoozedUntil.map({ now >= $0 }) ?? true {
            snoozedUntil = nil
            reminding = true
        }
    }

    /// Someone's at the Mac: it's been touched in the last quarter of an hour.
    private static var isUp: Bool {
        let kinds: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
        let idle = kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
        return idle < 15 * 60
    }
}

/// Shown in place of the pages at two in the morning, until you say you're going (or ask for
/// fifteen more minutes).
struct BedtimeAlert: View {
    @ObservedObject var bedtime: Bedtime

    static let moon = Color(red: 0.74, green: 0.66, blue: 1)

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Self.moon)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Self.moon.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Time for bed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                TimelineView(.everyMinute) { context in
                    Text("It's \(context.date.formatted(date: .omitted, time: .shortened)). Oyl's up waiting for you to sleep")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            pill("15 more min", foreground: .white, background: .white.opacity(0.14), action: bedtime.snooze)
            pill("Going to bed", foreground: .black, background: Self.moon, action: bedtime.dismiss)
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
}
