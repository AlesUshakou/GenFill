# GenFill architecture

## Design goals

1. **Behave like Photoshop's Generative Fill**: select, prompt (optional), Generate, browse
   variations, and the result lives as a masked layer.
2. **Stay colour managed.** The artist never leaves Nuke's working space. All conversion to
   what a model expects happens inside the node and is exactly inverted on the way back.
3. **Never break a render.** The node is a Group of native Nuke nodes. Generation needs the
   plugin; rendering does not.
4. **Backends are swappable.** Cloud today, local tomorrow, HDR-capable later.

## The node

`genfill.node.create()` builds a Group:

```
Source ─┬─ FrameHold ── Crop ── Reformat ── Write(source.png)            ┐
        │                                                               │ send side
Mask ───┴─ Switch ── Erode(expand) ── FrameHold ── Expression(rgb=m, a=1-m)
                           │                 ├─ Reformat(probe) ── Write(probe.png)
                           │                 └─ Crop ── Reformat ── Write(mask.png, mask_alpha.png)
                           └─ Blur(feather) ─────────────┐
Read(var_XX.png) ── Reformat(crop size) ── Transform(crop xy) ── Merge(copy, masked) ─┐
                                              └─ Copy(alpha) ── Premult ─────────────┤
Source ───────────────────────────────────────────────────────────────── Switch ── Output
```

- The four Write nodes are **disabled** except during the few milliseconds GenFill renders
  them, so *Render All* and farm submissions never touch them.
- The output Switch is `gf_has_result ? gf_output : 2`: until something is generated the node
  is a pass-through.
- `gf_frame` drives both FrameHolds: the plate and selection are sampled on the frame the
  selected variation was generated from.

## One Generate click

1. **Probe** (main thread): render the selection at ~192 px wide and find its bounds in
   Python (`pngio` + `region.mask_bbox`). This works for any matte, not just Roto.
2. **Region**: grow the bounds by `context` (default 35% of the selection's larger side,
   at least 32 px, region at least 512 px), ask the backend which resolution it wants for that
   shape, then refit the region to that exact aspect and keep it inside the format.
