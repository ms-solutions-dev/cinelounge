"""Network routes — which way a portal's requests leave the house.

Every portal goes out directly, over the house's own connection. A **route**
is a named HTTP proxy the operator can lay a portal onto instead: in the
console ("Network"), stored per portal as `portal.<id>._net` in the household
(see `manifest.NET_OVERRIDE_KEY`). Everything the portal fetches then goes
through that proxy — its pages in the runner child, and the video the relay
passes on.

## Where routes come from

- **`CL_PROXIES`** in the environment, read once at startup::

      CL_PROXIES="office=http://10.0.0.2:3128 lab=http://user:secret@lab:8080"

  A name on the left (`a-z`, `0-9`, `-`, at most 32), a proxy address on the
  right. A piece that cannot be read is dropped, not raised: a typo in one
  route must not keep the service from starting.
- **Proxies saved in the console** (`PUT /network/exits`), kept in the
  household settings and laid in with `set_saved()`.
- **Providers** that extensions register with `register_provider()` — see
  `RouteProvider` and `docs/EXTENSIONS.md`. A name the core already offers
  stays the core's.

## A route that is gone makes the portal broken, not direct

A portal laid onto a route nobody offers (any more) is `broken` with the
reason `no exit for net: <name>` (`registry.py`), and the runner refuses to
call it (`runner/call.py`). Quietly sending it out directly would hide the
mistake behind a portal that merely behaves differently.

## States are measured, and remembered

`status()` asks the route's provider; for a proxy that is a knock on its port.
The answer is remembered (`FRESH_S`), so the network page and the watch
(`web/exitwatch.py`) do not wait on an unreachable proxy one after the other.
Providers are asked **outside** the lock that guards the remembered states.
"""

from __future__ import annotations

import os
import re
import socket
import threading
import time
from collections.abc import Iterable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Final
from urllib.parse import urlsplit

from cinelounge.portalworks.extension import Register

if TYPE_CHECKING:
    from cinelounge.portalworks.manifest import Manifest

__all__ = [
    "DIRECT",
    "FRESH_S",
    "NAME_PATTERN",
    "PROVIDERS",
    "Route",
    "RouteProvider",
    "all_routes",
    "choose",
    "configure",
    "details",
    "exists",
    "forget_states",
    "get",
    "is_routed",
    "missing",
    "parse_proxy",
    "proxy_for",
    "register_provider",
    "reject",
    "saved",
    "set_saved",
    "source_of",
    "status",
    "statuses",
]

#: The way out without a route: the house's own connection.
DIRECT: Final = "direct"

#: What a route's name may look like. `direct` matches as well and is never a
#: route; callers check it first.
NAME_PATTERN: Final = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")

#: How long a proxy may take to answer the knock.
_PATIENCE_S: Final = 2.0

#: How old a remembered state may be before it is measured again — a little
#: more than the watch's interval, so the pages live on what the watch measured.
FRESH_S: Final = 330.0


@dataclass(frozen=True, slots=True)
class Route:
    """One way out: a name and the proxy address requests go through."""

    name: str
    proxy_url: str

    @property
    def shown(self) -> str:
        """`host:port` without user and password — what may leave through the API."""
        parts = urlsplit(self.proxy_url)
        host = parts.hostname or ""
        return f"{host}:{parts.port}" if parts.port else host


class RouteProvider:
    """Whatever offers routes. Every method has a default that offers nothing.

    A provider is registered once, at startup (`register_provider`), and is
    copied into every runner child like the other registries — so it holds
    plain data, no threads and no open connections.
    """

    def routes(self) -> list[Route]:
        """The routes this provider offers right now, in the order to show them."""
        return []

    def status(self, route: Route) -> dict[str, Any]:
        """Measure one of this provider's routes now.

        At least `id` and `state` (`running`, `stopped` or `unreachable`);
        `ms` and `why` where there is something to say. Remembered by the core.
        """
        return {"id": route.name, "state": "unreachable", "why": "no status", "ms": None}

    def choose(self, m: Manifest) -> str | None:
        """The route a portal takes when the operator has not chosen one.

        `None` leaves the decision to the next provider and, in the end, to
        `direct`. Asked often and quickly: no I/O here.
        """
        return None

    def details(self, name: str) -> dict[str, Any]:
        """Extra fields for one route (or `direct`) in the network view —
        current, not remembered like the status."""
        return {}

    def reject(self, name: str) -> str | None:
        """An error code when this provider considers `name` malformed —
        asked only for a name no provider offers."""
        return None


