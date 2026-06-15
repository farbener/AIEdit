-- Histogram.lua
-- Computes exposure/clipping statistics from a JPEG (pure Lua, no dependencies).
--
-- PUBLIC API
--   Histogram.analyse(jpegPath)
--     → summaryString, statsTable   on success
--     → nil, errorString            on failure
--   statsTable keys (luminance values are 0–255):
--     meanLum                  whole-frame mean
--     centerMeanLum            mean of a center patch (subject ONLY if centered)
--     centerReliable           false when center ≈ frame mean (patch = background)
--     skinMeanLum, skinPct      skin-tone luminance + % of frame that is skin
--     skinReliable             true when enough skin was found to trust skinMeanLum
--     clipHiPct, clipLoPct      highlight / shadow clipping
--   Metering roles (see the EXPOSURE RULE in AIProvider's prompt):
--     • clipping numbers   = authoritative (8-bit preview hides recoverable detail)
--     • skinMeanLum        = primary subject-brightness signal when skinReliable
--     • centerMeanLum      = fallback hint, valid only when centerReliable

local JpegDecode = require "JpegDecode"
local Log        = require "Log"

local Histogram = {}

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*all")
    f:close()
    return d
end

-- Analyse a JPEG file on disk. Returns (summaryString, statsTable) or (nil, errString).
function Histogram.analyse(jpegPath)
    local data = readFile(jpegPath)
    if not data then return nil, "Could not read JPEG for histogram." end

    local img, err = JpegDecode.decode(data)
    if not img then
        Log.write("Histogram: decode failed: " .. tostring(err))
        return nil, err
    end

    local n   = img.width * img.height
    local pix = img.pixels
    local W, H = img.width, img.height
    if n == 0 then return nil, "Empty image." end

    -- Center region (subject-likely area): middle 40% horizontally,
    -- upper-middle band vertically (where a portrait subject usually sits).
    local cx0 = math.floor(W * 0.30)
    local cx1 = math.floor(W * 0.70)
    local cy0 = math.floor(H * 0.20)
    local cy1 = math.floor(H * 0.75)

    -- 16-bin luminance histogram + channel sums + clipping counts
    local sumR, sumG, sumB, sumL = 0, 0, 0, 0
    local clipHiR, clipHiG, clipHiB = 0, 0, 0
    local clipHiL, clipLoL = 0, 0
    local bins = {}
    for i = 1, 16 do bins[i] = 0 end

    -- Center accumulators
    local cSumL, cCount, cClipLo, cClipHi = 0, 0, 0, 0

    -- Skin-tone accumulators: a composition-independent subject-brightness signal.
    -- A pixel counts as skin when its YCbCr chroma is in the standard skin range
    -- (Chai & Ngan): 77<=Cb<=127 and 133<=Cr<=173, with a luminance gate to skip
    -- near-black and blown pixels. Forest green and neutral greys fall outside
    -- this range, so a grey sweater / green background are not miscounted as skin.
    local skinSumL, skinCount = 0, 0

    for i = 0, n - 1 do
        local r = pix[i*3+1]
        local g = pix[i*3+2]
        local b = pix[i*3+3]
        local lum = 0.299*r + 0.587*g + 0.114*b
        sumR = sumR + r; sumG = sumG + g; sumB = sumB + b; sumL = sumL + lum
        if r >= 252 then clipHiR = clipHiR + 1 end
        if g >= 252 then clipHiG = clipHiG + 1 end
        if b >= 252 then clipHiB = clipHiB + 1 end
        if lum >= 250 then clipHiL = clipHiL + 1 end
        if lum <= 5   then clipLoL = clipLoL + 1 end
        local bin = math.floor(lum / 16) + 1
        if bin > 16 then bin = 16 end
        bins[bin] = bins[bin] + 1

        -- skin-tone classification (see accumulator comment above)
        if lum >= 40 and lum <= 245 then
            local cb = 128 - 0.168736*r - 0.331264*g + 0.5*b
            local cr = 128 + 0.5*r - 0.418688*g - 0.081312*b
            if cb >= 77 and cb <= 127 and cr >= 133 and cr <= 173 then
                skinSumL  = skinSumL + lum
                skinCount = skinCount + 1
            end
        end

        -- center region
        local px = i % W
        local py = math.floor(i / W)
        if px >= cx0 and px < cx1 and py >= cy0 and py < cy1 then
            cSumL = cSumL + lum
            cCount = cCount + 1
            if lum <= 5   then cClipLo = cClipLo + 1 end
            if lum >= 250 then cClipHi = cClipHi + 1 end
        end
    end

    local meanLum       = sumL / n
    local centerMeanLum = (cCount > 0) and (cSumL / cCount) or meanLum
    local centerClipLo  = (cCount > 0) and (100 * cClipLo / cCount) or 0
    local centerClipHi  = (cCount > 0) and (100 * cClipHi / cCount) or 0

    -- Skin-tone subject luminance: the most composition-independent signal.
    local skinPct      = 100 * skinCount / n
    local skinMeanLum  = (skinCount > 0) and (skinSumL / skinCount) or nil
    local skinReliable = skinPct >= 0.5   -- need a meaningful skin region to trust it

    local function pct(c) return 100 * c / n end

    local stats = {
        width    = img.width,
        height   = img.height,
        meanR    = sumR / n,
        meanG    = sumG / n,
        meanB    = sumB / n,
        meanLum  = meanLum,
        clipHiPct = pct(clipHiL),
        clipLoPct = pct(clipLoL),
        clipR    = pct(clipHiR),
        clipG    = pct(clipHiG),
        clipB    = pct(clipHiB),
    }

    -- Which channel clips first / most
    local firstChannel = "none"
    local maxClip = math.max(stats.clipR, stats.clipG, stats.clipB)
    if maxClip > 0.1 then
        if stats.clipR == maxClip then firstChannel = "red"
        elseif stats.clipG == maxClip then firstChannel = "green"
        else firstChannel = "blue" end
    end

    -- Tonal distribution (shadows / midtones / highlights as % of pixels)
    local shadows, mids, highs = 0, 0, 0
    for i = 1, 16 do
        if i <= 5 then shadows = shadows + bins[i]
        elseif i <= 11 then mids = mids + bins[i]
        else highs = highs + bins[i] end
    end
    shadows = 100 * shadows / n
    mids    = 100 * mids / n
    highs   = 100 * highs / n

    stats.shadowsPct    = shadows
    stats.midtonesPct   = mids
    stats.highlightsPct = highs
    stats.firstClipChannel = firstChannel
    stats.centerMeanLum = centerMeanLum
    stats.centerClipLo  = centerClipLo
    stats.centerClipHi  = centerClipHi
    stats.skinMeanLum   = skinMeanLum
    stats.skinPct       = skinPct
    stats.skinReliable  = skinReliable

    -- Is the center patch actually isolating a subject? If the center mean is
    -- about the same as the whole-frame mean, the patch is reading background
    -- (subject off-center or absent), so the center number must NOT drive exposure.
    local centerDiff     = centerMeanLum - meanLum
    local centerReliable = math.abs(centerDiff) >= 8
    stats.centerReliable = centerReliable

    -- SUBJECT-BRIGHTNESS lines (the model uses these for the Exposure decision).
    local subjectLines
    if skinReliable then
        subjectLines = string.format(
            "- SKIN-TONE mean luminance: %.0f/255 (%.0f%% of full scale), from %.1f%% of the frame classified as skin  <-- PRIMARY subject signal; expose to this\n" ..
            "- Center-patch mean luminance: %.0f/255 (%.0f%%) — secondary; %s",
            skinMeanLum, 100*skinMeanLum/255, skinPct,
            centerMeanLum, 100*centerMeanLum/255,
            centerReliable and "patch appears to contain the subject"
                or "center ~ frame mean, so the patch is reading BACKGROUND — ignore it for exposure")
    else
        subjectLines = string.format(
            "- No reliable skin region detected (skin = %.1f%% of frame) — judge subject exposure from the VISIBLE face/subject in the image.\n" ..
            "- Center-patch mean luminance: %.0f/255 (%.0f%%) — %s",
            skinPct,
            centerMeanLum, 100*centerMeanLum/255,
            centerReliable and "patch appears to contain the subject; usable as a hint"
                or "center ~ frame mean, so the patch is reading BACKGROUND — IGNORE it for exposure and rely on what you see")
    end

    -- Build a compact summary string for the prompt
    local summary = string.format(
        "MEASURED HISTOGRAM (objective, from the rendered %dx%d preview).\n" ..
        "CLIPPING / HEADROOM (trust these numbers over your visual impression — the 8-bit preview hides recoverable detail):\n" ..
        "- Highlight clipping: %.1f%% of frame near white (luma>=250); per channel R=%.1f%% G=%.1f%% B=%.1f%%; worst: %s; subject-area highlight clip: %.1f%%\n" ..
        "- Shadow clipping: %.1f%% of frame near black (luma<=5); subject-area shadow clip: %.1f%%\n" ..
        "- Whole-frame mean luminance: %.0f/255 (%.0f%% of full scale)\n" ..
        "- Tonal distribution: shadows %.0f%% / midtones %.0f%% / highlights %.0f%%\n" ..
        "SUBJECT BRIGHTNESS (for the Exposure decision — apply the EXPOSURE RULE in the instructions):\n%s",
        stats.width, stats.height,
        stats.clipHiPct, stats.clipR, stats.clipG, stats.clipB, firstChannel, centerClipHi,
        stats.clipLoPct, centerClipLo,
        meanLum, 100*meanLum/255,
        shadows, mids, highs,
        subjectLines
    )

    Log.write(string.format(
        "Histogram: meanLum=%.1f centerLum=%.1f skinLum=%s skinPct=%.2f%% centerReliable=%s clipHi=%.2f%% clipLo=%.2f%%",
        meanLum, centerMeanLum,
        skinMeanLum and string.format("%.1f", skinMeanLum) or "n/a",
        skinPct, tostring(centerReliable), stats.clipHiPct, stats.clipLoPct))

    return summary, stats
end

return Histogram
