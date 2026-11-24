#!/usr/bin/env bash
# evosim-connect.sh - laptop side of the EvoSim model servers (macOS and Linux; bash 3.2 is enough).
#
#   ./evosim-connect.sh [connect]   connect Unity's localhost:8000 / :11434 to running servers: yours or a
#                                   teammate's. If none is healthy, helps you start or set up your own.
#   ./evosim-connect.sh status      local ports, active tunnel, health of every registry entry
#   ./evosim-connect.sh start       forward to evosim-servers.sh on MY_MACHINE (also: stop, setup)
#   --dry-run                       print what would be run (ssh, curl, lsof) and run nothing
#
# Settings: servers.local.env (copy servers.example.env). Guide: README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CFG="$HERE/servers.local.env"
SERVERS_SH="$HERE/evosim-servers.sh"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
die()  { printf '  FAIL  %s\n' "$*" >&2; exit 1; }
show() { printf '  dry   %s\n' "$*"; }

DRY=0
CMD=""
for a in "$@"; do
    case $a in
        --dry-run) DRY=1 ;;
        -h | --help | help) CMD=help ;;
        *) [ -n "$CMD" ] || CMD=$a ;;
    esac
done
CMD=${CMD:-connect}

if [ "$CMD" = help ]; then
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

# safe VALUE: only characters that cannot break a remote command line
safe() {
    case $1 in
        '' | *[!A-Za-z0-9._:/-]*) return 1 ;;
    esac
}

# ---- settings ---------------------------------------------------------------------------------------------

if [ ! -f "$CFG" ]; then
    die "no servers.local.env: cp servers.example.env servers.local.env, then edit it (see README.md)"
fi
# shellcheck source=/dev/null
. "$CFG"
X_LOGIN="${X_LOGIN:-}"
DOMAIN="${DOMAIN:-polytechnique.fr}"
CANDIDATE_MACHINES="${CANDIDATE_MACHINES:-vendee albatros hibou verdier}"
REGISTRY="${REGISTRY:-}"
MY_MACHINE="${MY_MACHINE:-}"
MUTATOR_MODEL="${MUTATOR_MODEL:-gemma4:26b}"

safe "$X_LOGIN" || die "X_LOGIN is empty or has odd characters: set it in $CFG"
if [ "$X_LOGIN" = firstname.lastname ]; then
    if [ "$DRY" = 1 ]; then
        warn "X_LOGIN is still the placeholder firstname.lastname: set your Polytechnique login in $CFG"
    else
        die "X_LOGIN is still the placeholder firstname.lastname: set your Polytechnique login in $CFG"
    fi
fi
safe "$MUTATOR_MODEL" || die "MUTATOR_MODEL has odd characters"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6)   # probes: never prompt, fail fast
SSH_OPTS_I=(-o ConnectTimeout=10)                 # interactive: tunnel, start, setup

host_of() { case $1 in *.*) printf '%s' "$1" ;; *) printf '%s.%s' "$1" "$DOMAIN" ;; esac; }

# ---- remote scripts (sent on ssh's stdin, run on the machine) -----------------------------------------------

# args: MODE A B MODEL. MODE owner: A = owner login (ports computed as evosim-servers.sh does), B unused.
#       MODE ports: A = JEV port, B = Ollama port. Prints one line: OK jev oll | DOWN port | NOLORA port | NOMUT port | NOUSER
remote_probe() {
    cat << 'EOF'
mode=$1; a=$2; b=$3; model=$4
if [ "$mode" = owner ]; then
    uid=$(id -u "$a" 2>/dev/null) || { echo NOUSER; exit 0; }
    jev=$((20000 + uid % 10000)); oll=$((jev + 10000))
    cf=/Data/$a/evosim/config.env
    if [ -r "$cf" ]; then
        v=$(sed -n 's/^JEV_PORT="\${JEV_PORT:-\([0-9][0-9]*\)}".*/\1/p' "$cf" | head -n 1); [ -n "$v" ] && jev=$v
        v=$(sed -n 's/^OLLAMA_PORT="\${OLLAMA_PORT:-\([0-9][0-9]*\)}".*/\1/p' "$cf" | head -n 1); [ -n "$v" ] && oll=$v
    fi
else
    jev=$a; oll=$b
fi
curl -fsS --max-time 5 "http://127.0.0.1:$jev/health" > /dev/null 2>&1 || { echo "DOWN $jev"; exit 0; }
curl -fsS --max-time 5 "http://127.0.0.1:$jev/v1/models" 2>/dev/null | grep -qF jev-decision || { echo "NOLORA $jev"; exit 0; }
curl -fsS --max-time 5 "http://127.0.0.1:$oll/api/tags" 2>/dev/null | grep -qF "\"$model\"" || { echo "NOMUT $oll"; exit 0; }
echo "OK $jev $oll"
EOF
}

