"""Generate pipeline and variation management for a GenerativeFill node.

Flow of one Generate click (mirrors Photoshop):

1. Main thread: render a low-res probe of the selection and find its bounds.
2. Grow the bounds into a context region matched to the model's aspect.
3. Render the crop (8-bit, project colourspace) and the masks to the cache.
4. Background thread: call the backend for N variations, save them as PNGs.
5. Main thread: append a generation to the node's history and select its
   first variation (Read path, crop size and position are set on the
   internal nodes, so the result renders without this plugin).
"""
from __future__ import annotations

import datetime
import os
import subprocess
import sys
import threading
import traceback

import nuke

from . import backends, colorspace, config, pngio, region, state as gfstate
from . import node as gfnode
from .backends import BackendError, Cancelled, GenerationRequest

PROBE_LONG_SIDE = 192

_jobs = {}            # uid -> status dict
_jobs_lock = threading.Lock()


class UserError(Exception):
    """Problem the artist can fix; shown as-is."""


# --------------------------------------------------------------------------
# status (polled by the panel)
# --------------------------------------------------------------------------

def _uid(node):
    return node["gf_uid"].value()


def status(node):
    with _jobs_lock:
        return dict(_jobs.get(_uid(node), {"running": False, "message": "", "progress": 0.0,
                                            "error": ""}))


def _set_status(uid, **kw):
    with _jobs_lock:
        st = _jobs.setdefault(uid, {"running": False, "message": "", "progress": 0.0,
                                    "error": ""})
        st.update(kw)


def is_running(node):
    return status(node).get("running", False)


# --------------------------------------------------------------------------
# paths
# --------------------------------------------------------------------------

def cache_root(node):
    override = ""
    knob = node["gf_cache_dir"]
    try:
        override = knob.evaluate() or ""
    except Exception:
        override = knob.value() or ""
    override = override.strip()
    if override:
        return override
    script = nuke.root().name()
    if script and script != "Root":
        return os.path.join(os.path.dirname(script), "genfill_cache")
    return config.default_cache_root()


def cache_dir(node):
    return os.path.join(cache_root(node), _uid(node))


def resolve(node, gen, rel_path):
    """Absolute path of a variation, tolerant of moved/unsaved scripts."""
    candidates = [os.path.join(cache_dir(node), rel_path)]
    if gen.get("abs_dir"):
        candidates.append(os.path.join(gen["abs_dir"], os.path.basename(rel_path)))
    for c in candidates:
        if os.path.exists(c):
            return c
    return candidates[0]


def _fwd(path):
    return path.replace("\\", "/")


# --------------------------------------------------------------------------
# state helpers
# --------------------------------------------------------------------------

def get_state(node):
    return gfstate.loads(node["gf_state"].value())


def _save_state(node, st):
    node["gf_state"].setValue(gfstate.dumps(st))


def _internal(node, name):
    n = node.node(name)
    if n is None:
        raise UserError("GenerativeFill internals are missing node %r. Recreate the node." % name)
    return n


def refresh_result(node):
    """Point the internal Read/Reformat/Transform at the selected variation."""
    st = get_state(node)
    sel = gfstate.selected(st)
    if sel is None:
        node["gf_has_result"].setValue(False)
        node["gf_info"].setValue("")
        return
    gi, vi = sel
    gen = st["generations"][gi]
    path = resolve(node, gen, gen["files"][vi])
    read = _internal(node, gfnode.READ_RESULT)
    if _fwd(read["file"].value()) != _fwd(path):
        read["file"].setValue(_fwd(path))
    colorspace.apply_to_read(read, node["gf_transfer"].value())
    x, y, w, h = gen["region"]
    ref = _internal(node, gfnode.REFORMAT_RECV)
    ref["box_width"].setValue(w)
    ref["box_height"].setValue(h)
    _internal(node, gfnode.TRANSFORM_RECV)["translate"].setValue([x, y])
    node["gf_frame"].setValue(int(gen["frame"]))
    node["gf_has_result"].setValue(True)
    order = gfstate.variations(st)
    idx = order.index((gi, vi)) + 1
    prompt = gen.get("prompt") or "(remove)"
    if len(prompt) > 28:
        prompt = prompt[:27] + u"…"
    node["gf_info"].setValue("%s  [%d/%d]" % (prompt, idx, len(order)))


def select(node, gi, vi):
    st = gfstate.select(get_state(node), gi, vi)
    _save_state(node, st)
    refresh_result(node)


def step(node, delta):
    st = gfstate.step(get_state(node), delta)
    _save_state(node, st)
    refresh_result(node)


def delete_variation(node, gi, vi, delete_file=True):
    st = get_state(node)
    gen = st["generations"][gi]
    path = resolve(node, gen, gen["files"][vi])
    st, _removed = gfstate.remove_variation(st, gi, vi)
    _save_state(node, st)
    refresh_result(node)
    if delete_file:
        try:
            os.remove(path)
        except OSError:
            pass


