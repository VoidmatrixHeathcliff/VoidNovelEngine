local Diagnostics = require("application.framework.flow_text_diagnostics")
local LabelSyntax = require("application.framework.flow_text_label_syntax")

local module = {}

local function _split_lines(source_text)
    local text = tostring(source_text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    local line_list = {}
    local line_number = 1

    if text == "" then
        return
        {
            {
                number = 1,
                text = "",
                trimmed = "",
            }
        }
    end

    for line in (text .. "\n"):gmatch("(.-)\n") do
        table.insert(line_list,
        {
            number = line_number,
            text = line,
            trimmed = line:match("^%s*(.-)%s*$"),
        })
        line_number = line_number + 1
    end

    return line_list
end

local function _is_identifier_start(ch)
    return ch and ch:match("[A-Za-z_]")
end

local function _scan_string(text, index, line, column)
    local quote = text:sub(index, index)
    local cursor = index + 1
    local buffer = {}

    while cursor <= #text do
        local ch = text:sub(cursor, cursor)
        if ch == "\\" then
            local next_ch = text:sub(cursor + 1, cursor + 1)
            if next_ch == "n" then
                table.insert(buffer, "\n")
            elseif next_ch == "r" then
                table.insert(buffer, "\r")
            elseif next_ch == "t" then
                table.insert(buffer, "\t")
            elseif next_ch == "\"" then
                table.insert(buffer, "\"")
            elseif next_ch == "\\" then
                table.insert(buffer, "\\")
            else
                table.insert(buffer, next_ch)
            end
            cursor = cursor + 2
        elseif ch == quote then
            return
            {
                kind = "string",
                value = table.concat(buffer),
                line = line,
                column = column,
            },
            cursor + 1
        else
            table.insert(buffer, ch)
            cursor = cursor + 1
        end
    end

    return nil, index, Diagnostics.error("unterminated_string", "字符串没有正常闭合", line, column)
end

local function _scan_number(text, index)
    local cursor = index
    if text:sub(cursor, cursor) == "-" then
        cursor = cursor + 1
    end

    while cursor <= #text and text:sub(cursor, cursor):match("[%d_]") do
        cursor = cursor + 1
    end

    if text:sub(cursor, cursor) == "." and text:sub(cursor + 1, cursor + 1):match("[%d]") then
        cursor = cursor + 1
        while cursor <= #text and text:sub(cursor, cursor):match("[%d_]") do
            cursor = cursor + 1
        end
    end

    return text:sub(index, cursor - 1):gsub("_", ""), cursor
end

module.split_lines = _split_lines

module.tokenize_expression = function(text, line, column)
    local token_list = {}
    local diagnostic_list = {}
    local cursor = 1
    local base_line = tonumber(line) or 1
    local base_column = tonumber(column) or 1

    while cursor <= #text do
        local ch = text:sub(cursor, cursor)
        local token_column = base_column + cursor - 1

        if ch:match("%s") then
            cursor = cursor + 1
        elseif ch == "\"" then
            local token, next_cursor, err = _scan_string(text, cursor, base_line, token_column)
            if err then
                table.insert(diagnostic_list, err)
                break
            end
            table.insert(token_list, token)
            cursor = next_cursor
        elseif ch:match("[%d]") or (ch == "-" and text:sub(cursor + 1, cursor + 1):match("[%d]")) then
            local number_text
            number_text, cursor = _scan_number(text, cursor)
            table.insert(token_list,
            {
                kind = "number",
                value = number_text,
                line = base_line,
                column = token_column,
            })
        elseif ch == "$" then
            local start_cursor = cursor
            cursor = cursor + 1
            while cursor <= #text and text:sub(cursor, cursor):match("[%w_%.]") do
                cursor = cursor + 1
            end
            table.insert(token_list,
            {
                kind = "variable",
                value = text:sub(start_cursor + 1, cursor - 1),
                line = base_line,
                column = token_column,
            })
        elseif ch == "#" then
            local tail = text:sub(cursor + 1):match("^([0-9A-Fa-f]+)")
            if tail and (#tail == 6 or #tail == 8) then
                table.insert(token_list,
                {
                    kind = "color",
                    value = tail,
                    line = base_line,
                    column = token_column,
                })
                cursor = cursor + 1 + #tail
            else
                local label_name, next_cursor = LabelSyntax.scan_label_name(text, cursor + 1)
                if label_name then
                    table.insert(token_list,
                    {
                        kind = "label_ref",
                        value = label_name,
                        line = base_line,
                        column = token_column,
                    })
                    cursor = next_cursor
                else
                    table.insert(diagnostic_list,
                        Diagnostics.error("invalid_expression_token", string.format("无法识别的表达式字符：%s", ch), base_line, token_column))
                    cursor = cursor + 1
                end
            end
        elseif ch == "=" and text:sub(cursor + 1, cursor + 1) == "=" then
            table.insert(token_list, {kind = "op", value = "==", line = base_line, column = token_column})
            cursor = cursor + 2
        elseif ch == "!" and text:sub(cursor + 1, cursor + 1) == "=" then
            table.insert(token_list, {kind = "op", value = "!=", line = base_line, column = token_column})
            cursor = cursor + 2
        elseif ch == ">" and text:sub(cursor + 1, cursor + 1) == "=" then
            table.insert(token_list, {kind = "op", value = ">=", line = base_line, column = token_column})
            cursor = cursor + 2
        elseif ch == "<" and text:sub(cursor + 1, cursor + 1) == "=" then
            table.insert(token_list, {kind = "op", value = "<=", line = base_line, column = token_column})
            cursor = cursor + 2
        elseif ch == ">" or ch == "<" or ch == "(" or ch == ")" then
            table.insert(token_list, {kind = "op", value = ch, line = base_line, column = token_column})
            cursor = cursor + 1
        elseif _is_identifier_start(ch) then
            local start_cursor = cursor
            cursor = cursor + 1
            while cursor <= #text and text:sub(cursor, cursor):match("[%w_%.]") do
                cursor = cursor + 1
            end
            local value = text:sub(start_cursor, cursor - 1)
            local lower_value = string.lower(value)
            local kind = "identifier"
            if lower_value == "and" or lower_value == "or" or lower_value == "not" then
                kind = "op"
                value = lower_value
            elseif lower_value == "true" or lower_value == "false" then
                kind = "boolean"
                value = lower_value == "true"
            elseif lower_value == "null" then
                kind = "null"
                value = nil
            end
            table.insert(token_list,
            {
                kind = kind,
                value = value,
                line = base_line,
                column = token_column,
            })
        else
            table.insert(diagnostic_list,
                Diagnostics.error("invalid_expression_token", string.format("无法识别的表达式字符：%s", ch), base_line, token_column))
            cursor = cursor + 1
        end
    end

    table.insert(token_list, {kind = "eof", value = nil, line = base_line, column = base_column + #text})
    return token_list, diagnostic_list
end

return module
