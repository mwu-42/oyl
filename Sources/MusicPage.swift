import SwiftUI

struct MusicPage: View {
    @ObservedObject var nowPlaying: NowPlaying
    @ObservedObject var state: NotchState
    let hands: GestureWatcher

    var body: some View {
        if let track = nowPlaying.track {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 2) {
                        ArtworkControl(nowPlaying: nowPlaying, hands: hands)
                        lyricsHandle
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(track.artist.isEmpty ? track.album : track.artist)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .lineLimit(1)
                        SpectrumCurve(spectrum: nowPlaying.spectrum, color: nowPlaying.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .overlay { SurfingOyl(spectrum: nowPlaying.spectrum, nowPlaying: nowPlaying) }
                            .padding(.top, 6)
                        Spacer(minLength: 0)
                        ProgressRow(nowPlaying: nowPlaying, hands: hands)
                    }
                    .frame(height: Layout.artSize)
                }
                if state.showsLyrics, let lyrics = nowPlaying.lyrics {
                    LyricsView(lyrics: lyrics, nowPlaying: nowPlaying)
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.bottom, 2)
                Text("Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Play something in Music or Spotify")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 10)
        }
    }

    /// Just under the cover: opens the lyrics, when the song has some. Without any, nothing's
    /// there to click.
    @ViewBuilder private var lyricsHandle: some View {
        if nowPlaying.lyrics != nil {
            Button(action: state.toggleLyrics) {
                Image(systemName: state.showsLyrics ? "chevron.compact.up" : "chevron.compact.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: Layout.artSize, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help(state.showsLyrics ? "Hide lyrics" : "Show lyrics")
        }
    }
}

/// Oyl riding the visualizer's wave on a surfboard, bobbing up and down with the song and
/// tipping with the slope, drifting a little back and forth.
/// Oyl riding the visualizer's wave, as far along it as the song is along.
private struct SurfingOyl: View {
    let spectrum: AudioSpectrum
    let nowPlaying: NowPlaying

    private static let size = CGSize(width: 60, height: 30)

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
                let curve = spectrum.frames.value.curve
                let duration = nowPlaying.track?.duration ?? 0
                let progress = duration > 0 ? nowPlaying.position(at: context.date) / duration : 0
                // Kept a little in from the ends, so it's all on the wave.
                let along = 0.05 + 0.9 * min(max(progress, 0), 1)
                let (height, slope) = Self.wave(curve, at: along)
                // The curve's top there, measured as the visualizer draws it.
                let inset: CGFloat = 1.5
                let top = geometry.size.height - inset - (geometry.size.height - 2 * inset) * height
                let rise = slope * (geometry.size.height - 2 * inset) / max(geometry.size.width, 1)
                Oyl(surfing: true)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .rotationEffect(.radians(-atan(rise) * 0.8), anchor: .bottom)
                    .position(x: along * geometry.size.width, y: top - Self.size.height / 2 + 2)
            }
        }
        .allowsHitTesting(false)
    }

    /// The curve's value (0...1) at `along` (0...1 across), and its slope there.
    private static func wave(_ values: [Float], at along: Double) -> (CGFloat, CGFloat) {
        guard values.count > 1 else { return (0, 0) }
        let position = along * Double(values.count - 1)
        let index = min(Int(position), values.count - 2)
        let fraction = CGFloat(position - Double(index))
        let a = CGFloat(values[index]), b = CGFloat(values[index + 1])
        return (a + (b - a) * fraction, (b - a) * CGFloat(values.count - 1))
    }
}

/// The album cover is the whole control: click to play or pause, swipe left for the next track
/// (like flicking the cover away) and right for the previous one, pull down or up for volume.
/// Works with click-and-drag and with two-finger trackpad swipes. It also shows the volume
/// while a pinch on the camera turns it.
struct ArtworkControl: View {
    @ObservedObject var nowPlaying: NowPlaying
    let hands: GestureWatcher
    @StateObject private var gestures = ArtworkGestures()

