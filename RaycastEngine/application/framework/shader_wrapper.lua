local rl = Engine.Raylib

local Class = require("application.framework.class")

local ShaderWrapper = Class.define("Shader")

local function _has_shader(self)
    return self._shader ~= nil
end

local function set(self, uniform, val, opt)
    if not _has_shader(self) then return end
    local pos = self._uniform_pool[uniform]
    if pos == nil then
        pos = rl.GetShaderLocation(self._shader, uniform)
        self._uniform_pool[uniform] = pos
    end
    if not pos or pos < 0 then return end
    opt = opt or "plain"
    if opt == "plain" then
        rl.SetShaderValue(self._shader, pos, val)
    elseif opt == "texture" then
        rl.SetShaderValueTexture(self._shader, pos, val)
    elseif opt == "matrix" then
        rl.SetShaderValueMatrix(self._shader, pos, val)
    end
end

local function set_on_ues(self, callback)
    self._on_use = callback
end

local function use(self)
    if not _has_shader(self) then return end
    rl.BeginShaderMode(self._shader)
    self._is_in_use = true
    if rawget(self, "_on_use") then self:_on_use() end
end

local function unuse(self)
    if not self._is_in_use then return end
    self._is_in_use = false
    rl.EndShaderMode()
end

function ShaderWrapper:ctor(path)
    self._uniform_pool = {}
    self._on_use = nil
    self._is_in_use = false
    self._is_empty = false

    if type(path) == "table" and path.empty == true then
        self._is_empty = true
        self._shader = nil
        return
    end

    if type(path) == "table" then
        self._shader = rl.LoadShaderFromMemory(path.vertex_source, path.fragment_source)
    else
        self._shader = rl.LoadShader(nil, path)
    end
end

ShaderWrapper.set = set
ShaderWrapper.use = use
ShaderWrapper.unuse = unuse
ShaderWrapper.set_on_ues = set_on_ues
ShaderWrapper.set_on_use = set_on_ues

function ShaderWrapper.empty()
    return ShaderWrapper.new({empty = true})
end

function ShaderWrapper:is_empty()
    return self._is_empty == true
end

function ShaderWrapper:is_valid()
    if self:is_empty() then
        return true
    end
    return self._shader ~= nil and rl.IsShaderValid(self._shader) == true
end

function ShaderWrapper:dispose()
    if self._is_in_use then
        rl.EndShaderMode()
        self._is_in_use = false
    end
    if self._shader then
        rl.UnloadShader(self._shader)
        self._shader = nil
    end
end

ShaderWrapper.__gc = ShaderWrapper.dispose

return ShaderWrapper
