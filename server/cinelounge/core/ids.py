"""Identifiers — what a title is recognised by.

**The key is `portal : normalised title : year`, not the address.** With a
scraper the "identifier" is an address, and that changes the moment the site is
rebuilt. Key on it and you lose "continue watching" for the entire library as
soon as one portal changes its URL scheme. The address only travels alongside,
as a hint.
"""

from __future__ import annotations

import re
import secrets
import unicodedata

_NON_WORD = re.compile(r"[^a-z0-9]+")

# Without the characters that are easy to mix up: a pairing code is read off a
# screen and typed into another device. `0` against `O` and `1` against `l`
# cost a second attempt there.
_DICE = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
_DICE_LOWER = "abcdefghjkmnpqrstuvwxyz23456789"


def normalized(title: str) -> str:
    """Boil a title down to its core: lower case, no punctuation, no accents.

    "Die Pewi" and "die pewi!" are meant to be the same title, and so
    are "Shōgun" and "Shogun".
    """
    split_key = unicodedata.normalize("NFKD", title)
    without_accents = "".join(c for c in split_key if not unicodedata.combining(c))
    return _NON_WORD.sub("-", without_accents.casefold()).strip("-")


def key(portal: str, title: str, year: int | None = None) -> str:
    """`portal : normalised title : year` — the identifier progress hangs on."""
    return f"{portal}:{normalized(title)}:{year if year else ''}"


def pairing_code() -> str:
    """Six characters someone reads off a television.

    `secrets` rather than `random`: for a few minutes this code is the only
    thing keeping a stranger's device from attaching itself to a profile.
    """
    return "".join(secrets.choice(_DICE) for _ in range(6))


def invite_token() -> str:
    """The token inside an invitation link.

    Twenty-two characters out of 30 possibilities are roughly 108 bits — ample
    for something that works once and expires within hours.
    """
    return "".join(secrets.choice(_DICE_LOWER) for _ in range(22))


def device_token() -> str:
    """The long-lived token a paired device carries."""
    return secrets.token_urlsafe(32)
