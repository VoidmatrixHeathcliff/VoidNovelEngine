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
        local trace = debug.traceback(err) sdl.SetClipboardText(trace)
        local content = string.format("引擎发生了无法处理的错误，以下报错信息已经复制到剪切板，请反馈给开发者：\n\n%s", trace)
        sdl.ShowSimpleMessageBox(sdl.MessageBoxFlags.ERROR, "致命错误", content, GlobalContext.window)
    end
    rl.CloseWindow()
    sdl.DestroyRenderer(GlobalContext.renderer)
    sdl.DestroyWindow(GlobalContext.window)
end

local status, result = xpcall(main, traceback)