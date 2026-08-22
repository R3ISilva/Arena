-- Pure, network-agnostic game simulation. Owns the world and the authoritative
-- player state: spawning, move targets, pathfinding (via world), fixed-step
-- movement, and the server-authoritative ability simulation (per-player health,
-- per-slot loadouts/cooldowns, active abilities, and the stun status effect).
-- It knows nothing about peers, connections, messages, channels, or sequence
-- numbers — the session layer translates network I/O into these calls.
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
local DEFAULT_LOADOUT = { q = "beam", w = "morganapool", e = "beartrap", r = "morganastun" }

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
    self.loadouts = {}      -- slot -> { q, w, e, r } ability ids (server-owned)
    self.cooldowns = {}     -- slot -> { q, w, e, r } remaining seconds
    self.stun = {}          -- slot -> remaining stun seconds
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
    self.loadouts[slot] = { q = DEFAULT_LOADOUT.q, w = DEFAULT_LOADOUT.w, e = DEFAULT_LOADOUT.e, r = DEFAULT_LOADOUT.r }
    self.cooldowns[slot] = { q = 0, w = 0, e = 0, r = 0 }
    self.stun[slot] = nil
end

function Game:removePlayer(slot)
    self.players[slot] = nil
    self.health[slot] = nil
    self.loadouts[slot] = nil
    self.cooldowns[slot] = nil
    self.stun[slot] = nil
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
-- rejects empty/cooldown/stunned casters, clamps the target to the ability's
-- range from the caster, enforces a per-owner active cap (oldest removed),
-- instantiates the ability, and starts the cooldown. Returns the clamped
-- coordinates (plus the instance) so callers can echo the authoritative
-- placement; returns nil if the cast was rejected.
function Game:castAbility(slot, key, x, y)
    local player = self.players[slot]
    if not player then
        return nil
    end
    if self:isStunned(slot) then
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

    -- Abilities that require open ground (e.g. traps) reject a placement whose
    -- center falls inside an obstacle. The ability's circle may still overlap the
    -- wall edge, mirroring how point placement works elsewhere.
    if abilityModule.blockedByObstacles and self:isInsideObstacle(cx, cy) then
        return nil
    end

    -- Per-owner active cap (e.g. traps): remove the oldest instance when at cap.
    if abilityModule.maxActive then
        local owned = {}
        for _, existing in ipairs(self.abilities) do
            if existing.owner == slot and existing.abilityId == abilityId then
                table.insert(owned, existing)
            end
        end
        if #owned >= abilityModule.maxActive then
            local oldest = owned[1]
            for _, existing in ipairs(owned) do
                if existing.id < oldest.id then
                    oldest = existing
                end
            end
            for i = #self.abilities, 1, -1 do
                if self.abilities[i] == oldest then
                    table.remove(self.abilities, i)
                    break
                end
            end
        end
    end

    local instance = abilityModule.new(slot, cx, cy)
    instance.id = self.nextAbilityId
    self.nextAbilityId = self.nextAbilityId + 1
    instance.abilityId = abilityId
    instance:cast(slot, cx, cy, player.x, player.y)
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
    self.loadouts[slot] = { q = loadout.q, w = loadout.w, e = loadout.e, r = loadout.r }
end

function Game:setCooldowns(slot, cooldowns)
    local current = self.cooldowns[slot]
    if not current then
        return
    end
    current.q = cooldowns.q or 0
    current.w = cooldowns.w or 0
    current.e = cooldowns.e or 0
    current.r = cooldowns.r or 0
end

----------------------------------------
-- Stun status effect
----------------------------------------
function Game:isStunned(slot)
    return (self.stun[slot] or 0) > 0
end

function Game:getStunRemaining(slot)
    return self.stun[slot] or 0
end

-- Apply a stun: record the remaining time and clear the player's move order.
function Game:applyStun(slot, duration)
    if duration <= 0 then
        return
    end
    self.stun[slot] = duration
    self:clearTarget(slot)
end

-- Authoritative stun reconciliation (client snapshots).
function Game:setStun(slot, stunned, remaining)
    if stunned and remaining and remaining > 0 then
        self.stun[slot] = remaining
    else
        self.stun[slot] = nil
    end
end

