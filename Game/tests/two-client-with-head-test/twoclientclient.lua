-- Windowed auto-drive client for the two-window diagnostic (--twoclientwin).
--
-- One instance runs per love.exe window. It connects to the configured server,
-- renders the arena like the normal windowed client, but AUTO-DRIVES click-to-move
-- on a schedule (no mouse needed), instruments reconciliation to count snaps, and
-- after a fixed test window writes a result file under --out and closes its own
-- window (love.event.quit).
--
-- The outer launcher (scripts/twoclientwin.sh) starts two of these, reads both
-- result files, and asserts the same invariants as the headless --twoclient
-- diagnostic: both players move, both receive snapshots, zero reconciliation snaps
-- (no rubber-banding).
--
-- Run via main.lua flag:  --twoclientwin:child <1|2> --out <abs_dir>

local json = require("json")
local World = require("src.world")
local Session = require("src.session")
local net = require("src.net")

local function applyColor(color, alpha)
    love.graphics.setColor(color[1], color[2], color[3], alpha or color[4] or 1)
end

local function hasArg(args, name)
    for _, value in ipairs(args or {}) do
        if value == name then
            return true
        end
    end
    return false
end

local function argValue(args, name)
    for i = 1, #args do
        if args[i] == name then
            return args[i + 1]
        end
    end
    return nil
end

