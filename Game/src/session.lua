-- Transport-agnostic game session. This is the single seam between the network
-- adapter and the simulation: it consumes connection lifecycle events, inbound
-- messages, and fixed timestep ticks, and produces authoritative state plus a
-- queue of outbound messages.
--
-- Two modes:
--   * "server"  — authoritative simulation for all connected peers.
--   * "client"  — client-side prediction for the local player, interpolation for
--                 remote players, and reconciliation against server snapshots.
--
-- The adapter (or a test harness) drives it through:
--   session:onConnect(peerId)
--   session:onDisconnect(peerId)
--   session:onMessage(peerId, message)
--   session:tick(dt)
--
-- and reads results via session:getState() and session:drainOutbox().

local Session = {}
Session.__index = Session

local SLOTS = { "player1", "player2" }
local INTERPOLATION_DELAY = 0.1 -- render remote players ~100ms behind the newest snapshot

function Session.new(world, mode, netConfig)
    local self = setmetatable({}, Session)
    self.world = world
    self.mode = mode
    self.netConfig = netConfig
    self.outbox = {}

    if mode == "server" then
        self.slots = { player1 = nil, player2 = nil }
        self.peers = {}       -- peerId -> { slot = "player1" | "player2" | "spectator" }
        self.players = {}     -- slot -> { x, y, path } (authoritative)
        self.spectatorCount = 0
        self.seq = 0
        self.tickCount = 0
        local every = netConfig.tickRate / netConfig.snapshotRate
        self.snapshotEvery = math.max(1, math.floor(every + 0.5))
    elseif mode == "client" then
        self.connected = false
        self.slot = nil
        self.time = 0
        self.localPlayer = nil
        self.localTarget = nil
        self.remoteBuffers = {}   -- slot -> array of { time, x, y }
        self.remoteRendered = {}  -- slot -> { x, y }
        self.lastSeq = nil
    else
        error("unknown session mode: " .. tostring(mode))
    end

    return self
end

----------------------------------------
-- Connection lifecycle
----------------------------------------
function Session:onConnect(peerId)
    if self.mode == "server" then
        if self.peers[peerId] then
            return true -- already connected
        end

        local slot
        if self.slots.player1 == nil then
            slot = "player1"
        elseif self.slots.player2 == nil then
            slot = "player2"
        end

        if slot then
            self.slots[slot] = peerId
            self.peers[peerId] = { slot = slot }
            local spawnIndex = (slot == "player1") and 1 or 2
            local spawn = self.world.spawnPoints[spawnIndex]
            self.players[slot] = { x = spawn.x, y = spawn.y, path = {} }
            self:enqueue(peerId, 0, { type = "welcome", slot = slot })
            return true
        end

        -- No free player slot: admit as spectator up to the configured cap.
        if self.spectatorCount >= (self.netConfig.spectatorLimit or 32) then
            return false
        end
        self.spectatorCount = self.spectatorCount + 1
        self.peers[peerId] = { slot = "spectator" }
        self:enqueue(peerId, 0, { type = "welcome", slot = "spectator" })
        return true
    end

    self.connected = true
    return true
end

function Session:onDisconnect(peerId)
    if self.mode == "server" then
        local entry = self.peers[peerId]
        if not entry then
            return
        end
        self.peers[peerId] = nil
        if entry.slot == "spectator" then
            self.spectatorCount = math.max(0, self.spectatorCount - 1)
        else
            self.slots[entry.slot] = nil
            self.players[entry.slot] = nil
        end
        return
    end

    self.connected = false
    self.slot = nil
    self.localPlayer = nil
    self.localTarget = nil
    self.remoteBuffers = {}
    self.remoteRendered = {}
end

----------------------------------------
-- Inbound messages
----------------------------------------
function Session:onMessage(peerId, message)
    if self.mode == "server" then
        if message.type == "moveIntent" then
            local entry = self.peers[peerId]
            if not entry or entry.slot == "spectator" then
                return
            end
            if self.slots[entry.slot] ~= peerId then
                return
            end
            local x, y = message.x, message.y
            if type(x) ~= "number" or type(y) ~= "number" then
                return
            end
            x = math.max(0, math.min(self.world.windowWidth, x))
            y = math.max(0, math.min(self.world.windowHeight, y))

            local player = self.players[entry.slot]
            player.path = self.world:findPath(player.x, player.y, x, y)
        end
        return
    end

    if message.type == "welcome" then
        self.slot = message.slot
        if message.slot == "player1" or message.slot == "player2" then
            local spawnIndex = (message.slot == "player1") and 1 or 2
            local spawn = self.world.spawnPoints[spawnIndex]
            self.localPlayer = { x = spawn.x, y = spawn.y, path = {} }
            self.localTarget = nil
        else
            self.localPlayer = nil
            self.localTarget = nil
        end
    elseif message.type == "snapshot" then
        self:applySnapshot(message)
    end
end

