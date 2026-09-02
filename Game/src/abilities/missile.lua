-- Missile: a ground-targeted, delayed area blast (Veigar-W feel). Bound to the
-- fifth loadout slot, d, alongside q/w/e/r.
--
-- The cast is instant and does not root the caster: clicking a ground target
-- (clamped to range, and rejected if its center is inside an obstacle) commits
-- the placement at once and starts the 8s cooldown. A falling-missile ground
-- mark plays for 1.0s ("falling"), then the missile impacts: it deals a single
-- 60-damage burst to every player whose circle overlaps the 55px blast radius
-- -- including the caster, mirroring Morgana's Pool -- and erupts in fire
-- particles that fade out over 0.7s ("impact"). The fire burst is spawned
-- client-locally by the animation engine's cosmetic "impact" event.
--
-- The visual lifecycle is an explicit two-phase state machine -- "falling" ->
-- "impact" -> removed -- and every timer that feeds it is simulation state
-- (never wall-clock), so predicted and authoritative instances stay bit-for-bit
-- identical and snapshots carry the phase. The shared `remaining` field
-- carries whichever timer is active: fall time during "falling", fade time
-- during "impact".
--
-- Rendering uses the missile sprite sheet (sprites/missile_tilemap.png, a 5x4
-- grid of 320px tiles; frames 0-8 are the falling mark and 9-13 the impact
-- fire, 14-19 empty), each tile drawn at 80x80 in-world, centered, unrotated.
-- Frame and alpha are produced by the pure animation engine (src/anim.engine)
-- from this module's animation spec -- one entry per phase declared as inline
-- data beside the tuning below. The engine is never evaluated on the headless
-- server; only the client renderer runs it (at draw time and to consume the
-- spec's cosmetic "impact" event, which spawns the fire burst). The atlas is
-- created lazily inside draw() only: this module is also loaded by the
-- headless server, where the graphics module is disabled.
--
-- Static tuning lives here so engine code never needs to change to rebalance.

local Sprites = require("src.sprites")
local Anim = require("src.anim.engine")

local Missile = {}
Missile.__index = Missile

-- Static tuning + metadata (the shared ability contract).
Missile.name = "Missile"
Missile.type = "missile"
Missile.shape = "circle"           -- circular burst shape
Missile.damageModel = "burst"      -- single burst on impact (vs. per-second ticks)
Missile.trigger = nil              -- no overlap trigger
Missile.cooldown = 8               -- seconds, starts on cast
Missile.damage = 60                -- single burst damage
Missile.range = 300                -- cast range in pixels (clamped at the boundary)
Missile.radius = 55                -- blast radius in pixels at impact
Missile.fallDuration = 1.0         -- seconds the falling-missile mark plays before impact
Missile.fadeDuration = 0.7         -- seconds the impact fire lingers before removal
Missile.cancelable = false         -- cast is instant/committed; nothing to cancel or refund
Missile.blockedByObstacles = true  -- placement center must not be inside an obstacle
Missile.icon = { col = 1, row = 1 } -- HUD tile in abilities_tilemap.png: 0-indexed tile
                                    -- index 4 (col=1, row=1) of the 3x2 grid

-- Missile sheet animation map (0-indexed, row-major across 5 columns of a 5x4
-- grid of 320px tiles): frames 0-8 are the falling mark, 9-13 the impact fire
-- burst. Frames 14-19 are empty and never drawn.
local MISSILE_PATH = "sprites/missile_tilemap.png"
local MISSILE_TILE = 320           -- sheet is a 5x4 grid of 320px tiles
local MISSILE_FRAMES_PER_ROW = 5
local MISSILE_DRAW_SIZE = 80       -- in-world size of each tile (centered on the ability)
local MISSILE_SCALE = MISSILE_DRAW_SIZE / MISSILE_TILE

-- Animation spec: one entry per phase, declared as inline Lua data beside the
-- tuning above and loaded through the engine's loader (src.anim.engine). The
-- engine is a pure evaluator, so these numbers produce deterministic poses
-- from the simulation timers:
--   * falling walks frames 0 -> 8 over fallDuration (the missile dropping onto
--     its ground mark), with the engine's stepped clip indexing.
--   * impact plays the fire clip 9 -> 13 over fadeDuration, fades alpha 1 -> 0
--     linearly across the same window, and crosses a cosmetic "impact" event
--     at offset 0 so the client can burst the fire particles.
Missile.animation = Anim.load({
    falling = {
        type = "clip",
        frames = { 0, 1, 2, 3, 4, 5, 6, 7, 8 },
        duration = Missile.fallDuration,
    },
    impact = {
        type = "timeline",
        tracks = {
            { type = "clip", at = 0, frames = { 9, 10, 11, 12, 13 }, duration = Missile.fadeDuration },
            { type = "tween", at = 0, property = "alpha", from = 1, to = 0, duration = Missile.fadeDuration, easing = "linear" },
            { type = "event", at = 0, name = "impact" },
        },
    },
})

-- Fire burst tuning for the impact cosmetic (client-local; lives beside the
-- spec so it can be tuned without touching engine or particle code). Count,
-- speed, color, and lifetime are all declared here.
Missile.fire = {
    count = 18,          -- orange/red embers kicked up by the blast
    speed = 190,         -- base outward speed (px/s)
    speedVariance = 110, -- +/- per-particle speed
    lifetime = 0.7,      -- seconds each ember lingers (matches the impact fade)
    lifetimeVariance = 0.15,
    color = { 1.0, 0.42, 0.08 }, -- hot orange-red
    size = 3,
    drag = 5,            -- mild exponential slow-down so the burst hugs the ground
}

local missileAtlas -- created on first draw; never touched by the headless server

function Missile.new(owner, x, y, remaining)
    local self = setmetatable({}, Missile)
    self.owner = owner
    self.x = x or 0
    self.y = y or 0
    self.phase = "falling"       -- "falling" -> "impact" -> removed
    self.remaining = remaining or Missile.fallDuration
    self.active = true
    return self
end

-- Instant placement; the fall timer begins immediately in update(). No cast
-- root, no refundable windup: placement is committed at cast.
function Missile:cast(caster, x, y)
end

-- Advance the fall timer, then the impact fade timer. Returns { burst = true }
-- on the single tick where the fall completes and the burst must be applied.
function Missile:update(dt)
    if self.phase == "falling" then
        self.remaining = self.remaining - dt
        if self.remaining <= 0 then
            self.remaining = 0
            self.phase = "impact"
            self.remaining = Missile.fadeDuration
            return { burst = true }
        end
    elseif self.phase == "impact" then
        self.remaining = self.remaining - dt
        if self.remaining <= 0 then
            self.remaining = 0
            self.active = false
        end
    end
    return {}
end

function Missile:getBurstDamage()
    return Missile.damage
end

-- Rooting: the missile cast is instant, so the caster is never rooted.
function Missile:isRooting()
    return false
end

-- Type-specific snapshot fields (blast radius + phase). The active timer
-- travels via the shared `remaining` field in the abilities list, so
-- prediction reconciles bit-for-bit: `remaining` is handed to new() from the
-- entry and applySnapshot only has to reconstruct the phase.
function Missile:getSnapshot()
    return {
        radius = Missile.radius,
        phase = self.phase,
    }
end

function Missile:applySnapshot(entry)
    self.phase = entry.phase or "falling"
    -- remaining was already set in new() from the abilities-list entry.
end

-- Seconds into the current phase, derived from the ability's own simulation
-- timers. This is the hook the animation engine (and the client renderer's
-- event tracking) uses: given the phase and this elapsed, the pure evaluator
-- yields the pose.
function Missile:getAnimationElapsed()
    if self.phase == "falling" then
        return Missile.fallDuration - self.remaining
    elseif self.phase == "impact" then
        return Missile.fadeDuration - self.remaining
    end
    return 0
end

-- Frame index for the current phase: a thin wrapper over the pure animation
-- engine (Missile.animation), still a pure function of simulation timers so
-- predicted and authoritative instances render identically: 0 -> 8 while
-- falling (the missile mark), then 9 -> 13 while the impact fire fades.
function Missile:getFrame()
    return Anim.evaluate(Missile.animation, self.phase, self:getAnimationElapsed()).frame
end

-- Draw alpha: also a thin wrapper over the engine. 1 while falling and at the
-- instant of impact, then a linear dissolve to 0 over the impact phase (the
-- impact timeline's alpha tween). Pure function of sim timers.
function Missile:getAlpha()
    return Anim.evaluate(Missile.animation, self.phase, self:getAnimationElapsed()).alpha
end

-- Rendering: the missile sprite tile at 80x80 px (scale 0.25 from the 320px
-- tiles), centered on the ability, unrotated. Alpha is applied via the draw
-- color. The atlas is created on first draw only; the headless server never
-- reaches this code. The ground mark is sprite-only: the falling frames ARE
-- the telegraph, so no separate primitive circle is drawn.
function Missile:draw(colors)
    if not missileAtlas then
        missileAtlas = Sprites.new(MISSILE_PATH, MISSILE_TILE)
    end

    local frame = self:getFrame()
    local col = frame % MISSILE_FRAMES_PER_ROW
    local row = math.floor(frame / MISSILE_FRAMES_PER_ROW)
    local quad = Sprites.quad(missileAtlas, col, row)

    love.graphics.setColor(1, 1, 1, self:getAlpha())
    love.graphics.draw(
        missileAtlas.image,
        quad,
        self.x, self.y,
        0,
        MISSILE_SCALE, MISSILE_SCALE,
        MISSILE_TILE / 2, MISSILE_TILE / 2
    )
end

return Missile
