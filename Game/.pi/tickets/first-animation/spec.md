## Problem Statement

The Arena game's Bear Trap ability is rendered as a pulsing colored circle — a placeholder. The first real in-world animation is ready: a 20-frame flytrap sprite sheet. Players should see the trap visibly open as it arms, sit fully open while armed, and snap shut + fade out when it catches someone (or when it times out).

Today that is impossible without changing the simulation: the engine removes a triggered trap on the same tick it fires, so there is no window for a "snap + fade" animation. The sprite sheet is also not loaded or sliced anywhere, and the placeholder rendering (a pulsing circle) contains no sprite awareness.

## Solution

Replace the circle placeholder with the flytrap sprite animation. Drive the trap through an explicit three-phase visual lifecycle — arming → armed → despawning — mapped to the sprite sheet frames. Add a brief "despawning" linger after a trigger and after natural expiry so the snap-shut and fade-out can be seen, while keeping the stun (applied instantly on overlap) and all balance tuning identical.

The animation state becomes part of the shared simulation and its snapshots, so every client and spectator renders the same animation, and the state stays deterministic for client prediction and reconciliation. The sprite is loaded lazily on the client only (the dedicated server runs with graphics disabled).

## User Stories

1. As a player who places a trap, I want the flytrap to visibly open from closed (frames 13→7) during the 0.75s arming window, so that I can see it becoming ready.
2. As a player, I want the trap to look different while arming than while armed, so that I know it cannot trigger yet.
3. As a player, I want the trap to hold the fully-open pose (frame 6) once armed, so that I can tell at a glance it is live.
4. As a player, I want an armed trap to sit perfectly still on frame 6, so that it reads clearly as "set" without distracting motion.
5. As a player, I want armed traps to be clearly visible in the world, so that I can avoid them.
6. As a victim, I want the trap to snap shut fast (frames 6→0) the instant I step on it, so that the catch feels immediate and punchy.
7. As a victim, I want to be stunned at the exact moment I trigger the trap, so that gameplay feedback is instant even though the animation continues.
8. As a victim, I want the closed trap to fade out after snapping shut, so that it reads as despawning rather than disappearing abruptly.
9. As a player (both caster and victim), I want the triggered trap to linger briefly while it snaps and fades, so that the animation is actually visible instead of the trap vanishing in one frame.
10. As a player, I want a triggered trap to be single-use and never re-trigger during its despawn, so that I cannot be double-stunned by the same trap.
11. As a player, I want a trap whose 30s timer runs out to snap and fade out like a triggered one, so that expiry looks intentional rather than like a pop-in artifact.
12. As a player, I want the flytrap drawn at 40×40 px (the same size as the old placeholder circle), so that the world's visual scale does not change.
13. As a player, I want enemy traps to animate identically on my screen, so that what I see matches the shared game state.
14. As a spectator, I want to see traps arm, snap, and fade, so that I can follow the action.
15. As a player, I want my predicted trap to animate immediately when I cast, so that casting feels responsive over the network.
16. As a player, I want the trap's 20px trigger radius and 2s stun to remain unchanged, so that this visual change does not alter balance.
17. As a player, I want the trap to remain non-triggerable while it is still opening, so that it only catches me once it is fully armed.
18. As a developer, I want the flytrap sheet sliced as a 5×4 grid of 320px tiles (frames 0–13; 14–19 empty), so that the animation maps correctly to the art.
19. As a developer, I want the trap animation driven by simulation timers rather than wall-clock time, so that predicted and authoritative states stay bit-for-bit identical.
20. As a developer, I want the flytrap atlas loaded lazily on the client only, so that the headless server (which has no graphics module) keeps working.

## Implementation Decisions

**Frame map (0-indexed, row-major across 5 columns of a 5×4 grid of 320px tiles; frames 14–19 empty)**
- 13 = fully closed (arming start)
- 12, 11, 10, 9, 8 = opening
- 7 = open (last arming frame)
- 6 = fully open (armed/ready)
- 5, 4, 3, 2, 1 = closing
- 0 = fully closed (snap end)

**State machine** (replaces the current implicit "arming → armed → instantly removed" flow):
- `arming` → `armed` → `despawning` → removed (active=false)
- arming: not triggerable; advance armRemaining; when it reaches 0, enter armed.
- armed: triggerable (radius 20); advance lifetime remaining; on overlap OR when remaining reaches 0, enter despawning (despawnRemaining = 0.45).
- despawning: not triggerable; advance despawnRemaining; when it reaches 0, set active=false so the engine's existing removal sweep drops it.

**Timing constants** (declared in the trap module, next to existing tuning):
- armDelay = 0.75 (existing, drives arming)
- snapDuration = 0.15 (the "close fast" step)
- fadeDuration = 0.3 (the alpha dissolve)
- despawnDuration = 0.45 (sum; the linger window)

**Frame selection — pure function of simulation timers (never wall-clock):**
- arming: frame = round(lerp(13, 7, 1 − armRemaining/armDelay))
- armed: frame = 6
- despawning, snap sub-phase (elapsed < snapDuration): frame = round(lerp(6, 0, elapsed/snapDuration)), alpha = 1
- despawning, fade sub-phase (elapsed ≥ snapDuration): frame = 0, alpha = 1 − (elapsed − snapDuration)/fadeDuration

