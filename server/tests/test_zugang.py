"""One access decision with a reason (AP90, 16.11.2026).

Three things are pinned down here:

1. **The table.** Person × portal × layer → the reason `household/zugang.py`
   gives, in the fixed order 18+ → switch → role → ready.
2. **Every route asks it.** A sweep over `app.routes` calls each route as a
   child against an 18+ portal and as an adult against a portal their role
   does not list. A new route that goes past the decision turns it red — and a
   counter-check proves the sweep notices such a route.
3. **The changes that were wanted:** continue watching stays at a fault,
   `/household/nights` shows only one's own portals (gap L1), `/stream`
   re-resolves only for a person who may still see the portal (gap L2), the
   manifest's default is written down once, the switch can carry roles and
   the marketplace sets roles and switch in one call.
"""

from __future__ import annotations

import io
import tarfile
import time

import pytest
from fastapi import APIRouter, Request
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient

from cinelounge.household import zugang
from cinelounge.household.devices import Devices
from cinelounge.household.people import People
from cinelounge.household.roles import Roles
from cinelounge.web.access import Anyone, Services

PORTALS = {
    # on, listed by both roles
    "ahorn": (
        "api: 1\nid: ahorn\nname: Ahorn\nkind: native\ncapabilities: [search]\nenabled: true\n"
    ),
    # 18+, on, listed by both roles (the child's by mistake: the age lock wins)
    "nightshift": (
        "api: 1\nid: nightshift\nname: Night\nkind: native\nadult: true\n"
        "capabilities: [search]\nenabled: true\n"
    ),
    # on by default only — never switched, listed by the adult role
    "quiet": "api: 1\nid: quiet\nname: Quiet\nkind: native\nenabled: true\n",
    # off by default, listed by the adult role
    "dark": "api: 1\nid: dark\nname: Dark\nkind: native\nenabled: false\n",
    # on, but listed by no role
    "orphan": "api: 1\nid: orphan\nname: Orphan\nkind: native\nenabled: true\n",
    # on, listed by the adult role, but broken (a required setting is empty)
    "faulty": (
        "api: 1\nid: faulty\nname: Faulty\nkind: native\nenabled: true\n"
        "settings: [{key: token, required: true}]\n"
    ),
}


@pytest.fixture
def world(tmp_path, monkeypatch):
    for name, body in PORTALS.items():
        folder = tmp_path / "portals" / name
        folder.mkdir(parents=True)
        (folder / "portal.yml").write_text(body, encoding="utf-8")
        (folder / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")

    monkeypatch.setenv("CL_DATA", str(tmp_path))
    import importlib

    from cinelounge.web import main

    importlib.reload(main)
    main.app.state.services = Services.from_path(tmp_path)
    d = main.app.state.services

    people = People(d.store)
    people.create("Max", "admin", "1234")
    people.create("Sina", "adult", "1234")
    people.create("Eli", "child", "1111")

    with d.store.connect() as v:
        # The lists exactly as the table below needs them. The child's
        # `nightshift` is written past the lock on purpose: the age lock must
        # still win.
        v.execute("DELETE FROM role_portal")
        v.executemany(
            "INSERT INTO role_portal (role_id, portal_id) VALUES (?, ?)",
            [("adult", p) for p in ("ahorn", "nightshift", "quiet", "dark", "faulty")]
            + [("child", "ahorn"), ("child", "nightshift")],
        )
        # `quiet` stays on by its default only: the row the start wrote goes.
        v.execute("DELETE FROM portal_switch WHERE portal_id = 'quiet'")

    dev = Devices(d.store)
    tokens = {}
    for who in ("max", "sina", "eli"):
        o = dev.request_code(who + "-device", "iOS 18.7", "192.0.2.5")
        tokens[who] = dev.redeem(o.token, user_id=who)
    shared = dev.request_code("Apple TV", "tvOS 18.4", "192.0.2.33")
    tokens["shared"] = dev.redeem(shared.token, user_id=None)
    return TestClient(main.app), tokens, d


def _head(tokens, who):
    if who == "shared-eli":
        return {"X-CL-Device": tokens["shared"], "X-CL-Profile": "eli"}
    return {"X-CL-Device": tokens[who]}


# ── 1 · The table ───────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("person", "portal", "reason"),
    [
        ("max", "ahorn", zugang.OK),
        ("sina", "ahorn", zugang.OK),
        ("eli", "ahorn", zugang.OK),
        ("sina", "nightshift", zugang.OK),
        ("eli", "nightshift", zugang.ADULT),
        ("sina", "quiet", zugang.OK),
        ("eli", "quiet", zugang.NO_ROLE),
        ("sina", "dark", zugang.OFF),
        ("eli", "dark", zugang.OFF),
        ("max", "orphan", zugang.NO_ROLE),
        ("sina", "faulty", zugang.BROKEN),
        ("eli", "faulty", zugang.NO_ROLE),
    ],
)
def test_the_decision_names_the_first_reason(world, person, portal, reason):
    _, _, d = world
    e = d.access.check(d.people.by_id(person), d.registry.manifests[portal])
    assert e.reason == reason
    assert e.allowed is (reason == zugang.OK)
    assert e.permitted is (reason in (zugang.OK, zugang.BROKEN))


