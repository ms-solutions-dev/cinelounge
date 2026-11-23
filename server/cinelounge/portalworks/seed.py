"""Put the bundled portals into the data directory.

**The service reads `/data/portals`, the image ships `/app/portals`, and there
was no path between the two.** On the home lab `deploy.sh` papered over the
gap — it mounts the source tree and calls `scripts/grundstock.py`. Whoever
merely started the container ended up with zero portals and a console that
looks like a fault.

The logic lives here because two callers need it: this module on the service's
first start, and `scripts/grundstock.py` during operation. Two copies would be
two truths about the question of what "already there" means.

## What it does not touch

**Anything that came from the marketplace** (a `.market.json` beside it): the
version there may well be newer than the bundled one, and a silent rollback is
the last thing a seed may do.

**And on startup, nothing at all once a folder is present.** `seed_if_empty()`
only creates where nothing is. An operator who changed a portal by hand finds
it untouched after the next restart — catching up is a decision and belongs on
the command line.
"""

from __future__ import annotations

import filecmp
import logging
import shutil
from pathlib import Path
from typing import Final

_LOG = logging.getLogger("cinelounge.grundstock")

#: Where the bundled portals live — `/app/portals` in the image,
#: `<root>/portals` in the source tree. The same place, seen from either side.
BUNDLED: Final = Path(__file__).resolve().parent.parent.parent / "portals"

#: What does not come along. Scaffolding of the development machine, not
#: portal content.
IGNORE: Final = shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store", "*.bruecke")

#: Portals that are only a template and never go into service.
#:
#: `beispiel` is the SDK template (see `docs/SDK.md`). It would run, and that
#: is precisely what would be wrong: a household would get a portal with six
#: test films that nobody asked for.
TEMPLATE_ONLY: Final = frozenset({"beispiel"})


def bundled() -> list[Path]:
    """The bundled portals — templates excluded, in a fixed order."""
    if not BUNDLED.is_dir():
        return []
    return [
        p
        for p in sorted(BUNDLED.iterdir())
        if p.is_dir() and (p / "portal.yml").is_file() and p.name not in TEMPLATE_ONLY
    ]


def same(a: Path, b: Path) -> bool:
    """Do both folders hold the same content?

    `shallow=False` is the whole point: with `True`, `filecmp` compares size
    and timestamp only, and a move through `tar` resets both. Two files of
    equal length with different content would count as equal.
    """
    if not b.is_dir():
        return False
    links = {p.name for p in a.iterdir() if p.name != "__pycache__"}
    rechts = {p.name for p in b.iterdir() if p.name != "__pycache__"}
    if links - rechts:
        return False
    for name in links:
        p, q = a / name, b / name
        if p.is_dir():
            if not same(p, q):
                return False
        elif not q.is_file() or not filecmp.cmp(p, q, shallow=False):
            return False
    return True


def from_market(ziel: Path) -> bool:
    """Did this portal come from the marketplace?"""
    return (ziel / ".market.json").is_file()


def seed_if_empty(ziel: Path) -> list[str]:
    """On the very first start: create the bundled portals.

    **Only into a directory without any portal at all**, and that is the
    difference from `scripts/grundstock.py`: that one compares, fills in what
    is missing and overwrites a diverging version — when told to. This one
    touches nothing as soon as any portal is present. A service that undoes an
    operator's decision on restart is worse than one that does nothing.

    **Never raises.** A portal that cannot be copied must not keep the service
    from starting; it is simply missing, and that goes into the log.
    """
    neu: list[str] = []
    try:
        ziel.mkdir(parents=True, exist_ok=True)
    except OSError as err:
        _LOG.warning("Seed: cannot create %s — %s", ziel, err)
        return neu

    # **If a portal is already there, this is not a first start.** Filling in
    # what is missing sounds helpful and is not: whoever deliberately removed
    # a bundled portal would find it back after every restart — and a service
    # that undoes the operator's decisions is worse than one that does
    # nothing. Catching up is what `scripts/grundstock.py` is for, on demand.
    if any(p.is_dir() and (p / "portal.yml").is_file() for p in ziel.iterdir()):
        return neu

    for ordner in bundled():
        drueben = ziel / ordner.name
        if drueben.exists():
            continue
        try:
            shutil.copytree(ordner, drueben, ignore=IGNORE)
        except OSError as err:
            _LOG.warning("Seed: %s not installed — %s", ordner.name, err)
            continue
        neu.append(ordner.name)

    if neu:
        _LOG.warning("Seed: installed %s portal(s) (%s).", len(neu), ", ".join(neu))
    return neu
