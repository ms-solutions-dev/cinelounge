"""The portal routes. Translate HTTP inwards, nothing more.

**In front of every row stands the role check**, and here at the server — a
portal's own code checks nothing. In a household with children that is no
subtlety.

Extensions take part through `PortalViewHook` (`web/extension.py`): the menu,
the items of a listing or search, an opened entry, a played address. Their own
routes under `/p/{id}/…` check the person with `portal_for`, as these do.
"""

from __future__ import annotations

import threading
import time
from typing import Any, Final

from fastapi import APIRouter, Query, Request, Response
from fastapi.responses import StreamingResponse

from cinelounge.core import errors as f
from cinelounge.core.ids import key as _schluessel
from cinelounge.core.ids import normalized
from cinelounge.household import zugang
from cinelounge.household.people import Person
from cinelounge.portalworks import einmal, extension, playback, sammlung
from cinelounge.portalworks.manifest import Manifest
from cinelounge.portalworks.runner import call as runner
from cinelounge.stream import buffer, proxy
from cinelounge.web import extension as erweiterungen
from cinelounge.web.access import Anyone
from cinelounge.web.access import services as _dienste

router = APIRouter()


def portal_for(request: Request, portal_id: str, person: Person) -> Manifest:
    """Fetch the portal — **and check the permission before it goes out.**

    Three refusals, three codes: the portal does not exist, it is broken, or
    this person may not see it. An empty list would be the worse answer — it
    looks like "found nothing".

    **The decision is `household/zugang.py`'s** (AP90); here it is only
    translated into the codes the app has known since E1. The order lives
    there: 18+ first, readiness last — a broken 18+ portal must not answer a
    child with its name and the reason it is broken.
    """
    d = _dienste(request)
    m = d.registry.manifests.get(portal_id)
    if m is None:
        raise f.Error(f.PORTAL_UNKNOWN, {"id": portal_id}, status=404)
    e = d.access.check(person, m)
    if e.reason == zugang.ADULT:
        # **Hiding is not a lock.** The interface does not show it — here it
        # is refused, even when somebody calls the route directly.
        raise f.Error(f.AUTH_FORBIDDEN, {"right": "view_adult", "role": person.role}, status=403)
    if e.reason in (zugang.OFF, zugang.NO_ROLE):
        raise f.Error(f.PORTAL_DISABLED, {"id": portal_id}, status=403)
    if e.reason == zugang.BROKEN:
        raise f.Error(f.PORTAL_BROKEN, m.refusal(), status=503)
    if not e.allowed:
        # A reason added to `zugang` later and forgotten here refuses.
        raise f.Error(f.PORTAL_DISABLED, {"id": portal_id}, status=403)
    return m


