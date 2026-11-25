import AppKit
import SwiftUI
import os

// Your desktops' groups (see `SpaceGroups`), marked over macOS's own Mission Control while it's open:
// under its row of desktops, each group's run of them bracketed and named; a group whose desktops
// aren't next to each other there marked split, its parts linked, so they can be dragged back
// together (macOS keeps the order; only dragging in Mission Control changes it). Only read: Mission
// Control's row is looked at through accessibility, nothing's pressed or dragged, and the marks let
// every click through.

/// Mission Control's row of desktops, as its accessibility has it, on each display: read only.
enum MissionControlRow {
    struct Row: Equatable {
        /// The display's number, if it said.
        let display: CGDirectDisplayID?
        /// Each desktop's frame, left to right, in the screen's top-left coordinates (as the
        /// window server's).
        let frames: [CGRect]
    }

    /// Each display's row, while Mission Control's open (none, while it isn't). Off the main thread.
    nonisolated static func read(dock: pid_t) -> [Row] {
        guard let group = missionControl(dock) else { return [] }
        return children(group).filter { identifier($0) == "mc.display" }.compactMap { display in
            guard let spaces = children(display).first(where: { identifier($0) == "mc.spaces" }),
                  let list = children(spaces).first(where: { identifier($0) == "mc.spaces.list" }) else { return nil }
            let frames = children(list).compactMap(frame).sorted { $0.minX < $1.minX }
            return Row(display: number(display, "AXDisplayID").map { CGDirectDisplayID($0) }, frames: frames)
        }
    }

    private nonisolated static func missionControl(_ dock: pid_t) -> AXUIElement? {
        let element = AXUIElementCreateApplication(dock)
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let group = children(element).first(where: { identifier($0) == "mc" }), !children(group).isEmpty else { return nil }
        return group
    }

    private nonisolated static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private nonisolated static func identifier(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private nonisolated static func number(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private nonisolated static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }
}

/// A group's run of desktops next to each other in Mission Control's row: what's marked.
struct MissionMark: Identifiable, Equatable {
    let group: String
    let name: String
    /// The run's desktops together, in the screen's top-left coordinates.
    let frame: CGRect
    /// Where each desktop in it is across, for Midnight's stars.
    let centers: [CGFloat]
    /// Which part of the group this is, of how many (more than one: it's split).
    let part: Int
    let parts: Int

    var id: String { "\(group)#\(part)" }
    var isSplit: Bool { parts > 1 }

