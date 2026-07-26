#!/usr/bin/env python3
"""Headless balance simulator for Message Slots.

Mirrors the Swift engine's rules — the Scrabble letter distribution, the
category-biased draw, the vowel and solvability guarantees, the scoring formula
and the CPU's word choice — so the economy can be measured in seconds rather
than by playing thousands of turns.

**The question this exists to answer.** The category gates submission, so the
one thing that can ruin this game is handing players letters that spell nothing
in the category. `categoryBias` is the knob that prevents it, and there is no
way to set it by intuition: too low and turns strand, too high and the machine
is obviously rigged and every turn plays the same short word.

Usage:
    python3 tools/balance_sim.py                 # all skills, default settings
    python3 tools/balance_sim.py --bias-sweep    # measure the bias knob
    python3 tools/balance_sim.py --strict        # fail if outside bands
"""

from __future__ import annotations

import argparse
import json
import pathlib
import random
import statistics
import sys
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATEGORIES = ROOT / "Sources" / "GameCore" / "Resources" / "categories_starter.json"

# ---------------------------------------------------------------- mirrors ----
# All of the following mirror Sources/GameCore. If a number changes there and
# not here, the simulator silently stops describing the real game — which has
# already happened once in this project's history, so it's worth stating.

# LetterTile.value(of:)
VALUES = {}
for _letters, _v in [
    ("AEIOULNSTR", 1), ("DG", 2), ("BCMP", 3), ("FHVWY", 4),
    ("K", 5), ("JX", 8), ("QZ", 10),
]:
    for _c in _letters:
        VALUES[_c] = _v

# LetterBag.standardDistribution
DISTRIBUTION = {
    "A": 9, "B": 2, "C": 2, "D": 4, "E": 12, "F": 2, "G": 3, "H": 2,
    "I": 9, "J": 1, "K": 1, "L": 4, "M": 2, "N": 6, "O": 8, "P": 2,
    "Q": 1, "R": 6, "S": 4, "T": 6, "U": 4, "V": 2, "W": 2, "X": 1,
    "Y": 2, "Z": 1,
}
LETTERS = sorted(DISTRIBUTION)
BASE_WEIGHTS = [DISTRIBUTION[c] for c in LETTERS]
VOWELS = set("AEIOU")

# EconomyConfig.default
REEL_COUNT = 5
TRIES = 3
TRAY_CAPACITY = 10
MIN_WORD = 3
CATEGORY_BIAS = 3.5
LENGTH_FLOOR = 3
LENGTH_STEP = 4
POINTS_PER_UNUSED_TRY = 8
STREAK_STEP, STREAK_CAP = 0.1, 2.0
FULL_RACK_BONUS = 25
PURE_WORD_BONUS, PURE_WORD_FLOOR = 12, 5
HEAVY_LETTER_BONUS = 10
BONUS_RATE = 0.09

# CPUSkill
SKILLS = {
    "rookie": {"target_length": 3, "greed": 1},
    "steady": {"target_length": 4, "greed": 8},
    "sharp":  {"target_length": 6, "greed": 16},
}

# Health bands. `pass_rate` is the one that matters most: a stranded turn is the
# failure mode the whole category-bias mechanism exists to prevent.
BANDS = {
    "submit_rate":   (0.80, 1.00),
    "pass_rate":     (0.00, 0.15),
    "median_length": (3, 7),
}


def load_categories() -> list[dict]:
    if not CATEGORIES.exists():
        sys.exit(f"compiled categories not found at {CATEGORIES}; "
                 "run tools/compile_categories.py first")
    data = json.loads(CATEGORIES.read_text(encoding="utf-8"))
    out = []
    for category in data["categories"]:
        words = [w.upper() for w in category["words"]]
        out.append({
            "id": category["id"],
            "name": category["name"],
            "words": set(words),
            "by_need": [(w, Counter(w)) for w in words if len(w) <= TRAY_CAPACITY],
        })
    return out


def spellable(category: dict, letters) -> list[str]:
    have = Counter(letters)
    return [w for w, need in category["by_need"]
            if all(have[c] >= n for c, n in need.items())]


# ------------------------------------------------------------------ spin ----

def helpful_letters(category: dict, banked, tries_remaining: int) -> dict:
    """Mirrors SpinResolver.helpfulLetters."""
    have = Counter(banked)
    counts: dict[str, float] = {}

    for word, need in category["by_need"]:
        remaining = have.copy()
        shortfall = 0
        missing: Counter = Counter()
        for c, n in need.items():
            gap = n - remaining[c]
            if gap > 0:
                missing[c] = gap
                shortfall += gap
        if shortfall > max(1, tries_remaining) * REEL_COUNT:
            continue
        weight = 1.0 / max(len(word), 1)
        for c, n in missing.items():
            counts[c] = counts.get(c, 0.0) + weight * n
    return counts


