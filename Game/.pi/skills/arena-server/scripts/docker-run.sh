#!/usr/bin/env bash
# docker-run.sh — build (if needed) and run the Arena dedicated server in Docker.
# Enforces the project rule: the server ALWAYS runs in Docker.
#
# Uses:
#   ./docker-run.sh          build the image, then run the container detached
#
# The script resolves the Game/ directory itself (4 levels up from scripts/,
# via .pi/skills/arena-server), so it works regardless of the cwd.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
IMAGE="arena-server"
NAME="arena-server"
CONTAINER_PORT="27890"
# Map the host port to the same container port so clients reach the pick at
# 127.0.0.1:27890. A bare "-p 27890/udp" (no host: prefix) publishes to a random
# ephemeral host port (e.g. 0.0.0.0:58360->27890/udp), breaking every client that
# reads config.json and targets 127.0.0.1:27890. Keep the explicit HOST:CONTAINER
# form.
HOST_PORT="27890"

cd "$GAME_DIR"

# --- Precondition: Docker must be running ---------------------------------
if ! "$SCRIPT_DIR/docker-check.sh"; then
    echo "ERROR: Docker is not running. Start Docker Desktop, then retry." >&2
    exit 1
fi

# --- Build the image --------------------------------------------------------
echo ">> Building image '$IMAGE' from $GAME_DIR ..."
docker build -t "$IMAGE" .

# --- Stop any existing container to keep exactly one instance (rule #3) -----
if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    echo ">> Stopping and removing existing container '$NAME' ..."
    docker rm -f "$NAME" >/dev/null
fi

# --- Run detached ------------------------------------------------------------
echo ">> Starting container '$NAME' (mapping ${HOST_PORT}:${CONTAINER_PORT}/udp) ..."
docker run -d --name "$NAME" --rm -p "${HOST_PORT}:${CONTAINER_PORT}/udp" "$IMAGE" >/dev/null

echo ">> Server '$NAME' is running. Logs:"
docker logs "$NAME"
echo

# --- Self-verify: the pick must be a NON-ephemeral host port for clients -------
# The container logs "[server] listening on 0.0.0.0:27890" even when it is
# published on a random host port (if -p lost its host prefix). Don't trust that
# line; verify the actual host binding below.
PUBLISH="$(docker port "$NAME" "${CONTAINER_PORT}/udp" 2>/dev/null || true)"
echo "Published: $PUBLISH"
if printf '%s' "$PUBLISH" | grep -qE "0\.0\.0\.0:${HOST_PORT}"; then
    echo ">> OK: the pick is on 127.0.0.1:${HOST_PORT}."
else
    echo "ERROR: container running but NOT on host port $HOST_PORT." >&2
    echo "Expected '0.0.0.0:$HOST_PORT->$CONTAINER_PORT/udp', got '$PUBLISH'." >&2
    echo "Something regressed the -p mapping; fix docker-run.sh, then re-Up." >&2
    exit 1
fi
echo
echo "Verify the port is bound:  netstat -ano | grep 27890"
