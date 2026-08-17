-- Beam: a directional, long-range line burst with a short cast windup.
--
-- Aiming is direction-based (Lux R feel): the clicked point is only used to
-- derive a unit direction from the caster, and the beam always travels its full
-- length along that line regardless of how far away the click was. The cast
-- enters a 0.5s "charging" phase during which the caster is rooted and a faint
-- telegraph is drawn, then fires a single 50-damage burst to every player whose
-- circle overlaps the 35px-wide x 500px-long line (never the caster), and stays
-- visible for ~0.5s. The 8s cooldown starts on cast; a stun that interrupts the
-- windup cancels the cast and refunds it.
--
-- Static tuning lives here so engine code never needs to change to rebalance.

local Beam = {}
Beam.__index = Beam

-- Static tuning + metadata (the shared ability contract).
Beam.name = "Beam"
Beam.type = "beam"
Beam.shape = "line"            -- damage shape: a rectangle/capsule along a direction
Beam.damageModel = "burst"     -- single burst on fire (vs. per-second ticks)
Beam.trigger = nil             -- no overlap trigger
Beam.cooldown = 8              -- seconds, starts on cast
Beam.damage = 50               -- single burst damage
Beam.range = 500               -- cast range clamp (direction is preserved either way)
Beam.length = 500              -- beam length in pixels
Beam.width = 35                -- beam width in pixels
Beam.charge = 0.5              -- windup duration (rooted)
Beam.linger = 0.5              -- visibility after firing

function Beam.new(owner, x, y, remaining)
    local self = setmetatable({}, Beam)
    self.owner = owner
    self.x = x or 0
    self.y = y or 0
    self.directionX = 1
    self.directionY = 0
    self.phase = "charging"     -- "charging" -> "firing" -> (removed)
    self.remaining = remaining or Beam.charge
    self.fired = false
    self.active = true
    return self
end

-- Lock in the firing direction from the caster position to the clicked point.
-- The target distance is ignored: the beam always travels its full length.
function Beam:cast(caster, x, y, casterX, casterY)
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

-- Advance the windup/linger timers. Returns { burst = true } on the single tick
-- where the windup completes and the burst must be applied.
function Beam:update(dt)
    if self.phase == "charging" then
        self.remaining = self.remaining - dt
        if self.remaining <= 0 then
            self.remaining = Beam.linger
            self.phase = "firing"
            self.fired = true
            return { burst = true }
        end
    elseif self.phase == "firing" then
        self.remaining = self.remaining - dt
        if self.remaining <= 0 then
            self.remaining = 0
            self.active = false
        end
    end
    return {}
end

function Beam:getBurstDamage()
    return Beam.damage
end

-- Rooting: the caster cannot move while the windup is charging.
function Beam:isRooting()
    return self.phase == "charging"
end

-- Type-specific snapshot fields (direction + phase; remaining covers the timer).
function Beam:getSnapshot()
    return {
        directionX = self.directionX,
        directionY = self.directionY,
        phase = self.phase,
    }
end

function Beam:applySnapshot(entry)
    if entry.directionX ~= nil then
        self.directionX = entry.directionX
    end
    if entry.directionY ~= nil then
        self.directionY = entry.directionY
    end
    self.phase = entry.phase or "charging"
    if self.phase == "charging" then
        self.remaining = entry.remaining or Beam.charge
    elseif self.phase == "firing" then
        self.remaining = entry.remaining or Beam.linger
    else
        self.remaining = 0
    end
    self.fired = (self.phase == "firing")
end

-- Rendering: a faint telegraph line during the windup, then the fired beam as a
-- translucent rectangle during the linger.
function Beam:draw(colors)
    local ox, oy = self.x, self.y
    local dx, dy = self.directionX, self.directionY
    local length = Beam.length
    local width = Beam.width
    local ex = ox + dx * length
    local ey = oy + dy * length
    local px, py = -dy, dx
    local hw = width / 2

    if self.phase == "charging" then
        local telegraph = colors and colors.beamTelegraph
        if telegraph then
            love.graphics.setColor(telegraph[1], telegraph[2], telegraph[3], telegraph[4] or 1)
            love.graphics.setLineWidth(2)
            love.graphics.line(ox, oy, ex, ey)
            love.graphics.setLineWidth(1)
        end
    else
        local fill = colors and colors.beamFill
        if fill then
            love.graphics.setColor(fill[1], fill[2], fill[3], fill[4] or 1)
            love.graphics.polygon("fill",
                ox - px * hw, oy - py * hw,
                ox + px * hw, oy + py * hw,
                ex + px * hw, ey + py * hw,
                ex - px * hw, ey - py * hw
            )
        end
    end
end

return Beam
