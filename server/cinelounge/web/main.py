"""The routes. FastAPI translates HTTP inwards, nothing more.

**No logic stands here.** Whoever looks for a rule finds it in `household` or
`portalworks` — `web` hangs on everything, nothing hangs on `web`. That is the
same separation that divides `Features` from `Core` in the television app.

**Errors go out as a code, never as a sentence.** See `core/errors.py`.
"""

from __future__ import annotations

import logging
import os
import time
from pathlib import Path
from typing import Annotated, Any

from fastapi import Body, FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles

from cinelounge import __version__
from cinelounge.core import errors as f
from cinelounge.household.people import Person
from cinelounge.portalworks import routes, seed
from cinelounge.portalworks.manifest import Manifest
from cinelounge.portalworks.runner import call as runner
from cinelounge.portalworks.runner.fork import available as fork_da
from cinelounge.stream import buffer
from cinelounge.web import admin as verwaltung_router
from cinelounge.web import auth as anmeldung_router
from cinelounge.web import exitwatch, extension, firstrun, nightwatch, telegram
from cinelounge.web import network as netz_router
from cinelounge.web import portals as portale_router
from cinelounge.web.access import Anyone, Services, services

DATA = Path(os.environ.get("CL_DATA", "/data"))
STARTED_AT = time.time()

# The contract version. It stands in the self-description, and the app decides
# from it whether it can speak to this server.
API_VERSIONS = [1, 2]
#
# **2 seit AP47 (Beitritt), und 1 bleibt stehen.** Die App fragt
# `api.contains { bekannteFassungen.contains($0) }` — eine App, die nur 1 kennt,
# findet 1 und läuft weiter; nichts an Fassung 1 wurde weggenommen. Worauf eine
# neue App wirklich hören soll, ist die Fähigkeit `join` unten: Die Zahl sagt
# „der Vertrag hat sich geändert“, die Fähigkeit „das hier darfst du anbieten“.

# **The starter set — before anything else.** On the very first start
# `/data/portals` is empty; a console with zero portals looks like a fault, and
# a stranger does not know whether they did something wrong.
#
# **The order is the whole point.** On the first attempt this call stood thirty
# lines further down: the registry had already read by then, and `/health`
# reported `portals: 0` — with five freshly installed folders on disk. Measured
# 11.09.2026 at the first `docker compose up` from a foreign directory.
seed.seed_if_empty(DATA / "portals")

# **Extensions, phase 1 — before the registry reads a single manifest.** An
# extension may add portal kinds and manifest fields; a manifest read before
# that would be judged against an incomplete list. See `web/extension.py`.
extension.load()

# **The routes before the registry, and that is an order, not a habit.** The
# registry marks a portal `broken` whose route is missing; it can only do that
# once it knows which routes there are. `CL_PROXIES` names them (see
# `portalworks/routes.py`) — without it every portal goes direct. The proxies
# saved in the console follow once the household is open (`load_saved` below).
routes.configure(os.environ.get("CL_PROXIES"))

app = FastAPI(title="CineLounge Server", version=__version__, docs_url="/docs", redoc_url=None)
app.state.services = Services.from_path(DATA)
netz_router.load_saved(app.state.services)

# ── The buffer ──────────────────────────────────────────────────────────────
#
# **It did not run at all until 11.09.2026.** Nobody called
# `buffer.set_folder()`, `_ORDNER` stayed `None`, and so `begin()` and
# `begin_chunked()` returned `None` immediately. Checked on the data volume:
# under `/data/cache` lay portal caches and not a single `.bin`.
#
# What that cost without ever showing:
#
# - **No pre-loading in blocks.** File servers often cap each connection; four
#   connections are four times as fast. Playback ran all the same — only over a
#   single connection, and that looks like a slow server.
# - **Once-only addresses were dead.** An address that opens exactly once has
#   to be caught at resolve time and served from disk (`buffer.begin`);
#   without a folder there was nowhere to write it.
#
# A folder of its own, not `cache/`: portals keep their caches there, and
# `drop_orphans()` clears its folder out entirely at startup.
# **The service writes its start into the book.** That is the one entry the
# overview has even without anybody operating it — and it answers the question
# that comes first after every power cut: did it run through?
app.state.services.events.record("event.service_started", {"version": __version__})

