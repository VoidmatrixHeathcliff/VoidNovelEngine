local module = {}

local function _rename_pin_list(pin_list, name_by_key, name_by_old_name)
    if type(pin_list) ~= "table" or type(name_by_key) ~= "table" then
        return
    end

    for _, pin in ipairs(pin_list) do
        if type(pin) == "table" then
            local name = name_by_key[pin.key]
                or (type(name_by_old_name) == "table" and name_by_old_name[pin.name] or nil)
            if name then
                pin.name = name
            end
        end
    end
end

module.rename = function(data, config)
    if type(data) ~= "table" then
        return data
    end

    config = type(config) == "table" and config or {}
    _rename_pin_list(data.input_pin_list, config.input, config.input_legacy)
    _rename_pin_list(data.output_pin_list, config.output, config.output_legacy)
    return data
end

return module
