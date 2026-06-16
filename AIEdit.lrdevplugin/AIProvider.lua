--[[============================================================================
  AIProvider.lua  --  multi-provider AI client (Anthropic Claude / OpenAI / Ollama)

  Builds the request (image + histogram + metadata + style), sends it to the
  configured provider, and parses the JSON adjustment object the model returns.

  PUBLIC API
    AIProvider.analysePhoto(thumbPath, smallThumbPath, stylePrompt, metadata, histogramStr, strength)
      -> true,  editsTable   on success   (keys per SETTING_MAP + "reasoning")
      -> false, errorString  on failure

  HOW PROVIDERS WORK
    The active provider is chosen in the dialog and read via Settings.getProvider().
    Each provider has one entry in the ADAPTERS table below, supplying three things:
      url           the endpoint to POST to
      buildRequest  format (systemPrompt, userText, imgB64, apiKey, model) into
                    this provider's request body + headers
      parseText     pull the model's raw text reply out of the decoded response
    Everything else -- the prompt, the image, fence-stripping, error handling --
    is shared. TO ADD A PROVIDER (e.g. Gemini): add one ADAPTERS entry and one
    MODELS entry. No other file changes.

  DESIGN NOTES
    * Models are pinned in MODELS below; edit those strings to use newer models.
      Both must be vision-capable.
    * STRENGTH is NOT scaled numerically in code -- it is passed to the model as a
      textual instruction and the model scales its own corrections. For hard
      numeric scaling, do it in AIEditDialog.applyEdits, not here.
    * Markdown code fences are stripped defensively before parsing.
    * base64 is implemented in pure Lua because the SDK has no native libs.
============================================================================]]

local LrHttp = import "LrHttp"

local json     = require "dkjson"
local Log      = require "Log"
local Settings = require "Settings"

local AIProvider = {}

-- Model pinned per provider. Update these strings to switch to newer models.
local MODELS = {
    anthropic = "claude-sonnet-4-6",
    openai    = "gpt-4o",
    ollama    = "qwen2.5vl:7b",
}

