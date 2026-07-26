import Foundation
import AVFoundation
import os.lock

/// One-shot sound effects, triggered by gameplay.
enum SoundCue: UInt32 {
    case reelSpin
    case reelStop
    case bankWord       // pitch supplied separately
    case removeWord
    case bonus
    case extraTry
    case validGreen
    case frenzyStart
    case lockIn
    case scoreLine
    case rejected
}

/// Audio host: procedurally synthesised sound effects, plus playback of a
/// background music track supplied as an asset.
///
/// **Music is a file, not generated.** An earlier version synthesised an
/// adaptive score in code; it was not pleasant to listen to and has been
/// removed. Composed music is now dropped in as an audio file — see
/// `loadMusic(named:)` and docs/AUDIO.md for where to put it.
///
/// The effects synthesiser stays, because per-cue procedural audio is a good
/// fit for short UI sounds: no assets to ship, and cues can be parameterised
/// (the bank sound is pitched by part of speech, so building a sentence plays a
/// small melody).
///
/// Threading model:
///   - The **main thread** pushes `SoundCue`s and controls the music player.
///   - The **audio thread** runs `render`, drains the cue queue and mixes voices.
///
/// They communicate through a lock-guarded queue that the audio thread only
/// ever `tryLock`s — a dropped cue is inaudible, a blocked audio thread is not.
final class AudioEngine {

    // MARK: Configuration

    private let sampleRate = 44_100.0
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let pool: VoicePool

    // Music playback
    private let musicPlayer = AVAudioPlayerNode()
    private var musicFile: AVAudioFile?
    private var musicAttached = false

    // MARK: Shared state

    private struct Shared {
        var cues: [(cue: UInt32, pitch: Double)] = []
        var effectsEnabled = true
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    /// Reused by the audio thread so the render path never allocates.
    private var cueScratch: [(cue: UInt32, pitch: Double)] = []

    private(set) var isRunning = false

    init() {
        pool = VoicePool(capacity: 32, sampleRate: sampleRate)
        cueScratch.reserveCapacity(32)
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        configureSession()

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            self.render(frameCount: Int(frameCount), buffers: audioBufferList)
            return noErr
        }
        sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        engine.attach(musicPlayer)
        engine.connect(musicPlayer, to: engine.mainMixerNode, format: nil)
        musicAttached = true

        engine.mainMixerNode.outputVolume = 0.9

        do {
            try engine.start()
            isRunning = true
        } catch {
            // Audio is a nice-to-have, never a reason the game fails to run.
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        musicPlayer.stop()
        engine.stop()
        if let node = sourceNode { engine.detach(node) }
        if musicAttached { engine.detach(musicPlayer); musicAttached = false }
        sourceNode = nil
        pool.allNotesOff()
        isRunning = false
    }

    private func configureSession() {
        #if os(iOS)
        // `.ambient` means our audio never interrupts the player's own music.
        // A word game people play on a couch has no business stopping someone's
        // podcast. Revisit only if a licensed soundtrack makes that wrong.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
    }

    // MARK: Music
    //
    // Drop an audio file into the app target and call `loadMusic(named:)`.
    // Anything AVAudioFile reads works — .m4a, .mp3, .wav, .caf. A seamless
    // loop wants .m4a or .caf; .mp3 carries encoder padding that puts an
    // audible gap at the loop point.

    /// Loads a track by resource name. Returns false if it isn't in the bundle,
    /// so a missing file leaves the game silent rather than crashing.
    @discardableResult
    func loadMusic(named name: String, extension ext: String? = nil) -> Bool {
        let url: URL?
        if let ext {
            url = Bundle.main.url(forResource: name, withExtension: ext)
        } else {
            url = ["m4a", "mp3", "wav", "caf", "aiff"]
                .lazy
                .compactMap { Bundle.main.url(forResource: name, withExtension: $0) }
                .first
        }
        guard let url, let file = try? AVAudioFile(forReading: url) else { return false }
        musicFile = file
        return true
    }

