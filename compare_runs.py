"""Compare EvoSim runs side by side.

Usage, from the Unity project folder:
    python3 compare_runs.py                      # every finished run in Logs/EvoSim/runs, oldest first
    python3 compare_runs.py reference kill-0.8   # only these run folders, in this order
"""

import csv
import json
import sys
from pathlib import Path

RUNS = Path("Logs/EvoSim/runs")


def load(run):
    summary = json.loads((run / "summary.json").read_text())

    with open(run / "stats.csv", newline="") as f:
        rows = list(csv.DictReader(f))

    return summary, rows


def pop_range(rows, species):
    pops = [int(r[f"{species}_pop"]) for r in rows if r.get(f"{species}_pop")]

    if not pops:
        return "-"

    return f"{min(pops)}-{max(pops)}"


def column(summary, rows, species_order):
    out = [
        ("ticks", summary.get("ticks")),
        ("seed", summary.get("seed")),
        ("minutes", summary.get("minutes")),
        ("brain calls", summary.get("llm_calls")),
    ]

    for name in species_order:
        sp = summary["species"].get(name)

        out.append((name.upper(), "" if sp else "absent"))

        if not sp:
            labels = ["start - end", "range (every 100 ticks)", "births", "newcomers", "killed", "starved",
                      "migrated", "kills made", "mean lifespan", "max generation", "top actions"]

            out += [(f"{name}  {label}", "-") for label in labels]

            continue

        deaths = sp.get("deaths", {})

        share = ", ".join(f"{a} {v:.2f}" for a, v in sorted(sp.get("action_share", {}).items(), key=lambda kv: -kv[1])[:3])

        out += [
            (f"{name}  start - end", f"{sp.get('founders')} - {sp.get('pop_final')}"),
            (f"{name}  range (every 100 ticks)", pop_range(rows, name)),
            (f"{name}  births", sp.get("births")),
            (f"{name}  newcomers", sp.get("immigrants")),
            (f"{name}  killed", deaths.get("killed", 0)),
            (f"{name}  starved", deaths.get("starvation", 0)),
            (f"{name}  migrated", deaths.get("migrated", 0)),
            (f"{name}  kills made", sp.get("kills", 0)),
            (f"{name}  mean lifespan", sp.get("mean_lifespan")),
            (f"{name}  max generation", sp.get("max_gen")),
            (f"{name}  top actions", share),
        ]

    return out


def main():
    if len(sys.argv) > 1:
        runs = [RUNS / name for name in sys.argv[1:]]
    else:
        runs = sorted((p for p in RUNS.iterdir() if (p / "summary.json").exists()), key=lambda p: (p / "summary.json").stat().st_mtime)

    runs = [r for r in runs if (r / "summary.json").exists()]

    if not runs:
        print(f"no finished run (with summary.json) in {RUNS}")
        return

    loaded = [(r.name, *load(r)) for r in runs]

    species_order = []

    for _, summary, _ in loaded:
        for name in summary["species"]:
            if name not in species_order:
                species_order.append(name)

    columns = [(name, column(summary, rows, species_order)) for name, summary, rows in loaded]

    labels = [label.split("  ", 1)[1].join(["  ", ""]) if "  " in label else label for label, _ in columns[0][1]]

    width = max(len(label) for label in labels) + 2

    cell = max(len(str(v)) for name, col in columns for v in [name] + [value for _, value in col]) + 3

    print("".ljust(width) + "".join(name.rjust(cell) for name, _ in columns))

    for i, label in enumerate(labels):
        values = [str(col[i][1]) for _, col in columns]

        print(label.ljust(width) + "".join(v.rjust(cell) for v in values))


if __name__ == "__main__":
    main()
