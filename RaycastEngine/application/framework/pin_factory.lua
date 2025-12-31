local module = {}

local sdl = Engine.SDL
local util = Engine.Util
local imgui = Engine.ImGUI

local LogManager = require("application.framework.log_manager")
local ColorHelper = require("application.framework.color_helper")
local UndoManager = require("application.framework.undo_manager")
local GlobalContext = require("application.framework.global_context")
local ResourcesManager = require("application.framework.resources_manager")

local construct_func_pool = {}

-- 图标大小
local size_icon <const> = imgui.ImVec2(24, 24)

local type_color_pool <const> = 
{
    ["flow"] = imgui.ImVec4(imgui.ImColor(255, 255, 255, 255).value),
    ["object"] = imgui.ImVec4(imgui.ImColor(255, 255, 255, 255).value),
    ["vector2"] = ColorHelper.ValueTypeColorPool.vector2,
    ["color"] = ColorHelper.ValueTypeColorPool.color,
    ["string"] = ColorHelper.ValueTypeColorPool.string,
    ["int"] = ColorHelper.ValueTypeColorPool.int,
    ["float"] = ColorHelper.ValueTypeColorPool.float,
    ["bool"] = ColorHelper.ValueTypeColorPool.bool,
    ["font"] = ColorHelper.AssetTypeColorPool.font,
    ["audio"] = ColorHelper.AssetTypeColorPool.audio,
    ["shader"] = ColorHelper.AssetTypeColorPool.shader,
    ["texture"] = ColorHelper.AssetTypeColorPool.texture,
}

local function _base_load(pin, data)
    
end

local function _base_save(pin)
    local data = 
    {
        id = pin._id:get(),
        type_id = pin._type_id,
        is_output = pin._is_output,
        name = pin._name,
    }
    return data
end

local metatable = 
{
    __index =
    {
        on_update = function(self)
            local kind = imgui.NodeEditor.PinKind.Input if self._is_output then kind = imgui.NodeEditor.PinKind.Output end
            if self._is_output then
                if self._on_tick_widgets then imgui.BeginGroup() self:_on_tick_widgets() imgui.EndGroup() imgui.SameLine() end
                if self._name then imgui.Text(self._name) end
                if self._on_tick_widgets or self._name then imgui.SameLine() end
                imgui.NodeEditor.BeginPin(self._id, kind)
                    imgui.NodeEditor.Icon(size_icon, self._icon_type, self._linked_pin_id, self._color)
                imgui.NodeEditor.EndPin()
            else
                imgui.NodeEditor.BeginPin(self._id, kind)
                    imgui.NodeEditor.Icon(size_icon, self._icon_type, self._linked_pin_id, self._color)
                imgui.NodeEditor.EndPin()
                if self._on_tick_widgets or self._name then imgui.SameLine() end
                if self._on_tick_widgets then imgui.BeginGroup() self:_on_tick_widgets() imgui.EndGroup() imgui.SameLine() end
                if self._name then imgui.Text(self._name) end
            end
        end,
        on_load = function(self, data) return _base_load(self, data) end,
        on_save = function(self) return _base_save(self) end,
        set_val = function(self, val) end, get_val = function(self) end,
    }
}

local function _base_constructor(id, owner_id, is_output, type_id, icon_type, name)
    local o = 
    {
        _id = imgui.NodeEditor.PinId(id),
        _owner_id = owner_id,   -- 由于节点id会先于引脚id创建，所以此处已经是imgui.NodeId类型
        _linked_pin_id = nil,
        _type_id = type_id,
        _is_output = is_output,
        _icon_type = icon_type,
        _name = name,
        _on_tick_widgets = nil,
        _color = type_color_pool[type_id]
    }
    setmetatable(o, metatable)
    return o
end

construct_func_pool["flow"] = function(id, owner_id, is_output, name)
    return _base_constructor(id, owner_id, is_output, "flow", imgui.NodeEditor.IconType.Flow, name)
