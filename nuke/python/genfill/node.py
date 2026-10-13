"""Creates the GenerativeFill node (a Group built from native Nuke nodes).

Only native nodes live inside the Group, so a script containing GenFill
renders on a farm or another workstation **without the plugin installed**:
the chosen variation is a Read node with a fixed path, and the comp is plain
Reformat/Transform/Merge. The plugin is only needed to generate and to show
the Photoshop-style panel.

Internal graph::

    Source ─┬─ FrameHold ── Crop ── Reformat ── Write(src.png, sRGB 8-bit)   ┐ send
            │                                                                │ (disabled
    Mask ───┴─ Switch ── Erode(grow) ── FrameHold ── Expression(rgb=m, a=1-m)│  except while
                                │                     ├─ Reformat(probe) ── Write(probe)
                                │                     └─ Crop ── Reformat ── Write(mask, mask_a)
                                │
                                └── Blur(feather) ────────────────┐
    Read(result) ── Reformat(to crop size) ── Transform(to crop xy)┴─ Merge(copy, masked) ─┐
                                                └─ Copy(alpha) ── Premult ───────────────────┤
    Source ─────────────────────────────────────────────────────────────────── Switch ── Output
"""
from __future__ import annotations

import uuid

import nuke

from . import backends, colorspace

NODE_CLASS_LABEL = "GenerativeFill"
TILE_COLOR = 0x5B4CF5FF

# Internal node names
SRC_IN = "Source"
MASK_IN = "Mask"
HOLD_SRC = "gf_hold_src"
SEL_SWITCH = "gf_selection_switch"
GROW = "gf_grow"
HOLD_MATTE = "gf_hold_matte"
MASK_EXPR = "gf_mask_rgba"
PROBE_REFORMAT = "gf_probe_reformat"
PROBE_WRITE = "gf_probe_write"
CROP_SRC = "gf_crop_src"
REFORMAT_SRC = "gf_reformat_src"
WRITE_SRC = "gf_write_src"
CROP_MASK = "gf_crop_mask"
REFORMAT_MASK = "gf_reformat_mask"
WRITE_MASK = "gf_write_mask"
WRITE_MASK_A = "gf_write_mask_alpha"
READ_RESULT = "gf_result"
REFORMAT_RECV = "gf_reformat_result"
TRANSFORM_RECV = "gf_place_result"
FEATHER = "gf_feather"
COMP = "gf_comp"
COPY_ALPHA = "gf_fill_alpha"
PREMULT = "gf_fill_premult"
OUT_SWITCH = "gf_output_switch"
BLANK = "gf_layer_blank"
LAYER = "gf_layer"

WRITE_NODES = (PROBE_WRITE, WRITE_SRC, WRITE_MASK, WRITE_MASK_A)

SELECTION_MODES = ["Mask input", "Source alpha"]
OUTPUT_MODES = ["Comp", "Layer", "Bypass"]
OUTPUT_TOOLTIP = ("Comp: the fill blended over Source through the expanded, feathered selection.\n"
                  "Layer: just the generated fill in Source's format, premultiplied by the "
                  "expanded, feathered selection (alpha included), ready to Merge over anything. "
                  "Like a Photoshop generative layer with its mask.\n"
                  "Bypass: Source untouched.")
QUALITY_MODES = ["auto", "low", "medium", "high"]

PANEL_EXPR = '__import__("genfill.ui.panel", fromlist=["GenFillPanel"]).GenFillPanel()'

KNOB_CHANGED = """
try:
    import genfill.node
    genfill.node.knob_changed()
except ImportError:
    pass
"""


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def _set_frame_hold(node):
    for name in ("first_frame", "firstFrame"):
        if name in node.knobs():
            node[name].setExpression("parent.gf_frame")
            return
    raise RuntimeError("Unknown FrameHold knob layout in this Nuke version")


def _place(node, col, row):
    node.setXYpos(int(col * 140), int(row * 70))