    /// The runs of `groups` (each desktop's group, in the row's order) along `frames`: each group's
    /// desktops that are next to each other one mark, numbered among the group's parts. Desktops in
    /// no group have none.
    nonisolated static func marks(frames: [CGRect], groups: [(id: String, name: String)?]) -> [MissionMark] {
        guard frames.count == groups.count else { return [] }
        var runs: [(group: String, name: String, indices: [Int])] = []
        for (index, group) in groups.enumerated() {
            guard let group else { continue }
            if let last = runs.last, last.group == group.id, last.indices.last == index - 1 {
                runs[runs.count - 1].indices.append(index)
            } else {
                runs.append((group.id, group.name, [index]))
            }
        }
        var counts: [String: Int] = [:]
        for run in runs { counts[run.group, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return runs.map { run in
            let part = seen[run.group, default: 0]
            seen[run.group] = part + 1
            let rects = run.indices.map { frames[$0] }
            let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            return MissionMark(group: run.group, name: run.name, frame: union, centers: rects.map(\.midX), part: part,
                               parts: counts[run.group] ?? 1)
        }
    }
}

extension MissionMark {
    /// Amber, for a split group (paler in Midnight's, as its colors are).
    nonisolated static func amber(_ theme: NotchTheme) -> Color { theme.tint(Color(red: 1, green: 0.76, blue: 0.36)) }
}

@MainActor
final class MissionMarksModel: ObservableObject {
    @Published var marks: [MissionMark] = []
    @Published var theme = NotchTheme.standard
    @Published var shown = false
    @Published var size = CGSize(width: 1440, height: 900)
}

/// Over Mission Control while it's open, on every screen with groups to mark: watching its row (a
/// few times a second, as desktops are dragged about and the row opens out under the pointer) and
/// marking it afresh.
@MainActor
final class MissionGroups {
    private var panels: [CGDirectDisplayID: (panel: NSPanel, model: MissionMarksModel)] = [:]
    private var timer: Timer?
    private var reading = false
    private var hiding: DispatchWorkItem?
    /// Looked for till then, though it isn't there yet (its swipe's begun, or the Dock's said so).
    private var expecting: Date?
    /// When its row was last there: it's gone once it hasn't been for a moment.
    private var lastSeen: Date?
    /// Reads in a row Mission Control's own windows weren't up, though its row could still be
    /// read (it lingers a moment as it closes).
    private var downs = 0
    /// The Dock's said Mission Control's open, and not yet that it's gone: its row's trusted as it
    /// is (only a row found after a swipe, with no word from the Dock, needs its windows seen too).
    private var told = false
    /// What was last noted (for the log, which notes each change, not each read).
    private var lastNoted = ""

    var theme = NotchTheme.standard {
        didSet { for entry in panels.values { entry.model.theme = theme } }
    }

    /// The Dock says Mission Control's open, or that it's gone (as you go to a desktop, or come back
    /// to the one you were on): open, it's looked for; gone, the marks go at once.
    func showing(_ on: Bool) {
        told = on
        note(on ? "the Dock says Mission Control's open" : "the Dock says it's gone: marks away")
        if on { expect() } else {
            stop()
            // Desktops put together in it: a group now all one is done away with.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SpaceGroups.tidy() }
        }
    }

    init() {
        // And as you go to another Space (a window tiled into another's, too).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SpaceGroups.tidy() }
        }
    }

    /// Mission Control may be coming (three fingers began up, or the Dock said so): its row looked
    /// for a few seconds, and marked for as long as it's there.
    func expect() {
        guard Feature.missionControlGroups.isOn, !SpaceGroups().all.isEmpty else { return }
        expecting = Date().addingTimeInterval(3)
        if timer == nil { note("looking for its row") }
        start()
    }

    private func start() {
        hiding?.cancel()
        hiding = nil
        guard timer == nil else { return }
        // Ten times a second, so they keep up as the row opens out under the pointer.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func stop() {
        if timer != nil { note("done looking") }
        timer?.invalidate()
        timer = nil
        expecting = nil
        lastSeen = nil
        downs = 0
        for entry in panels.values { withAnimation(Self.ease(theme)) { entry.model.shown = false } }
        hiding?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timer == nil else { return }
                for entry in self.panels.values { entry.panel.orderOut(nil) }
            }
        }
        hiding = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func poll() {
        guard !reading, let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        else { return }
        reading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = MissionControlRow.read(dock: dock)
            let windows = MissionControl.dockWindowsUp()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.reading = false
                    guard self.timer != nil else { return }
                    let now = Date()
                    let up = !rows.isEmpty && (self.told || windows)
                    self.note(rows.isEmpty ? "no row" : up ? "row of \(rows.map(\.frames.count))" : "a row, but no windows and no word from the Dock")
                    self.downs = up ? 0 : self.downs + 1
                    guard up else {
                        // Not there (or only its row's left, as it closes) two reads running (one's
                        // a flicker, as the row opens out): the marks away; done looking a moment
                        // on, unless it's still awaited.
                        if self.downs >= 2 { self.hideMarks() }
                        if self.downs >= 3, (self.expecting.map { now > $0 } ?? true) || self.lastSeen != nil { self.stop() }
                        return
                    }
                    self.lastSeen = now
                    self.apply(rows)
                }
            }
        }
    }

    /// The marks out of sight, still looking.
    private func hideMarks() {
        for entry in panels.values where entry.model.shown {
            withAnimation(Self.ease(theme)) { entry.model.shown = false }
        }
    }

    private func apply(_ rows: [MissionControlRow.Row]) {
        guard !rows.isEmpty else { return }
        let groups = SpaceGroups().all
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            guard let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            let row = rows.first { $0.display == number } ?? (rows.count == 1 && NSScreen.screens.count == 1 ? rows.first : nil)
            guard let row, let display = FullscreenSpace.display(for: screen) else { continue }
            let spaces = Spaces.all(in: display, boot: Spaces.bootTime) { NSRunningApplication(processIdentifier: $0)?.localizedName }.spaces
            // Mid-drag the row and the Spaces can disagree for a moment: the marks stay as they were.
            guard spaces.count == row.frames.count else {
                // Mid-drag, or as it settles: out of sight till they agree again, rather than
                // left where they no longer belong.
                note("the row has \(row.frames.count) desktops, the Spaces \(spaces.count): marks hidden till they agree")
                if let entry = panels[number], entry.model.shown { withAnimation(Self.ease(theme)) { entry.model.shown = false } }
                continue
            }
            let top = primaryHeight - screen.frame.maxY
            let frames = row.frames.map { $0.offsetBy(dx: -screen.frame.minX, dy: -top) }
            let marks = MissionMark.marks(frames: frames, groups: spaces.map { space in
                SpaceGroups.group(of: space, in: groups).map { (id: $0.id, name: $0.name) }
            })
            show(marks, on: screen, number: number)
        }
    }

    private func show(_ marks: [MissionMark], on screen: NSScreen, number: CGDirectDisplayID) {
        let entry = panels[number] ?? makePanel(number)
        entry.model.size = screen.frame.size
        if entry.panel.frame != screen.frame { entry.panel.setFrame(screen.frame, display: false) }
        if entry.model.marks != marks {
            if entry.model.shown {
                // Following the row as it moves.
                withAnimation(Self.ease(theme)) { entry.model.marks = marks }
            } else {
                // Coming up: straight where they go, not from where they were last time.
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { entry.model.marks = marks }
            }
        }
        if !entry.panel.isVisible { entry.panel.orderFrontRegardless() }
        if !entry.model.shown { withAnimation(Self.ease(theme).delay(0.05)) { entry.model.shown = true } }
    }

    private func makePanel(_ number: CGDirectDisplayID) -> (panel: NSPanel, model: MissionMarksModel) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let model = MissionMarksModel()
        model.theme = theme
        let host = NSHostingView(rootView: MissionMarksView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panels[number] = (panel, model)
        return (panel, model)
    }

    /// Oyl's plain ease; Midnight's drift (quick enough to keep up with the row).
    static func ease(_ theme: NotchTheme) -> Animation {
        theme == .midnight ? .timingCurve(0.45, 0, 0.25, 1, duration: 0.28) : .easeOut(duration: 0.12)
    }

    private static let log = Logger(subsystem: "local.nott", category: "mission-groups")

    /// Noted in the log as it changes (kept, unlike every read), to find out what went wrong.
    private func note(_ what: String) {
        guard what != lastNoted else { return }
        lastNoted = what
        Self.log.notice("\(what, privacy: .public)")
    }
}

