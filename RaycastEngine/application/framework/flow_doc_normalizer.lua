local FlowDocModel = require("application.framework.flow_doc_model")

local module = {}

local function _copy_table(value)
    return FlowDocModel.copy_table(value)
end

local function _normalize_string(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function _normalize_string_list(value)
    local result = {}
    if type(value) ~= "table" then
        return result
    end

    for _, item in ipairs(value) do
        local text = _normalize_string(item)
        if text ~= "" then
            result[#result + 1] = text
        end
    end
    return result
end

local function _normalize_status(value)
    local status =
    {
        deprecated = nil,
        experimental = nil,
    }
    if type(value) ~= "table" then
        return status
    end

    if value.deprecated ~= nil then
        status.deprecated = _normalize_string(value.deprecated)
        if status.deprecated == "" then
            status.deprecated = false
        end
    end
    if value.experimental ~= nil then
        status.experimental = _normalize_string(value.experimental)
        if status.experimental == "" then
            status.experimental = false
        end
    end
    return status
end

local function _normalize_notes(value)
    local result = {}
    if type(value) ~= "table" then
        return result
    end

    for _, item in ipairs(value) do
        if type(item) == "table" then
            local note = FlowDocModel.new_note(item.kind, item.text or item.message)
            if note.text ~= "" then
                result[#result + 1] = note
            end
        elseif item ~= nil then
            local note = FlowDocModel.new_note("note", item)
            if note.text ~= "" then
                result[#result + 1] = note
            end
        end
    end
    return result
end

local function _normalize_examples(value)
    local result = {}
    if type(value) ~= "table" then
        return result
    end

    for _, item in ipairs(value) do
        if type(item) == "table" then
            local example = FlowDocModel.new_example(item)
            if example.code ~= "" then
                result[#result + 1] = example
            end
        elseif item ~= nil then
            local example = FlowDocModel.new_example({code = item})
            if example.code ~= "" then
                result[#result + 1] = example
            end
        end
    end
    return result
end

local function _normalize_outputs(value)
    local result = {}
    if type(value) ~= "table" then
        return result
    end

    for _, item in ipairs(value) do
        if type(item) == "table" then
            local output =
            {
                pin = _normalize_string(item.pin),
                brief = _normalize_string(item.brief or item.description),
            }
            if output.pin ~= "" or output.brief ~= "" then
                result[#result + 1] = output
            end
        end
    end
    return result
end

local function _normalize_links(value)
    local result = {}
    if type(value) ~= "table" then
        return result
    end

    for _, item in ipairs(value) do
        if type(item) == "table" then
            local link = FlowDocModel.new_link(item.kind, item.target, item.label)
            if link.kind ~= "" and link.target ~= "" then
                result[#result + 1] = link
            end
        end
    end
    return result
end

module.normalize_param_doc = function(value, fallback)
    local result = FlowDocModel.new_param_doc()
    local source = nil
    if type(value) == "table" then
        source = value
    elseif value ~= nil then
        source = {brief = value}
    else
        source = {}
    end
    local fallback_table = type(fallback) == "table" and fallback or {}

    result.brief = _normalize_string(source.brief ~= nil and source.brief or fallback_table.brief)
    result.description = _normalize_string(source.description ~= nil and source.description or fallback_table.description)
    result.default = _normalize_string(source.default ~= nil and source.default or fallback_table.default)
    result.value_hint = _normalize_string(source.value_hint ~= nil and source.value_hint or fallback_table.value_hint)
    result.examples = _normalize_examples(source.examples ~= nil and source.examples or fallback_table.examples)
    return result
end

module.normalize_command_doc = function(script_meta, fallback)
    local result = FlowDocModel.new_command_doc()
    local script = type(script_meta) == "table" and script_meta or {}
    local source = type(script.docs) == "table" and script.docs or {}
    local fallback_table = type(fallback) == "table" and fallback or {}

    result.brief = _normalize_string(source.brief ~= nil and source.brief or script.summary or fallback_table.brief)
    result.description = _normalize_string(source.description ~= nil and source.description or script.detail or fallback_table.description)
    result.usage = _normalize_string_list(source.usage ~= nil and source.usage or fallback_table.usage)
    result.notes = _normalize_notes(source.notes ~= nil and source.notes or fallback_table.notes)
    result.examples = _normalize_examples(source.examples ~= nil and source.examples or fallback_table.examples)
    result.outputs = _normalize_outputs(source.outputs ~= nil and source.outputs or fallback_table.outputs)
    result.see_also = _normalize_links(source.see_also ~= nil and source.see_also or fallback_table.see_also)
    result.status = _normalize_status(source.status ~= nil and source.status or fallback_table.status)
    return result
end

module.normalize_signature_item = function(item, index)
    if type(item) ~= "table" then
        item = {name = tostring(item), pin = item}
    else
        item = _copy_table(item)
    end

    item.name = item.name or item.key or item.pin or tostring(index)
    item.pin = item.pin or item.key or item.name or index
    item.aliases = type(item.aliases) == "table" and _copy_table(item.aliases) or {}
    item.doc = module.normalize_param_doc(item.doc)
    return item
end

module.normalize_script_meta = function(script_meta, type_id)
    if type(script_meta) ~= "table" then
        return nil
    end

    local script = _copy_table(script_meta)
    script.command = type(script.command) == "string" and script.command or type_id
    script.aliases = type(script.aliases) == "table" and _copy_table(script.aliases) or {}
    script.signature = type(script.signature) == "table" and _copy_table(script.signature) or {}
    if script.expose == nil then
        script.expose = true
    end

    for index, item in ipairs(script.signature) do
        script.signature[index] = module.normalize_signature_item(item, index)
    end

    script.docs = module.normalize_command_doc(script)
    if script.summary == nil then
        script.summary = script.docs.brief
    end
    if script.detail == nil then
        script.detail = script.docs.description
    end

    return script
end

return module
