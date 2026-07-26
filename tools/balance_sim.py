#!/usr/bin/env python3
"""Headless balance simulator for Message Slots (docs/ARCHITECTURE.md §11).

Mirrors the Swift engine's rules — reel role weighting, tier draw, verb pity,
the dead-end guarantee, the template grammar, the scoring formula and the CPU
player's heuristics — and runs thousands of bot turns to check the economy
against the health targets in docs/GAME_DESIGN.md §8:

    valid-sentence rate      75-85%
    median sentence length   5-6 words
    all-tries-used rate      60-70%
    pity activation rate     < 15%

This is a *tuning* tool, not a second implementation of the game: when it and
GameCore disagree, GameCore wins and this file gets fixed. Its value is that it
runs anywhere, in seconds, so economy changes can be checked before they reach
a device.

Usage:
    python3 tools/balance_sim.py [--turns 5000] [--skill steady] [--seed 1]
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
POOL_PATH = ROOT / "Sources" / "GameCore" / "Resources" / "words_starter.json"

# ---------------------------------------------------------------- economy ----
# Mirrors EconomyConfig.default in Sources/GameCore/Economy/EconomyConfig.swift.

REEL_COUNT = 5
TRIES_PER_TURN = 5
TRAY_SIZE = 10

TIER_SHARES = {"common": 0.55, "uncommon": 0.30, "rare": 0.12, "legendary": 0.03}

REEL_ROLES = [
    {"ART": 4.0, "PRON": 2.5, "ADJ": 1.5, "NOUN": 2.0, "VERB": 0.5, "ADV": 0.4, "CONJ": 0.6, "PREP": 0.5},
    {"ADJ": 4.0, "NOUN": 2.0, "ADV": 1.5, "ART": 1.0, "VERB": 1.0, "PRON": 0.6, "CONJ": 0.4, "PREP": 0.5},
    {"NOUN": 5.0, "ADJ": 1.2, "PRON": 1.0, "VERB": 1.2, "ART": 0.8, "ADV": 0.5, "CONJ": 0.3, "PREP": 0.5},
    {"VERB": 5.0, "ADV": 1.6, "NOUN": 1.2, "ADJ": 0.8, "PREP": 0.8, "ART": 0.5, "PRON": 0.4, "CONJ": 0.3},
    {"CONJ": 2.6, "PREP": 2.0, "ADV": 1.8, "NOUN": 1.6, "VERB": 1.6, "ADJ": 1.4, "ART": 1.2, "PRON": 1.0},
]

BONUS_RATE = 0.08
LAST_REEL_BONUS_MULTIPLIER = 2.0
MAX_BONUS_FACES_PER_SPIN = 2
BONUS_WEIGHTS = {
    "wordGem2": 3.0, "wordGem3": 1.2, "sentenceStar": 1.8, "extraTry": 2.2,
    "frenzy": 0.8, "wildCard": 1.6, "swap": 1.4, "gift": 1.6, "rust": 1.0,
}

PITY_VERB_TRIES_THRESHOLD = 2
PITY_VERB_WEIGHT_MULTIPLIER = 3.0

LENGTH_STEP, LENGTH_FLOOR, LENGTH_CAP = 0.25, 3, 3.0
GRAMMAR_VALID, GRAMMAR_SALAD = 2.0, 0.25
STAR_STEP = 0.5
POINTS_PER_UNUSED_TRY = 10
STREAK_STEP, STREAK_CAP = 0.1, 2.0
ALLITERATION_BONUS = 15
RHYME_BONUS = 15
# Mirrors EconomyConfig.senseBonus (Sources/GameCore/Economy/EconomyConfig.swift).
# Additive only — see evaluate_coherence() below and GAME_LOGIC.md §5.1.
SENSE_BONUS = 30

# Health targets from docs/GAME_DESIGN.md §8, per player profile.
#
# These are regression bands, not aspirations: they were measured against the
# shipping economy once it played well, and they exist so that a change to reel
# weights or the word pool cannot quietly break the feel of a turn. Widen them
# deliberately, never to make a red run go green.
PROFILE_TARGETS = {
    # A player squeezing every point out of the turn — the ceiling.
    "human":  {"valid_rate": (0.82, 0.95), "median_length": (6, 8), "all_tries_rate": (0.70, 0.92), "pity_rate": (0.0, 0.15)},
    # The CPU teammate profiles.
    "sharp":  {"valid_rate": (0.80, 0.95), "median_length": (5, 8), "all_tries_rate": (0.50, 0.90), "pity_rate": (0.0, 0.15)},
    "steady": {"valid_rate": (0.80, 0.95), "median_length": (4, 6), "all_tries_rate": (0.10, 0.50), "pity_rate": (0.0, 0.15)},
    "rookie": {"valid_rate": (0.60, 0.95), "median_length": (3, 5), "all_tries_rate": (0.00, 0.40), "pity_rate": (0.0, 0.15)},
}

# Invariants that must hold for every profile. These are the ones that actually
# protect the player experience: a turn that scores nothing is a turn that felt
# like a waste, and the design promises there is no such thing.
def universal_invariants(results):
    scores = [r["total"] for r in results]
    return [
        ("no zero-score turns", sum(1 for s in scores if s == 0) == 0),
        ("no empty trays", all(r["length"] >= 2 for r in results)),
        ("bottom decile still scores", sorted(scores)[len(scores) // 10] > 0),
    ]

GLUE = {"ART", "PRON", "CONJ", "PREP"}

# --------------------------------------------------------------- grammar ----
# Mirrors SentenceTemplate.standard.

TEMPLATES = [
    "ART? ADJ* NOUN|PRON ADV? VERB ADV?",
    "ART? ADJ* NOUN|PRON ADV? VERB ART? ADJ* NOUN|PRON ADV?",
    "ART? ADJ* NOUN|PRON ADV? VERB ADV? ADJ+",
    "ART? ADJ* NOUN|PRON ADV? VERB ADV? PREP ART? ADJ* NOUN|PRON",
    "ART? ADJ* NOUN|PRON ADV? VERB ART? ADJ* NOUN|PRON PREP ART? ADJ* NOUN|PRON",
    "ADV ART? ADJ* NOUN|PRON ADV? VERB ART? ADJ* NOUN|PRON?",
]


def parse_template(pattern: str):
    elements = []
    for raw in pattern.split():
        quant = ""
        if raw[-1] in "?*+":
            quant, raw = raw[-1], raw[:-1]
        elements.append((set(raw.split("|")), quant))
    return elements


PARSED_TEMPLATES = [parse_template(t) for t in TEMPLATES]


def matches(clause, elements) -> bool:
    """Backtracking match of word POS-sets against a template."""

    def go(ei: int, wi: int) -> bool:
        if ei == len(elements):
            return wi == len(clause)
        alts, quant = elements[ei]
        accepts = wi < len(clause) and bool(alts & clause[wi])
        if quant == "":
            return accepts and go(ei + 1, wi + 1)
        if quant == "?":
            if accepts and go(ei + 1, wi + 1):
                return True
            return go(ei + 1, wi)
        consumed = 0
        if quant == "+":
            if not accepts:
                return False
            consumed = 1
        while True:
            if go(ei + 1, wi + consumed):
                return True
            if wi + consumed >= len(clause) or not (alts & clause[wi + consumed]):
                return False
            consumed += 1

    return go(0, 0)


def clause_matches(clause) -> bool:
    return any(matches(clause, t) for t in PARSED_TEMPLATES)


def attempt(words) -> bool:
    """Split on pure conjunctions, then require every clause to match."""
    clauses, current = [], []
    for i, w in enumerate(words):
        pure_conj = w["pos"] == {"CONJ"}
        interior = 0 < i < len(words) - 1
        if pure_conj and interior and current:
            clauses.append(current)
            current = []
        else:
            current.append(w)
    if current:
        clauses.append(current)
    return bool(clauses) and all(clause_matches([w["pos"] for w in c]) for c in clauses)


def is_valid_sentence(tray) -> bool:
    if len(tray) < 2:
        return False
    if attempt(tray):
        return True
    if "CONJ" in tray[0]["pos"] and len(tray) > 2:
        return attempt(tray[1:])
    return False


# ------------------------------------------------------------------ pool ----

def load_pool():
    if not POOL_PATH.exists():
        sys.exit(f"compiled pool not found at {POOL_PATH}; run tools/compile_pools.py first")
    raw = json.loads(POOL_PATH.read_text(encoding="utf-8"))["words"]
    words = []
    for w in raw:
        pos = set(w["pos"])
        words.append({
            "text": w["text"],
            "pos": pos,
            "tier": w["tier"],
            "points": w["points"] + (1 if len(pos) > 1 else 0),  # multi-category premium
            "tags": w.get("tags", []),
            "semantics": set(w.get("semantics", [])),
            # Authored draw frequency (see WordEntry.weight). Absent = neutral.
            "weight": float(w.get("weight", 1.0)),
            "noun_like": bool(pos & {"NOUN", "PRON"}),
            "verb_like": "VERB" in pos,
        })
    return words


# ------------------------------------------------------------------ spin ----

def weighted_choice(rng, items, weights):
    total = sum(weights)
    if not items or total <= 0:
        return None
    roll = rng.random() * total
    for item, weight in zip(items, weights):
        roll -= weight
        if roll <= 0:
            return item
    return items[-1]


def draw_word(rng, pool, reel, pity, used):
    tier = weighted_choice(rng, list(TIER_SHARES), list(TIER_SHARES.values()))
    role = REEL_ROLES[min(reel, len(REEL_ROLES) - 1)]
    parts, weights = [], []
    for pos, w in role.items():
        if w <= 0:
            continue
        parts.append(pos)
        weights.append(w * (PITY_VERB_WEIGHT_MULTIPLIER if pity and pos == "VERB" else 1.0))
    pos = weighted_choice(rng, parts, weights) or "NOUN"

    for candidates in (
        [w for w in pool if w["tier"] == tier and pos in w["pos"]],
        [w for w in pool if pos in w["pos"]],
        pool,
    ):
        available = [w for w in candidates if w["text"] not in used]
        if available:
            # Weighted, not uniform — mirrors SpinResolver.weight(for:). Using
            # rng.choice here would silently ignore the authored frequencies and
            # the simulator would stop reflecting what players actually see.
            return weighted_choice(rng, available, [w["weight"] for w in available])
    return None


def spin(rng, pool, reels, tray, tries_remaining, excluded):
    """Returns (faces dict, pity_applied, repair_applied)."""
    pity = not any(w["verb_like"] for w in tray) and tries_remaining <= PITY_VERB_TRIES_THRESHOLD
    faces, used, bonuses = {}, set(excluded), 0

    for reel in sorted(reels):
        rate = BONUS_RATE * (LAST_REEL_BONUS_MULTIPLIER if reel == REEL_COUNT - 1 else 1.0)
        if bonuses < MAX_BONUS_FACES_PER_SPIN and rng.random() < rate:
            slot = weighted_choice(rng, list(BONUS_WEIGHTS), list(BONUS_WEIGHTS.values()))
            faces[reel] = {"bonus": slot}
            bonuses += 1
            continue
        word = draw_word(rng, pool, reel, pity, used)
        if word:
            used.add(word["text"])
            faces[reel] = {"word": word}

    # Dead-end guarantee. Mirrors SpinResolver.repairIfDeadEnd — including the
    # protection of reels that already supply a role, whether the repair placed
    # the word or the spin landed it. Without that, the NOUN pass overwrites the
    # only verb and hands back a table no sentence can be built from.
    repaired = False
    protected = set()

    def supplies(word, role):
        return word["noun_like"] if role == "NOUN" else role in word["pos"]

    needs = (("VERB", any(w["verb_like"] for w in tray)),
             ("NOUN", any(w["noun_like"] for w in tray)))

    for needed, in_tray in needs:
        if in_tray:
            continue
        providers = [r for r, f in faces.items() if "word" in f and supplies(f["word"], needed)]
        if len(providers) == 1:
            protected.add(providers[0])

    for needed, in_tray in needs:
        spun = [f["word"] for f in faces.values() if "word" in f]
        present = any(supplies(w, needed) for w in spun)
        if in_tray or present:
            continue
        available = [r for r in reels if r not in protected]
        targets = [r for r in available if "word" in faces.get(r, {})] or available
        if not targets:
            continue
        options = [w for w in pool
                   if needed in w["pos"]
                   and w["text"] not in {s["text"] for s in spun}
                   and w["text"] not in excluded]
        if options:
            faces[targets[-1]] = {"word": rng.choice(options)}
            protected.add(targets[-1])
            repaired = True

    return faces, pity, repaired


# ------------------------------------------------------------------- bot ----

# The three CPU skills mirror CPUSkill in Swift. `human` is a fourth profile
# that exists only here: it models an engaged player who keeps pushing while
# tries remain, and it is the profile the economy health targets are written
# against. Measuring balance against a polite CPU teammate would flatter the
# numbers — the bot stops as soon as it is satisfied, a person does not.
SKILLS = {
    "rookie": {"greed": 1, "target": 3},
    "steady": {"greed": 2, "target": 5},
    "sharp": {"greed": 4, "target": 7},
    "human": {"greed": 1, "target": 9},
}


def play_turn(rng, pool, skill):
    """Mirrors CPUPlayer's heuristics closely enough to test the economy."""
    cfg = SKILLS[skill]
    tray, tries, stars, gems = [], TRIES_PER_TURN, 0, []
    faces, pity_used = {}, False
    opening_words = None

    while True:
        # Banking empties a face; every reel re-spins, so a sentence can grow
        # well past five words across five tries.
        spinnable = list(range(REEL_COUNT))
        if tries <= 0:
            break
        excluded = {w["text"] for w in tray}
        tries -= 1
        new_faces, pity, _ = spin(rng, pool, spinnable, tray, tries, excluded)
        faces = new_faces
        pity_used = pity_used or pity
        if opening_words is None:
            opening_words = {f["word"]["text"] for f in faces.values() if "word" in f}

        progressed = True
        while progressed:
            progressed = False

            # 1. Collect bonuses.
            for reel, face in list(faces.items()):
                if "bonus" not in face:
                    continue
                slot = face["bonus"]
                if slot == "wordGem2":
                    gems.append(2)
                elif slot == "wordGem3":
                    gems.append(3)
                elif slot == "sentenceStar":
                    stars += 1
                elif slot == "extraTry":
                    tries += 1
                del faces[reel]
                progressed = True

            # 2. Fill missing categories, then 3. bank worthwhile words.
            missing = []
            if not any(w["noun_like"] for w in tray):
                missing.append("NOUN")
            if not any(w["verb_like"] for w in tray):
                missing.append("VERB")

            def available():
                return [(r, f["word"]) for r, f in faces.items() if "word" in f]

            picked = None
            for needed in missing:
                options = [(r, w) for r, w in available()
                           if (w["noun_like"] if needed == "NOUN" else needed in w["pos"])]
                if options and len(tray) < TRAY_SIZE:
                    picked = max(options, key=lambda rw: rw[1]["points"])
                    break

            if picked is None and len(tray) < min(cfg["target"], TRAY_SIZE):
                tray_valid = is_valid_sentence(tray)
                if tray_valid or len(tray) < 2:
                    threshold = 1 if tries <= 1 else cfg["greed"]
                    options = [(r, w) for r, w in available() if w["points"] >= threshold]
                    if options:
                        candidate = max(options, key=lambda rw: rw[1]["points"])
                        # A word may be slotted anywhere in the tray, not just
                        # appended — players drag, so the bot considers the same.
                        fits = any(
                            is_valid_sentence(tray[:i] + [candidate[1]] + tray[i:])
                            for i in range(len(tray) + 1)
                        )
                        if not tray_valid or fits:
                            picked = candidate

            if picked is not None:
                reel, word = picked
                entry = dict(word)
                entry["gem"] = gems.pop(0) if gems else 1
                # Slot it wherever it keeps the sentence legal, preferring the end.
                best_tray = tray + [entry]
                if not is_valid_sentence(best_tray):
                    for i in range(len(tray) + 1):
                        probe = tray[:i] + [entry] + tray[i:]
                        if is_valid_sentence(probe):
                            best_tray = probe
                            break
                tray = best_tray
                del faces[reel]      # the face empties; it refills next spin
                progressed = True

        if is_valid_sentence(tray) and len(tray) >= cfg["target"]:
            break

    # Best-effort reorder, as the bot does.
    if len(tray) >= 2 and not is_valid_sentence(tray):
        for i in range(len(tray)):
            for j in range(len(tray)):
                if i == j:
                    continue
                probe = tray[:]
                probe.insert(j, probe.pop(i))
                if is_valid_sentence(probe):
                    tray = probe
                    break
            if is_valid_sentence(tray):
                break

    return score_turn(tray, tries, stars, opening_words or set()), pity_used


