#!/usr/bin/env bash
# evosim-servers.sh - the EvoSim model servers on a Polytechnique computer-room machine (no root, no Docker).
#
#   JEV      vLLM on the GPU   the brain of the JEV scenes   laptop localhost:8000   (ref. prototype/docker/compose.yaml)
#   mutator  Ollama on the CPU gemma4:26b, rewrites genes    laptop localhost:11434  (ref. Docs/Site/guides/getting-started.md)
#
# Unity stays on your laptop. An SSH tunnel maps its localhost ports to this machine, so the scenes' hosts
# (http://localhost:8000 and http://localhost:11434) need no change. Same vLLM build as the course image
# (nightly 81198e97, installed as a wheel), same JEV revision and flags, same Ollama settings.
#
# On the X machine (pick one from the DSI list and keep it: /Data is local to each machine):
#   bash evosim-servers.sh setup        once: checks, installs, downloads (~55 GB on /Data), prints the SSH block
#   bash evosim-servers.sh start        each session: starts both servers and waits until they answer
#   bash evosim-servers.sh status       health, ports, GPU, RAM
#   bash evosim-servers.sh stop
#   bash evosim-servers.sh logs jev     (or: logs ollama)
#   bash evosim-servers.sh ssh-config   prints the SSH block again
# start and stop also take "jev" or "ollama" to act on one server only.
#
# On the laptop: paste the SSH block into ~/.ssh/config and keep "ssh -N evosim" open while Unity runs.
# Check: curl -s localhost:8000/v1/models ; curl -s localhost:11434/api/tags
# then in Unity: Window > EvoSim > Brain Health > Test connection.
# A second shell on the machine: ssh -o ClearAllForwardings=yes evosim
#
# Settings are in $BASE/config.env (ports, JEV_QUANT, JEV_KV, MUTATOR_MODEL); an environment variable of
# the same name wins. EVOSIM_BASE moves everything (default /Data/$USER/evosim, not your home: quota).

set -euo pipefail

USER="${USER:-$(id -un)}"
BASE="${EVOSIM_BASE:-/Data/$USER/evosim}"
CONF="$BASE/config.env"
VENV="$BASE/venv"
LOGS="$BASE/logs"
RUN="$BASE/run"
UV="$BASE/bin/uv"
OLLAMA_DIR="$BASE/ollama"
OLLAMA_BIN="$OLLAMA_DIR/bin/ollama"

# every download and cache goes to $BASE, never to the home directory
export HF_HOME="$BASE/hf"
unset HF_HUB_CACHE HUGGINGFACE_HUB_CACHE
export UV_CACHE_DIR="$BASE/uv-cache"
export UV_PYTHON_INSTALL_DIR="$BASE/python"
export XDG_CACHE_HOME="$BASE/cache"
export TRITON_CACHE_DIR="$BASE/cache/triton"
export FLASHINFER_WORKSPACE_BASE="$BASE"

JEV_REPO="autotrust/JEV-9B"
JEV_REV="b63f651ce8ed64481d3f5e73ecdb05f740042f01"
SNAP="$HF_HOME/hub/models--autotrust--JEV-9B/snapshots/$JEV_REV"
VLLM_COMMIT="81198e97ba7eee2a22540caaa756b7fdddcb4d93"
VLLM_VERSION="0.31.1rc1.dev88+g81198e97b"
TORCH_BACKEND="${TORCH_BACKEND:-cu130}"

if [ -f "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
fi

uid=$(id -u)
JEV_PORT="${JEV_PORT:-$((20000 + uid % 10000))}"
OLLAMA_PORT="${OLLAMA_PORT:-$((JEV_PORT + 10000))}"
JEV_QUANT="${JEV_QUANT:-}"
JEV_KV="${JEV_KV:-768M}"
JEV_GPU="${JEV_GPU:-0.90}"
MUTATOR_MODEL="${MUTATOR_MODEL:-gemma4:26b}"
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-4h}"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
die()  { printf '  FAIL  %s\n' "$*" >&2; exit 1; }