def _make_write(name, channels, raw, col, row, inp):
    w = nuke.nodes.Write(name=name, file_type="png")
    w.setInput(0, inp)
    if "datatype" in w.knobs():
        w["datatype"].setValue("8 bit")
    w["channels"].setValue(channels)
    if "create_directories" in w.knobs():
        w["create_directories"].setValue(True)
    if raw:
        colorspace.set_raw(w, True)
    w["disable"].setValue(True)   # only enabled while GenFill renders
    w["tile_color"].setValue(0x333333FF)
    _place(w, col, row)
    return w


def backend_labels():
    return [b.label for b in backends.all_backends()]


def backend_for(node):
    label = node["gf_backend"].value()
    for b in backends.all_backends():
        if b.label == label:
            return b
    return backends.all_backends()[0]


# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------

def _build_internals(group):
    with group:
        src = nuke.nodes.Input(name=SRC_IN)
        _place(src, 0, 0)
        mask = nuke.nodes.Input(name=MASK_IN)
        _place(mask, 3, 0)

        # ---- selection matte -------------------------------------------
        sel = nuke.nodes.Switch(name=SEL_SWITCH)
        sel.setInput(0, mask)
        sel.setInput(1, src)
        sel["which"].setExpression("parent.gf_selection")
        _place(sel, 3, 1)

        grow = nuke.nodes.Dilate(name=GROW)
        grow.setInput(0, sel)
        grow["channels"].setValue("alpha")
        grow["size"].setExpression("parent.gf_expand")
        _place(grow, 3, 2)

        hold_m = nuke.nodes.FrameHold(name=HOLD_MATTE)
        hold_m.setInput(0, grow)
        _set_frame_hold(hold_m)
        _place(hold_m, 3, 3)

        mexpr = nuke.nodes.Expression(name=MASK_EXPR)
        mexpr.setInput(0, hold_m)
        for i, ch in enumerate(("rgba.red", "rgba.green", "rgba.blue", "rgba.alpha")):
            try:
                mexpr["channel%d" % i].setValue(ch)
            except Exception:
                pass  # defaults are already r, g, b, a
        mexpr["expr0"].setValue("clamp(a)")
        mexpr["expr1"].setValue("clamp(a)")
        mexpr["expr2"].setValue("clamp(a)")
        mexpr["expr3"].setValue("1-clamp(a)")
        _place(mexpr, 4, 4)

        # ---- probe (low-res selection, used to find its bounds) ---------
        probe = nuke.nodes.Reformat(name=PROBE_REFORMAT)
        probe.setInput(0, mexpr)
        probe["type"].setValue("to box")
        probe["box_fixed"].setValue(True)
        probe["resize"].setValue("distort")
        probe["filter"].setValue("Impulse")
        _place(probe, 6, 5)
        _make_write(PROBE_WRITE, "rgb", True, 6, 6, probe)

        # ---- crops sent to the model ----------------------------------
        hold_s = nuke.nodes.FrameHold(name=HOLD_SRC)
        hold_s.setInput(0, src)
        _set_frame_hold(hold_s)
        _place(hold_s, 1, 1)

        crop_s = nuke.nodes.Crop(name=CROP_SRC)
        crop_s.setInput(0, hold_s)
        crop_s["reformat"].setValue(True)
        _place(crop_s, 1, 2)
        ref_s = nuke.nodes.Reformat(name=REFORMAT_SRC)
        ref_s.setInput(0, crop_s)
        ref_s["type"].setValue("to box")
        ref_s["box_fixed"].setValue(True)
        ref_s["resize"].setValue("distort")
        _place(ref_s, 1, 3)
        _make_write(WRITE_SRC, "rgb", False, 1, 4, ref_s)

        crop_m = nuke.nodes.Crop(name=CROP_MASK)
        crop_m.setInput(0, mexpr)
        crop_m["reformat"].setValue(True)
        _place(crop_m, 4, 5)
        ref_m = nuke.nodes.Reformat(name=REFORMAT_MASK)
        ref_m.setInput(0, crop_m)
        ref_m["type"].setValue("to box")
        ref_m["box_fixed"].setValue(True)
        ref_m["resize"].setValue("distort")
        _place(ref_m, 4, 6)
        _make_write(WRITE_MASK, "rgb", True, 4, 7, ref_m)
        _make_write(WRITE_MASK_A, "rgba", True, 5, 7, ref_m)

        # ---- result coming back --------------------------------------
        read = nuke.nodes.Read(name=READ_RESULT)
        if "on_error" in read.knobs():
            read["on_error"].setValue("checkerboard")
        _place(read, 0, 6)

        ref_r = nuke.nodes.Reformat(name=REFORMAT_RECV)
        ref_r.setInput(0, read)
        ref_r["type"].setValue("to box")
        ref_r["box_fixed"].setValue(True)
        ref_r["resize"].setValue("distort")
        _place(ref_r, 0, 7)

        place = nuke.nodes.Transform(name=TRANSFORM_RECV)
        place.setInput(0, ref_r)
        place["filter"].setValue("Impulse")
        _place(place, 0, 8)

        feather = nuke.nodes.Blur(name=FEATHER)
        feather.setInput(0, hold_m)
        feather["channels"].setValue("alpha")
        feather["size"].setExpression("parent.gf_feather")
        _place(feather, 2, 8)

        comp = nuke.nodes.Merge2(name=COMP)
        comp.setInput(0, src)       # B
        comp.setInput(1, place)     # A
        comp.setInput(2, feather)   # mask
        comp["operation"].setValue("copy")
        comp["Achannels"].setValue("rgb")
        comp["output"].setValue("rgb")
        comp["maskChannelMask"].setValue("rgba.alpha")
        _place(comp, 1, 10)

        cp = nuke.nodes.Copy(name=COPY_ALPHA)
        cp.setInput(0, place)
        cp.setInput(1, feather)
        cp["from0"].setValue("rgba.alpha")
        cp["to0"].setValue("rgba.alpha")
        _place(cp, 0, 10)
        pm = nuke.nodes.Premult(name=PREMULT)
        pm.setInput(0, cp)
        _place(pm, 0, 11)

        out_sw = nuke.nodes.Switch(name=OUT_SWITCH)
        out_sw.setInput(0, comp)
        out_sw.setInput(1, pm)
        out_sw.setInput(2, src)
        out_sw["which"].setExpression("parent.gf_has_result ? parent.gf_output : 2")
        _place(out_sw, 1, 12)

        out = nuke.nodes.Output()
        out.setInput(0, out_sw)
        _place(out, 1, 13)
    _build_layer(group)


