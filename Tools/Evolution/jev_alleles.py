"""Allele frequencies of the JEV Kingdoms runs (K02): do some instruction sentences take over, or is it drift?

Usage, from anywhere (paths are relative to the repo root):
    python3 Tools/Evolution/jev_alleles.py                      # every finished K02_KingdomsSelection run
    python3 Tools/Evolution/jev_alleles.py RUN_FOLDER ... [--every 100] [--no-plots]

Default runs: the finished (tick limit, at least 5000 ticks) K02 runs, the latest per variant and seed. The cached `full`
seed 1 runs are ignored and `full_nocache` seed 1 stands in for `full` seed 1. For each run, species and locus
(hunt, follow, rest, mate, eat): the share of each allele among the living soldiers every --every ticks, as a stacked-area PNG
under Logs/EvoSim/plots/jev/ (legend: the allele texts, the biggest few; matplotlib needed, else only the table), and a
table of the winning allele at the end of every population (the largest share among the living soldiers at the last tick).
"""

import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNS = ROOT / "Logs/EvoSim/runs"
LEGEND = 6


def default_runs():
    """{(arm, seed): run folder}: the latest finished run of each, with full_nocache s1 as full s1."""
    chosen = {}
    for d in sorted(RUNS.glob("K02_KingdomsSelection-*")):
        m = re.match(r"K02_KingdomsSelection-(.+)-s(\d+)-\d{8}-\d{6}$", d.name)
        if not m or not (d / "summary.json").exists():
            continue
        arm, seed = m.group(1), int(m.group(2))
        summary = json.loads((d / "summary.json").read_text())
        if summary.get("ticks", 0) < 5000 or summary.get("stopped") != "tick limit":
            continue
        if arm == "full" and seed == 1:
            continue
        if arm == "full_nocache":
            arm = "full"
        chosen[(arm, seed)] = d
    return chosen


def analyse(run, every):
    """{(species, locus): (times, {allele: [share per time]})} and {(species, locus): Counter of living alleles at the end}."""
    texts, origins = {}, {}
    for line in open(run / "alleles.jsonl"):
        a = json.loads(line)
        texts[a["id"]], origins[a["id"]] = a.get("text") or a["id"], a.get("origin")
    events = [json.loads(line) for line in open(run / "events.jsonl")]
    end = max(e["t"] for e in events)
    join = {e["id"]: e for e in events if e["kind"] in ("founder", "immigrant", "birth")}
    gone = {e["id"]: e["t"] for e in events if e["kind"] == "death"}
    times = list(range(0, end + 1, every))
    series = defaultdict(lambda: defaultdict(lambda: [0] * len(times)))
    totals = defaultdict(lambda: [0] * len(times))
    final = defaultdict(Counter)
    for i, e in join.items():
        out = gone.get(i, end + 1)
        for allele in e["genome"]:
            locus = allele.split(":")[0]
            key = (e["species"], locus)
            for k, t in enumerate(times):
                if e["t"] <= t < out:
                    series[key][allele][k] += 1
                    totals[key][k] += 1
            if i not in gone:
                final[key][allele] += 1
    shares = {key: (times, {a: [c / n if n else 0 for c, n in zip(counts, totals[key])] for a, counts in alleles.items()})
              for key, alleles in series.items()}
    return shares, final, texts, origins


def plot(path, times, alleles, texts, title):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    order = sorted(alleles, key=lambda a: -max(alleles[a]))
    shown, rest = order[:LEGEND], order[LEGEND:]
    ys = [alleles[a] for a in shown]
    labels = [f"{a.split(':')[1]}: {texts[a][:60]}" for a in shown]
    if rest:
        ys.append([sum(alleles[a][k] for a in rest) for k in range(len(times))])
        labels.append(f"{len(rest)} other alleles")
    fig, ax = plt.subplots(figsize=(9, 4.5))
    ax.stackplot(times, ys, labels=labels)
    ax.set_ylim(0, 1)
    ax.set_xlabel("tick")
    ax.set_ylabel("share of the living soldiers")
    ax.set_title(title)
    ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1), fontsize=7)
    fig.tight_layout()
    fig.savefig(path, dpi=100)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="*", help="run folders (default: the finished K02 runs)")
    ap.add_argument("--every", type=int, default=100, help="ticks between samples (default 100)")
    ap.add_argument("--no-plots", action="store_true")
    args = ap.parse_args()

    if args.runs:
        runs = {}
        for r in map(Path, args.runs):
            m = re.match(r".*?-(.+)-s(\d+)-\d{8}-\d{6}$", r.name)
            runs[(m.group(1), int(m.group(2))) if m else (r.name, 0)] = r
    else:
        runs = default_runs()
    if not runs:
        print("no finished run found")
        return
    can_plot = not args.no_plots
    if can_plot:
        try:
            import matplotlib  # noqa: F401
        except ImportError:
            print("matplotlib is not importable here: table only (pip install matplotlib for the plots)\n")
            can_plot = False
    out_dir = ROOT / "Logs/EvoSim/plots/jev"
    if can_plot:
        out_dir.mkdir(parents=True, exist_ok=True)

    table = defaultdict(list)                                          # arm -> rows
    loci = []
    for (arm, seed), run in sorted(runs.items()):
        shares, final, texts, origins = analyse(run, args.every)
        for (sp, locus), (times, alleles) in sorted(shares.items()):
            name = locus.split(".", 1)[1]
            if name not in loci:
                loci.append(name)
            if can_plot:
                plot(out_dir / f"{arm}-s{seed}-{sp}-{name}.png", times, alleles, texts, f"{arm} s{seed}, {sp} {name}")
        for sp in sorted({k[0] for k in final}):
            row = {}
            for (s2, locus), counts in final.items():
                if s2 != sp or not counts:
                    continue
                allele, n = counts.most_common(1)[0]
                tag = "founder" if origins.get(allele) in ("founder", "neutral", "control") else "new"
                row[locus.split(".", 1)[1]] = f"{texts[allele][:42]} ({n / sum(counts.values()):.2f}, {tag})"
            table[arm].append((seed, sp, row))

    print("Winning allele per locus at the end: text (share of the living soldiers, founder or new).\n")
    for arm, rows in table.items():
        print(f"### {arm}\n")
        print("| seed | army | " + " | ".join(loci) + " |")
        print("|---|---|" + "---|" * len(loci))
        for seed, sp, row in sorted(rows):
            print(f"| {seed} | {sp} | " + " | ".join(row.get(l, "-") for l in loci) + " |")
        print()
    if can_plot:
        print(f"plots: {out_dir.relative_to(ROOT)}/<arm>-s<seed>-<army>-<locus>.png")


if __name__ == "__main__":
    main()
