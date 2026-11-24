import AppKit
import SwiftUI

/// Whether an open app's asking for you, as one does by bouncing its icon in the macOS Dock (a
/// message come in, a download done): LaunchServices keeps it for each app (its
/// `LSWantsAttention`), and tells the Dock when it changes. Read from LaunchServices' own
/// functions (it has no public way in), out of the memory it shares with every app, so asking
/// after every app that's open takes a fraction of a millisecond.
enum AppAttention {
    private typealias MakeASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    /// The session everything open is in.
    private static let session: Int32 = -2
    private static let key = "LSWantsAttention" as CFString

    private static let functions: (makeASN: MakeASN, copyItem: CopyItem)? = {
        guard let services = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY),
              let makeASN = dlsym(services, "_LSASNCreateWithPid"),
              let copyItem = dlsym(services, "_LSCopyApplicationInformationItem") else { return nil }
        return (unsafeBitCast(makeASN, to: MakeASN.self), unsafeBitCast(copyItem, to: CopyItem.self))
    }()

    /// Whether LaunchServices can be asked (on a macOS that still has them).
    static var canTell: Bool { functions != nil }

    /// Whether the app `pid` is asking for you now.
    static func asks(_ pid: pid_t) -> Bool {
        guard let functions, let asn = functions.makeASN(nil, pid)?.takeRetainedValue(),
              let value = functions.copyItem(session, asn, key)?.takeRetainedValue() else { return false }
        return (value as? NSNumber)?.intValue ?? 0 != 0
    }

    /// Who's asking now (by their ids in the Dock), the first to ask first: those who were and are
    /// still open and not in front (so till you go to one, or it quits, even one that asked only
    /// for a moment, as most do, for the Dock's one bounce), then any newly asking that aren't in front.
    static func asking(before: [String], now: [String], open: Set<String>, front: String?) -> [String] {
        var asking = before.filter { open.contains($0) && $0 != front }
        for id in now where id != front && open.contains(id) && !asking.contains(id) { asking.append(id) }
        return asking
    }
}

/// A mark for an app asking for you, along the bottom edge under where its icon is in Oyl's Dock,
/// in place of the macOS Dock's icon bouncing up there: small, there till you go to it, its icon
/// popping up off it as it starts asking, and now and then after (see `AttentionPop`). In Oyl's
/// look, a little of the Dock come up out of the edge, black, flared into it, the app's own icon on it; in
/// Midnight Oyl's, its glyph traced in starlight just over the edge, out of a pool of night,
/// breathing, with a glint by it.
struct AttentionMark: View {
    let glyph: DockGlyph?
    let icon: NSImage
    /// Held at one point of its pop (for a picture of it).
    var lifted: AttentionPop.Lift?
    @Environment(\.notchTheme) private var theme

    static let tile: CGFloat = 20
    /// How tall it stands over the bottom edge.
    static let height: CGFloat = 26

    var body: some View {
        if theme == .midnight { traced } else { plain }
    }

    /// Midnight's glyph, traced; in Oyl's look, the app's own icon.
    private var picture: some View {
        Group {
            if theme == .midnight, let glyph {
                DockGlyphTile(glyph: glyph, tile: Self.tile, hovered: false, active: true)
            } else {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Self.tile, height: Self.tile)
            }
        }
    }

    private var plain: some View {
        let flare: CGFloat = 6
        return picture
            .modifier(AttentionPop(height: 9, after: 0.3, still: lifted))
            .padding(.horizontal, 4)
            .padding(.top, 3)
            .frame(height: Self.height, alignment: .top)
            .background {
                NotchShape(topRadius: flare, bottomRadius: 8)
                    .rotation(.degrees(180))
                    .fill(.black)
                    .padding(.horizontal, -flare)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: -1)
            }
    }

    private var traced: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            // A slow breath, and the glint by it twinkling out of step with it.
            let breath = 0.5 + 0.5 * sin(time * 2 * .pi / 3.2)
            let twinkle = 0.5 + 0.5 * sin(time * 2 * .pi / 2.3 + 1.1)
            picture
                .shadow(color: Midnight.moonlight.opacity(0.25 + 0.35 * breath), radius: 2 + 2 * breath)
                .overlay(alignment: .topTrailing) {
                    Sparkle(size: 2.5 + 1.2 * twinkle)
                        .fill(Midnight.starlight.opacity(0.55 + 0.45 * twinkle))
                        .frame(width: 8, height: 8)
                        .shadow(color: Midnight.moonlight.opacity(0.7), radius: 2)
                        .offset(x: 6, y: -5)
                }
                .modifier(AttentionPop(height: 8, after: 0.4, still: lifted))
                .padding(.top, 2)
                .frame(height: Self.height, alignment: .top)
                .background {
                    EllipticalGradient(colors: [Midnight.ink.opacity(0.75), Midnight.ink.opacity(0)], center: .center,
                                       startRadiusFraction: 0.15, endRadiusFraction: 0.5)
                        .frame(width: Self.tile * 2.6, height: Self.height * 1.8)
                        .offset(y: 4)
                }
        }
    }
}

