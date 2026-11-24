<#
.SYNOPSIS
  Windows version of evosim-connect.sh: connect Unity's localhost:8000 / :11434 to running EvoSim servers.

.DESCRIPTION
  .\evosim-connect.ps1 [connect]   look for a healthy server pair (registry, then your own machine) and open the tunnel
  .\evosim-connect.ps1 status      local ports and health of every registry entry
  Needs the Windows OpenSSH client (ssh) and curl.exe, both included in Windows 10/11. Settings: servers.local.env.
  Setting up your own servers is done with evosim-connect.sh (WSL / Git Bash) or by hand: see README.md, Path B.
#>
param([ValidateSet('connect', 'status')][string]$Command = 'connect')
$ErrorActionPreference = 'Stop'

function Ok($m)   { Write-Host "  ok    $m" }
function Warn($m) { Write-Host "  warn  $m" }
function Fail($m) { Write-Host "  FAIL  $m"; exit 1 }

# ---- settings: KEY="value" lines of servers.local.env ----
$cfgFile = Join-Path $PSScriptRoot 'servers.local.env'
if (-not (Test-Path $cfgFile)) { Fail 'no servers.local.env: copy servers.example.env to servers.local.env and edit it (see README.md)' }
$cfg = @{}
foreach ($line in Get-Content $cfgFile) {
    if ($line -match '^\s*([A-Z_]+)="([^"]*)"') { $cfg[$Matches[1]] = $Matches[2] }
}
function Cfg($k, $d) { if ($cfg.ContainsKey($k) -and $cfg[$k] -ne '') { $cfg[$k] } else { $d } }
$login   = Cfg 'X_LOGIN' ''
$domain  = Cfg 'DOMAIN' 'polytechnique.fr'
$model   = Cfg 'MUTATOR_MODEL' 'gemma4:26b'
$mine    = Cfg 'MY_MACHINE' ''
$cands   = (Cfg 'CANDIDATE_MACHINES' 'vendee albatros hibou verdier') -split '\s+'
$registry = (Cfg 'REGISTRY' '') -split '\s+' | Where-Object { $_ }
$safe = '^[A-Za-z0-9._:/-]+$'
if ($login -notmatch $safe -or $login -eq 'firstname.lastname') { Fail "set X_LOGIN (your Polytechnique login) in $cfgFile" }
if ($model -notmatch $safe) { Fail 'MUTATOR_MODEL has odd characters' }

function HostOf($m) { if ($m -like '*.*') { $m } else { "$m.$domain" } }

# ---- the remote probe, same as evosim-connect.sh; sent base64-encoded so Windows line endings cannot break it ----
$probe = @'
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
'@.Replace("`r`n", "`n")
$probeB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($probe))

# Test-Entry "machine:owner" or "machine:jev:ollama" -> @{Machine; Jev; Oll} when healthy, $null otherwise
function Test-Entry($entry) {
    $p = $entry -split ':'
    $m = $p[0]
    if ($p.Count -lt 2 -or $m -notmatch $safe -or $p[1] -notmatch $safe) { Warn "registry entry '$entry' is malformed: skipped"; return $null }
    if ($p[1] -match '^\d+$') { $kind = 'ports'; $a = $p[1]; $b = $p[2]; $who = "ports $a/$b" } else { $kind = 'owner'; $a = $p[1]; $b = '-'; $who = "owner $a" }
    if ($b -notmatch $safe) { Warn "registry entry '$entry' is malformed: skipped"; return $null }
    $out = & ssh -o BatchMode=yes -o ConnectTimeout=6 "$login@$(HostOf $m)" "echo $probeB64 | base64 -d | bash -s -- $kind $a $b $model" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { Warn "${m}: cannot ssh (no key, no network, or off campus: use the VPN)"; return $null }
    $w = "$out".Trim() -split '\s+'
    switch ($w[0]) {
        'OK'     { Ok "$m ($who): JEV on port $($w[1]), Ollama on port $($w[2]) are healthy"; return @{ Machine = $m; Jev = $w[1]; Oll = $w[2] } }
        'DOWN'   { Warn "$m ($who): JEV does not answer on port $($w[1]) (stopped; only the owner can start it)" }
        'NOLORA' { Warn "$m ($who): JEV on port $($w[1]) does not list jev-decision" }
        'NOMUT'  { Warn "$m ($who): Ollama on port $($w[1]) does not list $model" }
        'NOUSER' { Warn "$m ($who): no such account on that machine" }
        default  { Warn "$m ($who): unexpected answer '$out'" }
    }
    return $null
}

