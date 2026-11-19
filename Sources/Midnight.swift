import AppKit
import CoreVideo
import Metal
import os
import SwiftUI

/// The notch's looks: Oyl's own (Gargoyle), or Midnight Oyl.
enum NotchTheme: String {
    case standard, midnight
}

/// Midnight Oyl: a second look for the notch, for display as much as use. A Victorian celestial
/// atlas plate, engraved in silver-white on deep night and seen through TouchDesigner's glass:
/// the notch is the celestial pole, with a star chart drawn round it, a planisphere and an orrery
/// set into its wings, and a moon that tells the time for a pin. It blooms out along the menu bar and down
/// into a band across the whole top of the screen, its foot flowing and dissolving into the
/// desktop with no edge to it. The camera isn't shown: your hands are, as a constellation in its
/// sky. Every word is set in a High Victorian face, and the Oyls on the menu bar are moyls,
/// planets in their colors, floating (see `Moyl`).
///
/// The pieces, each its own file: `MidnightBackdrop` (the sky, glass and edge, drawn by a Metal
/// shader), `MidnightTracking` (the hands' constellation) and `MidnightNotch` (the band that holds
/// them, the pages and the rest). The pages are Oyl's own, set in Midnight's type through `notchFont` and paled through
/// `NotchTheme.tint`.
enum Midnight {
    // MARK: Palette

    /// The near-black under everything, faintly blue.
    static let ink = Color(red: 0.014, green: 0.018, blue: 0.04)
    /// Type, star cores, the brightest lines.
    static let white = Color(red: 0.95, green: 0.96, blue: 0.98)
    /// Engraved lines, rules and ticks.
    static let silver = Color(red: 0.84, green: 0.87, blue: 0.93)
    /// The first pass's name for `white`.
    static let ivory = white
    /// Secondary readouts and faint rules.
    static let bone = Color(red: 0.7, green: 0.73, blue: 0.8)
    /// The one glow there is, faint, like moonlight.
    static let moonlight = Color(red: 0.8, green: 0.87, blue: 1)
    /// The first pass's name for `moonlight`.
    static let xray = moonlight
    /// The warm few: some stars, and the lamp that's lit when the bloom is pinned.
    static let starlight = Color(red: 1, green: 0.95, blue: 0.86)
    /// The Milky Way's mottling, barely there.
    static let nebula = Color(red: 0.74, green: 0.7, blue: 0.92)
    /// Chromatic aberration's fringes either side of a line: thin and pale.
    static let fringeRed = Color(red: 1, green: 0.7, blue: 0.76)
    static let fringeBlue = Color(red: 0.66, green: 0.78, blue: 1)
    /// TouchDesigner's operator families, by color (paled): textures, channels, geometry, data.
    static let top = Color(red: 0.8, green: 0.74, blue: 0.96)
    static let chop = Color(red: 0.76, green: 0.92, blue: 0.8)
    static let sop = Color(red: 0.74, green: 0.83, blue: 1)
    static let dat = Color(red: 0.95, green: 0.78, blue: 0.88)

    // MARK: Layout

    /// The open notch: a band across the whole top of the screen (see `NotchState.bloomSize`), as
    /// deep as this at most, clamped to the screen; and at least this deep, however short the page.
    static let bandDepth: CGFloat = 420
    static let shallowest: CGFloat = 250
    /// The sky the band leaves under the page, for the charts, the stars and the hands.
    static let sky: CGFloat = 120
    /// Room past the band's foot, below it, for what spills out of it: motes, drops, filaments;
    /// and for the foot to swell into. (None either side: the band reaches the screen's edges.)
    /// Drawn there, never hit there.
    static let overflow = (side: CGFloat(0), below: CGFloat(112))

    // MARK: Motion

