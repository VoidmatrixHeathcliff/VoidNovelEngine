local Common = require("application.framework.builtin_node_common")
local PresentationUIBridge = require("application.framework.presentation_ui_bridge")
local RuntimeLayout = require("application.framework.runtime_layout_context")
local StyleManager = require("application.framework.style_manager")

local util = Common.util
local imgui = Common.imgui
local Timer = Common.Timer
local TextWrapper = Common.TextWrapper
local SubtitleObject = Common.SubtitleObject
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local _migrate_legacy_style_overrides

local NodeDef =
{
    type_id = "show_subtitle",
    pin_schema_version = 2,
    icon_id = "text-spacing",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "显示字幕",
    comment = "打字机效果呈现的水平居中文本",
    category = "演出控制",
    category_order = 1,
    order = 9,
    menu_visible = true,
    script =
    {
        aliases = {"subtitle"},
        summary = "显示带打字机效果的居中字幕。",
        detail = "适合旁白、场景提示和简短系统文本。char_interval 控制逐字显示速度，wait 决定字幕播完后是否等待玩家互动。",
        docs =
        {
            brief = "显示带打字机效果的居中字幕。",
            description = [=[
适合旁白、场景提示和简短系统文本。若当前存在激活样式，字体、字号、颜色与底部偏移会优先从样式系统回退。
]=],
            usage =
            {
                '@subtitle("...")',
                '@subtitle("...", char_interval: 0.01, wait: false)',
            },
            notes =
            {
                {kind = "tip", text = "char_interval 越小，字幕逐字速度越快。"},
            },
            examples =
            {
                {
                    title = "快速系统提示",
                    language = "vns",
                    code = '@subtitle("...", char_interval: 0.01, wait: false)',
                },
            },
            see_also =
            {
                {kind = "command", target = "show_dialog_box"},
            },
        },
        signature =
        {
            {name = "text", pin = "text", positional = true, required = true, doc = {brief = "字幕文本内容。"}},
            {name = "char_interval", pin = "char_interval", doc = {brief = "逐字显示时每个字符之间的时间间隔。", default = "0.03", value_hint = ">= 0"}},
            {name = "bottom_distance", pin = "bottom_distance", doc = {brief = "字幕距离屏幕底部的偏移。"}},
            {name = "font", pin = "font", doc = {brief = "字幕字体资源。"}},
            {name = "font_size", pin = "font_size", doc = {brief = "字幕字号。"}},
            {name = "color", pin = "color", doc = {brief = "字幕颜色。"}},
            {name = "wait", pin = "wait_interaction", aliases = {"wait_interaction"}, doc = {brief = "是否在字幕完整显示后等待玩家互动。", default = "true"}},
        },
        default_flow_output = "out",
    },
    migrate_pins = function(data, migrate_ctx)
        return _migrate_legacy_style_overrides(data,
            migrate_ctx and migrate_ctx.target_pin_schema_version or 2)
    end,
}

local object_id <const> = "bp-subtitle"
local style_bound_pin_key_pool =
{
    char_interval = true,
    bottom_distance = true,
    font = true,
    font_size = true,
    color = true,
}
local legacy_style_bound_pin_index_pool =
{
    [3] = true, -- char_interval
    [4] = true, -- bottom_distance
    [5] = true, -- font
    [6] = true, -- font_size
    [7] = true, -- color
}

_migrate_legacy_style_overrides = function(data, target_version)
    for index, pin in ipairs(data and data.input_pin_list or {}) do
        local key = type(pin) == "table" and pin.key or nil
        local is_style_bound = type(pin) == "table"
            and (style_bound_pin_key_pool[key] or (key == nil and legacy_style_bound_pin_index_pool[index]))
        if is_style_bound and rawget(pin, "val") ~= nil then
            pin.style_local_override = true
        end
    end
    if type(data) == "table" then
        data.pin_schema_version = target_version or 2
    end
    return data
end

local function _get_style_reference(binding, type_id)
    if type(binding) ~= "table" then
        return nil, false
    end

    local value, ok = StyleManager.try_get_raw_value(binding.domain, binding.field, type_id)
    if ok then
        return value, true
    end
    return nil, false
end