# **The first run.** With no person in the household the service creates a
# setup code and writes it to the log — otherwise whoever opens `cl.example` first
# sets things up, and that need not be whoever started the container.
firstrun.arm(app.state.services.people.is_empty())

buffer.set_folder(DATA / "buffer")
buffer.adopt_orphans()
buffer.start_sweeper()

# **The nightly run.** At four o'clock it checks every portal once through —
# from the menu to the video address — and writes the result into the book.
# Nothing is switched off in the process: a media library having a bad night
# would otherwise be gone by morning, and the operator would go looking for the
# switch instead of the cause. The same stance as at the marketplace, where
# there is no auto-update.
nightwatch.start(
    app.state.services.registry,
    app.state.services.nights,
    app.state.services.events,
    app.state.services.visibility,
)

# **Telegram and the route watch** (09.11.2026). Telegram listens to the event
# book; the watch writes `event.exit_down` into it when a route stays dark.
telegram.install(app.state.services)
exitwatch.start(app.state.services.events)

app.include_router(anmeldung_router.router)
app.include_router(portale_router.router)
app.include_router(telegram.router)
app.include_router(verwaltung_router.router)
app.include_router(netz_router.router)

#: The console lies beside this module, not on the data volume.
#:
#: **It belongs to the image and not to the data.** Whoever updates the
#: container gets the new interface with it; whoever backs up their `/data`
#: backs up their household and not our code.
CONSOLE = Path(__file__).resolve().parent / "console"

_LOG = logging.getLogger("cinelounge.web")

# **No Bonjour here.** Multicast does not cross a Docker bridge, and the
# address this container knows of itself is a bridge IP that means nothing to
# anybody on the home network (measured: 172.16.69.2, found on the network: 0).
# The announcing is done by `cinelounge-melder` on the host network.


@app.exception_handler(f.Error)
async def _fehler_hinaus(request: Request, err: f.Error) -> JSONResponse:
    """A code and its values — never a German sentence.

    The bridge today sends `f"{was}: {type(fehler).__name__}: {fehler}"` to the
    television. That is untranslatable and lands in a household that may well
    operate the app in Turkish.

    Extensions see every error answer first (`ctx.error_observer`), for their
    own bookkeeping; they cannot change it.
    """
    extension.observe_error(request, err)
    # **A server-side failure goes into the log, with its values** (AP59/AP60,
    # 30.09.2026). Until then a 502 left nothing but the access line: "GET /play … 502"
    # — one title failed twice that way, and the reason only ever
    # reached the television. The values are what the docstring of `f.Error` sends
    # here: the forensic trail belongs in the log. Client errors (4xx) stay quiet;
    # they are answers, not failures.
    if err.status >= 500:
        _LOG.warning(
            "%s %s -> %d %s %s",
            request.method,
            request.url.path,
            err.status,
            err.code,
            err.values,
        )
    return JSONResponse(err.as_json(), status_code=err.status)


# ── Self-description: "enter one address and it runs" ────────────────────────


@app.get("/.well-known/cinelounge")
def self_description(request: Request) -> dict[str, Any]:
    """What the app has to be able to find out from an address alone.

    Without this information it has to guess: which contract version, which
    languages, whether and how one signs in, whether a household already exists.
    """
    d = services(request)
    return {
        "name": d.store.read("haus.name", "CineLounge"),
        "version": __version__,
        "api": API_VERSIONS,
        "languages": ["de", "en", "tr"],
        "auth": "pin",
        "setup_required": d.people.is_empty(),
        "setup_code_armed": firstrun.armed(),
        "capabilities": ["household", "join", "portals", "state", "stream"],
    }


