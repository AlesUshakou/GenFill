# GenFill — Generative Fill for Nuke

Photoshop's Generative Fill, built into a Nuke node. Select an area, type what you want (or
leave the prompt empty to remove what's there), click **Generate**, then pick from the
variations. Your plate never leaves the colour-managed comp. No more round trips through
Photoshop.

![node](nuke/icons/GenFill.png)

## What it does (v0.1)

| Photoshop | GenFill in Nuke |
|---|---|
| Make a selection (lasso / marquee) | Draw in the **GenFillSelection** Roto that's created with the node (or use the Source alpha / any matte in the Mask input) |
| Contextual task bar: prompt + **Generate** | The same bar at the top of the node's properties. Enter generates. |
| Empty prompt = remove and fill from surroundings | Same. With Stability AI this uses their dedicated *Erase* model. |
| 3 variations per generation, browse with ‹ › | Same: thumbnail grid of every generation (newest first), ‹ 1/6 › arrows, right-click to reuse a prompt, reveal or delete |
| Generative layer with a layer mask | Output **Comp** (fill blended over the plate through the feathered selection) or **Fill only** (premultiplied layer) |
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

1. Add the `nuke` folder of this repo to Nuke's plugin path. Put this in
   `C:\Users\<you>\.nuke\init.py` (create the file if it doesn't exist):

   ```python
   import nuke
   nuke.pluginAddPath(r"C:/Users/Connor/OneDrive/Documents/repository/GenFill/nuke")
   ```

   (Or add that folder to the `NUKE_PATH` environment variable.)
2. Restart Nuke. You'll find **GenFill > Generative Fill** in the Nodes toolbar, or Tab-search
   "Generative Fill".
3. Set an API key: **GenFill > API Keys...** or the node's *Settings* tab. Alternatively set
   `STABILITY_API_KEY` / `OPENAI_API_KEY` in your environment.

Supported: Nuke 13 to 16+ (Python 3, PySide2 or PySide6). Windows, macOS, Linux.

## Use

1. Select your plate and create **Generative Fill**. A `GenFillSelection` Roto is created and
   wired into the Mask input.
2. Open the Roto, draw around what you want to replace (view the GenerativeFill node so you
   can see the plate).
3. In the GenerativeFill panel, type a prompt (*"a weathered wooden bench"*), or leave it
   empty to remove the object. Press **Generate**.
4. Click thumbnails or use ‹ › to choose a variation. Generate again to add more.
5. Tweak **expand** / **feather** to blend, and set **output** to *Comp* or *Fill only*.

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
| Stability AI | True masked inpainting; best at *removal* (empty prompt → Erase model) | ~1 MP per request, one request per variation. Key from platform.stability.ai |
| OpenAI GPT Image | Prompt following, adding objects | Re-renders the crop, which we composite back through the mask. `gpt-image-2` default; fixed-size models (`gpt-image-1`, `1.5`) are handled |
| Offline Preview | Testing the pipeline, no network | Smears surrounding colour into the selection; not AI |

> **Data note:** cloud backends upload the crop (not the whole frame) to that provider. Check
> your client / TPN rules before using them on production plates. A local backend (ComfyUI) is
> on the roadmap for exactly this reason.

## Roadmap

- **HDR**: invertible tone-mapped transfer so values above 1.0 survive the round trip, then
  16-bit / float pipelines for models that support them. See
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#hdr-roadmap).
- Local generation (ComfyUI / diffusers) for studios that can't send plates to the cloud.
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
    backends/         stability.py, openai_images.py, mock.py
    ui/               Photoshop-style panel (panel.py), API key dialog, Qt shim
tests/                stdlib unittest; runs without Nuke
docs/ARCHITECTURE.md
```

Run the tests (no Nuke needed):

```
python -m unittest discover -s tests -v
```

`tests/fake_nuke.py` is a small stand-in for the `nuke` module, so the node build and the full
generate → select → delete flow are tested with the offline backend.