local function _get_input_reference(node, key, type_id)
    local pin = node and node.find_input_pin and node:find_input_pin(key) or nil
    if not pin or not pin.get_reference then
        return nil
    end

    if pin._linked_pin_id then
        return pin:get_reference()
    end

    local binding = pin.get_style_binding and pin:get_style_binding() or nil
    if not binding then
        return pin:get_reference()
    end

    local local_reference = pin:get_reference()
    if pin.has_style_local_override and pin:has_style_local_override() then
        return local_reference
    end

    local style_reference, found_style_reference = _get_style_reference(binding, type_id)
    if found_style_reference then
        return style_reference
    end
    return local_reference
end

local function _build_subtitle_save_state(node, bottom_distance, text)
    return
    {
        layout_schema_version = 2,
        design_width = 1920,
        design_height = 1080,
        text = text,
        font_reference = _get_input_reference(node, "font", "font"),
        font_size = NodeRuntimeHelper.check_int(node, "font_size"),
        color = NodeRuntimeHelper.convert_imvec4_to_color_table(NodeRuntimeHelper.check_color(node, "color")),
        bottom_distance = bottom_distance,
    }
end

local function _can_save_subtitle_now(node, scene)
    if NodeRuntimeHelper.check_bool(node, "wait_interaction") ~= true then
        return false, "当前字幕节点未处于等待互动状态"
    end

    if node._ui_backend_active then
        local instance = node._ui_runtime_instance and scene and scene.find_ui_instance and scene:find_ui_instance(node._ui_runtime_instance.id or object_id) or nil
        if not instance then
            return false, "当前字幕界面尚未创建完成"
        end
        if node._ui_text_completed ~= true then
            return false, "当前字幕仍在逐字显示中"
        end
        return true
    end

    local subtitle = scene and scene.find_object and scene:find_object(object_id) or nil
    if not subtitle then
        return false, "当前字幕对象尚未创建完成"
    end
    if subtitle.can_push_on ~= true then
        return false, "当前字幕仍在逐字显示中"
    end
    return true
end