    /// Opening, and growing to a taller page: slow, a sky drawing itself on rather than a panel
    /// dropping; easing in to rest, with no bounce past it.
    static let bloom = Animation.spring(response: 1.1, dampingFraction: 1)
    /// Oyl's Dock's sky coming up: quicker, being only a strip of it at the foot of the screen.
    static let dockBloom = Animation.spring(response: dockBloomResponse, dampingFraction: 1)
    static let dockBloomResponse = 0.55

    /// How long after it starts the Dock's sky has bloomed `fraction` of the way open: on its
    /// spring, critically damped, 1 − (1 + ωt)e^(−ωt).
    static func dockBloomTime(_ fraction: Double) -> Double {
        guard fraction > 0 else { return 0 }
        let fraction = min(fraction, 0.9999)
        var low = 0.0, high = 30.0
        for _ in 0..<40 {
            let x = (low + high) / 2
            if 1 - (1 + x) * exp(-x) < fraction { low = x } else { high = x }
        }
        return (low + high) / 2 * dockBloomResponse / (2 * .pi)
    }
    /// Shrinking to a shorter page: quicker, folding up.
    static let fold = Animation.spring(response: 0.6, dampingFraction: 0.92)
    /// The Dock's shelf card going back into the bar: quick.
    static let wilt = Animation.easeIn(duration: 0.35)
    /// Closing: the opening run back, nearly as slowly, the page going first and then the band
    /// folding back up into the notch, settling into it as it settled open. On the bloom's own
    /// curve (its critically damped spring's, to within 2%), but of a fixed length, so what waits
    /// for the band to be gone knows how long.
    static let closing = Animation.timingCurve(0.2, 0.1, 0.25, 1, duration: closingDuration)
    static let closingDuration = 0.9

    /// Where a point in the camera's picture (0...1 across and down, as it's shown: mirrored) lands
    /// in a view of `size` the picture fills, cropped to fit (the way both the camera view and the
    /// tracking over it draw it).
    static func place(_ point: CGPoint, camera aspect: CGFloat, in size: CGSize) -> CGPoint {
        let viewAspect = size.width / max(size.height, 1)
        if aspect > viewAspect {
            // Wider than the view: cropped at the sides.
            let width = size.height * aspect
            return CGPoint(x: point.x * width - (width - size.width) / 2, y: point.y * size.height)
        }
        let height = size.width / aspect
        return CGPoint(x: point.x * size.width, y: point.y * height - (height - size.height) / 2)
    }
}

extension Midnight {
    // MARK: Type

    /// What a piece of text is, for Midnight Oyl to set it in the face for that. (Oyl's own look
    /// sets it all in the system font.)
    enum TextRole {
        /// The inscription, and anything set large.
        case display
        /// Titles: the song, a page's heading, a popup's.
        case heading
        /// Reading text.
        case body
        /// Buttons, section labels, small capitals.
        case label
        /// Figures that tick: countdowns, the clock, time gone, percentages.
        case numerals
        /// Readouts, commands and paths, monospaced.
        case data

        /// The part a system font of this size and weight plays on the notch's pages.
        init(size: CGFloat, weight: Font.Weight, design: Font.Design, digits: Bool) {
            if design == .monospaced {
                self = .data
            } else if digits || design == .rounded {
                self = .numerals
            } else if size >= 22 {
                self = .display
            } else if Midnight.rank(weight) >= Midnight.rank(.semibold) {
                self = size >= 12.5 ? .heading : .label
            } else {
                self = .body
            }
        }
    }

    /// The face for `role`, given the size the system font would be set at there: each is scaled
    /// to take about the same room (Superclarendon runs wide; Georgia and Bodoni small).
    static func font(_ role: TextRole, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let bold = rank(weight) >= rank(.bold)
        switch role {
        case .display:
            let name = rank(weight) >= rank(.heavy) ? "Superclarendon-Black"
                : rank(weight) <= rank(.light) ? "Superclarendon-Light" : "Superclarendon-Bold"
            return face(name, size)
        case .heading:
            return face(bold ? "Superclarendon-Bold" : "Superclarendon-Regular", size * 0.92)
        case .body:
            return face(bold ? "Georgia-Bold" : "Georgia", size * 1.06)
        case .label:
            return face(bold ? "Copperplate-Bold" : size >= 13 ? "Copperplate-Light" : "Copperplate", size)
        case .numerals:
            let book = size >= 20 && rank(weight) < rank(.semibold)
            return face(book ? "BodoniSvtyTwoITCTT-Book" : "BodoniSvtyTwoITCTT-Bold", size * 1.08)
        case .data:
            return face("Courier-Bold", max(size, 6))
        }
    }

