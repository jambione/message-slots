import Foundation

/// Real-time-safe synthesis primitives for the game's sound effects.
///
/// These generate every UI cue in code — reel thunks, the mallet note that
/// plays when a word is banked, bonus chimes. Background *music* is not
/// synthesised: an earlier procedural score was removed for sounding bad, and
/// music is now supplied as an audio asset (see AudioEngine.loadMusic).
/// Short, parameterised cues remain a good fit for synthesis; multi-minute
/// music emphatically is not.
///
/// Everything in this file runs on the audio render thread, which has a hard
/// deadline measured in microseconds. That imposes rules the rest of the app
/// doesn't live under:
///
///   - No allocation, no ARC traffic, no locks, no Swift runtime calls that
///     could allocate (that includes `Array` growth and `String`).
///   - No unbounded loops. Every voice renders in constant time per sample.
///
/// The voice pool is therefore a fixed-size buffer allocated once at startup
/// and mutated in place. Missing a deadline produces an audible click, and a
/// click in a relaxed lounge score is far more noticeable than one in a noisy
/// arcade mix — the genre is unforgiving about glitches, so the engineering has
/// to be correspondingly careful.

// MARK: - Wavetable

/// A precomputed sine table.
///
/// Calling `Foundation.sin()` per voice per sample is the single most expensive
/// thing this synth could do — a four-note Rhodes chord costs two `sin()` calls
/// per voice for FM, and with a dozen voices sounding that is ~1M transcendental
/// calls a second. In an unoptimised debug build that is more than enough to
/// blow the render deadline, which is heard as choppy, stuttering audio.
///
/// A 4096-entry table with linear interpolation is indistinguishable from real
/// `sin()` at these amplitudes and costs two loads and a lerp.
///
/// Phase is normalised to 0..<1 (not radians) so lookup is a multiply rather
/// than a divide, and wrapping is a cheap `truncatingRemainder`.
enum WaveTable {
    static let size = 4096
    private static let mask = size - 1

    static let sine: UnsafeMutablePointer<Double> = {
        let table = UnsafeMutablePointer<Double>.allocate(capacity: size + 1)
        for i in 0...size {
            table[i] = Foundation.sin(2.0 * Double.pi * Double(i) / Double(size))
        }
        return table
    }()

    /// `phase` in 0..<1. Values outside are wrapped.
    @inline(__always)
    static func sin(_ phase: Double) -> Double {
        var p = phase - phase.rounded(.down)
        if p < 0 { p += 1 }
        let scaled = p * Double(size)
        let index = Int(scaled) & mask
        let frac = scaled - Double(Int(scaled))
        return sine[index] + (sine[index + 1] - sine[index]) * frac
    }
}

/// Cheap soft clipper. `tanh()` per sample is another transcendental we don't
/// need — this cubic has the same gentle knee where it matters.
@inline(__always)
func softClip(_ x: Double) -> Double {
    if x >= 1.0 { return 2.0 / 3.0 }
    if x <= -1.0 { return -2.0 / 3.0 }
    return x - (x * x * x) / 3.0
}

// MARK: - Deterministic noise

/// xorshift64* — cheap, allocation-free noise for brushes and breath.
/// Deliberately not `SystemRandomNumberGenerator`: that can trap into the
/// kernel, which is not acceptable on the audio thread.
struct FastNoise {
    private var state: UInt64 = 0x9E3779B97F4A7C15

    mutating func next() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 2_685_821_657_736_338_717
        // Map to -1...1
        return Double(Int64(bitPattern: value)) / Double(Int64.max)
    }
}

// MARK: - One-pole filters

/// A one-pole lowpass. Enough tone shaping to make an oscillator sound like an
/// instrument, cheap enough to run per-sample on dozens of voices.
struct OnePole {
    var a = 0.0
    var z = 0.0

    /// `cutoff` in Hz.
    mutating func setCutoff(_ cutoff: Double, sampleRate: Double) {
        let clamped = max(20.0, min(cutoff, sampleRate * 0.45))
        a = exp(-2.0 * Double.pi * clamped / sampleRate)
    }

    mutating func lowpass(_ input: Double) -> Double {
        z = input * (1.0 - a) + z * a
        return z
    }

    mutating func highpass(_ input: Double) -> Double {
        input - lowpass(input)
    }
}

// MARK: - Voice

enum VoiceKind: UInt8 {
    /// Low, round thump — the weight under a reel landing.
    case bass
    /// Filtered noise wash.
    case brush
    /// Struck mallet, used when a word is banked.
    case mallet
    /// Pure sine bell for chimes and bonuses.
    case bell
    /// Filtered noise sweep for reel spins.
    case sweep
}