end

construct_func_pool["object"] = function(id, owner_id, is_output, name)
    local pin = _base_constructor(id, owner_id, is_output, "object", imgui.NodeEditor.IconType.Circle, name or "对象")
    pin.set_val = function(self, val)
        self._val = val
    end
    pin.get_val = function(self)
        if self._is_output then return self._val end
        if self._linked_pin_id then
            return GlobalContext.runtime_find_pin(self._linked_pin_id:get()):get_val()
        end
        return self._val
    end
    return pin
end

construct_func_pool["vector2"] = function(id, owner_id, is_output, name, extra_args)
    local pin = _base_constructor(id, owner_id, is_output, "vector2", imgui.NodeEditor.IconType.Circle, name or "二维向量")
    pin._val = imgui.ImVec2(0, 0)
    pin._prev_val = imgui.ImVec2(pin._val)
    pin._width_input = 50 if extra_args then pin._width_input = extra_args.width_input or pin._width_input end
    pin._can_edit = true if extra_args and extra_args.can_edit ~= nil then pin._can_edit = extra_args.can_edit end
    if pin._can_edit then
        pin._on_tick_widgets = function(self)
            imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
                imgui.SetNextItemWidth(self._width_input)
                imgui.InputFloat2("##vector2"..id, self._val, nil, nil)
                if imgui.IsItemDeactivatedAfterEdit() then
                    UndoManager.record(function(data) 
                            pin._val = data.old
                            pin._prev_val = imgui.ImVec2(pin._val)
                        end, function(data) 
                            pin._val = data.new
                            pin._prev_val = imgui.ImVec2(pin._val)
                        end, {old = imgui.ImVec2(pin._prev_val), new = imgui.ImVec2(pin._val)})
                    pin._prev_val = imgui.ImVec2(pin._val)
                end
            imgui.EndDisabled()
        end
    end
    pin.on_load = function(self, data) 
        _base_load(self, data)
        self._val.x = data.val.x
        self._val.y = data.val.y
        self._prev_val = imgui.ImVec2(self._val)
    end
    pin.on_save = function(self)
        local data = _base_save(self)
        data.val =  {x = self._val.x, y = self._val.y}
        return data
    end
    pin.set_val = function(self, val)
        self._val = imgui.ImVec2(val)
        self._prev_val = imgui.ImVec2(self._val)
    end
    pin.get_val = function(self)
        if self._is_output then
            return self._val
        end
        if self._linked_pin_id then
            return GlobalContext.runtime_find_pin(self._linked_pin_id:get()):get_val()
        end
        return self._val
    end
    return pin
end

