-- Bear Trap: a placeable, single-use crowd-control trap.
--
-- On cast a trap is placed at the clicked spot (clamped to range, through
-- obstacles) and the caster is rooted for 0.5s while it arms. The trap itself
-- takes 0.75s to arm, then lingers for 30s. The first time a non-stunned player
-- overlaps an armed trap it is stunned for 2s (no damage) and the trap begins
-- its despawn phase: it snaps shut and fades out over 0.45s before the engine's
-- removal sweep drops it, so the catch reads visually instead of the trap
-- vanishing in a single frame. Natural expiry plays the same snap + fade. A
-- player may have up to 4 live traps; placing a 5th removes the oldest. The 6s
-- cooldown starts on cast. Placement is committed at cast, so a stun during the
-- 0.5s root does not refund the cooldown or remove the trap.
--
-- The visual lifecycle is an explicit three-phase state machine -- "arming" ->
-- "armed" -> "despawning" -> removed -- and every timer that feeds it is
-- simulation state (never wall-clock), so predicted and authoritative instances
-- stay bit-for-bit identical and snapshots carry the phase.
--
-- Rendering uses the flytrap sprite sheet (sprites/flytrap_tilemap.png, a 5x4
-- grid of 320px tiles; frames 0-12 are the animation -- 0 closed pod, 1
-- opening, 2..6 fully open, 7..12 closing -- and 13-19 are empty). On trigger
-- the trap rotates so its bottom (the closed pod's tip) points at the victim
-- (the rotation is simulation state, carried by snapshots), so the snap reads
-- as catching them rather than closing in the air. The atlas is created lazily
-- inside draw() only: this module is also loaded by the headless server, where
-- the graphics module is disabled.
--
-- Frame and alpha are produced by the pure animation engine (src/anim.engine)
-- from this module's animation spec -- one entry per phase (arming, armed,
-- despawning) declared as inline data beside the tuning below -- and the
-- migration preserves the exact pre-spec output. The engine is never evaluated
-- on the headless server; only the client renderer runs it (at draw time and
-- to consume the spec's cosmetic "snap" event, which spawns the Trap.dust
-- burst). Abilities without a spec keep their primitive rendering.
--
-- Static tuning lives here so engine code never needs to change to rebalance.

local Sprites = require("src.sprites")
local Anim = require("src.anim.engine")

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
Trap.radius = 10               -- trigger radius in pixels: deliberately half the 40px sprite's
                                -- half-width (20px), so a player must visibly step onto the trap
                                -- (their center within 18px = trap 10 + player 8) to trigger it.
Trap.armDelay = 0.75           -- seconds until armed
Trap.duration = 30             -- seconds an armed trap lingers
Trap.stunDuration = 2          -- seconds of stun applied on trigger
Trap.castRoot = 0.5            -- seconds the caster is rooted after placing
Trap.maxActive = 4             -- per-owner cap of live traps
Trap.cancelable = false        -- placement is committed at cast (not refunded)
Trap.blockedByObstacles = true -- placement center must not be inside an obstacle
Trap.icon = { col = 1, row = 0 } -- HUD tile in abilities_tilemap.png (top-middle)

-- Despawn linger: the trap snaps shut (0.15s) and fades out (0.3s) over 0.45s
-- before removal. Declared next to the other tuning.
Trap.snapDuration = 0.15       -- seconds: frames 6 -> 0 (close fast)
Trap.fadeDuration = 0.3        -- seconds: alpha dissolve while closed
Trap.despawnDuration = 0.45    -- seconds: snap + fade total linger

