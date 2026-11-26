"""Writes Assets/Student/Scenarios/K04_KingdomsGarden.asset: one variant per source run (the common garden's evolved group).

Usage: python3 Tools/Evolution/make_garden_scenario.py RUN_FOLDER ...     (the source runs, e.g. the K03 cap20 runs)
Every variant sets the gene's source run on both armies; the scenario sets the garden rules (3 x 10 soldiers per army,
floor 0, cap 60, 3000 ticks, seeds 1-3) and the K03 settings the source runs used (maturity 50, kill chance 0.25).
"""

import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCENARIO = ROOT / "Assets/Student/Scenarios"


def entries(items, indent):
    return "".join(f"{indent}- path: {sp}/{p}\n{indent}  value: {v}\n" for sp in ("red", "blue") for p, v in items)


def main():
    runs = sorted(Path(r).resolve() for r in sys.argv[1:])
    if not runs:
        sys.exit(__doc__)
    head = (SCENARIO / "K03_KingdomsNeural.asset").read_text().split("  title:")[0].replace("K03_KingdomsNeural", "K04_KingdomsGarden")
    rules = [("MatingRule/maturity", 50), ("Diet/killChance", 0.25), ("Species/initialPopulation", 30), ("FloorRule/floor", 0), ("CapRule/cap", 60)]
    out = head + "  title: K04 Kingdoms garden\n  scene: Assets/Student/Scenes/KingdomsGarden.unity\n  set:\n" + entries(rules, "  ") + "  variants:\n"
    for r in runs:
        rel = r.relative_to(ROOT)
        out += f"  - name: src-{r.name.split('-', 1)[1]}\n    brain: \n    tier: T2\n    set:\n"
        out += entries([("Brain/GardenNeuralGenomeGene/sourceRun", rel)], "    ") + "    remove: []\n"
    out += "  seeds: " + "".join(struct.pack("<i", n).hex() for n in (1, 2, 3)) + "\n  ticks: 3000\n  brain: \n  expect:\n  - invariants\n  tier: T2\n"
    (SCENARIO / "K04_KingdomsGarden.asset").write_text(out)
    print(f"{len(runs)} variants written")


if __name__ == "__main__":
    main()
