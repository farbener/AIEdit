--[[============================================================================
  AIEditRevert.lua  —  ENTRY POINT for "AI Edit: Revert to Original"

  Restores each selected photo to the state it was in BEFORE its first AI edit,
  by re-applying the snapshot that AIEditDialog.applyEdits saved into the
  per-photo "preEditSettings" metadata.

  WHY SNAPSHOT RESTORE (and NOT an empty-table "reset")
    The obvious approach — photo:applyDevelopSettings({}, name, true), trusting
    the reset=true flag to clear everything — DOES NOT WORK: applying an EMPTY
    settings table is a no-op in the SDK, so the photo keeps its edits (the call
    logs success but nothing changes). Applying a NON-EMPTY settings table DOES
    work, so we restore the saved pre-edit settings as a full table. This is the
    same proven mechanism the in-dialog preview-revert uses.

  IF NO SNAPSHOT EXISTS
    A photo never AI-edited (or whose snapshot was cleared) has nothing to
    restore; we report that and leave it untouched. Use Lightroom's own
    Develop → Reset for a hard reset in that case.

  PUBLIC SURFACE
    None — this is a menu script. Runs top-to-bottom when invoked.
============================================================================]]

local LrApplication     = import "LrApplication"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrProgressScope   = import "LrProgressScope"

local json = require "dkjson"
local Log  = require "Log"

-- The develop keys the plugin can change — and therefore the ONLY keys revert
-- needs to restore. MUST stay in sync with SETTING_MAP's target values in
-- AIEditDialog.lua. We restore just these (not the whole getDevelopSettings blob)
-- because that blob includes string-encoded mask/retouch data which makes
-- applyDevelopSettings throw "Assertion failed: packed". The AI never touches
-- anything outside this list, so restoring only these is complete.
local RESET_KEYS = {
    "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012",
    "Whites2012", "Blacks2012", "Clarity2012", "Texture", "Dehaze",
    "Vibrance", "Saturation", "Temperature", "Tint",
    "HueAdjustmentRed", "HueAdjustmentOrange", "HueAdjustmentYellow",
    "HueAdjustmentGreen", "HueAdjustmentAqua", "HueAdjustmentBlue",
    "HueAdjustmentPurple", "HueAdjustmentMagenta",
    "SaturationAdjustmentRed", "SaturationAdjustmentOrange", "SaturationAdjustmentYellow",
    "SaturationAdjustmentGreen", "SaturationAdjustmentAqua", "SaturationAdjustmentBlue",
    "SaturationAdjustmentPurple", "SaturationAdjustmentMagenta",
    "LuminanceAdjustmentRed", "LuminanceAdjustmentOrange", "LuminanceAdjustmentYellow",
    "LuminanceAdjustmentGreen", "LuminanceAdjustmentAqua", "LuminanceAdjustmentBlue",
    "LuminanceAdjustmentPurple", "LuminanceAdjustmentMagenta",
    "PostCropVignetteAmount", "GrainAmount", "Sharpness", "LuminanceSmoothing",
}

Log.write("AIEditRevert: loaded")

LrFunctionContext.postAsyncTaskWithContext("AIEditRevert", function(context)
    LrDialogs.attachErrorDialogToFunctionContext(context)

    local catalog = LrApplication.activeCatalog()
    local photos  = catalog:getTargetPhotos()

    if not photos or #photos == 0 then
        LrDialogs.message("AI Edit — Revert", "No photo selected.", "warning")
        return
    end

    local total = #photos
    Log.write("AIEditRevert: " .. total .. " photo(s)")

    local progress = LrProgressScope({ title = "AI Edit — Revert" })

    local restored, noSnapshot = 0, 0

    catalog:withWriteAccessDo("AI Edit — revert to original", function()
        for i, photo in ipairs(photos) do
            if progress:isCanceled() then break end
            local name = photo:getFormattedMetadata("fileName") or ("photo " .. i)
            progress:setCaption(string.format("Reverting %d of %d: %s", i, total, name))
            progress:setPortionComplete(i - 1, total)

            -- Restore ONLY the plugin's own develop keys (RESET_KEYS) from the
            -- saved snapshot, each set back to its original value — or to neutral 0
            -- if it was absent originally. We do NOT re-apply the whole snapshot:
            -- it carries string-encoded mask/retouch data that makes
            -- applyDevelopSettings throw "Assertion failed: packed". Temperature/
            -- Tint and WhiteBalance are restored as-is (their neutral isn't 0).
            local encoded  = photo:getPropertyForPlugin(_PLUGIN, "preEditSettings")
            local snapshot
            if encoded and encoded ~= "" then
                local ok, decoded = pcall(function() return json.decode(encoded) end)
                if ok and type(decoded) == "table" then snapshot = decoded end
            end

            if snapshot and next(snapshot) ~= nil then
                local restore = {}
                for _, k in ipairs(RESET_KEYS) do
                    if snapshot[k] ~= nil then
                        restore[k] = snapshot[k]
                    elseif k ~= "Temperature" and k ~= "Tint" then
                        restore[k] = 0   -- absent originally → neutral default
                    end
                end
                if snapshot.WhiteBalance ~= nil then restore.WhiteBalance = snapshot.WhiteBalance end
                photo:applyDevelopSettings(restore, "AI Edit — revert to original")
                photo:setPropertyForPlugin(_PLUGIN, "preEditSettings", "")
                restored = restored + 1
                Log.write("  " .. name .. ": restored plugin keys to original")
            else
                noSnapshot = noSnapshot + 1
                Log.write("  " .. name .. ": no pre-edit snapshot — nothing to revert")
            end
        end
    end)

    progress:done()

    local msg
    if total == 1 then
        if restored == 1 then
            msg = "Reset to the original (pre-edit state) — all AI edits removed."
        else
            msg = "No saved pre-edit state was found for this photo, so there was nothing to revert. " ..
                  "If it still shows AI edits, use Lightroom's Develop → Reset."
        end
    else
        msg = string.format("Reverted %d of %d photos to their pre-edit original.", restored, total)
        if noSnapshot > 0 then
            msg = msg .. string.format(" %d had no saved state (use Develop → Reset for those).", noSnapshot)
        end
    end
    LrDialogs.message("AI Edit — Revert", msg, "info")
end)
