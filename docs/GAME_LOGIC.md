# Message Slots — Game Logic & Fun

*What makes a turn fun, and the exact levers that control it. This is the design lens focused purely on feel — mechanics are in [GAME_DESIGN.md](GAME_DESIGN.md), implementation is in [ARCHITECTURE.md](ARCHITECTURE.md).*

Validated against the built engine: `Sources/GameCore/`, `tools/balance_sim.py`, and a first working build on the iOS Simulator (ROADMAP.md, Phase 0).

---

## 1. The one question this document answers

**Is a single turn fun on its own, before any scoring, story, or multiplayer layer is added?**

Everything below is organized around the emotional arc of one turn:

```
anticipation → assessment → commitment → tension → relief/comedy → celebration
   (spin)        (read)       (bank)     (tries dwindle)  (lock in)    (score)
```

If any beat is flat, no amount of bonus tokens or story mode fixes it. Playtesting should isolate this loop before judging anything else.

---

## 2. The core tension: banking is a bet

The entire game is one repeated decision: **bank this word now, or hope the next spin is better?**

That decision only feels real if three things are simultaneously true:

1. **Banking is irreversible** (mostly). A word committed to the tray stays — you can reorder it, but you can't un-bank it without a Swap Token. This is what makes each bank a real choice rather than a preview.
2. **Spinning costs something.** A try is 20% of your turn. Every spin is a small wager.
3. **The reel refills.** Banking a word from reel 3 doesn't retire reel 3 — it comes back next spin with something new. This is *why sentences can grow past five words across five tries*, and it's also why banking never feels like "using up" a resource — it feels like *locking in progress*. (This was originally a bug in the first implementation — reels were staying empty after banking, which silently capped every sentence at five words and flattened the whole growth curve. Fixed; see ARCHITECTURE.md §4 and the regression test `testSentencesCanGrowBeyondTheReelCount`.)

**Design implication:** any future feature that lets players "peek" before committing, or makes banking reversible by default, kills this tension. Swap Tokens exist specifically as a *rare, earned* exception — not a standard tool.

### 2.1 What's actually irreversible: the spin, not the placement

The bet in this game is *getting a new word* — spinning costs a try, and once you've seen the result, that spin is spent. Where you put a word you already have is a different question, and it should be free: **arranging the tray is not the bet, spinning for new options is.**

This is why both of these are unrestricted, free actions with no cost and no cooldown:

- **Reordering the tray by dragging.** A player deciding "the verb reads better second" isn't taking a risk, they're expressing intent — the reducer's `.reorder` action never touches tries, bonuses, or the RNG.
- **Removing a word and having it return to its own reel** — but *only* if that reel hasn't been touched since. The moment you spin again, that reel has moved on, and pulling the old word back would effectively buy a free re-look at a spin you already spent a try on. So removal after a respin discards the word instead of restoring it — the one asymmetry that keeps this from quietly becoming a "keep spinning until I like everything, arrange for free at the end" degenerate strategy. And no resource is ever refunded on removal: a Word Gem or Wild Card spent to place a word is spent, whether or not you keep the word in the end.

The rule in one line: **you can always fix your own arrangement, you can never get a second look at a spin.** That's the actual boundary of "irreversible," and it's a sharper, friendlier line than "banking is final" — it protects the one thing worth protecting (spin economy) without punishing a player for a placement they immediately regretted.

---

## 3. The five-try arc

Five tries isn't an arbitrary number — it maps to a specific emotional shape:

| Try | What's happening | Feeling |
|---|---|---|
| 1–2 | Exploration — grab a strong noun or verb if one appears | Curious, low-stakes |
| 3–4 | Gap-filling — "I have a subject, I need a verb" | Focused, a little anxious |
| 5 (last) | Desperation or triumph | Peak tension — this is the moment |

The **verb pity system** (`SpinResolver`, `pityVerbTriesThreshold = 2`) exists entirely to protect try 4–5 from being a dead end. If a player reaches their last tries with no verb, verb weight on every reel triples — invisibly. The player should never consciously notice pity firing; they should just feel lucky. Measured pity activation rate in the live economy is **0%** across the human-maximizer, sharp, and steady profiles (see §7) — meaning the reel-role weighting and dead-end guarantee are doing the real work, and pity is the safety net underneath, not a crutch.