/// One sounding note. Plain struct in a preallocated buffer — no references,
/// nothing to retain or release on the audio thread.
struct Voice {
    var active = false
    var kind: VoiceKind = .bell

    var phase = 0.0
    var phaseInc = 0.0

    var amp = 0.0
    var env = 0.0
    var attackRate = 0.0
    var decayRate = 0.0
    var sustaining = false
    /// Samples remaining before the note releases. 0 means "decay immediately".
    var holdSamples = 0

    var pan = 0.5
    var filter = OnePole()
    var noise = FastNoise()

    mutating func render() -> Double {
        guard active else { return 0 }

        // Envelope
        if env < amp && !sustaining && attackRate > 0 {
            env += attackRate
            if env >= amp { env = amp; sustaining = holdSamples != 0 }
        } else if holdSamples > 0 {
            holdSamples -= 1
            if holdSamples == 0 { sustaining = false }
        } else {
            env *= sustaining ? 1.0 : decayRate
            if env < 0.00015 {
                active = false
                return 0
            }
        }

        var sample = 0.0
        switch kind {
        case .bass:
            // Sine plus a touch of second harmonic, lowpassed — round and
            // woody rather than buzzy.
            let fundamental = WaveTable.sin(phase)
            let harmonic = WaveTable.sin(phase * 2) * 0.18
            sample = filter.lowpass(fundamental + harmonic)

        case .brush:
            // Filtered noise. Texture, not pitch.
            sample = filter.lowpass(noise.next()) * 0.9

        case .mallet:
            // Fundamental plus an inharmonic partial — a soft wooden "pock".
            sample = (WaveTable.sin(phase) + WaveTable.sin(phase * 3.9) * 0.3) * 0.7

        case .bell:
            sample = WaveTable.sin(phase) + WaveTable.sin(phase * 2.76) * 0.25

        case .sweep:
            sample = filter.lowpass(noise.next())
        }

        // Normalised phase: wrap at 1.0, not 2π.
        phase += phaseInc
        if phase >= 1 { phase -= 1 }

        return sample * env
    }
}

// MARK: - Voice pool

/// Fixed-capacity voice allocator. Allocated once; the render thread only ever
/// reads and mutates in place.
final class VoicePool {
    private let storage: UnsafeMutableBufferPointer<Voice>
    let sampleRate: Double

    init(capacity: Int = 48, sampleRate: Double) {
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: Voice())
        self.sampleRate = sampleRate
    }

    deinit {
        storage.deinitialize()
        storage.deallocate()
    }

    /// Steals the quietest voice when the pool is full. Dropping the softest
    /// note is far less noticeable than dropping the newest one, which would
    /// make the instrument feel broken under load.
    private func allocate() -> Int {
        var quietest = 0
        var quietestEnv = Double.infinity
        for i in storage.indices {
            if !storage[i].active { return i }
            if storage[i].env < quietestEnv {
                quietestEnv = storage[i].env
                quietest = i
            }
        }
        return quietest
    }

    func noteOn(
        kind: VoiceKind,
        frequency: Double,
        amp: Double,
        attack: Double,
        decay: Double,
        pan: Double = 0.5,
        cutoff: Double = 6_000,
        hold: Double = 0
    ) {
        let index = allocate()
        var v = Voice()
        v.active = true
        v.kind = kind
        v.phase = 0
        // Normalised: cycles per sample, so phase runs 0..<1 per period.
        v.phaseInc = frequency / sampleRate
        v.amp = amp
        v.env = 0
        v.pan = pan
        v.attackRate = attack <= 0 ? amp : amp / (attack * sampleRate)
        // Exponential decay expressed as a per-sample multiplier reaching
        // -60dB at `decay` seconds.
        v.decayRate = pow(0.001, 1.0 / max(decay * sampleRate, 1))
        v.holdSamples = hold > 0 ? Int(hold * sampleRate) : 0
        v.filter.setCutoff(cutoff, sampleRate: sampleRate)
        v.noise = FastNoise()

        storage[index] = v
    }

    /// Mixes every active voice into an interleaved stereo pair.
    func render() -> (left: Double, right: Double) {
        var left = 0.0
        var right = 0.0
        for i in storage.indices where storage[i].active {
            let s = storage[i].render()
            let pan = storage[i].pan
            left += s * (1.0 - pan)
            right += s * pan
        }
        return (left, right)
    }

    func allNotesOff() {
        for i in storage.indices { storage[i].active = false }
    }
}

// MARK: - Pitch helpers

enum Pitch {
    /// MIDI note number to Hz. A4 = 69 = 440Hz.
    static func hz(_ midi: Double) -> Double {
        440.0 * pow(2.0, (midi - 69.0) / 12.0)
    }
}
