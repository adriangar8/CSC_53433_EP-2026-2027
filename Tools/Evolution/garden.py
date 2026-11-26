"""Common garden (G4) of K04 runs: do evolved networks outlive and out-breed founder networks, beyond what mutation alone does?

Usage, from anywhere (paths are relative to the repo root):
    python3 Tools/Evolution/garden.py RUN_FOLDER ...        # K04_KingdomsGarden-* runs (variant = one source run)

The initial cohort of every army is split by the origin label of its founder allele (alleles.jsonl: evolved, founder,
drifted). Per run and army, by origin: deaths (migrations and the run's end censor), soldier-ticks at risk, death rate and
lifetime offspring per initial soldier (children named as a parent in events.jsonl); the share of the living soldiers' ancestry
at the end that comes from each origin (each baby inherits the mean of its two parents' ancestry; the largest is the winner).
Rate ratio evolved/founder and drifted/founder with a 95 % interval from the log rate ratio, SE = sqrt(1/d1 + 1/d2), pooled
over the seeds and both armies of each variant (one source run) and over everything. Writes
Logs/EvoSim/garden-<timestamp>.csv (per run and army) and, with matplotlib, a pooled Kaplan-Meier plot by origin.
"""

import argparse
import csv
import json
import math
import time
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ORIGINS = ["evolved", "founder", "drifted"]


def analyse(run):
    """(variant, seed, rows per army, lives per origin) of one garden run; lives are (time, died) pairs for Kaplan-Meier."""
    info = json.loads((run / "run_info.json").read_text())
    variant, seed = info.get("variant", run.name), info.get("seed", 0)
    origin_of = {}
    for line in open(run / "alleles.jsonl"):
        a = json.loads(line)
        origin_of[a["id"]] = a.get("origin")
    events = [json.loads(line) for line in open(run / "events.jsonl")]
    end = max((e["t"] for e in events), default=0)
    stats_end = 0
    with open(run / "stats.csv", newline="") as f:
        for r in csv.DictReader(f):
            stats_end = max(stats_end, int(r["t"]))
    end = max(end, stats_end)
    joined = {e["id"]: e for e in events if e["kind"] in ("founder", "immigrant", "birth")}
    gone = {e["id"]: e for e in events if e["kind"] == "death"}
    children = defaultdict(int)
    for e in events:
        if e["kind"] == "birth":
            for p in e.get("parents", []):
                children[p] += 1

    ancestry = {}                                                    # animal -> {origin: share}
    for i, e in sorted(joined.items(), key=lambda kv: (kv[1]["t"], kv[0])):
        if e["kind"] == "birth":
            parents = [ancestry[p] for p in e.get("parents", []) if p in ancestry]
            mix = defaultdict(float)
            for par in parents:
                for o, s in par.items():
                    mix[o] += s / len(parents)
            ancestry[i] = dict(mix)
        else:
            ancestry[i] = {origin_of.get(e["genome"][0], "?"): 1.0}

    rows, lives = [], defaultdict(list)
    for sp in sorted({e["species"] for e in joined.values()}):
        cohort = [e for e in joined.values() if e["species"] == sp and e["kind"] == "founder"]
        alive = [i for i, e in joined.items() if e["species"] == sp and i not in gone]
        for o in ORIGINS:
            mine = [e for e in cohort if origin_of.get(e["genome"][0]) == o]
            deaths = ticks = offspring = 0
            for e in mine:
                d = gone.get(e["id"])
                died = d is not None and d.get("cause") != "migrated"
                stop = d["t"] if d is not None else end
                ticks += stop - e["t"]
                deaths += died
                offspring += children[e["id"]]
                lives[o].append((stop - e["t"], died))
            share = sum(ancestry[i].get(o, 0.0) for i in alive) / len(alive) if alive else float("nan")
            rows.append({"variant": variant, "seed": seed, "army": sp, "origin": o, "cohort": len(mine), "deaths": deaths,
                         "soldier_ticks": ticks, "death_rate": deaths / ticks if ticks else float("nan"),
                         "offspring_per_soldier": offspring / len(mine) if mine else float("nan"), "ancestry_share_end": share,
                         "living_end": len(alive)})
    return variant, seed, rows, lives


def rate_ratio(rows, a, b):
    """(ratio, low, high) of the death rate of origin a over origin b in rows, or None without deaths."""
    da = sum(r["deaths"] for r in rows if r["origin"] == a)
    db = sum(r["deaths"] for r in rows if r["origin"] == b)
    ta = sum(r["soldier_ticks"] for r in rows if r["origin"] == a)
    tb = sum(r["soldier_ticks"] for r in rows if r["origin"] == b)
    if min(da, db, ta, tb) <= 0:
        return None
    rr = (da / ta) / (db / tb)
    se = math.sqrt(1 / da + 1 / db)
    return rr, rr * math.exp(-1.96 * se), rr * math.exp(1.96 * se)