    /// How far apart `role`'s letters are set: copperplate capitals spaced out, the rest as drawn.
    static func tracking(_ role: TextRole, size: CGFloat) -> CGFloat {
        guard role == .label else { return 0 }
        return size * (size <= 10 ? 0.1 : size <= 12 ? 0.08 : 0.06)
    }

    /// Display: Superclarendon, for the inscription and anything set large.
    static func display(_ size: CGFloat) -> Font { font(.display, size: size) }
    /// Superclarendon's light italic: the flourish (the gesture's name, an aside).
    static func flourish(_ size: CGFloat) -> Font { face("Superclarendon-LightItalic", size) }
    static func heading(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { font(.heading, size: size, weight: weight) }
    /// Engraved capitals (Copperplate), for labels; lowercase comes out as small capitals.
    static func smallCaps(_ size: CGFloat) -> Font { font(.label, size: size) }
    /// Reading text: Georgia, a Scotch roman.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { font(.body, size: size, weight: weight) }
    static func italic(_ size: CGFloat) -> Font { face("Georgia-Italic", size * 1.06) }
    /// Figures that tick: Bodoni 72, whose digits are all one width.
    static func numerals(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font { font(.numerals, size: size, weight: weight) }
    /// Data readouts, TouchDesigner's way but typewritten: Courier, small, monospaced.
    static func data(_ size: CGFloat) -> Font { font(.data, size: size) }

    /// `name` at `size`, or the nearest face that's here if it isn't (looked for once).
    private static func face(_ name: String, _ size: CGFloat) -> Font {
        if missing.contains(name) {
            guard let stand = standIns[name] else { return .system(size: size, design: .serif) }
            return .custom(stand, fixedSize: size)
        }
        return .custom(name, fixedSize: size)
    }

    /// Faces in Midnight's roles that this Mac doesn't have. (Superclarendon is on disk but not in
    /// the font menus, so it's looked for by name.)
    private static let missing: Set<String> = Set(
        ["Superclarendon-Black", "Superclarendon-Light", "Superclarendon-Bold", "Superclarendon-Regular",
         "Superclarendon-LightItalic", "Georgia", "Georgia-Bold", "Georgia-Italic", "Copperplate", "Copperplate-Light",
         "Copperplate-Bold", "BodoniSvtyTwoITCTT-Book", "BodoniSvtyTwoITCTT-Bold", "Courier-Bold"]
            .filter { NSFont(name: $0, size: 12) == nil })

    private static let standIns = [
        "Superclarendon-Black": "BigCaslon-Medium", "Superclarendon-Light": "BigCaslon-Medium",
        "Superclarendon-Bold": "BigCaslon-Medium", "Superclarendon-Regular": "BigCaslon-Medium",
        "Superclarendon-LightItalic": "HoeflerText-Italic", "Georgia": "HoeflerText-Regular",
        "Georgia-Bold": "HoeflerText-Black", "Georgia-Italic": "HoeflerText-Italic",
        "Copperplate": "BodoniSvtyTwoSCITCTT-Book", "Copperplate-Light": "BodoniSvtyTwoSCITCTT-Book",
        "Copperplate-Bold": "BodoniSvtyTwoSCITCTT-Book", "BodoniSvtyTwoITCTT-Book": "Didot",
        "BodoniSvtyTwoITCTT-Bold": "Didot-Bold", "Courier-Bold": "CourierNewPS-BoldMT",
    ]

    /// Font weights in order, lightest first (they don't compare by themselves).
    static func rank(_ weight: Font.Weight) -> Int {
        weights.firstIndex(of: weight) ?? 3
    }
    private static let weights: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]

    // MARK: Accents

    /// Whiter, not radiant: `color` taken most of the way to the white of Midnight's type,
    /// keeping `keep` of it (and all its opacity), so its hue stays as a cast.
    static func pale(_ color: Color, keep: Double = 0.28) -> Color {
        Color(nsColor: pale(NSColor(color), keep: keep))
    }

    static func pale(_ color: NSColor, keep: Double = 0.28) -> NSColor {
        guard let color = color.usingColorSpace(.sRGB) else { return color }
        let keep = CGFloat(keep)
        func mix(_ white: CGFloat, _ value: CGFloat) -> CGFloat { white * (1 - keep) + value * keep }
        return NSColor(srgbRed: mix(0.95, color.redComponent), green: mix(0.96, color.greenComponent),
                       blue: mix(0.98, color.blueComponent), alpha: color.alphaComponent)
    }
}

extension NotchTheme {
    /// An accent as this look shows it: as it is in Oyl's own; in Midnight Oyl, paled toward its
    /// white (`Midnight.pale`). `urgent` keeps more of it, for what has to be seen: a timer
    /// ringing, an agent asking, bedtime.
    func tint(_ color: Color, urgent: Bool = false) -> Color {
        self == .midnight ? Midnight.pale(color, keep: urgent ? 0.42 : 0.28) : color
    }

