# Message Slots — Audio

*Sound effects and music. Companion to [GRAPHICS.md](GRAPHICS.md) — same role, different sense.*

---

## 1. The split: effects are generated, music is authored

| | How it's made | Where it lives |
|---|---|---|
| **Sound effects** | Synthesised in code at runtime | `App/Audio/SoundSynth.swift`, `AudioEngine.swift` |
| **Music** | An audio file you supply | dropped into the app target |

This split isn't arbitrary. Short UI cues are a genuinely good fit for synthesis: no assets to ship, no loading, and a cue can be *parameterised* — the sound of banking a word is pitched by that word's part of speech, which no fixed audio file could do.

Music is the opposite case, and we learned it the hard way. A first version generated an adaptive smooth-jazz score in code — ii–V–I changes, walking bass, brushed percussion, layers that thickened as a turn got tense. It was structurally correct and it sounded bad. **Procedural music was removed.** Multi-minute music that has to be *pleasant* on the hundredth listen is a composition problem, not an engineering one, and code-generated instruments land in an uncanny valley where the harmony is right but the timbre is lifeless.

---

## 2. Adding your music

1. Drag an audio file into the Xcode project, into the app target, named **`background_music`** (any extension: `.m4a`, `.mp3`, `.wav`, `.caf`, `.aiff`).
2. That's it. `AudioDirector.start()` looks for it and plays it looping at 35% volume.

If the file isn't there, `loadMusic` returns false and the game runs silently — a missing asset is never a crash.

To use a different name, change `AudioDirector.musicAsset`.

**Format note:** prefer `.m4a` or `.caf` for anything meant to loop seamlessly. MP3 carries encoder padding at the start and end of the file, which puts an audible gap at the loop point.

**Looping** re-schedules the file on completion rather than decoding it into a single buffer, so a long track doesn't sit decompressed in memory.

### If you want the music to react to gameplay later

The hook is `AudioDirector` — it already receives every game `Effect` and knows the turn state. Layered stems (a rhythm bed plus an overlay that fades in as tries run out) would slot in without engine changes: load several files, cross-fade their player volumes. That's the version worth building if the music should track the five-try tension arc in [GAME_LOGIC.md §3](GAME_LOGIC.md), and it works with real recordings rather than synthesised ones.

---

## 3. The cue list

Driven off `Effect` values from the reducer. Because a replayed turn emits an identical effect sequence, **a teammate's replayed turn sounds exactly as it did when they played it** — no separate audio scripting.

| Cue | Fires on | Sound | Reasoning |
|---|---|---|---|
| `reelSpin` | `.reelsSpun` | Filtered noise sweep | The mechanical whir; sells the machine |
| `reelStop` | `.reelsSpun` | Low thump + click | Physical weight of something landing |
| `bankWord` | `.wordBanked` | Mallet, **pitched by part of speech** | See §4 |
| `removeWord` | `.wordReturnedToReel` / `.wordDiscarded` | Soft descending pair | Removing is free and encouraged — must not sound like an error |
| `bonus` | `.bonusCollected`, `.gemAttached` | Rising bell figure | Unambiguously "good thing happened" |
| `extraTry` | `.tryGranted` | Single bright bell | Distinct from `bonus` — a different kind of gift |
| `validGreen` | transition into valid | Rising major third | Smallest gesture that reads as "yes" |
| `frenzyStart` | `.frenzyStarted` | Bell pair, high | The signature moment (GAME_DESIGN.md §3) |
| `lockIn` | `.sentenceLocked` | Warm major chord | Closes the turn |
| `scoreLine` | score sheet reveal | Ascending pentatonic | A long breakdown climbs; never runs out of scale |
| `rejected` | `.rejected` | Muted low thud | The game never scolds ([GAME_LOGIC.md §4](GAME_LOGIC.md)) — neither does the audio |

Two rules the table encodes:

- **Nothing punitive.** `rejected` and `removeWord` are the only "negative" sounds and both are soft and low. A buzzer would contradict the whole anti-frustration stance.
- **Frequent cues are quiet.** `validGreen` fires on every transition into a valid sentence and is mixed at roughly a third of `bonus`. A sound that plays constantly at full volume stops being feedback and becomes noise.

---

## 4. Banking a word plays a note

`bankWord` is pitched by the word's grammatical category:

| Category | Note |
|---|---|
| adverb | G5 |
| adjective | F5 |
| verb | D5 |
| noun | C5 |
| pronoun | A4 |
| preposition | G4 |
| conjunction | F4 |
| article | D4 |

Two things fall out of this for free:

1. **Building a sentence plays a melody.** "The grumpy octopus tangoed" has a different tune than "dog cat moon" — the tray becomes audible, not just visible.
2. **It teaches the taxonomy through a second sense**, the same job the colour coding does in [GRAPHICS.md §2.2](GRAPHICS.md) — and it works for players who can't rely on the colours at all.

The pitches are **F major pentatonic**, so any order of words sounds consonant. A chromatic mapping would carry more information per note and would sound awful; this has to be pleasant hundreds of times per session, so consonance wins over information density.

---

## 5. Real-time constraints

The synthesiser runs in an `AVAudioSourceNode` render callback with a deadline in microseconds. The rules, and why they're not optional:

- **No allocation, no locks, no ARC traffic** in the render path. Voices live in a preallocated `UnsafeMutableBufferPointer`; the cue queue is drained into a reused scratch array.
- **No transcendental functions per sample.** A 4096-entry interpolated sine wavetable replaces `sin()`; a cubic replaces `tanh()`.
- **`tryLock`, never `lock`.** A dropped cue is inaudible; an audio thread blocked on the main thread is very audible.

The first version violated the first two rules — returning a fresh array per sixteenth note and calling `sin()` several times per voice per sample — and CoreAudio logged `IOWorkLoop: skipping cycle due to overload`, heard as stuttering. Worth stating plainly because the file's own header comment had described the rules correctly while the code broke them.

**Known:** the overload message can still appear in **debug** builds when several cues fire at once, since unoptimised Swift carries bounds checks and retain/release through the mix loop. Check against a Release build before treating it as a real defect.

Audio session category is **`.ambient` with `.mixWithOthers`**, so the game never interrupts the player's own music or podcast. Revisit only if a licensed soundtrack makes that the wrong default.

---

## 6. Not built yet

- **Haptics.** `Effect` is the right seam and CoreHaptics patterns (`.reelThunk`, `.gemAttach`, `.jackpot`) are specified in [ARCHITECTURE.md §7](ARCHITECTURE.md), but nothing is wired.
- **Staggered reel landings.** All five reels currently land on one `reelStop`. Five sounds cascading over ~400ms is much of what makes a slot machine feel physical; needs a scheduled cue queue rather than immediate triggering.
- **Ducking.** Music should dip briefly under the grammar ×2 reveal, the score sheet's "applause moment" ([GAME_LOGIC.md §5](GAME_LOGIC.md)).
- **Separate music / effects volume controls.** The header toggle is currently all-or-nothing; the settings screen doesn't exist yet.
- **Score-sheet reveal timing.** `playScoreLine(index:)` exists but the sheet doesn't call it per line yet.
