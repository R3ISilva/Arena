-- Transport-agnostic world simulation: grid math, obstacle queries, deterministic
-- A* pathfinding, and fixed-step movement. Shared by the authoritative server and
-- the predictive client so both sides always compute the same result.

local World = {}
World.__index = World

local DIAGONAL_COST = math.sqrt(2)

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
-- Eight-directional neighbors. Orthogonal steps cost 1, diagonal steps cost
-- sqrt(2) so straight lines are preferred while diagonals remain available.
function World:neighboringCells(col, row)
    return {
        { col + 1, row, 1 },
        { col - 1, row, 1 },
        { col, row + 1, 1 },
        { col, row - 1, 1 },
        { col + 1, row + 1, DIAGONAL_COST },
        { col + 1, row - 1, DIAGONAL_COST },
        { col - 1, row + 1, DIAGONAL_COST },
        { col - 1, row - 1, DIAGONAL_COST },
    }
end

-- Octile distance: the exact shortest path cost on an open 8-connected grid.
-- Admissible and consistent with the orthogonal/diagonal step costs above.
function World:octileDistance(col, row, goalCol, goalRow)
    local dx = math.abs(col - goalCol)
    local dy = math.abs(row - goalRow)
    return (dx + dy) + (DIAGONAL_COST - 2) * math.min(dx, dy)
end

-- A diagonal step must not cut through a blocked corner: both adjacent
-- orthogonal cells have to be walkable.
function World:diagonalIsWalkable(col, row, nextCol, nextRow)
    local dCol = nextCol - col
    local dRow = nextRow - row
    if dCol == 0 or dRow == 0 then
        return true
    end
    return self:cellIsWalkable(col + dCol, row) and self:cellIsWalkable(col, row + dRow)
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
        return costSoFar[self:gridIndex(col, row)] + self:octileDistance(col, row, goalCol, goalRow)
    end

    while #open > 0 do
        local current = table.remove(open, 1)
        inOpen[current.index] = nil

        if current.index == goalIndex then
            return self:reconstructPath(cameFrom, startIndex, goalIndex)
        end

        for _, neighbor in ipairs(self:neighboringCells(current.col, current.row)) do
            local nextCol, nextRow, stepCost = neighbor[1], neighbor[2], neighbor[3]
            if self:cellIsWalkable(nextCol, nextRow) and self:diagonalIsWalkable(current.col, current.row, nextCol, nextRow) then
                local nextIndex = self:gridIndex(nextCol, nextRow)
                local tentativeCost = costSoFar[current.index] + stepCost
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
    local remaining = self.walkSpeed * dt
    while remaining > 0 and #player.path > 0 do
        local next = player.path[1]
        local dx = next.x - player.x
        local dy = next.y - player.y
        local distance = math.sqrt(dx * dx + dy * dy)

        if distance <= remaining then
            -- Arrive exactly at this waypoint (never overshoot) and carry the
            -- leftover movement into the next leg of the path.
            player.x = next.x
            player.y = next.y
            table.remove(player.path, 1)
            remaining = remaining - distance
        else
            player.x = player.x + (dx / distance) * remaining
            player.y = player.y + (dy / distance) * remaining
            remaining = 0
        end
    end
end

return World
