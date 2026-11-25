#!/usr/bin/env bash
# run_night.sh - runs every (variant, seed) of a Student scenario asset, one Unity -batchmode launch each (macOS).
#   Tools/Evolution/run_night.sh K02_KingdomsSelection [--stop HH:MM]          # default stop 07:45 (next occurrence)
#   Tools/Evolution/run_night.sh K02_KingdomsSelection --only full 1 [--ticks 100]   # a single run (smoke test)
# Seed-major order (s1: every variant, then s2 ...). No new run starts after the stop time. Before each run both servers must
# answer (JEV :8000, Ollama :11434; each retry first tries to reconnect the tunnel with evosim-connect.sh -b, every 2 min
# for 10 min, else the run is skipped and logged). A run that stops on a brain failure is repeated once from scratch.
# Output: Logs/EvoSim/night-<date>/ with one log per run, night.log and throughput.csv.
set -uo pipefail
[ -n "${NIGHT_CAFFEINATED:-}" ] || exec env NIGHT_CAFFEINATED=1 caffeinate -dims "$0" "$@"

ASSET=${1:?usage: run_night.sh ASSET [--stop HH:MM] [--only VARIANT SEED] [--ticks N]}; shift
STOP=07:45; ONLY_V=""; ONLY_S=""; TICKS=""
while [ $# -gt 0 ]; do
    case $1 in
        --stop) STOP=$2; shift 2 ;;
        --only) ONLY_V=$2; ONLY_S=$3; shift 3 ;;
        --ticks) TICKS=$2; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
cd "$(dirname "$0")/../.."
UNITY=${UNITY:-/Applications/Unity/Hub/Editor/6000.3.9f1/Unity.app/Contents/MacOS/Unity}
DIR=Logs/EvoSim/night-$(date +%Y%m%d); mkdir -p "$DIR"
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$DIR/night.log"; }

# stop time: the next HH:MM from now
STOP_AT=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) $STOP:00" +%s)
[ "$STOP_AT" -gt "$(date +%s)" ] || STOP_AT=$((STOP_AT + 86400))

servers_ok() {
    curl -fsS --max-time 5 http://localhost:8000/v1/models 2> /dev/null | grep -qF jev-decision &&
    curl -fsS --max-time 5 http://localhost:11434/api/tags 2> /dev/null | grep -qF '"gemma4:26b"'
}

reconnect() { Tools/EvoSimServers/evosim-connect.sh -b < /dev/null >> "$DIR/night.log" 2>&1; }

# the (variant, seed) pairs, seed-major
ASSET_FILE=Assets/Student/Scenarios/$ASSET.asset
if [ -n "$ONLY_V" ]; then PAIRS="$ONLY_S $ONLY_V"; else
PAIRS=$(python3 -I - "$ASSET_FILE" <<'PY'
import re, struct, sys
t = open(sys.argv[1]).read()
variants = re.findall(r"^  - name: (\S+)", t, re.M)
h = re.search(r"^  seeds: ([0-9a-f]*)", t, re.M).group(1)
for s in struct.unpack("<%di" % (len(h) // 8), bytes.fromhex(h)):
    for v in variants: print(s, v)
PY
)
fi

say "night start: $ASSET, stop at $STOP"
echo "$PAIRS" | while read -r seed variant; do
    [ "$(date +%s)" -lt "$STOP_AT" ] || { say "stop time reached; no run $variant s$seed"; continue; }
    waited=0
    until servers_ok; do
        [ $waited -lt 600 ] || break
        say "servers not answering before $variant s$seed; reconnecting tunnel, retry in 2 min"; reconnect; sleep 120; waited=$((waited + 120))
    done
    servers_ok || { say "SKIPPED $variant s$seed: servers down"; continue; }
    log=$DIR/$variant-s$seed.log
    for attempt in 1 2; do
        say "run $variant s$seed (attempt $attempt)"
        "$UNITY" -batchmode -nographics -projectPath . -executeMethod KingdomsBatch.RunCommandLine -asset "$ASSET" \
            -variant "$variant" -seed "$seed" ${TICKS:+-ticks "$TICKS"} -logFile "$log"
        say "  exit $? ($variant s$seed)"
        grep -q "stopped: brain failure" "$log" || break
        say "  brain failure in $variant s$seed; reconnecting and repeating"
        reconnect; sleep 30
        servers_ok || break
    done
done
say "night end"

python3 -I - "$DIR" <<'PY'
import csv, glob, os, re, sys
d = sys.argv[1]
rows = []
for log in sorted(glob.glob(d + "/*-s*.log")):
    m = None
    for line in open(log, errors="replace"):
        m = re.search(r"EvoSim scenario: \S+ (\S+) seed (\d+) \(\w+\): (\d+) ticks.*?, ([\d.]+) s, model calls (\d+) decisions \+ (\d+) mutations.*folder (.+)$", line) or m
    if not m:
        continue
    v, seed, ticks, secs, dec, mut, folder = m.groups()
    pops = {}
    with open(os.path.join(folder.strip(), "stats.csv"), newline="") as f:
        for r in csv.DictReader(f):
            for k, x in r.items():
                if k.endswith("_pop") and x: pops.setdefault(k[:-4], []).append(int(x))
    row = {"variant": v, "seed": seed, "ticks": ticks, "wall_s": secs, "decision_calls": dec, "mutation_calls": mut}
    for sp, p in sorted(pops.items()): row["mean_pop_" + sp] = round(sum(p) / len(p), 1)
    row["s_per_1000_ticks"] = round(float(secs) / int(ticks) * 1000, 1)
    rows.append(row)
cols = list(dict.fromkeys(k for r in rows for k in r))
with open(d + "/throughput.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols); w.writeheader(); w.writerows(rows)
print("wrote", d + "/throughput.csv", len(rows), "runs")
PY
