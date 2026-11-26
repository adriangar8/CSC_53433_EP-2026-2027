"""Learning trends of neural Kingdoms runs: per army and 1000-tick window, does the population change over time?

Usage, from anywhere (paths are relative to the repo root):
    python3 Tools/Evolution/neural_trends.py RUN_FOLDER ... [--window 1000] [--role winner|loser|all] [--no-plots]

Per run (events.jsonl, stats.csv, run_info.json) and army (species), per window:
  pop (soldier-ticks / window), mean_gen, born_share (share of the living that were born, not founders or immigrants,
  sampled every 100 ticks), stop_share, speed, meals_per_tick (from stats.csv), kills_per_capita and starve_hazard (both
  per soldier per window), births_per_soldier.
Each army is a `winner` (the higher mean generation in the run's last window; red on a tie) or a `loser`.
Writes Logs/EvoSim/trends-<timestamp>.csv (one row per run x army x window, all roles, with the role), one PNG per metric
under Logs/EvoSim/plots/ (mean line and min-max band over the runs of --role, default winner; one colour per variant; needs
matplotlib, else only the CSV), and prints, per variant, the first and last window mean of each metric for that role and in
how many runs both armies reached max gen >= 10.
"""

import argparse
import csv
import json
import statistics
import time
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
METRICS = ["pop", "mean_gen", "born_share", "stop_share", "speed", "meals_per_tick",
           "kills_per_capita", "starve_hazard", "births_per_soldier"]


def analyse(run, window):
    """Rows (one per army and window) and {army: max generation} of one run folder, or None when it has no stats."""
    info = json.loads((run / "run_info.json").read_text())
    variant, seed = info.get("variant", run.name), info.get("seed", 0)
    events = [json.loads(line) for line in open(run / "events.jsonl")]
    with open(run / "stats.csv", newline="") as f:
        stats = list(csv.DictReader(f))
    if not stats:
        return None
    ticks = max(int(r["t"]) for r in stats)
    armies = sorted({c[:-4] for c in stats[0] if c.endswith("_pop")})
    species_of = {e["id"]: e["species"] for e in events if "species" in e and e["kind"] in ("founder", "immigrant", "birth")}
    n_windows = ticks // window
    rows, max_gen = [], {}
    for sp in armies:
        join = {e["id"]: (e["t"], e["kind"]) for e in events if e.get("species") == sp and e["kind"] in ("founder", "immigrant", "birth")}
        leave = {e["id"]: e["t"] for e in events if e.get("species") == sp and e["kind"] == "death"}
        max_gen[sp] = max([e["gen"] for e in events if e.get("species") == sp and e["kind"] == "birth"], default=0)
        alive = [0] * (ticks + 2)                                    # soldiers alive at each tick
        born_alive = [0] * (ticks + 2)
        for i, (t, kind) in join.items():
            end = min(leave.get(i, ticks + 1), ticks + 1)
            for arr in ((alive, born_alive) if kind == "birth" else (alive,)):
                arr[min(t, ticks + 1)] += 1
                arr[end] -= 1
        for arr in (alive, born_alive):
            for t in range(1, len(arr)):
                arr[t] += arr[t - 1]
        for w in range(n_windows):
            a, b = w * window, (w + 1) * window
            at_risk = sum(alive[a:b])                                # soldier-ticks
            samples = range(a, b, 100)
            alive_s = sum(alive[t] for t in samples)
            born_s = sum(born_alive[t] for t in samples)
            inw = lambda t: a <= t < b
            births = sum(1 for i, (t, k) in join.items() if k == "birth" and inw(t))
            starved = sum(1 for e in events if e["kind"] == "death" and e.get("species") == sp and e.get("cause") == "starvation" and inw(e["t"]))
            kills = sum(1 for e in events if e["kind"] == "death" and "killer" in e and species_of.get(e["killer"]) == sp and inw(e["t"]))
            srows = [r for r in stats if a < int(r["t"]) <= b]
            col = lambda name: statistics.mean(float(r[sp + name]) for r in srows if r.get(sp + name)) if srows else float("nan")
            per_soldier = at_risk / window                           # mean number of soldiers in the window
            rows.append({
                "variant": variant, "seed": seed, "army": sp, "run": run.name, "window_start": a,
                "pop": per_soldier, "mean_gen": col("_mean_gen"),
                "born_share": born_s / alive_s if alive_s else float("nan"),
                "stop_share": col("_nn_share_stop"), "speed": col("_nn_speed"), "meals_per_tick": col("_nn_meals_per_tick"),
                "kills_per_capita": kills / per_soldier if per_soldier else float("nan"),
                "starve_hazard": starved / per_soldier if per_soldier else float("nan"),
                "births_per_soldier": births / per_soldier if per_soldier else float("nan"),
            })
    last = max(r["window_start"] for r in rows)
    final = {r["army"]: r["mean_gen"] for r in rows if r["window_start"] == last}
    top = max(sorted(final), key=lambda a: final[a])                 # sorted: the first army wins a tie
    for r in rows:
        r["role"] = "winner" if r["army"] == top else "loser"
    return variant, seed, rows, max_gen