/// The marks: in Oyl's look, a white bar under each group's run of desktops and its name on a
/// black pill under that, amber and dashed for a group that's split, its parts linked by a dashed
/// curve. In Midnight Oyl's, a fine silver line with a star under each desktop and the name in
/// italics on a breath of night, a split group's in pale amber, its parts joined by a dotted arc;
/// they drift in out of a blur. Only the names are words.
struct MissionMarksView: View {
    @ObservedObject var model: MissionMarksModel

    var body: some View {
        let midnight = model.theme == .midnight
        ZStack(alignment: .topLeading) {
            links(midnight: midnight)
            ForEach(model.marks) { mark in
                MissionMarkView(mark: mark, midnight: midnight)
                    .frame(width: max(mark.frame.width, 60))
                    .position(x: mark.frame.midX, y: mark.frame.maxY + 18)
            }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
        .opacity(model.shown ? 1 : 0)
        .blur(radius: midnight && !model.shown ? 6 : 0)
        .offset(y: model.shown ? 0 : -10)
        .environment(\.notchTheme, model.theme)
        .allowsHitTesting(false)
    }

    /// A split group's parts, linked one to the next under the row.
    @ViewBuilder private func links(midnight: Bool) -> some View {
        let split = Dictionary(grouping: model.marks.filter(\.isSplit), by: \.group)
        ForEach(split.keys.sorted(), id: \.self) { group in
            let parts = (split[group] ?? []).sorted { $0.part < $1.part }
            Path { path in
                for (from, to) in zip(parts, parts.dropFirst()) {
                    let start = CGPoint(x: from.frame.midX, y: from.frame.maxY + 6)
                    let end = CGPoint(x: to.frame.midX, y: to.frame.maxY + 6)
                    let dip = max(start.y, end.y) + 34 + min(abs(end.x - start.x) * 0.06, 30)
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: dip), control2: CGPoint(x: end.x, y: dip))
                }
            }
            .stroke(MissionMark.amber(model.theme).opacity(midnight ? 0.55 : 0.8),
                    style: StrokeStyle(lineWidth: midnight ? 0.9 : 1.5, lineCap: .round, dash: midnight ? [1, 5] : [5, 4]))
            .shadow(color: midnight ? Midnight.moonlight.opacity(0.3) : .clear, radius: 3)
        }
    }
}