construct_func_pool["color"] = function(id, owner_id, is_output, name, extra_args)
    local pin = _base_constructor(id, owner_id, is_output, "color", imgui.NodeEditor.IconType.Circle, name or "颜色")
    pin._val_color = imgui.ImColor(0, 0, 0, 255)
    pin._prev_color = imgui.ImColor(pin._val_color)
    pin._full_edit = false if extra_args then pin._full_edit = extra_args.full_edit or pin._full_edit end
    pin._on_tick_widgets = function(self)
        imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
            local flag = imgui.ColorEditFlags.NoTooltip | imgui.ColorEditFlags.NoOptions | imgui.ColorEditFlags.NoPicker | imgui.ColorEditFlags.AlphaBar
            if not self._full_edit then 
                imgui.SetNextItemWidth(132)
                imgui.ColorEdit4("##color"..id, self._val_color, flag)
            else
                imgui.SetNextItemWidth(200)
                imgui.ColorPicker4("##color"..id, self._val_color, flag)
            end
            if imgui.IsItemDeactivatedAfterEdit() then
                UndoManager.record(function(data) 
                        pin._val_color = data.old
                        pin._prev_color = imgui.ImColor(pin._val_color)
                    end, function(data) 
                        pin._val_color = data.new
                        pin._prev_color = imgui.ImColor(pin._val_color)
                    end, {old = imgui.ImColor(pin._prev_color), new = imgui.ImColor(pin._val_color)})
                pin._prev_color = imgui.ImColor(pin._val_color)
            end
        imgui.EndDisabled()
    end
    pin.on_load = function(self, data) 
        _base_load(self, data)
        self._val_color.value.x = data.val.r
        self._val_color.value.y = data.val.g
        self._val_color.value.z = data.val.b
        self._val_color.value.w = data.val.a
        self._prev_color = imgui.ImColor(self._val_color)
    end
    pin.on_save = function(self)
        local data = _base_save(self)
        data.val = 
        {
            r = pin._val_color.value.x, g = pin._val_color.value.y, 
            b = pin._val_color.value.z, a = pin._val_color.value.w
        }
        return data
    end
    pin.set_val = function(self, val)
        self._val_color = imgui.ImColor(val)
        self._prev_color = imgui.ImColor(self._val_color)
    end
    pin.get_val = function(self)
        if self._is_output then
            return self._val_color.value
        end
        if self._linked_pin_id then
            return GlobalContext.runtime_find_pin(self._linked_pin_id:get()):get_val()
        end
        return self._val_color.value
    end
    return pin
end

construct_func_pool["string"] = function(id, owner_id, is_output, name, extra_args)
    local pin = _base_constructor(id, owner_id, is_output, "string", imgui.NodeEditor.IconType.Circle, name or "字符串")
    pin._cstring = util.CString()
    pin._prev_text = pin._cstring:get()
    pin._width_input = 50 if extra_args then pin._width_input = extra_args.width_input or pin._width_input end
    pin._on_tick_widgets = function(self)
        imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
            imgui.SetNextItemWidth(self._width_input)
            imgui.InputText("##string"..id, self._cstring)
            if imgui.IsItemDeactivatedAfterEdit() then
                UndoManager.record(function(data) 
                        pin._cstring:set(data.old) 
                        pin._prev_text = data.old
                    end, function(data) 
                        pin._cstring:set(data.new) 
                        pin._prev_text = data.new
                    end, {old = pin._prev_text, new = pin._cstring:get()})
                pin._prev_text = pin._cstring:get()
            end
        imgui.EndDisabled()
    end
    pin.on_load = function(self, data) 
        _base_load(self, data)
        self._cstring:set(data.val)
        self._prev_text = data.val
    end
    pin.on_save = function(self)
        local data = _base_save(self)
        data.val = self._cstring:get()
        return data
    end
    pin.set_val = function(self, val)
        self._cstring:set(val)
        self._prev_val = val
    end
    pin.get_val = function(self)
        if self._is_output then
            return self._cstring:get()
        end
        if self._linked_pin_id then
            return GlobalContext.runtime_find_pin(self._linked_pin_id:get()):get_val()
        end
        return self._cstring:get()
    end
    return pin
end

construct_func_pool["int"] = function(id, owner_id, is_output, name, extra_args)
    local pin = _base_constructor(id, owner_id, is_output, "int", imgui.NodeEditor.IconType.Circle, name or "整数")
    pin._int = imgui.Int(0)
    pin._prev_val = pin._int.val
    pin._width_input = 100 if extra_args then pin._width_input = extra_args.width_input or pin._width_input end
    pin._can_edit = true if extra_args and extra_args.can_edit ~= nil then pin._can_edit = extra_args.can_edit end
    if pin._can_edit then
        pin._on_tick_widgets = function(self)
            imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
                imgui.SetNextItemWidth(self._width_input)
                imgui.InputInt("##int"..id, self._int)
                if imgui.IsItemDeactivatedAfterEdit() then
                    UndoManager.record(function(data) 
                            pin._int.val = data.old
                            pin._prev_val = data.old
                        end, function(data) 
                            pin._int.val = data.new
                            pin._prev_val = data.new
                        end, {old = pin._prev_val, new = pin._int.val})
                    pin._prev_val = pin._int.val
                end
            imgui.EndDisabled()
        end
    end
    pin.on_load = function(self, data) 
        _base_load(self, data)
        self._int.val = data.val
        self._prev_val = data.val
    end
    pin.on_save = function(self)
        local data = _base_save(self)
        data.val = self._int.val
        return data
    end
    pin.set_val = function(self, val)
        self._int.val = val
        self._prev_val = val
    end
    pin.get_val = function(self)
        if self._is_output then
            return self._int.val
        end
        if self._linked_pin_id then
            return GlobalContext.runtime_find_pin(self._linked_pin_id:get()):get_val()
        end
        return self._int.val
    end
    return pin