# prints: INFO own=<0|1> free=<free GPU MiB, -1 if no GPU>
remote_info() {
    cat << 'EOF'
own=0
[ -x "/Data/$(id -un)/evosim/venv/bin/vllm" ] && own=1
free=-1
if command -v nvidia-smi > /dev/null 2>&1; then
    line=$(nvidia-smi --query-gpu=memory.total,memory.used --format=csv,noheader,nounits 2>/dev/null | head -n 1)
    [ -n "$line" ] && free=$(echo "$line" | awk -F, '{print int($1 - $2)}')
fi
echo "INFO own=$own free=$free"
EOF
}

# setup detached from the ssh login (setsid + pid file), then follow its log; re-running re-attaches
remote_setup() {
    cat << 'EOF'
f=$HOME/evosim-setup.log; p=$HOME/.evosim-setup.pid
if ! { [ -f "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null; }; then
    setsid nohup bash "$HOME/evosim-servers.sh" setup > "$f" 2>&1 < /dev/null &
    echo $! > "$p"
else
    echo "  (setup already running on this machine: following its log)"
fi
tail -n +1 -f "$f" &
t=$!
while kill -0 "$(cat "$p")" 2>/dev/null; do sleep 5; done
sleep 1; kill "$t" 2>/dev/null
EOF
}

# ---- ssh helpers --------------------------------------------------------------------------------------------

# shellcheck disable=SC2029  # the command is meant to expand here
ssh_probe() { local m=$1; shift; ssh "${SSH_OPTS[@]}" "$X_LOGIN@$(host_of "$m")" "$@"; }
# shellcheck disable=SC2029
ssh_inter() { local m=$1; shift; ssh "${SSH_OPTS_I[@]}" "$X_LOGIN@$(host_of "$m")" "$@"; }

# ask QUESTION: yes only on a typed y, never without a terminal
ask() {
    local ans=""
    [ -t 0 ] || return 1
    printf '  ?     %s [y/N] ' "$1"
    read -r ans || true
    case $ans in y | Y | yes) return 0 ;; *) return 1 ;; esac
}

# entries: "MACHINE:X" (X = owner login) or "MACHINE:JEV:OLLAMA"; yours first
entries() {
    if [ -n "$MY_MACHINE" ]; then printf '%s:%s\n' "$MY_MACHINE" "$X_LOGIN"; fi
    local e
    for e in $REGISTRY; do printf '%s\n' "$e"; done
}

# ---- local ports --------------------------------------------------------------------------------------------

local_jev_ok() { curl -fsS --max-time 3 http://localhost:8000/v1/models 2> /dev/null | grep -qF jev-decision; }
local_mut_ok() { curl -fsS --max-time 3 http://localhost:11434/api/tags 2> /dev/null | grep -qF "\"$MUTATOR_MODEL\""; }

port_pids() {
    if command -v lsof > /dev/null; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2> /dev/null || true
    elif command -v ss > /dev/null; then
        ss -ltnp "sport = :$1" 2> /dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 || true
    fi
}

# free_ports: offers to kill an old ssh tunnel holding 8000 / 11434; never kills without a yes
free_ports() {
    local port pid cmd
    for port in 8000 11434; do
        for pid in $(port_pids "$port" | sort -u); do
            cmd=$(ps -o command= -p "$pid" 2> /dev/null || true)
            case $cmd in
                ssh\ * | */ssh\ *)
                    if ask "port $port is held by an old ssh tunnel (pid $pid: ${cmd:0:70}); kill it?"; then
                        kill "$pid" 2> /dev/null || true
                        sleep 1
                        ok "pid $pid stopped"
                    else
                        die "port $port is still held by pid $pid: close that tunnel (Ctrl+C in its terminal) and rerun"
                    fi
                    ;;
                *[Oo]llama*)
                    die "port $port is held by a local Ollama (pid $pid): quit it (menu bar icon on macOS, 'sudo systemctl stop ollama' on Linux), then rerun"
                    ;;
                *)
                    die "port $port is held by pid $pid (${cmd:0:70}): stop that program, then rerun"
                    ;;
            esac
        done
    done
    ok "ports 8000 and 11434 are free"
}

