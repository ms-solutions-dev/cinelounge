"""Who may see which portal.

**Why this lives here and not in portalworks.** The first attempt had
`Registry.for_person(person, …)` — and the layer contract rejected it on the
spot:

    cinelounge.portalworks is not allowed to import cinelounge.household
    - cinelounge.portalworks.registry -> cinelounge.household.people (l.13)

Rightly so. `portalworks` knows what a portal **looks like** — manifest,
capabilities, limits. Who is **allowed to see it** is a question of the
household and changes when somebody moves in or turns eighteen. Two things,
two places.

Without the contract this would have surfaced a year from now, on the day
somebody wanted to test `portalworks` on its own and dragged half the
application along.
"""

from __future__ import annotations

from collections.abc import Iterable

from cinelounge.core import errors as f
from cinelounge.household.store import Store


class Visibility:
    """The household's switch and the per-person permissions.

    **Two dimensions, and they are independent.** "Goes out to the devices"
    holds for the whole household; "is permitted" holds per person. A portal
    only becomes visible when both are true — and a user who cannot tell the
    two apart looks for the fault in the wrong place.
    """

    def __init__(self, store: Store) -> None:
        self.store = store

    # ── The household's switch ──────────────────────────────────────────────

    def is_on(self, portal_id: str, fallback: bool = False) -> bool:
        with self.store.connect() as v:
            z = v.execute(
                "SELECT on_air FROM portal_switch WHERE portal_id = ?", (portal_id,)
            ).fetchone()
        return bool(z["on_air"]) if z is not None else fallback

    def set_on(self, portal_id: str, on: bool) -> None:
        """The switch beats the manifest's default.

        Otherwise a portal somebody deliberately switched off would come back
        after every update.
        """
        with self.store.connect() as v:
            v.execute(
                "INSERT INTO portal_switch (portal_id, on_air) VALUES (?, ?) "
                "ON CONFLICT(portal_id) DO UPDATE SET on_air = excluded.on_air",
                (portal_id, int(on)),
            )

    # ── Permissions — since 09.11.2026 per role, not per person ─────────────

    def allowed_for(self, user_id: str) -> set[str]:
        """The portals of this person's **role**.

        Until 09.11.2026 this read one row per person and portal. Now a role
        carries the list (`household/roles.py`); the old table `visibility`
        stays for the way back and is no longer read.
        """
        with self.store.connect() as v:
            return {
                str(z["portal_id"])
                for z in v.execute(
                    "SELECT rp.portal_id FROM role_portal AS rp "
                    "JOIN person AS p ON p.role_id = rp.role_id WHERE p.id = ?",
                    (user_id,),
                )
            }

    def set_allowed(self, user_id: str, portal_id: str, allowed: bool) -> None:
        """Compatibility: switch the portal **in this person's role**.

        Per-person exceptions no longer exist (09.11.2026). The old console and
        older callers still say "for Sina"; they get what that means now —
        the portal for everyone holding Sina's role. The new console talks to
        `/household/roles` directly.
        """
        with self.store.connect() as v:
            z = v.execute("SELECT role_id FROM person WHERE id = ?", (user_id,)).fetchone()
            if z is None or z["role_id"] is None:
                raise f.Error("household.unknown_person", {"id": user_id}, status=404)
            if allowed:
                v.execute(
                    "INSERT OR IGNORE INTO role_portal (role_id, portal_id) VALUES (?, ?)",
                    (z["role_id"], portal_id),
                )
            else:
                v.execute(
                    "DELETE FROM role_portal WHERE role_id = ? AND portal_id = ?",
                    (z["role_id"], portal_id),
                )

    # ── The manifest's default, written down once (AP90) ───────────────────

    def pin_defaults(self, defaults: Iterable[tuple[str, bool]]) -> list[str]:
        """Give every portal without a switch row the value it has today.

        **Until AP90 there were two sources for "on".** Without a row in
        `portal_switch` the manifest's `enabled:` counted, so a portal nobody
        ever touched could go on or off by itself with an update of its
        manifest. From now on the switch is the only source: the row carries
        exactly the value the fallback gave, so nothing visible changes.

        Idempotent — `INSERT OR IGNORE` never touches a row that is there.
        Returns the portals that got a row, for the event book. The way back
        is deleting those rows.
        """
        rows = [(pid, int(on)) for pid, on in defaults]
        if not rows:
            return []
        with self.store.connect(immediate=True) as v:
            have = {str(z["portal_id"]) for z in v.execute("SELECT portal_id FROM portal_switch")}
            new = [(pid, on) for pid, on in rows if pid not in have]
            v.executemany(
                "INSERT OR IGNORE INTO portal_switch (portal_id, on_air) VALUES (?, ?)", new
            )
        return sorted(pid for pid, _ in new)