end

construct_func_pool["float"] = function(id, owner_id, is_output, name, extra_args)
    local pin = _base_constructor(id, owner_id, is_output, "float", imgui.NodeEditor.IconType.Circle, name or "浮点数")
    pin._float = imgui.Float(0)
    pin._prev_val = pin._float.val
    pin._width_input = 50 if extra_args then pin._width_input = extra_args.width_input or pin._width_input end
    pin._can_edit = true if extra_args and extra_args.can_edit ~= nil then pin._can_edit = extra_args.can_edit end
    if pin._can_edit then
        pin._on_tick_widgets = function(self)
            imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
                imgui.SetNextItemWidth(self._width_input)
                imgui.InputFloat("##float"..id, self._float)
                if imgui.IsItemDeactivatedAfterEdit() then
                    UndoManager.record(function(data) 
                            pin._float.val = data.old
                            pin._prev_val = data.old
                        end, function(data) 
                            pin._float.val = data.new
                            pin._prev_val = data.new
                        end, {old = pin._prev_val, new = pin._float.val})
                    pin._prev_val = pin._float.val
                end
            imgui.EndDisabled()
        end
    end
    pin.on_load = function(self, data) 
        _base_load(self, data)
        self._float.val = data.val
        self._prev_val = data.val
    end
    pin.on_save = function(self)
        local data = _base_save(self)
        data.val = self._float.val
        return data
    end
    pin.set_val = function(self, val)
        self._float.val = val
        self._prev_val = val
    end
    pin.get_val = function(self)
        if self._is_output then
            return self._float.val
        end
        if self._linked_pin_id then
            return GlobalContext.runtime_find_pin(self._linked_pin_id:get()):get_val()
        end
        return self._float.val
    end
    return pin
end

construct_func_pool["bool"] = function(id, owner_id, is_output, name, extra_args)
    local pin = _base_constructor(id, owner_id, is_output, "bool", imgui.NodeEditor.IconType.Circle, name or "布尔值")
    pin._bool = imgui.Bool(false)
    pin._can_edit = true if extra_args and extra_args.can_edit ~= nil then pin._can_edit = extra_args.can_edit end
    if pin._can_edit then
        pin._on_tick_widgets = function(self)
            imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
                if imgui.Checkbox("##bool"..id, self._bool) then
                    UndoManager.record(function(pin) pin._bool.val = not pin._bool.val end, 
                        function(pin) pin._bool.val = not pin._bool.val end, pin)
                end
            imgui.EndDisabled()
        end
    end
    pin.on_load = function(self, data) 
        _base_load(self, data)
        self._bool.val = data.val
    end
    pin.on_save = function(self)
        local data = _base_save(self)
        data.val = self._bool.val
        return data
    end
    pin.set_val = function(self, val)
        self._bool.val = val
        self._prev_val = val
    end
    pin.get_val = function(self)
        if self._is_output then
            return self._bool.val
        end
        if self._linked_pin_id then
            return GlobalContext.runtime_find_pin(self._linked_pin_id:get()):get_val()
        end
        return self._bool.val
    end
    return pin
end

