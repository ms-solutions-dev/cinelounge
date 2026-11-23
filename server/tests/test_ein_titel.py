"""One title, several portals — and the official source first.

"Salt Compass" stands at `fichte` and at `birke`; "Krimireihe" at Ahorn and at a
portal of another kind. The search used to hand that out as two rows, and whoever looked had
to recognise for themselves that it is the same thing.

**What is checked here is above all what is *not* merged.** Throwing too much
together is worse than nothing at all: whoever lays "Salt Compass" and "Salt Compass
(2021)" on top of each other sends somebody into the wrong series, and whoever
takes two episodes of the same series from two portals for the same episode,
into the wrong episode.
"""

from __future__ import annotations

from dataclasses import dataclass

import pytest

from cinelounge.portalworks import extension
from cinelounge.web.portals import _zusammenlegen


@dataclass
class _Manifest:
    id: str
    kind: str


class _Register:
    """Only what `_zusammenlegen` needs: kind and order."""

    def __init__(self, *paare: tuple[str, str]) -> None:
        self.manifests = {pid: _Manifest(pid, art) for pid, art in paare}


@pytest.fixture()
def register():
    return _Register(
        ("ahorn", "native"), ("zinne", "native"), ("fichte", "extern"), ("birke", "extern")
    )


def _item(title, **rest):
    return {"title": title, "address": "a", "key": "k", "kind": "series", **rest}


# ── Merging ─────────────────────────────────────────────────────────────────


def test_derselbe_titel_aus_zwei_portalen_wird_eine_zeile(register):
    d = _zusammenlegen(
        {"fichte": [_item("Salt Compass")], "birke": [_item("Salt Compass")]}, register
    )
    assert len(d) == 1
    assert [q["portal"] for q in d[0]["sources"]] == ["fichte", "birke"]


def test_schreibweise_und_zeichensetzung_zaehlen_nicht(register):
    """The same normalisation the progress hangs on."""
    d = _zusammenlegen(
        {"fichte": [_item("Die Corvellis")], "birke": [_item("die corvellis!")]},
        register,
    )
    assert len(d) == 1


def test_die_offizielle_quelle_steht_vorn(register):
    """**Origin, not quality.** The media library stays reachable if a
    page-reading portal breaks tomorrow."""
    d = _zusammenlegen({"birke": [_item("Krimireihe")], "ahorn": [_item("Krimireihe")]}, register)
    assert [q["portal"] for q in d[0]["sources"]] == ["ahorn", "birke"]


def test_innerhalb_einer_art_bleibt_die_reihenfolge_des_registers(register):
    d = _zusammenlegen({"zinne": [_item("Krimireihe")], "ahorn": [_item("Krimireihe")]}, register)
    assert [q["portal"] for q in d[0]["sources"]] == ["ahorn", "zinne"]


# ── And what stays apart ────────────────────────────────────────────────────


def test_ein_jahr_im_titel_trennt(register):
    """`Salt Compass` and `Salt Compass (2021)` are two series, not one."""
    d = _zusammenlegen({"fichte": [_item("Salt Compass"), _item("Salt Compass (2021)")]}, register)
    assert len(d) == 2


def test_verschiedene_jahre_trennen(register):
    d = _zusammenlegen(
        {"ahorn": [_item("Krimireihe", year=1970)], "zinne": [_item("Krimireihe", year=2024)]},
        register,
    )
    assert len(d) == 2


def test_zwei_folgen_derselben_serie_bleiben_zwei(register):
    """**The show title does not group.**

    Otherwise "Folge 41" from Ahorn would lie on "Folge 7" from Birke, only
    because both belong to "Krimireihe".
    """
    d = _zusammenlegen(
        {
            "ahorn": [_item("Folge 41: Kreidespur", show="Krimireihe", kind="episode")],
            "birke": [_item("Folge 7: Der Fall", show="Krimireihe", kind="episode")],
        },
        register,
    )
    assert len(d) == 2


def test_ein_titelloser_eintrag_faellt_weg(register):
    d = _zusammenlegen({"ahorn": [_item(""), _item("Krimireihe")]}, register)
    assert len(d) == 1


def test_hits_bleibt_unberuehrt(register):
    """An app reading `hits` notices nothing of `titles`."""
    hits = {"ahorn": [_item("Krimireihe")]}
    vorher = [dict(i) for i in hits["ahorn"]]
    _zusammenlegen(hits, register)
    assert hits["ahorn"] == vorher


# ── The ranking itself ──────────────────────────────────────────────────────


def test_eine_unbekannte_art_steht_hinten(register):
    """A portal of a kind that does not exist yet displaces nothing."""
    reg = _Register(("neu", "irgendwas"), ("ahorn", "native"))
    d = _zusammenlegen({"neu": [_item("Krimireihe")], "ahorn": [_item("Krimireihe")]}, reg)
    assert [q["portal"] for q in d[0]["sources"]] == ["ahorn", "neu"]
    assert extension.rank("native") < extension.rank("irgendwas") == extension.UNKNOWN_RANK
