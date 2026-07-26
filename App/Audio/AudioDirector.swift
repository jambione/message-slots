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
    //   1. Building a sentence plays a little melody, and "the grumpy octopus
    //      tangoed" has a different tune than "dog cat moon". The tray becomes
    //      audible, not just visible.
    //   2. It reinforces the category taxonomy through a second sense, exactly
    //      as the colour coding does (GRAPHICS.md §2.2) — useful for players
    //      who can't rely on the colours at all.
    //
    // The pitches are the F major pentatonic scale, so *any* order of words
    // sounds consonant. A chromatic mapping would be more "informative" and
    // would sound awful, which is the wrong trade: this has to be pleasant
    // hundreds of times per session.
    private func pitch(for pos: Set<PartOfSpeech>) -> Double {
        // Content words sit high and bright, glue words low and soft — which
        // matches their visual weight and their scoring weight.
        if pos.contains(.noun)        { return 72 }  // C5
        if pos.contains(.verb)        { return 74 }  // D5
        if pos.contains(.adjective)   { return 77 }  // F5
        if pos.contains(.adverb)      { return 79 }  // G5
        if pos.contains(.pronoun)     { return 69 }  // A4
        if pos.contains(.conjunction) { return 65 }  // F4
        if pos.contains(.preposition) { return 67 }  // G4
        return 62                                    // D4 — articles, lowest
    }

    // MARK: Effect handling

    /// `tray` is the state *after* the effect applied, used for intensity.
    func handle(_ effect: Effect, turn: TurnState, validity: ValidationResult?) {
        switch effect {
        case .reelsSpun:
            engine.play(.reelSpin)
            // A short stagger would be better still (five reels landing in
            // sequence), but that needs a scheduled cue queue — noted in
            // docs/AUDIO.md as the next refinement.
            engine.play(.reelStop)

        case .wordBanked(let trayIndex, _):
            let pos = turn.tray.indices.contains(trayIndex)
                ? turn.tray[trayIndex].entry.pos
                : []
            engine.play(.bankWord, pitch: pitch(for: pos))

        case .wordReturnedToReel, .wordDiscarded:
            engine.play(.removeWord)

        case .gemAttached, .bonusCollected:
            engine.play(.bonus)

        case .tryGranted:
            engine.play(.extraTry)

        case .frenzyStarted:
            engine.play(.frenzyStart)

        case .validityChanged(let result):
            // Only on the *transition* into valid — a chime on every keystroke
            // of a valid sentence would be maddening.
            if result.isValid, validity?.isValid != true {
                engine.play(.validGreen)
            }

        case .sentenceLocked:
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
