#!/usr/bin/env bash
# docker-check.sh — verify Docker is running (engine/daemon reachable), not just
# the CLI installed. Opens Docker Desktop on macOS/Windows if the daemon is not up.
#
# Uses:
#   ./docker-check.sh           exit 0 = Docker running, exit 1 = Docker not running
#   ./docker-check.sh --open    also attempts to launch Docker Desktop when down

set -euo pipefail

OPEN_REQUESTED="${1:-}"

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker CLI not found (is Docker installed / on PATH?)." >&2
    exit 1
fi

if docker info >/dev/null 2>&1; then
    echo "Docker is running (engine reachable: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown))."
    exit 0
fi

echo "Docker CLI is present but the Docker engine is NOT reachable." >&2

if [ "$OPEN_REQUESTED" = "--open" ]; then
    if command -v powershell.exe >/dev/null 2>&1; then
        echo ">> Attempting to start Docker Desktop ..." >&2
        powershell.exe -NoProfile -Command 'Start-Process "Docker Desktop"' >/dev/null 2>&1 || true
        echo "Launched Docker Desktop; it may take a moment to come up. Re-run ./docker-check.sh to confirm." >&2
    elif [ "$(uname)" = "Darwin" ] && command -v open >/dev/null 2>&1; then
        echo ">> Attempting to start Docker Desktop ..." >&2
        open -a Docker
    fi
else
    echo "Start Docker Desktop, then retry. (Pass './docker-check.sh --open' to auto-launch it.)" >&2
fi

exit 1
