-- src/particles.lua
--
-- Client-local particle emitter for cosmetic effects (e.g. Bear Trap's brown
-- dust burst when it snaps shut). Deliberately minimal: no textures, no blend
-- modes, no spawn-rate emitters -- just short-lived colored points that fly
-- outward and fade out. Player character and ability rendering stay untouched;
-- this only powers client-only flourishes.
--
-- Seams
--   Particles.new()        -> an empty emitter (a plain list of particles)
--   Particles.spawn(list, config) -- adds a burst of particles. The only
--                            randomness in the emitter lives here; spawns are
--                            driven by deterministic simulation state (the
--                            evaluator's crossed events), so the game logic
--                            never depends on the random directions/speeds.
--   Particles.advance(list, dt) -- pure, deterministic advance step: damps
--                            velocity, integrates position, ticks lifetimes,
--                            and drops dead particles. No graphics, no
--                            wall-clock reads, no randomness -- this is the
--                            seam the headless tests exercise.
--   Particles.draw(list)    -- the only step that touches graphics.
--
-- Particle motion runs on the client's frame dt (wall-clock driven), never on
-- simulation ticks, matching the existing click-effect and stun-ring pattern:
-- the visuals stay fluid without becoming part of the deterministic sim.

local Particles = {}

local function clamp01(value)
    return math.max(0, math.min(1, value))
end

-- Create an emitter: an empty list of particles.
function Particles.new()
    return {}
end

-- Spawn a burst at (x, y). Particles fly outward around `angle` within
-- `spread` (radians). Config fields and defaults:
--   x, y            burst center (default 0, 0)
--   count           number of particles (default 1)
--   speed           base speed in px/s (default 0)
--   speedVariance   +/- random speed added (default 0)
--   angle           base direction in radians (default 0)
--   spread          +/- random direction (default 0; 2*pi = full circle)
--   lifetime        base lifetime in seconds (default 0.5)
--   lifetimeVariance +/- random lifetime added (default 0)
--   color           { r, g, b } in 0..1 (default white)
--   size            point size in px (default 2)
--   drag            exponential velocity decay per second (default 0)
function Particles.spawn(list, config)
    local count = config.count or 1
    for _ = 1, count do
        local angle = (config.angle or 0) + (love.math.random() * 2 - 1) * (config.spread or 0)
        local speed = (config.speed or 0) + (love.math.random() * 2 - 1) * (config.speedVariance or 0)
        local lifetime = (config.lifetime or 0.5) + (love.math.random() * 2 - 1) * (config.lifetimeVariance or 0)
        lifetime = math.max(0.05, lifetime)
        table.insert(list, {
            x = config.x or 0,
            y = config.y or 0,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed,
            life = lifetime,
            maxLife = lifetime,
            color = config.color or { 1, 1, 1 },
            size = config.size or 2,
            drag = config.drag or 0,
        })
    end
end

-- Advance every particle by dt: apply exponential drag to velocity, integrate
-- position, decrement life, and remove dead particles. Deterministic given
-- the list and dt (spawn is the only random source and runs elsewhere), so
-- headless tests can drive and assert it without a window.
function Particles.advance(list, dt)
    for i = #list, 1, -1 do
        local p = list[i]
        p.life = p.life - dt
        if p.life <= 0 then
            table.remove(list, i)
        else
            if p.drag and p.drag > 0 then
                local damp = math.max(0, 1 - p.drag * dt)
                p.vx = p.vx * damp
                p.vy = p.vy * damp
            end
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
        end
    end
end

-- Alpha at a particle's current life: 1 at spawn, linear fade to 0. The fade
-- is derived from life/maxLife, so it is also deterministic per advance step.
local function particleAlpha(p)
    return clamp01(p.life / p.maxLife)
end

-- Draw all particles as colored points. The only step that touches graphics.
function Particles.draw(list)
    for _, p in ipairs(list) do
        love.graphics.setColor(p.color[1], p.color[2], p.color[3], particleAlpha(p))
        love.graphics.setPointSize(p.size)
        love.graphics.points(p.x, p.y)
    end
    if #list > 0 then
        love.graphics.setPointSize(1)
    end
end

return Particles