return Common.make_definition(NodeDef, function(ctx)
    local convert_color = NodeRuntimeHelper.convert_imvec4_to_sdl_color
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "text", type_id = "string", name = "文本", options = {width_input = 100}})
    builder:add_input({key = "char_interval", type_id = "float", name = "字符时间间隔", style_binding = {domain = "subtitle", field = "char_interval"}})
    builder:add_input({key = "bottom_distance", type_id = "float", name = "屏幕底部距离", style_binding = {domain = "subtitle", field = "bottom_distance"}})
    builder:add_input({key = "font", type_id = "font", name = "字体", default_factory = Common.default_font_reference, style_binding = {domain = "subtitle", field = "font"}})
    builder:add_input({key = "font_size", type_id = "int", name = "字号", options = {width_input = 100}, style_binding = {domain = "subtitle", field = "font_size"}})
    builder:add_input({key = "color", type_id = "color", name = "颜色", options = {full_edit = false}, style_binding = {domain = "subtitle", field = "color"}})
    builder:add_input({key = "wait_interaction", type_id = "bool", name = "等待互动"})
    builder:add_output({key = "out", type_id = "flow"})

    if not ctx.data then
        node:find_input_pin("char_interval"):set_val(0.03)
        node:find_input_pin("bottom_distance"):set_val(40)
        node:find_input_pin("font_size"):set_val(25)
        node:find_input_pin("color"):set_val(imgui.ImVec4(0.95, 0.95, 0.95, 1))
        node:find_input_pin("wait_interaction"):set_val(true)
    end

    node._subtitle_bottom_distance = 0
    node._ui_backend_active = false
    node._ui_runtime_instance = nil
    node._ui_full_text = ""
    node._ui_text_length = 0
    node._ui_text_index = 0
    node._ui_char_interval = 0
    node._ui_char_elapsed = 0
    node._ui_text_completed = false

    node.on_execute = function(self, scene)
        self._ui_backend_active = false
        self._ui_runtime_instance = nil

        local text = NodeRuntimeHelper.check_string(self, "text")
        local font_size = NodeRuntimeHelper.check_int(self, "font_size")
        if font_size < 1 then
            NodeRuntimeHelper.abort(self, "无效的字号输入")
        end
        if #text == 0 then
            text = " "
        end

        local interval = NodeRuntimeHelper.check_float(self, "char_interval")
        if interval < 0 then
            interval = 0
        end
        local subtitle = scene:find_object(object_id)
        self._subtitle_bottom_distance = NodeRuntimeHelper.check_float(self, "bottom_distance")

        if PresentationUIBridge.is_enabled() and scene and scene.open_ui and scene.find_ui_instance then
            local initial_text = interval <= 0 and text or util.UTF8Sub(text, 0, 1)
            local instance, err = PresentationUIBridge.open_subtitle(scene,
            {
                instance_id = object_id,
                text = initial_text,
                bottom_distance = self._subtitle_bottom_distance,
                font = _get_input_reference(self, "font", "font"),
                font_size = font_size,
                color = NodeRuntimeHelper.check_color(self, "color"),
            })
            if not instance then
                NodeRuntimeHelper.abort(self, string.format("无法打开 UI 字幕：%s", tostring(err or "未知错误")))
            end

            self._ui_backend_active = true
            self._ui_runtime_instance = instance
            self._ui_full_text = text
            self._ui_text_length = util.UTF8Len(text)
            self._ui_text_index = interval <= 0 and self._ui_text_length or 1
            self._ui_char_interval = interval
            self._ui_char_elapsed = 0
            self._ui_text_completed = interval <= 0 or self._ui_text_length <= 1
            return
        end

        if not subtitle then
            subtitle = SubtitleObject.new()
            scene:add_object(subtitle, object_id, 85)
        end
        local bottom_distance = self._subtitle_bottom_distance or 0
        subtitle:set_bottom_offset_provider(function()
            return RuntimeLayout.scale_y(bottom_distance)
        end)

        subtitle.idx_text = 1
        subtitle.is_visible = true
        subtitle.can_push_on = false

        local font_obj = NodeRuntimeHelper.check_resource(self, "font", "font")
        local resolved_font_size = RuntimeLayout.scale_font_size(font_size)
        local color_sdl = convert_color(NodeRuntimeHelper.check_color(self, "color"))
        subtitle:set_runtime_save_data(_build_subtitle_save_state(self, self._subtitle_bottom_distance, text))

        local canvas_width = RuntimeLayout.get_canvas_size()
        subtitle:set_text_object(TextWrapper.new(font_obj, util.UTF8Sub(text, 0, 1), color_sdl,
            math.max(1, RuntimeLayout.round(canvas_width)), resolved_font_size))
        scene:add_object(Timer.new(interval, function(timer)
            subtitle.idx_text = subtitle.idx_text + 1
            if subtitle.idx_text > util.UTF8Len(text) then
                subtitle.can_push_on = true
                timer:make_invalid()
            end
            subtitle.text_object:set_text(util.UTF8Sub(text, 0, subtitle.idx_text))
        end, false), "timer_subtitle")
    end

    node.on_execute_update = function(self, scene, delta)
        if self._ui_backend_active then
            local instance = self._ui_runtime_instance and scene:find_ui_instance(self._ui_runtime_instance.id or object_id) or nil
            if instance and not self._ui_text_completed and self._ui_char_interval > 0 then
                self._ui_char_elapsed = self._ui_char_elapsed + delta
                while self._ui_char_elapsed >= self._ui_char_interval and not self._ui_text_completed do
                    self._ui_char_elapsed = self._ui_char_elapsed - self._ui_char_interval
                    self._ui_text_index = self._ui_text_index + 1
                    if self._ui_text_index >= self._ui_text_length then
                        self._ui_text_index = self._ui_text_length
                        self._ui_text_completed = true
                    end
                    PresentationUIBridge.set_widget_text(instance, "subtitle_text", util.UTF8Sub(self._ui_full_text, 0, self._ui_text_index))
                end
            end

            if self._ui_text_completed then
                if NodeRuntimeHelper.check_bool(self, "wait_interaction") then
                    NodeRuntimeHelper.wait_interact_to_next_node(self, "out")
                else
                    NodeRuntimeHelper.execute_next_node(self, "out")
                end
            end
            return
        end

        local subtitle = scene:find_object(object_id)
        if subtitle and subtitle.can_push_on then
            if NodeRuntimeHelper.check_bool(self, "wait_interaction") then
                NodeRuntimeHelper.wait_interact_to_next_node(self, "out")
            else
                NodeRuntimeHelper.execute_next_node(self, "out")
            end
        end
    end

    node.can_save_now = function(self, scene, runtime)
        return _can_save_subtitle_now(self, scene)
    end

    node.collect_runtime_save_state = function(self, scene, runtime)
        local ok = _can_save_subtitle_now(self, scene)
        if ok ~= true then
            return nil
        end

        return
        {
            resume_mode = "interaction",
            output_ref = "out",
        }
    end

    return node
end)
