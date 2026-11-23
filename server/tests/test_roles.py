"""Roles as data and console access as a flag on the person (09.11.2026).

What is pinned down here:

- migration 11 turns the old per-person permissions into role lists the way
  the household expects (adults keep everything, children keep only what they
  all had) and console access comes from the old `admin`;
- roles can be created, changed and deleted, with the two lockout rules;
- console access needs the decider's PIN and stays with the last holder;
- letting somebody in at the door needs no PIN unless it hands out the console;
- a backup from before roles still restores into a working household.
"""

from __future__ import annotations

import sqlite3

import pytest
from fastapi.testclient import TestClient

from cinelounge.core import errors as f
from cinelounge.household import backup
from cinelounge.household.people import People
from cinelounge.household.roles import Roles
from cinelounge.household.store import MIGRATIONS, Store
from cinelounge.web.access import Services

ROLES_MIGRATION = next(i for i, m in enumerate(MIGRATIONS) if "CREATE TABLE role (" in m)

MANIFEST = """\
api: 1
id: {id}
name: {name}
kind: native
adult: {adult}
enabled: {default}
"""


def _old_household(path) -> None:
    """A household database exactly as it was before roles existed."""
    v = sqlite3.connect(path)
    for sql in MIGRATIONS[:ROLES_MIGRATION]:
        v.executescript(sql)
    v.execute(f"PRAGMA user_version = {ROLES_MIGRATION}")
    for ident, role in (("max", "admin"), ("sina", "child"), ("tv", "child"), ("eli", "adult")):
        v.execute(
            "INSERT INTO person (id, name, role, pin_hash, color, created) "
            "VALUES (?, ?, ?, '', '#E2564A', 0)",
            (ident, ident.title(), role),
        )
    rows = [
        ("sina", "ahorn"),
        ("sina", "zinne"),
        ("tv", "ahorn"),
        ("tv", "zinne"),
        ("tv", "esche"),
        ("eli", "kastanie"),
    ]
    v.executemany("INSERT INTO visibility (person_id, portal_id) VALUES (?, ?)", rows)
    v.executemany(
        "INSERT INTO portal_switch (portal_id, on_air) VALUES (?, ?)",
        [("ahorn", 1), ("zinne", 1), ("esche", 1), ("avena", 1), ("nachtfalter", 0)],
    )
    v.commit()
    v.close()


def test_migration_turns_permissions_into_roles(tmp_path):
    path = tmp_path / "household.sqlite"
    _old_household(path)
    store = Store(path)
    people = {p.id: p for p in People(store).list_all()}

    assert people["max"].role_id == "adult" and people["max"].console
    assert people["eli"].role_id == "adult" and not people["eli"].console
    assert people["sina"].role_id == "child" and not people["sina"].console
    # The derived old name still reads the same for the app.
    assert [people[i].role for i in ("max", "eli", "sina")] == ["admin", "adult", "child"]

    roles = {r.id: r for r in Roles(store).list_all()}
    # Adults: what any adult was permitted plus everything switched on.
    assert roles["adult"].portals == {"ahorn", "zinne", "esche", "avena", "kastanie"}
    # Children: only what every child had — the stricter answer wins.
    assert roles["child"].portals == {"ahorn", "zinne"}
    # The old table stays for the way back.
    with store.connect() as v:
        assert v.execute("SELECT COUNT(*) FROM visibility").fetchone()[0] == 6


def test_household_without_children_gives_the_child_role_the_adult_list(tmp_path):
    path = tmp_path / "household.sqlite"
    v = sqlite3.connect(path)
    for sql in MIGRATIONS[:ROLES_MIGRATION]:
        v.executescript(sql)
    v.execute(f"PRAGMA user_version = {ROLES_MIGRATION}")
    v.execute("INSERT INTO portal_switch (portal_id, on_air) VALUES ('ahorn', 1)")
    v.commit()
    v.close()
    roles = {r.id: r for r in Roles(Store(path)).list_all()}
    assert roles["child"].portals == {"ahorn"}


def test_defaults_are_adopted_once(tmp_path):
    path = tmp_path / "household.sqlite"
    _old_household(path)
    store = Store(path)
    roles = Roles(store)
    roles.adopt_defaults(["3tal", "ahorn"], switched={"ahorn"})
    assert "3tal" in roles.by_id("adult").portals  # type: ignore[union-attr]
    # Children exist, so their list does not grow by itself.
    assert "3tal" not in roles.by_id("child").portals  # type: ignore[union-attr]
    roles.set_portal("adult", "3tal", False)
    roles.adopt_defaults(["3tal"], switched=set())
    assert "3tal" not in roles.by_id("adult").portals, "only once"  # type: ignore[union-attr]


