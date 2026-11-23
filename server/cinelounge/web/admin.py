"""What the household admin may change.

**Separate from `main.py`, because writing happens here.** Everything in this
file demands a right; nothing here is readable without a role having been
checked. Standing among the read routes, the one line gets overlooked at the
next addition.

**The check sits in the dependency, not in the body.** `Admin` in the signature
is the lock; an `if person.role == …` in the code would be one you can forget.
"""

from __future__ import annotations

from typing import Annotated, Any, Final

from fastapi import APIRouter, Body, Depends, Request

from cinelounge.core import errors as f
from cinelounge.household import backup as household_backup
from cinelounge.household.joins import JoinRequest
from cinelounge.household.people import RIGHTS, Person, resolve_role
from cinelounge.household.roles import APP_RIGHTS
from cinelounge.market import install as market_install
from cinelounge.market import trust as market_trust
from cinelounge.portalworks import extension as registries
from cinelounge.portalworks import routes
from cinelounge.portalworks.manifest import NET_OVERRIDE_KEY, Manifest
from cinelounge.portalworks.runner import fork
from cinelounge.web import nightwatch
from cinelounge.web.access import Admin, Anyone, Installer, Services, requires, services

router = APIRouter(prefix="/household")

#: Who may switch portals. A right of its own, not `change_settings` — the two
#: should be separable later without routes having to move.
PortalSwitcher = Annotated[Person, Depends(requires("switch_portals"))]
AccessSetter = Annotated[Person, Depends(requires("change_access"))]
DevicePairer = Annotated[Person, Depends(requires("pair_devices"))]


# ── Portals: on, off, and for whom ───────────────────────────────────────────


#: How a settings key is recognised as a secret.
#:
#: A naming rule and not a marker in the manifest — that would come from whoever
#: wrote the portal, and they forgot it on the password field. Better one value
#: withheld too many than one too few.
_GEHEIME_TEILE: Final = ("pass", "pwd", "secret", "token", "key", "schluessel", "api")


def _geheim(key: str) -> bool:
    k = key.lower()
    return any(part in k for part in _GEHEIME_TEILE)


@router.get("/portals")
def all_portals(request: Request, _: PortalSwitcher) -> dict[str, Any]:
    """**All** portals — the switched-off and the broken ones too.

    The difference to `/portals`: that one is a viewer's view, this one
    administration's. The admin has to see a broken portal, otherwise they go
    looking for it in the file system.
    """
    d = services(request)
    people = d.people.list_all()
    roles = d.roles.list_all()
    allowed = {p.id: d.visibility.allowed_for(p.id) for p in people}
    # **Who sees it, computed here and not in the browser** (AP90). The console
    # used to rebuild the rule and ignored readiness; now it shows the server's
    # decision per person, with the reason against it.
    who = d.access.for_everyone(people, d.registry.manifests.values())
    role_who = d.access.for_roles(roles, d.registry.manifests.values())
    out = []
    for m in d.registry.manifests.values():
        out.append(
            {
                **m.as_json(),
                "on": d.visibility.is_on(m.id, m.on_by_default),
                "allowed_for": sorted(pid for pid in allowed if m.id in allowed[pid]),
                # Since 09.11.2026 the role decides; `allowed_for` is derived.
                "roles": [r.id for r in roles if m.id in r.portals],
                "who": {pid: e.as_json() for pid, e in who[m.id].items()},
                "role_who": {rid: e.as_json() for rid, e in role_who[m.id].items()},
                # Origin and own settings — what the detail page shows.
                #
                # **A secret's value does not go out.** A portal may carry a key
                # in `settings` (an API key, an account password); whoever passes
                # everything through here puts it in the answer of a route every
                # admin browser calls — and into every cache along the way. The
                # interface does not need the value: it shows THAT something is
                # stored.
                "source": m.folder.name if m.folder else None,
                # Version and checksum when it came from the marketplace;
                # empty when it was put there by hand (rebuild 09.11.2026).
                "origin": market_install.origin(m.id, d.registry.root),
                "settings": [
                    {
                        "key": str(e.get("key", "")),
                        "label": str(e.get("label") or e.get("key", "")),
                        "value": ("gesetzt" if str(e.get("value") or "") else "")
                        if _geheim(str(e.get("key", "")))
                        else str(e.get("value") or ""),
                        "secret": _geheim(str(e.get("key", ""))),
                        # Whether the portal runs at all without this
                        # value. The detail page sets the "required" mark from
                        # it — otherwise an empty field looks like a nicety.
                        "required": bool(e.get("required")),
                    }
                    for e in m.settings
                    if e.get("key")
                ],
            }
        )
    out.sort(key=lambda x: (not x["on"], x["name"].lower()))
    return {
        "portals": out,
        "people": [_person_json(p) for p in people],
        "roles": [r.as_json() for r in roles],
    }


def _person_json(p: Person) -> dict[str, Any]:
    """A person as every admin answer shows them — old fields and new."""
    return {
        "id": p.id,
        "name": p.name,
        "role": p.role,
        "role_id": p.role_id,
        "console": p.console,
        "color": p.color,
        "adult": p.adult,
    }


@router.post("/portals/{portal_id}/switch")
def switch_portal(
    request: Request,
    portal_id: str,
    person: PortalSwitcher,
    on: Annotated[bool, Body(embed=True)],
    roles: Annotated[list[str] | None, Body(embed=True)] = None,
) -> dict[str, Any]:
    """Switch a portal on or off for the whole household.

    **`roles` adds the portal to these roles in the same step** (AP90). Until
    then "on" put the portal into no role, and a portal could stand on "on"
    while nobody saw it. The answer says how many people see it now
    (`who_sees`); with `0` after switching on, the console asks which roles
    should get it and sends the call again with `roles`.

    Adding needs `change_access` on top — the same right the role page asks
    for. Roles are only added here, never taken away.
    """
    d = services(request)
    m = d.registry.manifests.get(portal_id)
    if m is None:
        raise f.Error(f.PORTAL_UNKNOWN, {"id": portal_id}, status=404)
    wanted = _checked_roles(d, person, portal_id, roles or [])
    with d.store.connect(immediate=True) as v:
        v.execute(
            "INSERT INTO portal_switch (portal_id, on_air) VALUES (?, ?) "
            "ON CONFLICT(portal_id) DO UPDATE SET on_air = excluded.on_air",
            (portal_id, int(on)),
        )
        v.executemany(
            "INSERT OR IGNORE INTO role_portal (role_id, portal_id) VALUES (?, ?)",
            [(r, portal_id) for r in wanted],
        )
    d.events.record("event.portal_switched", {"portal": portal_id, "on": on}, person.id)
    for role_id in wanted:
        r = d.roles.by_id(role_id)
        d.events.record(
            "event.role_portal_changed",
            {"role": r.name if r else role_id, "portal": portal_id, "on": True},
            person.id,
        )
    return {"id": portal_id, "on": on, "who_sees": _who_sees(d, m)}


def _who_sees(d: Services, m: Manifest) -> int:
    """How many people the rules let see this portal, broken or not.

    Broken counts as seen: the question behind it is "did anybody get the
    portal", and a missing exit is answered in the chain, not by asking for
    roles again.
    """
    people = d.people.list_all()
    return sum(1 for e in d.access.for_everyone(people, [m])[m.id].values() if e.permitted)


