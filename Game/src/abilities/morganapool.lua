-- Morgana's Pool: a damaging ground-target area with a short cast windup.
--
-- Static properties are declared here (localized next to the behavior) so tuning
-- never requires touching engine code. The "type" field is descriptive metadata
-- only — no engine dispatch is keyed off it.
--
-- Lifecycle: new(owner, x, y, remaining) creates an instance in the "charging"
-- phase, cast(caster, x, y) is a no-op (placement is committed in new()), and
-- update(dt) advances the windup first, then the tick/expiry timers once active.
-- The caster is rooted during the windup and a faint telegraph circle is drawn
-- at the target; the pool only starts dealing damage after the windup completes.

local Pool = {}
Pool.__index = Pool

-- Static tuning + metadata (the shared ability contract).
Pool.name = "Morgana's Pool"
Pool.type = "pool"
Pool.shape = "circle"          -- circular damage shape
Pool.damageModel = "tick"      -- damage applied as per-second ticks
Pool.trigger = nil             -- no overlap trigger
Pool.cooldown = 6    -- seconds, starts on cast
Pool.damage = 30     -- damage per second, applied as ticks
Pool.range = 200     -- cast range in pixels (clamped at the boundary)
Pool.radius = 60     -- effect radius in pixels
Pool.duration = 2    -- seconds the pool persists (after the windup)
Pool.charge = 0.5    -- windup duration (rooted)
Pool.tickInterval = 0.25
Pool.cancelable = true -- a stun during the windup cancels + refunds

function Pool.new(owner, x, y, remaining)
    local self = setmetatable({}, Pool)
    self.owner = owner
    self.x = x or 0
    self.y = y or 0
    self.phase = "charging"     -- "charging" -> "active" -> (removed)
    self.remaining = remaining or Pool.charge
    self.tickTimer = 0
    self.active = true
    return self
end

-- Uniform lifecycle hook. Placement is already committed in new(); the windup
-- is driven by update().
function Pool:cast(caster, x, y)
end

-- Advance the windup, then the tick/expiry timers, and report how many damage
-- ticks elapsed this step. The simulation applies the returned ticks to
-- overlapping players; no ticks are reported while still charging.
function Pool:update(dt)
    if self.phase == "charging" then
        self.remaining = self.remaining - dt
        if self.remaining <= 0 then
            self.remaining = Pool.duration
            self.phase = "active"
        end
        return {}
    end

    local ticks = 0
    self.tickTimer = self.tickTimer + dt
    while self.tickTimer >= Pool.tickInterval do
        self.tickTimer = self.tickTimer - Pool.tickInterval
        ticks = ticks + 1
    end

    self.remaining = self.remaining - dt
    if self.remaining <= 0 then
        self.remaining = 0
        self.active = false
    end
    return { ticks = ticks }
end

-- Damage applied per tick (30/sec over 0.25s ticks).
function Pool:getTickDamage()
    return Pool.damage * Pool.tickInterval
end

-- Rooting: the caster cannot move while the windup is charging.
function Pool:isRooting()
    return self.phase == "charging"
end

-- Type-specific snapshot fields (effect radius + phase).
function Pool:getSnapshot()
    return { radius = Pool.radius, phase = self.phase }
end

function Pool:applySnapshot(entry)
    self.phase = entry.phase or "charging"
    if self.phase == "charging" then
        self.remaining = entry.remaining or Pool.charge
    else
        self.remaining = entry.remaining or Pool.duration
    end
end

-- Placeholder rendering: a faint target telegraph during the windup, then a
-- translucent purple fill with a brighter outline once active.
function Pool:draw(colors)
    if self.phase == "charging" then
        local telegraph = colors and colors.poolTelegraph
        if telegraph then
            love.graphics.setColor(telegraph[1], telegraph[2], telegraph[3], telegraph[4] or 1)
            love.graphics.circle("line", self.x, self.y, Pool.radius)
        end
        return
    end

    local fill = colors and colors.poolFill
    local outline = colors and colors.poolOutline

    if fill then
        love.graphics.setColor(fill[1], fill[2], fill[3], fill[4] or 1)
        love.graphics.circle("fill", self.x, self.y, self.radius)
    end
    if outline then
        love.graphics.setColor(outline[1], outline[2], outline[3], outline[4] or 1)
        love.graphics.circle("line", self.x, self.y, self.radius)
    end
end

return Pool
