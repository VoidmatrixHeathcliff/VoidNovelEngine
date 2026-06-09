local FlowTextEditorSemantics = require("application.framework.flow_text_editor_semantics")
local FlowTextLabelSyntax = require("application.framework.flow_text_label_syntax")
local FlowTextLexer = require("application.framework.flow_text_lexer")

local module = {}

local function _trim(text)
    if type(text) ~= "string" then
        return ""
    end
    return text:match("^%s*(.-)%s*$")
end

local function _char_len(text)
    local ok, length = pcall(utf8.len, tostring(text or ""))
    if ok and length then
        return length
    end
    return #(tostring(text or ""))
end

local function _column_to_byte(text, column)
    local normalized_text = tostring(text or "")
    local normalized_column = math.max(1, math.floor(tonumber(column) or 1))
    local target_char = normalized_column - 1
    if target_char <= 0 then
        return 1
    end

    local length = _char_len(normalized_text)
    if target_char >= length then
        return #normalized_text + 1
    end

    local offset = utf8.offset(normalized_text, target_char + 1)
    return offset or (#normalized_text + 1)
end

local function _byte_to_column(text, byte_index)
    local normalized_text = tostring(text or "")
    local normalized_byte = math.max(1, math.floor(tonumber(byte_index) or 1))
    if normalized_byte <= 1 then
        return 1
    end

    local prefix = normalized_text:sub(1, normalized_byte - 1)
    return _char_len(prefix) + 1
end

local function _find_prev_non_space_byte(text, byte_index)
    local limit = math.floor(tonumber(byte_index) or 0)
    if limit < 1 then
        return nil, nil
    end

    local cursor = math.min(#text, limit)
    while cursor >= 1 do
        local ch = text:sub(cursor, cursor)
        if not ch:match("%s") then
            return cursor, ch
        end
        cursor = cursor - 1
    end
    return nil, nil
end

local function _scan_prefixed_identifier(before, marker)
    local marker_text = tostring(marker or "")
    if marker_text == "" then
        return nil, nil
    end

    local cursor = #before
    while cursor >= 1 and before:sub(cursor, cursor):match("[A-Za-z0-9_]") do
        cursor = cursor - 1
    end

    if before:sub(cursor, cursor) ~= marker_text then
        return nil, nil
    end

    local prefix = before:sub(cursor + 1)
    if prefix ~= "" and not prefix:match("^[A-Za-z_][A-Za-z0-9_]*$") then
        return nil, nil
    end

    return cursor, prefix
end

local function _scan_prefixed_label(before, marker)
    local text = tostring(before or "")
    local marker_text = tostring(marker or "")
    if marker_text == "" then
        return nil, nil
    end

    local search_start = 1
    local marker_start = nil
    while true do
        local found = text:find(marker_text, search_start, true)
        if not found then
            break
        end
        marker_start = found
        search_start = found + #marker_text
    end

    if not marker_start then
        return nil, nil
    end

    local prefix = text:sub(marker_start + #marker_text)
    if not FlowTextLabelSyntax.is_valid_label_prefix(prefix) then
        return nil, nil
    end

    return marker_start, prefix
end

local function _is_label_reference_context(before, hash_start)
    if hash_start <= 1 then
        return true
    end

    local prev_index, prev_char = _find_prev_non_space_byte(before, hash_start - 1)
    if not prev_index or not prev_char then
        return true
    end

    if prev_char == ":" or prev_char == "(" or prev_char == "," or prev_char == "=" then
        return true
    end

    if prev_char == ">" then
        local _, arrow_char = _find_prev_non_space_byte(before, prev_index - 1)
        return arrow_char == "-"
    end

    return false
end

local function _find_matching_paren(text, open_index)
    local depth = 0
    local in_string = false
    local escape = false

    for cursor = open_index, #text do
        local ch = text:sub(cursor, cursor)
        if in_string then
            if escape then
                escape = false
            elseif ch == "\\" then
                escape = true
            elseif ch == "\"" then
                in_string = false
            end
        else
            if ch == "\"" then
                in_string = true
            elseif ch == "(" then
                depth = depth + 1
            elseif ch == ")" then
                depth = depth - 1
                if depth == 0 then
                    return cursor
                end
            end
        end
    end

    return nil
end

local function _find_top_level(text, needle)
    local depth = 0
    local in_string = false
    local escape = false
    local cursor = 1
    local needle_len = #needle

    while cursor <= #text do
        local ch = text:sub(cursor, cursor)
        if in_string then
            if escape then
                escape = false
            elseif ch == "\\" then
                escape = true
            elseif ch == "\"" then
                in_string = false
            end
            cursor = cursor + 1
        else
            if ch == "\"" then
                in_string = true
                cursor = cursor + 1
            elseif ch == "(" then
                depth = depth + 1
                cursor = cursor + 1
            elseif ch == ")" then
                depth = math.max(0, depth - 1)
                cursor = cursor + 1
            elseif depth == 0 and text:sub(cursor, cursor + needle_len - 1) == needle then
                return cursor
            else
                cursor = cursor + 1
            end
        end
    end

    return nil
end

local function _split_top_level_segments(text)
    local result = {}
    local depth = 0
    local in_string = false
    local escape = false
    local segment_start = 1
    local cursor = 1

    while cursor <= #text do
        local ch = text:sub(cursor, cursor)
        if in_string then
            if escape then
                escape = false
            elseif ch == "\\" then
                escape = true
            elseif ch == "\"" then
                in_string = false
            end
        else
            if ch == "\"" then
                in_string = true
            elseif ch == "(" then
                depth = depth + 1
            elseif ch == ")" then
                depth = math.max(0, depth - 1)
            elseif ch == "," and depth == 0 then
                result[#result + 1] =
                {
                    start_byte = segment_start,
                    end_byte = cursor,
                    text = text:sub(segment_start, cursor - 1),
                }
                segment_start = cursor + 1
            end
        end
        cursor = cursor + 1
    end

    result[#result + 1] =
    {
        start_byte = segment_start,
        end_byte = #text + 1,
        text = text:sub(segment_start),
    }
    return result
end

local function _make_context(line_text, line_number, kind, replace_start_byte, replace_end_byte, prefix, extra)
    local context =
    {
        kind = kind,
        line = tonumber(line_number) or 1,
        replace_start_col = _byte_to_column(line_text, replace_start_byte),
        replace_end_col = _byte_to_column(line_text, replace_end_byte),
        prefix = prefix or "",
    }

    for key, value in pairs(extra or {}) do
        context[key] = value
    end
    return context
end

local function _find_signature_item(command_entry, name)
    for _, item in ipairs(command_entry and command_entry.signature or {}) do
        if item.name == name then
            return item
        end
        for _, alias in ipairs(item.aliases or {}) do
            if alias == name then
                return item
            end
        end
    end
    return nil
end

local function _collect_used_named_args(command_entry, args_text, current_segment)
    local used_pool = {}
    for _, segment in ipairs(_split_top_level_segments(args_text)) do
        if current_segment
            and segment.start_byte == current_segment.start_byte
            and segment.end_byte == current_segment.end_byte
        then
            goto continue
        end

        local colon_index = _find_top_level(segment.text, ":")
        if colon_index then
            local key_name = _trim(segment.text:sub(1, colon_index - 1))
            if key_name ~= "" then
                local signature_item = _find_signature_item(command_entry, key_name)
                if signature_item then
                    used_pool[signature_item.name] = true
                else
                    used_pool[key_name] = true
                end
            end
        end

        ::continue::
    end
    return used_pool
end

local function _find_segment_for_cursor(segment_list, cursor_in_args)
    for _, segment in ipairs(segment_list) do
        if cursor_in_args >= segment.start_byte and cursor_in_args <= segment.end_byte then
            return segment
        end
    end
    return segment_list[#segment_list]
end

local function _match_identifier_prefix(text)
    return text:match("^([A-Za-z_][A-Za-z0-9_]*)$")
end

local function _resolve_identifier_prefix(text)
    local normalized_text = _trim(text)
    local matched = _match_identifier_prefix(normalized_text)
    if matched ~= nil then
        return matched
    end
    if normalized_text == "" then
        return ""
    end
    return nil
end

local function _analyze_label_context(line_text, line_number, cursor_byte)
    local before = line_text:sub(1, cursor_byte - 1)
    local hash_start, prefix = _scan_prefixed_label(before, "#")
    if not hash_start or not _is_label_reference_context(before, hash_start) then
        return nil
    end

    local replace_start = hash_start + 1
    return _make_context(line_text, line_number, "label", replace_start, cursor_byte, prefix,
    {
        auto_trigger = true,
    })
end

local function _analyze_resource_type_context(line_text, line_number, cursor_byte)
    local before = line_text:sub(1, cursor_byte - 1)
    local ampersand_start, prefix = _scan_prefixed_identifier(before, "&")
    if not ampersand_start then
        return nil
    end

    local replace_start = ampersand_start + 1
    return _make_context(line_text, line_number, "resource_type", replace_start, cursor_byte, prefix,
    {
        auto_trigger = true,
    })
end

local function _analyze_resource_locator_context(line_text, line_number, cursor_byte)
    local before = line_text:sub(1, cursor_byte - 1)
    local asset_type, locator_prefix = before:match("&([A-Za-z_][A-Za-z0-9_]*)%s*%(%s*\"([^\"]*)$")
    if not asset_type then
        return nil
    end

    local fragment_start = before:match(".*()\"[^\"]*$")
    if not fragment_start then
        return nil
    end

    return _make_context(line_text, line_number, "resource_locator", fragment_start + 1, cursor_byte, locator_prefix,
    {
        asset_type = asset_type,
        auto_trigger = true,
    })
end

local function _analyze_flow_locator_string(line_text, line_number, cursor_byte, value_start_byte, value_before_cursor, extra)
    if not value_before_cursor:match('^%s*"[^"]*$') then
        return nil
    end

    local quote_offset = value_before_cursor:find('"', 1, true)
    if not quote_offset then
        return nil
    end

    local prefix = value_before_cursor:sub(quote_offset + 1)
    local replace_start = value_start_byte + quote_offset
    return _make_context(line_text, line_number, "flow_locator", replace_start, cursor_byte, prefix, extra)
end

local function _analyze_command_arguments(document, line_text, line_number, cursor_byte, command_entry, open_index, close_index)
    local args_start = open_index + 1
    local args_end = (close_index and close_index - 1) or #line_text
    if cursor_byte < args_start or cursor_byte > (args_end + 1) then
        return nil
    end

    local args_text = line_text:sub(args_start, args_end)
    local cursor_in_args = math.max(1, cursor_byte - args_start + 1)
    local segment_list = _split_top_level_segments(args_text)
    local current_segment = _find_segment_for_cursor(segment_list, cursor_in_args)
    if not current_segment then
        return nil
    end

    local segment_text = current_segment.text or ""
    local segment_abs_start = args_start + current_segment.start_byte - 1
    local cursor_in_segment = math.max(1, cursor_byte - segment_abs_start + 1)
    local before_cursor = segment_text:sub(1, cursor_in_segment - 1)

    local local_label_context = _analyze_label_context(segment_text, line_number, cursor_in_segment)
    if local_label_context then
        return _make_context(
            line_text,
            line_number,
            "label",
            segment_abs_start + _column_to_byte(segment_text, local_label_context.replace_start_col) - 1,
            segment_abs_start + _column_to_byte(segment_text, local_label_context.replace_end_col) - 1,
            local_label_context.prefix,
            {auto_trigger = true})
    end

    local local_resource_type_context = _analyze_resource_type_context(segment_text, line_number, cursor_in_segment)
    if local_resource_type_context then
        return _make_context(
            line_text,
            line_number,
            "resource_type",
            segment_abs_start + _column_to_byte(segment_text, local_resource_type_context.replace_start_col) - 1,
            segment_abs_start + _column_to_byte(segment_text, local_resource_type_context.replace_end_col) - 1,
            local_resource_type_context.prefix,
            {auto_trigger = true})
    end

    local local_resource_locator_context = _analyze_resource_locator_context(segment_text, line_number, cursor_in_segment)
    if local_resource_locator_context then
        return _make_context(
            line_text,
            line_number,
            "resource_locator",
            segment_abs_start + _column_to_byte(segment_text, local_resource_locator_context.replace_start_col) - 1,
            segment_abs_start + _column_to_byte(segment_text, local_resource_locator_context.replace_end_col) - 1,
            local_resource_locator_context.prefix,
            {
                asset_type = local_resource_locator_context.asset_type,
                auto_trigger = true,
            })
    end

    local colon_index = _find_top_level(segment_text, ":")
    if colon_index == nil then
        local segment_prefix = _trim(before_cursor)
        local identifier_prefix = _resolve_identifier_prefix(segment_prefix)
        if identifier_prefix ~= nil then
            local replace_start = segment_abs_start + cursor_in_segment - #identifier_prefix - 1
            return _make_context(line_text, line_number, "parameter", replace_start, cursor_byte, identifier_prefix,
            {
                command_name = command_entry.name,
                command_entry = command_entry,
                used_named_args = _collect_used_named_args(command_entry, args_text, current_segment),
                auto_trigger = true,
            })
        end
        return nil
    end

    if cursor_in_segment <= colon_index then
        local key_prefix = _trim(segment_text:sub(1, cursor_in_segment - 1))
        local identifier_prefix = _resolve_identifier_prefix(key_prefix)
        if identifier_prefix ~= nil then
            local replace_start = segment_abs_start + cursor_in_segment - #identifier_prefix - 1
            return _make_context(line_text, line_number, "parameter", replace_start, cursor_byte, identifier_prefix,
            {
                command_name = command_entry.name,
                command_entry = command_entry,
                used_named_args = _collect_used_named_args(command_entry, args_text, current_segment),
                auto_trigger = true,
            })
        end
        return nil
    end

    local key_name = _trim(segment_text:sub(1, colon_index - 1))
    local signature_item = _find_signature_item(command_entry, key_name)
    local value_start_byte = segment_abs_start + colon_index
    local value_text = segment_text:sub(colon_index + 1)
    local value_before_cursor = segment_text:sub(colon_index + 1, math.max(colon_index + 1, cursor_in_segment - 1))

    if signature_item and signature_item.adapter == "flow_locator" then
        local flow_context = _analyze_flow_locator_string(line_text, line_number, cursor_byte, value_start_byte, value_before_cursor,
        {
            command_name = command_entry.name,
            parameter_name = signature_item.name,
            auto_trigger = true,
        })
        if flow_context then
            return flow_context
        end
    end

    local schema_pin = command_entry.schema and command_entry.schema.input_by_key and command_entry.schema.input_by_key[signature_item and signature_item.pin or key_name] or nil
    if schema_pin and schema_pin.type_id == "flow" then
        local flow_context = _analyze_flow_locator_string(line_text, line_number, cursor_byte, value_start_byte, value_before_cursor,
        {
            command_name = command_entry.name,
            parameter_name = signature_item and signature_item.name or key_name,
            auto_trigger = true,
        })
        if flow_context then
            return flow_context
        end
    end

    return nil
end

local function _analyze_command_context(document, line_text, line_number, cursor_byte)
    local first_non_space = line_text:find("%S")
    if not first_non_space then
        return nil
    end

    if line_text:sub(first_non_space, first_non_space) ~= "@" or line_text:sub(first_non_space, first_non_space + 1) == "@@" then
        return nil
    end

    local name_start = first_non_space + 1
    local name_end = name_start
    while name_end <= #line_text and line_text:sub(name_end, name_end):match("[A-Za-z0-9_]") do
        name_end = name_end + 1
    end
    name_end = name_end - 1

    local open_index = line_text:find("(", name_end + 1, true)
    local replace_end = name_end >= name_start and (name_end + 1) or cursor_byte
    if cursor_byte >= name_start and cursor_byte <= math.max(name_start, replace_end) then
        local prefix = line_text:sub(name_start, cursor_byte - 1)
        return _make_context(line_text, line_number, "command", name_start, replace_end, prefix,
        {
            auto_trigger = true,
        })
    end

    if not open_index or cursor_byte < open_index then
        return nil
    end

    local command_name = line_text:sub(name_start, math.max(name_start, name_end))
    if command_name == "" then
        return nil
    end

    local command_entry = FlowTextEditorSemantics.find_command_entry(document, command_name)
    if not command_entry then
        return nil
    end

    local close_index = _find_matching_paren(line_text, open_index)
    return _analyze_command_arguments(document, line_text, line_number, cursor_byte, command_entry, open_index, close_index)
end

local function _analyze_directive_context(document, line_text, line_number, cursor_byte)
    local first_non_space = line_text:find("%S")
    if not first_non_space or line_text:sub(first_non_space, first_non_space + 1) ~= "@@" then
        return nil
    end

    local name_start = first_non_space + 2
    local name_end = name_start
    while name_end <= #line_text and line_text:sub(name_end, name_end):match("[A-Za-z0-9_]") do
        name_end = name_end + 1
    end
    name_end = name_end - 1

    local replace_end = name_end >= name_start and (name_end + 1) or cursor_byte
    if cursor_byte >= name_start and cursor_byte <= math.max(name_start, replace_end) then
        local prefix = line_text:sub(name_start, cursor_byte - 1)
        return _make_context(line_text, line_number, "directive", name_start, replace_end, prefix,
        {
            auto_trigger = true,
        })
    end

    local directive_name = line_text:sub(name_start, math.max(name_start, name_end))
    local open_index = line_text:find("(", name_end + 1, true)
    if not open_index or cursor_byte <= open_index then
        return nil
    end

    if directive_name == "import" then
        local before = line_text:sub(1, cursor_byte - 1)
        local prefix = before:match('@@import%s*%([^"]*"([^"]*)$')
        if prefix ~= nil then
            local replace_start = before:match('.*()"[^"]*$')
            if replace_start then
                return _make_context(line_text, line_number, "flow_locator", replace_start + 1, cursor_byte, prefix,
                {
                    auto_trigger = true,
                })
            end
        end
    elseif directive_name == "alias" then
        local body_text = line_text:sub(open_index + 1, #line_text)
        local cursor_in_body = math.max(1, cursor_byte - open_index)
        local equal_index = _find_top_level(body_text, "=")
        if equal_index and cursor_in_body > equal_index then
            local right_text = body_text:sub(equal_index + 1)
            local right_prefix = _trim(right_text:sub(1, math.max(0, cursor_in_body - equal_index - 1)))
            if right_prefix:match("^[A-Za-z_][A-Za-z0-9_]*$") or right_prefix == "" then
                local trimmed_leading = right_text:match("^%s*()") or 1
                local replace_start = open_index + equal_index + trimmed_leading
                return _make_context(line_text, line_number, "command", replace_start, cursor_byte, right_prefix,
                {
                    command_completion_mode = "name_only",
                    auto_trigger = true,
                })
            end
        end
    end

    return nil
end

local function _get_line_info(document, line_number)
    local cache = FlowTextEditorSemantics.ensure_cache(document)
    local line_list = cache.line_list or FlowTextLexer.split_lines(document:get_source_text())
    return line_list[math.max(1, math.floor(tonumber(line_number) or 1))] or {number = line_number or 1, text = "", trimmed = ""}
end

module.analyze = function(document, line_number, column)
    local line_info = _get_line_info(document, line_number)
    local line_text = tostring(line_info.text or "")
    local cursor_byte = _column_to_byte(line_text, column)

    return _analyze_directive_context(document, line_text, line_info.number, cursor_byte)
        or _analyze_command_context(document, line_text, line_info.number, cursor_byte)
        or _analyze_resource_locator_context(line_text, line_info.number, cursor_byte)
        or _analyze_resource_type_context(line_text, line_info.number, cursor_byte)
        or _analyze_label_context(line_text, line_info.number, cursor_byte)
end

return module
