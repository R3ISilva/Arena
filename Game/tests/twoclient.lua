-- Headless two-client diagnostic. Connects two real ENet clients to the configured
-- server, has both players click-to-move repeatedly, and reports each client's RTT,
-- predicted-vs-authoritative divergence, and reconciliation snap count. A healthy
-- run shows both players moving with zero snaps (no rubber-banding).
-- Run via: lovec.exe . --twoclient   (exit code 0 = healthy, 1 = snapping detected)

local json = require("json")
local World = require("src.world")
local Session = require("src.session")
local net = require("src.net")

local function makeClient(config)
    local session = Session.new(World.new(config), "client", config.server)
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

local function run()
    local text = love.filesystem.read("config.json")
    local config = json.decode(text)

    local session1, adapter1 = makeClient(config)
    local session2, adapter2 = makeClient(config)
    local stats1 = instrument(session1)
    local stats2 = instrument(session2)

    local fixedDt = 1 / config.server.tickRate
    local accumulator = 0
    local lastTime = love.timer.getTime()
    local deadline = lastTime + 15
    local nextClickAt = lastTime + 0.5
    local clickIndex = 1
    local targets = {
        { x = 60, y = 60 },
        { x = 740, y = 540 },
        { x = 740, y = 60 },
        { x = 60, y = 540 },
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

        adapter1:flushOutbox()
        adapter2:flushOutbox()
        love.timer.sleep(0.001)
    end

    local function report(name, session, stats)
        print(string.format("%s: slot=%s rtt=%.0fms divergence=%.1fpx snaps=%d snapshots=%d",
            name, tostring(session:getSlot()), (session.latency or 0) * 1000,
            stats.maxDivergence, stats.snaps, stats.samples))
    end
    report("client1", session1, stats1)
    report("client2", session2, stats2)

    adapter1:destroy()
    adapter2:destroy()

    local healthy = stats1.samples > 0 and stats2.samples > 0
        and stats1.snaps == 0 and stats2.snaps == 0
    if healthy then
        print("TWO-CLIENT DIAGNOSTIC PASSED (no rubber-banding)")
        return true
    end
    print("TWO-CLIENT DIAGNOSTIC FAILED (snapping detected or no snapshots received)")
    return false
end

return run
