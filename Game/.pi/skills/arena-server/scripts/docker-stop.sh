#!/usr/bin/env bash
# docker-stop.sh — stop and remove the Arena dedicated server container.
# A running container is the only allowed way to host the server (rule #1).
#
# Uses:
#   ./docker-stop.sh          stop + remove the container (frees port 27890)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="arena-server"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker CLI not found (is Docker installed / on PATH?)." >&2
    exit 1
fi

if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    echo ">> Stopping and removing container '$NAME' ..."
    docker rm -f "$NAME"
else
    echo ">> No running container named '$NAME' to stop."
fi

echo "Done."
