## Problem Statement

The game is currently a single-player LÖVE 2D prototype: a player clicks to move, an A* pathfinder routes them around static obstacles, and click effects give visual feedback. Everything runs locally in one process, with no notion of multiple players, a server, or network traffic. The user wants to introduce multiplayer over the internet so two people can share the same arena, with the long-term goal of evolving it into a 1v1 PvP game. The first milestone is to network the existing game as-is and defer all combat mechanics.

## Solution

Introduce a dedicated, authoritative server running as headless LÖVE that simulates the shared arena, and multiplayer clients that connect to it over the internet. The obstacle layout is static and shared through a single config file, so server and clients always agree on the world. The first two connections become players; any further connections join as spectators who can watch but not act. The server is the source of truth for player positions; each client predicts its own player for responsive click-to-move and reconciles against server snapshots, while the other player is interpolated. Only authoritative player positions are broadcast, keeping the protocol small. This establishes the netcode foundation that later PvP updates will build on.

## User Stories

1. As a player, I want the game to automatically connect to the server address stored in the shared config file, so that I can join a match without any manual networking setup.
2. As the first person to connect, I want to be assigned the first player slot with a distinct color, so that I am identifiable as Player 1.
3. As the second person to connect, I want to be assigned the second player slot with a different color, so that I am identifiable as Player 2.
4. As a player, I want to left-click a walkable spot and have my player path there using the same A* pathfinding as the single-player game, so that moving around obstacles still works.
5. As a player, I want my click-to-move to feel immediate even with internet latency, so that network delay does not make the game feel sluggish.
6. As a player, I want to see the other player move smoothly rather than teleport, so that I can track where they are going.
7. As a player, I want the server and both clients to share an identical obstacle layout from the config file, so that the world looks and behaves the same everywhere.
8. As a player, I want the server to be the authority over my position rather than trusting my client, so that the game state cannot be cheated or drift apart between machines.
9. As a player, I want a visible click effect at my click location, so that my input gives feedback.
10. As a player, I want my own A* path preview visible only to me, so that the opponent cannot see my exact route.
11. As a spectator (the third and later connections), I want to see the arena with its obstacles and both players moving, so that I can watch the match.
12. As a spectator, I want no ability to move or edit players, so that I cannot interfere with the match.
13. As a player who disconnects, I want my player slot to become free, so that the match can recover instead of staying half-dead.
14. As a new joiner arriving after a slot frees up, I want to fill the first available player slot (or spectate if both are taken), so that matches keep working over time.
15. As a developer/operator, I want to run the dedicated server without a window, so that I can host it on a headless machine or VPS.
16. As a developer, I want the server and clients to reuse the same game logic (pathfinding and movement), so that behavior stays consistent without duplicated code.
17. As a developer, I want the simulation to run on a fixed timestep independent of each client's frame rate, so that movement is deterministic and predictable.
18. As a player, I want my player to spawn at a position defined in the config, so that both players begin the match in known locations.
19. As a player, I want to quit cleanly with Escape, so that I can leave without corrupting the game.
20. As an operator, I want a cap on the number of concurrent spectators, so that the server cannot be overwhelmed by unlimited connections.
21. As a developer, I want connection-lifecycle events and movement updates to travel over separate reliability channels, so that critical join/leave events are never dropped while position updates stay low-latency.
22. As a player, I want the opponent's clicks not to be broadcast to me as effects, so that bandwidth stays minimal and only positions are shared.
23. As a developer, I want the client to reconcile any mismatch between my predicted position and the server's authoritative position, so that I never drift permanently out of sync.
24. As a player, I want to see two distinct avatars at the same time when both slots are filled, so that I can tell the two players apart.
25. As a developer, I want the config file to also carry the server address, tick/snapshot rates, per-player spawn points, and per-player colors, so that all machines agree on these values without code changes.
26. As a spectator who connects while the match is in progress, I want to immediately begin receiving current player positions, so that I can start watching without a restart.
27. As an operator, I want to deploy the dedicated server to Azure with a public endpoint, so that players anywhere can reach it over the internet.

## Implementation Decisions

Architecture and runtime
- The dedicated server is headless LÖVE (window and graphics modules disabled), reusing the existing A* pathfinding and movement logic. The client remains a normal windowed LÖVE build.
- Transport is ENet (lua-enet). Two channels are used: a reliable/ordered channel for connection lifecycle (welcome/slot assignment, disconnect) and an unreliable/sequenced channel for position snapshots and move intents.

Authority and netcode
- The simulation is server-authoritative: the server owns player positions and advances them on a fixed 30 Hz timestep. Clients send move intents (a target point), never raw positions.
- Client-side prediction: each client locally runs the same pathfinding and movement for its own player so click-to-move feels instant, then reconciles its predicted position to authoritative snapshots.
- Remote-player interpolation: the other player is rendered from buffered server snapshots (about 100 ms behind) to smooth network jitter.
- Determinism invariant: prediction and authority stay aligned because obstacles come from one shared config, A* is deterministic (no randomness), and movement uses a fixed timestep and an identical walk speed on both sides.

