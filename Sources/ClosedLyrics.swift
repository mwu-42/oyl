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
/// Each line's sung on the other side of the notch from the last, the first on the left: it fades
/// in faintly just before it's sung, then its words sparkle in one after another, each with a
/// glint, specks of light twinkling round them, while the last fades slowly away on its side. A
/// long line stretches as far along its side as it needs, shrinking only past nine tenths of it.
/// Where nothing's being sung, the song's own constellation pulses to the beat: both sides of
/// the notch in a break (and before the first line), the left for a song without lyrics. They
/// take no clicks. They come as soon as they're wanted and go once they haven't been for a
/// moment, so the gap between songs doesn't make them flicker; when the notch opens, straight away.
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

    /// Shows the song's lyrics (or, with none, its constellation: `seed` picks it) by the notch on
    /// `screen` while `wanted`, or hides them: at once if `opened` (the notch has opened over
    /// them, or the look's changed).
    func show(wanted: Bool, lyrics: Lyrics?, seed: String, on screen: NSScreen, metrics: NotchMetrics, opened: Bool) {
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
        place(on: screen, metrics: metrics)
        if model.lyrics?.trackID != lyrics?.trackID || model.seed != seed {
            model.lyrics = lyrics
            model.seed = seed
            model.swapped = Date()
        }
        guard !model.shown else { return }
        model.shown = true
        model.changed = Date()
        model.live = true
        panel.orderFrontRegardless()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + ClosedLyricsFrame.going + 0.05) { [weak self] in
            guard let self, !self.model.shown else { return }
            self.panel.orderOut(nil)
            self.model.live = false
            self.model.lyrics = nil
        }
    }

    /// Along the whole top of the screen, as deep as the menu bar's strip, the notch where it is.
    private func place(on screen: NSScreen, metrics: NotchMetrics) {
        let frame = CGRect(x: screen.frame.minX, y: screen.frame.maxY - metrics.size.height, width: screen.frame.width,
                           height: metrics.size.height)
        let notch = CGRect(x: metrics.centerX - screen.frame.minX - metrics.size.width / 2, y: 0, width: metrics.size.width,
                           height: metrics.size.height)
        if model.notch != notch { model.notch = notch }
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
    /// The song's lyrics; nil for one without (its constellation pulses instead), whose `seed` it is.
    @Published var lyrics: Lyrics?
    @Published var seed = ""
    /// When the song (or its lyrics) last changed, for what's new to come in.
    @Published var swapped = Date.distantPast
    /// Where the notch is in their window.
    @Published var notch = CGRect(origin: .zero, size: NotchMetrics.fallback.size)
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
                              fresh: context.date.timeIntervalSince(model.swapped), notch: model.notch,
                              beat: (Double(Beat.level), Beat.position(at: time)))
        }
        .allowsHitTesting(false)
    }
}

/// The lyrics by the notch at one moment: `position` seconds into the song (or, with no lyrics,
/// the constellation `seed` picks), `time` on Midnight's clock, `presence` of the way out from
/// behind the notch, `fresh` seconds since the song changed, the notch at `notch` in the frame
/// (the strip's whole width, the menu bar's depth), the music's bass `beat.level` and where it
/// is in the beat.
struct ClosedLyricsFrame: View {
    let lyrics: Lyrics?
    var seed = ""
    let position: Double
    let time: Double
    let presence: Double
    var fresh: Double = 10
    let notch: CGRect
    var beat: (level: Double, phase: Double?) = (0, nil)

    /// Between the notch and the words, and the words and the screen's edge.
    static let pad: CGFloat = 12
    /// How much of its side a line can take before it's shrunk to fit; and no smaller than this.
    static let stretch: CGFloat = 0.9, smallest: CGFloat = 0.6
    /// How long they take to come out from behind the notch, and to go back.
    static let coming = 0.7, going = 0.45
    /// How long a line fades in, faint, before it's sung; how long it takes to fade once the next
    /// is up; and, where a later one's coming in on its side, to make way.
    static let approach = 0.7, fading = 6.0, makingWay = 1.0
    /// How bright a line's words are before they sparkle in.
    static let faint: Double = 0.3

