# Message Slots — Functionality Spec

*What the application does: screens, modes, systems, and platform features. Mechanics/fun reasoning is in [GAME_LOGIC.md](GAME_LOGIC.md); visual design is in [GRAPHICS.md](GRAPHICS.md); technical implementation is in [ARCHITECTURE.md](ARCHITECTURE.md).*

Status column reflects what's actually built (`Sources/GameCore/`, `App/`) vs. designed-not-built, as of the Phase 0 prototype.

---

## 1. Platform

| | |
|---|---|
| Target | iPhone-first, iPad later |
| Minimum OS | iOS 17 |
| Orientation | Portrait only (v1.0) |
| Accounts | None required for any local or same-room mode. Game Center only for Remote Play matchmaking. |
| Monetization | Free; one-time "remove ads" IAP; cosmetic skins/word packs. No purchasable score advantage, ever (GAME_DESIGN.md §7). |

---

## 2. Game modes

| Mode | Players | Status | Function |
|---|---|---|---|
| Pass & Play | 2–4, one device | **Built** (prototype) | Turns alternate on one phone |
| Story Mode | 2–4 | **Built** (engine + prototype UI) | Sentences chain into a shared story with combo scoring |
| Beat the House / Target | 2–4 | **Built** (engine) | Team races a target score across rounds |
| Solo + CPU teammate | 1 (+bots) | **Built** (engine + prototype UI) | Full co-op loop against a bot partner |
| Remote Play (separate phones) | 2–4 | Designed, not built | Game Center async turns with push notifications and turn replay |
| Same Room (separate phones) | 2–4 | Designed, not built | Local network room code, live shared reels |
| Daily Spin | ∞ (global seed) | Designed, not built | Shared daily puzzle, one attempt, share card |
| Themed Rounds | any | Partially built (theme tags exist in word pool + scoring) | Rotating word packs with double-scoring theme words |

---

## 3. Screens

| Screen | Status | Function |
|---|---|---|
| Game screen | **Built** (prototype) | Reels, tray, lever, tries, team bank, story strip |
| Score sheet | **Built** (prototype) | Line-by-line score breakdown, continue button |
| Title / mode select | Not built | Entry point, choose mode |
| Player setup | Not built | Names, avatars, team name, CPU seat assignment |
| Turn handoff | Not built (score sheet currently doubles for this) | "Pass to [name]" transition between local players |
| Round results | Not built | End-of-round summary across all players |
| Sentence Gallery | Not built | Saved sentences/stories, share sheet |
| Settings | Not built | Audio, haptics, accessibility, word packs, difficulty |

**Next screen to build:** Title/mode select and Player setup — required before Pass & Play is a complete loop rather than a fixed two-player prototype.

---

## 4. Core turn functionality

Fully implemented in `GameCore` (`TurnReducer`, `TurnState`, `SpinResolver`) and exercised in the prototype:

- **Spin** — pull-to-spin gesture or SPIN button; unbanked reels re-spin, banked words stay in the tray, their reels refill.
- **Bank** — tap a reel to move its word into the tray; free (costs no try).
- **Arrange** — native drag-and-drop reordering within the tray (`draggable`/`dropDestination`), always free, never costs a try (GAME_LOGIC.md §2.1).
- **Remove from tray** — a small × control on each tray token un-banks it (not a long-press: `.draggable()` claims the long-press gesture to start its own drag session, so a long-press handler on the same view never fires — found and fixed during on-device verification). If the word's origin reel hasn't been spun since it was banked, the word returns there and can be re-banked or left to respin; if that reel has already moved on, the word is discarded instead. No resource spent to place a word (Gem, Wild Card) is ever refunded on removal. This is a deliberate design line, not a placeholder — see GAME_LOGIC.md §2.1.
- **Lock in** — available once ≥2 words are banked; forced when tries reach 0.
- **Live validity meter** — updates on every tray change; red/yellow/green states plus a plain-language nudge ("Needs a verb").
- **Sound effects** — synthesised at runtime, mapped from reducer `Effect` values; the bank sound is pitched by part of speech so a sentence plays a melody. Background music plays from a supplied audio asset (none shipped yet). Muted from a header toggle. See [AUDIO.md](AUDIO.md).
- **"Makes Sense" bonus** — a flat +30 style bonus (`EconomyConfig.senseBonus`) when the tray's subject and verb are both hand-tagged with a compatible semantic category (`Language/SemanticCoherence.swift`); additive only, never affects validity or the grammar multiplier. Rendered automatically by the existing generic style-bonus list in the score sheet — no new UI needed. See GAME_LOGIC.md §5.1.
- **Bonus token handling** — Word Gem, Sentence Star, Extra Try, Frenzy, Wild Card, Swap, Gift, Rust — all implemented in the reducer; Wild Card word entry and Swap/Gift UI are not yet built into the prototype screen.
- **Frenzy** — free re-spins on one reel, capped at 12 spins (`EconomyConfig.maxFrenzySpins`) so a turn can always end.

---

## 5. Match & multiplayer functionality

Implemented in `GameCore` (`MatchState`, `MatchEngine`, `MatchTransport`):