**Why not more tries?** More tries flattens the arc — exploration phase gets longer, the ending stops feeling scarce. **Why not fewer?** Fewer tries makes the dead-end guarantee load-bearing rather than a backstop, and removes the gap-filling phase that makes a sentence feel *built* rather than *handed to you*.

`EconomyConfig.easy` / `.hard` adjust try count (6 / 4) as difficulty knobs — this is the single highest-leverage tuning variable in the game.

---

## 4. Why word salad still scores something

The single most important anti-frustration rule: **no turn is ever worth zero.**

An invalid tray ("dog cat octopus") still scores at grammarMultiplier ×0.25 instead of ×2. This isn't generosity for its own sake — it's what keeps a bad turn from being a *punishing* turn. A player who spent five tries and got nothing walks away; a player who spent five tries and got a small, funny consolation score laughs and passes the phone.

The measured floor holds up: across every simulated player profile, **zero-score turns never occur**, and the bottom decile of scores is still meaningfully positive (see §7 table). This is a hard invariant checked by the balance simulator on every run, not a hope.

**Design implication:** any new scoring mechanic must be additive on top of this floor, never a replacement for it. A "perfect grammar or nothing" mode would violate the core promise of the game.

---

## 5. The grammar checker's job is to be generous, not correct

The sentence validator (`SentenceValidator`, template-based) is deliberately biased toward **false positives over false negatives**:

- Accepting a slightly odd sentence as valid: mildly funny, costs nothing.
- Rejecting a sentence a player believes is correct: feels like the game cheated them, is the single fastest way to make someone quit.

This is why the validator tries the tray as-written, then retries with a leading conjunction stripped, before giving up — and why the advisory tagger (NaturalLanguage, or a future on-device model) can only ever *downgrade* a green light to yellow, never veto a template match. See `SentenceValidatorTests.testAdvisoryCanOnlyDowngradeToYellowNeverReject` — this is enforced by a test, not just a comment.

**The corpus health targets:** ≥95% acceptance of sentences a person would call valid, 0% acceptance of obvious noun-piles. Current template set passes both on the hand-built test corpus (`SentenceValidatorTests.testCorpusAcceptanceRates`). This number should be re-measured continuously as real playtest sentences come in — the templates will always be behind real language, and the fix is always to *widen* the grammar, never to explain to a player why their sentence didn't count.

### 5.1 Rewarding sense without punishing nonsense

Generosity (§5) protects a player from ever being wrongly told their sentence doesn't count. But it leaves a gap: *"the dog"* and *"the dog wobbled majestically under a haunted lighthouse"* both simply pass or fail the same grammar check, and a player correctly noticed that gap — bare noun-plus-verb trays were clearing the bar as easily as sentences that actually mean something.

The fix had to thread a specific needle, stated directly by the person who asked for it: **"Funny and silly yes, invalid no."** Nonsense should stay legal — a co-op word game where "the kraken filed paperwork" gets rejected is a worse game — but sense-making should be worth *more* than luck-of-the-draw grammar.

**The resolution: an additive-only "Makes Sense" bonus, never a gate.** Grammar validity (§5) is completely unchanged — no new template requirement, no new rejection path. On top of it, `CoherenceEvaluator` (`Language/SemanticCoherence.swift`) looks at the tray's subject (the last noun-like word before the first verb) and that verb, and checks whether they're tagged as plausibly going together — e.g. an *animate* noun with a verb that claims *animate* subjects. If they match, the turn earns a flat `+30` (`EconomyConfig.senseBonus`) "Makes Sense" line in the score breakdown. If they don't match, or either word is untagged, the turn scores exactly as it would have without this feature — no penalty, no visible flag that anything was checked at all.

This means "the octopus danced" (tagged, compatible) outscores "the octopus wobbled skyscraper" (tagged, incompatible) or "the fribble glorped" (untagged) — but never disqualifies the second or third. Silly wins big when the words happen to line up, and just wins normally otherwise.

**Why not an LLM referee**, since that was raised as an option: the same three reasons the game already rejected LLM validation for grammar (ARCHITECTURE.md §6.1) apply just as hard here — determinism for replay-based remote-play verification, sub-frame latency on every tray change, and identical behavior regardless of a player's device. A hand-tagged, deterministic set intersection gets the *reward* half of "make it make sense" without reopening any of that. The sanctioned LLM seam (`SentenceJudge`) still exists for a future *optional, capped, advisory* flavor award — a different, smaller, opt-in idea — but it is not what powers this bonus.

