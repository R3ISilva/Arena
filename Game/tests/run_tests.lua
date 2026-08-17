-- Headless test harness for the game-session module (the transport-agnostic seam).
-- Run via: lovec.exe . --test   (exit code 0 = pass, 1 = fail)

local World = require("src.world")
local Game = require("src.game")
local Session = require("src.session")
local registry = require("src.abilities.registry")

local tests = {}

local function test(name, fn)
    table.insert(tests, { name = name, fn = fn })
end

local function fail(message)
    error(message, 0)
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        fail((message or "assertEqual") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

local function assertNear(actual, expected, epsilon, message)
    if math.abs(actual - expected) > (epsilon or 0.001) then
        fail((message or "assertNear") .. ": expected ~" .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

local function assertTrue(value, message)
    if not value then
        fail(message or "assertTrue: expected truthy value")
    end
end

----------------------------------------
-- Fixtures
----------------------------------------
local function makeConfig()
    return {
        window = { title = "test", width = 200, height = 200 },
        grid = { cellSize = 25 },
        player = {
            radius = 8,
            walkSpeed = 100,
            spawnPoints = { { x = 25, y = 25 }, { x = 175, y = 175 } },
        },
        obstacles = { { x = 75, y = 75, width = 50, height = 50 } },
        server = {
            address = "127.0.0.1",
            port = 27890,
            tickRate = 30,
            snapshotRate = 30,
            spectatorLimit = 2,
        },
        colors = {},
    }
end

local function newServerSession(config)
    return Session.new(Game.new(config or makeConfig()), "server", (config or makeConfig()).server)
end

local function newClientSession(config)
    return Session.new(Game.new(config or makeConfig()), "client", (config or makeConfig()).server)
end

----------------------------------------
-- Server: slot assignment
----------------------------------------
test("server assigns player1, player2, then spectator in connection order", function()
    local session = newServerSession()

    assertEqual(session:onConnect(1), true)
    assertEqual(session:onConnect(2), true)
    assertEqual(session:onConnect(3), true)

    local outbox = session:drainOutbox()
    assertEqual(#outbox, 3)

    assertEqual(outbox[1].message.type, "welcome")
    assertEqual(outbox[1].message.slot, "player1")
    assertEqual(outbox[1].to, 1)
    assertEqual(outbox[1].channel, 0)

    assertEqual(outbox[2].message.slot, "player2")
    assertEqual(outbox[2].to, 2)

    assertEqual(outbox[3].message.slot, "spectator")
    assertEqual(outbox[3].to, 3)
end)

test("server spawns players at their configured spawn points", function()
    local session = newServerSession()
    session:onConnect(1)
    session:onConnect(2)
    session:drainOutbox()

    local state = session:getState()
    assertEqual(state.players.player1.x, 25)
    assertEqual(state.players.player1.y, 25)
    assertEqual(state.players.player2.x, 175)
    assertEqual(state.players.player2.y, 175)
end)

test("server rejects connections beyond the spectator cap", function()
    local session = newServerSession()

    session:onConnect(1) -- player1
    session:onConnect(2) -- player2
    session:onConnect(3) -- spectator 1
    session:onConnect(4) -- spectator 2 (limit = 2)

    assertEqual(session:onConnect(5), false) -- over cap
end)

----------------------------------------
-- Server: movement authority
----------------------------------------
test("move intent advances the authoritative player along a deterministic path", function()
    local config = makeConfig()
    local game = Game.new(config)
    local world = game.world
    local session = Session.new(game, "server", config.server)
    session:onConnect(1)
    session:drainOutbox()

    session:onMessage(1, { type = "moveIntent", x = 175, y = 175 })

    -- The goal snaps to the center of the clicked cell.
    local goalCol, goalRow = world:worldToCell(175, 175)
    local goalX, goalY = world:cellCenter(goalCol, goalRow)

    local dt = 1 / 30
    local moved = false
    local previous = session:getState().players.player1

    for _ = 1, 150 do
        session:tick(dt)
        local current = session:getState().players.player1
        if current.x ~= previous.x or current.y ~= previous.y then
            moved = true
        end
        previous = current
    end

    assertTrue(moved, "player did not move after move intent")

    local dx = previous.x - goalX
    local dy = previous.y - goalY
    assertNear(dx * dx + dy * dy, 0, 25, "player should arrive near the goal cell center")
end)

test("move intent from a spectator is ignored", function()
    local session = newServerSession()
    session:onConnect(1)
    session:onConnect(2)
    session:onConnect(3) -- spectator
    session:drainOutbox()

    session:onMessage(3, { type = "moveIntent", x = 175, y = 175 })

    for _ = 1, 30 do
        session:tick(1 / 30)
    end

    local state = session:getState()
    assertEqual(state.players.player1.x, 25)
    assertEqual(state.players.player1.y, 25)
end)

test("movement is deterministic across two identical sessions", function()
    local function simulate()
        local session = newServerSession()
        session:onConnect(1)
        session:drainOutbox()
        session:onMessage(1, { type = "moveIntent", x = 175, y = 175 })
        for _ = 1, 60 do
            session:tick(1 / 30)
        end
        local player = session:getState().players.player1
        return player.x, player.y
    end

    local x1, y1 = simulate()
    local x2, y2 = simulate()
    assertEqual(x1, x2, "deterministic x coordinate")
    assertEqual(y1, y2, "deterministic y coordinate")
end)

test("player walks a long multi-waypoint path without getting stuck", function()
    -- Regression: with walkSpeed 260 the per-tick step (8.67 px) is larger than the
    -- old 4 px arrival radius, so the follower used to overshoot a waypoint and
    -- oscillate around it forever. The real obstacle layout + long path triggers it.
    local config = makeConfig()
    config.window = { title = "test", width = 800, height = 600 }
    config.grid.cellSize = 25
    config.player.walkSpeed = 260
    config.player.spawnPoints = { { x = 100, y = 100 }, { x = 700, y = 500 } }
    config.obstacles = {
        { x = 250, y = 150, width = 100, height = 250 },
        { x = 450, y = 250, width = 150, height = 100 },
        { x = 150, y = 420, width = 200, height = 60 },
        { x = 550, y = 80, width = 120, height = 120 },
    }

    local game = Game.new(config)
    local world = game.world
    local session = Session.new(game, "server", config.server)
    session:onConnect(1)
    session:drainOutbox()

    session:onMessage(1, { type = "moveIntent", x = 740, y = 540 })

    for _ = 1, 300 do
        session:tick(1 / 30)
    end

    local player = session:getState().players.player1
    local goalCol, goalRow = world:worldToCell(740, 540)
    local goalX, goalY = world:cellCenter(goalCol, goalRow)
    local dx = player.x - goalX
    local dy = player.y - goalY
    assertTrue(dx * dx + dy * dy <= 1,
        string.format("player stuck before goal: (%.1f, %.1f) vs goal (%.1f, %.1f)",
            player.x, player.y, goalX, goalY))
end)

test("dense grid: 10x smaller cells pathfind and walk smoothly to the goal", function()
    -- Regression: with cellSize 2.5 the arena is 320x240 cells (100x more than
    -- the old 25px grid), which used to make A* take seconds per click. The
    -- binary-heap open list keeps a full diagonal crossing fast, and the player
    -- must still arrive exactly at the goal cell center.
    local config = makeConfig()
    config.window = { title = "test", width = 800, height = 600 }
    config.grid.cellSize = 2.5
    config.player.walkSpeed = 260
    config.player.spawnPoints = { { x = 100, y = 100 }, { x = 700, y = 500 } }
    config.obstacles = {
        { x = 250, y = 150, width = 100, height = 250 },
        { x = 450, y = 250, width = 150, height = 100 },
        { x = 150, y = 420, width = 200, height = 60 },
        { x = 550, y = 80, width = 120, height = 120 },
    }

    local game = Game.new(config)
    local world = game.world
    local session = Session.new(game, "server", config.server)
    session:onConnect(1)
    session:drainOutbox()

    session:onMessage(1, { type = "moveIntent", x = 740, y = 540 })

    local player = game:getPlayerRef("player1")
    assertTrue(#player.path > 100, "dense grid should produce a long waypoint path")

    for _ = 1, 300 do
        session:tick(1 / 30)
    end

    player = session:getState().players.player1
    local goalCol, goalRow = world:worldToCell(740, 540)
    local goalX, goalY = world:cellCenter(goalCol, goalRow)
    local dx = player.x - goalX
    local dy = player.y - goalY
    assertTrue(dx * dx + dy * dy <= 1,
        string.format("player stuck before goal: (%.1f, %.1f) vs goal (%.1f, %.1f)",
            player.x, player.y, goalX, goalY))
end)

----------------------------------------
-- World: diagonal pathfinding
----------------------------------------
test("pathfinding takes diagonal shortcuts in open space", function()
    local config = makeConfig()
    config.obstacles = {}
    local world = World.new(config)

    local startX, startY = world:cellCenter(1, 1)
    local goalX, goalY = world:cellCenter(2, 2)
    local path = world:findPath(startX, startY, goalX, goalY)

    assertEqual(#path, 2, "diagonal neighbors should connect with a single step")
end)

test("pathfinding does not cut corners through obstacles", function()
    local config = makeConfig()
    -- Blocks cell (2,1): the diagonal from (1,1) to (2,2) must be refused.
    config.obstacles = { { x = 50, y = 25, width = 25, height = 25 } }
    local world = World.new(config)

    local startX, startY = world:cellCenter(1, 1)
    local goalX, goalY = world:cellCenter(2, 2)
    local path = world:findPath(startX, startY, goalX, goalY)

    assertEqual(#path, 3, "a blocked adjacent cell must forbid the diagonal corner-cut")
end)

----------------------------------------
-- Game: pure simulation (no network)
----------------------------------------
test("game spawns players at slot-specific spawn points", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")

    local p1 = game:getPlayer("player1")
    local p2 = game:getPlayer("player2")
    assertEqual(p1.x, 25)
    assertEqual(p1.y, 25)
    assertEqual(p2.x, 175)
    assertEqual(p2.y, 175)
end)

test("game setTarget clamps coordinates to the arena", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    local cx, cy = game:setTarget("player1", -500, 9999)
    assertEqual(cx, 0)
    assertEqual(cy, 200)

    local target = game:getTarget("player1")
    assertEqual(target.x, 0)
    assertEqual(target.y, 200)
end)

test("game setTarget computes a path and tick advances the player", function()
    local config = makeConfig()
    config.obstacles = {}
    local game = Game.new(config)
    game:spawnPlayer("player1")

    game:setTarget("player1", 175, 175)
    local startX = game:getPlayer("player1").x

    for _ = 1, 30 do
        game:tick(1 / 30)
    end

    local player = game:getPlayer("player1")
    assertTrue(player.x ~= startX, "player should move toward the target")
end)

test("game removePlayer stops it appearing in state", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")

    game:removePlayer("player1")

    local players = game:getPlayers()
    assertEqual(players.player1, nil)
    assertTrue(players.player2 ~= nil)
end)

----------------------------------------
-- Server: snapshot emission
----------------------------------------
test("snapshots broadcast authoritative positions on the unreliable channel", function()
    local session = newServerSession()
    session:onConnect(1)
    session:onConnect(2)
    session:drainOutbox()

    session:tick(1 / 30)

    local outbox = session:drainOutbox()
    local snapshot
    for _, entry in ipairs(outbox) do
        if entry.message.type == "snapshot" then
            snapshot = entry
        end
    end

    assertTrue(snapshot ~= nil, "expected a snapshot message")
    assertEqual(snapshot.to, "*")
    assertEqual(snapshot.channel, 1)
    assertEqual(snapshot.message.seq, 0)
    assertEqual(#snapshot.message.players, 2)
end)

test("snapshot sequence numbers increment", function()
    local session = newServerSession()
    session:onConnect(1)
    session:drainOutbox()

    session:tick(1 / 30)
    local first = session:drainOutbox()[1].message

    session:tick(1 / 30)
    local second = session:drainOutbox()[1].message

    assertEqual(first.seq, 0)
    assertEqual(second.seq, 1)
end)

----------------------------------------
-- Server: disconnect recovery
----------------------------------------
test("disconnect frees a slot and the next joiner fills it", function()
    local session = newServerSession()
    session:onConnect(1) -- player1
    session:onConnect(2) -- player2
    session:drainOutbox()

    session:onDisconnect(1)

    session:onConnect(3) -- should fill player1 (first available)
    local outbox = session:drainOutbox()

    local welcome
    for _, entry in ipairs(outbox) do
        if entry.message.type == "welcome" and entry.to == 3 then
            welcome = entry.message
        end
    end

    assertTrue(welcome ~= nil, "expected a welcome for peer 3")
    assertEqual(welcome.slot, "player1")
end)

test("disconnected player stops appearing in snapshots", function()
    local session = newServerSession()
    session:onConnect(1)
    session:onConnect(2)
    session:drainOutbox()

    session:onDisconnect(1)
    session:tick(1 / 30)

    local snapshot
    for _, entry in ipairs(session:drainOutbox()) do
        if entry.message.type == "snapshot" then
            snapshot = entry.message
        end
    end

    assertEqual(#snapshot.players, 1)
    assertEqual(snapshot.players[1].slot, "player2")
end)

----------------------------------------
-- Client: prediction and reconciliation
----------------------------------------
test("client predicts local movement immediately", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", { type = "welcome", slot = "player1" })
    session:drainOutbox()

    session:localMoveIntent(175, 175)
    local startX = session:getState().players.player1.x

    for _ = 1, 30 do
        session:tick(1 / 30)
    end

    local player = session:getState().players.player1
    assertTrue(player.x ~= startX, "local player should move via prediction")
end)

test("client move intent is queued on the unreliable channel", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", { type = "welcome", slot = "player1" })
    session:drainOutbox()

    session:localMoveIntent(150, 150)

    local outbox = session:drainOutbox()
    assertEqual(#outbox, 1)
    assertEqual(outbox[1].to, "server")
    assertEqual(outbox[1].channel, 1)
    assertEqual(outbox[1].message.type, "moveIntent")
    assertEqual(outbox[1].message.x, 150)
    assertEqual(outbox[1].message.y, 150)
end)

test("client prediction reconciles to authoritative position", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", { type = "welcome", slot = "player1" })

    -- Predict movement away from the eventual authoritative position.
    session:localMoveIntent(175, 175)
    for _ = 1, 20 do
        session:tick(1 / 30)
    end

    session:onMessage("server", {
        type = "snapshot",
        seq = 5,
        players = {
            { slot = "player1", x = 40, y = 40 },
            { slot = "player2", x = 175, y = 175 },
        },
    })

    local player = session:getState().players.player1
    assertNear(player.x, 40, 0.001, "predicted x should snap to authoritative x")
    assertNear(player.y, 40, 0.001, "predicted y should snap to authoritative y")
end)

test("client re-sends a lost move intent after reconciliation", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", { type = "welcome", slot = "player1" })

    session:localMoveIntent(175, 175)
    session:drainOutbox()

    for _ = 1, 20 do
        session:tick(1 / 30)
    end

    -- Authoritative snapshot shows the server never moved (intent was lost).
    session:onMessage("server", {
        type = "snapshot",
        seq = 5,
        players = {
            { slot = "player1", x = 25, y = 25 },
            { slot = "player2", x = 175, y = 175 },
        },
    })

    local found = false
    for _, entry in ipairs(session:drainOutbox()) do
        if entry.message.type == "moveIntent" then
            found = true
            assertEqual(entry.to, "server")
            assertEqual(entry.channel, 1)
        end
    end
    assertTrue(found, "expected a re-sent move intent after reconciliation")
end)

test("reconcile threshold scales with RTT", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", { type = "welcome", slot = "player1" })

    -- At 200 ms RTT the threshold is ~40 px, so a 30 px divergence is tolerated.
    session:setLatency(0.2)
    session:onMessage("server", {
        type = "snapshot",
        seq = 1,
        players = { { slot = "player1", x = 55, y = 25 } },
    })
    assertEqual(session:getState().players.player1.x, 25, "prediction lag within RTT margin must not snap")

    -- The same 30 px divergence exceeds the ~10 px floor once latency is zero.
    session:setLatency(0)
    session:onMessage("server", {
        type = "snapshot",
        seq = 2,
        players = { { slot = "player1", x = 55, y = 25 } },
    })
    assertEqual(session:getState().players.player1.x, 55, "real drift at low latency must snap")
end)

test("client interpolates the remote player", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", { type = "welcome", slot = "player1" })

    session:onMessage("server", {
        type = "snapshot",
        seq = 1,
        players = { { slot = "player2", x = 100, y = 100 } },
    })
    session:tick(1 / 30)

    local remote = session:getState().players.player2
    assertTrue(remote ~= nil, "remote player should be rendered")
    assertNear(remote.x, 100, 0.001)
    assertNear(remote.y, 100, 0.001)
end)

----------------------------------------
-- Client: spectator
----------------------------------------
test("spectator sees both players but cannot move", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", { type = "welcome", slot = "spectator" })

    session:localMoveIntent(100, 100)
    assertEqual(#session:drainOutbox(), 0, "spectator must not emit move intents")

    session:onMessage("server", {
        type = "snapshot",
        seq = 1,
        players = {
            { slot = "player1", x = 30, y = 30 },
            { slot = "player2", x = 170, y = 170 },
        },
    })
    session:tick(1 / 30)

    local state = session:getState()
    assertEqual(state.slot, "spectator")
    assertNear(state.players.player1.x, 30, 0.001)
    assertNear(state.players.player2.x, 170, 0.001)
end)

----------------------------------------
-- Ability registry
----------------------------------------
test("ability registry loads morganapool with its declared properties", function()
    local module = registry.load("morganapool")
    assertTrue(module ~= nil, "morganapool module should load")
    assertEqual(module.name, "Morgana's Pool")
    assertEqual(module.type, "pool")
    assertEqual(module.cooldown, 6)
    assertEqual(module.damage, 30)
    assertEqual(module.range, 200)
    assertEqual(module.radius, 60)
    assertEqual(module.duration, 2)
end)

----------------------------------------
-- Game: ability simulation (no network)
----------------------------------------
test("game castAbility clamps the target to the ability range", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    local cx, cy = game:castAbility("player1", "w", 200, 25)
    assertEqual(cx, 200)
    assertEqual(cy, 25)

    game:setCooldowns("player1", { q = 0, w = 0, e = 0 })

    local cx2, cy2 = game:castAbility("player1", "w", 25, 425)
    assertNear(cx2, 25, 0.001)
    assertNear(cy2, 225, 0.001)
end)

test("game castAbility rejects a recast during cooldown", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    local cx = game:castAbility("player1", "w", 200, 25)
    assertTrue(cx ~= nil, "first cast should succeed")

    assertEqual(game:castAbility("player1", "w", 100, 100), nil)

    for _ = 1, 177 do game:tick(1 / 30) end -- ~5.9s
    assertEqual(game:castAbility("player1", "w", 100, 100), nil)

    for _ = 1, 9 do game:tick(1 / 30) end -- ~6.2s total
    local again = game:castAbility("player1", "w", 100, 100)
    assertTrue(again ~= nil, "cast should succeed after the cooldown expires")
end)

test("pool spawns and expires after its duration", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:castAbility("player1", "w", 200, 25)
    assertEqual(#game:getAbilities(), 1)

    for _ = 1, 59 do game:tick(1 / 30) end
    assertEqual(#game:getAbilities(), 1, "pool should still be active just under 2s")

    for _ = 1, 3 do game:tick(1 / 30) end
    assertEqual(#game:getAbilities(), 0, "pool should expire after 2s")
end)

test("a player standing in a pool loses health in ticks", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:castAbility("player1", "w", 25, 25) -- pool centered on the caster

    assertEqual(game:getHealth("player1"), 100)

    for _ = 1, 8 do game:tick(1 / 30) end -- ~0.27s -> one 0.25s tick
    assertNear(game:getHealth("player1"), 92.5, 0.01, "one tick = 7.5 damage")

    for _ = 1, 23 do game:tick(1 / 30) end -- ~1.03s total -> four ticks
    assertNear(game:getHealth("player1"), 70, 0.01, "four ticks = 30 damage")
end)

test("health never drops below 0", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:setHealth("player1", 3)
    game:castAbility("player1", "w", 25, 25)
    for _ = 1, 10 do game:tick(1 / 30) end -- one tick (7.5) exceeds remaining 3

    assertEqual(game:getHealth("player1"), 0)
end)

test("loadout resolves q, w, and e slots", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    local qx = game:castAbility("player1", "q", 100, 100)
    assertTrue(qx ~= nil, "q slot should resolve to beam")

    local wx, wy = game:castAbility("player1", "w", 100, 100)
    assertTrue(wx ~= nil, "w slot should resolve to morganapool")
    assertEqual(wx, 100)
    assertEqual(wy, 100)

    local ex = game:castAbility("player1", "e", 50, 50)
    assertTrue(ex ~= nil, "e slot should resolve to beartrap")
end)

----------------------------------------
-- Server: ability authority
----------------------------------------
test("server welcome includes the recipient loadout", function()
    local session = newServerSession()
    session:onConnect(1)

    local welcome = session:drainOutbox()[1].message
    assertEqual(welcome.type, "welcome")
    assertEqual(welcome.slot, "player1")
    assertEqual(welcome.loadout.w, "morganapool")
    assertEqual(welcome.loadout.q, "beam")
    assertEqual(welcome.loadout.e, "beartrap")
end)

test("server castIntent spawns an authoritative pool", function()
    local session = newServerSession()
    session:onConnect(1)
    session:drainOutbox()

    session:onMessage(1, { type = "castIntent", slot = "w", x = 100, y = 25 })
    session:tick(1 / 30)

    local abilities = session:getState().abilities
    assertEqual(#abilities, 1)
    assertEqual(abilities[1].ability, "morganapool")
    assertEqual(abilities[1].owner, "player1")
    assertEqual(abilities[1].x, 100)
    assertEqual(abilities[1].y, 25)
end)

test("server cooldown blocks a recast", function()
    local session = newServerSession()
    session:onConnect(1)
    session:drainOutbox()

    session:onMessage(1, { type = "castIntent", slot = "w", x = 100, y = 25 })
    session:onMessage(1, { type = "castIntent", slot = "w", x = 150, y = 25 })

    assertEqual(#session:getState().abilities, 1, "recast during cooldown should be ignored")
end)

test("snapshots include abilities, health, and cooldowns", function()
    local session = newServerSession()
    session:onConnect(1)
    session:onConnect(2)
    session:drainOutbox()

    session:onMessage(1, { type = "castIntent", slot = "w", x = 100, y = 25 })
    session:tick(1 / 30)

    local snapshot
    for _, entry in ipairs(session:drainOutbox()) do
        if entry.message.type == "snapshot" then
            snapshot = entry.message
        end
    end

    assertTrue(snapshot ~= nil, "expected a snapshot")
    assertEqual(#snapshot.abilities, 1)
    assertEqual(snapshot.abilities[1].ability, "morganapool")

    local p1
    for _, p in ipairs(snapshot.players) do
        if p.slot == "player1" then
            p1 = p
        end
    end
    assertTrue(p1 ~= nil)
    assertEqual(p1.hp, 100)
    assertTrue(p1.cooldowns.w > 0, "cooldown should be reflected in the snapshot")
    assertEqual(p1.cooldowns.q, 0)
    assertEqual(p1.cooldowns.e, 0)
end)

test("cast intents from spectators and invalid slots are ignored", function()
    local session = newServerSession()
    session:onConnect(1)
    session:onConnect(2)
    session:onConnect(3) -- spectator
    session:drainOutbox()

    session:onMessage(3, { type = "castIntent", slot = "w", x = 100, y = 100 })
    session:onMessage(1, { type = "castIntent", slot = "r", x = 100, y = 100 })

    assertEqual(#session:getState().abilities, 0)
end)

test("disconnect cleans up a player's active abilities", function()
    local session = newServerSession()
    session:onConnect(1)
    session:onConnect(2)
    session:drainOutbox()

    session:onMessage(1, { type = "castIntent", slot = "w", x = 100, y = 25 })
    assertEqual(#session:getState().abilities, 1)

    session:onDisconnect(1)
    assertEqual(#session:getState().abilities, 0)
end)

----------------------------------------
-- Client: ability prediction and reconciliation
----------------------------------------
test("client cast predicts its pool and cooldown immediately", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", {
        type = "welcome",
        slot = "player1",
        loadout = { q = nil, w = "morganapool", e = nil },
    })
    session:drainOutbox()

    session:localCastIntent("w", 100, 25)

    local outbox = session:drainOutbox()
    assertEqual(#outbox, 1)
    assertEqual(outbox[1].to, "server")
    assertEqual(outbox[1].channel, 1)
    assertEqual(outbox[1].message.type, "castIntent")
    assertEqual(outbox[1].message.slot, "w")
    assertEqual(outbox[1].message.x, 100)
    assertEqual(outbox[1].message.y, 25)

    local state = session:getState()
    assertEqual(#state.abilities, 1, "predicted pool should appear immediately")
    assertTrue(state.cooldowns.w > 0, "local cooldown should start immediately")
end)

test("client snapshot reconciles ability, health, and cooldown", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", {
        type = "welcome",
        slot = "player1",
        loadout = { q = nil, w = "morganapool", e = nil },
    })
    session:drainOutbox()

    session:localCastIntent("w", 100, 25)

    session:onMessage("server", {
        type = "snapshot",
        seq = 1,
        players = {
            { slot = "player1", x = 25, y = 25, hp = 85, cooldowns = { q = 0, w = 3.5, e = 0 }, stunned = false, stunRemaining = 0 },
        },
        abilities = {
            { id = 7, ability = "morganapool", x = 60, y = 25, radius = 60, owner = "player1", remaining = 0.4 },
        },
    })

    local state = session:getState()
    assertEqual(#state.abilities, 1)
    assertEqual(state.abilities[1].id, 7)
    assertEqual(state.abilities[1].x, 60)
    assertNear(state.cooldowns.w, 3.5, 0.001)
    assertNear(state.health, 85, 0.001)
end)

----------------------------------------
-- Ability registry: beam + trap tuning
----------------------------------------
test("ability registry loads beam with its declared properties", function()
    local module = registry.load("beam")
    assertTrue(module ~= nil, "beam module should load")
    assertEqual(module.name, "Beam")
    assertEqual(module.type, "beam")
    assertEqual(module.shape, "line")
    assertEqual(module.damageModel, "burst")
    assertEqual(module.cooldown, 8)
    assertEqual(module.damage, 50)
    assertEqual(module.range, 500)
    assertEqual(module.length, 500)
    assertEqual(module.width, 35)
end)

test("ability registry loads beartrap with its declared properties", function()
    local module = registry.load("beartrap")
    assertTrue(module ~= nil, "beartrap module should load")
    assertEqual(module.name, "Bear Trap")
    assertEqual(module.type, "trap")
    assertEqual(module.trigger, "overlap")
    assertEqual(module.cooldown, 6)
    assertEqual(module.range, 200)
    assertEqual(module.armDelay, 0.75)
    assertEqual(module.duration, 30)
    assertEqual(module.stunDuration, 2)
    assertEqual(module.maxActive, 4)
    assertEqual(module.blockedByObstacles, true)
end)

test("beam and trap declare their HUD tilemap icon slots", function()
    local beam = registry.load("beam")
    local trap = registry.load("beartrap")
    assertEqual(beam.icon.col, 0)
    assertEqual(beam.icon.row, 0)
    assertEqual(trap.icon.col, 1)
    assertEqual(trap.icon.row, 0)
end)

----------------------------------------
-- Game: beam simulation
----------------------------------------
test("beam fires along its direction and bursts line-overlapping players", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")
    game:setPosition("player2", 175, 25) -- directly on player1's horizontal line

    game:castAbility("player1", "q", 500, 25)

    for _ = 1, 14 do game:tick(1 / 30) end -- ~0.47s (still charging)
    assertEqual(game:getHealth("player2"), 100, "beam must not fire during the windup")
    assertEqual(game:getHealth("player1"), 100)

    for _ = 1, 6 do game:tick(1 / 30) end -- ~0.67s total (fired)
    assertEqual(game:getHealth("player2"), 50, "beam burst should deal 50 damage")
    assertEqual(game:getHealth("player1"), 100, "beam must not damage the caster")
end)

test("beam does not damage players outside its line", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2") -- (175,175), off the horizontal beam line

    game:castAbility("player1", "q", 200, 25)
    for _ = 1, 20 do game:tick(1 / 30) end

    assertEqual(game:getHealth("player2"), 100, "player outside the beam line should not be hit")
end)

test("beam windup roots the caster and movement resumes after firing", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:setTarget("player1", 175, 25)
    game:tick(1 / 30)
    local xAfterMove = game:getPlayer("player1").x
    assertTrue(xAfterMove > 25, "player should have started moving")

    game:castAbility("player1", "q", 175, 25)
    local xAtCast = game:getPlayer("player1").x

    for _ = 1, 15 do game:tick(1 / 30) end -- through the windup
    assertNear(game:getPlayer("player1").x, xAtCast, 0.001, "caster should not move during the windup")

    for _ = 1, 20 do game:tick(1 / 30) end -- after firing
    assertTrue(game:getPlayer("player1").x > xAtCast, "caster should resume moving after the beam fires")
end)

test("beam cooldown starts at cast and blocks a recast", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    local cx = game:castAbility("player1", "q", 200, 25)
    assertTrue(cx ~= nil, "beam cast should succeed")
    assertEqual(game:getCooldowns("player1").q, 8, "beam cooldown starts at cast")

    assertEqual(game:castAbility("player1", "q", 200, 25), nil, "recast during cooldown should be rejected")
end)

test("stun during beam windup cancels the cast and refunds the cooldown", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    -- Arm a trap away from the caster.
    game:castAbility("player1", "e", 150, 25)
    for _ = 1, 30 do game:tick(1 / 30) end -- ~1s: armed

    -- Start a beam windup, then put the caster onto the armed trap before it fires.
    game:castAbility("player1", "q", 200, 25)
    assertEqual(game:getCooldowns("player1").q, 8, "beam cooldown starts at cast")

    game:setPosition("player1", 150, 25)
    game:tick(1 / 30)

    assertTrue(game:isStunned("player1"), "caster should be stunned by the armed trap")
    assertEqual(game:getCooldowns("player1").q, 0, "stun should refund the beam cooldown")

    local beams = 0
    for _, ability in ipairs(game:getAbilities()) do
        if ability.type == "beam" then beams = beams + 1 end
    end
    assertEqual(beams, 0, "interrupted beam should be cancelled")
end)

test("beam passes through obstacles", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")
    game:setPosition("player1", 25, 100)
    game:setPosition("player2", 175, 100)

    game:castAbility("player1", "q", 500, 100) -- horizontal beam crossing the obstacle
    for _ = 1, 20 do game:tick(1 / 30) end

    assertEqual(game:getHealth("player2"), 50, "beam should hit through the obstacle")
    assertEqual(game:getHealth("player1"), 100, "beam must not damage the caster")
end)

----------------------------------------
-- Game: trap + stun simulation
----------------------------------------
test("trap center cannot be inside an obstacle but may overlap its edge", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    -- The central obstacle spans (75..125, 75..125).
    assertEqual(game:castAbility("player1", "e", 100, 100), nil, "trap centered inside an obstacle should be rejected")
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 0)

    -- A trap whose circle overlaps the wall but whose center is outside is allowed.
    local cx = game:castAbility("player1", "e", 74, 100)
    assertTrue(cx ~= nil, "trap with its center outside the obstacle should place")
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 1)
end)

test("trap does not trigger before its arm delay", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:castAbility("player1", "e", 25, 25) -- drop under self
    for _ = 1, 10 do game:tick(1 / 30) end -- ~0.33s (still arming)

    assertEqual(game:isStunned("player1"), false, "arming trap must not stun")
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 1, "trap should still exist while arming")
end)

test("armed trap stuns the first player to overlap it and is consumed", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    -- Place a trap away from the caster and let it arm.
    game:castAbility("player1", "e", 150, 25)
    for _ = 1, 30 do game:tick(1 / 30) end -- ~1s: armed, caster still at spawn

    assertEqual(game:isStunned("player1"), false, "trap should be armed but not triggered yet")
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 1)

    -- Step onto the armed trap: it triggers and is consumed.
    game:setPosition("player1", 150, 25)
    game:tick(1 / 30)

    assertTrue(game:isStunned("player1"), "armed trap should stun the overlapping player")
    assertEqual(game:getStunRemaining("player1"), 2, "stun lasts 2s")
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 0, "trap should be consumed on trigger")
end)

test("trap cap removes the oldest trap when placing a 5th", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:castAbility("player1", "e", 50, 25)
    game:setCooldowns("player1", { q = 0, w = 0, e = 0 })
    game:castAbility("player1", "e", 75, 25)
    game:setCooldowns("player1", { q = 0, w = 0, e = 0 })
    game:castAbility("player1", "e", 100, 25)
    game:setCooldowns("player1", { q = 0, w = 0, e = 0 })
    game:castAbility("player1", "e", 125, 25)
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 4)

    game:setCooldowns("player1", { q = 0, w = 0, e = 0 })
    game:castAbility("player1", "e", 150, 25)

    assertEqual(game:countActiveAbilities("player1", "beartrap"), 4, "cap should stay at 4")

    local oldestPresent = false
    local newestPresent = false
    for _, ability in ipairs(game:getAbilities()) do
        if ability.abilityId == "beartrap" then
            if ability.x == 50 then oldestPresent = true end
            if ability.x == 150 then newestPresent = true end
        end
    end
    assertEqual(oldestPresent, false, "oldest trap should be removed")
    assertTrue(newestPresent, "newest trap should be present")
end)

test("a stunned player does not trigger traps (trap stays armed)", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")

    -- Player2 places an armed trap that stuns player1 at its spawn.
    game:castAbility("player2", "e", 25, 25)
    for _ = 1, 30 do game:tick(1 / 30) end -- arm + trigger under player1

    assertTrue(game:isStunned("player1"), "player1 should be stunned by the first trap")

    -- Player2 places a second trap under the still-stunned player1 and arms it.
    game:setCooldowns("player2", { q = 0, w = 0, e = 0 })
    game:castAbility("player2", "e", 25, 25)
    for _ = 1, 30 do game:tick(1 / 30) end -- arm trap 2

    assertEqual(game:countActiveAbilities("player2", "beartrap"), 1, "second trap should stay armed")
end)

test("stun clears the move target and blocks movement", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:setTarget("player1", 175, 25)
    game:tick(1 / 30)
    assertTrue(game:getPlayer("player1").x > 25, "player should be moving")

    game:applyStun("player1", 2)
    assertEqual(game:getTarget("player1"), nil, "stun should clear the move target")

    local xAtStun = game:getPlayer("player1").x
    for _ = 1, 30 do game:tick(1 / 30) end -- 1s of stun
    assertEqual(game:getPlayer("player1").x, xAtStun, "stunned player must not move")
end)

test("stun blocks casting", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:applyStun("player1", 2)
    assertEqual(game:castAbility("player1", "w", 100, 100), nil, "stunned player cannot cast pool")
    assertEqual(game:castAbility("player1", "q", 200, 25), nil, "stunned player cannot cast beam")
    assertEqual(game:castAbility("player1", "e", 100, 100), nil, "stunned player cannot place a trap")
end)

test("trap expires after its duration", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:castAbility("player1", "e", 100, 25)
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 1)

    for _ = 1, 29 * 30 do game:tick(1 / 30) end -- ~29s
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 1, "trap should still be alive just under 30s")

    for _ = 1, 2 * 30 do game:tick(1 / 30) end -- ~31s total
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 0, "trap should expire after 30s")
end)

test("beam and trap simulation is deterministic across two sessions", function()
    local function simulate()
        local session = newServerSession()
        session:onConnect(1)
        session:onConnect(2)
        session:drainOutbox()
        session:onMessage(1, { type = "castIntent", slot = "q", x = 200, y = 25 })
        session:onMessage(2, { type = "castIntent", slot = "e", x = 175, y = 175 })
        for _ = 1, 40 do session:tick(1 / 30) end
        local state = session:getState()
        return state.players.player1.hp, state.players.player2.stunned, #state.abilities
    end

    local hp1, stun1, count1 = simulate()
    local hp2, stun2, count2 = simulate()
    assertEqual(hp1, hp2, "deterministic hp")
    assertEqual(stun1, stun2, "deterministic stun")
    assertEqual(count1, count2, "deterministic ability count")
end)

----------------------------------------
-- Server: beam/trap/stun authority
----------------------------------------
test("server beam castIntent spawns an authoritative charging beam", function()
    local session = newServerSession()
    session:onConnect(1)
    session:onConnect(2)
    session:drainOutbox()

    session:onMessage(1, { type = "castIntent", slot = "q", x = 200, y = 25 })
    session:tick(1 / 30)

    local abilities = session:getState().abilities
    assertEqual(#abilities, 1)
    assertEqual(abilities[1].ability, "beam")
    assertEqual(abilities[1].owner, "player1")
    assertEqual(abilities[1].x, 25, "beam should fire from the caster position")
    assertEqual(abilities[1].y, 25)
    assertEqual(abilities[1].phase, "charging")
    assertNear(abilities[1].directionX, 1, 0.001, "beam should aim toward the click")
    assertNear(abilities[1].directionY, 0, 0.001)
end)

test("server trap castIntent spawns an authoritative arming trap", function()
    local session = newServerSession()
    session:onConnect(1)
    session:drainOutbox()

    session:onMessage(1, { type = "castIntent", slot = "e", x = 100, y = 25 })
    session:tick(1 / 30)

    local abilities = session:getState().abilities
    assertEqual(#abilities, 1)
    assertEqual(abilities[1].ability, "beartrap")
    assertEqual(abilities[1].owner, "player1")
    assertEqual(abilities[1].x, 100)
    assertEqual(abilities[1].y, 25)
    assertEqual(abilities[1].armed, false)
end)

test("snapshots include abilities and stun state", function()
    local session = newServerSession()
    session:onConnect(1)
    session:onConnect(2)
    session:drainOutbox()

    session:onMessage(1, { type = "castIntent", slot = "q", x = 200, y = 25 })
    session:onMessage(2, { type = "castIntent", slot = "e", x = 175, y = 175 })
    session:tick(1 / 30)

    local snapshot
    for _, entry in ipairs(session:drainOutbox()) do
        if entry.message.type == "snapshot" then snapshot = entry.message end
    end
    assertTrue(snapshot ~= nil, "expected a snapshot")

    local beamFound = false
    local trapFound = false
    for _, ability in ipairs(snapshot.abilities) do
        if ability.ability == "beam" and ability.phase == "charging" then beamFound = true end
        if ability.ability == "beartrap" and ability.armed == false then trapFound = true end
    end
    assertTrue(beamFound, "snapshot should carry the beam")
    assertTrue(trapFound, "snapshot should carry the trap")

    -- Let the trap arm + trigger under player2, then assert stun in a later snapshot.
    for _ = 1, 30 do session:tick(1 / 30) end
    local snapshot2
    for _, entry in ipairs(session:drainOutbox()) do
        if entry.message.type == "snapshot" then snapshot2 = entry.message end
    end
    local p2
    for _, p in ipairs(snapshot2.players) do
        if p.slot == "player2" then p2 = p end
    end
    assertTrue(p2 ~= nil and p2.stunned, "snapshot should carry the stun on player2")
end)

test("server ignores cast intents from a stunned player", function()
    local session = newServerSession()
    session:onConnect(1)
    session:drainOutbox()

    -- Player1 drops a trap on their own spawn and lets it arm + trigger.
    session:onMessage(1, { type = "castIntent", slot = "e", x = 25, y = 25 })
    for _ = 1, 31 do session:tick(1 / 30) end

    assertTrue(session:getState().players.player1.stunned, "player1 should be stunned")

    session:onMessage(1, { type = "castIntent", slot = "w", x = 100, y = 25 })
    assertEqual(#session:getState().abilities, 0, "stunned player's cast intent should be ignored")
end)

----------------------------------------
-- Client: beam/trap/stun prediction and reconciliation
----------------------------------------
test("client predicts its beam and reconciles the authoritative direction", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", {
        type = "welcome",
        slot = "player1",
        loadout = { q = "beam", w = "morganapool", e = "beartrap" },
    })
    session:drainOutbox()

    session:localCastIntent("q", 200, 25)

    local outbox = session:drainOutbox()
    assertEqual(#outbox, 1)
    assertEqual(outbox[1].message.type, "castIntent")
    assertEqual(outbox[1].message.slot, "q")

    local state = session:getState()
    assertEqual(#state.abilities, 1, "predicted beam should appear immediately")
    assertEqual(state.abilities[1].ability, "beam")
    assertEqual(state.abilities[1].phase, "charging")
    assertTrue(state.cooldowns.q > 0, "local beam cooldown should start immediately")

    session:onMessage("server", {
        type = "snapshot",
        seq = 1,
        players = {
            { slot = "player1", x = 25, y = 25, hp = 100, cooldowns = { q = 7.2, w = 0, e = 0 }, stunned = false, stunRemaining = 0 },
        },
        abilities = {
            { id = 9, ability = "beam", owner = "player1", x = 25, y = 25, remaining = 0.35, directionX = 1, directionY = 0, phase = "charging" },
        },
    })

    state = session:getState()
    assertEqual(#state.abilities, 1)
    assertEqual(state.abilities[1].id, 9)
    assertNear(state.abilities[1].directionX, 1, 0.001)
    assertNear(state.cooldowns.q, 7.2, 0.001)
end)

test("client predicts its trap and reconciles authoritative trap/stun", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", {
        type = "welcome",
        slot = "player1",
        loadout = { q = "beam", w = "morganapool", e = "beartrap" },
    })
    session:drainOutbox()

    session:localCastIntent("e", 100, 25)

    local state = session:getState()
    assertEqual(#state.abilities, 1, "predicted trap should appear immediately")
    assertEqual(state.abilities[1].ability, "beartrap")
    assertEqual(state.abilities[1].armed, false)

    session:onMessage("server", {
        type = "snapshot",
        seq = 1,
        players = {
            { slot = "player1", x = 25, y = 25, hp = 100, cooldowns = { q = 0, w = 0, e = 4.0 }, stunned = true, stunRemaining = 1.5 },
        },
        abilities = {
            { id = 5, ability = "beartrap", owner = "player1", x = 100, y = 25, remaining = 29.0, armed = true, armRemaining = 0, radius = 20 },
        },
    })

    state = session:getState()
    assertEqual(#state.abilities, 1)
    assertEqual(state.abilities[1].id, 5)
    assertEqual(state.abilities[1].armed, true)
    assertTrue(state.players.player1.stunned, "local player should be stunned from the snapshot")
end)

test("client reflects a remote player's stun from snapshots", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", { type = "welcome", slot = "player1" })

    session:onMessage("server", {
        type = "snapshot",
        seq = 1,
        players = {
            { slot = "player2", x = 175, y = 175, hp = 100, stunned = true, stunRemaining = 1.0 },
        },
    })
    session:tick(1 / 30)

    local remote = session:getState().players.player2
    assertTrue(remote ~= nil, "remote player should be rendered")
    assertTrue(remote.stunned, "remote stun should be reflected")
end)

----------------------------------------
-- Runner
----------------------------------------
local function run()
    local passed = 0
    local failed = 0

    for _, entry in ipairs(tests) do
        local ok, err = pcall(entry.fn)
        if ok then
            passed = passed + 1
            print("PASS  " .. entry.name)
        else
            failed = failed + 1
            print("FAIL  " .. entry.name)
            print("      " .. tostring(err))
        end
    end

    print(string.format("%d passed, %d failed", passed, failed))
    if failed == 0 then
        print("ALL TESTS PASSED")
        return true
    end
    print("SOME TESTS FAILED")
    return false
end

return run
