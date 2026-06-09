local imgui = Engine.ImGUI

local Class = require("application.framework.class")
local ResourcesManager = require("application.framework.resources_manager")

local size_icon_min <const> = imgui.ImVec2(18, 18)
local size_icon_max <const> = imgui.ImVec2(28, 28)
local pin_column_gap <const> = 18
local header_title_color <const> = imgui.ImVec4(imgui.ImColor(255, 255, 255, 255).value)
local header_comment_color <const> = imgui.ImVec4(imgui.ImColor(188, 211, 202, 255).value)
local header_icon_color <const> = imgui.ImVec4(imgui.ImColor(255, 255, 255, 255).value)

local BlueprintNode = Class.define("BlueprintNode")

local function _get_pin_id(pin)
    return pin and pin._id and pin._id:get() or nil
end

local function _find_pin_index(pin_list, target_pin)
    if not target_pin then
        return nil, nil
    end

    local target_id = _get_pin_id(target_pin)
    for index, pin in ipairs(pin_list or {}) do
        if pin == target_pin then
            return pin, index
        end
        if target_id ~= nil and _get_pin_id(pin) == target_id then
            return pin, index
        end
    end

    return nil, nil
end

local function _resolve_pin_ref(pin_list, pin_map, ref)
    if ref == nil then
        return nil, nil
    end

    if type(ref) == "number" then
        return pin_list[ref], ref
    end

    if type(ref) == "string" then
        local pin = pin_map and pin_map[ref] or nil
        if not pin then
            return nil, nil
        end
        return _find_pin_index(pin_list, pin)
    end

    if type(ref) == "table" then
        return _find_pin_index(pin_list, ref)
    end

    return nil, nil
end

local function _get_output_alignment_width(pin_list)
    local width = 0
    for _, pin in ipairs(pin_list) do
        width = math.max(width, pin:get_output_alignment_width())
    end
    return width
end

local function _get_pin_column_layout_width(pin_list)
    local width = 0
    for _, pin in ipairs(pin_list) do
        width = math.max(width, pin:get_layout_row_width())
    end
    return width
end

local function _should_auto_right_align_single_flow_output(node)
    if #node._output_pin_list ~= 1 then
        return false
    end

    local output_pin = node._output_pin_list[1]
    return output_pin ~= nil
        and output_pin._type_id == "flow"
        and output_pin._name == nil
end

function BlueprintNode:ctor(blueprint, data, type_id, icon, header_color, title, comment)
    self._blueprint = blueprint
    self._id = nil
    self._type_id = type_id
    self._icon = icon
    self._header_color = header_color
    self._title = title
    self._comment = comment
    self._input_pin_list = {}
    self._output_pin_list = {}
    self._input_pin_map = {}
    self._output_pin_map = {}
    self._position = {x = 0, y = 0}
    self._def = nil
    self._output_leading_width = 0
    self._single_output_right_padding = 0

    if data then
        self._id = imgui.NodeEditor.NodeId(data.id)
        self._position.x, self._position.y = data.position.x, data.position.y
    else
        self._id = imgui.NodeEditor.NodeId(blueprint:gen_next_uid())
    end
end

