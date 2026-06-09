local VideoPlaybackSession = require("application.framework.video_playback_session")

local module = {}

local active_session_list = {}

local function _remove_session(target)
    for index = #active_session_list, 1, -1 do
        if active_session_list[index] == target then
            table.remove(active_session_list, index)
            return
        end
    end
end

module.create_session = function(video_asset, options)
    local session = VideoPlaybackSession.new(video_asset, options)
    if not session then
        return nil, "创建视频播放会话失败"
    end
    if session.error_message then
        if session.close then
            session:close()
        end
        return nil, session.error_message
    end
    table.insert(active_session_list, session)
    return session
end

module.release_session = function(session)
    if not session then
        return
    end
    _remove_session(session)
    if session.close then
        session:close()
    end
end

module.update = function(delta)
    for index = #active_session_list, 1, -1 do
        local session = active_session_list[index]
        if not session or session.is_closed then
            table.remove(active_session_list, index)
        elseif session.tick then
            session:tick(delta)
            if session.is_closed then
                table.remove(active_session_list, index)
            end
        end
    end
end

module.shutdown_all = function()
    for index = #active_session_list, 1, -1 do
        local session = active_session_list[index]
        if session and session.close then
            session:close()
        end
        active_session_list[index] = nil
    end
end

return module
