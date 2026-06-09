local module = {}

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

module.copy_table = _copy_table

module.new_command_doc = function()
    return
    {
        brief = "",
        description = "",
        usage = {},
        notes = {},
        examples = {},
        outputs = {},
        see_also = {},
        status =
        {
            deprecated = nil,
            experimental = nil,
        },
    }
end

module.new_param_doc = function()
    return
    {
        brief = "",
        description = "",
        default = "",
        value_hint = "",
        examples = {},
    }
end

module.new_note = function(kind, text)
    return
    {
        kind = kind or "note",
        text = tostring(text or ""),
    }
end

module.new_example = function(item)
    local source = type(item) == "table" and item or {}
    return
    {
        title = tostring(source.title or ""),
        language = tostring(source.language or source.lang or ""),
        code = tostring(source.code or source.text or ""),
    }
end

module.new_link = function(kind, target, label)
    return
    {
        kind = tostring(kind or ""),
        target = tostring(target or ""),
        label = label ~= nil and tostring(label) or nil,
    }
end

return module