def thumbnails(node):
    """Display list for the panel: newest generation first."""
    st = get_state(node)
    sel = gfstate.selected(st)
    out = []
    for gi, vi in gfstate.variations(st):
        gen = st["generations"][gi]
        out.append({
            "gi": gi, "vi": vi,
            "path": resolve(node, gen, gen["files"][vi]),
            "prompt": gen.get("prompt", ""),
            "backend": gen.get("backend", ""),
            "seed": gen.get("seed", 0),
            "frame": gen.get("frame", 0),
            "selected": sel == (gi, vi),
        })
    return out


def open_cache(node):
    path = cache_dir(node)
    if not os.path.isdir(path):
        path = cache_root(node)
    if not os.path.isdir(path):
        nuke.message("Nothing generated yet.\nCache folder will be:\n%s" % cache_dir(node))
        return
    if sys.platform.startswith("win"):
        os.startfile(path)  # noqa: pylint
    elif sys.platform == "darwin":
        subprocess.Popen(["open", path])
    else:
        subprocess.Popen(["xdg-open", path])


# --------------------------------------------------------------------------
# rendering helpers (main thread)
# --------------------------------------------------------------------------

def _execute(node, write_name, path, frame):
    w = _internal(node, write_name)
    w["file"].setValue(_fwd(path))
    w["disable"].setValue(False)
    try:
        nuke.execute(w, frame, frame, 1)
    finally:
        w["disable"].setValue(True)
    if not os.path.exists(path):
        raise UserError("Nuke did not write %s" % path)


def _prepare(node, backend, frame, job_dir):
    """Render probe + crops. Returns (region, model_w, model_h, files dict)."""
    src_input = node.input(0)
    if src_input is None:
        raise UserError("Connect an image to the Source input.")
    if node["gf_selection"].getValue() == 0 and node.input(1) is None:
        raise UserError("Connect a Roto (or any matte) to the Mask input, "
                        "or set 'selection from' to Source alpha.")
    fmt = src_input.format()
    fw, fh = fmt.width(), fmt.height()

    # 1. probe
    if fw >= fh:
        pw, ph = PROBE_LONG_SIDE, max(1, int(round(PROBE_LONG_SIDE * fh / float(fw))))
    else:
        pw, ph = max(1, int(round(PROBE_LONG_SIDE * fw / float(fh)))), PROBE_LONG_SIDE
    probe = _internal(node, gfnode.PROBE_REFORMAT)
    probe["box_width"].setValue(pw)
    probe["box_height"].setValue(ph)
    probe_path = os.path.join(job_dir, "probe.png")
    _execute(node, gfnode.PROBE_WRITE, probe_path, frame)
    bbox = region.mask_bbox(pngio.read(probe_path))
    if bbox is None:
        raise UserError("The selection is empty on frame %d.\nDraw a shape in the "
                        "GenFillSelection Roto (or check the Mask / Source alpha)." % frame)

    # 2. region
    box = region.probe_bbox_to_format(bbox, pw, ph, fw, fh)
    context = node["gf_context"].value()
    min_size = int(node["gf_min_size"].value())
    model = node["gf_model"].value().strip()
    rough = region.expand_region(box, fw, fh, context=context, min_size=min_size)
    mw, mh = backend.model_size(rough.w, rough.h, model)
    reg = region.expand_region(box, fw, fh, context=context, min_size=min_size,
                               aspect=float(mw) / mh)

    # 3. crops
    for crop_name, ref_name in ((gfnode.CROP_SRC, gfnode.REFORMAT_SRC),
                                (gfnode.CROP_MASK, gfnode.REFORMAT_MASK)):
        _internal(node, crop_name)["box"].setValue([reg.x, reg.y, reg.r, reg.t])
        ref = _internal(node, ref_name)
        ref["box_width"].setValue(mw)
        ref["box_height"].setValue(mh)
    colorspace.apply_to_write(_internal(node, gfnode.WRITE_SRC), node["gf_transfer"].value())
    files = {
        "image": os.path.join(job_dir, "source.png"),
        "mask": os.path.join(job_dir, "mask.png"),
        "mask_alpha": os.path.join(job_dir, "mask_alpha.png"),
    }
    _execute(node, gfnode.WRITE_SRC, files["image"], frame)
    _execute(node, gfnode.WRITE_MASK, files["mask"], frame)
    _execute(node, gfnode.WRITE_MASK_A, files["mask_alpha"], frame)
    return reg, mw, mh, (fw, fh), files


# --------------------------------------------------------------------------
# generate
# --------------------------------------------------------------------------

