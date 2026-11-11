import SwiftUI
import UniformTypeIdentifiers

/// The shelf, over Oyl's Dock (opened from its tile there; see `DockView`): the latest
/// screenshots, what's just been saved and what Claude's just written or edited, and files kept
/// here, in a row, newest first, each to be dragged out into any app (or onto one in the Dock),
/// each marked with where it came from in a color the card's top says the meaning of. Hovered, one
/// has AirDrop, a way to convert it and a way off the shelf; right-clicked, the rest (copy, show in Finder,
/// the Trash). Click one to pick it out, shift-click another to pick out everything between, ⌘-click
/// to pick out one more (or one fewer): they drag out together, and what's done to one of them is
/// done to them all. Files dropped on the card or the tile, or chosen with its +, are kept.
struct ShelfCard: View {
    @ObservedObject var shelf: Shelf
    let width: CGFloat
    /// Keeps the Dock up (true) while a menu or the file picker is, and lets it go again.
    let hold: (Bool) -> Void
    @StateObject private var targeted = LocalState(false)
    @Environment(\.notchTheme) private var theme

    static let padding: CGFloat = 14
    static var height: CGFloat { 2 * padding + 18 + 7 + ShelfTile.height }

    var body: some View {
        let midnight = theme == .midnight
        // (Not for one of its own, dragged along it.)
        let taking = targeted.value && !ShelfDrag.shared.isDragging
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(Shelf.title)
                    .notchFont(size: 11, weight: .semibold, role: .label)
                    .foregroundStyle(.white.opacity(0.6))
                    .help("Drag one out, or drop a file to convert")
                Spacer(minLength: 8)
                if taking {
                    Text("Let go to keep it here")
                        .notchFont(size: 10, role: .body)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                } else if shelf.selection.count > 1 {
                    picked
                } else {
                    legend
                }
                Button { Self.choose(for: shelf, hold: hold) } label: {
                    Image(systemName: "plus")
                        .notchSymbol(size: 9, weight: .bold)
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(midnight ? 0 : 0.12)))
                        .overlay(Circle().strokeBorder(Midnight.silver.opacity(midnight ? 0.5 : 0), lineWidth: 0.6))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help("Choose files to keep here and convert")
            }
            .frame(height: 18)

            if shelf.items.isEmpty {
                empty
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelf.items) { item in
                            ShelfTile(shelf: shelf, item: item, menu: { menu(for: item, full: $0) })
                        }
                    }
                }
                .frame(height: ShelfTile.height)
            }
        }
        .padding(Self.padding)
        .frame(width: width, height: Self.height, alignment: .topLeading)
        // A click off the tiles lets go of what's picked out, as it does once the shelf's put away.
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { shelf.clearSelection() })
        .onDisappear { shelf.clearSelection() }
        .background {
            // Black, as the notch; or night, thinning out at its edges.
            if midnight {
                // A darker pool in the sky that's grown up round it (see `MidnightDockSky`), so it
                // reads, with no edge to it, as the band's page has.
                EllipticalGradient(colors: [Midnight.ink.opacity(0.85), Midnight.ink.opacity(0)], center: .center,
                                   startRadiusFraction: 0.3, endRadiusFraction: 0.5)
                    .frame(width: width * 1.2, height: Self.height * 1.9)
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.black)
                    .shadow(color: .black.opacity(0.5), radius: 14, y: -2)
            }
        }
        .overlay {
            // Where a drop goes, while a file's held over it.
            RoundedRectangle(cornerRadius: midnight ? 4 : 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: midnight ? 0.75 : 1.5, dash: [4, 3]))
                .foregroundStyle((midnight ? Midnight.silver : Color.white).opacity(taking ? 0.6 : 0))
                .padding(5)
                .allowsHitTesting(false)
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted.value, perform: drop)
        .animation(.easeOut(duration: 0.15), value: taking)
        .animation(.easeOut(duration: 0.15), value: shelf.selection.count > 1)
        .animation(NotchView.open, value: shelf.items.map(\.id))
    }

    /// How many are picked out, and a way to let go of them.
    private var picked: some View {
        HStack(spacing: 8) {
            Text("\(shelf.selection.count) selected · drag them out together")
                .notchFont(size: 10, role: .body)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Button("Clear") { shelf.clearSelection() }
                .buttonStyle(.plain)
                .notchFont(size: 10, weight: .semibold, role: .label)
                .foregroundStyle(.white.opacity(0.85))
                .help("Let go of what's selected")
        }
    }

    /// What each color means, for what's on.
    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(Shelf.Item.Origin.allCases.filter(\.isOn), id: \.self) { origin in
                HStack(spacing: 4) {
                    OriginMark(origin: origin)
                    Text(origin.name)
                        .notchFont(size: 10, role: .body)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: 5) {
            if !shelf.blocked.isEmpty {
                Text("Oyl can't see " + ListFormatter.localizedString(byJoining: shelf.blocked.map(Self.called)))
                    .notchFont(size: 12, weight: .medium)
                    .foregroundStyle(.white.opacity(0.7))
                Button("Allow it in Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .notchFont(size: 11, weight: .medium)
                .foregroundStyle(theme.tint(.blue))
            } else {
                Image(systemName: "tray")
                    .notchSymbol(size: 18, weight: .regular)
                    .foregroundStyle(.white.opacity(0.3))
                Text("Screenshots, what you download or save, and what Claude makes show up here")
                    .notchFont(size: 11)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: ShelfTile.height)
    }

    /// A folder as it's said: "your Downloads folder", "the Desktop".
    private static func called(_ folder: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if folder.standardizedFileURL.path == home.appendingPathComponent("Desktop").path { return "the Desktop" }
        if folder.standardizedFileURL.path == home.appendingPathComponent("Downloads").path { return "your Downloads folder" }
        return "where your screenshots go"
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard !ShelfDrag.shared.isDragging else { return false }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { shelf.keep([url]) }
                }
            }
        }
        return !files.isEmpty
    }

    /// Files picked to keep on the shelf, `hold` keeping the Dock up meanwhile.
    @MainActor
    static func choose(for shelf: Shelf, hold: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Keep"
        panel.message = "Choose files to keep on the shelf, to convert or drag out"
        // Keep the Dock up while it's up.
        hold(true)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            MainActor.assumeIsolated {
                hold(false)
                if response == .OK { shelf.keep(panel.urls) }
            }
        }
    }

    /// What can be done with an item (or everything picked out with it): what it converts into,
    /// then (`full`, right-clicked) the rest.
    private func menu(for item: Shelf.Item, full: Bool) {
        let menu = NSMenu()
        let items = shelf.acting(on: item)
        let many = items.count > 1
        let formats = Shelf.formats(for: items)
        menu.addItem(.sectionHeader(title: many ? "Convert \(items.count) to" : "Convert to"))
        for format in formats {
            menu.addItem(ClosureMenuItem(title: format.name) { shelf.convert(items, to: format) })
        }
        if many, formats.isEmpty {
            let none = NSMenuItem(title: "Nothing they all convert to", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        if full {
            let files = items.contains { $0.kind != .photo }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: many ? "Open \(items.count)" : "Open") { shelf.open(items) })
            menu.addItem(ClosureMenuItem(title: many ? "Copy \(items.count)" : "Copy") { shelf.copy(items) })
            menu.addItem(ClosureMenuItem(title: many ? "AirDrop \(items.count)…" : "AirDrop…") { shelf.airDrop(items) })
            if files {
                menu.addItem(ClosureMenuItem(title: "Show in Finder") { shelf.reveal(items) })
            }
            if !many, let label = shelf.label(for: item), item.url.deletingPathExtension().lastPathComponent != label {
                menu.addItem(ClosureMenuItem(title: "Rename to “\(label)”") { shelf.renameToLabel(item) })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: many ? "Take \(items.count) Off the Shelf" : "Take Off the Shelf") { shelf.remove(items) })
            if files {
                menu.addItem(ClosureMenuItem(title: many ? "Move \(items.count) to Trash" : "Move to Trash") { shelf.trash(items) })
            }
        }
        // Keep the Dock up while the menu is; popUp returns once it closes.
        hold(true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        hold(false)
    }
}