first_line() { printf '%s' "${1%%$'\n'*}"; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# ver_ge A B: true when version A >= version B
ver_ge() {
    local lowest
    lowest=$(printf '%s\n%s\n' "$1" "$2" | sort -V)
    [ "$(first_line "$lowest")" = "$2" ]
}

label() { if [ "$1" = jev ]; then printf 'JEV'; else printf 'Ollama'; fi; }

# http URL SECONDS [curl args...]: the body on success, nothing and a failure otherwise
http() {
    local url=$1 secs=$2
    shift 2
    curl -fsS --max-time "$secs" "$@" "$url" 2>/dev/null
}

port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# alive NAME: its process runs, and it is still the server we started (not a recycled pid)
alive() {
    local p cmd word=vllm
    if [ "$1" = ollama ]; then word=ollama; fi
    p=$(cat "$RUN/$1.pid" 2>/dev/null || true)
    [ -n "$p" ] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || return 1
    [[ ${cmd,,} == *"$word"* ]]
}

# launch NAME COMMAND...: in its own session, so it outlives the SSH login; the pid is its process group
launch() {
    local name=$1
    shift
    mkdir -p "$LOGS" "$RUN"
    setsid "$@" > "$LOGS/$name.log" 2>&1 < /dev/null &
    echo $! > "$RUN/$name.pid"
}

stop_one() {
    local name=$1 p
    p=$(cat "$RUN/$name.pid" 2>/dev/null || true)
    if [ -n "$p" ] && alive "$name"; then
        kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
        for _ in $(seq 30); do
            kill -0 "$p" 2>/dev/null || break
            sleep 1
        done
        kill -KILL -- "-$p" 2>/dev/null || true
        ok "$(label "$name") stopped"
    else
        ok "$(label "$name") not running"
    fi
    rm -f "$RUN/$name.pid"
}

# wait_ready NAME URL MINUTES
wait_ready() {
    local name=$1 url=$2 limit=$(($3 * 60)) t=0
    printf '  wait  %s ' "$(label "$name")"
    until http "$url" 5 > /dev/null; do
        if ! alive "$name"; then
            printf '\n'
            warn "$(label "$name") stopped; end of $LOGS/$name.log:"
            tail -n 25 "$LOGS/$name.log" | sed 's/^/        /'
            return 1
        fi
        if [ "$t" -ge "$limit" ]; then
            printf '\n'
            warn "$(label "$name") not ready after $3 min; follow it with: bash $0 logs $name"
            return 1
        fi
        printf '.'
        sleep 10
        t=$((t + 10))
    done
    printf ' ready (%s s)\n' "$t"
}

# gpu_info: sets GPU_NAME GPU_MEM GPU_USED (MiB) GPU_CC GPU_DRV from the first GPU
gpu_info() {
    local out name mem used cc drv
    command -v nvidia-smi > /dev/null || return 1
    out=$(nvidia-smi --query-gpu=name,memory.total,memory.used,compute_cap,driver_version --format=csv,noheader,nounits 2> /dev/null) || return 1
    IFS=',' read -r name mem used cc drv <<< "$(first_line "$out")"
    GPU_NAME=$(trim "$name")
    GPU_MEM=$(trim "$mem")
    GPU_USED=$(trim "$used")
    GPU_CC=$(trim "$cc")
    GPU_DRV=$(trim "$drv")
}

# users logged in at the machine itself (not over SSH)
present_users() {
    who 2> /dev/null | awk -v me="$USER" '$1 != me && $2 !~ /^pts\// {print $1}' | sort -u | tr '\n' ' '
}

preflight() {
    local os="unknown" glibc others ram_total ram_avail free_gb
    say "== checks on $(hostname -s)"

    if [ -r /etc/os-release ]; then
        os=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")
    fi
    glibc=$(first_line "$(ldd --version 2>&1)")
    glibc=${glibc##* }
    if ver_ge "$glibc" 2.28; then
        ok "$os, glibc $glibc"
    else
        die "$os, glibc $glibc: vLLM's wheels need glibc 2.28 or later"
    fi

    gpu_info || die "no working nvidia-smi: this machine has no usable NVIDIA GPU, pick another one"
    ok "GPU $GPU_NAME, $GPU_MEM MiB, compute capability $GPU_CC, driver $GPU_DRV"
    if ! ver_ge "$GPU_CC" 7.5; then
        die "compute capability $GPU_CC: vLLM needs 7.5 or more, pick another machine"
    fi
    if ! ver_ge "${GPU_DRV%%.*}" 580; then
        warn "driver $GPU_DRV is older than CUDA 13's (580): vLLM may refuse to start"
    fi
    if [ -z "$JEV_QUANT" ]; then
        if [ "$GPU_MEM" -ge 15000 ] && ver_ge "$GPU_CC" 8.0; then
            JEV_QUANT=fp8
        else
            JEV_QUANT=bitsandbytes
        fi
    fi
    if [ "$JEV_QUANT" = fp8 ]; then
        ok "JEV in FP8 (the reference)"
    else
        warn "JEV in 4-bit (bitsandbytes): GPU under 15 GB or older than Ampere; it runs, but less accurately than the reference FP8"
    fi
    if [ "$GPU_USED" -gt 1000 ] && ! alive jev; then
        warn "$GPU_USED MiB of the GPU already in use: someone else may be working on this machine"
    fi
    others=$(present_users)
    if [ -n "$others" ]; then
        warn "logged in at the machine itself: $others(an empty machine is better)"
    fi

    read -r ram_total ram_avail < <(free -g | awk '/^Mem:/ {print $2, $7}')
    if [ "$ram_avail" -ge 28 ]; then
        ok "RAM: $ram_avail of $ram_total GB free"
    else
        warn "RAM: $ram_avail of $ram_total GB free; $MUTATOR_MODEL on the CPU wants ~20 GB next to JEV: pick a machine with more RAM, or run 'start ollama' on a second machine"
    fi

    mkdir -p "$BASE" 2> /dev/null || die "cannot create $BASE (no /Data here?): set EVOSIM_BASE to a local disk with ~60 GB free, not your home"
    free_gb=$(df -Pk "$BASE" | awk 'NR == 2 {print int($4 / 1048576)}')
    if [ "$free_gb" -ge 60 ]; then
        ok "$BASE: $free_gb GB free"
    else
        warn "$BASE: $free_gb GB free; a fresh install needs ~55 GB (vLLM 12, JEV 19, Ollama and $MUTATOR_MODEL 22)"
    fi
}

write_config() {
    if [ -f "$CONF" ]; then
        ok "settings kept: $CONF"
        return
    fi
    cat > "$CONF" << EOF
# EvoSim model servers on $(hostname -s). After an edit: bash evosim-servers.sh stop; bash evosim-servers.sh start
# An environment variable of the same name wins over these lines.
JEV_PORT="\${JEV_PORT:-$JEV_PORT}"                    # JEV's port on this machine (laptop side: 8000)
OLLAMA_PORT="\${OLLAMA_PORT:-$OLLAMA_PORT}"              # Ollama's port on this machine (laptop side: 11434)
JEV_QUANT="\${JEV_QUANT:-$JEV_QUANT}"                  # fp8 = reference; bitsandbytes = 4-bit, less accurate
JEV_KV="\${JEV_KV:-$JEV_KV}"                           # KV cache (reference 768M; lower it on "out of memory")
JEV_GPU="\${JEV_GPU:-$JEV_GPU}"                        # --gpu-memory-utilization
MUTATOR_MODEL="\${MUTATOR_MODEL:-$MUTATOR_MODEL}"        # must match the MutatorService's Model in Unity
OLLAMA_KEEP_ALIVE="\${OLLAMA_KEEP_ALIVE:-$OLLAMA_KEEP_ALIVE}"      # how long the mutator stays in RAM when idle
EOF
    ok "settings written: $CONF"
}

install_uv() {
    if [ ! -x "$UV" ]; then
        curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL="$BASE/bin" sh > /dev/null 2>&1 || die "uv install failed"
        if [ ! -x "$UV" ] && [ -x "$BASE/bin/bin/uv" ]; then
            ln -sf "$BASE/bin/bin/uv" "$UV"
        fi
        [ -x "$UV" ] || die "uv installed, but not at $UV"
    fi
    ok "uv $("$UV" --version | awk '{print $2}')"
}

install_vllm() {
    local have=""
    if [ -x "$VENV/bin/python" ]; then
        have=$("$VENV/bin/python" -c 'import importlib.metadata as m; print(m.version("vllm"))' 2> /dev/null || true)
    fi
    if [ "$have" != "$VLLM_VERSION" ]; then
        if [ ! -x "$VENV/bin/python" ]; then
            "$UV" venv -q --python 3.12 "$VENV" || die "could not create the Python 3.12 venv in $VENV"
        fi
        say "  installing vLLM $VLLM_VERSION, the course image's build (~10 GB, 5-10 min) ..."
        "$UV" pip install -q --python "$VENV/bin/python" --torch-backend "$TORCH_BACKEND" \
            --extra-index-url "https://wheels.vllm.ai/$VLLM_COMMIT" "vllm==$VLLM_VERSION" huggingface_hub zstandard \
            || die "vLLM install failed; try again with: TORCH_BACKEND=auto bash $0 setup"
        "$VENV/bin/vllm" download-kernels > "$LOGS/download-kernels.log" 2>&1 || true
    fi
    ok "vLLM $VLLM_VERSION"
    if [ "$JEV_QUANT" = bitsandbytes ]; then
        "$UV" pip install -q --python "$VENV/bin/python" bitsandbytes || die "bitsandbytes install failed"
        ok "bitsandbytes (4-bit JEV)"
    fi
}

ollama_version() { "$OLLAMA_BIN" --version 2>&1 | grep -oE '[0-9]+(\.[0-9]+)+' | tail -n 1 || true; }

install_ollama() {
    local archive="$BASE/ollama-linux-amd64.tar.zst"
    if [ ! -x "$OLLAMA_BIN" ]; then
        mkdir -p "$OLLAMA_DIR"
        say "  downloading Ollama ..."
        curl -fL -# --retry 3 -o "$archive" https://ollama.com/download/ollama-linux-amd64.tar.zst || die "Ollama download failed"
        if tar --zstd -xf "$archive" -C "$OLLAMA_DIR" 2> /dev/null; then
            :
        elif command -v zstd > /dev/null && zstd -dc "$archive" | tar -x -C "$OLLAMA_DIR"; then
            :
        else
            "$VENV/bin/python" -c 'import sys, zstandard; zstandard.ZstdDecompressor().copy_stream(open(sys.argv[1], "rb"), sys.stdout.buffer)' "$archive" \
                | tar -x -C "$OLLAMA_DIR" || die "could not unpack $archive"
        fi
        rm -f "$archive"
        [ -x "$OLLAMA_BIN" ] || die "no $OLLAMA_BIN after unpacking"
    fi
    ok "Ollama $(ollama_version)"
}

download_jev() {
    local shards
    say "  downloading ~18 GB (resumable: rerun setup if it stops) ..."
    "$VENV/bin/python" - "$JEV_REPO" "$JEV_REV" << 'EOF' || die "JEV download failed (rerun setup to resume)"
import sys
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1], revision=sys.argv[2],
                  allow_patterns=["*.json", "*.jinja", "model-*.safetensors", "head.safetensors", "adapter/*", "adapter_vllm/*"])
EOF
    shopt -s nullglob
    shards=("$SNAP"/model-*.safetensors)
    shopt -u nullglob
    if [ "${#shards[@]}" -gt 0 ] && [ -f "$SNAP/head.safetensors" ] && [ -f "$SNAP/adapter_vllm/adapter_config.json" ]; then
        ok "JEV weights: ${#shards[@]} shards, head, adapter_vllm ($(du -shL "$SNAP" | cut -f1))"
    else
        die "JEV weights incomplete in $SNAP (rerun setup)"
    fi
}

