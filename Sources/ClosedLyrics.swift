import AppKit
import SwiftUI

extension NotchState {
    /// Midnight Oyl's lyrics are wanted by the closed notch now: that's on, the lyrics are, a song
    /// is playing (with lyrics or without: then its constellation pulses to the beat), and the
    /// notch is closed with nothing else beside it (open, it shows them itself).
    var wantsLyricsByNotch: Bool {
        theme == .midnight && showsLyricsClosed && showsLyrics && nowPlaying.isPlaying && !(nowPlaying.track?.isAudiobook ?? true)
            && mode != .expanded && compact.isEmpty && !isResting && !isViewingDesktops
    }
}

/// Midnight Oyl's lyrics while the notch is closed, if that's on (it's off at first): right up in
/// the menu bar's strip beside the notch, never below it, on no ground of their own (just stars).
/// Each line's sung on the other side of the notch from the last, the first on the left: its
/// words sparkling in one after another, each with a glint, specks of light twinkling round
/// them, while the last fades slowly away on its side. Where nothing's being sung (a song without lyrics, a break, the start before
/// the first line), the song's own constellation pulses to the beat instead. They keep to the
/// room either side of the notch that the app's menus and the menu bar's icons leave, and take no
/// clicks. They come as soon as they're wanted and go once they haven't been for a moment, so
/// the gap between songs doesn't make them flicker; when the notch opens, straight away.
@MainActor
final class ClosedLyrics {
    private let panel: NSPanel
    private let model = ClosedLyricsModel()
    private var hiding: DispatchWorkItem?
    private var placed: CGRect?
    private var screen: NSScreen?
    private var metrics = NotchMetrics.fallback
    private var fullscreen = false
    private var measuring: Timer?
    private var watching: NSObjectProtocol?

    /// How long they stay once they're not wanted.
    static let linger: TimeInterval = 1.5

