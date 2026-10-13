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
