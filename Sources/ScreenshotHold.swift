import AppKit
import Combine
import SwiftUI

/// macOS's floating thumbnail of a screenshot, held longer: ten seconds, not macOS's five or so,
/// which can't be set. macOS's own is turned off while this is on (`show-thumbnail`, in its
/// screenshot settings: yours kept, and put back once this is off or Oyl's quit for good), so the
/// file's saved at once; and Oyl shows its own in the same corner, from the screenshot folder as
/// each new screenshot lands there. Drag it where it's wanted (into a chat, a terminal for Claude
/// Code, a folder), click it to open it, close it with its ×; pointed at, it's held till the pointer
/// goes. In Oyl's look a picture edged in white with a bar under it running down; in Midnight Oyl's,
/// one with no edge, glowing faintly, a hairline under it running down to a star; each comes in from
/// the right, and goes the same way. On the Dock's settings, off to begin with.
@MainActor
final class ScreenshotHold {
    static let shared = ScreenshotHold()

    static let held: TimeInterval = 10
    nonisolated static let domain = "com.apple.screencapture" as CFString
    nonisolated static let thumbnailKey = "show-thumbnail" as CFString
    nonisolated static let keptKey = "screenshotHold.kept"
    nonisolated private static let unset = "unset"

    private var source: DispatchSourceFileSystemObject?
    private var folder: URL?
    private var since = Date()
    private var looking: DispatchWorkItem?
    private var following: AnyCancellable?
    private var panel: NSPanel?
    private let model = HeldShotModel()
    private var ticking: Timer?

    var theme = NotchTheme.standard {
        didSet { model.theme = theme }
    }

    func start() {
        following = Features.shared.follow(.holdScreenshots) { [weak self] on in self?.follow(on) }
    }

    private func follow(_ on: Bool) {
        Self.macThumbnail(on: !on)
        if on { watch() } else { stopWatching(); dismiss() }
    }

    /// Oyl's quitting: macOS's own thumbnail back, unless it's only for a moment.
    func quitting(forGood: Bool) {
        if forGood { Self.macThumbnail(on: true) }
    }

    // MARK: macOS's own thumbnail

    /// macOS's floating thumbnail on (as you had it) or off (yours kept, to be put back). Whether
    /// that changed anything. (In `domain`, with `store` keeping yours: scratch ones in tests.)
    @discardableResult
    nonisolated static func macThumbnail(on: Bool, in domain: CFString = domain, keeping store: UserDefaults = .standard) -> Bool {
        CFPreferencesAppSynchronize(domain)
        let current = CFPreferencesCopyAppValue(thumbnailKey, domain)
        let isOff = (current as? Bool) == false
        if on {
            guard let kept = store.object(forKey: keptKey) else { return false }
            store.removeObject(forKey: keptKey)
            // One you've turned on yourself meanwhile is left alone.
            guard isOff else { return false }
            CFPreferencesSetAppValue(thumbnailKey, (kept as? String) == unset ? nil : kept as CFPropertyList, domain)
        } else {
            guard !isOff else { return false }
            store.set(current ?? unset as CFPropertyList, forKey: keptKey)
            CFPreferencesSetAppValue(thumbnailKey, kCFBooleanFalse, domain)
        }
        CFPreferencesAppSynchronize(domain)
        return true
    }

    // MARK: Watching the screenshot folder

    private func watch() {
        let folder = Shelf.screenshotFolder()
        guard folder != self.folder || source == nil else { return }
        stopWatching()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.lookSoon() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        self.folder = folder
        since = Date()
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
        folder = nil
    }

