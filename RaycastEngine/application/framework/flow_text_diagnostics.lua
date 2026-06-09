local module = {}

local function _new(severity, code, message, line, column, extra)
    local diagnostic =
    {
        severity = severity or "error",
        code = code or "text_script_error",
        message = message or "文本剧本错误",
        line = tonumber(line) or 1,
        column = tonumber(column) or 1,
    }

    if type(extra) == "table" then
        for key, value in pairs(extra) do
            diagnostic[key] = value
        end
    end

    return diagnostic
end

module.new = _new

module.error = function(code, message, line, column, extra)
    return _new("error", code, message, line, column, extra)
end

module.warning = function(code, message, line, column, extra)
    return _new("warning", code, message, line, column, extra)
end

module.info = function(code, message, line, column, extra)
    return _new("info", code, message, line, column, extra)
end

module.has_errors = function(diagnostic_list)
    for _, diagnostic in ipairs(diagnostic_list or {}) do
        if diagnostic.severity == "error" then
            return true
        end
    end
    return false
end

module.sort = function(diagnostic_list)
    table.sort(diagnostic_list, function(left, right)
        if (left.line or 0) ~= (right.line or 0) then
            return (left.line or 0) < (right.line or 0)
        end
        if (left.column or 0) ~= (right.column or 0) then
            return (left.column or 0) < (right.column or 0)
        end
        return tostring(left.message or "") < tostring(right.message or "")
    end)
    return diagnostic_list
end

return module
