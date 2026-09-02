-- Morgana's Stun (Dark Binding): a full-range direction-based skillshot.
--
-- Aiming is direction-based (Lux R feel): the clicked point only derives a unit
-- direction from the caster, and the projectile always flies its full range
-- regardless of click distance. The cast enters a 0.5s "charging" phase during
-- which the caster is rooted (with no direction telegraph drawn), then a
-- projectile is launched that flies at fixed speed, passes over obstacles, and
-- stops on the first non-caster player it touches, stunning them for 2s (no
-- damage). The 10s cooldown starts on cast; a stun that interrupts the windup
-- cancels the cast and refunds it.
--
-- Static tuning lives here so engine code never needs to change to rebalance.

local Stun = {}
Stun.__index = Stun

-- Static tuning + metadata (the shared ability contract).
Stun.name = "Morgana's Stun"
Stun.type = "projectile"
Stun.shape = "circle"            -- circular hitbox for the projectile
Stun.damageModel = "none"        -- pure crowd control; no damage
Stun.trigger = "projectile"      -- handled by the simulation's projectile pass
Stun.cooldown = 10               -- seconds, starts on cast
Stun.damage = 0
Stun.range = 500                 -- full travel distance (and cast range clamp)
Stun.speed = 315                 -- projectile speed in px/s (3/4 of the original 420)
Stun.radius = 14                 -- projectile hitbox radius in px
Stun.charge = 0.5                -- windup duration (rooted)
Stun.stunDuration = 2            -- seconds of stun applied on hit
Stun.cancelable = true           -- a stun during the windup cancels + refunds
Stun.icon = { col = 2, row = 0 } -- HUD tile in abilities_tilemap.png (top-right)

function Stun.new(owner, x, y, remaining)
    local self = setmetatable({}, Stun)
    self.owner = owner
    self.x = x or 0
    self.y = y or 0
    self.directionX = 1
    self.directionY = 0
    self.phase = "charging"      -- "charging" -> "flying" -> (removed)
    self.remaining = remaining or Stun.charge
    self.traveled = 0            -- distance covered during the flying phase
    self.active = true
    return self
end

-- Lock in the firing direction from the caster position to the clicked point.
-- The target distance is ignored: the projectile always flies its full range.
function Stun:cast(caster, x, y, casterX, casterY)
    self.x = casterX
    self.y = casterY
    local dx = x - casterX
    local dy = y - casterY
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance > 0 then
        self.directionX = dx / distance
        self.directionY = dy / distance
    else
        -- Click exactly on self: no direction, fire a deterministic default.
        self.directionX = 1
        self.directionY = 0
    end
end

-- Advance the windup timer. The projectile's movement and full-range despawn are
-- driven by the simulation's projectile pass; this only handles the phase.
function Stun:update(dt)
    if self.phase == "charging" then
        self.remaining = self.remaining - dt
        if self.remaining <= 0 then
            self.remaining = 0
            self.phase = "flying"
        end
    end
    return {}
end

-- Rooting: the caster cannot move while the windup is charging.
function Stun:isRooting()
    return self.phase == "charging"
end

-- Type-specific snapshot fields (direction + phase + flight progress).
function Stun:getSnapshot()
    return {
        directionX = self.directionX,
        directionY = self.directionY,
        phase = self.phase,
        traveled = self.traveled,
    }
end

function Stun:applySnapshot(entry)
    if entry.directionX ~= nil then
        self.directionX = entry.directionX
    end
    if entry.directionY ~= nil then
        self.directionY = entry.directionY
    end
    self.phase = entry.phase or "charging"
    if self.phase == "charging" then
        self.remaining = entry.remaining or Stun.charge
    else
        self.remaining = 0
    end
    self.traveled = entry.traveled or 0
end

-- Rendering: nothing during the windup (no direction telegraph); only the
-- projectile itself is drawn as a dark-purple orb while in flight.
-- No animation spec (src.anim.engine) yet: primitive rendering only. Future
-- sprite art should migrate this to a spec so it can animate like Bear Trap.
function Stun:draw(colors)
    if self.phase ~= "flying" then
        return
    end
    local fill = colors and colors.stunProjectile
    if fill then
        love.graphics.setColor(fill[1], fill[2], fill[3], fill[4] or 1)
        love.graphics.circle("fill", self.x, self.y, Stun.radius)
    end
end

return Stun
