local FlowTextEditorSemantics = require("application.framework.flow_text_editor_semantics")
local FlowTextHoverProvider = require("application.framework.flow_text_hover_provider")

local module = {}

local function _char_len(text)
    local ok, length = pcall(utf8.len, tostring(text or ""))
    if ok and length then
        return length
    end
    return #(tostring(text or ""))
end

local function _starts_with(text, prefix)
    local lhs = string.lower(tostring(text or ""))
    local rhs = string.lower(tostring(prefix or ""))
    if rhs == "" then
        return true
    end
    return lhs:sub(1, #rhs) == rhs
end

local function _build_candidate(name, label, declaration, summary, insert_text, cursor_anchor_text, extra)
    local candidate =
    {
        name = name,
        label = label or name,
        declaration = declaration or label or name,
        summary = summary or "",
        insert_text = insert_text or name,
        cursor_offset = _char_len(cursor_anchor_text or insert_text or name),
    }

    for key, value in pairs(extra or {}) do
        candidate[key] = value
    end
    return candidate
end

local function _filter_and_sort(candidate_list, prefix)
    local result = {}
    for _, item in ipairs(candidate_list or {}) do
        if _starts_with(item.name, prefix) then
            result[#result + 1] = item
        end
    end

    table.sort(result, function(left, right)
        local left_alias = left.is_alias == true
        local right_alias = right.is_alias == true
        if left_alias ~= right_alias then
            return left_alias == false
        end
        return tostring(left.name) < tostring(right.name)
    end)
    return result
end

local function _get_parameter_variants(document, command_name, used_named_args)
    local variants = {}
    for _, item in ipairs(FlowTextEditorSemantics.get_parameter_candidates(document, command_name) or {}) do
        local is_used = used_named_args and used_named_args[item.name] == true
        if not is_used then
            variants[#variants + 1] = item.name
            for _, alias in ipairs(item.aliases or {}) do
                variants[#variants + 1] = alias
            end
        end
    end
    return variants
end

module.get_candidates = function(document, context)
    if not document or not context or not context.kind then
        return {}
    end

    if context.kind == "command" then
        local candidate_list = {}
        local name_only = context.command_completion_mode == "name_only"
        for _, entry in ipairs(FlowTextEditorSemantics.get_command_candidates(document) or {}) do
            local insert_text = tostring(entry.name)
            local cursor_anchor = insert_text
            if not name_only then
                insert_text = entry.completion_template or string.format("%s()", tostring(entry.name))
                cursor_anchor = entry.completion_cursor_text or string.format("%s(", tostring(entry.name))
            end
            candidate_list[#candidate_list + 1] = _build_candidate(
                entry.name,
                "@" .. tostring(entry.name),
                entry.declaration,
                entry.summary,
                insert_text,
                cursor_anchor,
                {
                    kind = "command",
                    is_alias = entry.canonical ~= entry.name,
                    hover_doc = FlowTextHoverProvider.build_command_doc(entry, entry.name),
                })
        end
        return _filter_and_sort(candidate_list, context.prefix)
    end

    if context.kind == "directive" then
        local candidate_list = {}
        for name in pairs(
        {
            alias = true,
            import = true,
            outline = true,
        })
        do
            local entry = FlowTextEditorSemantics.find_directive_entry(document, name)
            if entry then
                local insert_text = entry.completion_template or string.format("%s()", tostring(name))
                local cursor_anchor = entry.completion_cursor_text or string.format("%s(", tostring(name))
                candidate_list[#candidate_list + 1] = _build_candidate(
                    name,
                    "@@" .. tostring(name),
                    entry.declaration,
                    entry.summary,
                    insert_text,
                    cursor_anchor,
                    {
                        kind = "directive",
                        hover_doc = FlowTextHoverProvider.build_directive_doc(entry, name),
                    })
            end
        end
        return _filter_and_sort(candidate_list, context.prefix)
    end

    if context.kind == "parameter" then
        local candidate_list = {}
        local used_named_args = context.used_named_args or {}
        local seen_pool = {}
        for _, parameter_name in ipairs(_get_parameter_variants(document, context.command_name, used_named_args)) do
            if not seen_pool[parameter_name] then
                seen_pool[parameter_name] = true
                local entry = FlowTextEditorSemantics.find_parameter_entry(document, parameter_name)
                    or FlowTextEditorSemantics.find_parameter_entry(document, parameter_name:gsub("^@", ""))
                candidate_list[#candidate_list + 1] = _build_candidate(
                    parameter_name,
                    parameter_name,
                    entry and entry.declaration or parameter_name,
                    entry and entry.doc or "",
                    string.format("%s: ", tostring(parameter_name)),
                    string.format("%s: ", tostring(parameter_name)),
                    {
                        kind = "parameter",
                        hover_doc = FlowTextHoverProvider.build_parameter_doc(context.command_entry, parameter_name),
                    })
            end
        end
        return _filter_and_sort(candidate_list, context.prefix)
    end

    if context.kind == "label" then
        local candidate_list = {}
        for _, entry in ipairs(FlowTextEditorSemantics.get_label_candidates(document) or {}) do
            local summary = entry.imported
                and string.format("导入标签，定义于第 %d 行", tonumber(entry.line) or 1)
                or string.format("定义于第 %d 行", tonumber(entry.line) or 1)
            candidate_list[#candidate_list + 1] = _build_candidate(
                entry.name,
                "#" .. tostring(entry.name),
                entry.declaration,
                summary,
                entry.name,
                entry.name,
                {
                    kind = "label",
                    hover_doc = FlowTextHoverProvider.build_label_doc(entry),
                })
        end
        return _filter_and_sort(candidate_list, context.prefix)
    end

    if context.kind == "resource_type" then
        local candidate_list = {}
        for _, entry in ipairs(FlowTextEditorSemantics.get_resource_type_candidates(document) or {}) do
            candidate_list[#candidate_list + 1] = _build_candidate(
                entry.name,
                "&" .. tostring(entry.name),
                entry.declaration,
                entry.summary,
                string.format('%s("")', tostring(entry.name)),
                string.format('%s("', tostring(entry.name)),
                {
                    kind = "resource_type",
                    hover_doc = FlowTextHoverProvider.build_resource_type_doc(entry, entry.name),
                })
        end
        return _filter_and_sort(candidate_list, context.prefix)
    end

    if context.kind == "resource_locator" then
        local candidate_list = {}
        for _, entry in ipairs(FlowTextEditorSemantics.list_resources(document, context.asset_type) or {}) do
            local locator = context.asset_type == "flow" and (entry.locator or entry.name) or entry.name
            candidate_list[#candidate_list + 1] = _build_candidate(
                locator,
                locator,
                entry.declaration,
                entry.summary,
                locator,
                locator,
                {kind = "resource_locator"})
        end
        return _filter_and_sort(candidate_list, context.prefix)
    end

    if context.kind == "flow_locator" then
        local candidate_list = {}
        for _, entry in ipairs(FlowTextEditorSemantics.list_resources(document, "flow") or {}) do
            local locator = entry.locator or entry.name
            candidate_list[#candidate_list + 1] = _build_candidate(
                locator,
                locator,
                entry.declaration,
                entry.summary,
                locator,
                locator,
                {kind = "flow_locator"})
        end
        return _filter_and_sort(candidate_list, context.prefix)
    end

    return {}
end

return module
