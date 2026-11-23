"""arte — the conversion of measured answers, without the network.

**The fixtures under `portals/arte/vorlagen/` are synthetic**, written by
`intern/fixtures-synth/portals.py` in the shape of real answers from
11.09.2026 with invented titles and addresses: the fields `_als_item()` reads,
and the cases below (web links, a film in two zones, collections).

## What is checked here in particular

**That `languages` is not among the capabilities.** arte delivers one stream
per item with eight audio versions as tracks inside; the player makes the
choice. `INHALTE.md` expected otherwise (*"really serves `languages`"*), and
the temptation to declare it anyway is there for exactly that reason. A test of
its own pins it down, reasoning included — otherwise somebody adds it at the
next review.

**That `EXTERNAL` drops out.** Several entries of the front page are web links
without a `programId` — a tile of one leads nowhere.

**That the zones are de-duplicated.** An arte page is a shelf with up to 24
zones, and the same film stands in several of them.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

WURZEL = Path(__file__).resolve().parent.parent
ORDNER = WURZEL / "portals" / "arte"


@pytest.fixture(scope="module")
def arte():
    spec = importlib.util.spec_from_file_location("portal_arte_test", ORDNER / "portal.py")
    assert spec and spec.loader
    modul = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = modul
    spec.loader.exec_module(modul)
    return modul


def _vorlage(name: str) -> dict:
    return json.loads((ORDNER / "vorlagen" / name).read_text(encoding="utf-8"))


# ── The manifest ────────────────────────────────────────────────────────────


def test_manifest_und_klasse_sagen_dasselbe(arte):
    from cinelounge.portalworks import manifest as manifest_lesen

    m = manifest_lesen.read(ORDNER / "portal.yml")
    assert m.is_ready, m.broken_reason
    assert arte.Portal.id == m.id == "arte"
    assert set(arte.Portal.capabilities) == m.capabilities


def test_languages_wird_nicht_gemeldet(arte):
    """**Deliberate, not a gap.**

    arte gives one stream per item; the eight versions are tracks in the HLS
    manifest, and the player chooses them. Declaring `languages` would promise
    the console a choice that does nothing here — eight buttons that all deliver
    the same address.

    The same holds for `subtitles`: tracks, not files.
    """
    from cinelounge.portalworks import manifest as manifest_lesen

    m = manifest_lesen.read(ORDNER / "portal.yml")
    assert "languages" not in m.capabilities
    assert "subtitles" not in m.capabilities
    assert "resolver" not in m.capabilities


# ── The conversion ──────────────────────────────────────────────────────────


def test_eine_seite_wird_zu_eintraegen(arte):
    items, _ = arte._aus_zonen(_vorlage("seite-home.json"))
    assert items, "the front page yielded not a single entry"
    for i in items:
        assert i.title
        assert i.address.startswith(("show/", "collection/"))
        assert i.image and "__SIZE__" not in i.image, "the placeholder was left standing"
        assert i.image_source == "portal"


def test_die_zonen_werden_entdoppelt(arte):
    """The same film stands in several zones — in the list once."""
    roh = _vorlage("seite-home.json")
    aus_zonen = [
        e
        for z in roh["zones"]
        for e in (z.get("content") or {}).get("data") or []
        if e.get("programId")
    ]
    items, _ = arte._aus_zonen(roh)
    adressen = [i.address for i in items]
    assert len(adressen) == len(set(adressen)), "duplicates in the list"
    assert len(items) <= len(aus_zonen)


def test_weblinks_fallen_heraus(arte):
    """`EXTERNAL` has no `programId` — a tile of one leads nowhere."""
    ohne = {"kind": {"code": "EXTERNAL"}, "title": "Haben Sie schon ein Konto?"}
    assert arte._als_item(ohne) is None
    # And everything else without an id, too.
    assert arte._als_item({"kind": {"code": "SHOW"}, "title": "x"}) is None


def test_sammlung_und_beitrag_sind_unterscheidbar(arte):
    items, _ = arte._aus_zonen(_vorlage("seite-home.json"))
    sammlungen = [i for i in items if i.has_children]
    beitraege = [i for i in items if not i.has_children]
    assert sammlungen and beitraege, "the fixture shows only one kind"

    for i in sammlungen:
        assert i.address.startswith("collection/")
        assert i.kind == "series"
        # A collection has no running time of its own — and that is `None`, not 0.
        assert i.duration_min is None
    for i in beitraege:
        assert i.address.startswith("show/")
        assert i.kind == "episode"


def test_laufzeit_in_minuten_und_plausibel(arte):
    """`duration` is in seconds. 2783 is 46 minutes, not 2783."""
    items, _ = arte._aus_zonen(_vorlage("seite-home.json"))
    mit = [i for i in items if i.duration_min is not None]
    assert mit, "no item with a running time in the fixture"
    for i in mit:
        assert 1 <= i.duration_min <= 300, f"{i.title}: {i.duration_min} min"


def test_sprachfassungen_kommen_als_auskunft_mit(arte):
    """`Item.languages` is information — which is why it is filled."""
    items, _ = arte._aus_zonen(_vorlage("seite-home.json"))
    mit = [i for i in items if i.languages]
    assert mit, "not a single entry names its versions"
    for i in mit:
        assert all(isinstance(s, str) and s for s in i.languages)


# ── Collection and search ───────────────────────────────────────────────────


def test_eine_sammlung_hat_folgen(arte):
    items, _ = arte._aus_zonen(_vorlage("sammlung.json"))
    folgen = [i for i in items if not i.has_children]
    assert len(folgen) >= 3, "the collection yielded no episodes"
    for f in folgen:
        assert f.duration_min, f"{f.title}: episode without a running time"


def test_die_suche_traegt_einen_weiter_marker(arte):
    """And that one is a complete URL — as arte names it itself."""
    items, weiter = arte._aus_zonen(_vorlage("suche-natur.json"))
    assert items
    assert weiter and weiter.startswith("https://"), f"kein Weiter-Marker: {weiter!r}"


# ── The stream ──────────────────────────────────────────────────────────────


def test_genau_eine_quelle_und_die_fassungen_im_namen(arte):
    """One address, and the versions stand beside it instead of as a choice."""
    d = _vorlage("player.json")
    attrs = d["data"]["attributes"]
    stroeme = attrs["streams"]
    assert len(stroeme) == 1, "arte gave more than one stream — the assumption no longer holds"
    assert stroeme[0]["url"].startswith("https://")
    fassungen = [v.get("shortLabel") for v in stroeme[0].get("versions") or []]
    assert len(fassungen) > 1, "the item has only one version — poor fixture"


def test_der_quellenname_hat_keine_dubletten(arte):
    """`OmU` stands there twice as measured — once Polish, once Italian."""
    versionen = [
        {"shortLabel": "DE"},
        {"shortLabel": "OmU"},
        {"shortLabel": "FR"},
        {"shortLabel": "OmU"},
    ]
    gekuerzt = list(
        dict.fromkeys(
            str(v.get("shortLabel") or v.get("code"))
            for v in versionen
            if v.get("shortLabel") or v.get("code")
        )
    )
    assert gekuerzt == ["DE", "OmU", "FR"]


def test_resolve_gibt_hls_und_erfindet_keine_aufloesung(arte):
    from cinelounge.core.contract import Source

    s = arte.Portal().resolve(Source(id="https://x/y.m3u8", name="DE, FR", address=""))
    assert s.kind == "hls"
    assert s.resolved
    assert s.address == "https://x/y.m3u8"
    # The resolution stands in the manifest and is chosen by the player. A
    # number here would be a guess.
    assert s.resolution is None
    assert s.subtitles == []


def test_series_gibt_none(arte):
    """An arte address carries no series title — and claims none."""
    assert arte.Portal().series("show/123344-000-A") is None
    assert arte.Portal().series("collection/RC-026891") is None
