local Video = Engine.Video

local module = {}

local backend_pool = {}
local default_backend_id = "wmf"

local function _clone_table(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

module.register = function(id, backend)
    if type(id) ~= "string" or id == "" or type(backend) ~= "table" then
        return
    end
    backend.id = backend.id or id
    backend_pool[id] = backend
end

module.find = function(id)
    return backend_pool[id]
end

module.get_default = function()
    return backend_pool[default_backend_id]
end

module.is_supported = function(id)
    local backend = module.find(id or default_backend_id)
    if not backend then
        return false
    end
    return backend.is_supported and backend.is_supported() or false
end

module.get_capability_message = function(id)
    local backend = module.find(id or default_backend_id)
    if not backend then
        return "未注册的视频后端"
    end
    if backend.get_capability_message then
        return backend.get_capability_message()
    end
    return ""
end

module.create_session_handle = function(path_utf8, options)
    local backend = module.find(options and options.backend_id or default_backend_id)
    if not backend or not backend.create_session_handle then
        return nil, "未找到可用的视频后端"
    end
    return backend.create_session_handle(path_utf8, options)
end

module.list_backend = function()
    local result = {}
    for id, backend in pairs(backend_pool) do
        result[id] = _clone_table(backend)
    end
    return result
end

module.register(default_backend_id,
{
    id = default_backend_id,
    display_name = "Windows Media Foundation",
    is_supported = function()
        return Video.IsSupported()
    end,
    get_capability_message = function()
        return Video.GetCapabilityMessage()
    end,
    create_session_handle = function(path_utf8)
        local handle = Video.CreateSession(path_utf8)
        if not handle or not handle.IsValid or not handle:IsValid() then
            local message = Video.GetCapabilityMessage()
            if handle and handle.GetErrorMessage then
                local error_message = handle:GetErrorMessage()
                if error_message and error_message ~= "" then
                    message = error_message
                end
            end
            return nil, message ~= "" and message or "创建 WMF 视频会话失败"
        end
        if handle.HasError and handle:HasError() then
            local error_message = handle.GetErrorMessage and handle:GetErrorMessage() or nil
            handle:Close()
            return nil, error_message ~= nil and error_message ~= "" and error_message or "创建 WMF 视频会话失败"
        end
        return handle
    end,
})

return module
