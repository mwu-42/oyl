import SwiftUI

extension Midnight {
    /// How much further down the band reaches while the lyrics float in its sky.
    static let lyricsSky: CGFloat = 84
}

extension NotchState {
    /// Midnight Oyl floats the song's lyrics in the band's sky, under whichever page is up, rather
    /// than boxing them under the song: whenever they're on and the song has some.
    var floatsLyrics: Bool { theme == .midnight && showsLyrics && nowPlaying.lyrics != nil }
}

/// The lyrics in Midnight Oyl, drifting in the band's sky under the page as if they were
/// starlight: the line being sung in light italic, its words lighting one after another like
/// stars coming out, with a glint as each does and motes rising round it; the next line faint
/// and out of focus below and to the right, coming on; the one before rising off up to the
/// left, its words parting and floating away at their own paces and dissolving into stardust.
/// It all bobs and sways a little, word by word, and the lines lie along a gentle arc, as if
/// round an orbit far below. A break in the singing ("♪") is a little constellation, twinkling.
struct LyricsSky: View {
    let lyrics: Lyrics
    /// Read at each frame (the position's worked out from when it was last told, so there's
    /// nothing to watch).
    let nowPlaying: NowPlaying
    /// Where in the band they float.
    let area: CGRect
    /// How far they've come in with the page (and gone as it wilts).
    let shown: Double

    /// A touch early, as under the song, so a line's up as it's sung rather than just after.
    static let lead = 0.25

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: shown <= 0)) { context in
            LyricsSkyFrame(lyrics: lyrics, position: nowPlaying.position(at: context.date) + Self.lead,
                           time: MidnightBackdrop.clock)
        }
        .frame(width: area.width, height: area.height)
        .opacity(shown)
        .blur(radius: 8 * (1 - shown))
        .offset(y: 6 * (1 - shown))
        .position(x: area.midX, y: area.midY)
        .allowsHitTesting(false)
    }
}

/// The lyrics in the sky at one moment: `position` seconds into the song, `time` on the
/// backdrop's clock (which their drifting and twinkling go by).
struct LyricsSkyFrame: View {
    let lyrics: Lyrics
    let position: Double
    let time: Double

    var body: some View {
        Canvas { context, size in
            Self.draw(lyrics, at: position, time: time, in: context, size: size)
        }
    }

    /// The line being sung's type size; the others are set smaller.
    static let type: CGFloat = 21
    /// How far down the next line is, and how far right (the last, up and left).
    static let gap: CGFloat = 31, lean: CGFloat = 36
    /// How much smaller than the line being sung the others are.
    static let distant: CGFloat = 0.68

