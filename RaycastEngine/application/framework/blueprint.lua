local module = {}

local rl = Engine.Raylib
local util = Engine.Util
local json = Engine.JSON
local imgui = Engine.ImGUI

local Scene = require("application.framework.scene")
local NodeDef = require("application.framework.node_def")
local LogManager = require("application.framework.log_manager")
local NodeFactory = require("application.framework.node_factory")
local UndoManager = require("application.framework.undo_manager")
local ModifyManager = require("application.framework.modify_manager")
local GlobalContext = require("application.framework.global_context")
local ResourcesManager = require("application.framework.resources_manager")

local color_link_accepted = imgui.ImVec4(imgui.ImColor(45, 225, 45, 255).value)
local color_link_rejected = imgui.ImVec4(imgui.ImColor(225, 45, 45, 255).value)

local save_link
local _can_link

local function _deep_copy(val)
    if type(val) ~= "table" then return val end
    local out = {}
    for k, v in pairs(val) do
        out[_deep_copy(k)] = _deep_copy(v)
    end
    return out
end

local function _get_selected_node_id_set(self)
    local set = {}
    for _, node in pairs(self._node_pool) do
        if imgui.NodeEditor.IsNodeSelected(node._id) then
            set[node._id:get()] = true
        end
    end
    return set
end

local function _build_dump_data(self, only_selected)
    local dump_data = {
        max_uid = self._max_uid,
        node_pool = {},
        link_pool = {},
        is_open = self._is_open.val,
    }

    local selected_set = nil
    if only_selected then
        selected_set = _get_selected_node_id_set(self)
    end

    for id, node in pairs(self._node_pool) do
        if (not selected_set) or selected_set[id] then
            table.insert(dump_data.node_pool, node:on_save())
        end
    end

    if selected_set then
        for _, link in pairs(self._link_pool) do
            local owner_in = link.input._owner_id:get()
            local owner_out = link.output._owner_id:get()
            if selected_set[owner_in] and selected_set[owner_out] then
                table.insert(dump_data.link_pool, save_link(link))
            end
        end
    else
        for _, link in pairs(self._link_pool) do
            table.insert(dump_data.link_pool, save_link(link))
        end
    end

    return dump_data
end

local function _validate_blueprint_clipboard_data(data)
    if type(data) ~= "table" then
        return false, "剪贴板内容不是Lua对象/JSON对象"
    end
    if type(data.node_pool) ~= "table" then
        return false, "缺少字段：node_pool"
    end
    if type(data.link_pool) ~= "table" then
        return false, "缺少字段：link_pool"
    end
    if data.max_uid ~= nil and type(data.max_uid) ~= "number" then
        return false, "字段类型错误：max_uid"
    end
    if data.is_open ~= nil and type(data.is_open) ~= "boolean" then
        return false, "字段类型错误：is_open"
    end
    return true, nil
end

local function _spawn_link(self, link, can_undo)
    local function _spawn()
        self._link_pool[link.id:get()] = link
        link.input._linked_pin_id = link.output._id
        link.output._linked_pin_id = link.input._id
    end
    local function _despawn()
        self._link_pool[link.id:get()] = nil
        link.input._linked_pin_id = nil
        link.output._linked_pin_id = nil
    end
    _spawn()
    if can_undo then
        UndoManager.record(_despawn, _spawn)
    end
end

