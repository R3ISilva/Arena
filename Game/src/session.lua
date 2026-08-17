-- Transport-agnostic game session. This is the single seam between the network
-- adapter and the simulation: it consumes connection lifecycle events, inbound
-- messages, and fixed timestep ticks, and produces authoritative state plus a
-- queue of outbound messages.
--
-- The simulation itself lives in src/game.lua (pure, network-agnostic). The
-- session delegates all player state, movement, pathfinding, and ticking to a
-- Game instance and only translates network I/O to/from game commands.
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

function Session.new(game, mode, netConfig)
    local self = setmetatable({}, Session)
    self.game = game
    self.mode = mode
    self.netConfig = netConfig
    self.outbox = {}

    if mode == "server" then
        self.slots = { player1 = nil, player2 = nil }
        self.peers = {}       -- peerId -> { slot = "player1" | "player2" | "spectator" }
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
        self.remoteBuffers = {}   -- slot -> array of { time, x, y }
        self.remoteRendered = {}  -- slot -> { x, y }
        self.lastSeq = nil
        self.latency = 0          -- smoothed RTT in seconds, fed by the adapter
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
            self.game:spawnPlayer(slot)
            self:enqueue(peerId, 0, {
                type = "welcome",
                slot = slot,
                loadout = self.game:getLoadout(slot),
            })
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
            self.game:removePlayer(entry.slot)
        end
        return
    end

    self.connected = false
    self.slot = nil
    self.localPlayer = nil
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
            -- setTarget clamps to the arena and computes the authoritative path.
            self.game:setTarget(entry.slot, x, y)
        elseif message.type == "castIntent" then
            local entry = self.peers[peerId]
            if not entry or entry.slot == "spectator" then
                return
            end
            if self.slots[entry.slot] ~= peerId then
                return
            end
            local slot = message.slot
            if slot ~= "q" and slot ~= "w" and slot ~= "e" then
                return
            end
            local x, y = message.x, message.y
            if type(x) ~= "number" or type(y) ~= "number" then
                return
            end
            -- castAbility resolves the loadout slot, enforces the cooldown, and
            -- re-clamps the target to the ability's range authoritatively.
            self.game:castAbility(entry.slot, slot, x, y)
        end
        return
    end

    if message.type == "welcome" then
        self.slot = message.slot
        if message.slot == "player1" or message.slot == "player2" then
            self.game:spawnPlayer(message.slot)
            if message.loadout then
                self.game:setLoadout(message.slot, message.loadout)
            end
            self.localPlayer = self.game:getPlayerRef(message.slot)
        else
            self.localPlayer = nil
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

    local cx, cy = self.game:setTarget(self.slot, x, y)
    self:enqueue("server", 1, { type = "moveIntent", x = cx, y = cy })
end

-- Local cast input: predict the cast (deterministically clamped), start the local
-- cooldown + spawn the local pool immediately, and queue a cast intent to the
-- server. The authoritative snapshot reconciles pool/health/cooldown state.
function Session:localCastIntent(slot, x, y)
    if self.mode ~= "client" then
        return
    end
    if self.slot ~= "player1" and self.slot ~= "player2" then
        return
    end
    if not self.localPlayer then
        return
    end

    local cx, cy = self.game:castAbility(self.slot, slot, x, y)
    if not cx then
        return
    end
    self:enqueue("server", 1, { type = "castIntent", slot = slot, x = cx, y = cy })
    return cx, cy
end

function Session:applySnapshot(message)
    self.lastSeq = message.seq
    local now = self.time

    for _, entry in ipairs(message.players or {}) do
        if entry.slot == self.slot and self.localPlayer then
            self:reconcile(entry.x, entry.y)
            self.game:setHealth(entry.slot, entry.hp)
            if entry.cooldowns then
                self.game:setCooldowns(entry.slot, entry.cooldowns)
            end
        else
            local buffer = self.remoteBuffers[entry.slot]
            if not buffer then
                buffer = {}
                self.remoteBuffers[entry.slot] = buffer
            end
            table.insert(buffer, { time = now, x = entry.x, y = entry.y, hp = entry.hp })
            if #buffer > 60 then
                table.remove(buffer, 1)
            end
        end
    end

    self.game:applySnapshotPools(message.pools)
end