    var body: some View {
        let accent = Color(nsColor: nowPlaying.accent)

        ArtworkView(image: nowPlaying.artwork, cornerRadius: 11)
            .frame(width: Layout.artSize, height: Layout.artSize)
            .overlay {
                if let flash = gestures.flash {
                    Image(systemName: flash.symbol)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.black.opacity(0.5)))
                        .id(flash.id)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if gestures.showsVolume {
                    VolumeReadout(volume: nowPlaying.volume)
                        .padding(8)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                }
            }
            .background(ScrollReader { gestures.scrolled($0, nowPlaying: nowPlaying) })
            .onReceive(hands.$isTurning.removeDuplicates()) { gestures.showVolume(while: $0) }
            .scaleEffect(gestures.isActive ? 0.96 : (nowPlaying.isPlaying ? 1 : 0.9))
            .opacity(nowPlaying.isPlaying || gestures.isActive ? 1 : 0.75)
            .shadow(color: accent.opacity(nowPlaying.isPlaying ? 0.45 : 0), radius: 14)
            .offset(gestures.offset)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: nowPlaying.isPlaying)
            // Tight while held (sticky), loose and bouncy on release (the magnetic snap back).
            .animation(gestures.isActive ? .interactiveSpring(response: 0.2, dampingFraction: 0.8)
                                         : .spring(response: 0.38, dampingFraction: 0.5),
                       value: gestures.offset)
            .animation(.easeOut(duration: 0.2), value: gestures.showsVolume)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: gestures.flash)
            .contentShape(Rectangle())
            .onTapGesture { gestures.tapped(nowPlaying) }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { gestures.dragChanged($0.translation, nowPlaying: nowPlaying) }
                    .onEnded { gestures.dragEnded($0.translation, predicted: $0.predictedEndTranslation) }
            )
    }
}

@MainActor
final class ArtworkGestures: ObservableObject {
    struct Flash: Equatable {
        let id = UUID()
        let symbol: String
    }

    private enum Axis {
        case horizontal, vertical
    }

    @Published private(set) var offset = CGSize.zero
    @Published private(set) var isActive = false
    @Published private(set) var showsVolume = false
    @Published private(set) var flash: Flash?

    private static let pullNudge: CGFloat = 16     // furthest the cover moves when pulled
    private static let swipeNudge: CGFloat = 22
    private static let swipeDistance: CGFloat = 60 // travel that counts as a swipe
    private static let fullSpeed = 0.4             // volume per second at full pull
    private static let deadZone = 0.15

    private weak var nowPlaying: NowPlaying?
    private var axis: Axis?
    private var pull = 0.0                         // -1 (up) ... 1 (down)
    private var volumeTimer: Timer?
    private var volumeStep: Int?
    private var hideVolume: DispatchWorkItem?
    private var scrollTravel = CGSize.zero
    private var scrolling = false
    private var scrollSkipped = false
    private var scrollEnd: DispatchWorkItem?

    func tapped(_ nowPlaying: NowPlaying) {
        nowPlaying.togglePlayPause()
        show(nowPlaying.isPlaying ? "play.fill" : "pause.fill")
    }

    // MARK: Click and drag

    func dragChanged(_ translation: CGSize, nowPlaying: NowPlaying) {
        self.nowPlaying = nowPlaying
        isActive = true
        if axis == nil, hypot(translation.width, translation.height) >= 6 {
            axis = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
            if axis == .vertical { beginVolume() }
        }
        switch axis {
        case .horizontal:
            offset = CGSize(width: Self.swipeNudge * tanh(translation.width / 70), height: 0)
        case .vertical:
            // The cover only moves so far; past that, holding keeps the volume moving.
            pull = Double(tanh(translation.height / 60))
            offset = CGSize(width: 0, height: Self.pullNudge * pull)
        case nil:
            break
        }
    }