def _checked_roles(d: Services, person: Person, portal_id: str, roles: list[str]) -> list[str]:
    """The roles a portal should go into — known, allowed, before anything is written."""
    if not roles:
        return []
    if not person.may("change_access"):
        raise f.Error(f.AUTH_FORBIDDEN, {"right": "change_access", "role": person.role}, status=403)
    wanted = sorted(set(roles))
    for role_id in wanted:
        if d.roles.by_id(role_id) is None:
            raise f.Error("role.unknown", {"id": role_id}, status=404)
        _refuse_adult_for_locked(d, role_id, [portal_id])
    return wanted


@router.delete("/portals/{portal_id}")
def remove_portal(
    request: Request,
    portal_id: str,
    person: PortalSwitcher,
) -> dict[str, Any]:
    """Take a portal out of the house — **folder and all.**

    **There is no wastebasket, and that is the honest answer.** A portal that
    only disappears from the list still lies on the disk, takes up space and
    comes back at the next read. The operator would then have removed something
    that is still there.

    What **stays** is the progress: whoever watched half the season watched it.
    If the same portal comes back from the marketplace later, it finds its keys
    again (`portal:title:year`) — which is why nothing is deleted from
    `progress` here.

    The switch and the permissions go along: otherwise they point at a portal
    that no longer exists.
    """
    import shutil

    d = services(request)
    m = d.registry.manifests.get(portal_id)
    if m is None:
        raise f.Error(f.PORTAL_UNKNOWN, {"id": portal_id}, status=404)

    folder = m.folder
    # **The folder has to lie under the portals folder.** A manifest is a file
    # somebody else wrote; a `folder` outside would be a delete command for an
    # arbitrary path.
    #
    # The root comes from the **registry** and not from the environment: a
    # `DATA` out of `os.environ` is fixed at import time, and in the tests the
    # folder moves per case. Measured: the test passed alone and failed in the
    # suite.
    root = d.registry.root.resolve()
    try:
        ziel = folder.resolve()
        ziel.relative_to(root)
    except (ValueError, OSError):
        raise f.Error("portal.outside_data", {"id": portal_id}, status=409) from None

    shutil.rmtree(ziel, ignore_errors=False)
    d.visibility.set_on(portal_id, False)
    with d.store.connect() as v:
        v.execute("DELETE FROM visibility WHERE portal_id = ?", (portal_id,))
        v.execute("DELETE FROM portal_switch WHERE portal_id = ?", (portal_id,))
        v.execute("DELETE FROM role_portal WHERE portal_id = ?", (portal_id,))
    d.registry.reload()
    d.events.record("event.portal_removed", {"portal": portal_id}, person.id)
    return {"removed": portal_id, "folder": str(ziel), "progress_kept": True}


@router.put("/portals/{portal_id}/settings")
def write_portal_settings(
    request: Request,
    portal_id: str,
    person: PortalSwitcher,
    settings: Annotated[dict[str, str], Body(embed=True)],
) -> dict[str, Any]:
    """Set a portal's settings — an API key, for instance.

    **Why this is needed.** The detail page showed settings already, but there
    was no way to set one. For a portal with a required API key that meant: it
    cannot play a single item without the key, reports that honestly as
    `broken` — and the operator could only have entered the key over the
    command line. An honest error message without a way to fix it is half the
    work.

    **Only keys the manifest already carries.** Whoever could write arbitrary
    pairs here could slip settings into a foreign portal its author never
    foresaw. The unknown is an error, not silence — the same rule as when
    reading the manifest.

    **Writing goes into the household, not into the `portal.yml`.** The first
    attempt wrote back into the manifest file, and that was wrong twice:
    `yaml.safe_dump` ate the file's comment header, and with E4 the portal
    folder is pinned by `sha256` — a value in it does not survive the next
    version. The manifest belongs to the author, the value to the operator.

    Afterwards the registry reads anew and lays the stored values over the
    author's: a portal that was `broken` only because of an empty required field
    is `ready` again with the same call.
    """
    d = services(request)
    m = d.registry.manifests.get(portal_id)
    if m is None:
        raise f.Error(f.PORTAL_UNKNOWN, {"id": portal_id}, status=404)

    known = {str(e.get("key")) for e in m.settings if e.get("key")}
    unknown = sorted(set(settings) - known)
    if unknown:
        raise f.Error("settings.unknown_key", {"keys": unknown, "portal": portal_id}, status=422)

    for key, value in settings.items():
        d.store.set_portal_setting(portal_id, key, value)
    d.registry.reload()

    # **The keys, not the values.** A log that writes the API key along is
    # a second place where it stands — and the less conspicuous of the two.
    d.events.record(
        "event.portal_settings",
        {"portal": portal_id, "keys": ", ".join(sorted(settings))},
        person.id,
    )

    frisch = d.registry.manifests.get(portal_id)
    return {
        "portal": portal_id,
        "written": sorted(settings),
        "state": frisch.state if frisch else "broken",
        "reason": (frisch.broken_reason if frisch else None),
        "missing_settings": list(frisch.missing_settings) if frisch else [],
    }


@router.post("/portals/{portal_id}/net")
def set_portal_net(
    request: Request,
    portal_id: str,
    person: PortalSwitcher,
    net: Annotated[str, Body(embed=True)],
) -> dict[str, Any]:
    """Lay a portal onto a route — or take the operator's choice back.

    `net` is the name of a route (`portalworks/routes.py`), `direct` for "the
    house's own connection, whatever the default", or empty to hand the
    decision back to the default. **Only a route that exists**: one nobody set
    up would make the portal `broken` with the next reload, and a switch that
    breaks what it switches is worse than a 422 here.

    Household, not manifest — the same reason as for the settings above: the
    author's file is pinned by checksum, the operator's choice must survive
    the next version.
    """
    d = services(request)
    m = d.registry.manifests.get(portal_id)
    if m is None:
        raise f.Error(f.PORTAL_UNKNOWN, {"id": portal_id}, status=404)
    wish = net.strip().lower()
    if wish and wish != routes.DIRECT and not routes.exists(wish):
        raise f.Error(routes.reject(wish) or "network.no_exit", {"net": wish}, status=422)
    d.store.set_portal_setting(portal_id, NET_OVERRIDE_KEY, wish)
    d.registry.reload()
    d.events.record("event.portal_net", {"portal": portal_id, "net": wish or "manifest"}, person.id)
    frisch = d.registry.manifests.get(portal_id)
    # The manifest fields an extension publishes (`FieldSpec.public_json`)
    # come along, as in every other answer about the portal.
    published = {
        s.key: frisch.extras.get(s.key) if frisch else None
        for s in registries.FIELDS
        if s.public_json
    }
    return {
        "portal": portal_id,
        **published,
        "net_override": frisch.net_override if frisch else None,
        "exit_net": frisch.exit_net if frisch else None,
        "state": frisch.state if frisch else "broken",
        "reason": (frisch.broken_reason if frisch else None),
        "missing_settings": list(frisch.missing_settings) if frisch else [],
    }


@router.post("/people/{user_id}/access")
def set_access(
    request: Request,
    user_id: str,
    wer: AccessSetter,
    portal: Annotated[str, Body(embed=True)],
    allowed: Annotated[bool, Body(embed=True)],
) -> dict[str, Any]:
    """Grant a portal to **one** person or take it away.

    The age lock stays above it: granting an 18+ portal to a child's profile
    changes nothing — `web/portals.py` refuses all the same. That is why the
    answer here says what actually holds.
    """
    d = services(request)
    person = d.people.by_id(user_id)
    if person is None:
        raise f.Error("household.unknown_person", {"id": user_id}, status=404)
    m = d.registry.manifests.get(portal)
    if m is None:
        raise f.Error(f.PORTAL_UNKNOWN, {"id": portal}, status=404)
    if allowed and person.role_id:
        _refuse_adult_for_locked(d, person.role_id, [portal])
    d.visibility.set_allowed(user_id, portal, allowed)
    d.events.record(
        "event.access_changed",
        {"portal": portal, "person": person.name, "allowed": allowed},
        wer.id,
    )
    return {
        "person": user_id,
        "portal": portal,
        "allowed": allowed,
        "effective": d.access.check(person, m).permitted,
    }


