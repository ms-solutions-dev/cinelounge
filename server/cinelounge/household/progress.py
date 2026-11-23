"""Position, watched flag, favourites — per person.

**The difference from the old bridge is one column:** `person_id`. Over there
a single progress record serves the whole household, and "continue watching"
shows everybody what somebody else started last.

**And the value comes from the device token, never from a parameter.**
Otherwise any device could overwrite any person's progress — so the caller does
not say *whose* progress it means; the sign-in decides that.
"""

from __future__ import annotations

import time
from collections.abc import Collection
from typing import Any

from cinelounge.household.store import Store

# From where an episode counts as watched. No closing credits run to the last
# second, and nobody should be offered an episode again when all they skipped
# was the credits.
DONE_AT = 0.95

# Below this nothing was started — somebody merely looked in briefly.
STARTED_AFTER_S = 30.0


def _hinaus(z: Any) -> dict[str, Any]:
    duration = float(z["duration_s"] or 0)
    pos = float(z["position_s"] or 0)
    fraction = (pos / duration) if duration > 0 else 0.0
    return {
        "key": z["key"],
        "portal": z["portal_id"],
        "title": z["title"],
        "year": z["year"],
        "address": z["address"],
        "kind": z["kind"],
        "image": z["image"] or None,
        "language": z["language"] or None,
        "series": z["series"] or None,
        "position_s": pos,
        "duration_s": duration,
        # `None` rather than `0`: "never started" and "at second zero" are two
        # different things, and the app only draws the bar when there is a
        # number.
        "fraction": round(fraction, 4) if duration > 0 else None,
        "remaining_s": round(duration - pos) if duration > 0 else None,
        "watched": bool(z["watched"]),
        "favorite": bool(z["favorite"]),
        "changed": z["changed"],
    }


