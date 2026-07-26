# Message Slots — Game Design Document

*Companion to ROADMAP.md. This is the "what and why" of every mechanic. ARCHITECTURE.md covers the "how."*

---

## 1. Vision statement

A slot machine where the reels land on **words**, and the jackpot is a **sentence you made together**. Two friends pass the phone (or play async online), each spending 5 tries to bank words and build the best sentence they can. Scores pool into a team bank. The house is the enemy; laughter is the win condition.

The founding principles, verbatim from the design brief:

1. Slots gameplay, but tokens are **words**, not symbols.
2. **Cooperative** play with a friend, 2+ players.
3. A **full sentence** scores points.
4. **5 tries** per turn; you **bank** words between tries.
5. **Bonus tokens** that boost word/sentence score, grant extra tries, or grant free spins to fill a slot.
6. When your sentence is done and scored, **the next player takes a turn**.

Every design decision below traces back to one of these six.

---

## 2. The turn, in detail

### 2.1 Anatomy of the machine

- **5 reels**, each showing one token when stopped.
- Below the reels: the **Sentence Tray** — up to 10 slots where banked words live and get reordered.
- HUD: tries remaining (5 pips), team bank total, active multipliers, current round target.

### 2.2 Turn flow (state by state)

```
SPIN → EVALUATE → BANK/HOLD → (tries left?) → SPIN unbanked reels
                                    ↓ no
                              ARRANGE → LOCK IN → SCORE → HANDOFF
```

1. **Spin.** All 5 reels spin. Reels stop left-to-right with ~200ms stagger (builds anticipation; this is where slots feel comes from).
2. **Evaluate.** Player reads the 5 landed tokens. Tapping a token shows its part of speech and point value.
3. **Bank.** Drag any token down into the tray. Banking is **permanent for the turn** (except via Swap Token). A banked reel refills with a new token on the next spin.
4. **Re-spin.** Costs 1 try. Only unbanked reels spin. Player may also re-spin nothing and just bank more from the current face — banking never costs a try; **spinning costs the try**.
5. **Arrange.** Any time during the turn, tray words can be reordered by drag. Live validity meter updates on every change.
6. **Lock in.** Player taps LOCK IN (available any time after 2+ words banked, or forced when tries hit 0 — with a 10-second grace period to arrange).
7. **Score.** Animated breakdown (see §4). Points flow into the team bank with coin-cascade feedback.
8. **Handoff.** "Pass to [name]" screen (local) or push notification (online). Carry-over effects apply (Gift Tokens, team streak).

### 2.3 Why 5 reels and 5 tries

- 5 reels × 5 tries = up to 25 words seen per turn; enough raw material for a 6–8 word sentence without analysis paralysis.
- 5 tries creates a natural arc: tries 1–2 are exploration (grab a good noun/verb), tries 3–4 are gap-filling ("I need a verb!"), try 5 is desperation/comedy. That last-try tension is the emotional peak of every turn.
- Tunable: difficulty modes can set 4 (hard) or 6 (easy). The prototype must validate 5 as the default.

### 2.4 The dead-turn problem (critical design guard)

Worst case: player banks nouns early, then never lands a verb. Mitigations, in layers:

1. **Reel role weighting** — reels aren't identical. Default archetype: Reel 1 leans articles/pronouns, Reel 2 adjectives, Reel 3 nouns, Reel 4 verbs, Reel 5 mixed/connectors/bonus. Every spin is guaranteed ≥1 verb-capable and ≥1 noun-capable token *somewhere* across unbanked reels.
2. **Pity system** — if the tray lacks a verb and ≤2 tries remain, verb weight on all reels triples. Invisible to the player; feels like luck.
3. **Word salad consolation** — an invalid tray still scores 25% of raw word value. No zero-point turns, ever.
4. **Wild Card token** — the universal escape hatch.

---

## 3. Tokens

### 3.1 Word tokens

Every word token carries: text, **word category** (part of speech), rarity tier, and point value.