start_ollama() {
    local tags body
    if alive ollama; then
        ok "Ollama already running (port $OLLAMA_PORT)"
    else
        [ -x "$OLLAMA_BIN" ] || die "Ollama is not installed on this machine: run setup here first"
        if port_busy "$OLLAMA_PORT"; then
            die "port $OLLAMA_PORT is taken on this machine: change OLLAMA_PORT in $CONF"
        fi
        # CPU only, as the reference (num_gpu 0): the GPU is JEV's
        launch ollama env OLLAMA_HOST="127.0.0.1:$OLLAMA_PORT" OLLAMA_MODELS="$OLLAMA_DIR/models" \
            OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE" OLLAMA_MAX_LOADED_MODELS=1 CUDA_VISIBLE_DEVICES=-1 \
            "$OLLAMA_BIN" serve
        wait_ready ollama "http://127.0.0.1:$OLLAMA_PORT/api/tags" 2 || return 1
    fi
    if [ "${1:-}" = warm ]; then
        tags=$(http "http://127.0.0.1:$OLLAMA_PORT/api/tags" 5 || true)
        if [[ $tags != *"\"$MUTATOR_MODEL\""* ]]; then
            warn "$MUTATOR_MODEL is not pulled on this machine: run setup"
            return 1
        fi
        # same options as Unity's OllamaMutatorClient (num_gpu 0, num_ctx 1024), so its first call doesn't reload it
        body="{\"model\":\"$MUTATOR_MODEL\",\"messages\":[],\"keep_alive\":\"$OLLAMA_KEEP_ALIVE\",\"options\":{\"num_gpu\":0,\"num_ctx\":1024}}"
        if http "http://127.0.0.1:$OLLAMA_PORT/api/chat" 600 -d "$body" > /dev/null; then
            ok "Ollama on port $OLLAMA_PORT, $MUTATOR_MODEL loaded in RAM"
        else
            warn "Ollama is up but could not load $MUTATOR_MODEL: bash $0 logs ollama"
        fi
    fi
}