    init(nowPlaying: NowPlaying) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Over the menu bar and its icons, under the notch's own window.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: ClosedLyricsView(model: model) { [weak nowPlaying] in nowPlaying?.position(at: $0) ?? 0 })
        host.sizingOptions = []
        panel.contentView = host
    }

    /// Shows the song's lyrics (or, with none, its constellation: `seed` picks it) by the notch on
    /// `screen` while `wanted`, or hides them: at once if `opened` (the notch has opened over
    /// them, or the look's changed).
    func show(wanted: Bool, lyrics: Lyrics?, seed: String, on screen: NSScreen, metrics: NotchMetrics, fullscreen: Bool,
              opened: Bool) {
        if opened { hideNow() }
        guard wanted, !opened else {
            guard model.shown, hiding == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hiding = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
            return
        }
        hiding?.cancel()
        hiding = nil
        let moved = self.screen != screen || self.metrics != metrics || self.fullscreen != fullscreen
        self.screen = screen
        self.metrics = metrics
        self.fullscreen = fullscreen
        place(on: screen, metrics: metrics)
        if model.lyrics?.trackID != lyrics?.trackID || model.seed != seed {
            model.lyrics = lyrics
            model.seed = seed
            model.swapped = Date()
        }
        if model.notch != metrics.size { model.notch = metrics.size }
        if moved { measure() }
        guard !model.shown else { return }
        model.shown = true
        model.changed = Date()
        model.live = true
        panel.orderFrontRegardless()
        startMeasuring()
    }

    /// Gone straight away (back behind the notch, quickly).
    func hideNow() {
        hiding?.cancel()
        hide()
    }

    private func hide() {
        hiding = nil
        guard model.shown else { return }
        model.shown = false
        model.changed = Date()
        stopMeasuring()
        DispatchQueue.main.asyncAfter(deadline: .now() + ClosedLyricsFrame.going + 0.05) { [weak self] in
            guard let self, !self.model.shown else { return }
            self.panel.orderOut(nil)
            self.model.live = false
            self.model.lyrics = nil
        }
    }

    /// Across the top of the screen, centered on the notch, as deep as the menu bar's strip.
    private func place(on screen: NSScreen, metrics: NotchMetrics) {
        let size = ClosedLyricsFrame.size(notch: metrics.size)
        let frame = CGRect(x: (metrics.centerX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        guard placed != frame else { return }
        placed = frame
        panel.setFrame(frame, display: false)
    }

    // MARK: The room beside the notch

    /// Measured now, and again whenever another app's menus take the bar, and every few seconds
    /// (icons come and go), while they're up.
    private func startMeasuring() {
        measure()
        measuring?.invalidate()
        let timer = Timer(timeInterval: 6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.measure() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        measuring = timer
        if watching == nil {
            watching = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
                // (The new app's menus are up a moment after it is.)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated { self?.measure() } }
            }
        }
    }

    private func stopMeasuring() {
        measuring?.invalidate()
        measuring = nil
        if let watching { NSWorkspace.shared.notificationCenter.removeObserver(watching) }
        watching = nil
    }

    /// The room left and right of the notch: from its edges out to the end of the app's menus and
    /// the start of the bar's icons. In a fullscreen app, with the bar out of the way, all of it.
    private func measure() {
        guard let screen else { return }
        let reach = ClosedLyricsFrame.reach, notch = metrics
        let edges = (left: notch.centerX - notch.size.width / 2, right: notch.centerX + notch.size.width / 2)
        guard !fullscreen else {
            setRoom((reach, reach))
            return
        }
        let icons = WalkerOverlay.menuBarIcons(on: screen.frame).map(\.span.lowerBound).filter { $0 > edges.right }.min()
        let right = min(max((icons ?? .greatestFiniteMagnitude) - MenuBarRoom.gap - edges.right, 0), reach)
        guard let pid = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier, AXIsProcessTrusted() else {
            // Without leave to look at the app's menus, a guess at where most end.
            setRoom((min(MenuBarRoom.guess, reach), right))
            return
        }
        Task.detached(priority: .userInitiated) {
            let end = MenuBarRoom.menusEnd(of: pid)
            await MainActor.run { [weak self] in
                let left = end.map { min(max(edges.left - MenuBarRoom.gap - $0, 0), reach) } ?? min(MenuBarRoom.guess, reach)
                self?.setRoom((left, right))
            }
        }
    }

    private func setRoom(_ room: (left: CGFloat, right: CGFloat)) {
        if model.room.left != room.left || model.room.right != room.right { model.room = room }
    }
}

/// Where the app's menus end along the menu bar (to keep lyrics off them).
enum MenuBarRoom {
    /// Kept between the lyrics and the menus or icons.
    static let gap: CGFloat = 14
    /// How far left of the notch they go without leave to look at the menus.
    static let guess: CGFloat = 180

    /// The right end of the menus of the app with `pid`, as the screen measures across (nil if
    /// they can't be read), asking it for at most a quarter of a second.
    nonisolated static func menusEnd(of pid: pid_t) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        var end: CGFloat?
        for item in items {
            var position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
            else { continue }
            var point = CGPoint.zero, extent = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &point)
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
            guard extent.width > 0 else { continue }
            end = max(end ?? 0, point.x + extent.width)
        }
        return end
    }
}

@MainActor
final class ClosedLyricsModel: ObservableObject {
    @Published var shown = false
    /// When they last came or started going.
    @Published var changed = Date.distantPast
    /// Their window's up (they're showing, or on their way out).
    @Published var live = false
    /// The song's lyrics; nil for one without (its constellation pulses instead), whose `seed` it is.
    @Published var lyrics: Lyrics?
    @Published var seed = ""
    /// When the song (or its lyrics) last changed, for what's new to come in.
    @Published var swapped = Date.distantPast
    @Published var notch = NotchMetrics.fallback.size
    /// How far they can go either side of the notch.
    @Published var room: (left: CGFloat, right: CGFloat) = (MenuBarRoom.guess, ClosedLyricsFrame.reach)
}

struct ClosedLyricsView: View {
    @ObservedObject var model: ClosedLyricsModel
    /// How far into the song it is at a moment.
    let position: (Date) -> Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.live)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ClosedLyricsFrame(lyrics: model.lyrics, seed: model.seed, position: position(context.date) + LyricsSky.lead,
                              time: MidnightBackdrop.clock,
                              presence: ClosedLyricsFrame.presence(shown: model.shown, since: context.date.timeIntervalSince(model.changed)),
                              fresh: context.date.timeIntervalSince(model.swapped), notch: model.notch, room: model.room,
                              beat: (Double(Beat.level), Beat.position(at: time)))
        }
        .allowsHitTesting(false)
    }
}