-- Per-provider adapters (see "HOW PROVIDERS WORK" above).
--   buildRequest(systemPrompt, userText, imgB64, apiKey, model) -> body, headers
--   parseText(parsedResponse) -> rawText  OR  nil, errorString
local ADAPTERS = {

    -- -- Anthropic (Claude): /v1/messages, x-api-key header, image as a
    --    base64 "source" block. ---------------------------------------------
    anthropic = {
        url = "https://api.anthropic.com/v1/messages",
        buildRequest = function(systemPrompt, userText, imgB64, apiKey, model)
            local body = json.encode({
                model      = model,
                max_tokens = 1024,
                system     = systemPrompt,
                messages   = {
                    {
                        role    = "user",
                        content = {
                            { type = "image",
                              source = { type = "base64", media_type = "image/jpeg", data = imgB64 } },
                            { type = "text", text = userText },
                        },
                    },
                },
            })
            local headers = {
                { field = "Content-Type",      value = "application/json" },
                { field = "x-api-key",         value = apiKey },
                { field = "anthropic-version", value = "2023-06-01" },
            }
            return body, headers
        end,
        parseText = function(parsed)
            if not (parsed.content and parsed.content[1] and parsed.content[1].text) then
                return nil, "Unexpected Anthropic response structure."
            end
            return parsed.content[1].text
        end,
    },

    -- -- OpenAI (ChatGPT): /v1/chat/completions, Bearer auth, image as a
    --    data: URI, JSON mode forced via response_format. -------------------
    openai = {
        url = "https://api.openai.com/v1/chat/completions",
        buildRequest = function(systemPrompt, userText, imgB64, apiKey, model)
            local body = json.encode({
                model       = model,
                max_tokens  = 1024,
                -- JSON mode guarantees a valid JSON object. It requires the word
                -- "json" to appear in the messages -- our prompt already does.
                response_format = { type = "json_object" },
                messages    = {
                    { role = "system", content = systemPrompt },
                    {
                        role    = "user",
                        content = {
                            { type = "text", text = userText },
                            { type = "image_url",
                              image_url = { url = "data:image/jpeg;base64," .. imgB64 } },
                        },
                    },
                },
            })
            local headers = {
                { field = "Content-Type",  value = "application/json" },
                { field = "Authorization", value = "Bearer " .. apiKey },
            }
            return body, headers
        end,
        parseText = function(parsed)
            if not (parsed.choices and parsed.choices[1]
                    and parsed.choices[1].message and parsed.choices[1].message.content) then
                return nil, "Unexpected OpenAI response structure."
            end
            return parsed.choices[1].message.content
        end,
    },

    -- -- Ollama (local): native /api/chat endpoint (NOT the OpenAI-compat layer).
    --
    --    WHY NOT /v1/chat/completions:
    --      The OpenAI-compat endpoint silently ignores the "options" block, so
    --      num_predict and num_ctx cannot be raised. Ollama's default num_ctx is
    --      2048 tokens (input + output combined). Our request body (image +
    --      system prompt) already consumes most of that, leaving almost no room
    --      for output -- hence the truncated JSON. The native endpoint passes
    --      options through reliably.
    --
    --    WHY smallImgB64 (not imgB64):
    --      The 1024px thumbnail base64-encodes to ~350KB ~ 25 000 tokens.
    --      Even with num_ctx=8192 that would overflow the context window before
    --      a single output token is written. The 400px thumbnail (~90KB ~ 6 000
    --      tokens) fits comfortably and is more than enough for a 7B vision model.
    --      Cloud providers (Anthropic/OpenAI) use the full 1024px image; only
    --      the Ollama adapter uses the smaller one.
    --
    --    apiKey is ignored (Ollama has no auth).
    ollama = {
        url = "http://localhost:11434/api/chat",
        -- smallImgB64: base64 of the 400px thumbnail (passed from analysePhoto).
        -- imgB64 (1024px) is intentionally NOT used here -- see WHY above.
        buildRequest = function(systemPrompt, userText, imgB64, apiKey, model, smallImgB64)
            local imageData = smallImgB64 or imgB64   -- fall back to large if small absent
            local body = json.encode({
                model  = model,
                stream = false,   -- get a single complete response, not an SSE stream
                options = {
                    num_ctx     = 8192,   -- context window: input + output tokens
                    num_predict = 4096,   -- max output tokens (was silently ~200 before)
                },
                messages = {
                    { role = "system", content = systemPrompt },
                    {
                        role    = "user",
                        -- Ollama native multimodal: images go in a top-level "images"
                        -- array on the message, NOT as content blocks. The content
                        -- array carries only the text part.
                        content = userText,
                        images  = { imageData },
                    },
                },
            })
            local headers = {
                { field = "Content-Type", value = "application/json" },
            }
            return body, headers
        end,
        parseText = function(parsed)
            -- Native /api/chat response: { message: { role, content }, done: true, ... }
            -- (different from OpenAI-compat choices[0].message.content)
            if not (parsed.message and parsed.message.content) then
                return nil, "Unexpected Ollama response structure."
            end
            return parsed.message.content
        end,
    },
}

