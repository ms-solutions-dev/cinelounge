"""A portal waiting for a setting is `needs_setting`, not `broken`.

An empty required setting kept the portal from playing — rightly — but every
answer called it `broken`: the portal list, `/health`, the console, the night
book. The operator went looking for a fault in the code while all it needed
was a value. Pinned down here:

1. **The manifest** says `needs_setting` with the empty keys, and only for
   that reason; any other defect stays `broken`.
2. **`/health`** counts it under `needs_setting`, beside `broken` — a monitor
   that rings on `broken` stays quiet.
3. **The console** (`/household/portals`, the settings answer, the workshop)
   sends the word and the keys.
4. **Playing** it is still refused with `portal.broken` — the code the apps
   carry a sentence for — and the refusal names the keys.
5. **The night** skips it like a switched-off portal: no failure, no message.

All portals here are made up.
"""

from __future__ import annotations

import importlib

import pytest
from fastapi.testclient import TestClient

from cinelounge.household.devices import Devices
from cinelounge.household.people import People
from cinelounge.portalworks import manifest
from cinelounge.web.access import Services

PORTALS = {
    # ready
    "ahorn": "api: 1\nid: ahorn\nname: Ahorn\nkind: native\nenabled: true\n",
    # a required setting is empty
    "fichte": (
        "api: 1\nid: fichte\nname: Fichte\nkind: native\nenabled: true\n"
        "settings: [{key: token, required: true}, {key: region, value: ''}]\n"
    ),
    # broken for another reason: an unknown key
    "ulme": "api: 1\nid: ulme\nname: Ulme\nkind: native\nenabled: true\nquatsch: ja\n",
}


