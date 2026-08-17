-- Morgana's Pool: a damaging ground-target area that lingers for a short time.
--
-- Static properties are declared here (localized next to the behavior) so tuning
-- never requires touching engine code. The "type" field is descriptive metadata
-- only — no engine dispatch is keyed off it.
--
-- Lifecycle: new(owner, x, y, remaining) creates an active instance,
-- cast(caster, x, y) starts it (no-op here — the pool is instant), update(dt)
-- advances the tick/expiry timers and returns how many damage ticks elapsed this
-- step, and draw(colors) renders the placeholder purple circle on the client.

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
Pool.duration = 2    -- seconds the pool persists
Pool.tickInterval = 0.25

function Pool.new(owner, x, y, remaining)
    local self = setmetatable({}, Pool)
    self.owner = owner
    self.x = x or 0
    self.y = y or 0
    self.remaining = remaining or Pool.duration
    self.tickTimer = 0
    self.active = true
    return self
end

-- Uniform lifecycle hook. Morgana's Pool has no cast time: placement is already
-- committed in new(). Future cast-time abilities can phase here.
function Pool:cast(caster, x, y)
end

-- Advance the tick/expiry timers and report how many damage ticks elapsed this
-- step. The simulation applies the returned ticks to overlapping players.
function Pool:update(dt)
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

-- Pool never roots its caster.
function Pool:isRooting()
    return false
end

-- Type-specific snapshot fields (effect radius).
function Pool:getSnapshot()
    return { radius = Pool.radius }
end

-- Placeholder rendering: translucent purple fill with a brighter outline.
function Pool:draw(colors)
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
