"""People, roles, PINs — and the rule about who may do what.

**The rule lives here and not in the interface.** Hiding is not locking: if a
child's device queries an adult portal directly, the answer has to be a 403 and
not the listing. The usability pass on the phone app found exactly this mistake
once before — the parental lock claimed to block what it did not block.
"""

from __future__ import annotations

import sqlite3
import time
from dataclasses import dataclass
from typing import Final, Literal

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

from cinelounge.core import errors as f
from cinelounge.core.ids import normalized
from cinelounge.household.roles import APP_RIGHTS, CONSOLE_RIGHTS, Roles
from cinelounge.household.store import Store

#: The old role names. The app still sends and reads them; inside, a role is
#: data (`household/roles.py`) and console access is a flag on the person.
Role = Literal["admin", "adult", "child"]

_HASHER: Final = PasswordHasher()

# How often a PIN may be wrong before a minute's pause kicks in.
#
# **A four-digit PIN without a limit is not a PIN.** Ten thousand
# possibilities are tried in seconds; only the lockout turns the short number
# into protection. Five, then a minute — long enough to make guessing
# pointless, short enough that a typo does not cost the evening.
ATTEMPTS: Final = 5
LOCKOUT_S: Final = 60.0

#: Every right the server knows: what a role can grant, plus what only console
#: access grants. A right that is not listed here belongs to nobody.
RIGHTS: Final = frozenset(APP_RIGHTS) | CONSOLE_RIGHTS

#: The columns every read of a person needs, with the rights of their role.
PERSON_COLUMNS: Final = (
    "p.id, p.name, p.role_id, p.color, p.console, COALESCE(r.rights, '') AS rights"
)
#: The tables behind `PERSON_COLUMNS`.
PERSON_FROM: Final = "FROM person AS p LEFT JOIN role AS r ON r.id = p.role_id"
#: SQL over `PERSON_FROM`: does the person's role hold `own_devices`?
OWN_DEVICES_JOINED: Final = "(',' || COALESCE(r.rights, '') || ',') LIKE '%,own_devices,%'"


@dataclass(frozen=True, slots=True)
class Person:
    id: str
    name: str
    role_id: str | None
    color: str
    console: bool = False
    rights: frozenset[str] = frozenset()

    @property
    def role(self) -> Role:
        """The old name, derived — what the app still reads."""
        if self.console:
            return "admin"
        return "adult" if "view_adult" in self.rights else "child"

    @property
    def adult(self) -> bool:
        return "view_adult" in self.rights

    def may(self, right: str) -> bool:
        """Whether this person holds the right.

        Console rights come from console access, app rights from the role. An
        **unknown** right is `False` and not a `KeyError`: a typo at the call
        site should block, not let through.
        """
        if right in CONSOLE_RIGHTS:
            return self.console
        return right in self.rights


#: SQL: does the person's role hold `own_devices`? For queries on `person`.
OWN_DEVICES_SQL: Final = (
    "(',' || COALESCE((SELECT rights FROM role WHERE role.id = person.role_id), '') || ',')"
    " LIKE '%,own_devices,%'"
)


def person_from(z: sqlite3.Row) -> Person:
    return Person(
        z["id"],
        z["name"],
        z["role_id"],
        z["color"],
        bool(z["console"]),
        frozenset(r for r in str(z["rights"]).split(",") if r in APP_RIGHTS),
    )


def resolve_role(role: str) -> tuple[str, bool]:
    """An old role name or a role id → (role id, console).

    `admin` was both: everything to see and the console. It becomes the adult
    role plus console access.
    """
    if role == "admin":
        return "adult", True
    return role, False


def _pruefe_pin(pin: str) -> None:
    if not pin.isdigit() or not 4 <= len(pin) <= 8:
        raise f.Error("auth.pin_format", {"min": 4, "max": 8}, status=422)


