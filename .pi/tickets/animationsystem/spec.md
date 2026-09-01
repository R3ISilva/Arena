## Problem Statement

The game is a LÖVE 2D, Lua, ENet arena game built on a deterministic client/server simulation: the same simulation runs on the dedicated (headless) server as authority and on every client as prediction, and ability visuals are expected to be bit-for-bit identical everywhere. Today "animation" is not a system at all — it is a per-ability contract in which each ability exposes a phase state machine plus timers, and its draw code renders the phase by hand. Only one ability (Bear Trap) has real sprite animation, and its frame index and alpha are computed with manual, bespoke math inside the ability module. Beam, Morgana's Pool, and Morgana's Stun are drawn with primitive shapes. The user wants League-of-Legends-style ability animations, but there is no reusable mechanism to author them safely: adding any new visual means re-deriving timing math per ability, and any slip risks violating the determinism contract that keeps predicted and authoritative visuals identical across the network.

## Solution

Introduce a small, reusable animation engine offering three primitives — sprite-sheet clips, numeric tweens, and a timeline that composes them — that abilities opt into by declaring an animation spec as inline Lua data beside their existing tuning. The engine is a pure, side-effect-free evaluator: given a spec and elapsed time (derived from the existing simulation phase timers), it returns the pose (frame, rotation, scale, alpha) plus any cosmetic events crossed. It runs only on the client at draw time, never on the headless server, and never changes the network protocol or snapshot schema. Bear Trap is migrated first, producing byte-identical frame/alpha output to today's hand-rolled math, and gains a cosmetic brown dust burst when it snaps shut. Abilities without a spec keep their primitive rendering, marked with a comment for future migration. A minimal client-local particle emitter powers the dust burst and future effects.

## User Stories

1. As a developer, I want a reusable sprite-clip primitive, so that I can play a frame sequence from a sprite sheet without hand-writing frame-index math in every ability.
2. As a developer, I want a numeric tween primitive with easing curves, so that I can animate position, rotation, scale, alpha, and color declaratively.
3. As a developer, I want a timeline primitive that composes clips, tweens, and events in sequence and in parallel, so that a multi-stage animation is expressed as one spec rather than scattered update logic.
4. As a developer, I want to declare an ability's animation as inline Lua data beside its tuning, so that a visual and the behavior it animates live in one place.
5. As a developer, I want a loader abstraction in front of animation specs, so that I can swap in a JSON or other data format later without rewriting abilities.
6. As a developer, I want the engine to be a pure function of simulation timers, so that predicted and authoritative visuals stay identical on every machine.
7. As a developer, I want the engine to make no calls to wall-clock time or random numbers, so that its output is deterministic.
8. As a developer, I want the engine to have no graphics dependency, so that the headless server can keep loading ability modules without rendering anything.
9. As a developer, I want the engine to be evaluated only on the client, so that the wire keeps carrying phase and timers rather than frame numbers or poses.
10. As a developer, I want an optional animation spec with a primitive-rendering fallback, so that Beam, Morgana's Pool, and Morgana's Stun keep drawing exactly as they do today.
11. As a player, I want Bear Trap to animate exactly as before — closed pod opening while arming, held open while armed, snap shut and fade while despawning — so that nothing regresses.
12. As a player, I want a burst of small brown pixels to fly across the ground when the trap snaps shut, so that the catch reads as a physical event.
13. As a developer, I want Bear Trap's existing frame and alpha accessors to remain stable pure functions, so that existing callers and snapshot reconciliation keep working unchanged.
14. As a developer, I want Bear Trap's migration to produce byte-identical frame and alpha values to the old hand-rolled math, so that the refactor is provably safe.
15. As a developer, I want cosmetic events to be returned by the evaluator rather than fired inside it, so that the engine stays pure and the client decides what an event spawns.
16. As a developer, I want a minimal client-local particle emitter, so that the trap dust burst and future effects share one mechanism.
17. As a developer, I want particle spawns to be driven by deterministic simulation state while particle motion runs on wall-clock, so that visuals feel fluid without becoming part of the simulation.
18. As a test engineer, I want a headless test that asserts the engine and Bear Trap outputs are deterministic, so that a regression is caught without opening a window.
19. As a developer, I want the new engine and particle modules to be loadable in the existing headless test harness, so that tests run through the current test entry point.
20. As a developer, I want the migration to keep the network protocol unchanged, so that no client/server compatibility work is required.
21. As a developer, I want the trap dust burst to be a self-healing cosmetic, so that a rare snapshot rollback at most produces a spurious puff rather than any gameplay inconsistency.
22. As a player, I want the stun ring, click effects, and primitive ability visuals to be unaffected, so that the change is invisible except for the trap's new dust.
23. As a developer, I want clips to support loop and ping-pong playback, so that repeating or cycling effects do not need custom code.
24. As a developer, I want a documented set of easing curves, so that tweens can be authored predictably without reverse-engineering timing math.

