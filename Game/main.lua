-- LÖVE 2D: click-to-move with A* pathfinding around obstacles
-- Run with: love .

local json = require("json")

local configText, readError = love.filesystem.read("config.json")
assert(configText, "Could not read config.json: " .. tostring(readError))
local config = json.decode(configText)

----------------------------------------
-- Configuration
----------------------------------------
local WINDOW_TITLE = config.window.title
local WINDOW_WIDTH = config.window.width
local WINDOW_HEIGHT = config.window.height
local CELL_SIZE = config.grid.cellSize
local GRID_COLUMNS = math.floor(WINDOW_WIDTH / CELL_SIZE)
local GRID_ROWS = math.floor(WINDOW_HEIGHT / CELL_SIZE)

local WALK_SPEED = config.player.walkSpeed
local PLAYER_RADIUS = config.player.radius

local COLORS = config.colors
local CLICK_EFFECT = config.clickEffect
local obstacles = config.obstacles

----------------------------------------
-- Grid <-> world coordinates
----------------------------------------
local function gridIndex(col, row)
    return row * GRID_COLUMNS + col
end

local function indexToCell(index)
    return index % GRID_COLUMNS, math.floor(index / GRID_COLUMNS)
end

local function worldToCell(x, y)
    return math.floor(x / CELL_SIZE), math.floor(y / CELL_SIZE)
end

local function cellCenter(col, row)
    return col * CELL_SIZE + CELL_SIZE / 2, row * CELL_SIZE + CELL_SIZE / 2
end

local function waypoint(col, row)
    local x, y = cellCenter(col, row)
    return { x = x, y = y }
end

local function pointIsInsideObstacle(x, y)
    for _, obstacle in ipairs(obstacles) do
        if x > obstacle.x and x < obstacle.x + obstacle.width
            and y > obstacle.y and y < obstacle.y + obstacle.height then
            return true
        end
    end
    return false
end

local function cellIsWalkable(col, row)
    if col < 0 or col >= GRID_COLUMNS or row < 0 or row >= GRID_ROWS then
        return false
    end
    local centerX, centerY = cellCenter(col, row)
    return not pointIsInsideObstacle(centerX, centerY)
end

----------------------------------------
-- A* pathfinding
----------------------------------------
local function neighboringCells(col, row)
    return {
        { col + 1, row },
        { col - 1, row },
        { col, row + 1 },
        { col, row - 1 },
    }
end

local function manhattanDistance(col, row, goalCol, goalRow)
    return math.abs(col - goalCol) + math.abs(row - goalRow)
end

local function reconstructPath(cameFrom, startIndex, goalIndex)
    local path = {}
    local current = goalIndex
    while current ~= startIndex do
        local col, row = indexToCell(current)
        table.insert(path, 1, waypoint(col, row))
        current = cameFrom[current]
    end
    local startCol, startRow = indexToCell(startIndex)
    table.insert(path, 1, waypoint(startCol, startRow))
    return path
end

local function findPath(startX, startY, goalX, goalY)
    local startCol, startRow = worldToCell(startX, startY)
    local goalCol, goalRow = worldToCell(goalX, goalY)

    if not cellIsWalkable(startCol, startRow) or not cellIsWalkable(goalCol, goalRow) then
        return {}
    end

    local startIndex = gridIndex(startCol, startRow)
    local goalIndex = gridIndex(goalCol, goalRow)

    local open = { { index = startIndex, col = startCol, row = startRow } }
    local inOpen = { [startIndex] = true }
    local cameFrom = {}
    local costSoFar = { [startIndex] = 0 }

    local function estimatedCost(col, row)
        return costSoFar[gridIndex(col, row)] + manhattanDistance(col, row, goalCol, goalRow)
    end

    while #open > 0 do
        local current = table.remove(open, 1)
        inOpen[current.index] = nil

        if current.index == goalIndex then
            return reconstructPath(cameFrom, startIndex, goalIndex)
        end

        for _, neighbor in ipairs(neighboringCells(current.col, current.row)) do
            local nextCol, nextRow = neighbor[1], neighbor[2]
            if cellIsWalkable(nextCol, nextRow) then
                local nextIndex = gridIndex(nextCol, nextRow)
                local tentativeCost = costSoFar[current.index] + 1
                if tentativeCost < (costSoFar[nextIndex] or math.huge) then
                    cameFrom[nextIndex] = current.index
                    costSoFar[nextIndex] = tentativeCost
                    if not inOpen[nextIndex] then
                        table.insert(open, { index = nextIndex, col = nextCol, row = nextRow })
                        inOpen[nextIndex] = true
                    end
                end
            end
        end

        -- Keep open sorted by cheapest estimated cost (a sorted array acts as a simple priority queue).
        table.sort(open, function(a, b)
            return estimatedCost(a.col, a.row) < estimatedCost(b.col, b.row)
        end)
    end

    return {}
