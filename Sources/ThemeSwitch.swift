import SwiftUI

/// The switch between Oyl's look and Midnight Oyl's. It's unlike every other toggle because it
/// changes everything: a little sky with the moon at its end, a knob that slides across to it,
/// and its name set in Midnight's own face, a glimpse of the look it turns on.
///
/// Pointed at, it stirs. In Oyl's look the far end deepens to night, stars prick out one by one,
/// the moon comes up bright and tips, and the knob leans toward it (a plain ease, no overshoot).
/// In Midnight Oyl's, where its stars are always twinkling, they quicken and brighten, the moon
/// glows and a glint flares at its horn, and the moon leans back the way it would go. Clicked,
/// the knob slides over and the look changes behind it.
struct ThemeSwitch: View {
    /// Whether it's Midnight Oyl's look now (so the switch is on).
    let midnight: Bool
    var title = "Midnight Oyl"
    let flip: () -> Void
    @StateObject private var hover: LocalState<Bool>
    /// Slid across, the look about to change.
    @StateObject private var going = LocalState(false)

    /// `hovered`: as if pointed at from the first (for pictures of it).
    init(midnight: Bool, title: String = "Midnight Oyl", hovered: Bool = false, flip: @escaping () -> Void) {
        self.midnight = midnight
        self.title = title
        self.flip = flip
        _hover = StateObject(wrappedValue: LocalState(hovered))
    }

    static let track = CGSize(width: 30, height: 14)
    static let knob: CGFloat = 10
    /// How far Midnight's glow spills past the track, all round, to fade out in.
    private static let spill = CGSize(width: 12, height: 8)

    /// The knob's way across before the look changes: Oyl's quick and plain, Midnight's a slow drift.
    private var slide: (animation: Animation, time: Double) {
        midnight ? (.timingCurve(0.45, 0, 0.25, 1, duration: 0.42), 0.42) : (.easeInOut(duration: 0.2), 0.2)
    }

    private var lit: Bool { hover.value || going.value }

    /// Where the knob is along the track: at the moon in Midnight Oyl, at the start in Oyl's,
    /// leaning a little the other way while it's pointed at.
    private var knobX: CGFloat {
        let atMoon = midnight != going.value
        let lean: CGFloat = hover.value && !going.value ? (atMoon ? -2.5 : 2.5) : 0
        return 2 + (atMoon ? Self.track.width - Self.knob - 4 : 0) + lean
    }

