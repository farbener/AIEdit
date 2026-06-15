-- Settings.lua
-- Persists the chosen AI provider, per-provider API keys, and last-used dialog
-- values using LrPrefs (per-plugin, stored by Lightroom on the local machine —
-- API keys never leave it).
--
-- PUBLIC API
--   Settings.getProvider() / Settings.setProvider(id)   -- "anthropic" | "openai"
--   Settings.getApiKey(provider) / Settings.setApiKey(provider, key)
--   Settings.getLast()  → { style, strength, feedback, preview }
--   Settings.setLast(style, strength, feedback, preview)

local LrPrefs = import "LrPrefs"

local Settings = {}
local prefs    = LrPrefs.prefsForPlugin()

local DEFAULT_PROVIDER = "anthropic"

-- Which provider to use. Defaults to Anthropic.
function Settings.getProvider()
    return prefs.provider or DEFAULT_PROVIDER
end

function Settings.setProvider(id)
    prefs.provider = id or DEFAULT_PROVIDER
end

-- API keys are stored per provider (prefs.apiKey_anthropic, prefs.apiKey_openai)
-- so switching providers never clobbers the other key.
--   provider : "anthropic" | "openai" (defaults to the current provider)
function Settings.getApiKey(provider)
    provider = provider or Settings.getProvider()
    local key = prefs["apiKey_" .. provider]
    -- Migration: older builds stored a single Anthropic key in prefs.apiKey.
    if (not key or key == "") and provider == "anthropic" and prefs.apiKey then
        key = prefs.apiKey
    end
    return key or ""
end

function Settings.setApiKey(provider, key)
    provider = provider or Settings.getProvider()
    prefs["apiKey_" .. provider] = key or ""
end

-- Last-used dialog values (so the dialog reopens with your previous settings)
function Settings.getLast()
    return {
        style    = prefs.lastStyle or "",
        strength = prefs.lastStrength or 100,
        feedback = (prefs.lastFeedback == nil) and false or prefs.lastFeedback,
        preview  = (prefs.lastPreview == nil) and false or prefs.lastPreview,
    }
end

function Settings.setLast(style, strength, feedback, preview)
    prefs.lastStyle    = style or ""
    prefs.lastStrength = strength or 100
    prefs.lastFeedback = feedback and true or false
    prefs.lastPreview  = preview and true or false
end

return Settings
