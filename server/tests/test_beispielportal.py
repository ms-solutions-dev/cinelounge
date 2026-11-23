"""The example portal — the template has to run, otherwise it is a trap.

**Why this is checked at all.** `portals/beispiel/` is not loaded by the
service: the registry reads `/data/portals`, and it does not lie there. It is
a template to copy — and exactly that is the danger. Dead code nobody executes
decays silently, and whoever copies it half a year later rebuilds the decay.

This file calls all seven methods and checks the manifest against the same
reader the service uses. What is green here is a template; what is red here
never was one.

**No network.** The addresses in the catalogue are not fetched. A test that
hangs on somebody else's server is red on the day the server coughs — and then
says something about the server and nothing about the template.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

from cinelounge.core import errors as f
from cinelounge.core.contract import Entry, Item, Page, Source, Stream
from cinelounge.portalworks import manifest as manifest_lesen

ORDNER = Path(__file__).resolve().parent.parent / "portals" / "beispiel"


@pytest.fixture(scope="module")
def portal():
    """Load the portal the way the runner does in the child.

    Deliberately the same way as in `portalworks/runner/call.py`: via
    `spec_from_file_location` and `module.Portal()`. A test that wrote
    `import portals.beispiel.portal` instead would check a load path that does
    not exist in operation.
    """
    datei = ORDNER / "portal.py"
    spec = importlib.util.spec_from_file_location("portal_beispiel_test", datei)
    assert spec and spec.loader
    modul = importlib.util.module_from_spec(spec)
    sys.modules["portal_beispiel_test"] = modul
    spec.loader.exec_module(modul)
    return modul.Portal()


# ── The manifest ────────────────────────────────────────────────────────────


def test_manifest_wird_gelesen():
    m = manifest_lesen.read(ORDNER / "portal.yml")
    assert m.is_ready, m.broken_reason
    assert m.id == "beispiel"
    assert m.kind == "native"


def test_manifest_zeigt_alle_drei_sprachen():
    """The template is meant to show what a language field looks like — in all three."""
    m = manifest_lesen.read(ORDNER / "portal.yml")
    for feld in (m.name, m.description):
        assert set(feld) >= {"de", "en", "tr"}, feld


def test_manifest_und_klasse_sagen_dasselbe(portal):
    """Id and capabilities stand in two places. They have to be the same.

    **The service does not reconcile the two** — it reads the manifest for the
    console and calls the class for the data. A portal that claims `search`
    here and not there is simply never asked, and nobody says why. In a
    template that would be the most expensive fault.
    """
    m = manifest_lesen.read(ORDNER / "portal.yml")
    assert portal.id == m.id
    assert portal.capabilities == m.capabilities


# ── The seven methods ───────────────────────────────────────────────────────


def test_menu_gibt_eintraege(portal):
    eintraege = portal.menu()
    assert eintraege and all(isinstance(e, Entry) for e in eintraege)
    # `count` may be None — but not 0 where something lies.
    for e in eintraege:
        assert e.count is None or e.count > 0
    assert {e.group for e in eintraege} <= {"curated", "library"}


def test_listing_blaettert_und_hoert_auf(portal):
    """`paging` is declared — so it really has to page."""
    erste = portal.listing("all")
    assert isinstance(erste, Page)
    assert erste.items
    assert erste.next_page, "one page alone proves no paging"

    gesehen = list(erste.items)
    weiter = erste.next_page
    for _ in range(10):
        if not weiter:
            break
        seite = portal.listing("all", weiter)
        gesehen += seite.items
        weiter = seite.next_page
    else:
        pytest.fail("das Blaettern hoert nicht auf")

    assert len(gesehen) == erste.total
    # No duplicates across the page boundary — the classic off-by-one.
    assert len({i.address for i in gesehen}) == len(gesehen)


def test_seite_hinter_der_letzten_ist_kein_fehler(portal):
    """An empty level is no fault, and the template has to show that."""
    leer = portal.listing("all", "99")
    assert leer.items == []
    assert leer.note


def test_unbekannter_einstieg_ist_ein_code_kein_satz(portal):
    with pytest.raises(f.Error) as gefangen:
        portal.listing("gibtsnicht")
    assert gefangen.value.code == "portal.unknown_entry"


def test_children_nur_unter_der_serie(portal):
    serie = next(i for i in portal.listing("all").items if i.kind == "series")
    folgen = portal.children(serie)
    assert len(folgen) == 4
    assert [e.number for e in folgen] == [1, 2, 3, 4]

    film = next(i for i in portal.listing("films").items if i.kind == "film")
    assert portal.children(film) == []


def test_sources_und_resolve_fuehren_zu_einer_adresse(portal):
    film = portal.listing("films").items[0]
    quellen = portal.sources(film)
    assert quellen and all(isinstance(q, Source) for q in quellen)

    strom = portal.resolve(quellen[0])
    assert isinstance(strom, Stream)
    assert strom.resolved
    assert strom.address.startswith("https://")
    assert strom.kind == "file"


def test_untertitel_sind_englisch_benannt(portal):
    """Three fields, and all three are called as the app reads them.

    `language` / `format` / `address` — not `sprache`/`adresse`. The rename
    to English once produced two truths at exactly this spot.
    """
    film = next(i for i in portal.listing("films").items if i.title == "Big Buck Bunny")
    strom = portal.resolve(portal.sources(film)[0])
    assert strom.subtitles
    for u in strom.subtitles:
        assert set(u) == {"language", "format", "address"}


def test_ohne_untertitel_kommt_eine_leere_liste(portal):
    # Via the search, not via page one: with four entries per page this title
    # lies on the second, and the test is not meant to rebuild the paging.
    kurz = portal.search("For Bigger Fun")[0]
    strom = portal.resolve(portal.sources(kurz)[0])
    assert strom.subtitles == []


def test_unbekannte_adresse_wirft_einen_code(portal):
    with pytest.raises(f.Error) as gefangen:
        portal.sources(Item(title="?", address="film/gibtsnicht"))
    assert gefangen.value.code == "portal.unknown_item"


def test_search_findet_ueber_titel_und_beschreibung(portal):
    assert [i.title for i in portal.search("sintel")] == ["Sintel"]
    assert portal.search("Dragon") or portal.search("dragon")
    assert portal.search("") == []
    assert portal.search("zzz-gibt-es-nicht") == []


def test_series_beantwortet_folge_zu_serie(portal):
    serie = next(i for i in portal.listing("all").items if i.kind == "series")
    folge = portal.children(serie)[0]
    assert portal.series(folge.address) == "Bigger Things"
    assert portal.series(serie.address) == "Bigger Things"
    # A film belongs to no series — and that is `None`, not "".
    assert portal.series("film/Sintel") is None


# ── What else the template promises ─────────────────────────────────────────


def test_kein_eintrag_behauptet_ein_bild_das_er_nicht_nennt(portal):
    """`own_images` is declared — then every entry carries one too."""
    for item in portal.listing("all").items:
        assert item.image, item.title
        assert item.image_source == "portal"


def test_die_vorlage_ruft_nichts_aus_dem_netz():
    """No `requests`, no `urllib` — the catalogue stands in the file.

    **That is the property that keeps this template running in a year.** An
    example that scrapes a real site is broken as soon as the site changes, and
    then teaches the wrong thing.
    """
    quelle = (ORDNER / "portal.py").read_text(encoding="utf-8")
    code = "\n".join(z for z in quelle.split("\n") if not z.lstrip().startswith("#"))
    for verboten in ("import requests", "import urllib", "import http"):
        assert verboten not in code, verboten


# ── And once through the real runner ────────────────────────────────────────


@pytest.mark.skipif(not hasattr(__import__("os"), "fork"), reason="fork gibt es nur auf POSIX")
def test_der_laeufer_ruft_die_vorlage_wirklich_auf(tmp_path):
    """Not `module.Portal()` by hand but the service's way.

    **The difference is not academic.** The runner forks a child process, sets
    limits, loads the module there and sends the result back through a pipe —
    as JSON. A field that cannot be serialised shows here and never in a direct
    call. That is exactly how a portal kind once died: the manifest was
    intact, the call dead, and `/health` reported `ready: 8, broken: []`.

    Runs only where `fork` exists — that is, in the container and not on the
    development machine under Windows. `scripts/deploy.sh` runs the tests over
    there, and that is the reason.
    """
    import shutil

    from cinelounge.portalworks.registry import Registry
    from cinelounge.portalworks.runner import call as runner

    wurzel = tmp_path / "portals"
    wurzel.mkdir()
    shutil.copytree(ORDNER, wurzel / "beispiel", ignore=shutil.ignore_patterns("__pycache__"))

    bestand = Registry(wurzel)
    m = bestand.manifests["beispiel"]
    assert m.is_ready, m.broken_reason

    eintraege = runner.call(m, "menu", {})
    assert eintraege and eintraege[0]["id"] == "films"

    seite = runner.call(m, "listing", {"entry": "all"})
    assert seite["items"]
    assert seite["next_page"]

    treffer = runner.call(m, "search", {"text": "sintel"})
    assert [t["title"] for t in treffer] == ["Sintel"]

    # **And the setting arrives.** `portal.yml` sets `page_size: 4`; without
    # `configure()` the default in the code would stand. The difference is
    # only visible through the runner — in a direct call nobody calls
    # `configure()`.
    ein_mehr = wurzel / "beispiel" / "portal.yml"
    ein_mehr.write_text(
        ein_mehr.read_text(encoding="utf-8").replace('value: "4"', 'value: "2"'),
        encoding="utf-8",
    )
    bestand.reload()
    m2 = bestand.manifests["beispiel"]
    zwei = runner.call(m2, "listing", {"entry": "all"})
    assert len(zwei["items"]) == 2, (
        "`page_size: 2` aus dem Manifest kam nicht beim Portal an — "
        "`configure()` wird nicht gerufen"
    )
