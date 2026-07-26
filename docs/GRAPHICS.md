# Message Slots — Graphics & Visual Design

*Art direction, visual system, and motion design. Mechanics/fun reasoning is in [GAME_LOGIC.md](GAME_LOGIC.md); features are in [FUNCTIONALITY.md](FUNCTIONALITY.md).*

The Phase 0 prototype (`App/Components.swift`, `App/GameScreen.swift`) implements a first, deliberately plain pass at this system — dark theme, flat color tokens, no illustration — verified running on the iOS Simulator. This document describes both what's built and the fuller direction it's built toward.

---

## 1. Art direction

**The two references this game sits between:** a physical Vegas slot machine (tactile, mechanical, a little gaudy) and a word-game like a premium Scrabble app (typographic, confident, legible at speed). Message Slots should feel like the slot machine *cabinet* — lights, motion, a lever — built around type instead of fruit symbols.

**Tone:** warm, playful, a little theatrical — never mocking a bad sentence, never sterile. The visual language should make "word salad" turns feel like a fun consolation, not a failure state. This is a direct extension of the design rule in GAME_LOGIC.md §4 (no turn is worth zero) — the screen has to *look* like it agrees with that promise, not just score it that way.

**What it is not:** not a children's app (bright primary colors, cartoon mascots), not a hardcore casino app (chips, felt, gold trim). The reference point is closer to a well-made party-game box — Wingspan, Codenames, Just One — translated to a dark-mode mobile screen.

---

## 2. Color system

### 2.1 Base palette

The prototype ships a near-black background (`Color(white: 0.07)`) with a warm accent, not pure black — it should feel like a lit cabinet in a dim room, not a void.

| Role | Value (prototype) | Direction for final art |
|---|---|---|
| Background | `#121212` (white 0.07) | Keep near-black; consider a very subtle radial vignette behind the reels for "stage lighting" |
| Panel fill | `white @ 5–12% opacity` | Fine as a system; final art should add a hairline top-highlight to panels for a physical, lit-from-above feel |
| Primary accent | Orange (`.orange`, used for tries, current-player name) | This is the "house" color — reserve it for state that's about *you*, your turn, your progress |
| Success | Green | Lock-in button, valid sentence state |
| Warning/tension | Yellow | Gems, rust decay, "yellow" validity confidence |
| Danger/salad | Red (dimmed, `.red.opacity(0.7)`) | Never full-saturation red — this game should never look like it's punishing the player |

### 2.2 Word category colors (colorblind-safe by construction)

Each of the six core word categories gets a fixed hue, applied to token backgrounds. This is load-bearing for gameplay legibility (GAME_LOGIC.md — players scan reels fast, under time pressure from their own tries), so consistency matters more than beauty here.

| Category | Hue | Note |
|---|---|---|
| Noun | Blue `#4D94DB` | The "subject" color — cool, grounded, foundational |
| Verb | Vermillion `#EB7A33` | The "action" color — warm and saturated, draws the eye first (verbs are the scarcest resource, per GAME_LOGIC.md §3) |
| Adjective | Teal-green `#33BF94` | |
| Adverb | Amber/gold `#EBAD33` | Both adjective and adverb are "descriptor" categories and sit near each other on the wheel by design — they modify, they don't anchor |
| Conjunction | Reddish purple `#D98CC0` | Distinct from all others — conjunctions are the Story Mode signal color, should feel special |
| Preposition | Sky blue `#73C7EF` | Deliberately in the same family as noun-blue rather than fighting for maximum separation — prepositions are a glue category (`isGlue`) and rarely need split-second disambiguation from a noun; the on-token abbreviation covers the edge case |
| Article / Pronoun | Neutral gray `#8C8C8C` | Deliberately desaturated — these are "glue" words, cheap and plentiful; they shouldn't compete visually with content words |

**This palette replaces an earlier noun-green/verb-red concept.** The instinct behind that version was right — put the two categories a sentence *needs* at maximum contrast from each other — but red/green is the one hue pairing that fails under the most common forms of color blindness (deuteranopia/protanopia), which made it the worst possible choice for the game's single most important visual distinction. The fix keeps the same intent (grounded/cool subject vs. hot/active verb) while moving to **blue vs. vermillion**, the strongest hue-contrast pair that stays distinguishable under all three common types of color vision deficiency. The full six-color set is built outward from the [Okabe–Ito palette](https://jfly.uni-koeln.de/color/) — a categorical palette specifically constructed so *every* pair of colors in it remains distinguishable under deuteranopia, protanopia, and tritanopia, rather than optimizing one pair and hoping the rest hold up. Values above are the Okabe–Ito hues brightened for a near-black background; a formal simulator check (Sim Daltonism or equivalent) is still owed before lock, but the palette is safe by construction rather than by luck.

