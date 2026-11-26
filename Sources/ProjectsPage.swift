import AppKit
import SwiftUI

/// Each kind of line's mark, where it's an SF Symbol.
enum ProjectGlyph {
    static func symbol(_ kind: ProjectNode.Kind) -> String {
        switch kind {
        case .area: return "square.stack"
        case .project: return "folder"
        case .task: return "circle"
        case .idea: return "lightbulb"
        case .note: return "text.alignleft"
        }
    }
}

// MARK: - Reminders

/// A task's time come: the notch pops open to say so (in both looks), till it's put off ten
/// minutes, seen, or done. Clicked anywhere but its buttons, it's seen, and the outline opened
/// at it (`opened`).
struct ProjectAlert: View {
    let task: ProjectNode
    @ObservedObject var projects: ProjectStore
    var opened: () -> Void = {}

    static let bell = ReminderAlert.bell

    var body: some View {
        let project = projects.project(of: task.id)?.title
        let when = task.time.map(TodQuick.describe(time:)) ?? ""
        ReminderAlert(title: task.title, detail: [project, when].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                      snooze: { projects.snoozeRinging(minutes: 10) }, dismiss: { projects.dismissRinging() },
                      finish: { projects.finishRinging() }, opened: opened)
    }
}

/// A reminder, the notch open to say so: a bell, what it's for and when, and +10 min, OK and
/// Done; clicked anywhere else, `opened`.
struct ReminderAlert: View {
    let title: String
    /// What it's in and when: "cs 106b · 5 PM".
    let detail: String
    let snooze: () -> Void
    let dismiss: () -> Void
    let finish: () -> Void
    var opened: () -> Void = {}
    /// Drawn as if pointed at (for a picture of it).
    var pointed = false
    /// Pointed at: it says it can be clicked.
    @StateObject private var hovered = LocalState(false)
    @Environment(\.notchTheme) private var theme

    static let bell = Color(red: 1, green: 0.78, blue: 0.42)

    var body: some View {
        let bell = theme.tint(Self.bell, urgent: true)
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .notchSymbol(size: 18, weight: .semibold)
                .foregroundStyle(bell)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 34, height: 34)
                .background(Circle().fill(bell.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                OpensTab(hovered: hovered.value || pointed) {
                    Text(title.isEmpty ? "A reminder" : title)
                        .notchFont(size: 13, weight: .semibold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(detail)
                    .notchFont(size: 10.5)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            pill("+10 min", foreground: .white, background: .white.opacity(0.14), bright: false, action: snooze)
            pill("OK", foreground: .white, background: .white.opacity(0.14), bright: false, action: dismiss)
            pill("Done", foreground: .black, background: Self.bell, action: finish)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .opensTab(hovered: hovered, opened)
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
}