@app.get("/health")
def status(request: Request) -> dict[str, Any]:
    d = services(request)
    out: dict[str, Any] = {
        "ok": True,
        # **The version belongs here.** The self-description names it too, but
        # that one is open and read by the app; the console asks `/health` and
        # stood in front of a dash without this line.
        "version": __version__,
        "uptime_s": round(time.time() - STARTED_AT),
        "fork": fork_da(),
        "household": {"people": len(d.people.list_all()), "devices": len(d.devices.list_all())},
        # The console shows the buffer in the status strip ("3.2 GB"). Without
        # this line a dash stood there — and that looked like "empty" instead of
        # "no information".
        "buffer": buffer.status(),
        # **Counted, not asked.** How many routes there are — no round trip
        # to any of them. The measured state lives in `/network/exits`,
        # behind the view that wants it.
        "exits": len(routes.all_routes()),
        **d.registry.status(),
    }
    # **Which extensions run, and which did not.** An extension that failed
    # at startup leaves the service running without it; this is where the
    # operator sees that. Their own fields come along, never over a core field.
    for key, value in extension.health().items():
        out.setdefault(key, value)
    return out


# ── Household ────────────────────────────────────────────────────────────────


@app.get("/household/people")
def list_people(request: Request, _: Anyone) -> dict[str, Any]:
    return {
        "people": [
            {"id": p.id, "name": p.name, "role": p.role, "color": p.color, "adult": p.adult}
            for p in services(request).people.list_all()
        ]
    }


@app.get("/household/devices")
def list_devices(request: Request, _: verwaltung_router.DevicePairer) -> dict[str, Any]:
    d = services(request)
    return {
        "devices": [
            {
                "id": g.id,
                "name": g.name,
                "kind": g.kind,
                "person": g.user_id,
                "shared": g.shared,
                "last_seen": g.last_seen,
                "from": g.from_where,
                "paired": g.paired,
                "via_mark": g.via_mark,
            }
            for g in d.devices.list_all()
        ],
        "pending": [
            {
                "code": o.token,
                "kind": o.kind,
                "person": o.user_id,
                "device": o.device_name,
                "expires_in_s": round(o.remaining_s),
            }
            for o in d.devices.pending()
        ],
    }


@app.get("/portals")
def list_portals(request: Request, person: Anyone) -> dict[str, Any]:
    """What this person sees — not what exists.

    **The age lock takes effect here and not in the interface.** A child's
    profile never gets an 18+ portal in front of it at all — and if it calls the
    route directly, a 403 comes back (see `web/portals.py`).

    `permitted` (AP90) names the portals whose titles may stay in "continue
    watching" although they are broken right now. An app that sieves its
    continue-watching row against `portals` drops them; one that knows this
    field keeps them and hears "broken" only when it plays. Older apps ignore it.
    """
    d = services(request)
    return {
        "portals": [m.as_json() for m in _sichtbar(d, person)],
        "permitted": [m.id for m in _erlaubt(d, person)],
    }


def _sichtbar(d: Services, person: Person) -> list[Manifest]:
    """The portals this person sees: `household/zugang.py` decides (AP90)."""
    return d.access.visible(person, d.registry.manifests.values())


def _erlaubt(d: Services, person: Person) -> list[Manifest]:
    """Visible plus broken ones the rules allow — continue watching, favourites.

    Owner, 16.11.2026: a title from a portal with a fault stays where it was;
    the fault is said when it is played (`portal.broken` from `/play`).
    """
    return d.access.permitted(person, d.registry.manifests.values())


# ── Progress ─────────────────────────────────────────────────────────────────


@app.post("/state")
def report_progress(
    request: Request,
    person: Anyone,
    key: Annotated[str, Body(embed=True)],
    portal: Annotated[str, Body(embed=True)] = "",
    title: Annotated[str, Body(embed=True)] = "",
    year: Annotated[int | None, Body(embed=True)] = None,
    address: Annotated[str, Body(embed=True)] = "",
    kind: Annotated[str, Body(embed=True)] = "",
    image: Annotated[str, Body(embed=True)] = "",
    language: Annotated[str | None, Body(embed=True)] = None,
    series: Annotated[str, Body(embed=True)] = "",
    position_s: Annotated[float | None, Body(embed=True)] = None,
    duration_s: Annotated[float | None, Body(embed=True)] = None,
    watched: Annotated[bool | None, Body(embed=True)] = None,
    favorite: Annotated[bool | None, Body(embed=True)] = None,
) -> dict[str, Any]:
    """Position, watched mark, favourite — for **the signed-in person**.

    Whose progress is meant is said by the sign-in, not by the caller.
    """
    return services(request).progress.report(
        person.id,
        key,
        portal=portal,
        title=title,
        year=year,
        address=address,
        kind=kind,
        image=image,
        language=language,
        series=series,
        position_s=position_s,
        duration_s=duration_s,
        watched=watched,
        favorite=favorite,
    )


