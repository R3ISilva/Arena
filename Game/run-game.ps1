<#
.SYNOPSIS
  Runs one Arena windowed client, making sure Docker and the dedicated server
  ("the pick") are up first.

.DESCRIPTION
  1. Verifies the Docker engine is running (and offers to start Docker Desktop).
  2. Ensures the arena-server container is up, bringing it up via the skill's
     bundled docker-run.sh (the project rule: the server ALWAYS runs in Docker).
  3. Launches one GUI client (love.exe) against it.

  Exit codes:
    0  - client launched (write "OK" to stdout, then run-game.ps1 is still active
         because the client window is open; Ctrl+C or closing the window ends it)
    1  - Docker not running / start failed
    2  - required tooling (love.exe) not found

.PARAMETER SkipServer
  Only check Docker, do not start the server (assumes it is already up).
#>
[CmdletBinding()]
param(
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

# --- Step 1: Docker engine ----------------------------------------------
Write-Host "== Arena: run one client =="
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

# --- Step 2: Server (the pick) ------------------------------------------
$ContainerUp = & docker ps --format '{{.Names}}' 2>$null | Where-Object { $_ -eq "arena-server" }

if ($SkipServer) {
    if (-not $ContainerUp) {
        Write-Warning "--SkipServer given but no arena-server container found; the client will not be playable."
    }
} elseif (-not $ContainerUp) {
    Write-Host "The pick (arena-server) is not up - starting it via the skill's docker-run.sh..."
    $runScript = Join-Path $ServerScripts "docker-run.sh"
    if (-not (Test-Path $runScript)) {
        Write-Error "Server script not found: $runScript. Re-run the arena-server skill setup."
        exit 3
    }
    & bash $runScript
    if ($LASTEXITCODE -ne 0) {
        Write-Error "docker-run.sh failed to bring up the pick (exit $LASTEXITCODE)."
        exit 1
    }
} else {
    Write-Host "The pick is already up (arena-server container present)."
}

# --- Step 3: Launch one client ------------------------------------------
Write-Host "Launching one windowed client: $LoveExe $GameDir"
Start-Process -FilePath $LoveExe -ArgumentList "`"$GameDir`"" -WorkingDirectory $GameDir
Write-Host "Client launched (PID above / in the opened window). Play in the window; close it to end."
exit 0
