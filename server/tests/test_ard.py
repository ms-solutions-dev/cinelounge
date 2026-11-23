"""ARD — films as `poster` tiles and the "Reihe" as a series.

**The fixtures are synthetic** (written by `intern/fixtures-synth/portals.py`)
in the shape of the library's answers from 16.11.2026, with invented titles:
`einstieg-filme.json` is the category "Filme" (navigation row, a row of film
posters, a row of "Reihen"), `gruppe-reihe.json` the group page of a "Reihe"
of kind `INFINITE_SERIES`.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

WURZEL = Path(__file__).resolve().parent.parent
ORDNER = WURZEL / "portals" / "ard"


@pytest.fixture(scope="module")
def ard():
    spec = importlib.util.spec_from_file_location("portal_ard_test", ORDNER / "portal.py")
    assert spec and spec.loader
    modul = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = modul
    spec.loader.exec_module(modul)
    return modul


def _vorlage(name: str) -> dict:
    return json.loads((ORDNER / "vorlagen" / name).read_text(encoding="utf-8"))


def _portal(ard, antworten: dict[str, str]):
    """A portal whose fetcher answers from fixtures by address fragment."""

    def hole(address: str) -> dict:
        for teil, datei in antworten.items():
            if teil in address:
                return _vorlage(datei)
        raise AssertionError(f"unexpected address: {address}")

    return ard.Portal(fetch=hole)


def test_films_page_lists_poster_tiles(ard):
    """The first row with content is the row of films, not the row of series."""
    portal = _portal(ard, {"/editorial/filme": "einstieg-filme.json"})
    page = portal.listing("filme")

    assert [i.title for i in page.items] == [
        "Kreidezeit | Kriminalfilm",
        "Ziegelrot | Komödie über eine Dachdeckerin",
        "Sommer im Pumpwerk | Jugendfilm",
    ]
    for item in page.items:
        assert item.kind == "episode"
        assert not item.has_children
        assert "/item/" in item.address
        assert item.duration_min
    # The next row (the "Reihen") stays reachable.
    assert page.next_page == "2"


def test_infinite_series_is_a_series(ard):
    """A "Reihe" without seasons opens as a series with episodes beneath."""
    portal = _portal(
        ard,
        {
            "/editorial/filme": "einstieg-filme.json",
            "/grouping/": "gruppe-reihe.json",
        },
    )
    page = portal.listing("filme", next_page="2")
    reihe = next(i for i in page.items if i.title == "Kanzlei Brookmann | Reihe")

    assert reihe.kind == "series"
    assert reihe.has_children
    assert reihe.show is None

    folgen = portal.children(reihe)
    assert [f.title for f in folgen] == [
        "Kanzlei Brookmann - Der Fall Ostrowski",
        "Kanzlei Brookmann - Der Fall Ostrowski (Audiodeskription)",
    ]
    assert all(f.kind == "episode" and "/item/" in f.address for f in folgen)