def _build_layer(group):
    """Layer output: the premultiplied fill merged over a transparent copy of
    Source, so it has Source's format (the raw patch only has the crop's)."""
    with group:
        src = group.node(SRC_IN)
        pm = group.node(PREMULT)
        out_sw = group.node(OUT_SWITCH)
        blank = nuke.nodes.Remove(name=BLANK)
        blank.setInput(0, src)
        blank["operation"].setValue("remove")
        blank["channels"].setValue("all")
        _place(blank, -1, 10)
        layer = nuke.nodes.Merge2(name=LAYER)
        layer.setInput(0, blank)    # B: empty, Source's format
        layer.setInput(1, pm)       # A: fill premultiplied by feathered selection
        layer["operation"].setValue("over")
        _place(layer, -1, 11)
        out_sw.setInput(1, layer)


def ensure_current(group):
    """Upgrade nodes made by older GenFill versions (called when the panel opens)."""
    changed = False
    if group.node(LAYER) is None and group.node(PREMULT) is not None \
            and group.node(OUT_SWITCH) is not None and group.node(SRC_IN) is not None:
        _build_layer(group)
        changed = True
    knob = group.knobs().get("gf_output")
    if knob is not None and list(knob.values()) != OUTPUT_MODES:
        idx = int(knob.getValue())
        knob.setValues(OUTPUT_MODES)
        knob.setValue(idx)
        knob.setTooltip(OUTPUT_TOOLTIP)
        changed = True
    return changed


