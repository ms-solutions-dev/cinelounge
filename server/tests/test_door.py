"""The door ("Einlass"): one list for everything that wants in (09.11.2026).

Pinned down here:

- join requests, pairing codes and invitations come from one route, newest
  first, with one count per kind;
- the console makes a code with a name and a kind from a fixed list;
- an expired code stays visible as `expired` for an hour, and nothing can be
  done with it any more — neither reserving an owner nor redeeming it;
- only somebody with console access sees the door.
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from cinelounge.web.access import Services


@pytest.fixture
def house(tmp_path, monkeypatch):
    (tmp_path / "portals").mkdir()
    monkeypatch.setenv("CL_DATA", str(tmp_path))
    import importlib

    from cinelounge.web import main

    importlib.reload(main)
    main.app.state.services = Services.from_path(tmp_path)
    d = main.app.state.services
    d.people.create("Max", "admin", "1234")
    d.people.create("Eli", "adult", None)
    d.people.create("Sina", "child", None)
    heads = {}
    for who in ("max", "sina"):
        o = d.devices.request_code(who, "phone", "192.0.2.5")
        heads[who] = {"X-CL-Device": d.devices.redeem(o.token, user_id=who)}
    return TestClient(main.app), heads, d


def _expire(d, token: str, seconds_ago: float = 60) -> None:
    with d.store.connect() as v:
        v.execute(
            "UPDATE pending SET valid_until = ? WHERE token = ?", (time.time() - seconds_ago, token)
        )


def test_one_list_newest_first(house):
    client, heads, _ = house
    head = heads["max"]
    client.post(
        "/join",
        json={
            "name": "Kemal",
            "color": "#D6A13A",
            "device": "iPad",
            "kind": "ios",
            "want": ["portals"],
        },
    )
    time.sleep(0.01)
    code = client.post(
        "/household/devices/code", json={"name": "Apple TV Küche", "kind": "tv"}, headers=head
    ).json()
    time.sleep(0.01)
    invite = client.post("/household/invite", json={"person": "eli"}, headers=head).json()

    a = client.get("/household/door", headers=head)
    assert a.status_code == 200, a.text
    items = a.json()["items"]
    assert [i["type"] for i in items] == ["invite", "code", "join"]
    assert items[0]["id"] == invite["token"] and items[0]["person"] == "eli"
    assert items[1]["code"] == code["code"] and items[1]["device"] == "Apple TV Küche"
    assert items[1]["kind"] == "tv" and items[1]["person"] is None
    assert items[2]["name"] == "Kemal" and items[2]["want"] == ["portals"]
    assert a.json()["counts"] == {"join": 1, "code": 1, "invite": 1}


def test_a_code_has_a_name_and_a_kind_from_the_list(house):
    client, heads, _ = house
    head = heads["max"]
    a = client.post(
        "/household/devices/code", json={"name": "  iPad   Sina ", "kind": "tablet"}, headers=head
    )
    assert a.status_code == 200 and a.json()["device"] == "iPad Sina"
    a = client.post("/household/devices/code", json={"name": "x", "kind": "toaster"}, headers=head)
    assert a.status_code == 422
    assert a.json()["error"]["code"] == "household.bad_device_kind"


def test_an_expired_code_shows_up_but_cannot_be_used(house):
    client, heads, d = house
    head = heads["max"]
    code = client.post("/household/devices/code", json={"kind": "tv"}, headers=head).json()["code"]
    _expire(d, code)

    items = client.get("/household/door", headers=head).json()
    shown = next(i for i in items["items"] if i["id"] == code)
    assert shown["expired"] is True and shown["expires_in_s"] == 0
    assert items["counts"]["code"] == 0, "an expired code does not count as waiting"

    a = client.post(f"/household/pending/{code}/person", json={"person": "sina"}, headers=head)
    assert a.status_code == 404, "no owner can be reserved on an expired code"
    a = client.post("/redeem", json={"token": code, "name": "TV"})
    assert a.status_code in (404, 410), a.text

    # After the hour of grace it is gone for good.
    _expire(d, code, seconds_ago=7200)
    assert all(i["id"] != code for i in client.get("/household/door", headers=head).json()["items"])


def test_an_expired_invitation_is_simply_gone(house):
    client, heads, d = house
    head = heads["max"]
    token = client.post("/household/invite", json={"person": "eli"}, headers=head).json()["token"]
    _expire(d, token)
    assert all(
        i["id"] != token for i in client.get("/household/door", headers=head).json()["items"]
    )


def test_only_console_access_sees_the_door(house):
    client, heads, _ = house
    assert client.get("/household/door", headers=heads["sina"]).status_code == 403
    assert client.get("/household/door").status_code == 401
    # Same right as the door: whoever pairs devices may also list them.
    assert client.get("/household/devices", headers=heads["max"]).status_code == 200
    assert client.get("/household/devices", headers=heads["sina"]).status_code == 403
