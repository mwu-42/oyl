import AppKit
import SwiftUI

extension NotchState {
    /// The lyrics are wanted under the closed notch now: that's on, the lyrics are, the song has
    /// some and is playing, and the notch is closed (open, it shows them itself).
    var wantsLyricsUnderNotch: Bool {
        showsLyricsClosed && showsLyrics && nowPlaying.lyrics != nil && nowPlaying.isPlaying && mode != .expanded && !isResting
    }
}

/// The lyrics while the notch is closed, if that's on (it's off at first): in a window of their
/// own just under the notch, which takes no clicks, so whatever's under them works as ever. In
/// Midnight Oyl they float as they do in the band's sky (`LyricsSkyFrame`), over a soft dark haze
/// with no edge to it so they read over anything; in Gargoyle, the three lines the music page
/// shows, on a dark card. They come in as soon as they're wanted, and go once they haven't been
/// for a moment, so the gap between songs doesn't make them flicker.
@MainActor
final class ClosedLyrics {
    private let panel: NSPanel
    private let model = ClosedLyricsModel()
    private var hiding: DispatchWorkItem?
    private var placed: (theme: NotchTheme, metrics: NotchMetrics, frame: CGRect)?

    /// How big their window is in each look.
    static func size(_ theme: NotchTheme) -> CGSize {
        theme == .midnight ? CGSize(width: 600, height: 132) : CGSize(width: 440, height: 96)
    }

    /// How long they stay once they're not wanted.
    static let linger: TimeInterval = 1.5

    init(nowPlaying: NowPlaying) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Under the notch's own window and the Oyls' (whose speech bubbles hang over them).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: ClosedLyricsView(model: model, accent: { [weak nowPlaying] in nowPlaying?.accent ?? .white }) {
            [weak nowPlaying] in nowPlaying?.position(at: $0) ?? 0
        })
        host.sizingOptions = []
        panel.contentView = host
    }

    /// Shows `lyrics` under the notch on `screen` (in `theme`), or, with none, hides them; at
    /// once if the notch has opened over them (Midnight's glass would show them through it) or
    /// the look's changed.
    func show(_ lyrics: Lyrics?, theme: NotchTheme, on screen: NSScreen, metrics: NotchMetrics, opened: Bool) {
        if opened || (model.shown && theme != model.theme) { hideNow() }
        guard let lyrics, !opened else {
            guard model.shown, hiding == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hiding = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
            return
        }
        hiding?.cancel()
        hiding = nil
        place(theme: theme, on: screen, metrics: metrics)
        if model.lyrics?.trackID != lyrics.trackID { model.lyrics = lyrics }
        if model.theme != theme { model.theme = theme }
        guard !model.shown else { return }
        // The window fades (the glass with it), and what's in it drifts in.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        fade(to: 1, over: 0.6)
        withAnimation(.easeOut(duration: 0.6)) { model.shown = true }
    }

    /// Gone at once (Oyl's resting, say).
    func hideNow() {
        hiding?.cancel()
        hide()
    }

    private func hide() {
        hiding = nil
        guard model.shown else { return }
        fade(to: 0, over: 0.45)
        withAnimation(.easeIn(duration: 0.45)) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.model.shown else { return }
            self.panel.orderOut(nil)
            self.model.lyrics = nil
        }
    }

    private func fade(to alpha: CGFloat, over duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        }
    }

    /// Centered under the notch, just below the menu bar.
    private func place(theme: NotchTheme, on screen: NSScreen, metrics: NotchMetrics) {
        let size = Self.size(theme)
        let gap: CGFloat = theme == .midnight ? 0 : 5
        let frame = CGRect(x: (metrics.centerX - size.width / 2).rounded(), y: screen.frame.maxY - metrics.size.height - gap - size.height,
                           width: size.width, height: size.height)
        if let placed, placed.theme == theme, placed.metrics == metrics, placed.frame == frame { return }
        placed = (theme, metrics, frame)
        panel.setFrame(frame, display: false)
    }
}

@MainActor
final class ClosedLyricsModel: ObservableObject {
    @Published var shown = false
    @Published var lyrics: Lyrics?
    @Published var theme = NotchTheme.standard
}

struct ClosedLyricsView: View {
    @ObservedObject var model: ClosedLyricsModel
    /// The song's color (Gargoyle tints their ground with it), and how far into it it is.
    let accent: () -> NSColor
    let position: (Date) -> Double
    /// Midnight's frosted glass behind them (which only a window can draw, not a picture of one).
    var frosted = true

    var body: some View {
        let midnight = model.theme == .midnight
        ZStack {
            if let lyrics = model.lyrics {
                if midnight {
                    // Frosted dark glass, as the band's is, and a haze of ink over it, so they read
                    // over whatever's under them; both fading out to nothing, with no edge.
                    if frosted { FeatheredGlass(size: ClosedLyrics.size(.midnight)) }
                    EllipticalGradient(stops: [.init(color: Midnight.ink.opacity(0.86), location: 0),
                                               .init(color: Midnight.ink.opacity(0.68), location: 0.55),
                                               .init(color: Midnight.ink.opacity(0), location: 1)],
                                       center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.shown)) { context in
                        LyricsSkyFrame(lyrics: lyrics, position: position(context.date) + LyricsSky.lead,
                                       time: MidnightBackdrop.clock)
                    }
                    .frame(width: 560, height: 126)
                    .scaleEffect(0.86)
                } else {
                    LyricsView(lyrics: lyrics, accent: accent(), position: position)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .environment(\.notchTheme, model.theme)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: model.shown || !midnight ? 0 : 6)
        .offset(y: model.shown ? 0 : -6)
        .allowsHitTesting(false)
    }
}

/// Dark frosted glass in an oval, solid in the middle and thinning out to nothing at its edge.
private struct FeatheredGlass: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.maskImage = Self.mask(size)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// An oval as big as `size`, opaque in the middle, fading out toward its rim.
    static func mask(_ size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext,
                  let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.85).cgColor,
                                                     NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                            locations: [0, 0.5, 1]) else { return false }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: rect.width / rect.height, y: 1)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rect.height / 2,
                                       options: [])
            return true
        }
    }
}