**The six categories.** Every word on a reel is one of these — the tray colour-codes them, tokens carry the abbreviation, and reels are weighted by them:

| Category | Tag | Role in a sentence | Examples |
|---|---|---|---|
| **Noun** | n. | The who/what — subjects and objects | octopus, lighthouse, kerfuffle |
| **Verb** | v. | The action or state | tangoed, exploded, is |
| **Adjective** | adj. | Describes a noun | grumpy, iridescent, soggy |
| **Adverb** | adv. | Modifies a verb or adjective | magnificently, begrudgingly |
| **Conjunction** | conj. | Joins clauses — the engine of Story Mode | and, because, meanwhile |
| **Preposition** | prep. | Places a noun in the scene | under, beyond, without |

Two supporting function-word categories exist because the grammar needs them to accept natural sentences: **articles** (*the, a, every*) and **pronouns** (*it, they* — which also carry Story Mode callbacks). Together with conjunctions and prepositions these are the **glue**: cheap in points, essential in play. A pool starved of glue produces gorgeous words that can never form a sentence, so the content pipeline enforces a minimum glue share.

A word may belong to more than one category (*run* = noun or verb; *suddenly* = conjunction or adverb). Multi-category words resolve by position when the sentence is validated, are strictly more useful, and score +1 over their tier base.

Reel weighting is expressed entirely in these categories (§2.4): reel 1 leans articles and pronouns, reel 2 adjectives, reel 3 nouns, reel 4 verbs, reel 5 conjunctions and prepositions plus bonuses. The verb pity system, the tutorial, and the "you need a verb!" nudge all key off the same taxonomy.

| Tier | Examples | Points | Pool share |
|---|---|---|---|
| Common | the, a, is, ran, dog, big | 1–2 | 55% |
| Uncommon | gallop, velvet, grumpy, meanwhile | 3–5 | 30% |
| Rare | flabbergast, kaleidoscope, skulduggery | 6–8 | 12% |
| Legendary | onomatopoeia, discombobulate | 10 | 3% |

Design intent: commons are the glue (articles, pronouns, common verbs) that make sentences *possible*; rares are the spice that makes them *valuable and funny*. High-point words skew inherently comic — that's deliberate: the scoring system quietly bribes players into writing absurd sentences, which is the actual product.

Multi-POS words ("run" = noun or verb) are tagged with all valid parts of speech and resolve by position at validation time. They're strictly more valuable, so they get +1 point over their tier base.

### 3.2 Bonus tokens (complete set)

Bonus tokens occupy a reel face like words do. Base appearance rate: ~8% of faces, weighted toward Reel 5.

| Token | Effect | Banking behavior | Principle served |
|---|---|---|---|
| **×2 / ×3 Word Gem** | Multiplies the *next word* banked | Auto-attaches; gem shows on that word | Word score boost |
| **Sentence Star** | Final sentence score ×1.5 (stacks additively: 2 stars = ×2) | Sits in a bonus slot above tray | Sentence score boost |
| **Extra Try** | +1 try immediately (pip animates in) | Instant, does not occupy tray | More tries |
| **Free Spin Frenzy** | One chosen reel re-spins free, unlimited, for 15s of frantic tapping | Instant activation | "Infinite spins to fill the slot you're working on" |
| **Wild Card** | Becomes any dictionary word the player types (validated against bundled word list + profanity filter) | Banks like a word; worth base 3 pts | Escape hatch, agency |
| **Swap Token** | Return one banked word to its reel, re-spin that reel free | Held until used | Undo, reduces bank regret |
| **Gift Token** | Banks a random bonus (Gem/Star/Extra Try) into your **teammate's** next turn, at +1 potency | Held; fires on handoff | Cooperation made mechanical |
| **Rust Token** | A rare high-value word (8–10 pts) that decays −2 pts per spin you don't bank it | Reel face shows decay counter | Risk/reward tension |