-- A stun landing during a cancelable charging ability's windup cancels the cast
-- and refunds its cooldown (Beam, Pool, and morganastun). Bear Trap is not
-- cancelable: its placement is committed at cast.
function Game:cancelChargingAbilities(slot)
    local loadout = self.loadouts[slot]
    local cooldowns = self.cooldowns[slot]

    for i = #self.abilities, 1, -1 do
        local ability = self.abilities[i]
        if ability.owner == slot and ability.cancelable and ability.phase == "charging" then
            table.remove(self.abilities, i)
            if loadout and cooldowns then
                for key, id in pairs(loadout) do
                    if id == ability.abilityId then
                        cooldowns[key] = 0
                        break
                    end
                end
            end
        end
    end
end

-- True while the player is rooted by a charging ability (e.g. Beam windup).
function Game:isRooted(slot)
    for _, ability in ipairs(self.abilities) do
        if ability.owner == slot and ability.isRooting and ability:isRooting() then
            return true
        end
    end
    return false
end

-- Replace the local ability list with authoritative abilities from a snapshot.
function Game:applySnapshotAbilities(abilities)
    local result = {}
    for _, entry in ipairs(abilities or {}) do
        local instance = registry.new(entry.ability, entry.owner, entry.x, entry.y, entry.remaining)
        instance.id = entry.id
        instance.abilityId = entry.ability
        if instance.applySnapshot then
            instance:applySnapshot(entry)
        end
        table.insert(result, instance)
    end
    self.abilities = result
end

----------------------------------------
-- Simulation step
----------------------------------------
function Game:tick(dt)
    -- Advance existing stun timers toward zero.
    for slot, remaining in pairs(self.stun) do
        remaining = remaining - dt
        if remaining <= 0 then
            self.stun[slot] = nil
        else
            self.stun[slot] = remaining
        end
    end

    -- Movement: skip stunned players and players rooted by a charging ability.
    for slot, player in pairs(self.players) do
        if not self:isStunned(slot) and not self:isRooted(slot) then
            self.world:stepPlayer(player, dt)
        end
    end

    -- Advance per-slot cooldowns toward zero (data-driven: q/w/e/r and any
    -- future slots).
    for _, cooldowns in pairs(self.cooldowns) do
        for key, remaining in pairs(cooldowns) do
            if remaining > 0 then
                cooldowns[key] = math.max(0, remaining - dt)
            end
        end
    end

    local playerRadius = self.world.radius

    -- Advance active abilities and apply their damage. A pool deals its per-tick
    -- damage to every player whose circle overlaps the pool's circle (including
    -- the caster). A beam applies its burst once, when its windup completes, to
    -- every player overlapping its line (never the caster).
    for _, ability in ipairs(self.abilities) do
        local result = ability:update(dt) or {}

        if ability.damageModel == "tick" and result.ticks and result.ticks > 0 then
            local perTick = ability:getTickDamage()
            local reach = ability.radius + playerRadius
            local reachSq = reach * reach
            for slot, player in pairs(self.players) do
                local px = player.x - ability.x
                local py = player.y - ability.y
                if px * px + py * py <= reachSq then
                    self.health[slot] = math.max(0, self.health[slot] - result.ticks * perTick)
                end
            end
        end

        if ability.damageModel == "burst" and result.burst then
            local damage = ability:getBurstDamage()
            for slot, player in pairs(self.players) do
                if slot ~= ability.owner and self:overlapsBeam(ability, player.x, player.y) then
                    self.health[slot] = math.max(0, self.health[slot] - damage)
                end
            end
        end
    end

    -- Single-use overlap triggers (traps): an armed trap stuns and begins its
    -- despawn (snap shut + fade) on the first non-stunned player whose circle
    -- overlaps it. The stun lands instantly at the moment of overlap; the trap
    -- lingers while it despawns and can no longer re-trigger (its armed flag
    -- drops when the despawn phase starts). Abilities without a trigger hook
    -- fall back to the old instant removal.
    local newlyStunned = {}
    for _, ability in ipairs(self.abilities) do
        if ability.trigger == "overlap" and ability.armed and ability.active then
            local reach = ability.radius + playerRadius
            local reachSq = reach * reach
            for slot, player in pairs(self.players) do
                if not self:isStunned(slot) then
                    local px = player.x - ability.x
                    local py = player.y - ability.y
                    if px * px + py * py <= reachSq then
                        self:applyStun(slot, ability.stunDuration or 0)
                        newlyStunned[slot] = true
                        if ability.onTrigger then
                            ability:onTrigger()
                        else
                            ability.active = false
                        end
                        break
                    end
                end
            end
        end
    end

    -- Projectile triggers (morganastun): advance along the direction at fixed
    -- speed, then stop on the first non-caster player it overlaps, stunning them.
    -- It ignores obstacles and despawns after covering its full range.
    for _, ability in ipairs(self.abilities) do
        if ability.trigger == "projectile" and ability.active and ability.phase == "flying" then
            local step = ability.speed * dt
            ability.x = ability.x + ability.directionX * step
            ability.y = ability.y + ability.directionY * step
            ability.traveled = (ability.traveled or 0) + step

            if ability.traveled >= ability.range then
                ability.active = false
            else
                local reach = ability.radius + playerRadius
                local reachSq = reach * reach
                for slot, player in pairs(self.players) do
                    if slot ~= ability.owner then
                        local px = player.x - ability.x
                        local py = player.y - ability.y
                        if px * px + py * py <= reachSq then
                            self:applyStun(slot, ability.stunDuration)
                            newlyStunned[slot] = true
                            ability.active = false
                            break
                        end
                    end
                end
            end
        end
    end

    -- A stun that landed during a cancelable windup cancels the cast and refunds
    -- the cooldown.
    for slot in pairs(newlyStunned) do
        self:cancelChargingAbilities(slot)
    end

    -- Remove expired/consumed abilities.
    for i = #self.abilities, 1, -1 do
        if not self.abilities[i].active then
            table.remove(self.abilities, i)
        end
    end