3. **Crops**: set the Crop/Reformat knobs, render `source.png` (8-bit, project colourspace),
   `mask.png` (white = fill) and `mask_alpha.png` (alpha 0 = fill, OpenAI's convention).
4. **Generate** (background thread): the backend returns N PNGs and they're saved as
   `var_01.png…`. Nuke's ProgressTask provides Cancel.
5. **Apply** (main thread via `executeInMainThread`): append to the history JSON in
   `gf_state` and select the first variation. Selecting sets the Read path, Reformat box
   (crop size) and Transform (crop position) from that generation's stored region.

Each generation stores its own region, frame and model size, so selecting an old variation
restores its placement even if the selection has changed since.

## Files

```
<script dir>/genfill_cache/<node uid>/
    g001_20261012-201500/
        probe.png  source.png  mask.png  mask_alpha.png
        var_01.png var_02.png var_03.png
```

The uid is fixed at creation, so renaming the node doesn't orphan its cache. Paths in the
state are relative to the node's cache folder; the absolute folder is kept as a fallback for
scripts saved after generating.

## Backends

`backends.base.Backend` has two methods:

- `model_size(w, h, model)` returns the resolution to send for a crop of that shape.
- `generate(request, api_key, progress, cancelled)` returns a list of PNG bytes.

They're pure Python (stdlib `urllib`) and know nothing about Nuke, so they're unit tested with
mocked HTTP. To add one, subclass, then register it in `backends/__init__.py`.

## Local AI (free, offline)

```
Nuke (GenFill plugin)                         GenFill-LocalAI\ (outside OneDrive)
  backends/local.py                             env\  private Python 3.12 + PyTorch CUDA
  localai/client.py  --- JSON lines over --->   localai/worker.py (hidden helper process)
                         stdin / stdout           FLUX.1 Fill [dev] GGUF (diffusers)
                                                  T5-XXL (loaded briefly per new prompt)
                                                  CLIP-L, FLUX VAE, LaMa (TorchScript)
```

- **Why a separate process:** PyTorch and ~10 GB of model weights never load into Nuke. A crash
  or GPU out-of-memory becomes an error in the panel; Nuke and the script stay alive, and
  PyTorch's CUDA libraries can't clash with Nuke's (CopyCat/Cattery).
- **Lifecycle:** started hidden (`CREATE_NO_WINDOW`) on the first Local generation; model stays
  loaded between generations; exits when Nuke closes the pipe, on *Stop AI Helper*, or after
  10 idle minutes. Nuke's `PYTHONPATH`/`PYTHONHOME` are stripped from its environment.
- **Memory on 12 GB GPUs:** FLUX Q4_K_S (6.8 GB) stays on the GPU. T5 (9.5 GB) is loaded straight
  to the GPU only while a new prompt is encoded (the transformer is parked in system RAM for those
  seconds), then freed. Encodings are cached per prompt.
- **Removal (empty prompt):** variation 1 is LaMa; later variations run FLUX.1 Fill at strength
  0.8 starting from the LaMa result, which adds texture while staying a clean plate.
- **Installer** (`localai/installer.py`, dialog in `ui/localai_dialog.py`): uv builds the private
  Python, then PyTorch (cu128) and diffusers/transformers/gguf are installed, the models are
  downloaded from public repositories (no login), the diffusers configs for FLUX.1 Fill are
  written locally (the official repos are gated), and a self-test runs on the GPU.
  `manifest.json` marks a complete install.

## Colour

`colorspace.py` owns the round trip. v0.1 uses **SDR 8-bit**: Write and Read share one
colourspace (`default` = the project's 8-bit file setting), so the transform is exactly
inverted, and only pixels inside the feathered selection are replaced.

## HDR roadmap

The problem: models are trained on display-referred 8-bit images. Plate values above 1.0
(skies, practicals, speculars) clip when they're encoded, and the fill comes back with
nothing above 1.0, which reads as flat once it's graded.

Planned in order of payoff:

1. **Invertible tone-mapped transfer** (next). Before the Write, apply a smooth curve with an
   exact inverse that compresses scene-linear `[0, ∞)` into `[0, 1)`, e.g. a parametric
   Reinhard-style shoulder with exposure set from the region's context (`x' = x / (1 + x/w)`,
   inverse `x = x' / (1 − x'/w)`). Apply the inverse after the Read. Highlights in the context
   become visible to the model, and generated highlights come back above 1.0. This needs only
   two Expression nodes around the existing Write/Read, plus a new entry in
   `colorspace.TRANSFER_MODES`. Risk: 8-bit quantisation near the shoulder, so the
   *quality* depends on how much headroom is compressed. Mitigate with per-region exposure
   normalisation.
2. **16-bit I/O.** Write 16-bit PNG/TIFF for backends that accept it (most cloud APIs return
   8-bit today, so this matters mainly for local models).
3. **Highlight reconstruction.** For backends that only see SDR, transfer the luminance
   distribution of the surrounding HDR context onto the generated patch (ratio-map
   extrapolation in the context band), so a generated sky matches the plate's sky intensity.
4. **Local HDR-native models** (ComfyUI backend): log or float in, float out, no tonemap.

Because the node only ever calls `colorspace.apply_to_write/read` (and will call the
tonemap pair), adding these modes won't change the node graph users already have in scripts.

## Known limitations (v0.1)

- Anamorphic plates: pixel aspect is ignored when building the crop.
- Proxy mode is turned off temporarily while rendering the crops.
- The panel is Qt (PySide2/6). If it fails to load, the standard knobs still work and the
  result still renders; generation then needs the Python call
  `genfill.engine.generate(nuke.selectedNode())`.
- One generation at a time per node.