    /// Something's changed in the folder: looked at once it's settled (macOS marks a screenshot as
    /// one a moment after writing it).
    private func lookSoon(tries: Int = 3) {
        looking?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.look(tries: tries) }
        }
        looking = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func look(tries: Int) {
        guard let folder, Feature.holdScreenshots.isOn else { return }
        // The folder moved (its setting changed): watched afresh.
        if Shelf.screenshotFolder() != folder { watch() }
        let found = Self.newShots(in: folder, since: since)
        guard let newest = found.last else {
            // Written, but not marked yet: looked at again in a moment.
            if tries > 0, Self.unmarked(in: folder, since: since) { lookSoon(tries: tries - 1) }
            return
        }
        since = newest.date
        show(newest.url)
    }

    /// The pictures macOS has captured into `folder` since `since`, oldest first.
    nonisolated static func newShots(in folder: URL, since: Date) -> [(url: URL, date: Date)] {
        candidates(in: folder, since: since).filter { Shelf.isScreenCapture($0.url) }
    }

    nonisolated private static func unmarked(in folder: URL, since: Date) -> Bool {
        candidates(in: folder, since: since).contains { !Shelf.isScreenCapture($0.url) }
    }

    nonisolated static let pictureTypes: Set = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "pdf"]

    nonisolated private static func candidates(in folder: URL, since: Date) -> [(url: URL, date: Date)] {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return entries.compactMap { url -> (url: URL, date: Date)? in
            guard pictureTypes.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let created = values.creationDate, created > since else { return nil }
            return (url, created)
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: Showing it

    private func show(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let panel = self.panel ?? makePanel()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let size = HeldShotView.size(for: image.size)
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.maxX - size.width - 14, y: visible.minY + 14, width: size.width, height: size.height), display: false)
        model.url = url
        model.image = image
        model.left = 1
        model.hovered = false
        model.shown = false
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(Self.ease(self.theme)) { self.model.shown = true }
        }
        ticking?.invalidate()
        let step = 1.0 / 20
        let timer = Timer(timeInterval: step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Held while it's pointed at, or being dragged.
                guard !self.model.hovered, !self.model.dragging else { return }
                self.model.left -= step / Self.held
                if self.model.left <= 0 { self.dismiss() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticking = timer
    }

    private func dismiss() {
        ticking?.invalidate()
        ticking = nil
        guard let panel, panel.isVisible else { return }
        withAnimation(Self.ease(theme)) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, !self.model.shown else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        model.theme = theme
        model.open = { [weak self] in
            guard let url = self?.model.url else { return }
            NSWorkspace.shared.open(url)
            self?.dismiss()
        }
        model.close = { [weak self] in self?.dismiss() }
        // Let go somewhere it landed: done with. Called off: held on, its time running again.
        model.dragged = { [weak self] landed in
            self?.model.dragging = false
            if landed { self?.dismiss() }
        }
        let host = NSHostingView(rootView: HeldShotView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    static func ease(_ theme: NotchTheme) -> Animation {
        theme == .midnight ? .timingCurve(0.45, 0, 0.25, 1, duration: 0.45) : .easeOut(duration: 0.22)
    }
}

@MainActor
final class HeldShotModel: ObservableObject {
    @Published var url: URL?
    @Published var image: NSImage?
    /// How much of its time's left, 1 to 0.
    @Published var left: Double = 1
    @Published var hovered = false
    @Published var dragging = false
    @Published var shown = false
    @Published var theme = NotchTheme.standard
    var open: () -> Void = {}
    var close: () -> Void = {}
    /// A drag of it's over: whether it landed anywhere.
    var dragged: (Bool) -> Void = { _ in }
}

/// Where a held screenshot's dragged from: told once it's let go, and whether it landed.
final class HeldShotDrag: NSObject, NSDraggingSource {
    static let shared = HeldShotDrag()
    var ended: @MainActor (Bool) -> Void = { _ in }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic, .link] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let landed = !operation.isEmpty
        MainActor.assumeIsolated { ended(landed) }
    }
}

/// The held thumbnail itself (see `ScreenshotHold`).
struct HeldShotView: View {
    @ObservedObject var model: HeldShotModel
    /// With its handle (to drag it, click it): left off only for a picture of it.
    var handled = true

    /// Its panel's size, for a picture of `size`: the picture fitted in 200 by 130, and room round it.
    static func size(for size: NSSize) -> NSSize {
        let fitted = fit(size)
        return NSSize(width: fitted.width + 24, height: fitted.height + 34)
    }