@app.get("/state")
def read_progress(request: Request, person: Anyone, key: str) -> dict[str, Any]:
    d = services(request)
    # Same rule as `/resume`: an entry from a portal this person does not see
    # is answered like one that does not exist (owner, 09.11.2026: nothing
    # hidden may get through, not even "continue watching").
    item = d.progress.by_id(person.id, key, portals=[m.id for m in _erlaubt(d, person)])
    if item is None:
        raise f.Error("state.unknown_key", {"key": key}, status=404)
    return item


@app.delete("/state")
def forget_progress(request: Request, person: Anyone, key: str) -> dict[str, Any]:
    return {"forgotten": services(request).progress.forget(person.id, key)}


# **Nur aus Portalen, die diese Person sieht** (AP60, 30.09.2026). Bis dahin kam hier
# alles, was je angefangen wurde — auch aus ausgeschalteten Portalen und aus
# solchen über der Altersgrenze —, und jede Stelle der Apps
# musste selbst aussieben. Eine, die es vergaß, zeigte sie wieder (Besitzer: "das darf
# definitiv nicht passieren"). Jetzt gilt dieselbe Regel wie für `/portals`.


@app.get("/favorites")
def favorites(request: Request, person: Anyone, limit: int = 200) -> dict[str, Any]:
    d = services(request)
    sichtbar = [m.id for m in _erlaubt(d, person)]
    return {"favorites": d.progress.favorites(person.id, limit, portals=sichtbar)}


@app.get("/resume")
def resumable(request: Request, person: Anyone, limit: int = 50) -> dict[str, Any]:
    d = services(request)
    sichtbar = [m.id for m in _erlaubt(d, person)]
    return {"resumable": d.progress.resumable(person.id, limit, portals=sichtbar)}


# ── Console ──────────────────────────────────────────────────────────────────
#
# **Right at the end, and that is not cosmetics.** A mount on `/` catches
# everything that was not answered before it. Standing at the top it would
# swallow `/portals` and `/health` — silently, with HTTP 200 and an HTML page in
# the body, which is the worst way to be broken.


class Immutable(StaticFiles):
    """The built console's assets (rebuild 09.11.2026).

    Vite puts a content hash into every file name, so a file never changes
    under its name — it may stay in the cache for good. Only `index.html`
    (answered below, `no-cache`) decides which names are current.
    """

    def file_response(self, *args: Any, **kwargs: Any) -> Response:
        antwort = super().file_response(*args, **kwargs)
        antwort.headers["Cache-Control"] = "public, max-age=31536000, immutable"
        return antwort


if (CONSOLE / "assets").is_dir():
    # No `html=True`: the root path is answered by hand below, so that the
    # invitation in the address bar arrives.
    app.mount("/assets", Immutable(directory=CONSOLE / "assets"), name="assets")


@app.get("/")
def root() -> FileResponse:
    """The page itself.

    **Without a role check, and that is right.** What is served here is the
    interface's blueprint and not content: every row that appears in it is
    fetched separately by the browser afterwards — and every one of those routes
    checks. Serving the page reveals nothing beyond the fact that a CineLounge
    server stands here, and `/.well-known/cinelounge` says that anyway.
    """
    page = CONSOLE / "index.html"
    if not page.is_file():
        raise f.Error("web.no_ui", {"path": str(page)}, status=503)
    # No caching: a browser that keeps the old page after an update loads new
    # modules into an old frame.
    return FileResponse(page, headers={"Cache-Control": "no-cache"})


# ── Extensions, phase 2, and the preload ─────────────────────────────────────
#
# **At the end of the file, after every core route.** Starlette answers with
# the first route that matches; an extension's router added here cannot shadow
# `/health` or `/portals`.
extension.attach(app, app.state.services)

# **Preload before the first child comes into being.** What stands in
# sys.modules here, every child inherits ready-made — and portal code can no
# longer move it. The finding that forced this stands in runner/preload.py.
# It also seals the extension registries: every child sees the same ones.
runner.preload()
