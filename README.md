# Message Slots

A cooperative word-slots game for iPhone. The reels land on **words**, not symbols. You get 5 tries to bank words and build the best sentence you can, then pass to your teammate. Scores pool into one shared bank — you win or lose together.

Play it on one phone, on separate phones, or with a CPU teammate.

---

## Documents

| Document | What's in it |
|---|---|
| [ROADMAP.md](ROADMAP.md) | Phased build plan, from prototype to live ops |
| [docs/GAME_DESIGN.md](docs/GAME_DESIGN.md) | Full design: turn structure, word categories, bonus tokens, scoring maths, Story Mode, CPU teammates, multi-device play |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Technical design: module map, state machine, grammar engine, multiplayer transports, the LLM decision |

---

## What's built

The **deterministic game engine is complete and tested**. The UI is not started — that's the next step.

```
Sources/GameCore/
  Models/      word categories, tokens, bonuses, players
  Random/      SeededRNG — SplitMix64, serializable
  Economy/     EconomyConfig (every tunable number), WordPool
  Language/    template grammar validator, advisory tagger, SentenceJudge seam
  Scoring/     ScoreCalculator, ComboDetector (Story Mode)
  Story/       shared story, continuity, pronoun map
  Engine/      TurnState, TurnReducer (pure), SpinResolver + pity, CPUPlayer
  Match/       MatchState, MatchEngine, MatchTransport (local / remote / same-room)
```

**The property everything rests on:** a turn is fully described by `(seed, [TurnAction])`. Replay it and you get the identical result — which is what makes score-reveal animations honest, teammate-turn replay possible in remote play, and cheat detection work with no server.

---

## Working on it

### Build and test

```bash
swift build
swift test
```

Requires Xcode 15+ / Swift 5.9+. `GameCore` has no Apple-only dependencies in its required path, so it also builds and tests on Linux CI.

### Word pools

Words are authored as CSV and compiled into the bundled JSON resource, with validation (duplicates, category coverage quotas, tier mix, points-per-tier sanity, and whether the pool can actually form sentences):

```bash
python3 tools/compile_pools.py            # compile + validate
python3 tools/compile_pools.py --check-only
```

Edit `Content/words_starter.csv`, run the compiler, run the balance sim, commit both.

Format: `text,pos,tier,points,tags` — where `pos` is one or more of `NOUN VERB ADJ ADV CONJ PREP ART PRON`, pipe-separated for words that play multiple roles (`run,NOUN|VERB,common,2,`).

### Balance simulation

Thousands of bot turns against the live economy, checked against recorded regression bands:

```bash
python3 tools/balance_sim.py --all --turns 2000
python3 tools/balance_sim.py --strict          # non-zero exit on a miss, for CI
```

Run this after any change to reel weights, bonus rates, the scoring table, or the word pool. Current baseline is recorded in [docs/GAME_DESIGN.md §8](docs/GAME_DESIGN.md).

---

## Next up

The Phase 0 gate: a rough playable SwiftUI screen on a device, to answer the only question that matters — **is one turn fun on its own?** Everything else in the roadmap is downstream of that answer.
