local TableUtil = require("application.framework.table_util")

local module = {}

local clipboard_payload = nil
local clipboard_revision = 0

module.clear = function()
    clipboard_payload = nil
end

module.write = function(payload)
    if type(payload) ~= "table" then
        return false
    end

    clipboard_payload = TableUtil.deep_copy(payload)
    clipboard_revision = clipboard_revision + 1
    return true, clipboard_revision
end

module.read = function()
    if type(clipboard_payload) ~= "table" then
        return nil, clipboard_revision
    end

    return TableUtil.deep_copy(clipboard_payload), clipboard_revision
end

module.peek_revision = function()
    return clipboard_revision
end

module.has_payload = function()
    return type(clipboard_payload) == "table"
end

return module
