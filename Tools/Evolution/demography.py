"""Demography of Kingdoms runs: do BOTH species sustain themselves through births?

Usage, from anywhere (paths are relative to the repo root):
    python3 Tools/Evolution/demography.py                      # every Logs/EvoSim/runs/K01_KingdomsDemography-*
    python3 Tools/Evolution/demography.py RUN_FOLDER ... [--warmup 500]

Per run and species (events.jsonl, stats.csv, summary.json, run_info.json), then per variant across seeds, a markdown
table with PASS/FAIL, and Logs/EvoSim/demography-<timestamp>.csv (one row per run and species).
Births and immigrants count from the warm-up tick on; the other measures cover the whole run.
"""

import argparse
import csv
import json
import re
import statistics
import time
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNS = ROOT / "Logs/EvoSim/runs"
DEFAULT_MATURITY, DEFAULT_FLOOR, DEFAULT_CAP = 150, 3, 15


def setting(info, species, tail, default):
    """A setting of one species: the scenario's override if there is one, else the scene's value from the run's settings."""
    for table in (info.get("overrides") or {}, info.get("settings") or {}):
        for path, value in table.items():
            if path.lower().startswith(species + "/") and path.endswith(tail):
                return float(value)
    return default


def analyse(run, warmup):
    """One row per species for a run folder, or [] when the run has no summary."""
    if not (run / "summary.json").exists():
        return []
    info = json.loads((run / "run_info.json").read_text())
    summary = json.loads((run / "summary.json").read_text())
    m = re.match(r".*?-(.+)-s(\d+)-\d{8}-\d{6}$", run.name)
    variant = info.get("variant") or (m.group(1) if m else run.name)
    seed = summary.get("seed", int(m.group(2)) if m else 0)

    events = [json.loads(line) for line in open(run / "events.jsonl")]
    species_of = {e["id"]: e["species"] for e in events if "species" in e and e["kind"] in ("founder", "immigrant", "birth")}
    with open(run / "stats.csv", newline="") as f:
        stats = list(csv.DictReader(f))

    kills = defaultdict(int)
    for e in events:
        if e["kind"] == "death" and "killer" in e:
            kills[species_of.get(e["killer"])] += 1

    rows = []
    for sp in sorted(summary["species"]):
        mine = [e for e in events if e.get("species") == sp]
        births = [e for e in mine if e["kind"] == "birth" and e["t"] >= warmup]
        immigrants = [e for e in mine if e["kind"] == "immigrant" and e["t"] >= warmup]
        deaths = [e for e in mine if e["kind"] == "death"]
        maturity = setting(info, sp, "MatingRule/maturity", DEFAULT_MATURITY)
        floor = setting(info, sp, "FloorRule/floor", DEFAULT_FLOOR)
        cap = setting(info, sp, "CapRule/cap", DEFAULT_CAP)
        ticks = summary.get("ticks", 0)
        windows = [(a, a + 500) for a in range(warmup, ticks - 499, 500)]    # whole 500-tick windows after t0
        self_sustaining = (sum(not any(a <= e["t"] < b for e in immigrants) for a, b in windows) / len(windows)) if windows else float("nan")
        pops = [int(r[sp + "_pop"]) for r in stats if r.get(sp + "_pop")]
        row = {
            "variant": variant, "seed": seed, "species": sp,
            "births": len(births), "immigrants": len(immigrants),
            "born_share": len(births) / max(1, len(births) + len(immigrants)),
            "self_sustaining": self_sustaining,
            "minutes": summary.get("minutes", float("nan")),
            "birth_ratio": len(births) / max(1, len(immigrants)),
            "max_gen": max([e["gen"] for e in mine if e["kind"] == "birth"], default=0),
            "adult_death_share": sum(d["age"] >= maturity for d in deaths) / len(deaths) if deaths else 0.0,
            "median_age_at_death": statistics.median(d["age"] for d in deaths) if deaths else 0.0,
            "kills": kills[sp],
            "at_floor": sum(p <= floor for p in pops) / len(pops) if pops else 0.0,
            "at_cap": sum(p >= cap for p in pops) / len(pops) if pops else 0.0,
        }
        for action, share in summary["species"][sp].get("action_share", {}).items():
            row["act_" + action] = share
        rows.append(row)
    for row in rows:                                   # red/blue: the other species' kills; inf when it made none
        other = sum(r["kills"] for r in rows if r is not row)
        row["kill_ratio"] = row["kills"] / other if other else (float("inf") if row["kills"] else float("nan"))
    return rows