class Progress:
    def __init__(self, store: Store) -> None:
        self.store = store

    def report(
        self,
        user_id: str,
        key: str,
        *,
        portal: str = "",
        title: str = "",
        year: int | None = None,
        address: str = "",
        kind: str = "",
        image: str = "",
        language: str | None = None,
        series: str = "",
        position_s: float | None = None,
        duration_s: float | None = None,
        watched: bool | None = None,
        favorite: bool | None = None,
    ) -> dict[str, Any]:
        """Whatever is not sent along stays as it is.

        The Apple TV reports only its position every ten seconds, and a call
        that reset the favourite flag while doing so would be a trap.
        """
        now = time.time()
        with self.store.connect() as v:
            v.execute(
                "INSERT OR IGNORE INTO progress (person_id, key, changed) VALUES (?, ?, ?)",
                (user_id, key, now),
            )
            fields: list[str] = []
            values: list[Any] = []
            for name, value in (
                ("portal_id", portal or None),
                ("title", title or None),
                ("year", year),
                ("address", address or None),
                ("kind", kind or None),
                ("image", image or None),
                ("language", language),
                ("series", series or None),
                ("position_s", position_s),
                ("duration_s", duration_s),
                ("watched", None if watched is None else int(watched)),
                ("favorite", None if favorite is None else int(favorite)),
            ):
                if value is not None:
                    fields.append(name + " = ?")
                    values.append(value)

            # Die Gesehen-Marke setzt sich selbst, wenn niemand sie mitschickt.
            if (
                watched is None
                and position_s is not None
                and duration_s
                and position_s / duration_s >= DONE_AT
            ):
                fields.append("watched = 1")

            fields.append("changed = ?")
            values.extend([now, user_id, key])
            v.execute(
                "UPDATE progress SET " + ", ".join(fields) + " WHERE person_id = ? AND key = ?",
                values,
            )
            z = v.execute(
                "SELECT * FROM progress WHERE person_id = ? AND key = ?",
                (user_id, key),
            ).fetchone()
        return _hinaus(z)

    def by_id(
        self, user_id: str, key: str, portals: Collection[str] | None = None
    ) -> dict[str, Any] | None:
        """One entry; with `portals` only if it comes from one of them (same rule
        as `resumable`, so a hidden portal does not leak through a direct key)."""
        teil, werte = _nur_aus(portals)
        with self.store.connect() as v:
            z = v.execute(
                "SELECT * FROM progress WHERE person_id = ? AND key = ? " + teil,
                (user_id, key, *werte),
            ).fetchone()
        return _hinaus(z) if z else None

    def for_many(self, user_id: str, key: list[str]) -> dict[str, dict[str, Any]]:
        """The progress of many items in **one** query.

        One query per poster would be 277 queries for 277 items — and that is
        noticeable on the television.
        """
        if not key:
            return {}
        tokens = ",".join("?" * len(key))
        with self.store.connect() as v:
            rows = v.execute(
                "SELECT * FROM progress WHERE person_id = ? AND key IN (" + tokens + ")",
                [user_id, *key],
            ).fetchall()
        return {str(z["key"]): _hinaus(z) for z in rows}

    def forget(self, user_id: str, key: str) -> bool:
        with self.store.connect() as v:
            return (
                v.execute(
                    "DELETE FROM progress WHERE person_id = ? AND key = ?",
                    (user_id, key),
                ).rowcount
                > 0
            )

    def favorites(
        self, user_id: str, limit: int = 200, portals: Collection[str] | None = None
    ) -> list[dict[str, Any]]:
        """Favoriten — neueste zuerst; mit `portals` nur die aus diesen Portalen."""
        teil, werte = _nur_aus(portals)
        with self.store.connect() as v:
            rows = v.execute(
                "SELECT * FROM progress WHERE person_id = ? AND favorite = 1 "
                + teil
                + "ORDER BY changed DESC LIMIT ?",
                (user_id, *werte, limit),
            ).fetchall()
        return [_hinaus(z) for z in rows]

    def resumable(
        self, user_id: str, limit: int = 50, portals: Collection[str] | None = None
    ) -> list[dict[str, Any]]:
        """Angefangen und nicht zu Ende geschaut — neueste zuerst; mit `portals` nur
        die aus diesen Portalen."""
        teil, werte = _nur_aus(portals)
        with self.store.connect() as v:
            rows = v.execute(
                "SELECT * FROM progress WHERE person_id = ? AND watched = 0 "
                "AND position_s > ? AND duration_s > 0 " + teil + "ORDER BY changed DESC LIMIT ?",
                (user_id, STARTED_AFTER_S, *werte, limit),
            ).fetchall()
        return [_hinaus(z) for z in rows]

    def numbers(self, user_id: str) -> dict[str, int]:
        with self.store.connect() as v:
            z = v.execute(
                "SELECT COUNT(*) AS n, SUM(favorite) AS f, SUM(watched) AS g "
                "FROM progress WHERE person_id = ?",
                (user_id,),
            ).fetchone()
        return {"entries": z["n"] or 0, "favorites": z["f"] or 0, "watched": z["g"] or 0}


def _nur_aus(portals: Collection[str] | None) -> tuple[str, list[str]]:
    """Die Bedingung "nur aus diesen Portalen" — im SQL, damit `LIMIT` danach zählt.

    **Das Portal steht nicht in jeder Zeile.** Ältere Meldungen tragen kein
    `portal_id`; ihr Schlüssel beginnt aber immer mit dem Portal (`core.ids.key`:
    `portal:titel:jahr`). Eine Zeile, aus der sich kein Portal lesen lässt, fällt
    heraus: Wer nicht sagen kann, woher ein Titel stammt, kann auch nicht sagen, dass
    er gezeigt werden darf.
    """
    if portals is None:
        return "", []
    ids = sorted(set(portals))
    if not ids:
        return "AND 0 ", []
    platz = ", ".join("?" for _ in ids)
    return (
        "AND COALESCE(NULLIF(portal_id, ''), CASE WHEN instr(key, ':') > 0 "
        f"THEN substr(key, 1, instr(key, ':') - 1) END) IN ({platz}) ",
        ids,
    )