def evaluate_coherence(tray) -> bool:
    """Mirrors CoherenceEvaluator.evaluate (Language/SemanticCoherence.swift):
    first verb-like word, last noun-like word before it, both tagged, and the
    subject's class is one the verb claims. Untagged or absent either side is
    "no opinion" (False), never a penalty — only score_turn's caller decides
    whether to add the bonus, nothing here can subtract."""
    verb_idx = next((i for i, w in enumerate(tray) if w["verb_like"]), None)
    if verb_idx is None:
        return False
    subject_idx = None
    for i in range(verb_idx - 1, -1, -1):
        if tray[i]["noun_like"]:
            subject_idx = i
            break
    if subject_idx is None:
        return False
    subject, verb = tray[subject_idx], tray[verb_idx]
    if not subject["semantics"] or not verb["semantics"]:
        return False
    subject_class = next(iter(subject["semantics"]))
    return subject_class in verb["semantics"]


def score_turn(tray, tries_remaining, stars, opening_words):
    counted, raw = set(), 0
    for w in tray:
        if w["text"] in counted:
            continue
        counted.add(w["text"])
        raw += w["points"] * w.get("gem", 1)

    valid = is_valid_sentence(tray)
    length_m = min(1.0 + LENGTH_STEP * max(0, len(tray) - LENGTH_FLOOR), LENGTH_CAP)
    grammar_m = GRAMMAR_VALID if valid else GRAMMAR_SALAD
    star_m = 1.0 + STAR_STEP * stars

    style = 0
    content = [w for w in tray if not w["pos"] <= GLUE]
    initials = Counter(w["text"][0] for w in content)
    if initials and max(initials.values()) >= 3:
        style += ALLITERATION_BONUS
    endings = Counter(w["text"][-3:] for w in tray if len(w["text"]) >= 4)
    if endings and max(endings.values()) >= 2:
        style += RHYME_BONUS
    if evaluate_coherence(tray):
        style += SENSE_BONUS

    try_bonus = tries_remaining * POINTS_PER_UNUSED_TRY
    total = (raw * length_m * grammar_m * star_m + style + try_bonus)

    return {
        "total": round(total),
        "valid": valid,
        "length": len(tray),
        "tries_remaining": tries_remaining,
        "used_all_tries": tries_remaining == 0,
    }


