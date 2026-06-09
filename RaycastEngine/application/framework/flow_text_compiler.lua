local CommandRegistry = require("application.framework.flow_text_command_registry")
local Diagnostics = require("application.framework.flow_text_diagnostics")
local ExecutionBridge = require("application.framework.flow_text_execution_bridge")
local NativeIO = require("application.framework.native_io")
local NodeRegistry = require("application.framework.node_registry")
local Parser = require("application.framework.flow_text_parser")
local ResourceIndex = require("application.framework.resource_index")
local ValueAdapter = require("application.framework.flow_text_value_adapter")

local module = {}

local function _copy_diagnostics(source, target)
    for _, diagnostic in ipairs(source or {}) do
        table.insert(target, diagnostic)
    end
end

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}
    for key, item in pairs(value) do
        result[key] = _clone_value(item)
    end
    return result
end

local function _schema_find_input(schema, ref)
    if type(ref) == "string" then
        local numeric = tonumber(ref)
        if numeric and math.floor(numeric) == numeric then
            ref = numeric
        end
    end
    if type(ref) == "number" then
        return schema.input_list and schema.input_list[ref] or nil
    end
    return schema.input_by_key and schema.input_by_key[ref] or nil
end

local function _schema_find_output(schema, ref)
    if type(ref) == "string" then
        local numeric = tonumber(ref)
        if numeric and math.floor(numeric) == numeric then
            ref = numeric
        end
    end
    if type(ref) == "number" then
        return schema.output_list and schema.output_list[ref] or nil
    end
    return schema.output_by_key and schema.output_by_key[ref] or nil
end

local function _resolve_command_spec(command_name, alias_pool, statement, diagnostics)
    local canonical_name = alias_pool[command_name] or command_name
    if canonical_name == "node" then
        local type_arg = statement.args and statement.args.named and statement.args.named.type or nil
        if not type_arg or type_arg.kind ~= "string" then
            table.insert(diagnostics,
                Diagnostics.error("generic_node_missing_type", "@node(type: \"...\") 缺少合法的 type 参数", statement.source.line, statement.source.column))
            return nil
        end
        local type_id = type_arg.value
        if not NodeRegistry.has(type_id) then
            table.insert(diagnostics,
                Diagnostics.error("unknown_node_type", string.format("未知的节点类型：%s", tostring(type_id)), statement.source.line, statement.source.column))
            return nil
        end
        local spec = CommandRegistry.get_by_type(type_id) or CommandRegistry.make_fallback_spec(type_id)
        spec = _clone_value(spec)
        spec.command = canonical_name
        return spec, type_id
    end

    local spec = CommandRegistry.resolve(canonical_name)
    if spec then
        return _clone_value(spec), spec.type_id
    end

    if NodeRegistry.has(canonical_name) then
        local fallback = CommandRegistry.make_fallback_spec(canonical_name)
        return _clone_value(fallback), canonical_name
    end

    table.insert(diagnostics,
        Diagnostics.error("unknown_command", string.format("未知的文本命令：@%s", tostring(command_name)), statement.source.line, statement.source.column))
    return nil
end

