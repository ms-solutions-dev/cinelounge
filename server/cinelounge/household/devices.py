"""Pairing devices — by a code on the screen or by an invitation link.

**Two ways, because they solve two different cases.**

The *pairing code* assumes two people are present at once: one at the device,
one at the console. For a television in the house that is right — you are
standing in front of it anyway.

The *invitation* solves the case the code does not: setting somebody up who is
not standing in front of the television right now. It is **not a permanent
personal link** — that would be a key in a URL, forwarded once and foreign
access forever, revocable only by issuing a new one. This one is exchanged for
a device token the first time it is opened and is spent afterwards.
"""

from __future__ import annotations

import sqlite3
import time
from dataclasses import dataclass
from typing import Final

from cinelounge.core import errors as f
from cinelounge.core.ids import device_token, invite_token, pairing_code
from cinelounge.household.people import OWN_DEVICES_SQL
from cinelounge.household.store import Store

PAIRING_TTL_S: Final = 5 * 60.0
INVITE_TTL_S: Final = 24 * 3600.0


def insert_device(
    v: sqlite3.Connection,
    *,
    person_id: str,
    name: str,
    kind: str,
    from_where: str,
    via_mark: str | None,
) -> tuple[str, str]:
    """Ein Gerät anlegen, das über eine Personenmarke kam (AP47).

    Gibt `(merkmal, geräte_id)` zurück. **In der Verbindung des Aufrufers**,
    weil `Joins` das Anlegen mit dem Vermerk an der Anfrage in einem Zug
    schreiben muss — sonst legen zwei gleichzeitige Nachfragen zwei Geräte an.

    Kein Umweg über `pending`: Dort gibt es nur Kopplung und Einladung, und
    eine dritte Sorte hieße die `CHECK`-Bedingung umbauen (Migration 2).

    `via_mark=None` heißt: über keine Marke — das Gerät eines Kindes, das per
    Freigabe hereinkam (Entscheidung 14). Kein Widerruf einer Marke nimmt es mit.
    """
    now = time.time()
    secret = device_token()
    ident = invite_token()
    v.execute(
        "INSERT INTO device (id, name, kind, person_id, token, paired, last_seen, "
        "from_where, via_mark) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (ident, name, kind, person_id, secret, now, now, from_where, via_mark),
    )
    return secret, ident


@dataclass(frozen=True, slots=True)
class Device:
    id: str
    name: str
    kind: str
    user_id: str | None
    """`None` heisst geteilt — ein Fernseher im Wohnzimmer gehoert niemandem."""
    last_seen: float
    from_where: str
    paired: float = 0.0
    #: Came in over the person's mark (the app's profile key) — such devices
    #: fall when the mark is renewed.
    via_mark: bool = False

    @property
    def shared(self) -> bool:
        return self.user_id is None


@dataclass(frozen=True, slots=True)
class Pending:
    """Eine wartende Kopplung oder eine ausgesprochene Einladung."""

    token: str
    kind: str
    user_id: str | None
    device_name: str
    device_kind: str
    from_where: str
    valid_until: float
    created: float = 0.0

    @property
    def remaining_s(self) -> float:
        return max(0.0, self.valid_until - time.time())

    @property
    def expired(self) -> bool:
        return self.valid_until < time.time()