# ---- discovery ----------------------------------------------------------------------------------------------

T_MACHINE=""; T_JEV=""; T_OLL=""

# try_entry ENTRY: probes one registry entry from the machine itself; on success sets T_MACHINE T_JEV T_OLL
try_entry() {
    local m x y out kind a b who w1 w2 w3
    IFS=: read -r m x y <<< "$1"
    if ! { safe "$m" && safe "$x"; }; then warn "registry entry '$1' is malformed (MACHINE:OWNER or MACHINE:JEV:OLLAMA): skipped"; return 1; fi
    case $x in
        *[!0-9]*) kind=owner; a=$x; b=-; who="owner $x" ;;
        *) safe "${y:-}" || { warn "registry entry '$1' is malformed: skipped"; return 1; }; kind=ports; a=$x; b=$y; who="ports $x/$y" ;;
    esac
    if ! out=$(remote_probe | ssh_probe "$m" bash -s -- "$kind" "$a" "$b" "$MUTATOR_MODEL" 2> /dev/null); then
        warn "$m: cannot ssh (no key, no network, or off campus: use the VPN)"
        return 1
    fi
    read -r w1 w2 w3 <<< "$out"
    case $w1 in
        OK) ok "$m ($who): JEV on port $w2, Ollama on port $w3 are healthy"; T_MACHINE=$m; T_JEV=$w2; T_OLL=$w3; return 0 ;;
        DOWN) warn "$m ($who): JEV does not answer on port $w2 (stopped; only the owner can start it)" ;;
        NOLORA) warn "$m ($who): JEV on port $w2 does not list jev-decision" ;;
        NOMUT) warn "$m ($who): Ollama on port $w2 does not list $MUTATOR_MODEL" ;;
        NOUSER) warn "$m ($who): no such account on that machine" ;;
        *) warn "$m ($who): unexpected answer '$out'" ;;
    esac
    return 1
}

discover() {
    local e
    for e in $(entries); do
        if try_entry "$e"; then return 0; fi
    done
    return 1
}

open_tunnel() {
    say ""
    say "  Tunnel to $T_MACHINE: 8000 -> $T_JEV, 11434 -> $T_OLL. Leave this terminal open; close it with Ctrl+C (never Ctrl+Z)."
    say "  Check in a second terminal:  curl -s localhost:8000/v1/models   and   curl -s localhost:11434/api/tags"
    say "  Then in Unity: Window > EvoSim > Brain Health > Test connection (every host \"reachable\")."
    say ""
    exec ssh -N -L "8000:127.0.0.1:$T_JEV" -L "11434:127.0.0.1:$T_OLL" \
        -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 "${SSH_OPTS_I[@]}" "$X_LOGIN@$(host_of "$T_MACHINE")"
}

# ---- your own machine ---------------------------------------------------------------------------------------

OWN_AT=""; BEST_AT=""; BEST_FREE=-1

# scan_machines: sets OWN_AT (first machine with your install) and BEST_AT / BEST_FREE (most free GPU memory)
scan_machines() {
    local m info own free seen=" "
    for m in $MY_MACHINE $CANDIDATE_MACHINES; do
        case $seen in *" $m "*) continue ;; esac
        seen="$seen$m "
        safe "$m" || continue
        if ! info=$(remote_info | ssh_probe "$m" bash -s 2> /dev/null); then
            warn "$m: cannot ssh"
            continue
        fi
        own=${info#*own=}; own=${own%% *}
        free=${info##*free=}
        case $free in '' | *[!0-9-]*) continue ;; esac
        if [ "$own" = 1 ]; then
            OWN_AT=$m
            ok "$m: your install is here (/Data/$X_LOGIN/evosim)"
            return 0
        fi
        if [ "$free" -gt 0 ]; then
            ok "$m: GPU with $free MiB free"
        else
            warn "$m: no usable GPU"
        fi
        if [ "$free" -gt "$BEST_FREE" ]; then BEST_FREE=$free; BEST_AT=$m; fi
    done
}

save_my_machine() {
    MY_MACHINE=$1
    { grep -v '^MY_MACHINE=' "$CFG" || true; printf 'MY_MACHINE="%s"\n' "$1"; } > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    ok "MY_MACHINE=$1 saved in $CFG: always reuse this machine (/Data is local to it)"
}