    func tint(_ color: NSColor, urgent: Bool = false) -> NSColor {
        self == .midnight ? Midnight.pale(color, keep: urgent ? 0.42 : 0.28) : color
    }
}

private struct NotchThemeKey: EnvironmentKey {
    static let defaultValue = NotchTheme.standard
}

extension EnvironmentValues {
    /// Which look the notch is in, for the pages both looks share. NotchView sets it.
    var notchTheme: NotchTheme {
        get { self[NotchThemeKey.self] }
        set { self[NotchThemeKey.self] = newValue }
    }
}

extension Font {
    /// What `notchFont` sets, for where a modifier won't reach: a `Text` joined to another, a
    /// Canvas's text.
    static func notch(_ theme: NotchTheme, size: CGFloat, weight: Font.Weight = .regular,
                      design: Font.Design = .default, digits: Bool = false, role: Midnight.TextRole? = nil) -> Font {
        guard theme == .midnight else {
            let font = Font.system(size: size, weight: weight, design: design)
            return digits ? font.monospacedDigit() : font
        }
        let role = role ?? Midnight.TextRole(size: size, weight: weight, design: design, digits: digits)
        return Midnight.font(role, size: size, weight: weight)
    }
}

extension Text {
    /// `notchFont` for a `Text` (it stays one, so it can be joined to others).
    func notchFont(_ theme: NotchTheme, size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                   digits: Bool = false, role: Midnight.TextRole? = nil) -> Text {
        let text = font(.notch(theme, size: size, weight: weight, design: design, digits: digits, role: role))
        guard theme == .midnight else { return text }
        let role = role ?? Midnight.TextRole(size: size, weight: weight, design: design, digits: digits)
        return text.tracking(Midnight.tracking(role, size: size))
    }
}

extension View {
    /// Sets text the notch's way: in Oyl's own look, exactly `.system(size:weight:design:)` (with
    /// monospaced digits if `digits`); in Midnight Oyl, the Victorian face for its role, worked
    /// out from the rest if it isn't given.
    func notchFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                   digits: Bool = false, role: Midnight.TextRole? = nil) -> some View {
        modifier(NotchFont(size: size, weight: weight, design: design, digits: digits, role: role))
    }

    /// For an SF Symbol: the system font in both looks, drawn lighter in Midnight Oyl's (engraved,
    /// not inked).
    func notchSymbol(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(NotchSymbol(size: size, weight: weight))
    }
}