Rules of the bonus economy:
- Max 2 bonus tokens visible per spin (prevents bonus-flood turns that feel unearned).
- Gift Token is intentionally *better* than keeping a bonus yourself (+1 potency: a ×2 Gem gifts as ×3). Cooperation should always be the mathematically-correct warm fuzzy.
- Frenzy is the signature "slot machine" moment — sound design and haptics budget goes here first.

---

## 4. Scoring

### 4.1 The formula

```
raw      = Σ (word points × word gems)
lengthM  = 1.0 + 0.25 × max(0, wordCount − 3)        // capped at ×3
grammarM = valid ? 2.0 : 0.25                         // salad penalty
starM    = 1.0 + 0.5 × sentenceStars
styleB   = alliteration(15) + rhyme(15) + allFiveOriginalReels(25) + themeWords(10 each) + makesSense(30)
tryB     = 10 × triesRemaining
streakM  = 1.0 + 0.1 × teamStreak                     // capped at ×2

turnScore = (raw × lengthM × grammarM × starM + styleB + tryB) × streakM

// Story Mode only:
turnScore = (turnScore + comboB) × chainM      // comboB = callbacks/threads/connector/chapter, §5.1
```

**`makesSense(30)`** is purely additive and never gates validity — the subject and verb must both be hand-tagged with a compatible semantic category (`Language/SemanticCoherence.swift`) for it to fire. An untagged pool, or a grammatical-but-mismatched pairing, simply scores as if the line didn't exist — see GAME_LOGIC.md §5.1 for the full reasoning ("funny and silly yes, invalid no").

### 4.2 Worked example

Sam banks: "the(1) grumpy(4) octopus(6) tangoed(5) magnificently(7)" with one ×2 Gem on *octopus* and 1 try left, team streak 3.

- raw = 1+4+12+5+7 = **29**
- lengthM = 1.5 (5 words) → 43.5
- grammarM = 2.0 (valid!) → 87
- styleB = 0, tryB = 10 → 97
- streakM = 1.3 → **126 points**, and the streak ticks to 4.

The breakdown animates line by line — the grammar ×2 reveal is the applause moment, staged last-but-one before the streak multiplier.

### 4.3 Team structures (co-op framing)

- **Target mode (default):** the team must beat a house target across a round of N turns (N = players × 2). Targets escalate per round; word packs/skins unlock at milestone rounds.
- **Streak:** shared across players, so a weak turn by your friend *is your problem too* — you'll want to coach them. Table-talk is allowed and encouraged; it's the social loop.
- **No individual leaderboard in co-op modes.** Individual stats live in the private profile only. Never make a friend feel like the weak link on a results screen.

### 4.4 Anti-degenerate-play guards

- Min 3 words for the length multiplier to exceed ×1 — stops "Dogs dance" spam.
- Try bonus (10/try) is deliberately small vs. one more good word (~15–30 after multipliers): banking greed should usually beat early lock-in, but not always. That "should I stop?" doubt is the slots DNA.
- Repeated-word penalty: the same word twice in one sentence scores once.

---

## 5. Modes

| Mode | Players | Ship | Notes |
|---|---|---|---|
| **Pass & Play** | 2–4, one device | v1.0 | The soul of the game. Zero accounts, zero friction. |
| **Story Mode** | 2–4 | v1.0 | Sentences chain into one shared story; continuity earns combo points (§5.1) |
| **Beat the House** | 2–4 | v1.0 | Target-score co-op campaign, escalating difficulty tiers |
| **Solo + CPU teammate** | 1 (+bots) | v1.0 | Play the co-op game alone, with a CPU partner. See §5.3 |
| **Remote Play (separate phones)** | 2–4 | v1.1 | Game Center turn-based; each player on their own phone, a turn per coffee break. See §5.2 |
| **Same Room (live, separate phones)** | 2–4 | v1.2 | Everyone on their own phone in the same room, watching the same reels spin live. See §5.2 |
| **Daily Spin** | ∞ (global seed) | v1.2 | Same reels for everyone, one attempt, shareable card |
| **Themed Events** | any | v1.2+ | Rotating word packs (Pirates, Space, Rom-Com); theme words +10 each |

