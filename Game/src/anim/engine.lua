-- src/anim/engine.lua
--
-- Pure, deterministic animation engine. Given an animation spec (declared as
-- inline Lua data beside an ability's tuning), a phase name, and an elapsed
-- time derived from the simulation's phase timers, it returns a pose (frame,
-- rotation, scale, alpha) plus any cosmetic events crossed since the previous
-- evaluation. It never calls LÖVE graphics, never reads the wall clock, and
-- never touches random numbers, so predicted and authoritative clients
-- evaluate it to bit-identical output. The headless server can load ability
-- modules that require this module but never evaluates it.
--
-- Primitives
--   clip      a frame sequence over a total duration (stepped playback, so a
--             frame index comes from round(1 + t/duration*(n-1)) exactly as
--             League-style hand-rolled sprite math does), or explicit
--             per-frame timings; optional loop / ping-pong playback.
--   tween     a numeric animation of one pose property (frame, rotation,
--             scale, alpha) from a start to an end value over a duration with
--             an easing curve. Past the end it holds the end value.
--   timeline  an ordered set of tracks -- each a clip, tween, or event with a
--             start offset. Tracks at the same offset run in parallel; the
--             last track to write a pose property wins. Events are cosmetic
--             only: the evaluator returns the events whose timestamps fall in
--             the (prevElapsed, elapsed] window and the caller decides what
--             they spawn.
--
-- Spec shape (plain data; Anim.load normalizes it):
--   spec = {
--     phaseName = {
--       type = "clip",
--       frames = { 0, 1, 2 },        -- sprite-sheet frame indices
--       duration = 0.5,              -- total seconds (equal steps)
--       -- or: timings = { 0.1, 0.2, 0.2 },  -- per-frame durations
--       loop = false,                -- repeat from the start
--       pingpong = false,            -- bounce back and forth
--     },
--     phaseName2 = {
--       type = "tween",
--       property = "alpha",          -- "frame" | "rotation" | "scale" | "alpha"
--       from = 1,
--       to = 0,
--       duration = 0.3,
--       easing = "linear",
--     },
--     phaseName3 = {
--       type = "timeline",
--       tracks = {
--         { type = "clip",  at = 0,   frames = { 0, 1 }, duration = 0.2 },
--         { type = "tween", at = 0.2, property = "alpha", from = 1, to = 0,
--           duration = 0.3, easing = "linear" },
--         { type = "event", at = 0.2, name = "snap" },
--       },
--     },
--   }
--
-- Easing set (v1): linear, quadIn, quadOut, quadInOut, cubicIn, cubicOut,
-- cubicInOut, sineIn, sineOut, sineInOut, expoIn, expoOut, expoInOut.
-- (Elastic and back curves are deferred until a concrete need arises.)
--
-- Contract for abilities that opt into a spec:
--   * declare `animation = Anim.load({ ... })` on the module, and
--   * implement `instance:getAnimationElapsed()` returning seconds into the
--     current phase, derived from the ability's own simulation timers.
-- The client renderer calls Anim.evaluate per ability to obtain the pose for
-- drawing and the crossed events for cosmetics; an ability's own accessors
-- (e.g. getFrame / getAlpha) may be thin wrappers over the same call.

local Anim = {}

local function clamp01(value)
    return math.max(0, math.min(1, value))
end

local function clamp(value, lo, hi)
    return math.max(lo, math.min(hi, value))
end

local function round(value)
    return math.floor(value + 0.5)
end

----------------------------------------
-- Easing curves (documented set for v1)
----------------------------------------
local EASINGS = {
    linear = function(t) return t end,
    quadIn = function(t) return t * t end,
    quadOut = function(t) return t * (2 - t) end,
    quadInOut = function(t)
        if t < 0.5 then
            return 2 * t * t
        end
        return -1 + (4 - 2 * t) * t
    end,
    cubicIn = function(t) return t * t * t end,
    cubicOut = function(t) return 1 - (1 - t) ^ 3 end,
    cubicInOut = function(t)
        if t < 0.5 then
            return 4 * t * t * t
        end
        return 1 - (-2 * t + 2) ^ 3 / 2
    end,
    sineIn = function(t) return 1 - math.cos(t * math.pi / 2) end,
    sineOut = function(t) return math.sin(t * math.pi / 2) end,
    sineInOut = function(t) return -(math.cos(math.pi * t) - 1) / 2 end,
    expoIn = function(t)
        if t <= 0 then
            return 0
        end
        return 2 ^ (10 * t - 10)
    end,
    expoOut = function(t)
        if t >= 1 then
            return 1
        end
        return 1 - 2 ^ (-10 * t)
    end,
    expoInOut = function(t)
        if t <= 0 then
            return 0
        end
        if t >= 1 then
            return 1
        end
        if t < 0.5 then
            return 2 ^ (20 * t - 10) / 2
        end
        return (2 - 2 ^ (-20 * t + 10)) / 2
    end,
}

-- Return the eased value of `name` at normalized progress t (clamped to
-- [0, 1]). Unknown names fall back to linear so bad data cannot crash
-- rendering; it is a documented error to rely on that for authoring.
function Anim.ease(name, t)
    local fn = EASINGS[name] or EASINGS.linear
    return fn(clamp01(t))
end

----------------------------------------
-- Clip evaluation
----------------------------------------
local function clipIndex(entry, t)
    local n = #entry.frames
    if n <= 1 then
        return 1
    end
    if entry.timings then
        -- Per-frame durations: the frame whose [start, end) window holds t.
        -- A boundary time steps to the next frame (t == end of frame k starts
        -- frame k+1), matching the round()-based stepping below.
        local elapsed = 0
        for i = 1, n - 1 do
            elapsed = elapsed + entry.timings[i]
            if t < elapsed then
                return i
            end
        end
        return n
    end
    -- Even stepping: index = round(1 + t/duration*(n-1)), clamped. This is
    -- exactly the classic hand-rolled sprite math (frame changes at the
    -- half-step boundaries), so migrated abilities keep byte-identical output.
    local progress = clamp01(t / entry.duration)
    return clamp(round(1 + progress * (n - 1)), 1, n)
