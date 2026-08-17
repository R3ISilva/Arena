## Problem Statement

The Arena game currently supports only movement: players and spectators connect to a shared server, walk a grid arena via click-to-move, and see each other move. There is no combat — no abilities, no damage, and no health.

The user wants to introduce a reusable **ability system**: each ability lives in its own file and declares shared properties (name, cooldown, damage, type, sprites TBD), yet every ability is invoked the same way while internally handling its own animations and phases. The first concrete ability is "Morgana's Pool": a player aims within a range and places a damaging pool where they click, the ability is bound to one of the Q/W/E keys, players gain a health total, and stepping into a pool reduces that health. For now the pool is rendered as a purple circle.

## Solution

Introduce a **server-authoritative ability system** that mirrors the game's existing movement architecture. Abilities are pluggable modules with a common contract, loaded through a shared registry, and assigned to a player's Q/W/E slots via a **per-player loadout owned by the server** (future-proofing a pre-match selection screen).

Casting flows through the existing session seam as cast intents; the server simulates pool placement (clamped to range), cooldowns, damage ticks, and health, and syncs pools/health/cooldowns to clients via snapshots. Clients predict their own casts for instant feedback, render the purple pool, and show a League-style Q/W/E HUD plus health bars.

Input changes: **right-click moves**; **holding an ability key and left-clicking places the pool**. Morgana's Pool tuning: 200px cast range (clamped at the boundary), 6s cooldown from cast, 1s duration, 60px radius, ~30 damage/second ticked every 0.25s to anyone standing inside (including the caster), placeable over walls. Players have **100 display-only health** (0 HP has no consequence yet).

## User Stories

