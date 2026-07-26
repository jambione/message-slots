import Foundation
import GameCore

/// Translates game events into sound.
///
/// This is the only file that knows about *both* `GameCore` and the synth, and
/// it deliberately sits in the app target: `GameCore` stays free of
/// AVFoundation so the engine keeps building on Linux CI and stays replayable
/// in a headless test.
///
/// The mapping is driven off `Effect` values, which the reducer already emits
/// for the UI. That means audio needs no new engine hooks, and — because a
/// replayed turn emits the identical effect sequence — a teammate's replayed
/// turn sounds exactly like it did when they played it.
@MainActor
final class AudioDirector {
    private let engine = AudioEngine()

    private(set) var musicEnabled = true
    private(set) var effectsEnabled = true

    // MARK: Lifecycle

    /// Name of the background music asset, if one has been added to the app
    /// target. Nothing ships with the prototype yet — see docs/AUDIO.md.
    private static let musicAsset = "background_music"

    func start() {
        engine.start()
        // Silently no-ops until an audio file with this name is in the bundle,
        // so the game stays playable (and quiet) with no music asset present.
        if engine.loadMusic(named: Self.musicAsset), musicEnabled {
            engine.playMusic()
        }
    }

    func stop() { engine.stop() }

    var hasMusic: Bool { engine.hasMusic }

    func setMusicEnabled(_ enabled: Bool) {
        musicEnabled = enabled
        if enabled { engine.playMusic() } else { engine.stopMusic() }
    }

    func setEffectsEnabled(_ enabled: Bool) {
        effectsEnabled = enabled
        engine.setEffectsEnabled(enabled)
    }

    // MARK: Part-of-speech pitch mapping
    //
    // Banking a word plays a mallet note, and the note is chosen by the word's
    // grammatical category. Two things fall out of that for free:
    //
    //   1. Spelling a word plays a little melody, and it rises as the word gets
    //      more valuable. The tray becomes audible, not just visible.
    //   2. It gives letter value a second sensory channel alongside the colour
    //      coding (GRAPHICS.md §2.2) — useful for players who can't rely on
    //      colour at all.
    //
    // The pitches are the F major pentatonic scale, so *any* sequence of
    // letters sounds consonant. A chromatic mapping would carry more
    // information and would sound awful, which is the wrong trade: this fires
    // on every banked letter, hundreds of times per session.
    private func pitch(forLetterValue value: Int) -> Double {
        // Cheap letters low and soft, the 8–10 pointers bright at the top, so
        // landing a Z is audibly an event.
        switch value {
        case 0:      return 60   // blank — worth nothing, sits lowest
        case 1:      return 65   // F4
        case 2...3:  return 69   // A4
        case 4...5:  return 72   // C5
        case 6...8:  return 77   // F5
        default:     return 81   // A5
        }
    }

    // MARK: Effect handling

    /// `check` is the *previous* word check, used to detect the transition into
    /// a submittable word.
    func handle(_ effect: Effect, turn: TurnState, check: WordCheck?) {
        switch effect {
        case .reelsSpun:
            engine.play(.reelSpin)
            // A short stagger would be better still (five reels landing in
            // sequence), but that needs a scheduled cue queue — noted in
            // docs/AUDIO.md as the next refinement.
            engine.play(.reelStop)

        case .letterBanked(let trayIndex, _):
            let value = turn.tray.indices.contains(trayIndex)
                ? turn.tray[trayIndex].tile.value
                : 1
            engine.play(.bankWord, pitch: pitch(forLetterValue: value))

        case .blankPlayed:
            engine.play(.bankWord, pitch: pitch(forLetterValue: 0))

        case .letterReturnedToReel, .letterDiscarded:
            engine.play(.removeWord)

        case .gemAttached, .bonusCollected, .wordMultiplierRaised:
            engine.play(.bonus)

        case .tryGranted:
            engine.play(.extraTry)

        case .frenzyStarted:
            engine.play(.frenzyStart)

        case .wordChecked(let result):
            // Only on the *transition* into submittable — a chime on every tray
            // change while the word stayed valid would be maddening.
            if result.isSubmittable, check?.isSubmittable != true {
                engine.play(.validGreen)
            }

        case .wordLocked:
            engine.play(.lockIn)

        case .rejected:
            engine.play(.rejected)

        default:
            break
        }
    }

    /// Plays the score sheet's line-by-line reveal as a rising figure.
    /// Called by the UI as each line animates in.
    func playScoreLine(index: Int) {
        // F major pentatonic ascending, so a long breakdown climbs pleasantly
        // instead of running out of scale.
        let scale: [Double] = [65, 67, 69, 72, 74, 77, 79, 81, 84]
        engine.play(.scoreLine, pitch: scale[min(index, scale.count - 1)])
    }
}
