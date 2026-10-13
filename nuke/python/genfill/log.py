"""GenFill's log file.

Every Generate click, each pipeline step and every error (with traceback) is
written to ``<repo>/test_output/genfill.log`` when the build knows its repo
(installed builds and dev mode both do), otherwise to
``~/.nuke/genfill/genfill.log``. Messages also go to the Script Editor.
Set ``GENFILL_LOG`` to log somewhere else (the tests do).
"""
from __future__ import annotations

import logging
import os
import sys

_LOGGER_NAME = "genfill"
_MAX_BYTES = 2 * 1024 * 1024


def log_path():
    override = os.environ.get("GENFILL_LOG")
    if override:
        return override
    import genfill
    repo = genfill.repo_root()
    if repo:
        return os.path.join(repo, "test_output", "genfill.log")
    return os.path.join(os.path.expanduser("~"), ".nuke", "genfill", "genfill.log")


def get():
    logger = logging.getLogger(_LOGGER_NAME)
    if getattr(logger, "_genfill_ready", False):
        return logger
    logger.setLevel(logging.DEBUG)
    logger.propagate = False
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(message)s", "%Y-%m-%d %H:%M:%S")
    try:
        path = log_path()
        folder = os.path.dirname(path)
        if not os.path.isdir(folder):
            os.makedirs(folder)
        if os.path.exists(path) and os.path.getsize(path) > _MAX_BYTES:
            os.replace(path, path + ".old")
        fh = logging.FileHandler(path, encoding="utf-8")
        fh.setFormatter(fmt)
        fh.setLevel(logging.DEBUG)
        logger.addHandler(fh)
    except Exception as exc:  # logging must never break the tool
        sys.stderr.write("GenFill: could not open log file: %s\n" % exc)
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(logging.Formatter("GenFill %(levelname)s: %(message)s"))
    sh.setLevel(logging.INFO)
    logger.addHandler(sh)
    logger._genfill_ready = True
    try:
        import genfill
        import nuke
        logger.info("---- %s | Nuke %s | Python %s | GUI=%s ----", genfill.build_label(),
                    getattr(nuke, "NUKE_VERSION_STRING", "?"), sys.version.split()[0],
                    getattr(nuke, "GUI", "?"))
    except Exception:
        pass
    return logger


def debug(msg, *args):
    get().debug(msg, *args)


def info(msg, *args):
    get().info(msg, *args)


def warning(msg, *args):
    get().warning(msg, *args)


def error(msg, *args):
    get().error(msg, *args)


def exception(msg, *args):
    """Log an error with the current traceback."""
    get().exception(msg, *args)
