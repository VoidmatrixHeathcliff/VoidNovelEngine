local module = {}

local GameObject = require("application.framework.game_object")

local function on_enter(self)

end

local function on_exit(self)

end

local function add_object(self, obj, id, z_idx)
    self:del_object(id)

    obj._id = id
    if z_idx then obj._z_idx = z_idx end

    self._go_pool[id] = obj
    table.insert(self._go_list, obj)
end

local function del_object(self, id)
    local obj = self._go_pool[id]
    if not obj then return end
    self._go_pool[id] = nil
    for k, v in ipairs(self._go_list) do
        if v == obj then
            table.remove(self._go_list, k)
            break
        end
    end
end

local function find_object(self, id)
    return self._go_pool[id]
end

local function on_update(self, delta)
    table.sort(self._go_list, function(obj_1, obj_2) 
        return obj_1._z_idx < obj_2._z_idx
    end)
    for _, v in ipairs(self._go_list) do
        v:on_update(delta)
    end
    for i = #self._go_list, 1, -1 do
        local obj = self._go_list[i]
        if not obj._valid then
            self._go_pool[obj._id] = nil
            table.remove(self._go_list, i)
        end
    end
end

local function on_render(self)
    for _, v in ipairs(self._go_list) do
        v:on_render()
    end
end

module.new = function()
    local o = 
    {
        _metaname = "Scene",

        _go_pool = {},
        _go_list = {},

        on_enter = on_enter,
        on_exit = on_exit,
        add_object = add_object,
        del_object = del_object,
        find_object = find_object,
        on_update = on_update,
        on_render = on_render,
    }
    setmetatable(o, GameObject.new())
    o.__index = o
    return o
end

return module