"""The next page is fetched before anybody asks (AP76, 11.10.2026)."""

from __future__ import annotations

import time
from types import SimpleNamespace

import pytest

from cinelounge.portalworks import einmal
from cinelounge.web import portals


@pytest.fixture(autouse=True)
def frisch():
    einmal.vergiss()
    yield
    einmal.vergiss()


def test_naechste_seite_liegt_danach_im_vorrat(monkeypatch):
    aufrufe = []

    def call(m, method, argumente=None, **kw):
        aufrufe.append((m.id, method, dict(argumente or {})))
        return {"items": [{"title": "B"}], "next_page": None}

    monkeypatch.setattr(portals.runner, "call", call)
    m = SimpleNamespace(id="kiefer")
    faden = portals.naechste_seite_vorholen(m, "e1", "p2", "")
    assert faden is not None
    faden.join(5)
    assert aufrufe == [("kiefer", "listing", {"entry": "e1", "next_page": "p2", "user_input": ""})]

    # The viewer's own ask carries the same key and finds the answer without a fetch.
    def nie():
        raise AssertionError("fetched again")

    assert einmal.einmal(("kiefer", "listing", "e1", "p2", ""), nie) == {
        "items": [{"title": "B"}],
        "next_page": None,
    }
    assert portals.naechste_seite_vorholen(m, "e1", None, "") is None


def test_ein_fehler_beim_vorholen_bleibt_still(monkeypatch):
    def kaputt(*a, **kw):
        raise RuntimeError("504")

    monkeypatch.setattr(portals.runner, "call", kaputt)
    faden = portals.naechste_seite_vorholen(SimpleNamespace(id="p"), "e", "n", "")
    assert faden is not None
    faden.join(5)
    assert not faden.is_alive()
    time.sleep(0.05)
