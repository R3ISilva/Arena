-- Transport-agnostic world simulation: grid math, obstacle queries, deterministic
-- A* pathfinding, and fixed-step movement. Shared by the authoritative server and
-- the predictive client so both sides always compute the same result.

local World = {}
World.__index = World

function World.new(config)
    local self = setmetatable({}, World)
    self.cellSize = config.grid.cellSize
    self.windowWidth = config.window.width
    self.windowHeight = config.window.height
    self.columns = math.floor(self.windowWidth / self.cellSize)
    self.rows = math.floor(self.windowHeight / self.cellSize)
    self.obstacles = config.obstacles
    self.walkSpeed = config.player.walkSpeed
    self.radius = config.player.radius
    self.spawnPoints = config.player.spawnPoints
    return self
end

----------------------------------------
-- Grid <-> world coordinates
----------------------------------------
function World:gridIndex(col, row)
    return row * self.columns + col
end

function World:indexToCell(index)
    return index % self.columns, math.floor(index / self.columns)
end

function World:worldToCell(x, y)
    return math.floor(x / self.cellSize), math.floor(y / self.cellSize)
end

function World:cellCenter(col, row)
    return col * self.cellSize + self.cellSize / 2, row * self.cellSize + self.cellSize / 2
end

function World:waypoint(col, row)
    local x, y = self:cellCenter(col, row)
    return { x = x, y = y }
end

function World:pointIsInsideObstacle(x, y)
    for _, obstacle in ipairs(self.obstacles) do
        if x > obstacle.x and x < obstacle.x + obstacle.width
            and y > obstacle.y and y < obstacle.y + obstacle.height then
            return true
        end
    end
    return false
end

function World:cellIsWalkable(col, row)
    if col < 0 or col >= self.columns or row < 0 or row >= self.rows then
        return false
    end
    local centerX, centerY = self:cellCenter(col, row)
    return not self:pointIsInsideObstacle(centerX, centerY)
end

----------------------------------------
-- Deterministic A* pathfinding
----------------------------------------
function World:neighboringCells(col, row)
    return {
        { col + 1, row },
        { col - 1, row },
        { col, row + 1 },
        { col, row - 1 },
    }
end

function World:manhattanDistance(col, row, goalCol, goalRow)
    return math.abs(col - goalCol) + math.abs(row - goalRow)
end

function World:reconstructPath(cameFrom, startIndex, goalIndex)
    local path = {}
    local current = goalIndex
    while current ~= startIndex do
        local col, row = self:indexToCell(current)
        table.insert(path, 1, self:waypoint(col, row))
        current = cameFrom[current]
    end
    local startCol, startRow = self:indexToCell(startIndex)
    table.insert(path, 1, self:waypoint(startCol, startRow))
    return path
end

function World:findPath(startX, startY, goalX, goalY)
    local startCol, startRow = self:worldToCell(startX, startY)
    local goalCol, goalRow = self:worldToCell(goalX, goalY)

    if not self:cellIsWalkable(startCol, startRow) or not self:cellIsWalkable(goalCol, goalRow) then
        return {}
    end

    local startIndex = self:gridIndex(startCol, startRow)
    local goalIndex = self:gridIndex(goalCol, goalRow)

    local open = { { index = startIndex, col = startCol, row = startRow } }
    local inOpen = { [startIndex] = true }
    local cameFrom = {}
    local costSoFar = { [startIndex] = 0 }

    local function estimatedCost(col, row)
        return costSoFar[self:gridIndex(col, row)] + self:manhattanDistance(col, row, goalCol, goalRow)
    end

    while #open > 0 do
        local current = table.remove(open, 1)
        inOpen[current.index] = nil

        if current.index == goalIndex then
            return self:reconstructPath(cameFrom, startIndex, goalIndex)
        end

        for _, neighbor in ipairs(self:neighboringCells(current.col, current.row)) do
            local nextCol, nextRow = neighbor[1], neighbor[2]
            if self:cellIsWalkable(nextCol, nextRow) then
                local nextIndex = self:gridIndex(nextCol, nextRow)
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

        -- A sorted array acts as a simple priority queue. Tie-breaking on the unique
        -- cell index keeps the sort total and therefore deterministic across runs.
        table.sort(open, function(a, b)
            local costA = estimatedCost(a.col, a.row)
            local costB = estimatedCost(b.col, b.row)
            if costA ~= costB then
                return costA < costB
            end
            return a.index < b.index
        end)
    end

    return {}
end

----------------------------------------
-- Fixed-step movement along a path
----------------------------------------
function World:stepPlayer(player, dt)
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

    player.x = player.x + (dx / distance) * self.walkSpeed * dt
    player.y = player.y + (dy / distance) * self.walkSpeed * dt
end

return World
