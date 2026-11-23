"""One decision about who sees which portal — and why (AP90, 16.11.2026).

**Until then the rule stood in four copies.** `web/main.py`, `web/portals.py`
and twice in `web/admin.py` each combined the switch, the role and the age
lock themselves, in different orders, and only two of them looked at
readiness. The console rebuilt the rule a fifth time in TypeScript and got it
wrong for broken portals. Every route now asks `Access.check` and nothing
else; a test walks all routes of the app and turns red when one goes past it.

**The order is fixed and it decides which reason is named:**

1. ``adult``   — an 18+ portal and a person without "ab 18"
2. ``off``     — the household's switch is off
3. ``no_role`` — the person's role does not list the portal
4. ``broken``  — the portal is not ready (no exit, empty required field, …)

Readiness comes last so that a child never reads the failure reason of an 18+
portal, and the age lock comes first so that it holds even for a role that
lists an 18+ portal by mistake.

**A decision, not a bool.** The console shows *why* somebody does not see a
portal; with a bool it had to guess.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from typing import Final

from cinelounge.household.people import Person
from cinelounge.household.roles import Role
from cinelounge.household.store import Store
from cinelounge.portalworks.manifest import Manifest

OK: Final = "ok"
ADULT: Final = "adult"
OFF: Final = "off"
NO_ROLE: Final = "no_role"
BROKEN: Final = "broken"

#: The order of the checks — the first that fails is the reason.
ORDER: Final = (ADULT, OFF, NO_ROLE, BROKEN)


@dataclass(frozen=True, slots=True)
class Decision:
    """Whether a person sees a portal, and the first reason against it."""

    allowed: bool
    reason: str
    #: The broken reason, or the role that does not list the portal.
    detail: str | None = None

    @property
    def permitted(self) -> bool:
        """The household's rules allow it; only the technology is in the way.

        What a person started in a broken portal stays in "continue watching"
        (owner, 16.11.2026): the fault is reported when playing, not by
        letting the title vanish.
        """
        return self.reason in (OK, BROKEN)

    def as_json(self) -> dict[str, object]:
        return {"allowed": self.allowed, "reason": self.reason, "detail": self.detail}


class Access:
    """The one place that decides. Reads `portal_switch` and `role_portal`."""

    def __init__(self, store: Store) -> None:
        self.store = store

    # ── The tables, once per question ───────────────────────────────────────

    def _switches(self) -> dict[str, bool]:
        with self.store.connect() as v:
            return {
                str(z["portal_id"]): bool(z["on_air"])
                for z in v.execute("SELECT portal_id, on_air FROM portal_switch")
            }

    def _listed(self, person: Person) -> set[str]:
        """The portals of the person's role, read by the person's id.

        By id and not by `person.role_id`, as `Visibility.allowed_for` did: a
        person object held across a role change must not see the old list.
        """
        with self.store.connect() as v:
            return {
                str(z["portal_id"])
                for z in v.execute(
                    "SELECT rp.portal_id FROM role_portal AS rp "
                    "JOIN person AS p ON p.role_id = rp.role_id WHERE p.id = ?",
                    (person.id,),
                )
            }

    @staticmethod
    def _decide(
        person: Person, m: Manifest, switches: dict[str, bool], listed: set[str]
    ) -> Decision:
        if m.adult and not person.adult:
            return Decision(False, ADULT)
        # Without a row the manifest's default still counts. Since AP90 the
        # default is written down at start (`Visibility.pin_defaults`), so this
        # only covers a portal that appeared between two reloads.
        if not switches.get(m.id, m.on_by_default):
            return Decision(False, OFF)
        if m.id not in listed:
            return Decision(False, NO_ROLE, person.role_id)
        if not m.is_ready:
            return Decision(False, BROKEN, m.broken_reason)
        return Decision(True, OK)

    # ── The questions ───────────────────────────────────────────────────────

    def check(self, person: Person, m: Manifest) -> Decision:
        return self._decide(person, m, self._switches(), self._listed(person))

    def decide_all(self, person: Person, manifests: Iterable[Manifest]) -> dict[str, Decision]:
        """One decision per portal, with two queries in total."""
        switches, listed = self._switches(), self._listed(person)
        return {m.id: self._decide(person, m, switches, listed) for m in manifests}

    def visible(self, person: Person, manifests: Iterable[Manifest]) -> list[Manifest]:
        """What this person sees — the portal list, search, every content route."""
        ms = list(manifests)
        d = self.decide_all(person, ms)
        return [m for m in ms if d[m.id].allowed]

    def permitted(self, person: Person, manifests: Iterable[Manifest]) -> list[Manifest]:
        """What the rules allow, broken or not — continue watching, favourites."""
        ms = list(manifests)
        d = self.decide_all(person, ms)
        return [m for m in ms if d[m.id].permitted]

    def for_everyone(
        self, people: Iterable[Person], manifests: Iterable[Manifest]
    ) -> dict[str, dict[str, Decision]]:
        """Portal → person → decision, for the console's "who sees it"."""
        ms = list(manifests)
        out: dict[str, dict[str, Decision]] = {m.id: {} for m in ms}
        for p in people:
            for pid, dec in self.decide_all(p, ms).items():
                out[pid][p.id] = dec
        return out

    def for_roles(
        self, roles: Iterable[Role], manifests: Iterable[Manifest]
    ) -> dict[str, dict[str, Decision]]:
        """Portal → role → decision: what a member of the role would get.

        For the role page, which has to answer for a role nobody holds yet. A
        stand-in person with the role's rights and list goes through the same
        `_decide` — the console never rebuilds the rule.
        """
        ms = list(manifests)
        switches = self._switches()
        out: dict[str, dict[str, Decision]] = {m.id: {} for m in ms}
        for r in roles:
            stand_in = Person("", r.name, r.id, r.color, rights=r.rights)
            for m in ms:
                out[m.id][r.id] = self._decide(stand_in, m, switches, set(r.portals))
        return out
