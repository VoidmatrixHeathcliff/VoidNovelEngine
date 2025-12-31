local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local util = Engine.Util
local imgui = Engine.ImGUI

local Timer = require("application.framework.timer")
local Tween = require("application.framework.tween")
local NodeDef = require("application.framework.node_def")
local Billboard = require("application.framework.billboard")
local GameObject = require("application.framework.game_object")
local PinFactory = require("application.framework.pin_factory")
local LogManager = require("application.framework.log_manager")
local TextWrapper = require("application.framework.text_wrapper")
local ColorHelper = require("application.framework.color_helper")
local UndoManager = require("application.framework.undo_manager")
local GlobalContext = require("application.framework.global_context")
local ModifyManager = require("application.framework.modify_manager")
local BranchSelector = require("application.framework.branch_selector")
local ResourcesManager = require("application.framework.resources_manager")

local construct_func_pool = {}

-- 图标大小
local size_icon_min <const> = imgui.ImVec2(18, 18)
local size_icon_max <const> = imgui.ImVec2(28, 28)

-- 将ImVec4转换为SDLColor
local function _convert_imvec4_to_sdl_color(vec4)
    return sdl.Color(math.floor(vec4.x * 255), math.floor(vec4.y * 255), math.floor(vec4.z * 255), math.floor(vec4.w * 255))
end

-- 将ImVec4转换为RaylibColor
local function _convert_imvec4_to_raylib_color(vec4)
    return rl.Color(math.floor(vec4.x * 255), math.floor(vec4.y * 255), math.floor(vec4.z * 255), math.floor(vec4.w * 255))
end

-- 向节点附加引脚的工具函数
local function _attach_pin(node, pin_data, pin_type_id, is_output, name, extra_args)
    local target_list, pin_id = nil, nil
    if is_output then target_list = node._output_pin_list else target_list = node._input_pin_list end
    if pin_data then pin_id = pin_data.id else pin_id = node._blueprint:gen_next_uid() end
    local pin = PinFactory.create(pin_type_id, pin_id, node._id, is_output, name, extra_args)
    if pin_data then pin:on_load(pin_data) end
    table.insert(target_list, pin)
end

local function _base_save(node)
    local data = 
    {
        id = node._id:get(),
        type_id = node._type_id,
        input_pin_list = {},
        output_pin_list = {},
        position = {x = 0, y = 0}
    }
    local position = imgui.NodeEditor.GetNodePosition(node._id)
    data.position.x, data.position.y = math.floor(position.x), math.floor(position.y)
    for _, pin in ipairs(node._input_pin_list) do
        table.insert(data.input_pin_list, pin:on_save())
    end
    for _, pin in ipairs(node._output_pin_list) do
        table.insert(data.output_pin_list, pin:on_save())
    end
    return data
end

local color_comment <const> = imgui.ImColor(150, 150, 150, 255)

local metatable = 
{
    __index =
    {
        on_update = function(self)
            local min_rect, max_rect = nil, nil
            imgui.NodeEditor.BeginNode(self._id)
                -- 当_header_color字段存在时，则为流程节点
                if self._header_color then
                    imgui.BeginGroup()
                        if self._icon then
                            -- 根据是否存在注释自动切换图标尺寸
                            local size = size_icon_min if self._comment then size = size_icon_max end
                            imgui.Image(self._icon, size, nil, nil, nil, nil) 
                        end
                    imgui.EndGroup()
                    imgui.SameLine()
                    imgui.BeginGroup()
                        if self._title then imgui.Text(self._title) end
                        if self._comment then imgui.TextColored(color_comment.value, self._comment) end
                    imgui.EndGroup()
                    imgui.Dummy(imgui.ImVec2(0, 0))
                    max_rect = imgui.GetItemRectMax()
                end
                -- 这里对输入引脚进行了特判避免布局错乱
                if #self._input_pin_list > 0 then
                    imgui.BeginGroup()
                        for _, pin in ipairs(self._input_pin_list) do
                            pin:on_update()
                        end
                    imgui.EndGroup()
                    imgui.SameLine()
                end
                imgui.Dummy(imgui.ImVec2(self._dummy_width, 0))
                imgui.SameLine()
                imgui.BeginGroup()
                    for _, pin in ipairs(self._output_pin_list) do
                        pin:on_update()
                    end
                imgui.EndGroup()
            imgui.NodeEditor.EndNode()
            if self._header_color then
                local min_rect = imgui.GetItemRectMin()
                max_rect.x = imgui.GetItemRectMax().x
                imgui.NodeEditor.AddNodeHeaderBackground(self._id, 
                    ResourcesManager.find_icon("bp_bg"), self._header_color, min_rect, max_rect)
            end
        end,
        on_save = function(self) return _base_save(self) end,
        query_menu_id = function(self) end,
        on_show_menu = function(self) end,
        on_exetute = function(self, scene) end,
        on_exetute_update = function(self, scene, delta) end,
    }
}

local function _base_constructor(blueprint, data, type_id, dummy_width, icon, header_color, title, comment)
    local o = 
    {
        _blueprint = blueprint,
        _id = nil,
        _type_id = type_id,
        _dummy_width = dummy_width or 0,
        _icon = icon,
        _header_color = header_color,
        _title = title,
        _comment = comment,
        _input_pin_list = {},
        _output_pin_list = {},
        _position = {x = 0, y = 0},
    }
    if data then
        o._id = imgui.NodeEditor.NodeId(data.id)
        o._position.x, o._position.y = data.position.x, data.position.y
        imgui.NodeEditor.SetNodePosition(o._id, imgui.ImVec2(data.position.x, data.position.y))
    else
        o._id = imgui.NodeEditor.NodeId(blueprint:gen_next_uid())
    end
    setmetatable(o, metatable)
    return o
end

local function _execute_next_node(self, idx_route)
    idx_route = idx_route or 1
    local next_node, next_pin = nil, nil
    if self._output_pin_list[idx_route]._linked_pin_id then
        next_pin = GlobalContext.runtime_find_pin(self._output_pin_list[idx_route]._linked_pin_id:get())
        next_node = GlobalContext.runtime_find_node(next_pin._owner_id:get())
    end
    self._blueprint:execute_node(next_node, next_pin)
end

local function _wait_interact_to_next_node(self, idx_route)
    if GlobalContext.is_simulated_interaction or rl.IsMouseButtonPressed(rl.MouseButton.LEFT) or rl.IsKeyPressed(rl.KeyboardKey.SPACE) then
        _execute_next_node(self, idx_route)
    end
end

