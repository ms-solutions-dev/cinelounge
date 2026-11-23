"""ZDF and 3sat — the conversion of a real answer, without the network.

**Because of the running time that never stood on a tile.** `_als_item()` read
`attributes.duration.value` and divided by 60000. Two faults that hid each
other: `attributes` is `null` on every item measured, so no number ever
arrived, so the wrong unit never showed. `None` stood on every tile of both
broadcasters for as long as the portals have existed.

Measured 11.09.2026: the running time stands in `mainVideoContent` and is in
**seconds**. 472 to 5313 — as seconds 7.9 to 88.5 minutes, as milliseconds
fractions of a minute.

**The fixtures under `portals/*/vorlagen/` are synthetic**, written by
`intern/fixtures-synth/portals.py` in the shape of answers fetched on
11.09.2026, with invented titles. A test that went to the network instead
would be red on the day the broadcaster coughs, and would then say something
about the broadcaster.

Three hits per broadcaster, and the selection is deliberate: **two with a
stream, one without.** A search also delivers announcements as measured
(`hasVideo: false`, `currentVideoType: novideo`) — that they drop out is part
of what is checked.

Left out are `programmeItem`, `tracking` and `docstats`: schedule no portal
reads. A fixture is a test piece and not an archive.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

WURZEL = Path(__file__).resolve().parent.parent
SENDER = ("zdf", "3sat")


def _portal_modul(kennung: str):
    """Like the runner in the child: via the file, not via a package path."""
    datei = WURZEL / "portals" / kennung / "portal.py"
    spec = importlib.util.spec_from_file_location(f"portal_{kennung}_fam", datei)
    assert spec and spec.loader
    modul = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = modul
    spec.loader.exec_module(modul)
    return modul


def _vorlage(kennung: str) -> list[dict]:
    roh = json.loads(
        (WURZEL / "portals" / kennung / "vorlagen" / "suche.json").read_text(encoding="utf-8")
    )
    return roh["http://zdf.de/rels/search/results"]


@pytest.mark.parametrize("kennung", SENDER)
def test_die_vorlage_ist_eine_echte_antwort(kennung: str) -> None:
    treffer = _vorlage(kennung)
    assert treffer, "leere Vorlage"
    for t in treffer:
        assert "http://zdf.de/rels/target" in t


@pytest.mark.parametrize("kennung", SENDER)
def test_laufzeit_kommt_an_und_ist_plausibel(kennung: str) -> None:
    """**The test this file exists for.**

    A media library broadcasts between one minute and three hours. What lies
    outside that is not a running time but a unit.
    """
    modul = _portal_modul(kennung)
    gesehen = 0
    for t in _vorlage(kennung):
        ziel = t.get("http://zdf.de/rels/target") or {}
        item = modul._als_item(ziel)
        if item is None:
            continue
        mv = (ziel.get("mainVideoContent") or {}).get("http://zdf.de/rels/target") or {}
        if not mv.get("duration"):
            # Happens: announcements without a stream. Then `None` is right.
            assert item.duration_min is None
            continue
        gesehen += 1
        assert item.duration_min is not None, f"{item.title}: keine Laufzeit"
        assert 1 <= item.duration_min <= 180, f"{item.title}: {item.duration_min} min"
        # And the unit is right to the minute.
        assert item.duration_min == round(mv["duration"] / 60)
    assert gesehen, f"{kennung}: no item with a running time in the fixture"


@pytest.mark.parametrize("kennung", SENDER)
def test_ein_beitrag_ohne_strom_faellt_heraus(kennung: str) -> None:
    """No `ptmd-template`, no entry.

    A title in the list that does nothing when tapped is worse than one that
    is missing.
    """
    modul = _portal_modul(kennung)
    ohne = {"teaserHeadline": "Trailer ohne Strom", "mainVideoContent": {}}
    assert modul._als_item(ohne) is None


@pytest.mark.parametrize("kennung", SENDER)
def test_die_felder_der_kachel_sind_gefuellt(kennung: str) -> None:
    modul = _portal_modul(kennung)
    gefunden = 0
    for t in _vorlage(kennung):
        item = modul._als_item(t.get("http://zdf.de/rels/target") or {})
        if item is None:
            continue
        gefunden += 1
        assert item.title
        assert item.address, "without an address the tile leads nowhere"
        assert "{playerId}" in item.address, "the address is the ptmd template"
        assert item.image, "`own_images` is declared"
        assert item.image_source == "portal"
        assert item.year and 2000 <= item.year <= 2100
    assert gefunden, f"{kennung}: not a single entry out of the fixture"


@pytest.mark.parametrize("kennung", SENDER)
def test_kennung_und_faehigkeiten_stimmen_ueberein(kennung: str) -> None:
    """The same rule as for every portal — here once more explicitly."""
    from cinelounge.portalworks import manifest as manifest_lesen

    modul = _portal_modul(kennung)
    m = manifest_lesen.read(WURZEL / "portals" / kennung / "portal.yml")
    assert m.is_ready, m.broken_reason
    assert modul.Portal.id == m.id == kennung
    assert set(modul.Portal.capabilities) == m.capabilities


def test_3sat_und_zdf_teilen_die_umwandlung_wortgleich() -> None:
    """The duplication is deliberate — but then it has to be one.

    `3sat/portal.py` is deliberately a copy: a portal travels as a single
    archive into a stranger's household, and a shared module between two portal
    folders would make a package of it. The price is that a fix has to arrive
    in two places.

    **Exactly that nearly went wrong with the running-time fault.** This test
    holds the one function it hung on against each other in both files.
    """
    import re

    stuecke = []
    for kennung in SENDER:
        quelle = (WURZEL / "portals" / kennung / "portal.py").read_text(encoding="utf-8")
        m = re.search(r"\ndef _als_item\(.*?\n    \)\n", quelle, re.S)
        assert m, f"{kennung}: `_als_item` not found"
        # Comments out: the reasoning may differ, the code may not.
        ohne = re.sub(r"^\s*#.*$", "", m.group(0), flags=re.M)
        stuecke.append(re.sub(r"\n\s*\n", "\n", ohne).strip())

    assert stuecke[0] == stuecke[1], (
        "`_als_item` ist in zdf und 3sat auseinandergelaufen — eine Reparatur "
        "ist nur an einer Stelle angekommen."
    )
