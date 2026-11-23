"""The first start: an empty container becomes a household.

**What is checked here is the only route that creates something without a
token.** It stands under three conditions — empty household, correct code, and
never again afterwards — and each of them is one line in `web/auth.py` that
somebody flips by accident at the next rebuild.

**Why the code exists at all.** A fresh container has no person and therefore
no PIN: whoever opens `cl.example` first creates the household. On a home network
that is not necessarily whoever started the container. Only somebody who can
look at the log sees the code — and whoever can do that has everything anyway.

Until 11.09.2026 the login form promised a setup code ("stands in the
container's log") the service never wrote, and there was no field for it
either.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from cinelounge.web import firstrun


@pytest.fixture()
def leer(tmp_path, monkeypatch):
    """A service without any person — and with an armed first-run code."""
    import importlib

    from cinelounge.web.access import Services

    (tmp_path / "portals").mkdir()
    monkeypatch.setenv("CL_DATA", str(tmp_path))
    from cinelounge.web import main

    importlib.reload(main)
    main.app.state.services = Services.from_path(tmp_path)

    code = firstrun.arm(main.app.state.services.people.is_empty())
    assert code, "without a person there has to be a code"
    return TestClient(main.app), code


# ── The code ────────────────────────────────────────────────────────────────


def test_ohne_person_gibt_es_einen_code(leer):
    client, _ = leer
    d = client.get("/login/who").json()
    assert d["setup_required"] is True
    assert d["setup_code_armed"] is True


def test_der_code_steht_im_protokoll(caplog):
    """**It is no use if nobody finds it.**

    Between uvicorn's lines a single line with eight characters cannot be seen
    — hence the frame, and hence this test.
    """
    import logging

    with caplog.at_level(logging.WARNING, logger="cinelounge.erstlauf"):
        code = firstrun.arm(True)
    text = caplog.text
    assert code and code in text
    assert "Setup code" in text
    assert "┌" in text, "without a frame nobody finds it while scrolling"


def test_ein_falscher_code_richtet_nichts_ein(leer):
    client, _ = leer
    antwort = client.post("/setup", json={"code": "FALSCH12", "name": "X", "pin": "1234"})
    assert antwort.status_code == 403
    assert antwort.json()["error"]["code"] == "setup.bad_code"
    assert client.get("/login/who").json()["setup_required"] is True


def test_nach_fuenf_fehlversuchen_gilt_ein_neuer(leer):
    """**Replace instead of lock.**

    A lock would be a service making itself unusable — and anybody on the
    network could trigger that without knowing the code. A new one costs the
    operator one glance at the log.
    """
    _, code = leer
    for _ in range(firstrun.ATTEMPTS):
        assert firstrun.check("NICHTSO1") is False

    assert firstrun.armed(), "the service must not lock itself out"
    assert firstrun.check(code) is False, "the old code no longer holds after the swap"


# ── The household ───────────────────────────────────────────────────────────


def test_mit_dem_code_entsteht_ein_admin_mit_geraet(leer):
    """And in one step: whoever sets up is signed in afterwards."""
    client, code = leer
    antwort = client.post("/setup", json={"code": code, "name": "Max", "pin": "1234"})
    assert antwort.status_code == 200, antwort.text

    d = antwort.json()
    assert d["person"]["role"] == "admin", "the first person has to be able to administer"
    assert d["device_token"]

    ich = client.get("/household/me", headers={"X-CL-Device": d["device_token"]})
    assert ich.status_code == 200
    assert ich.json()["name"] == "Max"


def test_danach_ist_der_weg_zu(leer):
    """**Once, and only once.**

    A second call with the same code would be a second admin, created by
    somebody who only saw the container log — possibly weeks later.
    """
    client, code = leer
    client.post("/setup", json={"code": code, "name": "Max", "pin": "1234"})

    zweiter = client.post("/setup", json={"code": code, "name": "Fremd", "pin": "1111"})
    assert zweiter.status_code == 409
    assert zweiter.json()["error"]["code"] == "setup.done"

    d = client.get("/login/who").json()
    assert d["setup_required"] is False
    assert d["setup_code_armed"] is False
    assert not firstrun.armed()


def test_der_haushalt_gewinnt_vor_dem_code(leer):
    """A wrong code at a set-up household says "already done".

    **Not "wrong code".** Otherwise the answer would reveal whether a guessed
    code was right — at a service that has long had nothing left to create for
    anybody.
    """
    client, code = leer
    client.post("/setup", json={"code": code, "name": "Max", "pin": "1234"})

    antwort = client.post("/setup", json={"code": "GERATEN1", "name": "X", "pin": "1234"})
    assert antwort.json()["error"]["code"] == "setup.done"


def test_die_einrichtung_steht_im_buch(leer):
    """The first line of every house."""
    client, code = leer
    d = client.post("/setup", json={"code": code, "name": "Max", "pin": "1234"}).json()

    events = client.get("/household/events", headers={"X-CL-Device": d["device_token"]}).json()[
        "events"
    ]
    assert any(e["code"] == "event.household_created" for e in events)


# ── The form ────────────────────────────────────────────────────────────────
