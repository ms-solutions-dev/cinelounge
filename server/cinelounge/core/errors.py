"""Failures as codes, never as sentences.

**The rule the whole translation story hangs on:** the server never sends prose
that ends up on a screen. It sends a code and the values that belong in it;
the wording is chosen where someone is actually looking.

The old bridge broke this everywhere::

    raise HTTPException(502, f"{what}: {type(err).__name__}: {err}")
    raise HTTPException(502, "no host carried it — " + "; ".join(errors))

German, hard-wired, untranslatable — and it landed on the television of a
household that might well run the app in Turkish. The app had been doing it
right for a long time (``Text(appKey: "setup.continue")``), so the server
followed.

**Codes are English and dot-separated**, like the app's translation keys. They
are part of the public contract: a code that has once been out in the world is
never renamed — an older app would simply show nothing.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Final


# **Neither `slots` nor `frozen`.** Both break on an exception: `slots=True`
# builds a new class, and the traceback assignment inside the exception
# machinery then points at the old one — `TypeError: super(type, obj): obj is
# not an instance or subtype of type`. Found by
# `test_kopplung_gilt_genau_einmal`, not by reading.
@dataclass
class Error(Exception):
    """A failure that somebody should be able to translate.

    ``values`` fills the placeholders of the translation. What goes in there is
    **display material, not a forensic trail** — addresses, checksums and
    credentials belong in the log, not in a response.
    """

    code: str
    values: dict[str, Any] = field(default_factory=dict)
    status: int = 502
    """The HTTP status. It lives on the error rather than on the route, so that
    the same cause produces the same answer everywhere."""

    def as_json(self) -> dict[str, Any]:
        return {"error": {"code": self.code, "values": self.values}}


# ── Portal and run ───────────────────────────────────────────────────────────

PORTAL_UNKNOWN: Final = "portal.unknown"
PORTAL_BROKEN: Final = "portal.broken"
PORTAL_DISABLED: Final = "portal.disabled"

RUN_TIMEOUT: Final = "run.timeout"
RUN_OUT_OF_MEMORY: Final = "run.out_of_memory"
"""The runner hit its limit.

**A code of its own rather than `run.failed`.** Whoever sees it has nothing to
investigate: it is the number from the settings, and that is three clicks away.
Without the distinction, a limit set too tight looks exactly like a broken
portal.
"""
RUN_CRASHED: Final = "run.crashed"

# ── Playback ─────────────────────────────────────────────────────────────────

STREAM_NO_HOST: Final = "stream.no_host"
STREAM_HOST_EMPTY: Final = "stream.host_empty"
STREAM_EXPIRED: Final = "stream.expired"

STREAM_DRM: Final = "stream.drm"
"""Widevine or PlayReady — AVPlayer only speaks FairPlay.

**Not `stream.no_host`, and the difference is not a nicety.** "No host" sends
the viewer off to try again; here there can be no second try, not today and not
tomorrow. The app has a sentence of its own for it.

An ``#EXT-X-KEY:METHOD=AES-128`` with ``KEYFORMAT=identity`` is **not** meant:
that is ordinary segment encryption, and AVPlayer plays it.
"""

STREAM_GEO_BLOCKED: Final = "stream.geo_blocked"

# ── Access ───────────────────────────────────────────────────────────────────

AUTH_REQUIRED: Final = "auth.required"
AUTH_FORBIDDEN: Final = "auth.forbidden"
"""Signed in, but not allowed.

**The code that turns the parental lock into a rule.** Hiding something is not
locking it: if a child's device queries an adult portal directly, this is what
comes back, not the listing.
"""
HOUSEHOLD_LAST_ADMIN: Final = "household.last_admin"
"""The last admin stays.

A household without an admin can no longer be managed — no portals switched, no
devices paired, nobody added. The only way back would be a hand inside the
database, and that is not an interface.
"""
HOUSEHOLD_NOT_YOURSELF: Final = "household.not_yourself"
"""Nobody removes themselves.

Whoever did would be locked out in the same breath.
"""
AUTH_BAD_CREDENTIALS: Final = "auth.bad_credentials"
"""Name or PIN is wrong — **one of the two, and we do not say which.**

A code of its own next to `AUTH_REQUIRED`, and the difference is not a nicety:
`auth.required` means "you sent no device token" and sends the interface to the
sign-in screen; this one means "you are already standing there and mistyped".
Putting both on one code would show "not signed in" to someone who simply got
their PIN wrong — correct and useless.

What it does **not** give away is which half was wrong. Otherwise the service
tells everyone who tries which accounts exist.
"""
AUTH_LOCKED_OUT: Final = "auth.locked_out"
HOUSEHOLD_UNKNOWN_DEVICE: Final = "household.unknown_device"
"""Renaming a device that is not (or no longer) paired.

The console can be a step behind: a device revoked from another browser is
still on the screen here. Naming it must say so instead of reporting success
for a row that no longer exists.
"""
PAIRING_EXPIRED: Final = "pairing.expired"
INVITE_USED: Final = "invite.used"

# ── Marketplace ──────────────────────────────────────────────────────────────

MARKET_SOURCE_UNREACHABLE: Final = "market.source_unreachable"
MARKET_CHECKSUM_MISMATCH: Final = "market.checksum_mismatch"
"""The version we fetched is not the one that was signed.

It stops there. Nothing is weighed up: a checksum you can wave through is not a
checksum.
"""
MARKET_API_UNSUPPORTED: Final = "market.api_unsupported"
