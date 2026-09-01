<#
.SYNOPSIS
  Runs one or more Arena windowed clients, making sure Docker and the dedicated
  server ("the pick") are up first.

.DESCRIPTION
  1. Verifies the Docker engine is running (and offers to start Docker Desktop).
  2. Ensures the arena-server container is up, bringing it up via the skill's
     bundled docker-run.sh (the project rule: the server ALWAYS runs in Docker).
  3. Launches $ClientCount windowed client(s) (love.exe) against it.

  Exit codes:
    0  - client(s) launched (write "OK" to stdout, then run-game.ps1 is still
         active because the client window(s) are open; Ctrl+C or closing them
         ends it)
    1  - Docker not running / start failed
    2  - required tooling (love.exe) not found

.PARAMETER ClientCount
  How many windowed clients to launch. Defaults to 1; run-2clients.ps1 passes 2.

.PARAMETER SkipServer
  Only check Docker, do not start the server (assumes it is already up).
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 16)]
    [int]$ClientCount = 1,
    [switch]$SkipServer
)

# Use Continue so harmless native stderr (e.g. docker's blkio warning) is not
# escalated into a terminating NativeCommandError. Failures are detected via
# explicit $LASTEXITCODE checks throughout; cmdlet errors still print warnings.
$ErrorActionPreference = "Continue"

$GameDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ServerScripts = Join-Path $GameDir ".pi/skills/arena-server/scripts"
$LoveExe = "C:/Program Files/LOVE/love.exe"

# --- Tooling check -------------------------------------------------------
if (-not (Test-Path $LoveExe)) {
    Write-Error "LÖVE not found at '$LoveExe'. Set or fix the LOVE path."
    exit 2
}

function Test-DockerRunning {
    # docker info returns 0 only when the engine/daemon is reachable.
    # Redirect stderr aside; a missing docker CLI also yields a non-zero code.
    & docker info 2>$null
    return $LASTEXITCODE -eq 0
}

function Test-DockerReady {
    # `docker info` turns 0 as soon as the Windows named pipe is reachable, but
    # Docker Desktop's WSL backend can still be initializing its in-distro
    # /bin/bash for a few seconds. Building during that window trips the WSL
    # relay: `<3>WSL (..) execvpe(/bin/bash) failed: No such file or directory`.
    # A cheap, honest readiness probe is `docker version` against the Server: it
    # only returns 0 once the daemon (and its WSL backend) can actually answer.
    & docker version --format '{{.Server.Version}}' 2>$null
    return $LASTEXITCODE -eq 0
}

# --- Step 1: Docker engine ----------------------------------------------
$ClientWord = if ($ClientCount -eq 1) { "client" } else { "clients" }
Write-Host "== Arena: run $ClientCount $ClientWord =="
if (-not (Test-DockerRunning)) {
    Write-Host "Docker engine is NOT running - attempting to start Docker Desktop..."
    try {
        Start-Process "Docker Desktop"
    } catch {
        Write-Error "Could not start Docker Desktop. Start it manually and re-run."
        exit 1
    }
    Write-Host "Waiting for the Docker engine to come up (up to 60s)..."
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerRunning) { break }
        Start-Sleep -Seconds 2
    }
    if (-not (Test-DockerRunning)) {
        Write-Error "Docker engine did not come up in time. Try starting Docker Desktop manually, then re-run."
        exit 1
    }
    Write-Host "Docker engine is up."
} else {
    Write-Host "Docker engine is running."
}

# The pipe is reachable, but Docker Desktop's WSL backend may still be warming
# up its /bin/bash. Wait until the daemon can actually answer a Server query so
# the subsequent docker build does not race the WSL relay. This covers both the
# freshly-started path above and the already-running (but still-booting) path.
if (-not (Test-DockerReady)) {
    Write-Host "Waiting for Docker Desktop's backend to finish starting..."
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerReady) { break }
        Start-Sleep -Seconds 2
    }
    if (-not (Test-DockerReady)) {
        Write-Error "Docker daemon did not become ready in time. Try starting Docker Desktop manually, then re-run."
        exit 1
    }
    Write-Host "Docker backend is ready."
}