def test_the_age_lock_comes_before_the_switch_and_readiness(world):
    """A child never learns that an 18+ portal is off or why it is broken."""
    _, _, d = world
    d.visibility.set_on("nightshift", False)
    d.registry.manifests["nightshift"].broken_reason = "setting required but empty: token"
    e = d.access.check(d.people.by_id("eli"), d.registry.manifests["nightshift"])
    assert (e.reason, e.detail) == (zugang.ADULT, None)


def test_readiness_comes_last_and_carries_its_reason(world):
    _, _, d = world
    e = d.access.check(d.people.by_id("sina"), d.registry.manifests["faulty"])
    assert e.detail == "setting required but empty: token"
    d.visibility.set_on("faulty", False)
    assert d.access.check(d.people.by_id("sina"), d.registry.manifests["faulty"]).reason == "off"


def test_no_role_names_the_role(world):
    _, _, d = world
    e = d.access.check(d.people.by_id("eli"), d.registry.manifests["quiet"])
    assert e.detail == "child"


def test_the_console_gets_the_decision_per_person(world):
    client, tokens, _ = world
    portals = {
        p["id"]: p
        for p in client.get("/household/portals", headers=_head(tokens, "max")).json()["portals"]
    }
    assert portals["nightshift"]["who"]["eli"] == {
        "allowed": False,
        "reason": "adult",
        "detail": None,
    }
    assert portals["ahorn"]["who"]["sina"]["allowed"] is True
    assert portals["faulty"]["who"]["sina"]["reason"] == "broken"
    assert {pid for pid, e in portals["orphan"]["who"].items() if e["allowed"]} == set()
    # Per role as well, for a role nobody holds yet: the same rule, not a copy.
    assert portals["nightshift"]["role_who"]["child"]["reason"] == "adult"
    assert portals["quiet"]["role_who"]["adult"]["allowed"] is True
    assert portals["faulty"]["role_who"]["adult"]["reason"] == "broken"


# ── 2 · Every route asks the decision ───────────────────────────────────────

#: Routes the sweep does not call, each with the reason.
SKIP = {
    # Ends the device's sign-in; the sweep needs it afterwards.
    ("POST", "/logout"),
    # Writes the caller's own progress and echoes the key the caller sent.
    # Nothing is read from the household; every read of it is filtered.
    ("POST", "/state"),
}


#: What the sweep fills in. Every placeholder a route has gets the probed
#: portal, so a route that takes the portal from anywhere is asked about it.
def _fill(path: str, portal: str) -> str:
    import re

    return re.sub(r"\{[^}]+\}", portal, path)


def _params(portal: str) -> dict[str, str]:
    return {
        "portal": portal,
        "address": "x",
        "source": "x",
        "q": "x",
        "key": portal + ":probe:",
        "entry": "x",
        "title": "x",
    }


def _body(portal: str) -> dict[str, object]:
    return {
        "portal": portal,
        "key": portal + ":probe:",
        "entry": "x",
        "on": True,
        "allowed": True,
        "address": "x",
    }