class _Proxies(RouteProvider):
    """The core's own provider: `CL_PROXIES` plus the proxies saved in the console."""

    def __init__(self) -> None:
        self.from_env: dict[str, Route] = {}
        self.saved: dict[str, Route] = {}

    def routes(self) -> list[Route]:
        out = list(self.from_env.values())
        out += [r for n, r in self.saved.items() if n not in self.from_env]
        return out

    def status(self, route: Route) -> dict[str, Any]:
        return {
            "id": route.name,
            "host": route.shown,
            "source": "environment" if route.name in self.from_env else "console",
            **_knock(route, _PATIENCE_S),
        }


#: The providers, the core's first. `Register` seals them with every other
#: registry before the first runner child is forked.
PROVIDERS: Register[RouteProvider] = Register("route providers")
_PROXIES: Final = _Proxies()
PROVIDERS.add_core(_PROXIES)


def register_provider(provider: RouteProvider) -> RouteProvider:
    """An extension's routes. Only during `install`, like every registration."""
    return PROVIDERS.add(provider)


# ── Reading the routes ───────────────────────────────────────────────────────


def parse_proxy(name: str, address: str) -> Route | None:
    """A route from a name and an address, or `None` when either is unusable.

    `http://` and `https://` with a host; an optional port, user and password.
    """
    name = name.strip().lower()
    address = address.strip()
    if name == DIRECT or not NAME_PATTERN.match(name):
        return None
    try:
        parts = urlsplit(address)
        port_ok = parts.port is None or 0 < parts.port < 65536
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not parts.hostname or not port_ok:
        return None
    if parts.path not in ("", "/") or parts.query or parts.fragment:
        return None
    return Route(name=name, proxy_url=address.rstrip("/"))


def configure(spec: str | None) -> dict[str, Route]:
    """Read `CL_PROXIES`. Returns what was understood; the rest is dropped."""
    found: dict[str, Route] = {}
    for piece in re.split(r"[\s,;]+", (spec or "").strip()):
        name, sep, address = piece.partition("=")
        route = parse_proxy(name, address) if sep else None
        if route is not None:
            found[route.name] = route
    _PROXIES.from_env = found
    forget_states()
    return dict(found)


def set_saved(entries: Iterable[tuple[str, str]]) -> list[Route]:
    """Lay in the proxies saved in the console; unusable entries are dropped."""
    found: dict[str, Route] = {}
    for name, address in entries:
        route = parse_proxy(name, address)
        if route is not None:
            found[route.name] = route
    _PROXIES.saved = found
    forget_states()
    return list(found.values())


def saved() -> list[Route]:
    """The proxies saved in the console, as laid in last."""
    return list(_PROXIES.saved.values())


def source_of(name: str) -> str | None:
    """`environment`, `console`, `extension` — or `None` for no such route."""
    if name in _PROXIES.from_env:
        return "environment"
    if name in _PROXIES.saved:
        return "console"
    return "extension" if exists(name) else None


def _offered() -> list[tuple[RouteProvider, Route]]:
    """Every route with its provider; the first provider to offer a name keeps it."""
    out: list[tuple[RouteProvider, Route]] = []
    seen: set[str] = set()
    for provider in PROVIDERS:
        for route in provider.routes():
            if route.name in seen or route.name == DIRECT:
                continue
            seen.add(route.name)
            out.append((provider, route))
    return out


def all_routes() -> list[Route]:
    return [r for _, r in _offered()]


def get(name: str | None) -> Route | None:
    if not is_routed(name):
        return None
    return next((r for _, r in _offered() if r.name == name), None)


def exists(name: str | None) -> bool:
    return get(name) is not None


def _owner(route: Route) -> RouteProvider | None:
    return next((p for p, r in _offered() if r.name == route.name), None)


def is_routed(name: str | None) -> bool:
    return bool(name) and name != DIRECT


# ── A portal's way out ───────────────────────────────────────────────────────