def draw_letter(rng, helpful: dict, bias: float) -> str:
    peak = max(helpful.values()) if helpful else 0
    if peak <= 0:
        return rng.choices(LETTERS, weights=BASE_WEIGHTS, k=1)[0]
    weights = [
        base * (1.0 + (helpful.get(letter, 0.0) / peak) * (bias - 1.0))
        for letter, base in zip(LETTERS, BASE_WEIGHTS)
    ]
    return rng.choices(LETTERS, weights=weights, k=1)[0]


def spin(rng, category: dict, banked, tries_remaining: int, bias: float,
         guarantees: bool = True) -> list[str]:
    helpful = helpful_letters(category, banked, tries_remaining)
    faces = [draw_letter(rng, helpful, bias) for _ in range(REEL_COUNT)]

    if not guarantees:
        return faces

    # Vowel guarantee: a rack with no vowel is unspellable regardless.
    if not any(c in VOWELS for c in list(banked) + faces):
        vowels = sorted(VOWELS)
        faces[-1] = rng.choices(vowels, weights=[DISTRIBUTION[v] for v in vowels], k=1)[0]

    # Solvability guarantee: seed a whole word's worth of missing letters, not
    # one letter. Mirrors SpinResolver.repairPlan — fixing a single reel only
    # reached a 43% submittable rate, because an unspellable word is usually
    # missing several letters.
    if not spellable(category, list(banked) + faces):
        plan = repair_plan(category, list(banked) + faces)
        for i, letter in enumerate(plan):
            if i < REEL_COUNT:
                faces[REEL_COUNT - 1 - i] = letter
    return faces


def repair_plan(category: dict, visible) -> list[str]:
    """Fewest letters needed to make some category word reachable."""
    have = Counter(visible)
    best: list[str] | None = None
    for word, need in category["by_need"]:
        missing: list[str] = []
        remaining = have.copy()
        for c in word:
            if remaining[c] > 0:
                remaining[c] -= 1
            else:
                missing.append(c)
        if len(missing) > REEL_COUNT:
            continue
        if best is None or len(missing) < len(best):
            best = missing
        if not missing:
            break
    return best or []


# ----------------------------------------------------------------- score ----

def score_word(word: str, tries_remaining: int, opening, streak: int = 0) -> int:
    letter_points = sum(VALUES.get(c, 0) for c in word)
    over = max(0, len(word) - LENGTH_FLOOR)
    length_bonus = over * over * LENGTH_STEP

    style = 0
    if len(word) >= PURE_WORD_FLOOR:
        style += PURE_WORD_BONUS
    heavy = sum(1 for c in word if VALUES.get(c, 0) >= 8)
    style += heavy * HEAVY_LETTER_BONUS
    if opening and len(opening) >= REEL_COUNT:
        remaining = Counter(opening)
        for c in word:
            if remaining[c] > 0:
                remaining[c] -= 1
        if not any(v > 0 for v in remaining.values()):
            style += FULL_RACK_BONUS

    try_bonus = tries_remaining * POINTS_PER_UNUSED_TRY
    streak_m = min(1.0 + STREAK_STEP * streak, STREAK_CAP)
    return round((letter_points + length_bonus + style + try_bonus) * streak_m)


def word_value(word: str) -> int:
    over = max(0, len(word) - LENGTH_FLOOR)
    return sum(VALUES.get(c, 0) for c in word) + over * over * LENGTH_STEP


# ------------------------------------------------------------------ turn ----

