local module = {}

local function _node(kind, payload)
    local result = {kind = kind}
    for key, value in pairs(payload or {}) do
        result[key] = value
    end
    return result
end

module.label = function(name, source)
    return _node("label", {name = name, source = source})
end

module.invoke = function(command, args, bindings, source)
    return _node("invoke",
    {
        command = command,
        args = args or {positional = {}, named = {}},
        bindings = bindings or {},
        source = source,
    })
end

module.dialogue = function(role, text, source)
    return _node("dialogue",
    {
        role = role,
        text = text,
        source = source,
    })
end

module.choice = function(prompt, option_list, source)
    return _node("choice",
    {
        prompt = prompt,
        options = option_list or {},
        source = source,
    })
end

module.if_block = function(branch_list, else_body, source)
    return _node("if",
    {
        branches = branch_list or {},
        else_body = else_body,
        source = source,
    })
end

return module
