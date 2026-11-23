"""Who is asking — and are they allowed to?

**A module of its own so that `main` and `portals` do not import each other in
a circle.** Both need the same check; neither should need the other.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Final

from fastapi import Depends, Header, Request

from cinelounge.core import errors as f
from cinelounge.household.devices import Devices
from cinelounge.household.events import Events
from cinelounge.household.joins import Joins
from cinelounge.household.nights import Nights
from cinelounge.household.people import People, Person
from cinelounge.household.progress import Progress
from cinelounge.household.roles import Roles
from cinelounge.household.store import Store
from cinelounge.household.visibility import Visibility
from cinelounge.household.zugang import Access
from cinelounge.market.sources import Sources
from cinelounge.market.trust import Trust
from cinelounge.portalworks.registry import Registry
from cinelounge.web import extension


@dataclass(slots=True)
class Services:
    """Everything the routes need, in one place.

    No global state in the module: that way the service can be built in a test
    with a data folder of its own, without anything lingering afterwards.
    """

    store: Store
    people: People
    roles: Roles
    devices: Devices
    visibility: Visibility
    access: Access
    progress: Progress
    events: Events
    joins: Joins
    nights: Nights
    sources: Sources
    trust: Trust
    registry: Registry

    @classmethod
    def from_path(cls, data: Path) -> Services:
        store = Store(data / "household.sqlite")
        # The extensions' own tables, before anything reads the household.
        extension.migrate(store)
        people = People(store)
        d = cls(
            store=store,
            people=people,
            roles=Roles(store),
            devices=Devices(store),
            visibility=Visibility(store),
            access=Access(store),
            progress=Progress(store),
            events=Events(store),
            joins=Joins(store, people),
            nights=Nights(store),
            sources=Sources(store),
            trust=Trust(store),
            # The stored values come from the household, not from the
            # `portal.yml` — see `Store.portal_settings`. As a callback, so
            # that `portalworks` still knows nothing of `household`.
            registry=Registry(data / "portals", overrides=store.portal_settings),
        )
        # Once: what is on only by the manifest's default goes to the adult
        # role — the migration could not see manifests (`Roles.adopt_defaults`).
        with store.connect() as v:
            rows = v.execute("SELECT portal_id FROM portal_switch").fetchall()
        switched = {str(z["portal_id"]) for z in rows}
        d.roles.adopt_defaults(
            [m.id for m in d.registry.manifests.values() if m.on_by_default], switched
        )
        d.roles.prune_locked(m.id for m in d.registry.manifests.values() if m.adult)
        d.roles.sync_legacy()
        d.pin_switches()
        return d

    def pin_switches(self) -> list[str]:
        """Write the manifest's default down as the switch, once per portal (AP90).

        Runs at start and after every reload that can bring a new portal
        (marketplace, rollback, workshop). It runs **after** `adopt_defaults`,
        which still needs to know which portals were never switched. The
        event names what was written, so nothing changes silently.
        """
        pinned = self.visibility.pin_defaults(
            (m.id, m.on_by_default) for m in self.registry.manifests.values()
        )
        if pinned:
            self.events.record("event.switches_pinned", {"portals": ", ".join(pinned)})
        return pinned


def services(request: Request) -> Services:
    return request.app.state.services  # type: ignore[no-any-return]


async def current_person(
    request: Request,
    x_cl_device: Annotated[str | None, Header()] = None,
    x_cl_profile: Annotated[str | None, Header()] = None,
) -> Person:
    """The person behind the device token.

    **They come from the token and never from a parameter.** Otherwise every
    device could overwrite every person's progress, and the parental lock would
    be a matter of politeness.

    A **shared** device — a television in the living room belongs to nobody —
    names its profile additionally in `X-CL-Profile`. That is the profile choice
    at startup, and only somebody already in the household may be chosen.
    """
    d = services(request)
    if not x_cl_device:
        raise f.Error(f.AUTH_REQUIRED, status=401)
    g = d.devices.by_token(x_cl_device, request.client.host if request.client else "")
    if g is None:
        raise f.Error(f.AUTH_REQUIRED, status=401)

    # **Borrowed or own — the difference counts further down.**
    # A device with a person signed in with a PIN once; a shared one has only a
    # profile choice behind it, and that is one press of a button.
    ident = g.user_id
    request.state.borrowed = ident is None
    if ident is None:
        if not x_cl_profile:
            raise f.Error("auth.profile_required", {"device": g.name}, status=401)
        ident = x_cl_profile

    person = d.people.by_id(ident)
    if person is None:
        raise f.Error(f.AUTH_REQUIRED, status=401)

    # For the routes that need them afterwards — they should not have to look
    # it up a second time.
    request.state.person = person
    return person


#: What a **borrowed** profile gets to keep.
#:
#: A shared device is the television in the living room: whoever sits in front
#: of it says at startup who they are — and that is all it is. That is enough
#: for watching and **never for administering**. Otherwise anybody who picks up
#: the remote gets the whole household with one press on "Max".
#:
#: **Measured 11.09.2026** on a test device with no person: the header
#: `X-CL-Profile: max` gave 200 on `/household/backup` (1845 bytes of
#: household, including everything in it), 200 on `/household/events` and
#: switched a portal off. No PIN, no sign-in — the header alone.
#:
#: `current_person`'s docstring said even then that the person comes "from the
#: token and never from a parameter, otherwise the parental lock would be a
#: matter of politeness". On a shared device it came from exactly a parameter.
#:
#: **`view_adult` stands here deliberately** — decision of 11.09.2026, on the
#: question whether the profile choice on the television should ask for a PIN:
#: **no.** Whoever picks "Max" in the living room sees what Max may see.
#:
#: In plain words: the age rating is an **arrangement within the household and
#: not a lock** there, and that is exactly how it stands in the app contract
#: (`docs/PROMPT-APP.md`) and in `ARCHITEKTUR.md`, section 2a. Whoever wants it
#: otherwise gives the device a person — then the profile choice falls away and
#: the question with it.
#:
#: Administration is untouched by this: it never hung on an arrangement.
BORROWED_RIGHTS: Final = frozenset({"watch", "track_progress", "view_adult"})


def requires(right: str) -> Callable[..., object]:
    """A dependency that demands a right.

    **The place where the roles take effect.** Not the interface — hiding is not
    a lock.

    And since 11.09.2026 the place where **where** the person comes from counts
    too: a profile that was only picked and never backed by a PIN does not reach
    administration (see `BORROWED_RIGHTS`).
    """

    async def checker(
        request: Request,
        person: Annotated[Person, Depends(current_person)],
    ) -> Person:
        if getattr(request.state, "borrowed", False) and right not in BORROWED_RIGHTS:
            raise f.Error(
                "auth.borrowed_profile", {"right": right, "person": person.name}, status=403
            )
        if not person.may(right):
            raise f.Error(f.AUTH_FORBIDDEN, {"right": right, "role": person.role}, status=403)
        return person

    return checker


Anyone = Annotated[Person, Depends(current_person)]
Admin = Annotated[Person, Depends(requires("change_settings"))]

#: Who may install portals. Today the same role as `Admin` — but a different
#: right, and the rights table is the place where that counts.
Installer = Annotated[Person, Depends(requires("install_portals"))]