pull_mutator() {
    local started=0 tags
    if ! alive ollama; then
        start_ollama || die "Ollama did not start: bash $0 logs ollama"
        started=1
    fi
    tags=$(http "http://127.0.0.1:$OLLAMA_PORT/api/tags" 5 || true)
    if [[ $tags == *"\"$MUTATOR_MODEL\""* ]]; then
        ok "$MUTATOR_MODEL already pulled"
    else
        say "  pulling $MUTATOR_MODEL (~18 GB) ..."
        OLLAMA_HOST="127.0.0.1:$OLLAMA_PORT" "$OLLAMA_BIN" pull "$MUTATOR_MODEL" || die "pull failed (rerun setup to resume)"
        ok "$MUTATOR_MODEL pulled"
    fi
    if [ "$started" = 1 ]; then
        stop_one ollama
    fi
}

launch_jev() {
    if alive jev; then
        ok "JEV already running (port $JEV_PORT)"
        return
    fi
    [ -x "$VENV/bin/vllm" ] || die "vLLM is not installed on this machine: run setup here first"
    [ -f "$SNAP/adapter_vllm/adapter_config.json" ] || die "the JEV weights are not on this machine: run setup here first"
    if port_busy "$JEV_PORT"; then
        die "port $JEV_PORT is taken on this machine: change JEV_PORT in $CONF"
    fi
    if gpu_info && [ "$GPU_USED" -gt 1000 ]; then
        warn "$GPU_USED MiB of the GPU already in use: JEV may fail with 'out of memory'"
    fi
    # the flags of prototype/docker/compose.yaml, service jev
    launch jev env PATH="$VENV/bin:$PATH" HF_HUB_OFFLINE=1 VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0 \
        "$VENV/bin/vllm" serve "$JEV_REPO" \
        --revision "$JEV_REV" \
        --served-model-name "$JEV_REPO" \
        --quantization "$JEV_QUANT" \
        --enable-lora \
        --max-lora-rank 32 \
        --lora-modules "jev-decision=$SNAP/adapter_vllm" \
        --logprobs-mode processed_logprobs \
        --max-model-len 1024 \
        --max-num-seqs 8 \
        --max-num-batched-tokens 1024 \
        --gpu-memory-utilization "$JEV_GPU" \
        --kv-cache-memory-bytes "$JEV_KV" \
        --enable-prefix-caching \
        --mamba-cache-mode align \
        --host 127.0.0.1 \
        --port "$JEV_PORT"
    ok "JEV launched ($JEV_QUANT, port $JEV_PORT); start-up takes 5-10 min"
}