def leaks(client, app, head, portal) -> list[str]:
    """Every route whose answer names `portal` with a 2xx — a leak."""
    found = []
    calls = [
        (method, r)
        for r in app.routes
        if isinstance(r, APIRoute)
        for method in sorted(r.methods - {"HEAD"})
        if (method, r.path) not in SKIP
    ]
    # Reading first: a DELETE would otherwise take away what a GET should find.
    calls.sort(key=lambda c: c[0] != "GET")
    for method, r in calls:
        path = _fill(r.path, portal)
        kw: dict[str, object] = {"headers": head, "params": _params(portal)}
        if method in ("POST", "PUT", "PATCH"):
            kw["json"] = _body(portal)
        a = client.request(method, path, **kw)
        if 200 <= a.status_code < 300 and portal in a.text:
            found.append(f"{method} {r.path}")
    return found


@pytest.fixture
def quiet_portals(monkeypatch):
    """No portal code runs: every call answers with one item named after the portal."""
    from cinelounge.portalworks import playback
    from cinelounge.portalworks.runner import call as runner

    def call(m, method, args=None, limits=None, optional=False):
        if method == "menu":
            return [{"id": "x", "name": m.id}]
        if method in ("listing",):
            return {"items": [{"title": m.id, "address": "x"}]}
        return [{"title": m.id, "address": "x"}]

    monkeypatch.setattr(runner, "call", call)
    monkeypatch.setattr(playback, "sources", lambda m, a, t="", limits=None: [{"id": m.id}])
    monkeypatch.setattr(playback, "prepare", lambda *a, **k: None)
    monkeypatch.setattr(
        playback,
        "resolve_play",
        lambda m, **k: {"address": "http://192.0.2.9/" + m.id, "source": m.id, "kind": "file"},
    )


def _seed_progress(client, tokens, who, portal):
    client.post(
        "/state",
        headers=_head(tokens, who),
        json={
            "key": portal + ":probe:",
            "portal": portal,
            "position_s": 900,
            "duration_s": 3000,
            "favorite": True,
        },
    )


def test_no_route_hands_a_child_an_18plus_portal(world, quiet_portals):
    """Eli's role lists `nightshift`; no route may answer him with it."""
    client, tokens, d = world
    _seed_progress(client, tokens, "eli", "nightshift")
    d.nights.record("nightshift", False, step="menu", reason="timeout")
    from cinelounge.web import main

    for who in ("eli", "shared-eli"):
        assert leaks(client, main.app, _head(tokens, who), "nightshift") == [], who


def test_no_route_hands_an_adult_a_portal_their_role_lacks(world, quiet_portals):
    client, tokens, d = world
    _seed_progress(client, tokens, "sina", "orphan")
    d.nights.record("orphan", False, step="menu", reason="timeout")
    from cinelounge.web import main

    assert leaks(client, main.app, _head(tokens, "sina"), "orphan") == []


def test_the_sweep_sees_a_route_that_goes_past_the_decision(world, quiet_portals):
    """Counter-check: a route that reads the registry itself is found."""
    client, tokens, _ = world
    from cinelounge.web import main

    bypass = APIRouter()

    @bypass.get("/p/{portal_id}/bypass")
    def _bypass(request: Request, portal_id: str, person: Anyone) -> dict[str, object]:
        m = request.app.state.services.registry.manifests[portal_id]
        return {"portal": m.id}

    main.app.include_router(bypass)
    try:
        assert leaks(client, main.app, _head(tokens, "eli"), "nightshift") == [
            "GET /p/{portal_id}/bypass"
        ]
    finally:
        main.app.router.routes[:] = [
            r for r in main.app.router.routes if getattr(r, "path", "") != "/p/{portal_id}/bypass"
        ]


def test_the_sweep_sees_the_portal_where_it_is_allowed(world, quiet_portals):
    """Counter-check: an adult allowed to see `ahorn` does get it back — the sweep's
    calls reach the content, they do not just fail on their parameters."""
    client, tokens, d = world
    _seed_progress(client, tokens, "sina", "ahorn")
    d.nights.record("ahorn", False, step="menu", reason="timeout")
    from cinelounge.web import main

    found = set(leaks(client, main.app, _head(tokens, "sina"), "ahorn"))
    assert {
        "GET /portals",
        "GET /p/{portal_id}/menu",
        "GET /p/{portal_id}/list",
        "GET /search",
        "GET /play",
        "GET /resume",
        "GET /favorites",
        "GET /state",
        "GET /household/nights",
    } <= found