private struct MissionMarkView: View {
    let mark: MissionMark
    let midnight: Bool
    @Environment(\.notchTheme) private var theme

    private var tint: Color { mark.isSplit ? MissionMark.amber(theme) : (midnight ? Midnight.silver : .white) }
    private var label: String { mark.name }

    var body: some View {
        VStack(spacing: midnight ? 5 : 4) {
            if midnight { starLine } else { bar }
            Text(label)
                .font(midnight ? Midnight.italic(13.5) : .system(size: 11, weight: .semibold))
                .foregroundStyle(midnight ? tint.opacity(0.95) : tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, midnight ? 10 : 7)
                .padding(.vertical, midnight ? 3 : 2)
                .background {
                    if midnight {
                        Capsule().fill(Midnight.ink.opacity(0.7)).blur(radius: 5)
                    } else {
                        Capsule().fill(Color.black.opacity(0.75))
                    }
                }
                .shadow(color: midnight ? Midnight.moonlight.opacity(0.35) : .clear, radius: 5)
        }
    }

    private var bar: some View {
        let width = max(mark.frame.width - 10, 10)
        return Path { path in
            path.move(to: CGPoint(x: 1.5, y: 1.5))
            path.addLine(to: CGPoint(x: width - 1.5, y: 1.5))
        }
        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: mark.isSplit ? [6, 5] : []))
        .frame(width: width, height: 3)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }

    /// A fine line under the run, a star under each desktop on it.
    private var starLine: some View {
        let width = max(mark.frame.width - 10, 10)
        return ZStack {
            Rectangle()
                .fill(LinearGradient(colors: [.clear, tint.opacity(mark.isSplit ? 0.5 : 0.6), tint.opacity(mark.isSplit ? 0.5 : 0.6), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: width, height: 0.75)
            ForEach(Array(mark.centers.enumerated()), id: \.offset) { _, x in
                FourPointStar()
                    .fill(Midnight.starlight.opacity(mark.isSplit ? 0.7 : 0.95))
                    .frame(width: 7, height: 7)
                    .shadow(color: Midnight.moonlight.opacity(0.6), radius: 3)
                    .offset(x: x - mark.frame.midX)
            }
        }
        .frame(width: width, height: 8)
    }
}
