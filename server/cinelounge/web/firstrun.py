"""The first start: a code in the log, and out of it comes a household.

**Why a code at all.** A fresh container has no person and therefore no PIN —
whoever comes first creates the household. On a home network that means: the
first to open `cl.example`, and that need not be whoever started the container. A
guest, a child, a device somebody forgot: all of them can grind.

The code separates "I started this service" from "I happen to be on the same
Wi-Fi". Seeing it means having access to the container's log — and whoever has
that has everything anyway.

**It is not in the database.** It lives in the process and vanishes on restart;
then a new one stands in the log. A setup code still lying in `/data` a week
later is a key under the doormat.

**And it is only generated when there is something to set up.** As soon as one
person stands in the household there is no code any more — not even in memory.
"""

from __future__ import annotations

import logging
import secrets
from typing import Final

_LOG = logging.getLogger("cinelounge.erstlauf")

#: What the code is made of.
#:
#: The same selection as for the pairing codes: no zero, no O, no one, no I. It
#: gets typed out, by somebody reading it off a terminal.
ALPHABET: Final = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

#: Eight characters, not six.
#:
#: A pairing code lives five minutes; this one lives until somebody creates the
#: household — possibly a week. 32^8 is 10^12 possibilities, and after five
#: wrong tries it is replaced anyway.
LENGTH: Final = 8

#: After how many wrong tries a new code is generated.
#:
#: **Replace instead of lock.** A lock would be a service making itself
#: unusable — and anybody on the network can trigger exactly that without
#: knowing the code. A new code costs the operator one glance at the log and
#: the guesser everything they have tried so far.
ATTEMPTS: Final = 5

_code: str | None = None
_daneben = 0


def arm(is_empty: bool) -> str | None:
    """At startup: generate a code if the household is empty.

    Returns the code (for tests) or `None` if none is needed.
    """
    global _code, _daneben
    if not is_empty:
        _code = None
        return None
    _code = "".join(secrets.choice(ALPHABET) for _ in range(LENGTH))
    _daneben = 0
    _ins_protokoll(_code)
    return _code


def check(eingabe: str) -> bool:
    """Does the code match? **A wrong try counts.**

    After `ATTEMPTS` wrong tries a new one is generated and written to the log —
    whoever has been guessing until then starts over.
    """
    global _daneben
    if _code is None:
        return False
    # `compare_digest`, because otherwise the comparison stops at the first
    # wrong character. Over a home network that is barely measurable — but it
    # costs nothing, and an exception here would be the one forgotten later.
    if secrets.compare_digest(eingabe.strip().upper(), _code):
        return True
    _daneben += 1
    if _daneben >= ATTEMPTS:
        _LOG.warning("First run: %d wrong tries — the code is being replaced.", _daneben)
        arm(True)
    return False


def spend() -> None:
    """The household stands. From now on there is no code any more."""
    global _code, _daneben
    _code = None
    _daneben = 0


def armed() -> bool:
    """Whether a code is valid right now. For `/health` and the tests."""
    return _code is not None


def _ins_protokoll(code: str) -> None:
    """Conspicuous, multi-line, with no timestamp in front.

    **Whoever comes here is not searching — they are scrolling.** Between
    uvicorn's lines a single line with eight characters cannot be found, and a
    stranger does not even know what to look for.
    """
    rand = "─" * 46
    _LOG.warning(
        "\n┌%s┐\n│%s│\n│%s│\n│%s│\n└%s┘",
        rand,
        "  CineLounge is not set up yet.              ".ljust(46),
        f"  Setup code:  {code}".ljust(46),
        "  Enter it at: http://<this-host>             ".ljust(46),
        rand,
    )