-- -- Pure-Lua base64 encoder ---------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(data)
    local result = {}
    local len    = #data

    for i = 1, len - 2, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + b * 256 + c
        result[#result + 1] = B64:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
        result[#result + 1] = B64:sub(math.floor(n /   4096) % 64 + 1, math.floor(n /   4096) % 64 + 1)
        result[#result + 1] = B64:sub(math.floor(n /     64) % 64 + 1, math.floor(n /     64) % 64 + 1)
        result[#result + 1] = B64:sub(                n % 64 + 1,                 n % 64 + 1)
    end

    local rem = len % 3
    if rem == 1 then
        local a = data:byte(len)
        local n = a * 65536
        result[#result + 1] = B64:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
        result[#result + 1] = B64:sub(math.floor(n /   4096) % 64 + 1, math.floor(n /   4096) % 64 + 1)
        result[#result + 1] = "=="
    elseif rem == 2 then
        local a, b = data:byte(len - 1, len)
        local n = a * 65536 + b * 256
        result[#result + 1] = B64:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
        result[#result + 1] = B64:sub(math.floor(n /   4096) % 64 + 1, math.floor(n /   4096) % 64 + 1)
        result[#result + 1] = B64:sub(math.floor(n /     64) % 64 + 1, math.floor(n /     64) % 64 + 1)
        result[#result + 1] = "="
    end

    return table.concat(result)
end

-- -- Read binary file ----------------------------------------------------------
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*all")
    f:close()
    return data
end

-- -- Main API call -------------------------------------------------------------
--[[
  analysePhoto:
    thumbPath    - path to a JPEG thumbnail
    stylePrompt  - user style/mood string (may be empty)
    metadata     - table: { filename, iso, aperture, shutterSpeed, focalLength, ... }
    histogramStr - measured histogram summary string (may be nil)
    strength     - 0..200; sent to the model as guidance (NOT scaled in code)
  Returns:
    true,  edits table   on success
    false, error string  on failure
  The provider (Anthropic / OpenAI) is read from Settings; only the request
  shape and reply-extraction differ between them -- see ADAPTERS above.
]]
-- smallThumbPath: optional path to a smaller thumbnail (used by Ollama to keep
-- the request within its context window; cloud providers use the full thumbPath).
function AIProvider.analysePhoto(thumbPath, smallThumbPath, stylePrompt, metadata, histogramStr, strength)
    local provider = Settings.getProvider()
    local adapter  = ADAPTERS[provider]
    local model    = MODELS[provider]
    Log.write("AIProvider.analysePhoto: start (provider=" .. tostring(provider)
              .. ", model=" .. tostring(model) .. ")")
    if not adapter then
        return false, "Unknown AI provider: " .. tostring(provider)
    end

    local apiKey = Settings.getApiKey(provider)
    if provider ~= "ollama" and (not apiKey or apiKey == "") then
        return false, "No API key set for " .. provider .. ". Enter it in the dialog."
    end

    local imgData = readFile(thumbPath)
    if not imgData then
        return false, "Could not read thumbnail file: " .. tostring(thumbPath)
    end
    local imgB64 = base64Encode(imgData)

    -- Encode the small thumbnail for providers that need a smaller image.
    -- Currently only Ollama uses this -- its context window cannot fit the 1024px image.
    local smallImgB64 = nil
    if smallThumbPath then
        local smallData = readFile(smallThumbPath)
        if smallData then
            smallImgB64 = base64Encode(smallData)
            Log.write("AIProvider: small thumb encoded (" .. #smallData .. " bytes, b64=" .. #smallImgB64 .. ")")
        end
    end

    -- System prompt
    local systemPrompt = [[You are an expert photo retoucher producing Adobe Lightroom develop settings. You receive (1) a rendered JPEG preview, (2) shooting metadata, and (3) MEASURED HISTOGRAM STATISTICS computed from the preview. Use each input for what it is good at: the CLIPPING/headroom numbers are objective ground truth -- trust them over the 8-bit preview, because bright-but-recoverable areas look identical to truly clipped ones. For SUBJECT BRIGHTNESS, combine the measured subject signal with what you can SEE in the image, following the EXPOSURE RULE below -- do not blindly raise exposure because a number says "dark".

OUTPUT: ONLY a valid JSON object. No prose, no markdown, no code fences -- raw JSON only. Every numeric field MUST be an actual number (e.g. 0, -15, 5400). NEVER write a word, placeholder, or null for a numeric field -- do not output DEFAULT, AUTO, none, or similar. If you do not want to change a setting, use 0 (for ColorTempKelvin use a real Kelvin number such as 5500).

EXPOSURE RULE (read carefully before choosing Exposure -- the numbers and your eyes have different jobs):
1. SUBJECT brightness: when a SKIN-TONE luminance is given, that is the real subject brightness no matter where the subject sits in the frame -- use it as the primary signal. Aim the subject to roughly 48-58% of full scale (about 122-148 on 0-255) for a natural portrait; outdoor/ambient portraits look best nearer the lower half of that.
2. The CENTER-patch number is valid ONLY when the histogram says it contains the subject. If it is flagged as reading BACKGROUND (center ~ frame mean), IGNORE it -- never raise Exposure on its account.
3. CROSS-CHECK every exposure decision against the visible image:
   * numbers say "dark" BUT the visible face looks well exposed -> metering is sampling background; trust your eyes, keep Exposure within +/-0.3.
   * numbers say "dark" AND the visible face also looks dark -> genuinely underexposed; raise Exposure (typically +0.5 to +1.5).
   * visible face looks bright/hot, or skin luminance is above ~65% -> reduce Exposure.
4. BE CONSERVATIVE BY DEFAULT: typical Exposure moves are within +/-0.5 EV. Exceed that only when BOTH the subject number and the visible face agree the subject is clearly mis-exposed. Making a large +EV move on the strength of the center or whole-frame number alone is the #1 failure mode -- it blows out an already well-exposed off-center face. Do not do it.
5. CLIPPING is the one place the numbers override your eyes: if highlight clipping is significant, recover highlights (see discipline below) even if the preview looks fine.

DARK-BACKDROP PORTRAITS (CRITICAL -- applies when the subject is much brighter than the whole-frame/background average, i.e. a person on a dark studio backdrop):
- Brighten the SUBJECT using Exposure, NOT large Shadow/Black lifts. Exposure raises the whole image but the dark backdrop has little detail to reveal, so it stays dark; big Shadow/Black lifts instead haul the backdrop up into a flat, milky grey and destroy the depth. This is the #1 failure mode -- avoid it.
- Keep Shadows modest (roughly +10 to +40, not +60 to +80) and Blacks near 0 (about -5 to +10, never large positive). The goal is a clean, deep, dark background.
- PROTECT BACKGROUND COLOR: when the background is a neutral/dark studio backdrop (e.g. black, grey, or dark blue), be conservative with white-balance moves. Over-correcting a warm cast can tint a dark blue/neutral backdrop green or muddy. Make only the white-balance change needed to neutralize skin tones; do not chase a perfectly neutral whole-frame average. If unsure, keep Temp/Tint changes small.
- Result to aim for: a well-lit subject against a background that remains its original dark color, with real blacks intact.

HIGHLIGHT / EXPOSURE DISCIPLINE:
- If highlight clipping is above ~2%, pull Highlights strongly negative (typically -50 to -100) and usually Whites negative too (-10 to -60). Do NOT add positive Exposure when the SUBJECT highlights are already clipping.
- For high-key scenes (bright subject, bright skin or light/blond hair, backlight), bias toward recovery: negative Highlights, negative Whites, lift Shadows/Blacks to rebalance, Exposure near 0 or slightly negative.
- The source is often a RAW file with real highlight/shadow headroom, so recovery adjustments are effective -- be decisive, not timid, but never at the cost of flattening an intentionally dark background.
- Never darken a frame whose subject is already underexposed.

Required keys (all numeric except "reasoning"):
Exposure (-5 to +5 stops), Contrast (-100 to 100), Highlights (-100 to 100), Shadows (-100 to 100),
Whites (-100 to 100), Blacks (-100 to 100), Texture (-100 to 100), Clarity (-100 to 100), Dehaze (-100 to 100),
Vibrance (-100 to 100), Saturation (-100 to 100), ColorTempKelvin (2000-50000), Tint (-150 to 150),
HueRed, HueOrange, HueYellow, HueGreen, HueAqua, HueBlue, HuePurple, HueMagenta (each -100 to 100),
SatRed, SatOrange, SatYellow, SatGreen, SatAqua, SatBlue, SatPurple, SatMagenta (each -100 to 100),
LumRed, LumOrange, LumYellow, LumGreen, LumAqua, LumBlue, LumPurple, LumMagenta (each -100 to 100),
VignetteAmount (-100 to 100), GrainAmount (0 to 100), Sharpness (0 to 150), NoiseReduction (0 to 100),
reasoning (string, 1-2 sentences; mention how the histogram drove your highlight/shadow decisions).]]

    -- User message
    local metaStr = string.format(
        "File: %s | Type: %s | Camera: %s | Lens: %s\nISO: %s | Aperture: f/%s | Shutter: %s | Focal length: %smm | Exp.bias: %s | Flash: %s",
        tostring(metadata.filename     or "unknown"),
        tostring(metadata.fileType     or "?"),
        tostring(metadata.camera       or "?"),
        tostring(metadata.lens         or "?"),
        tostring(metadata.iso          or "?"),
        tostring(metadata.aperture     or "?"),
        tostring(metadata.shutterSpeed or "?"),
        tostring(metadata.focalLength  or "?"),
        tostring(metadata.exposureBias or "?"),
        tostring(metadata.flash        or "?")
    )

    local parts = { metaStr }
    -- File-type calibration hint
    if metadata.fileType and tostring(metadata.fileType):lower():find("raw") then
        parts[#parts + 1] = "This is a RAW file: it has substantial highlight and shadow headroom beyond what the preview shows, so recovery adjustments are safe and effective."
    elseif metadata.fileType then
        parts[#parts + 1] = "This is a non-RAW (e.g. JPEG) file: less headroom, so be more conservative with strong highlight/shadow recovery to avoid banding."
    end
    if histogramStr and histogramStr ~= "" then
        parts[#parts + 1] = histogramStr
    end
    if strength and strength ~= 100 then
        parts[#parts + 1] = string.format(
            "Adjustment strength: %d%% (scale the intensity of your corrections accordingly; 100%% is normal).",
            strength)
    end
    if stylePrompt and stylePrompt ~= "" then
        parts[#parts + 1] = "Style instruction: " .. stylePrompt
    else
        parts[#parts + 1] = "No style specified -- optimise naturally for a clean, well-balanced result."
    end
    parts[#parts + 1] = "Return the JSON adjustment object."
    local userText = table.concat(parts, "\n")

    -- Build the provider-specific request, then POST it.
    local bodyStr, headers = adapter.buildRequest(systemPrompt, userText, imgB64, apiKey, model, smallImgB64)
    Log.write("AIProvider: request body length=" .. tostring(#bodyStr))
    Log.write("AIProvider: POST " .. adapter.url)
    local response = LrHttp.post(adapter.url, bodyStr, headers)
    Log.write("AIProvider: response length=" .. tostring(response and #response or "nil"))

    if not response then
        return false, "HTTP request failed. Check your internet connection and API key."
    end

    -- Decode the outer JSON envelope.
    local parsed, _, parseErr = json.decode(response)
    if not parsed then
        return false, "Could not parse API response: " .. tostring(parseErr) .. "\n\nRaw: " .. response:sub(1, 200)
    end
    -- Both Anthropic and OpenAI report failures under parsed.error.message.
    if parsed.error then
        local e = parsed.error
        return false, "API error: " .. tostring(e.message or e.type or "unknown")
    end

    -- Extract the model's text reply (shape differs per provider).
    local rawText, textErr = adapter.parseText(parsed)
    if not rawText then
        return false, textErr or "Could not read model reply."
    end

    -- Models (especially local ones) sometimes wrap the JSON in a markdown
    -- fence or surrounding prose, and may even omit the *closing* fence -- which
    -- defeats fence-pair matching. Rather than depend on matched fences, extract
    -- the JSON object directly: everything from the first "{" to the last "}".
    local jsonText   = rawText
    local braceStart = rawText:find("{")
    local braceEnd   = select(2, rawText:find(".*}"))   -- index of the last "}"
    if braceStart and braceEnd and braceEnd >= braceStart then
        jsonText = rawText:sub(braceStart, braceEnd)
    end

    local edits, _, editErr = json.decode(jsonText)

    -- Fallback for non-compliant local models: some emit a bare placeholder
    -- (DEFAULT, AUTO, none, null, NaN) where a number belongs -- invalid JSON that
    -- fails the whole edit. Only on the failure path (so well-formed responses are
    -- never altered), replace any such value-position token with 0 and retry once.
    if not edits then
        local repaired = jsonText:gsub('(:%s*)(%a+)(%s*[,}])', function(pre, word, post)
            local w = word:lower()
            if w == "default" or w == "auto" or w == "none"
               or w == "null" or w == "nan" or w == "na" then
                return pre .. "0" .. post
            end
            return pre .. word .. post   -- leave true/false and anything else intact
        end)
        local retried, _, retryErr = json.decode(repaired)
        if retried then
            edits, jsonText, editErr = retried, repaired, nil
        end
    end
    if not edits or type(edits) ~= "table" then
        return false, "Model returned invalid JSON: " .. tostring(editErr) .. "\n\nRaw: " .. jsonText:sub(1, 300)
    end

    return true, edits
end

return AIProvider
