local CommandRegistry = require("application.framework.flow_text_command_registry")
local ExecutionBridge = require("application.framework.flow_text_execution_bridge")
local FlowTextLexer = require("application.framework.flow_text_lexer")
local FlowTextLabelSyntax = require("application.framework.flow_text_label_syntax")
local FlowTextPreprocessor = require("application.framework.flow_text_preprocessor")
local GlobalContext = require("application.framework.global_context")
local NodeRegistry = require("application.framework.node_registry")
local PinRegistry = require("application.framework.pin_registry")
local ResourceBrowser = require("application.framework.resource_browser")
local ResourceIndex = require("application.framework.resource_index")

local module = {}

local RESOURCE_TYPE_LIST =
{
    "texture",
    "audio",
    "video",
    "font",
    "shader",
    "style",
    "flow",
    "ui",
}

local RESOURCE_VALUE_TEMPLATE_TYPE_POOL = {}
for _, type_id in ipairs(RESOURCE_TYPE_LIST) do
    RESOURCE_VALUE_TEMPLATE_TYPE_POOL[type_id] = true
end

local FIXED_DIRECTIVE_MAP =
{
    alias =
    {
        name = "alias",
        summary = "为当前文本剧本文档声明命令别名。",
        syntax = "@@alias(short = target)",
        example = "@@alias(bg_room = switch_background)",
        completion_template = "alias( = )",
        completion_cursor_text = "alias(",
    },
    import =
    {
        name = "import",
        summary = "导入另一个 .vns 文本剧本的前置内容。",
        syntax = '@@import("flow_id")',
        example = '@@import("flow/common/prologue")',
        completion_template = 'import("")',
        completion_cursor_text = 'import("',
    },
    outline =
    {
        name = "outline",
        summary = "声明当前文档的大纲标题。",
        syntax = '@@outline("章节标题")',
        example = '@@outline("第一章 开场")',
        completion_template = 'outline("")',
        completion_cursor_text = 'outline("',
    },
}

local FIXED_COMMAND_MAP =
{
    ["if"] =
    {
        command = "if",
        aliases = {},
        summary = "条件分支起始语句。",
        detail = "表达式为真时执行当前分支体，否则继续检查后续 @elif / @else。",
        signature = {},
        syntax = "@if(expr)",
        completion_template = "if()",
        completion_cursor_text = "if(",
    },
    ["elif"] =
    {
        command = "elif",
        aliases = {},
        summary = "条件分支的追加判断语句。",
        detail = "只能出现在 @if 结构内部，用于补充额外条件。",
        signature = {},
        syntax = "@elif(expr)",
        completion_template = "elif()",
        completion_cursor_text = "elif(",
    },
    ["else"] =
    {
        command = "else",
        aliases = {},
        summary = "条件分支的兜底语句。",
        detail = "只能出现在 @if 结构内部，当前面条件都不满足时执行。",
        signature = {},
        syntax = "@else",
        completion_template = "else",
        completion_cursor_text = "else",
    },
    ["end"] =
    {
        command = "end",
        aliases = {},
        summary = "结束 @if 或 @choice 结构。",
        detail = "用于关闭当前控制块。",
        signature = {},
        syntax = "@end",
        completion_template = "end",
        completion_cursor_text = "end",
    },
    choice =
    {
        command = "choice",
        aliases = {},
        summary = "创建分支选项块。",
        detail = "后续使用多行 `- 选项 -> #label` 定义分支，最终以 @end 结束；当前 `@choice` 本身不承载运行时参数。",
        signature = {},
        syntax = "@choice(prompt: \"...\")",
        completion_template = "choice()",
        completion_cursor_text = "choice(",
    },
    jump =
    {
        command = "jump",
        aliases = {},
        summary = "无条件跳转到指定标签。",
        detail = "目标应为 #label，常用于局部路由与段落切换。",
        syntax = "@jump(#label)",
        signature =
        {
            {
                name = "target",
                pin = "target",
                positional = true,
                required = true,
                aliases = {},
                doc = "跳转目标标签。",
            },
        },
        completion_template = "jump(target: #)",
        completion_cursor_text = "jump(target: #",
    },
    node =
    {
        command = "node",
        aliases = {},
        summary = "调用任意已注册节点类型。",
        detail = "通过 type 参数显式指定节点 type_id，适合临时访问未暴露脚本别名的节点。",
        syntax = '@node(type: "node_type")',
        signature =
        {
            {
                name = "type",
                pin = "type",
                positional = false,
                required = true,
                aliases = {},
                doc = "目标节点的 type_id。",
            },
        },
        completion_template = "node(type: \"\")",
        completion_cursor_text = "node(type: \"",
    },
}