construct_func_pool["comment"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "comment")
    node._cstring = util.CString(NodeDef.comment.name)
    node._prev_text = node._cstring:get()
    node._size = {x = 600, y = 300}
    if data then
        node._cstring:set(data.text)
        node._size.x, node._size.y = data.size.x, data.size.y
    end
    node.on_update = function(self)
        imgui.NodeEditor.Comment(self._id, self._cstring:get(), imgui.ImVec2(self._size.x, self._size.y))
        local size = imgui.NodeEditor.GetNodeSize(self._id)
        -- x:16 y:38 为注释节点内容尺寸与实际渲染节点尺寸的差值
        if size.x - 16 ~= node._size.x or size.y - 38 ~= node._size.y then
            node._size.x, node._size.y = size.x - 16, size.y - 38
            ModifyManager.set_modify(true)
        end
    end
    node.on_save = function(self)
        local data = _base_save(self)
        data.text = self._cstring:get()
        data.size = {x = self._size.x, y = self._size.y}
        return data
    end
    node.query_menu_id = function(self)
        return string.format("comment_node_%d", self._id:get())
    end
    node.on_show_menu = function(self)
        imgui.Text("注释内容：")
        imgui.SameLine()
        imgui.SetNextItemWidth(100)
        imgui.InputText(string.format("##comment_%d", self._id:get()), self._cstring)
        if imgui.IsItemDeactivatedAfterEdit() then
            UndoManager.record(function(data) 
                    node._cstring:set(data.old) 
                    node._prev_text = data.old
                end, function(data) 
                    node._cstring:set(data.new) 
                    node._prev_text = data.new
                end, {old = node._prev_text, new = node._cstring:get()})
            node._prev_text = node._cstring:get()
        end
    end
    return node
end

construct_func_pool["extend_pins"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "extend_pins", 25, ResourcesManager.find_icon(NodeDef.extend_pins.icon_id),
        NodeDef.extend_pins.color, NodeDef.extend_pins.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "object", false)
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "         ")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "object", true, "扩展1")
    _attach_pin(node, data and data.output_pin_list[3] or nil, "object", true, "扩展2")
    _attach_pin(node, data and data.output_pin_list[4] or nil, "object", true, "扩展3")
    node.on_exetute = function(self, scene)
        local val = self._input_pin_list[2]:get_val()
        self._output_pin_list[2]:set_val(val)
        self._output_pin_list[3]:set_val(val)
        self._output_pin_list[4]:set_val(val)
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["merge_flow"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "merge_flow", 25, ResourcesManager.find_icon(NodeDef.merge_flow.icon_id),
        NodeDef.merge_flow.color, NodeDef.merge_flow.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false, "流程1")
    _attach_pin(node, data and data.input_pin_list[2] or nil, "flow", false, "流程2")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "flow", false, "流程3")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    node.on_exetute = function(self, scene)
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["entry"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "entry", 140, ResourcesManager.find_icon(NodeDef.entry.icon_id), 
        NodeDef.entry.color, NodeDef.entry.name, NodeDef.entry.comment)
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    node.on_exetute = function(self, scene)
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["branch"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "branch", 25, ResourcesManager.find_icon(NodeDef.branch.icon_id), 
        NodeDef.branch.color, NodeDef.branch.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "bool", false)
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "真")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "flow", true, "假")
    node.on_exetute = function(self, scene)
        if self._input_pin_list[2]:get_val() then
            _execute_next_node(self, 1)
        else
            _execute_next_node(self, 2)
        end
    end
    return node
end

construct_func_pool["loop"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "loop", 0, ResourcesManager.find_icon(NodeDef.loop.icon_id), 
        NodeDef.loop.color, NodeDef.loop.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "flow", false, "再次执行")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "flow", false, "结束循环")
    _attach_pin(node, data and data.input_pin_list[4] or nil, "int", false, "循环次数")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "             ")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "flow", true, "   循环体")
    _attach_pin(node, data and data.output_pin_list[3] or nil, "int", true, "当前次数", {can_edit = false})
    if not data then
        node._input_pin_list[4]:set_val(-1)
    end
    node.num_loop_completed = 0
    node.on_exetute = function(self, scene, entry_pin)
        local target_num_loop = self._input_pin_list[4]:get_val()
        if entry_pin == self._input_pin_list[1] then
            self.num_loop_completed = 0
            if target_num_loop == 0 then
                _execute_next_node(self, 1)
            else
                self._output_pin_list[3]:set_val(1)
                _execute_next_node(self, 2)
            end
        elseif entry_pin == self._input_pin_list[2] then
            self.num_loop_completed = self.num_loop_completed + 1
            if target_num_loop > 0 and self.num_loop_completed >= target_num_loop then
                _execute_next_node(self, 1)
            else
                local max_num_loop <const> = 10000
                if node.num_loop_completed > max_num_loop then
                    LogManager.log(string.format("节点[#%d]：循环超过最大次数上限[%d]，请检查循环条件", self._id:get(), max_num_loop), 
                        "error", {blueprint = self._blueprint._id, id = self._id:get()})
                    GlobalContext.stop_debug()
                    return
                end
                self._output_pin_list[3]:set_val(self.num_loop_completed + 1)
                _execute_next_node(self, 2)
            end
        else
            _execute_next_node(self, 1)
        end
    end
    return node
end

construct_func_pool["switch_scene"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "switch_scene", 0, ResourcesManager.find_icon(NodeDef.switch_scene.icon_id), 
        NodeDef.switch_scene.color, NodeDef.switch_scene.name, NodeDef.switch_scene.comment)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "string", false, "场景ID")
    node.on_exetute = function(self, scene)
        local id_scene = self._input_pin_list[2]:get_val()
        for _, blueprint in ipairs(GlobalContext.blueprint_list) do
            if id_scene == blueprint._id then
                GlobalContext.current_blueprint = blueprint
                blueprint:execute()
                return
            end
        end
        LogManager.log(string.format("节点[#%d]：无法找到指定ID的场景", self._id:get()), 
            "error", {blueprint = self._blueprint._id, id = self._id:get()})
        GlobalContext.stop_debug()
        return
    end
    return node
end

construct_func_pool["find_object"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "find_object", 0, ResourcesManager.find_icon(NodeDef.find_object.icon_id), 
        NodeDef.find_object.color, NodeDef.find_object.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "string", false, "对象ID")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "       ")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "flow", true, "失败")
    _attach_pin(node, data and data.output_pin_list[3] or nil, "object", true)
    node.on_exetute = function(self, scene)
        local id_object = self._input_pin_list[2]:get_val()
        local object = scene:find_object(id_object)
        self._output_pin_list[3]:set_val(object)
        if object then
            _execute_next_node(self, 1)
        else
            _execute_next_node(self, 2)
        end
    end
    return node
end