# ── 3 · What changed on purpose ─────────────────────────────────────────────


def test_continue_watching_stays_at_a_fault_and_play_says_why(world):
    """Owner, 16.11.2026: a broken portal's title stays; playing says "broken"."""
    client, tokens, _ = world
    head = _head(tokens, "sina")
    _seed_progress(client, tokens, "sina", "faulty")
    _seed_progress(client, tokens, "sina", "dark")

    resume = {x["key"] for x in client.get("/resume", headers=head).json()["resumable"]}
    favs = {x["key"] for x in client.get("/favorites", headers=head).json()["favorites"]}
    assert resume == favs == {"faulty:probe:"}, "broken stays, switched off does not"
    assert client.get("/state?key=faulty:probe:", headers=head).status_code == 200

    portals = client.get("/portals", headers=head).json()
    assert "faulty" not in {p["id"] for p in portals["portals"]}
    assert "faulty" in portals["permitted"] and "dark" not in portals["permitted"]

    a = client.get("/play?portal=faulty&address=x", headers=head)
    assert (a.status_code, a.json()["error"]["code"]) == (503, "portal.broken")


def test_a_child_never_sees_an_18plus_title_at_a_fault(world):
    client, tokens, d = world
    d.registry.manifests["nightshift"].broken_reason = "setting required but empty: token"
    _seed_progress(client, tokens, "eli", "nightshift")
    head = _head(tokens, "eli")
    assert client.get("/resume", headers=head).json()["resumable"] == []
    assert "nightshift" not in client.get("/portals", headers=head).json()["permitted"]


def test_nights_show_only_ones_own_portals(world):
    """Gap L1: the strips named every portal to every device."""
    client, tokens, d = world
    for p in PORTALS:
        d.nights.record(p, False, step="menu", reason="timeout")

    def seen(who):
        a = client.get("/household/nights", headers=_head(tokens, who))
        assert a.status_code == 200
        j = a.json()
        assert set(j["history"]) == set(j["last"]) >= set(j["failures"])
        return set(j["history"])

    assert seen("max") == set(PORTALS), "the console sees all of them"
    assert seen("sina") == {"ahorn", "nightshift", "quiet", "faulty"}, "broken stays, it explains"
    assert seen("eli") == {"ahorn"}
    assert seen("shared-eli") == {"ahorn"}


def test_a_borrowed_admin_profile_gets_no_console_view_of_the_nights(world):
    client, tokens, d = world
    for p in PORTALS:
        d.nights.record(p, True, step="play", reason="")
    head = {"X-CL-Device": tokens["shared"], "X-CL-Profile": "max"}
    got = set(client.get("/household/nights", headers=head).json()["history"])
    assert "orphan" not in got and "dark" not in got


def test_stream_resolves_again_only_for_who_may_still_see_it(world, monkeypatch):
    """Gap L2: `/stream` re-resolved any portal in its query."""
    client, _, d = world
    from cinelounge.portalworks import playback
    from cinelounge.stream import proxy
    from cinelounge.web import portals as routes

    asked: list[str] = []

    def again(m, source, limits=None):
        asked.append(m.id)
        return None

    def dead(*a, **k):
        raise OSError("gone")

    monkeypatch.setattr(proxy, "is_allowed", lambda a: True)
    monkeypatch.setattr(proxy, "fetch", dead)
    monkeypatch.setattr(playback, "resolve_again", again)
    monkeypatch.setattr(routes, "_GESPIELT", {})

    url = "/stream?address=http%3A%2F%2F192.0.2.9%2Fv&portal=ahorn&source=s1"
    assert client.get(url).status_code == 502
    assert asked == [], "nobody played s1 — nothing is resolved"

    routes._gespielt_merken("ahorn", "s1", "sina")
    client.get(url)
    assert asked == ["ahorn"]

    Roles(d.store).set_portal("adult", "ahorn", False)
    client.get(url)
    assert asked == ["ahorn"], "the role lost the portal — no new address"

    routes._gespielt_merken("nightshift", "s2", "eli")
    client.get(url.replace("portal=ahorn&source=s1", "portal=nightshift&source=s2"))
    assert asked == ["ahorn"], "a child's play never re-resolves an 18+ portal"


