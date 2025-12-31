local module = {}

local rl = Engine.Raylib

local function set(self, uniform, val, opt)
    local pos = self._uniform_pool[uniform]
    if not pos then
        pos = rl.GetShaderLocation(self._shader, uniform)
        self._uniform_pool[uniform] = pos
    end
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
    rl.BeginShaderMode(self._shader)
    if rawget(self, "_on_use") then self:_on_use() end
end

local function unuse(self)
    rl.EndShaderMode()
end

module.new = function(path)
    local o = 
    {
        _metaname = "Shader",

        _shader = rl.LoadShader(nil, path),
        _uniform_pool = {},
        _on_use = nil,

        set = set,
        use = use,
        unuse = unuse,
        set_on_ues = set_on_ues,

        __gc = function(self)
            rl.UnloadShader(self._shader)
        end
    }
    setmetatable(o, o)
    o.__index = o
    return o
end

return module