local Diagnostics = require("application.framework.flow_text_diagnostics")

local module = {}

local function _is_comment_or_empty(trimmed)
    return trimmed == ""
        or trimmed:match("^;")
        or trimmed:match("^//")
end

local function _parse_alias_directive(trimmed, line_number)
    local name, target = trimmed:match("^@@alias%s*%(%s*([A-Za-z_][A-Za-z0-9_]*)%s*=%s*([A-Za-z_][A-Za-z0-9_]*)%s*%)%s*$")
    if not name or not target then
        return nil, Diagnostics.error("invalid_alias_directive", "@@alias 语法无效，应写成 @@alias(short = target)", line_number, 1)
    end

    return
    {
        kind = "alias",
        name = name,
        target = target,
        line = line_number,
        column = 1,
    }
end

local function _parse_import_directive(trimmed, line_number)
    local locator = trimmed:match('^@@import%s*%(%s*"(.-)"%s*%)%s*$')
    if locator and locator ~= "" then
        return
        {
            kind = "import",
            locator = locator,
            line = line_number,
            column = 1,
        }
    end

    local key, value = trimmed:match('^@@import%s*%(%s*([A-Za-z_][A-Za-z0-9_]*)%s*=%s*"(.-)"%s*%)%s*$')
    if key and value and value ~= "" and (key == "target" or key == "path" or key == "file") then
        return
        {
            kind = "import",
            locator = value,
            line = line_number,
            column = 1,
        }
    end

    return nil, Diagnostics.error("invalid_import_directive", "@@import 语法无效，应写成 @@import(\"flow_id\")", line_number, 1)
end

local function _parse_outline_directive(trimmed, line_number)
    local title = trimmed:match('^@@outline%s*%(%s*"(.-)"%s*%)%s*$')
    if title and title ~= "" then
        return
        {
            kind = "outline",
            title = title,
            line = line_number,
            column = 1,
        }
    end

    local key, value = trimmed:match('^@@outline%s*%(%s*([A-Za-z_][A-Za-z0-9_]*)%s*=%s*"(.-)"%s*%)%s*$')
    if key and value and value ~= "" and (key == "title" or key == "name") then
        return
        {
            kind = "outline",
            title = value,
            line = line_number,
            column = 1,
        }
    end

    return nil, Diagnostics.error("invalid_outline_directive", "@@outline 语法无效，应写成 @@outline(\"title\")", line_number, 1)
end

local function _parse_directive(trimmed, line_number)
    if trimmed:match("^@@alias") then
        return _parse_alias_directive(trimmed, line_number)
    end
    if trimmed:match("^@@import") then
        return _parse_import_directive(trimmed, line_number)
    end
    if trimmed:match("^@@outline") then
        return _parse_outline_directive(trimmed, line_number)
    end

    return nil, Diagnostics.error("unknown_meta_directive", "未知的编译期指令", line_number, 1)
end

module.scan = function(line_list)
    local aliases = {}
    local imports = {}
    local directives = {}
    local diagnostics = {}
    local outline = nil
    local in_preamble = true

    for _, line in ipairs(line_list or {}) do
        local trimmed = line.trimmed or ""
        if _is_comment_or_empty(trimmed) then
            goto continue
        end

        if trimmed:match("^@@") then
            if not in_preamble then
                table.insert(diagnostics,
                    Diagnostics.error("meta_directive_after_body", "编译期指令必须写在文件开头区域", line.number, 1))
                goto continue
            end

            local directive, err = _parse_directive(trimmed, line.number)
            if err then
                table.insert(diagnostics, err)
            elseif directive then
                if directive.kind == "alias" then
                    aliases[directive.name] = directive.target
                elseif directive.kind == "import" then
                    table.insert(imports, directive)
                elseif directive.kind == "outline" then
                    outline = directive
                end
                table.insert(directives, directive)
            end
        else
            in_preamble = false
        end

        ::continue::
    end

    return
    {
        aliases = aliases,
        imports = imports,
        outline = outline,
        directives = directives,
        diagnostics = diagnostics,
    }
end

return module