    func dragEnded(_ translation: CGSize, predicted: CGSize) {
        if axis == .horizontal {
            let distance = abs(predicted.width) > abs(translation.width) ? predicted.width : translation.width
            if abs(distance) > Self.swipeDistance { skip(forward: distance < 0) }
        }
        finish()
    }

    // MARK: Two-finger swipes

    func scrolled(_ input: ScrollInput, nowPlaying: NowPlaying) {
        self.nowPlaying = nowPlaying
        // Ignore the glide after the fingers lift.
        guard !input.isMomentum else { return }
        if input.began || !scrolling {
            scrolling = true
            scrollTravel = .zero
            scrollSkipped = false
            axis = nil
        }
        isActive = true
        scrollTravel.width += input.fingerDelta.width
        scrollTravel.height += input.fingerDelta.height
        if axis == nil, hypot(scrollTravel.width, scrollTravel.height) >= 6 {
            axis = abs(scrollTravel.width) > abs(scrollTravel.height) ? .horizontal : .vertical
            if axis == .vertical { beginVolume(rateDriven: false) }
        }
        switch axis {
        case .horizontal:
            offset = CGSize(width: Self.swipeNudge * tanh(scrollTravel.width / 70), height: 0)
            if !scrollSkipped, abs(scrollTravel.width) > Self.swipeDistance {
                scrollSkipped = true
                skip(forward: scrollTravel.width < 0)
            }
        case .vertical:
            offset = CGSize(width: 0, height: Self.pullNudge * tanh(scrollTravel.height / 60))
            // Scrolling moves the volume directly: about 300 points for the full range.
            changeVolume(to: nowPlaying.volume - Double(input.fingerDelta.height) / 300)
        case nil:
            break
        }

        // Mouse wheels (and some trackpad gestures) never say they ended.
        scrollEnd?.cancel()
        if input.ended {
            endScroll()
        } else {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.endScroll() } }
            scrollEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func endScroll() {
        scrolling = false
        finish()
    }

    // MARK: Shared

    private func beginVolume(rateDriven: Bool = true) {
        hideVolume?.cancel()
        hideVolume = nil
        showsVolume = true
        volumeStep = nowPlaying.map { Int(($0.volume * 10).rounded()) }
        guard rateDriven, volumeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPull() }
        }
        RunLoop.main.add(timer, forMode: .common)
        volumeTimer = timer
    }

    /// Joystick-style: the further the pull, the faster the volume moves, and it keeps moving
    /// while held. A small dead zone keeps a resting hand from drifting it.
    private func applyPull() {
        guard let nowPlaying else { return }
        let deflection = max(abs(pull) - Self.deadZone, 0) / (1 - Self.deadZone)
        guard deflection > 0 else { return }
        let speed = Self.fullSpeed * pow(deflection, 1.5)
        changeVolume(to: nowPlaying.volume + (pull > 0 ? -speed : speed) / 30)
    }

    private func changeVolume(to target: Double) {
        guard let nowPlaying else { return }
        let volume = min(max(target, 0), 1)
        guard volume != nowPlaying.volume else { return }
        let step = Int((volume * 10).rounded())
        if step != volumeStep {
            // A tick every 10%, a firmer one at the ends.
            NSHapticFeedbackManager.defaultPerformer.perform(step == 0 || step == 10 ? .levelChange : .alignment,
                                                             performanceTime: .now)
            volumeStep = step
        }
        nowPlaying.setVolume(volume)
    }

    private func skip(forward: Bool) {
        guard let nowPlaying else { return }
        if forward { nowPlaying.next() } else { nowPlaying.previous() }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        show(forward ? "forward.fill" : "backward.fill")
    }

    private func finish() {
        volumeTimer?.invalidate()
        volumeTimer = nil
        axis = nil
        pull = 0
        isActive = false
        offset = .zero
        hideVolumeSoon()
    }

    /// Shows the level while something else changes it (a pinch turned on the camera), and for
    /// a moment after. `onReceive` hands this the current value again on every redraw, so it
    /// only touches anything when there's a change to make: setting `showsVolume` redraws, even
    /// to the same value, and that redraw would call this again, forever.
    func showVolume(while changing: Bool) {
        if changing {
            hideVolume?.cancel()
            hideVolume = nil
            if !showsVolume { showsVolume = true }
        } else if !isActive, hideVolume == nil {
            hideVolumeSoon()
        }
    }

    /// Keeps the level up for a moment after letting go.
    private func hideVolumeSoon() {
        guard showsVolume else { return }
        hideVolume?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.hideVolume = nil
                self?.showsVolume = false
            }
        }
        hideVolume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func show(_ symbol: String) {
        let flash = Flash(symbol: symbol)
        self.flash = flash
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                if self?.flash == flash { self?.flash = nil }
            }
        }
    }
}