# ── Marketplace ──────────────────────────────────────────────────────────────
#
# **There is no official index.** Whoever enters a source here decides for
# themselves who they believe — the service keeps no directory of foreign
# content, it fetches what it is told and says honestly what it checked.


@router.get("/market/sources")
def list_sources(request: Request, _: Installer) -> dict[str, Any]:
    """The entered sources and the stored trust anchors."""
    d = services(request)
    return {
        "sources": [
            {
                "url": q.url,
                "name": q.name,
                "added": q.added,
                "last_fetch": q.last_fetch,
                "last_error": q.last_error,
                # **How old the cache is belongs with it.** An empty cache
                # and a stale one are two different things, and the interface
                # has to be able to say both.
                "stale_s": q.stale_s,
                "cached": bool(q.cached),
            }
            for q in d.sources.list_all()
        ],
        "anchors": [
            {"fingerprint": a.fingerprint, "name": a.name, "added": a.added}
            for a in d.trust.list_all()
        ],
    }


@router.post("/market/sources")
def add_source(
    request: Request,
    person: Installer,
    url: Annotated[str, Body(embed=True)],
    name: Annotated[str, Body(embed=True)] = "",
) -> dict[str, Any]:
    """Enter a source."""
    d = services(request)
    q = d.sources.add(url, name)
    d.events.record("event.source_added", {"url": q.url, "name": q.name}, person.id)
    return {"url": q.url, "name": q.name}


@router.delete("/market/sources")
def remove_source(
    request: Request, person: Installer, url: Annotated[str, Body(embed=True)]
) -> dict[str, Any]:
    """Remove a source. Installed portals stay where they are.

    **Removing them would be the wrong conclusion**: a portal that runs keeps
    running — what falls away is the way to the next version.
    """
    d = services(request)
    weg = d.sources.remove(url)
    if weg:
        d.events.record("event.source_removed", {"url": url}, person.id)
    return {"removed": weg}


@router.post("/market/anchors")
def add_anchor(
    request: Request,
    person: Installer,
    public_key: Annotated[str, Body(embed=True)],
    name: Annotated[str, Body(embed=True)] = "",
) -> dict[str, Any]:
    """Store a trust anchor."""
    d = services(request)
    a = d.trust.add(public_key, name)
    d.events.record("event.anchor_added", {"fingerprint": a.fingerprint, "name": a.name}, person.id)
    return {"fingerprint": a.fingerprint, "name": a.name}


@router.delete("/market/anchors/{fingerprint}")
def remove_anchor(request: Request, fingerprint: str, person: Installer) -> dict[str, Any]:
    """Withdraw an anchor.

    What was signed with it reads `unsigned` afterwards — not `bad`. The
    difference counts: the signature was not wrong, this household simply no
    longer believes the signer.
    """
    d = services(request)
    weg = d.trust.remove(fingerprint)
    if weg:
        d.events.record("event.anchor_removed", {"fingerprint": fingerprint}, person.id)
    return {"removed": weg}


@router.get("/market")
def browse_market(request: Request, _: Installer) -> dict[str, Any]:
    """What the sources offer — with a trust level per entry.

    **Nothing is downloaded here.** The index names addresses and checksums;
    whether a file lies behind one is decided at install time. A marketplace
    that downloads while merely displaying fetches an archive for every tile.
    """
    d = services(request)
    eintraege, klagen = d.sources.fetch_all()

    drin = set(d.registry.manifests)
    heraus = []
    for e in eintraege:
        stufe, abdruck = d.trust.check(e)
        herkunft = market_install.origin(e["id"], d.registry.root)
        heraus.append(
            {
                **e,
                "trust": stufe,
                "signed_by": abdruck,
                # What already stands there — and whether it is the same version.
                "installed": e["id"] in drin,
                "installed_version": herkunft.get("version", ""),
                "same_version": herkunft.get("sha256", "") == e["sha256"],
            }
        )
    return {"portals": heraus, "complaints": klagen}


@router.post("/market/install")
def install_portal(
    request: Request,
    person: Installer,
    portal: Annotated[str, Body(embed=True)],
    source: Annotated[str, Body(embed=True)] = "",
    allow_unsigned: Annotated[bool, Body(embed=True)] = False,
    roles: Annotated[list[str] | None, Body(embed=True)] = None,
    on: Annotated[bool | None, Body(embed=True)] = None,
) -> dict[str, Any]:
    """Install a portal from the marketplace.

    **`roles` and `on` in the same call** (AP90). The console used to send
    three requests from the browser — install, every role, the switch — and a
    failure halfway left a portal installed for nobody. Now the roles are
    checked before anything is fetched, and after the install the switch and
    the role list are written in one transaction. `roles` is the complete
    list: roles not in it lose the portal, as the dialog's switches said.
    Without `roles` and `on` nothing about access changes.

    **`allow_unsigned` has to come explicitly**, and `bad` does not get through
    even with it. The difference is the whole point: a portal without a
    signature is one nobody vouched for — whoever wants it anyway says so. A
    portal with a wrong signature is an attack or a fault, and there is no
    switch for that.
    """
    d = services(request)
    eintraege, _ = d.sources.fetch_all()
    passend = [e for e in eintraege if e["id"] == portal and (not source or e["source"] == source)]
    if not passend:
        raise f.Error("market.unknown_portal", {"id": portal}, status=404)
    if len(passend) > 1:
        # **Two sources, the same portal.** The service does not decide that
        # for the operator — it says that there is something to decide.
        raise f.Error(
            "market.ambiguous",
            {"id": portal, "sources": ", ".join(sorted(e["source"] for e in passend))},
            status=409,
        )

    e = passend[0]
    if roles is not None:
        if not person.may("change_access"):
            raise f.Error(
                f.AUTH_FORBIDDEN, {"right": "change_access", "role": person.role}, status=403
            )
        for role_id in sorted(set(roles)):
            if d.roles.by_id(role_id) is None:
                raise f.Error("role.unknown", {"id": role_id}, status=404)
            if e.get("adult"):
                _refuse_adult_for_locked_ids(d, role_id, portal)
    if on is not None and not person.may("switch_portals"):
        raise f.Error(
            f.AUTH_FORBIDDEN, {"right": "switch_portals", "role": person.role}, status=403
        )
    stufe, abdruck = d.trust.check(e)
    if stufe == market_trust.BAD:
        raise f.Error("market.bad_signature", {"id": portal}, status=409)
    if stufe == market_trust.UNSIGNED and not allow_unsigned:
        raise f.Error("market.unsigned", {"id": portal}, status=409)

    roh = market_install.fetch_archive(e["url"], e["sha256"])
    fertig = market_install.install(roh, portal, e["version"], e["sha256"], d.registry.root)
    d.registry.reload()
    d.pin_switches()
    d.events.record(
        "event.portal_installed",
        {"portal": portal, "version": e["version"], "trust": stufe},
        person.id,
    )
    m = d.registry.manifests.get(portal)
    if roles is not None or on is not None:
        if m is not None and roles is not None:
            # The manifest is read now; what the index said is checked again.
            for role_id in roles:
                _refuse_adult_for_locked(d, role_id, [portal])
        _set_access_once(d, person, portal, roles, on)
    return {
        "portal": portal,
        "version": fertig.version,
        "trust": stufe,
        "signed_by": abdruck,
        "rollback_available": fertig.replaced,
        "on": d.visibility.is_on(portal, bool(m and m.on_by_default)),
        "who_sees": _who_sees(d, m) if m is not None else 0,
    }


