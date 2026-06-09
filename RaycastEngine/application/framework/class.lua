local module = {}

local function _get_object_class(obj)
    if type(obj) ~= "table" then return nil end
    return rawget(obj, "class")
end

local function _is_subclass_of(class, target)
    local current = class
    while current do
        if current == target then
            return true
        end
        current = rawget(current, "super")
    end
    return false
end

module.is_class = function(value)
    return type(value) == "table" and rawget(value, "__is_class") == true
end

module.get_class = function(obj)
    return _get_object_class(obj)
end

module.get_class_name = function(obj)
    if type(obj) ~= "table" then return type(obj) end
    local class = _get_object_class(obj) or obj
    return rawget(class, "__name") or rawget(obj, "_metaname") or type(obj)
end

module.is_instance = function(obj, target)
    local class = _get_object_class(obj)
    if not class or not target then return false end
    return _is_subclass_of(class, target)
end

module.call_super = function(current_class, self, method_name, ...)
    if not module.is_class(current_class) then
        error("call_super expects a class as current_class")
    end

    local super = rawget(current_class, "super")
    while super do
        local method = rawget(super, method_name)
        if method then
            return method(self, ...)
        end
        super = rawget(super, "super")
    end
end

module.define = function(name, base)
    local class = {}
    class.__name = name
    class.__is_class = true
    class.super = base

    local instance_metatable =
    {
        __index = function(_, key)
            return class[key]
        end,
        __tostring = function(obj)
            local tostring_func = obj.__tostring
            if tostring_func then
                return tostring_func(obj)
            end
            return module.get_class_name(obj)
        end,
        __gc = function(obj)
            local gc_func = obj.__gc
            if gc_func then
                gc_func(obj)
            end
        end
    }

    class.__instance_metatable = instance_metatable

    setmetatable(class,
    {
        __index = base,
        __tostring = function()
            return string.format("Class<%s>", name)
        end
    })

    class.new = function(...)
        local obj = setmetatable(
        {
            class = class,
            _metaname = name,
        }, instance_metatable)
        local result = nil
        if obj.ctor then
            result = obj:ctor(...)
        elseif base and base.ctor then
            result = base.ctor(obj, ...)
        end
        if result == false then
            local gc_func = obj.__gc
            if gc_func then
                gc_func(obj)
            end
            return nil
        end
        return obj
    end

    class.get_class = function(self)
        return rawget(self, "class") or class
    end

    class.get_class_name = function(self)
        return module.get_class_name(self)
    end

    class.is_a = function(self, target)
        if not target then return false end
        local current = rawget(self, "class") or self
        return _is_subclass_of(current, target)
    end

    return class
end

return module