def kaplan_meier(lives):
    """[(time, survival)] steps of a list of (time, died)."""
    at_risk, s, steps = len(lives), 1.0, [(0, 1.0)]
    for t in sorted({t for t, d in lives if d}):
        deaths = sum(1 for tt, d in lives if tt == t and d)
        s *= 1 - deaths / sum(1 for tt, _ in lives if tt >= t)
        steps.append((t, s))
    return steps


def fmt(x):
    return "n/a" if x is None else f"{x[0]:.2f} ({x[1]:.2f}-{x[2]:.2f})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="*", help="garden run folders (default: Logs/EvoSim/runs/K04_KingdomsGarden-*)")
    args = ap.parse_args()
    folders = [Path(r) for r in args.runs] or sorted((ROOT / "Logs/EvoSim/runs").glob("K04_KingdomsGarden-*"))
    rows, by_variant, lives_all = [], defaultdict(list), defaultdict(list)
    for f in folders:
        if not (f / "events.jsonl").exists() or not (f / "alleles.jsonl").exists():
            continue
        variant, seed, rs, lives = analyse(f)
        rows += rs
        by_variant[variant] += rs
        for o, l in lives.items():
            lives_all[o] += l
    if not rows:
        print("no garden run found")
        return

    print("Death-rate ratio (95 % CI), pooled over the seeds and both armies of each source run. Offspring: per initial soldier.\n")
    print("| source run | cohort e/f/d | offspring e/f/d | evolved/founder | drifted/founder | ancestry at end e/f/d |")
    print("|---|---|---|---|---|---|")
    wins = {"evolved": 0, "drifted": 0}
    for v, rs in by_variant.items():
        agg = lambda o, k: sum(r[k] for r in rs if r["origin"] == o)
        mean_off = lambda o: sum(r["offspring_per_soldier"] * r["cohort"] for r in rs if r["origin"] == o) / max(1, agg(o, "cohort"))
        share = lambda o: sum(r["ancestry_share_end"] for r in rs if r["origin"] == o and r["ancestry_share_end"] == r["ancestry_share_end"]) / max(1, sum(1 for r in rs if r["origin"] == o and r["ancestry_share_end"] == r["ancestry_share_end"]))
        ef, df = rate_ratio(rs, "evolved", "founder"), rate_ratio(rs, "drifted", "founder")
        for key, x in (("evolved", ef), ("drifted", df)):
            wins[key] += x is not None and x[2] < 1
        print(f"| {v} | {'/'.join(str(agg(o, 'cohort')) for o in ORIGINS)} | {'/'.join(f'{mean_off(o):.2f}' for o in ORIGINS)} | "
              f"{fmt(ef)} | {fmt(df)} | {'/'.join(f'{share(o):.2f}' for o in ORIGINS)} |")
    allr = [r for rs in by_variant.values() for r in rs]
    print(f"\nAll source runs pooled: evolved/founder {fmt(rate_ratio(allr, 'evolved', 'founder'))}, "
          f"drifted/founder {fmt(rate_ratio(allr, 'drifted', 'founder'))}, evolved/drifted {fmt(rate_ratio(allr, 'evolved', 'drifted'))}")
    print(f"Source runs where the CI is entirely below 1 (lower death rate than founders): evolved {wins['evolved']} of {len(by_variant)}, "
          f"drifted {wins['drifted']} of {len(by_variant)}")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    out = ROOT / "Logs/EvoSim" / f"garden-{stamp}.csv"
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print(f"\nwritten: {out.relative_to(ROOT)}")
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib is not importable here: no Kaplan-Meier plot (pip install matplotlib)")
        return
    fig, ax = plt.subplots(figsize=(7, 4.5))
    for k, o in enumerate(ORIGINS):
        steps = kaplan_meier(lives_all[o])
        ax.step([t for t, _ in steps], [s for _, s in steps], where="post", color=f"C{k}", label=f"{o} (n={len(lives_all[o])})")
    ax.set_xlabel("ticks since release")
    ax.set_ylabel("survival")
    ax.set_title("Kaplan-Meier by origin, all garden runs pooled")
    ax.legend()
    fig.tight_layout()
    png = ROOT / "Logs/EvoSim/plots" / f"garden-km-{stamp}.png"
    png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(png, dpi=110)
    print(f"plot: {png.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