def _refuse_adult_for_locked_ids(d: Services, role_id: str, portal_id: str) -> None:
    """`_refuse_adult_for_locked` for a portal not installed yet (the index says 18+)."""
    r = d.roles.by_id(role_id)
    if r is not None and r.child_lock:
        raise f.Error("role.child_locked", {"id": role_id, "portals": [portal_id]}, status=409)


def _set_access_once(
    d: Services, person: Person, portal_id: str, roles: list[str] | None, on: bool | None
) -> None:
    """Switch and role list in one transaction — all of it or nothing."""
    vorher: set[str] = set()
    with d.store.connect(immediate=True) as v:
        if on is not None:
            v.execute(
                "INSERT INTO portal_switch (portal_id, on_air) VALUES (?, ?) "
                "ON CONFLICT(portal_id) DO UPDATE SET on_air = excluded.on_air",
                (portal_id, int(on)),
            )
        if roles is not None:
            vorher = {
                str(z["role_id"])
                for z in v.execute(
                    "SELECT role_id FROM role_portal WHERE portal_id = ?", (portal_id,)
                )
            }
            v.execute("DELETE FROM role_portal WHERE portal_id = ?", (portal_id,))
            v.executemany(
                "INSERT INTO role_portal (role_id, portal_id) VALUES (?, ?)",
                [(r, portal_id) for r in sorted(set(roles))],
            )
    if on is not None:
        d.events.record("event.portal_switched", {"portal": portal_id, "on": on}, person.id)
    if roles is not None:
        for role_id in sorted(vorher ^ set(roles)):
            r = d.roles.by_id(role_id)
            d.events.record(
                "event.role_portal_changed",
                {"role": r.name if r else role_id, "portal": portal_id, "on": role_id in roles},
                person.id,
            )


@router.post("/market/rollback")
def rollback_portal(
    request: Request, person: Installer, portal: Annotated[str, Body(embed=True)]
) -> dict[str, Any]:
    """Bring a portal's previous version back."""
    d = services(request)
    zurueck = market_install.rollback(portal, d.registry.root)
    if not zurueck:
        raise f.Error("market.no_rollback", {"id": portal}, status=409)
    d.registry.reload()
    d.pin_switches()
    herkunft = market_install.origin(portal, d.registry.root)
    d.events.record(
        "event.portal_rolled_back",
        {"portal": portal, "version": herkunft.get("version", "")},
        person.id,
    )
    return {"portal": portal, "version": herkunft.get("version", "")}


# ── Nightly run ──────────────────────────────────────────────────────────────
#
# **Curation without a curator.** A marketplace without a central directory has
# no committee vetting portals. What it can have is a measurement: a portal that
# has played nothing for three nights says so itself.


@router.get("/nights")
def nights(request: Request, person: Anyone) -> dict[str, Any]:
    """The strips per portal and the last reason.

    **For everybody signed in, not only the admin.** Whether a portal carries is
    not administrative information — it is the answer to "why does this not
    work", and that should not depend on who asks. The reasons name error codes
    and no credentials.

    **But only for portals the person may see** (gap L1, AP90, 16.11.2026).
    The answer named every portal that ever ran, 18+ and switched-off ones
    included, to a borrowed child's profile as well. Whoever runs the console
    sees all of them; everybody else gets the portals their rules allow,
    broken ones included — a fault is exactly what this route explains.
    """
    d = services(request)
    alles = d.nights.as_json()
    borrowed = getattr(request.state, "borrowed", False)
    if person.may("change_settings") and not borrowed:
        return alles
    keep = {m.id for m in d.access.permitted(person, d.registry.manifests.values())}
    for feld in ("history", "last", "failures"):
        alles[feld] = {k: v for k, v in alles.get(feld, {}).items() if k in keep}
    return alles


@router.post("/nights/run")
def run_nights(
    request: Request, person: Admin, portal: Annotated[str | None, Body(embed=True)] = None
) -> dict[str, Any]:
    """Run the nightly pass now instead of waiting for four o'clock.

    **It runs inside the request and not in the background**, and that is
    deliberate: whoever starts it by hand wants to see the result. With eleven
    portals and twenty seconds of pause between them that takes a few minutes —
    which is why `gap_s=0` stands here, and the consideration for memory applies
    only to the run nobody ordered.
    """
    d = services(request)
    if portal is not None and portal not in d.registry.manifests:
        raise f.Error(f.PORTAL_UNKNOWN, {"id": portal}, status=404)
    # One portal: the "check now" button on its page (rebuild 09.11.2026).
    ergebnis = nightwatch.run_once(
        d.registry, d.nights, events=d.events, switch=d.visibility, gap_s=0.0, only=portal
    )
    d.events.record(
        "event.nights_run",
        {
            "carried": len(ergebnis.get("carried") or []),
            "failed": len(ergebnis.get("failed") or []),
        },
        person.id,
    )
    return ergebnis


# ── Event book ───────────────────────────────────────────────────────────────


@router.get("/events")
def read_events(request: Request, _: Admin, limit: int = 40) -> dict[str, Any]:
    """What happened in the household — **not what somebody watched.**

    The line is drawn at the head of `household/events.py` and is the whole
    design: administrative acts yes, usage behaviour no.

    **For the admin only**, and that is no formality: the entries name names
    ("X granted Y"), and whoever may read them sees who decides what in the
    house.

    Codes and values, no sentences — the console builds the sentence from them,
    just as with the errors.
    """
    d = services(request)
    return {"events": d.events.recent(limit), "days": d.events._days()}


# ── People ───────────────────────────────────────────────────────────────────


@router.post("/people")
def create_person(
    request: Request,
    _: Admin,
    name: Annotated[str, Body(embed=True)],
    role: Annotated[str, Body(embed=True)] = "adult",
    pin: Annotated[str, Body(embed=True)] = "",
    color: Annotated[str, Body(embed=True)] = "#E2564A",
    console: Annotated[bool | None, Body(embed=True)] = None,
) -> dict[str, Any]:
    """Create a resident — with a role id (or an old role name).

    **Without PIN unless they get the console.** A person who only watches
    comes in through their profile's mark; a PIN is for the console.
    """
    d = services(request)
    p = d.people.create(name, role, pin.strip() or None, color, console)
    d.events.record("event.person_added", {"name": p.name, "role": p.role})
    return _person_json(p)


@router.delete("/people/{user_id}")
def remove_person(
    request: Request,
    user_id: str,
    person: Admin,
) -> dict[str, Any]:
    """Take a person out of the household.

    **The progress goes with them, and that is the real question.** Continue
    watching, favourites, permissions and this person's paired devices disappear
    (`ON DELETE CASCADE` in the schema). There is no wastebasket: a half-deleted
    resident would be a profile nobody sees whose devices still have access.

    That is why the interface asks in two steps, and the answer here says what
    actually went along.
    """
    if user_id == person.id:
        raise f.Error(f.HOUSEHOLD_NOT_YOURSELF, {"id": user_id}, status=409)

    d = services(request)
    path = d.people.by_id(user_id)
    if path is None:
        raise f.Error("household.unknown_person", {"id": user_id}, status=404)

    devices = [g.id for g in d.devices.list_all() if g.user_id == user_id]
    # **Write before removing.** `People.remove()` clears the name out of the
    # book afterwards — but the event itself should carry the name the person
    # had, otherwise an act without an object stands there.
    d.events.record("event.person_removed", {"name": path.name, "devices": len(devices)}, person.id)
    d.people.remove(user_id)
    return {"removed": user_id, "name": path.name, "devices": len(devices)}


