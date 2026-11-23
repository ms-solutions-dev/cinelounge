"""Compare who sees which portal before and after the move to roles (migration 11).

Runs on a **copy** — the given database is never opened for writing. Prints,
per person, every portal whose visibility would change, and exits with 1 if
anything changes at all. Owner's condition (09.11.2026): Sina's view must stay
exactly as it is, and no child may gain anything — this is the check for it,
run against the real household before the rebuild is deployed.

    python scripts/check_role_migration.py /path/to/household.sqlite /path/to/portals

"Before" is the old rule: switched on (or on by default) and (admin, or a row
in `visibility`), plus the age lock. "After" is what the server computes once
the copy is migrated, exactly as at start-up (`Services.from_path`).
"""

from __future__ import annotations

import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

from cinelounge.household.people import People
from cinelounge.household.roles import Roles
from cinelounge.household.store import Store
from cinelounge.household.zugang import Access
from cinelounge.portalworks.registry import Registry


def _before(db: Path, manifests: dict) -> dict[str, set[str]]:
    v = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    v.row_factory = sqlite3.Row
    switch = {z["portal_id"]: bool(z["on_air"]) for z in v.execute("SELECT * FROM portal_switch")}
    rows: dict[str, set[str]] = {}
    for z in v.execute("SELECT person_id, portal_id FROM visibility"):
        rows.setdefault(z["person_id"], set()).add(z["portal_id"])
    seen: dict[str, set[str]] = {}
    for p in v.execute("SELECT id, role FROM person"):
        adult = p["role"] in ("admin", "adult")
        seen[p["id"]] = {
            m.id
            for m in manifests.values()
            if switch.get(m.id, m.on_by_default)
            and (p["role"] == "admin" or m.id in rows.get(p["id"], set()))
            and (adult or not m.adult)
        }
    v.close()
    return seen


def _after(db: Path, portals: Path) -> tuple[dict[str, set[str]], dict[str, str]]:
    store = Store(db)  # migrates the copy
    registry = Registry(portals, overrides=store.portal_settings)
    roles = Roles(store)
    with store.connect() as v:
        switched = {z["portal_id"] for z in v.execute("SELECT portal_id FROM portal_switch")}
    roles.adopt_defaults([m.id for m in registry.manifests.values() if m.on_by_default], switched)
    roles.sync_legacy()
    access = Access(store)
    seen, role_of = {}, {}
    for p in People(store).list_all():
        role_of[p.id] = f"{p.role_id}{' +console' if p.console else ''}"
        # Readiness aside, as this check always counted (AP90: `permitted`).
        seen[p.id] = {m.id for m in access.permitted(p, registry.manifests.values())}
    return seen, role_of


def main(db: Path, portals: Path) -> int:
    manifests = Registry(portals).manifests
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / "household.sqlite"
        src = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        dst = sqlite3.connect(copy)
        src.backup(dst)
        src.close()
        dst.close()
        before = _before(copy, manifests)
        ro = sqlite3.connect(f"file:{copy}?mode=ro", uri=True)
        grown_ups = {
            z[0] for z in ro.execute("SELECT id FROM person WHERE role IN ('admin', 'adult')")
        }
        ro.close()
        after, role_of = _after(copy, portals)
        shutil.rmtree(tmp, ignore_errors=True)

    changed, child_gains = 0, 0
    for pid in sorted(before):
        gained, lost = after.get(pid, set()) - before[pid], before[pid] - after.get(pid, set())
        mark = "OK  " if not (gained or lost) else "DIFF"
        print(f"{mark} {pid:<12} {role_of.get(pid, '?'):<18} sees {len(after.get(pid, set()))}")
        if gained:
            print(f"     + gains: {', '.join(sorted(gained))}")
            if pid not in grown_ups:
                print("     !!! a child would see more than before — do not deploy")
                child_gains += 1
        if lost:
            print(f"     - loses: {', '.join(sorted(lost))}")
        changed += bool(gained or lost)
    print("identical for everybody" if not changed else f"{changed} person(s) change")
    # 2: a child gains something — a hard stop. 1: something else changes —
    # look at it and decide. 0: nothing changes for anybody.
    return 2 if child_gains else 1 if changed else 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1]), Path(sys.argv[2])))