private struct NotchFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let digits: Bool
    let role: Midnight.TextRole?

    @Environment(\.notchTheme) private var theme

    func body(content: Content) -> some View {
        if theme == .midnight {
            let role = role ?? Midnight.TextRole(size: size, weight: weight, design: design, digits: digits)
            content
                .font(Midnight.font(role, size: size, weight: weight))
                .tracking(Midnight.tracking(role, size: size))
        } else {
            content.font(.notch(.standard, size: size, weight: weight, design: design, digits: digits))
        }
    }
}

extension View {
    /// A filled pill or capsule, the notch's way: in Oyl's own look, `fill` behind with `text` on
    /// it; in Midnight Oyl, a bright one (an accent, or white) is an outline in its paled tint,
    /// faintly filled, with its text in the tint and never black.
    func notchPill(_ fill: Color, text: Color, bright: Bool = true, urgent: Bool = false) -> some View {
        modifier(NotchPill(fill: fill, text: text, bright: bright, urgent: urgent))
    }
}

private struct NotchPill: ViewModifier {
    let fill: Color
    let text: Color
    let bright: Bool
    let urgent: Bool

    @Environment(\.notchTheme) private var theme

    func body(content: Content) -> some View {
        if theme == .midnight && bright {
            let tint = theme.tint(fill, urgent: urgent)
            content
                .foregroundStyle(tint)
                .background(Capsule().fill(tint.opacity(0.12)))
                .overlay(Capsule().strokeBorder(tint, lineWidth: 0.75))
        } else {
            content
                .foregroundStyle(text)
                .background(Capsule().fill(fill))
        }
    }
}

private struct NotchSymbol: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight

    @Environment(\.notchTheme) private var theme

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: theme == .midnight ? .light : weight))
    }
}

extension NotchState {
    /// The camera's own page, and its tab: Gargoyle's only. Midnight Oyl shows no picture, just
    /// the hands, always.
    var showsMirrorTab: Bool { showsMirror && theme != .midnight }
}

/// The camera's latest frame (mirrored, BGRA), handed from the camera's queue to whatever draws
/// it. Only fed while something's showing it (`isWanted`).
final class CameraFrames: @unchecked Sendable {
    static let shared = CameraFrames()

    // The lock's what makes the buffer safe to hand across (it isn't marked Sendable itself).
    private let state = OSAllocatedUnfairLock(uncheckedState: (buffer: CVPixelBuffer?.none, count: 0, wanted: false))

    /// Whether anything's drawing frames now; the camera skips handing them over otherwise.
    var isWanted: Bool {
        get { state.withLockUnchecked { $0.wanted } }
        set { state.withLockUnchecked { $0.wanted = newValue; if !newValue { $0.buffer = nil } } }
    }

    func publish(_ buffer: CVPixelBuffer) {
        state.withLockUnchecked {
            guard $0.wanted else { return }
            $0.buffer = buffer
            $0.count += 1
        }
    }

    /// The latest frame, and how many there have been (to tell a new one from the last).
    var latest: (buffer: CVPixelBuffer?, count: Int) {
        state.withLockUnchecked { ($0.buffer, $0.count) }
    }
}

/// One reading of the hands, for the tracking display: every joint the hand-pose model found,
/// and what Oyl makes of them.
struct HandTrack: Sendable {
    struct Joint: Sendable {
        /// The model's name for it: "thumbTip", "indexMCP", "wrist"…
        let name: String
        /// 0...1 across and down the picture, as it's shown (mirrored, top-left origin).
        let point: CGPoint
        let confidence: Float
    }

    /// Up to two hands, each its joints (21 when it's all in view).
    let hands: [[Joint]]
    /// The gesture it reads as, if any ("peace", "pinch"…), and how sure.
    let gesture: String?
    let certainty: Float?
    /// How long the model took on this frame, and how many frames it's reading a second.
    let modelTime: TimeInterval
    let rate: Double
    /// The picture's width over its height.
    let aspect: CGFloat
    /// When (`ProcessInfo.systemUptime`).
    let time: TimeInterval