ensure_script() {
    local m=$1 want have
    want=$(cksum < "$SERVERS_SH" | cut -d' ' -f1,2)
    have=$(ssh_probe "$m" 'cksum < ~/evosim-servers.sh' 2> /dev/null | cut -d' ' -f1,2 || true)
    if [ "$want" != "$have" ]; then
        scp -q "${SSH_OPTS_I[@]}" "$SERVERS_SH" "$X_LOGIN@$(host_of "$m"):evosim-servers.sh" || die "scp to $m failed"
        ok "evosim-servers.sh copied to $m"
    fi
}

# forward MACHINE SUBCOMMAND [server]: run evosim-servers.sh there
forward() {
    local m=$1; shift
    ensure_script "$m"
    if [ "$1" = setup ]; then
        say "  Setup takes ~30 min (~55 GB). It runs detached on $m: if this connection drops, rerun './evosim-connect.sh setup' to follow it."
        remote_setup | ssh_inter "$m" bash -s
    else
        # shellcheck disable=SC2088  # the ~ must reach the remote shell
        ssh -t "${SSH_OPTS_I[@]}" "$X_LOGIN@$(host_of "$m")" bash '~/evosim-servers.sh' "$@"
    fi
}

own_flow() {
    scan_machines
    if [ -n "$OWN_AT" ]; then
        if ask "start your servers on $OWN_AT now (JEV needs 2-10 min)?"; then
            [ "$OWN_AT" = "$MY_MACHINE" ] || save_my_machine "$OWN_AT"
            forward "$OWN_AT" start
            try_entry "$OWN_AT:$X_LOGIN" && open_tunnel
            die "servers started on $OWN_AT but not healthy yet: ./evosim-connect.sh status"
        fi
        say "  Start them later with: ./evosim-connect.sh start"
        return 1
    fi
    [ -n "$BEST_AT" ] && [ "$BEST_FREE" -gt 0 ] || die "no machine with a usable GPU among: $CANDIDATE_MACHINES"
    warn "no healthy servers and no install of yours: set up your own on $BEST_AT (most free GPU memory, $BEST_FREE MiB)"
    if [ "$BEST_FREE" -lt 15000 ]; then warn "under 15 GB free: JEV would run in 4-bit, less accurate"; fi
    if ask "run setup on $BEST_AT now (~30 min, ~55 GB in /Data/$X_LOGIN)?"; then
        save_my_machine "$BEST_AT"
        forward "$BEST_AT" setup
        say "  Setup finished (see the log above). Next: ./evosim-connect.sh   (it starts your servers and opens the tunnel)"
    else
        say "  Later: ./evosim-connect.sh setup   (or set MY_MACHINE in servers.local.env and run it)"
    fi
    return 1
}

# ---- dry run ------------------------------------------------------------------------------------------------