def choose(m: Manifest) -> str | None:
    """The providers' choice for a portal the operator left alone — the first
    answer wins, `None` when nobody has one."""
    for provider in PROVIDERS:
        name = provider.choose(m)
        if name:
            return name
    return None


def proxy_for(m: Manifest) -> str | None:
    """The proxy this portal's requests go through, `None` for direct."""
    route = get(m.exit_net)
    return route.proxy_url if route else None


def missing(m: Manifest) -> bool:
    """Whether the portal names a route nobody offers."""
    return is_routed(m.exit_net) and get(m.exit_net) is None


def reject(name: str) -> str | None:
    """The first provider's objection to a name nobody offers, if any."""
    for provider in PROVIDERS:
        code = provider.reject(name)
        if code:
            return code
    return None


def details(name: str) -> dict[str, Any]:
    """What the providers add to one route (or `direct`) in the network view."""
    out: dict[str, Any] = {}
    for provider in PROVIDERS:
        for key, value in provider.details(name).items():
            out.setdefault(key, value)
    return out


# ── States ───────────────────────────────────────────────────────────────────

#: The last measured state per route name: (when, state).
_LAST: dict[str, tuple[float, dict[str, Any]]] = {}
_LAST_LOCK = threading.Lock()


def forget_states() -> None:
    """New routes, new states — nothing remembered carries over."""
    with _LAST_LOCK:
        _LAST.clear()


def status(route: Route) -> dict[str, Any]:
    """Measure one route now, through its provider, and remember the answer."""
    owner = _owner(route)
    if owner is None:
        s: dict[str, Any] = {"id": route.name, "state": "unreachable", "why": "gone", "ms": None}
    else:
        try:
            s = dict(owner.status(route))
        except Exception as err:
            s = {"id": route.name, "state": "unreachable", "why": type(err).__name__, "ms": None}
    with _LAST_LOCK:
        _LAST[route.name] = (time.monotonic(), s)
    return s


def statuses(routes: list[Route], max_age_s: float = FRESH_S) -> list[dict[str, Any]]:
    """The state of several routes: remembered when fresh, otherwise measured —
    **in parallel**, so the slowest route sets the pace, not the sum of all."""
    now = time.monotonic()
    with _LAST_LOCK:
        cached = {r.name: _LAST.get(r.name) for r in routes}
    stale = [r for r in routes if (c := cached[r.name]) is None or now - c[0] > max_age_s]
    measured: dict[str, dict[str, Any]] = {}
    if stale:
        with ThreadPoolExecutor(max_workers=min(8, len(stale))) as pool:
            for r, s in zip(stale, pool.map(status, stale), strict=True):
                measured[r.name] = s
    out = []
    for r in routes:
        c = cached[r.name]
        out.append(measured[r.name] if c is None or r.name in measured else c[1])
    return out


def _knock(route: Route, patience_s: float) -> dict[str, Any]:
    """Whether a proxy answers: a connection to its port, and for `http://` one
    `HEAD` addressed to the proxy itself.

    Nothing goes out through the proxy — any HTTP answer, even an error, shows
    that a proxy listens there. `ms` is the time to connect.
    """
    parts = urlsplit(route.proxy_url)
    host = parts.hostname or ""
    port = parts.port or (443 if parts.scheme == "https" else 80)
    begun = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=patience_s) as conn:
            ms = int((time.monotonic() - begun) * 1000)
            if parts.scheme == "https":
                return {"state": "running", "ms": ms, "public_ip": None}
            conn.settimeout(patience_s)
            conn.sendall(f"HEAD / HTTP/1.0\r\nHost: {host}\r\n\r\n".encode("ascii", "replace"))
            first = conn.recv(16)
    except OSError as err:
        return {"state": "unreachable", "why": type(err).__name__, "ms": None, "public_ip": None}
    if first.startswith(b"HTTP/"):
        return {"state": "running", "ms": ms, "public_ip": None}
    return {"state": "stopped", "why": "no HTTP answer", "ms": ms, "public_ip": None}


def _after_fork_in_child() -> None:
    """A lock held by another thread at the fork would stay held in the child."""
    global _LAST_LOCK
    _LAST_LOCK = threading.Lock()


if hasattr(os, "register_at_fork"):
    os.register_at_fork(after_in_child=_after_fork_in_child)
