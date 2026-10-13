"""Registry of generation backends.

To add one: subclass :class:`base.Backend`, then append an instance to
``_BACKENDS``. Order here is the order shown in the node's model menu.
"""
from __future__ import annotations

from .base import Backend, BackendError, Cancelled, GenerationRequest
from .mock import MockBackend
from .openai_images import OpenAIBackend
from .stability import StabilityBackend

_BACKENDS = [StabilityBackend(), OpenAIBackend(), MockBackend()]

__all__ = ["Backend", "BackendError", "Cancelled", "GenerationRequest", "all_backends", "get"]


def all_backends():
    return list(_BACKENDS)


def ids():
    return [b.id for b in _BACKENDS]


def get(backend_id):
    for b in _BACKENDS:
        if b.id == backend_id:
            return b
    raise KeyError("Unknown GenFill backend %r" % backend_id)
