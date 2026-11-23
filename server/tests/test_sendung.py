"""What a hit belongs to — `Item.show`.

**The case this field exists for.** A search for "krimireihe" over the ARD
Mediathek gave forty hits on 11.09.2026, and the first were called:

    Folge 41: Kreidespur (S04/E05)
    Folge 51: Was weg ist, bleibt weg (S04/E11)

Which show that belongs to stood beside it — the library delivers a `show`
object of its own with "Die Almwache" and "Ruhestandsrevier" in it. The
scraper threw it away, and in the living room stood a list nobody can read.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

WURZEL = Path(__file__).resolve().parent.parent


# ── The contract ────────────────────────────────────────────────────────────


def test_das_feld_ist_freiwillig():
    """A portal that knows nothing of it keeps building as before."""
    from cinelounge.core.contract import Item

    i = Item(title="Irgendwas", address="x")
    assert i.show is None


# ── ARD ─────────────────────────────────────────────────────────────────────


@pytest.fixture()
def ard():
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "ard_portal", WURZEL / "portals" / "ard" / "portal.py"
    )
    modul = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modul)
    return modul


def test_ard_traegt_die_sendung_nach(ard):
    """The shape is copied from the real answer, not invented.

    Measured at `api.ardmediathek.de/page-gateway/widgets/ard/search/vod`:
    `shortTitle` and `longTitle` are `null` throughout the `show` object,
    `title` carries the name.
    """
    kachel = {
        "type": "ondemand",
        "coreAssetType": "EPISODE",
        "longTitle": "Folge 41: Kreidespur (S04/E05)",
        "links": {"target": {"href": "https://api.ardmediathek.de/page-gateway/pages/ard/item/x"}},
        "show": {"title": "Die Almwache", "shortTitle": None, "longTitle": None},
    }
    item = ard._item(kachel)
    assert item is not None
    assert item.title == "Folge 41: Kreidespur (S04/E05)"
    assert item.show == "Die Almwache"


def test_eine_serie_traegt_sich_nicht_selbst(ard):
    """**"Krimireihe · Krimireihe" says nothing twice.**

    On a show tile the `show` object is the tile itself; the field then stays
    empty.
    """
    kachel = {
        "type": "show",
        "coreAssetType": "SERIES",
        "longTitle": "Die Almwache",
        "links": {"target": {"href": "https://api.ardmediathek.de/page-gateway/pages/ard/item/y"}},
        "show": {"title": "Die Almwache"},
    }
    item = ard._item(kachel)
    assert item is not None
    assert item.show is None


def test_ohne_show_objekt_bleibt_es_leer(ard):
    kachel = {
        "type": "ondemand",
        "coreAssetType": "EPISODE",
        "longTitle": "Ein Film",
        "links": {"target": {"href": "https://api.ardmediathek.de/page-gateway/pages/ard/item/z"}},
    }
    item = ard._item(kachel)
    assert item is not None and item.show is None


# ── And the app learns of it ────────────────────────────────────────────────


def test_die_antwort_traegt_es_mit():
    """The way from the child process into the answer — no portal, no network.

    `runner/call.py` hands an `Item` out as `asdict()`; a new field comes along
    by itself that way. That is convenient and therefore worth checking: whoever
    rebuilds it notices here.
    """
    from dataclasses import asdict

    from cinelounge.core.contract import Item

    d = asdict(Item(title="Folge 41", address="x", show="Die Almwache"))
    assert d["show"] == "Die Almwache"
    # And it survives the way through JSON — `None` stays `null`, not `""`.
    zurueck = json.loads(json.dumps(asdict(Item(title="Ein Film", address="y"))))
    assert zurueck["show"] is None