def test_play_remembers_the_source_for_its_person(world, quiet_portals, monkeypatch):
    client, tokens, _ = world
    from cinelounge.web import portals as routes

    monkeypatch.setattr(routes, "_GESPIELT", {})
    a = client.get("/play?portal=ahorn&address=x", headers=_head(tokens, "sina"))
    assert a.status_code == 200
    assert set(routes._GESPIELT["ahorn|ahorn"]) == {"sina"}


# ── The manifest's default becomes the switch, once ─────────────────────────


def _switches(d) -> dict[str, int]:
    with d.store.connect() as v:
        return {z["portal_id"]: z["on_air"] for z in v.execute("SELECT * FROM portal_switch")}


def test_the_default_is_written_down_once_and_stays(tmp_path):
    for name, body in PORTALS.items():
        folder = tmp_path / "portals" / name
        folder.mkdir(parents=True)
        (folder / "portal.yml").write_text(body, encoding="utf-8")
    d = Services.from_path(tmp_path)
    first = _switches(d)
    assert first == {
        "ahorn": 1,
        "nightshift": 1,
        "quiet": 1,
        "dark": 0,
        "orphan": 1,
        "faulty": 1,
    }
    pinned = [e for e in d.events.recent() if e["code"] == "event.switches_pinned"]
    assert len(pinned) == 1

    # Idempotent: a second start writes nothing and says nothing.
    d2 = Services.from_path(tmp_path)
    assert _switches(d2) == first
    assert len([e for e in d2.events.recent() if e["code"] == "event.switches_pinned"]) == 1

    # An update that flips `enabled:` no longer moves the switch.
    (tmp_path / "portals" / "dark" / "portal.yml").write_text(
        PORTALS["dark"].replace("enabled: false", "enabled: true"), encoding="utf-8"
    )
    (tmp_path / "portals" / "ahorn" / "portal.yml").write_text(
        PORTALS["ahorn"].replace("enabled: true", "enabled: false"), encoding="utf-8"
    )
    d3 = Services.from_path(tmp_path)
    assert _switches(d3) == first


def test_a_switched_portal_keeps_its_value(tmp_path):
    for name, body in PORTALS.items():
        folder = tmp_path / "portals" / name
        folder.mkdir(parents=True)
        (folder / "portal.yml").write_text(body, encoding="utf-8")
    d = Services.from_path(tmp_path)
    d.visibility.set_on("ahorn", False)
    d.visibility.set_on("dark", True)
    assert d.pin_switches() == []
    assert _switches(d)["ahorn"] == 0 and _switches(d)["dark"] == 1


def test_pinning_changes_nobody_s_view(tmp_path):
    """The rows carry the fallback's value: the same people see the same portals."""
    for name, body in PORTALS.items():
        folder = tmp_path / "portals" / name
        folder.mkdir(parents=True)
        (folder / "portal.yml").write_text(body, encoding="utf-8")
    d = Services.from_path(tmp_path)
    People(d.store).create("Sina", "adult", "1234")
    sina = d.people.by_id("sina")
    before = [m.id for m in d.access.visible(sina, d.registry.manifests.values())]
    with d.store.connect() as v:
        v.execute("DELETE FROM portal_switch")
    unpinned = [m.id for m in d.access.visible(sina, d.registry.manifests.values())]
    assert d.pin_switches()
    assert [m.id for m in d.access.visible(sina, d.registry.manifests.values())] == before
    assert unpinned == before


# ── Switching on with roles ─────────────────────────────────────────────────


def test_switching_on_without_a_role_says_nobody_sees_it(world):
    client, tokens, _ = world
    a = client.post(
        "/household/portals/orphan/switch", headers=_head(tokens, "max"), json={"on": True}
    )
    assert a.status_code == 200
    assert a.json()["who_sees"] == 0


