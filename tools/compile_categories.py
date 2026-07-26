#!/usr/bin/env python3
"""Compile category word lists into the JSON resource GameCore loads.

Since the category list *is* the dictionary (see CategoryPack.swift), the
validation here is doing real design work rather than just checking syntax. The
question it answers is: **can a player actually finish a turn in this
category?**

A turn offers 5 reels over 3 spins, so the letters available are few and random.
A category full of long words is unplayable regardless of how well curated it
is. The checks below therefore enforce short-word coverage, and simulate real
draws from the Scrabble distribution to measure how often a category is
solvable at all.

Usage:
    python3 tools/compile_categories.py [--check-only] [--simulate N]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import random
import sys
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Content" / "categories_starter.txt"
OUT_DIR = ROOT / "Sources" / "GameCore" / "Resources"
OUT = OUT_DIR / "categories_starter.json"

# Mirrors LetterBag.standardDistribution in Sources/GameCore/Letters/LetterTile.swift.
DISTRIBUTION = {
    "A": 9, "B": 2, "C": 2, "D": 4, "E": 12, "F": 2, "G": 3, "H": 2,
    "I": 9, "J": 1, "K": 1, "L": 4, "M": 2, "N": 6, "O": 8, "P": 2,
    "Q": 1, "R": 6, "S": 4, "T": 6, "U": 4, "V": 2, "W": 2, "X": 1,
    "Y": 2, "Z": 1,
}
LETTERS = sorted(DISTRIBUTION)
WEIGHTS = [DISTRIBUTION[c] for c in LETTERS]

# A turn's realistic letter budget: 5 reels, 3 spins, but a player banks as they
# go and can't keep everything. 8 is a fair working estimate of what's in hand.
TURN_LETTERS = 8

# Health thresholds.
#
# `solve_rate` measures **unbiased** draws — pure Scrabble-bag randomness with
# no help. That is deliberately not how the game draws letters: because the
# category gates submission, drawing uniformly and hoping produces dead turns
# constantly (measured: only 13% of random racks can spell a musical
# instrument, since short ones barely exist beyond UKE and SAX). `SpinResolver`
# therefore biases reels toward letters that complete a word in the *active*
# category, the way the old design's verb-pity system worked — except here it's
# the primary mechanism rather than a safety net.
#
# So this number is a floor, not a target: it says "even with no help, this
# category isn't hopeless". Short-word coverage is the stronger signal, because
# biasing can raise the odds of finding a word but cannot invent short ones.
MIN_SHORT_WORDS = 15      # words of length <= 4
MIN_SOLVE_RATE = 0.10     # unbiased floor; the engine's biasing does the rest


def parse(path: pathlib.Path) -> list[dict]:
    if not path.exists():
        sys.exit(f"source not found: {path}")

    categories: list[dict] = []
    current: dict | None = None

    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        if line.startswith("@"):
            header = line[1:]
            parts = [p.strip() for p in header.split("|")]
            if len(parts) < 2:
                sys.exit(f"{path.name}:{lineno}: header needs '@id | Name [| hint]'")
            current = {
                "id": parts[0],
                "name": parts[1],
                "hint": parts[2] if len(parts) > 2 and parts[2] else None,
                "words": [],
            }
            categories.append(current)
            continue

        if current is None:
            sys.exit(f"{path.name}:{lineno}: words before any '@category' header")

        for token in line.split():
            word = token.strip().upper()
            if not word.isalpha():
                sys.exit(f"{path.name}:{lineno}: {word!r} is not alphabetic")
            current["words"].append(word)

    # Dedupe while keeping the file's order stable for readable diffs.
    for category in categories:
        seen: set[str] = set()
        unique = []
        for word in category["words"]:
            if word not in seen:
                seen.add(word)
                unique.append(word)
        category["words"] = unique

    return categories


def solve_rate(words: set[str], trials: int, rng: random.Random) -> float:
    """Fraction of random racks from which at least one word is spellable."""
    by_length: dict[int, list[Counter]] = {}
    for word in words:
        by_length.setdefault(len(word), []).append(Counter(word))

    lengths = sorted(by_length)
    solved = 0
    for _ in range(trials):
        rack = Counter(rng.choices(LETTERS, weights=WEIGHTS, k=TURN_LETTERS))
        hit = False
        for length in lengths:
            if length > TURN_LETTERS:
                break
            for need in by_length[length]:
                if all(rack[c] >= n for c, n in need.items()):
                    hit = True
                    break
            if hit:
                break
        solved += 1 if hit else 0
    return solved / trials


def validate(category: dict, trials: int, rng: random.Random) -> tuple[list[str], dict]:
    problems: list[str] = []
    words = set(category["words"])
    name = category["id"]

    if not words:
        return [f"{name}: no words"], {}

    lengths = Counter(len(w) for w in words)
    short = sum(count for length, count in lengths.items() if length <= 4)
    if short < MIN_SHORT_WORDS:
        problems.append(
            f"{name}: only {short} words of 4 letters or fewer "
            f"(need {MIN_SHORT_WORDS}) — will produce dead turns"
        )

    if not any(length <= 3 for length in lengths):
        problems.append(f"{name}: no words of 3 letters or fewer")

    rate = solve_rate(words, trials, rng)
    if rate < MIN_SOLVE_RATE:
        problems.append(
            f"{name}: only {rate:.0%} of random racks have a playable word "
            f"(need {MIN_SOLVE_RATE:.0%})"
        )

    stats = {
        "words": len(words),
        "short": short,
        "shortest": min(lengths),
        "longest": max(lengths),
        "solve_rate": rate,
    }
    return problems, stats


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check-only", action="store_true")
    ap.add_argument("--simulate", type=int, default=3000,
                    help="racks to simulate per category when measuring solve rate")
    args = ap.parse_args()

    categories = parse(SOURCE)
    rng = random.Random(20_260_726)

    print(f"{SOURCE.name}: {len(categories)} categories")
    failed = False
    total_words = 0

    for category in categories:
        problems, stats = validate(category, args.simulate, rng)
        total_words += stats.get("words", 0)
        if stats:
            print(
                f"  {category['id']:<14} {stats['words']:>4} words  "
                f"{stats['short']:>3} short  "
                f"len {stats['shortest']}-{stats['longest']}  "
                f"solvable {stats['solve_rate']:.0%}"
            )
        for problem in problems:
            failed = True
            print(f"    FAIL {problem}", file=sys.stderr)

    print(f"  total: {total_words} words")

    if failed:
        print("\n  VALIDATION FAILED", file=sys.stderr)
        return 1
    print("  validation passed")

    if not args.check_only:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        payload = {
            "id": SOURCE.stem,
            "categories": [
                {
                    "id": c["id"],
                    "name": c["name"],
                    **({"hint": c["hint"]} if c["hint"] else {}),
                    "words": sorted(set(c["words"])),
                }
                for c in categories
            ],
        }
        OUT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        print(f"  wrote {OUT.relative_to(ROOT)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
