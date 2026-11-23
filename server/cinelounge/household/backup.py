"""The whole household as **one** file — and back again.

**Why this is needed.** The design has had the button from the start, and there
it reports "backup created · 81 catalogue entries, 3 people, 3 devices". None
of that ever happened: the text sits in `entwuerfe/entwurf.js`, a backend never
existed. A button that fakes success is worse than no button — whoever believes
it restores nothing when it matters and only then finds out there is nothing
there.

**What is in it and what is not.** Six of the seven tables; `pending` stays
out, because a pairing code lives five minutes and a backup containing one only
brings it back as a corpse.

The portal folders are not in it either. They belong to the marketplace (B6)
and are pinned there by `sha256` — a version you restore by fetching it again
has no business in a backup. What does come here now that B6 stands are the
**sources** and the **trust anchors**: the record of *where* the portals came
from. The place for them is already laid out.

**This file is a master key.**

It contains `person.pin_hash`, every device token and every stored portal
secret. That is deliberate: a backup after which everybody has to pair again
and set every PIN anew is half a backup — and half a backup does not get used
when it matters. Whoever stores it stores access to the household.

**A version instead of guesswork.** `version: 1` sits at the top, and
`restore()` refuses what it does not know — the same rule as with the manifest.
A schema rebuild has hit this project twice already; a backup that quietly
restores the wrong thing would be the most expensive way to notice.
"""

from __future__ import annotations

import time
from typing import Any, Final

from cinelounge.core import errors as f
from cinelounge.household.roles import REPAIR_SQL, Roles
from cinelounge.household.store import Store

#: The version of this file format.
#:
#: It goes up when the **meaning** of a column changes. A column that is merely
#: added needs no new version: `restore()` writes only what it knows, and what
#: is missing stays at the table's default.
VERSION: Final = 1

#: What gets backed up, in the order it has to be restored in.
#:
#: `person` first: `device`, `visibility` and `progress` point at it through
#: `person_id`, and SQLite checks that (`ON DELETE CASCADE`). An order that is
#: only accidentally right breaks at the first household where somebody created
#: their person last.
# `role` and `role_portal` since 09.11.2026 — before `person`, which points at `role`.
TABELLEN: Final = (
    "role",
    "role_portal",
    "person",
    "device",
    "portal_switch",
    "visibility",
    "progress",
    "setting",
)

#: What does **not** come along.
#:
#: `pending` holds pairing codes (300 s) and invitations (24 h). Whatever of
#: that survives a backup has always expired — and an expired code that stands
#: in the list again after a restore looks like an open one.
NICHT_SICHERN: Final = ("pending",)


def export(store: Store) -> dict[str, Any]:
    """The household as a dictionary — ready for `json.dump`."""
    daten: dict[str, list[dict[str, Any]]] = {}
    with store.connect() as v:
        for name in TABELLEN:
            rows = v.execute(f"SELECT * FROM {name}").fetchall()  # fixed list
            daten[name] = [dict(z) for z in rows]

    return {
        "version": VERSION,
        "created": time.time(),
        # What `restore()` does not need, but a human holding the file does,
        # when they want to know whether it is the right one.
        "summary": {name: len(rows) for name, rows in daten.items()},
        # **The place for B6.** Marketplace sources and trust anchors come
        # here as soon as they exist. Empty and named beats absent: whoever
        # reads the backup sees what is still missing.
        "sources": [],
        "trust_anchors": [],
        "tables": daten,
    }


def restore(store: Store, daten: dict[str, Any], *, replace: bool = True) -> dict[str, int]:
    """Restore a backup. Returns how many rows were written per table.

    **`replace=True` clears first**, and that is the default: a backup
    establishes a state, it does not blend into one. Two households laid over
    each other produce permissions nobody ever granted.

    All of it in **one** transaction: if it breaks halfway, nothing is written.
    A half-restored household would be worse than the broken one before it —
    because it looks intact.
    """
    fassung = daten.get("version")
    if fassung != VERSION:
        raise f.Error(
            "backup.version",
            {"found": fassung, "expected": VERSION},
            status=422,
        )
    tabellen = daten.get("tables")
    if not isinstance(tabellen, dict):
        raise f.Error("backup.malformed", {"why": "tables"}, status=422)

    geschrieben: dict[str, int] = {}
    with store.connect() as v:
        if replace:
            # Backwards: children first, then parents.
            for name in reversed(TABELLEN):
                v.execute(f"DELETE FROM {name}")  # fixed list

        for name in TABELLEN:
            rows = tabellen.get(name) or []
            if not isinstance(rows, list):
                raise f.Error("backup.malformed", {"why": name}, status=422)

            bekannt = {z[1] for z in v.execute(f"PRAGMA table_info({name})")}
            n = 0
            for z in rows:
                if not isinstance(z, dict):
                    raise f.Error("backup.malformed", {"why": name}, status=422)
                # **Known columns only.** A backup from a newer build may
                # land here as long as the version number matches — what this
                # server does not know it leaves alone, rather than aborting on
                # a `no such column`.
                felder = [s for s in z if s in bekannt]
                if not felder:
                    continue
                marken = ", ".join("?" * len(felder))
                v.execute(
                    f"INSERT OR REPLACE INTO {name} ({', '.join(felder)}) VALUES ({marken})",
                    tuple(z[s] for s in felder),
                )
                n += 1
            geschrieben[name] = n
        # A backup from before roles has no `role` rows and no `role_id`:
        # put that straight in the same transaction (`roles.REPAIR_SQL`).
        for satz in REPAIR_SQL.split(";"):
            if satz.strip():
                v.execute(satz)
        # A backup from before the child lock (09.11.2026) carries roles without
        # it. Restoring must not quietly unlock the child role.
        rollen = daten.get("tables", {}).get("role") or []
        if rollen and not any("child_lock" in z for z in rollen):
            v.execute(
                "UPDATE role SET child_lock = 1 WHERE id = 'child' "
                "AND ',' || rights || ',' NOT LIKE '%,view_adult,%'"
            )
    Roles(store).sync_legacy()

    return geschrieben