construct_func_pool["font"] = function(id, owner_id, is_output, name, extra_args)
    local pin = _base_constructor(id, owner_id, is_output, "font", imgui.NodeEditor.IconType.Circle, name or "字体资产")
    pin._cstring = util.CString()
    pin._prev_text = pin._cstring:get()
    pin._width_input = 50 if extra_args then pin._width_input = extra_args.width_input or pin._width_input end
    pin._on_tick_widgets = function(self)
        imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
            imgui.SetNextItemWidth(self._width_input)
            imgui.InputText("##font"..id, self._cstring)
            if imgui.IsItemDeactivatedAfterEdit() then
                UndoManager.record(function(data) 
                        pin._cstring:set(data.old) 
                        pin._prev_text = data.old
                    end, function(data) 
                        pin._cstring:set(data.new) 
                        pin._prev_text = data.new
                    end, {old = pin._prev_text, new = pin._cstring:get()})
                pin._prev_text = pin._cstring:get()
            end
            if imgui.BeginDragDropTarget() then
                local payload = imgui.AcceptDragDropPayload("asset")
                if payload then
                    if payload.type == "font" then
                        self._cstring:set(payload.id)
                        UndoManager.record(function(data)
                                pin._cstring:set(data.old) 
                                pin._prev_text = data.old
                            end, function(data)
                                pin._cstring:set(data.new) 
                                pin._prev_text = data.new
                            end, {old = pin._prev_text, new = pin._cstring:get()})
                        pin._prev_text = pin._cstring:get()
                    else
                        LogManager.log(string.format("错误的引脚赋值类型，使用“%s”类型资产为“%s”类型引脚赋值", payload.type, "font"), "warning")
                    end
                end
                imgui.EndDragDropTarget()
            end
            if self._is_output or (not self._is_output and not self._linked_pin_id) then
                if not ResourcesManager.find_font(self._cstring:get()) then
                    imgui.TextColored(imgui.ImColor(183, 40, 46, 255).value, "+ 无效的资产ID")
                end
            end
        imgui.EndDisabled()
    end
    pin.on_load = function(self, data) 
        _base_load(self, data)
        self._cstring:set(data.val)
        self._prev_text = data.val
    end
    pin.on_save = function(self)
        local data = _base_save(self)
        data.val = self._cstring:get()
        return data
    end
    pin.set_val = function(self, val)
        self._cstring:set(val)
        self._prev_text = val
    end
    pin.get_val = function(self)
        if self._is_output then
            return ResourcesManager.find_font(self._cstring:get())
        end
        if self._linked_pin_id then
            return GlobalContext.runtime_find_pin(self._linked_pin_id:get()):get_val()
        end
        return ResourcesManager.find_font(self._cstring:get())
    end
    return pin
end

