# GenFill menu registration (GUI sessions only).
import nuke

if nuke.GUI:
    _toolbar = nuke.menu("Nodes")
    _menu = _toolbar.addMenu("GenFill", icon="GenFill.png")
    # Tab-search "Generative Fill" also finds this.
    _menu.addCommand("Generative Fill", "import genfill.node; genfill.node.create()",
                     icon="GenFill.png")
    _menu.addSeparator()
    _menu.addCommand("API Keys...", "import genfill.ui.settings; genfill.ui.settings.show()")
    _dev = _menu.addMenu("Developer")
    _dev.addCommand("Run Smoke Test", "import genfill.devtools; genfill.devtools.run_smoke_test()")
    _dev.addCommand("Reload GenFill (after installing a new build)",
                    "import genfill.devtools; genfill.devtools.reload_genfill()")
    _dev.addCommand("Build Info...", "import genfill.devtools; genfill.devtools.show_build_info()")
