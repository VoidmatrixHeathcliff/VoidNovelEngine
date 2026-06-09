local module = {}

local function _parse_tag(source, start_index)
    local close_index = source:find("]", start_index, true)
    if not close_index then
        return nil
    end
    local raw = source:sub(start_index + 1, close_index - 1)
    return
    {
        raw = raw,
        close_index = close_index,
    }
end

local function _semantic_display(kind, target)
    target = tostring(target or "")
    if kind == "command" then
        return "@" .. target
    end
    if kind == "directive" then
        return "@@" .. target
    end
    if kind == "type" then
        return "&" .. target
    end
    if kind == "label" then
        if target:sub(1, 1) == "#" then
            return target
        end
        return "#" .. target
    end
    return target
end

local function _parse_inline(source, start_index, end_tag)
    local nodes = {}
    local buffer = {}
    local length = #source
    local cursor = start_index or 1

    local function flush_buffer()
        if #buffer == 0 then
            return
        end
        nodes[#nodes + 1] =
        {
            kind = "text",
            text = table.concat(buffer),
        }
        buffer = {}
    end

    while cursor <= length do
        local ch = source:sub(cursor, cursor)
        if ch == "\\" then
            local next_char = source:sub(cursor + 1, cursor + 1)
            if next_char == "[" or next_char == "]" or next_char == "\\" then
                buffer[#buffer + 1] = next_char
                cursor = cursor + 2
            else
                buffer[#buffer + 1] = ch
                cursor = cursor + 1
            end
        elseif ch == "\n" then
            flush_buffer()
            nodes[#nodes + 1] = {kind = "line_break"}
            cursor = cursor + 1
        elseif ch ~= "[" then
            buffer[#buffer + 1] = ch
            cursor = cursor + 1
        else
            local parsed = _parse_tag(source, cursor)
            if not parsed then
                buffer[#buffer + 1] = ch
                cursor = cursor + 1
            else
                local raw = parsed.raw
                if end_tag and raw == "/" .. end_tag then
                    flush_buffer()
                    return nodes, parsed.close_index + 1, true
                end

                local matched = false
                if raw == "br" then
                    flush_buffer()
                    nodes[#nodes + 1] = {kind = "line_break"}
                    cursor = parsed.close_index + 1
                    matched = true
                else
                    local semantic_kind, semantic_target = raw:match("^(%w+)%s+(.+)$")
                    if semantic_kind and semantic_target and
                        (semantic_kind == "command"
                            or semantic_kind == "directive"
                            or semantic_kind == "param"
                            or semantic_kind == "pin"
                            or semantic_kind == "type"
                            or semantic_kind == "label")
                    then
                        flush_buffer()
                        nodes[#nodes + 1] =
                        {
                            kind = "semantic",
                            semantic_kind = semantic_kind,
                            target = semantic_target,
                            display = _semantic_display(semantic_kind, semantic_target),
                        }
                        cursor = parsed.close_index + 1
                        matched = true
                    end
                end

                if not matched then
                    local style_name = raw
                    local style_arg = nil
                    if raw:match("^color=") then
                        style_name = "color"
                        style_arg = raw:match("^color=(.+)$")
                    elseif raw:match("^url=") then
                        style_name = "url"
                        style_arg = raw:match("^url=(.+)$")
                    end

                    local is_container = style_name == "b"
                        or style_name == "i"
                        or style_name == "u"
                        or style_name == "code"
                        or style_name == "kbd"
                        or style_name == "color"
                        or style_name == "url"
                    if is_container then
                        flush_buffer()
                        local child_nodes, next_cursor, closed = _parse_inline(source, parsed.close_index + 1, style_name)
                        if closed then
                            nodes[#nodes + 1] =
                            {
                                kind = "container",
                                style = style_name,
                                arg = style_arg,
                                children = child_nodes,
                            }
                            cursor = next_cursor
                            matched = true
                        end
                    end
                end

                if not matched then
                    buffer[#buffer + 1] = source:sub(cursor, parsed.close_index)
                    cursor = parsed.close_index + 1
                end
            end
        end
    end

    flush_buffer()
    return nodes, cursor, false
end

local function _parse_blocks(text)
    local result = {}
    local normalized = tostring(text or ""):gsub("\r\n", "\n")
    local paragraph_buffer = {}
    local code_language = nil
    local code_buffer = {}

    local function flush_paragraph()
        if #paragraph_buffer == 0 then
            return
        end
        local paragraph_text = table.concat(paragraph_buffer, "\n")
        local inline_nodes = _parse_inline(paragraph_text, 1, nil)
        result[#result + 1] =
        {
            kind = "paragraph",
            children = inline_nodes,
        }
        paragraph_buffer = {}
    end

    local function flush_code_block()
        result[#result + 1] =
        {
            kind = "codeblock",
            language = code_language or "",
            text = table.concat(code_buffer, "\n"),
        }
        code_language = nil
        code_buffer = {}
    end

    for line in (normalized .. "\n"):gmatch("(.-)\n") do
        if code_language ~= nil then
            if line:match("^%s*%[/codeblock%]%s*$") then
                flush_code_block()
            else
                code_buffer[#code_buffer + 1] = line
            end
        else
            local lang = line:match("^%s*%[codeblock%s+lang=([%w_%-]+)%]%s*$")
            if lang then
                flush_paragraph()
                code_language = lang
            elseif line:match("^%s*$") then
                flush_paragraph()
            else
                paragraph_buffer[#paragraph_buffer + 1] = line
            end
        end
    end

    flush_paragraph()
    if code_language ~= nil then
        flush_code_block()
    end
    return result
end

local function _copy_style(style)
    local result = {}
    if type(style) ~= "table" then
        return result
    end
    for key, value in pairs(style) do
        result[key] = value
    end
    return result
end

local function _style_key(style)
    if type(style) ~= "table" then
        return ""
    end
    local key_list =
    {
        "bold",
        "italic",
        "underline",
        "code",
        "kbd",
        "color",
        "url",
        "semantic_kind",
    }
    local part_list = {}
    for _, key in ipairs(key_list) do
        local value = style[key]
        if value ~= nil and value ~= false then
            part_list[#part_list + 1] = string.format("%s=%s", key, tostring(value))
        end
    end
    return table.concat(part_list, ";")
end

local function _flatten_inline(nodes, style_override)
    local chunk_list = {}

    local function push(style, text)
        if text == nil or text == "" then
            return
        end
        local normalized_style = _copy_style(style)
        local style_key = _style_key(normalized_style)
        local last_chunk = chunk_list[#chunk_list]
        if last_chunk
            and last_chunk.kind == "text"
            and last_chunk.style_key == style_key
        then
            last_chunk.text = tostring(last_chunk.text or "") .. tostring(text)
            return
        end
        chunk_list[#chunk_list + 1] =
        {
            kind = "text",
            style = normalized_style,
            style_key = style_key,
            text = text,
        }
    end

    local function visit(node, inherited_style)
        if type(node) ~= "table" then
            return
        end

        if node.kind == "text" then
            push(inherited_style, node.text)
            return
        end
        if node.kind == "line_break" then
            chunk_list[#chunk_list + 1] = {kind = "line_break"}
            return
        end
        if node.kind == "semantic" then
            local semantic_style = _copy_style(inherited_style)
            semantic_style.semantic_kind = node.semantic_kind
            push(semantic_style, node.display or node.target or "")
            return
        end
        if node.kind == "container" then
            local next_style = _copy_style(inherited_style)
            if node.style == "b" then
                next_style.bold = true
            elseif node.style == "i" then
                next_style.italic = true
            elseif node.style == "u" then
                next_style.underline = true
            elseif node.style == "code" then
                next_style.code = true
            elseif node.style == "kbd" then
                next_style.kbd = true
            elseif node.style == "color" then
                next_style.color = node.arg
            elseif node.style == "url" then
                next_style.url = node.arg or true
                next_style.underline = true
            end
            for _, child in ipairs(node.children or {}) do
                visit(child, next_style)
            end
        end
    end

    for _, node in ipairs(nodes or {}) do
        visit(node, style_override)
    end
    return chunk_list
end

module.parse = function(text)
    return _parse_blocks(text)
end

module.flatten_inline = function(nodes, style_override)
    return _flatten_inline(nodes, style_override)
end

module.to_plain_text = function(text)
    local blocks = _parse_blocks(text)
    local line_list = {}
    for _, block in ipairs(blocks) do
        if block.kind == "paragraph" then
            local chunk_list = _flatten_inline(block.children)
            local buffer = {}
            for _, chunk in ipairs(chunk_list) do
                buffer[#buffer + 1] = chunk.kind == "line_break" and "\n" or tostring(chunk.text or "")
            end
            line_list[#line_list + 1] = table.concat(buffer)
        elseif block.kind == "codeblock" then
            line_list[#line_list + 1] = tostring(block.text or "")
        end
    end
    return table.concat(line_list, "\n\n")
end

return module
