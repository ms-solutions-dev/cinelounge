"""Roles as data: what somebody sees in the app (09.11.2026).

**Two kinds of rights, kept apart on purpose.** A *role* holds the app rights
(`APP_RIGHTS`) and the portals its people see. Running the console is not part
of any role — it hangs on the person (`person.console`), with a PIN of its own.
The owner's words: the role is what somebody sees, the console is who manages.

**Rights stay a fixed list in the code; roles are free.** A right the server
does not know, it cannot enforce. Whoever wants a new right writes code; whoever
wants a new role clicks one together in the console.

**`adult` and `child` are only the seeds.** They keep those ids so an app that
still sends the old role names keeps working, but they can be renamed, changed
and — once nobody holds them — deleted like any other role.
"""

from __future__ import annotations

import re
import time
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Final

from cinelounge.core import errors as f
from cinelounge.core.ids import normalized
from cinelounge.household.store import Store

#: What a role can grant. Order is the order the console shows them in.
APP_RIGHTS: Final = ("watch", "track_progress", "view_adult", "own_devices", "invite")

#: What only a person with console access holds. Never part of a role.
CONSOLE_RIGHTS: Final = frozenset(
    {
        "switch_portals",
        "change_access",
        "install_portals",
        "pair_devices",
        "change_settings",
        "workshop",
    }
)

_COLOR: Final = re.compile(r"^#[0-9a-fA-F]{6}$")

#: Role ids that mean something else to older clients (`people.resolve_role`).
RESERVED_IDS: Final = frozenset({"admin"})

#: Setting key: the manifest defaults were handed to the roles once.
DEFAULTS_ADOPTED: Final = "roles_defaults_adopted"


@dataclass(frozen=True, slots=True)
class Role:
    id: str
    name: str
    color: str
    rights: frozenset[str]
    portals: frozenset[str]
    position: int
    #: "For children": `view_adult` and 18+ portals are refused (migration 12).
    child_lock: bool = False

    def as_json(self, members: int = 0) -> dict[str, object]:
        return {
            "id": self.id,
            "name": self.name,
            "color": self.color,
            "rights": [r for r in APP_RIGHTS if r in self.rights],
            "portals": sorted(self.portals),
            "members": members,
            "child_lock": self.child_lock,
        }


def _parse_rights(raw: str) -> frozenset[str]:
    return frozenset(r for r in raw.split(",") if r in APP_RIGHTS)


def _validate(name: str | None, color: str | None, rights: Iterable[str] | None) -> None:
    if name is not None and not 1 <= len(name.strip()) <= 30:
        raise f.Error("role.bad_name", {"max": 30}, status=422)
    if color is not None and not _COLOR.match(color):
        raise f.Error("role.bad_color", status=422)
    if rights is not None:
        unknown = sorted(set(rights) - set(APP_RIGHTS))
        if unknown:
            # **Refuse, do not swallow.** A console that tries to put
            # `pair_devices` into a role should learn it failed — otherwise it
            # believes it granted it.
            raise f.Error("role.unknown_right", {"rights": unknown}, status=422)


#: Puts roles back in order after a restore from a backup older than roles:
#: seeds the two roles if none came along, and derives `role_id`/`console` from
#: the old `role` for every person without them — the same rule as migration 11.
REPAIR_SQL: Final = """
    INSERT OR IGNORE INTO role (id, name, color, rights, position, created)
        SELECT 'adult', 'Adult', '#6aa8ff',
               'watch,track_progress,view_adult,own_devices,invite', 0, strftime('%s', 'now')
        WHERE NOT EXISTS (SELECT 1 FROM role);
    INSERT OR IGNORE INTO role (id, name, color, rights, position, created, child_lock)
        SELECT 'child', 'Child', '#6fcf8e', 'watch,track_progress', 1, strftime('%s', 'now'), 1
        WHERE (SELECT COUNT(*) FROM role) = 1 AND EXISTS (SELECT 1 FROM role WHERE id = 'adult')
          AND NOT EXISTS (SELECT 1 FROM role WHERE id = 'child');
    UPDATE person SET
        console = CASE role WHEN 'admin' THEN 1 ELSE console END,
        role_id = CASE role WHEN 'child' THEN 'child' ELSE 'adult' END
        WHERE role_id IS NULL OR role_id NOT IN (SELECT id FROM role);
"""