def plot(rows, out_dir, stamp, role):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib is not importable here: CSV only (pip install matplotlib for the plots)")
        return []
    out_dir.mkdir(parents=True, exist_ok=True)
    variants = list(dict.fromkeys(r["variant"] for r in rows))
    written = []
    for m in METRICS:
        fig, ax = plt.subplots(figsize=(8, 4.5))
        for k, v in enumerate(variants):
            by_t = defaultdict(list)
            for r in rows:
                if r["variant"] == v and r[m] == r[m]:
                    by_t[r["window_start"]].append(r[m])
            xs = sorted(by_t)
            if not xs:
                continue
            colour = f"C{k}"
            ax.plot(xs, [statistics.mean(by_t[x]) for x in xs], color=colour, label=v)
            ax.fill_between(xs, [min(by_t[x]) for x in xs], [max(by_t[x]) for x in xs], color=colour, alpha=0.15)
        ax.set_xlabel("tick")
        ax.set_ylabel(m)
        ax.set_title(f"{m}: mean and min-max over runs ({role})")
        ax.legend()
        fig.tight_layout()
        path = out_dir / f"{stamp}-{role}-{m}.png"
        fig.savefig(path, dpi=110)
        plt.close(fig)
        written.append(path)
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+", help="run folders")
    ap.add_argument("--window", type=int, default=1000)
    ap.add_argument("--role", choices=["winner", "loser", "all"], default="winner", help="armies in the table and plots (default winner)")
    ap.add_argument("--no-plots", action="store_true")
    args = ap.parse_args()

    rows, evolved = [], defaultdict(list)
    for r in args.runs:
        got = analyse(Path(r), args.window)
        if got is None:
            continue
        variant, seed, rs, max_gen = got
        rows += rs
        evolved[variant].append(all(g >= 10 for g in max_gen.values()))
    if not rows:
        print("no finished run found")
        return
    all_rows = rows
    stamp = time.strftime("%Y%m%d-%H%M%S")
    out = ROOT / "Logs/EvoSim" / f"trends-{stamp}.csv"
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(all_rows[0]))
        w.writeheader()
        w.writerows(all_rows)

    if args.role != "all":
        rows = [r for r in rows if r["role"] == args.role]
    print(f"Window {args.window} ticks. First and last window, mean over the {args.role} armies of the runs.\n")
    print("| variant | runs | both armies evolved (max gen >= 10) | " + " | ".join(METRICS) + " |")
    print("|---|---|---|" + "---|" * len(METRICS))
    for v in dict.fromkeys(r["variant"] for r in rows):
        g = [r for r in rows if r["variant"] == v]
        first, last = min(r["window_start"] for r in g), max(r["window_start"] for r in g)
        cells = []
        for m in METRICS:
            a = [r[m] for r in g if r["window_start"] == first and r[m] == r[m]]
            b = [r[m] for r in g if r["window_start"] == last and r[m] == r[m]]
            cells.append(f"{statistics.mean(a):.2f} -> {statistics.mean(b):.2f}" if a and b else "n/a")
        print(f"| {v} | {len(evolved[v])} | {sum(evolved[v])} of {len(evolved[v])} | " + " | ".join(cells) + " |")
    print(f"\nwritten: {out.relative_to(ROOT)}")
    if not args.no_plots:
        for p in plot(rows, ROOT / "Logs/EvoSim/plots", stamp, args.role):
            print(f"plot: {p.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
