"""A level is sorted over all of its pages, not over the loaded one (AP60, 30.09.2026).

**The owner's condition:** sorted by rating, page one may not show a 6 before an
8 from page three.
"""

from __future__ import annotations

from typing import Any

import pytest

from cinelounge.core import errors as f
from cinelounge.portalworks import sammlung


@pytest.fixture(autouse=True)
def _leer() -> None:
    sammlung._BESTAENDE.clear()


def _holer(seiten: list[list[dict[str, Any]]]) -> Any:
    gerufen: list[str | None] = []

    def holen(weiter: str | None) -> dict[str, Any]:
        gerufen.append(weiter)
        n = int(weiter) if weiter else 0
        return {"items": seiten[n], "next_page": str(n + 1) if n + 1 < len(seiten) else None}

    holen.gerufen = gerufen  # type: ignore[attr-defined]
    return holen


def test_die_acht_von_seite_drei_steht_vor_der_sechs_von_seite_eins() -> None:
    holen = _holer(
        [
            [{"title": "Sechs", "rating": 6.0}],
            [{"title": "Ohne"}],
            [{"title": "Acht", "rating": 8.0}],
        ]
    )

    antwort = sammlung.seite(("p", "e", ""), holen, "rating", True, 0, im_hintergrund=False)

    assert [i["title"] for i in antwort["items"]] == ["Acht", "Sechs", "Ohne"]
    assert antwort["total"] == 3
    assert antwort["next_page"] is None
    assert holen.gerufen == [None, "1", "2"]


def test_ohne_wert_steht_auch_aufsteigend_hinten() -> None:
    items = [
        {"title": "b", "year": None},
        {"title": "a", "year": 2001},
        {"title": "c", "year": 1999},
    ]

    assert [i["title"] for i in sammlung.ordnen(items, "year", False)] == ["c", "a", "b"]
    assert [i["title"] for i in sammlung.ordnen(items, "title", True)] == ["c", "b", "a"]


def test_seitenweise_mit_eigener_marke() -> None:
    holen = _holer([[{"title": f"T{n:03d}"} for n in range(100)]])
    schluessel = ("p", "e", "")

    erste = sammlung.seite(schluessel, holen, "title", False, 0, im_hintergrund=False)
    zweite = sammlung.seite(schluessel, holen, "title", False, sammlung.stelle(erste["next_page"]))

    assert erste["next_page"] == "@48"
    assert zweite["items"][0]["title"] == "T048"
    assert zweite["next_page"] == "@96"
    # Once collected, not again.
    assert holen.gerufen == [None]


def test_waehrend_des_sammelns_kommt_der_stand() -> None:
    b = sammlung._Bestand(items=[{"title": "x"}] * 5)
    sammlung._BESTAENDE[("p", "e", "")] = b

    antwort = sammlung.seite(("p", "e", ""), _holer([[]]), "title", False, 0)

    assert antwort["preparing"] == {"done": 5}
    assert antwort["items"] == []


def test_ein_fehler_wird_gemeldet_und_vergessen() -> None:
    def holen(weiter: str | None) -> dict[str, Any]:
        raise f.Error("run.timeout", {"seconds": 45})

    with pytest.raises(f.Error) as fehler:
        sammlung.seite(("p", "e", ""), holen, "title", False, 0, im_hintergrund=False)

    assert fehler.value.code == "list.sort_failed"
    assert ("p", "e", "") not in sammlung._BESTAENDE


def test_die_antwort_sind_kopien() -> None:
    holen = _holer([[{"title": "a"}]])
    antwort = sammlung.seite(("p", "e", ""), holen, "title", False, 0, im_hintergrund=False)
    antwort["items"][0]["progress"] = 0.5

    wieder = sammlung.seite(("p", "e", ""), holen, "title", False, 0)

    assert "progress" not in wieder["items"][0]


def test_die_marke() -> None:
    assert sammlung.stelle("@96") == 96
    assert sammlung.stelle("f=showEntries&page=2") == 0
    assert sammlung.stelle(None) == 0