**Simulation change (the single behavioral change):** the overlap trigger pass now invokes the trap's trigger hook to start the despawn phase instead of setting active=false directly. It also skips traps already in the despawning phase (preserving single-use; only the first overlapping non-stunned player is stunned). The stun still applies at the instant of overlap.

**Snapshot/network contract:** the trap's getSnapshot/applySnapshot gain the despawn state (phase and/or despawnRemaining) so remote clients reconstruct and render the same snap+fade. The existing snapshot plumbing (abilities list → getSnapshot/applySnapshot) carries it through unchanged; the session layer needs no new messages.

**Rendering:** draw the flytrap sprite at 40×40 px (scale 0.125 from 320px tiles), centered on the trap's position, no rotation. Alpha is applied via the draw color. The pulsing-circle placeholder (and its wall-clock pulse) is removed entirely.

**Sprite loading:** the sprite atlas is loaded lazily inside the draw path (never at module load), because the trap module is loaded by the headless server where the graphics module is disabled. The shared sprite helper is extended to support an arbitrary tile size (320px) so a frame index can be mapped to its quad via col = frame % 5, row = floor(frame / 5).

## Testing Decisions

**Seams:** the feature is tested through the two existing seams, and no new seam is introduced — (1) the pure, network-agnostic simulation for trap lifecycle/trigger behavior, and (2) the transport-agnostic session seam for snapshot content and client prediction/reconciliation. This is exactly how the existing bear-trap tests are written, and it is the highest seam available in the codebase.

**What makes a good test:** assert external, observable behavior only — trap active count, stun state, removal timing, and snapshot fields. Do not reach into frame indices, sprite loading, or draw internals (the headless suite runs with no graphics).

**Tests to update:**
- "armed trap stuns the first player to overlap it and is consumed" — after trigger the trap is now still counted as active (despawning) for ~0.45s and only then removed; the assertion changes from "consumed on trigger" to "stuns instantly, lingers during despawn, then is removed".
- "trap expires after its duration" — removal now happens at ~30.45s (30s + 0.45s despawn); the existing ~31s assertion still holds, but an intermediate assertion should verify the trap entered despawning rather than vanishing instantly at 30s.

**Tests to add:**
- A triggered trap stuns instantly, remains counted as active during despawn, and is removed after ~0.45s.
- A despawning trap does not re-trigger: a second player stepping on it during despawn is not stunned, and the trap is consumed exactly once.
- Natural expiry enters the same despawn phase (trap counted active at 30s, removed at ~30.45s).
- Snapshots carry the despawn state so a remote client can reconstruct the despawn animation (assert the despawn field round-trips through getSnapshot/applySnapshot and appears in the serialized abilities list).
- Client prediction: a locally predicted trap that triggers enters despawn, and snapshot reconciliation preserves it.
- Determinism: extend the existing "beam and trap simulation is deterministic across two sessions" test to cover the full arming → trigger → despawn → removal lifecycle, ensuring two identical sessions produce identical state.

**Prior art:** the existing beartrap tests (arming, cap, single-use, expiry, determinism) and the session snapshot assertions (e.g. checking `state.abilities[i].armed`) are the direct templates. The registry/snapshot tests already validate the ability-module contract this feature extends.

## Out of Scope

- The HUD ability icon (still the separate abilities_tilemap.png tile); the flytrap sheet animates only the in-world trap.
- Audio/SFX for the snap or any other event.
- Any change to balance tuning: trigger radius (20), stun duration (2s), cooldown (6s), arm delay (0.75s), duration (30s), per-owner cap (4), or cast root (0.5s).
- Animations for the other abilities (beam, pool, stun projectile) — they keep their current placeholder circles.
- Frames 14–19 of the sheet (empty) and the unrelated missile_tilemap.png.
- Rotation/orientation of the sprite (the trap is symmetric/top-down).
- A separate "victim caught" visual beyond the trap's own snap+fade.
- Death/respawn, new abilities, or any match/round lifecycle changes.

## Further Notes

The original "6→13 disappearing" reading of the sheet was superseded during design; the fade is a pure alpha dissolve, not a frame-based fade. The corrected mapping is 13→7 (arming), 6 (ready), 6→0 (snap shut), with 0 and 13 both representing the closed pose.

There is a one-frame visual step from 7 to 6 at the exact moment the trap arms; this is intentional (7 is the last "opening" frame, 6 is the distinct "ready" pose) and both are open poses, so the step is negligible.

Because natural expiry now plays the 0.45s despawn animation, a trap's effective lifetime is 30.45s. This is considered acceptable and is captured by the expiry test.

The trapArming/trapArmed/trapOutline color entries become unused once the circle placeholder is removed and can be cleaned up from the config.

The existing "stun during a cancelable windup cancels + refunds" logic is unaffected: the trap is not cancelable, and its trigger path is orthogonal to the charging-ability cancellation sweep.