    /// How far out from behind the notch they are, `since` seconds after they were last `shown`
    /// or hidden.
    static func presence(shown: Bool, since: TimeInterval) -> Double {
        shown ? LyricsSkyFrame.ease(since / coming) : 1 - LyricsSkyFrame.ease(since / going)
    }

    /// 0 to 1, slower still at both ends than `ease`: for fading out.
    static func smoother(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * t * (t * (6 * t - 15) + 10)
    }

    var body: some View {
        Canvas { context, size in
            Self.draw(self, in: context, size: size)
        }
    }

    /// A line laid out to fit `room`: its words and their widths at full size, the gap between
    /// them, how much it's shrunk and how many words fit (any past that cut, with an ellipsis).
    struct Laid {
        var words: [GraphicsContext.ResolvedText] = []
        var widths: [CGFloat] = []
        var space: CGFloat = 0
        var scale: CGFloat = 1
        var fits = 0
        var ellipsis: GraphicsContext.ResolvedText?

        /// As wide as it's drawn.
        var width: CGFloat {
            let shown = widths.prefix(fits).reduce(0, +) + space * CGFloat(max(fits - 1, 0))
            return (shown + (ellipsis == nil ? 0 : space * 0.4 + 10)) * scale
        }
    }

    static func lay(_ text: String, size: CGFloat, room: CGFloat, in context: GraphicsContext) -> Laid {
        var laid = Laid()
        laid.words = LyricsSkyFrame.words(text).map {
            context.resolve(Text($0).font(Midnight.flourish(size)).foregroundStyle(Midnight.white))
        }
        laid.widths = laid.words.map { $0.measure(in: CGSize(width: 4000, height: 200)).width }
        laid.space = size * 0.3
        let full = laid.widths.reduce(0, +) + laid.space * CGFloat(max(laid.words.count - 1, 0))
        laid.scale = max(min(1, room / max(full, 1)), smallest)
        laid.fits = laid.words.count
        if full * laid.scale > room {
            laid.ellipsis = context.resolve(Text("…").font(Midnight.flourish(size)).foregroundStyle(Midnight.white))
            while laid.fits > 1 && laid.width > room { laid.fits -= 1 }
        }
        return laid
    }

    /// Which side of the notch `line` is sung on: the first with words (`first`) left, then
    /// right, and so on, each on the other side from the last.
    static func onLeft(_ line: Int, first: Int = 0) -> Bool {
        line >= first ? (line - first).isMultiple(of: 2) : false
    }

