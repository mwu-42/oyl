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
/// in place of the macOS Dock's icon bouncing up there: small, and still, there till you go to it.
/// In Oyl's look, a little of the Dock come up out of the edge, black, flared into it, its icon on
/// it; in Midnight Oyl's, its glyph traced in starlight just over the edge, out of a pool of night,
/// breathing, with a glint by it.
struct AttentionMark: View {
    let glyph: DockGlyph?
    let icon: NSImage
    @Environment(\.notchTheme) private var theme

    static let tile: CGFloat = 20
    /// How tall it stands over the bottom edge.
    static let height: CGFloat = 26

    var body: some View {
        if theme == .midnight { traced } else { plain }
    }

    private var picture: some View {
        Group {
            if let glyph {
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