def test_rights_come_from_role_and_console(tmp_path):
    people = People(Store(tmp_path / "h.sqlite"))
    max = people.create("Max", "admin", "1234")
    sina = people.create("Sina", "child", None)
    assert max.may("workshop") and max.may("view_adult")
    assert not sina.may("workshop") and not sina.may("view_adult") and sina.may("watch")
    assert not max.may("no_such_right")


def test_role_lifecycle_and_lockout_rules(tmp_path):
    store = Store(tmp_path / "h.sqlite")
    roles, people = Roles(store), People(store)
    teen = roles.create("Teenager", "#c08cf5", ["watch", "own_devices"], ["ahorn"])
    assert teen.id == "teenager" and teen.portals == {"ahorn"}
    assert roles.create("Teenager", "#c08cf5", ["watch"]).id == "teenager-2"

    with pytest.raises(f.Error) as e:
        roles.update(teen.id, rights=["watch", "pair_devices"])
    assert e.value.code == "role.unknown_right"
    with pytest.raises(f.Error) as e:
        roles.update(teen.id, color="red")
    assert e.value.code == "role.bad_color"

    people.create("Elif", teen.id, None)
    assert people.by_id("elif").role == "child"  # type: ignore[union-attr]
    with pytest.raises(f.Error) as e:
        roles.delete(teen.id)
    assert e.value.code == "role.in_use"

    # Granting "ab 18" moves the derived old name along.
    roles.update(teen.id, rights=["watch", "view_adult"])
    assert people.by_id("elif").role == "adult"  # type: ignore[union-attr]

    people.set_role("elif", "child")
    roles.delete(teen.id)
    assert roles.by_id(teen.id) is None
    for r in roles.list_all():
        if r.id != "child" and not roles.members().get(r.id):
            roles.delete(r.id)
    with pytest.raises(f.Error) as e:
        roles.delete("child")
    assert e.value.code in {"role.in_use", "role.last_role"}


def test_console_access_needs_a_pin_and_keeps_the_last_holder(tmp_path):
    people = People(Store(tmp_path / "h.sqlite"))
    people.create("Max", "admin", "1234")
    people.create("Sina", "child", None)
    with pytest.raises(f.Error) as e:
        people.set_console("sina", True)
    assert e.value.code == "household.console_needs_pin"
    assert people.set_console("sina", True, "4711").console
    assert people.sign_in("sina", "4711").may("change_access")
    assert not people.set_console("max", False).console
    with pytest.raises(f.Error) as e:
        people.set_console("sina", False)
    assert e.value.code == "household.last_admin"


def test_restoring_a_backup_from_before_roles(tmp_path):
    store = Store(tmp_path / "h.sqlite")
    data = {
        "version": backup.VERSION,
        "tables": {
            "person": [
                {
                    "id": "max",
                    "name": "Max",
                    "role": "admin",
                    "pin_hash": "",
                    "color": "#E2564A",
                    "created": 0,
                },
                {
                    "id": "sina",
                    "name": "Sina",
                    "role": "child",
                    "pin_hash": "",
                    "color": "#4A7FD9",
                    "created": 1,
                },
            ],
        },
    }
    backup.restore(store, data, replace=True)
    people = {p.id: p for p in People(store).list_all()}
    assert people["max"].console and people["max"].role_id == "adult"
    assert people["sina"].role_id == "child"
    assert {r.id for r in Roles(store).list_all()} == {"adult", "child"}