-- Local input: compute the predicted path and queue a move intent to the server.
function Session:localMoveIntent(x, y)
    if self.mode ~= "client" then
        return
    end
    if self.slot ~= "player1" and self.slot ~= "player2" then
        return
    end
    if not self.localPlayer then
        return
    end

    x = math.max(0, math.min(self.world.windowWidth, x))
    y = math.max(0, math.min(self.world.windowHeight, y))

    self.localTarget = { x = x, y = y }
    self.localPlayer.path = self.world:findPath(self.localPlayer.x, self.localPlayer.y, x, y)
    self:enqueue("server", 1, { type = "moveIntent", x = x, y = y })
end

function Session:applySnapshot(message)
    self.lastSeq = message.seq
    local now = self.time

    for _, entry in ipairs(message.players or {}) do
        if entry.slot == self.slot and self.localPlayer then
            self:reconcile(entry.x, entry.y)
        else
            local buffer = self.remoteBuffers[entry.slot]
            if not buffer then
                buffer = {}
                self.remoteBuffers[entry.slot] = buffer
            end
            table.insert(buffer, { time = now, x = entry.x, y = entry.y })
            if #buffer > 60 then
                table.remove(buffer, 1)
            end
        end
    end
end

-- Snap the predicted position to the authoritative one when they diverge, then
-- re-path toward the current target so movement continues seamlessly. A dropped
-- move intent is healed by re-sending it (move intents ride the unreliable channel).
-- The threshold tolerates normal latency-induced lag (prediction ahead of authority)
-- while still catching real drift from lost intents.
function Session:reconcile(authX, authY)
    local localPlayer = self.localPlayer
    local dx = localPlayer.x - authX
    local dy = localPlayer.y - authY
    local threshold = math.max(4, self.world.walkSpeed * 0.25)

    if dx * dx + dy * dy <= threshold * threshold then
        return
    end

    localPlayer.x, localPlayer.y = authX, authY
    if self.localTarget then
        localPlayer.path = self.world:findPath(localPlayer.x, localPlayer.y, self.localTarget.x, self.localTarget.y)
        self:enqueue("server", 1, { type = "moveIntent", x = self.localTarget.x, y = self.localTarget.y })
    else
        localPlayer.path = {}
    end
end

----------------------------------------
-- Simulation step
----------------------------------------
function Session:tick(dt)
    if self.mode == "server" then
        for _, player in pairs(self.players) do
            self.world:stepPlayer(player, dt)
        end

        self.tickCount = self.tickCount + 1
        if self.tickCount % self.snapshotEvery == 0 then
            self:emitSnapshot()
        end
        return
    end

    self.time = self.time + dt
    if self.localPlayer then
        self.world:stepPlayer(self.localPlayer, dt)
    end
    self:updateInterpolation()
end

function Session:emitSnapshot()
    local players = {}
    for _, slot in ipairs(SLOTS) do
        local player = self.players[slot]
        if player then
            table.insert(players, { slot = slot, x = player.x, y = player.y })
        end
    end

    self:enqueue("*", 1, { type = "snapshot", seq = self.seq, players = players })
    self.seq = self.seq + 1
end

function Session:updateInterpolation()
    local targetTime = self.time - INTERPOLATION_DELAY

    for slot, buffer in pairs(self.remoteBuffers) do
        if #buffer == 0 then
            self.remoteRendered[slot] = nil
        elseif #buffer == 1 or targetTime <= buffer[1].time then
            self.remoteRendered[slot] = { x = buffer[1].x, y = buffer[1].y }
        elseif targetTime >= buffer[#buffer].time then
            self.remoteRendered[slot] = { x = buffer[#buffer].x, y = buffer[#buffer].y }
        else
            for i = 1, #buffer - 1 do
                local a, b = buffer[i], buffer[i + 1]
                if targetTime >= a.time and targetTime <= b.time then
                    local span = math.max(b.time - a.time, 0.000001)
                    local fraction = (targetTime - a.time) / span
                    self.remoteRendered[slot] = {
                        x = a.x + (b.x - a.x) * fraction,
                        y = a.y + (b.y - a.y) * fraction,
                    }
                    break
                end
            end
        end
    end
end

----------------------------------------
-- Outbound messages
----------------------------------------
function Session:enqueue(to, channel, message)
    table.insert(self.outbox, { to = to, channel = channel, message = message })
end

function Session:drainOutbox()
    local outbox = self.outbox
    self.outbox = {}
    return outbox
end

----------------------------------------
-- State accessors
----------------------------------------
function Session:getState()
    local players = {}
    if self.mode == "server" then
        for _, slot in ipairs(SLOTS) do
            local player = self.players[slot]
            if player then
                players[slot] = { x = player.x, y = player.y }
            end
        end
        return { mode = "server", players = players, seq = self.seq }
    end

    for _, slot in ipairs(SLOTS) do
        if slot == self.slot and self.localPlayer then
            players[slot] = { x = self.localPlayer.x, y = self.localPlayer.y }
        elseif self.remoteRendered[slot] then
            players[slot] = self.remoteRendered[slot]
        end
    end

    return {
        mode = "client",
        slot = self.slot,
        connected = self.connected,
        players = players,
        lastSeq = self.lastSeq,
    }
end

function Session:getSlot()
    return self.slot
end

function Session:isPlayer()
    return self.slot == "player1" or self.slot == "player2"
end

function Session:getLocalPath()
    if self.localPlayer then
        return self.localPlayer.path
    end
    return {}
end

return Session