## Implementation Decisions

- Build a new animation engine module that is pure and deterministic: it exposes clip, tween, and timeline evaluation plus easing functions, and makes no calls to LÖVE graphics, wall-clock time, or random number generation. It is evaluated only by the client renderer.
- Build a new client-local particle emitter module with a pure advance step (update positions/velocities/lifetimes) and a separate draw step; the draw step is the only part that touches graphics.
- Modify the Bear Trap ability module to declare an animation spec (one entry per phase: arming, armed, despawning) and to make its existing frame and alpha accessors thin wrappers over the engine evaluator, preserving their exact outputs and public signatures.
- Modify the client renderer to host the particle emitter, advance and draw particles each frame, and consume the cosmetic events reported by the evaluator to spawn the trap dust burst.
- Leave the ability registry, the simulation, the session layer, and the network protocol completely unchanged. No snapshot schema changes and no config changes.
- Animation spec shape: a spec maps a phase name to either a clip (a frame sequence plus a duration or per-frame timing and a loop/ping-pong flag), a tween (a from value, a to value, a duration, an easing name, and a target property), or a timeline (an ordered set of tracks, each a clip, tween, or event with a start offset; tracks at the same offset run in parallel).
- Easing set for v1: linear, quad (in/out/in-out), cubic, sine, and exponential; elastic and back curves are deferred until a concrete need arises.
- Determinism contract: the evaluator is a pure function of the spec, the phase, and elapsed time; it never reads wall-clock or randomness; the server never evaluates it. Frame and alpha are always derived from simulation timers and are never stored on the wire.
- Event semantics: events are cosmetic-only. The evaluator returns the events whose timestamps fall within a (fromElapsed, toElapsed] window; the client tracks the last evaluated time per ability instance (keyed by ability id and phase) and applies newly crossed events. Because events are cosmetic, imperfect tracking under snapshot reconciliation (at worst a spurious or missing particle puff) is acceptable and self-healing.
- Bear Trap dust burst: triggered by the despawning phase's snap-completion event; it spawns a small burst of brown one-pixel particles that fly outward along the ground and fade out. Its count, speed, color, and lifetime are tuning values declared beside the Bear Trap spec so they can be tuned without touching engine code.
- Migration note: Beam, Morgana's Pool, and Morgana's Stun keep their primitive drawing and receive a comment that future sprite art should migrate them to the animation spec. The missile sprite sheet is ignored entirely.

## Testing Decisions

- Good tests assert external, observable behavior only: given a spec and elapsed time, the evaluator returns the expected pose, alpha, and events; Bear Trap's frame and alpha accessors return the same values as the pre-migration golden values across arming, armed, and despawning (including the snap sequence and fade); and two instances with identical simulation state produce identical output. Tests must not reach into internal helper tables.
- Primary seam: the pure evaluator and the pure particle-advance function are the single seam under test, exercised headlessly through the existing test harness (run via the console build with the test flag). No graphics, no network, no window.
- Modules tested: the animation engine (clip, tween, and timeline evaluation; easing; event crossing), the Bear Trap migration (golden frame/alpha values and the snap/fade timing), the particle emitter (advance and expiry), and determinism (two identical runs yield identical output).
- Prior art: the existing headless suite uses simple test registration plus equality and near-equality assertions, and already contains determinism tests such as "movement is deterministic across two identical sessions", "beam and trap simulation is deterministic across two sessions", and "morganastun projectile simulation is deterministic across two games". Follow the same pattern.
- Follow the project workflow: run the console build first to catch Lua errors, then the GUI build to confirm the trap animation and dust burst visually.

## Out of Scope

- Player character animation (walk, attack, or cast cycles); players remain plain circles.
- A full particle engine (spawn-rate emitters, blend modes, textured quads, or projectile trails).
- Migrating Beam, Morgana's Pool, or Morgana's Stun to sprite animation; they keep primitive rendering with a future-migration comment.
- Gameplay or simulation events (damage, hits, or effects fired at a keyframe); events are cosmetic-only.
- A JSON or external animation data format; only a loader abstraction is provided, and no JSON loader is built.
- Any change to the network protocol or snapshot schema.
- Animation authoring tooling or editors.
- Use of the missile sprite sheet, which is ignored entirely.

## Further Notes

- The engine must remain free of wall-clock time and random-number calls to preserve determinism; the only wall-clock-driven visuals are client-local cosmetics such as particle motion, matching the existing click-effect and stun-ring pattern.
- The single highest seam for testing is the pure evaluator; any additional seams introduced should be pure functions at the same level rather than graphics-touching code.
- Bear Trap's frame and alpha accessors remain stable public pure functions so the existing reconciliation logic and any future callers are unaffected.
- The dust burst color, count, speed, and lifetime are tuning values that live beside the Bear Trap spec, not hardcoded in engine code.