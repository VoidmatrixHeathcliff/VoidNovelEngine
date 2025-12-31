local module = {}

local next_scene = nil
local current_scene = nil

local scene_pool = {}

module.on_update = function(delta)
    if next_scene then
        if current_scene then
            current_scene:on_exit()
        end
        current_scene = next_scene
        current_scene:on_enter()
        next_scene = nil
    end

    if not current_scene then return end
    current_scene:on_update(delta)
end

module.on_render = function()
    if not current_scene then return end
    current_scene:on_render()
end
    
module.add_scene = function(scene, id)
    scene_pool[id] = scene
end

module.switch_to = function(id)
    next_scene = scene_pool[id]
end

return module