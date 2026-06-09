local Class = require("application.framework.class")

local VideoAsset = Class.define("VideoAsset")

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = _clone_value(item)
    end
    return copy
end

function VideoAsset:ctor(meta)
    self:refresh(meta)
end

function VideoAsset:refresh(meta)
    meta = meta or {}
    self.guid = meta.guid
    self.type = meta.type
    self.path = meta.path
    self.relative_path = meta.relative_path
    self.display_name = meta.display_name
    self.ext = meta.ext
    self.file_signature = _clone_value(meta.file_signature)
    self.importer = _clone_value(meta.importer or {})
    self.import_status = _clone_value(self.importer.video or {})
end

function VideoAsset:get_runtime_entry()
    return _clone_value(self.import_status.runtime_entry)
end

function VideoAsset:get_runtime_path()
    local runtime_entry = self.import_status.runtime_entry or {}
    if runtime_entry.path and runtime_entry.path ~= "" then
        return runtime_entry.path
    end
    return self.path
end

function VideoAsset:get_transcode_artifact_path()
    local artifact = self.import_status.transcode_artifact or {}
    return artifact.path
end

function VideoAsset:get_import_status()
    return _clone_value(self.import_status)
end

function VideoAsset:is_runtime_ready()
    local runtime_entry = self.import_status.runtime_entry or {}
    if runtime_entry.mode == "artifact" then
        local artifact = self.import_status.transcode_artifact or {}
        return artifact.exists == true and runtime_entry.path ~= nil and runtime_entry.path ~= ""
    end
    return runtime_entry.path ~= nil and runtime_entry.path ~= ""
end

function VideoAsset:dispose()
end

VideoAsset.__gc = VideoAsset.dispose

return VideoAsset
