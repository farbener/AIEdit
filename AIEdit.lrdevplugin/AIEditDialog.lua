--[[============================================================================
  AIEditDialog.lua  —  ENTRY POINT for "AI Edit Selected Photo…"

  WHAT THIS FILE DOES
    Shows the edit dialog, then for each selected photo: renders a thumbnail,
    measures a histogram, asks Claude for develop settings, and applies them.
    Optionally shows a visual preview with Keep/Revert (single photo only).

  REQUEST FLOW (the path a single photo takes)
    1. computeEdits()      render thumbs + histogram + metadata → AIProvider
    2. applyEdits()         snapshot original (scalars), map + apply settings
    3. feedbackCorrect()    diagnostic only — logs subject brightness vs target
    4. preview branch       force fresh render → show dialog → Keep or Revert
       (or) runBatch()      loop processOnePhoto() with a progress bar

  KEY SDK CONSTRAINTS (learned the hard way — see inline notes)
    • Everything runs inside LrFunctionContext.postAsyncTaskWithContext: the
      thumbnail callback, the dialog, LrHttp.post and withWriteAccessDo all
      require a task.
    • Lua 5.1: no goto/labels, and you CANNOT yield across a C/metamethod
      boundary — so never wrap a yielding SDK call (applyDevelopSettings,
      requestJpegThumbnail) in pcall, and never call yielding metadata getters
      while a view tree is being built.
    • Modern photos use Process Version 2012+; basic tone keys need the "2012"
      suffix (see SETTING_MAP).

  PUBLIC SURFACE
    None — this file is a menu script. It runs top-to-bottom when invoked.

  RELATED FILES
    AIProvider.lua (API call: Anthropic / OpenAI), Histogram.lua + JpegDecode.lua (metering),
    Presets.lua / Settings.lua (persistence), AIEditRevert.lua (reset),
    Log.lua (→ Documents/AIEdit_debug.log).
============================================================================]]

local LrApplication     = import "LrApplication"
local LrDialogs         = import "LrDialogs"
local LrView            = import "LrView"
local LrBinding         = import "LrBinding"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks           = import "LrTasks"
local LrProgressScope   = import "LrProgressScope"
local LrPathUtils       = import "LrPathUtils"
local LrFileUtils       = import "LrFileUtils"

local json      = require "dkjson"
local Log       = require "Log"
local Settings  = require "Settings"
local Presets   = require "Presets"
local Histogram = require "Histogram"
local AIProvider = require "AIProvider"

Log.reset()
Log.write("AIEditDialog.lua loaded")

-- ── Develop key map: JSON key → Lightroom SDK develop setting key ─────────────
-- IMPORTANT: modern photos use Process Version 2012+, where the basic tone
-- controls carry a "2012" suffix. Using the legacy keys (Exposure, Contrast…)
-- on a PV2012 photo is silently ignored or misinterpreted, which caused edits
-- to not apply (or to go dark). The version-independent keys (Vibrance,
-- Saturation, Temperature, Tint, HSL, Sharpness, etc.) keep their plain names.
local SETTING_MAP = {
    Exposure        = "Exposure2012",
    Contrast        = "Contrast2012",
    Highlights      = "Highlights2012",
    Shadows         = "Shadows2012",
    Whites          = "Whites2012",
    Blacks          = "Blacks2012",
    Clarity         = "Clarity2012",
    Texture         = "Texture",
    Dehaze          = "Dehaze",
    Vibrance        = "Vibrance",
    Saturation      = "Saturation",
    ColorTempKelvin = "Temperature",
    Tint            = "Tint",
    HueRed          = "HueAdjustmentRed",
    HueOrange       = "HueAdjustmentOrange",
    HueYellow       = "HueAdjustmentYellow",
    HueGreen        = "HueAdjustmentGreen",
    HueAqua         = "HueAdjustmentAqua",
    HueBlue         = "HueAdjustmentBlue",
    HuePurple       = "HueAdjustmentPurple",
    HueMagenta      = "HueAdjustmentMagenta",
    SatRed          = "SaturationAdjustmentRed",
    SatOrange       = "SaturationAdjustmentOrange",
    SatYellow       = "SaturationAdjustmentYellow",
    SatGreen        = "SaturationAdjustmentGreen",
    SatAqua         = "SaturationAdjustmentAqua",
    SatBlue         = "SaturationAdjustmentBlue",
    SatPurple       = "SaturationAdjustmentPurple",
    SatMagenta      = "SaturationAdjustmentMagenta",
    LumRed          = "LuminanceAdjustmentRed",
    LumOrange       = "LuminanceAdjustmentOrange",
    LumYellow       = "LuminanceAdjustmentYellow",
    LumGreen        = "LuminanceAdjustmentGreen",
    LumAqua         = "LuminanceAdjustmentAqua",
    LumBlue         = "LuminanceAdjustmentBlue",
    LumPurple       = "LuminanceAdjustmentPurple",
    LumMagenta      = "LuminanceAdjustmentMagenta",
    VignetteAmount  = "PostCropVignetteAmount",  -- artistic edge darkening (not lens correction)
    GrainAmount     = "GrainAmount",
    Sharpness       = "Sharpness",
    NoiseReduction  = "LuminanceSmoothing",
}