end

-- True when a point falls strictly inside any obstacle rectangle (matching the
-- world's walkability convention: the boundary itself is open ground).
-- Deterministic on both client and server, so predicted placements reconcile.
function Game:isInsideObstacle(x, y)
    local obstacles = self.world.obstacles
    for i = 1, #obstacles do
        local o = obstacles[i]
        if x > o.x and x < o.x + o.width and y > o.y and y < o.y + o.height then
            return true
        end
    end
    return false
end

-- Distance from a point to a beam's center segment (capsule overlap test).
function Game:overlapsBeam(ability, px, py)
    local ox, oy = ability.x, ability.y
    local dx, dy = ability.directionX, ability.directionY
    local length = ability.length or 0
    local halfWidth = (ability.width or 0) / 2

    local vx = px - ox
    local vy = py - oy
    local t = vx * dx + vy * dy
    if t < 0 then
        t = 0
    elseif t > length then
        t = length
    end

    local closestX = ox + dx * t
    local closestY = oy + dy * t
    local distX = px - closestX
    local distY = py - closestY
    local reach = halfWidth + self.world.radius
    return distX * distX + distY * distY <= reach * reach
end

----------------------------------------
-- State accessors
----------------------------------------
-- Live reference to a player's simulation state. Used by the client session for
-- prediction/introspection; mutating callers must go through the commands above.
function Game:getPlayerRef(slot)
    return self.players[slot]
end

-- Read-only copy of a player's position, health, and stun state.
function Game:getPlayer(slot)
    local player = self.players[slot]
    if not player then
        return nil
    end
    return {
        x = player.x,
        y = player.y,
        hp = self.health[slot],
        stunned = self:isStunned(slot),
        stunRemaining = self:getStunRemaining(slot),
    }
end

-- Read-only snapshot of all player positions + health + stun: slot -> table.
function Game:getPlayers()
    local result = {}
    for slot, player in pairs(self.players) do
        result[slot] = {
            x = player.x,
            y = player.y,
            hp = self.health[slot],
            stunned = self:isStunned(slot),
            stunRemaining = self:getStunRemaining(slot),
        }
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

-- Count a player's active abilities of a given id (e.g. placed traps).
function Game:countActiveAbilities(slot, abilityId)
    local count = 0
    for _, ability in ipairs(self.abilities) do
        if ability.owner == slot and ability.abilityId == abilityId then
            count = count + 1
        end
    end
    return count
end

-- Serialized ability list for snapshots: { id, ability, owner, x, y, remaining,
-- plus type-specific fields from the ability's getSnapshot() }.
function Game:getAbilitiesSnapshot()
    local result = {}
    for _, ability in ipairs(self.abilities) do
        local entry = {
            id = ability.id,
            ability = ability.abilityId,
            owner = ability.owner,
            x = ability.x,
            y = ability.y,
            remaining = ability.remaining,
        }
        if ability.getSnapshot then
            for k, v in pairs(ability:getSnapshot()) do
                entry[k] = v
            end
        end
        table.insert(result, entry)
    end
    return result
end

return Game
