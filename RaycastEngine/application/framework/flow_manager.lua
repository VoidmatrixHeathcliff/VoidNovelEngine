local module = {}

local rl = Engine.Raylib
local util = Engine.Util

local Blueprint = require("application.framework.blueprint")
local GlobalContext = require("application.framework.global_context")

local function _load_flow_form_dir(path_folder)
    local path_list = rl.LoadDirectoryFilesEx(path_folder, nil, true)
    for i = 1, path_list.count do
        local path = path_list:get(i - 1)
        local ext = string.lower(rl.GetFileExtension(path))
        if ext == ".bp" or ext == ".flow" then
            table.insert(GlobalContext.blueprint_list, 
                Blueprint.new(util.GBKToUTF8(path)))
        end
    end
    rl.UnloadDirectoryFiles(path_list)
end

module.load = function(path)
    _load_flow_form_dir("application\\flow")
    _load_flow_form_dir("application\\blueprint")
end

return module