construct_func_pool["save_global"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "save_global", 0, ResourcesManager.find_icon(NodeDef.save_global.icon_id), 
        NodeDef.save_global.color, NodeDef.save_global.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "string", false, "键")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "object", false, "值")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    node.on_exetute = function(self, scene)
        local id_object = self._input_pin_list[2]:get_val()
        local object = self._input_pin_list[3]:get_val()
        GlobalContext.runtime_global_context[id_object] = object
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["load_global"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "load_global", 0, ResourcesManager.find_icon(NodeDef.load_global.icon_id), 
        NodeDef.load_global.color, NodeDef.load_global.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "string", false, "键")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "       ")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "flow", true, "失败")
    _attach_pin(node, data and data.output_pin_list[3] or nil, "object", true, "   值")
    node.on_exetute = function(self, scene)
        local id_object = self._input_pin_list[2]:get_val()
        local object = GlobalContext.runtime_global_context[id_object]
        self._output_pin_list[3]:set_val(object)
        if object then
            _execute_next_node(self, 1)
        else
            _execute_next_node(self, 2)
        end
    end
    return node
end

construct_func_pool["vector2"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "vector2")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "vector2", true, nil, {width_input = 100})
    return node
end

construct_func_pool["color"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "color")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "color", true, nil, {full_edit = true})
    return node
end

construct_func_pool["string"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "string")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "string", true, nil, {width_input = 100})
    return node
end

construct_func_pool["int"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "int")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "int", true, nil, {width_input = 100})
    return node
end

construct_func_pool["float"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "float")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "float", true, nil, {width_input = 100})
    return node
end

construct_func_pool["bool"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "bool")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "bool", true)
    return node
end

construct_func_pool["random_int"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "random_int", 0, 
        ResourcesManager.find_icon(NodeDef.random_int.icon_id), NodeDef.random_int.color, NodeDef.random_int.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "int", false, "最小值")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "int", false, "最大值")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "       ")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "int", true, nil, {can_edit = false})
    if not data then
        node._input_pin_list[2]:set_val(0)
        node._input_pin_list[3]:set_val(100)
    end
    node.on_exetute = function(self, scene)
        local min_val = self._input_pin_list[2]:get_val()
        local max_val = self._input_pin_list[3]:get_val()
        if min_val > max_val then
            LogManager.log(string.format("节点[#%d]：随机数范围定义错误，最小值大于最大值", self._id:get()), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        self._output_pin_list[2]:set_val(math.random(min_val, max_val))
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["assemble_vector2"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "assemble_vector2", 0, 
        ResourcesManager.find_icon(NodeDef.assemble_vector2.icon_id), NodeDef.assemble_vector2.color, NodeDef.assemble_vector2.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "float", false, "X")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "float", false, "Y")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "              ")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "vector2", true, nil, {can_edit = false})
    node.on_exetute = function(self, scene)
        local x_val = self._input_pin_list[2]:get_val()
        local y_val = self._input_pin_list[3]:get_val()
        self._output_pin_list[2]:set_val(imgui.ImVec2(x_val, y_val))
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["equal"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "equal", 0, ResourcesManager.find_icon(NodeDef.equal.icon_id), NodeDef.equal.color, NodeDef.equal.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "object", false, "左值")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "object", false, "右值")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "bool", true, "", {can_edit = false})
    node.on_exetute = function(self, scene)
        local left_val = self._input_pin_list[2]:get_val()
        local right_val = self._input_pin_list[3]:get_val()
        self._output_pin_list[2]:set_val(left_val == right_val)
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["less"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "less", 0, ResourcesManager.find_icon(NodeDef.less.icon_id), NodeDef.less.color, NodeDef.less.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "object", false, "左值")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "object", false, "右值")
    _attach_pin(node, data and data.input_pin_list[4] or nil, "bool", false, "包含临界值")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "bool", true, "", {can_edit = false})
    node.on_exetute = function(self, scene)
        local left_val = self._input_pin_list[2]:get_val()
        local right_val = self._input_pin_list[3]:get_val()
        local status, result = pcall(function()
            if self._input_pin_list[4]:get_val() then
                return left_val <= right_val
            else
                return left_val < right_val
            end
        end)
        if status then
            self._output_pin_list[2]:set_val(result)
        else
            LogManager.log(string.format("节点[#%d]：运算在当前输入类型无效，“%s”与“%s”", self._id:get(), type(left_val), type(right_val)), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["greater"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "greater", 0, ResourcesManager.find_icon(NodeDef.greater.icon_id), NodeDef.greater.color, NodeDef.greater.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "object", false, "左值")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "object", false, "右值")
    _attach_pin(node, data and data.input_pin_list[4] or nil, "bool", false, "包含临界值")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "bool", true, "", {can_edit = false})
    node.on_exetute = function(self, scene)
        local left_val = self._input_pin_list[2]:get_val()
        local right_val = self._input_pin_list[3]:get_val()
        local status, result = pcall(function()
            if self._input_pin_list[4]:get_val() then
                return left_val >= right_val
            else
                return left_val > right_val
            end
        end)
        if status then
            self._output_pin_list[2]:set_val(result)
        else
            LogManager.log(string.format("节点[#%d]：运算在当前输入类型无效，“%s”与“%s”", self._id:get(), type(left_val), type(right_val)), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["floor"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "floor", 0, ResourcesManager.find_icon(NodeDef.floor.icon_id), NodeDef.floor.color, NodeDef.floor.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "float", false, "")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "int", true, "", {can_edit = false})
    node.on_exetute = function(self, scene)
        self._output_pin_list[2]:set_val(math.floor(self._input_pin_list[2]:get_val()))
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["ceil"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "ceil", 0, ResourcesManager.find_icon(NodeDef.ceil.icon_id), NodeDef.ceil.color, NodeDef.ceil.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "float", false, "")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "int", true, "", {can_edit = false})
    node.on_exetute = function(self, scene)
        self._output_pin_list[2]:set_val(math.ceil(self._input_pin_list[2]:get_val()))
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["round"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "round", 0, ResourcesManager.find_icon(NodeDef.round.icon_id), NodeDef.round.color, NodeDef.round.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "float", false, "")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "int", true, "", {can_edit = false})
    node.on_exetute = function(self, scene)
        local val, result = self._input_pin_list[2]:get_val(), 0
        if val >= 0 then result = math.floor(val + 0.5) else result = math.ceil(val - 0.5) end
        self._output_pin_list[2]:set_val(result)
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["font"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "font")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "font", true, nil, {width_input = 100})
    return node
end

construct_func_pool["audio"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "audio")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "audio", true, nil, {width_input = 100})
    return node
end

construct_func_pool["shader"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "shader")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "shader", true, nil, {width_input = 100})
    return node
end

construct_func_pool["texture"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "texture")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "texture", true, nil, {width_input = 100})
    return node
end

construct_func_pool["print"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "print", 80, ResourcesManager.find_icon(NodeDef.print.icon_id), 
        NodeDef.print.color, NodeDef.print.name, NodeDef.print.comment)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "object", false, "值")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    node.on_exetute = function(self, scene)
        LogManager.log(tostring(self._input_pin_list[2]:get_val()), "debug")
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["delay"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "delay", 0, ResourcesManager.find_icon(NodeDef.delay.icon_id), 
        NodeDef.delay.color, NodeDef.delay.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "float", false, "秒")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    node.on_exetute = function(self, scene)
        local val = node._input_pin_list[2]:get_val() if val < 0 then val = 0 end
        scene:add_object(Timer.new(val, function(timer) 
            _execute_next_node(self)
            timer:make_invalid()
        end, true), string.format("timer_%d", self._id:get()))
    end
    return node