The on-token abbreviation (n. / v. / adj. / adv. / conj. / prep.) remains the actual disambiguator regardless of palette — color is the fast-scan layer for typical vision, text is the guarantee for everyone else. That principle doesn't change with the color choice; only the choice itself improves.

**Never color-only.** Every token also carries a text abbreviation (n. / v. / adj. / adv. / conj. / prep.) so the system holds under any color vision deficiency and in bright outdoor sunlight where saturation reads poorly. This is already implemented (`PartOfSpeech.abbreviation`) and should be treated as non-negotiable, not a checkbox accessibility pass.

### 2.3 Rarity signal

Word rarity (common/uncommon/rare/legendary) currently has no dedicated visual treatment beyond the point-value badge — this is a gap. Recommended direction: a subtle border/glow treatment layered *on top of* the category color, so rarity and category stay visually separable:

- Common — no additional treatment
- Uncommon — thin bright border
- Rare — animated soft glow
- Legendary — glow + a brief shimmer/sparkle on landing

This mirrors trading-card and gacha-game rarity conventions players already read fluently, and gives high-tier spins the "oh!" reaction the scoring system is designed to reward (GAME_LOGIC.md §7).

---

## 3. Typography

- **Rounded system font** (`.rounded` design) throughout — already the prototype's choice, and correct: rounded type reads as friendly/game-like without being childish, and SF Rounded is free, variable-weight, and has excellent Dynamic Type support.
- **Word text:** bold, tight tracking, sized to fill the token — the word itself is always the largest, highest-contrast element on any token.
- **Category label + point value:** small, low-emphasis, secondary — informative, not competing with the word.
- **Sentence preview / story text:** the story strip uses a serif face in the prototype (`.serif`) as a deliberate contrast — signaling "this is prose, being written," distinct from the game-UI rounded sans everywhere else. Worth keeping and extending to the Sentence Gallery.

---

## 4. Reels

### 4.1 Current state (prototype)

Flat rounded rectangles, one per reel, showing either a word token, a bonus token, or an empty/dotted placeholder. No spin animation yet — tokens simply appear.

### 4.2 Target motion design

The reel is the single most important animated element in the game — it's the "slot machine" promise. Target behavior:

- **Vertical scroll-and-settle**, not a flat cut. Each reel spins independently with a staggered stop (~150–200ms offset per reel, left to right), which is what generates anticipation — the player's eye lands on reel 1's result while reels 4–5 are still moving.
- **Overshoot and settle** — the reel should slightly overshoot its landing position and ease back, like physical momentum, rather than stopping dead.
- **Near-miss dramatization** — when a rare/legendary word narrowly misses landing (i.e., appears adjacent in the scroll), briefly slow the scroll as it passes. This is a classic slot-machine technique for manufactured tension; use it honestly — never fake a near-miss that wasn't real, since the deterministic engine means the "miss" is always genuine.
- **Bonus token landing** — a distinct flash/pulse (gold for tokens, per §2.3 direction) so a bonus reads as an event, not just another face.

### 4.3 Pull-to-spin lever

Already implemented in the prototype (`PullToSpin` in `Components.swift`) as a horizontal capsule that stretches and tints as the player drags down, with haptic-ready detents. Visual refinement targets:

- Replace the flat capsule fill with a **tension-mapped gradient** that shifts color as pull approaches the threshold (currently orange throughout; consider orange → green as it crosses the fire point, giving a clear "now" signal).
- Add a **subtle mechanical texture** (a faint diagonal hatch or lever-groove pattern) to reinforce the physical-lever metaphor without adding literal 3D chrome — keep it flat/modern, just texturally hinted.
- The **reel block should physically react** to the pull — a slight downward compression or shake as tension builds, so the lever visually connects to the thing it's about to spin.

---

## 5. The tray & sentence

- **Token flight path:** when a word is banked, it should visibly travel from its reel position down into the tray (matched-geometry transition), not simply appear — this is what sells "the word is now mine." Not yet implemented; prototype currently swaps state instantly.
- **Sentence preview line:** large, bold, sits above the tray — this is the single line a player re-reads most often during a turn, and should never be visually secondary to the reels.
- **Validity meter:** a colored dot + label (red/yellow/green per GAME_LOGIC.md §5) is implemented; consider animating the dot color transition rather than a hard cut, since validity can flip on every reorder.
- **Gem/star decoration:** implemented as a corner badge on the token chip (yellow "×N" flag). Should get a small attach animation (a spark or pulse) at the moment a gem is applied, matching the `gemAttached` effect already emitted by the engine.

---

## 6. Interaction model (visual implications)

**Built.** Tray reordering now uses native drag-and-drop (`draggable`/`dropDestination`), replacing the earlier tap-to-pick/tap-to-place placeholder — resolving both the intended UX (dragging, not tapping) and the gestural conflict it had with the pull-to-spin lever occupying the same lower screen region.