1. As a player, I want to hold an ability key (W by default) to enter aim mode, so that I can prepare a cast before committing.
2. As a player, I want a range indicator around my character while aiming, so that I can see how far my ability reaches.
3. As a player, I want to left-click while aiming to place the pool at the clicked location, so that I control exactly where it lands.
4. As a player, I want a click beyond my range to clamp the pool to my max range in the clicked direction, so that my cast always lands as close as possible to where I aimed.
5. As a player, I want to release the ability key to cancel aiming without casting, so that I never place a pool by accident.
6. As a player, I want right-click to move my character, so that movement and casting do not conflict.
7. As a player, I want my pool to appear immediately when I click (client prediction), so that casting feels responsive even over a network.
8. As a player, I want the server to be the source of truth for pool placement and damage, so that both players observe consistent results.
9. As a player, I want a 6-second cooldown after casting, so that the ability has meaningful pacing.
10. As a player, I want a cast attempt during the cooldown to be ignored, so that I cannot spam the ability.
11. As a player, I want to see my abilities in a Q/W/E HUD at the bottom of the screen, so that I know what is bound to each slot.
12. As a player, I want an ability slot to render greyed out with a countdown while on cooldown, so that I know exactly when it becomes ready again.
13. As a player, I want an empty ability slot to render as disabled, so that I know a key does nothing.
14. As a player, I want my abilities assigned to Q/W/E slots via a loadout, so that I can later select abilities before a match without any code change.
15. As a player, I want 100 starting health, so that I have a measurable life total.
16. As a player, I want my health displayed in a bar, so that I know my current life at a glance.
17. As a player, I want to see the enemy's health above their character, so that I can tell whether my pool is hurting them.
18. As a player, I want to take damage while standing inside any pool (including my own), so that pools are a genuine threat and I must avoid my own area.
19. As a player, I want damage applied in small ticks rather than one burst, so that briefly touching a pool deals only partial damage.
20. As a player, I want the pool to last exactly 1 second, so that it is a short-lived zoning tool.
21. As a player, I want the pool rendered as a translucent purple circle with a brighter outline, so that its danger area is clearly visible.
22. As a player, I want enemy pools to be visible on my screen, so that I can react to and avoid them.
23. As a player, I want overlapping pools (mine and the enemy's) to each deal damage independently, so that stacking them is meaningful.
24. As a player, I want to be able to place the pool over walls, so that terrain does not block an area-of-effect cast.
25. As a player, I want my health to never drop below 0, so that the health bar stays sane while damage continues.
26. As a spectator, I want to see pools and player health, so that I can follow the match.
27. As a spectator, I want cast and move intents to be ignored by the server, so that I cannot affect the game.
28. As a developer, I want each ability to live in its own file, so that adding an ability never requires editing engine code.
29. As a developer, I want every ability to expose the same lifecycle (create, cast, update, draw), so that the engine can drive any ability uniformly.
30. As a developer, I want ability properties (name, cooldown, damage, type, range, radius, duration) declared inside the ability file, so that tuning is localized next to the behavior.
31. As a developer, I want a shared ability registry used by both server and client, so that both sides load identical ability modules.
32. As a developer, I want the "type" property to be descriptive metadata only, so that each ability remains free to implement its own behavior without engine switch-cases.

## Implementation Decisions

**Architecture & authority**
- Ability simulation, damage, cooldowns, and health are **server-authoritative**, mirroring the existing movement authority: the server simulates, clients send intents and predict locally, and snapshots reconcile.
- Ability code is shared between server and client through a single **ability registry** that maps an ability id to its module and exposes load/get operations. The registry is the only new module boundary; server and client require the same registry so behavior is identical on both sides.
- The per-player **loadout** (`{ q, w, e } → abilityId`) is owned by the server and delivered to the client on `welcome`. Q/W/E are fixed slots; the ability→slot assignment is data, decoupling input from any specific ability. The MVP default loadout assigns `w = "morganapool"` with `q`/`e` empty; a future pre-match selection screen simply rewrites this loadout before the match.

**Ability contract**
- Each ability file exposes **static properties** — `name`, `cooldown`, `damage`, `type`, `range`, `radius`, `duration` (sprites TBD) — and a **uniform lifecycle**: create an instance, `cast(caster, x, y)` to start it, `update(dt)` to advance phases/ticks, and `draw()` to render. Each ability owns its own phase/animation state internally.
- `type` ("pool", "target", …) is descriptive metadata only; no engine dispatch is keyed off it in this iteration.

**Pure simulation (game layer)**
- The pure, network-agnostic simulation gains: per-player **health** (initialized to 100, clamped to a floor of 0, display-only — no death/respawn), per-player **loadout** and **per-slot cooldown** state, and a set of **active abilities/pools**.
- Casting in the simulation: resolve the slot's ability via the loadout, reject if the slot is empty or the ability is on cooldown, **clamp the target to the ability's range** from the caster, and instantiate the ability. The clamped coordinates are returned so the caller can echo the authoritative placement (mirroring `setTarget`'s clamp-and-return behavior).
- The simulation tick advances active abilities and applies **damage ticks**: every 0.25s a pool deals its per-tick damage to every player whose circle overlaps the pool's circle (center distance < pool radius + player radius), including the caster. Placement ignores obstacles.
- Morgana's Pool tuning (declared in its file): `cooldown = 6s` (starts on cast), `duration = 1s`, `radius = 60px`, `range = 200px`, `damage ≈ 30/sec` applied as 0.25s ticks.

**Session layer (the seam)**
- Inbound **`castIntent`** message `{ type = "castIntent", slot = "q"|"w"|"e", x, y }` is validated (known player, not a spectator, valid slot) and translated into a simulation cast. The client sends pre-clamped coordinates; the server re-clamps authoritatively.
- `welcome` gains the recipient's **loadout** (sent on the reliable channel 0). `castIntent` rides the unreliable channel 1, like `moveIntent`.
- Snapshots gain: **active pools** (id, position, radius, owner, remaining duration) so every client can render them; per-player **health**; and the local player's **per-slot cooldown remaining** so cooldown UI reconciles. Broadly, snapshot player entries gain `hp`, and the snapshot gains a `pools` list plus per-player cooldown state.

**Client layer**
- Input rebinding: **right-click = move** (move intent), **hold ability key + left-click = cast**. Holding the key shows a range ring around the local player; releasing cancels aim. Input is driven by the loadout received on `welcome`, never by hardcoded ability→key pairs.
- **Prediction + reconciliation**: the client optimistically spawns its own pool (deterministically clamped, so it matches the server) and starts a local cooldown on cast; authoritative snapshot pool/health/cooldown data reconciles the local view, mirroring how movement prediction reconciles today.
- Rendering: pools draw as a translucent purple filled circle with a brighter purple outline (radius = damage radius), above the grid/obstacles and below player markers so player tokens stay readable. Pool/HUD colors are added to the existing color config alongside the other color definitions.
- HUD (League-style, bottom-center): Q/W/E boxes with states `ready`, `cooldown` (greyed out with a numeric countdown), and `empty`/`disabled`. The local player's health bar sits above the ability boxes; the enemy's health renders as a small overhead bar above their character.

## Testing Decisions

**Seam**
- The feature is tested through the **existing transport-agnostic session seam** — the highest seam in the codebase and the one already exercised by the headless suite. No new seam is introduced. Ability behavior is observed via `onConnect`/`onMessage`/`tick` plus `getState`/`drainOutbox`, exactly as movement is tested today. Pure ability simulation is additionally unit-tested directly against the simulation layer, matching the existing "pure simulation (no network)" test section.

**What makes a good test**
- Tests assert **external behavior** only: a cast clamps to range, a recast within cooldown is rejected, a pool spawns and expires after its duration, a player standing in a pool loses health, health syncs in snapshots, and spectators/empty slots produce no effect. No test reaches into internal phase/animation state or implementation details.

**Modules tested**
- **Ability registry**: loads the morganapool module and exposes its declared properties.
- **Pure simulation**: cast clamp-to-range, cooldown enforcement, pool lifecycle (spawn → tick → expire), damage ticks reduce health, health floor at 0, loadout slot resolution.
- **Session (server mode)**: `castIntent` spawns an authoritative pool; cooldown blocks recast; snapshots include pools/health/cooldowns; cast intents from spectators and empty slots are ignored; disconnect cleans up a player's active abilities.
- **Session (client mode)**: a local cast predicts its pool and cooldown immediately; snapshot reconciliation corrects pool/health/cooldown state.
- **Headless two-client diagnostic**: both clients cast, exercising real network edge cases (out-of-range clamp, cooldown blocking, health loss observed through snapshots).
- **Windowed two-client diagnostic**: auto-drives casting and verifies pools and health bars render while maintaining zero reconciliation snaps.

**Prior art**
- The headless session suite (currently 18 tests) is the direct template for the new unit/integration tests: fixtures build a config, `newServerSession`/`newClientSession` drive the seam, and assertions use the local assert helpers.
- The headless two-client diagnostic and the windowed two-client diagnostic are the templates for the networked casting/life-loss checks; they already instrument reconciliation and assert health invariants (currently zero snaps, which should remain true for predicted casts).

## Out of Scope

- Sprite/animation assets for abilities (the "sprites TBD" property); the purple circle is the placeholder rendering.
- The pre-match ability selection UI/screen itself — only the per-player loadout structure that makes it possible is introduced.
- More than one ability (only `morganapool` is implemented).
- Death/respawn mechanics — health is display-only; 0 HP has no consequence.
- Mana or any resource beyond cooldown; ability leveling/skill points; itemization.
- Obstacle-aware area-of-effect placement (pools deliberately ignore walls for now).
- More than two player slots, teams, or any match/round lifecycle.
- Audio/SFX.
- Rebindable movement/cast keys (keys are fixed; only ability→slot assignment is data-driven).

## Further Notes

- The `type` property is metadata only for this iteration; revisit if a future ability genuinely needs engine-level dispatch.
- Cooldown countdown display format (e.g. one decimal place) is a cosmetic detail left to the implementer; the HUD states (`ready` / `cooldown` / `empty`) are the contract.
- The hold-key aim state (with range ring) is the first step toward richer aim indicators and cast-time phases in future abilities.
- Server-dependent tests (`--twoclient`, `--twoclientwin`, `--probe`) require "the pick" (the Docker server) to be up via the arena-server skill scripts; the headless `--test` suite needs no server.
- Deterministic clamping on both client and server is what keeps predicted pools from causing reconciliation snaps — this should be preserved in tests.