def play_turn(rng, category: dict, skill: str, bias: float, guarantees: bool = True):
    """Plays one turn the way CPUPlayer does, returning a result dict."""
    profile = SKILLS[skill]
    tries = TRIES
    banked: list[str] = []
    reels: list[str] = []
    opening: list[str] = []

    while True:
        # Spin if we have tries and no reason to stop.
        if tries > 0 and not reels:
            reels = spin(rng, category, banked, tries - 1, bias, guarantees)
            tries -= 1
            if not opening:
                opening = list(reels)

        candidates = spellable(category, banked + reels)
        if not candidates:
            if tries > 0:
                reels = []
                continue
            return {"submitted": False, "word": "", "score": 0,
                    "length": 0, "tries_left": tries}

        target = (min(candidates, key=lambda w: (len(w), w)) if skill == "rookie"
                  else max(sorted(candidates), key=word_value))

        # Take what the target needs from the reels.
        need = Counter(target)
        for c in banked:
            if need[c] > 0:
                need[c] -= 1
        # Drop banked letters the target doesn't want.
        keep: list[str] = []
        want = Counter(target)
        for c in banked:
            if want[c] > 0:
                want[c] -= 1
                keep.append(c)
        banked = keep

        took = False
        for i, face in enumerate(reels):
            if need.get(face, 0) > 0 and len(banked) < TRAY_CAPACITY:
                banked.append(face)
                need[face] -= 1
                reels[i] = ""
                took = True
        reels = [r for r in reels if r]

        if "".join(banked) == target or not need or sum(need.values()) == 0:
            # Content? Sharp bots push for a better word while tries remain.
            projected = score_word(target, tries, opening)
            if tries > 0 and len(target) < profile["target_length"] and projected < profile["greed"]:
                reels = []
                continue
            return {"submitted": True, "word": target, "score": projected,
                    "length": len(target), "tries_left": tries}

        if tries == 0 and not took:
            return {"submitted": False, "word": "", "score": 0,
                    "length": 0, "tries_left": 0}
        if not took:
            reels = []


# ----------------------------------------------------------------- report ----

def run(categories, skill: str, turns: int, seed: int, bias: float,
        guarantees: bool = True):
    rng = random.Random(seed)
    results = []
    for _ in range(turns):
        category = rng.choice(categories)
        results.append(play_turn(rng, category, skill, bias, guarantees))

    submitted = [r for r in results if r["submitted"]]
    n = len(results)
    return {
        "submit_rate": len(submitted) / n,
        "pass_rate": 1 - len(submitted) / n,
        "median_length": statistics.median([r["length"] for r in submitted]) if submitted else 0,
        "median_score": statistics.median([r["score"] for r in submitted]) if submitted else 0,
        "mean_score": statistics.mean([r["score"] for r in submitted]) if submitted else 0,
        "results": results,
    }


def bias_sweep(categories, turns: int, seed: int):
    """Measures the single most important number in the game."""
    print("\n  categoryBias sweep — 'steady' bot, guarantees ON")
    print(f"  {'bias':>6}  {'submit':>7}  {'passes':>7}  {'med len':>8}  {'med score':>10}")
    for bias in [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.5, 6.0, 9.0]:
        m = run(categories, "steady", turns, seed, bias)
        print(f"  {bias:>6.1f}  {m['submit_rate']:>6.0%}  {m['pass_rate']:>7.0%}  "
              f"{m['median_length']:>8.0f}  {m['median_score']:>10.0f}")

    print("\n  guarantees OFF (what the bias alone achieves)")
    print(f"  {'bias':>6}  {'submit':>7}  {'passes':>7}")
    for bias in [1.0, 2.0, 3.5, 6.0]:
        m = run(categories, "steady", turns, seed, bias, guarantees=False)
        print(f"  {bias:>6.1f}  {m['submit_rate']:>6.0%}  {m['pass_rate']:>7.0%}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--turns", type=int, default=1500)
    ap.add_argument("--seed", type=int, default=20_260_726)
    ap.add_argument("--bias", type=float, default=CATEGORY_BIAS)
    ap.add_argument("--bias-sweep", action="store_true")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    categories = load_categories()
    print(f"Message Slots balance simulation — {args.turns} turns/skill, "
          f"seed={args.seed}, categoryBias={args.bias}")
    print(f"  {len(categories)} categories, "
          f"{sum(len(c['words']) for c in categories)} words")

    failed = False
    for skill in ["rookie", "steady", "sharp"]:
        m = run(categories, skill, args.turns, args.seed, args.bias)
        print(f"\n  skill: {skill}")
        for key, (lo, hi) in BANDS.items():
            value = m[key]
            ok = lo <= value <= hi
            failed = failed or not ok
            shown = f"{value:.0%}" if key.endswith("rate") else f"{value:.1f}"
            band = f"{lo:.0%}–{hi:.0%}" if key.endswith("rate") else f"{lo}–{hi}"
            print(f"    {'PASS' if ok else 'FAIL'}  {key:<14} {shown:>7}   band {band}")
        print(f"    score: mean {m['mean_score']:.0f}, median {m['median_score']:.0f}")
        lengths = Counter(r["length"] for r in m["results"] if r["submitted"])
        print(f"    lengths: {dict(sorted(lengths.items()))}")

    if args.bias_sweep:
        bias_sweep(categories, args.turns, args.seed)

    if args.strict and failed:
        print("\n  BANDS NOT MET", file=sys.stderr)
        return 1
    print("\n  done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