-- Snap the predicted position to the authoritative one when they diverge, then
-- re-path toward the current target so movement continues seamlessly. A dropped
-- move intent is healed by re-sending it (move intents ride the unreliable channel).
-- The threshold scales with RTT: normal prediction leads the authority by roughly
-- walkSpeed x latency, so the tolerance is walkSpeed x latency x 2, with a
-- walkSpeed x 0.1 floor that still catches real drift (lost intents) at low latency.
function Session:reconcile(authX, authY)
    local localPlayer = self.localPlayer
    local dx = localPlayer.x - authX
    local dy = localPlayer.y - authY
    local walkSpeed = self.game.walkSpeed
    local threshold = math.max(walkSpeed * 0.1, walkSpeed * (self.latency or 0) * 2)

    if dx * dx + dy * dy <= threshold * threshold then
        return
    end

    self.game:setPosition(self.slot, authX, authY)
    local target = self.game:getTarget(self.slot)
    if target then
        self.game:setTarget(self.slot, target.x, target.y)
        self:enqueue("server", 1, { type = "moveIntent", x = target.x, y = target.y })
    else
        self.game:clearTarget(self.slot)
    end
end

-- Feed the smoothed round-trip time (seconds) from the transport layer. Used only
-- by the client to size the reconciliation threshold so normal prediction lag is
-- tolerated while real drift from lost move intents is still corrected.
function Session:setLatency(seconds)
    self.latency = seconds or 0
end

----------------------------------------
-- Simulation step
----------------------------------------
function Session:tick(dt)
    if self.mode == "server" then
        self.game:tick(dt)

        self.tickCount = self.tickCount + 1
        if self.tickCount % self.snapshotEvery == 0 then
            self:emitSnapshot()
        end
        return
    end

    self.time = self.time + dt
    if self.localPlayer then
        self.game:tick(dt)
    end
    self:updateInterpolation()
end

function Session:emitSnapshot()
    local players = {}
    for _, slot in ipairs(SLOTS) do
        local position = self.game:getPlayer(slot)
        if position then
            local cooldowns = self.game:getCooldowns(slot)
            table.insert(players, {
                slot = slot,
                x = position.x,
                y = position.y,
                hp = position.hp,
                cooldowns = cooldowns and { q = cooldowns.q, w = cooldowns.w, e = cooldowns.e } or nil,
            })
        end
    end

    self:enqueue("*", 1, {
        type = "snapshot",
        seq = self.seq,
        players = players,
        pools = self.game:getPoolsSnapshot(),
    })
    self.seq = self.seq + 1
end

function Session:updateInterpolation()
    local targetTime = self.time - INTERPOLATION_DELAY

    for slot, buffer in pairs(self.remoteBuffers) do
        if #buffer == 0 then
            self.remoteRendered[slot] = nil
        else
            local hp = buffer[#buffer].hp
            if #buffer == 1 or targetTime <= buffer[1].time then
                self.remoteRendered[slot] = { x = buffer[1].x, y = buffer[1].y, hp = hp }
            elseif targetTime >= buffer[#buffer].time then
                self.remoteRendered[slot] = { x = buffer[#buffer].x, y = buffer[#buffer].y, hp = hp }
            else
                for i = 1, #buffer - 1 do
                    local a, b = buffer[i], buffer[i + 1]
                    if targetTime >= a.time and targetTime <= b.time then
                        local span = math.max(b.time - a.time, 0.000001)
                        local fraction = (targetTime - a.time) / span
                        self.remoteRendered[slot] = {
                            x = a.x + (b.x - a.x) * fraction,
                            y = a.y + (b.y - a.y) * fraction,
                            hp = hp,
                        }
                        break
                    end
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
    if self.mode == "server" then
        return {
            mode = "server",
            players = self.game:getPlayers(),
            pools = self.game:getPoolsSnapshot(),
            seq = self.seq,
        }
    end

    local players = {}
    for _, slot in ipairs(SLOTS) do
        if slot == self.slot and self.localPlayer then
            players[slot] = self.game:getPlayer(slot)
        elseif self.remoteRendered[slot] then
            players[slot] = self.remoteRendered[slot]
        end
    end

    local loadout, cooldowns, health
    if self.slot == "player1" or self.slot == "player2" then
        loadout = self.game:getLoadout(self.slot)
        cooldowns = self.game:getCooldowns(self.slot)
        health = self.game:getHealth(self.slot)
    end

    return {
        mode = "client",
        slot = self.slot,
        connected = self.connected,
        players = players,
        pools = self.game:getPoolsSnapshot(),
        loadout = loadout,
        cooldowns = cooldowns,
        health = health,
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