@router.post("/people/{user_id}/pin")
def set_pin(
    request: Request,
    user_id: str,
    actor: Admin,
    pin: Annotated[str, Body(embed=True)],
    my_pin: Annotated[str | None, Body(embed=True)] = None,
) -> dict[str, Any]:
    """Set a person's PIN.

    **Without the old PIN**, and that is deliberate: a child who forgot theirs
    should not stay locked out. Whoever may do this is an admin anyway and would
    reach everything by other means too.

    `my_pin`, when sent, is checked first — the console asks for it (09.11.2026),
    so a browser left open is not enough to change a PIN.
    """
    d = services(request)
    if my_pin is not None:
        d.people.sign_in(actor.id, my_pin.strip())
    d.people.set_pin(user_id, pin)
    return {"ok": True}


@router.post("/people/{user_id}/role")
def set_role(
    request: Request,
    user_id: str,
    person: Admin,
    role: Annotated[str, Body(embed=True)],
) -> dict[str, Any]:
    """Change a person's role — the child's profile that turned eighteen.

    **Takes effect with the next request, on every device.** The role is read
    from the household on each call (`access.current_person`), never from the
    token, so no device has to sign in again — and a device that cached its
    `rights` merely shows the old picture until it asks again; the server
    refuses or allows by the new one either way.

    **Not for oneself**, and this time it is only half a lockout rule: an admin
    can only *lose* something here, and losing it mid-session would leave the
    console open on a screen it may no longer use. Same code as `remove`, same
    sentence in the console.
    """
    d = services(request)
    before = d.people.by_id(user_id)
    if before is None:
        raise f.Error("household.unknown_person", {"id": user_id}, status=404)
    p = d.people.set_role(user_id, role)
    if before.role_id != p.role_id:
        r = d.roles.by_id(p.role_id or "")
        d.events.record(
            "event.person_role_changed",
            {"name": p.name, "role": r.name if r else p.role},
            person.id,
        )
    return _person_json(p)


@router.post("/people/{user_id}/console")
def set_console(
    request: Request,
    user_id: str,
    actor: Admin,
    on: Annotated[bool, Body(embed=True)],
    my_pin: Annotated[str, Body(embed=True)],
    pin: Annotated[str | None, Body(embed=True)] = None,
) -> dict[str, Any]:
    """Console access on or off — with the PIN of whoever decides.

    **The decider's PIN, first.** Their device token never expires; letting
    somebody manage the household is exactly the act where "the device is
    signed in" is not enough. `pin` is the new person's own PIN, needed when
    they have none yet. The last person with access keeps it
    (`household.last_admin`).
    """
    d = services(request)
    d.people.sign_in(actor.id, my_pin.strip())
    p = d.people.set_console(user_id, on, (pin or "").strip() or None)
    d.events.record(
        "event.console_granted" if on else "event.console_revoked", {"name": p.name}, actor.id
    )
    return _person_json(p)


# ── Roles ────────────────────────────────────────────────────────────────────


@router.get("/members")
def list_members(request: Request, _: DevicePairer) -> dict[str, Any]:
    """Everybody in the household as the console needs them: role, console
    access, whether a PIN is set and whether a mark was issued. Devices come
    from `/household/devices` (`person`)."""
    d = services(request)
    with d.store.connect() as v:
        extra = {
            z["id"]: z
            for z in v.execute("SELECT id, pin_hash, mark IS NOT NULL AS has_mark FROM person")
        }
    out = []
    for p in d.people.list_all():
        z = extra.get(p.id)
        out.append(
            {
                **_person_json(p),
                "has_pin": bool(z and z["pin_hash"]),
                "has_mark": bool(z and z["has_mark"]),
            }
        )
    return {"people": out}


@router.get("/roles")
def list_roles(request: Request, _: AccessSetter) -> dict[str, Any]:
    """Every role with its rights, portals and how many people hold it."""
    d = services(request)
    n = d.roles.members()
    return {
        "roles": [r.as_json(n.get(r.id, 0)) for r in d.roles.list_all()],
        "rights": list(APP_RIGHTS),
    }


@router.post("/roles")
def create_role(
    request: Request,
    actor: AccessSetter,
    name: Annotated[str, Body(embed=True)],
    color: Annotated[str, Body(embed=True)] = "#c08cf5",
    rights: Annotated[list[str] | None, Body(embed=True)] = None,
    portals: Annotated[list[str] | None, Body(embed=True)] = None,
    child_lock: Annotated[bool, Body(embed=True)] = False,
) -> dict[str, Any]:
    """A new role. Without rights it may watch and remember progress.

    `child_lock`: a role for children (no "ab 18", no 18+ portal, ever,
    unless the lock is lifted with a PIN)."""
    d = services(request)
    wanted = portals or []
    if child_lock:
        wanted = [pid for pid in wanted if not _is_adult(d, pid)]
    r = d.roles.create(
        name, color, rights or ["watch", "track_progress"], wanted, child_lock=child_lock
    )
    d.events.record("event.role_created", {"role": r.name}, actor.id)
    return r.as_json()


@router.patch("/roles/{role_id}")
def update_role(
    request: Request,
    role_id: str,
    actor: AccessSetter,
    name: Annotated[str | None, Body(embed=True)] = None,
    color: Annotated[str | None, Body(embed=True)] = None,
    rights: Annotated[list[str] | None, Body(embed=True)] = None,
    portals: Annotated[list[str] | None, Body(embed=True)] = None,
) -> dict[str, Any]:
    """Change what was sent — and only that."""
    d = services(request)
    if portals is not None:
        _refuse_adult_for_locked(d, role_id, portals)
    r = d.roles.update(role_id, name=name, color=color, rights=rights, portals=portals)
    d.events.record("event.role_changed", {"role": r.name}, actor.id)
    return r.as_json(d.roles.members().get(r.id, 0))


@router.post("/roles/{role_id}/portals")
def set_role_portal(
    request: Request,
    role_id: str,
    actor: AccessSetter,
    portal: Annotated[str, Body(embed=True)],
    on: Annotated[bool, Body(embed=True)],
) -> dict[str, Any]:
    """One portal in or out of a role — what one switch in the console does."""
    d = services(request)
    if portal not in d.registry.manifests:
        raise f.Error(f.PORTAL_UNKNOWN, {"id": portal}, status=404)
    if on:
        _refuse_adult_for_locked(d, role_id, [portal])
    d.roles.set_portal(role_id, portal, on)
    r = d.roles.by_id(role_id)
    assert r is not None
    d.events.record(
        "event.role_portal_changed", {"role": r.name, "portal": portal, "on": on}, actor.id
    )
    return r.as_json(d.roles.members().get(r.id, 0))


def _is_adult(d: Services, portal_id: str) -> bool:
    m = d.registry.manifests.get(portal_id)
    return bool(m and m.adult)


def _refuse_adult_for_locked(d: Services, role_id: str, portals: list[str]) -> None:
    """An 18+ portal never goes into a role with the child lock (09.11.2026)."""
    r = d.roles.by_id(role_id)
    if r is not None and r.child_lock:
        adult = sorted(pid for pid in portals if _is_adult(d, pid))
        if adult:
            raise f.Error("role.child_locked", {"id": role_id, "portals": adult}, status=409)


