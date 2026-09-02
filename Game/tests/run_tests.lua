-- Headless test harness for the game-session module (the transport-agnostic seam).
-- Run via: lovec.exe . --test   (exit code 0 = pass, 1 = fail)

local World = require("src.world")
local Game = require("src.game")
local Session = require("src.session")
local registry = require("src.abilities.registry")
local Anim = require("src.anim.engine")
local Particles = require("src.particles")

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

test("default loadout and cooldowns include an r slot bound to morganastun", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    local loadout = game:getLoadout("player1")
    assertEqual(loadout.q, "beam")
    assertEqual(loadout.w, "morganapool")
    assertEqual(loadout.e, "beartrap")
    assertEqual(loadout.r, "morganastun")

    local cooldowns = game:getCooldowns("player1")
    assertEqual(cooldowns.r, 0, "r cooldown starts at zero")
end)

test("default loadout and cooldowns include a d slot bound to missile", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    local loadout = game:getLoadout("player1")
    assertEqual(loadout.d, "missile")

    local cooldowns = game:getCooldowns("player1")
    assertEqual(cooldowns.d, 0, "d cooldown starts at zero")
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
    assertEqual(module.charge, 0.5)
    assertEqual(module.cancelable, true)
    assertEqual(module.blockedByObstacles, true)
end)

test("ability registry loads missile with its declared properties", function()
    local module = registry.load("missile")
    assertTrue(module ~= nil, "missile module should load")
    assertEqual(module.name, "Missile")
    assertEqual(module.type, "missile")
    assertEqual(module.shape, "circle")
    assertEqual(module.damageModel, "burst")
    assertEqual(module.cooldown, 8)
    assertEqual(module.damage, 60)
    assertEqual(module.range, 300)
    assertEqual(module.radius, 55)
    assertEqual(module.fallDuration, 1.0)
    assertEqual(module.fadeDuration, 0.7)
    assertEqual(module.cancelable, false)
    assertEqual(module.blockedByObstacles, true)
    assertEqual(module.icon.col, 1, "missile icon tile index 4 -> col 1")
    assertEqual(module.icon.row, 1, "missile icon tile index 4 -> row 1")
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

    -- All casts use open ground (200,25 lies outside the central obstacle) so
    -- this test exercises cooldown blocking, not obstacle rejection.
    assertEqual(game:castAbility("player1", "w", 200, 25), nil, "recast during cooldown should be rejected")

    for _ = 1, 177 do game:tick(1 / 30) end -- ~5.9s
    assertEqual(game:castAbility("player1", "w", 200, 25), nil, "recast before the cooldown expires should be rejected")

    for _ = 1, 9 do game:tick(1 / 30) end -- ~6.2s total
    local again = game:castAbility("player1", "w", 200, 25)
    assertTrue(again ~= nil, "cast should succeed after the cooldown expires")
end)

