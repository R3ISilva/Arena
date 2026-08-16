-- Pure, network-agnostic game simulation. Owns the world and the authoritative
-- player state: spawning, move targets, pathfinding (via world), and fixed-step
-- movement. It knows nothing about peers, connections, messages, channels, or
-- sequence numbers — the session layer translates network I/O into these calls.
--
-- Both the dedicated server (authority) and the windowed client (prediction)
-- drive their own Game instance through the same interface, which is what keeps
-- predicted movement bit-for-bit identical to the authoritative simulation.

local World = require("src.world")

local Game = {}
Game.__index = Game

local function clamp(value, lo, hi)
    return math.max(lo, math.min(hi, value))
end

function Game.new(config)
    local self = setmetatable({}, Game)
    self.world = World.new(config)
    self.windowWidth = config.window.width
    self.windowHeight = config.window.height
    self.walkSpeed = config.player.walkSpeed
    self.players = {}   -- slot -> { x, y, path, target }
    return self
end

----------------------------------------
-- Player lifecycle
----------------------------------------
-- Spawn a player at its slot-specific spawn point. player1 -> spawnPoints[1],
-- player2 -> spawnPoints[2].
function Game:spawnPlayer(slot)
    local spawnIndex = (slot == "player1") and 1 or 2
    local spawn = self.world.spawnPoints[spawnIndex]
    self.players[slot] = { x = spawn.x, y = spawn.y, path = {}, target = nil }
end

function Game:removePlayer(slot)
    self.players[slot] = nil
end

----------------------------------------
-- Commands
----------------------------------------
-- Set a player's move target: clamp to the arena, store the target, and compute
-- the path. Returns the clamped coordinates so callers can echo the exact
-- authoritative target (e.g. in a move intent). Returns nil if no such player.
function Game:setTarget(slot, x, y)
    local player = self.players[slot]
    if not player then
        return nil
    end
    x = clamp(x, 0, self.windowWidth)
    y = clamp(y, 0, self.windowHeight)
    player.target = { x = x, y = y }
    player.path = self.world:findPath(player.x, player.y, x, y)
    return x, y
end

-- Snap a player to an authoritative position (client reconciliation).
function Game:setPosition(slot, x, y)
    local player = self.players[slot]
    if player then
        player.x = x
        player.y = y
    end
end

function Game:clearTarget(slot)
    local player = self.players[slot]
    if player then
        player.target = nil
        player.path = {}
    end
end

function Game:getTarget(slot)
    local player = self.players[slot]
    return player and player.target or nil
end

----------------------------------------
-- Simulation step
----------------------------------------
function Game:tick(dt)
    for _, player in pairs(self.players) do
        self.world:stepPlayer(player, dt)
    end
end

----------------------------------------
-- State accessors
----------------------------------------
-- Live reference to a player's simulation state. Used by the client session for
-- prediction/introspection; mutating callers must go through the commands above.
function Game:getPlayerRef(slot)
    return self.players[slot]
end

-- Read-only copy of a player's position.
function Game:getPlayer(slot)
    local player = self.players[slot]
    if not player then
        return nil
    end
    return { x = player.x, y = player.y }
end

-- Read-only snapshot of all player positions: slot -> { x, y }.
function Game:getPlayers()
    local result = {}
    for slot, player in pairs(self.players) do
        result[slot] = { x = player.x, y = player.y }
    end
    return result
end

return Game
