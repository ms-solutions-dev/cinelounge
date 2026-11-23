"""Network — the routes, their state, and the portals that take them.

A route is a named HTTP proxy (`portalworks/routes.py`). The answers keep the
field names the apps and the console already read: a route is listed under
`exits`, a portal's route is its `exit_net`.

**Measured when the view opens, not on every `/health`.** Each route is a
knock on a proxy; one that is down waits for its timeout. That belongs to the
view that asks for it, not to the status strip every browser polls.
"""

from __future__ import annotations

import json
import time
from typing import Annotated, Any, Final

from fastapi import APIRouter, Body, Request

from cinelounge.core import errors as f
from cinelounge.portalworks import routes
from cinelounge.portalworks.runner import call as runner
from cinelounge.web import extension
from cinelounge.web.access import Admin, Services, services

router = APIRouter(prefix="/network")

#: Settings key for the proxies saved in the console: a JSON object
#: `{name: address}`. Underscores, not dots, like the other settings keys.
SAVED_KEY: Final = "network_proxies"


def _saved(d: Services) -> dict[str, str]:
    try:
        raw = json.loads(d.store.read(SAVED_KEY, "") or "{}")
    except ValueError:
        return {}
    return {str(k): str(v) for k, v in raw.items()} if isinstance(raw, dict) else {}


def load_saved(d: Services) -> None:
    """Lay the proxies saved in the console in — at startup, after the household
    is open. The registry reads again when there are any, so that a portal on
    a saved route is not broken for want of it."""
    found = routes.set_saved(_saved(d).items())
    if found:
        d.registry.reload()


@router.get("/exits")
def list_exits(request: Request, _: Admin) -> dict[str, Any]:
    """Every route with its state — and the portals that take it, or would if
    it existed.

    **`without_exit` is the list that matters.** A portal laid onto a route
    nobody offers is `broken` in the registry; here it stands under the
    routes, so the operator sees the route that is missing instead of a
    broken portal with no obvious cause.
    """
    d = services(request)
    portals = list(d.registry.manifests.values())
    out = []
    current = routes.all_routes()
    for r, state in zip(current, routes.statuses(current), strict=True):
        out.append(
            {
                **state,
                "portals": sorted(m.id for m in portals if m.exit_net == r.name),
                **routes.details(r.name),
            }
        )
    homeless = sorted((m.id, m.exit_net) for m in portals if routes.missing(m))
    answer: dict[str, Any] = {
        "exits": out,
        "without_exit": [{"id": pid, "net": net} for pid, net in homeless],
    }
    # What extensions report about the network, never over a core field.
    for key, value in extension.network_fields().items():
        answer.setdefault(key, value)
    return answer


@router.put("/exits")
def save_proxy(
    request: Request,
    person: Admin,
    name: Annotated[str, Body(embed=True)],
    address: Annotated[str, Body(embed=True)],
) -> dict[str, Any]:
    """Save a proxy as a route — or change the address of one saved before.

    `name` is how portals refer to it (`a-z`, `0-9`, `-`); `address` is
    `http://host:port`, with user and password if the proxy wants them. The
    address never leaves through the API again: lists show `host:port`.
    A name that `CL_PROXIES` or an extension already offers is taken.
    """
    d = services(request)
    route = routes.parse_proxy(name, address)
    if route is None:
        raise f.Error("network.bad_route", {"net": name.strip().lower()}, status=422)
    if routes.source_of(route.name) not in (None, "console"):
        raise f.Error("network.route_taken", {"net": route.name}, status=409)
    wish = _saved(d)
    wish[route.name] = route.proxy_url
    d.store.write(SAVED_KEY, json.dumps(wish, sort_keys=True))
    routes.set_saved(wish.items())
    d.registry.reload()
    d.events.record("event.route_saved", {"route": route.name}, person.id)
    return list_exits(request, person)


@router.delete("/exits/{exit_id}")
def remove_proxy(request: Request, exit_id: str, person: Admin) -> dict[str, Any]:
    """Remove a proxy saved in the console.

    Portals laid onto it stay laid onto it and are `broken` until the route is
    back or the operator chooses another — the same rule as everywhere.
    """
    d = services(request)
    wish = _saved(d)
    if exit_id not in wish:
        if routes.exists(exit_id):
            raise f.Error("network.route_taken", {"net": exit_id}, status=409)
        raise f.Error("network.no_exit", {"net": exit_id}, status=404)
    del wish[exit_id]
    d.store.write(SAVED_KEY, json.dumps(wish, sort_keys=True))
    routes.set_saved(wish.items())
    d.registry.reload()
    d.events.record("event.route_removed", {"route": exit_id}, person.id)
    return list_exits(request, person)


@router.post("/exits/{exit_id}/probe")
def probe_exit(request: Request, exit_id: str, _: Admin) -> dict[str, Any]:
    """Try every portal that takes this route — menu and first page.

    Each portal's menu and its first listing through the route, a few seconds
    a piece. A failure shows up with its code and, where the portal named one,
    the host. `direct` is the house's own connection.

    Runs in the request, deliberately: a handful of portals, and whoever
    pressed the button is looking at the answer.
    """
    d = services(request)
    if exit_id != routes.DIRECT and not routes.exists(exit_id):
        raise f.Error("network.no_exit", {"net": exit_id}, status=404)
    target = routes.get(exit_id)
    if target is not None:
        routes.status(target)  # measured now, so the card shows today's state
    checked = []
    for m in d.registry.manifests.values():
        if m.exit_net != exit_id or not m.is_ready:
            continue
        if not d.visibility.is_on(m.id, m.on_by_default):
            continue
        began = time.monotonic()
        try:
            entries = runner.call(m, "menu") or []
            if entries:
                runner.call(m, "listing", {"entry": entries[0]["id"]})
            checked.append(
                {"portal": m.id, "ok": True, "ms": int((time.monotonic() - began) * 1000)}
            )
        except f.Error as err:
            checked.append(
                {
                    "portal": m.id,
                    "ok": False,
                    "code": err.code,
                    "host": str(err.values.get("host") or ""),
                    "text": str(err.values.get("text") or err.values.get("why") or "")[:160],
                    "ms": int((time.monotonic() - began) * 1000),
                }
            )
    return {"exit": exit_id, "checked": checked, **routes.details(exit_id)}
