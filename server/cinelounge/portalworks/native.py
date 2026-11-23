"""The core's own portal kind: `native` — a `portal.py` beside the manifest.

Registered at import time as a core entry of `extension.KINDS`, so that it
stands first and survives every reset. `manifest.py` imports this module; a
manifest is therefore never read against a register without `native`.

Rank 0: a native portal speaks the interface its author wrote for it, mostly
a broadcaster's official one. When the same title stands in several portals,
that source goes first — it stays reachable whatever happens to the others.
"""

from __future__ import annotations

import importlib.util
import sys
from typing import TYPE_CHECKING, Any

from cinelounge.core import errors as f
from cinelounge.portalworks.extension import KINDS, KindSpec

if TYPE_CHECKING:
    from cinelounge.portalworks.manifest import Manifest

__all__ = ["NAME", "build", "validate"]

NAME = "native"

#: The file a native portal's code lives in, beside `portal.yml`.
CODE_FILE = "portal.py"


def build(m: Manifest) -> Any:  # inside the child only
    """Load `portal.py` from the portal's folder and return its `Portal()`."""
    file = m.folder / CODE_FILE
    name = "portal_" + m.id
    spec = importlib.util.spec_from_file_location(name, file)
    if spec is None or spec.loader is None:
        raise f.Error(f.PORTAL_BROKEN, {"id": m.id, "why": "not loadable"})
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module.Portal()


def validate(m: Manifest) -> str | None:
    if not (m.folder / CODE_FILE).exists():
        return f"kind: {NAME} without {CODE_FILE}"
    return None


KINDS.add_core(KindSpec(NAME, build=build, rank=0, validate=validate))