-- ── Get JPEG thumbnail via requestJpegThumbnail ──────────────────────────────
-- Renders the photo to in-memory JPEG bytes at the requested size.
--   params : photo (LrPhoto), width, height (pixels)
--   returns: jpegData (string), nil    on success
--            nil, errorMessage (string) on failure/timeout
--   note   : MUST run inside a task (it sleeps while polling the callback).
local THUMBNAIL_POLL_INTERVAL_SEC = 0.1   -- how often we check for the callback
local THUMBNAIL_MAX_POLLS         = 200   -- 200 × 0.1s = 20s hard timeout
local function getThumbnail(photo, width, height)
    Log.write("getThumbnail: start (" .. width .. "x" .. height .. ")")

    local jpegData = nil
    local errorMsg = nil
    local done     = false

    -- requestJpegThumbnail's callback signature is (jpegData, errorObj).
    -- We MUST keep the returned object referenced (holdRef) for the lifetime
    -- of the request: if it is garbage-collected the callback never fires.
    -- This variable looks unused but deleting it WILL break thumbnailing.
    local holdRef = photo:requestJpegThumbnail(width, height, function(data, err)
        if data then
            jpegData = data
            Log.write("getThumbnail: callback fired, got " .. tostring(#data) .. " bytes")
        else
            errorMsg = err or "unknown thumbnail error"
            Log.write("getThumbnail: callback fired with ERROR: " .. tostring(errorMsg))
        end
        done = true
    end)
    local _ = holdRef  -- silence "unused" tools; see comment above

    Log.write("getThumbnail: request issued, polling for callback…")

    local waited = 0
    while not done and waited < THUMBNAIL_MAX_POLLS do
        LrTasks.sleep(THUMBNAIL_POLL_INTERVAL_SEC)
        waited = waited + 1
    end

    Log.write("getThumbnail: poll ended after " .. (waited * THUMBNAIL_POLL_INTERVAL_SEC) .. "s, done=" .. tostring(done))

    if not done then
        local timeoutSec = THUMBNAIL_MAX_POLLS * THUMBNAIL_POLL_INTERVAL_SEC
        return nil, string.format("Thumbnail request timed out after %ds.", timeoutSec)
    end
    if not jpegData then
        return nil, tostring(errorMsg)
    end
    return jpegData, nil
end

-- ── Write JPEG bytes to a temp file (unique name per call) ───────────────────
local tempCounter = 0
local function writeTempJpeg(jpegData)
    tempCounter = tempCounter + 1
    local tmpDir  = LrPathUtils.getStandardFilePath("temp")
    local tmpName = string.format("aiedit_thumb_%d_%d.jpg", os.time(), tempCounter)
    local tmpPath = LrPathUtils.child(tmpDir, tmpName)
    Log.write("writeTempJpeg: writing to " .. tmpPath)
    local f = io.open(tmpPath, "wb")
    if not f then
        return nil, "Could not open temp file for writing: " .. tmpPath
    end
    f:write(jpegData)
    f:close()
    Log.write("writeTempJpeg: wrote " .. tostring(#jpegData) .. " bytes")
    return tmpPath, nil
end

-- ── Apply Claude's edits to the photo (snapshotting prior state) ─────────────
local function applyEdits(photo, edits)
    Log.write("applyEdits: start")
    local catalog = LrApplication.activeCatalog()

    -- Read current settings BEFORE entering the write gate.
    local before = photo:getDevelopSettings()
    local curPV  = before and before.ProcessVersion
    Log.write("applyEdits: current ProcessVersion = " .. tostring(curPV))

    local applied = 0
    catalog:withWriteAccessDo("AI Edit — apply develop settings", function()
        -- Snapshot the true original once (so repeated edits still revert to it).
        -- Store ALL SCALAR develop settings (every number/string/boolean), not
        -- just the keys we edit — so restore returns the photo faithfully to its
        -- original tone AND white balance AND everything else. We exclude
        -- table-valued fields (tone curves, masks, Look): they cause the
        -- "Assertion failed: packed" error on re-apply, and the AI never changes
        -- them anyway, so they remain at their original values regardless.
        local existing = photo:getPropertyForPlugin(_PLUGIN, "preEditSettings")
        if not existing or existing == "" then
            local snapshot = {}
            for k, v in pairs(before) do
                local t = type(v)
                if t == "number" or t == "string" or t == "boolean" then
                    snapshot[k] = v
                end
            end
            local okEnc, encoded = pcall(function() return json.encode(snapshot) end)
            if okEnc and encoded and #encoded > 2 then
                photo:setPropertyForPlugin(_PLUGIN, "preEditSettings", encoded)
                Log.write("applyEdits: snapshot stored (" .. #encoded .. " bytes, all scalars)")
            else
                Log.write("applyEdits: WARNING could not encode original settings")
            end
        else
            Log.write("applyEdits: original snapshot already exists, keeping it")
        end

        local settings = {}
        -- Keep the photo on a modern process version so the *2012 keys apply.
        -- Only upgrade if the photo is on a legacy PV (< 5); never downgrade.
        local pvMajor = curPV and tonumber((curPV:gsub("%..*", "")))
        if pvMajor and pvMajor < 5 then
            settings.ProcessVersion = "11.0"
            Log.write("applyEdits: upgrading legacy ProcessVersion to 11.0")
        end

        local logParts = {}
        for ourKey, lrKey in pairs(SETTING_MAP) do
            local val = edits[ourKey]
            if val ~= nil and type(val) == "number" then
                settings[lrKey] = val
                applied = applied + 1
                if val ~= 0 then
                    logParts[#logParts + 1] = ourKey .. "=" .. tostring(val)
                end
            end
        end
        photo:applyDevelopSettings(settings)
        Log.write("applyEdits: non-zero adjustments: " .. (table.concat(logParts, ", ")))
    end)
    Log.write("applyEdits: applied " .. applied .. " settings")
end

-- ── Render a photo to a temp JPEG and return its histogram stats table. ──────
local function measurePhoto(photo, size)
    local data = getThumbnail(photo, size, size)
    if not data then return nil end
    local path = writeTempJpeg(data)
    if not path then return nil end
    local _, stats = Histogram.analyse(path)
    LrFileUtils.delete(path)
    return stats
end

-- ── Compute proposed edits for ONE photo (no apply). ─────────────────────────
-- Returns ok(bool), editsTableOrError. The edits table includes a .reasoning.
local function computeEdits(photo, stylePrompt, strength)
    local name = photo:getFormattedMetadata("fileName") or "(unknown)"
    Log.write("computeEdits: " .. name .. " strength=" .. tostring(strength))

    local jpegData, thumbErr = getThumbnail(photo, 1024, 1024)
    if not jpegData then return false, "Thumbnail error: " .. tostring(thumbErr) end
    local thumbPath, writeErr = writeTempJpeg(jpegData)
    if not thumbPath then return false, "File error: " .. tostring(writeErr) end

    local histStr = nil
    local preStats = nil
    local smallData = getThumbnail(photo, 400, 400)
    if smallData then
        local smallPath = writeTempJpeg(smallData)
        if smallPath then
            local s, stats = Histogram.analyse(smallPath)
            LrFileUtils.delete(smallPath)
            histStr = s
            preStats = stats
            if stats then
                Log.write(string.format(
                    "computeEdits: pre-edit histogram meanLum=%.1f centerLum=%.1f clipHi=%.2f%% clipLo=%.2f%%",
                    stats.meanLum or -1, stats.centerMeanLum or -1,
                    stats.clipHiPct or -1, stats.clipLoPct or -1))
            end
        end
    end

    local meta = {
        filename     = name,
        iso          = photo:getFormattedMetadata("isoSpeedRating"),
        aperture     = photo:getFormattedMetadata("aperture"),
        shutterSpeed = photo:getFormattedMetadata("shutterSpeed"),
        focalLength  = photo:getFormattedMetadata("focalLength"),
        camera       = photo:getFormattedMetadata("cameraModel"),
        lens         = photo:getFormattedMetadata("lens"),
        fileType     = photo:getFormattedMetadata("fileType"),
        exposureBias = photo:getFormattedMetadata("exposureBias"),
        flash        = photo:getFormattedMetadata("flash"),
    }

    Log.write("computeEdits: calling Claude (strength=" .. tostring(strength) ..
              ", style='" .. tostring(stylePrompt) .. "')")
    local ok, editsOrErr = AIProvider.analysePhoto(thumbPath, stylePrompt, meta, histStr, strength)
    LrFileUtils.delete(thumbPath)
    if not ok then return false, tostring(editsOrErr) end
    -- Attach the pre-edit subject luminance for the analytical feedback pass.
    editsOrErr._preCenterLum = preStats and preStats.centerMeanLum or nil
    if editsOrErr.Exposure then
        Log.write(string.format("computeEdits: Claude proposes Exposure %+.2f EV (subject was %.1f)",
            editsOrErr.Exposure, editsOrErr._preCenterLum or -1))
    end
    return true, editsOrErr
end

-- ── Analytical feedback: predict the post-edit subject luminance from the ────
-- pre-edit luminance and the exposure we applied, then correct toward target.
-- This avoids re-rendering (Lightroom returns stale cached thumbnails after an
-- edit, so re-measuring is unreliable). Works in linear light.
local function srgbToLinear(c)
    c = c / 255
    if c <= 0.04045 then return c / 12.92 else return ((c + 0.055) / 1.055) ^ 2.4 end
end
local function linearToSrgb(l)
    if l <= 0.0031308 then l = l * 12.92 else l = 1.055 * (l ^ (1/2.4)) - 0.055 end
    return l * 255
end

local function feedbackCorrect(photo, preCenterLum, appliedExposure)
    local TARGET_LO, TARGET_HI, TARGET_MID = 150, 168, 159

    if not preCenterLum then
        Log.write("  feedback(diagnostic): no pre-edit luminance available")
        return nil
    end
    appliedExposure = appliedExposure or 0

    -- DIAGNOSTIC ONLY — we no longer auto-apply an exposure correction.
    -- Two reasons it can't be done reliably in the LR SDK:
    --   1. Re-measuring after an edit reads a STALE cached thumbnail (LR rebuilds
    --      previews lazily and requestJpegThumbnail returns the old one).
    --   2. Predicting from exposure alone overshoots: LR's Exposure2012 is not a
    --      linear multiply, and the prediction ignores the other brightening
    --      adjustments Claude applies (Shadows, Contrast, Whites), so it
    --      underestimates the real result and over-corrects.
    -- Claude's first pass already targets subject luminance via the histogram,
    -- which is the reliable mechanism. We log the prediction for insight only.
    local linPre  = srgbToLinear(preCenterLum)
    local linPost = linPre * (2 ^ appliedExposure)
    if linPost > 1 then linPost = 1 end
    local predicted = linearToSrgb(linPost)
    Log.write(string.format(
        "  feedback(diagnostic): pre-subject=%.1f, Claude applied %+.2f EV, naive-predicted=%.1f (target %d-%d) — NO auto-correction applied",
        preCenterLum, appliedExposure, predicted, TARGET_LO, TARGET_HI))
    return nil
end

-- ── Process ONE photo end-to-end (compute + apply + optional feedback). ───────
local function processOnePhoto(photo, stylePrompt, strength, feedbackLoop)
    local ok, editsOrErr = computeEdits(photo, stylePrompt, strength)
    if not ok then
        Log.write("  FAILED: " .. tostring(editsOrErr))
        return false, tostring(editsOrErr)
    end
    applyEdits(photo, editsOrErr)
    local reasoning = tostring(editsOrErr.reasoning or "No reasoning provided.")
    if feedbackLoop then
        local ev = feedbackCorrect(photo, editsOrErr._preCenterLum, editsOrErr.Exposure)
        if ev then
            reasoning = reasoning .. string.format("\n[Feedback pass: nudged exposure %+.2f EV toward a well-lit subject.]", ev)
        end
    end
    return true, reasoning
end

-- ── Run over a list of photos with progress + summary. ────────────────────────
local function runBatch(photos, stylePrompt, strength, feedback)
    local total = #photos
    Log.write("runBatch: " .. total .. " photo(s) feedback=" .. tostring(feedback))

    local progress = LrProgressScope({ title = "AI Edit" })

    local succeeded, failed = 0, 0
    local lastReason = ""
    local firstError = nil

    for i, photo in ipairs(photos) do
        if progress:isCanceled() then
            Log.write("runBatch: cancelled by user at " .. i)
            break
        end
        local name = photo:getFormattedMetadata("fileName") or ("photo " .. i)
        progress:setCaption(string.format("Editing %d of %d: %s", i, total, name))
        progress:setPortionComplete(i - 1, total)

        local ok, result = processOnePhoto(photo, stylePrompt, strength, feedback)
        if ok then
            succeeded = succeeded + 1
            lastReason = result
        else
            failed = failed + 1
            if not firstError then firstError = name .. ": " .. result end
        end
    end

    progress:done()

    -- Summary
    if total == 1 then
        if succeeded == 1 then
            LrDialogs.message("AI Edit — Complete",
                "Edits applied successfully.\n\nReasoning:\n" .. lastReason, "info")
        else
            LrDialogs.message("AI Edit — Failed", tostring(firstError), "critical")
        end
    else
        local msg = string.format("Processed %d photos.\n%d succeeded, %d failed.", total, succeeded, failed)
        if firstError then msg = msg .. "\n\nFirst error:\n" .. firstError end
        LrDialogs.message("AI Edit — Batch Complete", msg, failed > 0 and "warning" or "info")
    end
end

-- ── Main entry point ──────────────────────────────────────────────────────────
-- The ENTIRE body runs inside a task, because getTargetPhoto(), the dialog,
-- requestJpegThumbnail, LrHttp.post and withWriteAccessDo all require a task.
LrFunctionContext.postAsyncTaskWithContext("AIEdit", function(context)
    LrDialogs.attachErrorDialogToFunctionContext(context)
    Log.write("Main: postAsyncTaskWithContext entered (inside task)")

    local catalog = LrApplication.activeCatalog()
    local photos  = catalog:getTargetPhotos()   -- selected photos (or active one)
    Log.write("Main: getTargetPhotos returned " .. tostring(photos and #photos or 0))

    if not photos or #photos == 0 then
        Log.write("Main: no photos selected")
        LrDialogs.message("AI Edit", "No photo selected.\nPlease select one or more photos in the Library grid first.", "warning")
        return
    end
    local photoCount = #photos
    local firstName  = photos[1]:getFormattedMetadata("fileName") or "(unknown)"
    Log.write("Main: " .. photoCount .. " photo(s), first = " .. firstName)

    Log.write("Main: getting osFactory")
    local f     = LrView.osFactory()
    Log.write("Main: making property table")
    local props = LrBinding.makePropertyTable(context)
    local last  = Settings.getLast()
    props.stylePrompt = last.style
    props.strength    = last.strength
    -- Diagnostic logging defaults OFF unless a chosen preset enables it.
    props.feedback    = false
    props.preview     = last.preview
    props.presetName  = ""
    -- AI provider + its saved API key. Keys are stored per provider, so the
    -- field shows the key for whichever provider is selected.
    props.provider    = Settings.getProvider()
    Log.write("Main: getting saved API key for provider=" .. tostring(props.provider))
    props.apiKey      = Settings.getApiKey(props.provider)

    -- Provider dropdown items. Add a row here if you add a provider in AIProvider.
    local providerItems = {
        { title = "Anthropic (Claude)", value = "anthropic" },
        { title = "OpenAI (ChatGPT)",   value = "openai" },
        { title = "Ollama (Local)",     value = "ollama" },
    }
    -- "Get your key at …" hint per provider, shown under the key field.
    local providerKeyHint = {
        anthropic = "Anthropic key from console.anthropic.com — saved automatically.",
        openai    = "OpenAI key from platform.openai.com — saved automatically.",
    }
    -- When the provider changes: save the key typed for the old provider, then
    -- load the saved key for the newly selected one into the field.
    local lastProvider = props.provider
    props:addObserver("provider", function()
        Settings.setApiKey(lastProvider, props.apiKey)   -- preserve what was typed
        lastProvider = props.provider
        props.apiKey = Settings.getApiKey(props.provider)
        Log.write("Main: provider switched to " .. tostring(props.provider))
    end)

    -- Build preset dropdown items. Apply a preset to the fields when chosen.
    local presetNames = Presets.names()
    local presetItems = { { title = "— none —", value = "" } }
    for _, nm in ipairs(presetNames) do
        presetItems[#presetItems + 1] = { title = nm, value = nm }
    end
    props:addObserver("presetName", function()
        local p = Presets.get(props.presetName)
        if p then
            props.stylePrompt = p.style or ""
            props.strength    = p.strength or 100
            props.feedback    = p.feedback and true or false
            Log.write("Main: applied preset '" .. tostring(props.presetName) .. "'")
        end
    end)

    -- Pre-compute any yielding metadata calls BEFORE building the view.
    -- View construction goes through metamethods, and Lua 5.1 cannot yield
    -- across a C/metamethod boundary, so calling getFormattedMetadata inside
    -- f:column would throw "Yielding is not allowed within a C or metamethod call".
    -- Pre-compute the selection label BEFORE building the view (no yielding calls inside f:column).
    local selectionLabel
    if photoCount == 1 then
        selectionLabel = firstName
    else
        selectionLabel = string.format("%d photos selected (batch)", photoCount)
    end
    Log.write("Main: building dialog contents (" .. selectionLabel .. ")")

    local contents = f:column {
        spacing        = f:control_spacing(),
        bind_to_object = props,

        f:static_text { title = "AI Edit for Lightroom Classic", font = "<system/bold>" },
        f:separator { fill_horizontal = 1 },
        f:row {
            spacing = f:label_spacing(),
            f:static_text { title = "Selection:", font = "<system/bold>" },
            f:static_text { title = selectionLabel },
        },
        f:spacer { height = 10 },
        f:row {
            spacing = f:label_spacing(),
            f:static_text { title = "Preset:", font = "<system/bold>", width_in_chars = 8 },
            f:popup_menu {
                value = LrView.bind("presetName"),
                items = presetItems,
                width_in_chars = 24,
            },
        },
        f:static_text {
            title = "Choosing a preset fills in the style and strength below.",
            font  = "<system/small>",
        },
        f:spacer { height = 8 },
        f:static_text { title = "Style / mood instruction (optional):", font = "<system/bold>" },
        f:static_text {
            title = 'e.g. "cinematic teal and orange",  "soft moody portrait",  "vivid golden hour"',
            font  = "<system/small>",
        },
        f:edit_field {
            value           = LrView.bind("stylePrompt"),
            width_in_chars  = 52,
            height_in_lines = 2,
        },
        f:spacer { height = 10 },
        f:static_text { title = "Adjustment strength:", font = "<system/bold>" },
        f:row {
            spacing = f:label_spacing(),
            f:slider {
                value    = LrView.bind("strength"),
                min      = 0,
                max      = 200,
                integral = true,
                width    = 300,
            },
            f:static_text {
                title = LrView.bind {
                    key = "strength",
                    transform = function(v) return string.format("%d%%", v or 100) end,
                },
                width_in_chars = 6,
            },
        },
        f:static_text {
            title = "100% = normal. Lower for subtle edits, higher to push harder (e.g. stronger highlight recovery).",
            font  = "<system/small>",
        },
        f:spacer { height = 8 },
        f:checkbox {
            title = "Log exposure diagnostic (subject brightness vs target; no auto-correction)",
            value = LrView.bind("feedback"),
        },
        f:checkbox {
            title = "Preview proposed adjustments before applying (single photo only)",
            value = LrView.bind("preview"),
        },
        f:spacer { height = 6 },
        f:row {
            f:push_button {
                title  = "Save current as preset…",
                action = function()
                    local name = LrDialogs.runOpenPanel and nil  -- placeholder guard
                    -- Ask for a preset name with a tiny modal.
                    local np = LrBinding.makePropertyTable(context)
                    np.name = props.presetName ~= "" and props.presetName or ""
                    local nameDialog = f:column {
                        bind_to_object = np,
                        f:static_text { title = "Preset name:" },
                        f:edit_field { value = LrView.bind("name"), width_in_chars = 30 },
                    }
                    local r = LrDialogs.presentModalDialog({
                        title = "Save Preset",
                        contents = nameDialog,
                        actionVerb = "Save",
                    })
                    if r == "ok" and np.name and np.name ~= "" then
                        Presets.set(np.name, props.stylePrompt, props.strength, props.feedback)
                        LrDialogs.message("Preset saved", "Saved preset \"" .. np.name .. "\".", "info")
                    end
                end,
            },
        },
        f:spacer { height = 10 },
        f:separator { fill_horizontal = 1 },
        f:row {
            spacing = f:label_spacing(),
            f:static_text { title = "AI provider:", font = "<system/bold>", width_in_chars = 12 },
            f:popup_menu {
                value = LrView.bind("provider"),
                items = providerItems,
                width_in_chars = 22,
            },
        },
        f:static_text {
            title = LrView.bind {
                key = "provider",
                transform = function(p) return (p == "openai") and "OpenAI API Key:" or "Anthropic API Key:" end,
            },
            font = "<system/bold>",
            visible = LrView.bind { key = "provider", transform = function(p) return p ~= "ollama" end },
        },
        f:static_text {
            title = LrView.bind {
                key = "provider",
                transform = function(p) return providerKeyHint[p] or providerKeyHint.anthropic end,
            },
            font  = "<system/small>",
            visible = LrView.bind { key = "provider", transform = function(p) return p ~= "ollama" end },
        },
        f:edit_field {
            value          = LrView.bind("apiKey"),
            width_in_chars = 52,
            visible = LrView.bind { key = "provider", transform = function(p) return p ~= "ollama" end },
        },
        -- Ollama runs locally and needs no key; show the endpoint as read-only info.
        f:static_text {
            title = "Local Ollama — no API key needed.",
            font  = "<system/bold>",
            visible = LrView.bind { key = "provider", transform = function(p) return p == "ollama" end },
        },
        f:static_text {
            title = "Endpoint: http://localhost:11434/v1/chat/completions",
            font  = "<system/small>",
            visible = LrView.bind { key = "provider", transform = function(p) return p == "ollama" end },
        },
    }
    Log.write("Main: dialog contents built OK")

    Log.write("Main: presenting modal dialog")
    local actionVerb = (photoCount == 1) and "Analyse & Apply" or ("Apply to " .. photoCount .. " photos")
    local result = LrDialogs.presentModalDialog({
        title      = "AI Edit",
        contents   = contents,
        actionVerb = actionVerb,
        cancelVerb = "Cancel",
    })
    Log.write("Main: dialog returned '" .. tostring(result) .. "'")

    if result == "cancel" then
        Log.write("Main: user cancelled")
        return
    end

    Settings.setProvider(props.provider)
    Settings.setApiKey(props.provider, props.apiKey)
    local stylePrompt = props.stylePrompt
    local strength    = props.strength or 100
    local feedback    = props.feedback and true or false
    local preview     = props.preview and true or false
    Settings.setLast(stylePrompt, strength, feedback, preview)
    Log.write(string.format("Main: provider=%s style='%s' strength=%d feedback=%s preview=%s",
        tostring(props.provider), tostring(stylePrompt), strength, tostring(feedback), tostring(preview)))

    -- Preview mode only applies to a single photo (showing 20 previews is silly).
    if preview and photoCount == 1 then
        local photo = photos[1]
        local progress = LrProgressScope({ title = "AI Edit — analysing…" })
        local ok, edits = computeEdits(photo, stylePrompt, strength)
        if not ok then
            progress:done()
            LrDialogs.message("AI Edit — Failed", tostring(edits), "critical")
            return
        end

        -- Build a readable list of the non-trivial proposed adjustments.
        local order = {
            {"Exposure","Exposure (stops)"}, {"Contrast","Contrast"},
            {"Highlights","Highlights"}, {"Shadows","Shadows"},
            {"Whites","Whites"}, {"Blacks","Blacks"},
            {"Texture","Texture"}, {"Clarity","Clarity"}, {"Dehaze","Dehaze"},
            {"Vibrance","Vibrance"}, {"Saturation","Saturation"},
            {"ColorTempKelvin","Temp (K)"}, {"Tint","Tint"},
            {"VignetteAmount","Vignette"}, {"Sharpness","Sharpness"},
            {"NoiseReduction","Noise reduction"},
        }
        local lines = {}
        for _, pair in ipairs(order) do
            local v = edits[pair[1]]
            if type(v) == "number" and v ~= 0 then
                lines[#lines + 1] = string.format("%s: %s", pair[2], tostring(v))
            end
        end
        local listStr = (#lines > 0) and table.concat(lines, "\n") or "(no significant adjustments)"
        local reasoning = tostring(edits.reasoning or "")

        -- Apply so we can render a true visual preview (revert if rejected).
        progress:setCaption("Rendering preview…")

        -- Capture a local snapshot of the pre-preview state, restricted to the
        -- develop keys the plugin can change (SETTING_MAP targets) plus WhiteBalance.
        -- We do NOT capture the whole getDevelopSettings() blob: it includes
        -- string-encoded mask/retouch data that makes applyDevelopSettings throw
        -- "Assertion failed: packed" on revert. Restoring just our keys is complete
        -- — the AI never changes anything else. Temperature/Tint neutral isn't 0,
        -- so they're only captured when present (not zero-filled).
        local preState = {}
        do
            local cur = photo:getDevelopSettings()
            for _, lrKey in pairs(SETTING_MAP) do
                if cur[lrKey] ~= nil then
                    preState[lrKey] = cur[lrKey]
                elseif lrKey ~= "Temperature" and lrKey ~= "Tint" then
                    preState[lrKey] = 0   -- absent originally → neutral default
                end
            end
            if cur.WhiteBalance ~= nil then preState.WhiteBalance = cur.WhiteBalance end
        end
        local prevPersisted = photo:getPropertyForPlugin(_PLUGIN, "preEditSettings")

        applyEdits(photo, edits)
        if feedback then
            local ev = feedbackCorrect(photo, edits._preCenterLum, edits.Exposure)
            if ev then reasoning = reasoning .. string.format("\n[Feedback: %+.2f EV]", ev) end
        end
        -- Force Lightroom to (re)build the preview so catalog_photo shows the
        -- edited result, not a stale cached thumbnail.
        getThumbnail(photo, 1024, 1024)
        LrTasks.sleep(0.4)
        progress:done()

        local pf = LrView.osFactory()
        local pprops = LrBinding.makePropertyTable(context)
        local previewContents = pf:row {
            spacing = pf:control_spacing(),
            pf:catalog_photo {
                photo       = photo,
                width       = 360,
                height      = 480,
                frame_width = 1,
            },
            pf:column {
                width = 320,
                pf:static_text { title = "Proposed adjustments", font = "<system/bold>" },
                pf:static_text { title = listStr, height_in_lines = #lines + 1, width_in_chars = 40 },
                pf:spacer { height = 8 },
                pf:static_text { title = "Reasoning", font = "<system/bold>" },
                pf:static_text { title = reasoning, height_in_lines = 8, width_in_chars = 40 },
            },
        }

        local r = LrDialogs.presentModalDialog({
            title      = "AI Edit — Preview (already applied; keep or revert)",
            contents   = previewContents,
            actionVerb = "Keep",
            cancelVerb = "Revert",
        })

        if r ~= "ok" then
            -- Restore the exact pre-preview state from the complete local snapshot.
            local nKeys = 0
            for _ in pairs(preState) do nKeys = nKeys + 1 end
            Log.write("Main: preview REJECTED — reverting to local pre-state (" .. nKeys .. " keys)")
            local catalog = LrApplication.activeCatalog()
            catalog:withWriteAccessDo("AI Edit — revert preview", function()
                -- Apply the captured pre-preview state WITHOUT reset=true. preState
                -- holds every scalar key (plus zeroed adjustment keys) at its
                -- pre-edit value, so it overwrites each edited key directly. Using
                -- reset=true here would merge a scalars-only table onto a default
                -- set that contains PACKED members (tone curve/masks) and throw
                -- "Assertion failed: packed" on current Lightroom builds.
                photo:applyDevelopSettings(preState, "AI Edit — revert preview")
                photo:setPropertyForPlugin(_PLUGIN, "preEditSettings", prevPersisted or "")
            end)
            -- Verify: measure the reverted result and compare to the pre-edit value.
            -- Settle the render first (force a rebuild + brief wait) so we don't
            -- read a transitional/stale thumbnail and report a false delta.
            getThumbnail(photo, 400, 400)
            LrTasks.sleep(0.8)
            local after = measurePhoto(photo, 400)
            if after and after.centerMeanLum and edits._preCenterLum then
                local delta = after.centerMeanLum - edits._preCenterLum
                Log.write(string.format(
                    "Main: revert check — pre-edit subject=%.1f, after-revert subject=%.1f (Δ%.1f)%s",
                    edits._preCenterLum, after.centerMeanLum, delta,
                    (math.abs(delta) <= 4) and " — clean" or " — residual (may be stale render)"))
            end
            LrDialogs.message("AI Edit", "Reverted — no changes kept.", "info")
        else
            Log.write("Main: preview KEPT")
        end
        return
    end

    -- Normal path (single without preview, or batch).
    Log.write("Main: running batch over " .. photoCount .. " photo(s)")
    runBatch(photos, stylePrompt, strength, feedback)
    Log.write("Main: batch complete, returning")
end)