function Test-Local($url, $needle) {
    $r = & curl.exe -fsS --max-time 3 $url 2>$null
    return ($LASTEXITCODE -eq 0 -and "$r".Contains($needle))
}
$jevOk = Test-Local 'http://localhost:8000/v1/models' 'jev-decision'
$mutOk = Test-Local 'http://localhost:11434/api/tags' "`"$model`""

$entries = @()
if ($mine) { $entries += "${mine}:$login" }
$entries += $registry

if ($Command -eq 'status') {
    Write-Host '== local ports'
    if ($jevOk) { Ok 'localhost:8000 answers, lists jev-decision' } else { Warn 'localhost:8000 does not answer with jev-decision' }
    if ($mutOk) { Ok "localhost:11434 answers, lists $model" } else { Warn "localhost:11434 does not answer with $model" }
    foreach ($port in 8000, 11434) {
        Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | ForEach-Object {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            Write-Host "        port $port held by pid $($_.OwningProcess) ($($proc.ProcessName))"
        }
    }
    Write-Host '== registry'
    foreach ($e in $entries) { $null = Test-Entry $e }
    exit 0
}

# ---- connect ----
if ($jevOk -and $mutOk) {
    Ok "localhost:8000 (jev-decision) and localhost:11434 ($model) already answer: nothing to do"
    Write-Host '  Unity: Window > EvoSim > Brain Health > Test connection'
    exit 0
}

# free the ports: offer to stop an old ssh tunnel; a local Ollama must be quit by the user
foreach ($port in 8000, 11434) {
    foreach ($c in Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) {
        $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        $name = "$($proc.ProcessName)"
        if ($name -like 'ssh*') {
            $ans = Read-Host "  ?     port $port is held by an old ssh tunnel (pid $($c.OwningProcess)); stop it? [y/N]"
            if ($ans -match '^(y|yes)$') { Stop-Process -Id $c.OwningProcess; Ok "pid $($c.OwningProcess) stopped" }
            else { Fail "port $port is still held by pid $($c.OwningProcess): close that tunnel (Ctrl+C in its window) and rerun" }
        } elseif ($name -like '*ollama*') {
            Fail "port $port is held by a local Ollama: quit it (tray icon > Quit), then rerun"
        } else {
            Fail "port $port is held by pid $($c.OwningProcess) ($name): stop that program, then rerun"
        }
    }
}
Ok 'ports 8000 and 11434 are free'

Write-Host '== looking for running servers'
foreach ($e in $entries) {
    $t = Test-Entry $e
    if ($t) {
        Write-Host ''
        Write-Host "  Tunnel to $($t.Machine): 8000 -> $($t.Jev), 11434 -> $($t.Oll). Leave this window open; close it with Ctrl+C."
        Write-Host '  Check in a second window:  curl.exe -s localhost:8000/v1/models   and   curl.exe -s localhost:11434/api/tags'
        Write-Host '  Then in Unity: Window > EvoSim > Brain Health > Test connection (every host "reachable").'
        Write-Host ''
        & ssh -N -L "8000:127.0.0.1:$($t.Jev)" -L "11434:127.0.0.1:$($t.Oll)" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 "$login@$(HostOf $t.Machine)"
        exit $LASTEXITCODE
    }
}
Warn 'no healthy servers found'
Write-Host '  Start your own servers (README.md, Path B) with evosim-connect.sh from WSL or Git Bash, or by hand on the machine:'
Write-Host '    ssh <login>@<machine>.polytechnique.fr "bash ~/evosim-servers.sh start"'
exit 1