class People:
    """Der Bestand an Menschen im Haushalt."""

    def __init__(self, store: Store) -> None:
        self.store = store
        # Failed attempts per person. In memory rather than in the file: a
        # restart lifts the lockout, and rightly so — it is meant to make
        # guessing expensive, not to lock somebody out.
        self._fehl: dict[str, tuple[int, float]] = {}

    # ── Anlegen ──────────────────────────────────────────────────────────────

    def create(
        self,
        name: str,
        role: str,
        pin: str | None,
        color: str = "#E2564A",
        console: bool | None = None,
    ) -> Person:
        """Eine Person anlegen.

        `pin=None` heißt **ohne PIN** — nur für den Beitritt (AP47, Entscheidung
        8.1 a): Der Weg dieser Person ist die Personenmarke, und eine zweite PIN
        neben der Profil-PIN der App gäbe es sonst für denselben Menschen. Ein
        leerer String bleibt ein Formfehler; „keine PIN“ muss man ausdrücklich
        sagen.
        """
        if pin is not None:
            _pruefe_pin(pin)
        role_id, from_name = resolve_role(role)
        console = from_name if console is None else console
        if console and pin is None:
            # Whoever may run the console needs a PIN — otherwise they could
            # never sign in (decision 15).
            raise f.Error("household.console_needs_pin", status=422)
        ident = normalized(name)[:24] or "person"
        with self.store.connect() as v:
            if v.execute("SELECT 1 FROM role WHERE id = ?", (role_id,)).fetchone() is None:
                raise f.Error("household.unknown_role", {"role": role}, status=422)
            if v.execute("SELECT 1 FROM person WHERE id = ?", (ident,)).fetchone():
                raise f.Error("household.person_exists", {"name": name}, status=409)
            v.execute(
                "INSERT INTO person (id, name, role, role_id, console, pin_hash, color, created) "
                "VALUES (?, ?, 'child', ?, ?, ?, ?, ?)",
                (
                    ident,
                    name,
                    role_id,
                    int(console),
                    "" if pin is None else _HASHER.hash(pin),
                    color,
                    time.time(),
                ),
            )
        Roles(self.store).sync_legacy()
        p = self.by_id(ident)
        assert p is not None
        return p

    # ── Lesen ────────────────────────────────────────────────────────────────

    def list_all(self) -> list[Person]:
        with self.store.connect() as v:
            rows = v.execute(f"SELECT {PERSON_COLUMNS} {PERSON_FROM} ORDER BY p.created").fetchall()
        return [person_from(z) for z in rows]

    def by_id(self, ident: str) -> Person | None:
        with self.store.connect() as v:
            z = v.execute(
                f"SELECT {PERSON_COLUMNS} {PERSON_FROM} WHERE p.id = ?", (ident,)
            ).fetchone()
        return person_from(z) if z else None

    def is_empty(self) -> bool:
        """Whether nobody is here at all yet — the first run hangs on this."""
        with self.store.connect() as v:
            wie_viele: int = v.execute("SELECT COUNT(*) AS n FROM person").fetchone()["n"]
            return wie_viele == 0

    # ── Anmelden ─────────────────────────────────────────────────────────────

    def sign_in(self, ident: str, pin: str) -> Person:
        """Check the PIN and return the person — or raise.

        **The lockout applies before the check.** Otherwise every attempt costs
        the full argon2 computation, and that is exactly the lever an attacker
        looks for: they do not need to guess right, keeping the service busy is
        enough.
        """
        remaining, until = self._fehl.get(ident, (ATTEMPTS, 0.0))
        if remaining <= 0 and time.time() < until:
            raise f.Error(f.AUTH_LOCKED_OUT, {"seconds": round(until - time.time())}, status=429)

        with self.store.connect() as v:
            z = v.execute(
                f"SELECT {PERSON_COLUMNS}, p.pin_hash {PERSON_FROM} WHERE p.id = ?",
                (ident,),
            ).fetchone()

        # **The same answer for "does not exist" and "wrong PIN".** Otherwise
        # the service tells everyone who tries which accounts exist.
        if z is None:
            self._danebengegriffen(ident)
            raise f.Error(f.AUTH_BAD_CREDENTIALS, status=401)
        # **Eine Person ohne PIN meldet sich nie mit PIN an** — sie kam über
        # `/join` herein, ihr Ausweis ist die Personenmarke. Ohne diese Zeile
        # prüfte argon2 gegen einen leeren Abdruck, würfe `InvalidHash`, und
        # aus einer falschen Anmeldung würde eine 500. Dieselbe Antwort wie
        # „falsche PIN“, damit niemand erfährt, wer eine PIN hat.
        if not z["pin_hash"]:
            self._danebengegriffen(ident)
            raise f.Error(f.AUTH_BAD_CREDENTIALS, status=401)
        try:
            _HASHER.verify(z["pin_hash"], pin)
        except VerifyMismatchError:
            self._danebengegriffen(ident)
            raise f.Error(f.AUTH_BAD_CREDENTIALS, status=401) from None

        self._fehl.pop(ident, None)
        return person_from(z)

    def _danebengegriffen(self, ident: str) -> None:
        remaining, _ = self._fehl.get(ident, (ATTEMPTS, 0.0))
        remaining -= 1
        self._fehl[ident] = (remaining, time.time() + LOCKOUT_S if remaining <= 0 else 0.0)

    def remove(self, ident: str) -> None:
        """Take a person out of the household — with everything attached.

        **What goes along is written in the schema, not here.** `progress`,
        `visibility`, `device` and `pending` reference `person` with `ON DELETE
        CASCADE`, so those rows go too. That is intended: progress without a
        person would be a record nobody can attribute, and a device that
        belonged to somebody deleted would afterwards have no owner and still
        have access.

        **Two rules, and both are lockout protection.** Nobody removes
        themselves — whoever did would be outside in the same breath and could
        only get back in through the container log. And the last admin stays: a
        household without an admin can no longer be managed, and recovering
        would mean a hand inside the database.
        """
        with self.store.connect() as v:
            z = v.execute("SELECT console FROM person WHERE id = ?", (ident,)).fetchone()
            if z is None:
                raise f.Error("household.unknown_person", {"id": ident}, status=404)
            if z["console"]:
                others = v.execute(
                    "SELECT COUNT(*) AS n FROM person WHERE console = 1 AND id != ?",
                    (ident,),
                ).fetchone()["n"]
                if others == 0:
                    raise f.Error("household.last_admin", {"id": ident}, status=409)
            v.execute("DELETE FROM person WHERE id = ?", (ident,))
            # **The event book keeps the act, not the name.**
            # What somebody did in the household belongs to the history of the
            # house; who it was belongs to the person, and that person is gone.
            # Done explicitly here rather than through a foreign key — the
            # reasoning is with migration 3 in `store.py`.
            v.execute("UPDATE event SET person_id = NULL WHERE person_id = ?", (ident,))
        self._fehl.pop(ident, None)

    def set_pin(self, ident: str, pin: str) -> None:
        _pruefe_pin(pin)
        with self.store.connect() as v:
            v.execute(
                "UPDATE person SET pin_hash = ? WHERE id = ?",
                (_HASHER.hash(pin), ident),
            )
        self._fehl.pop(ident, None)

    def set_role(self, ident: str, role: str) -> Person:
        """Give a person another role — because somebody turned eighteen.

        **`role` is a role id**, or one of the old names. The old `admin` keeps
        meaning what it meant: the adult role plus console access. Any other
        value leaves console access alone — the role is what somebody sees,
        not whether they manage.

        **Until 19.09.2026 the only way was: remove and create anew.** That
        cost the progress, the favourites and every paired device, for a
        change that is one word in one row.
        """
        role_id, console = resolve_role(role)
        with self.store.connect() as v:
            z = v.execute("SELECT 1 FROM person WHERE id = ?", (ident,)).fetchone()
            if z is None:
                raise f.Error("household.unknown_person", {"id": ident}, status=404)
            if v.execute("SELECT 1 FROM role WHERE id = ?", (role_id,)).fetchone() is None:
                raise f.Error("household.unknown_role", {"role": role}, status=422)
            v.execute("UPDATE person SET role_id = ? WHERE id = ?", (role_id, ident))
        if console:
            self.set_console(ident, True)
        Roles(self.store).sync_legacy()
        p = self.by_id(ident)
        assert p is not None
        return p

    def set_console(self, ident: str, on: bool, pin: str | None = None) -> Person:
        """Console access on or off — a flag on the person, not on the role.

        **Granting needs a PIN** when the person has none yet: without one they
        could never sign in. **Taking it away from the last one is refused** —
        a household nobody can manage is only recoverable inside the database.
        """
        if pin is not None:
            _pruefe_pin(pin)
        with self.store.connect() as v:
            z = v.execute("SELECT pin_hash, console FROM person WHERE id = ?", (ident,)).fetchone()
            if z is None:
                raise f.Error("household.unknown_person", {"id": ident}, status=404)
            if on:
                if not z["pin_hash"] and pin is None:
                    raise f.Error("household.console_needs_pin", status=422)
                if pin is not None:
                    v.execute(
                        "UPDATE person SET pin_hash = ? WHERE id = ?", (_HASHER.hash(pin), ident)
                    )
                v.execute("UPDATE person SET console = 1 WHERE id = ?", (ident,))
            elif z["console"]:
                others = v.execute(
                    "SELECT COUNT(*) AS n FROM person WHERE console = 1 AND id != ?", (ident,)
                ).fetchone()["n"]
                if others == 0:
                    raise f.Error("household.last_admin", {"id": ident}, status=409)
                v.execute("UPDATE person SET console = 0 WHERE id = ?", (ident,))
        Roles(self.store).sync_legacy()
        self._fehl.pop(ident, None)
        p = self.by_id(ident)
        assert p is not None
        return p
