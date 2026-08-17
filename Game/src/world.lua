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

    -- Precompute a sparse bitmap of blocked cells (center strictly inside an
    -- obstacle). Obstacles are static, so this is built once and gives the A*
    -- hot loop O(1) walkability instead of re-testing every obstacle per cell.
    self.blocked = {}
    local obstacles = self.obstacles
    for row = 0, self.rows - 1 do
        for col = 0, self.columns - 1 do
            local centerX = col * self.cellSize + self.cellSize / 2
            local centerY = row * self.cellSize + self.cellSize / 2
            for i = 1, #obstacles do
                local obstacle = obstacles[i]
                if centerX > obstacle.x and centerX < obstacle.x + obstacle.width
                    and centerY > obstacle.y and centerY < obstacle.y + obstacle.height then
                    self.blocked[row * self.columns + col] = true
                    break
                end
            end
        end
    end
    self.walkSpeed = config.player.walkSpeed
    self.radius = config.player.radius
    self.spawnPoints = config.player.spawnPoints

    -- Persistent scratch space for A* pathfinding: one slot per cell, reused
    -- across calls. Plain arrays indexed by cell index are much faster than hash
    -- tables on the dense grid, and a monotonically increasing search id marks
    -- valid entries so nothing needs clearing between searches.
    self.searchId = 0
    self.gStamp = {}      -- gStamp[i] == searchId => gCost[i] is valid
    self.gCost = {}
    self.parentStamp = {} -- parentStamp[i] == searchId => parent[i] is valid
    self.parent = {}
    self.openCosts = {}   -- binary heap of open cells (fCost / cell index)
    self.openIndices = {}
    return self
end

----------------------------------------
-- Grid <-> world coordinates
----------------------------------------
function World:worldToCell(x, y)
    return math.floor(x / self.cellSize), math.floor(y / self.cellSize)
end

function World:cellCenter(col, row)
    return col * self.cellSize + self.cellSize / 2, row * self.cellSize + self.cellSize / 2
end

function World:cellIsWalkable(col, row)
    if col < 0 or col >= self.columns or row < 0 or row >= self.rows then
        return false
    end
    return not self.blocked[row * self.columns + col]
end