- **Shared team bank** — every player's score pools into one total; no individual leaderboard in co-op modes.
- **Shared streak** — resets on any invalid sentence, regardless of who played it.
- **Turn order** — round-robin across players (human or CPU).
- **Gifts** — a collected Gift Token boosts and forwards a bonus to the next player's turn automatically.
- **Story accumulation** — locked sentences append to a shared story; combo detection runs against it.
- **Transport abstraction** (`MatchTransport` protocol) — `LocalTransport` implemented; `GameKitTurnBasedTransport` (remote async) and `MultipeerTransport` (same-room) are designed but not implemented.
- **Turn verification** — any device can re-run a turn from `(seed, actions)` and confirm the claimed score, with no server. Implemented and tested (`MatchEngine.verify`); not yet exercised over a real network transport.
- **Mid-match transport change** — a match can move from Pass & Play to Remote Play without altering rules (`MatchState.connectivity` is mutable, tested in `testAMatchCanChangeTransportMidGame`).

---

## 6. CPU teammate functionality

Implemented (`CPUPlayer`, `MatchEngine.playCPUTurn`):

- Three skill presets — Sprocket (rookie), Wordsworth (steady), Cogsworth (sharp) — differing in greed threshold and target sentence length only.
- Plays through the same reducer as a human: same actions, same rules, fully replayable.
- Automatically fills empty seats, can be assigned per player slot.
- Paced playback in the prototype (~700ms "thinking" delay) so a bot's turn is watchable rather than instant.

Not yet built: a settings UI to choose CPU skill, and drop-in cover (converting a human seat to CPU mid-match when a remote player leaves) — this depends on the Remote Play transport landing first.

---

## 7. Content & data functionality

- **Word pool pipeline** — CSV source (`Content/words_starter.csv`) → validated, compiled JSON (`tools/compile_pools.py`) → bundled resource loaded by `WordPool.bundled()`. Validates category quotas, tier mix, duplicate words, and Story Mode ending-word coverage before it will produce output.
- **Word frequency weighting** — an optional 7th CSV column (`weight`, default 1.0) controls how often a word surfaces, separately from its tier/value. Used to make `the` and `a` dominate the determiner slot the way they dominate English; raises the chance a spin offers one from 10.3% to 31.5% without changing how often determiners appear overall. See ARCHITECTURE.md §5.1.
- **Semantic tagging** — an optional 6th CSV column tags nouns/verbs with `animate`/`place`/`food`/`object`/`abstract` for the "Makes Sense" bonus. Currently covers 89 of 206 starter-pool words (common/uncommon nouns and verbs, plus all pronouns); the compiler warns if either side of the noun/verb split ends up with zero tagged words.
- **Economy configuration** — every tunable number (reel weights, bonus rates, scoring constants, pity thresholds) lives in `EconomyConfig`, JSON-codable, with `.default`, `.easy`, `.hard` presets. No tunable is hard-coded in engine logic.
- **Balance simulator** — `tools/balance_sim.py` runs thousands of headless bot turns per player profile and checks against recorded regression bands; used to catch economy regressions before a human ever plays.
- **Persistence** — designed (SwiftData local + CloudKit sync for gallery/progression, ARCHITECTURE.md §8), not implemented — the prototype holds match state only in memory.

---

## 8. Accessibility functionality

Designed, partially built:

- **VoiceOver** — token chips carry accessibility labels ("octopus, noun, 5 points") in the prototype (`TokenChip`, `BonusChip`). Full screen navigation order and reel/tray semantics not yet audited.
- **Always-available SPIN button** — the pull-to-spin gesture is never the only path to a spin; a standard button sits below it and is what VoiceOver and Switch Control use. Built in the prototype.
- **Reduced motion** — designed (instant reel results, no spin animation) but not implemented; the current reel view always animates.
- **Dynamic Type** — token chips use `minimumScaleFactor` as a stopgap; a full Dynamic Type audit is outstanding.
- **Colorblind-safe category coding** — each word category has both a color and a text abbreviation (n. / v. / adj. / adv. / conj. / prep.) so color is never the only signal (GRAPHICS.md §3).

---

## 9. Content safety functionality

- **Family-friendly word pools** — curated by design; no profanity in the shipped starter pool.
- **Wild Card validation** — a Wild Card word must exist in the loaded pool (or a future fallback dictionary); free-text profanity filtering is designed but not yet implemented as a separate denylist pass.
- **Target audience** — 9+.

---

## 10. What's explicitly out of scope for v1.0

- Any purchasable gameplay advantage (permanent design rule, not a v1.0-only omission).
- Turn timers (untimed by default; an optional party-timer toggle is a later consideration).
- Text chat or voice — the game is designed to be played with people physically or virtually already talking; it doesn't need to replace that channel.
- Non-English word pools (localization is a Phase 5 consideration; each language needs its own hand-tuned pool, not a translation of the English one).

---

## 11. Immediate next-build priorities

In order of what unblocks the most other work:

1. **Title / mode select + Player setup** — without these, the prototype only ever starts one fixed 2-player Story Mode match. This is required before any real playtesting session can happen with a group.
2. **Turn handoff screen** — currently the score sheet's "Next turn" button does double duty; a real pass-and-play game needs a moment that says "hand the phone to Sam" clearly, especially since the reels reset behind it.
3. **Drag-and-drop tray** — tap-to-reorder is a placeholder; it visibly competes with the pull-to-spin gesture near the bottom of the screen (see GRAPHICS.md §6).
4. **Settings screen with CPU skill picker** — needed to let a solo player choose their teammate's difficulty rather than always facing Wordsworth.

*(Drag-and-drop tray reordering and remove-to-reel, both listed above, shipped in the prototype and are no longer on this list — retained here as a record that priority #3 from the previous revision of this doc is done.)*
