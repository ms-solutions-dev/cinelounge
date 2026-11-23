"""SVT Play — the geo filter and the conversion, without the network.

**The test this is mainly about is the filter.** Measured 11.09.2026 on the
front page: 517 of 911 entries carry `restrictions.onlyAvailableInSweden`. A
portal showing all of them fills the sidebar with titles of which every second
one does not start — exactly the reason `INHALTE.md` advises against BBC
iPlayer.

The filter can be switched off (`sweden_only`), because for a household in
Sweden it would be wrong. And it is thereby also the first example of a setting
a `native` portal really reads: until 11.09.2026 the runner called
`module.Portal()` without arguments, and `settings:` in the manifest never
arrived at a native portal.

The fixtures under `portals/svt/vorlagen/` are synthetic, written by
`intern/fixtures-synth/portals.py` in the shape of real answers: three
selections with six entries each, invented names.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

WURZEL = Path(__file__).resolve().parent.parent
ORDNER = WURZEL / "portals" / "svt"


@pytest.fixture(scope="module")
def svt():
    spec = importlib.util.spec_from_file_location("portal_svt_test", ORDNER / "portal.py")
    assert spec and spec.loader
    modul = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = modul
    spec.loader.exec_module(modul)
    return modul


def _vorlage(name: str) -> dict:
    return json.loads((ORDNER / "vorlagen" / name).read_text(encoding="utf-8"))


# ── The manifest ────────────────────────────────────────────────────────────


def test_manifest_und_klasse_sagen_dasselbe(svt):
    from cinelounge.portalworks import manifest as manifest_lesen

    m = manifest_lesen.read(ORDNER / "portal.yml")
    assert m.is_ready, m.broken_reason
    assert svt.Portal.id == m.id == "svt"
    assert set(svt.Portal.capabilities) == m.capabilities


def test_die_einstellung_steht_im_manifest(svt):
    """Without it in the manifest the value never reaches the portal.

    `overlay()` only lays values over keys the manifest already carries — a
    stored value for something that does not stand there would be a silent
    setting.
    """
    from cinelounge.portalworks import manifest as manifest_lesen

    m = manifest_lesen.read(ORDNER / "portal.yml")
    schluessel = {str(e.get("key")) for e in m.settings}
    assert "sweden_only" in schluessel
    eintrag = next(e for e in m.settings if e.get("key") == "sweden_only")
    assert eintrag.get("required") is False, "the filter must not be a required field"
    assert str(eintrag.get("value")).lower() in ("nein", "no", "false", "")


# ── The filter ──────────────────────────────────────────────────────────────


def test_gesperrte_titel_fallen_heraus(svt):
    """**The most important test in this file.**"""
    p = svt.Portal()
    auswahlen = _vorlage("start.json")["selections"]
    items = p._aus_auswahlen(auswahlen)

    roh = [(it.get("item") or {}) for a in auswahlen for it in a.get("items") or []]
    gesperrt = [e for e in roh if (e.get("restrictions") or {}).get("onlyAvailableInSweden")]
    assert gesperrt, "the fixture contains no blocked title — it is no good"

    namen = {i.title for i in items}
    for e in gesperrt:
        assert e.get("name") not in namen, f"{e.get('name')!r} is blocked and still stands there"


def test_mit_der_einstellung_kommen_sie_zurueck(svt):
    p_aus = svt.Portal()
    p_an = svt.Portal()
    p_an.configure({"sweden_only": "ja"})

    auswahlen = _vorlage("start.json")["selections"]
    assert len(p_an._aus_auswahlen(auswahlen)) > len(p_aus._aus_auswahlen(auswahlen))


@pytest.mark.parametrize("wert", ["ja", "yes", "true", "1", "an", "ON", " Ja "])
def test_die_einstellung_versteht_mehrere_schreibweisen(svt, wert):
    p = svt.Portal()
    p.configure({"sweden_only": wert})
    assert p._auch_gesperrte is True


@pytest.mark.parametrize("wert", ["nein", "", "no", "false", "0", "irgendwas"])
def test_alles_andere_heisst_nein(svt, wert):
    """**When in doubt, filter.**

    A typo in the setting must not lead to the list quietly consisting half of
    titles that do not start.
    """
    p = svt.Portal()
    p.configure({"sweden_only": wert})
    assert p._auch_gesperrte is False


def test_ohne_configure_wird_gefiltert(svt):
    """A portal whose `configure` was never called filters all the same."""
    assert svt.Portal()._auch_gesperrte is False


# ── The conversion ──────────────────────────────────────────────────────────


def test_sammlung_und_beitrag_bekommen_verschiedene_adressen(svt):
    items = svt.Portal()._aus_auswahlen(_vorlage("start.json")["selections"])
    assert items

    for i in items:
        if i.has_children:
            assert i.address.startswith("series/"), i.title
            assert i.kind == "series"
            # A collection is fetched by its slug, not by the `svtId` —
            # `listablesBySlug` takes only that.
            assert "/" not in i.address.split("/", 1)[1]
        else:
            assert i.address.startswith("show/"), i.title
            assert i.kind == "episode"


def test_bilder_werden_gebaut(svt):
    """SVT delivers no image URL, only an `id` and a timestamp."""
    items = svt.Portal()._aus_auswahlen(_vorlage("start.json")["selections"])
    mit = [i for i in items if i.image]
    assert mit, "not a single image built"
    for i in mit:
        assert i.image.startswith("https://www.svtstatic.se/image/wide/")
        assert i.image_source == "portal"


def test_laufzeit_in_minuten(svt):
    items = svt.Portal()._aus_auswahlen(_vorlage("start.json")["selections"])
    mit = [i for i in items if i.duration_min is not None]
    assert mit
    for i in mit:
        assert 1 <= i.duration_min <= 400, f"{i.title}: {i.duration_min} min"


def test_der_kurzname_kommt_aus_der_play_adresse(svt):
    assert svt._slug({"urls": {"svtplay": "/vardcentralen"}}) == "vardcentralen"
    assert svt._slug({"urls": {"svtplay": "/video/abc/x/y"}}) == "video"
    assert svt._slug({}) == ""


# ── Series and search ───────────────────────────────────────────────────────


def test_eine_serie_gibt_ihre_folgen(svt):
    p = svt.Portal()
    p.configure({"sweden_only": "ja"})  # the series in the fixture is blocked throughout
    d = _vorlage("serie.json")
    auswahlen = [
        ac
        for x in d.get("listablesBySlug") or []
        for ac in x.get("associatedContent") or []
        if str(ac.get("id") or "") != "related"
    ]
    folgen = p._aus_auswahlen(auswahlen)
    assert folgen, "the series yielded no episodes"
    assert any(f.duration_min for f in folgen)


def test_upptaeck_mer_faellt_heraus(svt):
    """`related` carries other series — they do not belong beneath this entry.

    Whoever takes them along unfolds one series and finds another in it.
    """
    d = _vorlage("serie.json")
    ids = [
        str(ac.get("id") or "")
        for x in d.get("listablesBySlug") or []
        for ac in x.get("associatedContent") or []
    ]
    assert "related" in ids, "the fixture does not show the case — it is no good"


def test_leere_suchtreffer_fallen_heraus(svt):
    """Four of the ten hits are category tiles without `teaser.item`."""
    d = _vorlage("suche.json")
    hits = ((d.get("searchPage") or {}).get("flat") or {}).get("hits") or []
    assert hits
    leer = [h for h in hits if not (h.get("teaser") or {}).get("item")]
    assert leer, "the fixture does not show the case"

    p = svt.Portal()
    for h in leer:
        assert p._als_item((h.get("teaser") or {}).get("item") or {}) is None


# ── The stream ──────────────────────────────────────────────────────────────


def test_nur_formate_die_der_abspieler_oeffnet(svt):
    """SVT delivers eleven versions, six of them `dash`. Those are not in the list."""
    d = _vorlage("video.json")
    alle = {v.get("format") for v in d.get("videoReferences") or []}
    assert any(f.startswith("dash") for f in alle), "the fixture shows no dash"
    for name in svt.FORMATE:
        assert not name.startswith("dash")


def test_untertitel_sind_echte_dateien(svt):
    """Unlike at arte: `subtitleReferences` with WebVTT and a language tag."""
    d = _vorlage("video.json")
    vtt = [s for s in d.get("subtitleReferences") or [] if s.get("format") == "webvtt"]
    assert vtt, "kein WebVTT in der Vorlage"
    for s in vtt:
        assert s.get("url", "").startswith("https://")
        assert s.get("language")


def test_resolve_traegt_die_untertitel_englisch_benannt(svt):
    """`language` / `format` / `address` — as the app reads them."""
    from cinelounge.core.contract import Source

    d = _vorlage("video.json")
    vtt = next(s for s in d["subtitleReferences"] if s.get("format") == "webvtt")

    # Without the network: leave the id out, then `resolve()` fetches nothing.
    st = svt.Portal().resolve(Source(id="https://x/y.m3u8", name="HLS", address=""))
    assert st.kind == "hls"
    assert st.address == "https://x/y.m3u8"
    assert st.subtitles == []
    # And the shape `resolve()` would build:
    gebaut = {"language": vtt.get("language"), "format": "vtt", "address": vtt["url"]}
    assert set(gebaut) == {"language", "format", "address"}


def test_series_gibt_none(svt):
    assert svt.Portal().series("show/jMdm7Lg") is None
    assert svt.Portal().series("series/vardcentralen") is None