    static func fit(_ size: NSSize) -> NSSize {
        let scale = min(200 / max(size.width, 1), 130 / max(size.height, 1), 1)
        return NSSize(width: max(size.width * scale, 60), height: max(size.height * scale, 40))
    }

    var body: some View {
        let midnight = model.theme == .midnight
        let fitted = Self.fit(model.image?.size ?? NSSize(width: 200, height: 130))
        VStack(spacing: 7) {
            ZStack(alignment: .topLeading) {
                picture(midnight: midnight)
                    .frame(width: fitted.width, height: fitted.height)
                    .overlay { if handled { HeldShotHandle(model: model) } }
                if model.hovered {
                    Button(action: model.close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(midnight ? Midnight.ink : .black)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(midnight ? Midnight.silver : .white))
                            .shadow(color: .black.opacity(0.35), radius: 2)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: -6)
                    .transition(.opacity)
                }
            }
            timeLeft(midnight: midnight, width: fitted.width)
        }
        .padding(.top, 12)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(model.shown ? 1 : 0)
        .offset(x: model.shown ? 0 : 60)
        .blur(radius: midnight && !model.shown ? 6 : 0)
        .animation(.easeOut(duration: 0.15), value: model.hovered)
        .environment(\.notchTheme, model.theme)
    }

    @ViewBuilder private func picture(midnight: Bool) -> some View {
        if let image = model.image {
            if midnight {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .mask(RoundedRectangle(cornerRadius: 8, style: .continuous).blur(radius: 1.5))
                    .shadow(color: Midnight.moonlight.opacity(model.hovered ? 0.45 : 0.28), radius: 12)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            }
        }
    }

    /// How long it's still held: a bar running down in Oyl's look; in Midnight's, a hairline running
    /// down to a star.
    @ViewBuilder private func timeLeft(midnight: Bool, width: CGFloat) -> some View {
        let left = max(min(model.left, 1), 0)
        if midnight {
            HStack(spacing: 3) {
                Rectangle()
                    .fill(LinearGradient(colors: [Midnight.silver.opacity(0), Midnight.silver.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max((width - 10) * left, 0), height: 0.8)
                FourPointStar().fill(Midnight.starlight).frame(width: 6, height: 6)
                    .shadow(color: Midnight.moonlight.opacity(0.6), radius: 3)
            }
            .frame(width: width, alignment: .leading)
            .opacity(model.hovered ? 1 : 0.8)
        } else {
            Capsule().fill(Color.white.opacity(0.85))
                .frame(width: max(width * left, 3), height: 3)
                .frame(width: width, alignment: .leading)
                .shadow(color: .black.opacity(0.35), radius: 1.5)
        }
    }
}

/// The picture's handle: pressed and dragged, the file goes where it's dropped (as the shelf's
/// tiles do); clicked, it's opened. Pointed at, it's held.
private struct HeldShotHandle: NSViewRepresentable {
    @ObservedObject var model: HeldShotModel

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.model = model
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) { view.model = model }

    final class HandleView: NSView {
        var model: HeldShotModel?
        private var pressed: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { model?.hovered = true } }
        override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { model?.hovered = false } }

        override func mouseDown(with event: NSEvent) { pressed = event }

        override func mouseDragged(with event: NSEvent) {
            guard let pressed, let url = MainActor.assumeIsolated({ model?.url }) else { return }
            let from = pressed.locationInWindow, to = event.locationInWindow
            guard hypot(to.x - from.x, to.y - from.y) > 3 else { return }
            self.pressed = nil
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let picture = MainActor.assumeIsolated { model?.image } ?? NSWorkspace.shared.icon(forFile: url.path)
            item.setDraggingFrame(bounds, contents: picture)
            MainActor.assumeIsolated {
                model?.dragging = true
                let model = self.model
                HeldShotDrag.shared.ended = { landed in model?.dragged(landed) }
            }
            beginDraggingSession(with: [item], event: pressed, source: HeldShotDrag.shared)
        }

        override func mouseUp(with event: NSEvent) {
            if pressed != nil, event.clickCount <= 1 { MainActor.assumeIsolated { model?.open() } }
            pressed = nil
        }
    }
}
