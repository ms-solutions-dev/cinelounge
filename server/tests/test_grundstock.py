"""`scripts/grundstock.py` — bundled portals into the data directory.

**The script writes into other people's folders, so it gets tested.** It
overwrites portals a household has in operation; a fault in it is not a red
test but a living room without portals. So what is checked above all is what
it does **not** do.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

WURZEL = Path(__file__).resolve().parent.parent


@pytest.fixture(scope="module")
def gs():
    datei = WURZEL / "scripts" / "grundstock.py"
    spec = importlib.util.spec_from_file_location("grundstock_test", datei)
    assert spec and spec.loader
    modul = importlib.util.module_from_spec(spec)
    sys.modules["grundstock_test"] = modul
    spec.loader.exec_module(modul)
    return modul


def _lauf(gs, ziel: Path, schreibt: bool, quelle: Path | None = None) -> None:
    """Run the script once, with `sys.argv` as on the command line."""
    alt_argv, alt_quelle = sys.argv, gs.QUELLE
    try:
        if quelle is not None:
            gs.QUELLE = quelle
        sys.argv = ["grundstock.py", str(ziel)] + (["--write"] if schreibt else [])
        gs.main()
    finally:
        sys.argv, gs.QUELLE = alt_argv, alt_quelle


def _portal(ordner: Path, kennung: str, inhalt: str = "erste Fassung") -> Path:
    p = ordner / kennung
    p.mkdir(parents=True, exist_ok=True)
    (p / "portal.yml").write_text(
        f"api: 1\nid: {kennung}\nname:\n  en: {kennung}\nkind: native\n", encoding="utf-8"
    )
    (p / "portal.py").write_text(f"# {inhalt}\n", encoding="utf-8")
    return p


# ── What it does ────────────────────────────────────────────────────────────


def test_ohne_write_wird_nichts_geschrieben(gs, tmp_path):
    quelle, ziel = tmp_path / "q", tmp_path / "z"
    _portal(quelle, "zinne")
    ziel.mkdir()

    _lauf(gs, ziel, schreibt=False, quelle=quelle)
    assert not (ziel / "zinne").exists(), "a dry run wrote"


def test_mit_write_kommt_es_an(gs, tmp_path):
    quelle, ziel = tmp_path / "q", tmp_path / "z"
    _portal(quelle, "zinne")

    _lauf(gs, ziel, schreibt=True, quelle=quelle)
    assert (ziel / "zinne" / "portal.py").read_text(encoding="utf-8") == "# erste Fassung\n"


def test_eine_neuere_fassung_ersetzt_die_alte(gs, tmp_path):
    quelle, ziel = tmp_path / "q", tmp_path / "z"
    _portal(quelle, "zinne", "erste Fassung")
    _lauf(gs, ziel, schreibt=True, quelle=quelle)

    _portal(quelle, "zinne", "zweite Fassung")
    _lauf(gs, ziel, schreibt=True, quelle=quelle)
    assert (ziel / "zinne" / "portal.py").read_text(encoding="utf-8") == "# zweite Fassung\n"


def test_die_alte_fassung_bleibt_als_rueckweg(gs, tmp_path):
    """The same place `market.rollback()` reads.

    A seed that breaks a portal is thereby one click in the console and not a
    search through the backup.
    """
    quelle, ziel = tmp_path / "q", tmp_path / "z"
    _portal(quelle, "zinne", "erste Fassung")
    _lauf(gs, ziel, schreibt=True, quelle=quelle)

    _portal(quelle, "zinne", "zweite Fassung")
    _lauf(gs, ziel, schreibt=True, quelle=quelle)

    vorige = ziel / ".zinne.vorige" / "portal.py"
    assert vorige.is_file(), "no way back stored"
    assert vorige.read_text(encoding="utf-8") == "# erste Fassung\n"


# ── What it does not do ─────────────────────────────────────────────────────


def test_ein_portal_aus_dem_marktplatz_bleibt_unberuehrt(gs, tmp_path):
    """**The most important test in this file.**

    Whoever installed a portal from the marketplace may have a newer version
    than the bundled one. Overwriting it would be a silent rollback — exactly
    what the way back in `market/install.py` is meant to prevent.
    """
    quelle, ziel = tmp_path / "q", tmp_path / "z"
    _portal(quelle, "zinne", "mitgeliefert")
    _lauf(gs, ziel, schreibt=True, quelle=quelle)

    # Somebody installs a newer version from the marketplace.
    (ziel / "zinne" / ".market.json").write_text(
        json.dumps({"id": "zinne", "version": "9.9.9"}), encoding="utf-8"
    )
    (ziel / "zinne" / "portal.py").write_text("# aus dem Marktplatz\n", encoding="utf-8")

    _portal(quelle, "zinne", "mitgeliefert, neuer")
    _lauf(gs, ziel, schreibt=True, quelle=quelle)

    assert (ziel / "zinne" / "portal.py").read_text(encoding="utf-8") == "# aus dem Marktplatz\n"
    assert not (ziel / ".zinne.vorige").exists(), "it was touched after all"


def test_fremde_portale_bleiben_liegen(gs, tmp_path):
    """What only lies over there may have been put there by hand."""
    quelle, ziel = tmp_path / "q", tmp_path / "z"
    _portal(quelle, "zinne")
    _portal(ziel, "eigenbau", "von Hand")

    _lauf(gs, ziel, schreibt=True, quelle=quelle)
    assert (ziel / "eigenbau" / "portal.py").read_text(encoding="utf-8") == "# von Hand\n"


def test_die_vorlage_bleibt_daheim(gs, tmp_path):
    """`beispiel` is the SDK template and belongs in no household.

    It would run — six test films nobody ordered.
    """
    quelle, ziel = tmp_path / "q", tmp_path / "z"
    _portal(quelle, "beispiel")
    _portal(quelle, "zinne")

    _lauf(gs, ziel, schreibt=True, quelle=quelle)
    assert (ziel / "zinne").is_dir()
    assert not (ziel / "beispiel").exists()


def test_gleicher_inhalt_wird_nicht_angefasst(gs, tmp_path):
    """No way back for a run that changed nothing.

    Otherwise every deploy creates a `.vorige` identical to the running version
    — and the way back then points at the same spot.
    """
    quelle, ziel = tmp_path / "q", tmp_path / "z"
    _portal(quelle, "zinne")
    _lauf(gs, ziel, schreibt=True, quelle=quelle)
    _lauf(gs, ziel, schreibt=True, quelle=quelle)
    assert not (ziel / ".zinne.vorige").exists()


def test_gleiche_groesse_anderer_inhalt_faellt_auf(gs, tmp_path):
    """`filecmp` with `shallow=True` would miss this.

    Two files of equal length, with a fresh timestamp from the move: in a
    shallow comparison they count as equal, and the change would never arrive.
    """
    quelle, ziel = tmp_path / "q", tmp_path / "z"
    _portal(quelle, "zinne", "AAAA")
    _lauf(gs, ziel, schreibt=True, quelle=quelle)

    _portal(quelle, "zinne", "BBBB")  # same length, other content
    _lauf(gs, ziel, schreibt=True, quelle=quelle)
    assert (ziel / "zinne" / "portal.py").read_text(encoding="utf-8") == "# BBBB\n"


def test_das_echte_portals_verzeichnis_haelt_sich_an_die_form(gs):
    """Every bundled portal carries a manifest the reader accepts."""
    from cinelounge.portalworks import manifest as manifest_lesen

    gefunden = 0
    for ordner in sorted(gs.QUELLE.iterdir()):
        if not ordner.is_dir() or not (ordner / "portal.yml").is_file():
            continue
        m = manifest_lesen.read(ordner / "portal.yml")
        assert m.is_ready, f"{ordner.name}: {m.broken_reason}"
        assert m.id == ordner.name, f"{ordner.name} calls itself {m.id}"
        gefunden += 1
    assert gefunden >= 2, "at least zdf and ard should come along"


def test_jedes_native_portal_sagt_in_beiden_dateien_dasselbe(gs):
    """Id and capabilities stand in two places — they have to be the same.

    **The service does not reconcile the two.** It reads the manifest for the
    console and calls the class for the data. Whoever lets them drift apart
    gets no error message but an interface claiming something other than what
    the portal does.

    Found 11.09.2026, when `portals/ard/` came from the homelab into the repo:
    the class named `suche staffeln untertitel eigene_bilder blaettern` —
    German names from before the rename to English. The file was not in the
    repo, so no renamer had ever touched it. And `blaettern`/`paging` stood
    only in the class, while `listing()` has always handed out a `next_page`.
    """
    import importlib.util

    from cinelounge.portalworks import manifest as manifest_lesen

    geprueft = 0
    for ordner in sorted(gs.QUELLE.iterdir()):
        if not ordner.is_dir() or not (ordner / "portal.py").is_file():
            continue
        m = manifest_lesen.read(ordner / "portal.yml")
        if not m.is_ready or m.kind != "native":
            continue

        # Like the runner in the child: via the file, not via a package path.
        spec = importlib.util.spec_from_file_location(
            f"portal_{ordner.name}_pruefung", ordner / "portal.py"
        )
        assert spec and spec.loader
        modul = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = modul
        spec.loader.exec_module(modul)
        klasse = modul.Portal

        assert klasse.id == m.id, f"{ordner.name}: class says {klasse.id!r}, manifest {m.id!r}"
        assert set(klasse.capabilities) == m.capabilities, (
            f"{ordner.name}: Klasse {sorted(klasse.capabilities)}, "
            f"Manifest {sorted(m.capabilities)}"
        )
        geprueft += 1

    assert geprueft >= 2, "zdf and ard are both `native` and should arrive here"
