# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions use the plugin's
`Info.lua` version number.

## [1.5.0]

### Fixed
- **Ollama JSON truncation.** The Ollama adapter previously used the
  OpenAI-compatible `/v1/chat/completions` endpoint, which silently ignores the
  `options` block -- so `num_predict` and `num_ctx` could not be raised above
  Ollama's built-in defaults (effectively ~200 output tokens). The model's
  response was cut off mid-key (e.g. stopping at `"Hue...`), causing a
  "Model returned invalid JSON" error on every Ollama run.

### Changed
- **Ollama adapter switched to native `/api/chat` endpoint.** The native
  endpoint respects the `options` block; `num_ctx = 8192` and
  `num_predict = 4096` are now sent, giving the model a full context window and
  enough room to complete the JSON output. Anthropic and OpenAI are unchanged.
- **Ollama uses the 400px thumbnail instead of 1024px.** The 1024px thumbnail
  base64-encodes to ~350 KB (~25 000 tokens), which overflows an 8192-token
  context window before a single output token is written. The 400px thumbnail
  (~90 KB, ~6 000 tokens) fits comfortably and is sufficient for a 7B vision
  model. Cloud providers (Anthropic/OpenAI) continue to receive the 1024px image.
- **All non-ASCII characters removed from `AIProvider.lua`.** Lightroom's
  embedded Lua 5.1 interpreter rejects non-ASCII bytes anywhere in a source
  file -- including inside comments and long strings. Em-dashes, arrows,
  bullets, and box-drawing characters have been replaced with ASCII equivalents.

## [1.4.0]

### Added
- **Ollama (local) provider.** Run a local vision model via Ollama's
  OpenAI-compatible endpoint (`http://localhost:11434/v1/chat/completions`),
  no API key required. Selectable in the dialog; the key field is hidden and the
  endpoint is shown as read-only info. Default model `qwen2.5vl:7b` (edit the
  `MODELS` table to change it). Anthropic and OpenAI are unchanged.

### Changed
- **More robust JSON extraction.** The reply parser now extracts the JSON object
  directly (first `{` to last `}`) instead of relying on matched markdown fence
  pairs -- local models sometimes wrap output in a fence and omit the closing one.
- Ollama requests use a higher `max_tokens` ceiling (2048) since local models can
  be more verbose; cloud providers are unchanged.

## [1.3.1]

### Fixed
- **"Revert to Original" did nothing.** The previous approach relied on an
  empty-settings-table reset, which is a no-op in the Lightroom SDK. Revert now
  restores the saved pre-edit snapshot.
- **"Assertion failed: packed" on revert.** Revert (and the preview Revert
  button) now restore only the develop keys the plugin actually writes, instead
  of the whole `getDevelopSettings()` blob -- which carries string-encoded
  mask/retouch data that cannot be re-applied.

### Changed
- Provider-neutral plugin name and dialog subtitle.
- Removed the website link from the Plug-in Manager page.

## [1.3.0]

### Added
- **Skin-tone subject metering.** The histogram classifies skin pixels (YCbCr)
  and reports their luminance as the primary subject-brightness signal, so
  exposure targets the actual face regardless of composition.
- **Metering-reliability flag.** When the center patch ~ the frame average it is
  flagged as background and excluded from the exposure decision.
- **Exposure fusion.** Clipping numbers are authoritative; subject brightness
  comes from skin metering cross-checked against the visible image; exposure
  stays within +/-0.5 EV unless both signals agree on more. Natural target band
  lowered to ~48-58%. Removes over-brightening of well-lit, off-center faces.

## [1.2.0]

### Added
- **Multiple AI providers** -- Anthropic Claude or OpenAI ChatGPT, chosen from a
  dropdown, with API keys stored separately per provider.
- Provider-aware dialog (key label/hint follow the selection; both persist).

### Changed
- Renamed the API module `ClaudeAPI.lua` -> `AIProvider.lua` and built a clean
  adapter layer so adding another provider is a one-entry change.

## [1.1.0]

### Added
- Visual preview with rendered image, adjustment list, reasoning, and Keep/Revert.
- Named presets, last-used recall, per-photo metadata context.
- Dark-backdrop prompt protection.
- Detailed step-by-step logging.

### Changed
- True-reset revert (later reworked in 1.3.1).
- All-scalar snapshots (fixes an earlier "packed" assertion on snapshot).
- Feedback loop changed to diagnostic-only logging after the post-edit
  re-measure proved unreliable (stale previews).

## [1.0.0]

### Added
- Initial release: send a photo to Claude, apply returned develop settings in
  Lightroom Classic. Pure-Lua JPEG decoder + histogram, bundled `dkjson`.
