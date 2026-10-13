"""API key dialog. Keys go to ~/.nuke/genfill/config.json, never into the script."""
from __future__ import annotations

from .qt import QtWidgets, exec_
from . import style
from .. import backends, config


class KeysDialog(QtWidgets.QDialog):
    def __init__(self, focus=None, parent=None):
        super(KeysDialog, self).__init__(parent)
        self.setWindowTitle("Generative Fill - API Keys")
        self.setMinimumWidth(480)
        self.setStyleSheet(style.STYLESHEET)
        lay = QtWidgets.QVBoxLayout(self)
        intro = QtWidgets.QLabel(
            "Keys are saved on this machine only (%s) and are never written into .nk "
            "scripts. Environment variables take priority if set." % config.CONFIG_PATH)
        intro.setWordWrap(True)
        intro.setObjectName("gfMuted")
        lay.addWidget(intro)
        form = QtWidgets.QFormLayout()
        self.fields = {}
        first = None
        for b in backends.all_backends():
            if not b.needs_key:
                continue
            field = QtWidgets.QLineEdit()
            field.setEchoMode(QtWidgets.QLineEdit.Password)
            field.setText(config.load().get("api_keys", {}).get(b.id, ""))
            src = config.key_source(b.id, b.env_var)
            hint = "Using %s" % src if src else "Not set"
            field.setPlaceholderText(hint if b.env_var else "")
            field.setToolTip("%s\nEnvironment variable: %s" % (hint, b.env_var))
            form.addRow(b.label, field)
            self.fields[b.id] = field
            if b.id == focus or first is None:
                first = field
        lay.addLayout(form)
        show = QtWidgets.QCheckBox("Show keys")
        show.toggled.connect(self._toggle)
        lay.addWidget(show)
        btns = QtWidgets.QDialogButtonBox(QtWidgets.QDialogButtonBox.Save
                                          | QtWidgets.QDialogButtonBox.Cancel)
        btns.accepted.connect(self._save)
        btns.rejected.connect(self.reject)
        lay.addWidget(btns)
        if first is not None:
            first.setFocus()

    def _toggle(self, on):
        mode = QtWidgets.QLineEdit.Normal if on else QtWidgets.QLineEdit.Password
        for f in self.fields.values():
            f.setEchoMode(mode)

    def _save(self):
        for bid, field in self.fields.items():
            config.set_api_key(bid, field.text())
        self.accept()


def show(focus=None):
    """Show the dialog modally. Returns True if saved."""
    dlg = KeysDialog(focus=focus, parent=QtWidgets.QApplication.activeWindow())
    return bool(exec_(dlg))
