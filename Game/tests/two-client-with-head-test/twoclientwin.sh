#!/usr/bin/env bash
# twoclientwin.sh — two-window, live-network diagnostic for Arena.
#
# Colocated with its companion windowed client (twoclientclient.lua) under
# tests/two-client-with-head-test/. This launcher drives that client as two real
# GUI love.exe windows against the pick (the Docker server), auto-drives each into
# a close-range orbit/strafe duel — both move and place Morgana's Pool on each other —
# and asserts:
#   * both clients connect as live players and receive snapshots
#   * both players actually move
#   * zero reconciliation snaps (no rubber-banding)
#   * both cast pools/beams and place traps, and take pool damage
#   * both observe stuns
#   * at least one player's health reaches 0 within the test window
#
# Unlike --twoclient (headless lovec.exe), each client is a real windowed process,
# so you can watch the arena render and the players move, then both windows close
# themselves and the launcher exits 0 (healthy) or 1 (failed).
#
# Prereqs: Docker running (the pick) and LÖVE installed at $LOVE_DIR.
#
# Uses:
#   ./twoclientwin.sh [--keep]     run; --keep leaves the server up afterwards
#   exit 0 = healthy, 1 = failure/snapping, 127 = deps missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_SCRIPTS="$GAME_DIR/.pi/skills/arena-server/scripts"

LOVE_DIR="${LOVE_DIR:-C:/Program Files/LOVE}"
LOVE_EXE="$LOVE_DIR/love.exe"
# Runtime output (per-client telemetry + result files) is a game-test artifact;
# keep it colocated with this test rather than polluting a pi-specific dir.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$TEST_DIR/.out"
DURATION="${TWOCLIENTWIN_DURATION:-30}"   # seconds each window runs before self-close
TIMEOUT="${TWOCLIENTWIN_TIMEOUT:-60}"     # seconds to wait for both windows to report

KEEP_SERVER=0
if [[ "${1:-}" == "--keep" ]]; then
    KEEP_SERVER=1
fi

if [[ ! -f "$LOVE_EXE" ]]; then
    echo "ERROR: LÖVE not found at '$LOVE_EXE' (set LOVE_DIR)." >&2
    exit 127
fi

echo "== Arena two-window diagnostic =="

# --- Server must be up (the pick) --------------------------------------------
if ! bash "$SERVER_SCRIPTS/docker-check.sh" >/dev/null 2>&1; then
    echo "ERROR: Docker is not running. Start Docker Desktop, then retry." >&2
    exit 127
fi

if ! docker ps --format '{{.Names}}' | grep -qx arena-server; then
    echo ">> Pick not up — starting it via docker-run.sh ..."
    bash "$SERVER_SCRIPTS/docker-run.sh"
    # Let the freshly-started server settle a beat before the clients hammer it,
    # so its first-tick warm-up doesn't show up as a client-side reconciliation snap.
    sleep 2
fi

# --- Clear stale results from a previous run ----------------------------------
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo ">> Starting two windowed clients against 127.0.0.1:27890 ..."
"$LOVE_EXE" "$GAME_DIR" --twoclientwin:child 1 --id 1 --duration "$DURATION" --out "$OUT_DIR" &
"$LOVE_EXE" "$GAME_DIR" --twoclientwin:child 2 --id 2 --duration "$DURATION" --out "$OUT_DIR" &

# --- Wait for both result files (the windows self-close after DURATION) -------
elapsed=0
ok1=0
ok2=0
while [[ $elapsed -lt $TIMEOUT ]]; do
    [[ -f "$OUT_DIR/client1.txt" ]] && ok1=1
    [[ -f "$OUT_DIR/client2.txt" ]] && ok2=1
    if [[ $ok1 -eq 1 && $ok2 -eq 1 ]]; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [[ $ok1 -ne 1 || $ok2 -ne 1 ]]; then
    echo "ERROR: timed out waiting for windowed clients to report results (elapsed ${elapsed}s)." >&2
    echo "  reported: client1=$ok1 client2=$ok2$([[ $elapsed -ge $TIMEOUT ]] && echo ' (TIMEOUT)')" >&2
    echo "  server logs:" >&2
    docker logs arena-server --tail 15 >&2 || true
    exit 1
fi

# --- Aggregate + assert ---------------------------------------------------------
echo
read_kv() { sed -n "s/^$2=//p" "$1" | tr -d '\r'; }

moved1=$(read_kv "$OUT_DIR/client1.txt" moved)
moved2=$(read_kv "$OUT_DIR/client2.txt" moved)
snaps1=$(read_kv "$OUT_DIR/client1.txt" snaps)
snaps2=$(read_kv "$OUT_DIR/client2.txt" snaps)
samples1=$(read_kv "$OUT_DIR/client1.txt" samples)
samples2=$(read_kv "$OUT_DIR/client2.txt" samples)
casts_w1=$(read_kv "$OUT_DIR/client1.txt" casts_w)
casts_w2=$(read_kv "$OUT_DIR/client2.txt" casts_w)
casts_q1=$(read_kv "$OUT_DIR/client1.txt" casts_q)
casts_q2=$(read_kv "$OUT_DIR/client2.txt" casts_q)
casts_e1=$(read_kv "$OUT_DIR/client1.txt" casts_e)
casts_e2=$(read_kv "$OUT_DIR/client2.txt" casts_e)
saw_pool1=$(read_kv "$OUT_DIR/client1.txt" saw_pool)
saw_pool2=$(read_kv "$OUT_DIR/client2.txt" saw_pool)
saw_beam1=$(read_kv "$OUT_DIR/client1.txt" saw_beam)
saw_beam2=$(read_kv "$OUT_DIR/client2.txt" saw_beam)
saw_trap1=$(read_kv "$OUT_DIR/client1.txt" saw_trap)
saw_trap2=$(read_kv "$OUT_DIR/client2.txt" saw_trap)
saw_stun1=$(read_kv "$OUT_DIR/client1.txt" saw_stun)
saw_stun2=$(read_kv "$OUT_DIR/client2.txt" saw_stun)
took_damage1=$(read_kv "$OUT_DIR/client1.txt" took_damage)
took_damage2=$(read_kv "$OUT_DIR/client2.txt" took_damage)
reach_zero1=$(read_kv "$OUT_DIR/client1.txt" reach_zero)
reach_zero2=$(read_kv "$OUT_DIR/client2.txt" reach_zero)
min_hp1=$(read_kv "$OUT_DIR/client1.txt" min_hp)
min_hp2=$(read_kv "$OUT_DIR/client2.txt" min_hp)

