"""Load what all portals share once — **before** the first fork.

**The trick E0 rests on.** Every child inherits the parent's memory
copy-on-write. Whatever is imported here costs the child nothing more — and,
far more importantly, it already sits **finished** in its `sys.modules` before
portal code can push its own paths in front of it.

## The standard library first

Portal code may bring packages of its own and put its folder at the front of
the search path. A package of its own named like a part of the standard
library — an old `xml` — then wins the import, and the real module is gone for
everything that child does afterwards. Imported here, before any portal code
ran, the standard library is already in `sys.modules`, and the child finds it
there. **None of this is about speed.** It is the condition under which one
portal cannot break the standard library for the next.

## Then what the kinds share

Each portal kind names the modules all its portals need (`KindSpec.preload`);
they follow the standard library. A module that fails to import costs the
portals of that kind their head start, not the service its start.

## What does NOT belong here

Portal code. The preloader loads what **all** portals of a kind share — not
one portal. Otherwise every child inherits the state of one portal, and the
isolation is gone again.
"""

from __future__ import annotations

import logging
from typing import Final

from cinelounge.portalworks import extension

_LOG = logging.getLogger("cinelounge.preload")

_LOADED = False

# The standard library first — precisely what portal code can displace.
_FIRST: Final = (
    "xml.parsers.expat",
    "xml.etree.ElementTree",
    "xml.dom.minidom",
    "sqlite3",
    "html.parser",
    "http.cookiejar",
    "urllib.request",
    "ssl",
    "hashlib",
    "base64",
    "gzip",
    "zlib",
)

# Then what is expensive and needed by everyone.
_THEN: Final = ("requests",)


def _modules() -> list[str]:
    """The standard library, the shared packages, then every kind's modules.

    Each name once, in that order; the kinds in the order they were registered.
    """
    out: list[str] = []
    for name in (*_FIRST, *_THEN, *(m for k in extension.KINDS for m in k.preload)):
        if name not in out:
            out.append(name)
    return out


def preload() -> int:
    """Import everything shared. Returns how many modules made it.

    Runs exactly once and **never raises**: a module missing here is one portal
    fewer that carries — no reason to keep the service from starting.
    """
    global _LOADED
    # **Sealed before anything else, and on every call.** What extensions
    # registered up to here is what every child inherits; a registration
    # after this line would reach some children and not others. See
    # `portalworks/extension.py`.
    extension.seal()
    if _LOADED:
        return 0
    _LOADED = True

    import importlib

    n = 0
    for name in _modules():
        try:
            importlib.import_module(name)
            n += 1
        except Exception as err:
            _LOG.warning("Preload: %s not loaded (%s)", name, err)

    _LOG.info("Preload: %d modules loaded", n)
    return n
