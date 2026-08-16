-- Windowed multiplayer client. Connects to the server from config, predicts its
-- own player, interpolates the remote player, and renders the shared arena.
-- Click effects and path previews are local-only.

local World = require("src.world")
local Session = require("src.session")
local net = require("src.net")

local client = {}

local function applyColor(color, alpha)
    love.graphics.setColor(color[1], color[2], color[3], alpha or color[4] or 1)
end

function client.run(config)
    local world = World.new(config)
    local session = Session.new(world, "client", config.server)
    local adapter = net.newClient(config, session)

    local WINDOW_TITLE = config.window.title
    local WINDOW_WIDTH = config.window.width
    local WINDOW_HEIGHT = config.window.height
    local CELL_SIZE = config.grid.cellSize
    local COLORS = config.colors
    local CLICK_EFFECT = config.clickEffect
    local PLAYER_RADIUS = config.player.radius
    local obstacles = config.obstacles

    local effects = {}
    local fixedDt = 1 / config.server.tickRate
    local accumulator = 0

    ----------------------------------------
    -- Click effects (local-only)
    ----------------------------------------
    local function createClickEffect(x, y)
        return {
            x = x,
            y = y,
            elapsed = 0,
            duration = CLICK_EFFECT.duration,
            radius = CLICK_EFFECT.radius,
            arrowCount = CLICK_EFFECT.arrowCount,
            arrowLength = CLICK_EFFECT.arrowLength,
            arrowWidth = CLICK_EFFECT.arrowWidth,
        }
    end

    local function updateEffects(dt)
        for i = #effects, 1, -1 do
            local effect = effects[i]
            effect.elapsed = effect.elapsed + dt
            if effect.elapsed >= effect.duration then
                table.remove(effects, i)
            end
        end
    end

    ----------------------------------------
    -- Drawing
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

    local function drawArrow(x, y, angle, length, width)
        local tipX = x + math.cos(angle) * length
        local tipY = y + math.sin(angle) * length
        local backX = x - math.cos(angle) * (width * 0.4)
        local backY = y - math.sin(angle) * (width * 0.4)
        local perpX, perpY = -math.sin(angle), math.cos(angle)

        love.graphics.polygon("fill",
            tipX, tipY,
            backX + perpX * width * 0.5, backY + perpY * width * 0.5,
            backX - perpX * width * 0.5, backY - perpY * width * 0.5
        )
    end

    local function drawEffects()
        for _, effect in ipairs(effects) do
            local fadeIn = effect.elapsed / 0.1
            local fadeOut = 1 - (effect.elapsed - 0.1) / 0.2
            local alpha = math.max(0, math.min(fadeIn, fadeOut))
            local radius = math.max(8, effect.radius - effect.elapsed * 45)

            applyColor(COLORS.clickEffect, alpha)
            for i = 0, effect.arrowCount - 1 do
                local angle = (i / effect.arrowCount) * math.pi * 2
                local arrowX = effect.x + math.cos(angle) * radius
                local arrowY = effect.y + math.sin(angle) * radius
                drawArrow(arrowX, arrowY, angle + math.pi, effect.arrowLength, effect.arrowWidth)
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
    -- LÖVE callbacks
    ----------------------------------------
    function love.load()
        love.window.setTitle(WINDOW_TITLE)
        love.window.setMode(WINDOW_WIDTH, WINDOW_HEIGHT)
    end

    function love.update(dt)
        adapter:pump()

        accumulator = accumulator + dt
        while accumulator >= fixedDt do
            session:tick(fixedDt)
            accumulator = accumulator - fixedDt
        end

        adapter:flushOutbox()
        updateEffects(dt)
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

        drawEffects()

        for _, slot in ipairs({ "player1", "player2" }) do
            local player = state.players[slot]
            if player then
                local fill, outline = playerColors(slot)
                drawPlayer(player.x, player.y, fill, outline)
            end
        end
    end

    function love.mousepressed(x, y, button)
        if button == 1 and session:isPlayer() then
            session:localMoveIntent(x, y)
            table.insert(effects, createClickEffect(x, y))
        end
    end

    function love.keypressed(key)
        if key == "escape" then
            love.event.quit()
        end
    end

    function love.quit()
        adapter:destroy()
    end

    return session
end

return client
