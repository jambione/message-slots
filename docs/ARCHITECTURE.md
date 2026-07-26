# Message Slots — Technical Architecture

*The "how" behind GAME_DESIGN.md. Target: iOS 17+, iPhone-first, Swift 6, SwiftUI + SpriteKit.*

---

## 1. Guiding constraints

1. **Deterministic core.** All game logic (spins, scoring, combos) is a pure, seedable state machine with zero UIKit/SwiftUI imports. This makes it unit-testable, replayable (score-breakdown animations replay real events), and multiplayer-safe (async opponents verify turns by re-running them from the seed).
2. **Offline-first.** Pass & Play and Solo need no network, no account, no server. Online (v1.1) rides Game Center so we still run no server.
3. **Everything is data.** Word pools, reel weights, bonus rates, scoring constants, pity thresholds — all in bundled JSON, hot-swappable for themes and remotely tunable later without an app update.

## 2. Module map (Swift Package targets)

```
MessageSlots.xcodeproj
├── GameCore          (pure Swift, no UI — the deterministic engine)
│   ├── Models        CoreTypes: PartOfSpeech, WordEntry, Token, BonusKind, Player
│   ├── Random        SeededRNG (SplitMix64, serializable)
│   ├── Economy       EconomyConfig, WordPool (all JSON-driven)
│   ├── Language      SentenceValidator, templates, advisory tagger, SentenceJudge
│   ├── Scoring       ScoreCalculator, ComboDetector
│   ├── Story         Story, StorySentence, PronounMap
│   ├── Engine        TurnState, TurnReducer, SpinResolver + pity, CPUPlayer
│   └── Match         MatchState, MatchEngine, MatchTransport
├── GameUI            (SwiftUI screens + SpriteKit reel scene)
├── Persistence       (SwiftData models, CloudKit sync, Gallery)
├── Multiplayer       (GameKit adapter — v1.1)
├── SharedAssets      (word packs, themes, audio, haptic patterns)
└── MessageSlotsApp   (composition root)
```

Dependency rule: arrows point inward only. `GameUI → GameCore`, never the reverse. `Multiplayer` serializes/deserializes `GameCore` state but contains no rules.

## 3. Core data models

```swift
struct WordEntry: Codable {           // one row of a word pool JSON
    let text: String
    let pos: Set<PartOfSpeech>        // .noun, .verb, .adjective, .article, .connector…
    let tier: Rarity                  // common / uncommon / rare / legendary
    let points: Int
    let tags: [String]                // theme tags: "pirate", "space"
    let semantics: Set<SemanticCategory>  // optional, sparse: .animate/.place/.food/.object/.abstract
                                          // — the "Makes Sense" scoring signal, see §6.2
    let weight: Double                    // draw frequency, default 1.0 — see §5.1
}

enum Token: Codable {
    case word(WordEntry, gem: Gem?)   // gem attaches at bank time
    case bonus(BonusKind)             // .wordGem(2), .sentenceStar, .extraTry,
}                                     // .frenzy, .wildCard, .swap, .gift, .rust(value:)

struct TurnState: Codable {
    var reels: [ReelFace]             // 5 faces, each .spinning/.landed(Token)/.banked
    var tray: [PlacedWord]            // ordered, ≤10
    var triesRemaining: Int           // starts 5, mutated by ExtraTry
    var heldBonuses: [BonusKind]      // swap, gift
    var rng: SeededRNG                // SplitMix64; the whole turn replays from this
}

struct MatchState: Codable {
    var mode: Mode
    var players: [Player]
    var teamBank: Int
    var teamStreak: Int
    var story: Story?                 // Story Mode only
    var roundIndex: Int
    var turnHistory: [CompletedTurn]  // enables replay, gallery, telemetry
}

struct Story: Codable {
    var sentences: [StorySentence]    // text + author + score
    var knownNouns: [String: Gender]  // for pronoun-map callback detection
    var endingWord: String            // chapter-close target
    var chainLevel: Int               // combo chain multiplier state
}
```

## 4. The turn state machine

```
idle → spinning → landed → banking ⇄ arranging → lockedIn → scoring → handoff
              ↑______________________|   (spend try, only unbanked reels)
```

Implemented as an enum-state reducer: `func reduce(_ state: TurnState, _ action: TurnAction) -> (TurnState, [Effect])`. Actions: `.spin`, `.bank(reelIndex, trayIndex)`, `.reorder`, `.useBonus`, `.typeWildCard(String)`, `.lockIn`. Effects (haptics, sounds, animations) are emitted as values and executed by GameUI — the reducer stays pure.