    static func draw(_ lyrics: Lyrics, at position: Double, time: Double, in context: GraphicsContext, size: CGSize) {
        let lines = lyrics.lines
        guard !lines.isEmpty else { return }
        let index = lines.lastIndex { $0.time <= position } ?? -1
        let since = index >= 0 ? position - lines[index].time : 0
        // How far the lines have moved up a place since this one began.
        let glide = index >= 0 ? ease(since / glideTime(lines, index)) : 1
        let drift = CGPoint(x: 7 * sin(time / 9.1), y: 4 * sin(time / 6.3 + 1))
        let middle = CGPoint(x: size.width / 2 + drift.x, y: size.height / 2 + drift.y)
        var singing: (rect: CGRect, strength: Double)?

        for line in max(index - 2, 0)...min(index + 2, lines.count - 1) {
            // 0 for the line being sung, 1 the next, -1 the last; in between as they move.
            let slot = Double(line - index) + (1 - glide)
            guard slot > -1.9, slot < 1.95 else { continue }
            let near = 1 - min(abs(slot), 1)
            let words = Self.words(lines[line].text)
            let set = words.map {
                SetWords.shared.word($0, kind: "lyric", size: Self.type, bound: CGSize(width: 2000, height: 200), in: context) {
                    Text($0).font(Midnight.flourish(Self.type)).foregroundStyle(Midnight.white)
                }
            }
            let resolved = set.map(\.text), widths = set.map(\.width)
            // Leaving, its words drift apart.
            let space = Self.type * 0.32 + (slot < 0 ? CGFloat(-slot) * 6 : 0)
            let breaking = words.isEmpty
            let width = breaking ? Self.breakWidth : widths.reduce(0, +) + space * CGFloat(max(words.count - 1, 0))
            let scale = (Self.distant + (1 - Self.distant) * CGFloat(near)) * min(1, (size.width - 40) / max(width, 1))
            let center = CGPoint(x: middle.x + CGFloat(slot) * Self.lean, y: middle.y + CGFloat(slot) * Self.gap)
            // A line held a long while (a long break after it, unmarked) dims a little as it waits.
            let lingering = line == index ? 1 - 0.4 * ease((since - 9) / 3) : 1

            var layer = context
            layer.opacity = opacity(at: slot) * lingering
            let blur = slot > 0 ? 1.6 * slot : 0.7 * -slot + 3 * max(-slot - 1, 0)
            if blur > 0.05 { layer.addFilter(.blur(radius: blur)) }
            // Whiter, not radiant: a faint moonlit haze round the line being sung.
            if near > 0.01 { layer.addFilter(.shadow(color: Midnight.moonlight.opacity(0.36 * near), radius: 5)) }
            layer.drawLayer { row in
                row.translateBy(x: center.x, y: center.y)
                row.scaleBy(x: scale, y: scale)
                if breaking {
                    interlude(line: line, slot: slot, time: time, in: row)
                    return
                }
                var x = -width / 2
                for (word, text) in resolved.enumerated() {
                    let seed = line &* 31 &+ word
                    let mid = x + widths[word] / 2
                    x += widths[word] + space
                    // Lit as it's sung: each word in turn, over the start of the line.
                    let litAt = Double(word) / Double(words.count) * spread(lines, line, words: words.count)
                    let lit = line < index ? 1 : line > index ? 0 : ease((since - litAt) / 0.45)
                    // Leaving, each word floats off at its own pace, and goes out on its own.
                    let away = CGFloat(max(-slot, 0))
                    let rise = away * CGFloat(5 + 9 * noise(seed, 1))
                    let out = slot < -0.8 ? 1 - ease((-slot - 0.8 - 0.5 * noise(seed, 2)) / 0.5) : 1
                    let bob = 1.7 * sin(time * 0.9 + Double(word) * 0.8 + Double(line) * 1.3)
                    let sway = 0.7 * sin(time * 0.55 + Double(word) * 1.9 + Double(line))
                    // On a gentle arc, as if round an orbit far below, each word tipped along it.
                    let arc = mid * mid / 6000, tilt = atan(Double(mid) / 3000)
                    var glyph = row
                    glyph.opacity = (0.42 + 0.58 * lit) * out
                    glyph.translateBy(x: mid + CGFloat(sway), y: arc + CGFloat(bob) - rise + 3 * CGFloat(1 - lit))
                    glyph.rotate(by: .radians(tilt + 0.012 * sin(time * 0.6 + Double(seed))))
                    glyph.draw(text, at: .zero, anchor: .center)
                    // A glint as it lights.
                    let glint = line == index ? bump((since - litAt) / 0.8) : 0
                    if glint > 0.01 {
                        var star = row
                        star.opacity = glint * 0.9
                        star.fill(sparkle(at: CGPoint(x: mid + widths[word] / 2 + 2, y: arc - Self.type * 0.42),
                                          radius: 2 + 3.5 * glint),
                                  with: .color(Midnight.starlight))
                    }
                }
            }
            let rect = CGRect(x: center.x - width * scale / 2, y: center.y - Self.type * scale / 2,
                              width: width * scale, height: Self.type * scale)
            if near > (singing?.strength ?? 0.3) { singing = (rect, near * lingering) }
            // Dissolving into stardust as it goes.
            if slot < -0.2 { shed(from: rect, line: line, progress: (-slot - 0.2) / 1.7, in: context) }
        }
        if let singing { motes(round: singing.rect, strength: singing.strength, time: time, in: context) }
    }

    /// A line's words; none for a break ("♪"), which is drawn as stars (`interlude`).
    static func words(_ text: String) -> [String] {
        text == "♪" ? [] : text.split(separator: " ").map(String.init)
    }

    /// How wide a break's stars are.
    static let breakWidth: CGFloat = 120

    /// A break in the singing: a little constellation along the arc, its stars joined by a faint
    /// dotted line, each twinkling at its own pace, the brightest slowly turning.
    static func interlude(line: Int, slot: Double, time: Double, in context: GraphicsContext) {
        let stars: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [(-58, 4, 2), (-31, -4, 3.6), (-4, 1, 1.4), (21, -7, 5.4), (54, 2, 2.6)]
        let away = CGFloat(max(-slot, 0))
        let places = stars.enumerated().map { star, at in
            CGPoint(x: at.x + CGFloat(0.8 * sin(time * 0.5 + Double(star))),
                    y: at.y + CGFloat(1.6 * sin(time * 0.8 + Double(star) * 1.4)) - away * CGFloat(6 + 8 * noise(line &* 7 &+ star, 1)))
        }
        var thread = context
        thread.opacity = 0.45
        var path = Path()
        path.addLines(places)
        thread.stroke(path, with: .color(Midnight.silver), style: StrokeStyle(lineWidth: 0.6, dash: [1.2, 2.6]))
        for (star, at) in stars.enumerated() {
            var glow = context
            glow.opacity = 0.55 + 0.45 * sin(time * (1.6 + 0.9 * noise(star, 4)) + Double(star) * 2.1)
            let place = places[star]
            if at.size >= 2 {
                var turned = glow
                turned.translateBy(x: place.x, y: place.y)
                turned.rotate(by: .radians(at.size > 4 ? time * 0.35 : 0))
                turned.fill(sparkle(at: .zero, radius: at.size * 1.6), with: .color(star == 3 ? Midnight.starlight : Midnight.white))
            }
            let dot = at.size * 0.45
            glow.fill(Path(ellipseIn: CGRect(x: place.x - dot, y: place.y - dot, width: 2 * dot, height: 2 * dot)), with: .color(Midnight.white))
        }
    }

