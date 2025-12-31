local Application = require("application.application")
local GlobalContext = require("application.framework.global_context")

local sdl = Engine.SDL
local rl = Engine.Raylib

local function main()
    Application.init().run()
end

local function traceback(err)
    if GlobalContext.debug then
        print(debug.traceback(err))
    else
        sdl.ShowSimpleMessageBox(sdl.MessageBoxFlags.ERROR,
            "Fatal Error", debug.traceback(err), GlobalContext.window)
    end
    rl.CloseWindow()
    sdl.DestroyRenderer(GlobalContext.renderer)
    sdl.DestroyWindow(GlobalContext.window)
end

local status, result = xpcall(main, traceback)