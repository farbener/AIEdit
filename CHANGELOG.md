# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions use the plugin's
`Info.lua` version number.

## [1.3.1]

### Fixed
- **"Revert to Original" did nothing.** The previous approach relied on an
  empty‑settings‑table reset, which is a no‑op in the Lightroom SDK. Revert now
  restores the saved pre‑edit snapshot.
- **"Assertion failed: packed" on revert.** Revert (and the preview Revert
  button) now restore only the develop keys the plugin actually writes, instead
  of the whole `getDevelopSettings()` blob — which carries string‑encoded
  mask/retouch data that cannot be re‑applied.

### Changed
- Provider‑neutral plugin name and dialog subtitle.
- Removed the website link from the Plug‑in Manager page.

## [1.3.0]

### Added
- **Skin‑tone subject metering.** The histogram classifies skin pixels (YCbCr)
  and reports their luminance as the primary subject‑brightness signal, so
  exposure targets the actual face regardless of composition.
- **Metering‑reliability flag.** When the center patch ≈ the frame average it is
  flagged as background and excluded from the exposure decision.
- **Exposure fusion.** Clipping numbers are authoritative; subject brightness
  comes from skin metering cross‑checked against the visible image; exposure
  stays within ±0.5 EV unless both signals agree on more. Natural target band
  lowered to ~48–58%. Removes over‑brightening of well‑lit, off‑center faces.

## [1.2.0]

### Added
- **Multiple AI providers** — Anthropic Claude or OpenAI ChatGPT, chosen from a
  dropdown, with API keys stored separately per provider.
- Provider‑aware dialog (key label/hint follow the selection; both persist).

### Changed
- Renamed the API module `ClaudeAPI.lua` → `AIProvider.lua` and built a clean
  adapter layer so adding another provider is a one‑entry change.

## [1.1.0]

### Added
- Visual preview with rendered image, adjustment list, reasoning, and Keep/Revert.
- Named presets, last‑used recall, per‑photo metadata context.
- Dark‑backdrop prompt protection.
- Detailed step‑by‑step logging.

### Changed
- True‑reset revert (later reworked in 1.3.1).
- All‑scalar snapshots (fixes an earlier "packed" assertion on snapshot).
- Feedback loop changed to diagnostic‑only logging after the post‑edit
  re‑measure proved unreliable (stale previews).

## [1.0.0]

### Added
- Initial release: send a photo to Claude, apply returned develop settings in
  Lightroom Classic. Pure‑Lua JPEG decoder + histogram, bundled `dkjson`.