-- Flytrap sheet animation map (0-indexed, row-major across 5 columns of a 5x4
-- grid of 320px tiles): 0 = closed pod (arming start), 1 = opening, 2..6 =
-- fully open (6 = armed/ready), 7..12 = closing frames, 0 = fully closed (snap
-- end). Frames 13-19 are empty and never drawn.
local FLYTRAP_PATH = "sprites/flytrap_tilemap.png"
local FLYTRAP_TILE = 320           -- sheet is a 5x4 grid of 320px tiles
local FLYTRAP_FRAMES_PER_ROW = 5
local FLYTRAP_DRAW_SIZE = 40       -- in-world size, matching the old placeholder circle
local FLYTRAP_SCALE = FLYTRAP_DRAW_SIZE / FLYTRAP_TILE
local FRAME_ARM_START = 0          -- fully closed pod
local FRAME_READY = 6              -- fully open (armed)

-- The snap-shut path is not a numeric lerp: the closing frames 7..12 sit
-- between the ready frame (6) and the closed pose (0) in sheet order, so the
-- animation walks an explicit sequence. Frames 7-12 are identical in the art;
-- they hold the folded-jaws pose briefly before the final close.
local SNAP_FRAMES = { 6, 7, 8, 9, 10, 11, 12, 0 }

-- The closed pod's long axis is vertical, so its bottom tip sits at
-- sprite-local DOWN. The trigger rotation subtracts this angle to make the
-- pod's bottom point at the victim (a victim to the right of the trap tilts
-- the pod so its tip faces them). The fully-open pose is a symmetric star, so
-- the aim is only visibly directional in the folded/closed poses -- which is
-- exactly what the snap + fade shows. Tunable if the art ever changes.
local POD_BOTTOM_ANGLE = math.pi / 2

-- Victims approaching along the pod's axis (directly above or below the trap)
-- need no rotation: the vertical pod is already pointing their way, and a 180
-- deg flip on the symmetric pod is invisible. Only victims meaningfully to the
-- side (more than this far from the vertical axis) rotate to aim at them.
local VERTICAL_DEADZONE = math.pi / 4 -- 45 deg half-cone above and below

-- Animation spec: one entry per phase, declared as inline Lua data beside the
-- tuning above and loaded through the engine's loader (src.anim.engine). The
-- engine is a pure evaluator, so these numbers reproduce the exact frame/alpha
-- output of the pre-migration hand-rolled math:
--   * arming walks frames 0 -> 6 over armDelay. The engine's stepped clip
--     indexes with round(1 + t/duration*(n-1)), which equals the old
--     round(6 * progress) stepping, so the frames are byte-identical.
--   * armed holds frame 6 (the ready pose) for the whole lifetime.
--   * despawning plays the closing sequence 6 -> 7..12 -> 0 over snapDuration
--     (the same round-based stepping as the old SNAP_FRAMES walk), then fades
--     alpha 1 -> 0 linearly over fadeDuration, and crosses a cosmetic "snap"
--     event at snap completion so the client can burst the dust.
Trap.animation = Anim.load({
    arming = {
        type = "clip",
        frames = { FRAME_ARM_START, 1, 2, 3, 4, 5, FRAME_READY },
        duration = Trap.armDelay,
    },
    armed = {
        type = "clip",
        frames = { FRAME_READY },
        duration = Trap.duration,
    },
    despawning = {
        type = "timeline",
        tracks = {
            { type = "clip", at = 0, frames = SNAP_FRAMES, duration = Trap.snapDuration },
            { type = "tween", at = Trap.snapDuration, property = "alpha", from = 1, to = 0, duration = Trap.fadeDuration, easing = "linear" },
            { type = "event", at = Trap.snapDuration, name = "snap" },
        },
    },
})

-- Dust burst tuning for the snap cosmetic (client-local; lives beside the
-- spec so it can be tuned without touching engine or particle code). Count,
-- speed, color, and lifetime are all declared here.
Trap.dust = {
    count = 14,          -- brown flecks kicked up when the trap snaps shut
    speed = 110,         -- base outward speed along the ground (px/s)
    speedVariance = 70,  -- +/- per-particle speed
    lifetime = 0.55,     -- seconds the dust lingers before fading out
    lifetimeVariance = 0.2,
    color = { 0.45, 0.32, 0.18 }, -- earthy brown
    size = 2,
    drag = 6,            -- exponential slow-down so the burst hugs the ground
}