local function _paste_nodes_from_data(self, data, mouse_pos)
    local ok, err = _validate_blueprint_clipboard_data(data)
    if not ok then
        return false, err
    end

    local node_data_list = data.node_pool
    if #node_data_list == 0 then
        return false, "node_pool为空"
    end

    local min_x, min_y = nil, nil
    for _, node_data in pairs(node_data_list) do
        if type(node_data) == "table" and type(node_data.position) == "table" then
            local x, y = node_data.position.x or 0, node_data.position.y or 0
            if not min_x or x < min_x then min_x = x end
            if not min_y or y < min_y then min_y = y end
        end
    end
    min_x, min_y = min_x or 0, min_y or 0

    local map_node_id = {}
    local map_pin_id = {}
    local created_nodes = {}

    for _, node_data in pairs(node_data_list) do
        if type(node_data) == "table" and node_data.type_id ~= "entry" then
            local data_new = _deep_copy(node_data)

            local old_node_id = data_new.id
            local new_node_id = self:gen_next_uid()
            data_new.id = new_node_id
            map_node_id[old_node_id] = new_node_id

            if type(data_new.position) ~= "table" then data_new.position = { x = 0, y = 0 } end
            data_new.position.x = (data_new.position.x or 0) - min_x + mouse_pos.x
            data_new.position.y = (data_new.position.y or 0) - min_y + mouse_pos.y

            if type(data_new.input_pin_list) == "table" then
                for _, pin_data in pairs(data_new.input_pin_list) do
                    if type(pin_data) == "table" then
                        local old_pin_id = pin_data.id
                        local new_pin_id = self:gen_next_uid()
                        pin_data.id = new_pin_id
                        map_pin_id[old_pin_id] = new_pin_id
                    end
                end
            end
            if type(data_new.output_pin_list) == "table" then
                for _, pin_data in pairs(data_new.output_pin_list) do
                    if type(pin_data) == "table" then
                        local old_pin_id = pin_data.id
                        local new_pin_id = self:gen_next_uid()
                        pin_data.id = new_pin_id
                        map_pin_id[old_pin_id] = new_pin_id
                    end
                end
            end

            local node = NodeFactory.create(self, data_new.type_id, data_new)
            self:spawn_node(node, true)
            table.insert(created_nodes, node)
        end
    end

    local created_link_count = 0
    if type(data.link_pool) == "table" then
        for _, link_data in pairs(data.link_pool) do
            if type(link_data) == "table" then
                local old_in = link_data.input_pin_id
                local old_out = link_data.output_pin_id
                local new_in = map_pin_id[old_in]
                local new_out = map_pin_id[old_out]
                if new_in and new_out then
                    local pin_input = self._pin_pool[new_in]
                    local pin_output = self._pin_pool[new_out]
                    if pin_input and pin_output and _can_link(pin_input, pin_output) then
                        local new_link_id = self:gen_next_uid()
                        local link = {
                            id = imgui.NodeEditor.LinkId(new_link_id),
                            input = pin_input,
                            output = pin_output,
                        }
                        _spawn_link(self, link, true)
                        created_link_count = created_link_count + 1
                    end
                end
            end
        end
    end

    imgui.NodeEditor.ClearSelection()
    for _, node in ipairs(created_nodes) do
        imgui.NodeEditor.SelectNode(node._id, true)
    end
    imgui.NodeEditor.NavigateToSelection(true)

    return true, string.format("已粘贴 %d 个节点，%d 条连接", #created_nodes, created_link_count)
end

-- 检查指定引脚对象是否可以被连接
_can_link = function(pin_input, pin_output)
    -- 检查两个引脚是否同处一个节点
    if pin_input._owner_id:get() == pin_output._owner_id:get() then
        return false
    end

    -- 检查是否输出引脚连接到输入引脚上
    if not pin_input._is_output or pin_output._is_output then
        return false
    end

    -- 检查输入输出引脚类型是否匹配
    -- 扩展：object类型引脚接受除去flow外所有类型输入
    -- 扩展：object类型引脚可以连接到除去flow外的所有类型输出
    -- 扩展：int类型引脚可以连接到float引脚
    if (pin_input._type_id == pin_output._type_id)
        or (pin_input._type_id == "object" and pin_output._type_id ~= "flow") 
        or (pin_output._type_id == "object" and pin_input._type_id ~= "flow") 
        or (pin_input._type_id == "int" and pin_output._type_id == "float")
    then
        return true
    end

    return false
end

-- 移除指定id的连接
local function _remove_link_by_link_id(self, id)
    local link = self._link_pool[id:get()]
    if not link then return end

    local undo_data = 
    {
        input_linked_pin_id = link.input._linked_pin_id,
        output_linked_pin_id = link.output._linked_pin_id,
    }

    self._link_pool[id:get()] = nil
    link.input._linked_pin_id = nil
    link.output._linked_pin_id = nil

    return link, undo_data
end

-- 移除指定id节点的连接，is_output用以标注检测目标是否为输出端
local function _remove_link_by_pin_id(self, pin_id, is_output)
    local pin = self._pin_pool[pin_id:get()]
    if not pin then return end

    for id, link in pairs(self._link_pool) do
        if (is_output and link.output == pin) or (not is_output and link.input == pin) then
            return self:_remove_link_by_link_id(imgui.NodeEditor.LinkId(id))
        end
    end
end

-- 删除指定id的节点
local function _remove_node_by_node_id(self, id)
    local node = self._node_pool[id:get()]
    if not node or node._type_id == "entry" then return end

    local undo_data = {input_link_data_list = {}, output_link_data_list = {}}

    -- 删除相关连接
    for _, pin in ipairs(node._input_pin_list) do
        local link, undo = self:_remove_link_by_pin_id(pin._id, true)
        if link then table.insert(undo_data.input_link_data_list, {link = link, undo = undo}) end
    end
    for _, pin in ipairs(node._output_pin_list) do
        local link, undo = self:_remove_link_by_pin_id(pin._id, false)
        if link then table.insert(undo_data.output_link_data_list, {link = link, undo = undo}) end
    end
    -- 删除相关引脚
    for _, pin in ipairs(node._input_pin_list) do
        self._pin_pool[pin._id:get()] = nil
    end
    for _, pin in ipairs(node._output_pin_list) do
        self._pin_pool[pin._id:get()] = nil
    end
    -- 删除节点本身
    self._node_pool[id:get()] = nil

    UndoManager.record(function(data)
        self._node_pool[id:get()] = node
        for _, pin in ipairs(node._input_pin_list) do
            self._pin_pool[pin._id:get()] = pin
        end
        for _, pin in ipairs(node._output_pin_list) do
            self._pin_pool[pin._id:get()] = pin
        end
        for _, info in ipairs(data.input_link_data_list) do
            self._link_pool[info.link.id:get()] = info.link
            info.link.input._linked_pin_id = info.undo.input_linked_pin_id
            info.link.output._linked_pin_id = info.undo.output_linked_pin_id
        end
        for _, info in ipairs(data.output_link_data_list) do
            self._link_pool[info.link.id:get()] = info.link
            info.link.input._linked_pin_id = info.undo.input_linked_pin_id
            info.link.output._linked_pin_id = info.undo.output_linked_pin_id
        end
    end, function(data)
        for _, info in ipairs(data.input_link_data_list) do
            self._link_pool[info.link.id:get()] = nil
            info.link.input._linked_pin_id = nil
            info.link.output._linked_pin_id = nil
        end
        for _, info in ipairs(data.output_link_data_list) do
            self._link_pool[info.link.id:get()] = nil
            info.link.input._linked_pin_id = nil
            info.link.output._linked_pin_id = nil
        end
        for _, pin in ipairs(node._input_pin_list) do
            self._pin_pool[pin._id:get()] = nil
        end
        for _, pin in ipairs(node._output_pin_list) do
            self._pin_pool[pin._id:get()] = nil
        end
        self._node_pool[id:get()] = nil
    end, undo_data)
end

-- 执行实际创建节点工作
local function _create_node_by_def(self, def, position)
    local node = NodeFactory.create(self, def.type_id)
    imgui.NodeEditor.SetNodePosition(node._id, position)
    node._position.x, node._position.y = position.x, position.y
    self:spawn_node(node, true)
    return node
end

-- 节点创建菜单项
local function _menu_item_create_node(self, def, position)
    local height <const> = imgui.GetTextLineHeight()
    local size_icon <const> = imgui.ImVec2(height, height)
    imgui.Image(ResourcesManager.find_icon(def.icon_id), size_icon, nil, nil, def.color, nil)
    imgui.SameLine()
    if imgui.MenuItem(def.name) then
        _create_node_by_def(self, def, position)
    end
end

-- 生成下一个uid，类型为Number
local function gen_next_uid(self)
    self._max_uid = self._max_uid + 1
    return self._max_uid
end

-- 向流程中添加指定node对象
-- 注意：所有的pool中的键均为Number类型的id
local function spawn_node(self, node, can_undo)
    local function _spawn()
        self._node_pool[node._id:get()] = node
        for _, pin in ipairs(node._input_pin_list) do
            self._pin_pool[pin._id:get()] = pin
        end
        for _, pin in ipairs(node._output_pin_list) do
            self._pin_pool[pin._id:get()] = pin
        end
    end
    _spawn()
    if can_undo then
        UndoManager.record(function()
            self._node_pool[node._id:get()] = nil
            for _, pin in ipairs(node._input_pin_list) do
                self._pin_pool[pin._id:get()] = nil
            end
            for _, pin in ipairs(node._output_pin_list) do
                self._pin_pool[pin._id:get()] = nil
            end
        end, _spawn)
    end
end

-- 加载连接
local function load_link(blueprint, data)
    local link = 
    {
        id = imgui.NodeEditor.LinkId(data.id),
        input = blueprint._pin_pool[data.input_pin_id],
        output = blueprint._pin_pool[data.output_pin_id],
    }
    link.input._linked_pin_id = link.output._id
    link.output._linked_pin_id = link.input._id
    return link
end

-- 保存连接
save_link = function(link)
    return 
    {
        id = link.id:get(),
        input_pin_id = link.input._id:get(),
        output_pin_id = link.output._id:get(),
    }
end

-- 加载流程
local function load_document(self)
    local file = io.open(util.UTF8ToGBK(self._path), "r")
    if not file then
        LogManager.log(string.format("无法打开流程文件：%s", self._path), "error")
        -- 打开失败时弹窗提醒
        -- sdl.ShowSimpleMessageBox(sdl.MessageBoxFlOags.ERROR, "打开失败", 
        --     string.format("无法打开文件：%s", self._path), GlobalContext.window)
        return
    end
    local result, data = json.ParseToLua(file:read("*a"))
    file:close()
    if not file then
        LogManager.log(string.format("无法解析流程文件：%s", self._path), "error")
        -- 解析失败时弹窗提醒
        -- sdl.ShowSimpleMessageBox(sdl.MessageBoxFlags.ERROR, "解析失败", 
        --     string.format("无法解析文件：%s", self._path), GlobalContext.window)
        return
    end
    imgui.NodeEditor.SetCurrentEditor(self._context)
    self._max_uid = data.max_uid
    self._is_open.val = data.is_open
    for id, node_data in pairs(data.node_pool) do
        self:spawn_node(NodeFactory.create(self, node_data.type_id, node_data), false)
    end
    for _, link_data in pairs(data.link_pool) do
        self._link_pool[link_data.id] = load_link(self, link_data)
    end
    LogManager.log(string.format("成功加载流程文件：%s", self._path), "success")
end

-- 保存流程
local function save_document(self)
    -- 记录此前的修改管理器上下文
    local prev_context = ModifyManager.get_context()
    ModifyManager.set_context(self._modify_context)
    -- 如果当前上下文没有被修改则直接返回无需重复保存
    if not ModifyManager.is_modify() then
        -- 回复此前修改管理器上下文
        ModifyManager.set_context(prev_context)
        return
    end
    -- 如果没有更新过则更新一次初始化位置信息等数据
    if not self._ticked then 
        imgui.NodeEditor.SetCurrentEditor(self._context)
        imgui.NodeEditor.Begin(self._id)
            self:on_tick()
        imgui.NodeEditor.End()
    end
    -- 收集需要序列化的数据
    local dump_data = 
    {
        max_uid = self._max_uid,
        node_pool = {}, link_pool = {},
        is_open = self._is_open.val,
    }
    for id, node in pairs(self._node_pool) do
        dump_data.node_pool[id] = node:on_save()
    end
    for id, link in pairs(self._link_pool) do
        dump_data.link_pool[id] = save_link(link)
    end
    -- 打开文件写入
    local file = io.open(util.UTF8ToGBK(self._path), "w")
    if not file then
        -- 写入失败时弹窗提醒
        sdl.ShowSimpleMessageBox(sdl.MessageBoxFlags.ERROR, "保存失败", 
            string.format("无法打开文件：%s", self._path), GlobalContext.window)
        ModifyManager.set_context(prev_context)
        return
    end
    local str_json = json.PrintFromLua(dump_data)
    file:write(str_json) file:flush() file:close()
    ModifyManager.set_modify(false)
    ModifyManager.set_context(prev_context)
    LogManager.log(string.format("成功保存流程文件：%s", self._path), "success")
end

local function on_tick(self)
    -- 处理节点渲染
    for id, node in pairs(self._node_pool) do
        node:on_update()
        local position = imgui.NodeEditor.GetNodePosition(node._id)
        local ix, iy = math.floor(position.x), math.floor(position.y)
        if node._position.x ~= ix or node._position.y ~= iy then
            node._position.x, node._position.y = ix, iy
            ModifyManager.set_modify(true)
        end
    end
    -- 处理连接渲染
    for _, link in pairs(self._link_pool) do
        imgui.NodeEditor.Link(link.id, link.input._id, link.output._id, link.input._color, 2)
    end
    if imgui.NodeEditor.BeginCreate() then
        -- 处理连接建立
        local id_input, id_output = imgui.NodeEditor.PinId(0), imgui.NodeEditor.PinId(0)
        if imgui.NodeEditor.QueryNewLink(id_input, id_output) then
            local pin_input, pin_output = self._pin_pool[id_input:get()], self._pin_pool[id_output:get()]
            if id_input:check_valid() and id_output:check_valid() and _can_link(pin_input, pin_output) then
                if imgui.NodeEditor.AcceptNewItem(color_link_accepted, 2) then
                    --[=========================================[
                        当新连接建立时：
                            1. 断开并保存输入节点的旧有连接对象
                            2. 断开并保存输出节点的旧有连接对象
                            3. 创建新的连接对象
                        撤销时：
                            1. 移除新创建的连接对象
                            2. 检查若输入节点旧有连接对象存在则恢复
                            3. 检查若输出节点旧有连接对象存在则恢复
                    --]=========================================]
                    local undo_data = 
                    {
                        prev_input_pin_id = pin_input._linked_pin_id,
                        prev_output_pin_id = pin_output._linked_pin_id,
                    }
                    -- 检查输入节点是否已经连接并断开
                    if pin_input._linked_pin_id then
                        undo_data.prev_input_link, undo_data.prev_input_linked_data = self:_remove_link_by_pin_id(pin_input._id, false)
                    end
                    -- 检查输出节点是否已经连接并断开
                    if pin_output._linked_pin_id then
                        undo_data.prev_output_link, undo_data.prev_output_linked_data = self:_remove_link_by_pin_id(pin_output._id, true)
                    end
                    -- 创建新连接
                    undo_data.new_link_id = self:gen_next_uid()
                    undo_data.new_link = 
                    {
                        id = imgui.NodeEditor.LinkId(undo_data.new_link_id),
                        input = pin_input,
                        output = pin_output
                    }
                    self._link_pool[undo_data.new_link_id] = undo_data.new_link
                    pin_input._linked_pin_id, pin_output._linked_pin_id = id_output, id_input
                    -- 记录撤销重做
                    UndoManager.record(function(data)
                        self._link_pool[data.new_link_id] = nil
                        pin_input._linked_pin_id = nil
                        pin_output._linked_pin_id = nil
                        if data.prev_input_link then
                            self._link_pool[data.prev_input_link.id:get()] = data.prev_input_link
                            data.prev_input_link.input._linked_pin_id = data.prev_input_linked_data.input_linked_pin_id
                            data.prev_input_link.output._linked_pin_id = data.prev_input_linked_data.output_linked_pin_id
                        end
                        if data.prev_output_link then
                            self._link_pool[data.prev_output_link.id:get()] = data.prev_output_link
                            data.prev_output_link.input._linked_pin_id = data.prev_output_linked_data.input_linked_pin_id
                            data.prev_output_link.output._linked_pin_id = data.prev_output_linked_data.output_linked_pin_id
                        end
                    end, function(data)
                        if data.prev_input_link then
                            self._link_pool[data.prev_input_link.id:get()] = nil
                            data.prev_input_link.input._linked_pin_id = nil
                            data.prev_input_link.output._linked_pin_id = nil
                        end
                        if data.prev_output_link then
                            self._link_pool[data.prev_output_link.id:get()] = nil
                            data.prev_output_link.input._linked_pin_id = nil
                            data.prev_output_link.output._linked_pin_id = nil
                        end
                        pin_input._linked_pin_id = id_output
                        pin_output._linked_pin_id = id_input
                        self._link_pool[data.new_link_id] = data.new_link
                    end, undo_data)
                end
            else
                imgui.NodeEditor.RejectNewItem(color_link_rejected, 2)
            end
        end
        -- 处理新节点创建
        local id_pin = imgui.NodeEditor.PinId(0)
        if imgui.NodeEditor.QueryNewNode(id_pin) then
            if imgui.NodeEditor.AcceptNewItem() then
                imgui.OpenPopup("CreateNewNode")
            end
        end
    end
    imgui.NodeEditor.EndCreate()
    if imgui.NodeEditor.BeginDelete() then
        -- 处理节点删除
        local id_node = imgui.NodeEditor.NodeId()
        while imgui.NodeEditor.QueryDeletedNode(id_node) do
            self:_remove_node_by_node_id(id_node)
        end
        -- 处理连接删除
        local id_link = imgui.NodeEditor.LinkId()
        while imgui.NodeEditor.QueryDeletedLink(id_link) do
            if imgui.NodeEditor.AcceptDeletedItem() then
                local link, undo_data = self:_remove_link_by_link_id(id_link)
                UndoManager.record(function(data)
                    self._link_pool[link.id:get()] = link
                    link.input._linked_pin_id = data.input_linked_pin_id
                    link.output._linked_pin_id = data.output_linked_pin_id
                end, function(data) 
                    self._link_pool[link.id:get()] = nil
                    link.input._linked_pin_id = nil
                    link.output._linked_pin_id = nil
                end, undo_data)
            end
        end
    end
    imgui.NodeEditor.EndDelete()
    -- 处理右键菜单
    local mouse_pos = imgui.GetMousePos()
    imgui.NodeEditor.Suspend()
        local id_node = imgui.NodeEditor.NodeId(0)
        if imgui.NodeEditor.ShowNodeContextMenu(id_node) then
            self._node_menu = self._node_pool[id_node:get()]
            self._id_menu = self._node_menu:query_menu_id()
            if rawget(self, "_id_menu") then
                imgui.OpenPopup(self._id_menu)
            end
        elseif imgui.NodeEditor.ShowBackgroundContextMenu() then
            imgui.OpenPopup("CreateNewNode")
        end
        if rawget(self, "_id_menu") then
            if imgui.BeginPopup(self._id_menu) then
                self._node_menu:on_show_menu()
                imgui.EndPopup()
            end
        end
        if imgui.BeginPopup("CreateNewNode") then
            local flags_default = imgui.TreeNodeFlags.SpanFullWidth
            local flags_open = imgui.TreeNodeFlags.DefaultOpen | imgui.TreeNodeFlags.SpanFullWidth
            if imgui.TreeNode("演出控制", flags_open) then
                self:_menu_item_create_node(NodeDef.delay, mouse_pos)
                self:_menu_item_create_node(NodeDef.wait_interaction, mouse_pos)
                self:_menu_item_create_node(NodeDef.switch_background, mouse_pos)
                self:_menu_item_create_node(NodeDef.add_foreground, mouse_pos)
                self:_menu_item_create_node(NodeDef.remove_foreground, mouse_pos)
                self:_menu_item_create_node(NodeDef.move_foreground, mouse_pos)
                self:_menu_item_create_node(NodeDef.show_letterboxing, mouse_pos)
                self:_menu_item_create_node(NodeDef.hide_letterboxing, mouse_pos)
                self:_menu_item_create_node(NodeDef.show_subtitle, mouse_pos)
                self:_menu_item_create_node(NodeDef.hide_subtitle, mouse_pos)
                self:_menu_item_create_node(NodeDef.show_dialog_box, mouse_pos)
                self:_menu_item_create_node(NodeDef.hide_dialog_box, mouse_pos)
                self:_menu_item_create_node(NodeDef.transition_fade_in, mouse_pos)
                self:_menu_item_create_node(NodeDef.transition_fade_out, mouse_pos)
                self:_menu_item_create_node(NodeDef.show_choice_button, mouse_pos)
                imgui.TreePop()
            end
            if imgui.TreeNode("音频播控", flags_open) then
                self:_menu_item_create_node(NodeDef.play_audio, mouse_pos)
                self:_menu_item_create_node(NodeDef.stop_audio, mouse_pos)
                self:_menu_item_create_node(NodeDef.stop_all_audio, mouse_pos)
                imgui.TreePop()
            end
            if imgui.TreeNode("流程控制", flags_default) then
                self:_menu_item_create_node(NodeDef.branch, mouse_pos)
                self:_menu_item_create_node(NodeDef.loop, mouse_pos)
                self:_menu_item_create_node(NodeDef.switch_scene, mouse_pos)
                imgui.TreePop()
            end
            if imgui.TreeNode("对象功能", flags_default) then
                self:_menu_item_create_node(NodeDef.find_object, mouse_pos)
                imgui.TreePop()
            end
            if imgui.TreeNode("环境变量", flags_default) then
                self:_menu_item_create_node(NodeDef.save_global, mouse_pos)
                self:_menu_item_create_node(NodeDef.load_global, mouse_pos)
                imgui.TreePop()
            end
            if imgui.TreeNode("值节点", flags_default) then
                self:_menu_item_create_node(NodeDef.color, mouse_pos)
                self:_menu_item_create_node(NodeDef.string, mouse_pos)
                self:_menu_item_create_node(NodeDef.int, mouse_pos)
                self:_menu_item_create_node(NodeDef.float, mouse_pos)
                self:_menu_item_create_node(NodeDef.bool, mouse_pos)
                self:_menu_item_create_node(NodeDef.vector2, mouse_pos)
                self:_menu_item_create_node(NodeDef.random_int, mouse_pos)
                self:_menu_item_create_node(NodeDef.assemble_vector2, mouse_pos)
                imgui.TreePop()
            end
            if imgui.TreeNode("运算与逻辑", flags_default) then
                self:_menu_item_create_node(NodeDef.equal, mouse_pos)
                self:_menu_item_create_node(NodeDef.less, mouse_pos)
                self:_menu_item_create_node(NodeDef.greater, mouse_pos)
                self:_menu_item_create_node(NodeDef.floor, mouse_pos)
                self:_menu_item_create_node(NodeDef.ceil, mouse_pos)
                self:_menu_item_create_node(NodeDef.round, mouse_pos)
                imgui.TreePop()
            end
            if imgui.TreeNode("资产节点", flags_default) then
                self:_menu_item_create_node(NodeDef.font, mouse_pos)
                self:_menu_item_create_node(NodeDef.audio, mouse_pos)
                self:_menu_item_create_node(NodeDef.shader, mouse_pos)
                self:_menu_item_create_node(NodeDef.texture, mouse_pos)
                imgui.TreePop()
            end
            if imgui.TreeNode("其他", flags_default) then
                self:_menu_item_create_node(NodeDef.comment, mouse_pos)
                self:_menu_item_create_node(NodeDef.extend_pins, mouse_pos)
                self:_menu_item_create_node(NodeDef.merge_flow, mouse_pos)
                self:_menu_item_create_node(NodeDef.print, mouse_pos)
                imgui.TreePop()
            end
            imgui.EndPopup()
        end
    imgui.NodeEditor.Resume()
    if not self._ticked then
        self._ticked = true
    end
    -- 卧槽为啥啊只有三帧之后才生效！
    if self._navigate_counter < 4 then
        self._navigate_counter = self._navigate_counter + 1
        if self._navigate_counter == 3 then
            imgui.NodeEditor.NavigateToContent()
        end
    end
end

local function on_update(self, delta)   
    ModifyManager.set_context(self._modify_context)
    local flag = imgui.TabItemFlags.None
    if ModifyManager.is_modify() then flag = flag | imgui.TabItemFlags.UnsavedDocument end
    if GlobalContext.bp_id_selected_next_frame == self._id then 
        flag = flag | imgui.TabItemFlags.SetSelected
        GlobalContext.bp_id_selected_next_frame = nil
    end
    if imgui.BeginTabItem(self._id, self._is_open, flag) then
        UndoManager.set_context(self._undo_context)
        if not GlobalContext.is_debug_game then
            GlobalContext.current_blueprint = self
        end
        imgui.NodeEditor.SetCurrentEditor(self._context)
        imgui.NodeEditor.Begin(self._id)
            self:on_tick()
            local mouse_pos = imgui.GetMousePos()
        imgui.NodeEditor.End()
        if GlobalContext.is_show_flow.val then
            for _, link in pairs(self._link_pool) do
                if link.input._type_id == "flow" then
                    imgui.NodeEditor.Flow(link.id)
                end
            end
        end
        if GlobalContext.is_show_all_node_id.val then
            imgui.NodeEditor.ShowAllNodeID()
        end
        if imgui.BeginDragDropTarget() then
            -- imgui.SetTooltip("释放以创建节点")
            local payload = imgui.AcceptDragDropPayload("asset")
            if payload then
                local node = nil
                if payload.type == "font" then
                    node = _create_node_by_def(self, NodeDef.font, mouse_pos)
                elseif payload.type == "audio" then
                    node = _create_node_by_def(self, NodeDef.audio, mouse_pos)
                elseif payload.type == "shader" then
                    node = _create_node_by_def(self, NodeDef.shader, mouse_pos)
                elseif payload.type == "texture" then
                    node = _create_node_by_def(self, NodeDef.texture, mouse_pos)
                end
                if node then node._output_pin_list[1]:set_val(payload.id) end
            end
            imgui.EndDragDropTarget()
        end
        if imgui.GetIO().KeyCtrl then
            if not imgui.IsAnyItemActive() then
                -- 处理撤销重做
                if imgui.IsKeyPressed(imgui.ImGuiKey.Z, false) then
                    UndoManager.undo()
                elseif imgui.IsKeyPressed(imgui.ImGuiKey.Y, false) then
                    UndoManager.redo()
                end
                -- 处理复制/粘贴（节点）
                if imgui.IsKeyPressed(imgui.ImGuiKey.C, false) then
                    local selected_set = _get_selected_node_id_set(self)
                    local has_selection = next(selected_set) ~= nil
                    local dump_data = _build_dump_data(self, has_selection)
                    local str_json = json.PrintFromLua(dump_data)
                    rl.SetClipboardText(str_json)
                    self._clipboard_preview_open.val = true
                    self._clipboard_preview_text:set(str_json)
                    if has_selection then
                        self._clipboard_preview_status:set(string.format("已复制选中节点：%d 个节点，%d 条连接", #dump_data.node_pool, #dump_data.link_pool))
                    else
                        self._clipboard_preview_status:set(string.format("未选择节点，已复制整个流程：%d 个节点，%d 条连接", #dump_data.node_pool, #dump_data.link_pool))
                    end
                elseif imgui.IsKeyPressed(imgui.ImGuiKey.V, false) then
                    local clip = rl.GetClipboardText()
                    clip = clip or ""
                    self._clipboard_preview_open.val = true
                    self._clipboard_preview_text:set(clip)

                    local ok_parse, parsed_or_err = json.ParseToLua(clip)
                    if not ok_parse then
                        self._clipboard_preview_status:set(string.format("剪贴板解析失败：%s", tostring(parsed_or_err)))
                    else
                        local ok_schema, err_schema = _validate_blueprint_clipboard_data(parsed_or_err)
                        if not ok_schema then
                            self._clipboard_preview_status:set(string.format("剪贴板内容不是流程格式：%s", tostring(err_schema)))
                        else
                            local ok_paste, paste_msg = _paste_nodes_from_data(self, parsed_or_err, mouse_pos)
                            if ok_paste then
                                self._clipboard_preview_status:set(paste_msg)
                            else
                                self._clipboard_preview_status:set(string.format("粘贴失败：%s", tostring(paste_msg)))
                            end
                        end
                    end
                end
                -- 处理导航到内容
                if imgui.IsKeyPressed(imgui.ImGuiKey.R, false) then
                    imgui.NodeEditor.NavigateToContent()
                end
            end
            -- 处理保存
            if imgui.IsKeyPressed(imgui.ImGuiKey.S, false) then
                self:save_document()
            end
        end

        if self._clipboard_preview_open and self._clipboard_preview_open.val then
            imgui.SetNextWindowSize(imgui.ImVec2(520, 360), imgui.ImGuiCond.FirstUseEver)
            if imgui.Begin(string.format("剪贴板检查 - %s", self._id), self._clipboard_preview_open) then
                imgui.SeparatorText("状态")
                imgui.PushTextWrapPos(0)
                imgui.Text(self._clipboard_preview_status:get())
                imgui.PopTextWrapPos()
                imgui.SeparatorText("内容预览")
                imgui.InputTextMultiline("##clipboard_preview", self._clipboard_preview_text, imgui.ImVec2(0, 0), imgui.InputTextFlags.ReadOnly)
            end
            imgui.End()
        end

        imgui.EndTabItem()
        UndoManager.set_context()
    end
    ModifyManager.set_context()
end

local function execute(self, scene)
    local node_entry = nil
    for _, node in pairs(self._node_pool) do
        if node._type_id == "entry" then
            node_entry = node
            break
        end
    end
    if not node_entry then
        LogManager.log(string.format("执行流程脚本时出错，无法找到入口节点：%s", self._id), "error")
        GlobalContext.stop_debug()
        return
    end
    LogManager.log(string.format("开始调试场景：%s", self._id), "info")
    self._scene_context = Scene.new()
    self:execute_node(node_entry)
end

local function execute_node(self, node, entry_pin)
    if not node then 
        LogManager.log("调试结束", "success")
        GlobalContext.stop_debug()
        return
    end
    self._next_node = node
    self._next_node_entry_pin = entry_pin
end

module.new = function(path)
    local config = imgui.NodeEditor.Config()
    config.SettingsFile = nil
    local is_create_file = not rl.FileExists(util.UTF8ToGBK(path))
    local o = 
    {
        -- [================================[ 基础数据和编辑器前端字段 ]=================================]

        _id = rl.GetFileNameWithoutExt(path),                               -- 流程ID标题，不带后缀的文件名
        _max_uid = 0,                                                       -- 最大的uid值，随内容累加
        _pin_pool = {},                                                     -- 引脚对象池
        _link_pool = {},                                                    -- 连接对象池
        _node_pool = {},                                                    -- 节点对象池
        _is_open = imgui.Bool(true),                                        -- 当前是否处于打开状态
        _path = path,                                                       -- 完整流程文件路径
        _ticked = false,                                                    -- 是否更新过，用以标记是否是第一次被更新
        _id_menu = nil,                                                     -- 显示当前节点右键菜单的Popup ID
        _node_menu = nil,                                                   -- 显示当前节点右键菜单的节点对象
        _navigate_counter = 0,                                              -- 导航到全部内容的计数器
        _context = imgui.NodeEditor.Create(config),                         -- 流程编辑器上下文
        _undo_context = UndoManager.create_context(),                       -- 撤销管理器上下文
        _modify_context = ModifyManager.create_context(is_create_file),     -- 修改管理器上下文

        _clipboard_preview_open = imgui.Bool(false),                         -- 是否显示剪贴板检查窗口
        _clipboard_preview_text = util.CString(""),                          -- 剪贴板原始文本
        _clipboard_preview_status = util.CString(""),                        -- 状态/错误信息

        _remove_link_by_link_id = _remove_link_by_link_id,                  -- 通过连接ID移除连接对象
        _remove_link_by_pin_id = _remove_link_by_pin_id,                    -- 通过引脚ID移除连接对象
        _remove_node_by_node_id = _remove_node_by_node_id,                  -- 通过节点ID移除节点对象
        _menu_item_create_node = _menu_item_create_node,                    -- 创建节点使用的MenuItem界面组件

        on_tick = on_tick,                                                  -- 流程对象更新方法（执行实际更新任务）
        on_update = on_update,                                              -- 流程对象更新方法（执行周边更新任务）
        spawn_node = spawn_node,                                            -- 将节点对象添加到流程中
        load_document = load_document,                                      -- 从内置的文件路径中加载流程文档
        save_document = save_document,                                      -- 将流程文档保存到内置的文件路径中
        gen_next_uid = gen_next_uid,                                        -- 生成下一个全局ID

        -- [========================================[ 运行时字段 ]=======================================]

        _next_node = nil,                                                   -- 下一个需要被执行的节点对象
        _next_node_entry_pin = nil,                                         -- 下一个需要被执行的节点对象入口引脚对象
        _current_node = nil,                                                -- 当前正在更新的节点对象
        _scene_context = nil,                                               -- 正在运行的场景对象上下文
        
        execute = execute,                                                  -- 流程脚本执行入口
        execute_node = execute_node,                                        -- 执行指定节点逻辑

        __gc = function(self)
            imgui.NodeEditor.Destroy(self._context)
        end
    }
    setmetatable(o, o)
    o.__index = o

    UndoManager.set_context(o._undo_context)
    if is_create_file then
        o:spawn_node(NodeFactory.create(o, "entry"), false)
        o:save_document()
    else
        o:load_document()
    end
    return o
end

return module