local function _copy_table(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}
    for key, item in pairs(value) do
        result[key] = _copy_table(item)
    end
    return result
end

local function _push_symbol(target, name, declaration)
    if type(name) ~= "string" or name == "" then
        return
    end
    target[#target + 1] =
    {
        name = name,
        declaration = declaration or name,
    }
end

local function _get_pin_label(type_id)
    local pin_def = PinRegistry.get(type_id)
    local display_name = pin_def and (pin_def.display_name or pin_def.name) or type_id
    if display_name and display_name ~= type_id then
        return string.format("%s / %s", display_name, tostring(type_id))
    end
    return tostring(type_id or "unknown")
end

local function _join_text(list, separator)
    return table.concat(list or {}, separator or ", ")
end

local function _get_param_doc_brief(doc)
    if type(doc) == "table" then
        if doc.brief and doc.brief ~= "" then
            return tostring(doc.brief)
        end
        if doc.description and doc.description ~= "" then
            return tostring(doc.description)
        end
        return ""
    end
    if doc ~= nil then
        return tostring(doc)
    end
    return ""
end

local function _build_signature_line(item, pin_info)
    local part_list = {}
    part_list[#part_list + 1] = tostring(item.name)

    if pin_info and pin_info.type_id then
        part_list[#part_list + 1] = string.format("类型:%s", _get_pin_label(pin_info.type_id))
    end

    if item.required then
        part_list[#part_list + 1] = "必填"
    end

    if item.positional then
        part_list[#part_list + 1] = "位置参数"
    end

    if item.aliases and #item.aliases > 0 then
        part_list[#part_list + 1] = string.format("别名:%s", _join_text(item.aliases, ", "))
    end

    local line = "- " .. _join_text(part_list, " / ")
    local doc_text = _get_param_doc_brief(item.doc)
    if doc_text ~= "" then
        line = string.format("%s\n  %s", line, doc_text)
    elseif pin_info and pin_info.name and pin_info.name ~= "" then
        line = string.format("%s\n  %s", line, tostring(pin_info.name))
    end
    return line
end

local function _build_command_declaration(entry)
    local line_list = {}
    line_list[#line_list + 1] = string.format("命令 @%s", tostring(entry.name))
    if entry.canonical and entry.canonical ~= entry.name then
        line_list[#line_list + 1] = string.format("规范名: @%s", tostring(entry.canonical))
    end
    if entry.aliases and #entry.aliases > 0 then
        line_list[#line_list + 1] = string.format("别名: %s", _join_text(entry.aliases, ", "))
    end
    if entry.node_title and entry.node_title ~= "" then
        line_list[#line_list + 1] = string.format("节点: %s", tostring(entry.node_title))
    end
    if entry.category and entry.category ~= "" then
        line_list[#line_list + 1] = string.format("分类: %s", tostring(entry.category))
    end
    if entry.summary and entry.summary ~= "" then
        line_list[#line_list + 1] = string.format("摘要: %s", tostring(entry.summary))
    end
    if entry.detail and entry.detail ~= "" then
        line_list[#line_list + 1] = string.format("说明: %s", tostring(entry.detail))
    end

    if entry.signature and #entry.signature > 0 then
        line_list[#line_list + 1] = "参数:"
        for _, item in ipairs(entry.signature) do
            local pin_key = item.pin or item.name
            local pin_info = entry.schema and entry.schema.input_by_key and entry.schema.input_by_key[pin_key] or nil
            line_list[#line_list + 1] = _build_signature_line(item, pin_info)
        end
    end

    return table.concat(line_list, "\n")
end

local function _get_signature_pin_info(entry, item)
    local pin_key = item and (item.pin or item.name) or nil
    if not pin_key then
        return nil
    end
    return entry
        and entry.schema
        and entry.schema.input_by_key
        and entry.schema.input_by_key[pin_key]
        or nil
end

local function _build_completion_value_template(entry, item)
    local pin_info = _get_signature_pin_info(entry, item)
    local type_id = pin_info and pin_info.type_id or nil
    local adapter = item and item.adapter or nil
    local command_name = entry and (entry.canonical or entry.name) or nil
    local parameter_name = item and item.name or nil

    if adapter == "flow_locator" then
        return '""', '"'
    end
    if command_name == "jump" and parameter_name == "target" then
        return "#", "#"
    end
    if command_name == "node" and parameter_name == "type" then
        return '""', '"'
    end
    if RESOURCE_VALUE_TEMPLATE_TYPE_POOL[type_id] and type_id ~= "flow" then
        return string.format('&%s("")', tostring(type_id)), string.format('&%s("', tostring(type_id))
    end
    if type_id == "string" then
        return '""', '"'
    end
    if type_id == "vector2" then
        return "(, )", "("
    end
    if type_id == "color" then
        return "#", "#"
    end
    return "", ""
end

local function _build_command_completion_template(entry)
    local command_name = tostring(entry and entry.name or "")
    local argument_list = {}
    local cursor_anchor = nil

    for _, item in ipairs(entry and entry.signature or {}) do
        if item.required == true then
            local parameter_name = tostring(item.name or item.pin or "")
            if parameter_name ~= "" then
                local value_text, value_cursor_text = _build_completion_value_template(entry, item)
                local existing_args = table.concat(argument_list, ", ")
                local prefix = existing_args ~= "" and (existing_args .. ", ") or ""
                if not cursor_anchor then
                    cursor_anchor = string.format("%s(%s%s: %s", command_name, prefix, parameter_name, value_cursor_text or "")
                end
                argument_list[#argument_list + 1] = string.format("%s: %s", parameter_name, value_text or "")
            end
        end
    end

    return string.format("%s(%s)", command_name, table.concat(argument_list, ", ")),
        cursor_anchor or string.format("%s(", command_name)
end

local function _normalize_command_entry(entry)
    entry.aliases = entry.aliases or {}
    entry.signature = entry.signature or {}
    if not entry.completion_template then
        entry.completion_template, entry.completion_cursor_text = _build_command_completion_template(entry)
    else
        entry.completion_cursor_text = entry.completion_cursor_text or entry.completion_template
    end
    entry.declaration = entry.declaration or _build_command_declaration(entry)
    return entry
end

local function _make_fixed_command_entry(name)
    local spec = FIXED_COMMAND_MAP[name]
    if not spec then
        return nil
    end

    return _normalize_command_entry(
    {
        name = name,
        canonical = spec.command,
        aliases = _copy_table(spec.aliases or {}),
        summary = spec.summary,
        detail = spec.detail,
        signature = _copy_table(spec.signature or {}),
        syntax = spec.syntax,
        category = "文本结构",
        node_title = "内置文本语法",
        completion_template = spec.completion_template,
        completion_cursor_text = spec.completion_cursor_text,
        is_fixed_command = true,
    })
end

local function _make_registry_command_entry(spec, display_name)
    local node_definition = spec.type_id and NodeRegistry.get(spec.type_id) or nil
    local schema = spec.type_id and ExecutionBridge.describe_node_schema(spec.type_id) or nil
    local script_meta = node_definition and node_definition.script or {}
    local aliases = {}
    for _, alias in ipairs(spec.aliases or {}) do
        aliases[#aliases + 1] = "@" .. tostring(alias)
    end

    return _normalize_command_entry(
    {
        name = display_name or spec.command,
        canonical = spec.command,
        type_id = spec.type_id,
        aliases = aliases,
        summary = script_meta.summary or node_definition and node_definition.comment or node_definition and node_definition.title or spec.command,
        detail = script_meta.detail or "",
        signature = _copy_table(spec.signature or {}),
        category = node_definition and node_definition.category or "",
        node_title = node_definition and (node_definition.title or node_definition.name) or spec.type_id,
        schema = schema,
    })
end

local function _build_parameter_entries(command_entry_by_name)
    local aggregate_map = {}

    local function append_parameter(source_command, item, schema)
        if not item or not item.name then
            return
        end

        local function ensure_slot(name)
            local slot = aggregate_map[name]
            if slot then
                return slot
            end

            slot =
            {
                name = name,
                type_pool = {},
                command_pool = {},
                command_list = {},
                alias_pool = {},
                doc_list = {},
            }
            aggregate_map[name] = slot
            return slot
        end

        local pin_info = schema and schema.input_by_key and schema.input_by_key[item.pin or item.name] or nil
        local slot = ensure_slot(item.name)
        if pin_info and pin_info.type_id then
            slot.type_pool[pin_info.type_id] = _get_pin_label(pin_info.type_id)
        end
        if source_command and not slot.command_pool[source_command] then
            slot.command_pool[source_command] = true
            slot.command_list[#slot.command_list + 1] = "@" .. tostring(source_command)
        end
        for _, alias in ipairs(item.aliases or {}) do
            slot.alias_pool[alias] = true
            local alias_slot = ensure_slot(alias)
            alias_slot.type_pool = _copy_table(slot.type_pool)
            if source_command and not alias_slot.command_pool[source_command] then
                alias_slot.command_pool[source_command] = true
                alias_slot.command_list[#alias_slot.command_list + 1] = "@" .. tostring(source_command)
            end
            alias_slot.alias_pool[item.name] = true
            local alias_doc_text = _get_param_doc_brief(item.doc)
            if alias_doc_text ~= "" then
                alias_slot.doc_list[#alias_slot.doc_list + 1] = alias_doc_text
            end
        end
        local doc_text = _get_param_doc_brief(item.doc)
        if doc_text ~= "" then
            slot.doc_list[#slot.doc_list + 1] = doc_text
        elseif pin_info and pin_info.name and pin_info.name ~= "" then
            slot.doc_list[#slot.doc_list + 1] = tostring(pin_info.name)
        end
    end

    for _, command_entry in pairs(command_entry_by_name) do
        for _, item in ipairs(command_entry.signature or {}) do
            append_parameter(command_entry.canonical or command_entry.name, item, command_entry.schema)
        end
    end

    local result = {}
    for name, item in pairs(aggregate_map) do
        table.sort(item.command_list)
        local type_list = {}
        for _, label in pairs(item.type_pool) do
            type_list[#type_list + 1] = label
        end
        table.sort(type_list)

        local alias_list = {}
        for alias in pairs(item.alias_pool or {}) do
            alias_list[#alias_list + 1] = alias
        end
        table.sort(alias_list)

        local doc_text = item.doc_list[1] or ""
        local declaration_line_list =
        {
            string.format("参数 %s", tostring(name)),
        }
        if #type_list > 0 then
            declaration_line_list[#declaration_line_list + 1] = string.format("类型: %s", _join_text(type_list, ", "))
        end
        if #item.command_list > 0 then
            declaration_line_list[#declaration_line_list + 1] = string.format("相关命令: %s", _join_text(item.command_list, ", "))
        end
        if #alias_list > 0 then
            declaration_line_list[#declaration_line_list + 1] = string.format("别名: %s", _join_text(alias_list, ", "))
        end
        if doc_text ~= "" then
            declaration_line_list[#declaration_line_list + 1] = string.format("说明: %s", tostring(doc_text))
        end

        result[name] =
        {
            name = name,
            declaration = table.concat(declaration_line_list, "\n"),
            command_list = item.command_list,
            type_list = type_list,
            alias_list = alias_list,
            doc = doc_text,
        }
    end
    return result
end

local function _build_directive_entries()
    local result = {}
    for name, item in pairs(FIXED_DIRECTIVE_MAP) do
        result[name] =
        {
            name = name,
            declaration = table.concat(
            {
                string.format("元指令 @@%s", tostring(name)),
                string.format("作用: %s", tostring(item.summary or "")),
                string.format("语法: %s", tostring(item.syntax or "")),
                string.format("示例: %s", tostring(item.example or "")),
            }, "\n"),
            summary = item.summary,
            syntax = item.syntax,
            completion_template = item.completion_template,
            completion_cursor_text = item.completion_cursor_text,
        }
    end
    return result
end

local function _build_resource_type_entries()
    local result = {}
    for _, type_id in ipairs(RESOURCE_TYPE_LIST) do
        local type_label = ResourceBrowser.get_type_label and ResourceBrowser.get_type_label(type_id) or type_id
        result[type_id] =
        {
            name = type_id,
            declaration = table.concat(
            {
                string.format("资源类型 &%s", tostring(type_id)),
                string.format("目标资源域: %s", tostring(type_label)),
                string.format('示例: &%s("asset/id")', tostring(type_id)),
            }, "\n"),
            summary = tostring(type_label),
        }
    end
    return result
end

local function _build_label_declaration(name, line, source_path, imported)
    local declaration_line_list =
    {
        string.format("标签 #%s", tostring(name)),
        string.format("定义位置: 行 %d", tonumber(line) or 1),
    }
    if source_path and source_path ~= "" then
        declaration_line_list[#declaration_line_list + 1] = string.format("来源文件: %s", tostring(source_path))
    end
    if imported then
        declaration_line_list[#declaration_line_list + 1] = "来源: @@import 导入文档"
    end
    return table.concat(declaration_line_list, "\n")
end

local function _is_imported_label(document, source)
    if type(source) ~= "table" then
        return false
    end

    local source_flow_guid = source.flow_guid
    if document and document._resource_guid and source_flow_guid and source_flow_guid ~= document._resource_guid then
        return true
    end

    local source_path = source.path
    if document and document._path and source_path and source_path ~= document._path then
        return true
    end

    return false
end

local function _collect_label_entries(document, line_list)
    local result = {}
    for _, line in ipairs(line_list or {}) do
        local label_name = line.trimmed and FlowTextLabelSyntax.parse_label_definition(line.trimmed) or nil
        if label_name and not result[label_name] then
            result[label_name] =
            {
                name = label_name,
                line = line.number or 1,
                column = 1,
                source_path = document and document._path or nil,
                imported = false,
                declaration = _build_label_declaration(label_name, line.number or 1, document and document._path or nil, false),
            }
        end
    end

    local compiled_program = document and document.get_compiled_program and document:get_compiled_program() or document and document._compiled_program
    local labels = compiled_program and compiled_program.labels or nil
    local label_sources = compiled_program and compiled_program.label_sources or nil
    local source_map = compiled_program and compiled_program.source_map or nil
    for label_name, instruction_index in pairs(labels or {}) do
        if type(label_name) == "string" and not label_name:match("^__internal_") and not result[label_name] then
            local source = label_sources and label_sources[label_name] or source_map and source_map[instruction_index] or nil
            local line_number = source and source.line or 1
            local source_path = source and source.path or nil
            local imported = _is_imported_label(document, source)
            result[label_name] =
            {
                name = label_name,
                line = line_number,
                column = source and source.column or 1,
                source_path = source_path,
                flow_guid = source and source.flow_guid or nil,
                imported = imported,
                declaration = _build_label_declaration(label_name, line_number, source_path, imported),
            }
        end
    end

    return result
end

local function _collect_variable_entries(source_text)
    local result = {}

    local function push(name, scope_label)
        if name == nil or name == "" or result[name] then
            return
        end
        result[name] =
        {
            name = name,
            declaration = string.format("%s\n作用域: %s", tostring(name), tostring(scope_label)),
        }
    end

    local text = tostring(source_text or "")
    for variable_name in text:gmatch("(%$[A-Za-z_][A-Za-z0-9_%.]*)") do
        push(variable_name, "局部变量")
    end
    for variable_name in text:gmatch("(global%.[A-Za-z_][A-Za-z0-9_%.]*)") do
        push(variable_name, "全局变量")
    end
    for variable_name in text:gmatch("(temp%.[A-Za-z_][A-Za-z0-9_%.]*)") do
        push(variable_name, "临时变量")
    end
    return result
end

local function _get_alias_pool(document, local_alias_pool)
    local result = {}
    for key, value in pairs(local_alias_pool or {}) do
        result[key] = value
    end

    local compiled_program = document.get_compiled_program and document:get_compiled_program() or document._compiled_program
    if compiled_program and type(compiled_program.aliases) == "table" then
        for key, value in pairs(compiled_program.aliases) do
            result[key] = value
        end
    end
    return result
end

local function _build_command_state(document)
    local command_entry_by_name = {}
    local command_candidate_list = {}
    local command_spec_by_name = {}

    local function register_command(entry, spec)
        entry = _normalize_command_entry(entry)
        command_entry_by_name[entry.name] = entry
        command_candidate_list[#command_candidate_list + 1] = entry
        command_spec_by_name[entry.name] = spec or FIXED_COMMAND_MAP[entry.canonical]
    end

    for name in pairs(FIXED_COMMAND_MAP) do
        local entry = _make_fixed_command_entry(name)
        if entry then
            register_command(entry, FIXED_COMMAND_MAP[name])
        end
    end

    for _, spec in ipairs(CommandRegistry.list and CommandRegistry.list() or {}) do
        register_command(_make_registry_command_entry(spec), spec)
        for _, alias in ipairs(spec.aliases or {}) do
            register_command(_make_registry_command_entry(spec, alias), spec)
        end
    end

    table.sort(command_candidate_list, function(left, right)
        if tostring(left.canonical) ~= tostring(right.canonical) then
            return tostring(left.canonical) < tostring(right.canonical)
        end
        return tostring(left.name) < tostring(right.name)
    end)

    local line_list = FlowTextLexer.split_lines(document:get_source_text())
    local preprocessor_result = FlowTextPreprocessor.scan(line_list)
    local alias_pool = _get_alias_pool(document, preprocessor_result.aliases or {})

    for alias_name, target_name in pairs(alias_pool) do
        if command_entry_by_name[alias_name] == nil then
            local target_entry = command_entry_by_name[target_name]
            local entry =
            {
                name = alias_name,
                canonical = target_entry and target_entry.canonical or target_name,
                aliases = {},
                summary = target_entry and target_entry.summary or "当前文档中的命令别名。",
                detail = string.format("@@alias(%s = %s)", tostring(alias_name), tostring(target_name)),
                signature = target_entry and _copy_table(target_entry.signature) or {},
                category = "文档别名",
                node_title = target_entry and target_entry.node_title or "文本剧本文档别名",
                schema = target_entry and target_entry.schema or nil,
            }
            entry.declaration = table.concat(
            {
                string.format("命令别名 @%s", tostring(alias_name)),
                string.format("目标命令: @%s", tostring(target_name)),
                string.format("作用域: 当前文本剧本文档"),
                target_entry and string.format("摘要: %s", tostring(target_entry.summary or "")) or "",
            }, "\n")
            register_command(entry, target_entry and command_spec_by_name[target_entry.name] or nil)
        end
    end

    table.sort(command_candidate_list, function(left, right)
        if tostring(left.canonical) ~= tostring(right.canonical) then
            return tostring(left.canonical) < tostring(right.canonical)
        end
        return tostring(left.name) < tostring(right.name)
    end)

    return
    {
        line_list = line_list,
        preprocessor_result = preprocessor_result,
        alias_pool = alias_pool,
        command_entry_by_name = command_entry_by_name,
        command_candidate_list = command_candidate_list,
        command_spec_by_name = command_spec_by_name,
    }
end

local function _build_symbol_payload(state)
    local symbol_payload =
    {
        keywords = {},
        identifiers = {},
        preproc_identifiers = {},
    }

    local keyword_pool =
    {
        ["if"] = true,
        ["elif"] = true,
        ["else"] = true,
        ["end"] = true,
        choice = true,
        jump = true,
        node = true,
    }

    for keyword_name in pairs(keyword_pool) do
        symbol_payload.keywords[#symbol_payload.keywords + 1] = keyword_name
    end
    table.sort(symbol_payload.keywords)

    for _, entry in ipairs(state.command_candidate_list or {}) do
        _push_symbol(symbol_payload.preproc_identifiers, entry.name, entry.declaration)
    end

    for _, directive_entry in pairs(state.directive_entry_by_name or {}) do
        _push_symbol(symbol_payload.preproc_identifiers, directive_entry.name, directive_entry.declaration)
    end

    for _, resource_entry in pairs(state.resource_type_entry_by_name or {}) do
        _push_symbol(symbol_payload.preproc_identifiers, resource_entry.name, resource_entry.declaration)
    end

    for _, parameter_entry in pairs(state.parameter_entry_by_name or {}) do
        _push_symbol(symbol_payload.identifiers, parameter_entry.name, parameter_entry.declaration)
    end

    for _, label_entry in pairs(state.label_entry_by_name or {}) do
        _push_symbol(symbol_payload.identifiers, label_entry.name, label_entry.declaration)
    end

    for _, variable_entry in pairs(state.variable_entry_by_name or {}) do
        _push_symbol(symbol_payload.identifiers, variable_entry.name, variable_entry.declaration)
    end

    table.sort(symbol_payload.identifiers, function(left, right)
        return tostring(left.name) < tostring(right.name)
    end)
    table.sort(symbol_payload.preproc_identifiers, function(left, right)
        return tostring(left.name) < tostring(right.name)
    end)

    return symbol_payload
end

local function _build_cache(document)
    local command_state = _build_command_state(document)
    local directive_entry_by_name = _build_directive_entries()
    local resource_type_entry_by_name = _build_resource_type_entries()
    local label_entry_by_name = _collect_label_entries(document, command_state.line_list)
    local variable_entry_by_name = _collect_variable_entries(document:get_source_text())
    local parameter_entry_by_name = _build_parameter_entries(command_state.command_entry_by_name)
    local cache = document.get_editor_assist_cache and document:get_editor_assist_cache() or (document._editor_assist_cache or {})

    cache.semantic_revision = string.format(
        "%d:%d:%d:%d",
        tonumber(document._source_revision) or 0,
        tonumber(document._compiled_revision) or 0,
        CommandRegistry.get_revision and CommandRegistry.get_revision() or 0,
        tonumber(GlobalContext.resource_index_revision) or 0)
    cache.line_list = command_state.line_list
    cache.preprocessor_result = command_state.preprocessor_result
    cache.alias_pool = command_state.alias_pool
    cache.command_entry_by_name = command_state.command_entry_by_name
    cache.command_candidate_list = command_state.command_candidate_list
    cache.command_spec_by_name = command_state.command_spec_by_name
    cache.directive_entry_by_name = directive_entry_by_name
    cache.resource_type_entry_by_name = resource_type_entry_by_name
    cache.label_entry_by_name = label_entry_by_name
    cache.variable_entry_by_name = variable_entry_by_name
    cache.parameter_entry_by_name = parameter_entry_by_name
    cache.resource_cache_by_type = cache.resource_cache_by_type or {}
    cache.symbol_payload = _build_symbol_payload(cache)
    document._editor_assist_cache = cache
    return cache
end

module.ensure_cache = function(document)
    local cache = document.get_editor_assist_cache and document:get_editor_assist_cache() or (document._editor_assist_cache or {})
    local signature = string.format(
        "%d:%d:%d:%d",
        tonumber(document._source_revision) or 0,
        tonumber(document._compiled_revision) or 0,
        CommandRegistry.get_revision and CommandRegistry.get_revision() or 0,
        tonumber(GlobalContext.resource_index_revision) or 0)
    if cache.semantic_revision == signature and cache.symbol_payload then
        return cache
    end
    return _build_cache(document)
end

module.find_command_entry = function(document, name)
    local cache = module.ensure_cache(document)
    return cache.command_entry_by_name and cache.command_entry_by_name[name] or nil
end

module.find_parameter_entry = function(document, name)
    local cache = module.ensure_cache(document)
    return cache.parameter_entry_by_name and cache.parameter_entry_by_name[name] or nil
end

module.find_label_entry = function(document, name)
    local cache = module.ensure_cache(document)
    return cache.label_entry_by_name and cache.label_entry_by_name[name] or nil
end

module.find_directive_entry = function(document, name)
    local cache = module.ensure_cache(document)
    return cache.directive_entry_by_name and cache.directive_entry_by_name[name] or nil
end

module.find_resource_type_entry = function(document, name)
    local cache = module.ensure_cache(document)
    return cache.resource_type_entry_by_name and cache.resource_type_entry_by_name[name] or nil
end

module.find_variable_entry = function(document, name)
    local cache = module.ensure_cache(document)
    return cache.variable_entry_by_name and cache.variable_entry_by_name[name] or nil
end

module.get_command_spec = function(document, name)
    local cache = module.ensure_cache(document)
    return cache.command_spec_by_name and cache.command_spec_by_name[name] or nil
end

module.get_alias_pool = function(document)
    local cache = module.ensure_cache(document)
    return cache.alias_pool or {}
end

module.get_symbol_payload = function(document)
    local cache = module.ensure_cache(document)
    return cache.symbol_payload
end

module.get_command_candidates = function(document)
    local cache = module.ensure_cache(document)
    return cache.command_candidate_list or {}
end

module.get_label_candidates = function(document)
    local cache = module.ensure_cache(document)
    local result = {}
    for _, item in pairs(cache.label_entry_by_name or {}) do
        result[#result + 1] = item
    end
    table.sort(result, function(left, right)
        return tostring(left.name) < tostring(right.name)
    end)
    return result
end

module.get_resource_type_candidates = function(document)
    local cache = module.ensure_cache(document)
    local result = {}
    for _, type_id in ipairs(RESOURCE_TYPE_LIST) do
        local item = cache.resource_type_entry_by_name and cache.resource_type_entry_by_name[type_id] or nil
        if item then
            result[#result + 1] = item
        end
    end
    return result
end

module.get_parameter_candidates = function(document, command_name)
    local cache = module.ensure_cache(document)
    local command_entry = cache.command_entry_by_name and cache.command_entry_by_name[command_name] or nil
    if not command_entry then
        return {}
    end

    local result = {}
    for _, item in ipairs(command_entry.signature or {}) do
        result[#result + 1] = _copy_table(item)
    end
    return result
end

module.list_resources = function(document, asset_type)
    local cache = module.ensure_cache(document)
    local revision = tonumber(GlobalContext.resource_index_revision) or 0
    cache.resource_cache_by_type = cache.resource_cache_by_type or {}
    local resource_cache = cache.resource_cache_by_type[asset_type]
    if resource_cache and resource_cache.revision == revision then
        return resource_cache.items
    end

    local item_list = {}
    for _, meta in ipairs(ResourceIndex.list_by_type(asset_type) or {}) do
        item_list[#item_list + 1] =
        {
            name = meta.id,
            locator = meta.relative_path or meta.id,
            summary = meta.display_name or meta.id,
            declaration = string.format(
                "%s\n资源类型: %s\n文件: %s",
                tostring(meta.id),
                tostring(ResourceBrowser.get_type_label and ResourceBrowser.get_type_label(asset_type) or asset_type),
                tostring(meta.relative_path or meta.path or meta.id)),
            meta = meta,
        }
    end
    table.sort(item_list, function(left, right)
        return tostring(left.name) < tostring(right.name)
    end)

    cache.resource_cache_by_type[asset_type] =
    {
        revision = revision,
        items = item_list,
    }
    return item_list
end

return module
