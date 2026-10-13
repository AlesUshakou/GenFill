"""PySide6 (Nuke 16+) / PySide2 (Nuke 13-15) compatibility shim."""
try:
    from PySide6 import QtCore, QtGui, QtWidgets  # noqa: F401
    QT6 = True
except ImportError:  # pragma: no cover - depends on Nuke version
    from PySide2 import QtCore, QtGui, QtWidgets  # noqa: F401
    QT6 = False

Qt = QtCore.Qt


def exec_(obj):
    """QDialog/QMenu exec that works on both bindings."""
    return obj.exec() if hasattr(obj, "exec") else obj.exec_()
