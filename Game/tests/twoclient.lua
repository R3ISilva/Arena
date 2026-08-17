-- Headless two-client diagnostic. Connects two real ENet clients to the configured
-- server, has both players click-to-move repeatedly AND cast Morgana's Pool, and
-- reports each client's RTT, predicted-vs-authoritative divergence, reconciliation
-- snap count, and ability health/pool telemetry. A healthy run shows both players
-- moving with zero snaps (no rubber-banding), both casting, both seeing pools in
-- snapshots, and both taking self-damage from their own pools.
-- Run via: lovec.exe . --twoclient   (exit code 0 = healthy, 1 = unhealthy)

local json = require("json")
local Game = require("src.game")
local Session = require("src.session")
local net = require("src.net")

local function makeClient(config)
    local session = Session.new(Game.new(config), "client", config.server)
    local adapter = net.newClient(config, session)
    return session, adapter
end

-- Wrap reconcile to observe the divergence it sees and count position-changing snaps.
local function instrument(session)
    local stats = { snaps = 0, samples = 0, maxDivergence = 0 }
    local origReconcile = session.reconcile
    session.reconcile = function(self, authX, authY)
        local lp = self.localPlayer
        if lp then
            local dx = lp.x - authX
            local dy = lp.y - authY
            local divergence = math.sqrt(dx * dx + dy * dy)
            stats.samples = stats.samples + 1
            stats.maxDivergence = math.max(stats.maxDivergence, divergence)
            local beforeX, beforeY = lp.x, lp.y
            origReconcile(self, authX, authY)
            if lp.x ~= beforeX or lp.y ~= beforeY then
                stats.snaps = stats.snaps + 1
            end
        else
            origReconcile(self, authX, authY)
        end
    end
    return stats
end

local function observe(session, stats)
    local state = session:getState()
    if state.health and state.health < 100 then
        stats.tookDamage = true
    end
    if state.pools and #state.pools > 0 then
        stats.sawPool = true
    end
end

local function run()
    local text = love.filesystem.read("config.json")
    local config = json.decode(text)

    local session1, adapter1 = makeClient(config)
    local session2, adapter2 = makeClient(config)
    local stats1 = instrument(session1)
    local stats2 = instrument(session2)

    local castStats1 = { sent = 0, sawPool = false, tookDamage = false }
    local castStats2 = { sent = 0, sawPool = false, tookDamage = false }

    local fixedDt = 1 / config.server.tickRate
    local accumulator = 0
    local lastTime = love.timer.getTime()
    local deadline = lastTime + 15
    local nextClickAt = lastTime + 0.5
    local nextCastAt = lastTime + 1.0
    local clickIndex = 1
    local castIndex = 1
    local targets = {
        { x = 60, y = 60 },
        { x = 740, y = 540 },
        { x = 740, y = 60 },
        { x = 60, y = 540 },
    }
    -- Alternate between a self-cast (damages the caster) and a far cast
    -- (exercises the authoritative range clamp).
    local castTargets = {
        { kind = "self" },
        { kind = "far", dx = 500, dy = 500 },
    }

    while love.timer.getTime() < deadline do
        adapter1:pump()
        adapter2:pump()

        local now = love.timer.getTime()
        local frameDt = now - lastTime
        lastTime = now
        if frameDt > 0.25 then
            frameDt = 0.25 -- clamp so a stall doesn't spiral the accumulator
        end

        accumulator = accumulator + frameDt
        while accumulator >= fixedDt do
            session1:tick(fixedDt)
            session2:tick(fixedDt)
            accumulator = accumulator - fixedDt
        end

        if now >= nextClickAt then
            if session1:isPlayer() then
                session1:localMoveIntent(targets[clickIndex].x, targets[clickIndex].y)
            end
            if session2:isPlayer() then
                local other = ((clickIndex + 1) % #targets) + 1
                session2:localMoveIntent(targets[other].x, targets[other].y)
            end
            clickIndex = (clickIndex % #targets) + 1
            nextClickAt = now + 3
        end

        if now >= nextCastAt then
            local target = castTargets[castIndex]
            if session1:isPlayer() and session1.localPlayer then
                local lp = session1.localPlayer
                local cx = (target.kind == "far") and (lp.x + target.dx) or lp.x
                local cy = (target.kind == "far") and (lp.y + target.dy) or lp.y
                if session1:localCastIntent("w", cx, cy) then
                    castStats1.sent = castStats1.sent + 1
                end
            end
            if session2:isPlayer() and session2.localPlayer then
                local lp = session2.localPlayer
                local cx = (target.kind == "far") and (lp.x + target.dx) or lp.x
                local cy = (target.kind == "far") and (lp.y + target.dy) or lp.y
                if session2:localCastIntent("w", cx, cy) then
                    castStats2.sent = castStats2.sent + 1
                end
            end
            castIndex = (castIndex % #castTargets) + 1
            nextCastAt = now + 2.0
        end

        observe(session1, castStats1)
        observe(session2, castStats2)

        adapter1:flushOutbox()
        adapter2:flushOutbox()
        love.timer.sleep(0.001)
    end

    local function report(name, session, stats, cast)
        print(string.format(
            "%s: slot=%s rtt=%.0fms divergence=%.1fpx snaps=%d snapshots=%d casts=%d sawPool=%s tookDamage=%s hp=%.0f",
            name, tostring(session:getSlot()), (session.latency or 0) * 1000,
            stats.maxDivergence, stats.snaps, stats.samples, cast.sent,
            tostring(cast.sawPool), tostring(cast.tookDamage),
            (session:getState().health or 100)))
    end
    report("client1", session1, stats1, castStats1)
    report("client2", session2, stats2, castStats2)

    adapter1:destroy()
    adapter2:destroy()

    local healthy = stats1.samples > 0 and stats2.samples > 0
        and stats1.snaps == 0 and stats2.snaps == 0
        and castStats1.sent > 0 and castStats2.sent > 0
        and castStats1.sawPool and castStats2.sawPool
        and castStats1.tookDamage and castStats2.tookDamage

    if healthy then
        print("TWO-CLIENT DIAGNOSTIC PASSED (no rubber-banding, both cast and took damage)")
        return true
    end
    print("TWO-CLIENT DIAGNOSTIC FAILED (snapping, missing casts/pools, or no damage observed)")
    return false
end

return run