### 5.1 Story Mode — sentences become a story, continuity becomes combos

The flagship co-op mode. Each turn's locked sentence is appended to the **team story**, displayed as a growing storybook page between turns. Your job isn't just a good sentence — it's a good *next* sentence.

**Combo points** reward continuity with the story so far:

| Combo | Trigger | Bonus |
|---|---|---|
| **Callback** | Reuse a noun (or its pronoun: octopus → it/he/she) from any earlier sentence | +20 per callback, max 2/turn |
| **Thread** | Reuse a noun from the *immediately previous* sentence | +40 (replaces Callback for that word) |
| **Connector open** | Start your sentence with a connector (Meanwhile, Suddenly, Because, But…) | +15 |
| **Chain meter** | Every consecutive sentence with ≥1 Callback/Thread grows the chain: ×1.1 → ×1.5 on turn score | Resets on a turn with no continuity |
| **Chapter close** | Round's final sentence contains a designated "ending word" (drawn at round start, visible to all: e.g., *finally*, *home*, *asleep*) | +100 team bonus, "The End" celebration |

Detection is mechanical, not judged: exact-word and pronoun-map matching against story nouns (implementation in ARCHITECTURE.md). No AI grading of "does this make sense" — players are the judges of story quality, and the fun is precisely that the mechanics reward coherence while the reels fight it.

Mode-specific tuning:

- Reels get a **Story Bias**: nouns already in the story reappear in pools at 3× weight, and the connector share of Reel 5 doubles. The machine conspires to make callbacks land-able.
- The round-start **ending word** is guaranteed to appear on reels during the final turn (pity-injected if never seen).
- Story length: a round = 1 chapter of players × 2 sentences; a full game = 3 chapters. Finished stories save to the Gallery as illustrated storybook pages — the premier share artifact ("read the saga we spun").
- Ships in v1.0 as a Pass & Play option; in v1.1 it becomes the standout async mode (a story unfolding over days of push notifications).

---

### 5.2 Playing on separate phones

Pass & Play is the launch soul of the game, but **most friends aren't in the same room**, so cross-device play is a first-class requirement, not an afterthought. Two flavors, one shared engine:

**Remote Play (async, v1.1)** — the default way friends play apart.

- Each player has the app on their own phone. Invite via Game Center friends or an iMessage link.
- You play your full turn (spin, bank, arrange, lock in) whenever you like; your friend gets a push notification: *"Sam added to your story: 'The grumpy octopus tangoed magnificently.' Your turn."*
- Perfect fit for the 60-second turn: a match lives across a day or a week, a few taps at a time. Story Mode async is the standout experience — a saga that arrives in notifications.
- **Spectate-the-turn replay:** when your turn opens, you first watch a 5-second replay of your teammate's spins and their sentence assembling. This is the co-op glue that async games usually lose — you still get to *witness* your friend's luck and cleverness, just time-shifted. (Enabled by the deterministic engine: we replay from their seed + actions, not a video.)
- Reactions: one-tap emoji/sticker responses to a teammate's sentence, delivered with the next turn notification.
- Multiple concurrent matches; a home-screen list shows whose turn it is in each.

**Same Room (live, v1.2)** — everyone in the same place, but each on their own phone.