class Devices:
    def __init__(self, store: Store) -> None:
        self.store = store

    # ── Pairing: the device announces itself and shows a code ───────────────

    def request_code(self, name: str, kind: str, from_where: str) -> Pending:
        token = pairing_code()
        now = time.time()
        with self.store.connect() as v:
            # **Expired entries go here, not only when somebody looks.**
            #
            # Until now the clean-up happened in `pending()` only — that is,
            # exactly when somebody opens the console. Whoever has set their
            # household up once does not do that for months, and every code,
            # every abandoned pairing attempt and every invitation issued sat
            # there as a row until then.
            #
            # Dangerous it never was — `redeem()` checks `valid_until` and
            # `used` and lets nothing dead through. It is the kind of residue
            # that piles up quietly and travels along into every backup (A6).
            #
            # The place is deliberate: whoever creates a new code is in the
            # middle of pairing a device — then it may cost one query more.
            # The hour of grace is the same as in `pending()`: a code that has
            # just expired should still be able to explain why it no longer
            # works.
            v.execute(
                "DELETE FROM pending WHERE valid_until < ? OR used IS NOT NULL", (now - 3600,)
            )
            v.execute(
                "INSERT INTO pending (token, kind, device_name, device_kind, from_where, "
                "created, valid_until) VALUES (?, 'pairing', ?, ?, ?, ?, ?)",
                (token, name, kind, from_where, now, now + PAIRING_TTL_S),
            )
        return Pending(token, "pairing", None, name, kind, from_where, now + PAIRING_TTL_S, now)

    # ── Invitation: the admin issues it, the link travels on ────────────────

    def invite(self, user_id: str, hours: float = 24.0) -> Pending:
        now = time.time()
        until = now + hours * 3600.0
        token = invite_token()
        with self.store.connect() as v:
            z = v.execute(
                f"SELECT {OWN_DEVICES_SQL} AS own FROM person WHERE id = ?", (user_id,)
            ).fetchone()
            if z is None:
                raise f.Error("household.unknown_person", {"id": user_id}, status=404)
            # **No invitation link for children's profiles.** A child's device
            # is paired by the admin at the device — otherwise the age lock is
            # a matter of prudence rather than a rule.
            if not z["own"]:
                raise f.Error("invite.not_for_children", {"id": user_id}, status=403)
            v.execute(
                "INSERT INTO pending (token, kind, person_id, created, valid_until) "
                "VALUES (?, 'invite', ?, ?, ?)",
                (token, user_id, now, until),
            )
        return Pending(token, "invite", user_id, "", "", "", until, now)

    # ── Redeeming ───────────────────────────────────────────────────────────

    def redeem(
        self,
        token: str,
        *,
        user_id: str | None = None,
        name: str = "",
        kind: str = "",
        from_where: str = "",
    ) -> str:
        """Exchange a token for a device token. Returns the device token.

        The token is **spent** afterwards — a second call comes up empty. With
        a pairing the admin says who the device belongs to (`user_id`, `None` =
        shared); with an invitation that is settled already.
        """
        now = time.time()
        # **Two different things, two names.** `token` is the code being
        # redeemed; `secret` is the long-lived token the device carries
        # afterwards. During the rename to English both were called `token`
        # for one round — the code was overwritten before the query read it,
        # and every pairing ran into "pairing.expired".
        secret = device_token()
        with self.store.connect() as v:
            z = v.execute("SELECT * FROM pending WHERE token = ?", (token,)).fetchone()
            if z is None:
                raise f.Error(f.PAIRING_EXPIRED, status=404)
            if z["used"] is not None:
                raise f.Error(f.INVITE_USED, status=410)
            if z["valid_until"] < now:
                raise f.Error(f.PAIRING_EXPIRED, status=410)

            # **Whoever is named explicitly wins; otherwise what was noted
            # applies.** This used to read `z["person_id"] if kind == "invite"
            # else user_id` — so with a pairing *only* the explicit `user_id`
            # counted, and `web/auth.py:redeem()` never passes one. The column
            # stayed unused for pairings, and the row of people in the console
            # was a row of buttons without effect.
            owner = user_id if user_id is not None else z["person_id"]
            v.execute(
                "INSERT INTO device (id, name, kind, person_id, token, paired, "
                "last_seen, from_where) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    token,
                    name or z["device_name"] or "Device",
                    kind or z["device_kind"],
                    owner,
                    secret,
                    now,
                    now,
                    from_where or z["from_where"],
                ),
            )
            v.execute("UPDATE pending SET used = ? WHERE token = ?", (now, token))
        return secret

    def note_person(self, token: str, user_id: str | None) -> bool:
        """Who the device should belong to once it redeems the code.

        **Noting, not assigning.** The device does not exist yet; what stands
        here is read by `redeem()` at redemption time. `None` means "shared" —
        the television in the living room belongs to nobody and asks at start.

        For pairings only: with an invitation the recipient is already settled,
        and changing them here would be a second route to the same thing.
        """
        if user_id is not None:
            with self.store.connect() as v:
                z = v.execute("SELECT id FROM person WHERE id = ?", (user_id,)).fetchone()
            if z is None:
                raise f.Error("household.unknown_person", {"id": user_id}, status=404)

        now = time.time()
        with self.store.connect() as v:
            return (
                v.execute(
                    "UPDATE pending SET person_id = ? WHERE token = ? AND kind = 'pairing' "
                    "AND used IS NULL AND valid_until >= ?",
                    (user_id, token, now),
                ).rowcount
                > 0
            )

    def revoke(self, token: str) -> bool:
        with self.store.connect() as v:
            return v.execute("DELETE FROM pending WHERE token = ?", (token,)).rowcount > 0

    # ── Bestand ──────────────────────────────────────────────────────────────

    def pending(self, include_expired: bool = False) -> list[Pending]:
        """What is currently in flight. Entries expired over an hour ago are
        cleared on the way.

        `include_expired` also returns those that ran out within that hour —
        the console shows them as "expired" instead of letting a code vanish
        while somebody is still reading it off the television.
        """
        now = time.time()
        with self.store.connect() as v:
            v.execute(
                "DELETE FROM pending WHERE valid_until < ? OR used IS NOT NULL", (now - 3600,)
            )
            rows = v.execute(
                "SELECT * FROM pending WHERE used IS NULL AND valid_until >= ? ORDER BY created",
                (now - 3600 if include_expired else now,),
            ).fetchall()
        return [
            Pending(
                z["token"],
                z["kind"],
                z["person_id"],
                z["device_name"],
                z["device_kind"],
                z["from_where"],
                z["valid_until"],
                z["created"] or 0.0,
            )
            for z in rows
        ]

    def list_all(self) -> list[Device]:
        with self.store.connect() as v:
            rows = v.execute("SELECT * FROM device ORDER BY paired").fetchall()
        return [
            Device(
                z["id"],
                z["name"],
                z["kind"],
                z["person_id"],
                z["last_seen"],
                z["from_where"],
                z["paired"] or 0.0,
                bool(z["via_mark"]),
            )
            for z in rows
        ]

    def browser_of(self, person_id: str, from_where: str) -> str | None:
        """The token of a browser that has been here before.

        **Why this query exists.** Every sign-in used to create a new device.
        Measured on 10 Sep 2026 in the running household: **40 rows**, nearly
        all of them "Browser" and "Console in the browser", the same machine,
        the same person. The list meant to show who has access was unreadable —
        and showing that is its only job.

        A browser is not a television: it is not paired, it signs in. If the
        same person comes back from the same address, it is the same device.

        **The address alone would not be enough**, which is why the person
        stands beside it: two people can sit behind one address, and their
        access must not be shared.
        """
        with self.store.connect() as v:
            z = v.execute(
                "SELECT token FROM device WHERE person_id = ? AND kind = 'web' "
                "AND from_where = ? ORDER BY last_seen DESC LIMIT 1",
                (person_id, from_where),
            ).fetchone()
            if z is None:
                return None
            v.execute("UPDATE device SET last_seen = ? WHERE token = ?", (time.time(), z["token"]))
        return str(z["token"])

    def by_token(self, token: str, from_where: str = "") -> Device | None:
        """The device behind a token — and it notes that the device was here.

        **And from where.** Until 12.09.2026 `from_where` was written once, at
        redeem time, and never again: the console showed the address a phone
        had while pairing, weeks later, as if it were current. A phone that
        moves from Wi-Fi to the tunnel keeps its token and changes its
        address — so the address follows every call, like `last_seen` does.
        An empty `from_where` (a test client, a call without a peer) leaves
        the stored one alone instead of blanking it.
        """
        with self.store.connect() as v:
            z = v.execute("SELECT * FROM device WHERE token = ?", (token,)).fetchone()
            if z is None:
                return None
            v.execute(
                "UPDATE device SET last_seen = ?, from_where = ? WHERE id = ?",
                (time.time(), from_where or z["from_where"], z["id"]),
            )
        return Device(
            z["id"],
            z["name"],
            z["kind"],
            z["person_id"],
            z["last_seen"],
            from_where or z["from_where"],
        )

    def revoke_device(self, device_id: str) -> bool:
        with self.store.connect() as v:
            return v.execute("DELETE FROM device WHERE id = ?", (device_id,)).rowcount > 0

    def rename(self, device_id: str, name: str) -> bool:
        """Give a device the name the household uses for it.

        What a device calls itself ("iPhone", "Apple TV 4K (3rd generation)")
        is a model, not a name — with two phones in the house the list reads
        "iPhone, iPhone". The name is the household's word for the device, so
        the household may change it; the device never sends one again after
        pairing anyway.
        """
        with self.store.connect() as v:
            return (
                v.execute("UPDATE device SET name = ? WHERE id = ?", (name, device_id)).rowcount > 0
            )

    def assign(self, device_id: str, user_id: str | None) -> None:
        """Change a device's person after the fact.

        Without it you would have to throw a device away and pair it again just
        because you picked the wrong name while pairing.
        """
        with self.store.connect() as v:
            v.execute("UPDATE device SET person_id = ? WHERE id = ?", (user_id, device_id))
