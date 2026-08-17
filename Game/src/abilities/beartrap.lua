-- Bear Trap: a placeable, single-use crowd-control trap.
--
-- On cast a trap is placed at the clicked spot (clamped to range, through
-- obstacles). It takes 0.75s to arm, then lingers for 30s. The first time a
-- non-stunned player overlaps an armed trap it is consumed and that player is
-- stunned for 2s (no damage). A player may have up to 4 live traps; placing a
-- 5th removes the oldest. The 6s cooldown starts on cast.
--
-- Static tuning lives here so engine code never needs to change to rebalance.

local Trap = {}
Trap.__index = Trap

-- Static tuning + metadata (the shared ability contract).
Trap.name = "Bear Trap"
Trap.type = "trap"
Trap.shape = "circle"          -- circle overlap for the trigger
Trap.damageModel = "none"      -- no damage; stun only
Trap.trigger = "overlap"       -- single-use overlap trigger
Trap.cooldown = 6              -- seconds, starts on cast
Trap.damage = 0
Trap.range = 200               -- cast range in pixels (clamped at the boundary)
Trap.radius = 20               -- trigger radius in pixels
Trap.armDelay = 0.75           -- seconds until armed
Trap.duration = 30             -- seconds an armed trap lingers
Trap.stunDuration = 2          -- seconds of stun applied on trigger
Trap.maxActive = 4             -- per-owner cap of live traps
Trap.blockedByObstacles = true -- placement center must not be inside an obstacle

function Trap.new(owner, x, y, remaining)
    local self = setmetatable({}, Trap)
    self.owner = owner
    self.x = x or 0
    self.y = y or 0
    self.remaining = remaining or Trap.duration
    self.armed = false
    self.armRemaining = Trap.armDelay
    self.active = true
    return self
end

-- Instant placement; the arming delay begins immediately.
function Trap:cast(caster, x, y)
end

-- Advance the arming and expiry timers. No damage; the trigger is handled by the
-- simulation using the "overlap" trigger contract.
function Trap:update(dt)
    if not self.armed then
        self.armRemaining = self.armRemaining - dt
        if self.armRemaining <= 0 then
            self.armRemaining = 0
            self.armed = true
        end
    end

    self.remaining = self.remaining - dt
    if self.remaining <= 0 then
        self.remaining = 0
        self.active = false
    end
    return {}
end

function Trap:isRooting()
    return false
end

-- Type-specific snapshot fields (armed state + arming timer).
function Trap:getSnapshot()
    return {
        radius = Trap.radius,
        armed = self.armed,
        armRemaining = self.armRemaining,
    }
end

function Trap:applySnapshot(entry)
    self.armed = not not entry.armed
    self.armRemaining = entry.armRemaining or 0
end

-- Rendering: arming traps pulse dimly, armed traps are solid.
function Trap:draw(colors)
    local color = self.armed and colors.trapArmed or colors.trapArming
    local outline = colors.trapOutline or colors.trapArmed
    if not color then
        return
    end

    local alpha = color[4] or 1
    if not self.armed then
        local pulse = 0.5 + 0.5 * math.sin(love.timer.getTime() * 6)
        alpha = alpha * (0.4 + 0.6 * pulse)
    end

    love.graphics.setColor(color[1], color[2], color[3], alpha)
    love.graphics.circle("fill", self.x, self.y, Trap.radius)

    if outline then
        love.graphics.setColor(outline[1], outline[2], outline[3], outline[4] or 1)
        love.graphics.circle("line", self.x, self.y, Trap.radius)
    end
end

return Trap