def fmt(values, digits=1):
    """mean (min-max) of numbers."""
    return f"{statistics.mean(values):.{digits}f} ({min(values):.{digits}f}-{max(values):.{digits}f})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="*", help="run folders (default: Logs/EvoSim/runs/K01_KingdomsDemography-*)")
    ap.add_argument("--warmup", type=int, default=500, help="t0: births and immigrants count from this tick (default 500)")
    args = ap.parse_args()

    folders = [Path(r) for r in args.runs] or sorted(RUNS.glob("K01_KingdomsDemography-*"))
    rows = [row for folder in folders for row in analyse(folder, args.warmup)]
    if not rows:
        print("no finished run found")
        return

    variants = list(dict.fromkeys(r["variant"] for r in rows))
    species = sorted({r["species"] for r in rows})
    first_sp = "red" if "red" in species else species[0]
    by = lambda v, sp=None: [r for r in rows if r["variant"] == v and (sp is None or r["species"] == sp)]

    print(f"Warm-up t0 = {args.warmup}. Cells are mean (min-max) over seeds.\n")
    print("| variant | species | seeds | births | immigrants | births/imm | max gen | adult deaths | median age at death | kills | at floor | at cap |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for v in variants:
        for sp in species:
            g = by(v, sp)
            print(f"| {v} | {sp} | {len(g)} | {fmt([r['births'] for r in g])} | {fmt([r['immigrants'] for r in g])} | "
                  f"{fmt([r['birth_ratio'] for r in g], 2)} | {fmt([r['max_gen'] for r in g], 0)} | "
                  f"{fmt([r['adult_death_share'] for r in g], 2)} | {fmt([r['median_age_at_death'] for r in g], 0)} | "
                  f"{fmt([r['kills'] for r in g], 0)} | {fmt([r['at_floor'] for r in g], 2)} | {fmt([r['at_cap'] for r in g], 2)} |")

    print("\nBorn share = births / (births + immigrants) after t0; self-sustaining = share of whole 500-tick windows after t0 with no immigrant; wall minutes per run.\n")
    print("| variant | species | born share mean (min over seeds) | self-sustaining mean (min) | kill ratio per seed | min |")
    print("|---|---|---|---|---|---|")
    for v in variants:
        for sp in species:
            g = by(v, sp)
            bs, ss = [r["born_share"] for r in g], [r["self_sustaining"] for r in g]
            kr = ", ".join(f"s{r['seed']}:{r['kill_ratio']:.2f}" for r in by(v, first_sp) ) if sp == first_sp else ""
            print(f"| {v} | {sp} | {statistics.mean(bs):.2f} ({min(bs):.2f}) | {statistics.mean(ss):.2f} ({min(ss):.2f}) | {kr} | {statistics.mean(r['minutes'] for r in g):.1f} |")

    actions = sorted({k for r in rows for k in r if k.startswith("act_")})
    print("\nAction shares (mean over seeds):\n")
    print("| variant | species | " + " | ".join(a[4:] for a in actions) + " |")
    print("|---|---|" + "---|" * len(actions))
    for v in variants:
        for sp in species:
            g = by(v, sp)
            print(f"| {v} | {sp} | " + " | ".join(f"{statistics.mean(r.get(a, 0) for r in g):.2f}" for a in actions) + " |")

    print("\n| variant | (1) births > immigrants, every seed, both | (2) max gen >= 10, every seed, both | (3) mean kill ratio red/blue in 0.67-1.5 | kill ratio range over seeds | result |")
    print("|---|---|---|---|---|---|")
    first = "red" if "red" in species else species[0]
    for v in variants:
        c1 = all(r["births"] > r["immigrants"] for r in by(v))
        c2 = all(r["max_gen"] >= 10 for r in by(v))
        ratios = [r["kill_ratio"] for r in by(v, first)]
        mean_ratio = statistics.mean(ratios)
        c3 = 0.67 <= mean_ratio <= 1.5
        flag = lambda ok: "PASS" if ok else "FAIL"
        print(f"| {v} | {flag(c1)} | {flag(c2)} | {flag(c3)} ({first}/other {mean_ratio:.2f}) | {min(ratios):.2f}-{max(ratios):.2f} | **{flag(c1 and c2 and c3)}** |")

    out = ROOT / "Logs/EvoSim" / time.strftime("demography-%Y%m%d-%H%M%S.csv")
    columns = list(dict.fromkeys(k for r in rows for k in r))
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=columns)
        w.writeheader()
        w.writerows(rows)
    print(f"\nwritten: {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
