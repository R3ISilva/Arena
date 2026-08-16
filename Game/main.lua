-- Entry point. Modes:
--   (default) windowed multiplayer client
--   --server  dedicated server (headless when GAME_SERVER=1)
--   --test    headless test harness (prints results, exits non-zero on failure)
--   --probe   headless client connectivity probe (prints slot + exits)

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
    if hasArg(args, "--test") then
        local runTests = require("tests.run_tests")
        os.exit(runTests() and 0 or 1)
    elseif hasArg(args, "--probe") then
        local runProbe = require("tests.probe")
        os.exit(runProbe() and 0 or 1)
    end

    local config = loadConfig()

    if hasArg(args, "--server") or os.getenv("GAME_SERVER") == "1" then
        require("src.server").run(config)
    else
        require("src.client").run(config)
    end
end
