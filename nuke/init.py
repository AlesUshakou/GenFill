# GenFill - Photoshop-style Generative Fill for Nuke.
# Loaded when this folder is on NUKE_PATH (or added with nuke.pluginAddPath).
import nuke

nuke.pluginAddPath("./python")
nuke.pluginAddPath("./icons")

try:
    import genfill as _genfill
    print("%s loaded from %s" % (_genfill.build_label(), _genfill.build_info()["location"]))
except Exception as _exc:  # never block Nuke startup
    print("GenFill: failed to load: %s" % _exc)