@router.post("/roles/{role_id}/child_lock")
def set_child_lock(
    request: Request,
    role_id: str,
    actor: AccessSetter,
    on: Annotated[bool, Body(embed=True)],
    my_pin: Annotated[str | None, Body(embed=True)] = None,
) -> dict[str, Any]:
    """Lock a role for children, or lift the lock.

    **Locking is free, unlocking costs the PIN.** Making something safer
    needs no proof; making 18+ possible for a child's role does — a browser
    left open must not be enough.
    """
    d = services(request)
    if not on:
        if not my_pin:
            raise f.Error("role.child_lock_pin", status=422)
        d.people.sign_in(actor.id, my_pin.strip())
    adult = [m.id for m in d.registry.manifests.values() if m.adult]
    r = d.roles.set_child_lock(role_id, on, adult)
    d.events.record(
        "event.role_child_locked" if on else "event.role_child_unlocked", {"role": r.name}, actor.id
    )
    return r.as_json(d.roles.members().get(r.id, 0))


@router.delete("/roles/{role_id}")
def delete_role(request: Request, role_id: str, actor: AccessSetter) -> dict[str, Any]:
    """Delete a role nobody holds any more (`role.in_use` otherwise)."""
    d = services(request)
    r = d.roles.by_id(role_id)
    d.roles.delete(role_id)
    d.events.record("event.role_deleted", {"role": r.name if r else role_id}, actor.id)
    return {"deleted": role_id}


# ── Devices ──────────────────────────────────────────────────────────────────


# ── Backup ───────────────────────────────────────────────────────────────────


@router.get("/backup")
def backup(request: Request, _: Admin) -> dict[str, Any]:
    """The whole household as one file.

    **For the admin only, and that is no formality.** The answer contains every
    `pin_hash`, every device token and every stored portal key — whoever has it
    has the household. Why it is complete all the same stands in
    `household/backup.py`: a backup after which everybody has to pair again does
    not get used when it matters.

    The console hangs it off a `Content-Disposition` header; here it comes as
    JSON, so that `curl` and a timer can take the same path.
    """
    return household_backup.export(services(request).store)


@router.post("/restore")
def restore(
    request: Request,
    person: Admin,
    data: Annotated[dict[str, Any], Body()],
    replace: Annotated[bool, Body(embed=True)] = True,
) -> dict[str, Any]:
    """Restore a backup.

    **`replace` is deliberately the default.** A backup establishes a state, it
    does not mix itself in — two households on top of each other produce
    permissions nobody ever granted.

    Afterwards the household from the file holds, **including for whoever is
    calling right now**: if their own device is not in it, their token is
    worthless with the next call. That is right and belongs in the interface as
    a warning, not in an exception here.
    """
    d = services(request)
    written = household_backup.restore(d.store, data, replace=replace)
    # The registry reads portal values out of the household
    # (`portal_settings`). Without this follow-up a portal whose key just came
    # back would stay `broken` — and the other way round.
    d.registry.reload()
    # **After the restore, not before.** The book from the backup replaces the
    # running one; an entry written before would be overwritten with it, and the
    # act that overwrote it invisible.
    d.events.record("event.restored", {"tables": sum(written.values())}, person.id)
    return {"restored": written}


#: What the console offers when it makes a code (mockup: Apple TV, iPhone,
#: iPad, Browser). A device that redeems the code may still report its own,
#: finer kind — this is only the household's first guess for the icon.
DEVICE_KINDS: Final = ("tv", "phone", "tablet", "web")


@router.post("/devices/code")
def pairing_code(
    request: Request,
    _: DevicePairer,
    name: Annotated[str, Body(embed=True)] = "Device",
    kind: Annotated[str, Body(embed=True)] = "tv",
) -> dict[str, Any]:
    """Generate a pairing code to be typed in at the device."""
    if kind not in DEVICE_KINDS:
        raise f.Error("household.bad_device_kind", {"kinds": list(DEVICE_KINDS)}, status=422)
    name = " ".join(name.split())
    from_where = request.client.host if request.client else ""
    o = services(request).devices.request_code(name[:60] or "Device", kind, from_where)
    return {"code": o.token, "expires_in_s": round(o.remaining_s), "device": o.device_name}


@router.post("/invite")
def invite(
    request: Request,
    _: DevicePairer,
    person: Annotated[str, Body(embed=True)],
    hours: Annotated[float, Body(embed=True)] = 24.0,
) -> dict[str, Any]:
    """A personalised invitation link.

    The second way beside the code: whoever already has a device in hand does
    not type a code off a screen but opens a link. Both ways end in the same
    device token.
    """
    o = services(request).devices.invite(person, hours)
    base = str(request.base_url).rstrip("/")
    return {
        "token": o.token,
        "url": f"{base}/?invite={o.token}",
        "expires_in_s": round(o.remaining_s),
        "person": o.user_id,
    }


@router.post("/devices/{device_id}/person")
def assign_device(
    request: Request,
    device_id: str,
    wer: DevicePairer,
    person: Annotated[str | None, Body(embed=True)] = None,
) -> dict[str, Any]:
    """Give a device to a person — or make it shared with `null`.

    A shared device (the television in the living room) belongs to nobody and
    asks for the profile at startup.
    """
    d = services(request)
    d.devices.assign(device_id, person)
    d.events.record("event.device_assigned", {"device": device_id, "to": person or ""}, wer.id)
    return {"id": device_id, "person": person}


@router.post("/devices/{device_id}/name")
def rename_device(
    request: Request,
    device_id: str,
    wer: DevicePairer,
    name: Annotated[str, Body(embed=True)],
) -> dict[str, Any]:
    """Give a device the household's name for it.

    Sixty characters, like a pairing name, and never empty: an empty name
    would be a row with an icon and nothing beside it, and the sentence in
    the log ("… heißt jetzt") would trail off.
    """
    clean = " ".join(name.split())[:60]
    if not clean:
        raise f.Error("household.device_no_name", status=422)
    d = services(request)
    if not d.devices.rename(device_id, clean):
        raise f.Error(f.HOUSEHOLD_UNKNOWN_DEVICE, {"id": device_id}, status=404)
    d.events.record("event.device_renamed", {"device": device_id, "name": clean}, wer.id)
    return {"id": device_id, "name": clean}


@router.delete("/devices/{device_id}")
def revoke_device(request: Request, device_id: str, person: DevicePairer) -> dict[str, Any]:
    """Take a device's access away. It never reports back afterwards."""
    d = services(request)
    weg = d.devices.revoke_device(device_id)
    if weg:
        d.events.record("event.device_revoked", {"device": device_id}, person.id)
    return {"removed": weg}


@router.post("/pending/{token}/person")
def note_pending_person(
    request: Request,
    token: str,
    wer: DevicePairer,
    person: Annotated[str | None, Body(embed=True)] = None,
) -> dict[str, Any]:
    """Who the device about to redeem this code should belong to.

    **Reserve instead of assigning afterwards.** The console shows the row of
    people at the waiting pairing — that is, before the device has typed the
    code. Until 11.09.2026 that was a row of buttons without effect: pressing
    one only reported "type in the code", and the device arrived as a shared one
    afterwards.

    `null` means shared. With a television that is the right answer and not a
    missing one.
    """
    d = services(request)
    gemerkt = d.devices.note_person(token, person)
    if not gemerkt:
        # Expired, redeemed or an invitation — in all three cases the code is
        # nothing that anything can still be reserved against.
        raise f.Error(f.PAIRING_EXPIRED, {"code": token[:8]}, status=404)
    return {"code": token, "person": person}


