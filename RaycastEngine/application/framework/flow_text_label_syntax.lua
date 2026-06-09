local module = {}

local CJK_LABEL_RANGE_LIST <const> =
{
    {0x3007, 0x3007},
    {0x3400, 0x4DBF},
    {0x4E00, 0x9FFF},
    {0xF900, 0xFAFF},
    {0x20000, 0x2A6DF},
    {0x2A700, 0x2B73F},
    {0x2B740, 0x2B81F},
    {0x2B820, 0x2CEAF},
    {0x2CEB0, 0x2EBEF},
    {0x30000, 0x3134F},
    {0x31350, 0x323AF},
}

local function _is_ascii_letter(codepoint)
    return (codepoint >= 65 and codepoint <= 90) or (codepoint >= 97 and codepoint <= 122)
end

local function _is_ascii_digit(codepoint)
    return codepoint >= 48 and codepoint <= 57
end

local function _is_cjk_label_codepoint(codepoint)
    for _, range in ipairs(CJK_LABEL_RANGE_LIST) do
        if codepoint >= range[1] and codepoint <= range[2] then
            return true
        end
    end
    return false
end

local function _is_label_start_codepoint(codepoint)
    return _is_ascii_letter(codepoint) or codepoint == 95 or _is_cjk_label_codepoint(codepoint)
end

local function _is_label_part_codepoint(codepoint)
    return _is_label_start_codepoint(codepoint) or _is_ascii_digit(codepoint)
end

local function _decode_utf8_codepoint(text, index)
    local byte_1 = text:byte(index)
    if not byte_1 then
        return nil, nil
    end

    if byte_1 < 0x80 then
        return byte_1, index + 1
    end

    local byte_2 = text:byte(index + 1)
    if byte_1 < 0xC2 or not byte_2 or byte_2 < 0x80 or byte_2 > 0xBF then
        return nil, nil
    end

    if byte_1 < 0xE0 then
        return (byte_1 - 0xC0) * 0x40 + (byte_2 - 0x80), index + 2
    end

    local byte_3 = text:byte(index + 2)
    if not byte_3 or byte_3 < 0x80 or byte_3 > 0xBF then
        return nil, nil
    end

    if byte_1 == 0xE0 and byte_2 < 0xA0 then
        return nil, nil
    end
    if byte_1 == 0xED and byte_2 >= 0xA0 then
        return nil, nil
    end
    if byte_1 < 0xF0 then
        return (byte_1 - 0xE0) * 0x1000 + (byte_2 - 0x80) * 0x40 + (byte_3 - 0x80), index + 3
    end

    local byte_4 = text:byte(index + 3)
    if byte_1 > 0xF4 or not byte_4 or byte_4 < 0x80 or byte_4 > 0xBF then
        return nil, nil
    end
    if byte_1 == 0xF0 and byte_2 < 0x90 then
        return nil, nil
    end
    if byte_1 == 0xF4 and byte_2 > 0x8F then
        return nil, nil
    end

    return
        (byte_1 - 0xF0) * 0x40000
        + (byte_2 - 0x80) * 0x1000
        + (byte_3 - 0x80) * 0x40
        + (byte_4 - 0x80),
        index + 4
end

local function _validate_label_name(text, allow_empty)
    local normalized_text = tostring(text or "")
    if normalized_text == "" then
        return allow_empty == true
    end

    local is_first = true
    local found = false
    local cursor = 1
    while cursor <= #normalized_text do
        local codepoint, next_cursor = _decode_utf8_codepoint(normalized_text, cursor)
        if not codepoint then
            return false
        end

        local valid = is_first and _is_label_start_codepoint(codepoint) or _is_label_part_codepoint(codepoint)
        if not valid then
            return false
        end
        is_first = false
        found = true
        cursor = next_cursor
    end

    return found or allow_empty == true
end

module.is_valid_label_name = function(text)
    return _validate_label_name(text, false)
end

module.is_valid_label_prefix = function(text)
    return _validate_label_name(text, true)
end

module.scan_label_name = function(text, start_byte)
    local normalized_text = tostring(text or "")
    local start_cursor = math.max(1, math.floor(tonumber(start_byte) or 1))
    local cursor = start_cursor
    if cursor > #normalized_text then
        return nil, cursor
    end

    local found = false
    local is_first = true
    local end_byte = cursor
    while cursor <= #normalized_text do
        local codepoint, next_cursor = _decode_utf8_codepoint(normalized_text, cursor)
        if not codepoint then
            break
        end

        local valid = is_first and _is_label_start_codepoint(codepoint) or _is_label_part_codepoint(codepoint)
        if not valid then
            break
        end

        end_byte = next_cursor
        is_first = false
        found = true
        cursor = next_cursor
    end

    if not found then
        return nil, start_cursor
    end

    return normalized_text:sub(start_cursor, end_byte - 1), end_byte
end

module.parse_label_reference = function(text)
    local normalized_text = tostring(text or "")
    if normalized_text:sub(1, 1) ~= "#" then
        return nil
    end

    local label_name, end_byte = module.scan_label_name(normalized_text, 2)
    if not label_name or end_byte <= #normalized_text then
        return nil
    end
    return label_name
end

module.parse_label_definition = function(text)
    local normalized_text = tostring(text or "")
    if normalized_text:sub(1, 1) ~= "#" then
        return nil
    end

    local cursor = 2
    while cursor <= #normalized_text and normalized_text:sub(cursor, cursor):match("%s") do
        cursor = cursor + 1
    end

    local label_name, end_byte = module.scan_label_name(normalized_text, cursor)
    if not label_name then
        return nil
    end

    if normalized_text:sub(end_byte):match("^%s*$") then
        return label_name
    end
    return nil
end

return module