# --- Helper: run the skill's docker-run.sh (build + start the pick) -----
function Invoke-ArenaServerRun {
    $runScript = Join-Path $ServerScripts "docker-run.sh"
    if (-not (Test-Path $runScript)) {
        Write-Error "Server script not found: $runScript. Re-run the arena-server skill setup."
        exit 3
    }
    # `bash` on Windows can resolve to WSL's relay stub, which fails with
    # `execvpe(/bin/bash) failed: No such file or directory` when the WSL
    # default distro has no working /bin/bash. The shell scripts are plain
    # bash and only need `docker`/coreutils, so prefer the known-good Git bash
    # executable (if installed) and only fall back to `bash` on PATH.
    $bashCandidates = @(
        "C:/Program Files/Git/bin/bash.exe",        # Git for Windows
        "C:/Program Files/Git/usr/bin/bash.exe"
    )
    $Bash = $bashCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Bash) {
        # Last resort: whatever `bash` resolves to on PATH.
        $Bash = (Get-Command bash -ErrorAction SilentlyContinue).Source
    }
    if (-not $Bash) {
        Write-Error "Could not locate bash to run docker-run.sh. Install Git for Windows or WSL bash."
        exit 3
    }
    & $Bash $runScript
    if ($LASTEXITCODE -ne 0) {
        Write-Error "docker-run.sh failed to bring up the pick (exit $LASTEXITCODE)."
        exit 1
    }
}

# The Docker image is rebuilt (and the container recreated) by docker-run.sh
# on every invocation, so the image's creation timestamp advances with each build.
# A source change therefore leaves at least one tracked server file newer than
# the running image -> rebuild needed. Only the server-relevant files matter:
# the top-level config/lua/json plus everything under src/.
function Get-ArenaSourceCutoff {
    $paths = @()
    $paths += @("config.json", "main.lua", "conf.lua", "json.lua") | ForEach-Object {
        Join-Path $GameDir $_
    }
    $srcDir = Join-Path $GameDir "src"
    if (Test-Path $srcDir) {
        $paths += Get-ChildItem -Path $srcDir -Recurse -File -Force | ForEach-Object { $_.FullName }
    }
    $newest = Get-Date 0
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $t = (Get-Item -LiteralPath $p).LastWriteTime
            if ($t -gt $newest) { $newest = $t }
        }
    }
    return $newest
}

# --- Step 2: Server (the pick) ------------------------------------------
$ContainerUp = & docker ps --format '{{.Names}}' 2>$null | Where-Object { $_ -eq "arena-server" }

$needsUpdate = $false
if ($ContainerUp) {
    $sourceCutoff = Get-ArenaSourceCutoff
    # WSL/Windows clocks can skew by a small amount; rebuild only when the newest
    # source file is clearly newer than the image build (a few seconds of slack).
    $imageCreated = Get-Date (docker inspect --format '{{.Created}}' "arena-server" 2>$null)
    if ($imageCreated) {
        $needsUpdate = $sourceCutoff -gt $imageCreated.AddSeconds(5)
    } else {
        # Couldn't read the image age; rebuild to be safe.
        $needsUpdate = $true
    }
    if ($needsUpdate) {
        Write-Host "Server source changed since the image was built - the pick needs a rebuild."
    }
}

if ($SkipServer) {
    if (-not $ContainerUp) {
        Write-Warning "--SkipServer given but no arena-server container found; the client will not be playable."
    }
} elseif (-not $ContainerUp) {
    Write-Host "The pick (arena-server) is not up - starting it via the skill's docker-run.sh..."
    Invoke-ArenaServerRun
} elseif ($needsUpdate) {
    Write-Host "Rebuilding the pick because the server source changed since its image was built."
    Invoke-ArenaServerRun
} else {
    Write-Host "The pick is already up and up to date with the current source."
}

# --- Step 3: Launch the client(s) ---------------------------------------
for ($i = 1; $i -le $ClientCount; $i++) {
    Write-Host "Launching windowed client $i/$ClientCount : $LoveExe $GameDir"
    Start-Process -FilePath $LoveExe -ArgumentList "`"$GameDir`"" -WorkingDirectory $GameDir
}
Write-Host "Launched $ClientCount client(s). Play in the windows; close them to end."
exit 0
