"""Signing in to the console.

**The browser is just a device too.** It does not pair by code — it stands in
front of the same person who knows the PIN. So: name and PIN in, device token
out, and from then on it is a device like any other. That way there is exactly
*one* path by which somebody reaches data, and not two.

**The roles hold unchanged.** A browser a child signs in at gets a child's
rights — and `/household/devices` stays shut.
"""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Body, Request

from cinelounge.core import errors as f
from cinelounge.household.people import Person
from cinelounge.web import firstrun
from cinelounge.web.access import Anyone, services

router = APIRouter()


@router.post("/setup")
def first_run(
    request: Request,
    code: Annotated[str, Body(embed=True)],
    name: Annotated[str, Body(embed=True)],
    pin: Annotated[str, Body(embed=True)],
) -> dict[str, Any]:
    """Create the household — once, with the code from the log.

    **The only route that creates something without a token.** That is why it
    stands under three conditions: the household must be empty, the code must
    match, and afterwards neither exists any more.

    The first person is an **admin**, and that is not a choice: a household
    without an admin could never create anybody again.
    """
    d = services(request)
    # **The household first, then the code.** Whoever comes too late should not
    # be able to read from the answer whether their guessed code was right.
    if not d.people.is_empty():
        raise f.Error("setup.done", status=409)
    if not firstrun.check(code):
        raise f.Error("setup.bad_code", status=403)

    person = d.people.create(name.strip()[:60] or "Admin", "admin", pin.strip())
    firstrun.spend()

    from_where = request.client.host if request.client else ""
    pending = d.devices.request_code("Console in the browser", "web", from_where)
    token = d.devices.redeem(pending.token, user_id=person.id, from_where=from_where)
    d.events.record("event.household_created", {"who": person.name}, person.id)
    return {
        "device_token": token,
        "person": {
            "id": person.id,
            "name": person.name,
            "role": person.role,
            "color": person.color,
            "adult": person.adult,
        },
    }


@router.post("/login")
def sign_in(
    request: Request,
    name: Annotated[str, Body(embed=True)],
    pin: Annotated[str, Body(embed=True)],
    device: Annotated[str, Body(embed=True)] = "Browser",
) -> dict[str, Any]:
    """Trade name and PIN for a device token.

    `name` is the person's **id** (`max`), not the display name — the
    interface fetches it from `/login/who` so that nobody has to guess.

    The attempt limit sits in `People.sign_in`: five wrong tries, then a minute
    of pause. A four-digit PIN without a limit is no PIN.
    """
    d = services(request)
    person = d.people.sign_in(name.strip().lower(), pin.strip())

    from_where = request.client.host if request.client else ""

    # **One browser, one row.** Otherwise the device list grows with every
    # sign-in: measured, 40 rows, nearly all of them "Browser", the same
    # machine, the same person. A list meant to show who has access is then only
    # paper.
    token = d.devices.browser_of(person.id, from_where)
    if token is None:
        pending = d.devices.request_code(device[:60] or "Browser", "web", from_where)
        token = d.devices.redeem(pending.token, user_id=person.id, from_where=from_where)
    return {
        "device_token": token,
        "person": {
            "id": person.id,
            "name": person.name,
            "role": person.role,
            "color": person.color,
            "adult": person.adult,
        },
    }


@router.get("/login/who")
def who_lives_here(request: Request) -> dict[str, Any]:
    """Who can sign in — callable **without** signing in.

    That is deliberately open: the names stand on every television in the living
    room anyway, and without this list somebody would have to guess their id.
    What protects is the PIN, not the secrecy of the names.

    **Children's profiles are not in it.** The console is no place for children;
    they sign in at the television, not in administration.
    """
    d = services(request)
    return {
        "setup_required": d.people.is_empty(),
        # **Whether a code lies ready for it, too.** The household cannot
        # become empty — the last admin stays — so in operation the two are
        # always the same. They stand apart nonetheless: whoever checks the
        # first run wants to know whether the code is armed, not to infer it.
        "setup_code_armed": firstrun.armed(),
        "people": [
            # `console`: the console's sign-in shows only these (09.11.2026);
            # the list stays as it was for whoever else reads it.
            {"id": p.id, "name": p.name, "role": p.role, "color": p.color, "console": p.console}
            for p in d.people.list_all()
            if p.adult or p.console
        ],
    }


@router.post("/redeem")
def redeem(
    request: Request,
    token: Annotated[str, Body(embed=True)],
    name: Annotated[str, Body(embed=True)] = "Device",
    kind: Annotated[str, Body(embed=True)] = "web",
) -> dict[str, Any]:
    """Trade a pairing token or an invitation for a device token.

    **Without signing in, and that is no hole.** The token *is* the proof: it is
    random, valid once and expires. Exactly this path is taken by the Apple TV
    after the code and by the invitation link — the same route, so that there
    are not two redemption paths of which one is forgotten at the next rebuild.

    Who the device belongs to is already settled with an invitation; with a
    pairing the admin assigns it afterwards
    (`/household/devices/{id}/person`).
    """
    # **Only the pairing code is upper-cased.** It has six characters out of
    # the upper-case die and is read off a television — whoever types it in
    # lower case means the same one. An invitation token is 22 characters and
    # lower case; a blanket `.upper()` made it impossible to find.
    raw = token.strip()
    d = services(request)
    from_where = request.client.host if request.client else ""
    token = d.devices.redeem(
        raw.upper() if len(raw) == 6 else raw, name=name[:60], kind=kind, from_where=from_where
    )
    g = d.devices.by_token(token)
    person = d.people.by_id(g.user_id) if g and g.user_id else None
    # **Without `who`.** Whoever redeemed the code is the device itself — nobody
    # is signed in yet, and with a pairing the person is settled only
    # afterwards anyway.
    d.events.record("event.device_paired", {"name": (g.name if g else ""), "kind": kind})
    return {
        "device_token": token,
        "person": None
        if person is None
        else {
            "id": person.id,
            "name": person.name,
            "role": person.role,
            "color": person.color,
            "adult": person.adult,
        },
    }


