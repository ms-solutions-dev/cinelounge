"""The routes — and above all whom they answer.

**The heart of this file is not that something works but that something does
NOT.** A child's device calling an 18+ portal's route directly has to get a
403 — not the list, and not an empty list. The bridge checks nothing at this
point; whoever reaches it gets every portal.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from cinelounge.household.devices import Devices
from cinelounge.household.people import People
from cinelounge.household.visibility import Visibility
from cinelounge.web.access import Services

MANIFEST_AHORN = """
api: 1
id: ahorn
name: {de: Ahorn Mediathek, en: Ahorn Media Library}
kind: native
capabilities: [search, seasons]
enabled: true
"""

MANIFEST_ADULT = """
api: 1
id: nightshift
name: Night programme
kind: native
adult: true
enabled: true
"""

MANIFEST_BROKEN = """
api: 1
id: broken
name: Broken
kind: native
proxy: true
"""


@pytest.fixture
def world(tmp_path, monkeypatch):
    """A complete household with three people, three devices, three portals."""
    for name, body in (
        ("ahorn", MANIFEST_AHORN),
        ("nightshift", MANIFEST_ADULT),
        ("broken", MANIFEST_BROKEN),
    ):
        folder = tmp_path / "portals" / name
        folder.mkdir(parents=True)
        open(folder / "portal.yml", "w", encoding="utf-8").write(body)
        if name != "broken":
            (folder / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")

    monkeypatch.setenv("CL_DATA", str(tmp_path))
    import importlib

    from cinelounge.web import main

    importlib.reload(main)
    main.app.state.services = Services.from_path(tmp_path)
    d = main.app.state.services

    people = People(d.store)
    people.create("Max", "admin", "1234")
    people.create("Sina", "adult", "1234")
    people.create("Eli", "child", "1111")

    dev = Devices(d.store)
    tokens = {}
    for current_person in ("max", "sina", "eli"):
        o = dev.request_code(current_person + "-Gerät", "iOS 18.7", "192.0.2.5")
        tokens[current_person] = dev.redeem(o.token, user_id=current_person)
    shared = dev.request_code("Apple TV", "tvOS 18.4", "192.0.2.33")
    tokens["shared"] = dev.redeem(shared.token, user_id=None)

    vis = Visibility(d.store)
    for current_person in ("sina", "eli"):
        vis.set_allowed(current_person, "ahorn", True)
    vis.set_allowed("sina", "nightshift", True)
    vis.set_allowed("eli", "nightshift", True)  # granted — and locked all the same

    return TestClient(main.app), tokens


def get_as(world, path, current_person, **head):
    client, tokens = world
    k = {"X-CL-Device": tokens[current_person], **head}
    return client.get(path, headers=k)


# ── Without a token nothing works ────────────────────────────────────────────


def test_ohne_geraet_kein_zutritt(world):
    client, _ = world
    for path in ("/portals", "/state?key=x", "/favorites", "/p/ahorn/menu"):
        a = client.get(path)
        assert a.status_code == 401, path
        assert a.json()["error"]["code"] == "auth.required"


def test_selbstauskunft_und_health_brauchen_nichts(world):
    """The app has to find out from an address alone what it is talking to."""
    client, _ = world
    a = client.get("/.well-known/cinelounge")
    assert a.status_code == 200
    assert a.json()["api"] == [1, 2], "2 seit AP47 — und die 1 bleibt für ältere Apps"
    assert a.json()["setup_required"] is False
    assert client.get("/health").status_code == 200


# ── The age lock is a rule, not a display property ───────────────────────────


def test_kind_sieht_das_portal_ab_18_nicht(world):
    names = [p["id"] for p in get_as(world, "/portals", "eli").json()["portals"]]
    assert "ahorn" in names
    assert "nightshift" not in names


def test_kind_bekommt_403_wenn_es_die_adresse_direkt_abruft(world):
    """**Hiding is not a lock.**

    The usability pass of the phone app found exactly this fault once before:
    the parental lock claimed to lock what it did not lock.
    """
    a = get_as(world, "/p/nightshift/menu", "eli")
    assert a.status_code == 403
    assert a.json()["error"]["code"] == "auth.forbidden"


def test_erwachsene_duerfen_es(world):
    """The access then fails at the portal itself, not at the role."""
    a = get_as(world, "/p/nightshift/menu", "sina")
    assert a.status_code != 403


# ── Roles at the administrative routes ───────────────────────────────────────


def test_nur_der_admin_sieht_die_geraete(world):
    assert get_as(world, "/household/devices", "max").status_code == 200
    for current_person in ("sina", "eli"):
        a = get_as(world, "/household/devices", current_person)
        assert a.status_code == 403
        assert a.json()["error"]["code"] == "auth.forbidden"


def test_freigabe_entscheidet_was_jemand_sieht(world):
    _, _ = world
    # Max has not a single permission — as admin he still sees everything active.
    assert {p["id"] for p in get_as(world, "/portals", "max").json()["portals"]} == {
        "ahorn",
        "nightshift",
    }
    assert {p["id"] for p in get_as(world, "/portals", "sina").json()["portals"]} == {
        "ahorn",
        "nightshift",
    }


def test_defektes_portal_faellt_auf_statt_still_zu_wirken(world):
    """`durchreichen:` stands in two of the bridge's manifests and has done
    nothing since 29.08. — silently ignored. Here it aborts."""
    client, _ = world
    status = client.get("/health").json()
    assert status["ready"] == 2
    assert status["broken"][0]["id"] == "broken"
    assert "proxy" in status["broken"][0]["reason"]


# ── Shared devices ───────────────────────────────────────────────────────────


def test_geteiltes_geraet_muss_ein_profil_nennen(world):
    """A television in the living room belongs to nobody."""
    a = get_as(world, "/portals", "shared")
    assert a.status_code == 401
    assert a.json()["error"]["code"] == "auth.profile_required"


def test_geteiltes_geraet_mit_profil_sieht_dessen_sicht(world):
    a = get_as(world, "/portals", "shared", **{"X-CL-Profile": "eli"})
    assert a.status_code == 200
    assert {p["id"] for p in a.json()["portals"]} == {"ahorn"}


# ── The progress belongs to the person, not the device ───────────────────────


def test_stand_ist_je_person_getrennt(world):
    client, tokens = world
    client.post(
        "/state",
        headers={"X-CL-Device": tokens["sina"]},
        json={
            "key": "ahorn:krimireihe:",
            "title": "Krimireihe",
            "position_s": 600,
            "duration_s": 5400,
        },
    )
    meiner = client.get("/state?key=ahorn:krimireihe:", headers={"X-CL-Device": tokens["sina"]})
    assert meiner.status_code == 200
    assert meiner.json()["position_s"] == 600

    # The same id, another person: nothing.
    fremder = client.get("/state?key=ahorn:krimireihe:", headers={"X-CL-Device": tokens["max"]})
    assert fremder.status_code == 404


def test_gesehen_setzt_sich_selbst(world):
    """No credits run to the last second."""
    client, tokens = world
    head = {"X-CL-Device": tokens["sina"]}
    client.post(
        "/state", headers=head, json={"key": "ahorn:film:", "position_s": 5300, "duration_s": 5400}
    )
    assert client.get("/state?key=ahorn:film:", headers=head).json()["watched"] is True


def test_teilmeldung_loescht_nichts(world):
    """The Apple TV reports only its position every ten seconds."""
    client, tokens = world
    head = {"X-CL-Device": tokens["sina"]}
    client.post("/state", headers=head, json={"key": "ahorn:serie:", "favorite": True})
    client.post("/state", headers=head, json={"key": "ahorn:serie:", "position_s": 42})
    e = client.get("/state?key=ahorn:serie:", headers=head).json()
    assert e["favorite"] is True
    assert e["position_s"] == 42


def test_weiterschauen_zeigt_nur_angefangenes(world):
    client, tokens = world
    head = {"X-CL-Device": tokens["sina"]}
    client.post(
        "/state", headers=head, json={"key": "ahorn:kurz:", "position_s": 5, "duration_s": 3000}
    )
    client.post(
        "/state", headers=head, json={"key": "ahorn:lang:", "position_s": 900, "duration_s": 3000}
    )
    kennungen = [x["key"] for x in client.get("/resume", headers=head).json()["resumable"]]
    assert "ahorn:lang:" in kennungen
    assert "ahorn:kurz:" not in kennungen  # under 30 s is a peek, not a start


def test_play_bricht_nicht_an_einer_methode_die_das_portal_nicht_hat(world):
    """`/play?address=` looks the language up — and took everything down with it.

    **Found 10.09.2026 on the running service, not here.** `play()` called
    `series` to find the last chosen language version. A media-library portal
    does not have that method, and the runner made `run.crashed` of it — for
    ZDF, ARD, arte, 3sat, that is, for exactly the starter set.

    Why nobody noticed: the workshop pass takes the way over `source=`, and
    `series` is never called there. The app takes `address=`.

    The test does **not** check that `/play` succeeds — the test portal has no
    methods at all. It checks that the error is no longer called `series`.
    """
    client, tokens = world
    a = client.get(
        "/play",
        params={"portal": "ahorn", "address": "/irgendein/eintrag"},
        headers={"X-CL-Device": tokens["max"]},
    )
    assert "series" not in a.text, f"`series` still takes playback down: {a.text[:300]}"


def test_der_laeufer_kennt_nur_seine_eigenen_namen():
    """`__all__` named three names that no longer exist.

    After the rename to English `rufe`, `vorladen`, `METHODEN` still stood
    there. A `from ... import *` would have failed on it, and nobody would have
    noticed — nobody does that. Still, a list that lies is worse than none.
    """
    from cinelounge.portalworks.runner import call as modul

    for name in modul.__all__:
        assert hasattr(modul, name), f"__all__ names {name!r}, the module does not have it"


def test_stand_mit_art_wird_geschrieben(world):
    """`POST /state` mit gesetztem `kind` muss 200 geben und die Art tragen.

    **Befund vom 12.09.2026, belegt am 24.09.:** `Progress.update` schrieb in
    die Spalte `art`, die seit Migration 2 `kind` heisst. Jede Meldung mit Art
    lief in `no such column: art` und kam als 500 zurueck; die App schickt die
    Art deshalb nach einem 5xx ein zweites Mal ohne sie (`PortalSource.swift`,
    `nochmalOhneArt`). Genau dieser Umweg darf erst fallen, wenn diese Pruefung
    gruen ist.
    """
    client, tokens = world
    head = {"X-CL-Device": tokens["sina"]}
    a = client.post(
        "/state",
        headers=head,
        json={
            "key": "ahorn:krimireihe:",
            "title": "Krimireihe",
            "kind": "series",
            "position_s": 60,
        },
    )
    assert a.status_code == 200, a.text
    assert client.get("/state?key=ahorn:krimireihe:", headers=head).json()["kind"] == "series"


# ── Resume and favourites only from portals the person sees (AP60, 30.09.2026) ──
#
# The owner: two portals are switched off, and once their titles turned up in
# "Weiterschauen" all the same — "das darf definitiv nicht passieren".
# The server delivered every row ever started and left the sieving to each app.


def _angefangen(client, head, key, portal=None, favorit=False):
    body = {"key": key, "position_s": 900, "duration_s": 3000}
    if portal:
        body["portal"] = portal
    if favorit:
        body["favorite"] = True
    client.post("/state", headers=head, json=body)


def test_weiterschauen_nur_aus_sichtbaren_portalen(world):
    client, tokens = world
    head = {"X-CL-Device": tokens["sina"]}
    _angefangen(client, head, "ahorn:lang:", portal="ahorn")
    _angefangen(client, head, "nightshift:spaet:", portal="nightshift")
    _angefangen(client, head, "broken:kaputt:", portal="broken")
    _angefangen(client, head, "nachtfalter:aus:", portal="nachtfalter")
    # An old row without the portal field: the key names it.
    _angefangen(client, head, "nachtfalter:alt:")
    _angefangen(client, head, "ohnedoppelpunkt")

    kennungen = {x["key"] for x in client.get("/resume", headers=head).json()["resumable"]}

    assert kennungen == {"ahorn:lang:", "nightshift:spaet:"}


def test_ausgeschaltet_heisst_auch_aus_weiterschauen_und_favoriten(world):
    client, tokens = world
    head = {"X-CL-Device": tokens["sina"]}
    _angefangen(client, head, "nightshift:spaet:", portal="nightshift", favorit=True)
    _angefangen(client, head, "ahorn:lang:", portal="ahorn", favorit=True)

    from cinelounge.web import main

    Visibility(main.app.state.services.store).set_allowed("sina", "nightshift", False)

    weiter = {x["key"] for x in client.get("/resume", headers=head).json()["resumable"]}
    favoriten = {x["key"] for x in client.get("/favorites", headers=head).json()["favorites"]}
    assert weiter == {"ahorn:lang:"}
    assert favoriten == {"ahorn:lang:"}


def test_ein_kind_bekommt_nichts_ueber_seiner_grenze(world):
    """Eli may see `nightshift` by permission — the age lock wins, here as in `/portals`."""
    client, tokens = world
    head = {"X-CL-Device": tokens["eli"]}
    _angefangen(client, head, "nightshift:spaet:", portal="nightshift", favorit=True)
    _angefangen(client, head, "ahorn:kinder:", portal="ahorn", favorit=True)

    weiter = {x["key"] for x in client.get("/resume", headers=head).json()["resumable"]}
    favoriten = {x["key"] for x in client.get("/favorites", headers=head).json()["favorites"]}
    assert weiter == {"ahorn:kinder:"}
    assert favoriten == {"ahorn:kinder:"}


def test_a_child_gets_nothing_hidden_through_any_route(world):
    """Owner, 09.11.2026: what a child does not see must not get through anywhere —
    no "continue watching", no direct key, no search hit, no menu, no playback.

    Eli's role lists the 18+ portal `nightshift`; the age lock must win on every
    route, on his own device and on the shared television alike.
    """
    client, tokens = world
    own = {"X-CL-Device": tokens["eli"]}
    _angefangen(client, own, "nightshift:spaet:", portal="nightshift", favorit=True)
    _angefangen(client, own, "nightshift:alt:")  # old row, portal only in the key

    shared = {"X-CL-Device": tokens["shared"], "X-CL-Profile": "eli"}
    for head in (own, shared):
        assert "nightshift" not in {
            p["id"] for p in client.get("/portals", headers=head).json()["portals"]
        }
        assert client.get("/resume", headers=head).json()["resumable"] == []
        assert client.get("/favorites", headers=head).json()["favorites"] == []
        for key in ("nightshift:spaet:", "nightshift:alt:"):
            assert client.get(f"/state?key={key}", headers=head).status_code == 404, key
        for path in (
            "/p/nightshift/menu",
            "/p/nightshift/list",
            "/play?portal=nightshift&address=x",
        ):
            assert client.get(path, headers=head).status_code == 403, path
        hits = client.get("/search?q=spaet", headers=head).json()
        assert "nightshift" not in hits["hits"] and "nightshift" not in hits["failed"]


def test_die_grenze_zaehlt_nach_dem_sieben(world):
    """`LIMIT` counts what is shown — ten hidden rows must not crowd out the one visible."""
    client, tokens = world
    head = {"X-CL-Device": tokens["sina"]}
    _angefangen(client, head, "ahorn:lang:", portal="ahorn")
    for n in range(10):
        _angefangen(client, head, f"nachtfalter:t{n}:", portal="nachtfalter")

    antwort = client.get("/resume?limit=1", headers=head).json()["resumable"]

    assert [x["key"] for x in antwort] == ["ahorn:lang:"]


def test_die_serie_einer_folge_kommt_in_weiterschauen_an(world):
    """AP63, 01.10.2026: "Details" aus Weiterschauen zeigte nur die Folge — die Zeile
    kannte ihre Serie nicht. Die App schickt die Kennung der Serienseite mit."""
    client, tokens = world
    head = {"X-CL-Device": tokens["sina"]}
    serie = "ahorn|ahorn:krimireihe:|f=showSeasons&x=1"
    body = {
        "key": "ahorn:folge-1:",
        "kind": "episode",
        "series": serie,
        "position_s": 300,
        "duration_s": 3000,
    }
    assert client.post("/state", headers=head, json=body).status_code == 200
    # Eine spaetere Meldung ohne Serie loescht sie nicht.
    client.post("/state", headers=head, json={"key": "ahorn:folge-1:", "position_s": 400})
    zeilen = client.get("/resume", headers=head).json()["resumable"]
    zeile = next(z for z in zeilen if z["key"] == "ahorn:folge-1:")
    assert zeile["series"] == serie