    /// How long the lines take to move up a place when `index` begins: a second, or less for a
    /// line that's soon over, so they're in place before the next.
    static func glideTime(_ lines: [Lyrics.Line], _ index: Int) -> Double {
        guard lines.indices.contains(index + 1) else { return 1.1 }
        return min(max((lines[index + 1].time - lines[index].time) * 0.7, 0.25), 1.1)
    }

    /// How long a line's words take to all light: over the start of the line, quicker for a short one.
    static func spread(_ lines: [Lyrics.Line], _ index: Int, words: Int) -> Double {
        let length = lines.indices.contains(index + 1) ? lines[index + 1].time - lines[index].time : 4
        return min(length * 0.55, Double(words) * 0.22, 2)
    }

    /// How much of a line shows `slot` places from the one being sung.
    static func opacity(at slot: Double) -> Double {
        if slot >= 0 { return slot <= 1 ? 1 - 0.4 * slot : 0.6 * max(1 - (slot - 1) / 0.95, 0) }
        return slot >= -1 ? 1 + 0.7 * slot : 0.3 * max(1 - (-slot - 1) / 0.9, 0)
    }

    /// Motes round the line being sung, rising and twinkling, each coming back somewhere new
    /// along it when it's risen out.
    static func motes(round rect: CGRect, strength: Double, time: Double, in context: GraphicsContext) {
        for mote in 0..<18 {
            let period = 4.5 + 3 * noise(mote, 7)
            let turn = time / period + noise(mote, 8)
            let cycle = floor(turn), phase = turn - cycle
            let x = rect.minX - 16 + (rect.width + 32) * CGFloat(noise(mote, Int(cycle) &* 13 &+ 1))
            let y = rect.midY + 12 - CGFloat(phase) * 46 + 3 * CGFloat(sin(time * 1.3 + Double(mote)))
            let twinkle = 0.55 + 0.45 * sin(time * (3 + 4 * noise(mote, 9)) + Double(mote))
            var dot = context
            dot.opacity = sin(.pi * phase) * twinkle * 0.7 * strength
            let color = [Midnight.white, Midnight.moonlight, Midnight.starlight][mote % 3]
            if mote % 5 == 0 {
                dot.fill(sparkle(at: CGPoint(x: x, y: y), radius: 2.6), with: .color(color))
            } else {
                let radius = 0.6 + 1.1 * CGFloat(noise(mote, 10))
                dot.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)),
                         with: .color(color))
            }
        }
    }

    /// Stardust off a line that's going, `progress` of the way gone: motes scattering up and
    /// left from along it, fading as they go.
    static func shed(from rect: CGRect, line: Int, progress: Double, in context: GraphicsContext) {
        guard progress > 0, progress < 1 else { return }
        for mote in 0..<10 {
            let seed = line &* 17 &+ mote
            let start = 0.35 * noise(seed, 3)
            let along = min(max((progress - start) / (1 - start), 0), 1)
            guard along > 0 else { continue }
            let x = rect.minX + rect.width * CGFloat(noise(seed, 4)) - CGFloat(along) * CGFloat(10 + 20 * noise(seed, 5))
            let y = rect.midY - CGFloat(along) * CGFloat(14 + 22 * noise(seed, 6))
            var dot = context
            dot.opacity = sin(.pi * along) * 0.65
            let radius = 0.5 + CGFloat(noise(seed, 11))
            dot.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)),
                     with: .color(mote % 2 == 0 ? Midnight.silver : Midnight.starlight))
        }
    }

    /// A four-pointed star, its points thin.
    static func sparkle(at center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        let waist = radius * 0.22
        for point in 0..<4 {
            let angle = Double(point) * .pi / 2, between = angle + .pi / 4
            let tip = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
            let side = CGPoint(x: center.x + waist * CGFloat(cos(between)), y: center.y + waist * CGFloat(sin(between)))
            if point == 0 { path.move(to: tip) } else { path.addLine(to: tip) }
            path.addLine(to: side)
        }
        path.closeSubpath()
        return path
    }

    /// 0 to 1, slow at both ends.
    static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Up and back down over 0...1: quick up, slow away.
    static func bump(_ t: Double) -> Double {
        guard t > 0, t < 1 else { return 0 }
        return sin(.pi * pow(t, 0.6))
    }

    /// The same number in 0..<1 for the same two numbers.
    static func noise(_ a: Int, _ b: Int) -> Double {
        var z = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(b)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