    /// Starts (or restarts) the loaded track, looping indefinitely.
    func playMusic(volume: Float = 0.35) {
        guard isRunning, let file = musicFile else { return }
        musicPlayer.stop()
        musicPlayer.volume = volume
        scheduleMusicLoop(file)
        musicPlayer.play()
    }

    /// Re-schedules on completion rather than reading the whole file into a
    /// buffer: a multi-minute track would otherwise sit decompressed in memory.
    private func scheduleMusicLoop(_ file: AVAudioFile) {
        file.framePosition = 0
        musicPlayer.scheduleFile(file, at: nil) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.isRunning, self.musicPlayer.isPlaying || self.musicFile != nil else { return }
                self.scheduleMusicLoop(file)
            }
        }
    }

    func stopMusic() { musicPlayer.stop() }

    func setMusicVolume(_ volume: Float) { musicPlayer.volume = volume }

    var hasMusic: Bool { musicFile != nil }

    // MARK: Effects — main-thread API

    func play(_ cue: SoundCue, pitch: Double = 0) {
        shared.withLock {
            guard $0.effectsEnabled else { return }
            // Bounded queue: never let the game grow this without limit on the
            // audio thread's behalf.
            if $0.cues.count > 24 { $0.cues.removeFirst() }
            $0.cues.append((cue.rawValue, pitch))
        }
    }

    func setEffectsEnabled(_ enabled: Bool) {
        shared.withLock { $0.effectsEnabled = enabled }
        if !enabled { pool.allNotesOff() }
    }

    // MARK: Audio thread

    private func render(frameCount: Int, buffers: UnsafeMutablePointer<AudioBufferList>) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(buffers)

        // `tryLock`, never `lock` — see the class comment.
        cueScratch.removeAll(keepingCapacity: true)
        shared.withLockIfAvailable { state in
            self.cueScratch.append(contentsOf: state.cues)
            state.cues.removeAll(keepingCapacity: true)
        }

        for item in cueScratch {
            trigger(cue: SoundCue(rawValue: item.cue), pitch: item.pitch)
        }

        for frame in 0..<frameCount {
            let (l, r) = pool.render()
            // Cubic soft clip rather than `tanh` — a transcendental per sample
            // is exactly the kind of cost that makes a render callback miss its
            // deadline, which is heard as crackling.
            let left = Float(softClip(l * 1.2) * 0.8)
            let right = Float(softClip(r * 1.2) * 0.8)

            // `standardFormatWithSampleRate` is deinterleaved: one buffer per
            // channel, each holding `frameCount` mono samples.
            if ablPointer.count >= 2 {
                channel(ablPointer[0])[frame] = left
                channel(ablPointer[1])[frame] = right
            } else if ablPointer.count == 1 {
                let buffer = ablPointer[0]
                let ptr = channel(buffer)
                if buffer.mNumberChannels == 2 {
                    ptr[frame * 2] = left
                    ptr[frame * 2 + 1] = right
                } else {
                    ptr[frame] = (left + right) * 0.5
                }
            }
        }
    }

    private func channel(_ buffer: AudioBuffer) -> UnsafeMutablePointer<Float> {
        buffer.mData!.assumingMemoryBound(to: Float.self)
    }

    // MARK: Cues

    private func trigger(cue: SoundCue?, pitch: Double) {
        guard let cue else { return }
        switch cue {
        case .reelSpin:
            pool.noteOn(kind: .sweep, frequency: 0, amp: 0.10, attack: 0.05,
                        decay: 0.5, pan: 0.5, cutoff: 2_600)

        case .reelStop:
            // Low thump plus a click — the physical sound of something landing.
            pool.noteOn(kind: .bass, frequency: 92, amp: 0.16, attack: 0.001,
                        decay: 0.16, pan: 0.5, cutoff: 700)
            pool.noteOn(kind: .mallet, frequency: 1_400, amp: 0.05, attack: 0.0005,
                        decay: 0.05, pan: 0.5, cutoff: 8_000)

        case .bankWord:
            // Pitched by part of speech (see AudioDirector), so banking a
            // sentence plays a little melody and "noun verb noun" sounds
            // different from "adj adj noun".
            let midi = pitch > 0 ? pitch : 72
            pool.noteOn(kind: .mallet, frequency: Pitch.hz(midi), amp: 0.13,
                        attack: 0.001, decay: 0.45, pan: 0.5, cutoff: 6_500)

        case .removeWord:
            // A soft descending "un-place". Deliberately not a buzzer: removing
            // a word is free and encouraged (GAME_LOGIC.md §2.1) and must never
            // sound like a mistake.
            pool.noteOn(kind: .mallet, frequency: Pitch.hz(64), amp: 0.07,
                        attack: 0.001, decay: 0.22, pan: 0.5, cutoff: 3_000)
            pool.noteOn(kind: .mallet, frequency: Pitch.hz(59), amp: 0.06,
                        attack: 0.001, decay: 0.3, pan: 0.5, cutoff: 3_000)

        case .bonus:
            // Rising bell figure — unmistakably "good thing happened".
            pool.noteOn(kind: .bell, frequency: Pitch.hz(77), amp: 0.09,
                        attack: 0.001, decay: 0.7, pan: 0.45, cutoff: 9_000)
            pool.noteOn(kind: .bell, frequency: Pitch.hz(81), amp: 0.08,
                        attack: 0.001, decay: 0.9, pan: 0.55, cutoff: 9_000)
            pool.noteOn(kind: .bell, frequency: Pitch.hz(84), amp: 0.07,
                        attack: 0.001, decay: 1.1, pan: 0.5, cutoff: 9_000)

        case .extraTry:
            pool.noteOn(kind: .bell, frequency: Pitch.hz(79), amp: 0.09,
                        attack: 0.001, decay: 0.8, pan: 0.5, cutoff: 9_000)

        case .validGreen:
            // A rising major third: the smallest gesture that reads as "yes".
            // Quiet, because it fires on every transition into valid.
            pool.noteOn(kind: .bell, frequency: Pitch.hz(72), amp: 0.045,
                        attack: 0.002, decay: 0.3, pan: 0.5, cutoff: 7_000)
            pool.noteOn(kind: .bell, frequency: Pitch.hz(76), amp: 0.04,
                        attack: 0.002, decay: 0.45, pan: 0.5, cutoff: 7_000)

        case .frenzyStart:
            pool.noteOn(kind: .bell, frequency: Pitch.hz(86), amp: 0.08,
                        attack: 0.001, decay: 1.0, pan: 0.5, cutoff: 9_000)
            pool.noteOn(kind: .bell, frequency: Pitch.hz(91), amp: 0.06,
                        attack: 0.001, decay: 1.2, pan: 0.5, cutoff: 9_000)

        case .lockIn:
            // A warm major chord to close the turn.
            for (i, midi) in [57.0, 61, 64, 69].enumerated() {
                pool.noteOn(kind: .bell, frequency: Pitch.hz(midi), amp: 0.06,
                            attack: 0.002, decay: 1.4,
                            pan: 0.42 + Double(i) * 0.05, cutoff: 7_500)
            }

        case .scoreLine:
            let midi = pitch > 0 ? pitch : 72
            pool.noteOn(kind: .bell, frequency: Pitch.hz(midi), amp: 0.06,
                        attack: 0.001, decay: 0.4, pan: 0.5, cutoff: 8_000)

        case .rejected:
            // Muted, low, brief. The game never scolds (GAME_LOGIC.md §4), so
            // neither does the sound design.
            pool.noteOn(kind: .bass, frequency: Pitch.hz(45), amp: 0.09,
                        attack: 0.004, decay: 0.25, pan: 0.5, cutoff: 500)
        }
    }
}
