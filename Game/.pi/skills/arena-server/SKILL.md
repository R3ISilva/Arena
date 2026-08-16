---
name: arena-server
description: Hold up "the pick" — the single Arena server container that clients reach at 127.0.0.1:27890, ALWAYS in Docker via the bundled scripts — when the user asks to run/stop the server, alters server code (src/server.lua, src/session.lua), runs a server-dependent diagnostic (--twoclient, --twoclientwin, --probe), or reports clients failing to connect.
---

# Arena Dedicated Server

The server runs **in Docker** (`docker-run.sh` self-verifies the port, so it just works). Exact commands/probe bars live in [`reference.md`](reference.md).

- **Up:** `scripts/docker-check.sh` then `scripts/docker-run.sh`. Criterion: it prints `OK: the pick is on 127.0.0.1:27890`.
- **Probe:** run the game diagnostics to confirm the pick is healthy. Commands, exit bars, and ordering live in [`../../../tests/README.md`](../../../tests/README.md) — see the headless `--test`/`--probe`/`--twoclient`, plus the windowed `two-client-with-head-test/twoclientwin.sh` (run that one only when you want to watch it; the pick is brought up by it when absent, and torn down afterward unless `--keep`).
- **Down:** `scripts/docker-stop.sh`.

Never a bare `lovec . --server`.
