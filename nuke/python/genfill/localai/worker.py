"""GenFill local AI helper process.

Started (hidden, no window) by Nuke with the private Python environment that
the in-Nuke installer creates. It never imports ``nuke`` or ``genfill``: it is
a standalone script so its heavy dependencies (PyTorch, diffusers) stay out of
Nuke's process. If it crashes or runs out of GPU memory, Nuke keeps running.

Protocol: one JSON object per line.
  stdin  (from Nuke):  {"id": "...", "cmd": "ping" | "load" | "generate" | "selftest"
                        | "cancel" | "shutdown", ...}
  stdout (to Nuke):    {"id": "...", "event": "progress" | "done" | "error" | "pong" | "bye", ...}
Everything else the libraries print goes to stderr (Nuke points it at a log).

The process exits when Nuke closes the pipe (Nuke quit or crashed), on
"shutdown", or after ``--idle`` seconds without work (frees the GPU).
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import shutil
import sys
import threading
import time
import traceback

PROTOCOL_VERSION = 1
_send_lock = threading.Lock()
_proto_out = None


def send(obj):
    line = json.dumps(obj) + "\n"
    with _send_lock:
        _proto_out.write(line)
        _proto_out.flush()


def log(msg, *args):
    sys.stderr.write(time.strftime("%H:%M:%S ") + (msg % args if args else msg) + "\n")
    sys.stderr.flush()


def memory_status():
    """'RAM free x GB, commit free y GB' on Windows (commit = RAM + page file)."""
    if not sys.platform.startswith("win"):
        return ""
    try:
        import ctypes

        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                        ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                        ("ullTotalPageFile", ctypes.c_ulonglong),
                        ("ullAvailPageFile", ctypes.c_ulonglong),
                        ("ullTotalVirtual", ctypes.c_ulonglong),
                        ("ullAvailVirtual", ctypes.c_ulonglong),
                        ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
        st = MEMORYSTATUSEX()
        st.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st))
        return "RAM free %.1f/%.1f GB, commit free %.1f/%.1f GB" % (
            st.ullAvailPhys / 1e9, st.ullTotalPhys / 1e9, st.ullAvailPageFile / 1e9,
            st.ullTotalPageFile / 1e9)
    except Exception:
        return ""


WINDOWS_MEMORY_MSG = (
    "Windows ran out of memory (RAM + page file) while loading the AI. Close other memory-heavy "
    "apps (browsers, other DCCs), or let Windows manage the page file size (System > About > "
    "Advanced system settings > Performance > Advanced > Virtual memory), then try again.")


class Cancelled(Exception):
    pass


class Job(object):
    def __init__(self, msg):
        self.msg = msg
        self.id = msg.get("id")
        self.cancel = threading.Event()

    def progress(self, fraction, message):
        send({"id": self.id, "event": "progress", "fraction": float(fraction), "message": message})

    def check(self):
        if self.cancel.is_set():
            raise Cancelled()


# --------------------------------------------------------------------------
# real engine: FLUX.1 Fill (diffusers, GGUF) + LaMa
# --------------------------------------------------------------------------

class Engine(object):
    def __init__(self, root):
        self.root = root
        with open(os.path.join(root, "manifest.json"), "r") as fh:
            self.manifest = json.load(fh)
        self.pipe = None
        self.lama = None
        self.device = None
        self.embed_cache = {}

    def _path(self, key):
        return os.path.join(self.root, self.manifest[key])

    def info(self):
        import torch
        out = {"torch": torch.__version__, "cuda": torch.cuda.is_available()}
        if torch.cuda.is_available():
            p = torch.cuda.get_device_properties(0)
            free, total = torch.cuda.mem_get_info()
            out.update(gpu=p.name, vram_total=total, vram_free=free)
        out["model"] = self.manifest.get("unet")
        out["loaded"] = self.pipe is not None
        return out

    def load(self, job=None):
        if self.pipe is not None:
            return
        import torch
        from diffusers import (AutoencoderKL, FlowMatchEulerDiscreteScheduler, FluxFillPipeline,
                               FluxTransformer2DModel, GGUFQuantizationConfig)
        from transformers import CLIPTextModel, CLIPTokenizer, T5TokenizerFast

        if not torch.cuda.is_available():
            raise RuntimeError(
                "The Local AI's PyTorch can't use your NVIDIA GPU (on the CPU a fill would take "
                "hours). Click 'Local AI...' in the node's panel (or GenFill > Local AI: Install / Repair in the top menu) and click Repair. "
                "(PyTorch %s, CUDA build %s)" % (torch.__version__, torch.version.cuda))
        self.device = "cuda"
        log("libraries imported (torch %s, CUDA %s, %s)", torch.__version__, torch.version.cuda,
            torch.cuda.get_device_name(0))
        log("memory: %s", memory_status())
        dtype = torch.bfloat16
        cfg = self._path("flux_config_dir")
        t0 = time.time()
        if job:
            job.progress(0.0, "Loading FLUX.1 Fill (first time takes a minute)...")
        t1 = time.time()
        transformer = FluxTransformer2DModel.from_single_file(
            self._path("unet"), quantization_config=GGUFQuantizationConfig(compute_dtype=dtype),
            config=cfg, subfolder="transformer", torch_dtype=dtype)
        log("FLUX transformer read in %.1fs", time.time() - t1)
        vae = AutoencoderKL.from_single_file(self._path("vae"), config=cfg, subfolder="vae",
                                             torch_dtype=dtype)
        scheduler = FlowMatchEulerDiscreteScheduler.from_pretrained(cfg, subfolder="scheduler")
        text_encoder = CLIPTextModel.from_pretrained(self._path("clip_dir"), torch_dtype=dtype)
        tokenizer = CLIPTokenizer.from_pretrained(self._path("clip_dir"))
        tokenizer_2 = T5TokenizerFast.from_pretrained(self._path("t5_dir"))
        self.pipe = FluxFillPipeline(scheduler=scheduler, vae=vae, text_encoder=text_encoder,
                                     tokenizer=tokenizer, text_encoder_2=None,
                                     tokenizer_2=tokenizer_2, transformer=transformer)
        self.pipe.to(self.device)
        self.pipe.vae.enable_tiling()
        self.pipe.set_progress_bar_config(disable=True)
        log("FLUX.1 Fill loaded in %.1fs", time.time() - t0)

    # -- prompt encoding: T5 is ~9.5 GB, so it visits the GPU only briefly ----
    def encode(self, prompt, job):
        if prompt in self.embed_cache:
            return self.embed_cache[prompt]
        import torch
        from transformers import T5EncoderModel
        job.progress(0.02, "Reading the prompt...")
        log("before T5: %s", memory_status())
        pipe = self.pipe
        pipe.transformer.to("cpu")
        torch.cuda.empty_cache() if self.device == "cuda" else None
        t5 = None
        try:
            t5 = T5EncoderModel.from_pretrained(self._path("t5_dir"), torch_dtype=torch.bfloat16,
                                                device_map={"": self.device})
            log("T5 loaded to %s", self.device)
            pipe.text_encoder_2 = t5
            with torch.no_grad():
                pe, ppe, _ids = pipe.encode_prompt(prompt=prompt, prompt_2=prompt,
                                                   device=self.device, max_sequence_length=512)
            result = (pe.detach(), ppe.detach())
        finally:
            pipe.text_encoder_2 = None
            del t5
            if self.device == "cuda":
                torch.cuda.empty_cache()
            pipe.transformer.to(self.device)
        if len(self.embed_cache) > 16:
            self.embed_cache.clear()
        self.embed_cache[prompt] = result
        return result

    def run_lama(self, image, mask):
        import numpy as np
        import torch
        import torch.nn.functional as F
        from PIL import Image
        if self.lama is None:
            self.lama = torch.jit.load(self._path("lama"), map_location="cpu").eval()
        model = self.lama.to(self.device)
        try:
            im = np.asarray(image.convert("RGB")).astype(np.float32) / 255.0
            mk = (np.asarray(mask.convert("L")) > 127).astype(np.float32)
            h, w = mk.shape
            it = torch.from_numpy(im.transpose(2, 0, 1))[None].to(self.device)
            mt = torch.from_numpy(mk)[None, None].to(self.device)
            ph, pw = (8 - h % 8) % 8, (8 - w % 8) % 8
            if ph or pw:
                it = F.pad(it, (0, pw, 0, ph), mode="reflect")
                mt = F.pad(mt, (0, pw, 0, ph), mode="reflect")
            with torch.no_grad():
                out = model(it, mt)
            out = out[0, :, :h, :w].permute(1, 2, 0).float().cpu().numpy()
            return Image.fromarray((out.clip(0, 1) * 255).round().astype("uint8"))
        finally:
            self.lama = model.to("cpu")
            if self.device == "cuda":
                torch.cuda.empty_cache()

    def _flux(self, job, embeds, image, mask, width, height, seed, steps, guidance, strength,
              done_before, total):
        import torch
        pipe = self.pipe

        def on_step(p, i, t, kwargs):
            frac = (done_before + (i + 1) / float(steps)) / total
            job.progress(0.05 + 0.95 * frac, "Generating variation %d of %d (step %d/%d)"
                         % (done_before + 1, total, i + 1, steps))
            if job.cancel.is_set():
                p._interrupt = True
            return kwargs

        t_var = time.time()
        gen = torch.Generator("cpu").manual_seed(int(seed))
        out = pipe(prompt_embeds=embeds[0], pooled_prompt_embeds=embeds[1], image=image,
                   mask_image=mask, width=int(width), height=int(height), strength=float(strength),
                   guidance_scale=float(guidance), num_inference_steps=int(steps), generator=gen,
                   max_sequence_length=512, callback_on_step_end=on_step)
        job.check()
        log("variation %d: %d steps in %.1fs", done_before + 1, steps, time.time() - t_var)
        return out.images[0]

    def generate(self, job):
        import torch
        from PIL import Image
        m = job.msg
        if self.pipe is None:
            job.progress(0.0, "Loading the AI libraries...")
        self.load(job)
        image = Image.open(m["image"]).convert("RGB")
        mask = Image.open(m["mask"]).convert("L")
        width, height = int(m["width"]), int(m["height"])
        if image.size != (width, height):
            image = image.resize((width, height), Image.LANCZOS)
            mask = mask.resize((width, height), Image.NEAREST)
        count, steps = int(m.get("count", 3)), int(m.get("steps", 24))
        seed, guidance = int(m.get("seed", 1)), float(m.get("guidance", 30.0))
        prompt = (m.get("prompt") or "").strip()
        removal = not prompt
        os.makedirs(m["out_dir"], exist_ok=True)
        outputs = []
        try:
            prefill = None
            if removal:
                job.progress(0.01, "Removing with LaMa...")
                prefill = self.run_lama(image, mask)
            embeds = self.encode(prompt, job)
            for i in range(count):
                job.check()
                if removal and i == 0:
                    result = prefill
                elif removal:
                    result = self._flux(job, embeds, prefill, mask, width, height, seed + i, steps,
                                        guidance, float(m.get("refine_strength", 0.8)), i, count)
                else:
                    result = self._flux(job, embeds, image, mask, width, height, seed + i, steps,
                                        guidance, 1.0, i, count)
                path = os.path.join(m["out_dir"], "local_%02d.png" % (i + 1))
                result.save(path)
                outputs.append(path)
            return outputs
        except torch.cuda.OutOfMemoryError:
            torch.cuda.empty_cache()
            raise MemoryError(
                "The GPU ran out of memory. Close other GPU-heavy apps, lower the viewer "
                "resolution, or reinstall Local AI with a smaller model size.")

    def selftest(self, job):
        from PIL import Image, ImageDraw
        tmp = os.path.join(self.root, "selftest")
        if os.path.isdir(tmp):
            shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(tmp)
        img = Image.new("RGB", (512, 512), (90, 120, 160))
        ImageDraw.Draw(img).rectangle([0, 300, 512, 512], fill=(70, 90, 60))
        mask = Image.new("L", (512, 512), 0)
        ImageDraw.Draw(mask).ellipse([180, 180, 330, 330], fill=255)
        img.save(os.path.join(tmp, "src.png"))
        mask.save(os.path.join(tmp, "mask.png"))
        t0 = time.time()
        job.msg.update(image=os.path.join(tmp, "src.png"), mask=os.path.join(tmp, "mask.png"),
                       width=512, height=512, count=2, steps=4, seed=1, prompt="",
                       out_dir=tmp)
        files = self.generate(job)
        info = self.info()
        info["selftest_seconds"] = round(time.time() - t0, 1)
        info["files"] = files
        return info


# --------------------------------------------------------------------------
# fake engine (tests; no PyTorch)
# --------------------------------------------------------------------------

class FakeEngine(object):
    def __init__(self, root):
        self.root = root
        self.loaded = False

    def info(self):
        return {"fake": True, "gpu": "FakeGPU", "loaded": self.loaded}

    def load(self, job=None):
        self.loaded = True

    def generate(self, job):
        m = job.msg
        if m.get("prompt") == "crash":
            os._exit(3)
        if m.get("prompt") == "oom":
            raise MemoryError("The GPU ran out of memory.")
        self.load(job)
        os.makedirs(m["out_dir"], exist_ok=True)
        out = []
        steps = int(m.get("steps", 4))
        for i in range(int(m.get("count", 3))):
            for s in range(steps):
                job.check()
                job.progress((i + (s + 1) / float(steps)) / m.get("count", 3), "fake step")
                time.sleep(float(m.get("step_delay", 0.0)))
            path = os.path.join(m["out_dir"], "local_%02d.png" % (i + 1))
            shutil.copyfile(m["image"], path)
            out.append(path)
        return out

    def selftest(self, job):
        return dict(self.info(), selftest_seconds=0.0)


# --------------------------------------------------------------------------
# main loop
# --------------------------------------------------------------------------

def preload():
    """Import torch / diffusers / transformers up front, timing each step."""
    send({"event": "status", "message": "Loading the AI libraries (first start can take a minute)..."})
    steps = [
        ("torch", "import torch"),
        ("torch CUDA init", "import torch; torch.cuda.is_available() and torch.cuda.init()"),
        ("transformers", "import transformers; from transformers import CLIPTextModel, T5EncoderModel"),
        ("diffusers", "from diffusers import FluxFillPipeline, FluxTransformer2DModel, AutoencoderKL"),
        ("PIL / numpy", "import PIL.Image, numpy"),
    ]
    total = time.time()
    for name, code in steps:
        t0 = time.time()
        try:
            exec(code, {})
        except Exception as exc:
            log("preload %s FAILED after %.1fs: %s", name, time.time() - t0, exc)
            return
        log("preload %-16s %.1fs", name, time.time() - t0)
    log("libraries ready in %.1fs", time.time() - total)
    send({"event": "status", "message": "AI libraries loaded."})


def main(argv=None):
    global _proto_out
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--idle", type=float, default=600.0)
    ap.add_argument("--fake", action="store_true")
    args = ap.parse_args(argv)

    # Keep the protocol channel clean: anything printed by libraries (even C
    # code writing to fd 1) goes to stderr instead.
    _proto_out = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr

    engine = FakeEngine(args.root) if args.fake else Engine(args.root)
    jobs = queue.Queue()
    current = [None]

    def reader():
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            try:
                msg = json.loads(raw)
            except ValueError:
                log("bad message: %r", raw[:200])
                continue
            if msg.get("cmd") == "cancel":
                job = current[0]
                if job is not None and (msg.get("target") in (None, job.id)):
                    job.cancel.set()
                continue
            jobs.put(msg)
        # Nuke closed the pipe (quit or crashed): stop any running job and exit.
        job = current[0]
        if job is not None:
            job.cancel.set()
        jobs.put(None)

    send({"event": "hello", "protocol": PROTOCOL_VERSION, "pid": os.getpid(), "fake": args.fake})
    log("GenFill helper started (pid %s, idle timeout %ss)", os.getpid(), args.idle)
    # Import the heavy libraries BEFORE a thread starts blocking on stdin. On
    # Windows a pending read on the stdin pipe can stall other work on the
    # process's standard handles; inside the helper, importing PyTorch took
    # minutes while the same import elsewhere took seconds.
    if not args.fake:
        preload()
    threading.Thread(target=reader, name="stdin", daemon=True).start()

    while True:
        try:
            msg = jobs.get(timeout=args.idle)
        except queue.Empty:
            log("idle for %ss, exiting to free GPU memory", args.idle)
            send({"event": "bye", "reason": "idle"})
            return 0
        if msg is None:
            log("pipe closed, exiting")
            return 0
        cmd = msg.get("cmd")
        job = Job(msg)
        current[0] = job
        try:
            if cmd == "shutdown":
                send({"id": job.id, "event": "bye", "reason": "shutdown"})
                return 0
            elif cmd == "ping":
                send({"id": job.id, "event": "pong", "info": engine.info() if args.fake
                      else {"loaded": engine.pipe is not None}})
            elif cmd == "load":
                engine.load(job)
                send({"id": job.id, "event": "done", "info": engine.info()})
            elif cmd == "generate":
                files = engine.generate(job)
                send({"id": job.id, "event": "done", "files": files})
            elif cmd == "selftest":
                send({"id": job.id, "event": "done", "info": engine.selftest(job)})
            else:
                send({"id": job.id, "event": "error", "message": "unknown command %r" % cmd})
        except Cancelled:
            send({"id": job.id, "event": "error", "cancelled": True, "message": "Cancelled."})
        except MemoryError as exc:
            send({"id": job.id, "event": "error", "oom": True, "message": str(exc)})
        except OSError as exc:
            log(traceback.format_exc())
            if getattr(exc, "winerror", None) == 1455 or "1455" in str(exc):
                log("memory at failure: %s", memory_status())
                send({"id": job.id, "event": "error", "oom": True, "message": WINDOWS_MEMORY_MSG})
            else:
                send({"id": job.id, "event": "error",
                      "message": "%s: %s" % (type(exc).__name__, exc)})
        except Exception as exc:
            tb = traceback.format_exc()
            log(tb)
            send({"id": job.id, "event": "error", "message": "%s: %s" % (type(exc).__name__, exc),
                  "traceback": tb})
        finally:
            current[0] = None


if __name__ == "__main__":
    sys.exit(main())