@router.post("/logout")
def sign_out(request: Request, person: Anyone) -> dict[str, Any]:
    """Hand this browser's access back.

    Not only forget the token — the device disappears from the list. A signed-out
    browser left standing as a device is a row nobody can place any more.
    """
    token = request.headers.get("x-cl-device", "")
    d = services(request)
    g = d.devices.by_token(token)
    if g:
        d.devices.revoke_device(g.id)
    return {"ok": True}


# ── Beitritt (AP47): anfragen, nachfragen, mit der Marke anmelden ─────────────
#
# **Hier und nicht in `admin.py`.** Diese Datei ist die ohne `Depends`-Sperre,
# und ihr Kopftext sagt, warum sie das sein darf: Die Marke *ist* der Ausweis.
# Ein offener Weg zwischen den gesperrten in `admin.py` wäre genau die eine
# Zeile, die beim nächsten Zusatz überlesen wird.


def _person_json(p: Person) -> dict[str, Any]:
    return {"id": p.id, "name": p.name, "role": p.role, "color": p.color, "adult": p.adult}


@router.post("/join", status_code=202)
def ask_to_join(
    request: Request,
    name: Annotated[str, Body(embed=True)],
    want: Annotated[list[str], Body(embed=True)],
    color: Annotated[str, Body(embed=True)] = "#E2564A",
    device: Annotated[str, Body(embed=True)] = "",
    kind: Annotated[str, Body(embed=True)] = "web",
) -> dict[str, Any]:
    """Eine Person bittet um Aufnahme. `202`: angenommen, nicht erledigt.

    **Keine Rolle im Rumpf.** Was jemand *will*, sagt er; was er *ist*, sagt
    der Verwalter. Stünde die Rolle hier, könnte ein Fremder `admin` verlangen.
    **Keine PIN** (Entscheidung 8.1 a) und **kein `from`**: Die Herkunft ist
    die Adresse der Anfrage, und die kann eine App nicht angeben, ohne sie auch
    falsch angeben zu können.
    """
    d = services(request)
    from_where = request.client.host if request.client else ""
    o = d.joins.ask(name, color, want, device, kind, from_where)
    # **Ohne Person** — es ist noch niemand. Das Feld ist ohnehin `NULL`-fähig.
    d.events.record(
        "event.join_requested", {"name": o.name, "device": o.device_name, "from": from_where}
    )
    return {"request": o.token, "state": "pending", "expires_in_s": round(o.remaining_s)}


@router.get("/join/{token}")
def join_state(request: Request, token: str) -> dict[str, Any]:
    """Nachfragen, wie es um die Anfrage steht — die Anfragemarke ist der Ausweis.

    Nach der Freigabe steht in derselben Antwort schon das Gerätemerkmal, in
    derselben Form wie bei `/login` und `/redeem` (`device_token` + `person`),
    dazu die Personenmarke fürs Profil. Ein zweiter Schritt über
    `/device/enroll` wäre nur ein Schritt mehr, der scheitern kann.
    """
    d = services(request)
    from_where = request.client.host if request.client else ""
    a = d.joins.poll(token.strip(), from_where)
    if a.state == "pending":
        return {"state": "pending", "expires_in_s": round(a.remaining_s)}
    if a.state == "declined" or a.person is None:
        return {"state": "declined"}
    return {
        "state": "approved",
        "device_token": a.device_token,
        # `null` bei einem Kind: Es trägt keine Marke (Entscheidung 14).
        "person_mark": a.mark or None,
        "person": _person_json(a.person),
    }


@router.post("/device/enroll")
def enroll(
    request: Request,
    mark: Annotated[str, Body(embed=True)],
    name: Annotated[str, Body(embed=True)] = "Device",
    kind: Annotated[str, Body(embed=True)] = "web",
) -> dict[str, Any]:
    """Die Personenmarke gegen ein Gerätemerkmal tauschen.

    **Das Gerät gehört danach der Person** — es ist ihr Gerät, sie hat sich mit
    ihrer Marke gemeldet. Ein geteilter Wohnzimmerfernseher wird deshalb nicht
    so angemeldet: Er gehört niemandem, und eine freigegebene Person steht in
    seinem Profilwähler ohnehin.

    Die Antwort hat dieselbe Form wie `/login` und `/redeem`, damit die App
    keinen neuen Typ braucht.
    """
    d = services(request)
    from_where = request.client.host if request.client else ""
    secret, person = d.joins.enroll(mark.strip(), name, kind, from_where)
    d.events.record("event.device_enrolled", {"name": name[:60], "person": person.name}, person.id)
    return {"device_token": secret, "person": _person_json(person)}