wait_jev() {
    local models
    wait_ready jev "http://127.0.0.1:$JEV_PORT/health" 15 || return 1
    models=$(http "http://127.0.0.1:$JEV_PORT/v1/models" 5 || true)
    if [[ $models == *jev-decision* ]]; then
        ok "JEV serves autotrust/JEV-9B and jev-decision"
    else
        warn "JEV answers but does not list jev-decision: check $SNAP/adapter_vllm"
    fi
}

ssh_block() {
    local host
    host=$(hostname -f 2> /dev/null || hostname)
    case $host in
        *.*) ;;
        *) host="$host.polytechnique.fr" ;;
    esac
    cat << EOF
Host evosim
    HostName $host
    User $USER
    LocalForward 8000 127.0.0.1:$JEV_PORT
    LocalForward 11434 127.0.0.1:$OLLAMA_PORT
    ExitOnForwardFailure yes
    ServerAliveInterval 30
EOF
}

cmd_setup() {
    preflight
    mkdir -p "$LOGS" "$RUN"
    write_config
    say "== tools"
    install_uv
    install_vllm
    install_ollama
    say "== JEV weights ($JEV_REPO @ ${JEV_REV:0:12})"
    download_jev
    say "== mutator"
    pull_mutator
    say ""
    say "Setup done on $(hostname -s). On your laptop, add this to ~/.ssh/config (Windows: C:\\Users\\<you>\\.ssh\\config):"
    say ""
    ssh_block
    say ""
    say "Then: bash $0 start (here), and ssh -N evosim (laptop) while Unity runs."
}