- One phone hosts; others join over local network/Bluetooth (MultipeerConnectivity) with a 4-letter room code, no internet required.
- All devices render the same reels spinning in real time; only the active player can bank/lock. Non-active players see a live "watching Sam" view and can send reaction taps and suggest words (suggestions appear as a tinted hint on the active player's tray — advice only, never forced).
- Solves the pass-and-play hygiene problem (nobody wants to hand over their phone) while keeping the shared-table energy.

**Design rules that hold across all device configurations:**

- The rules, scoring, pools, and pity system are identical everywhere. No mode-specific balance forks.
- A match can change shape mid-game: start Pass & Play on one phone, and if someone has to leave, convert it to Remote Play and finish async. Match state is portable by design.
- Nothing in the game requires an account. Game Center sign-in is only needed for Remote Play matchmaking; local and Same Room work anonymously.

### 5.3 Playing with the CPU

A co-op game needs a second player, and a second player is not always available. The CPU fills that seat.

**Three teammates, by skill:**

| Skill | Character | Behaviour |
|---|---|---|
| **Sprocket** (rookie) | Eager, a bit chaotic | Grabs the first thing that works, banks short sentences fast. Easy to out-score, fun to watch. |
| **Wordsworth** (steady) | Reliable partner | Completes the sentence, then extends while the odds look good. The default. |
| **Professor Cogsworth** (sharp) | Patient show-off | Holds out for rare words and bonus tokens, banks late, writes long sentences. |

**Where the CPU shows up:**

- **Solo play** — you and a bot against the house target. The full co-op game, one player.
- **Filling a seat** — three friends want to play a four-hander; a bot takes the fourth chair.
- **Drop-out cover** — someone leaves a remote match mid-game; rather than killing the story, their seat converts to a CPU so the match can finish.
- **The tutorial** — the first turn you ever see is a bot playing one, narrated.
- **Balance testing** — the same bot drives the headless simulator that tunes the economy (§8).

**Rules the CPU plays by:**

- **The same ones you do.** The bot emits the same actions into the same engine, sees the same reels, and cannot re-roll a spin or peek at the random seed. Its turns are recorded, replayable and verifiable exactly like a person's.
- **Skill changes patience, not privilege.** A sharper bot waits longer and aims higher; it never gets better odds, extra tries, or hidden points.
- **It is a teammate, not an opponent.** Its score goes into the same shared bank. In Story Mode it writes into the same story, and it will happily hand you a Gift Token.
- **It plays visibly.** Bot turns animate at human pace with the same spin, bank and lock-in beats, so watching one is part of the fun rather than a loading screen.

## 6. UX and feel

### 6.0 Pull down to spin

The spin is a **pull-down gesture**, not a button. Drag anywhere on the machine and the reels stretch downward like a lever under tension; release and they snap and spin. It costs a try, so it should feel like committing to something.

- **Tension mapping:** the further you pull, the tighter the resistance and the longer the reels spin on release. A short tug gives a quick flick; a full pull gives a long, dramatic spin. Purely cosmetic — the outcome was decided by the seed, not the pull — but it hands the player the *feeling* of authorship, which is the whole point of a lever.
- **Haptics:** a rising tick pattern as you pull past each detent, a firm thunk at full extension, then the per-reel landing thumps.
- **Release-to-cancel:** pull back up past the origin without releasing and the lever disengages — no accidental tries burned, which matters when a try is 20% of your turn.
- **One-handed by design:** the pull zone covers the lower half of the screen so the gesture works with a thumb, on a phone, at a bar table.
- **Per-reel pull during Frenzy:** while Free Spin Frenzy is running, the gesture narrows to the chosen reel — pull, release, pull, release, as fast as you like.
- **Accessibility:** a persistent SPIN button sits alongside the gesture and always works. VoiceOver announces "spin, button"; Switch Control and reduced-motion players never need the gesture, and no scoring depends on it.

### 6.1 The juice budget, ranked

1. **Reel physics** — overshoot-and-settle spin, per-reel thunk haptic, near-miss slow-down when a rare token is adjacent.
2. **Score reveal** — line-by-line breakdown, coin cascade into team bank, confetti on grammar ×2.
3. **Banking** — token physically drops into tray with weight; gem attach sparkles.
4. **Frenzy** — screen edge glow, escalating music layer, rapid-fire haptics.
5. **Handoff** — machine "resets" with a lever-crank animation as the next name card slides in.

### 6.2 Emotional beats per turn

Anticipation (spin) → assessment (read) → commitment (bank) → tension (tries dwindle) → relief/comedy (lock in) → celebration (score) → generosity (handoff, maybe a Gift). The design goal is that every ~60-second turn traverses all seven.

### 6.3 Accessibility & audience

- VoiceOver: every token reads "word, part of speech, points." Reels announce results after settling.
- Reduced motion: instant reel results, no spin animation; all information, none of the vertigo.
- Dynamic Type throughout; tokens scale with a 2-line max then marquee.
- Colorblind-safe rarity coding: shape of token frame, not just color.
- Content: curated family-safe pools; Wild Card input filtered. Target rating 9+.

### 6.4 Screens

Title → Mode select → Player setup → **Game** → Handoff → Round results → Gallery → Settings. (Wireframe descriptions in ARCHITECTURE.md §7; keep total v1.0 surface to these 8.)

---

## 7. Retention & social

- **Sentence Gallery**: every locked sentence saved with score and author. The gallery *is* the memory of game nights.
- **Share cards**: sentence + score + machine art, exported to iMessage/social with one tap. This is the acquisition engine — a funny sentence is an ad.
- **Progression**: XP per turn → levels → unlock word packs, machine skins, token cosmetics. Nothing gameplay-affecting is ever paywalled or grind-gated in a way that splits a co-op team.
- **Daily Spin** (v1.2) is the habit anchor; pass-and-play is the social peak.

### Monetization

One-time "Premium" IAP (removes ads — interstitials between rounds only, never mid-turn), cosmetic skins, themed word packs. Hard rule: **no purchasable score advantage.** In a co-op game, pay-to-win doesn't just imbalance — it embarrasses the payer in front of their friend.

---

## 8. Balancing philosophy & telemetry

Tune like a slots designer, not a word-game designer: the levers are pool composition, reel weights, bonus rates, and pity thresholds.

### 8.1 The simulator comes first

`tools/balance_sim.py` runs thousands of bot turns against the shipping economy in seconds, so a change to reel weights or the word pool is checked before it ever reaches a device. Every profile is measured, because a change that helps a patient player can quietly ruin a hasty one.

**Measured baseline** (206-word starter pool, 800 turns per profile, default economy):

| Profile | Valid sentences | Median length | Used all tries | Median score |
|---|---|---|---|---|
| Human (maximiser — the ceiling) | 90.5% | 7 words | 77% | 132 |
| Cogsworth (sharp) | 93.5% | 6 words | 79% | 112 |
| Wordsworth (steady) | 90.4% | 5 words | 24% | 90 |
| Sprocket (rookie) | 89.8% | 3 words | 12% | 62 |

These are **regression bands, not aspirations**. They were recorded once the game played well; their job is to catch a future pool edit that silently starves the reels of verbs. The rule is: widen a band deliberately, never to turn a red run green.

### 8.2 The invariants that actually matter

Checked for every profile, every run:

- **No zero-score turns.** Ever. A turn that scores nothing is a turn that felt wasted, and the word-salad consolation exists precisely to prevent it.
- **No empty trays.** Every turn ends with at least two words.
- **The bottom decile still scores.** Bad luck should mean a small score, never a humiliating one.
- **Pity stays rare** (<15%). It currently sits at 0% — the reel-role weighting and the dead-end guarantee are doing the work, and pity is the seldom-used safety net it was meant to be.

### 8.3 Live telemetry

Log per turn (privacy-safe, no PII, no sentence text): tries used, words seen/banked, category gaps encountered, pity activations, validity result, score, lock-in timing. Watch for drift against the simulated baseline — a live validity rate well under the simulated one means real players are hitting grammar the templates reject, which is a cue to widen the template set, not to punish the player.

---

## 9. Open questions (tracked, with current leanings)

| Question | Leaning | Decide by |
|---|---|---|
| Turn timer? | No timer v1; optional "party timer" toggle later | Phase 1 playtest |
| Tray size | 10 | Phase 0 |
| Can players discuss/help during a turn? | Yes, always — it's the point | Decided |
| Punctuation/word inflection ("run"→"runs") | No inflection v1 — pools carry inflected forms as separate tokens | Phase 0 |
| 3+ player reel sharing (leftover bank passes on?) | No — clean slate per turn except Gifts/streak | Phase 1 playtest |
