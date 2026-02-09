local module = {}

local util = Engine.Util
local rl = Engine.Raylib
local imgui = Engine.ImGUI

local imgui_helper = require("application.framework.imgui_helper")
local resources_manager = require("application.framework.resources_manager")

module.on_enter = function()
    local path_list = rl.LoadDirectoryFilesEx("application\\style", nil, true)
    for i = 1, path_list.count do
        local path = path_list:get(i - 1)
        local ext = string.lower(rl.GetFileExtension(path))
        if ext == ".style" then
            
        end
    end
    rl.UnloadDirectoryFiles(path_list)
end

local float = imgui.Float(24)
local cstring = util.CString("font")
local color = imgui.ImColor(104, 163, 68, 255)

module.on_update = function(self, delta)
    imgui.Begin("样式设计视图")
        imgui.TextDisabled("当前版本暂不支持样式设计功能…")
    imgui.End()
end

return module