def _add_knobs(group):
    tab = nuke.Tab_Knob("gf_tab", "Generative Fill")
    group.addKnob(tab)

    panel = nuke.PyCustom_Knob("gf_panel", "", PANEL_EXPR)
    panel.setFlag(nuke.STARTLINE)
    group.addKnob(panel)

    group.addKnob(nuke.Text_Knob("gf_div_sel", "Selection"))
    k = nuke.Enumeration_Knob("gf_selection", "selection from", SELECTION_MODES)
    k.setTooltip("Where the area to fill comes from: the Mask input's alpha "
                 "(e.g. a Roto) or the Source's own alpha.")
    group.addKnob(k)
    k = nuke.Double_Knob("gf_expand", "expand")
    k.setRange(0, 50)
    k.setValue(4)
    k.setTooltip("Grow the selection before generating (pixels). Like Select > Modify > Expand.")
    group.addKnob(k)
    k = nuke.Double_Knob("gf_feather", "feather")
    k.setRange(0, 100)
    k.setValue(8)
    k.setTooltip("Soften the edge where the fill is blended back into the plate.")
    group.addKnob(k)
    k = nuke.Enumeration_Knob("gf_output", "output", OUTPUT_MODES)
    k.setTooltip(OUTPUT_TOOLTIP)
    group.addKnob(k)

    # ---- Settings tab ----------------------------------------------------
    group.addKnob(nuke.Tab_Knob("gf_settings_tab", "Settings"))
    k = nuke.Enumeration_Knob("gf_backend", "model", backend_labels())
    k.setTooltip("Which generator to use. API keys are set with the API Keys button, "
                 "never saved in the script.")
    group.addKnob(k)
    k = nuke.String_Knob("gf_model", "model version", "")
    k.setTooltip("Optional model override, e.g. gpt-image-1.5. Empty = backend default.")
    group.addKnob(k)
    k = nuke.Enumeration_Knob("gf_quality", "quality", QUALITY_MODES)
    k.setTooltip("Passed to backends that support it (OpenAI).")
    group.addKnob(k)
    k = nuke.Int_Knob("gf_variations", "variations")
    k.setValue(3)
    k.setTooltip("Variations per Generate click. Photoshop gives 3.")
    group.addKnob(k)
    k = nuke.Int_Knob("gf_seed", "seed")
    k.setValue(0)
    k.setTooltip("0 = new random seed every time (Photoshop behaviour).")
    group.addKnob(k)
    k = nuke.String_Knob("gf_negative", "negative prompt", "")
    k.setTooltip("What to avoid (Stability only).")
    group.addKnob(k)

    group.addKnob(nuke.Text_Knob("gf_div_ctx", "Context"))
    k = nuke.Double_Knob("gf_context", "context")
    k.setRange(0.0, 2.0)
    k.setValue(0.35)
    k.setTooltip("How much surrounding image to send, as a fraction of the selection size. "
                 "More context = better matching, less detail.")
    group.addKnob(k)
    k = nuke.Int_Knob("gf_min_size", "min region")
    k.setValue(512)
    k.setTooltip("Smallest crop sent to the model, in plate pixels.")
    group.addKnob(k)

    group.addKnob(nuke.Text_Knob("gf_div_color", "Color"))
    k = nuke.String_Knob("gf_transfer", "8-bit colorspace", colorspace.DEFAULT)
    k.setTooltip("Colorspace used for the 8-bit round trip to the model (Write out, Read back). "
                 "'default' = the project's 8-bit files setting. Use your display / sRGB "
                 "texture space name to override.")
    group.addKnob(k)

    group.addKnob(nuke.Text_Knob("gf_div_files", "Files"))
    k = nuke.File_Knob("gf_cache_dir", "cache folder")
    k.setTooltip("Where generated images are stored. Empty = <script folder>/genfill_cache.")
    group.addKnob(k)
    k = nuke.PyScript_Knob("gf_keys_btn", "API Keys...",
                           "import genfill.ui.settings; genfill.ui.settings.show()")
    k.setFlag(nuke.STARTLINE)
    group.addKnob(k)
    group.addKnob(nuke.PyScript_Knob("gf_open_cache_btn", "Open Cache Folder",
                                     "import genfill.engine; genfill.engine.open_cache(nuke.thisNode())"))
    k = nuke.Int_Knob("gf_frame", "reference frame")
    k.setTooltip("Frame the selected variation was generated on. The fill is held from it.")
    k.setFlag(nuke.READ_ONLY)
    group.addKnob(k)

    # ---- hidden state ----------------------------------------------------
    for knob in (nuke.Boolean_Knob("gf_has_result", "has result"),
                 nuke.String_Knob("gf_prompt", "prompt", ""),
                 nuke.String_Knob("gf_info", "info", ""),
                 nuke.String_Knob("gf_uid", "uid", uuid.uuid4().hex[:12]),
                 nuke.Multiline_Eval_String_Knob("gf_state", "state", "")):
        knob.setFlag(nuke.INVISIBLE)
        group.addKnob(knob)