Why a reducer: the score-breakdown replay, async-multiplayer verification, tutorial scripting, and TestFlight bug repro all become "feed a recorded action list back through the reducer."

## 5. Spin resolution & economy

`SpinResolver` per unbanked reel: pick tier by reel-role weights → pick word within tier (theme/story-bias weights applied) → roll bonus slot (capped at 2 bonus faces per spin).

`PityController` runs *before* weighting each spin, inspecting tray + tries:

- No verb-capable token banked && tries ≤ 2 → verb weight ×3 on all reels.
- Story Mode, final turn, ending word never surfaced → inject on a random reel.
- Guarantee invariant: every full-spin result contains ≥1 noun-capable and ≥1 verb-capable face.

All rolls consume the turn's `SeededRNG` in a defined order, so a `(seed, actions)` pair fully reproduces the turn.

Economy JSON (per mode/difficulty): tier shares, reel role matrix (5×POS weights), bonus rates, pity thresholds, scoring constants. Ship defaults from GAME_DESIGN.md §3; tune from telemetry.

### 5.1 Word frequency is not rarity

`WordEntry.weight` (default 1.0) scales a word's chance of being drawn once its category and tier have been rolled. It is deliberately a separate axis from `tier`:

- **`tier`** = what a word is *worth*. Legendary words score more.
- **`weight`** = how often you *see* it.

Function words are the case that forces the distinction. Every determiner in the pool is `common` and worth 1 point, but English is not uniform across them — and with all ten equally likely, the determiner slot spread so thin that "the" reached the reels on about 6% of spins, so trays read *"Friend ate"* rather than *"The friend ate"*. Weighting `the` at 9 and `a` at 6 against 0.6–1.2 for the possessives and demonstratives raises the chance a spin offers "the" or "a" from **10.3% to 31.5%**, while leaving the overall determiner rate unchanged at 46.2% — this redistributes *within* the category rather than crowding out nouns and verbs.

Note the alternative fix that was rejected: deleting the rare determiners would have hit the same numbers while permanently removing variety. Weighting keeps "every kraken" reachable, just uncommon.

Measured by `tools/balance_sim.py`, which mirrors the same weighting in `draw_word` — a uniform `rng.choice` there would silently stop reflecting what players see.

## 6. Language engine (the hard part)

Two-layer validator, both on-device and offline:

1. **POS template layer (authoritative).** The tray's POS sequence (multi-POS words resolve greedily against templates) must match one of a curated set of sentence templates, expressed as a small regex-like grammar over POS symbols:
   `ART? ADJ* NOUN (ADV? VERB) (ART? ADJ* NOUN)? (CONN CLAUSE)?` etc.
   Templates are data (JSON), so playtesting can add patterns without code changes.
2. **NaturalLanguage sanity layer (advisory).** Apple's `NLTagger` POS-tags the assembled sentence; wild disagreement with the template parse flags "questionable" — used for telemetry and the validity meter's yellow zone, never to reject. Philosophy: **be generous.** False-positives (accepting nonsense) are funny; false-negatives (rejecting valid sentences) are rage-quits.

Validity meter states: red (no template match) / yellow (matches but NL disagrees) / green (both agree). Yellow scores full grammar bonus.

**ComboDetector (Story Mode):** exact-match banked nouns against `story.knownNouns`, plus a pronoun map (octopus→it, tagged-gendered names→he/she, plurals→they). Connector-open = first tray token has `.connector` POS. Chapter close = ending word present in final sentence. No ML judging of coherence — deterministic and explainable, per design doc §5.1.

**Wild Card input:** validated against the bundled dictionary (word must exist in any pool or the fallback lexicon ~30k words) + profanity denylist.

### 6.1 Should a small LLM verify sentences?

Considered and deliberately declined *as the referee*, for three reasons:

1. **Latency.** The validity light updates on every tray drag, inside one frame (16ms). Template matching runs in microseconds; on-device inference is two orders of magnitude slower.
2. **Determinism.** Remote play verifies a teammate's turn by re-running it from `(seed, actions)` and comparing scores (§9.1). Model output varies with OS version, device and sampling — two phones would compute two different scores for the same sentence, and the verifier would flag honest players as cheats. This is the disqualifying reason.
3. **Availability.** On-device models need recent hardware. A player on an older iPhone must not get a different rulebook than the friend they are playing with.

Where a model **is** wired in (`SentenceJudge`, `AdvisoryTagger`):

