"""A shared device borrows a profile — and may watch with it.

**The case this file exists for.** A television in the living room belongs to
nobody; whoever sits in front of it picks a profile at startup, and that then
stands in `X-CL-Profile`. Until 11.09.2026 that header was a complete sign-in:
on the running service `X-CL-Profile: max` from a test device without a
person gave 200 on `/household/backup` — 1845 bytes of household —, 200 on the
event book, and switched a portal off. No PIN, no sign-in, one header.

`current_person`'s docstring said even then that the person comes "from the
token and never from a parameter, otherwise the parental lock would be a matter
of politeness". On a shared device it came from exactly a parameter.

**What is checked is the line, not the lock:** watching stays, administering
only works from a device that belongs to a person.
"""

from __future__ import annotations

import pytest

from tests.test_web import world  # noqa: F401

# ── Without a profile nothing works ─────────────────────────────────────────


def test_ohne_profil_fragt_das_geraet_zuerst(world):  # noqa: F811
    client, tokens = world
    antwort = client.get("/portals", headers={"X-CL-Device": tokens["shared"]})
    assert antwort.status_code == 401
    assert antwort.json()["error"]["code"] == "auth.profile_required"


# ── Watching stays ──────────────────────────────────────────────────────────


def test_ein_geliehenes_profil_darf_schauen(world):  # noqa: F811
    """**Otherwise the television would be broken**, and it is the device's purpose."""
    client, tokens = world
    koepfe = {"X-CL-Device": tokens["shared"], "X-CL-Profile": "max"}

    assert client.get("/portals", headers=koepfe).status_code == 200
    ich = client.get("/household/me", headers=koepfe)
    assert ich.status_code == 200
    assert ich.json()["role"] == "admin", "the person is the same — only the way there differs"


def test_auch_das_kinderprofil_darf_schauen(world):  # noqa: F811
    """The lock sits on the path and not on the role."""
    client, tokens = world
    koepfe = {"X-CL-Device": tokens["shared"], "X-CL-Profile": "eli"}
    assert client.get("/portals", headers=koepfe).status_code == 200


# ── Administering does not ──────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("weg", "art", "leib"),
    [
        ("/household/backup", "get", None),
        ("/household/events", "get", None),
        ("/household/settings", "get", None),
        ("/household/portals", "get", None),
        ("/household/market/sources", "get", None),
        ("/household/portals/ahorn/switch", "post", {"on": False}),
        ("/household/devices/code", "post", {"name": "x", "kind": "tv"}),
        ("/household/nights/run", "post", {}),
    ],
)
def test_ein_geliehenes_profil_verwaltet_nichts(world, weg, art, leib):  # noqa: F811
    """Every one of these routes returned a measured 200 on 11.09.2026.

    The backup was the worst: **the whole household as one file**, callable
    from a device nobody ever signed in at.
    """
    client, tokens = world
    koepfe = {"X-CL-Device": tokens["shared"], "X-CL-Profile": "max"}

    antwort = getattr(client, art)(weg, headers=koepfe, **({"json": leib} if leib else {}))
    assert antwort.status_code == 403, f"{weg} stands open to a borrowed profile"
    assert antwort.json()["error"]["code"] == "auth.borrowed_profile"


def test_dasselbe_profil_am_eigenen_geraet_darf_alles(world):  # noqa: F811
    """**The cross-check, and without it the rest checks nothing.**

    If the lock sat on the right instead of the path, everything above would
    look the same — and the admin could no longer reach the backup from their
    own machine.
    """
    client, tokens = world
    antwort = client.get("/household/backup", headers={"X-CL-Device": tokens["max"]})
    assert antwort.status_code == 200

    schalten = client.post(
        "/household/portals/ahorn/switch",
        json={"on": True},
        headers={"X-CL-Device": tokens["max"]},
    )
    assert schalten.status_code == 200


def test_die_grenze_ist_eine_erlaubnisliste():
    """Everything not expressly allowed is locked.

    The reverse list — "these rights are forbidden" — would be quietly open at
    the next new right: whoever adds one and forgets the list would have given
    it to the television.
    """
    from cinelounge.household.people import RIGHTS
    from cinelounge.web.access import BORROWED_RIGHTS

    assert set(RIGHTS) >= BORROWED_RIGHTS, "a right that does not exist at all"
    verwaltung = set(RIGHTS) - BORROWED_RIGHTS
    for recht in ("pair_devices", "change_settings", "install_portals", "switch_portals"):
        assert recht in verwaltung, f"{recht} stands open to a borrowed profile"
