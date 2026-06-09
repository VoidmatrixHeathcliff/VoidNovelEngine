local AST = require("application.framework.flow_text_ast")
local Diagnostics = require("application.framework.flow_text_diagnostics")
local Lexer = require("application.framework.flow_text_lexer")
local LabelSyntax = require("application.framework.flow_text_label_syntax")
local Preprocessor = require("application.framework.flow_text_preprocessor")

local module = {}

local function _trim(text)
    if type(text) ~= "string" then
        return ""
    end
    return text:match("^%s*(.-)%s*$")
end

local function _make_source(path, line, column)
    return
    {
        path = path,
        line = line,
        column = column or 1,
    }
end

local function _is_comment_or_empty(trimmed)
    return trimmed == ""
        or trimmed:match("^;")
        or trimmed:match("^//")
end

local function _split_top_level(text, separator)
    local result = {}
    local depth = 0
    local in_string = false
    local escape = false
    local start_index = 1
    local cursor = 1
    local separator_len = #separator

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
            elseif depth == 0 and text:sub(cursor, cursor + separator_len - 1) == separator then
                table.insert(result, text:sub(start_index, cursor - 1))
                cursor = cursor + separator_len
                start_index = cursor
            else
                cursor = cursor + 1
            end
        end
    end

    table.insert(result, text:sub(start_index))
    return result
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

local function _parse_simple_string(text)
    local trimmed = _trim(text)
    if not trimmed:match('^".*"$') then
        return nil
    end

    local token_list, diagnostic_list = Lexer.tokenize_expression(trimmed, 1, 1)
    if #diagnostic_list > 0 then
        return nil
    end
    if token_list[1] and token_list[1].kind == "string" then
        return token_list[1].value
    end
    return nil
end

