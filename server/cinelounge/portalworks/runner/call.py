"""One portal call — inside a child process, behind limits.

**Portal code runs in the child only.** That is the whole of stage E0: code
that talks to a foreign site must never lay eyes on the process that knows the
household and the device tokens.

**How a portal is built is its kind's business.** `kind:` in the manifest
names a registered `extension.KindSpec`; its `build` runs here, inside the
child, and whatever it imports is imported there. The core brings `native`
(`portalworks/native.py`), extensions bring more. The parent never builds a
portal — on a machine without `fork` the API process stays startable whatever
a kind would import.
"""

from __future__ import annotations

import logging
import time
from dataclasses import asdict
from typing import Any

from cinelounge.core import errors as f
from cinelounge.core.contract import Entry, Item, Page, Source, Stream
from cinelounge.portalworks import extension, routes
from cinelounge.portalworks.manifest import Manifest
from cinelounge.portalworks.runner.fork import Limits, run
from cinelounge.portalworks.runner.preload import preload
from cinelounge.portalworks.runner.spur import Spur

# What a portal can answer. The names come from the contract, not from the
# HTTP route — that keeps the runner independent of the web layer.
__all__ = ["METHODS", "call", "preload"]

_LOG = logging.getLogger("cinelounge.runner")

# From how many seconds on a successful call carries its trail in the log line.
LANGSAM_S = 3.0

# **These names are the method names, not just labels.**
# The child calls `getattr(portal, method)`. Until 11 Sep 2026 this list said
# `series` while every implementation was called `serie` — the lookup came up
# empty, and since `optional=True` that was no longer an exception but a
# `None`. So the central per-series language choice never ran at all:
# `web/portals.py` asks for it before every playback and always got nothing.
# `tests/test_vertrag.py` now checks this list against the protocol.
METHODS = frozenset({"menu", "listing", "children", "sources", "resolve", "search", "series"})


def _portal_bauen(m: Manifest) -> Any:  # inside the child only
    """Build the portal object in the child, through its kind."""
    spec = extension.kind(m.kind)
    if spec is None:
        raise f.Error(f.PORTAL_BROKEN, {"id": m.id, "why": "unknown kind " + m.kind})
    return spec.build(m)


def _route_child(via: str) -> None:
    """Inside the child only: everything this portal fetches goes through its route.

    **Environment, not a patch.** `requests` (`trust_env`), `urllib.request`
    (`getproxies_environment`) and `http.client` through them all read
    `HTTP_PROXY`/`HTTPS_PROXY` — that covers portal code without touching a
    line of it. Set in the child, after the fork, so the parent never routes
    anything: the API process talks to the apps on the LAN and to nothing
    else.

    `NO_PROXY` keeps the container's own addresses off the route: a portal
    that serves something on `127.0.0.1` (see `stream/buffer.py`) must still
    reach it, and a proxy elsewhere could not connect back into the container
    anyway.
    """
    import os
    import urllib.request

    for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
        os.environ[name] = via
        os.environ[name.lower()] = via
    os.environ["NO_PROXY"] = os.environ["no_proxy"] = "127.0.0.1,localhost,::1"
    # **The inherited default opener does not read the environment again.**
    # `urlopen()` builds its opener once, and its `ProxyHandler` copies the
    # proxies at that moment. The parent may already have built it — so a
    # child calling plain `urlopen()` went out directly with the route's
    # variables set. Measured on 16.09.2026: the same public address with and
    # without the route. A fresh opener reads the environment now.
    urllib.request.install_opener(urllib.request.build_opener())


def _hinaus(value: Any) -> Any:
    """Data classes into dictionaries — `pickle` carries both, JSON only one."""
    if isinstance(value, (Entry, Item, Source, Stream)):
        return asdict(value)
    if isinstance(value, Page):
        d = asdict(value)
        d["items"] = [asdict(i) for i in value.items]
        return d
    if isinstance(value, list):
        return [_hinaus(x) for x in value]
    return value


