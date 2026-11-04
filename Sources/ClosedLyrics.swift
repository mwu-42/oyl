import AppKit
import SwiftUI

extension NotchState {
    /// Midnight Oyl's lyrics are wanted by the closed notch now: that's on, the lyrics are, the
    /// song has some and is playing, and the notch is closed with nothing else beside it (open,
    /// it shows them itself).
    var wantsLyricsByNotch: Bool {
        theme == .midnight && showsLyricsClosed && showsLyrics && nowPlaying.lyrics != nil && nowPlaying.isPlaying
            && mode != .expanded && compact.isEmpty && !isResting && !isViewingDesktops
    }
}

/// Midnight Oyl's lyrics while the notch is closed, if that's on (it's off at first): up in the
/// menu bar's strip, in a black bar that grows out of either side of the notch as if the notch
/// had spread, its ends dissolving into the bar. The line being sung is right of the notch, its
/// words lighting one after another from the notch outward, each with a glint, specks of light
/// twinkling round them; as the next comes, it slips back in behind the notch and comes out the
/// other side, lingering faint on the left till it's pushed on and dissolves. A window of their own, which takes no clicks: what's under the bar still
/// works. They come in as soon as they're wanted, and go once they haven't been for a moment,
/// so the gap between songs doesn't make them flicker; when the notch opens, straight away.
@MainActor
final class ClosedLyrics {
    private let panel: NSPanel
    private let model = ClosedLyricsModel()
    private var hiding: DispatchWorkItem?
    private var placed: CGRect?

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

    /// Shows `lyrics` by the notch on `screen`, or, with none, hides them: at once if `opened`
    /// (the notch has opened over them, or the look's changed).
    func show(_ lyrics: Lyrics?, on screen: NSScreen, metrics: NotchMetrics, opened: Bool) {
        if opened { hideNow() }
        guard let lyrics, !opened else {
            guard model.shown, hiding == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hiding = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
            return
        }
        hiding?.cancel()
        hiding = nil
        place(on: screen, metrics: metrics)
        if model.lyrics?.trackID != lyrics.trackID { model.lyrics = lyrics }
        if model.notch != metrics.size { model.notch = metrics.size }
        guard !model.shown else { return }
        model.shown = true
        model.changed = Date()
        model.live = true
        panel.orderFrontRegardless()
    }

    /// Gone straight away (back into the notch, quickly).
    func hideNow() {
        hiding?.cancel()
        hide()
    }

