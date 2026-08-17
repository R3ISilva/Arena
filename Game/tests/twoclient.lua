-- Headless two-client diagnostic. Connects two real ENet clients to the configured
-- server, has both players click-to-move repeatedly AND cast all three loadout
-- abilities (Morgana's Pool on W, Beam on Q, Bear Trap on E), and reports each
-- client's RTT, predicted-vs-authoritative divergence, reconciliation snap count,
-- and ability telemetry (casts sent, abilities seen, damage taken, stuns seen).
-- A healthy run shows both players moving with zero snaps (no rubber-banding),
-- both casting every slot, seeing pools/beams/traps, taking damage, and observing
-- a stun (each client self-triggers its own trap while standing still).
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
    for _, ability in ipairs(state.abilities or {}) do
        if ability.ability == "morganapool" then stats.sawPool = true end
        if ability.ability == "beam" then stats.sawBeam = true end
        if ability.ability == "beartrap" then stats.sawTrap = true end
    end
    for _, player in pairs(state.players or {}) do
        if player.stunned then stats.sawStun = true end
    end
end

local function newCastStats()
    return {
        sentW = 0, sentQ = 0, sentE = 0,
        sawPool = false, sawBeam = false, sawTrap = false, sawStun = false,
        tookDamage = false,
    }
end

local function run()
    local text = love.filesystem.read("config.json")
    local config = json.decode(text)

    local session1, adapter1 = makeClient(config)
    local session2, adapter2 = makeClient(config)
    local stats1 = instrument(session1)
    local stats2 = instrument(session2)

    local castStats1 = newCastStats()
    local castStats2 = newCastStats()

    local fixedDt = 1 / config.server.tickRate
    local accumulator = 0
    local lastTime = love.timer.getTime()
    local deadline = lastTime + 15
    local nextClickAt = lastTime + 0.5
    local nextCastAt = lastTime + 1.0
    local stayUntil = 0
    local clickIndex = 1
    local castIndex = 1
    local targets = {
        { x = 60, y = 60 },
        { x = 740, y = 540 },
        { x = 740, y = 60 },
        { x = 60, y = 540 },
    }
    -- Rotate through the three abilities. Pool self-casts damage the caster and
    -- far casts exercise the range clamp; the beam aims at the opponent; the trap
    -- drops at the caster's feet and the caster holds still so it arms + triggers.
    local castPlan = {
        { slot = "w", self = true },
        { slot = "q" },
        { slot = "e" },
        { slot = "w", self = false },
    }

    local function tryCast(session, stats, plan, otherSlot, now)
        if not (session:isPlayer() and session.localPlayer) then
            return
        end
        local lp = session.localPlayer
        local state = session:getState()
        local opponent = state.players[otherSlot]

        local cx, cy
        if plan.slot == "q" then
            -- Beam: aim in the opponent's direction (direction-based, Lux R feel).
            cx = opponent and opponent.x or (lp.x + 300)
            cy = opponent and opponent.y or lp.y
        elseif plan.slot == "e" then
            -- Trap: drop at the caster's feet and stop so it arms + triggers.
            cx, cy = lp.x, lp.y
            session:localMoveIntent(lp.x, lp.y)
            stayUntil = now + 1.5
        elseif plan.self then
            cx, cy = lp.x, lp.y
        else
            cx, cy = lp.x + 500, lp.y + 500
        end

        if session:localCastIntent(plan.slot, cx, cy) then
            if plan.slot == "w" then
                stats.sentW = stats.sentW + 1
            elseif plan.slot == "q" then
                stats.sentQ = stats.sentQ + 1
            elseif plan.slot == "e" then
                stats.sentE = stats.sentE + 1
            end
        end
    end

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
            local staying = now < stayUntil
            if session1:isPlayer() and session1.localPlayer then
                if staying then
                    session1:localMoveIntent(session1.localPlayer.x, session1.localPlayer.y)
                else
                    session1:localMoveIntent(targets[clickIndex].x, targets[clickIndex].y)
                end
            end
            if session2:isPlayer() and session2.localPlayer then
                if staying then
                    session2:localMoveIntent(session2.localPlayer.x, session2.localPlayer.y)
                else
                    local other = ((clickIndex + 1) % #targets) + 1
                    session2:localMoveIntent(targets[other].x, targets[other].y)
                end
            end
            clickIndex = (clickIndex % #targets) + 1
            nextClickAt = now + 3
        end

        if now >= nextCastAt then
            local plan = castPlan[castIndex]
            tryCast(session1, castStats1, plan, "player2", now)
            tryCast(session2, castStats2, plan, "player1", now)
            castIndex = (castIndex % #castPlan) + 1
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
            "%s: slot=%s rtt=%.0fms divergence=%.1fpx snaps=%d snapshots=%d castW=%d castQ=%d castE=%d sawPool=%s sawBeam=%s sawTrap=%s sawStun=%s tookDamage=%s hp=%.0f",
            name, tostring(session:getSlot()), (session.latency or 0) * 1000,
            stats.maxDivergence, stats.snaps, stats.samples,
            cast.sentW, cast.sentQ, cast.sentE,
            tostring(cast.sawPool), tostring(cast.sawBeam), tostring(cast.sawTrap),
            tostring(cast.sawStun), tostring(cast.tookDamage),
            (session:getState().health or 100)))
    end
    report("client1", session1, stats1, castStats1)
    report("client2", session2, stats2, castStats2)

    adapter1:destroy()
    adapter2:destroy()

    local healthy = stats1.samples > 0 and stats2.samples > 0
        and stats1.snaps == 0 and stats2.snaps == 0
        and castStats1.sentW > 0 and castStats2.sentW > 0
        and castStats1.sentQ > 0 and castStats2.sentQ > 0
        and castStats1.sentE > 0 and castStats2.sentE > 0
        and castStats1.sawPool and castStats2.sawPool
        and castStats1.sawBeam and castStats2.sawBeam
        and castStats1.sawTrap and castStats2.sawTrap
        and castStats1.sawStun and castStats2.sawStun
        and castStats1.tookDamage and castStats2.tookDamage

    if healthy then
        print("TWO-CLIENT DIAGNOSTIC PASSED (no rubber-banding, all abilities cast, stuns observed)")
        return true
    end
    print("TWO-CLIENT DIAGNOSTIC FAILED (snapping, missing casts/abilities, or no damage/stun observed)")
    return false
end

return run
