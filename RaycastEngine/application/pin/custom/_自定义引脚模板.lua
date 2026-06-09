--[[
自定义引脚模板说明：
1. 当前文件名以下划线开头，启动扫描时会被自动忽略，可安全作为模板长期保留。
2. 使用时请复制一份并重命名为非下划线开头的 .lua 文件。
3. 请务必修改 type_id，且保证在当前工程中唯一。
4. Pin 负责“类型、默认值、编辑控件、序列化、取值与连线兼容规则”。
5. 新版本建议同时提供 runtime.validate，并让 get_val 走 BlueprintPin 的安全链路。
]]

local Common = require("application.framework.builtin_pin_common")

local util = Common.util
local imgui = Common.imgui
local UndoManager = Common.UndoManager
local ColorHelper = Common.ColorHelper

return Common.make_definition(
{
    type_id = "your_custom_pin",
    display_name = "你的自定义引脚",
    icon_type = imgui.NodeEditor.IconType.Circle,
    color = ColorHelper.ValueTypeColorPool.string,
    default_name = "自定义值",
    runtime =
    {
        validate = function(value, opts)
            if value == nil then
                if opts and opts.allow_nil then
                    return true, nil
                end
                return false, nil, {code = "nil_value"}
            end
            if type(value) ~= "string" then
                return false, nil, {code = "type_mismatch", actual_type = type(value)}
            end
            return true, value
        end,
    },

    -- 如需特殊连线规则，可按需放开。
    -- 默认情况下，只有同 type_id 的引脚可连线。
    -- can_accept = function(input_pin, output_pin, link_ctx)
    --     return output_pin._type_id == "string"
    -- end,
}, function(pin, ctx)
    -- ctx.definition: 当前引脚定义
    -- ctx.pin_id / ctx.owner_id / ctx.direction / ctx.is_output
    -- ctx.name: 当前引脚名称
    -- ctx.options: PinFactory 解析后的 options
    -- ctx.registry: PinRegistry

    pin._cstring = util.CString()
    pin._prev_text = pin._cstring:get()
    pin._width_input = ctx.options.width_input or 150

    pin._on_tick_widgets = function(self)
        imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
            imgui.SetNextItemWidth(self._width_input)
            imgui.InputText("##custom_pin_" .. ctx.pin_id, self._cstring)
            if imgui.IsItemDeactivatedAfterEdit() then
                local next_text = pin._cstring:get()
                if next_text == pin._prev_text then
                    imgui.EndDisabled()
                    return
                end
                UndoManager.record(function(data)
                        pin._cstring:set(data.old)
                        pin._prev_text = data.old
                    end,
                    function(data)
                        pin._cstring:set(data.new)
                        pin._prev_text = data.new
                    end,
                    {old = pin._prev_text, new = next_text})
                pin._prev_text = next_text
            end
        imgui.EndDisabled()
    end

    pin.on_load = function(self, data)
        Common.BlueprintPin.on_load(self, data)
        self._cstring:set(data.val or "")
        self._prev_text = self._cstring:get()
    end

    pin.on_save = function(self)
        local data = Common.BlueprintPin.on_save(self)
        -- SAVE TRACE: custom pin template appends its editable value.
        data.val = self._cstring:get()
        return data
    end

    pin.set_val = function(self, val)
        self._cstring:set(tostring(val or ""))
        self._prev_text = self._cstring:get()
    end

    pin.get_val = function(self)
        return self:_resolve_runtime_input_value(self._cstring:get())
    end
end)
