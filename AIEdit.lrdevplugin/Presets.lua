-- Presets.lua
-- Stores named recipes (style text + strength + feedback flag) in plugin prefs,
-- serialised as a single JSON string under prefs.presetsJson.
--
-- PUBLIC API
--   Presets.names()                          → sorted array of preset names
--   Presets.get(name)                        → { style, strength, feedback } | nil
--   Presets.set(name, style, strength, feedback)  (overwrites if name exists)
--   Presets.delete(name)

local LrPrefs = import "LrPrefs"
local json    = require "dkjson"

local Presets = {}
local prefs   = LrPrefs.prefsForPlugin()

-- Internal: load the presets table from prefs (JSON string).
local function load()
    local raw = prefs.presetsJson
    if not raw or raw == "" then return {} end
    local t = json.decode(raw)
    return (type(t) == "table") and t or {}
end

local function save(t)
    prefs.presetsJson = json.encode(t)
end

-- Returns an array of preset names (sorted).
function Presets.names()
    local t = load()
    local names = {}
    for name, _ in pairs(t) do names[#names + 1] = name end
    table.sort(names)
    return names
end

-- Returns a preset table { style=, strength=, feedback= } or nil.
function Presets.get(name)
    return load()[name]
end

-- Save/overwrite a preset.
function Presets.set(name, style, strength, feedback)
    local t = load()
    t[name] = { style = style or "", strength = strength or 100, feedback = feedback and true or false }
    save(t)
end

-- Delete a preset.
function Presets.delete(name)
    local t = load()
    t[name] = nil
    save(t)
end

return Presets