@router.delete("/pending/{token}")
def revoke_pending(request: Request, token: str, _: DevicePairer) -> dict[str, Any]:
    """Invalidate a pending code or invitation link."""
    return {"revoked": services(request).devices.revoke(token)}


# ── Beitritt (AP47): Anfragen freigeben, Personenmarken ausgeben ──────────────
#
# **`/joins` und nicht `/pending`** (Entscheidung 8.6): `pending` steht in
# `GET /household/devices` schon für Kopplungen und Einladungen, und der
# Leitstand teilt jenes Feld fest in zwei Hälften. Eine dritte Sorte dort wäre
# unsichtbar, ohne dass etwas kaputt aussieht.


def _join_json(o: JoinRequest) -> dict[str, Any]:
    return {
        "id": o.token,
        "name": o.name,
        "color": o.color,
        "want": list(o.want),
        "device": o.device_name,
        "kind": o.device_kind,
        # Herkunft und Zeit, weil der Verwalter nur daran „aus meinem Netz“ von
        # „von außen“ unterscheiden kann.
        "from": o.from_where,
        "asked": o.created,
        "expires_in_s": round(o.remaining_s),
    }


@router.get("/joins")
def list_joins(request: Request, _: DevicePairer) -> dict[str, Any]:
    """The open requests — with name, device, time and origin — and what one can
    approve them as.

    **The roles come along** (AP85, 09.11.2026). Whoever may approve holds
    `pair_devices`, but `GET /household/roles` needs `change_access`: an app
    asking there would choose blind. So the request list carries the choice —
    only what the choice needs, not the portals or the member count.
    """
    d = services(request)
    return {
        "requests": [_join_json(o) for o in d.joins.open_requests()],
        "roles": [
            {
                "id": r.id,
                "name": r.name,
                "color": r.color,
                "adult": "view_adult" in r.rights,
                "own_devices": "own_devices" in r.rights,
            }
            for r in d.roles.list_all()
        ],
    }


# ── The door ("Einlass"): everything that wants into the household ──────────


@router.get("/door")
def door(request: Request, _: DevicePairer) -> dict[str, Any]:
    """Join requests, waiting pairing codes and open invitations — **one list**.

    Until the rebuild these came from two routes (`/household/joins` and the
    `pending` half of `/household/devices`) and the console stitched them
    together. One list means one order (newest first) and one count, and a
    third kind cannot go missing because a view forgot to ask for it.

    Codes that ran out within the last hour stay in with `expired: true`: a
    code that disappears while somebody is still reading it off the screen
    looks like a fault; one that says "expired" explains itself. Every action
    on an expired code is refused by the server anyway.
    """
    d = services(request)
    items: list[dict[str, Any]] = [
        {"type": "join", **_join_json(o), "created": o.created, "expired": False}
        for o in d.joins.open_requests()
    ]
    for o in d.devices.pending(include_expired=True):
        common = {
            "id": o.token,
            "created": o.created,
            "expires_in_s": round(o.remaining_s),
            "expired": o.expired,
        }
        if o.kind == "invite":
            if o.expired:
                continue  # an invitation link nobody used is simply gone
            items.append({"type": "invite", **common, "person": o.user_id})
        else:
            items.append(
                {
                    "type": "code",
                    **common,
                    "code": o.token,
                    "device": o.device_name,
                    "kind": o.device_kind,
                    # Reserved owner; `null` means shared (profile choice).
                    "person": o.user_id,
                    "from": o.from_where,
                }
            )
    items.sort(key=lambda i: i["created"], reverse=True)
    counts = {
        t: sum(1 for i in items if i["type"] == t and not i["expired"])
        for t in ("join", "code", "invite")
    }
    return {"items": items, "counts": counts}


@router.post("/joins/{token}/approve")
def approve_join(
    request: Request,
    token: str,
    wer: DevicePairer,
    role: Annotated[str, Body(embed=True)],
    pin: Annotated[str | None, Body(embed=True)] = None,
    name: Annotated[str | None, Body(embed=True)] = None,
    person_pin: Annotated[str | None, Body(embed=True)] = None,
    console: Annotated[bool | None, Body(embed=True)] = None,
) -> dict[str, Any]:
    """Eine Anfrage freigeben — mit Rolle und der PIN des Freigebenden.

    **Role and console apart** (AP85, 09.11.2026). `role` is a role id from
    `GET /household/joins`; `console: true` hands out the console on top. The
    old word `admin` still works and means "the role `adult` plus console" —
    but since roles are data `adult` may be the role with the 18+ lock, and an
    admin approved that way would run the console without 18+. New apps send
    the role and `console` separately.

    **Handing out the console needs `change_access`.** Today every approver
    holds it (the console rights come as one), so this only guards the day
    they are split: the console is the right to give rights.

    **`role` ohne Vorgabe.** Die Rolle ist die eigentliche Entscheidung dieses
    Weges; ein Aufruf, der sie vergisst, soll absagen und nicht raten.

    **Die PIN des Freigebenden, vor allem anderen.** Sein Gerätemerkmal läuft
    nie ab, seine App ist also dauerhaft angemeldet — und einen Fremden in den
    Haushalt zu lassen ist genau der Akt, bei dem „das Gerät ist angemeldet“
    nicht genügt. Geprüft über `People.sign_in`, also mit den fünf Versuchen
    und der Minute Pause. Face ID in der App ersetzt das nicht: Der Server
    prüft die Rolle, nie die App.

    Ein **geliehenes** Profil kommt gar nicht bis hierher: `pair_devices` steht
    nicht in `BORROWED_RIGHTS`.

    `name` wahlfrei, für `household.person_exists`: Der Verwalter benennt um,
    statt die Anfrage wegzuwerfen.

    **`person_pin` nur und immer für `role: admin`** (Entscheidung 15, 4–8
    Ziffern). Ein Verwalter ohne eigene PIN könnte selbst nie freigeben und
    käme nicht in den Leitstand. Für jede andere Rolle bleibt es bei „keine
    PIN“ (Entscheidung 8.1 a) — eine mitgeschickte wird abgewiesen und nicht
    still verschluckt, sonst glaubte der Verwalter, er hätte eine gesetzt.
    """
    d = services(request)
    # **Since 09.11.2026 the decider's PIN only guards console access.** The
    # owner's decision: letting somebody in with a role is what the console is
    # there for; handing out the console as well needs the PIN. A PIN that is
    # sent anyway is still checked — the app sends one.
    role_id, by_name = resolve_role(role)
    with_console = by_name if console is None else console
    if pin is not None or with_console:
        d.people.sign_in(wer.id, (pin or "").strip())
    if with_console and not wer.may("change_access"):
        raise f.Error(f.AUTH_FORBIDDEN, {"right": "change_access", "role": wer.role}, status=403)
    if d.roles.by_id(role_id) is None:
        raise f.Error("household.unknown_role", {"role": role}, status=422)

    pin_neu = (person_pin or "").strip()
    if with_console and not pin_neu:
        raise f.Error("join.admin_needs_pin", status=422)
    if not with_console and pin_neu:
        raise f.Error("join.pin_only_for_admin", {"role": role}, status=422)

    o, person = d.joins.approve(
        token, role_id, name, pin_neu if with_console else None, console=with_console
    )

    # **What "portals" means now that roles are data**: what their role sees.
    # Nothing to record any more — the answer only says what holds.
    # Readiness aside, as before AP90: a broken portal is still "theirs".
    portals = sorted(m.id for m in d.access.permitted(person, d.registry.manifests.values()))

    d.events.record("event.join_approved", {"name": person.name, "role": person.role}, wer.id)
    return {
        "person": {
            "id": person.id,
            "name": person.name,
            "role": person.role,
            "color": person.color,
            "adult": person.adult,
            "role_id": person.role_id,
            "console": person.console,
        },
        "granted": list(o.want),
        "portals": sorted(portals),
    }


