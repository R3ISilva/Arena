# Arena Server — Reference

This file covers the **server** (`the pick`, Docker on `127.0.0.1:27890`).
The game-level **tests** are documented in [`../../../tests/README.md`](../../../tests/README.md).

## Scripts (in `scripts/`)

| Script | Effect | Exit |
|---|---|---|
| `docker-check.sh` | Docker engine reachable? | 0 running / 1 down |
| `docker-run.sh` | build image → remove existing `arena-server` → run detached on `-p 27890:27890/udp` → self-verify `docker port` shows `0.0.0.0:27890` | 0 on port / non-zero failed |
| `docker-stop.sh` | stop + remove `arena-server` | 0 |

## The pick (port / config)

- Mapping `-p 27890:27890/udp`; clients reach it at `127.0.0.1:27890`.
- `config.json` → `server.port` must equal `27890` (both container and clients read it).
- Startup log: `[server] listening on 0.0.0.0:27890`.

## Testing the pick

The diagnostics (`--test`, `--probe`, `--twoclient`, and the windowed
`two-client-with-head-test`) are **game tests**, not server docs. Full usage,
exit bars, and the run-only-when-watching note for the windowed one live in
[**`../../../tests/README.md`**](../../../tests/README.md). Quick facts:

- **Server required** for `--probe` / `--twoclient` / `two-client-with-head-test`
  (the last one starts the pick itself); `--test` needs no server.
- The "with head" test opens two GUI windows — run it only when you want to
  **watch** the test in action; use `--twoclient` for headless CI assertions.