- **Advisory validity** — can turn a green light yellow and feed telemetry about template gaps. Never rejects, never changes score.
- **Judge's Award** — a small, capped, clearly-labelled flavour bonus ("Most Cinematic", ≤50 pts) plus a quip for the results screen and share card. Because it is not reproducible, the verdict is computed **once on the author's device and travels with the turn payload**; receiving clients replay it rather than recompute it. Wrapped in `TimeLimitedJudge` so a slow model can never stall the results screen.
- **Content pipeline (offline, not shipped)** — drafting theme packs, checking category tags, and mining playtest logs for sentences the templates wrongly rejected. This is the highest-value use: it improves the deterministic grammar without shipping a model at all.

To wire Apple's on-device model, implement `SentenceJudge` in the app target against the Foundation Models framework and inject it; `GameCore` stays free of Apple-only dependencies and keeps building on Linux CI. Verify the framework's API against the current SDK before use.

### 6.2 Semantic coherence ("Makes Sense" bonus)

A third, much smaller signal layered on top of the two-layer validator: does the sentence's subject and verb plausibly go together, not just grammatically agree? `CoherenceEvaluator.evaluate(_ tray:)` (`Language/SemanticCoherence.swift`) finds the tray's first verb-capable word, then the nearest noun-or-pronoun-capable word before it, and checks whether `subject.semantics` and `verb.semantics` — a `Set<SemanticCategory>` of `.animate/.place/.food/.object/.abstract` — share any category. It never runs a model and never touches `ValidationResult`; it feeds one optional line into `ScoreCalculator.styleBonuses`. Design rationale, including why this is deliberately *not* the LLM's job, lives in GAME_LOGIC.md §5.1.

**Content schema.** `WordEntry.semantics` is `Codable` with an `decodeIfPresent(...) ?? []` fallback, so older compiled pools without the field decode cleanly to "untagged." The CSV pipeline (`Content/*.csv` → `tools/compile_pools.py`) carries it as an optional 6th, pipe-separated column, with draw frequency as an optional 7th: `text,pos,tier,points,tags,semantics,weight`. Both are omitted from the compiled JSON when they hold their default, so the output stays readable. `compile_pools.py` validates category spelling and warns (not fails) if either side of the noun/verb split has zero tagged words, since that would make the bonus permanently inert without anyone noticing.

## 7. UI architecture

