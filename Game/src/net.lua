-- Thin ENet adapter. This is the only network-aware component: it translates
-- socket events into session events and session messages into packets.
--
-- Channels: 0 = reliable/ordered (lifecycle), 1 = unreliable/sequenced (moves/snapshots).

local enet = require("enet")
local protocol = require("src.protocol")

local net = {}

local CHANNEL_COUNT = 2
local RELIABLE = "reliable"
local UNRELIABLE = "unreliable"

local function encode(message)
    return protocol.encode(message)
end

local function decode(payload)
    local ok, result = pcall(protocol.decode, payload)
    if ok then
        return result
    end
    return nil
end

local function flagForChannel(channel)
    return channel == 0 and RELIABLE or UNRELIABLE
end

----------------------------------------
-- Server adapter
----------------------------------------
local ServerAdapter = {}
ServerAdapter.__index = ServerAdapter

function net.newServer(config, session)
    local self = setmetatable({}, ServerAdapter)
    self.session = session

    local server = config.server
    local peerCount = (server.spectatorLimit or 32) + 2
    local bindAddress = "0.0.0.0:" .. tostring(server.port)

    self.host = enet.host_create(bindAddress, peerCount, CHANNEL_COUNT, 0, 0)
    assert(self.host, "failed to create ENet server host on " .. bindAddress)

    self.peerById = {}
    self.idByPeer = setmetatable({}, { __mode = "k" })
    self.nextId = 1
    return self
end

function ServerAdapter:pump()
    while true do
        local event = self.host:service(0)
        if not event then
            break
        end

        if event.type == "connect" then
            local id = self.nextId
            self.nextId = self.nextId + 1
            self.peerById[id] = event.peer
            self.idByPeer[event.peer] = id

            if not self.session:onConnect(id) then
                -- Over spectator cap: disconnect gracefully so the client sees it.
                self.peerById[id] = nil
                self.idByPeer[event.peer] = nil
                event.peer:disconnect(0)
            end
        elseif event.type == "receive" then
            local id = self.idByPeer[event.peer]
            if id then
                local message = decode(event.data)
                if message then
                    self.session:onMessage(id, message)
                end
            end
        elseif event.type == "disconnect" then
            local id = self.idByPeer[event.peer]
            if id then
                self.session:onDisconnect(id)
                self.peerById[id] = nil
                self.idByPeer[event.peer] = nil
            end
        end
    end
end

function ServerAdapter:flushOutbox()
    for _, entry in ipairs(self.session:drainOutbox()) do
        local payload = encode(entry.message)
        local flag = flagForChannel(entry.channel)
        if entry.to == "*" then
            self.host:broadcast(payload, entry.channel, flag)
        else
            local peer = self.peerById[entry.to]
            if peer then
                peer:send(payload, entry.channel, flag)
            end
        end
    end
    self.host:flush()
end

function ServerAdapter:destroy()
    if self.host then
        self.host:destroy()
        self.host = nil
    end
end

----------------------------------------
-- Client adapter
----------------------------------------
local ClientAdapter = {}
ClientAdapter.__index = ClientAdapter

function net.newClient(config, session)
    local self = setmetatable({}, ClientAdapter)
    self.session = session

    self.host = enet.host_create(nil, 1, CHANNEL_COUNT, 0, 0)
    assert(self.host, "failed to create ENet client host")

    local server = config.server
    local address = tostring(server.address) .. ":" .. tostring(server.port)
    self.serverPeer = self.host:connect(address, CHANNEL_COUNT, 0)
    assert(self.serverPeer, "failed to connect to server at " .. address)

    self.connected = false
    return self
end

function ClientAdapter:pump()
    while true do
        local event = self.host:service(0)
        if not event then
            break
        end

        if event.type == "connect" then
            self.connected = true
            self.session:onConnect("server")
        elseif event.type == "receive" then
            local message = decode(event.data)
            if message then
                self.session:onMessage("server", message)
            end
        elseif event.type == "disconnect" then
            self.connected = false
            self.session:onDisconnect("server")
        end
    end

    -- Feed the smoothed RTT (ms -> s) so reconciliation can scale its threshold
    -- with latency instead of using a fixed pixel distance.
    if self.serverPeer then
        local rtt = self.serverPeer:round_trip_time()
        if rtt then
            self.session:setLatency(rtt / 1000)
        end
    end
end

function ClientAdapter:flushOutbox()
    for _, entry in ipairs(self.session:drainOutbox()) do
        if entry.to == "server" and self.serverPeer then
            local payload = encode(entry.message)
            local flag = flagForChannel(entry.channel)
            self.serverPeer:send(payload, entry.channel, flag)
        end
    end
    self.host:flush()
end

function ClientAdapter:isConnected()
    return self.connected
end

function ClientAdapter:destroy()
    if self.host then
        if self.serverPeer then
            -- Graceful disconnect so the server frees the slot immediately instead
            -- of waiting for the ENet peer timeout after an abrupt socket close.
            self.serverPeer:disconnect(0)
            self.host:flush()
            for _ = 1, 64 do
                local event = self.host:service(0)
                if not event then
                    break
                end
                if event.type == "disconnect" then
                    break
                end
            end
        end
        self.host:destroy()
    end
    self.host = nil
    self.serverPeer = nil
end

net.ServerAdapter = ServerAdapter
net.ClientAdapter = ClientAdapter
return net
