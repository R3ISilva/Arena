-- Temporary headless client connectivity probe. Connects to the configured server,
-- waits for a welcome + snapshot, and reports what it received.
-- Run via: lovec.exe . --probe

local json = require("json")
local World = require("src.world")
local Session = require("src.session")
local net = require("src.net")

local function run()
    local text = love.filesystem.read("config.json")
    local config = json.decode(text)

    local session = Session.new(World.new(config), "client", config.server)
    local adapter = net.newClient(config, session)

    local dt = 1 / config.server.tickRate
    local deadline = love.timer.getTime() + 4

    while love.timer.getTime() < deadline do
        adapter:pump()
        session:tick(dt)
        adapter:flushOutbox()
        love.timer.sleep(0.001)
    end

    local state = session:getState()
    print("connected: " .. tostring(state.connected))
    print("slot:      " .. tostring(state.slot))
    print("lastSeq:   " .. tostring(state.lastSeq))
    for slot, player in pairs(state.players) do
        print(string.format("player %s -> (%.1f, %.1f)", slot, player.x, player.y))
    end

    adapter:destroy()

    if state.connected and state.slot and state.lastSeq ~= nil then
        print("PROBE PASSED")
        return true
    end
    print("PROBE FAILED")
    return false
end

return run