# ------------------------------------------------------------------ main ----

def run_profile(pool, skill: str, turns: int, seed: int):
    rng = random.Random(seed)
    results, pity_count = [], 0
    for _ in range(turns):
        result, pity = play_turn(rng, pool, skill)
        results.append(result)
        pity_count += 1 if pity else 0

    n = len(results)
    metrics = {
        "valid_rate": sum(r["valid"] for r in results) / n,
        "median_length": statistics.median(r["length"] for r in results),
        "all_tries_rate": sum(r["used_all_tries"] for r in results) / n,
        "pity_rate": pity_count / n,
    }
    return results, metrics


def report(skill: str, results, metrics) -> list[str]:
    n = len(results)
    scores = sorted(r["total"] for r in results)
    failures = []

    print(f"\n  profile: {skill}")
    for key, (lo, hi) in PROFILE_TARGETS[skill].items():
        value = metrics[key]
        ok = lo <= value <= hi
        if not ok:
            failures.append(f"[{skill}] {key}={value:.3f} outside {lo}–{hi}")
        shown = f"{value:.1%}" if key.endswith("rate") else f"{value:.1f}"
        target = f"{lo:.0%}–{hi:.0%}" if key.endswith("rate") else f"{lo}–{hi}"
        print(f"    {'PASS' if ok else 'MISS'}  {key:<16} {shown:>8}   band {target}")

    for name, ok in universal_invariants(results):
        if not ok:
            failures.append(f"[{skill}] invariant broken: {name}")
        print(f"    {'PASS' if ok else 'FAIL'}  {name}")

    print(f"    score: mean {statistics.mean(scores):.0f}, median {statistics.median(scores):.0f}, "
          f"p10 {scores[n // 10]}, p90 {scores[n * 9 // 10]}")
    print(f"    lengths: {dict(sorted(Counter(r['length'] for r in results).items()))}")
    return failures


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--turns", type=int, default=2000)
    ap.add_argument("--skill", choices=sorted(SKILLS), default="human")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--all", action="store_true", help="run every profile")
    ap.add_argument("--strict", action="store_true", help="exit non-zero if any band is missed")
    args = ap.parse_args()

    pool = load_pool()
    profiles = sorted(SKILLS) if args.all else [args.skill]

    print(f"Message Slots balance simulation — {args.turns} turns/profile, seed={args.seed}")
    print(f"  pool: {len(pool)} words")

    failures = []
    for skill in profiles:
        results, metrics = run_profile(pool, skill, args.turns, args.seed)
        failures += report(skill, results, metrics)

    if failures:
        print("\n  tuning needed:")
        for f in failures:
            print(f"    - {f}")
        return 1 if args.strict else 0

    print("\n  all bands and invariants met")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
