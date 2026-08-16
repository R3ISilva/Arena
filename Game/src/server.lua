-- Dedicated authoritative server. Runs the shared world/session on a fixed
-- timestep and pumps ENet events every frame. Headless when GAME_SERVER=1
-- (graphics/window modules disabled via conf.lua).

local World = require("src.world")
local Session = require("src.session")
local net = require("src.net")

local server = {}

function server.run(config)
    -- Flush prints immediately so `docker logs` shows output without waiting for
    -- the process buffer to fill (stdout is fully buffered when piped).
    io.stdout:setvbuf("line")
    io.stderr:setvbuf("line")

    local world = World.new(config)
    local session = Session.new(world, "server", config.server)
    local adapter = net.newServer(config, session)

    local fixedDt = 1 / config.server.tickRate
    local accumulator = 0

    function love.update(dt)
        adapter:pump()

        accumulator = accumulator + dt
        while accumulator >= fixedDt do
            session:tick(fixedDt)
            accumulator = accumulator - fixedDt
        end

        adapter:flushOutbox()
    end

    function love.quit()
        adapter:destroy()
    end

    print(string.format("[server] listening on 0.0.0.0:%d (tickRate=%d snapshotRate=%d)",
        config.server.port, config.server.tickRate, config.server.snapshotRate))
end

return server
