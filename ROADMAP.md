# Message Slots — Design Outline & Build Roadmap

*A cooperative word-slots game for iPhone. Spin words, bank the good ones, build the best sentence together.*

Working title options: **Message Slots**, **Sentence Spinner**, **Word Jackpot**, **Spin a Yarn**

---

## 1. Game Concept

Two or more players take turns at a slot machine whose reels land on **words** instead of symbols. Each player spins, banks promising words, and tries to assemble the highest-scoring **sentence** within a limited number of tries. Scores pool into a shared team total — it's cooperative, so you win (or lose) together against a target score, a timer, or an escalating "house."

### Design pillars
1. **Fast, juicy, tactile** — spins feel like a real slot machine: haptics, sound, momentum.
2. **Cooperative, not competitive** — my great sentence helps *us*; players cheer each other on.
3. **Creative expression** — funny/absurd sentences are the real reward; scoring rewards both skill and silliness.
4. **Snackable turns** — a turn takes 30–90 seconds; a full round fits in a coffee break.

---

## 2. Core Gameplay Loop

### A turn, step by step
1. **Spin** — 5 reels spin and land on word tokens (drawn from weighted word pools: nouns, verbs, adjectives, articles, connectors, wildcards).
2. **Bank** — drag any landed words down into your **Sentence Tray** (the sentence you're building). Banked words are locked in.
3. **Re-spin** — unbanked reels re-spin. You start each turn with **5 tries** (spins).
4. **Build** — arrange banked words in the tray in any order. A live **grammar/validity meter** shows whether the tray currently forms a valid sentence.
5. **Lock in** — when out of tries (or satisfied early), lock your sentence. Score is calculated and added to the **team bank**.
6. **Pass the reels** — next player's turn begins. Some bonuses carry over (see Bonus Tokens).

### Sentence validity
- Minimum: subject + verb (e.g., "Dogs dance").
- A lightweight on-device grammar checker validates structure (see Tech, §7). Fallback: template matching (ART? ADJ* NOUN VERB ...) for offline reliability.
- Invalid trays can still be locked for a small consolation score ("word salad" — 25% value) so no turn feels like a total loss.

### Scoring
| Factor | Effect |
|---|---|
| Word rarity | Each word has a point value (common = 1–2, rare = 5–10), shown on its token like Scrabble tiles |
| Sentence length | Multiplier: 3 words ×1, 5 words ×1.5, 7 words ×2, 9+ ×3 |
| Grammar bonus | Fully valid sentence ×2 |
| Unused tries | +10 per spin left (rewards efficiency) |
| Style bonuses | Alliteration, rhyme, using all 5 original reels, theme-of-the-round words |
| Streaks | Team streak: consecutive valid sentences ramp a shared multiplier ×1.1 → ×2 |

### Bonus tokens (land on reels alongside words)
- **×2 / ×3 Word Gem** — attaches to the next word you bank, multiplying its value.
- **Sentence Star** — multiplies your final sentence score ×1.5.
- **Extra Try** — +1 spin this turn.
- **Free Spin Frenzy** — unlimited re-spins for one reel slot for 15 seconds.
- **Wild Card** — becomes any word you type (must be a real dictionary word).
- **Swap Token** — trade one banked word back for a fresh spin of that reel.
- **Gift Token** — banked bonus passes to your *teammate's* next turn (reinforces co-op).
- **Rust Token** (hazard) — a word that loses value each try you wait to bank it; risk/reward.

---

## 3. Game Modes

1. **Pass & Play (v1.0 launch)** — two+ players share one phone, alternating turns. Zero-friction way to play with a friend.
2. **Story Mode (v1.0)** — each turn's sentence chains into one shared story; continuity (callbacks, threads, connector openings, chapter-ending words) earns **combo points** and a growing chain multiplier. Full spec in docs/GAME_DESIGN.md §5.1.
3. **Beat the House / Target Mode** — the team faces a target score across N rounds. Difficulty tiers unlock word packs.
4. **Remote Play on separate phones (v1.1)** — Game Center turn-based matches; play a turn, your friend gets a push notification, and their turn opens with a replay of yours. Story Mode async — a saga unfolding over days — is the standout. Spec: docs/GAME_DESIGN.md §5.2.
5. **Same Room, separate phones (v1.2)** — local network/Bluetooth room code; everyone watches the same reels live on their own device.
6. **Daily Spin (v1.2)** — everyone worldwide gets the same seeded reels; one attempt; shareable result card (Wordle-style social hook).
7. **Themed Rounds** — "Pirate Week," "Space," "Rom-Com": themed word pools and matching visuals; theme words score double.
8. **Solo Practice** — same loop vs. your own high score; good tutorial vehicle.

---

## 4. Player Experience & Retention

- **Onboarding**: 60-second interactive tutorial disguised as your first spin — no text walls.
- **The Sentence Gallery**: every locked sentence is saved; the funniest ones become shareable cards (sentence + score + slot-machine art) for iMessage/social.
- **Progression**: XP → levels → unlock word packs (fancy adjectives, dinosaurs, slang), machine skins (retro Vegas, sci-fi, wooden saloon), and new bonus tokens.
- **Team identity**: name your duo/team; team stats, best-ever sentence, longest streak.
- **Juice checklist**: reel spin haptics (CoreHaptics), coin-cascade on big scores, confetti on grammar bonus, distinct per-token sounds, celebratory callouts ("NICE SENTENCE!").
- **Accessibility**: VoiceOver labels on all tokens, Dynamic Type, colorblind-safe token colors, reduced-motion mode (no spinning animation).
- **Family-friendly**: curated word lists, profanity filter on Wild Card input; aim for age 9+.

### Monetization (light, co-op-friendly)
- Free with ads-free premium unlock (one-time IAP).
- Cosmetic machine skins and themed word packs as IAP; **never** sell score advantages — it's co-op, pay-to-win would poison it.

---

## 5. Screens (v1.0)

1. Title / mode select
2. Player setup (names, avatars, team name)
3. **Game screen** — reels top, sentence tray bottom, tries counter, team bank, bonus slots
4. Turn handoff screen ("Pass to Sam!")
5. Round results — sentences replayed with scoring breakdown animation
6. Sentence Gallery + share sheet
7. Settings (audio, haptics, accessibility, word packs)

---

## 6. Tech Stack

| Concern | Choice | Why |
|---|---|---|
| UI | SwiftUI + SpriteKit overlay for reels | SwiftUI for menus/tray; SpriteKit for performant spin physics & particles |
| Language | Swift 6 | |
| Grammar check | `NaturalLanguage` framework (POS tagging) + template rules | On-device, offline, fast |
| Word lists | Bundled JSON word pools with POS + rarity + point value | Curatable, theme-packable |
| Multiplayer | GameKit `GKTurnBasedMatch` (v1.1) | Free async turns, matchmaking, no server to run |
| Persistence | SwiftData (local), CloudKit sync for gallery/progression | |
| Haptics/Audio | CoreHaptics + AVAudioEngine | |
| Analytics | Lightweight, privacy-first (e.g., TelemetryDeck) | |
| Min target | iOS 17, iPhone-first (iPad later) | |

---

## 7. Build Roadmap

### Phase 0 — Prototype the fun (2–3 weeks) — *engine complete*
- [x] Word pool schema + content pipeline (`Content/*.csv` → `tools/compile_pools.py` → JSON, with validation)
- [x] Starter pool: 206 words across the six categories *(grow toward 1,200)*
- [x] `GameCore` package: seeded RNG, spin resolver, reel roles, verb pity, dead-end guarantee
- [x] Template grammar validator + advisory tagger seam
- [x] Scoring engine, style bonuses, Story Mode combo detection
- [x] Turn reducer (pure, replayable), match engine, transport seam
- [x] CPU teammate (three skills) playing by the same rules
- [x] Test suite: scoring cases, pity invariants, determinism/replay, remote verification
- [x] Headless balance simulator with regression bands (`tools/balance_sim.py`)
- [x] Ugly-but-playable single-screen SwiftUI prototype (`App/`, `tools/generate_xcodeproj.py`)
- [x] **First simulator run** — builds and plays end to end on iPhone 17 / iOS 26.5: spin, bank, category-coloured tokens, live validity meter, word-salad consolation scoring, story accumulating across turns, CPU teammate taking its turn, shared bank and streak
- [x] Semantic coherence ("Makes Sense") bonus, drag-to-reorder, remove-to-reel, word frequency weighting — all verified on device
- [x] Sound effects (synthesised, mapped from reducer effects); music seam for an authored asset
- [ ] **Kill/iterate gate:** is one turn fun on its own? Playtest with 5 people; tune word pools and try count until it is. *Nothing else matters until this is fun.*

### Blocking the kill/iterate gate

The shortest path to putting this in front of five people. Everything else in Phase 1 can wait behind these.

- [x] **Run the test suite.** Done — and it was worth doing. The suite compiled first time but **7 of 107 tests failed**, uncovering one real engine defect (the dead-end guarantee, below) and one fragile fixture. Now **109 tests, all green**, plus `python3 tools/balance_sim.py --all --turns 2000` meeting every band. The generated Xcode project still has no test target, so this only runs via SwiftPM — that gap is unchanged (see Technical debt below).
- [ ] **Handoff screen** between players. The score sheet currently doubles as one, which means there is no moment where the phone changes hands deliberately — the ritual that makes pass-and-play work socially.
- [ ] **Wild Card text entry.** The bonus is fully implemented in the reducer and completely unreachable in the UI, so the one guaranteed escape from a dead-end turn doesn't exist for a player.
- [ ] **Swap and Gift UI.** Same situation: both work in the engine, neither has a control. Gift in particular is the mechanic that makes cooperation mathematically correct, and right now it only ever fires automatically.
- [ ] Confirm on device that "the" and "a" now reach the reels at the measured rate (simulated at 31.5% of spins, not yet watched).
- [ ] Onboarding — even a single card explaining "bank words, build a sentence, 5 spins". Five playtesters shouldn't need a person sitting next to them.

**Findings from the first test-suite run** — both fixed and verified green. The pattern here is the inverse of the device findings below: these were invisible to *playing* and only a compiler and 2,000 seeds could see them.

- **The dead-end guarantee was broken, and the repair itself was breaking it.** `repairIfDeadEnd` protected only the reels it had written, not reels where the spin had landed a role naturally. So a spin that produced a verb and no noun would enter the noun repair, pick the last plain-word reel — the lone verb — and overwrite it. The guarantee handed back a table with no verb at all: precisely the dead turn it exists to prevent, and the one invariant GAME_DESIGN leans on hardest. **Measured at 21 of 2000 opening spins (~1%) on the shipped pool**, so roughly one dead turn per hundred spins in a playtest. Fixed by protecting the sole provider of each unbanked role before either repair pass runs (`SpinResolver.swift`). Two regression tests added: the specific seed that regressed, and a 2,000-seed sweep over the *shipped* pool — the fixture pool is small enough that the existing 300-seed test caught only 6 cases and no test exercised the real content at all.
- **The same bug was in `tools/balance_sim.py`, in a worse form** — the Python mirror had no reel protection whatsoever, so its NOUN pass could overwrite the verb its own VERB pass had just placed. Exactly the silent drift flagged under Technical debt, found only because the Swift fix prompted a look. Ported across; all bands still pass, so the economy is unmoved.
- `testLockedTurnRejectsFurtherActions` was a **fragile fixture, not an engine bug** — the lock guard is correct. The test banked reels 0 and 1 on seed 42, where reel 1 holds a `wordGem`; a bonus attaches rather than filling the tray, so lock-in hit the `tray.count >= 2` guard and the turn never locked. Now it banks two *word* faces explicitly and asserts both preconditions, so a future failure names the real cause.

**Findings from the first run** (fix before playtesting):

- Pull-to-spin could fire more than once per gesture, eating tries. Guarded with a per-pull latch and a larger minimum drag distance — **still needs re-testing with a real finger**, since a synthetic drag is exactly the kind of input that hid the drag-to-reorder bug below.
- ~~Tap-to-reorder in the tray competes with the lever gesture~~ — **fixed:** tray now uses native drag-and-drop, fully separate from the lever gesture. Engine gained real remove-and-restore semantics in the same pass (word returns to its origin reel if untouched since banking, otherwise discarded — arranging is always free, spinning is the only real bet; see docs/GAME_LOGIC.md §2.1). Removal was originally wired to a long-press, but on-device testing found `.draggable()` claims the long-press gesture for its own drag session, so the handler never fired — a real gesture-conflict bug, not a simulator artifact. Replaced with an explicit × button on each token (also more discoverable, better VoiceOver support). Still needs on-device re-verification — the last simulator session ended when the host's screen capture stopped responding, before this fix could be visually confirmed (task #21, blocked pending Mac access).
- **"Makes Sense" coherence bonus added** (post first-run, in response to playtester feedback that a bare noun+verb tray scored the same as a fully-built sentence): an additive-only +30 style bonus when the tray's subject and verb are both hand-tagged with a compatible semantic category — never gates validity, never rejects a silly sentence. Engine, content pipeline (89/206 starter words tagged), Python balance simulator, and Swift test coverage all done; see docs/GAME_LOGIC.md §5.1.

**Findings from the second run** — all resolved and verified on device unless noted. Kept as a record because the *pattern* matters: five of these six were invisible to the test suite and only surfaced by playing the game.

- ~~× button removal unverified~~ — **confirmed working on device.** Tapping × un-banks the word, returns it to its origin reel when that reel hasn't moved on, costs no try, and correctly downgrades the validity meter. Drag-to-reorder also confirmed free and instant. Both bugs from the first run are now closed.
- **"Makes Sense" verified end to end**, including the negative path: *"Mountain saw."* (place noun + animate verb) scored as a fully valid ×2 sentence with no bonus line, exactly as designed — nonsense stays legal, it just doesn't earn extra.
- Score sheet labelled raw word points as "Words", directly above a line reading "Length ×1 · 2 words". For a 3-word sentence it displayed "Words 5", which reads like the sheet contradicting itself. Relabelled "Word points" — same class of trust bug as the ×1.25 rounding issue above.
- Style bonuses computed a `detail` string that the score sheet never rendered, so "+30" appeared with no explanation. Now shown beneath the bonus name ("Makes Sense · grandma sang"), which matters most for the coherence bonus, whose whole purpose is to teach that sense is worth points.
- **Pronouns were untagged**, so *"We levitated."* earned nothing despite `levitated` being tagged `animate`. Pronouns are among the most common subjects in English; all ten are now tagged (see docs/GAME_LOGIC.md §5.1). Found by playing, not by testing — the suite passed before and after.
- **"the" and "a" almost never appeared.** Not a missing-content bug — all ten determiners were in the pool and equally weighted, so the slot spread thin enough that "the" reached the reels on ~6% of spins and sentences read *"Friend ate"*. Added `WordEntry.weight` (draw frequency, separate from tier/value) and weighted the determiners by real usage: a spin now offers "the" or "a" 31.5% of the time, up from 10.3%, with the overall determiner rate unchanged. Regression-tested in `WordFrequencyTests`; see ARCHITECTURE.md §5.1.
- **Reordering by dragging didn't work at all.** `.draggable()` starts a UIKit drag session and waits for a press-and-hold first, so a quick flick did nothing. Replaced with a plain `DragGesture` at a 6pt threshold, with the neighbouring words sliding to show the drop position. Worth noting *why* the earlier on-device check missed this: the synthetic drag held for a full second before moving, which is exactly the gesture `.draggable` wants and no real player performs. **Not yet re-verified on device.**
- **Procedural audio was choppy** — the render callback allocated on every sixteenth note and called `sin()`/`tanh()` per voice per sample. Fixed with a 4096-entry wavetable, a cubic soft-clip and reusable scratch buffers, which cleared the `IOWorkLoop` overload warnings. **But the music was rejected on musical grounds regardless, and has been removed.** Code-generated instruments landed in an uncanny valley — harmonically correct, lifeless to listen to. Music is now an authored audio asset dropped into the app target; the synthesiser remains for short, parameterised sound effects, which is what it's actually good at. See docs/AUDIO.md.
- **Drag-to-reorder verified working** with a quick flick, gap-opening animation and all, and the × remove button still takes taps without the drag gesture swallowing them.
- Score sheet rounded a ×1.25 length multiplier to "×1.2". Fixed — a score sheet that misreports its own arithmetic destroys trust in the whole economy.
- No handoff screen yet between players; the score sheet currently does that job. **Still open** — tracked under "Blocking the kill/iterate gate" above.

### Phase 1 — Core game, Pass & Play (4–6 weeks)

*Engine work here is largely done; what remains is almost entirely presentation. Marked ⚙️ where the rules exist and only the UI is missing — those are cheap.*

- [ ] Real reel visuals in SpriteKit: spin physics, overshoot-settle, near-miss drama. **The single biggest gap between "prototype" and "game"** — reels currently just swap contents with no motion, which removes the anticipation beat the whole loop is built on
- [x] Pull-down-to-spin gesture (latched against double-fire; always-available SPIN button for accessibility)
- [x] Sentence tray with tap-to-bank, drag-to-reorder, tap-× to remove
- [x] Full scoring engine + score breakdown sheet *(reveal is instant; per-line animation still to do)*
- [ ] ⚙️ Bonus token UI: Wild Card entry, Swap, Gift, Frenzy — all working in the reducer, none reachable on screen
- [ ] ⚙️ Turn handoff flow for 2–4 local players *(team bank and target-score rounds already run)*
- [ ] ⚙️ Story Mode UI: story log view *(combo detection, chain multiplier and story-bias reel weighting are all implemented and tested)*
- [ ] ⚙️ CPU teammate UI: skill picker, drop-out cover *(three skills implemented; bot turns already play at human pace)*
- [ ] Haptics pass — `Effect` is the right seam and the pattern library is specified in ARCHITECTURE.md §7, but nothing is wired
- [ ] Audio pass #2: staggered reel landings (five sounds cascading, not one), music ducking under the grammar ×2 reveal, per-line score sheet cues. See AUDIO.md §6
- [ ] Drop in a background music asset (seam ready, no file yet)
- [ ] Settings screen: separate music/effects volume, CPU skill, difficulty preset, accessibility
- [ ] Onboarding tutorial
- [ ] Grow word pool toward ~1,200, tagging semantics and frequency *as words are authored* rather than retrofitting

### Technical debt

- ~~**No test target in the generated Xcode project.**~~ **Resolved.** `tools/generate_xcodeproj.py` now generates three targets — `GameCore.framework` (engine + word-pool resource), `MessageSlots.app` (links and embeds it), and `GameCoreTests.xctest` (links it, `@testable` imports it). The suite runs identically under `swift test` and `xcodebuild test` (109 tests, both green on iPhone 17 simulator), so tests no longer depend on remembering to leave Xcode. Two consequences worth knowing: the App sources now need a real `import GameCore` (four files gained one), and the word-pool JSON ships in the framework bundle rather than the app bundle — `WordPool.bundled` already handled this via `Bundle(for:)`, and a clean build plus device launch confirmed it resolves. The test bundle deliberately has **no `TEST_HOST`**: these are pure logic tests over a framework, so they run without launching the app and cannot be broken by UI work.
- **Balance simulator is a hand-maintained mirror** of the Swift engine (`tools/balance_sim.py`). It has already caught real bugs, but every rule now lives in two places and they can silently drift — the coherence bonus and word weighting each had to be ported by hand. **The drift is no longer hypothetical:** the dead-end repair bug existed independently in both implementations, in *different* forms, and the Python copy was the more broken of the two. A second instance turned up immediately after — `score_turn` accepted an `opening_words` argument and never read it, so the +25 "Full House" bonus went unmodelled and the regression bands were calibrated against an economy slightly below the real one (now fixed; only the `steady` profile moved, mean 96 → 97). Worth raising this above "worth considering" — the simulator validating an economy the engine doesn't actually implement is a failure mode that gets more expensive the longer it stands.
- **Debug-build audio overload.** `IOWorkLoop: skipping cycle due to overload` can still appear when several cues fire at once; unoptimised Swift carries bounds checks and ARC through the mix loop. Re-check against a Release build before treating it as a real defect.
- **Advisory tagger is unproven.** `NaturalLanguageAdvisor` can only downgrade green→yellow and is enforced by a test, but it has never been measured against real playtest sentences to see whether its "reads oddly" judgements are actually useful or just noise.

### Phase 2 — Polish & retention (3–4 weeks)
- [ ] Sentence Gallery + shareable result cards
- [ ] XP, levels, first unlockables (1 skin, 1 word pack)
- [ ] Accessibility pass (VoiceOver, Dynamic Type, reduced motion). The category colours are already Okabe–Ito colourblind-safe with on-token text abbreviations doing the real work (GRAPHICS.md §2.2), and the audio's part-of-speech pitch mapping gives a third channel — but none of it has been tested with an actual screen-reader user
- [ ] Profanity filter, app icon, App Store assets
- [ ] **New token designs** — the two ideas in IDEAS.md, neither yet resolved:
  - *X / hazard token* (removes a word) — collides with "no turn is ever worth zero"; the least punishing execution is probably "removes a word **and** re-spins that reel free", so it reads as a shuffle rather than a loss
  - *Word trade* (take a teammate's word, leave one behind) — needs renaming away from "steal", since in a shared-bank co-op game it's a positive-sum transaction, not theft. Wants a guard so it isn't always the optimal play
- [ ] Tune the open questions in GAME_LOGIC.md §10 from real data — Sentence Star stacking is currently uncapped and is the most likely thing to break the economy
- [ ] Expand semantic tagging to rare/legendary words and adjectives (IDEAS.md)
- [ ] Beta via TestFlight (20–50 testers), tune scoring economy from data

### Phase 3 — v1.0 App Store launch
- [ ] App Review prep (privacy manifest, age rating, IAP for ad-free if included at launch)
- [ ] Launch marketing: share-card virality is the engine — make sharing frictionless

### Phase 4 — v1.1 Remote play on separate phones (4–6 weeks post-launch)
- [ ] `MatchTransport` abstraction + `GameKitTurnBasedTransport`
- [ ] GameKit turn-based async matches + push notifications + deep links
- [ ] Turn replay ("watch what your teammate did") from `(seed, actions)`
- [ ] Reactions on teammate sentences; multi-match home list
- [ ] Friend invites via Game Center + iMessage link
- [ ] Team stats sync via CloudKit

### Phase 5 — v1.2 Same-room live play + live ops
- [ ] `MultipeerTransport`: room codes, host-authoritative session, peer reconnect
- [ ] Spectator view, reaction taps, word suggestions
- [ ] Daily Spin (seeded global puzzle + share card)
- [ ] Themed word-pack events (seasonal)
- [ ] iPad layout; localization (word pools per language are big lifts — start with EN, then ES/FR)

---

## 8. Risks & open questions

- **Grammar checking is the hard part.** Category templates will accept some nonsense and reject some valid sentences. Mitigation: be generous (fun > strictness), let word salad score partial credit, and iterate from playtest logs. A small LLM was considered as the referee and declined — it breaks remote-play determinism; it is wired in as an advisory/flavour layer instead (docs/ARCHITECTURE.md §6.1).
- **Word pool balance is the real economy.** Too many rare nouns and no verbs = frustrating turns. Needs telemetry + tuning like any slots math.
- **Reel weighting must guarantee playability**: every spin should land at least one verb-capable and one noun-capable slot.
- Open: turn timer or untimed? (Recommend untimed for v1, optional timer toggle.)
- Open: max sentence length / tray size? (Recommend 10 words.)

---

*Next step: Phase 0 — I can scaffold the Xcode project and build the playable prototype whenever you're ready.*