local flytrapAtlas -- created on first draw; never touched by the headless server

function Trap.new(owner, x, y, remaining)
    local self = setmetatable({}, Trap)
    self.owner = owner
    self.x = x or 0
    self.y = y or 0
    self.remaining = remaining or Trap.duration
    self.phase = "arming"        -- "arming" -> "armed" -> "despawning" -> removed
    self.armed = false           -- true only while triggerable (phase == "armed")
    self.armRemaining = Trap.armDelay
    self.despawnRemaining = 0
    self.castRootRemaining = Trap.castRoot
    self.rotation = 0              -- aim angle set on trigger (bottom -> victim)
    self.active = true
    return self
end

-- Instant placement; the arming delay and caster root begin immediately.
function Trap:cast(caster, x, y)
end

-- Phase transitions. `armed` is kept in sync here so the engine's trigger pass
-- (ability.armed) and snapshots (entry.armed) stay consistent with the phase.
function Trap:enterArmed()
    self.phase = "armed"
    self.armed = true
end

function Trap:enterDespawn()
    self.phase = "despawning"
    self.armed = false
    self.despawnRemaining = Trap.despawnDuration
end

-- Trigger hook invoked by the simulation the instant a non-stunned player
-- first overlaps the armed trap. The stun is applied by the simulation at the
-- same moment; this hook starts the despawn phase (snap shut + fade) and aims
-- the trap's bottom at the victim. victimX/victimY come from the simulation,
-- so the rotation is deterministic and snapshot-carried. Natural expiry passes
-- no victim and leaves the default rotation.
-- Returns true when the trap entered the despawn phase.
function Trap:onTrigger(victimX, victimY)
    if self.phase ~= "armed" then
        return false
    end
    if victimX and victimY then
        local aim = math.atan2(victimY - self.y, victimX - self.x)
        -- Angular distance from the nearest vertical (directly above or below).
        -- Victims inside the deadzone keep rotation 0; sideways victims rotate
        -- so the pod's bottom points at them.
        local delta = (aim - POD_BOTTOM_ANGLE + math.pi) % (2 * math.pi) - math.pi
        if math.min(math.abs(delta), math.pi - math.abs(delta)) > VERTICAL_DEADZONE then
            self.rotation = delta
        end
    end
    self:enterDespawn()
    return true
end

-- Advance the caster root, the arming timer, the armed lifetime, and the
-- despawn linger. No damage; the trigger is handled by the simulation using
-- the "overlap" trigger contract.
--
-- The lifetime timer (remaining) starts at placement and runs through the
-- arming and armed phases (as before the despawn retrofit), so natural expiry
-- still begins at 30s -- it just enters the 0.45s despawn linger instead of
-- vanishing instantly. The despawn branch drives the linger to zero, at which
-- point the engine's removal sweep drops the trap.
function Trap:update(dt)
    if self.castRootRemaining > 0 then
        self.castRootRemaining = math.max(0, self.castRootRemaining - dt)
    end

    if self.phase == "arming" then
        self.armRemaining = self.armRemaining - dt
        self.remaining = self.remaining - dt
        if self.remaining <= 0 then
            self.remaining = 0
        end
        if self.armRemaining <= 0 then
            self.armRemaining = 0
            self:enterArmed()
        end
    elseif self.phase == "armed" then
        self.remaining = self.remaining - dt
        if self.remaining <= 0 then
            self.remaining = 0
            self:enterDespawn()
        end
    elseif self.phase == "despawning" then
        self.despawnRemaining = self.despawnRemaining - dt
        if self.despawnRemaining <= 0 then
            self.despawnRemaining = 0
            self.active = false
        end
    end
    return {}
end

-- Rooting: the caster cannot move for the first 0.5s after placing the trap.
function Trap:isRooting()
    return self.castRootRemaining > 0