----------------------------------------
-- Deterministic A* pathfinding
----------------------------------------
-- Eight-directional neighbor offsets. Orthogonal steps cost 1, diagonal steps
-- cost sqrt(2) so straight lines are preferred while diagonals remain available.
local NEIGHBOR_OFFSETS = {
    { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
    { 1, 1, DIAGONAL_COST }, { 1, -1, DIAGONAL_COST }, { -1, 1, DIAGONAL_COST }, { -1, -1, DIAGONAL_COST },
}

-- Octile distance: the exact shortest path cost on an open 8-connected grid.
-- Admissible and consistent with the orthogonal/diagonal step costs above.
-- Pure module function (no self); the World:octileDistance method wraps it.
local function octileDistance(col, row, goalCol, goalRow)
    local dx = math.abs(col - goalCol)
    local dy = math.abs(row - goalRow)
    return (dx + dy) + (DIAGONAL_COST - 2) * math.min(dx, dy)
end

function World:octileDistance(col, row, goalCol, goalRow)
    return octileDistance(col, row, goalCol, goalRow)
end

function World:findPath(startX, startY, goalX, goalY)
    local columns = self.columns
    local rows = self.rows
    local cellSize = self.cellSize

    local startCol, startRow = self:worldToCell(startX, startY)
    local goalCol, goalRow = self:worldToCell(goalX, goalY)

    -- Fast walkability check via the precomputed blocked-cell bitmap.
    local blocked = self.blocked
    local function isWalkable(col, row)
        if col < 0 or col >= columns or row < 0 or row >= rows then
            return false
        end
        return not blocked[row * columns + col]
    end

    if not isWalkable(startCol, startRow) or not isWalkable(goalCol, goalRow) then
        return {}
    end

    local startIndex = startRow * columns + startCol
    local goalIndex = goalRow * columns + goalCol

    -- Reused scratch arrays (allocated once in World.new). A per-search id marks
    -- valid entries, so nothing needs clearing between searches.
    local searchId = self.searchId + 1
    self.searchId = searchId
    local gStamp, gCost = self.gStamp, self.gCost
    local parentStamp, parent = self.parentStamp, self.parent
    local openCosts, openIndices = self.openCosts, self.openIndices

    gStamp[startIndex] = searchId
    gCost[startIndex] = 0

    -- Binary min-heap of (fCost, cellIndex) pairs with an explicit size counter,
    -- so the arrays are reused without clearing. Ordering breaks ties on the
    -- unique cell index, keeping every search deterministic.
    local heapSize = 0
    local function heapPush(cost, index)
        heapSize = heapSize + 1
        local n = heapSize
        while n > 1 do
            local p = math.floor(n / 2)
            local pc, pi = openCosts[p], openIndices[p]
            if cost > pc or (cost == pc and index > pi) then
                break
            end
            openCosts[n], openIndices[n] = pc, pi
            n = p
        end
        openCosts[n], openIndices[n] = cost, index
    end

    local function heapPop()
        if heapSize == 0 then
            return nil
        end
        local topCost, topIndex = openCosts[1], openIndices[1]
        local lastCost, lastIndex = openCosts[heapSize], openIndices[heapSize]
        openCosts[heapSize], openIndices[heapSize] = nil, nil
        heapSize = heapSize - 1
        if heapSize == 0 then
            return topCost, topIndex
        end
        local i = 1
        while true do
            local left = i * 2
            if left > heapSize then
                break
            end
            local right = left + 1
            local child = left
            if right <= heapSize then
                local lc, li = openCosts[left], openIndices[left]
                local rc, ri = openCosts[right], openIndices[right]
                if rc < lc or (rc == lc and ri < li) then
                    child = right
                end
            end
            local cc, ci = openCosts[child], openIndices[child]
            if lastCost < cc or (lastCost == cc and lastIndex < ci) then
                break
            end
            openCosts[i], openIndices[i] = cc, ci
            i = child
        end
        openCosts[i], openIndices[i] = lastCost, lastIndex
        return topCost, topIndex
    end

    heapPush(octileDistance(startCol, startRow, goalCol, goalRow), startIndex)

    while heapSize > 0 do
        local currentCost, currentIndex = heapPop()
        local currentCol = currentIndex % columns
        local currentRow = math.floor(currentIndex / columns)

        if currentIndex == goalIndex then
            -- Reconstruct the start..goal waypoint chain from parent links.
            local path = {}
            local current = goalIndex
            while current ~= startIndex do
                local col = current % columns
                local row = math.floor(current / columns)
                table.insert(path, 1, { x = col * cellSize + cellSize / 2, y = row * cellSize + cellSize / 2 })
                current = parent[current]
            end
            table.insert(path, 1, { x = startCol * cellSize + cellSize / 2, y = startRow * cellSize + cellSize / 2 })
            return path
        end

        -- Lazy deletion: skip stale entries whose cell got a cheaper g after push.
        if currentCost <= gCost[currentIndex] + octileDistance(currentCol, currentRow, goalCol, goalRow) then
            for _, offset in ipairs(NEIGHBOR_OFFSETS) do
                local dCol, dRow, stepCost = offset[1], offset[2], offset[3]
                local nextCol = currentCol + dCol
                local nextRow = currentRow + dRow
                -- Corner-cut rule: a diagonal step also needs both adjacent
                -- orthogonal cells to be walkable.
                if isWalkable(nextCol, nextRow) and (dCol == 0 or dRow == 0
                    or (isWalkable(currentCol + dCol, currentRow) and isWalkable(currentCol, currentRow + dRow))) then
                    local nextIndex = nextRow * columns + nextCol
                    local tentativeCost = gCost[currentIndex] + stepCost
                    if gStamp[nextIndex] ~= searchId or tentativeCost < gCost[nextIndex] then
                        parent[nextIndex] = currentIndex
                        parentStamp[nextIndex] = searchId
                        gCost[nextIndex] = tentativeCost
                        gStamp[nextIndex] = searchId
                        heapPush(tentativeCost + octileDistance(nextCol, nextRow, goalCol, goalRow), nextIndex)
                    end
                end
            end
        end
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