    var body: some View {
        Button(action: switchLooks) {
            HStack(spacing: 6) {
                if midnight { night } else { day }
                Text(title)
                    .font(Midnight.flourish(midnight ? 12 : 11.5))
                    .foregroundStyle((midnight ? Midnight.white : Color.white).opacity(lit ? 1 : 0.8))
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { on in
            withAnimation(midnight ? .easeInOut(duration: 0.4) : .easeOut(duration: 0.18)) { hover.value = on }
        }
        .accessibilityLabel(title)
        .accessibilityValue(midnight ? "On" : "Off")
    }

    private func switchLooks() {
        guard !going.value else { return }
        withAnimation(slide.animation) { going.value = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + slide.time) {
            flip()
            going.value = false
        }
    }

    // MARK: Oyl's look

    /// Where the stars prick out, between the knob and the moon (and how big and bright).
    private static let dayStars: [(at: CGPoint, size: CGFloat, bright: Double)] = [
        (CGPoint(x: 16.2, y: 3.6), 1.4, 0.95), (CGPoint(x: 17.4, y: 10.4), 1, 0.65), (CGPoint(x: 26.8, y: 3.2), 1, 0.8),
    ]

    private var day: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(lit ? 0.2 : 0.14),
                                              Color(red: 0.12, green: 0.16, blue: 0.4).opacity(lit ? 1 : 0.6)],
                                     startPoint: .leading, endPoint: .trailing))
            ForEach(Self.dayStars.indices, id: \.self) { index in
                let star = Self.dayStars[index]
                Circle()
                    .fill(.white)
                    .frame(width: star.size, height: star.size)
                    .position(star.at)
                    .opacity(lit ? star.bright : 0)
                    // One after another, as stars come out.
                    .animation(.easeOut(duration: 0.18).delay(lit ? 0.05 * Double(index) : 0), value: lit)
            }
            Image(systemName: "moon.fill")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(.white.opacity(lit ? 1 : 0.5))
                .rotationEffect(.degrees(lit ? -18 : 0))
                .scaleEffect(lit ? 1.12 : 1)
                .position(x: Self.track.width - 7.5, y: Self.track.height / 2)
            Circle()
                .fill(.white)
                .frame(width: Self.knob, height: Self.knob)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                .offset(x: knobX)
        }
        .frame(width: Self.track.width, height: Self.track.height)
    }

    // MARK: Midnight Oyl's

    /// Its stars, off to the side away from the moon: where, how big, how quickly each twinkles,
    /// and where in its twinkle it starts.
    private static let nightStars: [(at: CGPoint, size: CGFloat, rate: Double, phase: Double)] = [
        (CGPoint(x: 4, y: 4.5), 1.6, 1.3, 0), (CGPoint(x: 8.5, y: 10), 1.1, 1.9, 1.7), (CGPoint(x: 12, y: 3.5), 1.3, 1.1, 3.1),
        (CGPoint(x: 15.5, y: 9.5), 0.9, 2.6, 0.6), (CGPoint(x: 6.5, y: 7.5), 0.8, 2.2, 4.4),
    ]

    private var night: some View {
        let lit = self.lit
        return ZStack(alignment: .leading) {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    // A patch of night with no edge: a glow, deepest toward the moon's end, gone to
                    // nothing well inside what's drawn (so nothing cuts it off).
                    context.translateBy(x: Self.spill.width, y: Self.spill.height)
                    let middle = CGPoint(x: Self.track.width * 0.62, y: Self.track.height / 2)
                    let reach = Self.track.height / 2 + Self.spill.height - 1
                    context.fill(Path(CGRect(origin: CGPoint(x: -Self.spill.width, y: -Self.spill.height), size: size)),
                                 with: .radialGradient(Gradient(stops: [
                                     .init(color: Midnight.moonlight.opacity(lit ? 0.2 : 0.12), location: 0),
                                     .init(color: Midnight.moonlight.opacity(lit ? 0.08 : 0.045), location: 0.55),
                                     .init(color: Midnight.moonlight.opacity(0), location: 1),
                                 ]), center: middle, startRadius: 0, endRadius: reach))
                    for star in Self.nightStars {
                        let twinkle = 0.5 + 0.5 * sin(time * star.rate * (lit ? 2.2 : 1) + star.phase)
                        let radius = star.size * (0.8 + 0.4 * twinkle) * (lit ? 1.3 : 1)
                        var glint = context
                        glint.opacity = (lit ? 0.55 : 0.25) + (lit ? 0.45 : 0.4) * twinkle
                        glint.fill(FourPointStar().path(in: CGRect(x: star.at.x - radius, y: star.at.y - radius,
                                                                   width: 2 * radius, height: 2 * radius)),
                                   with: .color(Midnight.starlight))
                    }
                }
            }
            .frame(width: Self.track.width + 2 * Self.spill.width, height: Self.track.height + 2 * Self.spill.height)
            .padding(.horizontal, -Self.spill.width)
            .padding(.vertical, -Self.spill.height)
            .allowsHitTesting(false)
            ZStack {
                Crescent()
                    .fill(Midnight.silver)
                    .shadow(color: Midnight.moonlight.opacity(lit ? 0.5 : 0.28), radius: lit ? 3 : 2)
                // A glint off its upper horn as it's pointed at.
                FourPointStar()
                    .fill(Midnight.starlight)
                    .frame(width: 6, height: 6)
                    .scaleEffect(lit ? 1 : 0.2)
                    .rotationEffect(.degrees(lit ? 45 : 0))
                    .opacity(lit ? 0.85 : 0)
                    .offset(x: 2.5, y: -6)
            }
            .frame(width: Self.knob, height: Self.knob)
            .offset(x: knobX)
        }
        .frame(width: Self.track.width, height: Self.track.height)
    }
}

/// A crescent moon, lit on its left: a disc with a bite out of its upper right.
struct Crescent: Shape {
    func path(in rect: CGRect) -> Path {
        let bite = rect.offsetBy(dx: rect.width * 0.36, dy: -rect.height * 0.2)
        return Path(ellipseIn: rect).subtracting(Path(ellipseIn: bite))
    }
}