def test_the_pre_deploy_check_reports_every_change(tmp_path, capsys):
    """`scripts/check_role_migration.py` is run against the real household
    before deploying. It must name a child whose list would change — here `tv`,
    which loses `esche` to the children's intersection — and leave Sina "OK"."""
    import importlib.util
    from pathlib import Path

    spec = importlib.util.spec_from_file_location(
        "check", Path(__file__).parent.parent / "scripts" / "check_role_migration.py"
    )
    check = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(check)  # type: ignore[union-attr]

    for ident, adult in (
        ("ahorn", "false"),
        ("zinne", "false"),
        ("esche", "false"),
        ("avena", "false"),
        ("kastanie", "false"),
        ("nachtfalter", "true"),
    ):
        folder = tmp_path / "portals" / ident
        folder.mkdir(parents=True)
        (folder / "portal.yml").write_text(
            MANIFEST.format(id=ident, name=ident, adult=adult, default="false"), encoding="utf-8"
        )
        (folder / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    db = tmp_path / "household.sqlite"
    _old_household(db)
    before = db.read_bytes()

    assert check.main(db, tmp_path / "portals") == 1, "changes, but no child gains"
    out = capsys.readouterr().out
    assert "OK   sina" in out
    assert "DIFF tv" in out and "- loses: esche" in out
    # An adult with a short personal list gets the adult role's list — the
    # consequence of "no per-person exceptions"; it must be visible, not hidden.
    assert "DIFF eli" in out and "+ gains: ahorn, avena, esche, zinne" in out
    assert "!!!" not in out
    assert db.read_bytes() == before, "the real database is never touched"

    # A child that would gain is the hard stop. The migration cannot produce
    # that by construction (children get the intersection), so a broken
    # "after" is slipped in to prove the stop fires.
    real_after = check._after

    def leaky(*args):
        seen, role_of = real_after(*args)
        seen["sina"] = seen["sina"] | {"nachtfalter"}
        return seen, role_of

    check._after = leaky
    assert check.main(db, tmp_path / "portals") == 2
    assert "!!! a child would see more" in capsys.readouterr().out
    assert db.read_bytes() == before, "the real database is never touched"


# ── Over HTTP ────────────────────────────────────────────────────────────────


@pytest.fixture
def house(tmp_path, monkeypatch):
    for ident, name, adult in (("ahorn", "Ahorn", "false"), ("nightshift", "Nightshift", "true")):
        folder = tmp_path / "portals" / ident
        folder.mkdir(parents=True)
        (folder / "portal.yml").write_text(
            MANIFEST.format(id=ident, name=name, adult=adult, default="true"), encoding="utf-8"
        )
        (folder / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    monkeypatch.setenv("CL_DATA", str(tmp_path))
    import importlib

    from cinelounge.web import main

    importlib.reload(main)
    main.app.state.services = Services.from_path(tmp_path)
    d = main.app.state.services
    d.people.create("Max", "admin", "1234")
    o = d.devices.request_code("max", "ios", "192.0.2.5")
    token = d.devices.redeem(o.token, user_id="max")
    return TestClient(main.app), {"X-CL-Device": token}, d


def test_roles_over_http(house):
    client, head, _ = house
    a = client.get("/household/roles", headers=head).json()
    assert [r["id"] for r in a["roles"]] == ["adult", "child"]
    assert "own_devices" in a["rights"]

    a = client.post("/household/roles", json={"name": "Gast", "portals": ["ahorn"]}, headers=head)
    assert a.status_code == 200 and a.json()["rights"] == ["watch", "track_progress"]
    gast = a.json()["id"]

    a = client.post(
        f"/household/roles/{gast}/portals", json={"portal": "nightshift", "on": True}, headers=head
    )
    assert sorted(a.json()["portals"]) == ["ahorn", "nightshift"]
    a = client.patch(f"/household/roles/{gast}", json={"name": "Besuch"}, headers=head)
    assert a.json()["name"] == "Besuch"
    assert client.delete(f"/household/roles/{gast}", headers=head).status_code == 200


def test_the_door_needs_no_pin_unless_it_hands_out_the_console(house):
    client, head, d = house
    req = client.post(
        "/join",
        json={
            "name": "Selin",
            "color": "#4A90D9",
            "device": "iPhone",
            "kind": "ios",
            "want": ["portals"],
        },
    ).json()["request"]
    a = client.post(f"/household/joins/{req}/approve", json={"role": "child"}, headers=head)
    assert a.status_code == 200, a.text
    assert a.json()["portals"] == ["ahorn"], "the age lock keeps nightshift out"
    assert d.people.by_id("selin").role_id == "child"  # type: ignore[union-attr]

    req = client.post(
        "/join",
        json={
            "name": "Kemal",
            "color": "#D6A13A",
            "device": "iPad",
            "kind": "ios",
            "want": ["portals"],
        },
    ).json()["request"]
    a = client.post(f"/household/joins/{req}/approve", json={"role": "admin"}, headers=head)
    assert a.status_code == 401, "handing out the console needs the decider's PIN"


def test_console_over_http(house):
    client, head, d = house
    d.people.create("Sina", "child", None)
    a = client.post(
        "/household/people/sina/console", json={"on": True, "my_pin": "1234"}, headers=head
    )
    assert a.status_code == 422 and a.json()["error"]["code"] == "household.console_needs_pin"
    a = client.post(
        "/household/people/sina/console",
        json={"on": True, "my_pin": "1234", "pin": "4711"},
        headers=head,
    )
    assert a.status_code == 200 and a.json()["console"] is True and a.json()["role_id"] == "child"
    me = client.get("/household/me", headers=head).json()
    assert me["console"] is True and me["role_id"] == "adult"


# ── The child lock (migration 12, 09.11.2026) ────────────────────────────────


def test_a_new_household_starts_with_the_child_role_locked(tmp_path):
    roles = Roles(Store(tmp_path / "h.sqlite"))
    assert roles.by_id("child").child_lock  # type: ignore[union-attr]
    assert not roles.by_id("adult").child_lock  # type: ignore[union-attr]
    with pytest.raises(f.Error) as e:
        roles.update("child", rights=["watch", "view_adult"])
    assert e.value.code == "role.child_locked"


def test_the_lock_holds_over_http_and_only_a_pin_lifts_it(house):
    client, head, d = house
    # An 18+ portal cannot go into the locked child role, by either way.
    a = client.post(
        "/household/roles/child/portals", json={"portal": "nightshift", "on": True}, headers=head
    )
    assert a.status_code == 409 and a.json()["error"]["code"] == "role.child_locked"
    a = client.patch(
        "/household/roles/child", json={"portals": ["ahorn", "nightshift"]}, headers=head
    )
    assert a.status_code == 409
    d.people.create("Sina", "child", None)
    a = client.post(
        "/household/people/sina/access",
        json={"portal": "nightshift", "allowed": True},
        headers=head,
    )
    assert a.status_code == 409
    a = client.patch(
        "/household/roles/child", json={"rights": ["watch", "view_adult"]}, headers=head
    )
    assert a.status_code == 409
    assert "nightshift" not in d.roles.by_id("child").portals  # type: ignore[union-attr]

    # Lifting it: no PIN, wrong PIN, right PIN.
    assert (
        client.post(
            "/household/roles/child/child_lock", json={"on": False}, headers=head
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/household/roles/child/child_lock", json={"on": False, "my_pin": "0000"}, headers=head
        ).status_code
        == 401
    )
    a = client.post(
        "/household/roles/child/child_lock", json={"on": False, "my_pin": "1234"}, headers=head
    )
    assert a.status_code == 200 and a.json()["child_lock"] is False

    # Unlocked, it can be given 18+ — and locking again takes it all back out.
    client.patch("/household/roles/child", json={"rights": ["watch", "view_adult"]}, headers=head)
    client.post(
        "/household/roles/child/portals", json={"portal": "nightshift", "on": True}, headers=head
    )
    assert d.people.by_id("sina").adult  # type: ignore[union-attr]
    a = client.post("/household/roles/child/child_lock", json={"on": True}, headers=head)
    assert a.json()["child_lock"] and "view_adult" not in a.json()["rights"]
    assert "nightshift" not in a.json()["portals"]
    assert not d.people.by_id("sina").adult  # type: ignore[union-attr]


def test_a_role_made_for_children_drops_18plus(house):
    client, head, _ = house
    a = client.post(
        "/household/roles",
        json={
            "name": "Enkel",
            "rights": ["watch", "view_adult"],
            "portals": ["ahorn", "nightshift"],
            "child_lock": True,
        },
        headers=head,
    )
    assert a.status_code == 200
    assert (
        a.json()["child_lock"]
        and a.json()["rights"] == ["watch"]
        and a.json()["portals"] == ["ahorn"]
    )


def test_an_old_backup_does_not_unlock_the_child_role(tmp_path):
    store = Store(tmp_path / "h.sqlite")
    old = {
        "version": backup.VERSION,
        "tables": {
            "role": [
                {
                    "id": "adult",
                    "name": "Adult",
                    "color": "#6aa8ff",
                    "rights": "watch,view_adult",
                    "position": 0,
                    "created": 0,
                },
                {
                    "id": "child",
                    "name": "Child",
                    "color": "#6fcf8e",
                    "rights": "watch",
                    "position": 1,
                    "created": 0,
                },
            ],
        },
    }
    backup.restore(store, old, replace=True)
    assert Roles(store).by_id("child").child_lock  # type: ignore[union-attr]


def test_an_18plus_leftover_in_a_locked_role_goes_at_start(tmp_path, monkeypatch):
    folder = tmp_path / "portals" / "nightshift"
    folder.mkdir(parents=True)
    (folder / "portal.yml").write_text(
        MANIFEST.format(id="nightshift", name="N", adult="true", default="true"), encoding="utf-8"
    )
    (folder / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    store = Store(tmp_path / "household.sqlite")
    with store.connect() as v:
        v.execute("INSERT INTO role_portal (role_id, portal_id) VALUES ('child', 'nightshift')")
    monkeypatch.setenv("CL_DATA", str(tmp_path))
    d = Services.from_path(tmp_path)
    assert "nightshift" not in d.roles.by_id("child").portals  # type: ignore[union-attr]


def test_a_role_called_admin_is_a_role_and_not_the_old_alias(house):
    """Found on the household copy (09.11.2026): a role named "Admin" got the id
    `admin`, which the server reads as the old alias for adult + console — the
    person moved into it stayed in "Adult"."""
    client, head, d = house
    a = client.post(
        "/household/roles",
        json={"name": "Admin", "rights": ["watch", "view_adult"], "portals": ["ahorn"]},
        headers=head,
    )
    rid = a.json()["id"]
    assert rid != "admin" and a.json()["name"] == "Admin"
    assert (
        client.post("/household/people/max/role", json={"role": rid}, headers=head).status_code
        == 200
    )
    assert d.people.by_id("max").role_id == rid  # type: ignore[union-attr]


# ── Approving a join with roles as data (AP85 #73, 09.11.2026) ───────────────


def _join(client, name):
    return client.post(
        "/join",
        json={
            "name": name,
            "color": "#4A90D9",
            "device": "iPhone",
            "kind": "phone",
            "want": ["portals"],
        },
    ).json()["request"]


def test_the_request_list_carries_the_roles_to_choose_from(house):
    client, head, _ = house
    _join(client, "Selin")
    a = client.get("/household/joins", headers=head)
    assert a.status_code == 200, a.text
    roles = {r["id"]: r for r in a.json()["roles"]}
    assert roles["child"] == {
        "id": "child",
        "name": roles["child"]["name"],
        "color": roles["child"]["color"],
        "adult": False,
        "own_devices": False,
    }
    assert roles["adult"]["adult"] is True and roles["adult"]["own_devices"] is True
    assert "portals" not in roles["adult"], "the choice needs no portal list"


def test_role_and_console_are_approved_apart(house):
    client, head, d = house
    # The adult role with the 18+ lock — the household after go-live step 5.
    d.roles.create(
        "Ab 18",
        "#E2564A",
        ["watch", "track_progress", "view_adult", "own_devices", "invite"],
        ["ahorn", "nightshift"],
    )
    ab18 = next(r.id for r in d.roles.list_all() if r.name == "Ab 18")
    client.post(
        "/household/roles/adult/child_lock", json={"on": True, "my_pin": "1234"}, headers=head
    )

    # The old word: the adult role plus console — now the locked one, so no 18+.
    req = _join(client, "Alt")
    a = client.post(
        f"/household/joins/{req}/approve",
        json={"role": "admin", "pin": "1234", "person_pin": "4711"},
        headers=head,
    )
    assert a.status_code == 200, a.text
    assert a.json()["person"]["role_id"] == "adult" and a.json()["person"]["console"] is True
    assert a.json()["person"]["adult"] is False

    # The new way: any role, console on top — the admin keeps 18+.
    req = _join(client, "Neu")
    a = client.post(
        f"/household/joins/{req}/approve",
        json={"role": ab18, "console": True, "pin": "1234", "person_pin": "4711"},
        headers=head,
    )
    assert a.status_code == 200, a.text
    p = a.json()["person"]
    assert p["role_id"] == ab18 and p["console"] is True and p["adult"] is True
    assert "nightshift" in a.json()["portals"]

    # Console without the new person's PIN: refused, as for `admin`.
    req = _join(client, "OhnePin")
    a = client.post(
        f"/household/joins/{req}/approve",
        json={"role": ab18, "console": True, "pin": "1234"},
        headers=head,
    )
    assert a.status_code == 422 and a.json()["error"]["code"] == "join.admin_needs_pin"

    # Console without the approver's PIN: refused before anything else.
    a = client.post(
        f"/household/joins/{req}/approve",
        json={"role": ab18, "console": True, "person_pin": "4711"},
        headers=head,
    )
    assert a.status_code == 401

    # A role id that does not exist.
    a = client.post(f"/household/joins/{req}/approve", json={"role": "gibtsnicht"}, headers=head)
    assert a.status_code == 422 and a.json()["error"]["code"] == "household.unknown_role"
