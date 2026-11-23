"""Old code against new code: does every person see every portal as before? (AP90)

Owner's condition (16.11.2026): the household's own roles must not see
anything differently after the access rework, except for what was changed on
purpose. This script is the evidence. It runs twice against a **copy** of the
real household — once with the old code on `PYTHONPATH`, once with the new —
and a third time to compare:

    PYTHONPATH=/old python scripts/access_parity.py observe household.sqlite portals old.json
    PYTHONPATH=/new python scripts/access_parity.py observe household.sqlite portals new.json
    python scripts/access_parity.py compare old.json new.json

`observe` copies the database into a temporary folder before anything opens
it, so the given file is never written. It goes through the HTTP routes with
`TestClient` — the same calls the apps make, so it works with any version of
the code. No portal code runs: the runner and the resolver answer with a stub,
because only the gate in front of them is compared, not what is behind it.
Telegram, the nightly run and the exit watch stay off.

What is observed per person: the portal list, menu/list/children/sources/
play per portal, every further route under `/p/{id}/` the running code has
(an extension's own, too — without parameters, a POST with an empty JSON
body, so only the gate in front of it decides), search across all and per
portal, continue watching,
favourites, `/state`, the nightly strips, the same through a borrowed profile,
and the console's view of every portal. Progress keys are hashed — the
output names portals and people by id, never what somebody watched.

`compare` sorts every difference into *same*, *wanted* or *error*. Wanted are
only: titles of a broken portal the person may see staying in continue
watching/favourites/`/state`, and `/household/nights` showing a non-console
person only their own portals. Exit code 1 when there is any error.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import sys
import tempfile
from pathlib import Path
from typing import Any

PROBE = ":ap90probe:"


def _h(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()[:16]


def _copy_db(src: Path, dst: Path) -> None:
    # `immutable=1`: the copy is a WAL file on a read-only mount, and without
    # it SQLite wants to create the `-shm` beside it.
    a = sqlite3.connect(f"file:{src}?mode=ro&immutable=1", uri=True)
    b = sqlite3.connect(dst)
    a.backup(b)
    a.close()
    b.close()


def _switch_rows(db: Path) -> dict[str, int]:
    v = sqlite3.connect(db)
    rows = {str(z[0]): int(z[1]) for z in v.execute("SELECT portal_id, on_air FROM portal_switch")}
    v.close()
    return rows


def observe(db: Path, portals: Path, out: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        boot = root / "boot"
        data = root / "data"
        boot.mkdir()
        data.mkdir()
        (data / "portals").symlink_to(portals.resolve())
        _copy_db(db, data / "household.sqlite")
        result = _observe(boot, data)
    out.write_text(json.dumps(result, indent=1, sort_keys=True), encoding="utf-8")
    import cinelounge

    print(f"code from {Path(cinelounge.__file__).parent}")
    print(f"observed {len(result['people'])} people × {len(result['portals'])} portals → {out}")


_PER_PORTAL = "/p/{portal_id}/"
_OBSERVED = {_PER_PORTAL + x for x in ("menu", "list", "children", "sources")}


def _further_routes(app: Any) -> list[tuple[str, str]]:
    """Method and path of every route under `/p/{portal_id}/` not observed by name.

    Read from the app, not listed here: whatever the running code (and the
    extensions it loaded) answers is compared, under the same key in both runs.
    """
    from fastapi.routing import APIRoute

    return sorted(
        (method, r.path)
        for r in app.routes
        if isinstance(r, APIRoute) and r.path.startswith(_PER_PORTAL) and r.path not in _OBSERVED
        for method in r.methods - {"HEAD", "OPTIONS"}
    )


def _observe(boot: Path, data: Path) -> dict[str, Any]:
    os.environ["CL_DATA"] = str(boot)

    # Side effects off before `web.main` is imported: no Telegram message, no
    # nightly run, no exit watch, no buffer sweeper.
    from cinelounge.portalworks import playback
    from cinelounge.portalworks.runner import call as runner
    from cinelounge.stream import buffer
    from cinelounge.web import exitwatch, nightwatch, telegram

    telegram.install = lambda *a, **k: None
    nightwatch.start = lambda *a, **k: None
    exitwatch.start = lambda *a, **k: None
    buffer.start_sweeper = lambda *a, **k: None

    def call(m, method, args=None, limits=None, optional=False):
        if method == "menu":
            return [{"id": "x", "name": "x"}]
        if method == "listing":
            return {"items": [{"title": "probe", "address": "x"}]}
        if method == "series":
            return ""
        return [{"title": "probe", "address": "x"}]

    runner.call = call
    playback.sources = lambda m, a, t="", limits=None: [{"id": "s"}]
    playback.prepare = lambda *a, **k: None
    playback.resolve_play = lambda m, **k: {
        "address": "http://192.0.2.9/v",
        "source": "s",
        "kind": "file",
    }

    from fastapi.testclient import TestClient

    from cinelounge.household.devices import Devices
    from cinelounge.web import main
    from cinelounge.web.access import Services

    switches_before = _switch_rows(data / "household.sqlite")
    d = Services.from_path(data)
    switches_after = _switch_rows(data / "household.sqlite")
    # Started twice, as after a restart: a migration must not move again.
    Services.from_path(data)
    switches_again = _switch_rows(data / "household.sqlite")
    main.app.state.services = d
    client = TestClient(main.app)

    people = d.people.list_all()
    manifests = list(d.registry.manifests.values())
    dev = Devices(d.store)
    tokens: dict[str, str] = {}
    for p in people:
        o = dev.request_code("ap90-probe", "probe", "192.0.2.1")
        tokens[p.id] = dev.redeem(o.token, user_id=p.id)
    o = dev.request_code("ap90-shared", "probe", "192.0.2.2")
    shared = dev.redeem(o.token, user_id=None)

    def get(head: dict[str, str], path: str, **params: Any) -> Any:
        return client.get(path, headers=head, params=params)

    further = _further_routes(main.app)

    def status(a: Any) -> str:
        if a.status_code < 300:
            return str(a.status_code)
        try:
            return f"{a.status_code} {a.json()['error']['code']}"
        except Exception:
            return str(a.status_code)

    result: dict[str, Any] = {
        "portals": {
            m.id: {"adult": m.adult, "ready": m.is_ready, "default": m.on_by_default}
            for m in manifests
        },
        "people": {},
        "switches": {"before": switches_before, "after": switches_after, "again": switches_again},
    }
    console_head = next(({"X-CL-Device": tokens[p.id]} for p in people if p.console), None)
    if console_head is not None:
        admin = get(console_head, "/household/portals").json()["portals"]
        result["admin_view"] = {
            x["id"]: {
                "on": x["on"],
                "roles": sorted(x["roles"]),
                "allowed_for": sorted(x["allowed_for"]),
                "who": {pid: e["reason"] for pid, e in (x.get("who") or {}).items()},
            }
            for x in admin
        }

    for p in people:
        head = {"X-CL-Device": tokens[p.id]}
        for m in manifests:
            client.post(
                "/state",
                headers=head,
                json={
                    "key": m.id + PROBE,
                    "portal": m.id,
                    "position_s": 900,
                    "duration_s": 3000,
                    "favorite": True,
                },
            )
        per: dict[str, Any] = {
            "role": p.role_id,
            "console": p.console,
            "adult": p.adult,
            "list": sorted(x["id"] for x in get(head, "/portals").json()["portals"]),
        }
        routes: dict[str, dict[str, str]] = {}
        for m in manifests:
            routes[m.id] = {
                "menu": status(get(head, f"/p/{m.id}/menu")),
                "list": status(get(head, f"/p/{m.id}/list", entry="x")),
                "children": status(get(head, f"/p/{m.id}/children", address="x")),
                "sources": status(get(head, f"/p/{m.id}/sources", address="x")),
                "play": status(get(head, "/play", portal=m.id, address="x")),
                "state": status(get(head, "/state", key=m.id + PROBE)),
            }
            for method, path in further:
                at = re.sub(r"\{[^}]+\}", "x", path.replace("{portal_id}", m.id))
                if method == "GET":
                    a = client.get(at, headers=head)
                else:
                    a = client.request(method, at, headers=head, json={})
                routes[m.id][f"{method} {path.removeprefix(_PER_PORTAL)}"] = status(a)
            s = get(head, "/search", q="x", portal=m.id).json()
            routes[m.id]["search_one"] = (
                "hit"
                if m.id in s.get("hits", {})
                else ("failed " + s["failed"][m.id] if m.id in s.get("failed", {}) else "-")
            )
        per["routes"] = routes
        s = get(head, "/search", q="x").json()
        per["search"] = {"hits": sorted(s.get("hits", {})), "failed": s.get("failed", {})}
        per["resume"] = sorted(
            [x.get("portal") or x["key"].split(":")[0], _h(x["key"])]
            for x in get(head, "/resume", limit=100000).json()["resumable"]
        )
        per["favorites"] = sorted(
            [x.get("portal") or x["key"].split(":")[0], _h(x["key"])]
            for x in get(head, "/favorites", limit=100000).json()["favorites"]
        )
        n = get(head, "/household/nights")
        per["nights"] = sorted(n.json().get("history", {})) if n.status_code == 200 else status(n)
        borrowed = {"X-CL-Device": shared, "X-CL-Profile": p.id}
        per["borrowed"] = {
            "list": sorted(x["id"] for x in get(borrowed, "/portals").json()["portals"]),
            "resume": sorted(
                x.get("portal") or x["key"].split(":")[0]
                for x in get(borrowed, "/resume", limit=100000).json()["resumable"]
            ),
            "menu": {m.id: status(get(borrowed, f"/p/{m.id}/menu")) for m in manifests},
        }
        nb = get(borrowed, "/household/nights")
        per["borrowed"]["nights"] = (
            sorted(nb.json().get("history", {})) if nb.status_code == 200 else status(nb)
        )
        result["people"][p.id] = per
    return result


# ── compare ─────────────────────────────────────────────────────────────────


def _person(
    op: dict[str, Any], np_: dict[str, Any], broken: set[str], permitted: set[str]
) -> tuple[int, int, list[str], list[str]]:
    """One person, old against new: counts and the labels of what differs."""
    same = wanted = 0
    bad: list[str] = []
    why: list[str] = []

    def check(label: str, a: Any, b: Any, ok_if: Any = None) -> None:
        nonlocal same, wanted
        if a == b:
            same += 1
        elif ok_if is not None and ok_if(a, b):
            wanted += 1
            why.append(label)
        else:
            bad.append(f"{label}: {a} → {b}")

    def kept_at_fault(a: list, b: list) -> bool:
        extra = {tuple(x) for x in b} - {tuple(x) for x in a}
        gone = {tuple(x) for x in a} - {tuple(x) for x in b}
        return not gone and all(x[0] in broken and x[0] in permitted for x in extra)

    check("list", op["list"], np_["list"])
    check("search", op["search"], np_["search"])
    for pid, r in op["routes"].items():
        for k, v in r.items():
            nv = np_["routes"].get(pid, {}).get(k)
            if k == "state":
                check(
                    f"{pid}.state",
                    v,
                    nv,
                    lambda a, b, pid=pid: (
                        a.startswith("404") and b == "200" and pid in broken and pid in permitted
                    ),
                )
            else:
                check(f"{pid}.{k}", v, nv)
    check("resume", op["resume"], np_["resume"], kept_at_fault)
    check("favorites", op["favorites"], np_["favorites"], kept_at_fault)

    def own_nights(a: Any, b: Any, op: dict = op) -> bool:
        if op["console"] or not isinstance(a, list) or not isinstance(b, list):
            return False
        return set(b) == {x for x in a if x in permitted}

    check("nights", op["nights"], np_["nights"], own_nights)
    ob, nb = op["borrowed"], np_["borrowed"]
    check("borrowed.list", ob["list"], nb["list"])
    check(
        "borrowed.resume",
        ob["resume"],
        nb["resume"],
        lambda a, b: not (set(a) - set(b)) and set(b) - set(a) <= broken & permitted,
    )
    for pid, v in ob["menu"].items():
        check(f"borrowed.{pid}.menu", v, nb["menu"].get(pid))
    check(
        "borrowed.nights",
        ob["nights"],
        nb["nights"],
        lambda a, b: (
            isinstance(a, list)
            and isinstance(b, list)
            and set(b) == {x for x in a if x in permitted}
        ),
    )
    return same, wanted, why, bad


def compare(old_path: Path, new_path: Path) -> int:
    old = json.loads(old_path.read_text(encoding="utf-8"))
    new = json.loads(new_path.read_text(encoding="utf-8"))
    portals = new["portals"]
    broken = {pid for pid, x in portals.items() if not x["ready"]}
    who = {pid: x.get("who", {}) for pid, x in new.get("admin_view", {}).items()}
    errors: list[str] = []

    # The migration: rows only added, each with the value the fallback gave,
    # nothing moved on the second start.
    sw = new["switches"]
    for pid, on in sw["after"].items():
        if pid in sw["before"]:
            if sw["before"][pid] != on:
                errors.append(f"switch {pid}: stored row changed {sw['before'][pid]} → {on}")
        elif on != int(portals[pid]["default"]):
            errors.append(f"switch {pid}: pinned {on}, default was {portals[pid]['default']}")
    if sw["again"] != sw["after"]:
        errors.append("switch rows moved on the second start")
    pinned = sorted(set(sw["after"]) - set(sw["before"]))

    for pid, ov in old.get("admin_view", {}).items():
        nv = new.get("admin_view", {}).get(pid)
        if nv is None:
            errors.append(f"console view: {pid} missing")
            continue
        for k in ("on", "roles", "allowed_for"):
            if ov[k] != nv[k]:
                errors.append(f"console view {pid}.{k}: {ov[k]} → {nv[k]}")

    table: list[tuple[str, str, int, int, int]] = []
    wanted_by: dict[str, list[str]] = {}
    for person, op in old["people"].items():
        np_ = new["people"].get(person)
        if np_ is None:
            errors.append(f"{person}: missing in new")
            continue
        permitted = {pid for pid, w in who.items() if w.get(person) in ("ok", "broken")}
        same, wanted, why, bad = _person(op, np_, broken, permitted)
        table.append(
            (
                person,
                str(op["role"]) + (" +console" if op["console"] else ""),
                same,
                wanted,
                len(bad),
            )
        )
        errors.extend(f"{person}: {x}" for x in bad)
        wanted_by[person] = why

    print(f"portals: {len(portals)} ({len(broken)} not ready: {', '.join(sorted(broken)) or '-'})")
    print(f"switch rows pinned by the migration: {', '.join(pinned) or 'none'}")
    print()
    print(f"{'person':<14} {'role':<20} {'same':>6} {'wanted':>7} {'error':>6}")
    for row in table:
        print(f"{row[0]:<14} {row[1]:<20} {row[2]:>6} {row[3]:>7} {row[4]:>6}")
    print()
    for person, labels in wanted_by.items():
        if labels:
            print(f"wanted for {person}: {', '.join(labels)}")
    print()
    if errors:
        print("ERRORS:")
        for e in errors:
            print("  " + e)
        return 1
    print("no error: old and new agree except for the wanted changes")
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "observe":
        observe(Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]))
    elif len(sys.argv) == 4 and sys.argv[1] == "compare":
        sys.exit(compare(Path(sys.argv[2]), Path(sys.argv[3])))
    else:
        print(__doc__)
        sys.exit(2)