local function parseNumber(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

-- Reconcile wrapper: count position-changing snaps and observe the divergence
-- (mirrors the headless --twoclient instrumentation).
local function instrument(session, stats)
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
end

return function(args)
    local id = parseNumber(argValue(args, "--id"), 1)
    local outDir = argValue(args, "--out") or "."
    local DURATION = 12 -- test window in seconds

    local text = love.filesystem.read("config.json")
    local config = json.decode(text)
    local world = World.new(config)
    local session = Session.new(world, "client", config.server)
    local adapter = net.newClient(config, session)

    local WINDOW_WIDTH = config.window.width
    local WINDOW_HEIGHT = config.window.height
    local CELL_SIZE = config.grid.cellSize
    local COLORS = config.colors
    local CLICK_EFFECT = config.clickEffect
    local PLAYER_RADIUS = config.player.radius
    local obstacles = config.obstacles

    local stats = { snaps = 0, samples = 0, maxDivergence = 0, moved = false, gotSnapshot = false }
    instrument(session, stats)

    local targets = {
        { x = 60, y = 60 },
        { x = 740, y = 540 },
        { x = 740, y = 60 },
        { x = 60, y = 540 },
    }
    local clickIndex = 1
    local nextClickOffset = 1.0
    local autoDriving = false
    local startTime = 0
    local spawnX, spawnY = nil, nil
    local accumulator = 0
    local fixedDt = 1 / config.server.tickRate
    local gotSnapshotEver = false
    local launchTime = love.timer.getTime()
    local STARTUP_TIMEOUT = 8 -- seconds; if we never come up (no welcome/snapshot), self-report + quit

    ----------------------------------------
    -- Drawing (mirrors src/client.lua)
    ----------------------------------------
    local function drawGrid()
        applyColor(COLORS.grid)
        for x = 0, WINDOW_WIDTH, CELL_SIZE do
            love.graphics.line(x, 0, x, WINDOW_HEIGHT)
        end
        for y = 0, WINDOW_HEIGHT, CELL_SIZE do
            love.graphics.line(0, y, WINDOW_WIDTH, y)
        end
    end

    local function drawObstacles()
        applyColor(COLORS.obstacleFill)
        for _, obstacle in ipairs(obstacles) do
            love.graphics.rectangle("fill", obstacle.x, obstacle.y, obstacle.width, obstacle.height)
        end
        applyColor(COLORS.obstacleOutline)
        for _, obstacle in ipairs(obstacles) do
            love.graphics.rectangle("line", obstacle.x, obstacle.y, obstacle.width, obstacle.height)
        end
    end

    local function drawPath(path)
        applyColor(COLORS.path)
        for i = 1, #path do
            local point = path[i]
            love.graphics.circle("fill", point.x, point.y, 3)
            local nextPoint = path[i + 1]
            if nextPoint then
                love.graphics.line(point.x, point.y, nextPoint.x, nextPoint.y)
            end
        end
    end

    local function drawPlayer(x, y, fill, outline)
        applyColor(fill)
        love.graphics.circle("fill", x, y, PLAYER_RADIUS)
        applyColor(outline)
        love.graphics.circle("line", x, y, PLAYER_RADIUS)
    end

    local function playerColors(slot)
        if slot == "player1" then
            return COLORS.player1Fill, COLORS.player1Outline
        end
        return COLORS.player2Fill, COLORS.player2Outline
    end

    ----------------------------------------
    -- Result reporting + teardown
    ----------------------------------------
    local function writeResult()
        local path = outDir .. "/client" .. tostring(id) .. ".txt"
        local lines = {
            "id=" .. tostring(id),
            "slot=" .. tostring(session:getSlot() or ""),
            "rtt_ms=" .. string.format("%.1f", (session.latency or 0) * 1000),
            "moved=" .. tostring(stats.moved),
            "snaps=" .. tostring(stats.snaps),
            "samples=" .. tostring(stats.samples),
            "max_divergence=" .. string.format("%.1f", stats.maxDivergence),
            "got_snapshot=" .. tostring(stats.gotSnapshot),
        }
        local handle = io.open(path, "w")
        if handle then
            handle:write(table.concat(lines, "\n") .. "\n")
            handle:close()
        end
    end

    local function finish()
        writeResult()
        love.event.quit()
    end

    ----------------------------------------
    -- LÖVE callbacks
    ----------------------------------------
    function love.load()
        love.window.setTitle("Arena two-window client " .. tostring(id))
        love.window.setMode(WINDOW_WIDTH, WINDOW_HEIGHT)
    end

    local DEBUG_DUMP = os.getenv("TWOCLIENTWIN_DEBUG") == "1"

    function love.update(dt)
        adapter:pump()
        if DEBUG_DUMP then
            local slot = session:getSlot() or "none"
            local lastSeq = session.lastSeq or "nil"
            print(string.format("[child%d] conn=%s slot=%s lastSeq=%s auto=%s",
                id, tostring(adapter:isConnected()), slot, tostring(lastSeq), tostring(autoDriving)))
        end

        accumulator = accumulator + dt
        while accumulator >= fixedDt do
            session:tick(fixedDt)
            accumulator = accumulator - fixedDt
        end
        adapter:flushOutbox()

        if not gotSnapshotEver and session.lastSeq ~= nil then
            gotSnapshotEver = true
            stats.gotSnapshot = true
        end

        -- Startup watchdog: if we never became a live, fed player (e.g. no server,
        -- connection refused, or the slot is already full), don't hang forever —
        -- report the failure and close our own window so the launcher can stop.
        if not autoDriving and love.timer.getTime() - launchTime >= STARTUP_TIMEOUT then
            finish()
            return
        end

        -- Start the test proper once this window is a live player and the server
        -- has sent its first snapshot.
        if not autoDriving and session:isPlayer() and stats.gotSnapshot then
            local lp = session.localPlayer
            spawnX, spawnY = lp.x, lp.y
            autoDriving = true
            startTime = love.timer.getTime()
            nextClickOffset = 1.0
        end

        if autoDriving then
            local elapsed = love.timer.getTime() - startTime
            if elapsed >= nextClickOffset then
                session:localMoveIntent(targets[clickIndex].x, targets[clickIndex].y)
                clickIndex = (clickIndex % #targets) + 1
                nextClickOffset = elapsed + 2.0
            end

            local lp = session.localPlayer
            if lp and (spawnX ~= nil) and (lp.x ~= spawnX or lp.y ~= spawnY) then
                stats.moved = true
            end

            if elapsed >= DURATION then
                finish()
            end
        end
    end

    function love.draw()
        local state = session:getState()
        local background = COLORS.background
        love.graphics.clear(background[1], background[2], background[3], background[4])

        drawGrid()
        drawObstacles()

        if session:isPlayer() then
            drawPath(session:getLocalPath())
        end

        for _, slot in ipairs({ "player1", "player2" }) do
            local player = state.players[slot]
            if player then
                local fill, outline = playerColors(slot)
                drawPlayer(player.x, player.y, fill, outline)
            end
        end
    end

    function love.quit()
        adapter:destroy()
    end

    return session
end
