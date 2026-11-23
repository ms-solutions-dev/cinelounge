"""The timer that sets the nightly run going.

**Why this lies here.** It calls both: `portalworks.nightly` (which checks) and
`household.nights` (which keeps the book). Those two must not know each other —
the layer contract in `setup.cfg` does not let `portalworks` reach into
`household`, nor the other way round. What brings them together is the layer
above, and that is `web`.

## Staggered, and that is the point

Checking eleven portals at once means eleven child processes at once, each with
a 256 MB limit. On a mini PC that is the difference between a nightly run and an
OOM kill. So one after the other, with a pause in between: the run may take an
hour, nobody is watching anyway.

## Why a thread and not a `lifespan`

The same reasoning as for the buffer sweeper: the service forks for every portal
call, and a thread does not survive `os.fork()`. It belongs in the parent
process, and a child checking portals on the side would be a fault —
`os.register_at_fork` sees to it that none does.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from datetime import datetime
from typing import Any, Final

from cinelounge.household.nights import Nights
from cinelounge.portalworks import extension, nightly
from cinelounge.portalworks.manifest import Manifest
from cinelounge.portalworks.registry import Registry

_LOG = logging.getLogger("cinelounge.nachtlauf")

#: At which hour the run begins (the container's local time).
#:
#: Four in the morning: late enough that nobody is watching any more, early
#: enough that the result is there at the breakfast table. And it is the hour by
#: which the media libraries have their night maintenance behind them — a run at
#: 02:00 regularly measures their rebuild and not the portal.
HOUR: Final = 4

#: How long is waited between two portals.
#:
#: Eleven portals at once are eleven child processes with a 256 MB limit each.
#: On a mini PC that is the difference between a nightly run and an OOM kill.
#: Twenty seconds cost less than four minutes across eleven portals, and nobody
#: is watching anyway.
GAP_S: Final = 20.0

#: How often it is checked whether the hour has come.
TICK_S: Final = 300.0

_UHR: threading.Thread | None = None
_SCHLUSS = threading.Event()
_LAEUFT = threading.Event()


def run_once(
    registry: Registry,
    nights: Nights,
    *,
    events: Any = None,
    switch: Any = None,
    gap_s: float = GAP_S,
    only: str | None = None,
) -> dict[str, Any]:
    """Check every portal once through (or just `only`). **Never raises.**

    `events` is the event book's writer or `None` — it is only called when a
    portal fails on the third night in a row. Not on every failure: a book with
    eleven lines every night is no book.

    `switch` is `Visibility` or `None` and says which portals are switched on.
    Without it all of them are checked — right for a test, not in operation.
    """
    if _LAEUFT.is_set():
        return {"skipped": "already running"}
    _LAEUFT.set()
    begonnen = time.time()
    getragen: list[str] = []
    gescheitert: list[str] = []
    uebersprungen: list[str] = []

    try:
        chosen = [m for m in registry.manifests.values() if only is None or m.id == only]
        for i, m in enumerate(chosen):
            if _SCHLUSS.is_set():
                break
            if i:
                _SCHLUSS.wait(gap_s)

            # **A switched-off portal has not failed.** `None` and not
            # `False`: a strip that paints both the same makes a pause look
            # like a fault.
            #
            # The **household's** switch, not the manifest's default. Here stood
            # `not m.on_by_default and not m.is_ready` — which almost never
            # applied and read the wrong field. Measured, a portal standing at
            # `enabled: false` was checked all the same, and got a red stripe
            # although nobody uses it.
            an = True if switch is None else switch.is_on(m.id, m.on_by_default)
            if not an:
                nights.record(m.id, None, step="off", reason="")
                uebersprungen.append(m.id)
                continue

            # **Nor has a portal waiting for a setting.** It cannot play
            # without the value, and the night would say so every night; from
            # the third on that became `event.portal_failing` and a message,
            # for something that is a task for the operator and not a fault.
            # Like a switched-off one: `None`, no failure.
            if m.needs_setting:
                nights.record(m.id, None, step="needs_setting", reason=m.broken_reason or "")
                uebersprungen.append(m.id)
                continue

            ergebnis = nightly.check(m)
            nights.record(
                m.id,
                ergebnis.ok,
                step=ergebnis.step,
                reason=ergebnis.reason,
                ms=ergebnis.ms,
            )
            (getragen if ergebnis.ok else gescheitert).append(m.id)

            if ergebnis.ok:
                _LOG.info("Nightly run %s: carried (%d ms)", m.id, ergebnis.ms)
                _nachher(m, ergebnis)
                continue

            _LOG.warning("Nightly run %s: failed at %s — %s", m.id, ergebnis.step, ergebnis.reason)
            # **Into the book only from the third night on.** One is an
            # outage, two is bad luck, three is a state — and only that is worth
            # a line somebody reads later.
            if events is not None and nights.failing(m.id):
                events.record(
                    "event.portal_failing",
                    {"portal": m.id, "step": ergebnis.step, "why": ergebnis.reason[:120]},
                )
            _nachher(m, ergebnis)
    finally:
        _LAEUFT.clear()

    return {
        "carried": getragen,
        "failed": gescheitert,
        "skipped": uebersprungen,
        "seconds": round(time.time() - begonnen, 1),
    }


def _nachher(m: Manifest, ergebnis: nightly.Result) -> None:
    """Every `NightlyHook.after`, on this thread. One that raises is logged and skipped.

    Called while `_LAEUFT` is set; a hook must not wait for the run to end.
    """
    for hook in extension.NIGHTLY_HOOKS:
        try:
            hook.after(m, ergebnis)
        except Exception as err:
            _LOG.warning("Nightly hook failed after %s: %s", m.id, type(err).__name__)


def start(registry: Registry, nights: Nights, events: Any = None, switch: Any = None) -> None:
    """Start the timer. Calling it repeatedly is allowed and does nothing."""
    global _UHR
    if _UHR is not None and _UHR.is_alive():
        return
    _SCHLUSS.clear()
    _UHR = threading.Thread(
        target=_uhrwerk,
        args=(registry, nights, events, switch),
        name="nightwatch",
        daemon=True,
    )
    _UHR.start()


def stop() -> None:
    """For the tests and for shutting down."""
    _SCHLUSS.set()


def _uhrwerk(registry: Registry, nights: Nights, events: Any, switch: Any) -> None:
    """Look every `TICK_S` whether the hour has come.

    **No `sleep` until the target time.** A thread that sleeps eight hours
    misses every clock change and every restart in between — and whoever
    restarts the service at 03:59 would get the run only the next day.
    """
    zuletzt = ""
    while not _SCHLUSS.is_set():
        _SCHLUSS.wait(TICK_S)
        if _SCHLUSS.is_set():
            return
        jetzt = datetime.now()
        marke = jetzt.strftime("%Y-%m-%d")
        if jetzt.hour == HOUR and marke != zuletzt:
            zuletzt = marke
            try:
                d = run_once(registry, nights, events=events, switch=switch)
                _LOG.info(
                    "Nightly run done: %d carried, %d failed, %d skipped, %.1f s",
                    len(d.get("carried") or []),
                    len(d.get("failed") or []),
                    len(d.get("skipped") or []),
                    d.get("seconds") or 0.0,
                )
            except Exception:
                _LOG.exception("Nightly run aborted")


def _bei_fork_im_kind() -> None:
    """In the child there is no timer.

    A thread does not survive `os.fork()` — in the child only the forking one
    runs. Clearing the flags is necessary all the same: a child that inherits
    `_LAEUFT` set would take a run to be under way that never existed in it.
    """
    global _UHR
    _UHR = None
    _LAEUFT.clear()
    _SCHLUSS.clear()


if hasattr(os, "register_at_fork"):
    os.register_at_fork(after_in_child=_bei_fork_im_kind)