    /// Which joints join which, for drawing bones: each finger from the wrist out.
    static let bones: [(String, String)] = {
        let fingers = [["thumbCMC", "thumbMP", "thumbIP", "thumbTip"], ["indexMCP", "indexPIP", "indexDIP", "indexTip"],
                       ["middleMCP", "middlePIP", "middleDIP", "middleTip"], ["ringMCP", "ringPIP", "ringDIP", "ringTip"],
                       ["littleMCP", "littlePIP", "littleDIP", "littleTip"]]
        return fingers.flatMap { finger in zip(["wrist"] + finger.dropLast(), finger).map { ($0, $1) } }
    }()
}

/// The latest `HandTrack`, from the camera's queue to the tracking display, which reads it as it
/// draws (so nothing re-renders for it).
final class HandTrackFeed: @unchecked Sendable {
    static let shared = HandTrackFeed()

    private let state = OSAllocatedUnfairLock<HandTrack?>(initialState: nil)

    func publish(_ track: HandTrack) { state.withLock { $0 = track } }
    func clear() { state.withLock { $0 = nil } }
    var latest: HandTrack? { state.withLock { $0 } }
}

/// Metal for Midnight Oyl's shaders. They're compiled when first needed, from source, since
/// there's no Xcode here to compile them ahead of time; each source once.
enum MidnightMetal {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()

    private static let libraries = OSAllocatedUnfairLock<[String: MTLLibrary]>(initialState: [:])

    /// The library built from `source`, compiled the first time it's asked for.
    static func library(_ source: String) throws -> MTLLibrary {
        if let library = libraries.withLock({ $0[source] }) { return library }
        guard let device else { throw MidnightError.noGPU }
        let library = try device.makeLibrary(source: source, options: nil)
        libraries.withLock { $0[source] = library }
        return library
    }

    enum MidnightError: Error {
        case noGPU
    }
}

/// Words as Midnight sets them, kept from frame to frame. Resolving a `Text` and measuring it (a
/// layout in Core Text) for every word of every line, 30 times a second, was most of what drawing
/// the lyrics cost, and the same word in the same type on the same screen comes out the same each
/// time. Only for type whose look never changes (`style` is always the same for a `kind`).
final class SetWords: @unchecked Sendable {
    static let shared = SetWords()
    /// Off, every word's resolved afresh, as before (for checking it makes no difference).
    var isOn = true

    private struct Key: Hashable {
        let kind: String, word: String, size: CGFloat, scale: CGFloat, bound: CGSize

        func hash(into hasher: inout Hasher) {
            hasher.combine(kind); hasher.combine(word); hasher.combine(size); hasher.combine(scale)
            hasher.combine(bound.width); hasher.combine(bound.height)
        }
    }
    private let lock = NSLock()
    private var kept: [Key: (text: GraphicsContext.ResolvedText, width: CGFloat)] = [:]

    /// `word` set as `style` has it (`kind` naming that style), resolved in `context`, and how
    /// wide it is measured in `bound`.
    func word(_ word: String, kind: String, size: CGFloat, bound: CGSize, in context: GraphicsContext,
              style: (String) -> Text) -> (text: GraphicsContext.ResolvedText, width: CGFloat) {
        func make() -> (text: GraphicsContext.ResolvedText, width: CGFloat) {
            let text = context.resolve(style(word))
            return (text: text, width: text.measure(in: bound).width)
        }
        guard isOn else { return make() }
        let key = Key(kind: kind, word: word, size: size, scale: context.environment.displayScale, bound: bound)
        lock.lock()
        if let found = kept[key] {
            lock.unlock()
            return found
        }
        lock.unlock()
        let made = make()
        lock.lock()
        // A song's worth of words and more, then start again.
        if kept.count > 800 { kept.removeAll(keepingCapacity: true) }
        kept[key] = made
        lock.unlock()
        return made
    }
}