@router.post("/joins/{token}/decline")
def decline_join(request: Request, token: str, wer: DevicePairer) -> dict[str, Any]:
    """Eine Anfrage ablehnen — ohne Grund im Rumpf.

    Ohne diesen Weg könnte eine Anfrage nur aussitzen, und der Anfragende sähe
    sieben Tage „wartet auf Freigabe“ für etwas, das längst entschieden ist.
    """
    d = services(request)
    o = d.joins.decline(token)
    d.events.record("event.join_declined", {"name": o.name}, wer.id)
    return {"declined": True}


async def _eigene_oder_verwalter(request: Request, user_id: str, person: Anyone) -> Person:
    """Die eigene Marke — oder als Verwalter die eines anderen.

    **Nie auf einem geliehenen Profil.** Wer am Wohnzimmerfernseher „Max“
    wählt, bekäme sonst mit einem Knopfdruck Maxs Schlüssel für jedes weitere
    Gerät. Die Marke ist mehr als Zuschauen, und `BORROWED_RIGHTS` ist eine
    Erlaubnisliste.

    Die eigene, weil das Beenden einer Profilfreigabe (Entscheidung 8.4) von
    der Person ausgeht, der das Profil gehört — und die muss kein Verwalter
    sein.
    """
    if getattr(request.state, "borrowed", False):
        raise f.Error(
            "auth.borrowed_profile", {"right": "person_mark", "person": person.name}, status=403
        )
    if person.id != user_id and not person.may("pair_devices"):
        raise f.Error(f.AUTH_FORBIDDEN, {"right": "pair_devices", "role": person.role}, status=403)
    return person


MarkKeeper = Annotated[Person, Depends(_eigene_oder_verwalter)]


@router.post("/people/{user_id}/mark")
def issue_mark(request: Request, user_id: str, wer: MarkKeeper) -> dict[str, Any]:
    """Die Personenmarke — die vorhandene oder eine neue.

    Für Personen, die nicht über `/join` kamen: Ihr Profil in der App braucht
    die Marke genauso, damit ein weiteres Gerät sich selbst anmeldet.
    """
    d = services(request)
    mark, neu = d.joins.issue_mark(user_id)
    if neu:
        d.events.record("event.mark_issued", {"person": user_id}, wer.id)
    return {"person": user_id, "mark": mark}


@router.delete("/people/{user_id}/mark")
def renew_mark(request: Request, user_id: str, wer: MarkKeeper) -> dict[str, Any]:
    """Die Marke widerrufen — **jedes Gerät, das über sie kam, fällt mit**.

    Und es gibt sofort eine neue (Entscheidung 8.4): Die geht ins Profil, und
    die eigenen Geräte melden sich damit still wieder an. Ein Widerruf ohne
    neue Marke ließe die Person selbst draußen stehen.
    """
    d = services(request)
    mark, weg = d.joins.renew_mark(user_id)
    d.events.record("event.mark_renewed", {"person": user_id, "devices": weg}, wer.id)
    return {"person": user_id, "mark": mark, "devices_removed": weg}


# ── Settings ─────────────────────────────────────────────────────────────────

#: What may be set over this route — an allow list.
#:
#: **Not the whole key space.** The same table holds values the service keeps
#: for itself; an open route onto those would be a remote control for its
#: innards.
#:
#: **The text beside each key is a fallback, not a label.** The console
#: translates over the key (`ui.setting.haus_name`); what stands here applies
#: only as long as there is no sentence there. A server that sends finished
#: sentences breaks its own rule — and that showed when the settings were
#: translated into Turkish except for four lines.
ALLOWED: dict[str, str] = {
    "haus.name": "The name devices see on the network",
    # `haus.sprache` and the two `melden.telegram_*` fields went on 09.11.2026:
    # nothing ever read them. Telegram has its own flow (`web/telegram.py`).
}


@router.get("/settings")
def read_settings(request: Request, _: Admin) -> dict[str, Any]:
    d = services(request)
    return {
        "settings": {k: d.store.read(k, "") for k in ALLOWED},
        "describes": ALLOWED,
    }


@router.put("/settings")
def write_settings(
    request: Request,
    _: Admin,
    settings: Annotated[dict[str, str], Body(embed=True)],
) -> dict[str, Any]:
    d = services(request)
    unknown = sorted(set(settings) - set(ALLOWED))
    if unknown:
        raise f.Error("settings.unknown_key", {"keys": unknown}, status=422)
    for k, v in settings.items():
        d.store.write(k, str(v))
    return {"settings": {k: d.store.read(k, "") for k in ALLOWED}}


# ── Workshop: what is broken ─────────────────────────────────────────────────


@router.get("/workshop")
def workshop(
    request: Request, _: Annotated[Person, Depends(requires("workshop"))]
) -> dict[str, Any]:
    """The truth about the state — unvarnished.

    Here stands what `/health` keeps quiet: which portal is broken and why. A
    manifest with an unknown key is broken, and the reason belongs in front of
    the admin's eyes rather than in a log.

    **And the runner's limits**, because the workshop writes them up. Until
    11.09.2026 they stood as `rlimit 256 MB · deadline 20 s` fixed in the
    markup: whoever changes them in `runner/fork.py` changes a number that
    stands in two places — and the visible one is the wrong one.

    `name` is a **language field** and not a German sentence. `m.title("de")`
    used to stand here; which language is shown is decided by the console and
    not by this router. It only came to light when the workshop called this
    route for the very first time — it had stood unused since E1.
    """
    d = services(request)
    return {
        "portals": [
            {
                "id": m.id,
                "name": m.name or {"en": m.id},
                "kind": m.kind,
                "ready": m.is_ready,
                "state": m.state,
                "reason": m.broken_reason,
                "capabilities": sorted(m.capabilities),
            }
            for m in d.registry.manifests.values()
        ],
        "limits": {
            "memory_mb": fork.MEMORY_MB,
            "cpu_s": fork.CPU_S,
            "deadline_s": fork.DEADLINE_S,
        },
    }


@router.post("/workshop/reload")
def reload_portals(
    request: Request, _: Annotated[Person, Depends(requires("workshop"))]
) -> dict[str, Any]:
    """Read the portal folders again — without restarting the container."""
    d = services(request)
    d.registry.reload()
    d.pin_switches()
    return d.registry.status()


@router.get("/me")
def me(person: Anyone) -> dict[str, Any]:
    """Who am I and what may I do — so the interface offers nothing the server
    refuses afterwards. **The lock stays at the server all the same.**
    """
    return {
        "id": person.id,
        "name": person.name,
        "role": person.role,
        "color": person.color,
        "adult": person.adult,
        # **All rights, not a selection.** The selection was a fault: it left
        # `install_portals` out, the interface read `undefined` and hid the
        # marketplace tab — from an admin who has it. Found in the browser pass,
        # not by reading.
        "rights": {r: person.may(r) for r in sorted(RIGHTS)},
        "role_id": person.role_id,
        "console": person.console,
    }