def create():
    """Menu entry point: create a GenerativeFill node (plus a Roto for the selection)."""
    selected = nuke.selectedNodes()
    upstream = selected[0] if len(selected) == 1 else None
    for n in nuke.allNodes():
        n.setSelected(False)

    group = nuke.nodes.Group()
    group.setName(NODE_CLASS_LABEL, uncollide=True)
    # Knobs first: the internal nodes' expressions reference parent.gf_*,
    # and Nuke reports "Nothing is named parent.gf_frame" if they don't exist yet.
    _add_knobs(group)
    _build_internals(group)
    group["knobChanged"].setValue(KNOB_CHANGED)
    group["tile_color"].setValue(TILE_COLOR)
    group["label"].setValue("[value gf_info]")
    group["help"].setValue("Photoshop-style Generative Fill. Draw a selection with the "
                           "attached Roto (or use the Source alpha), type a prompt (or leave "
                           "it empty to remove), and click Generate.")

    if upstream is not None:
        group.setInput(0, upstream)
        group.setXYpos(upstream.xpos(), upstream.ypos() + 90)
    # A Roto for the selection, like a marquee/lasso in Photoshop.
    roto = nuke.nodes.Roto()
    roto.setName("GenFillSelection", uncollide=True)
    roto["output"].setValue("alpha")
    if "replace" in roto.knobs():
        # Shapes replace the alpha instead of merging with the plate's alpha,
        # so a plate with a solid alpha doesn't select the whole frame.
        roto["replace"].setValue(True)
    if upstream is not None:
        roto.setInput(0, upstream)   # gives the Roto the plate's format
    roto.setXYpos(group.xpos() + 150, group.ypos() - 30)
    group.setInput(1, roto)
    group["gf_selection"].setValue(0)

    group.setSelected(True)
    if nuke.GUI:
        nuke.show(group)
    return group


# --------------------------------------------------------------------------
# callbacks
# --------------------------------------------------------------------------

def knob_changed():
    node = nuke.thisNode()
    knob = nuke.thisKnob()
    name = knob.name()
    if name == "inputChange":
        has_mask = node.input(1) is not None
        if has_mask and node["gf_selection"].getValue() == 1 and node.input(0) is not None \
                and node.input(1) is not node.input(0):
            node["gf_selection"].setValue(0)
        elif not has_mask and node["gf_selection"].getValue() == 0:
            node["gf_selection"].setValue(1)
    elif name in ("gf_cache_dir", "gf_transfer", "showPanel"):
        from . import engine
        try:
            engine.refresh_result(node)
        except Exception as exc:  # never break the properties panel
            print("GenFill: could not refresh result: %s" % exc)
