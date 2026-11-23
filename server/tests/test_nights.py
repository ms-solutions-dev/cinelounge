"""The book of nightly runs — three values, and the third is the point.

`ok` is `1`, `0` or `None`: **carried, failed, did not run at all.** A portal
that was switched off has not failed; a strip that paints both the same makes
a pause look like a fault, and whoever searches for it searches in the wrong
place.

Checked here is the book, not the check. What `portalworks/nightly.py` does
needs `fork` and running portals — that stands in `test_nightly_lauf.py`.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from cinelounge.household.nights import KEEP_NIGHTS, NIGHTS, Nights, tonight
from cinelounge.household.store import Store


@pytest.fixture()
def buch(tmp_path):
    return Nights(Store(tmp_path / "haus.sqlite"))


def _vor(tagen: int) -> float:
    """A point in time that safely belongs to the night `tagen` nights ago.

    **Computed from `tonight()`, not from the calendar day.** Until 12.09.2026
    "today 12:00 UTC" stood here — and between midnight and noon UTC that is
    not the night `tonight()` currently means but the *next* one: `tonight()`
    subtracts twelve hours. Measured at 08:11 UTC: the test wrote to
    `2026-09-12`, the strip ended at `2026-09-11`, five tests red — green in
    the afternoon without a line having changed.

    Midnight of the following day minus twelve hours is noon of the intended
    night — safely in the middle, at any time of day.
    """
    nacht = datetime.strptime(tonight(), "%Y-%m-%d").replace(tzinfo=UTC)
    return (nacht + timedelta(days=1 - tagen)).timestamp()


# ── The night as a date ─────────────────────────────────────────────────────


def test_der_tag_beginnt_mittags():
    """**A run at 03:00 belongs to the previous day's night.**

    Otherwise "last night" would mean something different depending on the
    hour, and a strip with two entries for the same evening would follow.
    """
    abend = datetime(2026, 9, 11, 23, 30, tzinfo=UTC).timestamp()
    nacht = datetime(2026, 9, 12, 3, 0, tzinfo=UTC).timestamp()
    morgen = datetime(2026, 9, 12, 13, 0, tzinfo=UTC).timestamp()

    assert tonight(abend) == "2026-09-11"
    assert tonight(nacht) == "2026-09-11", "03:00 belongs to the night before"
    assert tonight(morgen) == "2026-09-12"


def test_zwei_laeufe_in_einer_nacht_ersetzen_einander(buch):
    """The primary key is `(portal, night)` — not the timestamp."""
    buch.record("zinne", False, step="menu", reason="erster Versuch")
    buch.record("zinne", True, step="resolve")

    assert buch.history("zinne")[-1] == 1
    letzte = buch.last("zinne")
    assert letzte and letzte.step == "resolve"


# ── The strip ───────────────────────────────────────────────────────────────


def test_naechte_ohne_lauf_sind_luecken(buch):
    """**The difference between "did not carry" and "did not run".**

    Without the gaps a portal that has only been here since yesterday could
    not be told apart from one that failed twelve times.
    """
    buch.record("zinne", True, when=_vor(0))
    streifen = buch.history("zinne")

    assert len(streifen) == NIGHTS
    assert streifen[-1] == 1
    assert all(x is None for x in streifen[:-1])


def test_der_streifen_steht_aeltestes_zuerst(buch):
    buch.record("zinne", False, when=_vor(2))
    buch.record("zinne", True, when=_vor(1))
    buch.record("zinne", True, when=_vor(0))

    assert buch.history("zinne")[-3:] == [0, 1, 1]


def test_uebersprungen_ist_weder_getragen_noch_gescheitert(buch):
    """`None` and not `False`: a switched-off portal has not failed."""
    buch.record("zinne", None, step="skipped", reason="abgeschaltet", when=_vor(0))
    assert buch.history("zinne")[-1] is None

    letzte = buch.last("zinne")
    assert letzte is not None
    assert letzte.ok is None, "`None` became False"
    assert letzte.step == "skipped"


def test_ein_portal_ohne_eintrag_hat_einen_leeren_streifen(buch):
    assert buch.history("gibtsnicht") == [None] * NIGHTS
    assert buch.last("gibtsnicht") is None


# ── When something fails for good ───────────────────────────────────────────


def test_drei_fehlnaechte_in_folge(buch):
    for n in (2, 1, 0):
        buch.record("kiefer", False, step="sources", when=_vor(n))
    assert buch.failing("kiefer")


def test_zwei_sind_noch_kein_zustand(buch):
    """One is an outage, two is bad luck, three is a state."""
    for n in (1, 0):
        buch.record("kiefer", False, when=_vor(n))
    assert not buch.failing("kiefer")


def test_eine_pause_bricht_die_kette_nicht(buch):
    """**Nights without a run do not count — and do not count against.**

    A portal that failed two nights, paused one and then failed again has
    failed three times and not once.
    """
    buch.record("x", False, when=_vor(4))
    buch.record("x", False, when=_vor(3))
    # Night 2: no run.
    buch.record("x", False, when=_vor(0))
    assert buch.failing("x")


def test_eine_getragene_nacht_bricht_sie_schon(buch):
    buch.record("x", False, when=_vor(3))
    buch.record("x", False, when=_vor(2))
    buch.record("x", True, when=_vor(1))
    buch.record("x", False, when=_vor(0))
    assert not buch.failing("x")


def test_uebersprungen_zaehlt_nicht_als_fehlschlag(buch):
    """Otherwise a portal counts as broken that was only switched off."""
    buch.record("x", False, when=_vor(2))
    buch.record("x", None, when=_vor(1))
    buch.record("x", False, when=_vor(0))
    assert not buch.failing("x")


# ── Cleaning up and output ──────────────────────────────────────────────────


def test_alte_naechte_werden_aufgeraeumt(buch):
    buch.record("zinne", True, when=_vor(KEEP_NIGHTS + 5))
    buch.record("zinne", True, when=_vor(0))

    with buch.store.connect() as v:
        wie_viele = v.execute("SELECT COUNT(*) c FROM night").fetchone()["c"]
    assert wie_viele == 1, "the old entry still stands"


def test_record_wirft_nie(buch, monkeypatch):
    """A nightly run that fails at bookkeeping has measured all the same."""

    def kaputt(*a, **k):
        raise RuntimeError("Platte voll")

    monkeypatch.setattr(buch.store, "connect", kaputt)
    buch.record("zinne", True)  # must not raise


def test_as_json_traegt_streifen_und_grund(buch):
    buch.record("zinne", True, step="resolve", ms=812, when=_vor(1))
    buch.record("kiefer", False, step="sources", reason="api.key fehlt", when=_vor(0))

    d = buch.as_json()
    assert d["nights"] == NIGHTS
    assert set(d["history"]) == {"zinne", "kiefer"}
    assert d["history"]["zinne"][-2] == 1
    assert d["last"]["kiefer"]["step"] == "sources"
    assert "api.key" in d["last"]["kiefer"]["reason"]
    assert d["last"]["zinne"]["ms"] == 812