- **SwiftUI** app shell, navigation, tray, HUD, results, gallery. State flows: `GameViewModel` (@Observable) owns `TurnStateMachine`, renders from `TurnState`, dispatches `TurnAction`s.
- **SpriteKit** scene embedded via `SpriteView` for the reel block only: spin physics (overshoot-settle), near-miss choreography, particle effects. The scene is a dumb renderer of reel effects; it never owns game state.
- **Tray** is pure SwiftUI (`draggable`/`dropDestination`), with matched-geometry token flight from reel to tray.
- **Haptics:** CoreHaptics pattern library (`.reelThunk`, `.gemAttach`, `.frenzyRamp`, `.jackpot`) triggered by reducer Effects.
- Screens (8 total, GAME_DESIGN.md §6.4). Handoff screen doubles as privacy shield in pass-and-play (next player can't see remaining reel state — irrelevant in co-op but keeps the ritual).

## 8. Persistence & sync

- **SwiftData**: `PlayerProfile`, `SavedSentence`, `SavedStory`, `MatchRecord`, `UnlockState`. Local-first.
- **CloudKit** (private DB) syncs profile, gallery, and unlocks across the user's devices. No custom backend.
- In-flight match autosave after every reducer transition — process death mid-turn resumes seamlessly.

## 9. Multiplayer — playing on separate phones

The engine is built for this from day one: `MatchState` is `Codable`, and every turn is fully described by `(seed, [TurnAction])`. Any device can reconstruct any turn exactly. That single property gives us async play, cheat resistance, and turn replay for free.

**Transport abstraction.** `GameCore` never knows how bytes move. `Multiplayer` implements one protocol, three ways:

```swift
protocol MatchTransport {
    func send(_ state: MatchState, turn: CompletedTurn) async throws
    var incoming: AsyncStream<MatchUpdate> { get }
}
```

| Transport | Ship | Backing |
|---|---|---|
| `LocalTransport` | v1.0 | In-memory; pass-and-play on one device |
| `GameKitTurnBasedTransport` | v1.1 | `GKTurnBasedMatch` — remote async |
| `MultipeerTransport` | v1.2 | `MultipeerConnectivity` — same-room live |

Because the transport is swappable, a match can **migrate mid-game** (pass-and-play → remote async) by re-hosting the same `MatchState` on a different transport.

### 9.1 Remote async (v1.1)

- `GKTurnBasedMatch`; match data = compressed `MatchState` JSON. 64KB limit is ample — prune `turnHistory` to the last round plus full story text; archive older turns locally.
- **Turn integrity:** each `CompletedTurn` ships `(seed, actions)`. The receiving client re-runs the reducer and compares the score. Mismatch → trust the recompute, flag telemetry. Protects against modified clients without a server.
- **Turn replay for spectating:** the same `(seed, actions)` payload drives the 5-second "here's what your teammate did" replay when a turn opens (GDD §5.2). The replay player is just the reducer stepped on a timer into the normal UI — no separate rendering path, no video.
- Push notifications via GameKit built-ins; deep link straight into the pending turn.
- Invites: Game Center friends, `GKMatchmakerViewController`, and iMessage links (`GKGameSession`-style URL carrying match ID).
- Timeouts: generous default (7 days/turn) with an optional nudge; a timed-out turn auto-locks whatever is in the tray rather than forfeiting — never punish a busy friend with a dead match.

### 9.2 Same-room live (v1.2)

- `MCSession` over Wi-Fi/Bluetooth, host-authoritative: the host device owns the `TurnStateMachine` and broadcasts `(state, effects)` diffs; peers render and send only `TurnAction`s when they're the active player.
- 4-letter room code via `MCNearbyServiceAdvertiser`/`Browser`. No internet, no accounts.
- Reactions and word suggestions are non-authoritative side-channel messages — they never mutate `TurnState`, they only decorate the active player's UI.
- Reconnect: peers rejoin by requesting a full `MatchState` snapshot; the deterministic core means a rejoining phone catches up exactly.

### 9.3 Identity

No account required anywhere. Local players are ad-hoc names; Game Center identity is used only for remote matchmaking and is never required to play.

## 10. Word pool pipeline

- Source of truth: CSV per pack (`word,pos,tier,points,tags`) in `/Content`, compiled to JSON by a build-phase script that also validates (no dupes, POS coverage quotas per tier, profanity screen, template-solvability check: can this pool actually form sentences?).
- Starter pack target: ~1,200 words (55/30/12/3 tier split, POS quotas: ≥25% verb-capable, ≥30% noun-capable, ≥8% connectors/articles).
- Theme packs are additive overlays with their own `tags`, loaded per mode config.

## 11. Testing strategy

- **GameCore**: exhaustive unit tests — scoring table cases from GDD §4.2, pity invariants (property-based: "every spin has noun+verb capability"), combo detection fixtures, template acceptance corpus (200 valid / 200 invalid sentences, target ≥95% / ≥80%).
- **Determinism test**: record real playtest turns, assert replay equality — this test doubles as the multiplayer verifier.
- **UI**: snapshot tests for screens; XCUITest for the golden path (spin→bank→lock→score→handoff).
- **Balance**: headless simulation harness — 10k bot turns per economy config, outputs the health metrics from GDD §8 (validity %, median length, pity rate) so tuning happens before human playtests.

## 12. Telemetry & privacy

TelemetryDeck (or equivalent privacy-first): anonymous, no PII, no sentence text ever uploaded by default (sentences are user content; share is explicit). Events: turn summaries (GDD §8 fields), funnel (tutorial completion, mode starts), economy health. Privacy manifest accordingly; no ATT prompt needed.

## 13. Performance budgets

- Reel spin: 60fps sustained on iPhone 12; SpriteKit scene ≤ 3ms/frame.
- Spin resolve + validity check: < 16ms (one frame) — POS templates are trivially fast; NLTagger runs async off the hot path.
- Cold launch → title: < 1.5s; word pool JSON lazy-loaded per mode.
- Match data (async): < 32KB compressed typical.

## 14. Build order dependency graph

```
WordPool JSON + schema ─┐
SeededRNG + SpinResolver ├─→ TurnStateMachine ─→ ScoreCalculator ─→ Prototype UI (Phase 0)
POS templates ──────────┘                                   │
                                                            ▼
                              SpriteKit reels + tray + juice (Phase 1)
                              ComboDetector + Story UI (Phase 1)
                              Persistence + Gallery (Phase 2)
                              GameKit adapter (Phase 4)
```

Phase numbering matches ROADMAP.md. The Phase 0 prototype uses the *real* GameCore with placeholder UI — engine code is never throwaway.