function BlueprintNode:on_update()
    local max_rect = nil
    local output_alignment_width = _get_output_alignment_width(self._output_pin_list)
    local output_column_width = _get_pin_column_layout_width(self._output_pin_list)
    local output_leading_width = 0
    local manual_single_output_leading_width = 0
    local header_width = 0
    local input_column_width = 0
    if #self._output_pin_list == 1 then
        manual_single_output_leading_width = math.max(0, self._output_leading_width or 0)
        if manual_single_output_leading_width > 0 then
            output_leading_width = manual_single_output_leading_width
        end
    end
    imgui.NodeEditor.BeginNode(self._id)
        if self._header_color then
            local header_begin = imgui.GetCursorScreenPos()
            imgui.BeginGroup()
                if self._icon then
                    local size = size_icon_min
                    if self._comment then size = size_icon_max end
                    imgui.Image(self._icon, size, nil, nil, header_icon_color, nil)
                end
            imgui.EndGroup()
            imgui.SameLine()
            imgui.BeginGroup()
                if self._title then
                    imgui.TextColored(header_title_color, self._title)
                end
                if self._comment then imgui.TextColored(header_comment_color, self._comment) end
            imgui.EndGroup()
            local header_content_max = imgui.ImVec2(imgui.GetItemRectMax().x, imgui.GetItemRectMax().y)
            header_width = math.max(0, header_content_max.x - header_begin.x)
            imgui.Dummy(imgui.ImVec2(0, 0))
            max_rect = imgui.GetItemRectMax()
        end

        if #self._input_pin_list > 0 then
            local input_begin = imgui.GetCursorScreenPos()
            imgui.BeginGroup()
                for _, pin in ipairs(self._input_pin_list) do
                    pin:on_update()
                end
            imgui.EndGroup()
            input_column_width = math.max(0, imgui.GetItemRectMax().x - input_begin.x)
            if #self._output_pin_list > 0 then
                imgui.SameLine()
                imgui.Dummy(imgui.ImVec2(pin_column_gap, 0))
                imgui.SameLine()
            end
        end

        if #self._output_pin_list > 0 then
            local body_width_without_leading = output_column_width
            if #self._input_pin_list > 0 then
                body_width_without_leading = input_column_width + pin_column_gap + output_column_width
            end
            if manual_single_output_leading_width <= 0 and header_width > body_width_without_leading then
                local right_padding = 0
                if _should_auto_right_align_single_flow_output(self) then
                    right_padding = math.max(0, self._single_output_right_padding or 0)
                end
                output_leading_width = math.max(output_leading_width, header_width - body_width_without_leading + right_padding)
            end
            if output_leading_width > 0.5 then
                imgui.Dummy(imgui.ImVec2(output_leading_width, 0))
                imgui.SameLine(0, 0)
            end
            imgui.BeginGroup()
                for _, pin in ipairs(self._output_pin_list) do
                    pin:on_update(output_alignment_width)
                end
            imgui.EndGroup()
        end
    imgui.NodeEditor.EndNode()

    if manual_single_output_leading_width <= 0 and _should_auto_right_align_single_flow_output(self) then
        local node_size = imgui.NodeEditor.GetNodeSize(self._id)
        local body_width_with_leading = output_column_width + output_leading_width
        if #self._input_pin_list > 0 then
            body_width_with_leading = input_column_width + pin_column_gap + output_column_width + output_leading_width
        end
        local content_width = math.max(header_width, body_width_with_leading)
        local outer_extra_width = math.max(0, (node_size.x or 0) - content_width)
        self._single_output_right_padding = outer_extra_width * 0.5
    end

    if self._header_color then
        local min_rect = imgui.GetItemRectMin()
        max_rect.x = imgui.GetItemRectMax().x
        imgui.NodeEditor.AddNodeHeaderBackground(self._id,
            ResourcesManager.find_icon("bp_bg"), self._header_color, min_rect, max_rect)
    end
end

function BlueprintNode:on_save()
    -- SAVE TRACE: node_data collected under dump_data.node_pool[node_id].
    -- Fields: id, type_id, pin_schema_version, input_pin_list, output_pin_list, position.
    local data =
    {
        id = self._id:get(),
        type_id = self._type_id,
        pin_schema_version = self._def and self._def.pin_schema_version or 1,
        input_pin_list = {},
        output_pin_list = {},
        position = {x = 0, y = 0}
    }
    local position = imgui.NodeEditor.GetNodePosition(self._id)
    data.position.x, data.position.y = math.floor(position.x), math.floor(position.y)
    for _, pin in ipairs(self._input_pin_list) do
        -- SAVE TRACE: input pin fields are collected by pin:on_save().
        table.insert(data.input_pin_list, pin:on_save())
    end
    for _, pin in ipairs(self._output_pin_list) do
        -- SAVE TRACE: output pin fields are collected by pin:on_save().
        table.insert(data.output_pin_list, pin:on_save())
    end
    return data
end

function BlueprintNode:query_menu_id()

end

function BlueprintNode:on_show_menu()

end

function BlueprintNode:on_execute(scene, entry_pin)

end

function BlueprintNode:on_execute_update(scene, delta)

end

function BlueprintNode:on_exetute(scene, entry_pin)
    return self:on_execute(scene, entry_pin)
end

function BlueprintNode:on_exetute_update(scene, delta)
    return self:on_execute_update(scene, delta)

end

function BlueprintNode:get_definition()
    return self._def
end

function BlueprintNode:resolve_input_pin(ref)
    return _resolve_pin_ref(self._input_pin_list, self._input_pin_map, ref)
end

function BlueprintNode:resolve_output_pin(ref)
    return _resolve_pin_ref(self._output_pin_list, self._output_pin_map, ref)
end

function BlueprintNode:get_input_pin(ref)
    local pin = self:resolve_input_pin(ref)
    return pin
end

function BlueprintNode:get_output_pin(ref)
    local pin = self:resolve_output_pin(ref)
    return pin
end

function BlueprintNode:find_input_pin(key)
    if type(key) ~= "string" then
        return nil
    end
    return self._input_pin_map[key]
end

function BlueprintNode:find_output_pin(key)
    if type(key) ~= "string" then
        return nil
    end
    return self._output_pin_map[key]
end

function BlueprintNode:set_output_val(ref, value)
    local pin = self:get_output_pin(ref)
    if pin and pin.set_val then
        pin:set_val(value)
    end
    return pin
end

function BlueprintNode:set_input_default(ref, value)
    local pin = self:get_input_pin(ref)
    if pin and pin.set_val then
        pin:set_val(value)
    end
    return pin
end

return BlueprintNode