end

construct_func_pool["wait_interaction"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "wait_interaction", 55, ResourcesManager.find_icon(NodeDef.wait_interaction.icon_id), 
        NodeDef.wait_interaction.color, NodeDef.wait_interaction.name, NodeDef.wait_interaction.comment)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "bool", false, "等待互动")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    if not data then node._input_pin_list[2]:set_val(true) end
    node.on_exetute_update = function(self, scene, delta)
        if self._input_pin_list[2]:get_val() then
            _wait_interact_to_next_node(self)
        else
            _execute_next_node(self)
        end
    end
    return node
end

construct_func_pool["switch_background"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "switch_background", 0, ResourcesManager.find_icon(NodeDef.switch_background.icon_id), 
        NodeDef.switch_background.color, NodeDef.switch_background.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "texture", false, "纹理")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "float", false, "淡入时间")
    _attach_pin(node, data and data.input_pin_list[4] or nil, "bool", false, "等待互动")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    if not data then
        node._input_pin_list[3]:set_val(1)
        node._input_pin_list[4]:set_val(true)
    end
    local id_game_object <const> = "bp-background"
    node.on_exetute = function(self, scene)
        local background_obj = scene:find_object(id_game_object)
        if not background_obj then
            background_obj = GameObject.new()
            background_obj._metaname = "BackgroundObject"
            background_obj.alpha_next = 0
            background_obj.texture_prev = nil
            background_obj.texture_next = nil
            background_obj.on_render = function(self)
                local origin <const> = rl.Vector2(0, 0)
                local rect_dst <const> = rl.Rectangle(0, 0, GlobalContext.width_game_window, GlobalContext.height_game_window)
                if rawget(self, "texture_prev") then
                    rl.DrawTexturePro(self.texture_prev, rl.Rectangle(0, 0, self.texture_prev.width, self.texture_prev.height), 
                        rect_dst, origin, 0, ColorHelper.WHITE)
                end
                if rawget(self, "texture_next") then
                    rl.DrawTexturePro(self.texture_next, rl.Rectangle(0, 0, self.texture_next.width, self.texture_next.height), 
                        rect_dst, origin, 0, rl.Color(255, 255, 255, math.floor(255 * self.alpha_next)))
                end
            end
            background_obj.on_fade_in_complete = function(self)
                self.texture_prev = self.texture_next
                self.texture_next = nil
                self.alpha_next = 1
            end
            scene:add_object(background_obj, id_game_object, 0)
        end
        background_obj.texture_next = self._input_pin_list[2]:get_val()
        if not rawget(background_obj, "texture_next") then
            LogManager.log(string.format("节点[#%d]：无效的纹理对象输入", self._id:get()), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        background_obj.alpha_next = 0
        local duration_fade_in = self._input_pin_list[3]:get_val()
        if duration_fade_in > 0 then
            scene:add_object(Tween.new(background_obj, "alpha_next", 0, 1, duration_fade_in, function() 
                background_obj:on_fade_in_complete() 
            end), "tween_switch_background")
        else
            background_obj:on_fade_in_complete()
            -- 这里进行了特殊处理，避免转场等效果延后一帧出现
            if not self._input_pin_list[4]:get_val() then
                _execute_next_node(self)
            end
        end
    end
    node.on_exetute_update = function(self, scene, delta)
        local background_obj = scene:find_object(id_game_object)
        if self._input_pin_list[4]:get_val() then
            if background_obj.alpha_next == 1 then
                _wait_interact_to_next_node(self)
            end
        else
            _execute_next_node(self)
        end
    end
    return node
end

construct_func_pool["add_foreground"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "add_foreground", 0, ResourcesManager.find_icon(NodeDef.add_foreground.icon_id), 
        NodeDef.add_foreground.color, NodeDef.add_foreground.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "float", false, "缩放")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "vector2", false, "位置", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[4] or nil, "texture", false, "纹理")
    _attach_pin(node, data and data.input_pin_list[5] or nil, "float", false, "淡入时间")
    _attach_pin(node, data and data.input_pin_list[6] or nil, "bool", false, "等待互动")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "              ")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "object", true, "前景图片")
    if not data then
        node._input_pin_list[2]:set_val(1)
        node._input_pin_list[5]:set_val(0.5)
        node._input_pin_list[6]:set_val(true)
    end
    local id_game_object <const> = string.format("bp-foreground-%d", node._id:get())
    node.on_exetute = function(self, scene)
        local foreground_obj = GameObject.new()
        local position = node._input_pin_list[3]:get_val()
        foreground_obj._metaname = "ForegroundObject"
        foreground_obj.alpha = 0
        foreground_obj.scale = node._input_pin_list[2]:get_val()
        foreground_obj.texture = node._input_pin_list[4]:get_val()
        foreground_obj.position = rl.Vector2(position.x, position.y)
        if not rawget(foreground_obj, "texture") then
            LogManager.log(string.format("节点[#%d]：无效的纹理对象输入", self._id:get()), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        foreground_obj.on_render = function(self)
            rl.DrawTextureEx(self.texture, self.position, 0, self.scale, rl.Color(255, 255, 255, math.floor(255 * self.alpha)))
        end
        foreground_obj.on_fade_in_complete = function(self)
            self.alpha = 1
        end
        scene:add_object(foreground_obj, id_game_object, 0)
        node._output_pin_list[2]:set_val(foreground_obj)
        local duration_fade_in = self._input_pin_list[5]:get_val()
        if duration_fade_in > 0 then
            scene:add_object(Tween.new(foreground_obj, "alpha", 0, 1, duration_fade_in, function() 
                foreground_obj:on_fade_in_complete() 
            end), string.format("tween_add_foreground_%d", node._id:get()))
        else
            foreground_obj:on_fade_in_complete()
            -- 这里进行了特殊处理，避免转场等效果延后一帧出现
            if not self._input_pin_list[6]:get_val() then
                _execute_next_node(self)
            end
        end
    end
    node.on_exetute_update = function(self, scene, delta)
        local foreground_obj = scene:find_object(id_game_object)
        if self._input_pin_list[6]:get_val() then
            if foreground_obj.alpha == 1 then
                _wait_interact_to_next_node(self)
            end
        else
            _execute_next_node(self)
        end
    end
    return node
end

construct_func_pool["remove_foreground"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "remove_foreground", 0, ResourcesManager.find_icon(NodeDef.remove_foreground.icon_id), 
        NodeDef.remove_foreground.color, NodeDef.remove_foreground.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "object", false, "前景图片")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "float", false, "淡出时间")
    _attach_pin(node, data and data.input_pin_list[4] or nil, "bool", false, "等待互动")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    if not data then
        node._input_pin_list[3]:set_val(0.5)
        node._input_pin_list[4]:set_val(true)
    end
    node.on_exetute = function(self, scene)
        local foreground_obj = self._input_pin_list[2]:get_val()
        local time = self._input_pin_list[3]:get_val()
        if not foreground_obj or foreground_obj._metaname ~= "ForegroundObject" then
            LogManager.log(string.format("节点[#%d]：无效的前景图片对象输入", self._id:get(), type(left_val), type(right_val)), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        if time > 0 then
            scene:add_object(Tween.new(foreground_obj, "alpha", 1, 0, time, function() 
                foreground_obj:make_invalid()
            end), string.format("tween_remove_foreground_%d", node._id:get()))
        else
            foreground_obj:make_invalid()
            -- 这里进行了特殊处理，避免转场等效果延后一帧出现
            if not self._input_pin_list[4]:get_val() then
                _execute_next_node(self)
            end
        end
    end
    node.on_exetute_update = function(self, scene, delta)
        if self._input_pin_list[4]:get_val() then
            if self._input_pin_list[2]:get_val().alpha <= 0 then
                _wait_interact_to_next_node(self)
            end
        else
            _execute_next_node(self)
        end
    end
    return node
end

construct_func_pool["move_foreground"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "move_foreground", 0, ResourcesManager.find_icon(NodeDef.move_foreground.icon_id), 
        NodeDef.move_foreground.color, NodeDef.move_foreground.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "object", false, "前景图片")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "vector2", false, "目标位置", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[4] or nil, "float", false, "时间")
    _attach_pin(node, data and data.input_pin_list[5] or nil, "bool", false, "等待互动")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    if not data then
        node._input_pin_list[4]:set_val(0.5)
        node._input_pin_list[5]:set_val(true)
    end
    node.on_exetute = function(self, scene)
        local foreground_obj = self._input_pin_list[2]:get_val()
        local position = node._input_pin_list[3]:get_val()
        local time = self._input_pin_list[4]:get_val()
        if not foreground_obj or foreground_obj._metaname ~= "ForegroundObject" then
            LogManager.log(string.format("节点[#%d]：无效的前景图片对象输入", self._id:get(), type(left_val), type(right_val)), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        foreground_obj.move_progress = 0
        foreground_obj.src_position = rl.Vector2(foreground_obj.position.x, foreground_obj.position.y)
        foreground_obj.dst_position = rl.Vector2(position.x, position.y)
        foreground_obj.on_update = function(self, delta)
            if self.move_progress < 1 then
                self.position.x = math.lerp(self.src_position.x, self.dst_position.x, self.move_progress)
                self.position.y = math.lerp(self.src_position.y, self.dst_position.y, self.move_progress)
            end
        end
        foreground_obj.on_move_complete = function(self)
            self.position = self.dst_position
        end
        if time > 0 then
            scene:add_object(Tween.new(foreground_obj, "move_progress", 0, 1, time, function() 
                foreground_obj:on_move_complete()
            end, "out"), string.format("tween_remove_foreground_%d", node._id:get()))
        else
            foreground_obj:on_move_complete()
        end
    end
    node.on_exetute_update = function(self, scene, delta)
        if self._input_pin_list[5]:get_val() then
            if self._input_pin_list[2]:get_val().move_progress >= 1 then
                _wait_interact_to_next_node(self)
            end
        else
            _execute_next_node(self)
        end
    end
    return node
end

construct_func_pool["show_letterboxing"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "show_letterboxing", 0, ResourcesManager.find_icon(NodeDef.show_letterboxing.icon_id), 
        NodeDef.show_letterboxing.color, NodeDef.show_letterboxing.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "float", false, "高度")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "float", false, "缓入时间")
    _attach_pin(node, data and data.input_pin_list[4] or nil, "bool", false, "等待互动")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    if not data then
        node._input_pin_list[2]:set_val(200)
        node._input_pin_list[3]:set_val(1.5)
    end
    local id_game_object <const> = "bp-letterboxing"
    node.on_exetute = function(self, scene)
        local letterboxing = scene:find_object(id_game_object)
        if not letterboxing then
            letterboxing = GameObject.new()
            letterboxing._metaname = "Letterboxing"
            letterboxing.progress = 0
            letterboxing.on_render = function(self)
                local full_height <const> = node._input_pin_list[2]:get_val()
                local rect = rl.Rectangle(0, 0, GlobalContext.width_game_window, full_height * self.progress)
                rl.DrawRectangleRec(rect, ColorHelper.BLACK)
                rect.y = GlobalContext.height_game_window - rect.height
                rl.DrawRectangleRec(rect, ColorHelper.BLACK)
            end
            letterboxing.on_show_complete = function(self)
                self.progress = 1
            end
            letterboxing.on_hide_complete = function(self)
                self.progress = 0
            end
            scene:add_object(letterboxing, id_game_object, 80)
        end
        local duration_ease = self._input_pin_list[3]:get_val()
        if duration_ease > 0 then
            scene:add_object(Tween.new(letterboxing, "progress", 0, 1, duration_ease, function()
                letterboxing:on_show_complete() 
            end, "out"), "tween_letterboxing")
        else
            letterboxing:on_show_complete()
        end
    end
    node.on_exetute_update = function(self, scene, delta)
        local letterboxing = scene:find_object(id_game_object)
        if self._input_pin_list[4]:get_val() then
            if letterboxing.progress == 1 then
                _wait_interact_to_next_node(self)
            end
        else
            _execute_next_node(self)
        end
    end
    return node