def call(
    m: Manifest,
    method: str,
    arguments: dict[str, Any] | None = None,
    limits: Limits | None = None,
    optional: bool = False,
) -> Any:
    """Call one portal method and return its result.

    The call runs in a child process with its own `sys.modules`, its own memory
    limit and its own deadline. If it crashes, the child dies — not the
    service.

    **`optional=True` means: this method is allowed to be missing.** Not every
    portal answers every question — `series`, for instance, exists only where
    episodes belong to a series. A broadcaster's library has none, and that is
    not a defect.

    Found on 10 Sep 2026 at the route that matters: `/play?address=…` called
    `series` only to look up the language chosen last, and took the whole
    playback down with it when there was none. `run.crashed` for ZDF, ARD,
    arte, 3sat — for exactly the bundled set, that is. The workshop run was
    green because it goes the `source=` way.

    A missing method then yields `None`, not an error. A **crash inside** the
    method stays an error, `optional` or not — otherwise we would swallow a
    real portal problem.
    """
    if method not in METHODS:
        raise f.Error("run.unknown_method", {"method": method}, status=400)
    if not m.is_ready:
        raise f.Error(f.PORTAL_BROKEN, m.refusal(), status=503)

    args = dict(arguments or {})
    # Resolved in the parent, so that a route that is gone is a plain error
    # here and not a portal that quietly went out directly.
    via = routes.proxy_for(m)
    if routes.missing(m):
        raise f.Error(
            f.PORTAL_BROKEN, {"id": m.id, "why": "no exit for net: " + m.exit_net}, status=503
        )

    spur = Spur()

    def work() -> Any:
        # The trail first, so that every step below — including routing and
        # building the portal — shows up in it. Child only; see `spur.py`.
        spur.einschalten()
        if via:
            _route_child(via)
        # What extensions set up for every request of this child — after the
        # route, so it holds for it, and before any portal code runs.
        for setup in extension.CHILD_SETUPS:
            setup(m, via)
        portal = _portal_bauen(m)

        # **Settings first, then the question.** Some kinds hand them over
        # while building; native portals did not receive them at all until
        # 11 Sep 2026 — `module.Portal()` takes no arguments. A stranger
        # following the SDK built a setting that never arrived.
        #
        # Optional, and a failure here is a failure: a portal that does not
        # accept its settings carries on with the wrong values, and that only
        # shows up in the result.
        vorbereiten = getattr(portal, "configure", None)
        if callable(vorbereiten) and m.settings:
            vorbereiten(
                {str(e["key"]): str(e.get("value") or "") for e in m.settings if e.get("key")}
            )

        fn = getattr(portal, method, None)
        if fn is None:
            if optional:
                return None
            raise f.Error("run.unknown_method", {"method": method, "portal": m.id})
        if method in ("children", "sources"):
            args["item"] = Item(title=args.pop("title", ""), address=args.pop("address", ""))
        elif method == "resolve":
            args["source"] = Source(id=args.pop("source", ""), name="", address="")
        return _hinaus(fn(**args))

    start = time.monotonic()
    try:
        result = run(work, limits)
    except f.Error as err:
        _observe(m, method, err)
        # The trail stays in the log: it names hosts and files, and `values`
        # is display material for the app, not a forensic record.
        trail = spur.zusammenfassung()
        spur.aufraeumen()
        _LOG.warning(zeile(m.id, method, start, err.code, trail))
        raise
    _observe(m, method, None)
    langsam = time.monotonic() - start >= LANGSAM_S
    trail = spur.zusammenfassung() if langsam else None
    spur.aufraeumen()
    # **Warning, not info, for a slow success.** Nothing configures Python's
    # logging here; the container log therefore carries warnings and above
    # only. A call that took longer than `LANGSAM_S` is exactly what somebody
    # reading that log is looking for, the quick ones are not.
    (_LOG.warning if langsam else _LOG.info)(zeile(m.id, method, start, None, trail))
    return result


def _observe(m: Manifest, method: str, err: f.Error | None) -> None:
    """Tell the call observers (`extension.CALL_OBSERVERS`) how the call ended.

    In the parent, after the child is gone and outside every lock. An observer
    that raises is logged and does not change the outcome.
    """
    for observe in extension.CALL_OBSERVERS:
        try:
            observe(m, method, err)
        except Exception:
            _LOG.exception("call observer failed for %s.%s", m.id, method)


def zeile(
    portal: str, method: str, start: float, code: str | None = None, spur: str | None = None
) -> str:
    """One line per call: portal, method, outcome, how long it took — and the trail.

    **Where the 20 seconds go was in no log** (AP74, 11.10.2026): 11 of 164
    `/list` in 48 hours hit the deadline, and nothing said which portal and
    which method, or whether the others were quick. One line each, with the
    duration to the tenth, answers that without a debugger on the host. On a
    failure, and on a success slower than `LANGSAM_S`, the child's trail
    follows (`spur.py`): which step took how long, and which one was still
    open when the deadline struck.
    """
    dauer = time.monotonic() - start
    ergebnis = "ok" if code is None else code
    text = f"{portal}.{method} {ergebnis} in {dauer:.1f} s"
    return text if not spur else f"{text} — {spur}"