cmd_start() {
    local what=$1
    say "== start on $(hostname -s)"
    if [ "$what" != ollama ]; then
        launch_jev
    fi
    if [ "$what" != jev ]; then
        start_ollama warm || true
    fi
    if [ "$what" != ollama ]; then
        wait_jev
    fi
    say ""
    say "  laptop: ssh -N evosim (8000 -> $JEV_PORT, 11434 -> $OLLAMA_PORT here). The servers keep running after you log out."
}

cmd_stop() {
    local what=$1
    if [ "$what" != ollama ]; then
        stop_one jev
    fi
    if [ "$what" != jev ]; then
        stop_one ollama
    fi
}

cmd_status() {
    local loaded others
    say "== $(hostname -s): $BASE"
    if alive jev; then
        if http "http://127.0.0.1:$JEV_PORT/health" 5 > /dev/null; then
            ok "JEV ready on port $JEV_PORT ($JEV_QUANT)"
        else
            warn "JEV running on port $JEV_PORT but not ready yet (start-up 5-10 min): bash $0 logs jev"
        fi
    else
        say "  --    JEV stopped"
    fi
    if alive ollama; then
        loaded=$(http "http://127.0.0.1:$OLLAMA_PORT/api/ps" 5 || true)
        if [[ $loaded == *"\"$MUTATOR_MODEL\""* ]]; then
            ok "Ollama ready on port $OLLAMA_PORT, $MUTATOR_MODEL in RAM"
        elif [ -n "$loaded" ]; then
            warn "Ollama ready on port $OLLAMA_PORT, $MUTATOR_MODEL not in RAM (the next mutation reloads it, maybe past Unity's 60 s time-out)"
        else
            warn "Ollama process up but not answering on port $OLLAMA_PORT: bash $0 logs ollama"
        fi
    else
        say "  --    Ollama stopped"
    fi
    if gpu_info; then
        say "        GPU $GPU_NAME: $GPU_USED of $GPU_MEM MiB used"
    fi
    free -g | awk '/^Mem:/ {printf "        RAM: %s of %s GB used\n", $3, $2}'
    others=$(present_users)
    if [ -n "$others" ]; then
        warn "logged in at the machine itself: $others"
    fi
}

target="${2:-all}"
case $target in
    all | jev | ollama) ;;
    *) die "unknown server '$target': use jev or ollama" ;;
esac

case "${1:-help}" in
    setup) cmd_setup ;;
    start) cmd_start "$target" ;;
    stop) cmd_stop "$target" ;;
    status) cmd_status ;;
    logs) if [ "$target" = all ]; then target=jev; fi; tail -n 40 -f "$LOGS/$target.log" ;;
    ssh-config) ssh_block ;;
    *) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
