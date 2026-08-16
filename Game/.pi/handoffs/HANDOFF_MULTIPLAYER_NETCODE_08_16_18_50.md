# Handoff: MULTIPLAYER_NETCODE
Date: 2026-08-16 18:50 GMT | Branch: main | Status: in progress

## Summary
Implemented the full multiplayer netcode spec (authoritative headless LÖVE server + predictive ENet clients) by refactoring the single-player game into shared modules, then containerized the server with Docker and verified client↔container connectivity end-to-end. A reconciliation rubber-banding bug surfaced in real two-client testing; the root cause was identified (fixed 65px reconcile threshold vs Docker's high RTT) and an RTT-aware threshold fix was implemented and passes unit + single-client checks, but still needs final confirmation in the exact two-client manual scenario.

## Work Completed
- [x] Refactored `main.lua` monolith into `src/world.lua`, `src/session.lua`, `src/net.lua`, `src/protocol.lua`, `src/server.lua`, `src/client.lua` — shared world logic is the determinism seam; `session.lua` is the transport-agnostic test seam.
- [x] Extended `config.json`: spawn points, per-player colors, `server {address,port,tickRate,snapshotRate,spectatorLimit}`; removed `startX/startY` and runtime obstacle editing.
- [x] Added `json.encode` (was decode-only) for wire payloads.
- [x] Added headless test harness `tests/run_tests.lua` (`lovec.exe . --test`, exit 0/1) — 16 tests passing.
- [x] Added `Dockerfile` (Ubuntu 24.04 + LÖVE 11.5, headless) and `.dockerignore`.
- [x] Added `--probe` mode + `tests/probe.lua` for headless connectivity checks.
- [x] Fixed slot-freeing: client now disconnects gracefully (`peer:disconnect(0)` + flush + service) instead of `host:destroy()` (which made ENet wait ~32s timeout before freeing a slot).
- [x] Fixed `docker logs` buffering: `io.stdout:setvbuf("line")` in server startup.
- [x] Fixed reconciliation rubber-banding: replaced fixed threshold with RTT-derived threshold (see Technical Context).
- [x] Worked around Ubuntu `love` package post-install bug (broken `update-alternatives` man path) with `|| true`.

## Files Affected
- Created: `src/world.lua`, `src/session.lua`, `src/net.lua`, `src/protocol.lua`, `src/server.lua`, `src/client.lua`, `conf.lua`, `Dockerfile`, `.dockerignore`, `tests/run_tests.lua`, `tests/probe.lua`
- Modified: `main.lua` (mode dispatch: default client / `--server` / `--test` / `--probe`), `config.json` (schema), `json.lua` (encode)
- Deleted (staged, not by this session — review before committing): `../Arena/Bem-vindo.md`

## Technical Context

### Architecture
- **`src/world.lua`** — pure grid/A*/movement, deterministic. A* sort tie-breaks on unique cell index so it is total/deterministic. `stepPlayer` uses a fixed `dt`.
- **`src/session.lua`** — the seam. Two modes (`"server"`, `"client"`), driven by `onConnect(peerId)`, `onDisconnect(peerId)`, `onMessage(peerId, msg)`, `tick(dt)`; emits state via `getState()` and outbound messages via `drainOutbox()`. Messages are plain tables; outbox entries are `{to=peerId|"*"|"server", channel, message}`.
- **`src/net.lua`** — only ENet-aware file. Channel 0 = `"reliable"` (welcome), channel 1 = `"unreliable"` (snapshots/moveIntents). Maps ENet peer userdata↔numeric ids (`idByPeer` is a weak-keyed table).
- **Protocol** (JSON): `welcome {slot}`, `snapshot {seq, players[{slot,x,y}]}`, `moveIntent {x,y}`; connect/disconnect are ENet events with no payload.
- Fixed 30 Hz timestep on both sides via an accumulator in `love.update` (`fixedDt = 1/tickRate`).

### ENet facts (LÖVE 11.5 bundles lua-enet; `require("enet")` works)
- `host:service(ms)` returns `{type, peer, data, channel}`; types `"connect"/"receive"/"disconnect"`; `data` is number for connect/disconnect, string for receive.
- `peer:send(data, channel, flag)` with flag `"reliable"`/`"unreliable"`/`"unsequenced"`.
- `peer:round_trip_time()` returns ms (smoothed; starts at ENet default 500 ms, settles after pings).
- `host:get_socket_address()` returns a single `"ip:port"` string (not two return values).

### Reconciliation (the bug)
- Client predicts its own movement; server is authority. Normal prediction means the client leads the server by roughly `RTT × walkSpeed`. Original code snapped when divergence exceeded a fixed `walkSpeed*0.25` (65 px at speed 260).
- Docker Desktop UDP RTT was measured ~295 ms during connection establishment, settling to ~82 ms steady-state; at 295 ms the lag is ~77 px > 65 px → snap every snapshot → each snap re-sent a move intent → server's path got reset every tick → server froze at its first waypoint → visible "forward + teleport back" loop.
- **Fix (in `src/session.lua:reconcile`)**: threshold = `max(walkSpeed*0.1, walkSpeed*latency*2)`, where `latency` (seconds) is fed by the adapter via `session:setLatency(rttMs/1000)` from `peer:round_trip_time()` in `ClientAdapter:pump`. On genuine divergence: snap, re-path to target, and re-send the move intent (heals a dropped intent since moveIntents ride the unreliable channel).

### Docker
- Headless server: `conf.lua` disables window/graphics/audio/sound/joystick/physics when `os.getenv("GAME_SERVER")=="1"`; container also sets `SDL_VIDEODRIVER=dummy` and `SDL_AUDIODRIVER=dummy`.
- Ubuntu 24.04 `love` package postinst fails (references missing `love-11.5.6.gz` man page); `|| true` tolerated — binary installs fine.
- Port: UDP 27890 (`EXPOSE` + `-p 27890:27890/udp`).

### Gotcha (important for any future diagnostics)
- Any headless loop script that drives `session:tick(dt)` MUST use the fixed-timestep accumulator, not call `tick(dt)` once per loop iteration. An earlier diagnostic ticked 33× too fast and produced misleading "server stuck / 295 ms divergence" readings. `tests/probe.lua` still has this bug (harmless for its connect-only purpose, but should be fixed).

## Current State
- Working: unit tests 16/16 (`lovec.exe . --test`), client loads clean, headless server runs in Docker (logs `[server] listening on 0.0.0.0:27890`), host client↔container connectivity confirmed (`--probe` reports `player1`/`player2`/`spectator` correctly), graceful disconnect frees slots immediately.
- Verified with corrected single-client diagnostic: RTT settles ~82 ms, predicted-vs-authoritative divergence ~9 px, threshold ~43 px → **zero snaps** (fix works in that scenario).
- NOT yet re-verified: the exact two-client manual test the user reported (both windows open, clicking to move). This is the critical remaining check.
- Known minor issue: `tests/probe.lua` ticks without an accumulator (see gotcha above).
- Git: all work is uncommitted. Branch `main` is behind `origin/main` by 5 commits. A staged `deleted: ../Arena/Bem-vindo.md` is unrelated to this session — review before committing.

## Next Steps
### Immediate
1. Re-run the real two-client test to confirm the fix (this is the unverified user scenario):
   - Ensure server: `docker rm -f arena-server; cd Game && docker run -d --name arena-server -p 27890:27890/udp arena-server`
   - Launch 2 clients: `powershell.exe -NoProfile -Command "Start-Process 'C:\Program Files\LOVE\love.exe' -WorkingDirectory 'E:\Arena\Game' -ArgumentList '.'"` twice (1s apart).
   - Have the user click-to-move in both windows for ~30s; confirm no forward/teleport-back.
2. If rubber-banding persists, re-instrument `src/session.lua:reconcile` with a temporary `print` of `dx, dy, threshold, latency` and re-test two clients to get real divergence/RTT numbers (remember the accumulator gotcha).

### Then
- Fix `tests/probe.lua` to use the fixed-timestep accumulator (same pattern as `src/client.lua:love.update`).
- Rebuild the Docker image after any `src/` changes: `docker build -t arena-server .`
- Review the staged `../Arena/Bem-vindo.md` deletion, then commit this work.
- Optional tuning if needed: reconcile margin is currently 2× RTT with a `walkSpeed*0.1` floor; could be raised if real two-client RTT is higher than 82 ms.

### Blocked on
- Final confirmation from the user that the rubber-banding is gone in real two-client play.

## Useful Commands & Resources
- Tests: `cd Game && "C:/Program Files/LOVE/lovec.exe" . --test`
- Connectivity probe: `cd Game && "C:/Program Files/LOVE/lovec.exe" . --probe`
- Build image: `cd Game && docker build -t arena-server .`
- Run server: `docker run --rm -d --name arena-server -p 27890:27890/udp arena-server`; logs: `docker logs -f arena-server`
- Run client (Windows): `"C:/Program Files/LOVE/love.exe" E:/Arena/Game`
- Spec: `Game/.pi/tickets/multiplayer/spec.md`
- Project instructions (mandatory `lovec.exe` workflow): `Game/AGENTS.md`