end

construct_func_pool["hide_letterboxing"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "hide_letterboxing", 0, ResourcesManager.find_icon(NodeDef.hide_letterboxing.icon_id), 
        NodeDef.hide_letterboxing.color, NodeDef.hide_letterboxing.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "float", false, "缓出时间")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "bool", false, "等待互动")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    if not data then
        node._input_pin_list[2]:set_val(1.5)
    end
    local id_game_object <const> = "bp-letterboxing"
    node.on_exetute = function(self, scene)
        local letterboxing = scene:find_object(id_game_object)
        if not letterboxing then return end
        local duration_ease = self._input_pin_list[2]:get_val()
        if duration_ease > 0 then
            scene:add_object(Tween.new(letterboxing, "progress", 1, 0, duration_ease, function()
                letterboxing:on_hide_complete()
            end, "out"), "tween_letterboxing")
        else
            letterboxing:on_hide_complete()
        end
    end
    node.on_exetute_update = function(self, scene, delta)
        local letterboxing = scene:find_object(id_game_object)
        if self._input_pin_list[3]:get_val() then
            if not letterboxing or letterboxing.progress == 0 then
                _wait_interact_to_next_node(self)
            end
        else
            _execute_next_node(self)
        end
    end
    return node
end

construct_func_pool["show_subtitle"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "show_subtitle", 0, ResourcesManager.find_icon(NodeDef.show_subtitle.icon_id), 
        NodeDef.show_subtitle.color, NodeDef.show_subtitle.name, NodeDef.show_subtitle.comment)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "string", false, "文本", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[3] or nil, "float", false, "字符时间间隔")
    _attach_pin(node, data and data.input_pin_list[4] or nil, "float", false, "屏幕底部距离")
    _attach_pin(node, data and data.input_pin_list[5] or nil, "font", false, "字体")
    _attach_pin(node, data and data.input_pin_list[6] or nil, "int", false, "字号", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[7] or nil, "color", false, "颜色", {full_edit = false})
    _attach_pin(node, data and data.input_pin_list[8] or nil, "bool", false, "等待互动")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    if not data then
        node._input_pin_list[3]:set_val(0.03)
        node._input_pin_list[4]:set_val(40)
        node._input_pin_list[6]:set_val(25)
        node._input_pin_list[7]:set_val(imgui.ImVec4(0.95, 0.95, 0.95, 1))
        node._input_pin_list[8]:set_val(true)
    end
    local id_game_object <const> = "bp-subtitle"
    node.on_exetute = function(self, scene)
        local subtitle = scene:find_object(id_game_object)
        if not subtitle then
            subtitle = GameObject.new()
            subtitle._metaname = "Subtitle"
            subtitle.on_render = function(self)
                if not self.is_visible then return end
                rl.DrawTextureV(self.text_object.texture, rl.Vector2((GlobalContext.width_game_window - self.text_object.w) / 2, 
                    GlobalContext.height_game_window - node._input_pin_list[4]:get_val() + - self.text_object.h), ColorHelper.WHITE)
            end
            scene:add_object(subtitle, id_game_object, 85)
        end
        subtitle.idx_text = 1
        subtitle.is_visible = true
        subtitle.can_push_on = false
        local text = self._input_pin_list[2]:get_val()
        local font_obj = self._input_pin_list[5]:get_val()
        local font_size = self._input_pin_list[6]:get_val()
        if not font_obj then
            LogManager.log(string.format("节点[#%d]：无效的字体对象输入", self._id:get()), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        if font_size < 1 then
            LogManager.log(string.format("节点[#%d]：无效的字号输入", self._id:get()), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        local font = font_obj:get(font_size)
        local color_vec4 = self._input_pin_list[7]:get_val()
        local color_sdl = sdl.Color(math.floor(255 * color_vec4.x), math.floor(255 * color_vec4.y), 
            math.floor(255 * color_vec4.z), math.floor(255 * color_vec4.w))
        local interval = self._input_pin_list[3]:get_val() if interval < 0 then interval = 0 end
        subtitle.text_object = TextWrapper.new(font, util.UTF8Sub(text, 0, 1), color_sdl)
        scene:add_object(Timer.new(interval, function(timer)
            subtitle.idx_text = subtitle.idx_text + 1
            if subtitle.idx_text > util.UTF8Len(text) then
                subtitle.can_push_on = true
                timer:make_invalid()
            end
            subtitle.text_object:set_text(util.UTF8Sub(text, 0, subtitle.idx_text))
        end, false), "timer_subtitle")
    end
    node.on_exetute_update = function(self, scene, delta)
        local subtitle = scene:find_object(id_game_object)
        if self._input_pin_list[8]:get_val() then
            if subtitle.can_push_on then
                _wait_interact_to_next_node(self)
            end
        else
            _execute_next_node(self)
        end
    end
    return node
end

construct_func_pool["hide_subtitle"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "hide_subtitle", 30, ResourcesManager.find_icon(NodeDef.hide_subtitle.icon_id), 
        NodeDef.hide_subtitle.color, NodeDef.hide_subtitle.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    node.on_exetute = function(self, scene)
        local subtitle = scene:find_object("bp-subtitle")
        if not subtitle then return end
        subtitle.is_visible = false
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["show_dialog_box"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "show_dialog_box", 0, ResourcesManager.find_icon(NodeDef.show_dialog_box.icon_id), 
        NodeDef.show_dialog_box.color, NodeDef.show_dialog_box.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "string", false, "角色文本", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[3] or nil, "string", false, "内容文本", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[4] or nil, "vector2", false, "位置", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[5] or nil, "float", false, "宽度")
    _attach_pin(node, data and data.input_pin_list[6] or nil, "float", false, "淡入时间")
    _attach_pin(node, data and data.input_pin_list[7] or nil, "font", false, "角色字体")
    _attach_pin(node, data and data.input_pin_list[8] or nil, "font", false, "内容字体")
    _attach_pin(node, data and data.input_pin_list[9] or nil, "int", false, "角色字号", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[10] or nil, "int", false, "内容字号", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[11] or nil, "color", false, "角色颜色", {full_edit = false})
    _attach_pin(node, data and data.input_pin_list[12] or nil, "color", false, "内容颜色", {full_edit = false})
    _attach_pin(node, data and data.input_pin_list[13] or nil, "color", false, "背景颜色", {full_edit = false})
    _attach_pin(node, data and data.input_pin_list[14] or nil, "bool", false, "等待互动")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "          ")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "object", true, "对话框")
    if not data then
        node._input_pin_list[5]:set_val(420)
        node._input_pin_list[6]:set_val(1.0)
        node._input_pin_list[9]:set_val(20)
        node._input_pin_list[10]:set_val(25)
        node._input_pin_list[11]:set_val(imgui.ImVec4(0.95, 0.95, 0.95, 1))
        node._input_pin_list[12]:set_val(imgui.ImVec4(0.75, 0.75, 0.75, 1))
        node._input_pin_list[13]:set_val(imgui.ImVec4(0, 0, 0, 0.7))
        node._input_pin_list[14]:set_val(true)
    end
    local id_game_object <const> = string.format("dialog_box_%d", node._id:get())
    node.on_exetute = function(self, scene)
        local name = self._input_pin_list[2]:get_val()
        local dialogue = self._input_pin_list[3]:get_val()
        local position = self._input_pin_list[4]:get_val()
        local width = self._input_pin_list[5]:get_val()
        local font_name = self._input_pin_list[7]:get_val()
        local font_size_name = self._input_pin_list[9]:get_val()
        local font_dialog = self._input_pin_list[8]:get_val()
        local font_size_dialog = self._input_pin_list[10]:get_val()
        local color_name = _convert_imvec4_to_sdl_color(self._input_pin_list[11]:get_val())
        local color_dialog = _convert_imvec4_to_sdl_color(self._input_pin_list[12]:get_val())
        local color_bg = _convert_imvec4_to_sdl_color(self._input_pin_list[13]:get_val())
        local time = self._input_pin_list[6]:get_val()
        if not font_name or not font_dialog then
            LogManager.log(string.format("节点[#%d]：无效的字体对象输入", self._id:get()), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        if font_size_name < 1 or font_size_dialog < 1 then
            LogManager.log(string.format("节点[#%d]：无效的字号输入", self._id:get()), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        local dialog_box = Billboard.new(name, dialogue, position.x, position.y, width, 
            font_name:get(font_size_name), font_dialog:get(font_size_dialog), 
            color_name, color_dialog, color_bg, time < 0 and 0 or time)
        scene:add_object(dialog_box, id_game_object, 50)
        node._output_pin_list[2]:set_val(dialog_box)
    end
    node.on_exetute_update = function(self, scene, delta)
        local dialog_box = scene:find_object(id_game_object)
        if self._input_pin_list[14]:get_val() then
            if dialog_box._progress == 1 then
                _wait_interact_to_next_node(self)
            end
        else
            _execute_next_node(self)
        end
    end
    return node
end

construct_func_pool["hide_dialog_box"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "hide_dialog_box", 0, ResourcesManager.find_icon(NodeDef.hide_dialog_box.icon_id), 
        NodeDef.hide_dialog_box.color, NodeDef.hide_dialog_box.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "object", false, "对话框")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "float", false, "淡出时间")
    _attach_pin(node, data and data.input_pin_list[4] or nil, "bool", false, "等待互动")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    if not data then
        node._input_pin_list[3]:set_val(1)
        node._input_pin_list[4]:set_val(true)
    end
    node.on_exetute = function(self, scene)
        local dialog_box = self._input_pin_list[2]:get_val()
        local time = self._input_pin_list[3]:get_val()
        if not dialog_box or dialog_box._metaname ~= "DialogBox" then
            LogManager.log(string.format("节点[#%d]：无效的对话框对象输入", self._id:get(), type(left_val), type(right_val)), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        dialog_box:hide(time < 0 and 0 or time)
    end
    node.on_exetute_update = function(self, scene, delta)
        if self._input_pin_list[4]:get_val() then
            if self._input_pin_list[2]:get_val()._progress == 0 then
                _wait_interact_to_next_node(self)
            end
        else
            _execute_next_node(self)
        end
    end
    return node
end

construct_func_pool["play_audio"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "play_audio", 20, ResourcesManager.find_icon(NodeDef.play_audio.icon_id), 
        NodeDef.play_audio.color, NodeDef.play_audio.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "audio", false)
    _attach_pin(node, data and data.input_pin_list[3] or nil, "int", false, "循环次数")
    _attach_pin(node, data and data.input_pin_list[4] or nil, "float", false, "音量")
    _attach_pin(node, data and data.input_pin_list[5] or nil, "float", false, "淡入时间")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "       ")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "int", true, "频道", {can_edit = false})
    if not data then
        node._input_pin_list[4]:set_val(1.0)
    end
    node.on_exetute = function(self, scene)
        local audio = self._input_pin_list[2]:get_val()
        local loop = node._input_pin_list[3]:get_val() if loop < 0 then loop = -1 end
        local time = node._input_pin_list[5]:get_val() if time < 0 then time = 0 end
        local volume = math.clamp(node._input_pin_list[4]:get_val(), 0, 1)
        if not audio then
            LogManager.log(string.format("节点[#%d]：无效的音频对象输入", self._id:get()), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        sdl.VolumeChunk(audio, math.floor(volume * sdl.MAX_VOLUME))
        local channel = sdl.FadeInChannel(-1, audio, loop, math.floor(time * 1000))
        if channel == -1 then
            LogManager.log(string.format("节点[#%d]：音频播放失败，请检查资产", self._id:get()), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        node._output_pin_list[2]:set_val(channel)
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["stop_audio"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "stop_audio", 0, ResourcesManager.find_icon(NodeDef.stop_audio.icon_id), 
        NodeDef.stop_audio.color, NodeDef.stop_audio.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "int", false, "频道", {can_edit = false})
    _attach_pin(node, data and data.input_pin_list[3] or nil, "float", false, "淡出时间")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "       ")
    if not data then
        node._input_pin_list[2]:set_val(-1)
    end
    node.on_exetute = function(self, scene)
        local channel = self._input_pin_list[2]:get_val()
        local time = node._input_pin_list[3]:get_val() if time < 0 then time = 0 end
        if channel < 0 then
            LogManager.log(string.format("节点[#%d]：无效的频道输入", self._id:get()), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        sdl.FadeOutChannel(channel, math.floor(time * 1000))
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["stop_all_audio"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "stop_all_audio", 0, ResourcesManager.find_icon(NodeDef.stop_all_audio.icon_id), 
        NodeDef.stop_all_audio.color, NodeDef.stop_all_audio.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "float", false, "淡出时间")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "       ")
    node.on_exetute = function(self, scene)
        local time = node._input_pin_list[2]:get_val() if time < 0 then time = 0 end
        sdl.FadeOutChannel(-1, math.floor(time * 1000))
        _execute_next_node(self)
    end
    return node
end

construct_func_pool["transition_fade_in"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "transition_fade_in", 0, ResourcesManager.find_icon(NodeDef.transition_fade_in.icon_id), 
        NodeDef.transition_fade_in.color, NodeDef.transition_fade_in.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "float", false, "时间")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "bool", false, "等待互动")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    if not data then
        node._input_pin_list[2]:set_val(1)
    end
    local id_game_object <const> = "bp-transition-fade"
    node.on_exetute = function(self, scene)
        local transition_fade_obj = scene:find_object(id_game_object)
        if not transition_fade_obj then
            transition_fade_obj = GameObject.new()
            transition_fade_obj._metaname = "TransitionFade"
            transition_fade_obj.on_render = function(self)
                rl.DrawRectangle(0, 0, GlobalContext.width_game_window, 
                    GlobalContext.height_game_window, rl.Color(0, 0, 0, math.floor(255 * self.alpha)))
            end
            scene:add_object(transition_fade_obj, id_game_object, 100)
        end
        transition_fade_obj.on_fade_in_complete = function(self)
            transition_fade_obj.alpha = 0
        end
        transition_fade_obj.alpha = 1
        local duration_fade = self._input_pin_list[2]:get_val()
        if duration_fade > 0 then
            scene:add_object(Tween.new(transition_fade_obj, "alpha", 1, 0, duration_fade, function() 
                transition_fade_obj:on_fade_in_complete() 
            end), "tween_transition_fade")
        else
            transition_fade_obj:on_fade_in_complete()
        end
    end
    node.on_exetute_update = function(self, scene, delta)
        local transition_fade_obj = scene:find_object(id_game_object)
        if self._input_pin_list[3]:get_val() then
            if transition_fade_obj.alpha == 0 then
                _wait_interact_to_next_node(self)
            end
        else
            _execute_next_node(self)
        end
    end
    return node
end

construct_func_pool["transition_fade_out"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "transition_fade_out", 0, ResourcesManager.find_icon(NodeDef.transition_fade_out.icon_id), 
        NodeDef.transition_fade_out.color, NodeDef.transition_fade_out.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "float", false, "时间")
    _attach_pin(node, data and data.input_pin_list[3] or nil, "bool", false, "等待互动")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true)
    if not data then
        node._input_pin_list[2]:set_val(1)
    end
    local id_game_object <const> = "bp-transition-fade"
    node.on_exetute = function(self, scene)
        local transition_fade_obj = scene:find_object(id_game_object)
        if not transition_fade_obj then
            transition_fade_obj = GameObject.new()
            transition_fade_obj._metaname = "TransitionFade"
            transition_fade_obj.on_render = function(self)
                rl.DrawRectangle(0, 0, GlobalContext.width_game_window, 
                    GlobalContext.height_game_window, rl.Color(0, 0, 0, math.floor(255 * self.alpha)))
            end
            scene:add_object(transition_fade_obj, id_game_object, 100)
        end
        transition_fade_obj.on_fade_in_complete = function(self)
            transition_fade_obj.alpha = 1
        end
        transition_fade_obj.alpha = 0
        local duration_fade = self._input_pin_list[2]:get_val()
        if duration_fade > 0 then
            scene:add_object(Tween.new(transition_fade_obj, "alpha", 0, 1, duration_fade, function() 
                transition_fade_obj:on_fade_in_complete() 
            end), "tween_transition_fade")
        else
            transition_fade_obj:on_fade_in_complete()
        end
    end
    node.on_exetute_update = function(self, scene, delta)
        local transition_fade_obj = scene:find_object(id_game_object)
        if self._input_pin_list[3]:get_val() then
            if transition_fade_obj.alpha == 1 then
                _wait_interact_to_next_node(self)
            end
        else
            _execute_next_node(self)
        end
    end
    return node