**Scope of tagging, deliberately small to start:** 89 of the starter pool's 206 words (common/uncommon nouns and verbs, plus every pronoun) carry one or more of five hand-authored categories — `animate`, `place`, `food`, `object`, `abstract` — chosen to cover the highest-traffic word combinations without trying to model real-world semantics exhaustively. Rare/legendary words and all adjectives/adverbs are untagged for now (tracked in `docs/IDEAS.md`); an untagged word is documented everywhere in the code as "no opinion," never "wrong," because a sparse first pass must never look like a bug to a player who banks an untagged word and simply doesn't see the bonus line.

**Pronouns had to be tagged, and only on-device play revealed it.** The first tagging pass covered nouns and verbs and skipped pronouns entirely — which looked harmless until a real turn produced *"We levitated."*: a perfectly good sentence, with a verb explicitly tagged `animate`, earning nothing. Pronouns are among the most common subjects in English, so leaving them untagged silently suppressed the bonus on a large share of exactly the natural sentences it was built to reward. All ten now carry `animate`, except *it*, which takes every category since it stands in for anything. Worth noting as a pattern: a sparse-by-design system fails quietly, so its gaps surface through play rather than through tests — the tests all passed both before and after this fix.

`tools/balance_sim.py` mirrors this exact rule (`evaluate_coherence`, `SENSE_BONUS = 30`) and confirms it doesn't move the game outside its measured bands (§7) — the bonus is additive enough that it nudges median scores up slightly without changing valid-sentence rate, tries-used rate, or pity activation.

---

## 6. Bonus tokens: what each one is actually for

Bonus tokens aren't decoration — each one exists to protect or amplify a specific part of the tension arc. If a new bonus type is proposed, it should be checked against this table for what job it does.

| Token | Protects/amplifies | What breaks if it's too common |
|---|---|---|
| Extra Try | The arc itself — extends exploration or gives one more shot at the ending | Turns lose their five-try shape; every turn becomes the same length |
| ×2/×3 Word Gem | The payoff of a good bank — rewards recognizing a strong word | Devalues the base scoring table; every word feels like it's "supposed to" be multiplied |
| Sentence Star | The lock-in moment — a reason to be excited about finishing | Diminishing if stacked without limit — currently uncapped, worth re-examining |
| Free Spin Frenzy (now capped at `maxFrenzySpins = 12`) | The single most "slot machine" feeling moment in the game — unbounded excitement, bounded cost | Originally had no spin limit at all; an unattended Frenzy could spin forever for free. Fixed after code review — see ARCHITECTURE.md §4 |
| Wild Card | The escape hatch — guarantees no turn is un-completable | Too common and the reels stop mattering; the player just types their sentence |
| Swap | Undo for banking regret — the *exception* to "banking is a bet" | Too common and banking stops being a real decision (§2) |
| Gift | Turns generosity into the mathematically correct play — cooperation is rewarded, not just nice | If gifting were ever worse than keeping a bonus, players would learn to hoard, and the co-op framing would ring false |
| Rust | The one token that punishes hesitation — a countdown built into a reward | Too aggressive a decay rate and it becomes "why bother," too slow and it's a free bonus with a scary name |

**Bonus density is capped at 2 faces per spin** (`maxBonusFacesPerSpin`) specifically so a lucky spin doesn't feel unearned — bonuses should feel like *finding* something, not like the default state of the reels.

---

## 7. What the simulator actually tells us

`tools/balance_sim.py` runs thousands of bot turns per player profile and checks against recorded bands. This isn't a nice-to-have — it caught a real fun-breaking bug (the reel-refill issue in §2) before a single human playtester ever touched the game. Treat it as the first playtester, not a replacement for real ones.

**Measured baseline** (206-word starter pool):

| Profile | What it models | Valid sentences | Median length | Used all tries | Median score |
|---|---|---|---|---|---|
| Human (maximiser) | The ceiling — an engaged player squeezing every point | 90.5% | 7 words | 77% | 132 |
| Cogsworth (sharp CPU) | A patient, high-skill teammate | 93.5% | 6 words | 79% | 112 |
| Wordsworth (steady CPU) | The default teammate | 90.4% | 5 words | 24% | 90 |
| Sprocket (rookie CPU) | A fast, low-ambition teammate | 89.8% | 3 words | 12% | 62 |