construct_func_pool["audio"] = function(id, owner_id, is_output, name, extra_args)
    local pin = _base_constructor(id, owner_id, is_output, "audio", imgui.NodeEditor.IconType.Circle, name or "音频资产")
    pin._cstring = util.CString()
    pin._prev_text = pin._cstring:get()
    pin._width_input = 50 if extra_args then pin._width_input = extra_args.width_input or pin._width_input end
    pin._on_tick_widgets = function(self)
        imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
            imgui.SetNextItemWidth(self._width_input)
            imgui.InputText("##audio"..id, self._cstring)
            if imgui.IsItemDeactivatedAfterEdit() then
                UndoManager.record(function(data) 
                        pin._cstring:set(data.old) 
                        pin._prev_text = data.old
                    end, function(data) 
                        pin._cstring:set(data.new) 
                        pin._prev_text = data.new
                    end, {old = pin._prev_text, new = pin._cstring:get()})
                pin._prev_text = pin._cstring:get()
            end
            if imgui.BeginDragDropTarget() then
                local payload = imgui.AcceptDragDropPayload("asset")
                if payload then
                    if payload.type == "audio" then
                        self._cstring:set(payload.id)
                        UndoManager.record(function(data) 
                                pin._cstring:set(data.old) 
                                pin._prev_text = data.old
                            end, function(data) 
                                pin._cstring:set(data.new) 
                                pin._prev_text = data.new
                            end, {old = pin._prev_text, new = pin._cstring:get()})
                        pin._prev_text = pin._cstring:get()
                    else
                        LogManager.log(string.format("错误的引脚赋值类型，使用“%s”类型资产为“%s”类型引脚赋值", payload.type, "audio"), "warning")
                    end
                end
                imgui.EndDragDropTarget()
            end
            if self._is_output or (not self._is_output and not self._linked_pin_id) then
                if not ResourcesManager.find_audio(self._cstring:get()) then
                    imgui.TextColored(imgui.ImColor(183, 40, 46, 255).value, "+ 无效的资产ID")
                end
            end
        imgui.EndDisabled()
    end
    pin.on_load = function(self, data) 
        _base_load(self, data)
        self._cstring:set(data.val)
        self._prev_text = data.val
    end
    pin.on_save = function(self)
        local data = _base_save(self)
        data.val = self._cstring:get()
        return data
    end
    pin.set_val = function(self, val)
        self._cstring:set(val)
        self._prev_text = val
    end
    pin.get_val = function(self)
        if self._is_output then
            return ResourcesManager.find_audio(self._cstring:get())
        end
        if self._linked_pin_id then
            return GlobalContext.runtime_find_pin(self._linked_pin_id:get()):get_val()
        end
        return ResourcesManager.find_audio(self._cstring:get())
    end
    return pin
end

construct_func_pool["shader"] = function(id, owner_id, is_output, name, extra_args)
    local pin = _base_constructor(id, owner_id, is_output, "shader", imgui.NodeEditor.IconType.Circle, name or "着色器资产")
    pin._cstring = util.CString()
    pin._prev_text = pin._cstring:get()
    pin._width_input = 50 if extra_args then pin._width_input = extra_args.width_input or pin._width_input end
    pin._on_tick_widgets = function(self)
        imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
            imgui.SetNextItemWidth(self._width_input)
            imgui.InputText("##shader"..id, self._cstring)
            if imgui.IsItemDeactivatedAfterEdit() then
                UndoManager.record(function(data) 
                        pin._cstring:set(data.old) 
                        pin._prev_text = data.old
                    end, function(data) 
                        pin._cstring:set(data.new) 
                        pin._prev_text = data.new
                    end, {old = pin._prev_text, new = pin._cstring:get()})
                pin._prev_text = pin._cstring:get()
            end
            if imgui.BeginDragDropTarget() then
                local payload = imgui.AcceptDragDropPayload("asset")
                if payload then
                    if payload.type == "shader" then
                        self._cstring:set(payload.id)
                        UndoManager.record(function(data) 
                                pin._cstring:set(data.old) 
                                pin._prev_text = data.old
                            end, function(data) 
                                pin._cstring:set(data.new) 
                                pin._prev_text = data.new
                            end, {old = pin._prev_text, new = pin._cstring:get()})
                        pin._prev_text = pin._cstring:get()
                    else
                        LogManager.log(string.format("错误的引脚赋值类型，使用“%s”类型资产为“%s”类型引脚赋值", payload.type, "shader"), "warning")
                    end
                end
                imgui.EndDragDropTarget()
            end
            if self._is_output or (not self._is_output and not self._linked_pin_id) then
                if not ResourcesManager.find_shader(self._cstring:get()) then
                    imgui.TextColored(imgui.ImColor(183, 40, 46, 255).value, "+ 无效的资产ID")
                end
            end
        imgui.EndDisabled()
    end
    pin.on_load = function(self, data) 
        _base_load(self, data)
        self._cstring:set(data.val)
        self._prev_text = data.val
    end
    pin.on_save = function(self)
        local data = _base_save(self)
        data.val = self._cstring:get()
        return data
    end
    pin.set_val = function(self, val)
        self._cstring:set(val)
        self._prev_text = val
    end
    pin.get_val = function(self)
        if self._is_output then
            return ResourcesManager.find_shader(self._cstring:get())
        end
        if self._linked_pin_id then
            return GlobalContext.runtime_find_pin(self._linked_pin_id:get()):get_val()
        end
        return ResourcesManager.find_shader(self._cstring:get())
    end
    return pin