/// One thing on the shelf: its picture, with what it is on it, and under it what it shows (a
/// screenshot's label; see `ScreenshotLabeler`) or its name, and when it was taken or kept. The
/// picture drags out as the file (with the rest picked out, if it's one of them). Picked out, in
/// Oyl's look it's ringed in white, its name on a pill; in Midnight Oyl's, moonlight comes up
/// inside it, breathing, and a star twinkles by its name.
struct ShelfTile: View {
    @ObservedObject var shelf: Shelf
    let item: Shelf.Item
    /// Shows its menu: the formats it converts to, or (true) everything.
    let menu: (Bool) -> Void
    @StateObject private var hover = LocalState(false)
    @Environment(\.notchTheme) private var theme

    static let picture = CGSize(width: 104, height: 68)
    static let height = picture.height + 4 + 12 + 11

    var body: some View {
        let midnight = theme == .midnight
        let shape = RoundedRectangle(cornerRadius: midnight ? 2.5 : 9, style: .continuous)
        let converting = shelf.converting[item.url]
        let failure = shelf.failures[item.url]
        let picked = shelf.selection.contains(item.url)
        VStack(spacing: 4) {
            ZStack {
                shape.fill(midnight ? Midnight.ink.opacity(0.5) : Color.white.opacity(0.07))
                if let image = shelf.thumbnails[item.url] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(3)
                }
                DragHandle(files: dragged, hovered: { hover.value = $0 }, pick: { shelf.pick(item, $0) },
                           isAmongOthers: { shelf.acting(on: item).count > 1 }, open: { shelf.open(item) }, menu: { menu(true) })
                badge
                if converting != nil || failure != nil {
                    shape.fill(Color.black.opacity(0.6))
                    if let converting {
                        VStack(spacing: 3) {
                            ProgressView().controlSize(.small)
                            Text(converting.name)
                                .notchFont(size: 9, weight: .semibold, role: .label)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    } else if let failure {
                        Text(failure)
                            .notchFont(size: 9, weight: .medium)
                            .foregroundStyle(theme.tint(Color(red: 1, green: 0.55, blue: 0.5), urgent: true))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(4)
                    }
                }
                if hover.value && converting == nil { controls }
            }
            .frame(width: Self.picture.width, height: Self.picture.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Midnight.silver.opacity(midnight ? (hover.value ? 0.75 : 0.4) : 0), lineWidth: 0.6))
            // Picked out.
            .overlay {
                if picked {
                    if midnight {
                        Moonlit(shape: shape).transition(.opacity)
                    } else {
                        shape.strokeBorder(.white.opacity(0.9), lineWidth: 2).transition(.opacity)
                    }
                }
            }
            // What was just made, picked out.
            .overlay(shape.strokeBorder((midnight ? Midnight.starlight : Color.white).opacity(shelf.fresh == item.url ? 0.9 : 0),
                                        lineWidth: 1.5))
            .animation(.easeOut(duration: 0.4), value: shelf.fresh == item.url)

            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    if picked && midnight {
                        Twinkle().transition(.opacity)
                    } else if let origin = item.origin {
                        OriginMark(origin: origin)
                    }
                    Text(title)
                        .notchFont(size: 9.5, role: .body)
                        .foregroundStyle(picked ? (midnight ? Midnight.starlight : .white) : .white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(item.isCapture ? .tail : .middle)
                }
                .padding(.horizontal, picked && !midnight ? 5 : 0)
                .frame(height: 12)
                .background {
                    if picked && !midnight { Capsule().fill(.white.opacity(0.2)).transition(.opacity) }
                }
                Text(when)
                    .notchFont(size: 8.5, digits: true, role: .data)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .frame(height: 11)
            }
            .frame(width: Self.picture.width)
            .help(shelf.label(for: item) ?? item.url.lastPathComponent)
            .animation(.easeOut(duration: 0.3), value: shelf.label(for: item))
        }
        .animation(.easeOut(duration: 0.15), value: hover.value)
        .animation(.easeOut(duration: 0.15), value: picked)
    }

    /// What dragging it takes out: it, then the rest picked out with it, each with its picture.
    private func dragged() -> [(url: URL, image: NSImage?)] {
        let rest = shelf.acting(on: item).filter { $0.url != item.url }
        return ([item] + rest).map { ($0.url, shelf.thumbnails[$0.url]) }
    }

    /// The format, low left; a recording's, a converted file's or one from Photos' mark beside it.
    private var badge: some View {
        let midnight = theme == .midnight
        return VStack {
            Spacer()
            HStack(spacing: 3) {
                if item.kind == .recording {
                    Image(systemName: "play.fill").notchSymbol(size: 6, weight: .bold)
                }
                if item.kind == .converted {
                    Image(systemName: "arrow.triangle.2.circlepath").notchSymbol(size: 6, weight: .bold)
                }
                if item.kind == .photo {
                    Image(systemName: "photo").notchSymbol(size: 6, weight: .bold)
                }
                Text(item.url.hasDirectoryPath ? "FOLDER" : item.url.pathExtension.uppercased())
                    .notchFont(size: 6.5, weight: .bold, role: .data)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 4)
            .frame(height: 11)
            .background(midnight ? AnyShapeStyle(Midnight.ink.opacity(0.85)) : AnyShapeStyle(Color.black.opacity(0.55)),
                        in: RoundedRectangle(cornerRadius: midnight ? 1.5 : 3, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .allowsHitTesting(false)
    }

    /// Top left, the file into the Trash (not one from Photos, which is in Photos still); top
    /// right, just off the shelf (well apart, so one's not hit for the other); low right, AirDrop
    /// and convert. Each for everything picked out with it, if it's one of them.
    private var controls: some View {
        let items = shelf.acting(on: item)
        let these = items.count > 1 ? "these \(items.count)" : nil
        return VStack {
            HStack {
                if item.kind != .photo {
                    button("trash", help: these.map { "Move \($0) to the Trash" } ?? "Move to the Trash") { shelf.trash(items) }
                }
                Spacer()
                button("xmark", help: these.map { "Take \($0) off the shelf (the files stay)" } ?? "Take off the shelf (the file stays)") {
                    shelf.remove(items)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Spacer()
                // (AirDrop's own mark isn't one of the symbols apps get; this is the nearest.)
                button("dot.radiowaves.up.forward", help: these.map { "AirDrop \($0)" } ?? "AirDrop") { shelf.airDrop(items) }
                button("arrow.triangle.2.circlepath", help: these.map { "Convert \($0) to another format" } ?? "Convert to another format") {
                    menu(false)
                }
            }
        }
        .padding(3)
        .transition(.opacity)
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        let midnight = theme == .midnight
        return Button(action: action) {
            Image(systemName: symbol)
                .notchSymbol(size: 7.5, weight: .bold)
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(midnight ? Midnight.ink.opacity(0.85) : Color.black.opacity(0.65)))
                .overlay(Circle().strokeBorder(Midnight.silver.opacity(midnight ? 0.6 : 0), lineWidth: 0.6))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }

    /// A screenshot's label (what it is till it has one), or the file's name.
    private var title: String {
        guard item.isCapture else { return item.url.lastPathComponent }
        return shelf.label(for: item) ?? (item.kind == .recording ? "Screen recording" : "Screenshot")
    }

    private var when: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(item.date) { return item.date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(item.date) { return "Yesterday " + item.date.formatted(date: .omitted, time: .shortened) }
        return item.date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Over a shelf item's picture: clicked, it's picked out (shift-clicked, everything between; ⌘,
/// one more or fewer); dragged, it's the file itself (and the rest picked out with it), going out
/// to whatever it's dropped on; double-clicked, it opens; right-clicked, its menu. (AppKit's own
/// drag, so the notch can follow it out; see `ShelfDrag`.)
private struct DragHandle: NSViewRepresentable {
    /// What a drag takes out, the one pressed first.
    let files: () -> [(url: URL, image: NSImage?)]
    let hovered: (Bool) -> Void
    let pick: (Shelf.Picking) -> Void
    /// It's picked out, with others.
    let isAmongOthers: () -> Bool
    let open: () -> Void
    let menu: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.files = files
        view.hovered = hovered
        view.pick = pick
        view.isAmongOthers = isAmongOthers
        view.open = open
        view.showMenu = menu
    }

    final class HandleView: NSView {
        var files: () -> [(url: URL, image: NSImage?)] = { [] }
        var hovered: (Bool) -> Void = { _ in }
        var pick: (Shelf.Picking) -> Void = { _ in }
        var isAmongOthers: () -> Bool = { false }
        var open: () -> Void = {}
        var showMenu: () -> Void = {}
        private var pressed: NSEvent?
        /// Pressed plainly on one picked out with others: it's picked out alone only once it's let
        /// go without a drag, so they can all be dragged out together.
        private var pickOnRelease = false

        // The panel's rarely key, so the first press has to start the drag.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hovered(true) }
        override func mouseExited(with event: NSEvent) { hovered(false) }

        override func mouseDown(with event: NSEvent) {
            pressed = event
            pickOnRelease = false
            let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if keys.contains(.shift) {
                pick(.through)
            } else if keys.contains(.command) {
                pick(.toggle)
            } else if event.clickCount == 2 {
                pressed = nil
                open()
            } else if isAmongOthers() {
                pickOnRelease = true
            } else {
                pick(.only)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let pressed else { return }
            let from = pressed.locationInWindow, to = event.locationInWindow
            guard hypot(to.x - from.x, to.y - from.y) > 3 else { return }
            self.pressed = nil
            pickOnRelease = false
            let files = files()
            guard !files.isEmpty else { return }
            // Each its own picture, piled a little behind the one pressed.
            let items = files.enumerated().map { index, file in
                let picture = file.image ?? NSWorkspace.shared.icon(forFile: file.url.path)
                let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
                let step = CGFloat(min(index, 3)) * 4
                item.setDraggingFrame(fitted(picture.size).offsetBy(dx: step, dy: -step), contents: picture)
                return item
            }
            let session = beginDraggingSession(with: items, event: pressed, source: ShelfDrag.shared)
            if items.count > 1 { session.draggingFormation = .pile }
        }

        override func mouseUp(with event: NSEvent) {
            if pickOnRelease { pick(.only) }
            pressed = nil
            pickOnRelease = false
        }

        override func rightMouseDown(with event: NSEvent) {
            showMenu()
        }

        /// The picture as big as it's shown.
        private func fitted(_ size: NSSize) -> NSRect {
            let scale = min(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
            let fitted = NSSize(width: size.width * scale, height: size.height * scale)
            return NSRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                          width: fitted.width, height: fitted.height)
        }
    }
}

extension Shelf {
    /// What it's called on its card, and its button in the Dock.
    static let title = "Recent"
    static let symbol = "tray.full"
}

extension Shelf.Item.Origin {
    var name: String {
        switch self {
        case .download: return "Downloads"
        case .claude: return "Claude"
        case .screenshot: return "Screenshots"
        }
    }

    /// Blue for what's been downloaded or saved, orange for Claude's, light green for screenshots.
    var color: Color {
        switch self {
        case .download: return Color(red: 0.32, green: 0.6, blue: 1)
        case .claude: return Color(red: 1, green: 0.56, blue: 0.2)
        case .screenshot: return Color(red: 0.55, green: 0.9, blue: 0.5)
        }
    }

    /// It's on the shelf (each can be turned off).
    var isOn: Bool {
        switch self {
        case .download: return Feature.savedShelf.isOn
        case .claude: return Feature.claudeShelf.isOn
        case .screenshot: return Feature.screenshotsShelf.isOn
        }
    }
}

/// Where a shelf item came from, in its color: a dot in Oyl's look; in Midnight's, a paler one
/// with a soft halo, like a coloured star, slowly breathing.
struct OriginMark: View {
    let origin: Shelf.Item.Origin
    @Environment(\.notchTheme) private var theme

    var body: some View {
        if theme == .midnight {
            let color = theme.tint(origin.color, urgent: true)
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let beat = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 1.3 + phase)
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .shadow(color: color.opacity(0.5 + 0.35 * beat), radius: 2 + 1.5 * beat)
            }
            .frame(width: 6, height: 6)
        } else {
            Circle()
                .fill(origin.color)
                .frame(width: 6, height: 6)
        }
    }

    /// Each breathes in its own time.
    private var phase: Double {
        switch origin {
        case .download: return 0
        case .claude: return 2.1
        case .screenshot: return 4.2
        }
    }
}

/// Midnight Oyl's picked out: moonlight come up inside the picture from its edges, with no edge of
/// its own, slowly breathing.
struct Moonlit<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let breath = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 1.6)
            ZStack {
                shape.fill(Midnight.moonlight.opacity(0.03 + 0.03 * breath))
                shape.stroke(Midnight.starlight.opacity(0.35 + 0.2 * breath), lineWidth: 6)
                    .blur(radius: 6)
            }
            .clipShape(shape)
        }
        .allowsHitTesting(false)
    }
}

/// By a picked-out item's name, in Midnight Oyl: a star, twinkling, turning a little.
struct Twinkle: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let twinkle = 0.5 + 0.5 * sin(time * 2 * .pi / 1.7)
            Sparkle(size: 3.4 + 1.4 * twinkle)
                .fill(Midnight.starlight.opacity(0.7 + 0.3 * twinkle))
                .rotationEffect(.radians(time * 0.5))
                .shadow(color: Midnight.moonlight.opacity(0.7), radius: 2)
        }
        .frame(width: 9, height: 9)
    }
}