/// A scroll event reduced to what the cover needs, in the direction the fingers actually
/// moved (positive = right / down) whatever the natural-scrolling setting.
struct ScrollInput: Sendable {
    let fingerDelta: CGSize
    let began: Bool
    let ended: Bool
    let isMomentum: Bool

    init(_ event: NSEvent) {
        let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8  // mouse wheels report lines
        fingerDelta = CGSize(width: event.scrollingDeltaX * direction * scale,
                             height: event.scrollingDeltaY * direction * scale)
        began = event.phase.contains(.began)
        ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        isMomentum = !event.momentumPhase.isEmpty
    }
}

/// Passes scroll events over its frame to `onScroll`. It never takes clicks (`hitTest` returns
/// nil), so taps and drags still reach the SwiftUI gestures on top.
struct ScrollReader: NSViewRepresentable {
    let onScroll: (ScrollInput) -> Void

    func makeNSView(context: Context) -> ScrollReaderView {
        ScrollReaderView()
    }

    func updateNSView(_ view: ScrollReaderView, context: Context) {
        view.onScroll = onScroll
    }
}

final class ScrollReaderView: NSView {
    var onScroll: ((ScrollInput) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let input = ScrollInput(event)
            let location = event.locationInWindow
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, window.windowNumber == windowNumber,
                      self.bounds.contains(self.convert(location, from: nil)) else { return false }
                self.onScroll?(input)
                return true
            }
            return handled ? nil : event
        }
    }
}

private struct VolumeReadout: View {
    let volume: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: volume < 0.01 ? "speaker.slash.fill" : volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 14, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: geometry.size.width * min(max(volume, 0), 1))
                }
            }
            .frame(height: 4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(.black.opacity(0.6)))
    }
}

struct ProgressRow: View {
    @ObservedObject var nowPlaying: NowPlaying
    /// A pinch dragged sideways on the camera scrubs too; the bar shows where it'll land.
    @ObservedObject var hands: GestureWatcher
    @StateObject private var scrub = LocalState<Double?>(nil)  // 0...1 while the bar is being dragged

    var body: some View {
        let duration = nowPlaying.track?.duration ?? 0
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let playing = nowPlaying.position(at: context.date)
            let elapsed = scrub.value.map { $0 * duration }
                ?? hands.scrubOffset.map { min(max(playing + $0, 0), duration) } ?? playing
            HStack(spacing: 8) {
                Text(Self.format(elapsed))
                    .frame(width: 36, alignment: .leading)
                ScrubBar(fraction: duration > 0 ? elapsed / duration : 0,
                         onChanged: { scrub.value = $0 },
                         onEnded: { fraction in
                             nowPlaying.seek(to: fraction * duration)
                             scrub.value = nil
                         })
                Text("-" + Self.format(max(duration - elapsed, 0)))
                    .frame(width: 40, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        // Radio streams have no duration.
        .opacity(duration > 0 ? 1 : 0)
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