class Roles:
    """The household's roles."""

    def __init__(self, store: Store) -> None:
        self.store = store

    # ── Reading ────────────────────────────────────────────────────────────────

    def list_all(self) -> list[Role]:
        with self.store.connect() as v:
            rows = v.execute("SELECT * FROM role ORDER BY position, created").fetchall()
            portals = v.execute("SELECT role_id, portal_id FROM role_portal").fetchall()
        per_role: dict[str, set[str]] = {}
        for z in portals:
            per_role.setdefault(z["role_id"], set()).add(z["portal_id"])
        return [
            Role(
                z["id"],
                z["name"],
                z["color"],
                _parse_rights(z["rights"]),
                frozenset(per_role.get(z["id"], ())),
                z["position"],
                bool(z["child_lock"]),
            )
            for z in rows
        ]

    def by_id(self, ident: str) -> Role | None:
        return next((r for r in self.list_all() if r.id == ident), None)

    def members(self) -> dict[str, int]:
        with self.store.connect() as v:
            return {
                z["role_id"]: z["n"]
                for z in v.execute("SELECT role_id, COUNT(*) AS n FROM person GROUP BY role_id")
            }

    def portals_of(self, role_id: str | None) -> frozenset[str]:
        if role_id is None:
            return frozenset()
        with self.store.connect() as v:
            return frozenset(
                z["portal_id"]
                for z in v.execute(
                    "SELECT portal_id FROM role_portal WHERE role_id = ?", (role_id,)
                )
            )

    # ── Writing ────────────────────────────────────────────────────────────

    def create(
        self,
        name: str,
        color: str,
        rights: Iterable[str],
        portals: Iterable[str] = (),
        child_lock: bool = False,
    ) -> Role:
        rights = list(rights)
        if child_lock:
            # A role for children starts without "ab 18", however it was asked for.
            rights = [r for r in rights if r != "view_adult"]
        _validate(name, color, rights)
        name = name.strip()
        base = normalized(name)[:24] or "role"
        if base in RESERVED_IDS:
            # `admin` is the old role name the app still sends (= adult plus
            # console). A role with that id would be read as that alias: a
            # person moved into "Admin" stayed in "Adult" (found on the
            # household copy, 09.11.2026). Such a role gets `admin-role`.
            base = f"{base}-role"
        with self.store.connect(immediate=True) as v:
            ident, n = base, 2
            while v.execute("SELECT 1 FROM role WHERE id = ?", (ident,)).fetchone():
                ident, n = f"{base}-{n}", n + 1
            pos = v.execute("SELECT COALESCE(MAX(position), -1) + 1 AS p FROM role").fetchone()["p"]
            v.execute(
                "INSERT INTO role (id, name, color, rights, position, created, child_lock) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    ident,
                    name,
                    color,
                    ",".join(sorted(set(rights))),
                    pos,
                    time.time(),
                    int(child_lock),
                ),
            )
            v.executemany(
                "INSERT OR IGNORE INTO role_portal (role_id, portal_id) VALUES (?, ?)",
                [(ident, p) for p in set(portals)],
            )
        role = self.by_id(ident)
        assert role is not None
        return role

    def update(
        self,
        ident: str,
        *,
        name: str | None = None,
        color: str | None = None,
        rights: Iterable[str] | None = None,
        portals: Iterable[str] | None = None,
    ) -> Role:
        """Change what was sent — and only that.

        `portals` replaces the whole list; `set_portal` switches a single one.
        Having both costs nothing and spares the console twelve calls for a
        new role.
        """
        rights = None if rights is None else list(rights)
        _validate(name, color, rights)
        with self.store.connect() as v:
            z = v.execute("SELECT child_lock FROM role WHERE id = ?", (ident,)).fetchone()
            if z is None:
                raise f.Error("role.unknown", {"id": ident}, status=404)
            if rights is not None and "view_adult" in rights and z["child_lock"]:
                # **Refused, not dropped:** a console that asks for "ab 18" on a
                # locked role must learn that it did not get it.
                raise f.Error("role.child_locked", {"id": ident}, status=409)
            if name is not None:
                v.execute("UPDATE role SET name = ? WHERE id = ?", (name.strip(), ident))
            if color is not None:
                v.execute("UPDATE role SET color = ? WHERE id = ?", (color, ident))
            if rights is not None:
                v.execute(
                    "UPDATE role SET rights = ? WHERE id = ?",
                    (",".join(sorted(set(rights))), ident),
                )
            if portals is not None:
                v.execute("DELETE FROM role_portal WHERE role_id = ?", (ident,))
                v.executemany(
                    "INSERT INTO role_portal (role_id, portal_id) VALUES (?, ?)",
                    [(ident, p) for p in set(portals)],
                )
        if rights is not None:
            self.sync_legacy()
        role = self.by_id(ident)
        assert role is not None
        return role

    def set_portal(self, ident: str, portal_id: str, on: bool) -> None:
        with self.store.connect() as v:
            if v.execute("SELECT 1 FROM role WHERE id = ?", (ident,)).fetchone() is None:
                raise f.Error("role.unknown", {"id": ident}, status=404)
            if on:
                v.execute(
                    "INSERT OR IGNORE INTO role_portal (role_id, portal_id) VALUES (?, ?)",
                    (ident, portal_id),
                )
            else:
                v.execute(
                    "DELETE FROM role_portal WHERE role_id = ? AND portal_id = ?",
                    (ident, portal_id),
                )

    def set_child_lock(self, ident: str, on: bool, adult_portals: Iterable[str] = ()) -> Role:
        """Lock or unlock a role for children.

        Locking also takes "ab 18" and every 18+ portal out of the role, so a
        locked role is clean at once and not only from now on. Who may unlock
        (PIN) is the route's business.
        """
        with self.store.connect() as v:
            z = v.execute("SELECT rights FROM role WHERE id = ?", (ident,)).fetchone()
            if z is None:
                raise f.Error("role.unknown", {"id": ident}, status=404)
            if on:
                kept = [r for r in str(z["rights"]).split(",") if r and r != "view_adult"]
                v.execute(
                    "UPDATE role SET child_lock = 1, rights = ? WHERE id = ?",
                    (",".join(sorted(kept)), ident),
                )
                v.executemany(
                    "DELETE FROM role_portal WHERE role_id = ? AND portal_id = ?",
                    [(ident, p) for p in set(adult_portals)],
                )
            else:
                v.execute("UPDATE role SET child_lock = 0 WHERE id = ?", (ident,))
        self.sync_legacy()
        role = self.by_id(ident)
        assert role is not None
        return role

    def prune_locked(self, adult_portals: Iterable[str]) -> None:
        """Take 18+ portals out of every locked role. Runs at start, when the
        manifests are known (an old list could still carry one)."""
        adult = sorted(set(adult_portals))
        if not adult:
            return
        with self.store.connect() as v:
            v.execute(
                "DELETE FROM role_portal WHERE portal_id IN ("
                + ",".join("?" * len(adult))
                + ") AND role_id IN (SELECT id FROM role WHERE child_lock = 1)",
                adult,
            )

    def delete(self, ident: str) -> None:
        """Delete a role — only once nobody holds it.

        **No silent reassignment.** Deleting a role with people in it would mean
        deciding where those people go; the person at the console decides that,
        not this call. And the last role stays: without one there would be
        nothing left to hand out at the door.
        """
        with self.store.connect() as v:
            if v.execute("SELECT 1 FROM role WHERE id = ?", (ident,)).fetchone() is None:
                raise f.Error("role.unknown", {"id": ident}, status=404)
            n = v.execute(
                "SELECT COUNT(*) AS n FROM person WHERE role_id = ?", (ident,)
            ).fetchone()["n"]
            if n:
                raise f.Error("role.in_use", {"id": ident, "members": n}, status=409)
            if v.execute("SELECT COUNT(*) AS n FROM role").fetchone()["n"] <= 1:
                raise f.Error("role.last_role", {"id": ident}, status=409)
            v.execute("DELETE FROM role WHERE id = ?", (ident,))

    def forget_portal(self, portal_id: str) -> None:
        """Take a removed portal out of every role."""
        with self.store.connect() as v:
            v.execute("DELETE FROM role_portal WHERE portal_id = ?", (portal_id,))

    # ── One-off adoption and keeping in step ─────────────────────────────────────

    def adopt_defaults(self, on_by_default: Iterable[str], switched: set[str]) -> None:
        """Hand what is on only by the manifest's default to the roles, once.

        The migration only sees `portal_switch`. A portal that is on by default
        and was never switched was visible to the admin before — without this
        step it would vanish from their view after the change.
        """
        if self.store.read(DEFAULTS_ADOPTED):
            return
        new = [p for p in on_by_default if p not in switched]
        # `adult` always; `child` only while nobody holds it — a real child's
        # list came from their own permissions and must not grow by itself.
        targets = ["adult"] + (["child"] if not self.members().get("child") else [])
        with self.store.connect() as v:
            for role_id in targets:
                if v.execute("SELECT 1 FROM role WHERE id = ?", (role_id,)).fetchone():
                    v.executemany(
                        "INSERT OR IGNORE INTO role_portal (role_id, portal_id) VALUES (?, ?)",
                        [(role_id, p) for p in new],
                    )
        self.store.write(DEFAULTS_ADOPTED, "1")

    def sync_legacy(self) -> None:
        """Bring `person.role` in step with `console` and the role's rights.

        The app still reads `role` (mark check, approval). Derived: console →
        `admin`, a role with `view_adult` → `adult`, otherwise `child`.
        """
        with self.store.connect() as v:
            v.execute(
                """
                UPDATE person SET role = CASE
                    WHEN console = 1 THEN 'admin'
                    WHEN (SELECT ',' || rights || ',' FROM role WHERE role.id = person.role_id)
                         LIKE '%,view_adult,%' THEN 'adult'
                    ELSE 'child' END
                """
            )
