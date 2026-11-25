import AppKit

/// What you hear and feel as Control (tapped, then held) swaps Oyl's look: Oyl's own low, round
/// tones (see `ChimeTone`), and a tap of the trackpad (felt only with a finger on it, as all its
/// taps are; with Haptics on). Into Midnight Oyl, nightfall: down a fifth, slow to come in, a faint
/// shimmer of stars over it, and two soft taps. Back to Oyl's look, daybreak: up through a fifth,
/// warm and quick, and one firm tap. ⌃ ⌃ held: its sound turns the sound off.
enum ThemeChime {
    /// Nightfall: B3 down to E3, then B2 under it, with E5 and B5 faint over them, as stars.
    /// Daybreak: B2, E3 and B3, quickly up.
    nonisolated static func notes(toMidnight: Bool) -> [ChimeTone.Note] {
        typealias Note = ChimeTone.Note
        let warm = [ChimeTone.Overtone(ratio: 2, level: 0.2, fade: 0.5)]
        guard toMidnight else {
            return [246.94 / 2, 164.81, 246.94].enumerated().map { index, pitch in
                Note(pitch: pitch, at: Double(index) * 0.085, level: 0.28 + 0.03 * Double(index), attack: 0.01,
                     fade: index == 2 ? 0.28 : 0.16, overtones: warm)
            }
        }
        let stars = [ChimeTone.Overtone(ratio: 2, level: 0.14, fade: 0.6), ChimeTone.Overtone(ratio: 6, level: 0.05, fade: 0.5)]
        return [
            Note(pitch: 246.94, at: 0, level: 0.26, attack: 0.05, fade: 0.22, overtones: stars),
            Note(pitch: 164.81, at: 0.16, level: 0.3, attack: 0.07, fade: 0.3, overtones: stars),
            Note(pitch: 123.47, at: 0.32, level: 0.3, attack: 0.1, fade: 0.42, overtones: warm),
            Note(pitch: 659.25, at: 0.36, level: 0.045, attack: 0.02, fade: 0.25, overtones: []),
            Note(pitch: 987.77, at: 0.5, level: 0.035, attack: 0.02, fade: 0.3, overtones: []),
        ]
    }

    @MainActor private static var sounds: [Bool: NSSound] = [:]

    /// Heard and felt as the look's swapped (to Midnight's, or not).
    @MainActor
    static func swapped(toMidnight: Bool) {
        if Feature.themeSound.isOn {
            let sound = sounds[toMidnight] ?? NSSound(data: ChimeTone.wav(notes(toMidnight: toMidnight)))
            sounds[toMidnight] = sound
            if sound?.isPlaying == true { sound?.stop() }
            sound?.play()
        }
        Haptics.perform(.levelChange)
        guard toMidnight else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { Haptics.perform(.alignment) }
    }
}