for id in 1 2; do
    f="$OUT_DIR/client$id.txt"
    slot=$(read_kv "$f" slot)
    div=$(read_kv "$f" max_divergence)
    rtt=$(read_kv "$f" rtt_ms)
    if [[ "$id" == "1" ]]; then
        s_moved=$moved1; s_snaps=$snaps1; s_samples=$samples1; s_cw=$casts_w1; s_cq=$casts_q1; s_ce=$casts_e1; s_pool=$saw_pool1; s_beam=$saw_beam1; s_trap=$saw_trap1; s_stun=$saw_stun1; s_dmg=$took_damage1; s_zero=$reach_zero1; s_minhp=$min_hp1
    else
        s_moved=$moved2; s_snaps=$snaps2; s_samples=$samples2; s_cw=$casts_w2; s_cq=$casts_q2; s_ce=$casts_e2; s_pool=$saw_pool2; s_beam=$saw_beam2; s_trap=$saw_trap2; s_stun=$saw_stun2; s_dmg=$took_damage2; s_zero=$reach_zero2; s_minhp=$min_hp2
    fi
    echo "client$id: slot=$slot rtt=${rtt}ms divergence=${div}px snaps=$s_snaps snapshots=$s_samples moved=$s_moved castW=$s_cw castQ=$s_cq castE=$s_ce saw_pool=$s_pool saw_beam=$s_beam saw_trap=$s_trap saw_stun=$s_stun took_damage=$s_dmg min_hp=${s_minhp} reach_zero=$s_zero"
done

echo "duel outcome: min_hp1=$min_hp1 min_hp2=$min_hp2 reach_zero1=$reach_zero1 reach_zero2=$reach_zero2"

healthy=1
[[ "$moved1" == "true" && "$moved2" == "true" ]] || { healthy=0; echo ">> FAIL: a client did not move"; }
[[ "$snaps1" == "0" && "$snaps2" == "0" ]] || { healthy=0; echo ">> FAIL: a client snapped (rubber-banding)"; }
[[ "$samples1" -gt 0 && "$samples2" -gt 0 ]] || { healthy=0; echo ">> FAIL: a client received no snapshots"; }
[[ "$casts_w1" -gt 0 && "$casts_w2" -gt 0 ]] || { healthy=0; echo ">> FAIL: a client did not cast a pool"; }
[[ "$casts_q1" -gt 0 && "$casts_q2" -gt 0 ]] || { healthy=0; echo ">> FAIL: a client did not cast a beam"; }
[[ "$casts_e1" -gt 0 && "$casts_e2" -gt 0 ]] || { healthy=0; echo ">> FAIL: a client did not place a trap"; }
[[ "$saw_pool1" == "true" && "$saw_pool2" == "true" ]] || { healthy=0; echo ">> FAIL: a client never rendered a pool"; }
[[ "$saw_beam1" == "true" && "$saw_beam2" == "true" ]] || { healthy=0; echo ">> FAIL: a client never rendered a beam"; }
[[ "$saw_trap1" == "true" && "$saw_trap2" == "true" ]] || { healthy=0; echo ">> FAIL: a client never rendered a trap"; }
[[ "$saw_stun1" == "true" && "$saw_stun2" == "true" ]] || { healthy=0; echo ">> FAIL: a client never observed a stun"; }
[[ "$took_damage1" == "true" && "$took_damage2" == "true" ]] || { healthy=0; echo ">> FAIL: a client never took damage"; }
if [[ "$reach_zero1" == "true" || "$reach_zero2" == "true" || "$min_hp1" == "0" || "$min_hp2" == "0" ]]; then
    echo ">> a player reached 0 HP (combat resolved)"
else
    healthy=0; echo ">> FAIL: no player reached 0 HP within ${DURATION}s"
fi

echo
if [[ $healthy -eq 1 ]]; then
    echo "TWO-WINDOW DIAGNOSTIC PASSED: one player reached 0 HP, both dueled with pools/beams/traps + stuns, zero reconciliation snaps (no rubber-banding)"
else
    echo "TWO-WINDOW DIAGNOSTIC FAILED"
fi

if [[ $KEEP_SERVER -eq 1 ]]; then
    echo ">> Leaving the pick running per --keep."
else
    echo ">> Stopping the pick."
    bash "$SERVER_SCRIPTS/docker-stop.sh" >/dev/null
fi

[[ $healthy -eq 1 ]]
