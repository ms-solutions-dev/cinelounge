"""The nightly run — what every portal did on every night.

**Curation without a curator.** A marketplace without a central directory has
no committee vetting portals. What it can have instead is a measurement: a
portal that has played nothing for three nights says so itself.

## What lives here and what does not

This module **keeps the book**. It checks nothing — `portalworks.nightly` does
that, and it does so in a child process, because foreign code runs there. The
split is the same as everywhere: `household` knows about the household,
`portalworks` about portals, and between them sits a layer that calls both.

## Three values, not two

`ok` is `1`, `0` or `None` — **carried, failed, did not run at all**. The third
is not hair-splitting: a portal that was switched off has not failed. A strip
that paints both the same makes a pause look like a fault, and whoever goes
looking then looks in the wrong place.

## What the nightly run does **not** do

**It switches nothing off.** That would be the obvious consequence and the
wrong one: a broadcaster's library that waits out one night would be gone by
morning, and the operator would go looking for the switch instead of the
cause. The same stance as in `market/install.py` — no auto-update there, no
auto-disable here. What it does is report: after three failed nights in a row
one entry in the event book, and the console shows the strip.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Final

from cinelounge.household.store import Store

#: How many nights the strip shows.
#:
#: Fourteen, because the console draws fourteen marks and two weeks is the span
#: in which a pattern becomes visible: "every Friday" stands out, "once a
#: quarter" no longer does.
NIGHTS: Final = 14

#: When a portal counts as persistently failing.
#:
#: Three nights in a row. One is an outage, two is bad luck, three is a
#: condition — and only then is a notification worth pulling somebody out of
#: their evening for.
FAILED_IN_A_ROW: Final = 3

#: How long the entries stay.
#:
#: Twice as long as the strip. Anything older answers no question anybody still
#: asks, and it travels along in every backup.
KEEP_NIGHTS: Final = 28


@dataclass(frozen=True, slots=True)
class Night:
    """What one portal did on one night."""

    portal_id: str
    night: str
    """The date as `2026-09-12` — not a timestamp.

    A run that starts at 03:58 and ends at 04:07 belongs to **one** night; two
    runs in the same night are meant to replace each other rather than stand
    side by side.
    """
    ok: bool | None
    step: str
    """How far it got: `menu`, `listing`, `sources`, `resolve`."""
    reason: str
    ms: int | None
    ran: float


def tonight(when: float | None = None) -> str:
    """Which night a point in time belongs to.

    **The day begins at noon, not at midnight.** A run at 03:00 belongs to the
    previous night — otherwise "last night" would mean something different
    depending on the hour, and a strip with two entries for the same evening
    would be the result.
    """
    t = datetime.fromtimestamp(when if when is not None else time.time(), tz=UTC)
    return (t - timedelta(hours=12)).strftime("%Y-%m-%d")


class Nights:
    """The book of nightly runs."""

    def __init__(self, store: Store) -> None:
        self.store = store

    def record(
        self,
        portal_id: str,
        ok: bool | None,
        *,
        step: str = "",
        reason: str = "",
        ms: int | None = None,
        when: float | None = None,
    ) -> None:
        """Record one result. **Never raises.**

        As with the event book: a nightly run that fails at bookkeeping has
        measured all the same, and the measurement matters more than its entry.
        """
        now = when if when is not None else time.time()
        try:
            with self.store.connect() as v:
                v.execute(
                    "INSERT INTO night (portal_id, night, ok, step, reason, ms, ran) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?) "
                    "ON CONFLICT(portal_id, night) DO UPDATE SET "
                    "ok = excluded.ok, step = excluded.step, reason = excluded.reason, "
                    "ms = excluded.ms, ran = excluded.ran",
                    (
                        portal_id,
                        tonight(now),
                        None if ok is None else int(ok),
                        step[:40],
                        reason[:300],
                        ms,
                        now,
                    ),
                )
                self._aufraeumen(v, now)
        except Exception:
            pass

    def history(self, portal_id: str, nights: int = NIGHTS) -> list[int | None]:
        """The last nights as a strip, **oldest first**.

        Nights without an entry appear as `None`. That is the difference
        between "did not carry" and "did not run", and without the gaps a
        portal that has only been here since yesterday could not be told apart
        from one that failed twelve times.
        """
        rows = self._rows(portal_id, nights)
        return [rows.get(tag) for tag in self._tage(nights)]

    def all_histories(self, nights: int = NIGHTS) -> dict[str, list[int | None]]:
        """For every portal there is an entry for."""
        with self.store.connect() as v:
            kennungen = [z["portal_id"] for z in v.execute("SELECT DISTINCT portal_id FROM night")]
        return {k: self.history(k, nights) for k in sorted(kennungen)}

    def failing(self, portal_id: str, in_a_row: int = FAILED_IN_A_ROW) -> bool:
        """Did the last `in_a_row` nights **all** fail?

        Nights without a run neither break the chain nor count towards it — a
        portal that failed two nights, paused for one and then failed again has
        failed three times, not once.
        """
        gelaufen = [x for x in reversed(self.history(portal_id, KEEP_NIGHTS)) if x is not None]
        return len(gelaufen) >= in_a_row and all(x == 0 for x in gelaufen[:in_a_row])

    def last(self, portal_id: str) -> Night | None:
        """The most recent entry — for the question "why"."""
        with self.store.connect() as v:
            z = v.execute(
                "SELECT * FROM night WHERE portal_id = ? ORDER BY night DESC LIMIT 1",
                (portal_id,),
            ).fetchone()
        if z is None:
            return None
        return Night(
            z["portal_id"],
            z["night"],
            None if z["ok"] is None else bool(z["ok"]),
            z["step"],
            z["reason"],
            z["ms"],
            z["ran"],
        )

    def as_json(self, nights: int = NIGHTS) -> dict[str, Any]:
        """What the console needs: the strips and the last reason."""
        streifen = self.all_histories(nights)
        return {
            "nights": nights,
            "history": streifen,
            "last": {
                k: {"night": n.night, "ok": n.ok, "step": n.step, "reason": n.reason, "ms": n.ms}
                for k in streifen
                if (n := self.last(k)) is not None
            },
            # The failed nights with their reason, newest first — the portal
            # page lists them (rebuild 09.11.2026). A strip says *that* it
            # failed; this says *why*, night by night.
            "failures": self.failures(nights),
        }

    def failures(
        self, nights: int = NIGHTS, per_portal: int = 5
    ) -> dict[str, list[dict[str, Any]]]:
        days = self._tage(nights)
        if not days:
            return {}
        with self.store.connect() as v:
            rows = v.execute(
                "SELECT portal_id, night, step, reason FROM night "
                "WHERE ok = 0 AND night >= ? ORDER BY night DESC",
                (min(days),),
            ).fetchall()
        out: dict[str, list[dict[str, Any]]] = {}
        for z in rows:
            lst = out.setdefault(z["portal_id"], [])
            if len(lst) < per_portal:
                lst.append({"night": z["night"], "step": z["step"], "reason": z["reason"]})
        return out

    # ── Inside ──────────────────────────────────────────────────────────────

    def _tage(self, nights: int) -> list[str]:
        """The last `nights` nights, oldest first."""
        heute = datetime.strptime(tonight(), "%Y-%m-%d").replace(tzinfo=UTC)
        return [(heute - timedelta(days=n)).strftime("%Y-%m-%d") for n in range(nights - 1, -1, -1)]

    def _rows(self, portal_id: str, nights: int) -> dict[str, int | None]:
        with self.store.connect() as v:
            rows = v.execute(
                "SELECT night, ok FROM night WHERE portal_id = ? ORDER BY night DESC LIMIT ?",
                (portal_id, nights),
            ).fetchall()
        return {z["night"]: z["ok"] for z in rows}

    def _aufraeumen(self, v: Any, now: float) -> None:
        grenze = (datetime.fromtimestamp(now, tz=UTC) - timedelta(days=KEEP_NIGHTS)).strftime(
            "%Y-%m-%d"
        )
        v.execute("DELETE FROM night WHERE night < ?", (grenze,))