/// An app's icon popping up while it's asking for you, as the macOS Dock's bounces, but less: two
/// low hops (`height`, then under half that) a moment (`after`) after it starts asking, or comes
/// into sight asking, and one lower hop each minute it's still asking. In Oyl's look, up and down
/// on a plain ease; in Midnight Oyl's, lifted slowly as if on the air and let down again, the
/// moonlight round it flaring at the top. Not while `active` is off.
struct AttentionPop: ViewModifier {
    var active = true
    let height: CGFloat
    var after: TimeInterval = 0.3
    /// Held at one point of a hop, rather than hopping (for a picture of it).
    var still: Lift?
    @StateObject private var pops = LocalState(Pops())
    @Environment(\.notchTheme) private var theme

    /// How long between the hops after the first.
    static let every: TimeInterval = 60

    /// How high it is, of `height`, and (Midnight Oyl's) how bright the moonlight round it.
    struct Lift: Equatable {
        var height: CGFloat = 0
        var glow: CGFloat = 0
    }

    /// Each pop, and whether it's the first since it started asking.
    struct Pops: Equatable {
        var count = 0
        var first = true
    }

    func body(content: Content) -> some View {
        let midnight = theme == .midnight
        if let still {
            lifted(content, still, midnight: midnight)
        } else {
            content
                .keyframeAnimator(initialValue: Lift(), trigger: pops.value) { view, lift in
                    lifted(view, lift, midnight: midnight)
                } keyframes: { _ in
                    Self.keyframes(midnight: midnight, first: pops.value.first)
                }
                .task(id: active) {
                    guard active else { return }
                    try? await Task.sleep(for: .seconds(after))
                    var first = true
                    while !Task.isCancelled {
                        pops.value = Pops(count: pops.value.count + 1, first: first)
                        first = false
                        try? await Task.sleep(for: .seconds(Self.every))
                    }
                }
        }
    }

    /// Lifted, and in Midnight Oyl, moonlight round it: a halo of its own behind it (a shadow over
    /// the glint's own would leave its edges in it).
    private func lifted(_ view: some View, _ lift: Lift, midnight: Bool) -> some View {
        view
            .background {
                if midnight, lift.glow > 0 {
                    Circle()
                        .fill(Midnight.moonlight.opacity(0.4 * lift.glow))
                        .scaleEffect(1.2)
                        .blur(radius: 6)
                }
            }
            .offset(y: -lift.height * height)
    }

    /// A pop: the first since it started asking two hops, the second under half the first; after
    /// that, one, lower.
    @KeyframesBuilder<Lift>
    static func keyframes(midnight: Bool, first: Bool) -> some Keyframes<Lift> {
        let (high, low): (CGFloat, CGFloat) = first ? (1, 0.42) : (0.6, 0)
        let up: UnitCurve = midnight ? .easeInOut : .easeOut, down: UnitCurve = midnight ? .easeInOut : .easeIn
        KeyframeTrack(\.height) {
            LinearKeyframe(high, duration: midnight ? 0.6 : 0.24, timingCurve: up)
            LinearKeyframe(0, duration: midnight ? 0.8 : 0.24, timingCurve: down)
            LinearKeyframe(low, duration: midnight ? 0.45 : 0.17, timingCurve: up)
            LinearKeyframe(0, duration: midnight ? 0.6 : 0.17, timingCurve: down)
        }
        KeyframeTrack(\.glow) {
            LinearKeyframe(midnight ? high : 0, duration: midnight ? 0.6 : 0.01, timingCurve: .easeInOut)
            LinearKeyframe(0, duration: midnight ? 1.2 : 0.01, timingCurve: .easeInOut)
        }
    }
}

/// On an app's icon in Oyl's Dock while it's asking for you: a dot, high on its right, in Oyl's
/// look; a glint, twinkling, in Midnight Oyl's.
struct AttentionBadge: View {
    let tile: CGFloat
    @Environment(\.notchTheme) private var theme

    /// Oyl's color for an app asking: a soft red, as the Dock's badges are.
    static let color = Color(red: 1, green: 0.38, blue: 0.33)

    var body: some View {
        if theme == .midnight {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let twinkle = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.3)
                Sparkle(size: 3.5 + 1.5 * twinkle)
                    .fill(theme.tint(Self.color, urgent: true).opacity(0.7 + 0.3 * twinkle))
                    .frame(width: 11, height: 11)
                    .shadow(color: Midnight.moonlight.opacity(0.6), radius: 2)
            }
            .offset(x: 3, y: -3)
        } else {
            Circle()
                .fill(Self.color)
                .frame(width: max(tile * 0.18, 7), height: max(tile * 0.18, 7))
                .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 1))
                .offset(x: 1, y: -1)
        }
    }
}
