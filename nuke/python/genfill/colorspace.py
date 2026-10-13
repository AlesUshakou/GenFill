"""Colour round trip between Nuke's working space and the model.

Image models are trained on display-referred 8-bit sRGB images, i.e. exactly
what Photoshop hands them. Nuke works scene-linear. So the node:

  1. converts the crop to the 8-bit file colourspace on the way out (Write),
  2. converts the result back with the *same* colourspace on the way in (Read),

so the round trip is an exact inverse and the generated pixels sit in the comp
in linear. Only pixels inside the selection are replaced, so the 8-bit
quantisation never touches the rest of the plate.

``default`` means "whatever this project uses for 8-bit files" (Project
Settings > Color). That follows OCIO/ACES configs automatically. Artists can
override it on the node's Settings tab with any colourspace name the Read and
Write nodes offer.

HDR roadmap (see docs/ARCHITECTURE.md): new transfer *modes* will slot in
here, e.g. log-encode to 16-bit for models that accept it, or an
exposure-normalised SDR encode with highlight reconstruction. The node calls
:func:`apply_to_write` / :func:`apply_to_read` only, so the graph doesn't
change when modes are added.
"""
from __future__ import annotations

DEFAULT = "default"

TRANSFER_MODES = [
    # (id, label, available)
    ("sdr8", "SDR 8-bit (sRGB, Photoshop-equivalent)", True),
    ("log16", "HDR log 16-bit (planned)", False),
    ("hdr_tonemap", "HDR tonemap + highlight recovery (planned)", False),
]


def _set_cs_knob(knob, name):
    """Set a Read/Write ``colorspace`` knob by name, tolerant of config naming."""
    if not name or name == DEFAULT:
        knob.setValue(0)  # first entry is always "default (...)"
        return True
    values = list(knob.values())
    # values may be "Category/name" style entries; match on the leaf too.
    for i, v in enumerate(values):
        leaf = v.split("\t")[0].split("/")[-1]
        if v == name or leaf == name:
            knob.setValue(i)
            return True
    try:
        knob.setValue(name)
        return True
    except Exception:
        return False


def apply_to_write(write_node, name):
    return _set_cs_knob(write_node["colorspace"], name)


def apply_to_read(read_node, name):
    return _set_cs_knob(read_node["colorspace"], name)


def set_raw(node, raw=True):
    """Masks must not be colour transformed."""
    if "raw" in node.knobs():
        node["raw"].setValue(bool(raw))