/// The lyrics by the notch at one moment: `position` seconds into the song (or, with no lyrics,
/// the constellation `seed` picks), `time` on Midnight's clock, `presence` of the way out from
/// behind the notch, `fresh` seconds since the song changed, beside a notch of `notch`'s size (in
/// the middle of the top of the frame) with `room` either side of it, the music's bass `beat.level`
/// and where it is in the beat.
struct ClosedLyricsFrame: View {
    let lyrics: Lyrics?
    var seed = ""
    let position: Double
    let time: Double
    let presence: Double
    var fresh: Double = 10
    let notch: CGSize
    let room: (left: CGFloat, right: CGFloat)
    var beat: (level: Double, phase: Double?) = (0, nil)

    /// The furthest either side of the notch they go, however much room there is.
    static let reach: CGFloat = 420
    /// Between the notch and the words.
    static let pad: CGFloat = 12
    /// How long they take to come out from behind the notch, and to go back.
    static let coming = 0.7, going = 0.45
    /// With less room than this on one side of the notch (an app with a lot of menus, say), every
    /// line goes on the other.
    static let tight: CGFloat = 110

    static func size(notch: CGSize) -> CGSize {
        CGSize(width: notch.width + 2 * reach, height: notch.height)
    }

    /// How far out from behind the notch they are, `since` seconds after they were last `shown`
    /// or hidden.
    static func presence(shown: Bool, since: TimeInterval) -> Double {
        shown ? LyricsSkyFrame.ease(since / coming) : 1 - LyricsSkyFrame.ease(since / going)
    }

    var body: some View {
        Canvas { context, size in
            Self.draw(self, in: context, size: size)
        }
    }

    /// A line laid out to fit `room`: its words and their widths at full size, the gap between
    /// them, how much it's shrunk (no smaller than 0.72) and how many words fit (the rest cut,
    /// with an ellipsis); or a break, where the constellation is.
    struct Laid {
        var words: [GraphicsContext.ResolvedText] = []
        var widths: [CGFloat] = []
        var space: CGFloat = 0
        var scale: CGFloat = 1
        var fits = 0
        var ellipsis: GraphicsContext.ResolvedText?
        var breaking = false

        /// As wide as it's drawn.
        var width: CGFloat {
            if breaking { return ClosedLyricsFrame.constellationWidth }
            let shown = widths.prefix(fits).reduce(0, +) + space * CGFloat(max(fits - 1, 0))
            return (shown + (ellipsis == nil ? 0 : space * 0.4 + 10)) * scale
        }
    }

    static func lay(_ text: String, size: CGFloat, room: CGFloat, in context: GraphicsContext) -> Laid {
        var laid = Laid()
        let words = LyricsSkyFrame.words(text)
        guard !words.isEmpty else {
            laid.breaking = true
            return laid
        }
        laid.words = words.map { context.resolve(Text($0).font(Midnight.flourish(size)).foregroundStyle(Midnight.white)) }
        laid.widths = laid.words.map { $0.measure(in: CGSize(width: 2000, height: 200)).width }
        laid.space = size * 0.3
        let full = laid.widths.reduce(0, +) + laid.space * CGFloat(words.count - 1)
        laid.scale = max(min(1, room / max(full, 1)), 0.72)
        laid.fits = words.count
        if full * laid.scale > room {
            laid.ellipsis = context.resolve(Text("…").font(Midnight.flourish(size)).foregroundStyle(Midnight.white))
            while laid.fits > 1 && laid.width > room { laid.fits -= 1 }
        }
        return laid
    }

    /// Which side of the notch `line` goes: the first with words (`first`) left, then right, and
    /// so on, each on the other side from the last (a break too, its constellation; what's before
    /// the first, right); or, with too little room on one side (an app with a lot of menus,
    /// say), all on the other.
    static func onLeft(_ line: Int, first: Int = 0, room: (left: CGFloat, right: CGFloat)) -> Bool {
        switch (room.left >= tight, room.right >= tight) {
        case (true, false): return true
        case (false, true): return false
        case (false, false): return room.left >= room.right
        case (true, true): return line >= first ? (line - first).isMultiple(of: 2) : false
        }
    }

    /// How long a line takes to fade once the next is being sung on the other side; and on the
    /// same side, where it has to make way.
    static let fading = 2.4, makingWay = 0.3

