local Class = require("application.framework.class")

local GameObject = Class.define("GameObject")

function GameObject:ctor(id, z_idx)
    self._id = id or ""
    self._z_idx = z_idx or 0
    self._valid = true
    self._destroyed = false
    self._scene = nil
end

function GameObject:get_id()
    return self._id
end

function GameObject:get_scene()
    return self._scene
end

function GameObject:get_z_idx()
    return self._z_idx
end

function GameObject:set_z_idx(z_idx)
    local next_z_idx = tonumber(z_idx) or 0
    if self._z_idx == next_z_idx then
        return
    end

    self._z_idx = next_z_idx
    local scene = self._scene
    if scene and scene.mark_object_order_dirty then
        scene:mark_object_order_dirty()
    end
end

function GameObject:is_valid()
    return self._valid
end

function GameObject:is_destroyed()
    return self._destroyed
end

function GameObject:invalidate()
    self._valid = false
end

GameObject.make_invalid = GameObject.invalidate

function GameObject:on_added(scene)

end

function GameObject:on_removed(scene)

end

function GameObject:on_update(delta)

end

function GameObject:on_render()

end

function GameObject:on_destroy()

end

function GameObject:destroy()
    if self._destroyed then return end
    self._destroyed = true
    self._valid = false
    self:on_destroy()
end

function GameObject:__tostring()
    return self:get_class_name()
end

return GameObject
