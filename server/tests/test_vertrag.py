"""The contract and the runner have to know the same names.

**The case this file exists for.** `runner/call.py` carried
`METHODS = {…, "series"}`; every implementation was called `serie`. In the
child the runner does `getattr(portal, method)` — and the access went into
nothing.

Since 10.09.2026 `optional=True` stood on it, because a media-library portal
really does not have to answer the question. That turned the crash into an
answer: `None`, at every portal, every time. The central per-series language
choice — the viewer's wish of 28.08.2026, "instead of having to choose at
every episode" — was built and never ran.

**An `optional` hides exactly that.** It is still right; what was wrong was
that nobody held the two lists against each other. This file does that now.
"""

from __future__ import annotations

import inspect

from cinelounge.core.contract import Portal
from cinelounge.portalworks.runner.call import METHODS


def _protokollmethoden() -> set[str]:
    """What the protocol prescribes in methods — without attributes."""
    return {
        name
        for name, wert in vars(Portal).items()
        if not name.startswith("_") and inspect.isfunction(wert)
    }


def test_jede_laeufermethode_steht_im_protokoll():
    """`getattr(portal, name)` has to be able to find something.

    The names in `METHODS` are **method names**, not labels: the child looks
    them up in the portal object.
    """
    fehlt = sorted(METHODS - _protokollmethoden())
    assert not fehlt, (
        "Der Laeufer ruft Methoden, die das Protokoll nicht kennt: "
        + ", ".join(fehlt)
        + " — `getattr` findet nichts, und mit `optional=True` ist das dann "
        "keine Ausnahme, sondern ein stilles None."
    )


#: What stands in the protocol and does **not** go through `call()`.
#:
#: Exactly one name, and the reason stands beside it: `configure()` answers no
#: question, it prepares the portal. The runner calls it in the child before
#: asking the first question — making it reachable via `METHODS` would offer
#: it as a data source, and that it is not.
#:
#: The list is deliberately a list of exceptions and not a pattern: every
#: entry costs a reason here and a check below.
VORBEREITUNG = frozenset({"configure"})


def test_jede_protokollmethode_ist_erreichbar():
    """And the other way round: what stands in the protocol, the runner has to be able to call.

    A method that stands only in the contract is a promise to foreign portal
    authors nobody keeps — they implement it, and it is never called.
    """
    fehlt = sorted(_protokollmethoden() - METHODS - VORBEREITUNG)
    assert not fehlt, "the protocol promises methods the runner never calls: " + ", ".join(fehlt)


def test_die_vorbereitung_wird_auch_wirklich_gerufen():
    """An exception from `METHODS` is only one if it stands somewhere else.

    Otherwise the list above would be a convenient way to keep a dead method
    in the contract — exactly what `test_jede_protokollmethode_ist_erreichbar`
    is meant to prevent.
    """
    from pathlib import Path

    laeufer = (
        Path(__file__).resolve().parent.parent / "cinelounge" / "portalworks" / "runner" / "call.py"
    ).read_text(encoding="utf-8")

    for name in sorted(VORBEREITUNG):
        assert f'getattr(portal, "{name}"' in laeufer, (
            f"`{name}` steht in der Ausnahmeliste, aber der Laeufer holt es nirgends"
        )
