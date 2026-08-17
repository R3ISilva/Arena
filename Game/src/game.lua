-- Pure, network-agnostic game simulation. Owns the world and the authoritative
-- player state: spawning, move targets, pathfinding (via world), fixed-step
-- movement, and the server-authoritative ability simulation (per-player health,
-- per-slot loadouts/cooldowns, and active abilities/pools). It knows nothing
-- about peers, connections, messages, channels, or sequence numbers — the
-- session layer translates network I/O into these calls.
--
-- Both the dedicated server (authority) and the windowed client (prediction)
-- drive their own Game instance through the same interface, which is what keeps
-- predicted movement and predicted casts bit-for-bit identical to the
-- authoritative simulation.

local World = require("src.world")
local registry = require("src.abilities.registry")

local Game = {}
Game.__index = Game

local INITIAL_HEALTH = 100
local DEFAULT_LOADOUT = { q = nil, w = "morganapool", e = nil }

local function clamp(value, lo, hi)
    return math.max(lo, math.min(hi, value))
end

function Game.new(config)
    local self = setmetatable({}, Game)
    self.world = World.new(config)
    self.windowWidth = config.window.width
    self.windowHeight = config.window.height
    self.walkSpeed = config.player.walkSpeed
    self.players = {}       -- slot -> { x, y, path, target }
    self.health = {}        -- slot -> number (display-only, floored at 0)
    self.loadouts = {}      -- slot -> { q, w, e } ability ids (server-owned)
    self.cooldowns = {}     -- slot -> { q, w, e } remaining seconds
    self.abilities = {}     -- list of active ability instances
    self.nextAbilityId = 1
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
    self.health[slot] = INITIAL_HEALTH
    self.loadouts[slot] = { q = DEFAULT_LOADOUT.q, w = DEFAULT_LOADOUT.w, e = DEFAULT_LOADOUT.e }
    self.cooldowns[slot] = { q = 0, w = 0, e = 0 }
end

function Game:removePlayer(slot)
    self.players[slot] = nil
    self.health[slot] = nil
    self.loadouts[slot] = nil
    self.cooldowns[slot] = nil
    for i = #self.abilities, 1, -1 do
        if self.abilities[i].owner == slot then
            table.remove(self.abilities, i)
        end
    end
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

-- Cast an ability from a player's loadout slot. Resolves the slot's ability,
-- rejects empty/cooldown slots, clamps the target to the ability's range from
-- the caster, instantiates the ability, and starts the cooldown. Returns the
-- clamped coordinates (plus the instance) so callers can echo the authoritative
-- placement; returns nil if the cast was rejected.
function Game:castAbility(slot, key, x, y)
    local player = self.players[slot]
    if not player then
        return nil
    end
    local loadout = self.loadouts[slot]
    if not loadout then
        return nil
    end
    local abilityId = loadout[key]
    if not abilityId then
        return nil
    end
    local cooldowns = self.cooldowns[slot]
    if not cooldowns or cooldowns[key] > 0 then
        return nil
    end
    local abilityModule = registry.load(abilityId)
    if not abilityModule then
        return nil
    end

    -- Clamp the target to the ability's range in the clicked direction.
    local dx = x - player.x
    local dy = y - player.y
    local distance = math.sqrt(dx * dx + dy * dy)
    local cx, cy = x, y
    if distance > abilityModule.range and distance > 0 then
        local scale = abilityModule.range / distance
        cx = player.x + dx * scale
        cy = player.y + dy * scale
    end

    local instance = abilityModule.new(slot, cx, cy)
    instance.id = self.nextAbilityId
    self.nextAbilityId = self.nextAbilityId + 1
    instance.abilityId = abilityId
    instance:cast(slot, cx, cy)
    table.insert(self.abilities, instance)

    cooldowns[key] = abilityModule.cooldown

    return cx, cy, instance
end

-- Reconciliation helpers (client prediction).
function Game:setHealth(slot, hp)
    if self.health[slot] and type(hp) == "number" then
        self.health[slot] = math.max(0, hp)
    end
end

function Game:setLoadout(slot, loadout)
    if not loadout then
        return
    end
    self.loadouts[slot] = { q = loadout.q, w = loadout.w, e = loadout.e }
end

function Game:setCooldowns(slot, cooldowns)
    local current = self.cooldowns[slot]
    if not current then
        return
    end
    current.q = cooldowns.q or 0
    current.w = cooldowns.w or 0
    current.e = cooldowns.e or 0
end

-- Replace the local ability list with authoritative pools from a snapshot.
function Game:applySnapshotPools(pools)
    local result = {}
    for _, entry in ipairs(pools or {}) do
        local instance = registry.new(entry.ability, entry.owner, entry.x, entry.y, entry.remaining)
        instance.id = entry.id
        instance.abilityId = entry.ability
        table.insert(result, instance)
    end
    self.abilities = result
end

----------------------------------------
-- Simulation step
----------------------------------------
function Game:tick(dt)
    for _, player in pairs(self.players) do
        self.world:stepPlayer(player, dt)
    end

    -- Advance per-slot cooldowns toward zero.
    for _, cooldowns in pairs(self.cooldowns) do
        if cooldowns.q > 0 then
            cooldowns.q = math.max(0, cooldowns.q - dt)
        end
        if cooldowns.w > 0 then
            cooldowns.w = math.max(0, cooldowns.w - dt)
        end
        if cooldowns.e > 0 then
            cooldowns.e = math.max(0, cooldowns.e - dt)
        end
    end

    -- Advance active abilities and apply their damage ticks. A pool deals its
    -- per-tick damage to every player whose circle overlaps the pool's circle
    -- (including the caster); placement ignores obstacles.
    local playerRadius = self.world.radius
    for i = #self.abilities, 1, -1 do
        local ability = self.abilities[i]
        local ticks = ability:update(dt)
        if not ability.active then
            table.remove(self.abilities, i)
        end
        if ticks and ticks > 0 then
            local perTick = ability:getTickDamage()
            local reach = ability.radius + playerRadius
            local reachSq = reach * reach
            for slot, player in pairs(self.players) do
                local px = player.x - ability.x
                local py = player.y - ability.y
                if px * px + py * py <= reachSq then
                    self.health[slot] = math.max(0, self.health[slot] - ticks * perTick)
                end
            end
        end
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

-- Read-only copy of a player's position and health.
function Game:getPlayer(slot)
    local player = self.players[slot]
    if not player then
        return nil
    end
    return { x = player.x, y = player.y, hp = self.health[slot] }
end

-- Read-only snapshot of all player positions + health: slot -> { x, y, hp }.
function Game:getPlayers()
    local result = {}
    for slot, player in pairs(self.players) do
        result[slot] = { x = player.x, y = player.y, hp = self.health[slot] }
    end
    return result
end

function Game:getHealth(slot)
    return self.health[slot]
end

function Game:getLoadout(slot)
    return self.loadouts[slot]
end

function Game:getCooldowns(slot)
    return self.cooldowns[slot]
end

-- Live list of active ability instances (for rendering and snapshot building).
function Game:getAbilities()
    return self.abilities
end

-- Serialized pool list for snapshots: { id, ability, x, y, radius, owner, remaining }.
function Game:getPoolsSnapshot()
    local result = {}
    for _, ability in ipairs(self.abilities) do
        table.insert(result, {
            id = ability.id,
            ability = ability.abilityId,
            x = ability.x,
            y = ability.y,
            radius = ability.radius,
            owner = ability.owner,
            remaining = ability.remaining,
        })
    end
    return result
end

return Game