def _mit_stand(
    request: Request, person: Person, portal_id: str, items: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    """Entries together with their progress — in **one** query, not one per poster."""
    d = _dienste(request)
    for i in items:
        i["key"] = _schluessel(portal_id, i.get("title") or "", i.get("year"))
    remembered = d.progress.for_many(person.id, [i["key"] for i in items])
    for i in items:
        e = remembered.get(i["key"])
        i["state"] = (
            None
            if e is None
            else {
                "fraction": e["fraction"],
                "remaining_s": e["remaining_s"],
                "position_s": e["position_s"],
                "watched": e["watched"],
                "favorite": e["favorite"],
                "language": e["language"],
            }
        )
    # A note about a German-to-English mapping used to stand here, pointing at
    # `web/uebersetzung.py`. That file is gone and the contract itself is
    # English since B3 — what leaves this function are the keys the entries
    # already carry.
    return items


# ── Browsing ─────────────────────────────────────────────────────────────────


@router.get("/p/{portal_id}/menu")
def menu(request: Request, portal_id: str, person: Anyone) -> dict[str, Any]:
    m = portal_for(request, portal_id, person)
    entries = einmal.einmal((m.id, "menu"), lambda: runner.call(m, "menu")) or []
    # The view hooks get copies — the cached menu stays as the portal gave it.
    entries = erweiterungen.view_menu(request, person, m, entries)
    return {"portal": portal_id, "entries": entries}


@router.get("/p/{portal_id}/list")
def listing(
    request: Request,
    portal_id: str,
    person: Anyone,
    entry: str = Query("", alias="entry", description="die Kennung aus /menu"),
    next_page: str | None = Query(None, alias="next"),
    user_input: str = Query(
        "", alias="input", description="die Antwort auf ein voriges needs_input"
    ),
    sort: str = Query("", description="title, rating or year — over all pages of the level"),
    order: str = Query("", description="asc or desc; without it rating and year go down"),
) -> dict[str, Any]:
    m = portal_for(request, portal_id, person)
    if not entry and not next_page:
        raise f.Error("list.no_entry", status=422)
    # Opened: the first page only, not the answer to a question asked inside it.
    if entry and not next_page and not user_input:
        erweiterungen.view_opened(request, person, m, entry)
    if sort:
        if sort not in sammlung.SORTEN:
            raise f.Error("list.sort_unknown", {"sort": sort}, status=422)
        if not entry:
            raise f.Error("list.no_entry", status=422)

        def holen(weiter: str | None) -> dict[str, Any]:
            antwort: dict[str, Any] = runner.call(
                m, "listing", {"entry": entry, "next_page": weiter, "user_input": user_input}
            )
            # A divider has no title worth sorting and no rating; sorted over
            # all pages it would land between the videos (AP77).
            antwort["items"] = [
                i for i in (antwort.get("items") or []) if i.get("kind") != "separator"
            ]
            return antwort

        page = sammlung.seite(
            (m.id, entry, user_input),
            holen,
            sort,
            order == "desc" if order else sort != "title",
            sammlung.stelle(next_page),
        )
    else:
        argumente = {"entry": entry, "next_page": next_page, "user_input": user_input}
        page = einmal.einmal(
            (m.id, "listing", entry, next_page, user_input),
            lambda: runner.call(m, "listing", argumente),
        )
        naechste_seite_vorholen(m, entry, page.get("next_page"), user_input)
    items = list(page.get("items") or [])
    # Copies go to the view hooks, not the cached page: what a hook fills in
    # may change, the cache would not.
    items = [dict(i) for i in items]
    erweiterungen.view_items(m, items)
    return {
        "portal": portal_id,
        "total": page.get("total"),
        "next": page.get("next_page"),
        "note": page.get("note"),
        "needs_input": page.get("needs_input"),
        "input_suggestion": page.get("input_suggestion"),
        "question": page.get("question"),
        "preparing": page.get("preparing"),
        "truncated": page.get("truncated"),
        "items": _mit_stand(request, person, portal_id, items),
    }


def naechste_seite_vorholen(
    m: Manifest, entry: str, next_page: str | None, user_input: str
) -> threading.Thread | None:
    """Fetch the page after this one now, so that it is there when the viewer gets there.

    **"Gefühlt keine Wartezeit"** (AP76, 11.10.2026). Both apps extend a level
    when its last tile shows; until then the viewer looked at a spinner for as
    long as the site took. The page they will ask for next is known — it is
    `next_page` — so it goes into `einmal`'s memory right away, under exactly
    the key their request will carry. Their ask then finds the answer, or joins
    the fetch that is still running. One page ahead, not a chain: the page
    after that is fetched when this one is asked for.

    Nothing is reported from here. If the fetch fails, the viewer's own ask
    repeats it and gets the error with its reason.
    """
    if not next_page:
        return None
    schluessel = (m.id, "listing", entry, next_page, user_input)
    argumente = {"entry": entry, "next_page": next_page, "user_input": user_input}

    def los() -> None:
        try:
            einmal.einmal(schluessel, lambda: runner.call(m, "listing", argumente))
        except Exception:
            pass

    faden = threading.Thread(target=los, name=f"vorab-seite-{m.id}", daemon=True)
    faden.start()
    return faden


@router.get("/p/{portal_id}/children")
def children(
    request: Request,
    portal_id: str,
    person: Anyone,
    address: str,
    title: str = "",
) -> dict[str, Any]:
    m = portal_for(request, portal_id, person)
    items = (
        einmal.einmal(
            (m.id, "children", address, title),
            lambda: runner.call(m, "children", {"address": address, "title": title}),
        )
        or []
    )
    return {"portal": portal_id, "items": _mit_stand(request, person, portal_id, list(items))}


@router.get("/p/{portal_id}/sources")
def sources(
    request: Request,
    portal_id: str,
    person: Anyone,
    address: str,
    title: str = "",
) -> dict[str, Any]:
    m = portal_for(request, portal_id, person)
    found = playback.sources(m, address, title)
    # The app calls `/play` right after this — the policy may get its pick
    # ready in the meantime (AP63).
    playback.prepare(m, found)
    return {
        "portal": portal_id,
        "sources": found,
    }


@router.get("/search")
def search(request: Request, person: Anyone, q: str, portal: str | None = None) -> dict[str, Any]:
    """Across all portals at once — one pass per portal.

    A portal that fails does not take the others with it: its code stands beside
    its empty result.
    """
    d = _dienste(request)
    asked = [portal] if portal else [m.id for m in d.registry.ready()]
    hits: dict[str, Any] = {}
    failed: dict[str, str] = {}
    for pid in asked:
        try:
            m = portal_for(request, pid, person)
            if "search" not in m.capabilities:
                continue
            items = [dict(i) for i in (runner.call(m, "search", {"text": q}) or [])]
            erweiterungen.view_items(m, items)
            hits[pid] = _mit_stand(request, person, pid, items)
        except f.Error as err:
            # A portal this person may not see is not an error — it simply
            # does not appear.
            if err.code not in (f.AUTH_FORBIDDEN, f.PORTAL_DISABLED):
                failed[pid] = err.code
        except Exception as err:
            failed[pid] = "run.crashed"
            del err
    return {
        "query": q,
        "hits": hits,
        # **The same thing again, merged** — and `hits` stays as it was. An app
        # already reading it notices nothing of this field.
        "titles": _zusammenlegen(hits, d.registry),
        "failed": failed,
    }


def _zusammenlegen(hits: dict[str, Any], registry: Any) -> list[dict[str, Any]]:
    """The same title from several portals into one row.

    **Grouping runs over `normalized(title)` and the year** — the same
    normalisation the progress hangs on (`core/ids.py`). "Die Pewi" and "die
    pewi!" are one that way, "Hisvei Weprir" and "Hisvei Weprir (2023)" stay two:
    the suffix stands in the title, and whoever throws it away lays two series
    on top of each other.

    **Sources in front by their kind's rank** (`extension.KindSpec.rank`) — a
    statement about origin, not about quality: a source that speaks an
    official interface stays reachable when a page-reading one breaks. Within
    one rank the registry's order stays; it is the file system's and
    therefore predictable. A kind nobody registered stands last.

    **The show title does not group.** Two episodes of the same series from two
    portals are not the same episode, and a list claiming so sends somebody into
    the wrong one.
    """
    art = {m.id: extension.rank(m.kind) for m in registry.manifests.values()}
    reihe = {pid: i for i, pid in enumerate(registry.manifests)}

    gruppen: dict[tuple[str, int | None], dict[str, Any]] = {}
    for pid, items in hits.items():
        for i in items or []:
            titel = str(i.get("title") or "")
            if not titel:
                continue
            marke = (normalized(titel), i.get("year"))
            gruppe = gruppen.setdefault(
                marke,
                {"title": titel, "year": i.get("year"), "show": i.get("show"), "sources": []},
            )
            gruppe["sources"].append(
                {
                    "portal": pid,
                    "address": i.get("address"),
                    "key": i.get("key"),
                    "kind": i.get("kind"),
                    "image": i.get("image"),
                }
            )

    for gruppe in gruppen.values():
        gruppe["sources"].sort(key=lambda q: (art.get(q["portal"], 9), reihe.get(q["portal"], 99)))
    return list(gruppen.values())


# ── Playing ──────────────────────────────────────────────────────────────────


@router.get("/play")
def play(
    request: Request,
    portal: str,
    person: Anyone,
    source: str = Query("", alias="source", description="die Kennung aus /sources"),
    address: str = Query("", alias="address", description="der Eintrag — mit source: der Rückweg"),
) -> dict[str, Any]:
    """The video address — as JSON, never as a 302.

    **No redirect.** A 302 carries no headers along and cannot give a reason for
    a refusal; the app needs both. The way over the relay stands in `address`
    anyway.

    **`source` and `address` together** (since 16.09.2026): the chosen source
    goes first, and when it does not carry, the item's other sources follow —
    the answer then says `switched: true` and names the `source` that did.
    `source` alone stays what it was: exactly this one, or a refusal.
    """
    m = portal_for(request, portal, person)

    def sprache() -> str:
        # `optional=True`: a media-library portal knows no show mapping.
        # Without it this lookup took the whole playback down with it — see
        # `runner/call.py`.
        title = runner.call(m, "series", {"address": address}, optional=True)
        if not title:
            return ""
        e = _dienste(request).progress.by_id(person.id, _schluessel(portal, title, None))
        return str((e or {}).get("language") or "")

    # **Asked only when needed** (AP63, 01.10.2026): a fork of its own before every
    # press, and with a chosen source it only orders the fallback.
    done = playback.resolve_play(
        m, address=address, source=source, language=sprache if address else ""
    )
    erweiterungen.view_played(request, person, m, address or source)
    _gespielt_merken(m.id, str(done.get("source") or ""), person.id)
    base = str(request.base_url).rstrip("/")
    done["address"] = proxy.own_address(
        done["address"],
        base,
        {"portal": portal, "source": done.get("source", ""), "buffer": done.get("buffer") or ""},
    )
    return done


#: How long `/stream` may resolve a played source again for its person (AP90).
#:
#: A film runs for hours and the relay re-resolves whenever the source's address
#: expired underneath it; the window has to outlast a long evening, not a
#: request.
GESPIELT_S: Final = 6 * 3600.0

#: `portal|source` → person → until when. In memory: after a restart the relay
#: is gone as well, and the app asks `/play` again.
_GESPIELT: dict[str, dict[str, float]] = {}
_GESPIELT_LOCK = threading.Lock()


def _gespielt_merken(portal_id: str, source: str, person_id: str) -> None:
    """Remember who `/play` resolved this source for — the only way `/stream` learns it."""
    if not source:
        return
    now = time.time()
    with _GESPIELT_LOCK:
        _GESPIELT.setdefault(portal_id + "|" + source, {})[person_id] = now + GESPIELT_S
        if len(_GESPIELT) > 2000:
            for k in [k for k, w in _GESPIELT.items() if max(w.values()) < now]:
                _GESPIELT.pop(k, None)


def _nachaufloesen(request: Request, m: Manifest | None, source: str) -> str | None:
    """Resolve a source again — **only for somebody who may still see the portal.**

    Gap L2 (AP90, 16.11.2026): the player sends no header, so `/stream` knew no
    person and resolved whatever portal stood in the query, past switch, role
    and age lock. Now it takes the people `/play` resolved exactly this source
    for, and asks `household/zugang.py` for each of them — switched off in the
    meantime means no new address.
    """
    if m is None or not source:
        return None
    now = time.time()
    with _GESPIELT_LOCK:
        wer = [p for p, bis in _GESPIELT.get(m.id + "|" + source, {}).items() if bis >= now]
    d = _dienste(request)
    for pid in wer:
        person = d.people.by_id(pid)
        if person is not None and d.access.check(person, m).allowed:
            return playback.resolve_again(m, source)
    return None


@router.api_route("/stream", methods=["GET", "HEAD"])
def stream(
    request: Request,
    address: str,
    portal: str = Query(""),
    source: str = Query(""),
    buffer_token: str = Query("", alias="buffer"),
) -> Response:
    """Relay the video stream.

    Only what `/play` resolved itself is cleared — otherwise this would be an
    open forwarder for every address in the world.
    """
    if buffer_token and buffer.has(buffer_token):
        if request.method == "HEAD":
            answered = buffer.head(buffer_token)
            if answered:
                return Response(status_code=answered[0], headers=answered[1])
        else:
            read_bytes = buffer.read_range(buffer_token, request.headers.get("range"))
            if read_bytes:
                progress, head, chunks = read_bytes
                return StreamingResponse(chunks, status_code=progress, headers=head)
        raise f.Error("stream.buffer_gone", status=502)

    if not proxy.is_allowed(address):
        raise f.Error("stream.not_ours", status=403)

    d = _dienste(request)
    m = d.registry.manifests.get(portal) if portal else None
    base = str(request.base_url).rstrip("/")

    if request.method == "HEAD":
        try:
            progress, head = proxy.head_only(address)
        except Exception:
            fresh = _nachaufloesen(request, m, source)
            if not fresh:
                raise f.Error("stream.head_failed", status=502) from None
            progress, head = proxy.head_only(fresh)
        return Response(status_code=progress, headers=head)

    try:
        progress, head, body, whole = proxy.fetch(address, request.headers.get("range"), base)
    except Exception:
        fresh = _nachaufloesen(request, m, source)
        if not fresh or fresh == address:
            raise f.Error("stream.host_silent", status=502) from None
        progress, head, body, whole = proxy.fetch(fresh, request.headers.get("range"), base)

    if whole:
        return Response(content=body, status_code=progress, headers=head)
    # `whole` says which of the two cases it is; `body`'s common type cannot.
    assert not isinstance(body, bytes)
    return StreamingResponse(body, status_code=progress, headers=head)