    private func hide() {
        hiding = nil
        guard model.shown else { return }
        model.shown = false
        model.changed = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + ClosedLyricsFrame.going + 0.05) { [weak self] in
            guard let self, !self.model.shown else { return }
            self.panel.orderOut(nil)
            self.model.live = false
            self.model.lyrics = nil
        }
    }

    /// Across the top of the screen, centered on the notch, as deep as the menu bar's strip and
    /// a little more, for the bar's soft foot.
    private func place(on screen: NSScreen, metrics: NotchMetrics) {
        let size = ClosedLyricsFrame.size(notch: metrics.size)
        let frame = CGRect(x: (metrics.centerX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        guard placed != frame else { return }
        placed = frame
        panel.setFrame(frame, display: false)
    }
}

@MainActor
final class ClosedLyricsModel: ObservableObject {
    @Published var shown = false
    /// When they last came or started going.
    @Published var changed = Date.distantPast
    /// Their window's up (they're showing, or on their way out).
    @Published var live = false
    @Published var lyrics: Lyrics?
    @Published var notch = NotchMetrics.fallback.size
}

struct ClosedLyricsView: View {
    @ObservedObject var model: ClosedLyricsModel
    /// How far into the song it is at a moment.
    let position: (Date) -> Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.live)) { context in
            if let lyrics = model.lyrics {
                ClosedLyricsFrame(lyrics: lyrics, position: position(context.date) + LyricsSky.lead, time: MidnightBackdrop.clock,
                                  presence: ClosedLyricsFrame.presence(shown: model.shown, since: context.date.timeIntervalSince(model.changed)),
                                  notch: model.notch)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The bar and its lyrics at one moment: `position` seconds into the song, `time` on Midnight's
/// clock, `presence` of the way out of the notch, beside a notch of `notch`'s size (in the middle
/// of the top of the frame).
struct ClosedLyricsFrame: View {
    let lyrics: Lyrics
    let position: Double
    let time: Double
    let presence: Double
    let notch: CGSize

    /// How far either side of the notch the bar can reach for its line: right, the one being
    /// sung; left, the last. Then how long its ends take to fade out.
    static let reach = (right: CGFloat(400), left: CGFloat(300)), fade: CGFloat = 34
    /// Between the notch and the words, and the words and where the bar starts to fade.
    static let pad: CGFloat = 14
    /// How far the bar's foot fades out below the menu bar's strip.
    static let foot: CGFloat = 8
    /// How long it takes to come out of the notch, and to go back in.
    static let coming = 0.7, going = 0.45

    static func size(notch: CGSize) -> CGSize {
        CGSize(width: notch.width + 2 * (max(reach.right, reach.left) + fade), height: notch.height + foot)
    }

    /// How far out of the notch it is, `since` seconds after it was last `shown` or hidden.
    static func presence(shown: Bool, since: TimeInterval) -> Double {
        shown ? LyricsSkyFrame.ease(since / coming) : 1 - LyricsSkyFrame.ease(since / going)
    }

    var body: some View {
        Canvas { context, size in
            Self.draw(lyrics, at: position, time: time, presence: presence, notch: notch, in: context, size: size)
        }
    }

    /// A line laid out to fit `room`: its words and their widths at full size, the gap between
    /// them, how much it's shrunk (no smaller than 0.72) and how many words fit (the rest cut,
    /// with an ellipsis); or a break, drawn as stars.
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
            if breaking { return LyricsSkyFrame.breakWidth * scale }
            let shown = widths.prefix(fits).reduce(0, +) + space * CGFloat(max(fits - 1, 0))
            return (shown + (ellipsis == nil ? 0 : space * 0.4 + 10)) * scale
        }
    }

    static func lay(_ text: String, size: CGFloat, room: CGFloat, in context: GraphicsContext) -> Laid {
        var laid = Laid()
        let words = LyricsSkyFrame.words(text)
        guard !words.isEmpty else {
            laid.breaking = true
            laid.scale = 0.55
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

    static func draw(_ lyrics: Lyrics, at position: Double, time: Double, presence: Double, notch: CGSize,
                     in context: GraphicsContext, size: CGSize) {
        let lines = lyrics.lines
        guard !lines.isEmpty, presence > 0 else { return }
        let index = lines.lastIndex { $0.time <= position } ?? -1
        let since = index >= 0 ? position - lines[index].time : 0
        // How far the last line has slipped round behind the notch to the left, and this one come on.
        let glide = index >= 0 ? LyricsSkyFrame.ease(since / LyricsSkyFrame.glideTime(lines, index)) : 1
        let type = (notch.height * 0.43).rounded()
        let middle = size.width / 2, bar = notch.height
        let edges = (left: middle - notch.width / 2, right: middle + notch.width / 2)
        func laid(_ line: Int, room: CGFloat) -> Laid? {
            lines.indices.contains(line) ? lay(lines[line].text, size: type, room: room - 2 * pad, in: context) : nil
        }
        let sung = laid(index, room: reach.right), last = laid(index - 1, room: reach.right)
        let leftNow = laid(index - 1, room: reach.left), leftBefore = laid(index - 2, room: reach.left)
        // Each side reaches as far as its words need (moving from the last's to the next's), out of
        // the notch as it comes and back in as it goes.
        func wing(_ from: Laid?, _ to: Laid?) -> CGFloat {
            let a = from.map { $0.width + 2 * pad } ?? 0, b = to.map { $0.width + 2 * pad } ?? 0
            return (a + (b - a) * CGFloat(glide)) * CGFloat(presence)
        }
        let right = wing(last, sung), left = wing(leftBefore, leftNow)
        drawBar(left: left, right: right, edges: edges, bar: bar, in: context)

        let words = LyricsSkyFrame.ease((presence - 0.35) / 0.65)
        let lingering = 1 - 0.4 * LyricsSkyFrame.ease((since - 9) / 3)
        let baseline = bar / 2 + 0.5
        // Each side's words only on that side's bar: past the notch's edge (behind which they slip)
        // and no further out than the bar's come.
        var rightSide = context, leftSide = context
        rightSide.clip(to: Path(CGRect(x: edges.right, y: 0, width: right, height: bar)))
        leftSide.clip(to: Path(CGRect(x: edges.left - left, y: 0, width: left, height: bar)))
        // The last line slips back in behind the notch first; then this one comes on, out of it.
        let gone = CGFloat(LyricsSkyFrame.ease(glide / 0.55)), on = LyricsSkyFrame.ease((glide - 0.35) / 0.65)
        if let last, glide < 1 {
            write(last, line: index - 1, from: edges.right + pad, leading: true, y: baseline, opacity: words * (1 - 0.5 * glide),
                  lighting: nil, shift: -(last.width + pad) * gone, time: time, in: rightSide)
        }
        if let sung {
            write(sung, line: index, from: edges.right + pad, leading: true, y: baseline, opacity: words * on * lingering,
                  lighting: (since, LyricsSkyFrame.spread(lines, index, words: sung.words.count)), shift: 10 * CGFloat(1 - on),
                  time: time, in: rightSide)
        }
        // Left: the last line, come round from behind the notch, faint, pushing the one before it
        // on out, where it dissolves.
        if let leftNow {
            write(leftNow, line: index - 1, from: edges.left - pad, leading: false, y: baseline, opacity: words * 0.42,
                  lighting: nil, shift: (leftNow.width + pad) * CGFloat(1 - glide), blur: 0.5, time: time, in: leftSide)
        }
        if let leftBefore, glide < 1 {
            write(leftBefore, line: index - 2, from: edges.left - pad, leading: false, y: baseline,
                  opacity: words * 0.42 * (1 - glide), lighting: nil, shift: -((leftNow?.width ?? 0) + pad) * CGFloat(glide),
                  blur: 0.5 + 2 * CGFloat(glide),
                  time: time, in: leftSide)
        }
        specks(from: edges.right, out: right, bar: bar, strength: words * lingering, time: time, in: rightSide)
    }

    /// Black out of the notch either way, as far as `left` and `right` reach, then dissolving
    /// along its ends and its foot.
    private static func drawBar(left: CGFloat, right: CGFloat, edges: (left: CGFloat, right: CGFloat), bar: CGFloat,
                                in context: GraphicsContext) {
        guard left > 0.5 || right > 0.5 else { return }
        let from = edges.left - left - fade, to = edges.right + right + fade
        let width = max(to - from, 1)
        let stops: [Gradient.Stop] = [
            .init(color: .black.opacity(0), location: 0),
            .init(color: .black, location: min(fade / width, 0.5)),
            .init(color: .black, location: max(1 - fade / width, 0.5)),
            .init(color: .black.opacity(0), location: 1),
        ]
        let shading = GraphicsContext.Shading.linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: from, y: 0),
                                                             endPoint: CGPoint(x: to, y: 0))
        context.fill(Path(CGRect(x: from, y: 0, width: width, height: bar)), with: shading)
        // Its foot, fading down over the screen below in a few steps.
        for step in 0..<4 {
            var below = context
            below.opacity = 0.7 * (1 - Double(step) / 4)
            below.fill(Path(CGRect(x: from, y: bar + CGFloat(step) * foot / 4, width: width, height: foot / 4)), with: shading)
        }
    }

    /// `laid`'s words set out from `x` (rightward if `leading`, else leftward), centered on `y`,
    /// moved `shift` along, each bobbing a little; while `lighting` (how long the line's been up,
    /// and how long its words take to light), each in turn, with a glint.
    private static func write(_ laid: Laid, line: Int, from x: CGFloat, leading: Bool, y: CGFloat, opacity: Double,
                              lighting: (since: Double, spread: Double)?, shift: CGFloat, blur: CGFloat = 0, time: Double,
                              in context: GraphicsContext) {
        guard opacity > 0.01 else { return }
        var layer = context
        layer.opacity = opacity
        if blur > 0.05 { layer.addFilter(.blur(radius: blur)) }
        if lighting != nil { layer.addFilter(.shadow(color: Midnight.moonlight.opacity(0.4), radius: 4)) }
        let start = (leading ? x : x - laid.width) + shift
        layer.drawLayer { row in
            row.translateBy(x: start, y: y)
            row.scaleBy(x: laid.scale, y: laid.scale)
            if laid.breaking {
                var stars = row
                stars.translateBy(x: LyricsSkyFrame.breakWidth / 2, y: 0)
                LyricsSkyFrame.interlude(line: line, slot: 0, time: time, in: stars)
                return
            }
            var along: CGFloat = 0
            for word in 0..<laid.fits {
                let width = laid.widths[word]
                let litAt = lighting.map { Double(word) / Double(laid.words.count) * $0.spread } ?? 0
                let lit = lighting.map { LyricsSkyFrame.ease(($0.since - litAt) / 0.45) } ?? 1
                let bob = 0.8 * sin(time * 0.9 + Double(word) * 0.8 + Double(line) * 1.3)
                var glyph = row
                glyph.opacity = 0.42 + 0.58 * lit
                glyph.draw(laid.words[word], at: CGPoint(x: along, y: CGFloat(bob) + 2 * CGFloat(1 - lit)), anchor: .leading)
                if let lighting {
                    let glint = LyricsSkyFrame.bump((lighting.since - litAt) / 0.8)
                    if glint > 0.01 {
                        var star = row
                        star.opacity = glint * 0.9
                        star.fill(LyricsSkyFrame.sparkle(at: CGPoint(x: along + width + 1.5, y: -6), radius: 1.5 + 2.5 * glint),
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

    /// Specks of light twinkling in the bar round the line being sung, drifting slowly outward,
    /// each turning up somewhere new along it when it's gone.
    private static func specks(from edge: CGFloat, out: CGFloat, bar: CGFloat, strength: Double, time: Double,
                               in context: GraphicsContext) {
        guard out > 2 * pad, strength > 0.01 else { return }
        for speck in 0..<12 {
            let period = 3.5 + 3 * LyricsSkyFrame.noise(speck, 21)
            let turn = time / period + LyricsSkyFrame.noise(speck, 22)
            let cycle = floor(turn), phase = turn - cycle
            let x = edge + 6 + (out - 12) * CGFloat(LyricsSkyFrame.noise(speck, Int(cycle) &* 7 &+ 3)) + CGFloat(phase) * 8
            let y = bar * CGFloat(0.15 + 0.7 * LyricsSkyFrame.noise(speck, Int(cycle) &* 5 &+ 9))
            let twinkle = 0.5 + 0.5 * sin(time * (3 + 3 * LyricsSkyFrame.noise(speck, 23)) + Double(speck))
            var dot = context
            dot.opacity = sin(.pi * phase) * twinkle * 0.55 * strength
            let radius = 0.45 + 0.6 * CGFloat(LyricsSkyFrame.noise(speck, 24))
            dot.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)),
                     with: .color(speck % 3 == 0 ? Midnight.starlight : Midnight.silver))
        }
    }
}
