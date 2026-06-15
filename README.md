# AI Edit for Lightroom Classic

An Adobe Lightroom **Classic** plugin that sends a photo to an AI model (Anthropic Claude or OpenAI ChatGPT), gets back a full set of develop adjustments tailored to that image, and applies them — with a visual preview, presets, batch editing, and one‑click revert.

It is built for portraits and tuned to get the **subject** correctly exposed without wrecking the background, using skin‑tone metering rather than naive frame‑average brightness. Everything runs locally inside Lightroom; the only network call is the single HTTPS request to the provider you choose, using your own API key.

> **Lightroom Classic only.** The cloud "Lightroom" app has no plugin SDK. Windows and macOS are both supported.

> [!NOTE]
> **Disclaimer: this plugin was "vibe coded."** It was built collaboratively with an AI assistant, iterating by feel and testing as we went, rather than through a formal engineering process. It has been exercised across its features and works — but it has not been through rigorous QA, and it talks to paid third‑party APIs and writes to your Lightroom catalog. Use it at your own risk, keep backups of anything you care about, and treat the AI's edits as a starting point. PRs and bug reports welcome.
📖 **Documentation:** https://farbener.github.io/AIEdit/AIEdit-Documentation.html

---

## Features

- **Two AI providers, switchable in the dialog** — Anthropic Claude (`claude-sonnet-4-6`) or OpenAI ChatGPT (`gpt-4o`). API keys are stored separately per provider, so you can keep both.
- **Subject‑aware exposure** — a pure‑Lua histogram classifies skin‑tone pixels and meters the actual face, regardless of where it sits in the frame. Clipping data is treated as authoritative; the center patch is a flagged fallback. The result: off‑center faces are no longer blown out.
- **Visual preview** — see the rendered edit plus the model's adjustment list and reasoning, then **Keep** or **Revert** (single‑photo).
- **Non‑destructive, true revert** — "Revert to Original" restores the photo to its pre‑edit state. All edits are ordinary Lightroom develop settings.
- **Presets** — save a style + strength recipe and reapply it from a dropdown.
- **Batch editing** — select many photos and apply in one run, each metered individually.
- **Per‑photo context** — camera, lens, ISO, and RAW‑vs‑JPEG headroom are sent to the model so recovery decisions are sensible.
- **No heavy dependencies** — a from‑scratch pure‑Lua baseline JPEG decoder and histogram; the only bundled library is `dkjson` for JSON.

---

## Requirements

- **Adobe Lightroom Classic** (SDK 6.0+, i.e. any recent version) on Windows or macOS.
- An API key for at least one provider:
  - **Anthropic** — <https://console.anthropic.com> → API Keys
  - **OpenAI** — <https://platform.openai.com> → API keys
- **API usage costs money.** You pay your provider per request with your own key. A single edit sends one downsized JPEG plus a short text prompt, so cost per photo is small, but it is not zero. Both providers require active billing/credit before the API will respond.

---

## Installation

1. Download the latest release (or clone this repo).
2. You should have a folder named **`AIEdit.lrdevplugin`**. Put it somewhere permanent (not your Downloads folder).
3. In Lightroom Classic: **File → Plug‑in Manager… → Add**, select the `AIEdit.lrdevplugin` folder, then **Done**.
4. Select a photo, run **Library → Plug‑in Extras → AI Edit Selected Photo…**, choose your provider, and paste your API key (it's saved automatically).

---

## Usage

**Edit a photo**

1. Select one or more photos in the Library grid.
2. **Library → Plug‑in Extras → AI Edit Selected Photo…**
3. Choose your **AI provider**, optionally type a **style instruction** (e.g. `warm golden tones`), set **strength** (100% = normal), and keep **Preview** on for single photos.
4. **Analyse & Apply**, review the preview, then **Keep** or **Revert**.

**Revert a photo**

- **Library → Plug‑in Extras → AI Edit: Revert to Original** returns the selected photo(s) to the pre‑edit state.

**Presets**

- Set a style + strength, click **Save current as preset…**, name it. It then appears in the Preset dropdown on future runs.

---

## How it works

For each photo the plugin renders two JPEG thumbnails, decodes one in pure Lua to compute a histogram, and sends the image + histogram + metadata + your style note to the chosen provider. The model returns a JSON object of develop adjustments, which the plugin maps to Lightroom develop keys and applies in one write (after snapshotting the prior state for revert).

The exposure logic deliberately combines signals rather than trusting one number:

- **Clipping / headroom numbers are authoritative** (an 8‑bit preview hides recoverable detail).
- **Skin‑tone luminance is the primary subject signal**, found by classifying pixels in YCbCr — so a grey sweater or green foliage isn't mistaken for the subject.
- **The center patch is a fallback hint**, flagged as unreliable when it merely matches the frame average (i.e. it's reading background).

This is what stops an already well‑lit, off‑center face from being over‑brightened.

A full documentation site is included at [`docs/AIEdit-Documentation.html`](docs/AIEdit-Documentation.html) (open it in any browser).

---

## Configuration

- **Models** are pinned per provider in `AIEdit.lrdevplugin/AIProvider.lua` (the `MODELS` table). Edit those strings to use a different/newer model. Both must be vision‑capable.
- **Adding another provider** (e.g. Gemini) is a single entry in the `ADAPTERS` table plus one `MODELS` line — no other file changes.
- **Plugin identifier** is `io.github.farbener.aiedit` (`Info.lua`). If you fork and redistribute, use your own (e.g. `io.github.<you>.aiedit`). Choose it **before** distributing — changing it later orphans users' saved keys and presets.

---

## Privacy & security

- Your API key is stored locally in Lightroom's per‑plugin preferences and is sent only to the provider you select. It is never written to the debug log.
- Each edit uploads a downsized JPEG of the photo plus a short text prompt to the chosen provider's API. Review the provider's data‑use policy if that matters to you.
- The debug log (`<Documents>/AIEdit_debug.log`) records steps for troubleshooting; it does not contain your key. It does contain local file paths, so scrub it before sharing publicly.

---

## Limitations

- **Lightroom Classic only** — no SDK exists for the cloud app.
- Visual **preview is single‑photo**; batches apply directly with a summary.
- A **reverted RAW** matches Lightroom's neutral render, not the camera's JPEG — set Develop → Profile to "Camera Standard" to close the gap.
- The system prompt was tuned with Claude; **OpenAI may need minor prompt re‑tuning** to match exposure discipline exactly.
- The SDK can't add toolbar/filmstrip buttons — commands live in the Library menu.

---

## Troubleshooting

Open `<Documents>/AIEdit_debug.log` — it records every step (histogram readings, the model's proposal, applied settings). The bundled documentation has a full troubleshooting section. Common cases:

- **"API error: …"** — check the key for the selected provider and confirm billing/credit is active.
- **Edit looks too bright/dark** — check the `Histogram:` log line; `skinLum` should match how bright the face actually looks.
- **Reverted RAW looks flat** — expected; it's the neutral profile, not a bug (see Limitations).

---

## Contributing

Issues and pull requests are welcome. The code is plain Lua against the Lightroom SDK (Lua 5.1 — no `goto`, no native libraries). Each file has a single responsibility and a header docblock explaining its contract and any SDK gotchas. Please keep that style.

---

## License

Released under the [MIT License](LICENSE).

Bundles [`dkjson`](http://dkolf.de/src/dkjson-lua.fsl/) by David Kolf, used under its own permissive license (see the header of `dkjson.lua`).

---

## Acknowledgements

Built on the Adobe Lightroom Classic SDK and the Anthropic and OpenAI APIs.