end

construct_func_pool["show_choice_button"] = function(blueprint, data)
    local node = _base_constructor(blueprint, data, "show_choice_button", 0, ResourcesManager.find_icon(NodeDef.show_choice_button.icon_id), 
        NodeDef.show_choice_button.color, NodeDef.show_choice_button.name)
    _attach_pin(node, data and data.input_pin_list[1] or nil, "flow", false)
    _attach_pin(node, data and data.input_pin_list[2] or nil, "string", false, "分支文本1", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[3] or nil, "string", false, "分支文本2", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[4] or nil, "string", false, "分支文本3", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[5] or nil, "string", false, "分支文本4", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[6] or nil, "string", false, "分支文本5", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[7] or nil, "font", false, "字体")
    _attach_pin(node, data and data.input_pin_list[8] or nil, "int", false, "字号", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[9] or nil, "color", false, "默认颜色", {full_edit = false})
    _attach_pin(node, data and data.input_pin_list[10] or nil, "color", false, "高亮颜色", {full_edit = false})
    _attach_pin(node, data and data.input_pin_list[11] or nil, "color", false, "背景颜色", {full_edit = false})
    _attach_pin(node, data and data.input_pin_list[12] or nil, "color", false, "边框颜色", {full_edit = false})
    _attach_pin(node, data and data.input_pin_list[13] or nil, "int", false, "按钮间隔")
    _attach_pin(node, data and data.input_pin_list[14] or nil, "vector2", false, "按钮内边距", {width_input = 100})
    _attach_pin(node, data and data.input_pin_list[15] or nil, "float", false, "屏幕底部距离")
    _attach_pin(node, data and data.input_pin_list[16] or nil, "float", false, "按钮最小宽度")
    _attach_pin(node, data and data.output_pin_list[1] or nil, "flow", true, "分支1")
    _attach_pin(node, data and data.output_pin_list[2] or nil, "flow", true, "分支2")
    _attach_pin(node, data and data.output_pin_list[3] or nil, "flow", true, "分支3")
    _attach_pin(node, data and data.output_pin_list[4] or nil, "flow", true, "分支4")
    _attach_pin(node, data and data.output_pin_list[5] or nil, "flow", true, "分支5")
    if not data then
        node._input_pin_list[8]:set_val(25)
        node._input_pin_list[9]:set_val(imgui.ImColor(255, 255, 255, 195).value)
        node._input_pin_list[10]:set_val(imgui.ImColor(104, 163, 68, 225).value)
        node._input_pin_list[11]:set_val(imgui.ImColor(0, 0, 0, 175).value)
        node._input_pin_list[12]:set_val(imgui.ImColor(95, 95, 95, 175).value)
        node._input_pin_list[13]:set_val(20)
        node._input_pin_list[14]:set_val(imgui.ImVec2(100, 12))
        node._input_pin_list[15]:set_val(150)
        node._input_pin_list[16]:set_val(400)
    end
    local id_game_object <const> = "bp-choice-button"
    node.on_exetute = function(self, scene)
        local choice_button = scene:find_object(id_game_object)
        if not choice_button then
            choice_button = BranchSelector
            choice_button._metaname = "ChoiceButton"
            scene:add_object(choice_button, id_game_object, 90)
        end
        local font = node._input_pin_list[7]:get_val()
        local font_size = node._input_pin_list[8]:get_val()
        if not font then
            LogManager.log(string.format("节点[#%d]：无效的字体对象输入", self._id:get()), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        if font_size < 1 then
            LogManager.log(string.format("节点[#%d]：无效的字号输入", self._id:get()), 
                "error", {blueprint = self._blueprint._id, id = self._id:get()})
            GlobalContext.stop_debug()
            return
        end
        choice_button.set_style(node._input_pin_list[13]:get_val(), node._input_pin_list[14]:get_val(), 
            node._input_pin_list[15]:get_val(), node._input_pin_list[16]:get_val(), font, font_size, 
            _convert_imvec4_to_raylib_color(node._input_pin_list[9]:get_val()),
            _convert_imvec4_to_raylib_color(node._input_pin_list[10]:get_val()),
            _convert_imvec4_to_raylib_color(node._input_pin_list[11]:get_val()), 
            _convert_imvec4_to_raylib_color(node._input_pin_list[12]:get_val()))
        local text_list = {}
        local idx_last_text = 2
        -- 找到最后一个有效分支文本
        for i = 6, 2, -1 do
            local text = node._input_pin_list[i]:get_val()
            if #text ~= 0 then
                idx_last_text = i 
                break
            end
        end
        for i = 2, idx_last_text do
            local text = node._input_pin_list[i]:get_val()
            if #text == 0 then text = " " end
            table.insert(text_list, text)
        end
        choice_button.set_text(text_list)
        choice_button.set_callback(function(idx_clicked)
            _execute_next_node(self, idx_clicked)
        end)
    end
    return node
end

module.create = function(blueprint, node_type, data)
    local func = construct_func_pool[node_type]
    assert(func, string.format("unknown node type: %s", node_type))
    return func(blueprint, data)
end

return module