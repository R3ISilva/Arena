# Arena — Tests

All of these exercise Arena's networking/game logic over a real LÖVE runtime.
The first three are **headless** (console, `lovec.exe`, no windows, print + exit
with a code). The last one — the *"with head"* test — opens **real GUI windows**
and is meant to be seen, not run in a CI loop.

> **Server note:** everything except `--test` talks to *the pick* (the Docker
> server on `127.0.0.1:27890`). Bring it up first with the arena-server skill
> scripts:
> ```bash
> bash .pi/skills/arena-server/scripts/docker-run.sh     # bring up
> bash .pi/skills/arena-server/scripts/docker-stop.sh    # tear down
> ```
> The `--twoclientwin` "with head" test starts the server itself.

Exit codes: `0` = pass, `1` = fail.

---

## 1. `--test` — headless session suite (**run_tests.lua**)

The main automated suite: 40 unit/integration tests over the transport-agnostic
`session` module — no network needed. Covers slot assignment, spawn points,
server movement authority, snapshot emission/sequencing, disconnect recovery,
client prediction/validation, reconciliation vs RTT, remote interpolation,
spectator behavior, and the server-authoritative ability system (registry,
cast clamp-to-range, cooldown enforcement, pool lifecycle/damage ticks, health
floor, loadout resolution, cast intent handling, and client prediction of casts).

```bash
"C:/Program Files/LOVE/lovec.exe" . --test
```
Bar: `40 passed, 0 failed` / `ALL TESTS PASSED`, exit 0.

## 2. `--probe` — live connectivity probe (**probe.lua**)

One real ENet client connects to the pick for ~4s and reports what it received
(connected state, slot, snapshot seq, latency, player positions). A quick sanity
check that the network path works against a live server.

```bash
"C:/Program Files/LOVE/lovec.exe" . --probe
```
Bar: `PROBE PASSED`.

## 3. `--twoclient` — headless two-client diagnostic (**twoclient.lua**)

Two real ENet clients (no windows) connect to the pick, both click-to-move across
the arena and cast Morgana's Pool (self-casts to take damage + far casts to
exercise the range clamp) for ~15s. Each reports RTT, predicted-vs-authoritative
divergence, reconciliation snap count, and ability telemetry (casts sent, pools
seen, damage taken). A healthy run shows **zero snaps** (no rubber-banding) with
both clients casting, seeing pools, and taking damage.

```bash
"C:/Program Files/LOVE/lovec.exe" . --twoclient
```
Bar: both `snaps=0`, exit 0.

## 4. `two-client-with-head-test/` — windowed live test (**run only when you want to SEE it**)

>The **"with head"** test opens two real GUI windows and runs a live network
>session for ~12s. It is **not** a headless assertion — run it **only when you
>want to watch the test in action** (two windows render the arena and the players
>move by themselves). For automated CI-style checking, prefer `--twoclient`
>(#3) which asserts the same invariants without windows.

This self-contained folder holds the launcher (`twoclientwin.sh`) and the
auto-drive client it launches twice (`twoclientclient.lua`). It brings the pick
up itself, opens **two** GUI windows that auto-drive click-to-move and cast
Morgana's Pool (rendering the purple pools + overhead health bars), and after
~12s both windows **close themselves** and the launcher asserts both moved,
cast, saw pools, and took damage with zero snaps.

```bash
bash tests/two-client-with-head-test/twoclientwin.sh            # stops the server after
bash tests/two-client-with-head-test/twoclientwin.sh --keep     # leaves the server up
```
Bar: `TWO-WINDOW DIAGNOSTIC PASSED`, exit 0.

Env overrides: `TWOCLIENTWIN_DURATION` (seconds each window runs) and
`TWOCLIENTWIN_TIMEOUT` (max seconds to wait for both windows to report).

Result/telemetry files land in `two-client-with-head-test/.out/` (runtime output,
git-ignored, wiped each run).

---

### Order of preference / quick decision guide

| Want to | Run |
|---|---|
| Fast, deterministic regression check | `--test` |
| Confirm the network path to a live server | `--probe` |
| Assert two-client networking w/o windows (CI) | `--twoclient` |
| Actually see two windows move + test live networking | `two-client-with-head-test/twoclientwin.sh` |