    static func draw(_ frame: ClosedLyricsFrame, in context: GraphicsContext, size: CGSize) {
        let presence = frame.presence, notch = frame.notch
        guard presence > 0 else { return }
        let bar = notch.height
        let room = (left: max(notch.minX - pad, 0), right: max(size.width - notch.maxX - pad, 0))
        let words = LyricsSkyFrame.ease((presence - 0.2) / 0.8) * LyricsSkyFrame.ease(frame.fresh / 0.6)
        // Out from behind the notch as they come, and back as they go.
        let hidden = CGFloat(1 - LyricsSkyFrame.ease(presence))
        let baseline = bar / 2 + 0.5

        // Each side's words only in the strip, past the notch's edge (behind which they slip as
        // they come and go), fading out toward the screen's edge.
        func side(left: Bool) -> GraphicsContext {
            var clipped = context
            let rect = left ? CGRect(x: 0, y: 0, width: notch.minX, height: bar)
                : CGRect(x: notch.maxX, y: 0, width: max(size.width - notch.maxX, 0), height: bar)
            let width = max(rect.width, 1), soft = min(24, width / 3) / width, inner = min(4, width / 6) / width
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
        func from(_ left: Bool) -> CGFloat { left ? notch.minX - pad : notch.maxX + pad }
        // Back toward the notch: rightward on the left, leftward on the right.
        func inward(_ left: Bool) -> CGFloat { left ? 1 : -1 }
        func stars(_ left: Bool, opacity: Double) {
            constellation(seed: frame.seed + (left ? "" : " right"), at: from(left), leftward: left, bar: bar, opacity: opacity,
                          shift: inward(left) * (constellationWidth + pad) * hidden, beat: frame.beat, time: frame.time,
                          in: left ? sides.left : sides.right)
        }

        guard let lyrics = frame.lyrics, !lyrics.lines.isEmpty else {
            // No lyrics: the song's constellation, pulsing to the beat, on the left.
            stars(true, opacity: words)
            return
        }
        let lines = lyrics.lines
        let index = lines.lastIndex { $0.time <= frame.position } ?? -1
        let since = index >= 0 ? frame.position - lines[index].time : 0
        let type = (bar * 0.43).rounded()
        let lingering = 1 - 0.4 * LyricsSkyFrame.ease((since - 9) / 3)
        let first = lines.firstIndex { $0.text != "♪" } ?? lines.count
        // A break (and the start, before the first line): stars on both sides; a line, its side.
        func isBreak(_ line: Int) -> Bool { line < first || lines[line].text == "♪" }
        func takes(_ line: Int, left: Bool) -> Bool { isBreak(line) || onLeft(line, first: first) == left }
        // When a line starts to come in: a little before it's sung.
        func arriving(_ line: Int) -> Double { lines[line].time - approach }

        // The line being sung, the one coming (faintly, just before it's sung), and the two before,
        // fading slowly; each on its side, making way for a later one coming in on it.
        for line in max(index - 2, -1)...min(index + 1, lines.count - 1) {
            for left in [true, false] where takes(line, left: left) {
                var opacity = words
                if line > index {
                    let ahead = lines[line].time - frame.position
                    guard ahead < approach else { continue }
                    opacity *= LyricsSkyFrame.ease((approach - ahead) / approach)
                } else if line < index {
                    opacity *= 1 - smoother((frame.position - lines[line + 1].time) / fading)
                } else {
                    opacity *= lingering
                }
                if let later = (line + 1..<index + 2).first(where: { lines.indices.contains($0) && takes($0, left: left) }) {
                    opacity *= 1 - smoother((frame.position - arriving(later)) / makingWay)
                }
                guard opacity > 0.01 else { continue }
                if isBreak(line) {
                    stars(left, opacity: opacity)
                    continue
                }
                let laid = lay(lines[line].text, size: type, room: stretch * (left ? room.left : room.right) - pad, in: context)
                let over = line < index ? smoother((frame.position - lines[line + 1].time) / fading) : 0
                write(laid, line: line, from: from(left), leading: !left, y: baseline, opacity: opacity,
                      lighting: line >= index ? (frame.position - lines[line].time, LyricsSkyFrame.spread(lines, line, words: laid.words.count)) : nil,
                      shift: inward(left) * (laid.width + pad) * hidden, blur: 1.4 * CGFloat(over), time: frame.time,
                      in: left ? sides.left : sides.right)
                if line == index {
                    specks(along: from(left), out: laid.width, leftward: left, bar: bar, strength: opacity, time: frame.time,
                           in: left ? sides.left : sides.right)
                }
            }
        }
    }

    /// `laid`'s words set out from `x` (rightward if `leading`, else leftward), centered on `y`,
    /// moved `shift` along, each bobbing a little; while `lighting` (how long since the line's
    /// time, negative before it, and how long its words take to light), faint till each in turn
    /// sparkles in, with a glint.
    private static func write(_ laid: Laid, line: Int, from x: CGFloat, leading: Bool, y: CGFloat, opacity: Double,
                              lighting: (since: Double, spread: Double)?, shift: CGFloat, blur: CGFloat = 0, time: Double,
                              in context: GraphicsContext) {
        guard opacity > 0.01, laid.fits > 0 else { return }
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
                glyph.opacity = faint + (1 - faint) * lit
                glyph.draw(laid.words[word], at: CGPoint(x: along, y: CGFloat(bob) + 1.5 * CGFloat(1 - lit)), anchor: .leading)
                // A glint as it sparkles in.
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

    /// How wide a constellation is.
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