end

-- Type-specific snapshot fields: phase, the armed flag (true only while
-- triggerable), and the timers that drive the animation (arming timer, caster
-- root, despawn linger). The lifetime timer travels via the shared `remaining`
-- field in the abilities list.
function Trap:getSnapshot()
    return {
        radius = Trap.radius,
        armed = self.armed,
        phase = self.phase,
        armRemaining = self.armRemaining,
        castRootRemaining = self.castRootRemaining,
        despawnRemaining = self.despawnRemaining,
        rotation = self.rotation,
    }
end

function Trap:applySnapshot(entry)
    self.phase = entry.phase or (entry.armed and "armed" or "arming")
    self.armed = (self.phase == "armed")
    self.armRemaining = entry.armRemaining or 0
    self.castRootRemaining = entry.castRootRemaining or 0
    if self.phase == "despawning" then
        self.despawnRemaining = entry.despawnRemaining or Trap.despawnDuration
    else
        self.despawnRemaining = 0
    end
    self.rotation = entry.rotation or 0
end

-- Seconds into the current phase, derived from the ability's own simulation
-- timers. This is the hook the animation engine (and the client renderer's
-- event tracking) uses: given the phase and this elapsed, the pure evaluator
-- yields the pose. `armed` needs no timer: its spec holds frame 6 regardless.
function Trap:getAnimationElapsed()
    if self.phase == "arming" then
        return Trap.armDelay - self.armRemaining
    elseif self.phase == "despawning" then
        return Trap.despawnDuration - self.despawnRemaining
    end
    return 0
end

-- Frame index for the current phase: a thin wrapper over the pure animation
-- engine (Trap.animation), still a pure function of simulation timers so
-- predicted and authoritative instances render identically. The spec's clip
-- stepping is the pre-migration hand-rolled math, so the output is
-- byte-identical: 0 -> 6 while arming (closed pod -> open), 6 while armed
-- (ready), then the closing sequence 6 -> 7..12 -> 0 while despawning (snap
-- shut), holding 0 through the fade.
function Trap:getFrame()
    return Anim.evaluate(Trap.animation, self.phase, self:getAnimationElapsed()).frame
end

-- Draw alpha: also a thin wrapper over the engine. 1 while arming/armed and
-- during the snap, then a linear dissolve to 0 over the fade sub-phase of the
-- despawn (the despawning timeline's alpha tween). Pure function of sim
-- timers.
function Trap:getAlpha()
    return Anim.evaluate(Trap.animation, self.phase, self:getAnimationElapsed()).alpha
end

-- Rendering: the flytrap sprite at 40x40 px (scale 0.125 from the 320px
-- tiles), centered on the trap, rotated by the aim angle set on trigger (0
-- otherwise). Alpha is applied via the draw color. The atlas is created on
-- first draw only; the headless server never reaches this code. The old
-- pulsing-circle placeholder (and its wall-clock pulse) is removed entirely.
function Trap:draw(colors)
    if not flytrapAtlas then
        flytrapAtlas = Sprites.new(FLYTRAP_PATH, FLYTRAP_TILE)
    end

    local frame = self:getFrame()
    local col = frame % FLYTRAP_FRAMES_PER_ROW
    local row = math.floor(frame / FLYTRAP_FRAMES_PER_ROW)
    local quad = Sprites.quad(flytrapAtlas, col, row)

    love.graphics.setColor(1, 1, 1, self:getAlpha())
    -- Center pivot so the aim rotation turns the mouth toward the victim
    -- without shifting the trap. ox/oy are in (unscaled) image pixels: half a
    -- tile lands the quad's center exactly on (self.x, self.y).
    love.graphics.draw(
        flytrapAtlas.image,
        quad,
        self.x, self.y,
        self.rotation,
        FLYTRAP_SCALE, FLYTRAP_SCALE,
        FLYTRAP_TILE / 2, FLYTRAP_TILE / 2
    )
end

return Trap
