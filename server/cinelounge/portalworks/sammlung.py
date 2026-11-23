"""A level sorted over all of its pages (AP60, 30.09.2026).

**The owner's condition:** sorted by rating, page one may not show a 6 before an
8 from page three. Sorting the loaded page on the device breaks exactly that,
and many sites cannot sort (a collection without an order to ask for). So the
server fetches the whole level once, sorts it, and hands it out in pages of its
own.

**Measured, and the reason for the background:** a page from the portal's
cache comes in 0.1 s, a fresh one in 4-5 s. A large collection is 38 pages —
about three minutes the first time. No request waits that long; until
the level is complete the answer is `preparing` with the count so far, and the
app asks again. Afterwards the level stays for `HALTEN_S`.
"""

from __future__ import annotations

import threading
import time
from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Final

from cinelounge.core import errors as f

SORTEN: Final = frozenset({"title", "rating", "year"})
SEITE: Final = 48
# A level beyond this is not sorted any further, and the answer says so
# (`truncated`). 1500 is about 62 pages of a typical site; the largest
# collection seen has 900.
HOECHSTENS: Final = 1500
HALTEN_S: Final = 6 * 3600
_BESTAENDE_HOECHSTENS: Final = 16

Holer = Callable[[str | None], dict[str, Any]]


@dataclass
class _Bestand:
    items: list[dict[str, Any]] = field(default_factory=list)
    fertig: bool = False
    abgeschnitten: bool = False
    fehler: str | None = None
    seit: float = field(default_factory=time.time)


_BESTAENDE: OrderedDict[tuple[str, ...], _Bestand] = OrderedDict()
_SPERRE = threading.Lock()
# **One collector at a time.** Every page is a run of the portal in a child
# process and a request to the site; two levels at once would double both for
# nobody's benefit — the second viewer waits the same either way.
_EINER = threading.Semaphore(1)


def _sammeln(b: _Bestand, holen: Holer) -> None:
    with _EINER:
        weiter: str | None = None
        try:
            while True:
                seite = holen(weiter)
                neu = list(seite.get("items") or [])
                with _SPERRE:
                    b.items.extend(neu)
                weiter = seite.get("next_page")
                if not weiter:
                    break
                if len(b.items) >= HOECHSTENS:
                    b.abgeschnitten = True
                    break
        except Exception as err:
            b.fehler = str(getattr(err, "code", "") or type(err).__name__)
        finally:
            with _SPERRE:
                b.fertig = True
                b.seit = time.time()


def _bestand(schluessel: tuple[str, ...], holen: Holer, im_hintergrund: bool) -> _Bestand:
    neu = False
    with _SPERRE:
        b = _BESTAENDE.get(schluessel)
        if b and b.fertig and time.time() - b.seit > HALTEN_S:
            b = None
        if b is None:
            b = _Bestand()
            _BESTAENDE[schluessel] = b
            neu = True
            while len(_BESTAENDE) > _BESTAENDE_HOECHSTENS:
                _BESTAENDE.popitem(last=False)
        _BESTAENDE.move_to_end(schluessel)
    if neu:
        if im_hintergrund:
            threading.Thread(target=_sammeln, args=(b, holen), daemon=True).start()
        else:
            _sammeln(b, holen)
    return b


def ordnen(items: list[dict[str, Any]], sort: str, absteigend: bool) -> list[dict[str, Any]]:
    """Stable, and whatever has no value goes last — in both directions.

    A missing rating as zero would put forty unrated titles on top of the
    ascending order, which answers no question anybody asked.
    """
    if sort == "title":
        return sorted(items, key=lambda i: str(i.get("title") or "").casefold(), reverse=absteigend)
    feld = "rating" if sort == "rating" else "year"
    mit = [i for i in items if isinstance(i.get(feld), int | float)]
    ohne = [i for i in items if not isinstance(i.get(feld), int | float)]
    mit.sort(key=lambda i: float(i[feld]), reverse=absteigend)
    return mit + ohne


def seite(
    schluessel: tuple[str, ...],
    holen: Holer,
    sort: str,
    absteigend: bool,
    ab: int,
    *,
    im_hintergrund: bool = True,
) -> dict[str, Any]:
    """One page of the sorted level — or how far the collecting has come."""
    b = _bestand(schluessel, holen, im_hintergrund)
    with _SPERRE:
        fertig, fehler, gesammelt = b.fertig, b.fehler, len(b.items)
        items = list(b.items) if fertig else []
    if fehler:
        # Dropped, so that the next attempt starts over instead of repeating
        # the failure for six hours.
        with _SPERRE:
            if _BESTAENDE.get(schluessel) is b:
                del _BESTAENDE[schluessel]
        raise f.Error("list.sort_failed", {"why": fehler}, status=502)
    if not fertig:
        return {"items": [], "total": None, "next_page": None, "preparing": {"done": gesammelt}}
    geordnet = ordnen(items, sort, absteigend)
    ende = ab + SEITE
    return {
        # Copies: the route writes each viewer's progress into the entries.
        "items": [dict(i) for i in geordnet[ab:ende]],
        "total": len(geordnet),
        "next_page": f"@{ende}" if ende < len(geordnet) else None,
        "truncated": b.abgeschnitten,
    }


def stelle(marke: str | None) -> int:
    """The position a `next` marker of this module stands for — 0 for anything else."""
    if marke and marke.startswith("@") and marke[1:].isdigit():
        return int(marke[1:])
    return 0
