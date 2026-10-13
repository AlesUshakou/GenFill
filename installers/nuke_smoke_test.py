"""Entry point for `Nuke -t installers/nuke_smoke_test.py` (terminal mode).

Uses whichever GenFill build init.py loaded (normally the one install.ps1
installed). If GenFill isn't installed, falls back to this repo's source.
"""
import os
import sys

import nuke  # noqa: F401  (provided by Nuke)

try:
    import genfill  # noqa: F401
except ImportError:
    here = os.path.dirname(os.path.abspath(sys.argv[0] if sys.argv and sys.argv[0] else "."))
    sys.path.insert(0, os.path.join(here, "..", "nuke", "python"))
    import genfill  # noqa: F401

import genfill.devtools as devtools

print(genfill.build_label())
ok = devtools.run_smoke_test(show_result=False)
sys.exit(0 if ok else 1)