end

----------------------------------------
-- Player
----------------------------------------
local player = {
    x = config.player.startX,
    y = config.player.startY,
    path = {},
}

local function movePlayerAlongPath(dt)
    if #player.path == 0 then
        return
    end

    local next = player.path[1]
    local dx = next.x - player.x
    local dy = next.y - player.y
    local distance = math.sqrt(dx * dx + dy * dy)

    if distance < 4 then
        table.remove(player.path, 1)
        return
    end

    player.x = player.x + (dx / distance) * WALK_SPEED * dt
    player.y = player.y + (dy / distance) * WALK_SPEED * dt
end

----------------------------------------
-- Click effects
----------------------------------------
local effects = {}

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
-- Input handling
----------------------------------------
local function obstacleAt(x, y)
    for index, obstacle in ipairs(obstacles) do
        if x > obstacle.x and x < obstacle.x + obstacle.width
            and y > obstacle.y and y < obstacle.y + obstacle.height then
            return index
        end
    end
    return nil
end

local function handleMoveClick(x, y)
    player.path = findPath(player.x, player.y, x, y)
    table.insert(effects, createClickEffect(x, y))
end

local function handleObstacleClick(x, y)
    local existing = obstacleAt(x, y)
    if existing then
        table.remove(obstacles, existing)
        return
    end

    local col, row = worldToCell(x, y)
    table.insert(obstacles, {
        x = col * CELL_SIZE,
        y = row * CELL_SIZE,
        width = CELL_SIZE,
        height = CELL_SIZE,
    })
    player.path = {}
end

----------------------------------------
-- Drawing
----------------------------------------
local function applyColor(color, alpha)
    love.graphics.setColor(color[1], color[2], color[3], alpha or color[4] or 1)
end

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

local function drawPath()
    applyColor(COLORS.path)
    for i = 1, #player.path do
        local point = player.path[i]
        love.graphics.circle("fill", point.x, point.y, 3)

        local nextPoint = player.path[i + 1]
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

local function drawPlayer()
    applyColor(COLORS.playerFill)
    love.graphics.circle("fill", player.x, player.y, PLAYER_RADIUS)

    applyColor(COLORS.playerOutline)
    love.graphics.circle("line", player.x, player.y, PLAYER_RADIUS)
end

----------------------------------------
-- LÖVE callbacks
----------------------------------------
function love.load()
    love.window.setTitle(WINDOW_TITLE)
    love.window.setMode(WINDOW_WIDTH, WINDOW_HEIGHT)
end

function love.update(dt)
    movePlayerAlongPath(dt)
    updateEffects(dt)
end

function love.draw()
    local background = COLORS.background
    love.graphics.clear(background[1], background[2], background[3], background[4])
    drawGrid()
    drawObstacles()
    drawPath()
    drawEffects()
    drawPlayer()
end

function love.mousepressed(x, y, button)
    if button == 1 then
        handleMoveClick(x, y)
    elseif button == 2 then
        handleObstacleClick(x, y)
    end
end

function love.keypressed(key)
    if key == "escape" then
        love.event.quit()
    end
end
