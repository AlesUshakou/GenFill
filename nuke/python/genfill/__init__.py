"""GenFill: Photoshop-style Generative Fill inside Nuke.

Modules that import ``nuke`` (node, engine, ui) are imported lazily so the
pure-Python parts (region math, PNG IO, state, backends) can be unit tested
outside Nuke.
"""
__version__ = "0.1.0"