World and config
- Obstacles become static, read-only data loaded from the shared config file; runtime obstacle editing (right-click) is removed. The config file is the single source of truth for the world.
- The config schema is extended to carry server/network settings and per-player data. This shape comes from the existing config prototype, trimmed to the decision-relevant parts:
  - window: { title, width, height }
  - grid: { cellSize }
  - player: { radius, walkSpeed, spawnPoints: [ {x, y}, {x, y} ] }
  - obstacles: [ { x, y, width, height } ]
  - server: { address, port, tickRate, snapshotRate, spectatorLimit }
  - colors: player1Fill/player1Outline, player2Fill/player2Outline, plus shared background/grid/obstacle/path/clickEffect colors.

Match and discovery
- Two player slots plus spectators. The first two connections are assigned slots in connection order; all later connections are spectators.
- On disconnect, the vacated slot is freed and the next connection fills it (falling back to spectator if both slots are occupied). There is no reconnection with identity; a disconnector becomes an ordinary new joiner.
- A spectator cap (e.g., 32) bounds the number of concurrent connections.
- Discovery is fixed-address: clients auto-connect to the address/port in the config file. There is no join UI or matchmaking.

Sync surface and protocol
- The only runtime state broadcast is authoritative player positions. Click effects and path previews are local-only; names and chat are deferred.
- Protocol message shapes (from the same decision, encoded as schema):
  - server → client, reliable: welcome { slot: "player1" | "player2" | "spectator" }
  - server → client, unreliable: snapshot { seq, players: [ { slot, x, y } ] }
  - client → server, unreliable: moveIntent { x, y }
  - connect/disconnect are ENet events with no payload.

Modules and seam
- A transport-agnostic game-session module is introduced with two modes (authoritative server mode and predictive client mode). It exposes an event interface (connect, moveIntent, disconnect, tick) and produces authoritative state plus a queue of outbound messages. This is the single test seam.
- A thin ENet adapter translates socket events into session events and session messages into packets, and is the only network-aware component.
- Config loading is shared by server and client so both read identical world and network settings.

Deployment
- The dedicated server is deployed to Azure as a Linux VM with a public IP and an open UDP port for ENet. The headless LÖVE build runs on the VM as a long-lived process (service), and clients' config points at the VM's public address/port.

## Testing Decisions

What makes a good test
- Tests assert external behavior only: given a sequence of session events, the resulting authoritative world state and emitted messages are correct. They do not inspect internal implementation details (e.g., how the priority queue is stored).

The seam
- The single seam is the transport-agnostic game-session module, driven headlessly (no window, no real sockets) with synthetic events. Both modes (server-authoritative and client-predictive) are exercised through the same interface.

Modules tested
- The game-session module: slot assignment (first two connections become players, later ones become spectators); movement authority (a move intent advances the authoritative player along a deterministic A* path); snapshot emission (positions are broadcast each tick); disconnect recovery (slot freed, next joiner fills it); and client-prediction reconciliation (predicted position converges to the authoritative position).
- Determinism of movement and pathfinding: identical inputs produce identical positions across runs, guarding the prediction invariant.

Prior art
- The codebase has no automated test suite today; the only existing verification is the manual console-build smoke check described in the project instructions. This spec establishes the first headless test harness, run through the console build so failures surface as plain text with a non-zero exit code.

## Out of Scope

- PvP combat, health/damage, abilities, auto-attacks, and win conditions (deferred to later server updates).
- Minions, towers, nexus, champions, and other MOBA-like content.
- Runtime obstacle editing (obstacles are static and come from the config).
- Chat, player names/labels, lobbies, matchmaking, room codes, accounts, and authentication.
- Lag compensation for combat, and anti-cheat measures beyond server-side authority.
- Session persistence and identity-based reconnection (disconnect simply frees the slot).
- Scaling beyond two players plus a capped spectator pool.

## Further Notes

- Deployment: the dedicated server is deployed to Azure (a Linux VM with a public IP and an open UDP port, running the headless LÖVE build as a service). Clients only make outbound connections to the Azure endpoint, so no NAT traversal is needed. Local testing can still point the config at a port-forwarded machine.
- The saved UDP tutorial (under sources/) informed the transport discussion, but ENet was chosen over raw UDP for connection management, reliability, and sequencing.
- The existing config file already centralizes shared constants, which is the natural home for the new server/network settings and per-player spawn/color data.
- Keeping click effects and path previews local-only minimizes the message surface to position snapshots, keeping bandwidth low and the protocol small.
- The deterministic-movement invariant is critical: any future change that breaks determinism (randomness in pathfinding, variable timesteps, or divergent configs) will silently break client prediction.