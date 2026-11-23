"""One fetch for many askers — and a memory that serves while it refreshes.

**Measured on the device (AP63, 01.10.2026):** at app start the television sent
every portal list twice, and `/list` had no memory at all. Each request forked
its own child and went cold to the site; when one of them hung until the
20-second deadline, the others were held up with it. The same level asked twice
within seconds is one fetch here, and asked again within `FRIST_S` it is none.

**Stale while revalidating (AP74, 11.10.2026):** 11 of 164 `/list` in 48 hours
ran into the 20-second deadline, mostly as the first request after hours of
quiet — and the same level answered in under a second two minutes later. Until
then an answer older than `FRIST_S` was simply gone, and the viewer waited for
the cold fetch. Now an answer stays for `ALT_S`. Asked after `FRIST_S`, it is
handed out at once and renewed in the background; if the renewal fails or times
out, the old answer stays and the next attempt waits `NACHLAUF_S`. Only the very
first ask for a level still waits for the site.

**Only answers, never failures,** and never a page that says it is still being
prepared — that one is meant to be asked again. What comes out is a copy: the
web layer writes the person's progress into the items.
"""

from __future__ import annotations

import copy
import logging
import threading
import time
from collections.abc import Callable, Hashable
from dataclasses import dataclass
from typing import Any

_LOG = logging.getLogger("cinelounge.einmal")

FRIST_S = 90.0
"""How long an answer counts as fresh."""
ALT_S = 6 * 3600.0
"""How long a stale answer is still handed out while a renewal runs."""
NACHLAUF_S = 30.0
"""How long a failed renewal keeps the next one from starting."""


@dataclass
class _Antwort:
    wert: Any
    frisch_bis: float
    gemerkt: float

    def frisch(self, jetzt: float) -> bool:
        return self.frisch_bis > jetzt

    def brauchbar(self, jetzt: float) -> bool:
        return self.gemerkt + ALT_S > jetzt


_ANTWORTEN: dict[Hashable, _Antwort] = {}
_LAEUFT: dict[Hashable, _Lauf] = {}
_SPERRE = threading.Lock()


class _Lauf:
    def __init__(self) -> None:
        self.fertig = threading.Event()
        self.wert: Any = None
        self.fehler: BaseException | None = None


def _merkbar(wert: Any) -> bool:
    return not (isinstance(wert, dict) and wert.get("preparing"))


def _merken(schluessel: Hashable, wert: Any, frist_s: float) -> None:
    jetzt = time.time()
    with _SPERRE:
        _ANTWORTEN[schluessel] = _Antwort(wert, jetzt + frist_s, jetzt)
        if len(_ANTWORTEN) > 300:
            for k in [k for k, a in _ANTWORTEN.items() if not a.brauchbar(jetzt)]:
                _ANTWORTEN.pop(k, None)


def _erneuern(schluessel: Hashable, holen: Callable[[], Any], frist_s: float) -> None:
    """In the background: fetch again, keep the old answer when it fails."""
    lauf = _LAEUFT[schluessel]
    try:
        wert = holen()
        lauf.wert = wert
        if _merkbar(wert):
            _merken(schluessel, wert, frist_s)
    except BaseException as err:
        lauf.fehler = err
        with _SPERRE:
            alt = _ANTWORTEN.get(schluessel)
            if alt is not None:
                alt.frisch_bis = time.time() + NACHLAUF_S
        _LOG.warning("%r: renewal failed (%s), keeping the old answer", schluessel, err)
    finally:
        with _SPERRE:
            _LAEUFT.pop(schluessel, None)
        lauf.fertig.set()


def einmal(schluessel: Hashable, holen: Callable[[], Any], frist_s: float = FRIST_S) -> Any:
    """`holen()` once for all who ask the same at the same time; remembered for `frist_s`.

    A stale answer (older than `frist_s`, younger than `ALT_S`) is returned at
    once while one background renewal runs; see the module docstring.
    """
    jetzt = time.time()
    with _SPERRE:
        gemerkt = _ANTWORTEN.get(schluessel)
        if gemerkt is not None and not gemerkt.brauchbar(jetzt):
            _ANTWORTEN.pop(schluessel, None)
            gemerkt = None
        if gemerkt is not None and gemerkt.frisch(jetzt):
            return copy.deepcopy(gemerkt.wert)
        lauf = _LAEUFT.get(schluessel)
        eigener = lauf is None
        if lauf is None:
            lauf = _LAEUFT[schluessel] = _Lauf()
        if gemerkt is not None:
            # Stale: serve what is there and renew in the background — one
            # renewal per key, the others just take the old answer too.
            if eigener:
                threading.Thread(
                    target=_erneuern,
                    args=(schluessel, holen, frist_s),
                    name="einmal-erneuern",
                    daemon=True,
                ).start()
            return copy.deepcopy(gemerkt.wert)
    if not eigener:
        lauf.fertig.wait()
        if lauf.fehler is not None:
            raise lauf.fehler
        return copy.deepcopy(lauf.wert)
    try:
        wert = holen()
        lauf.wert = wert
        if _merkbar(wert):
            _merken(schluessel, wert, frist_s)
        return copy.deepcopy(wert)
    except BaseException as err:
        lauf.fehler = err
        raise
    finally:
        with _SPERRE:
            _LAEUFT.pop(schluessel, None)
        lauf.fertig.set()


def erneuerung_abwarten(schluessel: Hashable, hoechstens_s: float = 5.0) -> None:
    """For tests: wait until a background renewal of `schluessel` has ended."""
    with _SPERRE:
        lauf = _LAEUFT.get(schluessel)
    if lauf is not None:
        lauf.fertig.wait(hoechstens_s)


def vergiss() -> None:
    """For tests."""
    with _SPERRE:
        _ANTWORTEN.clear()
