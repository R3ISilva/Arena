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
-- grid of 320px tiles; frames 0-13 are the animation, 14-19 are empty). The
-- atlas is created lazily inside draw() only: this module is also loaded by the
-- headless server, where the graphics module is disabled.
--
-- Static tuning lives here so engine code never needs to change to rebalance.

local Sprites = require("src.sprites")

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
-- grid of 320px tiles): 13 = closed (arming start), 12..8 = opening, 7 = open
-- (last arming frame), 6 = fully open (armed/ready), 5..1 = closing,
-- 0 = fully closed (snap end). Frames 14-19 are empty and never drawn.
local FLYTRAP_PATH = "sprites/flytrap_tilemap.png"
local FLYTRAP_TILE = 320           -- sheet is a 5x4 grid of 320px tiles
local FLYTRAP_FRAMES_PER_ROW = 5
local FLYTRAP_DRAW_SIZE = 40       -- in-world size, matching the old placeholder circle
local FLYTRAP_SCALE = FLYTRAP_DRAW_SIZE / FLYTRAP_TILE
local FRAME_ARM_START = 13         -- fully closed
local FRAME_ARM_END = 7            -- open (last arming frame)
local FRAME_READY = 6              -- fully open (armed)
local FRAME_CLOSED = 0             -- fully closed (snap end)

local flytrapAtlas -- created on first draw; never touched by the headless server

local function round(value)
    return math.floor(value + 0.5)
end

local function clamp01(value)
    return math.max(0, math.min(1, value))
end

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
-- same moment; this hook only starts the despawn phase (snap shut + fade).
-- Returns true when the trap entered the despawn phase.
function Trap:onTrigger()
    if self.phase ~= "armed" then
        return false
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
end

-- Frame index for the current phase: a pure function of simulation timers, so
-- predicted and authoritative instances render identically. 13 -> 7 while
-- arming (closed -> open), 6 while armed (ready), 6 -> 0 while despawning
-- (snap shut), holding 0 through the fade.
function Trap:getFrame()
    if self.phase == "arming" then
        local progress = clamp01(1 - self.armRemaining / Trap.armDelay)
        return round(FRAME_ARM_START + (FRAME_ARM_END - FRAME_ARM_START) * progress)
    elseif self.phase == "armed" then
        return FRAME_READY
    end
    -- despawning
    local elapsed = Trap.despawnDuration - self.despawnRemaining
    if elapsed < Trap.snapDuration then
        local progress = clamp01(elapsed / Trap.snapDuration)
        return round(FRAME_READY + (FRAME_CLOSED - FRAME_READY) * progress)
    end
    return FRAME_CLOSED
end

-- Draw alpha: 1 while arming/armed and during the snap, then a linear dissolve
-- to 0 over the fade sub-phase of the despawn. Also a pure function of sim
-- timers.
function Trap:getAlpha()
    if self.phase ~= "despawning" then
        return 1
    end
    local elapsed = Trap.despawnDuration - self.despawnRemaining
    if elapsed < Trap.snapDuration then
        return 1
    end
    return clamp01(1 - (elapsed - Trap.snapDuration) / Trap.fadeDuration)
end

-- Rendering: the flytrap sprite at 40x40 px (scale 0.125 from the 320px
-- tiles), centered on the trap, no rotation (the trap is symmetric / top-down).
-- Alpha is applied via the draw color. The atlas is created on first draw only;
-- the headless server never reaches this code. The old pulsing-circle
-- placeholder (and its wall-clock pulse) is removed entirely.
function Trap:draw(colors)
    if not flytrapAtlas then
        flytrapAtlas = Sprites.new(FLYTRAP_PATH, FLYTRAP_TILE)
    end

    local frame = self:getFrame()
    local col = frame % FLYTRAP_FRAMES_PER_ROW
    local row = math.floor(frame / FLYTRAP_FRAMES_PER_ROW)
    local quad = Sprites.quad(flytrapAtlas, col, row)

    love.graphics.setColor(1, 1, 1, self:getAlpha())
    love.graphics.draw(
        flytrapAtlas.image,
        quad,
        self.x - FLYTRAP_DRAW_SIZE / 2,
        self.y - FLYTRAP_DRAW_SIZE / 2,
        0,
        FLYTRAP_SCALE,
        FLYTRAP_SCALE
    )
end

return Trap