    static func draw(_ frame: ClosedLyricsFrame, in context: GraphicsContext, size: CGSize) {
        let presence = frame.presence, notch = frame.notch, room = frame.room
        guard presence > 0 else { return }
        let middle = size.width / 2, bar = notch.height
        let edges = (left: middle - notch.width / 2, right: middle + notch.width / 2)
        let words = LyricsSkyFrame.ease((presence - 0.2) / 0.8) * LyricsSkyFrame.ease(frame.fresh / 0.6)
        // Out from behind the notch as they come, and back as they go.
        let hidden = CGFloat(1 - LyricsSkyFrame.ease(presence))
        let baseline = bar / 2 + 0.5

        // Each side's words only in the strip, in that side's room: past the notch's edge (behind
        // which they slip as they come and go), and fading out toward its far end.
        func side(left: Bool) -> GraphicsContext {
            let width = left ? room.left : room.right
            var clipped = context
            let rect = left ? CGRect(x: edges.left - width, y: 0, width: width, height: bar)
                : CGRect(x: edges.right, y: 0, width: width, height: bar)
            let soft = min(22, width / 3) / max(width, 1), inner = min(4, width / 6) / max(width, 1)
            let stops: [Gradient.Stop] = left
                ? [.init(color: .clear, location: 0), .init(color: .white, location: soft),
                   .init(color: .white, location: 1 - inner), .init(color: .clear, location: 1)]
                : [.init(color: .clear, location: 0), .init(color: .white, location: inner),
                   .init(color: .white, location: 1 - soft), .init(color: .clear, location: 1)]
            clipped.clipToLayer { mask in
                mask.fill(Path(rect), with: .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: rect.minX, y: 0),
                                                            endPoint: CGPoint(x: rect.maxX, y: 0)))
            }
            return clipped
        }
        let sides = (left: side(left: true), right: side(left: false))
        // Set from the notch outward: leftward on the left (ending at the notch), rightward on the right.
        func from(_ left: Bool) -> CGFloat { left ? edges.left - pad : edges.right + pad }
        // Back toward the notch: rightward on the left, leftward on the right.
        func inward(_ left: Bool) -> CGFloat { left ? 1 : -1 }

        guard let lyrics = frame.lyrics, !lyrics.lines.isEmpty else {
            // No lyrics: the song's constellation, pulsing to the beat, on the left.
            constellation(seed: frame.seed, at: from(true), leftward: true, bar: bar, opacity: words,
                          shift: (constellationWidth + pad) * hidden, beat: frame.beat, time: frame.time, in: sides.left)
            return
        }
        let lines = lyrics.lines
        let index = lines.lastIndex { $0.time <= frame.position } ?? -1
        let since = index >= 0 ? frame.position - lines[index].time : 0
        let type = (bar * 0.43).rounded()
        let lingering = 1 - 0.4 * LyricsSkyFrame.ease((since - 9) / 3)
        let first = lines.firstIndex { $0.text != "♪" } ?? 0
        func onLeft(_ line: Int) -> Bool { Self.onLeft(line, first: first, room: room) }

        // The line being sung, and the two before it, fading (the start before the first counts as
        // a line, as a break does: the constellation's there). Each its own side.
        for line in max(index - 2, -1)...index {
            let left = onLeft(line)
            let width = left ? room.left : room.right
            let laid = line >= 0 ? lay(lines[line].text, size: type, room: width - 2 * pad, in: context) : nil
            let into = left ? sides.left : sides.right
            var opacity = words
            if line < index {
                // Done: fading slowly once the next is up; quickly, where a later one's on its side.
                let over = frame.position - lines[line + 1].time
                opacity *= 1 - LyricsSkyFrame.ease(over / fading)
                if let later = ((line + 1)...index).first(where: { onLeft($0) == left }) {
                    opacity *= 1 - LyricsSkyFrame.ease((frame.position - lines[later].time) / makingWay)
                }
                opacity *= 0.8
            } else {
                opacity *= lingering
            }
            guard opacity > 0.01 else { continue }
            let drawnWidth = laid.map { $0.width } ?? constellationWidth
            let shift = inward(left) * (drawnWidth + pad) * hidden
            if let laid, !laid.breaking {
                let over = line < index ? CGFloat(frame.position - lines[line + 1].time) : 0
                write(laid, line: line, from: from(left), leading: !left, y: baseline, opacity: opacity,
                      lighting: line == index ? (since, LyricsSkyFrame.spread(lines, index, words: laid.words.count)) : nil,
                      shift: shift, blur: min(over / CGFloat(fading), 1) * 1.6, time: frame.time, in: into)
                if line == index {
                    specks(along: from(left), out: laid.width, leftward: left, bar: bar, strength: opacity, time: frame.time, in: into)
                }
            } else {
                constellation(seed: frame.seed, at: from(left), leftward: left, bar: bar, opacity: opacity, shift: shift,
                              beat: frame.beat, time: frame.time, in: into)
            }
        }
    }

    /// `laid`'s words set out from `x` (rightward if `leading`, else leftward), centered on `y`,
    /// moved `shift` along, each bobbing a little; while `lighting` (how long the line's been up,
    /// and how long its words take to light), each in turn, with a glint.
    private static func write(_ laid: Laid, line: Int, from x: CGFloat, leading: Bool, y: CGFloat, opacity: Double,
                              lighting: (since: Double, spread: Double)?, shift: CGFloat, blur: CGFloat = 0, time: Double,
                              in context: GraphicsContext) {
        guard opacity > 0.01, !laid.breaking else { return }
        var layer = context
        layer.opacity = opacity
        if blur > 0.05 { layer.addFilter(.blur(radius: blur)) }
        if lighting != nil { layer.addFilter(.shadow(color: Midnight.moonlight.opacity(0.4), radius: 4)) }
        let start = (leading ? x : x - laid.width) + shift
        layer.drawLayer { row in
            row.translateBy(x: start, y: y)
            row.scaleBy(x: laid.scale, y: laid.scale)
            var along: CGFloat = 0
            for word in 0..<laid.fits {
                let width = laid.widths[word]
                let litAt = lighting.map { Double(word) / Double(laid.words.count) * $0.spread } ?? 0
                let lit = lighting.map { LyricsSkyFrame.ease(($0.since - litAt) / 0.45) } ?? 1
                let bob = 0.7 * sin(time * 0.9 + Double(word) * 0.8 + Double(line) * 1.3)
                var glyph = row
                glyph.opacity = 0.42 + 0.58 * lit
                glyph.draw(laid.words[word], at: CGPoint(x: along, y: CGFloat(bob) + 1.5 * CGFloat(1 - lit)), anchor: .leading)
                // A glint as it lights.
                if let lighting {
                    let glint = LyricsSkyFrame.bump((lighting.since - litAt) / 0.8)
                    if glint > 0.01 {
                        var star = row
                        star.opacity = glint * 0.9
                        star.fill(LyricsSkyFrame.sparkle(at: CGPoint(x: along + width + 1.5, y: -5), radius: 1.5 + 2.5 * glint),
                                  with: .color(Midnight.starlight))
                    }
                }
                along += width + laid.space
            }
            if let ellipsis = laid.ellipsis {
                var glyph = row
                glyph.opacity = 0.6
                glyph.draw(ellipsis, at: CGPoint(x: along - laid.space * 0.6, y: 0), anchor: .leading)
            }
        }
    }

    /// How wide the constellation is.
    static let constellationWidth: CGFloat = 132

    /// The song's constellation (the same for the same `seed`): seven stars across the strip,
    /// joined by a faint dotted line, set out from `x` (leftward or not) and moved `shift` along.
    /// On each beat its brightest star flares and the light runs along the line out from it, the
    /// stars swelling with the bass; without a steady beat to go by, just the bass, or a slow
    /// breath when there's none to hear.
    static func constellation(seed: String, at x: CGFloat, leftward: Bool, bar: CGFloat, opacity: Double, shift: CGFloat,
                              beat: (level: Double, phase: Double?), time: Double, in context: GraphicsContext) {
        guard opacity > 0.01 else { return }
        let stars = constellationStars(seed: seed, bar: bar)
        let origin = (leftward ? x - constellationWidth : x) + shift
        let places = stars.map { CGPoint(x: origin + $0.x, y: $0.y + CGFloat(0.6 * sin(time * 0.8 + Double($0.x)))) }
        let brightest = stars.indices.max { stars[$0].size < stars[$1].size } ?? 0
        let through = beat.phase.map { $0 - floor($0) }
        // How hard the beat's hitting: just after one, most; the bass, as it swells; or breathing.
        let kick = through.map { exp(-$0 * 4.5) } ?? 0
        let swell = beat.phase == nil && beat.level < 0.02 ? 0.25 + 0.25 * sin(time * 1.6) : beat.level
        let pulse = min(max(0.7 * kick + 0.6 * swell, 0), 1)
        var thread = context
        thread.opacity = opacity * (0.35 + 0.35 * pulse)
        var path = Path()
        path.addLines(places)
        thread.stroke(path, with: .color(Midnight.silver), style: StrokeStyle(lineWidth: 0.6, dash: [1.2, 2.6]))
        for (index, star) in stars.enumerated() {
            // The light running out along the line from the brightest, a star a tenth of a beat.
            let away = Double(abs(index - brightest))
            let run = through.map { exp(-pow(($0 * 10 - away) * 0.9, 2)) } ?? 0
            let twinkle = 0.75 + 0.25 * sin(time * (1.8 + 0.9 * LyricsSkyFrame.noise(index, 31)) + Double(index) * 2.1)
            let lift = index == brightest ? pulse : 0.45 * pulse + 0.55 * run
            var glow = context
            glow.opacity = opacity * min(twinkle * (0.5 + 0.5 * lift), 1)
            let radius = star.size * CGFloat(1 + 0.8 * lift)
            let place = places[index]
            if star.size >= 1.6 {
                var turned = glow
                turned.translateBy(x: place.x, y: place.y)
                turned.rotate(by: .radians(index == brightest ? time * 0.3 : 0))
                turned.fill(LyricsSkyFrame.sparkle(at: .zero, radius: min(radius * 1.7, bar / 2 - 3)),
                            with: .color(index == brightest ? Midnight.starlight : Midnight.white))
            }
            let dot = radius * 0.5
            glow.fill(Path(ellipseIn: CGRect(x: place.x - dot, y: place.y - dot, width: 2 * dot, height: 2 * dot)), with: .color(Midnight.white))
        }
    }

    /// The constellation's stars, across its width and within the strip, the same for the same
    /// `seed`: where each is from its left, and how big.
    static func constellationStars(seed: String, bar: CGFloat) -> [(x: CGFloat, y: CGFloat, size: CGFloat)] {
        let base = seed.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }
        let count = 7
        return (0..<count).map { star in
            let x = constellationWidth * (CGFloat(star) + 0.5 + 0.7 * CGFloat(LyricsSkyFrame.noise(base, star * 3) - 0.5)) / CGFloat(count)
            let y = bar * (0.28 + 0.44 * CGFloat(LyricsSkyFrame.noise(base, star * 3 + 1)))
            let size = 1.1 + 1.8 * CGFloat(pow(LyricsSkyFrame.noise(base, star * 3 + 2), 2))
            return (x, y, size)
        }
    }

    /// Specks of light twinkling round the line being sung (`out` wide, from `edge`, leftward or
    /// not), each turning up somewhere new along it when it's gone.
    private static func specks(along edge: CGFloat, out: CGFloat, leftward: Bool, bar: CGFloat, strength: Double, time: Double,
                               in context: GraphicsContext) {
        guard out > 12, strength > 0.01 else { return }
        for speck in 0..<12 {
            let period = 3.5 + 3 * LyricsSkyFrame.noise(speck, 21)
            let turn = time / period + LyricsSkyFrame.noise(speck, 22)
            let cycle = floor(turn), phase = turn - cycle
            let across = 4 + (out - 8) * CGFloat(LyricsSkyFrame.noise(speck, Int(cycle) &* 7 &+ 3)) + CGFloat(phase) * 6
            let x = leftward ? edge - across : edge + across
            let y = bar * CGFloat(0.12 + 0.76 * LyricsSkyFrame.noise(speck, Int(cycle) &* 5 &+ 9))
            let twinkle = 0.5 + 0.5 * sin(time * (3 + 3 * LyricsSkyFrame.noise(speck, 23)) + Double(speck))
            var dot = context
            dot.opacity = sin(.pi * phase) * twinkle * 0.6 * strength
            let radius = 0.45 + 0.6 * CGFloat(LyricsSkyFrame.noise(speck, 24))
            dot.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)),
                     with: .color(speck % 3 == 0 ? Midnight.starlight : Midnight.silver))
        }
    }
}