def test_switching_on_with_roles_adds_them_in_the_same_step(world):
    client, tokens, d = world
    d.visibility.set_on("orphan", False)
    a = client.post(
        "/household/portals/orphan/switch",
        headers=_head(tokens, "max"),
        json={"on": True, "roles": ["adult", "child"]},
    )
    assert a.status_code == 200, a.text
    assert a.json()["who_sees"] == 3
    assert "orphan" in Roles(d.store).portals_of("child")
    codes = [e["code"] for e in d.events.recent()]
    assert codes.count("event.role_portal_changed") == 2


def test_a_locked_role_refuses_an_18plus_portal_and_nothing_is_written(world):
    client, tokens, d = world
    d.visibility.set_on("nightshift", False)
    with d.store.connect() as v:
        v.execute("DELETE FROM role_portal WHERE role_id = 'child'")
    a = client.post(
        "/household/portals/nightshift/switch",
        headers=_head(tokens, "max"),
        json={"on": True, "roles": ["adult", "child"]},
    )
    assert a.status_code == 409
    assert _switches(d)["nightshift"] == 0, "the switch did not move either"
    assert "nightshift" not in Roles(d.store).portals_of("child")


def test_an_unknown_role_refuses_before_anything_moves(world):
    client, tokens, d = world
    d.visibility.set_on("orphan", False)
    a = client.post(
        "/household/portals/orphan/switch",
        headers=_head(tokens, "max"),
        json={"on": True, "roles": ["nope"]},
    )
    assert a.status_code == 404
    assert _switches(d)["orphan"] == 0


# ── The marketplace in one call ─────────────────────────────────────────────


def _archive(manifest: str, root: str) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, text in (("portal.yml", manifest), ("portal.py", "class Portal: pass\n")):
            raw = text.encode()
            info = tarfile.TarInfo(f"{root}/{name}")
            info.size = len(raw)
            info.mtime = int(time.time())
            tar.addfile(info, io.BytesIO(raw))
    return buf.getvalue()


@pytest.fixture
def market(world, monkeypatch):
    import hashlib

    from cinelounge.market import install as market_install

    client, tokens, d = world
    raw = {
        "zinne": _archive("api: 1\nid: zinne\nname: Zinne\nkind: native\n", "zinne"),
        "late": _archive("api: 1\nid: late\nname: Late\nkind: native\nadult: true\n", "late"),
    }
    entries = [
        {
            "id": k,
            "source": "s",
            "url": k,
            "sha256": hashlib.sha256(v).hexdigest(),
            "version": "1.0.0",
            "adult": k == "late",
        }
        for k, v in raw.items()
    ]
    monkeypatch.setattr(d.sources, "fetch_all", lambda: (entries, {}))
    monkeypatch.setattr(d.trust, "check", lambda e: ("signed", "abc"))
    monkeypatch.setattr(market_install, "fetch_archive", lambda url, sha: raw[url])
    return client, tokens, d


def test_install_sets_roles_and_switch_in_one_call(market):
    client, tokens, d = market
    a = client.post(
        "/household/market/install",
        headers=_head(tokens, "max"),
        json={"portal": "zinne", "roles": ["adult", "child"], "on": True},
    )
    assert a.status_code == 200, a.text
    assert a.json()["on"] is True and a.json()["who_sees"] == 3
    assert _switches(d)["zinne"] == 1
    assert "zinne" in Roles(d.store).portals_of("child")


def test_install_with_a_bad_role_leaves_nothing_behind(market):
    client, tokens, d = market
    a = client.post(
        "/household/market/install",
        headers=_head(tokens, "max"),
        json={"portal": "late", "roles": ["adult", "child"], "on": True},
    )
    assert a.status_code == 409
    assert "late" not in d.registry.manifests, "not installed"
    assert not (d.registry.root / "late").exists()
    assert "late" not in _switches(d)


def test_install_without_roles_changes_no_access(market):
    """The old call stays what it was: install only, the default pinned."""
    client, tokens, d = market
    a = client.post(
        "/household/market/install", headers=_head(tokens, "max"), json={"portal": "zinne"}
    )
    assert a.status_code == 200
    assert _switches(d)["zinne"] == 0, "no `enabled:` in the manifest: off, written down"
    assert "zinne" not in Roles(d.store).portals_of("adult")
