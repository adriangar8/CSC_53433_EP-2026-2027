# EvoSim model servers (JEV + Ollama mutator)

The JEV scenes need two model servers: **JEV** (vLLM on a GPU, port 8000 in Unity) and the **Ollama mutator**
(`gemma4:26b` on the CPU, port 11434 in Unity). They run on a Polytechnique room machine; Unity stays on your laptop
and reaches them through an SSH tunnel, so no scene changes. **The Neuro scenes need no server.**

## TL;DR

```
cd Tools/EvoSimServers
cp servers.example.env servers.local.env      # then edit: X_LOGIN = your Polytechnique login
./evosim-connect.sh                           # Windows: .\evosim-connect.ps1
```

It connects to running servers (a teammate's or yours) if a healthy pair exists, and otherwise offers to start or
set up your own on a free machine. Leave the terminal it opens running while Unity runs; Ctrl+C closes the tunnel.
`./evosim-connect.sh --dry-run connect` prints every ssh/curl it would run and runs nothing.

| Command | What it does |
|---|---|
| `./evosim-connect.sh [connect]` | Steps: already connected? → free stale ports → probe the registry → tunnel; else start/set up your own |
| `./evosim-connect.sh status` | Local ports, who holds them, health of every registry entry |
| `./evosim-connect.sh start` / `stop` / `setup` | Run `evosim-servers.sh` on your machine (`MY_MACHINE`), copying it there if missing or changed |

macOS and Linux: `evosim-connect.sh` (needs only ssh, scp, curl, lsof or ss; works with macOS's bash 3.2).
Windows: `evosim-connect.ps1` does `connect` and `status`; to set up or start your own servers use the commands of
Path B by hand, or WSL / Git Bash with `evosim-connect.sh`.

## Once per laptop

1. **A network that reaches the machines**: the campus network, or the school VPN from home.
2. **An SSH key**, so the scripts never wait for a password (they use `BatchMode`):
   - macOS / Linux: `ssh-keygen -t ed25519` (Enter at every question), then `ssh-copy-id firstname.lastname@hibou.polytechnique.fr`.
   - Windows (PowerShell): `ssh-keygen -t ed25519`, then
     `type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh firstname.lastname@hibou.polytechnique.fr "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"`.
   The key works on every room machine (they share your account).
3. **Optional `~/.ssh/config` alias**, handy for typing `ssh` by hand (Windows: `C:\Users\<you>\.ssh\config`, create the
   folder and file if missing). The scripts do not need it: they use `X_LOGIN` and `DOMAIN` from `servers.local.env`.
   ```
   Host evosim-hibou
       HostName hibou.polytechnique.fr
       User firstname.lastname
   ```
4. `cp servers.example.env servers.local.env` and set `X_LOGIN`. This file is git-ignored; the repository is public,
   so never put it, or anyone's login or ports, in a committed file.

### servers.local.env

| Variable | Meaning |
|---|---|
| `X_LOGIN` | your Polytechnique login (required) |
| `CANDIDATE_MACHINES` | machines scanned for your install and free GPU memory (default `vendee albatros hibou verdier france vanda`; the full list of room machines is on the [DSI page](https://portail.polytechnique.edu/dsi/salles-informatiques/liste-des-ordinateurs)) |
| `REGISTRY` | servers to try first, space separated: `machine:owner_login` (ports computed from that owner's uid and their `config.env`) or `machine:jev_port:ollama_port` |
| `MY_MACHINE` | the machine holding your own install; written by the script after a setup |
| `MUTATOR_MODEL` | must match the MutatorService's Model in Unity (default `gemma4:26b`) |
| `DOMAIN` | appended to short machine names (default `polytechnique.fr`) |

Your own machine is probed first, automatically (as `MY_MACHINE:X_LOGIN`), then the registry in order.

## Path A: connect to running servers

Put the teammate's entry in `REGISTRY`, e.g. `REGISTRY="vendee:their.login"`, and run `./evosim-connect.sh`. You log in with
**your own** login: anyone with an account can reach servers running on a machine, and `/Data/<owner>/evosim/config.env`
is read only to find the ports. The script checks from the machine itself that JEV answers (`/health`), lists
`jev-decision` (`/v1/models`) and that Ollama lists the mutator model (`/api/tags`), then opens

```
ssh -N -L 8000:127.0.0.1:<jev port> -L 11434:127.0.0.1:<ollama port> <login>@<machine>.polytechnique.fr
```

Check in a second terminal (Windows: `curl.exe`); both print JSON, the first mentions `jev-decision`, the second the mutator model:

```
curl -s localhost:8000/v1/models
curl -s localhost:11434/api/tags
```

Then in Unity: **Window > EvoSim > Brain Health > Test connection**: every host "reachable".
If the servers are stopped, only the account that started them can start them: ask that teammate.

## Path B: set up and run your own

**Pick a machine** (`./evosim-connect.sh` proposes the one with the most free GPU memory):
an NVIDIA GPU with 15 GB or more (FP8, the reference; below that JEV runs in 4-bit, less accurate) and about 32 GB of RAM.
Known good: vendee (RTX 4000 Ada, 20 GB), albatros / hibou / verdier (RTX A5000, 24 GB), all 62 GB RAM.
Also candidates: france (RTX A4000, 16 GB, 124 GB RAM) and vanda (RTX 2000 Ada, 16 GB, 61 GB RAM). Their 16 GB cards are
just above FP8's 15 GB minimum, so they only work when almost nothing else uses the GPU (checked once, not run yet).
Any machine on the DSI list may have a GPU: add it to `CANDIDATE_MACHINES` after checking with `nvidia-smi`.
**One JEV per GPU**: vLLM takes 90 % of it; if someone already runs JEV on a machine, use another (`nvidia-smi` shows the memory in use).
**Always reuse the same machine**: everything goes to `/Data/<login>/evosim`, local to that machine (the script remembers it in `MY_MACHINE`).

**Setup, once** (~30 min, ~55 GB downloaded; no root, no Docker):

```
./evosim-connect.sh setup
```

> **Setup starts nothing.** When it ends (the log says `Setup done`), **run `./evosim-connect.sh` again**: that second run
> starts your servers (JEV: 2-10 min) and opens the tunnel. The script prints this reminder too.

It copies `evosim-servers.sh` to the machine and runs the setup there, detached from your ssh login: if the connection drops,
rerun the same command to follow it again. By hand: `scp evosim-servers.sh <login>@<machine>.polytechnique.fr:` then `ssh` there and `bash evosim-servers.sh setup`.

**Each session**: start, tunnel, check, Unity, stop.

1. Start (JEV needs 2-10 min; the servers keep running after you log out): `./evosim-connect.sh start`
   (by hand: `ssh <machine> 'bash ~/evosim-servers.sh start'`).
2. Tunnel: `./evosim-connect.sh` (it finds your servers and opens it). Leave that terminal open; Ctrl+C closes it, never Ctrl+Z.
3. Check with the two `curl` commands above.
4. Unity: Window > EvoSim > Brain Health > Test connection.
5. When done: Ctrl+C the tunnel, then `./evosim-connect.sh stop`.

Other commands on the machine: `bash ~/evosim-servers.sh status`, `logs jev`, `logs ollama`, `start jev`, `stop ollama`.
Your ports there come from your user id (JEV = 20000 + uid % 10000, Ollama = JEV + 10000) and can be changed in `/Data/<login>/evosim/config.env`.

## Sharing your servers with teammates

**Rule: whenever you set up servers on a machine, add it to your own `servers.local.env` and tell the team**
(the script reminds you after a setup); each teammate then adds the entry to theirs. The committed `servers.example.env`
stays empty: this repository is public.

Tell them your machine and login. They add `machine:your.login` to their `REGISTRY` (or `machine:jev_port:ollama_port`, from
`bash ~/evosim-servers.sh ssh-config` on the machine) in their own `servers.local.env`. Only your account can start or stop
your servers. Tell the others before long runs: the servers are shared.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `bind: Address already in use` on 8000 / 11434 | An old tunnel or a local Ollama holds the port. The script offers to kill an old ssh tunnel (it never kills without asking). Manually: macOS `lsof -i :8000 -i :11434`; Linux `ss -ltnp \| grep -E ':(8000\|11434) '`; then `kill -9 <pid>`. Windows: `netstat -ano \| findstr ":8000 :11434"` then `taskkill /PID <pid> /F`. A local Ollama: quit it (macOS/Windows: the app; Linux: `sudo systemctl stop ollama`) |
| curl prints nothing or hangs | The tunnel is down or paused (rerun `./evosim-connect.sh`), or the servers stopped (`./evosim-connect.sh status`; `start` your own, or ask the owner) |
| `cannot ssh` | No key (see "Once per laptop"), no network: from home use the campus network or the school VPN |
| `start` says JEV stopped and shows its log | Send that log. `out of memory`: another JEV or job uses the GPU: pick another machine |
| Servers vanished overnight / after a weekday | The DSI stops long jobs (below). `start` again; nothing is downloaded twice |
| `/Data` wiped | Run `setup` again |

## Rules (DSI)

- Heavy computation on the room machines only **18h-8h and on weekends**; on weekdays, processes of users who are not at the
  machine may be killed. For longer runs, ask the DSI for an exception.
- `/Data` is not backed up.
- **Keep `Logs/EvoSim/runs/` and `Library/EvoSim/AnswerCache`**: with `-cache` a run replays without the servers.

## Files

`evosim-connect.sh` / `.ps1` (laptop), `evosim-servers.sh` (the course's reference install, runs on the machine; copied unchanged),
`servers.example.env` (documented settings), `servers.local.env` (yours, git-ignored).
