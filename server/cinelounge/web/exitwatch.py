"""The route watch: notices when a network route goes down (09.11.2026).

Without it a route's state was only measured when somebody opened the network
page, and a dead route showed only indirectly — as portals failing in the
nightly run. For a message "route X is down" somebody has to look regularly;
this is that somebody.

**Two misses in a row, then one event.** One unanswered knock is a hiccup;
two, five minutes apart, are a state. And one event per outage, not one per
check: `event.exit_down` when it goes, `event.exit_back` when it returns. The
book stays readable and the phone stays quiet.

Every state measured here is remembered (`routes.status`), so the first page
after a restart does not wait on a dead route either.
"""

from __future__ import annotations

import logging
import os
import threading
from typing import Any, Final

from cinelounge.portalworks import routes

_LOG = logging.getLogger(__name__)

#: How often every route is asked.
CHECK_S: Final = 300.0
#: How many misses in a row count as "down".
MISSES: Final = 2

_STOP = threading.Event()
_THREAD: threading.Thread | None = None


class Watch:
    """The memory between two checks — kept apart from the thread for tests."""

    def __init__(self, events: Any) -> None:
        self.events = events
        self.misses: dict[str, int] = {}
        self.down: set[str] = set()

    def check(self, statuses: list[dict[str, Any]]) -> None:
        for s in statuses:
            ident = str(s.get("id", ""))
            if s.get("state") == "running":
                self.misses[ident] = 0
                if ident in self.down:
                    self.down.discard(ident)
                    self.events.record("event.exit_back", {"exit": ident})
                continue
            self.misses[ident] = self.misses.get(ident, 0) + 1
            if self.misses[ident] >= MISSES and ident not in self.down:
                self.down.add(ident)
                self.events.record(
                    "event.exit_down",
                    {
                        "exit": ident,
                        "state": s.get("state", ""),
                        "why": str(s.get("why") or "")[:80],
                    },
                )


def start(events: Any) -> None:
    """Start the watch. Without routes it looks and finds nothing to do."""
    global _THREAD
    if _THREAD is not None and _THREAD.is_alive():
        return
    _STOP.clear()
    watch = Watch(events)
    _THREAD = threading.Thread(target=_loop, args=(watch,), name="exitwatch", daemon=True)
    _THREAD.start()


def stop() -> None:
    _STOP.set()


def _loop(watch: Watch) -> None:
    # The first look right at start: it also fills the remembered states.
    first = True
    while first or not _STOP.wait(CHECK_S):
        first = False
        try:
            current = routes.all_routes()
            if current:
                watch.check([routes.status(r) for r in current])
        except Exception:
            _LOG.exception("Route watch: check failed")


def _after_fork_in_child() -> None:
    """A thread does not survive `fork()`; the child starts without a watch."""
    global _THREAD
    _THREAD = None
    _STOP.clear()


if hasattr(os, "register_at_fork"):
    os.register_at_fork(after_in_child=_after_fork_in_child)