local function _build_input_bindings(statement, spec, schema, diagnostics)
    local binding_list = {}
    local used_pin_ref_pool = {}
    local positional_arg_list = statement.args and statement.args.positional or {}
    local named_arg_map = statement.args and statement.args.named or {}
    local positional_signature_list = {}

    for _, item in ipairs(spec.signature or {}) do
        if item.positional then
            positional_signature_list[#positional_signature_list + 1] = item
        end
    end
    table.sort(positional_signature_list, function(left, right)
        return (left.positional_index or 0) < (right.positional_index or 0)
    end)

    if #positional_arg_list > #positional_signature_list then
        table.insert(diagnostics,
            Diagnostics.error("too_many_positional_arguments", string.format("@%s 的位置参数过多", tostring(statement.command)), statement.source.line, statement.source.column))
    end

    for index, value_spec in ipairs(positional_arg_list) do
        local signature_item = positional_signature_list[index]
        if signature_item then
            local pin_info = _schema_find_input(schema, signature_item.pin)
            if not pin_info then
                table.insert(diagnostics,
                    Diagnostics.error("missing_signature_pin", string.format("命令签名引用了不存在的输入引脚：%s", tostring(signature_item.pin)), statement.source.line, statement.source.column))
            else
                local ok, err = ValueAdapter.validate_literal(value_spec, pin_info.type_id, signature_item.adapter)
                if not ok and err then
                    table.insert(diagnostics, err)
                end
                table.insert(binding_list, {pin_ref = signature_item.pin, value = value_spec, adapter = signature_item.adapter})
                used_pin_ref_pool[tostring(signature_item.pin)] = true
            end
        end
    end

    for key, value_spec in pairs(named_arg_map) do
        if statement.command == "node" and key == "type" then
            goto continue
        end

        local signature_item = (spec.named_lookup or {})[key]
        local pin_ref = signature_item and signature_item.pin or key
        local pin_info = _schema_find_input(schema, pin_ref)
        if not pin_info then
            table.insert(diagnostics,
                Diagnostics.error("unknown_named_argument", string.format("@%s 不存在名为 %s 的输入参数", tostring(statement.command), tostring(key)), value_spec.line, value_spec.column))
            goto continue
        end
        if used_pin_ref_pool[tostring(pin_ref)] then
            table.insert(diagnostics,
                Diagnostics.error("duplicate_argument_binding", string.format("参数 %s 被重复赋值", tostring(key)), value_spec.line, value_spec.column))
            goto continue
        end
        local ok, err = ValueAdapter.validate_literal(value_spec, pin_info.type_id, signature_item and signature_item.adapter or nil)
        if not ok and err then
            table.insert(diagnostics, err)
        end
        table.insert(binding_list, {pin_ref = pin_ref, value = value_spec, adapter = signature_item and signature_item.adapter or nil})
        used_pin_ref_pool[tostring(pin_ref)] = true

        ::continue::
    end

    for _, item in ipairs(spec.signature or {}) do
        if item.required and not used_pin_ref_pool[tostring(item.pin)] then
            table.insert(diagnostics,
                Diagnostics.error("missing_required_argument", string.format("@%s 缺少必填参数 %s", tostring(statement.command), tostring(item.name)), statement.source.line, statement.source.column))
        end
    end

    return binding_list
end

local function _build_output_bindings(statement, spec, schema, diagnostics)
    local route_bindings = {}
    local data_bindings = {}
    local raw_bindings = statement.bindings or {}
    local default_output = spec.default_flow_output or schema.default_flow_output

    if raw_bindings.default then
        if default_output == nil then
            table.insert(diagnostics,
                Diagnostics.error("missing_default_flow_output", string.format("@%s 没有可用于 -> #label 的默认流程输出", tostring(statement.command)), statement.source.line, statement.source.column))
        else
            route_bindings[default_output] = raw_bindings.default
        end
    end

    for key, binding in pairs(raw_bindings) do
        if key ~= "default" then
            local output_info = _schema_find_output(schema, key)
            if not output_info then
                table.insert(diagnostics,
                    Diagnostics.error("unknown_output_binding", string.format("@%s 不存在名为 %s 的输出引脚", tostring(statement.command), tostring(key)), statement.source.line, statement.source.column))
            elseif output_info.type_id == "flow" then
                if binding.kind ~= "label" then
                    table.insert(diagnostics,
                        Diagnostics.error("invalid_flow_output_binding", "流程输出只能绑定到 #label", statement.source.line, statement.source.column))
                else
                    route_bindings[output_info.key or output_info.index] = binding
                end
            else
                if binding.kind ~= "variable" then
                    table.insert(diagnostics,
                        Diagnostics.error("invalid_data_output_binding", "数据输出只能绑定到变量", statement.source.line, statement.source.column))
                else
                    data_bindings[output_info.key or output_info.index] = binding
                end
            end
        end
    end

    return route_bindings, data_bindings, default_output
end

local function _compile_invoke(statement, alias_pool, diagnostics)
    local spec, type_id = _resolve_command_spec(statement.command, alias_pool, statement, diagnostics)
    if not spec or not type_id then
        return nil
    end

    local schema = ExecutionBridge.describe_node_schema(type_id)
    if not schema then
        table.insert(diagnostics,
            Diagnostics.error("missing_node_schema", string.format("无法构建节点 schema：%s", tostring(type_id)), statement.source.line, statement.source.column))
        return nil
    end

    local input_bindings = _build_input_bindings(statement, spec, schema, diagnostics)
    local route_bindings, data_bindings, default_output = _build_output_bindings(statement, spec, schema, diagnostics)

    return
    {
        kind = "invoke",
        command = spec.command,
        type_id = type_id,
        input_bindings = input_bindings,
        route_bindings = route_bindings,
        data_bindings = data_bindings,
        default_flow_output = default_output,
        source = _clone_value(statement.source),
    }
end

local function _compile_dialogue(statement, alias_pool, diagnostics)
    local invoke_statement =
    {
        command = "show_dialog_box",
        args =
        {
            positional = {},
            named =
            {
                role = {kind = "string", value = statement.role or "", line = statement.source.line, column = statement.source.column},
                text = {kind = "string", value = statement.text or "", line = statement.source.line, column = statement.source.column},
                wait = {kind = "bool", value = true, line = statement.source.line, column = statement.source.column},
            },
        },
        bindings = {},
        source = _clone_value(statement.source),
    }
    return _compile_invoke(invoke_statement, alias_pool, diagnostics)
end

local function _compile_choice(statement, alias_pool, diagnostics)
    local option_count = math.min(#(statement.options or {}), 5)
    if option_count == 0 then
        table.insert(diagnostics, Diagnostics.error("empty_choice_block", "@choice 至少需要一个选项", statement.source.line, statement.source.column))
        return nil
    end
    if #(statement.options or {}) > 5 then
        table.insert(diagnostics, Diagnostics.error("choice_option_overflow", "@choice 当前最多支持 5 个选项", statement.source.line, statement.source.column))
    end

    if statement.prompt and statement.prompt.kind ~= "null" then
        table.insert(diagnostics, Diagnostics.warning("choice_prompt_ignored", "当前内置 show_choice_button 节点不支持 prompt，已忽略该字段", statement.source.line, statement.source.column))
    end

    local named_args = {}
    local bindings = {}
    for index = 1, option_count do
        local option = statement.options[index]
        named_args[string.format("choice_text_%d", index)] = option.text
        bindings[string.format("choice_%d", index)] = {kind = "label", target = option.target}
    end

    local invoke_statement =
    {
        command = "show_choice_button",
        args = {positional = {}, named = named_args},
        bindings = bindings,
        source = _clone_value(statement.source),
    }
    return _compile_invoke(invoke_statement, alias_pool, diagnostics)
end

local function _merge_alias_pool(base, override)
    local result = {}
    for key, value in pairs(base or {}) do
        result[key] = value
    end
    for key, value in pairs(override or {}) do
        result[key] = value
    end
    return result
end

local function _append_array(target, source)
    for _, item in ipairs(source or {}) do
        table.insert(target, item)
    end
end

local function _annotate_diagnostics(diagnostic_list, path, flow_guid)
    local annotated = {}
    for _, diagnostic in ipairs(diagnostic_list or {}) do
        local entry = _clone_value(diagnostic)
        if entry.path == nil then
            entry.path = path
        end
        if entry.flow_guid == nil then
            entry.flow_guid = flow_guid
        end
        table.insert(annotated, entry)
    end
    return annotated
end

local function _annotate_statement_source(statement, flow_guid)
    if type(statement) ~= "table" then
        return
    end

    if type(statement.source) == "table" then
        statement.source.flow_guid = flow_guid
    end

    if statement.kind == "choice" then
        for _, option in ipairs(statement.options or {}) do
            if type(option.source) == "table" then
                option.source.flow_guid = flow_guid
            end
        end
        return
    end

    if statement.kind == "if" then
        for _, branch in ipairs(statement.branches or {}) do
            if type(branch.source) == "table" then
                branch.source.flow_guid = flow_guid
            end
            for _, child in ipairs(branch.body or {}) do
                _annotate_statement_source(child, flow_guid)
            end
        end
        for _, child in ipairs(statement.else_body or {}) do
            _annotate_statement_source(child, flow_guid)
        end
    end
end

local function _annotate_ast_sources(statement_list, flow_guid)
    for _, statement in ipairs(statement_list or {}) do
        _annotate_statement_source(statement, flow_guid)
    end
end

local function _read_import_source(document, guid, path)
    local manager = document and document._manager or nil
    local imported_document = manager and manager.find_by_guid and manager.find_by_guid(guid) or nil
    if imported_document
        and imported_document.is_document_loaded
        and imported_document:is_document_loaded()
        and imported_document.get_source_text
    then
        return imported_document:get_source_text(), imported_document._path or path, imported_document._resource_guid or guid
    end

    local text, err = NativeIO.read_text(path)
    if not text then
        return nil, err or "读取导入的文本剧本源码失败"
    end
    return text, path, guid
end

local function _make_import_identity(flow_guid, path)
    if type(flow_guid) == "string" and flow_guid ~= "" then
        return "guid:" .. flow_guid
    end
    return "path:" .. tostring(path or "")
end

local function _collect_parse_unit(document, source_text, path, flow_guid, state, import_from)
    local identity = _make_import_identity(flow_guid, path)
    local cached = state.cache[identity]
    if cached then
        return cached
    end

    if state.active[identity] then
        table.insert(state.diagnostics,
            Diagnostics.error("import_cycle", string.format("检测到循环 @@import 链路，位置：%s", tostring(import_from or path or flow_guid or "<unknown>")), 1, 1))
        return
        {
            parse_result =
            {
                ast = {},
                aliases = {},
                outline_items = {},
                imports = {},
            },
            ast = {},
            aliases = {},
            dependencies = {},
        }
    end

    state.active[identity] = true

    local parse_result = Parser.parse_document(source_text or "", path)
    _copy_diagnostics(_annotate_diagnostics(parse_result.diagnostics, path, flow_guid), state.diagnostics)
    _annotate_ast_sources(parse_result.ast, flow_guid)

    local merged_ast = {}
    local merged_aliases = {}
    local dependency_pool = {}
    local imported_guid_pool = {}

    for _, directive in ipairs(parse_result.imports or {}) do
        local import_guid = ResourceIndex.resolve_guid("flow", directive.locator)
        if not import_guid then
            table.insert(state.diagnostics,
                Diagnostics.error("missing_import_target", string.format("无法解析 @@import 目标：%s", tostring(directive.locator)), directive.line, directive.column))
            goto continue_import
        end

        local meta = ResourceIndex.find_by_guid(import_guid)
        local ext = meta and string.lower(Engine.Raylib.GetFileExtension(meta.path or "")) or ""
        if not meta or ext ~= ".vns" then
            table.insert(state.diagnostics,
                Diagnostics.error("invalid_import_target", string.format("@@import 目标必须是 .vns 文本剧本文件：%s", tostring(directive.locator)), directive.line, directive.column))
            goto continue_import
        end

        dependency_pool[import_guid] = true
        if imported_guid_pool[import_guid] then
            goto continue_import
        end
        imported_guid_pool[import_guid] = true

        local import_text, import_path, import_flow_guid, read_err = _read_import_source(document, import_guid, meta.path)
        if not import_text then
            table.insert(state.diagnostics,
                Diagnostics.error("import_read_failed", string.format("加载 @@import 目标失败：%s", tostring(read_err or directive.locator)), directive.line, directive.column))
            goto continue_import
        end

        local child_unit = _collect_parse_unit(document, import_text, import_path, import_flow_guid, state, directive.locator)
        merged_aliases = _merge_alias_pool(merged_aliases, child_unit.aliases or {})
        _append_array(merged_ast, child_unit.ast)
        for _, dependency_guid in ipairs(child_unit.dependencies or {}) do
            dependency_pool[dependency_guid] = true
        end

        ::continue_import::
    end

    merged_aliases = _merge_alias_pool(merged_aliases, parse_result.aliases or {})
    _append_array(merged_ast, parse_result.ast)

    local dependencies = {}
    for dependency_guid in pairs(dependency_pool) do
        table.insert(dependencies, dependency_guid)
    end
    table.sort(dependencies)

    local unit =
    {
        parse_result = parse_result,
        ast = merged_ast,
        aliases = merged_aliases,
        dependencies = dependencies,
    }

    state.cache[identity] = unit
    state.active[identity] = nil
    return unit
end

module.compile_document = function(document)
    local compile_state =
    {
        cache = {},
        active = {},
        diagnostics = {},
    }
    local root_unit = _collect_parse_unit(document, document._source_text or "", document._path, document._resource_guid, compile_state)
    local parse_result = root_unit.parse_result or {ast = {}, aliases = {}, outline_items = {}}
    local diagnostics = compile_state.diagnostics or {}

    local instructions = {}
    local labels = {}
    local label_sources = {}
    local internal_label_serial = 0
    local current_label = nil

    local function new_internal_label()
        internal_label_serial = internal_label_serial + 1
        return string.format("__internal_%d", internal_label_serial)
    end

    local function mark_label(label_name, source)
        if labels[label_name] ~= nil then
            table.insert(diagnostics,
                Diagnostics.error("duplicate_label", string.format("标签重复定义：#%s", tostring(label_name)), source.line, source.column))
            return
        end
        labels[label_name] = #instructions + 1
        label_sources[label_name] = _clone_value(source)
        current_label = label_name
    end

    local compile_statement

    local function append_instruction(instruction)
        if not instruction then
            return
        end
        instruction.source = instruction.source or {}
        instruction.source.label = current_label
        table.insert(instructions, instruction)
    end

    local function compile_block(statement_list, alias_pool)
        for _, statement in ipairs(statement_list or {}) do
            compile_statement(statement, alias_pool)
        end
    end

    compile_statement = function(statement, alias_pool)
        if statement.kind == "label" then
            mark_label(statement.name, statement.source)
            return
        end

        if statement.kind == "dialogue" then
            append_instruction(_compile_dialogue(statement, alias_pool, diagnostics))
            return
        end

        if statement.kind == "choice" then
            append_instruction(_compile_choice(statement, alias_pool, diagnostics))
            return
        end

        if statement.kind == "invoke" then
            local command_name = alias_pool[statement.command] or statement.command
            if command_name == "jump" then
                local target_value = statement.args.named.target or statement.args.positional[1]
                if not target_value or target_value.kind ~= "label_ref" then
                    table.insert(diagnostics,
                        Diagnostics.error("invalid_jump_target", "@jump 必须指定 #label 作为 target", statement.source.line, statement.source.column))
                else
                    append_instruction(
                    {
                        kind = "jump",
                        target_label = target_value.name,
                        source = _clone_value(statement.source),
                    })
                end
                return
            end

            append_instruction(_compile_invoke(statement, alias_pool, diagnostics))
            return
        end

        if statement.kind == "if" then
            local end_label = new_internal_label()
            for _, branch in ipairs(statement.branches or {}) do
                local next_label = new_internal_label()
                append_instruction(
                {
                    kind = "jump_if_false",
                    expression = branch.expr,
                    target_label = next_label,
                    source = _clone_value(branch.source),
                })
                compile_block(branch.body, alias_pool)
                append_instruction(
                {
                    kind = "jump",
                    target_label = end_label,
                    source = _clone_value(branch.source),
                })
                mark_label(next_label, branch.source)
            end
            if statement.else_body then
                compile_block(statement.else_body, alias_pool)
            end
            mark_label(end_label, statement.source)
            return
        end
    end

    compile_block(root_unit.ast or parse_result.ast, root_unit.aliases or parse_result.aliases or {})

    for _, instruction in ipairs(instructions) do
        if instruction.kind == "jump" and labels[instruction.target_label] == nil then
            table.insert(diagnostics,
                Diagnostics.error("missing_jump_label", string.format("跳转目标不存在：#%s", tostring(instruction.target_label)), instruction.source.line, instruction.source.column))
        elseif instruction.kind == "jump_if_false" and labels[instruction.target_label] == nil then
            table.insert(diagnostics,
                Diagnostics.error("missing_branch_label", string.format("条件分支目标不存在：#%s", tostring(instruction.target_label)), instruction.source.line, instruction.source.column))
        else
            for _, binding in pairs(instruction.route_bindings or {}) do
                if binding.kind == "label" and labels[binding.target] == nil then
                    table.insert(diagnostics,
                        Diagnostics.error("missing_route_label", string.format("输出绑定目标不存在：#%s", tostring(binding.target)), instruction.source.line, instruction.source.column))
                end
            end
        end
    end

    for _, diagnostic in ipairs(diagnostics) do
        if diagnostic.path == nil then
            diagnostic.path = document._path
        end
        if diagnostic.flow_guid == nil then
            diagnostic.flow_guid = document._resource_guid
        end
    end

    Diagnostics.sort(diagnostics)

    local source_map = {}
    for index, instruction in ipairs(instructions) do
        source_map[index] =
        {
            path = instruction.source and instruction.source.path or document._path,
            line = instruction.source and instruction.source.line or 1,
            column = instruction.source and instruction.source.column or 1,
            label = instruction.source and instruction.source.label or nil,
            flow_guid = instruction.source and instruction.source.flow_guid or document._resource_guid,
        }
    end

    return
    {
        version = 1,
        flow_guid = document._resource_guid,
        labels = labels,
        label_sources = label_sources,
        aliases = root_unit.aliases or parse_result.aliases or {},
        instructions = instructions,
        source_map = source_map,
        diagnostics = diagnostics,
        outline_items = parse_result.outline_items or {},
        dependencies = root_unit.dependencies or {},
        entry_index = labels.start or 1,
    }
end

return module
