# Message Slots — Ideas Backlog

*A holding pen for ideas that aren't ready for a committed doc yet. Nothing here is designed, scoped, or promised — it's raw material. When an idea is ready to commit, move it into GAME_LOGIC.md, FUNCTIONALITY.md, GRAPHICS.md, or the ROADMAP and delete it from here.*

Add freely. Half-formed is fine. No idea needs to justify itself to go on this list — that's what separates this file from the real docs.

---

## Gameplay

- **Topic-constrained sentences.** A round (or a single turn) is given a topic — "kitchen," "outer space," "a bad first date" — and words that match the topic score bonus, or the sentence must *stay on-topic* to fully validate. Open questions to resolve before this is ready to design:
  - Is it a *bonus* (like Themed Rounds' theme-word bonus, which already exists in GAME_DESIGN.md §5) or a *constraint* (sentence must relate to the topic to score at all)? A hard constraint risks breaking the "no turn is worth zero" rule (GAME_LOGIC.md §4) unless it's very generously judged.
  - Who judges "on-topic"? Category tags on words (like the existing `pirate`/`space` tags) could work for a curated topic, but player-typed sentences are hard to grade against a topic without either a wordlist-tag approach (cheap, a bit rigid) or a language-model judge (see ARCHITECTURE.md §6.1 — deliberately avoided as a scoring authority for determinism reasons; could work as a flavor-only "Judge's Award" instead, same pattern as `SentenceJudge`).
  - Could piggyback on the existing tag system almost for free: "topic" is just a themed round where the theme is chosen per-round instead of per-pack, and topic words are drawn from tags rather than hand-authored packs.
  - Natural fit for **Daily Spin** (GAME_DESIGN.md §2, v1.2) — a global daily topic gives the shared puzzle a fresh flavor each day without needing new word packs.

- **Hazard token: "X" removes a random word from your sentence.** The game currently has exactly one token that can hurt you (Rust, which decays while you hesitate) and seven that only help. A genuine hazard would sharpen the risk of spinning — right now spinning costs a try but can never actively cost you *progress*, so "spin again" is close to a free roll once you've banked something good. Open questions before this is designed:
  - It collides head-on with "no turn is ever worth zero" (GAME_LOGIC.md §4) and the anti-frustration stance generally. Losing a legendary word to a coin flip is the kind of thing that makes someone put the phone down — especially in a co-op game where it also hurts a friend's score.
  - Softer executions that keep the tension without the sting: let it take the *lowest-value* word rather than a random one (bad luck, not disaster); make it a threat you can *defuse* by banking before it resolves (a countdown, like Rust); or make it remove a word but refund the try, so it costs progress rather than opportunity.
  - Best version may be: it removes a random word **and the reel it came from re-spins for free**, so it reads as a shuffle rather than a punishment. Same disruption, no net loss, and it can even be good for you.
- **"Steal a word" — take a word from your teammate's banked sentence, replacing it with one of yours.** Mechanically rich: it creates the game's first real inter-player interaction beyond gifting and shared streak.
  - The framing needs care, because the game is explicitly cooperative (GAME_DESIGN.md §4.3: shared bank, no individual leaderboard). "Steal" is competitive language for what would actually be a *pooled* transaction — both scores go into the same bank, so taking a strong word from a teammate only helps the team if it's worth more in your sentence than theirs. That's a genuinely interesting optimisation problem, and it's the opposite of adversarial.
  - Suggests renaming to something co-op-native — **Trade**, **Borrow**, or **Swap Shop** — which also makes the required replacement feel like the point rather than a penalty.
  - Because it's a positive-sum trade, it wants a guard so it isn't always correct: perhaps the donor picks which replacement they receive, or the trade must leave their sentence still valid. Otherwise the optimal play is always "move every good word to whoever has the best multiplier," which flattens turns into bookkeeping.
  - Strong fit for Remote Play, where it gives an asynchronous turn something to *react to* rather than just following.
- **Expand semantic tagging past the starter set.** The "Makes Sense" bonus (GAME_LOGIC.md §5.1) currently only tags common/uncommon nouns and verbs plus pronouns (89 of 206 starter words). Untagged is safe — it's "no opinion," never a penalty — but the bonus fires more often, and feels more alive, the more of the pool carries a tag. Candidates for a future pass, roughly in order of expected payoff:
  - Rare and legendary nouns/verbs — currently zero-tagged; these are the words players get most excited to bank, so a compatible pairing there ("the kraken smuggled") would land harder than a common-word match.
  - Adjectives/adverbs, if a future coherence rule wants to check more than just subject+verb (e.g. does the adjective plausibly describe this noun's semantic class?) — not designed yet, would need its own pass through GAME_LOGIC.md before building.
  - The eventual 1,200-word pool — tagging should happen as content is authored, not as a separate retrofit pass, so `compile_pools.py`'s zero-tagging warning stays meaningful rather than a permanent known-ignorable.

## Visual / feel

- (add here)

## Modes / social

- (add here)

## Monetization / retention

- (add here)

## Technical / tooling

- (add here)

## Parking lot (ideas raised and set aside, with why)

- **Noun=green / verb=red token coloring.** The instinct (put the two categories a sentence needs at max contrast) was right and is preserved; the specific hues were superseded because red/green fails under the most common color blindness. Replaced with a full Okabe–Ito-derived six-color palette (blue/vermillion for noun/verb, plus safe hues for the other four categories) — see GRAPHICS.md §2.2. Not a rejection of the idea, just a better execution of it.