Reading this correctly: the *spread* between profiles is the interesting part. A 70-point gap between Sprocket and the human ceiling means skill matters, but a Sprocket turn still clears 60+ points — nobody watching a rookie CPU (or playing like one) feels like they're wasting their turn. That spread is what "cooperative, not competitive" needs to feel true even though individual skill clearly varies.

**What to watch for as the pool grows toward 1,200 words:** these numbers should stay roughly stable. If the valid-sentence rate climbs much past 95% the game has gotten too easy (every spin trivially completable); if it drops toward 60% the templates or reel weighting need attention before it reaches a human playtester.

---

## 8. Story Mode: continuity as a second currency

Story Mode (`ComboDetector`) adds a second, orthogonal fun loop on top of the base turn: not "is this a good sentence" but "is this a good *next* sentence." The two loops are deliberately kept separate in scoring (combo bonus applies as a multiplier *after* the base turn score) so a player can't ignore sentence quality just to chase callbacks.

The two continuity rewards are tuned to different behaviors:

- **Thread** (+40, reusing the *immediately previous* sentence's noun) rewards responsiveness — reacting to what your teammate just wrote.
- **Callback** (+20, capped at 2/turn, reusing *any* earlier noun) rewards long-term memory of the story — a callback three sentences later can be genuinely funny in a way a same-turn reuse can't.

The chain multiplier (+10% per consecutive turn with continuity, capped at ×1.5) is the mechanism that makes a story feel like it's *building* rather than being a sequence of unrelated sentences — but it resets hard on a broken turn, which is intentional: a story that drifts should feel like it drifted, not be quietly forgiven.

**Reel bias makes this fair, not just possible.** Nouns already in the story reappear at 3× weight (`storyNounBias`). Without this, callbacks would be a lottery rather than a skill — measured in `testStoryNounsResurfaceMoreOften`, confirming the bias measurably increases reappearance rate rather than just existing in config.

---

## 9. Playing with a bot doesn't feel different — that's the point

The CPU teammate (`CPUPlayer`) plays through the *exact same reducer* a human does — same seed, same actions, same rules, fully replayable and verifiable. This matters for fun, not just architecture: a bot that "cheated" (saw the RNG, re-rolled, got bonus points) would be detectable eventually, and the moment a player suspects their teammate isn't playing fair, the cooperative framing collapses.

Skill (`CPUSkill`) is tuned as *patience and ambition*, never privilege:

- **Rookie** grabs the first workable word — fast, chaotic, easy to watch and easy to "beat."
- **Steady** completes the sentence, then extends opportunistically — the default partner.
- **Sharp** holds out for rare words and bonus tokens — visibly more careful, noticeably higher-scoring.

This gives solo players (and anyone filling an empty seat) a real difficulty dial without ever making the CPU feel like an opponent rather than a partner — it always deposits into the *same* team bank.

---

## 10. Open tuning questions, ranked by expected impact

1. **Sentence Star stacking** — currently uncapped (each star adds +0.5× additively). Two or three stars in one turn could dominate the score. Needs a cap or a diminishing curve once real playtest data exists.
2. **Try bonus vs. one more word** — `pointsPerUnusedTry = 10` is deliberately small next to a good word's value (~15–30 after multipliers), so banking greed should usually beat stopping early, but not always (`testBankingAnotherGoodWordBeatsSavingATry` locks in the *current* balance point — re-verify after any scoring change).
3. **Rust decay rate** (−2 pts/spin) — untested against real hesitation behavior; a real player deciding "do I wait one more spin" is a different psychological moment than a bot's greedy threshold.
4. **Word pool growth to ~1,200 words** — the six-category taxonomy and tier system should hold, but comedic value is unevenly distributed (rare/legendary words skew funnier by design — GAME_DESIGN.md §3.1). Growing the pool without maintaining that skew would flatten the "aha, a great word!" moments that make high-tier spins exciting.

None of these are guesses in the sense of "we don't know" — they're the specific next things the simulator plus real playtesting should measure before Phase 1 locks the economy.
