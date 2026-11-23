"""The event book — what happened in the household, not what somebody watched.

**The line between those two is the whole design.** "Recently" used to show a
state and not a history: the service's uptime and which portal is currently
broken. That is true and still not a log — after a restart the same thing
stands there again, and what somebody flipped yesterday is known to nobody.

**What goes in here: operations.** Who switched a portal, paired a device,
changed a permission, restored a backup. Those are administrative acts, and
whoever cannot retrace them administers on suspicion.

**What does not go in here: who watched what.** The plan asks exactly that
question ("and then how long belongs to it as well"), and the honest answer is
not to ask it in the first place. A household is not a company: a log of who
started which film when is an instrument of power inside a family, and it is
not going to come about here by accident.

Progress (`progress`) is something else — it belongs to the person themselves,
they can see it, and it serves continuing to watch. A log serves other people
looking things up.

**Codes instead of sentences**, as with the errors. An event is
`{code, values, who}`; the interface builds the sentence from it. A log in a
language the reader does not speak is no log.
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from typing import Any, Final

from cinelounge.household.store import Store

#: How long an entry stays unless somebody sets otherwise.
#:
#: **Thirty days, and the number is a stance.** Whoever asks after a month who
#: switched a portal off asks out of curiosity and not out of need — and a log
#: that stays forever will eventually be used for something it was not meant
#: for. Changeable through `log.tage` in the household settings.
DEFAULT_DAYS: Final = 30

#: An upper bound, regardless of age.
#:
#: Against the case where something writes in a loop: the table lives in the
#: same file as the household, and that file goes into every backup.
MAX_ROWS: Final = 5000


#: Somebody who wants to hear about events as they happen (Telegram, 09.11.2026).
Listener = Callable[[str, dict[str, Any]], None]


class Events:
    def __init__(self, store: Store) -> None:
        self.store = store
        #: Called after every recorded event. Same rule as writing: a listener
        #: that fails never fails the act, and must return quickly (Telegram
        #: hands the message to its own thread).
        self.listeners: list[Listener] = []

    # ── Writing ─────────────────────────────────────────────────────────────

    def record(self, code: str, values: dict[str, Any] | None = None, who: str = "") -> None:
        """Record one event. Never raises.

        **A log must never be the reason something fails.** The call sits
        beside the actual work — flipping a portal, pairing a device — and if
        writing jams, the work is done all the same. What is lost here is a
        line; what would otherwise be lost is the act.
        """
        try:
            with self.store.connect() as v:
                v.execute(
                    "INSERT INTO event (at, code, values_json, person_id) VALUES (?, ?, ?, ?)",
                    (time.time(), code, json.dumps(values or {}, ensure_ascii=False), who or None),
                )
                self._trim(v)
        except Exception:  # see the docstring
            pass
        for listener in list(self.listeners):
            try:
                listener(code, dict(values or {}))
            except Exception:  # see the docstring
                pass

    def _trim(self, v: Any) -> None:
        """Clear out the old — on writing, not on reading.

        The same reasoning as with the pairing codes: whoever only tidies up
        when somebody looks never tidies up in a household that runs for
        months.
        """
        tage = self._days()
        if tage > 0:
            v.execute("DELETE FROM event WHERE at < ?", (time.time() - tage * 86400,))
        v.execute(
            "DELETE FROM event WHERE id NOT IN (  SELECT id FROM event ORDER BY at DESC LIMIT ?)",
            (MAX_ROWS,),
        )

    def _days(self) -> int:
        """`log.tage` from the household — `0` means: do not delete by age."""
        roh = self.store.read("log.tage", "")
        try:
            return int(roh) if str(roh).strip() else DEFAULT_DAYS
        except (TypeError, ValueError):
            # An unreadable value must not end up deleting nothing at all —
            # that would be the silent version of "forever".
            return DEFAULT_DAYS

    # ── Reading ─────────────────────────────────────────────────────────────

    def recent(self, limit: int = 40) -> list[dict[str, Any]]:
        """The most recent entries, newest first."""
        with self.store.connect() as v:
            rows = v.execute(
                "SELECT at, code, values_json, person_id FROM event ORDER BY at DESC LIMIT ?",
                (max(1, min(limit, 200)),),
            ).fetchall()
        return [
            {
                "at": z["at"],
                "code": z["code"],
                # A broken entry must not take the list with it: the log is
                # what you look at when something else is already jammed.
                "values": _lies(z["values_json"]),
                "who": z["person_id"] or "",
            }
            for z in rows
        ]

    def count(self) -> int:
        with self.store.connect() as v:
            return int(v.execute("SELECT COUNT(*) c FROM event").fetchone()["c"])


def _lies(roh: Any) -> dict[str, Any]:
    try:
        wert = json.loads(roh or "{}")
        return wert if isinstance(wert, dict) else {}
    except (TypeError, ValueError):
        return {}
