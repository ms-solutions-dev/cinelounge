"""One line per portal call, with its duration (AP74, 11.10.2026) — see `runner/call.py`."""

from __future__ import annotations

import time

from cinelounge.portalworks.runner import call


def test_zeile_nennt_portal_methode_ergebnis_und_dauer():
    start = time.monotonic() - 1.26
    assert call.zeile("ahorn", "listing", start).startswith("ahorn.listing ok in 1.")
    assert call.zeile("ahorn", "listing", start, "run.timeout").startswith(
        "ahorn.listing run.timeout in 1."
    )