def _write(root, portals):
    for name, body in portals.items():
        folder = root / "portals" / name
        folder.mkdir(parents=True)
        (folder / "portal.yml").write_text(body, encoding="utf-8")
        (folder / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")


@pytest.fixture
def world(tmp_path, monkeypatch):
    _write(tmp_path, PORTALS)
    monkeypatch.setenv("CL_DATA", str(tmp_path))
    from cinelounge.web import main

    importlib.reload(main)
    main.app.state.services = Services.from_path(tmp_path)
    d = main.app.state.services
    max = People(d.store).create("Max", "admin", "1234")
    with d.store.connect() as v:
        v.executemany(
            "INSERT OR IGNORE INTO role_portal (role_id, portal_id) VALUES (?, ?)",
            [(max.role_id, p) for p in PORTALS],
        )
    dev = Devices(d.store)
    o = dev.request_code("max-device", "iOS 18.7", "192.0.2.5")
    head = {"X-CL-Device": dev.redeem(o.token, user_id="max")}
    return TestClient(main.app), head, d


# ── 1 · The manifest ─────────────────────────────────────────────────────────


def test_an_empty_required_setting_is_needs_setting(tmp_path):
    _write(tmp_path, {"fichte": PORTALS["fichte"]})
    m = manifest.read(tmp_path / "portals" / "fichte" / "portal.yml")
    assert not m.is_ready, "it still cannot play"
    assert m.needs_setting
    assert m.state == "needs_setting"
    assert m.missing_settings == ["token"], "only the required one"
    j = m.as_json()
    assert (j["state"], j["missing_settings"]) == ("needs_setting", ["token"])
    assert j["reason"] == "setting required but empty: token", "the sentence stays"


def test_the_value_makes_it_ready_and_taking_it_away_brings_it_back(tmp_path):
    _write(tmp_path, {"fichte": PORTALS["fichte"]})
    file = tmp_path / "portals" / "fichte" / "portal.yml"
    m = manifest.read(file)
    manifest.overlay(m, {"token": "abc"})
    assert (m.state, m.missing_settings) == ("ready", [])
    m2 = manifest.read(file)
    manifest.overlay(m2, {"token": ""})
    assert m2.state == "needs_setting"


def test_another_defect_stays_broken(tmp_path):
    """An unknown key, a missing `portal.py`: no value mends that."""
    _write(tmp_path, {"ulme": PORTALS["ulme"]})
    m = manifest.read(tmp_path / "portals" / "ulme" / "portal.yml")
    assert (m.state, m.missing_settings) == ("broken", [])
    assert not m.needs_setting


def test_a_read_defect_wins_over_the_empty_setting(tmp_path):
    """A manifest without `portal.py` and with an empty required key is broken:
    filling the key would not make it play."""
    folder = tmp_path / "portals" / "fichte"
    folder.mkdir(parents=True)
    (folder / "portal.yml").write_text(PORTALS["fichte"], encoding="utf-8")
    m = manifest.read(folder / "portal.yml")
    manifest.overlay(m, {"region": "x"})
    assert m.state == "broken"


# ── 2 · /health ──────────────────────────────────────────────────────────────


def test_health_counts_it_beside_broken(world):
    client, _, _ = world
    h = client.get("/health").json()
    assert [x["id"] for x in h["broken"]] == ["ulme"]
    assert h["needs_setting"] == [
        {"id": "fichte", "reason": "setting required but empty: token", "settings": ["token"]}
    ]
    assert h["portals"] == 3 and h["ready"] == 1
    assert h["ready"] + len(h["broken"]) + len(h["needs_setting"]) == h["portals"]


# ── 3 · The console ──────────────────────────────────────────────────────────


def test_the_console_list_sends_the_word_and_the_keys(world):
    client, head, _ = world
    portals = {p["id"]: p for p in client.get("/household/portals", headers=head).json()["portals"]}
    assert portals["fichte"]["state"] == "needs_setting"
    assert portals["fichte"]["missing_settings"] == ["token"]
    assert portals["ulme"]["state"] == "broken"
    assert portals["ahorn"]["state"] == "ready"
    work = {p["id"]: p for p in client.get("/household/workshop", headers=head).json()["portals"]}
    assert (work["fichte"]["ready"], work["fichte"]["state"]) == (False, "needs_setting")


def test_filling_the_setting_answers_ready_and_emptying_it_needs_setting(world):
    client, head, _ = world
    url = "/household/portals/fichte/settings"
    a = client.put(url, headers=head, json={"settings": {"token": "abc"}}).json()
    assert (a["state"], a["missing_settings"]) == ("ready", [])
    b = client.put(url, headers=head, json={"settings": {"token": ""}}).json()
    assert (b["state"], b["missing_settings"]) == ("needs_setting", ["token"])


# ── 4 · Playing ──────────────────────────────────────────────────────────────


def test_playing_it_is_refused_with_the_known_code_and_the_keys(world):
    client, head, _ = world
    a = client.get("/play?portal=fichte&address=x", headers=head)
    assert a.status_code == 503
    err = a.json()["error"]
    assert err["code"] == "portal.broken", "the code the apps carry a sentence for"
    assert err["values"]["settings"] == ["token"]
    assert err["values"]["state"] == "needs_setting"
    assert "token" in err["values"]["why"]


def test_a_broken_portal_is_refused_as_before(world):
    client, head, d = world
    # A manifest that cannot be read has no default switch; on by hand.
    d.visibility.set_on("ulme", True)
    err = client.get("/play?portal=ulme&address=x", headers=head).json()["error"]
    assert err["code"] == "portal.broken"
    assert "settings" not in err["values"] and "state" not in err["values"]


# ── 5 · The night ────────────────────────────────────────────────────────────


def test_the_night_skips_it_without_a_failure(world):
    _, _, d = world
    from cinelounge.web import nightwatch

    calls = []

    class Book:
        def record(self, code, values=None, who=""):
            calls.append(code)

    for _ in range(4):
        out = nightwatch.run_once(d.registry, d.nights, events=Book(), gap_s=0, only="fichte")
        assert out["skipped"] == ["fichte"] and out["failed"] == []
    assert calls == [], "no `event.portal_failing` for a missing value"
    assert not d.nights.failing("fichte")
    last = d.nights.last("fichte")
    assert last is not None and last.step == "needs_setting"
