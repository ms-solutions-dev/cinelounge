"""One fetch for many askers (AP63, 01.10.2026) — see `portalworks/einmal.py`."""

from __future__ import annotations

import threading
import time

import pytest

from cinelounge.portalworks import einmal


@pytest.fixture(autouse=True)
def frisch():
    einmal.vergiss()
    yield
    einmal.vergiss()


def test_zwei_gleichzeitige_abrufe_holen_einmal():
    gezaehlt = []

    def holen():
        gezaehlt.append(1)
        time.sleep(0.2)
        return {"items": [1, 2]}

    ergebnisse = []
    faeden = [
        threading.Thread(target=lambda: ergebnisse.append(einmal.einmal(("p", "list", "e"), holen)))
        for _ in range(3)
    ]
    for f in faeden:
        f.start()
    for f in faeden:
        f.join()
    assert len(gezaehlt) == 1
    assert ergebnisse == [{"items": [1, 2]}] * 3


def test_gemerkt_und_als_kopie():
    gezaehlt = []

    def holen():
        gezaehlt.append(1)
        return {"items": [{"title": "A"}]}

    erste = einmal.einmal("k", holen)
    erste["items"][0]["title"] = "verbogen"
    assert einmal.einmal("k", holen) == {"items": [{"title": "A"}]}
    assert len(gezaehlt) == 1


def test_fehler_und_vorbereitung_werden_nicht_gemerkt():
    gezaehlt = []

    def kaputt():
        gezaehlt.append(1)
        raise RuntimeError("504")

    for _ in range(2):
        with pytest.raises(RuntimeError):
            einmal.einmal("f", kaputt)
    assert len(gezaehlt) == 2

    def bereitet():
        gezaehlt.append(1)
        return {"preparing": True}

    einmal.einmal("v", bereitet)
    einmal.einmal("v", bereitet)
    assert len(gezaehlt) == 4


# ── Stale while revalidating (AP74, 11.10.2026) ──────────────────────────────


def test_abgelaufen_liefert_sofort_und_erneuert_im_hintergrund():
    gezaehlt = []

    def holen():
        gezaehlt.append(1)
        time.sleep(0.2)
        return {"items": [len(gezaehlt)]}

    assert einmal.einmal("s", holen, frist_s=0.0) == {"items": [1]}
    # Stale right away: the old answer comes back at once, not after 0.2 s.
    start = time.monotonic()
    assert einmal.einmal("s", holen, frist_s=60.0) == {"items": [1]}
    assert time.monotonic() - start < 0.1
    # A second stale ask starts no second renewal.
    assert einmal.einmal("s", holen, frist_s=60.0) == {"items": [1]}
    einmal.erneuerung_abwarten("s")
    assert len(gezaehlt) == 2
    assert einmal.einmal("s", holen) == {"items": [2]}
    assert len(gezaehlt) == 2


def test_gescheiterte_erneuerung_behaelt_die_alte_antwort():
    gezaehlt = []

    def holen():
        gezaehlt.append(1)
        if len(gezaehlt) > 1:
            raise RuntimeError("504")
        return {"items": ["alt"]}

    assert einmal.einmal("g", holen, frist_s=0.0) == {"items": ["alt"]}
    assert einmal.einmal("g", holen) == {"items": ["alt"]}
    einmal.erneuerung_abwarten("g")
    assert len(gezaehlt) == 2
    # The failure set a grace period: the next ask is served, nothing is fetched.
    assert einmal.einmal("g", holen) == {"items": ["alt"]}
    assert len(gezaehlt) == 2


def test_zu_alt_wird_frisch_geholt(monkeypatch):
    gezaehlt = []

    def holen():
        gezaehlt.append(1)
        return {"items": [len(gezaehlt)]}

    assert einmal.einmal("z", holen, frist_s=0.0) == {"items": [1]}
    monkeypatch.setattr(einmal, "ALT_S", 0.0)
    # Older than ALT_S: no stale answer, the ask waits for the fetch.
    assert einmal.einmal("z", holen) == {"items": [2]}
    assert len(gezaehlt) == 2
