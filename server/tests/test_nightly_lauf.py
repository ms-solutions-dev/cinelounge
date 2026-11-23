"""`portalworks/nightly.py` — the check itself.

It goes through `runner.call()` into a child process, so it needs `fork` and
only runs where the service runs: `scripts/deploy.sh` runs the tests over
there in the container.

**Checked against the example portal.** It has no source of its own — the
catalogue stands in the file — so this test measures the nightly run and not
the weather at some broadcaster.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(not hasattr(os, "fork"), reason="fork gibt es nur auf POSIX")

WURZEL = Path(__file__).resolve().parent.parent


@pytest.fixture(autouse=True)
def klopfen_traegt(monkeypatch):
    """The knock goes out to the network — here it is answered at home.

    The example portal hands out addresses that nobody serves; whether the knock
    itself judges right is `test_probe.py`'s business.
    """
    from cinelounge.portalworks import nightly

    monkeypatch.setattr(nightly, "_klopfen", lambda address, headers, via: True)


@pytest.fixture()
def bestand(tmp_path):
    """A registry with the SDK template in it.

    In operation it never lies in `/data/portals` — `grundstock.py` expressly
    leaves it home. For this test it is just right: a portal that runs through
    without the network.
    """
    from cinelounge.portalworks.registry import Registry

    wurzel = tmp_path / "portals"
    wurzel.mkdir()
    shutil.copytree(
        WURZEL / "portals" / "beispiel",
        wurzel / "beispiel",
        ignore=shutil.ignore_patterns("__pycache__"),
    )
    return Registry(wurzel)


def test_ein_funktionierendes_portal_traegt(bestand):
    """From the menu to the address — and `step` says how far it got."""
    from cinelounge.portalworks import nightly

    ergebnis = nightly.check(bestand.manifests["beispiel"])
    assert ergebnis.ok, f"{ergebnis.step}: {ergebnis.reason}"
    assert ergebnis.step == "resolve", "carried means: all the way to the address"
    assert ergebnis.address.startswith("https://")
    assert ergebnis.ms > 0


def test_ein_defektes_manifest_kommt_gar_nicht_erst_los(bestand, tmp_path):
    """And the reason stands beside it, instead of it trying `menu`."""
    from cinelounge.portalworks import nightly
    from cinelounge.portalworks.registry import Registry

    (tmp_path / "portals" / "beispiel" / "portal.yml").write_text(
        "api: 1\nid: beispiel\nname:\n  en: x\nkind: native\nquatsch: ja\n", encoding="utf-8"
    )
    m = Registry(tmp_path / "portals").manifests["beispiel"]
    ergebnis = nightly.check(m)

    assert not ergebnis.ok
    assert ergebnis.step == "manifest"
    assert "quatsch" in ergebnis.reason


def test_ein_portal_das_nichts_zurueckgibt_scheitert_bei_menu(bestand, tmp_path):
    from cinelounge.portalworks import nightly
    from cinelounge.portalworks.registry import Registry

    (tmp_path / "portals" / "beispiel" / "portal.py").write_text(
        "class Portal:\n"
        "    id = 'beispiel'\n"
        "    name = 'x'\n"
        "    capabilities = set()\n"
        "    def menu(self):\n"
        "        return []\n",
        encoding="utf-8",
    )
    m = Registry(tmp_path / "portals").manifests["beispiel"]
    ergebnis = nightly.check(m)

    assert not ergebnis.ok
    assert ergebnis.step == "menu"
    assert "no entries" in ergebnis.reason


def test_ein_absturz_im_portal_wird_zum_grund(bestand, tmp_path):
    """**`check()` never raises.**

    A nightly run over eleven portals must not abort at the second — what the
    third would have done is exactly the information it runs for.
    """
    from cinelounge.portalworks import nightly
    from cinelounge.portalworks.registry import Registry

    (tmp_path / "portals" / "beispiel" / "portal.py").write_text(
        "class Portal:\n"
        "    id = 'beispiel'\n"
        "    name = 'x'\n"
        "    capabilities = set()\n"
        "    def menu(self):\n"
        "        raise ValueError('kaputt mit Ansage')\n",
        encoding="utf-8",
    )
    m = Registry(tmp_path / "portals").manifests["beispiel"]
    ergebnis = nightly.check(m)

    assert not ergebnis.ok
    assert ergebnis.step == "menu"
    assert "kaputt mit Ansage" in ergebnis.reason, ergebnis.reason


def test_ein_portal_das_blaettert_aber_nicht_abspielt_traegt_nicht(bestand, tmp_path):
    """**Without `resolve` it has not carried.**

    Exactly what `INHALTE.md` warns of at BBC iPlayer: a sidebar full of titles
    of which none starts.
    """
    from cinelounge.portalworks import nightly
    from cinelounge.portalworks.registry import Registry

    (tmp_path / "portals" / "beispiel" / "portal.py").write_text(
        "from cinelounge.core.contract import Entry, Item, Page, Source, Stream\n"
        "class Portal:\n"
        "    id = 'beispiel'\n"
        "    name = 'x'\n"
        "    capabilities = set()\n"
        "    def menu(self):\n"
        "        return [Entry(id='a', name='A')]\n"
        "    def listing(self, entry, next_page=None, user_input=''):\n"
        "        return Page(items=[Item(title='T', address='x')])\n"
        "    def sources(self, item):\n"
        "        return [Source(id='s', name='S', address='y')]\n"
        "    def resolve(self, source):\n"
        "        return Stream(address='', resolved=False)\n",
        encoding="utf-8",
    )
    m = Registry(tmp_path / "portals").manifests["beispiel"]
    ergebnis = nightly.check(m)

    assert not ergebnis.ok
    assert ergebnis.step == "resolve"


def test_gesperrte_quellen_zaehlen_nicht_als_quellen(bestand, tmp_path):
    """A source the portal marks as blocked is no source that carries."""
    from cinelounge.portalworks import nightly
    from cinelounge.portalworks.registry import Registry

    (tmp_path / "portals" / "beispiel" / "portal.py").write_text(
        "from cinelounge.core.contract import Entry, Item, Page, Source\n"
        "class Portal:\n"
        "    id = 'beispiel'\n"
        "    name = 'x'\n"
        "    capabilities = set()\n"
        "    def menu(self):\n"
        "        return [Entry(id='a', name='A')]\n"
        "    def listing(self, entry, next_page=None, user_input=''):\n"
        "        return Page(items=[Item(title='T', address='x')])\n"
        "    def sources(self, item):\n"
        "        return [Source(id='s', name='S', address='y', blocked=True,\n"
        "                       reason='sign-in')]\n",
        encoding="utf-8",
    )
    m = Registry(tmp_path / "portals").manifests["beispiel"]
    ergebnis = nightly.check(m)

    assert not ergebnis.ok
    assert ergebnis.step == "sources"
    assert "blocked" in ergebnis.reason


def test_der_lauf_ueber_alle_portale_bricht_nicht_ab(bestand, tmp_path):
    """A broken portal beside an intact one — both go into the book."""
    from cinelounge.household.nights import Nights
    from cinelounge.household.store import Store
    from cinelounge.portalworks.registry import Registry
    from cinelounge.web import nightwatch

    kaputt = tmp_path / "portals" / "kaputt"
    kaputt.mkdir()
    (kaputt / "portal.yml").write_text(
        "api: 1\nid: kaputt\nname:\n  en: Kaputt\nkind: native\n", encoding="utf-8"
    )
    (kaputt / "portal.py").write_text(
        "class Portal:\n"
        "    id = 'kaputt'\n"
        "    name = 'Kaputt'\n"
        "    capabilities = set()\n"
        "    def menu(self):\n"
        "        raise RuntimeError('nein')\n",
        encoding="utf-8",
    )

    buch = Nights(Store(tmp_path / "haus.sqlite"))
    d = nightwatch.run_once(Registry(tmp_path / "portals"), buch, gap_s=0.0)

    assert "beispiel" in d["carried"], d
    assert "kaputt" in d["failed"], d
    assert buch.history("beispiel")[-1] == 1
    assert buch.history("kaputt")[-1] == 0


def test_ein_abgeschaltetes_portal_wird_uebersprungen(bestand, tmp_path):
    """**`None` and not `False`** — it did not fail, it did not run.

    Measured 11.09.2026: the first attempt read `m.on_by_default` instead of
    the household switch and skipped only what was **switched off and
    broken**. That almost never applied; a portal at `enabled: false` was
    checked all the same — a red stripe for a portal nobody uses.
    """
    from cinelounge.household.nights import Nights
    from cinelounge.household.store import Store
    from cinelounge.household.visibility import Visibility
    from cinelounge.portalworks.registry import Registry
    from cinelounge.web import nightwatch

    store = Store(tmp_path / "haus.sqlite")
    schalter = Visibility(store)
    schalter.set_on("beispiel", False)

    buch = Nights(store)
    d = nightwatch.run_once(Registry(tmp_path / "portals"), buch, switch=schalter, gap_s=0.0)

    assert d["skipped"] == ["beispiel"], d
    assert not d["carried"]
    assert buch.history("beispiel")[-1] is None, "switched off was counted as a failure"

    letzte = buch.last("beispiel")
    assert letzte is not None
    assert letzte.step == "off"


def test_ohne_schalter_wird_alles_geprueft(bestand, tmp_path):
    """For a test that is right; in operation `main.py` passes it along."""
    from cinelounge.household.nights import Nights
    from cinelounge.household.store import Store
    from cinelounge.portalworks.registry import Registry
    from cinelounge.web import nightwatch

    buch = Nights(Store(tmp_path / "haus.sqlite"))
    d = nightwatch.run_once(Registry(tmp_path / "portals"), buch, gap_s=0.0)
    assert d["carried"] == ["beispiel"]


def test_eine_adresse_ohne_video_dahinter_traegt_nicht(bestand, monkeypatch):
    """**An address is a claim; the probe is the proof** (08.11.2026).

    A portal stayed green for weeks while a source handed out an HTML page as a
    finished stream. Every source resolves here, none carries — and the reason
    names it.
    """
    from cinelounge.portalworks import nightly

    monkeypatch.setattr(nightly, "_klopfen", lambda address, headers, via: False)
    ergebnis = nightly.check(bestand.manifests["beispiel"])

    assert not ergebnis.ok
    assert ergebnis.step == "resolve"
    assert "no video behind" in ergebnis.reason, ergebnis.reason


def test_ein_geschuetztes_video_zaehlt_als_getragen(monkeypatch):
    """DRM is a finding about the content, not a broken portal."""
    from cinelounge.portalworks import nightly
    from cinelounge.stream import probe

    monkeypatch.undo()

    def geschuetzt(address, headers=None, via=None):
        raise probe.DrmError("widevine")

    monkeypatch.setattr(probe, "probe", geschuetzt)
    assert nightly._klopfen("https://x.example/a.m3u8", {}, None) is True
