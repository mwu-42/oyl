import AppKit

/// What you hear and feel as Control (tapped, then held) swaps Oyl's look: Oyl's own low, round
/// tones (see `ChimeTone`), and a tap of the trackpad (felt only with a finger on it, as all its
/// taps are; with Haptics on). Into Midnight Oyl, moonrise: slowly up an octave, each note slow to
/// come in, a faint shimmer of stars over the top, and two soft taps. Back to Oyl's look, daybreak:
/// quickly up through a fifth, warm, and one firm tap. Both go up; Midnight's slower and higher. ⌃ ⌃ held: its sound turns the sound off.
enum ThemeChime {
    /// Moonrise: E3, B3 and E4, slowly up, with B4 and E5 faint over them at the top, as stars.
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
            Note(pitch: 164.81, at: 0, level: 0.27, attack: 0.06, fade: 0.24, overtones: warm),
            Note(pitch: 246.94, at: 0.17, level: 0.29, attack: 0.07, fade: 0.28, overtones: stars),
            Note(pitch: 329.63, at: 0.34, level: 0.3, attack: 0.09, fade: 0.42, overtones: stars),
            Note(pitch: 493.88, at: 0.42, level: 0.045, attack: 0.02, fade: 0.25, overtones: []),
            Note(pitch: 659.25, at: 0.54, level: 0.035, attack: 0.02, fade: 0.3, overtones: []),
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
