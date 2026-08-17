-- Windowed multiplayer client. Connects to the server from config, predicts its
-- own player + casts, interpolates the remote player, and renders the shared
-- arena (pools, beams, traps, stuns, health bars, and the Q/W/E ability HUD).
--
-- Input: right-click moves; holding an ability key (Q/W/E) enters aim mode and
-- left-clicking places the ability. Releasing the key cancels aim.

local Game = require("src.game")
local Session = require("src.session")
local net = require("src.net")
local registry = require("src.abilities.registry")
local Sprites = require("src.sprites")

local client = {}

local function applyColor(color, alpha)
    love.graphics.setColor(color[1], color[2], color[3], alpha or color[4] or 1)
end

local function clamp(value, lo, hi)
    return math.max(lo, math.min(hi, value))
end

function client.run(config)
    local game = Game.new(config)
    local session = Session.new(game, "client", config.server)
    local adapter = net.newClient(config, session)

    local WINDOW_TITLE = config.window.title
    local WINDOW_WIDTH = config.window.width
    local WINDOW_HEIGHT = config.window.height
    local CELL_SIZE = config.grid.cellSize
    local COLORS = config.colors
    local CLICK_EFFECT = config.clickEffect
    local PLAYER_RADIUS = config.player.radius
    local obstacles = config.obstacles

    local MAX_HEALTH = 100 -- matches the simulation's initial health

    local effects = {}
    local fixedDt = 1 / config.server.tickRate
    local accumulator = 0

    local aimingSlot = nil -- "q" | "w" | "e" while the ability key is held
    local keyFont, smallFont
    local abilityAtlas

    local function ensureFonts()
        if not keyFont then
            keyFont = love.graphics.newFont(16)
            smallFont = love.graphics.newFont(12)
        end
    end

    local function ensureSprites()
        if not abilityAtlas then
            abilityAtlas = Sprites.new("sprites/abilities_tilemap.png")
        end
    end

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
        if CELL_SIZE < 10 then
            for i = 1, #path - 1 do
                local a, b = path[i], path[i + 1]
                love.graphics.line(a.x, a.y, b.x, b.y)
            end
        else
            for i = 1, #path do
                local point = path[i]
                love.graphics.circle("fill", point.x, point.y, 3)

                local nextPoint = path[i + 1]
                if nextPoint then
                    love.graphics.line(point.x, point.y, nextPoint.x, nextPoint.y)
                end
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

    -- Stunned players: yellow body plus an orbiting ring so the status reads at
    -- a glance from any angle.
    local function drawStunnedPlayer(x, y)
        local body = COLORS.stunBody
        local ring = COLORS.stunRing

        applyColor(body)
        love.graphics.circle("fill", x, y, PLAYER_RADIUS)

        applyColor(body)
        love.graphics.circle("line", x, y, PLAYER_RADIUS)

        local t = love.timer.getTime() * 3
        local orbitRadius = PLAYER_RADIUS + 7
        local rx = x + math.cos(t) * orbitRadius
        local ry = y + math.sin(t) * orbitRadius
        applyColor(ring)
        love.graphics.circle("line", rx, ry, 4)
    end

    local function playerColors(slot)
        if slot == "player1" then
            return COLORS.player1Fill, COLORS.player1Outline
        end
        return COLORS.player2Fill, COLORS.player2Outline
    end

    local function drawHealthBar(x, y, width, height, hp, maxHp, fillColor, backColor)
        applyColor(backColor)
        love.graphics.rectangle("fill", x, y, width, height)

        local ratio = clamp(hp / maxHp, 0, 1)
        if ratio > 0 then
            applyColor(fillColor)
            love.graphics.rectangle("fill", x, y, width * ratio, height)
        end

        applyColor(COLORS.hudText)
        love.graphics.rectangle("line", x, y, width, height)
    end

    local function drawOverheadHealth(x, y, hp)
        local width = 44
        local height = 6
        drawHealthBar(
            x - width / 2,
            y - PLAYER_RADIUS - 10,
            width,
            height,
            hp,
            MAX_HEALTH,
            COLORS.healthEnemyFill,
            COLORS.healthBack
        )
    end

    -- League-style bottom-center HUD: Q/W/E boxes with ready/cooldown/empty
    -- states, and the local player's health bar above them.
    local HUD_BOX = 56
    local HUD_GAP = 8
    local HEALTH_H = 10
    local KEY_BACK = { 0, 0, 0, 0.6 } -- backing behind the hotkey letter

    local function drawHUD(state)
        local slot = session:getSlot()
        if slot ~= "player1" and slot ~= "player2" then
            return
        end
        local loadout = state.loadout
        local cooldowns = state.cooldowns
        if not loadout or not cooldowns then
            return
        end

        local totalWidth = HUD_BOX * 3 + HUD_GAP * 2
        local startX = (WINDOW_WIDTH - totalWidth) / 2
        local hudY = WINDOW_HEIGHT - HUD_BOX - 16

        drawHealthBar(
            startX,
            hudY - HEALTH_H - 6,
            totalWidth,
            HEALTH_H,
            state.health or 0,
            MAX_HEALTH,
            COLORS.healthFill,
            COLORS.healthBack
        )

        local keys = { "q", "w", "e" }
        for i, key in ipairs(keys) do
            local x = startX + (i - 1) * (HUD_BOX + HUD_GAP)
            local abilityId = loadout[key]
            local cooldown = cooldowns[key] or 0

            -- box background
            applyColor(COLORS.hudBox)
            love.graphics.rectangle("fill", x, hudY, HUD_BOX, HUD_BOX)

            local borderColor = COLORS.hudText
            local labelText

            if not abilityId then
                -- empty/disabled slot
                applyColor(COLORS.hudDisabled)
                love.graphics.rectangle("fill", x, hudY, HUD_BOX, HUD_BOX)
            else
                local abilityModule = registry.load(abilityId)
                local icon = abilityModule.icon

                if icon then
                    -- Draw the ability's tilemap icon scaled to fill the box.
                    ensureSprites()
                    local quad = Sprites.quad(abilityAtlas, icon.col, icon.row)
                    love.graphics.setColor(1, 1, 1, 1)
                    love.graphics.draw(
                        abilityAtlas.image,
                        quad,
                        x, hudY,
                        0,
                        HUD_BOX / abilityAtlas.tile,
                        HUD_BOX / abilityAtlas.tile
                    )
                end

                if cooldown > 0 then
                    -- Dim the icon while it recharges and show a countdown.
                    applyColor(COLORS.hudCooldown, 0.72)
                    love.graphics.rectangle("fill", x, hudY, HUD_BOX, HUD_BOX)
                    labelText = string.format("%.1f", cooldown)
                elseif not icon then
                    -- No sprite yet: show the ability name when ready.
                    labelText = abilityModule.name
                else
                    borderColor = COLORS.hudReady
                end
            end

            -- Hotkey label in the top-left corner, on a dark backing so it stays
            -- legible over bright icon art.
            love.graphics.setFont(keyFont)
            local keyLabel = string.upper(key)
            applyColor(KEY_BACK)
            love.graphics.rectangle("fill", x + 4, hudY + 4, keyFont:getWidth(keyLabel) + 8, keyFont:getHeight() + 4)
            applyColor(COLORS.hudText)
            love.graphics.print(keyLabel, x + 8, hudY + 6)

            if labelText then
                love.graphics.setFont(smallFont)
                applyColor(COLORS.hudText)
                love.graphics.print(labelText, x + 8, hudY + HUD_BOX - 24)
            end

            -- Live trap counter on the E hotkey (hidden at zero).
            if key == "e" then
                local trapCount = game:countActiveAbilities(slot, "beartrap")
                if trapCount >= 1 then
                    love.graphics.setFont(smallFont)
                    applyColor(COLORS.hudText)
                    local label = tostring(trapCount) .. "/4"
                    local labelWidth = smallFont:getWidth(label)
                    love.graphics.print(label, x + HUD_BOX - labelWidth - 6, hudY + 6)
                end
            end

            applyColor(borderColor)
            love.graphics.rectangle("line", x, hudY, HUD_BOX, HUD_BOX)
        end
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

        -- A stun cancels a held aim mode.
        if aimingSlot and session:isPlayer() then
            local state = session:getState()
            local me = state.players[session:getSlot()]
            if me and me.stunned then
                aimingSlot = nil
            end
        end
    end

    function love.draw()
        ensureFonts()
        local state = session:getState()
        local background = COLORS.background
        love.graphics.clear(background[1], background[2], background[3], background[4])

        drawGrid()
        drawObstacles()

        if session:isPlayer() then
            drawPath(session:getLocalPath())
        end

        -- Abilities render above the grid/obstacles and below player markers.
        for _, ability in ipairs(game:getAbilities()) do
            ability:draw(COLORS)
        end

        drawEffects()

        local slot = session:getSlot()
        for _, s in ipairs({ "player1", "player2" }) do
            local player = state.players[s]
            if player then
                if player.stunned then
                    drawStunnedPlayer(player.x, player.y)
                else
                    local fill, outline = playerColors(s)
                    drawPlayer(player.x, player.y, fill, outline)
                end
                if s ~= slot and player.hp ~= nil then
                    drawOverheadHealth(player.x, player.y, player.hp)
                end
            end
        end

        -- Aim range ring around the local player.
        if aimingSlot and session:isPlayer() then
            local me = state.players[slot]
            local loadout = state.loadout
            if me and loadout then
                local abilityId = loadout[aimingSlot]
                if abilityId then
                    local abilityModule = registry.load(abilityId)
                    applyColor(COLORS.rangeRing)
                    love.graphics.circle("line", me.x, me.y, abilityModule.range)
                end
            end
        end

        drawHUD(state)
    end

    function love.mousepressed(x, y, button)
        if not session:isPlayer() then
            return
        end
        if button == 2 then
            -- right-click moves
            session:localMoveIntent(x, y)
            table.insert(effects, createClickEffect(x, y))
        elseif button == 1 and aimingSlot then
            -- hold ability key + left-click casts
            session:localCastIntent(aimingSlot, x, y)
            aimingSlot = nil
        end
    end

    function love.keypressed(key)
        if key == "escape" then
            love.event.quit()
        elseif key == "q" or key == "w" or key == "e" then
            if session:isPlayer() then
                local state = session:getState()
                local me = state.players[session:getSlot()]
                local loadout = state.loadout
                local cooldowns = state.cooldowns
                if me and not me.stunned and loadout and loadout[key] and cooldowns and (cooldowns[key] or 0) <= 0 then
                    aimingSlot = key
                end
            end
        end
    end

    function love.keyreleased(key)
        if key == aimingSlot then
            aimingSlot = nil
        end
    end

    function love.quit()
        adapter:destroy()
    end

    return session
end

return client
