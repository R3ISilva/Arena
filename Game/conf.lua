-- LÖVE configuration. For the headless dedicated server (GAME_SERVER=1) the
-- window/graphics/audio modules are disabled so it can run on a VPS with no display.

function love.conf(t)
    t.identity = "arena"
    t.window.title = "Arena"
    t.window.width = 800
    t.window.height = 600
    t.window.vsync = 1

    if os.getenv("GAME_SERVER") == "1" then
        t.modules.window = false
        t.modules.graphics = false
        t.modules.audio = false
        t.modules.sound = false
        t.modules.joystick = false
        t.modules.physics = false
    end
end
