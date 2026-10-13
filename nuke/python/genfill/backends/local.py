"""Local generation inside the GenFill plugin (free, offline, no tokens).

Uses the hidden AI helper (``genfill.localai``): FLUX.1 Fill [dev] for prompts,
LaMa (+ FLUX refinement) when the prompt is empty. Installed from Nuke with
GenFill > Local AI > Install.

FLUX.1 [dev] models are under the FLUX.1 [dev] Non-Commercial License.
"""
from __future__ import annotations

import os
import random

from .base import Backend, BackendError, Cancelled
from .. import region

QUALITY_STEPS = {"low": 16, "medium": 24, "auto": 24, "high": 32}
MAX_SEED = 2 ** 32 - 1


class NotInstalled(BackendError):
    pass


class LocalBackend(Backend):
    id = "local"
    label = "Local: FLUX.1 Fill (free, runs on your GPU)"
    needs_key = False
    description = ("Free and offline on this PC's GPU. FLUX.1 Fill for prompts, LaMa for removal. "
                   "FLUX.1 [dev] licence: non-commercial use.")
    guidance = 30.0
    refine_strength = 0.8

    def is_installed(self):
        from .. import localai
        return localai.is_installed()

    def model_size(self, width, height, model=""):
        # FLUX works best around 1 MP; keep sides on a 64 px grid.
        return region.scale_to_pixel_budget(width, height, 1024 * 1024, 64, min_side=512,
                                            max_side=1536, max_aspect=3.0)

    def generate(self, request, api_key, progress=None, cancelled=None):
        from .. import localai
        from ..localai.client import WorkerError, get_client
        if not localai.is_installed():
            raise NotInstalled("Local AI isn't installed yet. Click 'Local AI...' in the node's panel to install it.")
        out_dir = os.path.join(os.path.dirname(request.image_path), "local_out")
        payload = {
            "image": request.image_path,
            "mask": request.mask_path,
            "prompt": request.prompt,
            "width": request.width,
            "height": request.height,
            "count": request.count,
            "seed": request.seed or random.randint(1, MAX_SEED - request.count),
            "steps": QUALITY_STEPS.get(request.quality, QUALITY_STEPS["auto"]),
            "guidance": self.guidance,
            "refine_strength": self.refine_strength,
            "out_dir": out_dir,
        }
        client = get_client()
        if progress and not client.is_running():
            progress(0.0, "Starting the local AI...")
        try:
            done = client.request("generate", payload, progress=progress, cancelled=cancelled)
        except WorkerError as exc:
            if exc.cancelled:
                raise Cancelled("Cancelled")
            try:
                from .. import log as gflog
                from ..localai.client import helper_log_tail
                gflog.error("AI helper error: %s\n--- helper.log (last lines) ---\n%s", exc,
                            helper_log_tail())
            except Exception:
                pass
            raise BackendError(str(exc))
        results = []
        for path in done.get("files", []):
            with open(path, "rb") as fh:
                results.append(fh.read())
        if not results:
            raise BackendError("The local AI returned no images.")
        return results