end

construct_func_pool["texture"] = function(id, owner_id, is_output, name, extra_args)
    local pin = _base_constructor(id, owner_id, is_output, "texture", imgui.NodeEditor.IconType.Circle, name or "纹理资产")
    pin._cstring = util.CString()
    pin._prev_text = pin._cstring:get()
    pin._width_input = 50 if extra_args then pin._width_input = extra_args.width_input or pin._width_input end
    pin._on_tick_widgets = function(self)
        imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
            imgui.SetNextItemWidth(self._width_input)
            imgui.InputText("##texture"..id, self._cstring)
            if imgui.IsItemDeactivatedAfterEdit() then
                UndoManager.record(function(data) 
                        pin._cstring:set(data.old) 
                        pin._prev_text = data.old
                    end, function(data) 
                        pin._cstring:set(data.new) 
                        pin._prev_text = data.new
                    end, {old = pin._prev_text, new = pin._cstring:get()})
                pin._prev_text = pin._cstring:get()
            end
            if imgui.BeginDragDropTarget() then
                local payload = imgui.AcceptDragDropPayload("asset")
                if payload then
                    if payload.type == "texture" then
                        self._cstring:set(payload.id)
                        UndoManager.record(function(data)
                                pin._cstring:set(data.old) 
                                pin._prev_text = data.old
                            end, function(data) 
                                pin._cstring:set(data.new) 
                                pin._prev_text = data.new
                            end, {old = pin._prev_text, new = pin._cstring:get()})
                        pin._prev_text = pin._cstring:get()
                    else
                        LogManager.log(string.format("错误的引脚赋值类型，使用“%s”类型资产为“%s”类型引脚赋值", payload.type, "texture"), "warning")
                    end
                end
                imgui.EndDragDropTarget()
            end
            if self._is_output or (not self._is_output and not self._linked_pin_id) then
                local texture = ResourcesManager.find_sdl_texture(self._cstring:get())
                if texture then
                    local info = sdl.QueryTexture(texture)
                    local pos_begin = imgui.GetCursorPos()
                    local scale = self._width_input / info.w
                    local size_image = imgui.ImVec2(info.w * scale, info.h * scale)
                    imgui.Image(texture, size_image, nil, nil, nil, imgui.ImColor(255, 255, 255, 100).value)
                else
                    imgui.TextColored(imgui.ImColor(183, 40, 46, 255).value, "+ 无效的资产ID")
                end
            end
        imgui.EndDisabled()
    end
    pin.on_load = function(self, data) 
        _base_load(self, data)
        self._cstring:set(data.val)
        self._prev_text = data.val
    end
    pin.on_save = function(self)
        local data = _base_save(self)
        data.val = self._cstring:get()
        return data
    end
    pin.set_val = function(self, val)
        self._cstring:set(val)
        self._prev_text = val
    end
    pin.get_val = function(self)
        if self._is_output then
            return ResourcesManager.find_texture(self._cstring:get())
        end
        if self._linked_pin_id then
            return GlobalContext.runtime_find_pin(self._linked_pin_id:get()):get_val()
        end
        return ResourcesManager.find_texture(self._cstring:get())
    end
    return pin
end

module.create = function(pin_type_id, id, owner_id, is_output, name, extra_args)
    local func = construct_func_pool[pin_type_id]
    assert(func, string.format("unknown pin type: %s", pin_type_id))
    return func(id, owner_id, is_output, name, extra_args)
end

return module