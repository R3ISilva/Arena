<#
.SYNOPSIS
  Runs two Arena windowed clients, making sure Docker and the dedicated server
  ("the pick") are up first.

.DESCRIPTION
  Thin wrapper over run-game.ps1 that forwards -ClientCount 2 (and optionally
  -SkipServer), so the Docker/server bootstrap logic lives in exactly one place
  (run-game.ps1). See run-game.ps1's help for the full description and exit
  codes.

  The server has two spawn points, so each of the two clients gets a slot and
  the game is immediately playable between the two windows.

  1. Verifies the Docker engine is running (and offers to start Docker Desktop).
  2. Ensures the arena-server container is up, bringing it up via the skill's
     bundled docker-run.sh (the project rule: the server ALWAYS runs in Docker).
  3. Launches two GUI clients (love.exe) against it.

.PARAMETER SkipServer
  Only check Docker, do not start the server (assumes it is already up).
#>
[CmdletBinding()]
param(
    [switch]$SkipServer
)

$GameDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RunGame = Join-Path $GameDir "run-game.ps1"
if (-not (Test-Path $RunGame)) {
    Write-Error "run-game.ps1 not found next to run-2clients.ps1: $RunGame"
    exit 2
}

if ($SkipServer) {
    & $RunGame -ClientCount 2 -SkipServer
} else {
    & $RunGame -ClientCount 2
}
exit $LASTEXITCODE