end

-- Frame at time t for a normalized clip entry. Past the end (without loop or
-- ping-pong) the clip holds its last frame.
local function clipFrame(entry, t)
    if entry.pingpong then
        local period = entry.duration * 2
        local x = t % period
        if x > entry.duration then
            x = period - x
        end
        t = x
    elseif entry.loop then
        t = t % entry.duration
    end
    return entry.frames[clipIndex(entry, t)]
end

----------------------------------------
-- Tween evaluation
----------------------------------------
local function tweenValue(entry, t)
    local p = clamp01(t / entry.duration)
    local e = Anim.ease(entry.easing or "linear", p)
    return entry.from + (entry.to - entry.from) * e
end

----------------------------------------
-- Timeline evaluation
----------------------------------------
local function defaultPose()
    return { frame = nil, rotation = 0, scale = 1, alpha = 1 }
end

-- Apply every track whose start offset has been reached. Tracks run in order
-- (stable as declared); the last track to write a pose property wins, so
-- clips at later offsets replace earlier frames and tweens at the same offset
-- compose different properties in parallel.
local function evaluateTimeline(entry, elapsed, prevElapsed)
    local pose = defaultPose()
    local events = {}
    for _, track in ipairs(entry.tracks) do
        if elapsed >= track.at then
            if track.type == "clip" then
                pose.frame = clipFrame(track, elapsed - track.at)
            elseif track.type == "tween" then
                pose[track.property] = tweenValue(track, elapsed - track.at)
            elseif track.type == "event" then
                if (prevElapsed == nil or track.at > prevElapsed) and track.at <= elapsed then
                    table.insert(events, { name = track.name, at = track.at })
                end
            end
        end
    end
    return pose, events
end

local function finalize(pose)
    -- The pose contract: frame is always a whole sprite index. Tweening a
    -- frame property animates the rounded index (round = floor(x + 0.5), the
    -- codebase's existing convention). Clip frames are integers already.
    if pose.frame ~= nil then
        pose.frame = round(pose.frame)
    end
    return pose
end

----------------------------------------
-- Public evaluator
----------------------------------------
-- Evaluate one phase of a spec at `elapsed` seconds into that phase.
-- prevElapsed, when given, opens the event window (prevElapsed, elapsed];
-- when nil, every event at or before `elapsed` is reported (the client's
-- first evaluation of a phase -- cosmetic events are self-healing).
-- Returns pose, events.
function Anim.evaluate(spec, phase, elapsed, prevElapsed)
    local entry = spec and spec[phase]
    if not entry then
        return defaultPose(), {}
    end
    if entry.type == "clip" then
        local pose = defaultPose()
        pose.frame = clipFrame(entry, elapsed)
        return finalize(pose), {}
    elseif entry.type == "tween" then
        local pose = defaultPose()
        pose[entry.property] = tweenValue(entry, elapsed)
        return finalize(pose), {}
    end
    local pose, events = evaluateTimeline(entry, elapsed, prevElapsed)
    return finalize(pose), events
end

----------------------------------------
-- Loader abstraction
----------------------------------------
-- Normalize (and validate) an animation spec written as inline Lua data.
-- Abilities call Anim.load once at module load time; swapping in a JSON or
-- other data format later requires changing only this function, never the
-- abilities or the evaluator. Entries are copied so later mutation by one
-- caller cannot corrupt another's spec.
local function normalizeClip(entry)
    if entry.timings then
        local total = 0
        for _, duration in ipairs(entry.timings) do
            total = total + duration
        end
        entry.duration = total
    end
    assert(type(entry.frames) == "table" and #entry.frames > 0, "clip needs a non-empty frames array")
    assert(entry.duration and entry.duration > 0, "clip needs a duration or per-frame timings")
end

local function normalizeTween(entry)
    entry.easing = entry.easing or "linear"
    assert(entry.property, "tween needs a property (frame/rotation/scale/alpha)")
    assert(entry.from ~= nil and entry.to ~= nil, "tween needs from and to values")
    assert(entry.duration and entry.duration > 0, "tween needs a duration")
end

local function normalizeTrack(track)
    local copy = {}
    for key, value in pairs(track) do
        copy[key] = value
    end
    if copy.type == "clip" then
        normalizeClip(copy)
    elseif copy.type == "tween" then
        normalizeTween(copy)
    elseif copy.type == "event" then
        assert(copy.name, "event track needs a name")
    else
        error("unknown timeline track type: " .. tostring(copy.type))
    end
    return copy
end

function Anim.load(spec)
    assert(type(spec) == "table", "animation spec must be a table")
    local out = {}
    for phase, entry in pairs(spec) do
        assert(type(entry) == "table", "animation entry for phase '" .. tostring(phase) .. "' must be a table")
        local copy = {}
        for key, value in pairs(entry) do
            copy[key] = value
        end
        if copy.type == "clip" then
            normalizeClip(copy)
        elseif copy.type == "tween" then
            normalizeTween(copy)
        elseif copy.type == "timeline" then
            local tracks = {}
            for _, track in ipairs(copy.tracks) do
                table.insert(tracks, normalizeTrack(track))
            end
            copy.tracks = tracks
        else
            error("unknown animation entry type: " .. tostring(copy.type))
        end
        out[phase] = copy
    end
    return out
end

return Anim
