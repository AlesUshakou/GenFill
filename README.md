# GenFill — Generative Fill for Nuke

Photoshop's Generative Fill, built into a Nuke node. Select an area, type what you want (or
leave the prompt empty to remove what's there), click **Generate**, then pick from the
variations. Your plate never leaves the colour-managed comp. No more round trips through
Photoshop.

![node](nuke/icons/GenFill.png)

## What it does (v0.1)

| Photoshop | GenFill in Nuke |
|---|---|
| Make a selection (lasso / marquee) | **✏ Draw Selection** right in the node's panel: Roto shapes drawn on the node itself, with the shape list under the prompt bar (or use any matte in the Mask input, or the Source alpha) |
| Contextual task bar: prompt + **Generate** | The same bar at the top of the node's properties. Enter generates. |
| Empty prompt = remove and fill from surroundings | Same. With Stability AI this uses their dedicated *Erase* model. |
| 3 variations per generation, browse with ‹ › | Same: thumbnail grid of every generation (newest first), ‹ 1/6 › arrows, right-click to reuse a prompt, reveal or delete |
| Generative layer with a layer mask | Output **Comp** (fill blended over the plate through the expanded, feathered selection) or **Layer** (just the fill, in the plate's format, premultiplied by that selection, with alpha) |
| Model picker | **Stability AI** (inpaint / erase), **OpenAI GPT Image**, or **Offline Preview** (no AI; tests the pipeline for free) |

What makes it work as a Nuke node:

- **Colour managed.** The crop goes out as 8-bit sRGB (the project's 8-bit file colourspace,
  so OCIO/ACES configs just work) and comes back through the exact inverse. Only pixels inside
  the selection are replaced, so the rest of the plate stays bit-for-bit untouched.
- **Context crop like Photoshop.** It doesn't send the whole frame. It sends the selection
  plus a band of context, resized to what the model wants, at a matching aspect ratio so
  nothing gets stretched.
- **Farm-safe.** Everything inside the Group is a native Nuke node. Once you've picked a
  variation, the script renders anywhere, even with the plugin not installed.
- **Keys stay out of scripts.** API keys come from environment variables or
  `~/.nuke/genfill/config.json`. They're never written to the .nk.

## Install

Double-click **`installers\install.bat`**. It runs the tests, copies the current build to
`%USERPROFILE%\.nuke\plugins\GenFill`, stamps it with the version and git commit, and adds a
managed block to your `.nuke\init.py`. Run it again whenever you want to test the latest
code. See [installers/README.md](installers/README.md) for the details, dev mode and uninstall.

Then:

1. Start Nuke. You'll find **GenFill > Generative Fill** in the Nodes toolbar, or Tab-search
   "Generative Fill". The Script Editor prints which build loaded.
2. Set an API key: **GenFill > API Keys...** or the node's *Settings* tab. Alternatively set
   `STABILITY_API_KEY` / `OPENAI_API_KEY` in your environment.
3. For the free local model: **GenFill > Local AI > Install / Repair...** (one-time, ~25 GB,
   runs in the background).
4. Optional: **GenFill > Developer > Run Smoke Test** checks the build end to end with the
   offline backend and writes a report to `test_output\`.

Supported: Nuke 13 to 16+ (Python 3, PySide2 or PySide6). The installer is Windows-only for
now; on macOS/Linux add the repo's `nuke` folder to `NUKE_PATH`.

## Use

1. Select your plate and create **Generative Fill**, and view it.
2. Click **✏ Draw Selection** and draw around what you want to replace in the Viewer. The shapes
   belong to the node; edit, toggle or animate them from the shape list in the same panel.
   (Prefer your own matte? Connect it to the Mask input and *selection from* switches to it.)
3. In the GenerativeFill panel, type a prompt (*"a weathered wooden bench"*), or leave it
   empty to remove the object. Press **Generate**.
4. Click thumbnails or use ‹ › to choose a variation. Generate again to add more.
5. Tweak **expand** / **feather** to blend, and set **output** to *Comp* or *Layer*.

The fill is generated on the current frame and held. The *reference frame* on the Settings tab
shows which frame a variation came from.

### Settings tab

| Knob | Meaning |
|---|---|
| model | Generator backend |
| model version | Optional override, e.g. `gpt-image-1.5` (empty = backend default) |
| quality | OpenAI quality level |
| variations | Variations per click (default 3, like Photoshop) |
| seed | 0 = new random seed each click |
| negative prompt | Things to avoid (Stability) |
| context | How much surrounding image to send, as a fraction of the selection size |
| min region | Smallest crop sent, in plate pixels (default 512) |
| 8-bit colorspace | Colourspace for the round trip. `default` = the project's 8-bit setting |
| cache folder | Where results are stored. Empty = `<script folder>/genfill_cache/<node id>` |

### Backends

| Backend | Good at | Notes |
|---|---|---|
| **Local: FLUX.1 Fill** | Free, offline, no tokens. Strong fill quality; LaMa for clean removal | Runs on your NVIDIA GPU inside the plugin (a hidden helper, no windows). Install from **GenFill > Local AI > Install** (~25 GB). FLUX.1 [dev] licence: **non-commercial** |
| Stability AI | True masked inpainting; best at *removal* (empty prompt → Erase model) | Cloud, paid. ~1 MP per request, one request per variation |
| OpenAI GPT Image | Prompt following, adding objects | Cloud, paid. Re-renders the crop, which we composite back through the mask |
| Offline Preview | Testing the pipeline, no network | Smears surrounding colour into the selection; not AI |

> **Data note:** cloud backends upload the crop (not the whole frame) to that provider. Check
> your client / TPN rules before using them on production plates. The Local model never sends anything off
> your machine.

## Color pipeline

Image models only understand display-style values in 0..1, and nothing they generate goes above
1.0. GenFill keeps your plate's range by **encoding** it into a space where it fits, letting the
model work there, and decoding the result with the exact inverse. Choose on the Settings tab
(**color pipeline**):

| Mode | What the model sees | Use for |
|---|---|---|
| **Auto (match input)** (default) | Display-referred plates (PNG/JPG in matte_paint / sRGB, log plates like LogC): the plate's own colorspace, i.e. the original file values. Scene-linear plates (EXR, ACEScg): the display transform. | Almost everything |
| **Display transform** | Your show's output transform, e.g. ACES **Output - Rec.709** (auto-detected, or set *display colorspace*). Its tone curve rolls highlights into 0..1 so the model sees a natural picture; Nuke's inverse brings them back. | Scene-linear plates with highlights |
| **Log (ACEScct)** | ACEScct (pure maths, no OCIO needed). 0..1 covers scene-linear up to ~222. Flatter look for the model. | Configs without an output transform; maximum headroom |
| **Input colorspace** | Always the Read's colorspace. | Forcing the plate's own encoding |
| **Custom** | Any OCIO colorspace you type. | Anything else |

**Bit depth:** the local model gets a **32-bit float TIFF** and returns the model's raw float
output, so nothing is rounded to 8 bits on the way in or out. That matters most for the inverse
display transform, which stretches the top of the range and would band with 8-bit files. Cloud
models only accept 8-bit PNG; they use the same encoding, just quantised.

Each variation remembers the encoding it was made with, so switching modes never breaks older
variations. The Script Editor / log shows the decision, e.g.
`color: plate Read Read1 (colorspace 'ACES - ACEScg', .exr) -> display: Output - Rec.709`.

## Privacy and security

**Local: FLUX.1 Fill runs entirely on your machine.** The crop, mask, prompt and results go
from Nuke to the hidden helper process over a private pipe and are processed on your GPU. The
helper makes no network connections: it is started with Hugging Face's offline mode on and
telemetry off, and only reads model files from `%USERPROFILE%\GenFill-LocalAI`. You can confirm
this by blocking `GenFill-LocalAI\python\...\python.exe` in Windows Firewall; generation keeps
working.

Network is used only by the **installer**, and only to download: uv (GitHub), Python packages
(PyPI and the official PyTorch index) and the model files (Hugging Face, GitHub). Nothing about
your images or prompts is sent.

**Cloud models (Stability AI, OpenAI) are different:** the crop around your selection and the
prompt are uploaded to that company. Use them only when your client allows it.

**Where your data ends up on disk:**

| What | Where |
|---|---|
| Crops, masks, generated variations | `genfill_cache\` next to the saved script (or `%TEMP%\genfill_cache` if unsaved). If your scripts live in OneDrive/Dropbox, this folder syncs with them; set **cache folder** on the Settings tab to keep it local. |
| GenFill log (includes prompts) | `test_output\genfill.log` in the repo when installed from it, else `~\.nuke\genfill\genfill.log` |
| Helper / installer logs | `%USERPROFILE%\GenFill-LocalAI\logs\` |
| API keys (cloud models only) | `~\.nuke\genfill\config.json`, never in .nk scripts |

## Roadmap

- **HDR**: invertible tone-mapped transfer so values above 1.0 survive the round trip, then
  16-bit / float pipelines for models that support them. See
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#hdr-roadmap).
- A commercially licensed local model option (e.g. Qwen-Image-Edit, Apache 2.0).
- Adobe Firefly Fill (the actual Photoshop model) for studios with Firefly Services access.
- Reference image input, like Photoshop's "Reference image".
- Track-and-apply: stick a still fill to a moving plate via a tracker / CornerPin.
- Grain matching on the generated patch.

## Development

```
nuke/                 <- add this folder to NUKE_PATH
  init.py, menu.py
  icons/GenFill.png
  python/genfill/
    node.py           builds the Group and its knobs
    engine.py         generate pipeline, variations, threading
    region.py         selection bounds and context-crop math (pure Python)
    pngio.py          dependency-free PNG IO (pure Python)
    state.py          variation history stored on the node (pure Python)
    colorspace.py     the colour round trip (where HDR modes will slot in)
    config.py         API keys and cache defaults
    devtools.py       Reload GenFill + in-Nuke smoke test
    localai/          free local AI: installer, hidden helper (worker.py), Nuke-side client
    backends/         stability.py, openai_images.py, mock.py
    ui/               Photoshop-style panel (panel.py), API key dialog, Qt shim
installers/           install / dev-install / uninstall / smoke test (Windows)
tests/                stdlib unittest; runs without Nuke
docs/ARCHITECTURE.md
```

Run the tests (no Nuke needed):

```
python -m unittest discover -s tests -v
```

`tests/fake_nuke.py` is a small stand-in for the `nuke` module, so the node build and the full
generate → select → delete flow are tested with the offline backend.
