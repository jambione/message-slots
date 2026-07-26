#!/usr/bin/env python3
"""Compile Message Slots word-pool CSVs into the JSON resource consumed by GameCore.

Also runs the content validation described in docs/ARCHITECTURE.md §10:
  - no duplicate words
  - POS coverage quotas (enough verbs / nouns / glue words to form sentences)
  - tier mix within tolerance of the design target (55/30/12/3)
  - every tier has at least one noun and one verb (pity system needs an escape hatch)

Usage:
    python3 tools/compile_pools.py [--check-only]

Run from the repository root. Exits non-zero if validation fails, so it can be
wired into an Xcode build phase or CI.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTENT_DIR = ROOT / "Content"
OUT_DIR = ROOT / "Sources" / "GameCore" / "Resources"

VALID_POS = {"NOUN", "VERB", "ADJ", "ADV", "CONJ", "PREP", "ART", "PRON"}
VALID_TIERS = {"common", "uncommon", "rare", "legendary"}
# Mirrors SemanticCategory in Sources/GameCore/Language/SemanticCoherence.swift.
# For a NOUN: the kind of thing it is. For a VERB: the subject kinds it
# plausibly takes. Sparse and optional by design — see that file's doc comment
# for why an untagged word is "no opinion", never "wrong".
VALID_SEMANTICS = {"animate", "place", "food", "object", "abstract"}

# Design target from docs/GAME_DESIGN.md §3.1, with generous tolerance for a
# hand-authored starter pool. Tighten these as the pool grows toward 1,200 words.
TIER_TARGET = {"common": 0.55, "uncommon": 0.30, "rare": 0.12, "legendary": 0.03}
TIER_TOLERANCE = 0.12

# Minimum share of the pool that must be capable of each role. A pool that fails
# these will strand players mid-turn no matter how good the pity system is.
POS_QUOTA = {"VERB": 0.15, "NOUN": 0.25}
GLUE_QUOTA = 0.12  # ART + PRON + CONJ + PREP combined

# Point value sanity per tier (min, max).
TIER_POINTS = {
    "common": (1, 2),
    "uncommon": (3, 5),
    "rare": (6, 8),
    "legendary": (9, 10),
}


def parse_csv(path: pathlib.Path) -> list[dict]:
    entries: list[dict] = []
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 4:
            raise SystemExit(f"{path.name}:{lineno}: expected 4-7 fields, got {len(parts)}: {raw!r}")
        text, pos_field, tier, points = parts[0], parts[1], parts[2], parts[3]
        tags_field = parts[4] if len(parts) > 4 else ""
        semantics_field = parts[5] if len(parts) > 5 else ""
        weight_field = parts[6] if len(parts) > 6 else ""

        pos = [p for p in pos_field.split("|") if p]
        bad = set(pos) - VALID_POS
        if bad:
            raise SystemExit(f"{path.name}:{lineno}: unknown part(s) of speech {sorted(bad)}")
        if tier not in VALID_TIERS:
            raise SystemExit(f"{path.name}:{lineno}: unknown tier {tier!r}")
        try:
            pts = int(points)
        except ValueError:
            raise SystemExit(f"{path.name}:{lineno}: points must be an integer, got {points!r}")

        semantics = [s for s in semantics_field.split("|") if s]
        bad_sem = set(semantics) - VALID_SEMANTICS
        if bad_sem:
            raise SystemExit(f"{path.name}:{lineno}: unknown semantic categor{'y' if len(bad_sem) == 1 else 'ies'} {sorted(bad_sem)}")

        # Draw frequency, deliberately independent of rarity. Omitted means 1.0.
        if weight_field:
            try:
                weight = float(weight_field)
            except ValueError:
                raise SystemExit(f"{path.name}:{lineno}: weight must be a number, got {weight_field!r}")
            if weight <= 0:
                raise SystemExit(f"{path.name}:{lineno}: weight must be positive, got {weight}")
        else:
            weight = 1.0

        entry = {
            "text": text.lower(),
            "pos": sorted(pos),
            "tier": tier,
            "points": pts,
            "tags": [t for t in tags_field.split("|") if t],
            "semantics": sorted(semantics),
        }
        # Only emit a weight when it isn't the default, matching WordEntry's
        # encoder so the compiled JSON stays readable.
        if weight != 1.0:
            entry["weight"] = weight
        entries.append(entry)
    return entries


def validate(entries: list[dict]) -> list[str]:
    problems: list[str] = []
    total = len(entries)
    if total == 0:
        return ["pool is empty"]

    # Duplicates
    dupes = [w for w, n in Counter(e["text"] for e in entries).items() if n > 1]
    if dupes:
        problems.append(f"duplicate words: {sorted(dupes)}")

    # Tier mix
    tier_counts = Counter(e["tier"] for e in entries)
    for tier, target in TIER_TARGET.items():
        share = tier_counts[tier] / total
        if abs(share - target) > TIER_TOLERANCE:
            problems.append(
                f"tier {tier} share {share:.0%} is outside target {target:.0%} "
                f"±{TIER_TOLERANCE:.0%} ({tier_counts[tier]}/{total})"
            )

    # Points match tier
    for e in entries:
        lo, hi = TIER_POINTS[e["tier"]]
        if not lo <= e["points"] <= hi:
            problems.append(f"{e['text']}: {e['points']} pts outside {e['tier']} range {lo}-{hi}")

    # POS coverage
    for pos, quota in POS_QUOTA.items():
        share = sum(1 for e in entries if pos in e["pos"]) / total
        if share < quota:
            problems.append(f"{pos}-capable share {share:.0%} below quota {quota:.0%}")

    glue = sum(1 for e in entries if {"ART", "PRON", "CONJ", "PREP"} & set(e["pos"])) / total
    if glue < GLUE_QUOTA:
        problems.append(f"glue-word share {glue:.0%} below quota {GLUE_QUOTA:.0%}")

    # Every tier needs sentence-capable words so high-tier spins aren't dead ends
    for tier in VALID_TIERS:
        in_tier = [e for e in entries if e["tier"] == tier]
        if not in_tier:
            problems.append(f"tier {tier} has no words")
            continue
        if not any("NOUN" in e["pos"] for e in in_tier):
            problems.append(f"tier {tier} has no noun-capable words")
        if not any("VERB" in e["pos"] for e in in_tier) and tier != "legendary":
            problems.append(f"tier {tier} has no verb-capable words")

    # Story mode needs designated ending words
    if not any("ending" in e["tags"] for e in entries):
        problems.append("no words tagged 'ending' — Story Mode chapter close has no target")

    # Semantic coherence (GAME_LOGIC.md §5.1) needs at least some tagged nouns
    # AND verbs on each side to ever produce a bonus. Not required to be
    # comprehensive — the mechanic is additive and safe when sparse — but a
    # pool with zero tagging on one side makes the whole feature permanently
    # inert, which is worth a loud warning rather than a silent no-op.
    tagged_nouns = sum(1 for e in entries if "NOUN" in e["pos"] and e["semantics"])
    tagged_verbs = sum(1 for e in entries if "VERB" in e["pos"] and e["semantics"])
    if tagged_nouns == 0 or tagged_verbs == 0:
        problems.append(
            f"semantic coherence has no signal to work with: {tagged_nouns} tagged nouns, "
            f"{tagged_verbs} tagged verbs — the 'Makes Sense' bonus can never fire"
        )

    return problems


def summarize(entries: list[dict]) -> str:
    total = len(entries)
    tiers = Counter(e["tier"] for e in entries)
    pos = Counter(p for e in entries for p in e["pos"])
    lines = [f"{total} words"]
    lines.append(
        "  tiers: " + ", ".join(f"{t} {tiers[t]} ({tiers[t]/total:.0%})" for t in
                                ["common", "uncommon", "rare", "legendary"])
    )
    lines.append("  pos:   " + ", ".join(f"{p} {n}" for p, n in sorted(pos.items())))
    tags = Counter(t for e in entries for t in e["tags"])
    if tags:
        lines.append("  tags:  " + ", ".join(f"{t} {n}" for t, n in sorted(tags.items())))
    semantics = Counter(s for e in entries for s in e["semantics"])
    if semantics:
        tagged = sum(1 for e in entries if e["semantics"])
        lines.append(
            f"  semantics: {tagged} words tagged ("
            + ", ".join(f"{s} {n}" for s, n in sorted(semantics.items())) + ")"
        )
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check-only", action="store_true", help="validate without writing JSON")
    args = ap.parse_args()

    csvs = sorted(CONTENT_DIR.glob("*.csv"))
    if not csvs:
        print(f"no CSV pools found in {CONTENT_DIR}", file=sys.stderr)
        return 1

    failed = False
    for csv_path in csvs:
        entries = parse_csv(csv_path)
        print(f"\n{csv_path.name}: {summarize(entries)}")

        problems = validate(entries)
        if problems:
            failed = True
            print(f"  VALIDATION FAILED ({len(problems)}):", file=sys.stderr)
            for p in problems:
                print(f"    - {p}", file=sys.stderr)
        else:
            print("  validation passed")

        if not args.check_only and not problems:
            OUT_DIR.mkdir(parents=True, exist_ok=True)
            out = OUT_DIR / (csv_path.stem + ".json")
            payload = {"id": csv_path.stem, "words": entries}
            out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            print(f"  wrote {out.relative_to(ROOT)}")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