Removal was first built as a long-press on the token, matching pattern conventions elsewhere in iOS — but on-device verification caught a real gesture conflict: `.draggable()` claims the long-press internally to begin its own drag session, so a `.onLongPressGesture` attached to the same view never wins that race and silently never fires. Rather than fight gesture-priority ordering, removal now lives on a small dedicated **×** control in the token's top-leading corner. This is a deterministic tap target with no ambiguity against the drag gesture, and it's also more discoverable and VoiceOver-friendly than a hidden long-press would have been — a case where fixing the bug produced a better interaction than the one it replaced.

Current visual treatment: the dragged token dims to 35% opacity in place while a system drag preview follows the finger, and the drop target position gets a white outline. This is functional but plain — target polish:

- Replace the flat opacity-dim with a proper **lift** (scale up ~1.05×, drop shadow) on the token still following the finger, matching the "physically picked up" feel described for the reel-to-tray flight in §5.
- Animate the **gap** at the drop target — tokens on either side should slide apart to open a visible slot, rather than the current hard-outline indicator, which reads more like a selection state than an insertion point.
- The trailing empty drop zone (for dropping at the very end of the sentence) is currently an invisible hit target; give it a faint dashed-outline "drop here" affordance so it doesn't feel like a dead zone when idle.

---

## 7. Score reveal

Implemented as a modal sheet (`ScoreSheet`) with a line-by-line breakdown, matching the design intent in GAME_DESIGN.md §4.2 (an honest, auditable tally rather than a single number appearing). Current version is functional but static — every line appears at once.

Target motion design:

- **Sequential reveal:** each scoring line animates in with a brief delay between them (raw words → length → grammar → stars → style bonuses → try bonus → streak), building toward the total. The grammar-multiplier line (×2 or ×0.25) is the "applause moment" per GAME_LOGIC.md and should get the most emphatic treatment — a distinct color flash and haptic on reveal.
- **Coin-cascade on the total:** GAME_DESIGN.md §6.1 calls for a physical coin-cascade feel as points land in the team bank; not yet built. This is the second-highest-priority animation after the reel spin itself.
- **Story combo lines** (thread/callback/conjunction-open/chapter-close), when present, should visually connect back to the story strip — e.g., the relevant earlier sentence briefly highlights in the story text as its callback bonus reveals.

---

## 8. Iconography & bonus tokens

Current bonus tokens use single-glyph symbols on a flat yellow chip (×2, ★, +1, ∞, ?, ⇄, 🎁, ⧗). This is a placeholder system, not final art. Direction for real iconography:

- Each bonus deserves a small custom icon (not a system emoji/glyph) so the set reads as a designed family rather than assorted symbols — this matters because bonus tokens are meant to feel like *finding* something special (GAME_LOGIC.md §6).
- Icons should be simple enough to read at token size (roughly 60×74pt) and hold up in grayscale for accessibility contrast checks.
- Rust's icon should visibly communicate decay — a design like a fraying edge or a fading fill, distinct from the "reward" feeling of every other bonus.

---

## 9. Theming & skins (post-launch)

GAME_DESIGN.md §7 and ROADMAP.md Phase 2/5 call for cosmetic machine skins (retro Vegas, sci-fi, wooden saloon) and themed word packs (Pirate, Space, Rom-Com) as the primary non-gameplay monetization and retention lever. Visual system implications to design for now, even though skins aren't built yet:

- The reel frame, background, and lever should be **themeable as a discrete layer**, separate from token category colors (which must stay consistent across skins — a noun is always the same blue, or the legibility system breaks).
- Theme word tags already exist in the data model (`WordEntry.tags`) and drive a scoring bonus (GAME_DESIGN.md §5.1) — the visual system should give theme-tagged words a small badge or accent so players notice *why* a word is worth extra, not just that it is.

---

## 10. Accessibility (visual)

- **Dynamic Type:** token chips currently use `minimumScaleFactor` as a stopgap fallback; a proper pass should define explicit type scale steps for the token/reel layout so text never clips at large accessibility sizes.
- **Reduced motion:** not yet implemented. When enabled, reel spins should resolve instantly to their result (no scroll animation) while every other visual signal (category color, validity meter, score reveal) stays intact — motion is decoration here, never the only carrier of information.
- **Contrast:** category colors were chosen to be distinguishable from each other and from the dark background at a glance; a formal WCAG contrast pass against the final background value is still owed once the background treatment (vignette, texture) is finalized.

---

## 11. Immediate next visual-build priorities

1. Reel spin animation (scroll-and-settle, staggered stops) — the single highest-impact missing visual, since the prototype currently just swaps token state with no motion at all.
2. Token flight from reel to tray on banking.
3. Sequential score-sheet reveal with the coin-cascade on the total.
4. ~~Drag-and-drop tray reordering~~ — built; remaining polish (lift/shadow, gap animation) tracked in §6.
5. Rarity treatment (border/glow) on uncommon+ tokens, so high-value spins get a visible "moment."
