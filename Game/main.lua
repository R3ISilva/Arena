-- Entry point. Modes:
--   (default) windowed multiplayer client
--   --server  dedicated server (headless when GAME_SERVER=1)
--   --test    headless test harness (prints results, exits non-zero on failure)
--   --probe   headless client connectivity probe (prints slot + exits)
--   --twoclient headless two-client reconciliation diagnostic (prints RTT/divergence/snaps + exits)

local json = require("json")

local function loadConfig()
    local text, readError = love.filesystem.read("config.json")
    assert(text, "Could not read config.json: " .. tostring(readError))
    return json.decode(text)
end

local function hasArg(args, name)
    for _, value in ipairs(args or {}) do
        if value == name then
            return true
        end
    end
    return false
end

function love.load(args)
    if hasArg(args, "--twoclientwin:child") then
        -- One windowed, auto-driving client. The tests/two-client-with-head-test/
        -- twoclientwin.sh launcher starts two of these and asserts the aggregate.
        require("tests.two-client-with-head-test.twoclientclient")(args)
        return
    end
    if hasArg(args, "--test") then
        local runTests = require("tests.run_tests")
        os.exit(runTests() and 0 or 1)
    elseif hasArg(args, "--probe") then
        local runProbe = require("tests.probe")
        os.exit(runProbe() and 0 or 1)
    elseif hasArg(args, "--twoclient") then
        local runTwoClient = require("tests.twoclient")
        os.exit(runTwoClient() and 0 or 1)
    elseif hasArg(args, "--twoclientwin") then
        -- The two-window diagnostic is orchestrated from the shell (it needs two
        -- GUI love.exe processes). The child mode is --twoclientwin:child.
        print("Run the two-window diagnostic via tests/two-client-with-head-test/twoclientwin.sh")
        os.exit(2)
    end

    local config = loadConfig()

    if hasArg(args, "--server") or os.getenv("GAME_SERVER") == "1" then
        require("src.server").run(config)
    else
        require("src.client").run(config)
    end
end