local function _parse_value(text, line, column, allow_bare_text)
    local trimmed = _trim(text)
    if trimmed == "" then
        return nil, Diagnostics.error("missing_value", "缺少参数值", line, column)
    end

    local string_value = _parse_simple_string(trimmed)
    if string_value ~= nil then
        return {kind = "string", value = string_value, line = line, column = column}
    end

    if trimmed == "true" then
        return {kind = "bool", value = true, line = line, column = column}
    end
    if trimmed == "false" then
        return {kind = "bool", value = false, line = line, column = column}
    end
    if trimmed == "null" then
        return {kind = "null", value = nil, line = line, column = column}
    end

    if trimmed:match("^%-?%d+$") then
        return {kind = "number", value = tonumber(trimmed), number_kind = "int", line = line, column = column}
    end
    if trimmed:match("^%-?%d+%.%d+$") then
        return {kind = "number", value = tonumber(trimmed), number_kind = "float", line = line, column = column}
    end

    local color_hex = trimmed:match("^#([0-9A-Fa-f]+)$")
    if color_hex and (#color_hex == 6 or #color_hex == 8) then
        return {kind = "color", value = color_hex, line = line, column = column}
    end

    local asset_type = trimmed:match("^&([A-Za-z_][A-Za-z0-9_]*)%s*%(")
    if asset_type then
        local open_index = trimmed:find("(", 1, true)
        local close_index = open_index and _find_matching_paren(trimmed, open_index)
        if not open_index or not close_index or close_index ~= #trimmed then
            return nil, Diagnostics.error("invalid_asset_literal", "资源字面量必须写成 &type(\"locator\")", line, column)
        end

        local asset_locator = trimmed:sub(open_index + 1, close_index - 1)
        local locator_value = _parse_simple_string(asset_locator)
        if locator_value == nil then
            return nil, Diagnostics.error("invalid_asset_literal", "资源字面量必须写成 &type(\"locator\")", line, column)
        end
        return
        {
            kind = "asset",
            asset_type = asset_type,
            locator = locator_value,
            line = line,
            column = column,
        }
    end

    local legacy_asset_type = trimmed:match("^&([A-Za-z_][A-Za-z0-9_]*)%s*:%s*(.+)$")
    if legacy_asset_type then
        return nil, Diagnostics.error("invalid_asset_literal", "资源字面量必须写成 &type(\"locator\")", line, column)
    end

    local local_name = trimmed:match("^%$([A-Za-z_][A-Za-z0-9_%.]*)$")
    if local_name then
        return {kind = "variable", scope = "local", name = local_name, line = line, column = column}
    end

    local global_name = trimmed:match("^global%.([A-Za-z_][A-Za-z0-9_%.]*)$")
    if global_name then
        return {kind = "variable", scope = "global", name = global_name, line = line, column = column}
    end

    local temp_name = trimmed:match("^temp%.([A-Za-z_][A-Za-z0-9_%.]*)$")
    if temp_name then
        return {kind = "variable", scope = "temp", name = temp_name, line = line, column = column}
    end

    local label_name = LabelSyntax.parse_label_reference(trimmed)
    if label_name then
        return {kind = "label_ref", name = label_name, line = line, column = column}
    end

    local vector_body = trimmed:match("^%((.*)%)$")
    if vector_body then
        local parts = _split_top_level(vector_body, ",")
        if #parts ~= 2 then
            return nil, Diagnostics.error("invalid_vector2_literal", "Vector2 字面量应为 (x, y)", line, column)
        end
        local x_value, x_err = _parse_value(parts[1], line, column + 1, false)
        local y_value, y_err = _parse_value(parts[2], line, column + #parts[1] + 2, false)
        if x_err then
            return nil, x_err
        end
        if y_err then
            return nil, y_err
        end
        return
        {
            kind = "vector2",
            x = x_value,
            y = y_value,
            line = line,
            column = column,
        }
    end

    if allow_bare_text then
        return {kind = "string", value = trimmed, line = line, column = column}
    end

    return nil, Diagnostics.error("unsupported_value_literal", string.format("无法解析的值字面量：%s", trimmed), line, column)
end

local function _parse_expression(text, line, column)
    local token_list, diagnostic_list = Lexer.tokenize_expression(text, line, column)
    if #diagnostic_list > 0 then
        return nil, diagnostic_list[1]
    end

    local cursor = 1

    local function peek()
        return token_list[cursor]
    end

    local function consume(expected_kind, expected_value)
        local token = token_list[cursor]
        if not token then
            return nil
        end
        if expected_kind and token.kind ~= expected_kind then
            return nil
        end
        if expected_value ~= nil and token.value ~= expected_value then
            return nil
        end
        cursor = cursor + 1
        return token
    end

    local parse_expression_impl

    local function parse_primary()
        local token = peek()
        if not token or token.kind == "eof" then
            return nil, Diagnostics.error("missing_expression", "表达式不完整", line, column)
        end

        if token.kind == "op" and token.value == "(" then
            consume("op", "(")
            local expr, err = parse_expression_impl()
            if err then
                return nil, err
            end
            if not consume("op", ")") then
                return nil, Diagnostics.error("missing_right_paren", "表达式缺少右括号", token.line, token.column)
            end
            return expr
        end

        if token.kind == "variable" then
            consume("variable")
            return {kind = "variable", scope = "local", name = token.value, line = token.line, column = token.column}
        end
        if token.kind == "identifier" then
            consume("identifier")
            local global_name = tostring(token.value)
            local global_scope, global_path = global_name:match("^(global)%.(.+)$")
            if global_scope and global_path then
                return {kind = "variable", scope = global_scope, name = global_path, line = token.line, column = token.column}
            end
            local temp_scope, temp_path = global_name:match("^(temp)%.(.+)$")
            if temp_scope and temp_path then
                return {kind = "variable", scope = temp_scope, name = temp_path, line = token.line, column = token.column}
            end
            return nil, Diagnostics.error("invalid_expression_identifier", string.format("表达式中不支持裸标识符：%s", global_name), token.line, token.column)
        end
        if token.kind == "boolean" then
            consume("boolean")
            return {kind = "bool", value = token.value, line = token.line, column = token.column}
        end
        if token.kind == "null" then
            consume("null")
            return {kind = "null", value = nil, line = token.line, column = token.column}
        end
        if token.kind == "number" then
            consume("number")
            local text_value = tostring(token.value)
            return
            {
                kind = "number",
                value = tonumber(text_value),
                number_kind = text_value:find("%.") and "float" or "int",
                line = token.line,
                column = token.column,
            }
        end
        if token.kind == "string" then
            consume("string")
            return {kind = "string", value = token.value, line = token.line, column = token.column}
        end
        if token.kind == "label_ref" then
            consume("label_ref")
            return {kind = "label_ref", name = token.value, line = token.line, column = token.column}
        end

        return nil, Diagnostics.error("invalid_expression_primary", "无法解析的表达式主项", token.line, token.column)
    end

    local function parse_unary()
        local token = peek()
        if token and token.kind == "op" and token.value == "not" then
            consume("op", "not")
            local expr, err = parse_unary()
            if err then
                return nil, err
            end
            return {kind = "unary", op = "not", expr = expr, line = token.line, column = token.column}
        end
        return parse_primary()
    end

    local function parse_comparison()
        local left, err = parse_unary()
        if err then
            return nil, err
        end

        while true do
            local token = peek()
            if token and token.kind == "op"
                and (token.value == "==" or token.value == "!=" or token.value == ">" or token.value == "<" or token.value == ">=" or token.value == "<=")
            then
                consume("op")
                local right, right_err = parse_unary()
                if right_err then
                    return nil, right_err
                end
                left = {kind = "binary", op = token.value, left = left, right = right, line = token.line, column = token.column}
            else
                break
            end
        end

        return left
    end

    local function parse_and()
        local left, err = parse_comparison()
        if err then
            return nil, err
        end

        while true do
            local token = peek()
            if token and token.kind == "op" and token.value == "and" then
                consume("op", "and")
                local right, right_err = parse_comparison()
                if right_err then
                    return nil, right_err
                end
                left = {kind = "binary", op = "and", left = left, right = right, line = token.line, column = token.column}
            else
                break
            end
        end

        return left
    end

    parse_expression_impl = function()
        local left, err = parse_and()
        if err then
            return nil, err
        end

        while true do
            local token = peek()
            if token and token.kind == "op" and token.value == "or" then
                consume("op", "or")
                local right, right_err = parse_and()
                if right_err then
                    return nil, right_err
                end
                left = {kind = "binary", op = "or", left = left, right = right, line = token.line, column = token.column}
            else
                break
            end
        end

        return left
    end

    local expr, err = parse_expression_impl()
    if err then
        return nil, err
    end

    if peek() and peek().kind ~= "eof" then
        local token = peek()
        return nil, Diagnostics.error("unexpected_expression_tail", "表达式末尾存在无法解析的内容", token.line, token.column)
    end

    return expr
end

local function _parse_bindings(text, line_number, diagnostics)
    local bindings = {}
    local trimmed = _trim(text)
    if trimmed == "" then
        return bindings
    end

    if trimmed:match("^#") then
        bindings.default = {kind = "label", target = trimmed:sub(2)}
        return bindings
    end

    for _, part in ipairs(_split_top_level(trimmed, " ")) do
        local item = _trim(part)
        if item ~= "" then
            local colon_index = _find_top_level(item, ":")
            if not colon_index then
                table.insert(diagnostics,
                    Diagnostics.error("invalid_route_binding", string.format("无效的输出绑定：%s", item), line_number, 1))
            else
                local key = _trim(item:sub(1, colon_index - 1))
                local value_text = _trim(item:sub(colon_index + 1))
                if value_text:match("^#") then
                    bindings[key] = {kind = "label", target = value_text:sub(2)}
                else
                    local value, err = _parse_value(value_text, line_number, colon_index + 1, false)
                    if err then
                        table.insert(diagnostics, err)
                    elseif value.kind ~= "variable" then
                        table.insert(diagnostics,
                            Diagnostics.error("invalid_data_binding", "数据输出只能绑定到 $var / global.xxx / temp.xxx", line_number, colon_index + 1))
                    else
                        bindings[key] = {kind = "variable", target = value}
                    end
                end
            end
        end
    end

    return bindings
end

local function _parse_command_line(line_text, line_number, path, diagnostics)
    local trimmed = _trim(line_text)
    local name = trimmed:match("^@([A-Za-z_][A-Za-z0-9_]*)")
    if not name then
        table.insert(diagnostics, Diagnostics.error("invalid_command", "命令语法无效", line_number, 1))
        return nil
    end

    local name_end = 1 + #name
    local open_index = trimmed:find("(", name_end, true)
    if not open_index then
        table.insert(diagnostics, Diagnostics.error("missing_command_paren", "命令必须写成 @command(...)", line_number, 1))
        return nil
    end

    local close_index = _find_matching_paren(trimmed, open_index)
    if not close_index then
        table.insert(diagnostics, Diagnostics.error("missing_command_right_paren", "命令参数列表缺少右括号", line_number, 1))
        return nil
    end

    local args_text = trimmed:sub(open_index + 1, close_index - 1)
    local bindings_text = _trim(trimmed:sub(close_index + 1))
    local bindings = {}

    if bindings_text ~= "" then
        if not bindings_text:match("^%-%>") then
            table.insert(diagnostics,
                Diagnostics.error("invalid_command_tail", "命令参数后只能跟 -> 输出绑定子句", line_number, close_index + 1))
        else
            bindings = _parse_bindings(bindings_text:sub(3), line_number, diagnostics)
        end
    end

    local args = {positional = {}, named = {}}
    if _trim(args_text) ~= "" then
        for _, raw_part in ipairs(_split_top_level(args_text, ",")) do
            local part = _trim(raw_part)
            if part ~= "" then
                local colon_index = _find_top_level(part, ":")
                if colon_index then
                    local key = _trim(part:sub(1, colon_index - 1))
                    if not key:match("^[A-Za-z_][A-Za-z0-9_]*$") then
                        table.insert(diagnostics,
                            Diagnostics.error("invalid_named_argument", string.format("无效的具名参数：%s", key), line_number, 1))
                    else
                        local value, err = _parse_value(part:sub(colon_index + 1), line_number, colon_index + 1, false)
                        if err then
                            table.insert(diagnostics, err)
                        else
                            args.named[key] = value
                        end
                    end
                else
                    local value, err = _parse_value(part, line_number, 1, false)
                    if err then
                        table.insert(diagnostics, err)
                    else
                        table.insert(args.positional, value)
                    end
                end
            end
        end
    end

    return AST.invoke(name, args, bindings, _make_source(path, line_number, 1))
end

local function _parse_choice_option(line_text, line_number, diagnostics)
    local trimmed = _trim(line_text)
    local body = trimmed:match("^%-%s*(.+)$")
    if not body then
        table.insert(diagnostics, Diagnostics.error("invalid_choice_option", "@choice 块内只能使用 - option -> #label 形式的选项行", line_number, 1))
        return nil
    end

    local arrow_index = _find_top_level(body, "->")
    if not arrow_index then
        table.insert(diagnostics, Diagnostics.error("missing_choice_route", "选项必须写成 - 文本 -> #label", line_number, 1))
        return nil
    end

    local text_part = _trim(body:sub(1, arrow_index - 1))
    local target_part = _trim(body:sub(arrow_index + 2))
    local text_value, text_err = _parse_value(text_part, line_number, 1, true)
    if text_err then
        table.insert(diagnostics, text_err)
        return nil
    end

    local target = LabelSyntax.parse_label_reference(target_part)
    if not target then
        table.insert(diagnostics, Diagnostics.error("invalid_choice_target", "选项跳转目标必须是 #标签", line_number, arrow_index + 2))
        return nil
    end

    return
    {
        text = text_value,
        target = target,
        source = _make_source(nil, line_number, 1),
    }
end

local function _parse_document(source_text, path)
    local line_list = Lexer.split_lines(source_text)
    local preprocessor_result = Preprocessor.scan(line_list)
    local diagnostics = {}
    local statement_list = {}
    local label_list = {}
    local outline_items = {}
    local cursor = 1

    for _, item in ipairs(preprocessor_result.diagnostics or {}) do
        table.insert(diagnostics, item)
    end

    if preprocessor_result.outline and preprocessor_result.outline.title then
        table.insert(outline_items,
        {
            kind = "outline",
            name = preprocessor_result.outline.title,
            line = preprocessor_result.outline.line or 1,
            column = preprocessor_result.outline.column or 1,
        })
    end

    local parse_block

    local function parse_if_block(path_value, line)
        local condition_text = line.trimmed:match("^@if%s*%((.*)%)%s*$")
        if not condition_text then
            table.insert(diagnostics, Diagnostics.error("invalid_if_syntax", "@if 语法无效，应为 @if(expr)", line.number, 1))
            return AST.if_block({}, nil, _make_source(path_value, line.number, 1))
        end

        local branch_list = {}
        local expr, expr_err = _parse_expression(condition_text, line.number, 4)
        if expr_err then
            table.insert(diagnostics, expr_err)
        end

        local first_body, stop_kind = parse_block(path_value, {elif = true, else_ = true, end_ = true})
        table.insert(branch_list, {expr = expr, body = first_body, source = _make_source(path_value, line.number, 1)})

        while stop_kind == "elif" do
            local elif_line = line_list[cursor]
            local elif_condition = elif_line.trimmed:match("^@elif%s*%((.*)%)%s*$")
            if not elif_condition then
                table.insert(diagnostics, Diagnostics.error("invalid_elif_syntax", "@elif 语法无效，应为 @elif(expr)", elif_line.number, 1))
                elif_condition = "false"
            end
            cursor = cursor + 1
            local elif_expr, elif_err = _parse_expression(elif_condition, elif_line.number, 6)
            if elif_err then
                table.insert(diagnostics, elif_err)
            end
            local elif_body
            elif_body, stop_kind = parse_block(path_value, {elif = true, else_ = true, end_ = true})
            table.insert(branch_list, {expr = elif_expr, body = elif_body, source = _make_source(path_value, elif_line.number, 1)})
        end

        local else_body = nil
        if stop_kind == "else" then
            cursor = cursor + 1
            else_body, stop_kind = parse_block(path_value, {end_ = true})
        end

        if stop_kind == "end" then
            cursor = cursor + 1
        else
            table.insert(diagnostics, Diagnostics.error("missing_if_end", "@if 结构缺少 @end", line.number, 1))
        end

        return AST.if_block(branch_list, else_body, _make_source(path_value, line.number, 1))
    end

    local function parse_choice_block(path_value, invoke_node, line)
        local option_list = {}
        local found_end = false
        cursor = cursor + 1

        while cursor <= #line_list do
            local current = line_list[cursor]
            local trimmed = current.trimmed or ""
            if _is_comment_or_empty(trimmed) then
                cursor = cursor + 1
            elseif trimmed:match("^@end%s*$") then
                found_end = true
                cursor = cursor + 1
                break
            else
                local option = _parse_choice_option(current.text, current.number, diagnostics)
                if option then
                    table.insert(option_list, option)
                end
                cursor = cursor + 1
            end
        end

        if not found_end then
            table.insert(diagnostics, Diagnostics.error("missing_choice_end", "@choice 结构缺少 @end", line.number, 1))
        end

        return AST.choice(invoke_node.args.named.prompt, option_list, _make_source(path_value, line.number, 1))
    end

    parse_block = function(path_value, stop_pool)
        local block_statement_list = {}

        while cursor <= #line_list do
            local line = line_list[cursor]
            local trimmed = line.trimmed or ""

            if _is_comment_or_empty(trimmed) or trimmed:match("^@@") then
                cursor = cursor + 1
                goto continue
            end

            if trimmed:match("^#") then
                local label_name = LabelSyntax.parse_label_definition(trimmed)
                if not label_name then
                    table.insert(diagnostics, Diagnostics.error("invalid_label", "标签语法无效，应为 #标签名，支持中文、英文、数字与下划线组合", line.number, 1))
                else
                    table.insert(label_list, {name = label_name, line = line.number, column = 1})
                    table.insert(outline_items, {kind = "label", name = label_name, line = line.number, column = 1})
                    table.insert(block_statement_list, AST.label(label_name, _make_source(path_value, line.number, 1)))
                end
                cursor = cursor + 1
                goto continue
            end

            if stop_pool then
                if stop_pool.elif and trimmed:match("^@elif%s*%(") then
                    return block_statement_list, "elif"
                end
                if stop_pool.else_ and trimmed:match("^@else%s*$") then
                    return block_statement_list, "else"
                end
                if stop_pool.end_ and trimmed:match("^@end%s*$") then
                    return block_statement_list, "end"
                end
            end

            if trimmed:match("^@if%s*%(") then
                cursor = cursor + 1
                table.insert(block_statement_list, parse_if_block(path_value, line))
                goto continue
            end

            if trimmed:match("^@choice%s*%(") then
                local invoke_node = _parse_command_line(line.text, line.number, path_value, diagnostics)
                if invoke_node then
                    table.insert(block_statement_list, parse_choice_block(path_value, invoke_node, line))
                else
                    cursor = cursor + 1
                end
                goto continue
            end

            if trimmed:match("^@") then
                local command = _parse_command_line(line.text, line.number, path_value, diagnostics)
                if command then
                    table.insert(block_statement_list, command)
                end
                cursor = cursor + 1
                goto continue
            end

            local narrator_text = trimmed:match("^:%s*(.+)$")
            if narrator_text ~= nil then
                table.insert(block_statement_list, AST.dialogue("", narrator_text, _make_source(path_value, line.number, 1)))
                cursor = cursor + 1
                goto continue
            end

            local role_text, dialogue_text = line.text:match("^%s*(.-)%s*:%s*(.+)$")
            if role_text and dialogue_text then
                table.insert(block_statement_list, AST.dialogue(_trim(role_text), _trim(dialogue_text), _make_source(path_value, line.number, 1)))
                cursor = cursor + 1
                goto continue
            end

            table.insert(diagnostics, Diagnostics.error("unknown_statement", "无法识别的文本剧本语句", line.number, 1))
            cursor = cursor + 1

            ::continue::
        end

        return block_statement_list, nil
    end

    local body_statements = parse_block(path, nil)
    for _, statement in ipairs(body_statements or {}) do
        table.insert(statement_list, statement)
    end

    return
    {
        ast = statement_list,
        labels = label_list,
        outline_items = outline_items,
        aliases = preprocessor_result.aliases or {},
        imports = preprocessor_result.imports or {},
        outline = preprocessor_result.outline or nil,
        directives = preprocessor_result.directives or {},
        diagnostics = diagnostics,
        line_list = line_list,
    }
end

module.parse_document = _parse_document
module.parse_value = _parse_value
module.parse_expression = _parse_expression

return module