plan() {
    local e m x y first=""
    say "== dry run: nothing is executed. Plan for '$CMD' (login $X_LOGIN, mutator $MUTATOR_MODEL)"
    case $CMD in
        connect)
            say "1. already connected?"
            show "curl -fsS --max-time 3 http://localhost:8000/v1/models | grep jev-decision"
            show "curl -fsS --max-time 3 http://localhost:11434/api/tags | grep \"$MUTATOR_MODEL\""
            say "2. free the ports (asks before killing an old ssh tunnel; a local Ollama must be quit by you)"
            if command -v lsof > /dev/null; then
                show "lsof -nP -iTCP:8000 -sTCP:LISTEN -t ; lsof -nP -iTCP:11434 -sTCP:LISTEN -t"
            else
                show "ss -ltnp 'sport = :8000' ; ss -ltnp 'sport = :11434'"
            fi
            say "3. look for running servers, from each machine itself (first healthy pair wins)"
            for e in $(entries); do
                IFS=: read -r m x y <<< "$e"
                [ -n "$first" ] || first=$m
                case $x in
                    *[!0-9]*) show "ssh ${SSH_OPTS[*]} $X_LOGIN@$(host_of "$m") bash -s -- owner $x - $MUTATOR_MODEL   # ports from 'id -u $x' (+ its config.env)" ;;
                    *) show "ssh ${SSH_OPTS[*]} $X_LOGIN@$(host_of "$m") bash -s -- ports $x $y $MUTATOR_MODEL" ;;
                esac
            done
            [ -n "$first" ] || warn "MY_MACHINE and REGISTRY are both empty: nothing to probe, so step 4 applies"
            say "   remote script: curl 127.0.0.1:<jev>/health, /v1/models (jev-decision), 127.0.0.1:<ollama>/api/tags ($MUTATOR_MODEL)"
            say "4. if one is healthy, open the tunnel (foreground)"
            show "ssh -N -L 8000:127.0.0.1:<jev> -L 11434:127.0.0.1:<ollama> -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 ${SSH_OPTS_I[*]} $X_LOGIN@<machine>.$DOMAIN"
            say "5. otherwise look for your own install and free GPU memory on: ${MY_MACHINE:+$MY_MACHINE }$CANDIDATE_MACHINES"
            for m in $MY_MACHINE $CANDIDATE_MACHINES; do
                show "ssh ${SSH_OPTS[*]} $X_LOGIN@$(host_of "$m") bash -s   # own install? nvidia-smi free MiB"
            done
            say "   then, after a yes: copy the script if missing or changed, and start (install found) or setup (not)"
            show "scp ${SSH_OPTS_I[*]} evosim-servers.sh $X_LOGIN@<machine>.$DOMAIN:evosim-servers.sh"
            show "ssh -t ${SSH_OPTS_I[*]} $X_LOGIN@<machine>.$DOMAIN bash ~/evosim-servers.sh start    # or: setup, detached"
            ;;
        status)
            say "local ports (curl), the ssh processes holding them, then each registry entry:"
            for e in $(entries); do
                IFS=: read -r m x y <<< "$e"
                show "ssh ${SSH_OPTS[*]} $X_LOGIN@$(host_of "$m") bash -s -- <probe for $x${y:+:$y}>"
            done
            ;;
        start | stop | setup)
            [ -n "$MY_MACHINE" ] || warn "MY_MACHINE is empty: the real run would scan $CANDIDATE_MACHINES first"
            show "scp ${SSH_OPTS_I[*]} evosim-servers.sh $X_LOGIN@$(host_of "${MY_MACHINE:-<machine>}"):evosim-servers.sh   # only if missing or changed"
            show "ssh -t ${SSH_OPTS_I[*]} $X_LOGIN@$(host_of "${MY_MACHINE:-<machine>}") bash ~/evosim-servers.sh $CMD"
            ;;
    esac
}

# ---- commands -----------------------------------------------------------------------------------------------

cmd_connect() {
    if local_jev_ok && local_mut_ok; then
        ok "localhost:8000 (jev-decision) and localhost:11434 ($MUTATOR_MODEL) already answer: nothing to do"
        say "  Unity: Window > EvoSim > Brain Health > Test connection"
        return 0
    fi
    free_ports
    say "== looking for running servers"
    if discover; then open_tunnel; fi
    say "== no healthy servers found"
    own_flow
}

cmd_status() {
    local p e
    say "== local ports"
    if local_jev_ok; then ok "localhost:8000 answers, lists jev-decision"; else warn "localhost:8000 does not answer with jev-decision"; fi
    if local_mut_ok; then ok "localhost:11434 answers, lists $MUTATOR_MODEL"; else warn "localhost:11434 does not answer with $MUTATOR_MODEL"; fi
    for p in 8000 11434; do
        for pid in $(port_pids "$p" | sort -u); do
            say "        port $p held by pid $pid: $(ps -o command= -p "$pid" 2> /dev/null | cut -c1-90)"
        done
    done
    say "== registry"
    for e in $(entries); do try_entry "$e" || true; done
    [ -n "$(entries)" ] || warn "MY_MACHINE and REGISTRY are empty: nothing to probe"
}

cmd_machine() {
    local sub=$1
    if [ -z "$MY_MACHINE" ]; then
        [ "$sub" = setup ] || die "MY_MACHINE is not set: run ./evosim-connect.sh (it finds or sets up your machine)"
        scan_machines
        [ -z "$OWN_AT" ] || die "you already have an install on $OWN_AT: set MY_MACHINE=\"$OWN_AT\" in $CFG"
        [ -n "$BEST_AT" ] && [ "$BEST_FREE" -gt 0 ] || die "no machine with a usable GPU among: $CANDIDATE_MACHINES"
        ask "run setup on $BEST_AT (most free GPU memory, $BEST_FREE MiB)?" || die "cancelled"
        save_my_machine "$BEST_AT"
    fi
    forward "$MY_MACHINE" "$sub"
}

if [ "$DRY" = 1 ]; then
    case $CMD in connect | status | start | stop | setup) plan; exit 0 ;; esac
fi

case $CMD in
    connect) cmd_connect ;;
    status) cmd_status ;;
    start | stop | setup) cmd_machine "$CMD" ;;
    *) die "unknown command '$CMD': connect, status, start, stop, setup (--dry-run, --help)" ;;
esac