test("pool spawns with a windup and expires after windup + duration", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:castAbility("player1", "w", 200, 25)
    assertEqual(#game:getAbilities(), 1)

    -- Windup (0.5s) + duration (2s) = 2.5s total = 75 ticks.
    for _ = 1, 74 do game:tick(1 / 30) end
    assertEqual(#game:getAbilities(), 1, "pool should still be active just under 2.5s")

    for _ = 1, 3 do game:tick(1 / 30) end
    assertEqual(#game:getAbilities(), 0, "pool should expire after windup + duration")
end)

test("a player standing in a pool loses health in ticks after the windup", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:castAbility("player1", "w", 25, 25) -- pool centered on the caster

    assertEqual(game:getHealth("player1"), 100)

    -- Windup (0.5s) completes around tick 16; no damage is dealt during it.
    for _ = 1, 16 do game:tick(1 / 30) end
    assertEqual(game:getHealth("player1"), 100, "no damage during the windup")

    -- ~0.3s active -> one 0.25s tick (7.5 damage).
    for _ = 1, 9 do game:tick(1 / 30) end
    assertNear(game:getHealth("player1"), 92.5, 0.01, "one tick = 7.5 damage")

    -- ~1.03s active total -> four ticks (30 damage).
    for _ = 1, 22 do game:tick(1 / 30) end
    assertNear(game:getHealth("player1"), 70, 0.01, "four ticks = 30 damage")
end)

test("health never drops below 0", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:setHealth("player1", 3)
    game:castAbility("player1", "w", 25, 25)
    for _ = 1, 15 do game:tick(1 / 30) end -- windup
    for _ = 1, 10 do game:tick(1 / 30) end -- one tick (7.5) exceeds remaining 3

    assertEqual(game:getHealth("player1"), 0)
end)

test("loadout resolves q, w, e, and r slots", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    local qx = game:castAbility("player1", "q", 100, 100)
    assertTrue(qx ~= nil, "q slot should resolve to beam")

    local wx, wy = game:castAbility("player1", "w", 200, 25) -- open ground (outside the central obstacle)
    assertTrue(wx ~= nil, "w slot should resolve to morganapool")
    assertEqual(wx, 200)
    assertEqual(wy, 25)

    local ex = game:castAbility("player1", "e", 50, 50)
    assertTrue(ex ~= nil, "e slot should resolve to beartrap")

    local rx = game:castAbility("player1", "r", 100, 100)
    assertTrue(rx ~= nil, "r slot should resolve to morganastun")
end)

test("default loadout resolves the d slot to missile", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    local dx = game:castAbility("player1", "d", 100, 25)
    assertTrue(dx ~= nil, "d slot should resolve to missile")
    assertEqual(#game:getAbilities(), 1)
    assertEqual(game:getAbilities()[1].abilityId, "missile")
    assertEqual(game:getAbilities()[1].phase, "falling")
end)

test("missile cast clamps the target to its 300px range", function()
    local config = makeConfig()
    config.window = { title = "test", width = 800, height = 600 }
    config.player.spawnPoints = { { x = 100, y = 100 }, { x = 700, y = 500 } }
    config.obstacles = {} -- open ground everywhere
    local game = Game.new(config)
    game:spawnPlayer("player1")

    -- A click 700px away clamps to the 300px range in the clicked direction.
    local cx, cy = game:castAbility("player1", "d", 800, 100)
    assertTrue(cx ~= nil, "missile cast should succeed")
    assertEqual(cx, 400, "target should clamp to 300px horizontally")
    assertEqual(cy, 100)

    -- A click inside the range is placed unclamped.
    game:setCooldowns("player1", { q = 0, w = 0, e = 0, r = 0, d = 0 })
    local cx2, cy2 = game:castAbility("player1", "d", 300, 100)
    assertTrue(cx2 ~= nil, "second missile cast should succeed")
    assertEqual(cx2, 300)
    assertEqual(cy2, 100)
end)

test("missile cooldown starts on cast and blocks a recast for 8s", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    local cx = game:castAbility("player1", "d", 100, 25)
    assertTrue(cx ~= nil, "first missile cast should succeed")
    assertEqual(game:getCooldowns("player1").d, 8, "missile cooldown starts at cast")

    assertEqual(game:castAbility("player1", "d", 50, 25), nil, "recast during the cooldown should be rejected")

    for _ = 1, 177 do game:tick(1 / 30) end -- ~5.9s
    assertEqual(game:castAbility("player1", "d", 50, 25), nil, "recast before the cooldown expires should be rejected")

    for _ = 1, 66 do game:tick(1 / 30) end -- ~8.1s total
    local again = game:castAbility("player1", "d", 50, 25)
    assertTrue(again ~= nil, "cast should succeed after the cooldown expires")
end)

test("missile placement is rejected when its center is inside an obstacle", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    -- The central obstacle spans (75..125, 75..125): a rejected cast must not
    -- spawn anything or start the cooldown.
    assertEqual(game:castAbility("player1", "d", 100, 100), nil, "missile centered inside an obstacle should be rejected")
    assertEqual(#game:getAbilities(), 0)
    assertEqual(game:getCooldowns("player1").d, 0, "a rejected cast must not start the cooldown")

    -- A missile whose circle overlaps the wall but whose center is outside is
    -- allowed, matching Bear Trap's open-ground rule.
    local cx = game:castAbility("player1", "d", 74, 100)
    assertTrue(cx ~= nil, "missile with its center outside the obstacle should place")
    assertEqual(#game:getAbilities(), 1)
end)

test("missile falls without damage and bursts once for 60 to everyone in range including the caster", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")
    -- A missile on the caster: player1 (25,25) sits on the blast center and
    -- player2 (60,25) is 35px away; both are inside the 55px blast radius
    -- (reach = radius 55 + player radius 8 = 63).
    game:setPosition("player2", 60, 25)
    game:castAbility("player1", "d", 25, 25)
    assertEqual(game:getAbilities()[1].phase, "falling")

    for _ = 1, 27 do game:tick(1 / 30) end -- ~0.9s, still falling
    assertEqual(game:getHealth("player1"), 100, "no damage to the caster during the fall")
    assertEqual(game:getHealth("player2"), 100, "no damage to the victim during the fall")
    assertEqual(game:getAbilities()[1].phase, "falling", "missile should still be falling at 0.9s")

    for _ = 1, 6 do game:tick(1 / 30) end -- ~1.1s total: the impact has landed
    assertEqual(game:getHealth("player1"), 40, "the caster takes the full 60-damage burst")
    assertEqual(game:getHealth("player2"), 40, "an overlapping victim takes the full 60-damage burst")
    assertEqual(game:getAbilities()[1].phase, "impact", "missile enters the impact fade after the burst")

    -- The burst fires exactly once: health stays put through the rest of the fade.
    for _ = 1, 30 do game:tick(1 / 30) end -- ~2.1s total
    assertEqual(game:getHealth("player1"), 40, "the burst must not repeat")
    assertEqual(game:getHealth("player2"), 40)
end)

test("missile instance is removed after the fall + fade window", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:castAbility("player1", "d", 100, 25) -- away from the caster: nobody gets hit
    assertEqual(#game:getAbilities(), 1)

    for _ = 1, 27 do game:tick(1 / 30) end -- ~0.9s: still falling
    assertEqual(game:getAbilities()[1].phase, "falling", "missile should still be falling at 0.9s")

    for _ = 1, 6 do game:tick(1 / 30) end -- ~1.1s total: fall done, fade in progress
    assertEqual(game:getAbilities()[1].phase, "impact", "missile should be fading out at 1.1s")

    for _ = 1, 24 do game:tick(1 / 30) end -- ~1.9s total > 1.0s fall + 0.7s fade
    assertEqual(#game:getAbilities(), 0, "missile should be removed after fall + fade")
end)

test("missile cast is instant and does not root the caster", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:setTarget("player1", 175, 25)
    game:tick(1 / 30)
    assertTrue(game:getPlayer("player1").x > 25, "player should start moving before casting")

    game:castAbility("player1", "d", 25, 175) -- off the movement path
    assertEqual(game:isRooted("player1"), false, "missile cast must not root the caster")
    local xAtCast = game:getPlayer("player1").x

    for _ = 1, 30 do game:tick(1 / 30) end -- through the whole 1.0s fall
    assertTrue(game:getPlayer("player1").x > xAtCast, "caster should keep moving while the missile falls")
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
    assertEqual(welcome.loadout.r, "morganastun")
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
    session:onMessage(1, { type = "castIntent", slot = "x", x = 100, y = 100 })

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
            { id = 7, ability = "morganapool", x = 60, y = 25, radius = 60, owner = "player1", remaining = 0.4, phase = "active" },
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
    assertEqual(module.radius, 10)
    assertEqual(module.armDelay, 0.75)
    assertEqual(module.duration, 30)
    assertEqual(module.stunDuration, 2)
    assertEqual(module.maxActive, 4)
    assertEqual(module.castRoot, 0.5)
    assertEqual(module.cancelable, false)
    assertEqual(module.blockedByObstacles, true)
end)

test("ability registry loads morganastun with its declared properties", function()
    local module = registry.load("morganastun")
    assertTrue(module ~= nil, "morganastun module should load")
    assertEqual(module.name, "Morgana's Stun")
    assertEqual(module.type, "projectile")
    assertEqual(module.trigger, "projectile")
    assertEqual(module.damageModel, "none")
    assertEqual(module.cooldown, 10)
    assertEqual(module.damage, 0)
    assertEqual(module.range, 500)
    assertEqual(module.speed, 315)
    assertEqual(module.radius, 14)
    assertEqual(module.charge, 0.5)
    assertEqual(module.stunDuration, 2)
    assertEqual(module.cancelable, true)
end)

test("abilities declare their HUD tilemap icon slots", function()
    local beam = registry.load("beam")
    local trap = registry.load("beartrap")
    local stun = registry.load("morganastun")
    assertEqual(beam.icon.col, 0)
    assertEqual(beam.icon.row, 0)
    assertEqual(trap.icon.col, 1)
    assertEqual(trap.icon.row, 0)
    assertEqual(stun.icon.col, 2)
    assertEqual(stun.icon.row, 0)
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
-- Game: windup retrofit + morganastun
----------------------------------------
test("pool windup roots the caster and delays its damage", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")
    game:setPosition("player2", 100, 25)

    game:setTarget("player1", 175, 25)
    game:tick(1 / 30)
    assertTrue(game:getPlayer("player1").x > 25, "player should start moving before casting")

    game:castAbility("player1", "w", 100, 25)
    local xAtCast = game:getPlayer("player1").x
    local pool = game:getAbilities()[1]
    assertEqual(pool.abilityId, "morganapool")
    assertEqual(pool.phase, "charging")

    for _ = 1, 14 do game:tick(1 / 30) end -- ~0.47s, still charging
    assertNear(game:getPlayer("player1").x, xAtCast, 0.001, "caster rooted during pool windup")
    assertEqual(game:getHealth("player2"), 100, "pool deals no damage during windup")

    for _ = 1, 12 do game:tick(1 / 30) end -- windup done + ~0.4s active
    assertTrue(game:getHealth("player2") < 100, "pool should deal damage after the windup")
    assertTrue(game:getPlayer("player1").x > xAtCast, "caster resumes moving after the windup")
end)

test("stun during pool windup cancels the cast and refunds the cooldown", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:castAbility("player1", "e", 150, 25) -- trap away from the caster
    for _ = 1, 30 do game:tick(1 / 30) end -- ~1s: armed

    game:castAbility("player1", "w", 100, 25)
    assertEqual(game:getCooldowns("player1").w, 6, "pool cooldown starts at cast")

    game:setPosition("player1", 150, 25)
    game:tick(1 / 30)

    assertTrue(game:isStunned("player1"), "caster should be stunned by the armed trap")
    assertEqual(game:getCooldowns("player1").w, 0, "stun should refund the pool cooldown")

    local pools = 0
    for _, ability in ipairs(game:getAbilities()) do
        if ability.type == "pool" then pools = pools + 1 end
    end
    assertEqual(pools, 0, "interrupted pool should be cancelled")
end)

test("trap roots the caster for 0.5s while arming on its 0.75s delay", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:setTarget("player1", 175, 25)
    game:tick(1 / 30)
    assertTrue(game:getPlayer("player1").x > 25, "player should start moving before casting")

    game:castAbility("player1", "e", 25, 175) -- off the movement path
    local xAtCast = game:getPlayer("player1").x
    local trap = game:getAbilities()[1]
    assertEqual(trap.abilityId, "beartrap")
    assertEqual(trap.armed, false)

    for _ = 1, 14 do game:tick(1 / 30) end -- ~0.47s
    assertNear(game:getPlayer("player1").x, xAtCast, 0.001, "caster rooted during the trap cast")
    assertEqual(trap.armed, false, "trap still arming during the root")

    for _ = 1, 6 do game:tick(1 / 30) end -- ~0.67s total
    assertTrue(game:getPlayer("player1").x > xAtCast, "caster moves again after the 0.5s root")
    assertEqual(trap.armed, false, "trap still arming at 0.67s")

    for _ = 1, 6 do game:tick(1 / 30) end -- ~0.87s total
    assertEqual(trap.armed, true, "trap arms at 0.75s")
end)

test("stun during the trap root does not refund or remove the placed trap", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:castAbility("player1", "e", 150, 25) -- trap A away from the caster
    for _ = 1, 30 do game:tick(1 / 30) end -- ~1s: armed

    game:setCooldowns("player1", { q = 0, w = 0, e = 0, r = 0 })
    game:castAbility("player1", "e", 25, 25) -- trap B at the caster's feet (roots 0.5s)
    assertEqual(game:getCooldowns("player1").e, 6, "trap cooldown starts at cast")

    game:setPosition("player1", 150, 25)
    game:tick(1 / 30) -- trap A triggers and stuns the caster during trap B's root

    assertTrue(game:isStunned("player1"))
    assertTrue(game:getCooldowns("player1").e > 0, "trap cooldown must NOT be refunded")

    -- Trap A lingers while it snaps/fades; trap B is still down at the caster's
    -- feet. Both are counted while A is despawning.
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 2, "triggered trap A lingers while despawning")
    local trapA, trapB
    for _, ability in ipairs(game:getAbilities()) do
        if ability.abilityId == "beartrap" then
            if ability.x == 150 then trapA = ability end
            if ability.x == 25 then trapB = ability end
        end
    end
    assertTrue(trapB ~= nil, "the placed trap B stays down")
    assertEqual(trapA.phase, "despawning", "triggered trap A enters the despawn phase")

    -- Once trap A's linger completes, only trap B remains.
    for _ = 1, 20 do game:tick(1 / 30) end -- ~0.67s: A despawned, B still arming
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 1, "only trap B remains after A despawns")
    assertTrue(game:isStunned("player1"), "the 2s stun from trap A is still in effect")
end)

test("morganastun windup roots the caster, then the projectile stuns the enemy", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")
    game:setPosition("player2", 150, 25)

    game:setTarget("player1", 175, 25)
    game:tick(1 / 30)
    assertTrue(game:getPlayer("player1").x > 25, "player should start moving before casting")

    game:castAbility("player1", "r", 500, 25)
    local xAtCast = game:getPlayer("player1").x
    local ability = game:getAbilities()[1]
    assertEqual(ability.abilityId, "morganastun")
    assertEqual(ability.phase, "charging")

    for _ = 1, 14 do game:tick(1 / 30) end -- ~0.47s, still charging
    assertNear(game:getPlayer("player1").x, xAtCast, 0.001, "caster rooted during the windup")
    assertEqual(game:isStunned("player2"), false, "no hit during the windup")

    for _ = 1, 20 do game:tick(1 / 30) end -- windup + flight
    assertTrue(game:isStunned("player2"), "projectile should stun the first enemy it reaches")
    assertEqual(game:isStunned("player1"), false, "projectile must never hit its caster")
    assertEqual(game:getHealth("player2"), 100, "morganastun deals no damage")
    assertEqual(#game:getAbilities(), 0, "projectile despawns on hit")
end)

test("morganastun projectile despawns after its full range", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:castAbility("player1", "r", 500, 25)

    -- Windup (~0.5s) + full flight (500px at 315px/s ~1.59s) is ~2.1s total.
    for _ = 1, 70 do game:tick(1 / 30) end
    assertEqual(#game:getAbilities(), 0, "projectile should despawn after covering its full range")
end)

test("morganastun projectile passes over obstacles", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")
    game:setPosition("player1", 25, 100)
    game:setPosition("player2", 175, 100)

    game:castAbility("player1", "r", 500, 100) -- horizontal shot crossing the obstacle
    for _ = 1, 40 do game:tick(1 / 30) end

    assertTrue(game:isStunned("player2"), "projectile should cross the obstacle and hit")
    assertEqual(game:isStunned("player1"), false, "projectile must never hit its caster")
end)

test("stun during morganastun windup cancels the cast and refunds the cooldown", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:castAbility("player1", "e", 150, 25)
    for _ = 1, 30 do game:tick(1 / 30) end -- ~1s: armed

    game:castAbility("player1", "r", 500, 25)
    assertEqual(game:getCooldowns("player1").r, 10, "morganastun cooldown starts at cast")

    game:setPosition("player1", 150, 25)
    game:tick(1 / 30)

    assertTrue(game:isStunned("player1"))
    assertEqual(game:getCooldowns("player1").r, 0, "stun refunds the morganastun cooldown")

    local projectiles = 0
    for _, ability in ipairs(game:getAbilities()) do
        if ability.type == "projectile" then projectiles = projectiles + 1 end
    end
    assertEqual(projectiles, 0, "interrupted morganastun should be cancelled")
end)

test("morganastun projectile simulation is deterministic across two games", function()
    local function simulate()
        local game = Game.new(makeConfig())
        game:spawnPlayer("player1")
        game:spawnPlayer("player2")
        game:setPosition("player2", 150, 25)
        game:castAbility("player1", "r", 500, 25)
        for _ = 1, 30 do game:tick(1 / 30) end
        return game:isStunned("player2"), game:getStunRemaining("player2"), #game:getAbilities()
    end

    local s1, r1, c1 = simulate()
    local s2, r2, c2 = simulate()
    assertEqual(s1, s2, "deterministic stun state")
    assertEqual(r1, r2, "deterministic stun remaining")
    assertEqual(c1, c2, "deterministic ability count")
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

test("pool center cannot be inside an obstacle but may overlap its edge", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    -- The central obstacle spans (75..125, 75..125). Centered inside it, the
    -- pool must be rejected (a rejected cast does not start the cooldown).
    assertEqual(game:castAbility("player1", "w", 100, 100), nil, "pool centered inside an obstacle should be rejected")

    -- A pool whose circle overlaps the wall but whose center is outside (74 is
    -- just past the obstacle's 75 edge) is allowed.
    local cx = game:castAbility("player1", "w", 74, 100)
    assertTrue(cx ~= nil, "pool with its center outside the obstacle should place")
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

    -- Step onto the armed trap: it stuns instantly and enters the despawn
    -- phase (snap shut + fade) instead of being removed on the spot.
    game:setPosition("player1", 150, 25)
    game:tick(1 / 30)

    assertTrue(game:isStunned("player1"), "armed trap should stun the overlapping player")
    assertEqual(game:getStunRemaining("player1"), 2, "stun lasts 2s")
    local trap = game:getAbilities()[1]
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 1, "trap lingers while despawning")
    assertEqual(trap.phase, "despawning", "triggered trap should enter the despawn phase")

    -- The ~0.45s despawn linger completes and only then is the trap removed.
    for _ = 1, 14 do game:tick(1 / 30) end -- ~0.47s
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 0, "trap removed after the despawn linger")
end)

test("armed trap triggers only inside its smaller trigger radius", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")

    -- Player2 arms a trap at (100, 25), away from both spawns.
    game:castAbility("player2", "e", 100, 25)
    for _ = 1, 30 do game:tick(1 / 30) end -- ~1s: armed

    -- Reach = trap radius (10) + player radius (8) = 18px. A player standing
    -- 24px from the trap center grazes the 40px sprite but stays outside the
    -- trigger circle: no stun, and the trap stays armed.
    game:setPosition("player1", 124, 25)
    game:tick(1 / 30)
    assertEqual(game:isStunned("player1"), false, "player at 24px (outside the 18px reach) must not trigger")
    assertEqual(game:getAbilities()[1].phase, "armed", "trap stays armed")
    assertEqual(game:countActiveAbilities("player2", "beartrap"), 1)

    -- Stepping to 18px (the reach boundary) triggers instantly.
    game:setPosition("player1", 118, 25)
    game:tick(1 / 30)
    assertTrue(game:isStunned("player1"), "player at the 18px reach boundary must be stunned")
    assertEqual(game:getAbilities()[1].phase, "despawning", "trap enters despawn on trigger")
end)

test("trap rotates so its bottom points at the victim when triggered", function()
    -- Victim to the RIGHT of the trap: the pod's bottom tip (sprite-local
    -- down) must end up pointing right, i.e. rotation = atan2(dy, dx) - pi/2
    -- = -pi/2.
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")
    game:castAbility("player2", "e", 100, 25)
    for _ = 1, 30 do game:tick(1 / 30) end -- ~1s: armed

    game:setPosition("player1", 118, 25)
    game:tick(1 / 30)
    assertTrue(game:isStunned("player1"), "victim to the right should be stunned")
    assertNear(game:getAbilities()[1].rotation, -math.pi / 2, 0.001, "bottom points right at a victim on the right")

    -- Victim BELOW the trap: the bottom already points down, so no rotation
    -- is applied (rotation = pi/2 - pi/2 = 0).
    local game2 = Game.new(makeConfig())
    game2:spawnPlayer("player1")
    game2:spawnPlayer("player2")
    game2:castAbility("player2", "e", 100, 25)
    for _ = 1, 30 do game2:tick(1 / 30) end -- ~1s: armed

    game2:setPosition("player1", 100, 43)
    game2:tick(1 / 30)
    assertTrue(game2:isStunned("player1"), "victim below should be stunned")
    assertNear(game2:getAbilities()[1].rotation, 0, 0.001, "bottom already points down at a victim below")

    -- Victim directly ABOVE the trap: the pod's vertical axis already points
    -- their way, so the deadzone keeps rotation 0 (a 180 deg flip on the
    -- symmetric pod would be pointless).
    local game3 = Game.new(makeConfig())
    game3:spawnPlayer("player1")
    game3:spawnPlayer("player2")
    game3:castAbility("player2", "e", 100, 25)
    for _ = 1, 30 do game3:tick(1 / 30) end -- ~1s: armed

    game3:setPosition("player1", 100, 7)
    game3:tick(1 / 30)
    assertTrue(game3:isStunned("player1"), "victim above should be stunned")
    assertNear(game3:getAbilities()[1].rotation, 0, 0.001, "no rotation for a victim directly above")
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
    assertEqual(game:castAbility("player1", "r", 500, 25), nil, "stunned player cannot cast morganastun")
end)

test("trap expires after its duration", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:castAbility("player1", "e", 100, 25)
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 1)

    for _ = 1, 29 * 30 do game:tick(1 / 30) end -- ~29s
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 1, "trap should still be alive just under 30s")

    -- At 30s the trap enters the same despawn phase as a triggered one instead
    -- of vanishing instantly, and stays counted active during the linger.
    for _ = 1, 40 do game:tick(1 / 30) end -- ~30.33s total
    local trap = game:getAbilities()[1]
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 1, "trap is counted active while despawning")
    assertEqual(trap.phase, "despawning", "trap should enter despawning at 30s, not vanish instantly")

    for _ = 1, 25 do game:tick(1 / 30) end -- ~31.17s total
    assertEqual(game:countActiveAbilities("player1", "beartrap"), 0, "trap removed after 30s + 0.45s despawn")
end)

test("a triggered trap stuns instantly and is removed after the ~0.45s despawn", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")

    -- Player2 arms a trap away from both spawns, then player1 steps on it.
    game:castAbility("player2", "e", 100, 25)
    for _ = 1, 30 do game:tick(1 / 30) end -- ~1s: armed
    game:setPosition("player1", 100, 25)
    game:tick(1 / 30) -- trigger

    assertTrue(game:isStunned("player1"), "stun must land the instant of overlap")
    assertNear(game:getStunRemaining("player1"), 2, 0.001)
    assertEqual(game:countActiveAbilities("player2", "beartrap"), 1, "trap stays counted active during despawn")

    -- ~0.4s after the trigger it is still despawning; just past 0.45s it is
    -- removed by the engine's sweep.
    for _ = 1, 11 do game:tick(1 / 30) end -- ~0.37s since trigger
    assertEqual(game:countActiveAbilities("player2", "beartrap"), 1, "trap still despawning at ~0.4s")

    for _ = 1, 3 do game:tick(1 / 30) end -- ~0.47s since trigger
    assertEqual(game:countActiveAbilities("player2", "beartrap"), 0, "trap removed just after 0.45s")
end)

test("a despawning trap does not re-trigger", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:spawnPlayer("player2")

    -- Player2 arms a trap away from both spawns.
    game:castAbility("player2", "e", 100, 25)
    for _ = 1, 30 do game:tick(1 / 30) end -- ~1s: armed

    -- Player1 steps on it: stun lands and the trap enters its despawn.
    game:setPosition("player1", 100, 25)
    game:tick(1 / 30)
    assertTrue(game:isStunned("player1"), "first overlapping player is stunned")

    -- Player2 walks onto the same trap during the despawn: no second stun.
    game:setPosition("player2", 100, 25)
    for _ = 1, 10 do game:tick(1 / 30) end -- ~0.33s into the 0.45s despawn
    assertEqual(game:isStunned("player2"), false, "despawning trap must not re-trigger")
    assertTrue(game:isStunned("player1"), "first stun still in effect")

    -- The trap is consumed exactly once: it finishes its linger and is gone.
    for _ = 1, 10 do game:tick(1 / 30) end -- ~0.67s after trigger
    assertEqual(game:countActiveAbilities("player2", "beartrap"), 0, "trap is consumed exactly once")
end)

test("snapshots carry the trap despawn state", function()
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")

    game:castAbility("player1", "e", 100, 25)
    for _ = 1, 30 do game:tick(1 / 30) end -- ~1s: armed

    -- Victim steps on from the right of the trap: the pod's bottom tip
    -- (sprite-local down) rotates -90 deg to face them (rotation =
    -- atan2(dy, dx) - pi/2 = -pi/2).
    game:setPosition("player1", 115, 25)
    game:tick(1 / 30) -- trigger: despawn begins
    local trap = game:getAbilities()[1]
    assertEqual(trap.phase, "despawning")
    assertNear(trap.rotation, -math.pi / 2, 0.001, "trap aims its bottom at the victim")

    -- The module's own snapshot contract round-trips the despawn state.
    local entry = trap:getSnapshot()
    assertEqual(entry.phase, "despawning")
    assertEqual(entry.armed, false)
    assertTrue(entry.despawnRemaining ~= nil and entry.despawnRemaining > 0, "snapshot carries despawnRemaining")
    assertNear(entry.rotation, -math.pi / 2, 0.001, "snapshot carries the aim rotation")

    local clone = registry.new("beartrap", "player1", 100, 25, 0)
    clone:applySnapshot(entry)
    assertEqual(clone.phase, "despawning")
    assertEqual(clone.armed, false)
    assertNear(clone.despawnRemaining, entry.despawnRemaining, 0.0001, "despawn timer round-trips")
    assertNear(clone.rotation, -math.pi / 2, 0.001, "aim rotation round-trips through applySnapshot")

    -- The serialized abilities list carries the same fields for the wire.
    local list = game:getAbilitiesSnapshot()
    assertEqual(#list, 1)
    assertEqual(list[1].phase, "despawning")
    assertEqual(list[1].armed, false)
    assertNear(list[1].despawnRemaining, trap.despawnRemaining, 0.0001, "despawn fields appear in the abilities list")
    assertNear(list[1].rotation, -math.pi / 2, 0.001, "aim rotation appears in the abilities list")
end)

test("beam and trap simulation is deterministic across two sessions", function()
    local function simulate()
        local session = newServerSession()
        session:onConnect(1)
        session:onConnect(2)
        session:drainOutbox()
        session:onMessage(1, { type = "castIntent", slot = "q", x = 200, y = 25 })
        session:onMessage(2, { type = "castIntent", slot = "e", x = 175, y = 175 })

        -- Sample the full trap lifecycle: arming (10), despawn (30), removal
        -- (100) -- the trap arms at ~0.75s, triggers under player2, and is
        -- removed ~0.45s later. Two identical sessions must agree at every
        -- checkpoint, including the despawn phase and the aim rotation.
        local samples = {}
        local function sample()
            local state = session:getState()
            local trapPhase = nil
            local trapRot = nil
            for _, ability in ipairs(state.abilities) do
                if ability.ability == "beartrap" then
                    trapPhase = ability.phase
                    trapRot = ability.rotation
                end
            end
            return string.format("hp=%s:stun2=%s:count=%s:trapPhase=%s:trapRot=%s",
                tostring(state.players.player1.hp), tostring(state.players.player2.stunned),
                tostring(#state.abilities), tostring(trapPhase), tostring(trapRot))
        end
        for i = 1, 100 do
            session:tick(1 / 30)
            if i == 10 or i == 30 or i == 100 then
                table.insert(samples, sample())
            end
        end
        return table.concat(samples, "|")
    end

    local s1 = simulate()
    local s2 = simulate()
    assertEqual(s1, s2, "deterministic full trap lifecycle across two sessions")
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

    -- The triggered trap is still playing its 0.45s despawn linger; let it
    -- finish, then confirm the stunned player's cast produced nothing.
    for _ = 1, 20 do session:tick(1 / 30) end
    assertEqual(#session:getState().abilities, 0, "stunned player's cast intent should be ignored")
end)

test("server castIntent accepts the r slot and spawns a charging morganastun", function()
    local session = newServerSession()
    session:onConnect(1)
    session:drainOutbox()

    session:onMessage(1, { type = "castIntent", slot = "r", x = 500, y = 25 })
    session:tick(1 / 30)

    local abilities = session:getState().abilities
    assertEqual(#abilities, 1)
    assertEqual(abilities[1].ability, "morganastun")
    assertEqual(abilities[1].owner, "player1")
    assertEqual(abilities[1].phase, "charging")
    assertNear(abilities[1].directionX, 1, 0.001, "morganastun should aim toward the click")
    assertNear(abilities[1].directionY, 0, 0.001)
end)

test("snapshots carry the r cooldown and projectile state", function()
    local session = newServerSession()
    session:onConnect(1)
    session:onConnect(2)
    session:drainOutbox()

    session:onMessage(1, { type = "castIntent", slot = "r", x = 500, y = 25 })
    session:tick(1 / 30)

    local snapshot
    for _, entry in ipairs(session:drainOutbox()) do
        if entry.message.type == "snapshot" then snapshot = entry.message end
    end
    assertTrue(snapshot ~= nil, "expected a snapshot")

    local p1
    for _, p in ipairs(snapshot.players) do
        if p.slot == "player1" then p1 = p end
    end
    assertTrue(p1 ~= nil)
    assertTrue(p1.cooldowns.r > 0, "r cooldown should be reflected in the snapshot")

    local stunFound = false
    for _, ability in ipairs(snapshot.abilities) do
        if ability.ability == "morganastun" and ability.phase == "charging" then
            stunFound = true
        end
    end
    assertTrue(stunFound, "snapshot should carry the charging morganastun")
end)

test("server castIntent accepts the d slot and spawns an authoritative missile", function()
    local session = newServerSession()
    session:onConnect(1)
    session:drainOutbox()

    session:onMessage(1, { type = "castIntent", slot = "d", x = 100, y = 25 })
    session:tick(1 / 30)

    local abilities = session:getState().abilities
    assertEqual(#abilities, 1)
    assertEqual(abilities[1].ability, "missile")
    assertEqual(abilities[1].owner, "player1")
    assertEqual(abilities[1].x, 100)
    assertEqual(abilities[1].y, 25)
    assertEqual(abilities[1].phase, "falling")
end)

test("snapshots carry the d cooldown and the missile's phase", function()
    local session = newServerSession()
    session:onConnect(1)
    session:onConnect(2)
    session:drainOutbox()

    session:onMessage(1, { type = "castIntent", slot = "d", x = 100, y = 25 })
    session:tick(1 / 30)

    local snapshot
    for _, entry in ipairs(session:drainOutbox()) do
        if entry.message.type == "snapshot" then snapshot = entry.message end
    end
    assertTrue(snapshot ~= nil, "expected a snapshot")

    local p1
    for _, p in ipairs(snapshot.players) do
        if p.slot == "player1" then p1 = p end
    end
    assertTrue(p1 ~= nil)
    assertTrue(p1.cooldowns.d > 0, "d cooldown should be reflected in the snapshot")

    local missileFound = false
    for _, ability in ipairs(snapshot.abilities) do
        if ability.ability == "missile" and ability.phase == "falling" and ability.radius == 55 then
            missileFound = true
        end
    end
    assertTrue(missileFound, "snapshot should carry the falling missile with its radius")
end)

test("invalid cast slots are ignored and d is now valid", function()
    local session = newServerSession()
    session:onConnect(1)
    session:drainOutbox()

    session:onMessage(1, { type = "castIntent", slot = "x", x = 100, y = 25 })
    assertEqual(#session:getState().abilities, 0, "an unknown slot should be ignored")

    session:onMessage(1, { type = "castIntent", slot = "d", x = 100, y = 25 })
    session:tick(1 / 30)
    assertEqual(#session:getState().abilities, 1, "the d slot should be accepted")
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
            { id = 5, ability = "beartrap", owner = "player1", x = 100, y = 25, remaining = 29.0, armed = true, armRemaining = 0, radius = 10 },
        },
    })

    state = session:getState()
    assertEqual(#state.abilities, 1)
    assertEqual(state.abilities[1].id, 5)
    assertEqual(state.abilities[1].armed, true)
    assertTrue(state.players.player1.stunned, "local player should be stunned from the snapshot")
end)

test("client predicts a triggered trap's despawn and reconciles it", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", {
        type = "welcome",
        slot = "player1",
        loadout = { q = nil, w = nil, e = "beartrap" },
    })
    session:drainOutbox()

    -- Predict a cast at the caster's feet; the trap arms and immediately
    -- triggers under the local player (prediction, no server round-trip).
    session:localCastIntent("e", 25, 25)
    for _ = 1, 22 do session:tick(1 / 30) end -- ~0.73s: still arming
    assertEqual(session:getState().abilities[1].phase, "arming")

    session:tick(1 / 30) -- tick 23: arms + triggers under the caster
    local state = session:getState()
    assertTrue(state.players.player1.stunned, "local player should be stunned by the predicted trap")
    assertEqual(state.abilities[1].phase, "despawning", "predicted trap should enter despawn")

    -- Reconcile with an authoritative snapshot carrying the despawn state.
    session:onMessage("server", {
        type = "snapshot",
        seq = 1,
        players = {
            { slot = "player1", x = 25, y = 25, hp = 100, cooldowns = { q = 0, w = 0, e = 5.2 }, stunned = true, stunRemaining = 1.4 },
        },
        abilities = {
            { id = 3, ability = "beartrap", owner = "player1", x = 25, y = 25, remaining = 0, armed = false, armRemaining = 0, castRootRemaining = 0, phase = "despawning", despawnRemaining = 0.2, radius = 10, rotation = -math.pi / 2 },
        },
    })

    state = session:getState()
    assertEqual(#state.abilities, 1)
    assertEqual(state.abilities[1].phase, "despawning", "snapshot reconciliation preserves the despawn phase")
    assertNear(state.abilities[1].despawnRemaining, 0.2, 0.0001, "snapshot reconciliation preserves the despawn timer")
    assertNear(state.abilities[1].rotation, -math.pi / 2, 0.0001, "snapshot reconciliation preserves the aim rotation")
    assertTrue(state.players.player1.stunned, "snapshot stun is applied")
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

test("client predicts the r cast and reconciles the projectile", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", {
        type = "welcome",
        slot = "player1",
        loadout = { q = "beam", w = "morganapool", e = "beartrap", r = "morganastun" },
    })
    session:drainOutbox()

    session:localCastIntent("r", 500, 25)

    local outbox = session:drainOutbox()
    assertEqual(#outbox, 1)
    assertEqual(outbox[1].message.type, "castIntent")
    assertEqual(outbox[1].message.slot, "r")

    local state = session:getState()
    assertEqual(#state.abilities, 1, "predicted morganastun should appear immediately")
    assertEqual(state.abilities[1].ability, "morganastun")
    assertEqual(state.abilities[1].phase, "charging")
    assertTrue(state.cooldowns.r > 0, "local r cooldown should start immediately")

    session:onMessage("server", {
        type = "snapshot",
        seq = 1,
        players = {
            { slot = "player1", x = 25, y = 25, hp = 100, cooldowns = { q = 0, w = 0, e = 0, r = 9.5 }, stunned = false, stunRemaining = 0 },
        },
        abilities = {
            { id = 3, ability = "morganastun", owner = "player1", x = 25, y = 25, remaining = 0.3, directionX = 1, directionY = 0, phase = "charging", traveled = 0 },
        },
    })

    state = session:getState()
    assertEqual(#state.abilities, 1)
    assertEqual(state.abilities[1].id, 3)
    assertEqual(state.abilities[1].phase, "charging")
    assertNear(state.abilities[1].directionX, 1, 0.001)
    assertNear(state.cooldowns.r, 9.5, 0.001)
end)

test("client predicts the d cast and reconciles the missile", function()
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", {
        type = "welcome",
        slot = "player1",
        loadout = { q = "beam", w = "morganapool", e = "beartrap", r = "morganastun", d = "missile" },
    })
    session:drainOutbox()

    session:localCastIntent("d", 100, 25)

    local outbox = session:drainOutbox()
    assertEqual(#outbox, 1)
    assertEqual(outbox[1].message.type, "castIntent")
    assertEqual(outbox[1].message.slot, "d")

    local state = session:getState()
    assertEqual(#state.abilities, 1, "predicted missile should appear immediately")
    assertEqual(state.abilities[1].ability, "missile")
    assertEqual(state.abilities[1].phase, "falling")
    assertTrue(state.cooldowns.d > 0, "local d cooldown should start immediately")

    -- Reconcile with an authoritative snapshot carrying the impact phase and
    -- its remaining fade timer.
    session:onMessage("server", {
        type = "snapshot",
        seq = 1,
        players = {
            { slot = "player1", x = 25, y = 25, hp = 100, cooldowns = { q = 0, w = 0, e = 0, r = 0, d = 7.1 }, stunned = false, stunRemaining = 0 },
        },
        abilities = {
            { id = 3, ability = "missile", owner = "player1", x = 100, y = 25, remaining = 0.15, phase = "impact", radius = 55 },
        },
    })

    state = session:getState()
    assertEqual(#state.abilities, 1)
    assertEqual(state.abilities[1].id, 3)
    assertEqual(state.abilities[1].phase, "impact", "snapshot reconciliation preserves the missile phase")
    assertNear(state.abilities[1].remaining, 0.15, 0.0001, "snapshot reconciliation preserves the fade timer")
    assertNear(state.cooldowns.d, 7.1, 0.001)
end)

----------------------------------------
-- Animation engine: pure clip/tween/timeline evaluation
----------------------------------------
-- These exercise the evaluator (the primary seam) headlessly: given a spec,
-- a phase, and an elapsed time it must return the expected pose and crossed
-- events -- and nothing else (no graphics, no wall-clock, no randomness).

test("easing curves hit their endpoints with sane midpoints", function()
    assertEqual(Anim.ease("linear", 0), 0)
    assertEqual(Anim.ease("linear", 1), 1)
    assertNear(Anim.ease("linear", 0.5), 0.5, 1e-9)
    assertNear(Anim.ease("quadIn", 0.5), 0.25, 1e-9)
    assertNear(Anim.ease("quadOut", 0.5), 0.75, 1e-9)
    assertNear(Anim.ease("quadInOut", 0.5), 0.5, 1e-9)
    assertNear(Anim.ease("cubicIn", 0.5), 0.125, 1e-9)
    assertNear(Anim.ease("cubicOut", 0.5), 0.875, 1e-9)
    assertNear(Anim.ease("sineIn", 0.5), 0.2928932188, 1e-6)
    assertNear(Anim.ease("sineOut", 0.5), 0.7071067812, 1e-6)
    assertEqual(Anim.ease("expoIn", 1), 1)
    assertEqual(Anim.ease("expoOut", 0), 0)
    -- Unknown names fall back to linear so bad data cannot crash rendering.
    assertNear(Anim.ease("nonexistent", 0.5), 0.5, 1e-9)
end)

test("clips step through frames and hold the last frame past the end", function()
    local spec = Anim.load({ cast = { type = "clip", frames = { 0, 1, 2, 3, 4 }, duration = 1 } })
    assertEqual(Anim.evaluate(spec, "cast", 0).frame, 0)
    assertEqual(Anim.evaluate(spec, "cast", 0.125).frame, 1)
    assertEqual(Anim.evaluate(spec, "cast", 0.375).frame, 2)
    assertEqual(Anim.evaluate(spec, "cast", 0.625).frame, 3)
    assertEqual(Anim.evaluate(spec, "cast", 0.875).frame, 4)
    assertEqual(Anim.evaluate(spec, "cast", 1).frame, 4)
    assertEqual(Anim.evaluate(spec, "cast", 5).frame, 4, "clip holds its last frame past the end")
end)

test("clips loop and ping-pong", function()
    local loop = Anim.load({ spin = { type = "clip", frames = { 0, 1, 2, 3 }, duration = 0.4, loop = true } })
    -- t=0.5 wraps to 0.1 -> progress 0.25 -> round(1 + 0.75) = 2 -> frame 1
    assertEqual(Anim.evaluate(loop, "spin", 0.5).frame, 1)
    -- t=0.8 wraps to 0 -> frame 0
    assertEqual(Anim.evaluate(loop, "spin", 0.8).frame, 0)

    local bounce = Anim.load({ wobble = { type = "clip", frames = { 0, 1, 2, 3 }, duration = 0.4, pingpong = true } })
    -- t=0.5: period 0.8, x=0.5 > 0.4 -> mirrored to 0.3 -> progress 0.75 ->
    -- round(1 + 2.25) = 3 -> frame 2
    assertEqual(Anim.evaluate(bounce, "wobble", 0.5).frame, 2)
    -- t=0.2 is on the outward leg halfway to the peak -> frame 2 as well
    assertEqual(Anim.evaluate(bounce, "wobble", 0.2).frame, 2)
    -- t=0.8 wraps to 0 -> frame 0
    assertEqual(Anim.evaluate(bounce, "wobble", 0.8).frame, 0)
end)

test("clips support per-frame timings", function()
    -- Timings are binary-exact here (0.125/0.25/0.125) so boundary assertions
    -- are stable: frame k spans [cum(k-1), cum(k)), and the boundary time
    -- steps to the next frame.
    local spec = Anim.load({ steps = { type = "clip", frames = { 10, 20, 30 }, timings = { 0.125, 0.25, 0.125 } } })
    assertEqual(Anim.evaluate(spec, "steps", 0).frame, 10)
    assertEqual(Anim.evaluate(spec, "steps", 0.1).frame, 10)
    assertEqual(Anim.evaluate(spec, "steps", 0.125).frame, 20, "boundary time steps to the next frame")
    assertEqual(Anim.evaluate(spec, "steps", 0.3).frame, 20)
    assertEqual(Anim.evaluate(spec, "steps", 0.375).frame, 30)
    assertEqual(Anim.evaluate(spec, "steps", 0.5).frame, 30)
    assertEqual(Anim.evaluate(spec, "steps", 0.9).frame, 30, "holds the last frame past the total")
end)

test("tweens interpolate with easing and hold the end value", function()
    local spec = Anim.load({ fade = { type = "tween", property = "alpha", from = 1, to = 0, duration = 1, easing = "linear" } })
    assertNear(Anim.evaluate(spec, "fade", 0).alpha, 1, 1e-9)
    assertNear(Anim.evaluate(spec, "fade", 0.5).alpha, 0.5, 1e-9)
    assertNear(Anim.evaluate(spec, "fade", 1).alpha, 0, 1e-9)
    assertNear(Anim.evaluate(spec, "fade", 3).alpha, 0, 1e-9, "tween holds its end value past the duration")

    -- A tween can target rotation/scale/frame too.
    local grow = Anim.load({ pop = { type = "tween", property = "scale", from = 0.5, to = 2, duration = 1, easing = "quadOut" } })
    assertNear(Anim.evaluate(grow, "pop", 0.5).scale, 0.5 + 1.5 * 0.75, 1e-9)
end)

test("timelines compose clips and tweens in parallel and sequence", function()
    local spec = Anim.load({
        cast = {
            type = "timeline",
            tracks = {
                { type = "clip", at = 0, frames = { 0, 1, 2 }, duration = 0.2 },
                { type = "tween", at = 0.1, property = "alpha", from = 1, to = 0, duration = 0.1, easing = "linear" },
                { type = "tween", at = 0.1, property = "scale", from = 1, to = 1.5, duration = 0.1, easing = "linear" },
            },
        },
    })
    -- At 0.15 the clip is 75% through (frame 2) and both tweens are halfway.
    local pose = Anim.evaluate(spec, "cast", 0.15)
    assertEqual(pose.frame, 2)
    assertNear(pose.alpha, 0.5, 1e-9)
    assertNear(pose.scale, 1.25, 1e-9)
    -- Before the tween tracks start, the pose defaults apply (clip is still on
    -- frame 0 at 20% progress: round(1 + 0.2*2) = 1).
    local early = Anim.evaluate(spec, "cast", 0.04)
    assertEqual(early.frame, 0)
    assertEqual(early.alpha, 1)
    assertEqual(early.scale, 1)
end)

test("timelines report events crossed in the (prev, elapsed] window", function()
    local spec = Anim.load({
        cast = {
            type = "timeline",
            tracks = {
                { type = "event", at = 0.5, name = "pop" },
                { type = "event", at = 1.0, name = "bang" },
            },
        },
    })
    local _, events = Anim.evaluate(spec, "cast", 0.25, nil)
    assertEqual(#events, 0, "no events before the first timestamp")

    local _, events = Anim.evaluate(spec, "cast", 0.75, 0.25)
    assertEqual(#events, 1)
    assertEqual(events[1].name, "pop")

    local _, events = Anim.evaluate(spec, "cast", 1.25, 0.75)
    assertEqual(#events, 1)
    assertEqual(events[1].name, "bang")

    local _, events = Anim.evaluate(spec, "cast", 1.5, 1.25)
    assertEqual(#events, 0, "no re-report after the window passes")

    -- A rewound elapsed window (snapshot rollback) reports nothing.
    local _, events = Anim.evaluate(spec, "cast", 0.4, 0.75)
    assertEqual(#events, 0, "a rollback window reports nothing")
end)

test("evaluate returns a default pose for unknown phases", function()
    local spec = Anim.load({ armed = { type = "clip", frames = { 6 }, duration = 30 } })
    local pose, events = Anim.evaluate(spec, "nonexistent", 1)
    assertEqual(pose.frame, nil)
    assertEqual(pose.rotation, 0)
    assertEqual(pose.scale, 1)
    assertEqual(pose.alpha, 1)
    assertEqual(#events, 0)
end)

test("engine evaluation is deterministic", function()
    local spec = Anim.load({
        cast = {
            type = "timeline",
            tracks = {
                { type = "clip", at = 0, frames = { 0, 1, 2, 3 }, duration = 0.4 },
                { type = "tween", at = 0.2, property = "alpha", from = 1, to = 0, duration = 0.3, easing = "sineOut" },
                { type = "event", at = 0.5, name = "snap" },
            },
        },
    })
    local function sample()
        local pose, events = Anim.evaluate(spec, "cast", 0.53, 0.2)
        local crossed = {}
        for _, e in ipairs(events) do
            table.insert(crossed, e.name)
        end
        return pose.frame, pose.rotation, pose.scale, pose.alpha, table.concat(crossed, ",")
    end
    local f1, r1, s1, a1, e1 = sample()
    local f2, r2, s2, a2, e2 = sample()
    assertEqual(f1, f2, "deterministic frame")
    assertEqual(r1, r2, "deterministic rotation")
    assertEqual(s1, s2, "deterministic scale")
    assertEqual(a1, a2, "deterministic alpha")
    assertEqual(e1, e2, "deterministic events")
end)

test("anim.load normalizes specs (default easing, timings total)", function()
    local spec = Anim.load({
        a = { type = "tween", property = "alpha", from = 1, to = 0, duration = 1 },
        b = { type = "clip", frames = { 0, 1 }, timings = { 0.25, 0.25 } },
        c = { type = "timeline", tracks = {
            { type = "tween", at = 0, property = "alpha", from = 1, to = 0, duration = 1 },
        } },
    })
    assertEqual(spec.a.easing, "linear", "tweens default to linear easing")
    assertNear(spec.b.duration, 0.5, 1e-9, "timings total becomes the clip duration")
    assertEqual(spec.c.tracks[1].easing, "linear", "timeline tracks normalize too")
end)

----------------------------------------
-- Bear Trap: animation-spec migration golden values
----------------------------------------
-- The pre-migration getFrame/getAlpha math is reproduced byte-for-byte by the
-- engine from Trap.animation. The frame sequences below are hardcoded golden
-- values sampled at the 30 Hz tick grid; alpha is asserted against the old
-- formula (clamp01(1 - (elapsed - snap)/fade)) so the migration is provably
-- safe. Nothing here reaches into the engine's internals.

local Trap = registry.load("beartrap")

test("beartrap arming frames match the pre-migration golden stepping", function()
    -- Old math: frame = round(6 * progress), progress = 1 - armRemaining/armDelay.
    -- At 30 Hz that is round(8 * tick/30), sampled per tick below.
    local golden = { 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 5, 6, 6 }
    for tick = 0, #golden - 1 do
        local trap = registry.new("beartrap", "player1", 100, 25, 0)
        trap.phase = "arming"
        trap.armRemaining = Trap.armDelay - tick / 30
        assertEqual(trap:getFrame(), golden[tick + 1], string.format("arming frame at tick %d", tick))
        assertEqual(trap:getAlpha(), 1, "alpha stays 1 while arming")
    end
end)

test("beartrap armed phase holds frame 6 with alpha 1", function()
    local trap = registry.new("beartrap", "player1", 100, 25, 0)
    trap.phase = "armed"
    trap.remaining = 20 -- arbitrarily mid-life; the pose must not change
    assertEqual(trap:getFrame(), 6)
    assertEqual(trap:getAlpha(), 1)
    -- The engine pose carries rotation/scale defaults for future tweens.
    local pose = Anim.evaluate(Trap.animation, "armed", trap:getAnimationElapsed())
    assertEqual(pose.rotation, 0)
    assertEqual(pose.scale, 1)
end)

test("beartrap despawn snap frames match the pre-migration golden values", function()
    -- Old math: pos = 1 + clamp01(elapsed/snapDuration)*7, index = round(pos)
    -- into SNAP_FRAMES while elapsed < snapDuration, then hold the closed pose.
    local golden = { 6, 8, 9, 11, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    for tick = 0, #golden - 1 do
        local trap = registry.new("beartrap", "player1", 100, 25, 0)
        trap.phase = "despawning"
        trap.despawnRemaining = Trap.despawnDuration - tick / 30
        assertEqual(trap:getFrame(), golden[tick + 1], string.format("despawn frame at tick %d", tick))
    end
end)

test("beartrap despawn alpha fades exactly like the old dissolve", function()
    -- Old alpha: 1 during the snap, then clamp01(1 - (elapsed-snap)/fade). The
    -- engine's alpha tween (started at snap completion) must reproduce it.
    for tick = 0, 14 do
        local elapsed = tick / 30
        local expected
        if elapsed < Trap.snapDuration then
            expected = 1
        else
            expected = math.max(0, math.min(1, 1 - (elapsed - Trap.snapDuration) / Trap.fadeDuration))
        end
        local trap = registry.new("beartrap", "player1", 100, 25, 0)
        trap.phase = "despawning"
        trap.despawnRemaining = Trap.despawnDuration - elapsed
        assertNear(trap:getAlpha(), expected, 1e-9, string.format("despawn alpha at tick %d", tick))
    end
end)

test("beartrap frame and alpha accessors are deterministic across identical instances", function()
    local function sample(phase, elapsed)
        local trap = registry.new("beartrap", "player1", 100, 25, 0)
        trap.phase = phase
        if phase == "arming" then
            trap.armRemaining = Trap.armDelay - elapsed
        elseif phase == "despawning" then
            trap.despawnRemaining = Trap.despawnDuration - elapsed
        end
        return trap:getFrame(), trap:getAlpha()
    end
    for _, phase in ipairs({ "arming", "armed", "despawning" }) do
        local elapsed = (phase == "despawning") and 0.3 or 0.4
        local f1, a1 = sample(phase, elapsed)
        local f2, a2 = sample(phase, elapsed)
        assertEqual(f1, f2, phase .. " frame deterministic")
        assertEqual(a1, a2, phase .. " alpha deterministic")
    end
end)

test("beartrap despawn crosses its snap event at snap completion", function()
    local function crossedAt(elapsed, prevElapsed)
        local trap = registry.new("beartrap", "player1", 100, 25, 0)
        trap.phase = "despawning"
        trap.despawnRemaining = Trap.despawnDuration - elapsed
        return Anim.evaluate(Trap.animation, trap.phase, trap:getAnimationElapsed(), prevElapsed)
    end

    local _, events = crossedAt(0.1, nil) -- mid-snap: no event yet
    assertEqual(#events, 0)

    local _, events = crossedAt(0.2, 0.1) -- just past snap completion: event
    assertEqual(#events, 1)
    assertEqual(events[1].name, "snap")

    local _, events = crossedAt(0.3, 0.2) -- window moved past it: no re-report
    assertEqual(#events, 0)
end)

test("client-style event windows fire the trap snap exactly once per lifecycle", function()
    -- Replays the client renderer's per-instance window tracking (keyed by
    -- ability id + phase, last elapsed per phase) over a real simulated trap
    -- lifecycle: cast under the caster, arm, trigger, snap, fade, remove. The
    -- dust-spawning "snap" event must cross exactly once.
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:castAbility("player1", "e", 25, 25) -- trap under the caster

    local fired = 0
    local animState = {}
    for _ = 1, 40 do
        game:tick(1 / 30)
        for _, ability in ipairs(game:getAbilities()) do
            if ability.animation and ability.id then
                local elapsed = ability:getAnimationElapsed()
                local prev = animState[ability.id]
                if prev and prev.phase ~= ability.phase then
                    prev = nil -- phase change restarts the timeline
                end
                local _, events = Anim.evaluate(ability.animation, ability.phase, elapsed, prev and prev.lastElapsed)
                animState[ability.id] = { phase = ability.phase, lastElapsed = elapsed }
                for _, event in ipairs(events) do
                    if event.name == "snap" then
                        fired = fired + 1
                    end
                end
            end
        end
    end
    assertEqual(fired, 1, "exactly one snap event across the full lifecycle")
end)

----------------------------------------
-- Missile: animation-spec golden values
----------------------------------------
-- The missile's frame/alpha accessors are pure wrappers over the animation
-- engine (src/anim.engine) driven by the phase timers, exactly like Bear
-- Trap's spec migration. The engine's stepped clip indexing is
-- round(1 + t/duration*(n-1)); the golden arrays below are that formula
-- sampled on the 30 Hz tick grid, so nothing here reaches into internals.

local Missile = registry.load("missile")

test("missile falling frames step 0 -> 8 across the fall duration", function()
    -- Even 9-frame walk over the 1.0s fall (30 ticks at 30 Hz).
    local golden = { 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8 }
    for tick = 0, #golden - 1 do
        local missile = registry.new("missile", "player1", 100, 25, 0)
        missile.phase = "falling"
        missile.remaining = Missile.fallDuration - tick / 30
        assertEqual(missile:getFrame(), golden[tick + 1], string.format("falling frame at tick %d", tick))
        assertEqual(missile:getAlpha(), 1, "alpha stays 1 while falling")
    end
end)

test("missile impact frames step 9 -> 13 while alpha fades 1 -> 0", function()
    -- Even 5-frame fire walk over the 0.7s fade (21 ticks at 30 Hz).
    local golden = { 9, 9, 9, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 12, 12, 12, 12, 12, 13, 13, 13 }
    for tick = 0, #golden - 1 do
        local missile = registry.new("missile", "player1", 100, 25, 0)
        missile.phase = "impact"
        missile.remaining = Missile.fadeDuration - tick / 30
        assertEqual(missile:getFrame(), golden[tick + 1], string.format("impact frame at tick %d", tick))
        assertNear(missile:getAlpha(), 1 - (tick / 30) / Missile.fadeDuration, 1e-9,
            string.format("impact alpha at tick %d", tick))
    end
end)

test("missile frame and alpha accessors are deterministic across identical instances", function()
    local function sample(phase, elapsed)
        local missile = registry.new("missile", "player1", 100, 25, 0)
        missile.phase = phase
        if phase == "falling" then
            missile.remaining = Missile.fallDuration - elapsed
        else
            missile.remaining = Missile.fadeDuration - elapsed
        end
        return missile:getFrame(), missile:getAlpha()
    end
    for _, phase in ipairs({ "falling", "impact" }) do
        local elapsed = 0.3
        local f1, a1 = sample(phase, elapsed)
        local f2, a2 = sample(phase, elapsed)
        assertEqual(f1, f2, phase .. " frame deterministic")
        assertEqual(a1, a2, phase .. " alpha deterministic")
    end
end)

test("missile impact crosses its cosmetic event at offset 0", function()
    local function crossedAt(elapsed, prevElapsed)
        local missile = registry.new("missile", "player1", 100, 25, 0)
        missile.phase = "impact"
        missile.remaining = Missile.fadeDuration - elapsed
        return Anim.evaluate(Missile.animation, missile.phase, missile:getAnimationElapsed(), prevElapsed)
    end

    -- The first evaluation of the impact phase (no previous window) reports
    -- the event so the client can burst the fire at the moment of impact.
    local _, events = crossedAt(0, nil)
    assertEqual(#events, 1)
    assertEqual(events[1].name, "impact")

    -- A window that has already moved past offset 0 reports nothing new.
    local _, events = crossedAt(0.1, 0.05)
    assertEqual(#events, 0)
end)

test("client-style event windows fire the missile impact exactly once per lifecycle", function()
    -- Replays the client renderer's per-instance window tracking (keyed by
    -- ability id + phase, last elapsed per phase) over a real simulated
    -- missile lifecycle: cast, fall, impact, fade, remove. The fire-spawning
    -- "impact" event must cross exactly once.
    local game = Game.new(makeConfig())
    game:spawnPlayer("player1")
    game:castAbility("player1", "d", 25, 25) -- missile on the caster

    local fired = 0
    local animState = {}
    for _ = 1, 60 do -- 2.0s > the 1.0s fall + 0.7s fade lifecycle
        game:tick(1 / 30)
        for _, ability in ipairs(game:getAbilities()) do
            if ability.animation and ability.id then
                local elapsed = ability:getAnimationElapsed()
                local prev = animState[ability.id]
                if prev and prev.phase ~= ability.phase then
                    prev = nil -- phase change restarts the timeline
                end
                local _, events = Anim.evaluate(ability.animation, ability.phase, elapsed, prev and prev.lastElapsed)
                animState[ability.id] = { phase = ability.phase, lastElapsed = elapsed }
                for _, event in ipairs(events) do
                    if event.name == "impact" then
                        fired = fired + 1
                    end
                end
            end
        end
    end
    assertEqual(fired, 1, "exactly one impact event across the full lifecycle")
end)

test("fire latches suppress the missile impact's re-fire after a snapshot rewind", function()
    -- In networked play the client predicts the impact on its own tick while
    -- the authoritative sim transitions a tick later (the client casts
    -- instantly on input; the server processes the intent a pump later). A
    -- stale in-flight "falling" snapshot can then rewind the predicted impact,
    -- and the authoritative impact snapshot re-enters the phase -- re-reporting
    -- the self-healing "impact" event and double-bursting the fire. The
    -- client's per-owner fire latch (firedImpacts) must keep the particles to
    -- a single eruption per blast.
    local config = makeConfig()
    local server = Session.new(Game.new(config), "server", config.server)
    local client = Session.new(Game.new(config), "client", config.server)
    server:onConnect(1)
    server:onConnect(2)
    client:onConnect("server")
    for _, entry in ipairs(server:drainOutbox()) do
        if entry.message.type == "welcome" and entry.to == 1 then
            client:onMessage("server", entry.message)
        end
    end
    client:drainOutbox()

    -- The server's ability id counter skews ahead of the client's prediction
    -- (player2 casts first), so the authoritative missile id differs from the
    -- one the client predicts.
    server:onMessage(2, { type = "castIntent", slot = "w", x = 175, y = 175 })

    client:localCastIntent("d", 25, 25)
    for _, entry in ipairs(client:drainOutbox()) do
        if entry.message.type == "castIntent" then
            server:onMessage(1, entry.message)
        end
    end

    -- Replicate the client renderer's per-instance window tracking plus its
    -- firedImpacts latch (re-armed only by a new cast: a fresh id entering the
    -- falling phase), counting raw event crossings and effective spawns.
    local crossings = 0
    local spawns = 0
    local firedImpacts = {}
    local lastFallingMissileId = {}
    local animState = {}
    local function consume()
        for _, ability in ipairs(client.game:getAbilities()) do
            if ability.animation and ability.id then
                local elapsed = ability:getAnimationElapsed()
                local prev = animState[ability.id]
                if prev and prev.phase ~= ability.phase then
                    prev = nil -- phase change restarts the timeline
                end
                local _, events = Anim.evaluate(ability.animation, ability.phase, elapsed, prev and prev.lastElapsed)
                animState[ability.id] = { phase = ability.phase, lastElapsed = elapsed }
                -- A new missile cast (fresh id, falling) re-arms the latch.
                if ability.abilityId == "missile" then
                    if ability.phase == "falling" and lastFallingMissileId[ability.owner] ~= ability.id then
                        firedImpacts["missile|" .. ability.owner] = nil
                        lastFallingMissileId[ability.owner] = ability.id
                    end
                end
                for _, event in ipairs(events) do
                    if event.name == "impact" then
                        crossings = crossings + 1
                        local key = ability.abilityId .. "|" .. ability.owner
                        if not firedImpacts[key] then
                            firedImpacts[key] = true
                            spawns = spawns + 1
                        end
                    end
                end
            end
        end
        for id in pairs(animState) do
            local found = false
            for _, ability in ipairs(client.game:getAbilities()) do
                if ability.id == id then
                    found = true
                    break
                end
            end
            if not found then
                animState[id] = nil
            end
        end
    end

    -- Lockstep both sessions so the client's prediction crosses the fall ->
    -- impact boundary one tick before the server's own simulation.
    for _ = 1, 29 do
        server:tick(1 / 30)
        for _, entry in ipairs(server:drainOutbox()) do
            if entry.message.type == "snapshot" then
                client:onMessage("server", entry.message)
            end
        end
        client:tick(1 / 30)
        consume()
    end
    client:tick(1 / 30) -- the client's predicted impact
    consume()
    assertEqual(crossings, 1, "the predicted impact crosses exactly once")
    assertEqual(spawns, 1, "the predicted impact erupts exactly once")

    -- Tick the server until its missile enters the impact phase, keeping the
    -- newest falling snapshot (the stale one that rewinds the prediction) and
    -- the first impact snapshot (the authoritative re-entry).
    local staleFalling, authoritativeImpact
    while not authoritativeImpact do
        server:tick(1 / 30)
        local snap
        for _, entry in ipairs(server:drainOutbox()) do
            if entry.message.type == "snapshot" then snap = entry.message end
        end
        for _, ability in ipairs(snap and snap.abilities or {}) do
            if ability.ability == "missile" then
                if ability.phase == "impact" then
                    authoritativeImpact = snap
                else
                    staleFalling = snap
                end
            end
        end
    end

    client:onMessage("server", staleFalling) -- rewind: back to falling
    consume()
    client:onMessage("server", authoritativeImpact) -- re-entry: impact again
    consume()

    assertEqual(crossings, 2, "the stale snapshot + authoritative impact re-cross the phase boundary")
    assertEqual(spawns, 1, "the fire latch keeps a single eruption per blast")
end)

test("fire latches suppress the missile impact's re-fire when a fade-end snapshot straggles in", function()
    -- At the end of the 0.7s fade the client's local sim removes the missile
    -- ~1 tick before the server does (the client predicted the cast early).
    -- The server's last snapshot can then land in a frame with no local tick,
    -- re-adding the dying impact (remaining ~0) for a frame. The latch must
    -- survive the missile's brief absence -- it is only re-armed by a genuinely
    -- new cast (a fresh id entering the falling phase) -- so the re-added
    -- missile cannot erupt the fire a second time. A later cast must still
    -- erupt its own burst.
    local session = newClientSession()
    session:onConnect("server")
    session:onMessage("server", {
        type = "welcome",
        slot = "player1",
        loadout = { q = "beam", w = "morganapool", e = "beartrap", r = "morganastun", d = "missile" },
    })
    session:drainOutbox()

    session:localCastIntent("d", 25, 25)
    session:drainOutbox()

    local crossings = 0
    local spawns = 0
    local firedImpacts = {}
    local lastFallingMissileId = {}
    local animState = {}
    local function consume()
        for _, ability in ipairs(session.game:getAbilities()) do
            if ability.animation and ability.id then
                local elapsed = ability:getAnimationElapsed()
                local prev = animState[ability.id]
                if prev and prev.phase ~= ability.phase then
                    prev = nil -- phase change restarts the timeline
                end
                local _, events = Anim.evaluate(ability.animation, ability.phase, elapsed, prev and prev.lastElapsed)
                animState[ability.id] = { phase = ability.phase, lastElapsed = elapsed }
                -- A new missile cast (fresh id, falling) re-arms the latch.
                if ability.abilityId == "missile" then
                    if ability.phase == "falling" and lastFallingMissileId[ability.owner] ~= ability.id then
                        firedImpacts["missile|" .. ability.owner] = nil
                        lastFallingMissileId[ability.owner] = ability.id
                    end
                end
                for _, event in ipairs(events) do
                    if event.name == "impact" then
                        crossings = crossings + 1
                        local key = ability.abilityId .. "|" .. ability.owner
                        if not firedImpacts[key] then
                            firedImpacts[key] = true
                            spawns = spawns + 1
                        end
                    end
                end
            end
        end
        for id in pairs(animState) do
            local found = false
            for _, ability in ipairs(session.game:getAbilities()) do
                if ability.id == id then
                    found = true
                    break
                end
            end
            if not found then
                animState[id] = nil
            end
        end
    end

    -- Predict the full lifecycle: fall (30 ticks) + fade (21 ticks) + margin.
    for _ = 1, 54 do
        session:tick(1 / 30)
        consume()
    end
    assertEqual(crossings, 1, "the predicted impact crosses exactly once")
    assertEqual(spawns, 1, "the predicted impact erupts exactly once")
    assertEqual(#session.game:getAbilities(), 0, "the client's local sim removed the missile at fade end")

    -- The server's last snapshot (sent a tick later, still listing the dying
    -- missile) straggles in during a frame with no local tick, re-adding it.
    session:onMessage("server", {
        type = "snapshot",
        seq = 1,
        players = {},
        abilities = {
            { id = 3, ability = "missile", owner = "player1", x = 25, y = 25, remaining = 0.03, phase = "impact", radius = 55 },
        },
    })
    consume() -- no client tick this frame: the re-added dying missile is visible

    assertEqual(crossings, 2, "the fade-end straggler re-observes the impact phase")
    assertEqual(spawns, 1, "the latch must survive the missile's brief absence")

    -- A genuinely new cast (fresh id entering the falling phase) re-arms the
    -- latch and erupts its own burst once it lands.
    session.game:setCooldowns("player1", { q = 0, w = 0, e = 0, r = 0, d = 0 })
    session:localCastIntent("d", 50, 25)
    for _ = 1, 31 do
        session:tick(1 / 30)
        consume()
    end
    assertEqual(spawns, 2, "a fresh cast from the same owner erupts its own burst")
end)

----------------------------------------
-- Particle emitter: pure advance step
----------------------------------------
-- Particles.spawn is the only random/graphics-free-but-random spot and is
-- client-local; the advance step is the deterministic seam under test.

test("particles advance integrates velocity and ticks lifetime", function()
    local list = {
        { x = 0, y = 0, vx = 20, vy = 10, life = 1, maxLife = 1, drag = 0 },
    }
    Particles.advance(list, 0.5)
    assertNear(list[1].x, 10, 1e-9)
    assertNear(list[1].y, 5, 1e-9)
    assertNear(list[1].life, 0.5, 1e-9)
end)

test("particles expire when their life reaches zero", function()
    -- 0.125/0.25 are binary-exact, so the boundary assertion is stable.
    local list = {
        { x = 0, y = 0, vx = 0, vy = 0, life = 0.25, maxLife = 1, drag = 0 },
    }
    Particles.advance(list, 0.125)
    assertEqual(#list, 1, "still alive mid-life")
    Particles.advance(list, 0.125)
    assertEqual(#list, 0, "removed exactly at end of life")
end)

test("particle drag damps velocity before integrating", function()
    local list = {
        { x = 0, y = 0, vx = 100, vy = 0, life = 1, maxLife = 1, drag = 2 },
    }
    Particles.advance(list, 0.25)
    -- damp = max(0, 1 - 2*0.25) = 0.5 -> vx 50 -> x += 50*0.25 = 12.5
    assertNear(list[1].vx, 50, 1e-9)
    assertNear(list[1].x, 12.5, 1e-9)
    -- Drag never reverses a particle: a full half-second damps velocity to 0.
    Particles.advance(list, 0.5)
    assertEqual(list[1].vx, 0)
end)

test("particle advance is deterministic", function()
    local function run()
        local list = {
            { x = 1, y = 2, vx = 30, vy = -20, life = 0.7, maxLife = 1, drag = 1.5 },
            { x = 5, y = 5, vx = -5, vy = 8, life = 0.4, maxLife = 0.4, drag = 0 },
        }
        for _ = 1, 10 do
            Particles.advance(list, 1 / 60)
        end
        local parts = {}
        for _, p in ipairs(list) do
            table.insert(parts, string.format("%.6f,%.6f,%.6f", p.x, p.y, p.life))
        end
        return table.concat(parts, "|")
    end
    assertEqual(run(), run())
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