def generate(node, prompt=None):
    """Start a generation. Returns False if it could not start."""
    if is_running(node):
        return False
    if prompt is not None:
        node["gf_prompt"].setValue(prompt)
    prompt = node["gf_prompt"].value()
    backend = gfnode.backend_for(node)
    api_key = ""
    if backend.needs_key:
        api_key = config.get_api_key(backend.id, backend.env_var)
        if not api_key:
            from .ui import settings
            if not settings.show(focus=backend.id):
                return False
            api_key = config.get_api_key(backend.id, backend.env_var)
            if not api_key:
                return False

    uid = _uid(node)
    st = get_state(node)
    frame = int(nuke.frame())
    prev_frame = int(node["gf_frame"].value())
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    gen_id = "g%03d_%s" % (gfstate.next_generation_number(st), stamp)
    job_dir = os.path.join(cache_dir(node), gen_id)

    root = nuke.root()
    proxy = root["proxy"].value()
    _set_status(uid, running=True, message="Preparing selection...", progress=0.0, error="")
    try:
        if not os.path.isdir(job_dir):
            os.makedirs(job_dir)
        if proxy:
            root["proxy"].setValue(False)
        node["gf_frame"].setValue(frame)
        reg, mw, mh, fmt, files = _prepare(node, backend, frame, job_dir)
    except UserError as exc:
        node["gf_frame"].setValue(prev_frame)
        _set_status(uid, running=False, message="", error=str(exc))
        nuke.message(str(exc))
        return False
    except Exception as exc:  # unexpected: show and log
        node["gf_frame"].setValue(prev_frame)
        traceback.print_exc()
        _set_status(uid, running=False, message="", error="Could not prepare: %s" % exc)
        nuke.message("GenFill could not prepare the selection:\n%s" % exc)
        return False
    finally:
        if proxy:
            root["proxy"].setValue(True)

    seed = int(node["gf_seed"].value())
    count = max(1, min(10, int(node["gf_variations"].value())))
    request = GenerationRequest(
        image_path=files["image"], mask_path=files["mask"],
        mask_alpha_path=files["mask_alpha"], prompt=prompt, width=mw, height=mh,
        seed=seed, count=count, negative_prompt=node["gf_negative"].value(),
        model=node["gf_model"].value().strip(), quality=node["gf_quality"].value())
    meta = {
        "id": gen_id,
        "prompt": prompt,
        "backend": backend.id,
        "model": request.model,
        "seed": seed,
        "frame": frame,
        "prev_frame": prev_frame,
        "format": list(fmt),
        "region": [reg.x, reg.y, reg.w, reg.h],
        "model_size": [mw, mh],
        "abs_dir": job_dir,
        "created": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    t = threading.Thread(target=_worker, args=(node, uid, backend, request, api_key, meta,
                                               job_dir), name="GenFill-%s" % uid)
    t.daemon = True
    t.start()
    return True


def cancel(node):
    _set_status(_uid(node), cancel_requested=True)


def _worker(node, uid, backend, request, api_key, meta, job_dir):
    task = nuke.ProgressTask("Generative Fill")
    task.setMessage("Sending to %s..." % backend.label)

    def progress(frac, msg):
        task.setProgress(int(5 + 90 * frac))
        task.setMessage(msg)
        _set_status(uid, progress=frac, message=msg)

    def cancelled():
        with _jobs_lock:
            requested = _jobs.get(uid, {}).get("cancel_requested", False)
        return requested or task.isCancelled()

    _set_status(uid, message="Generating...", progress=0.05, cancel_requested=False)
    try:
        images = backend.generate(request, api_key, progress=progress, cancelled=cancelled)
        files = []
        for i, data in enumerate(images):
            name = "var_%02d.png" % (i + 1)
            with open(os.path.join(job_dir, name), "wb") as fh:
                fh.write(data)
            files.append("%s/%s" % (meta["id"], name))
        meta["files"] = files
        nuke.executeInMainThread(_finish, args=(node, uid, meta))
    except Cancelled:
        nuke.executeInMainThread(_fail, args=(node, uid, meta, "Cancelled.", False))
    except BackendError as exc:
        nuke.executeInMainThread(_fail, args=(node, uid, meta, str(exc), True))
    except Exception as exc:
        traceback.print_exc()
        nuke.executeInMainThread(_fail, args=(node, uid, meta, "Unexpected error: %s" % exc, True))
    finally:
        del task


def _node_alive(node):
    try:
        node.name()
        return True
    except ValueError:
        return False


def _finish(node, uid, meta):
    _set_status(uid, running=False, progress=1.0, message="", error="")
    if not _node_alive(node):
        return
    meta = dict(meta)
    meta.pop("prev_frame", None)
    st = gfstate.add_generation(get_state(node), meta, select_first=True)
    _save_state(node, st)
    refresh_result(node)


def _fail(node, uid, meta, message, show):
    _set_status(uid, running=False, progress=0.0, message="", error=message)
    if not _node_alive(node):
        return
    node["gf_frame"].setValue(int(meta.get("prev_frame", meta["frame"])))
    refresh_result(node)
    print("GenFill: %s" % message)
    if show:
        nuke.message("Generative Fill failed:\n\n%s" % message)
