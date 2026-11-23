"""Beitritt (AP47): Anfrage, Freigabe, Personenmarke — und vor allem die Absagen.

**Der zweite offene Schreibweg des Dienstes nach `POST /setup`.** Deshalb prüft
diese Datei weniger, dass etwas geht, als dass etwas **nicht** geht: Die
Drossel greift und überlebt einen Neustart, eine Frist läuft ab, eine Freigabe
ohne die PIN des Verwalters oder ohne Rolle sagt ab, ein geliehenes Profil gibt
nichts frei, und der Widerruf einer Marke nimmt jedes Gerät mit, das über sie
kam — aber keines, das anders hereinkam.

Jeder dieser Wächter ist beim Bau einmal entschärft worden, und die Prüfung
hier ist dabei rot geworden (Gegenprobe, 24.09.2026).
"""

from __future__ import annotations

import sqlite3
import time

import pytest
from fastapi.testclient import TestClient

from cinelounge.core import errors as f
from cinelounge.household import store as store_modul
from cinelounge.household.devices import Devices
from cinelounge.household.joins import FETCH_GRACE_S, MAX_OPEN, Joins
from cinelounge.household.people import People
from cinelounge.household.store import Store
from cinelounge.web.access import Services

MANIFEST_AHORN = """
api: 1
id: ahorn
name: Ahorn
kind: native
enabled: true
"""

MANIFEST_NACHT = """
api: 1
id: nightshift
name: Night programme
kind: native
adult: true
enabled: true
"""

SELIN = {"name": "Selin", "color": "#4A90D9", "device": "Selins iPhone", "kind": "web"}


def _dienst(tmp_path, monkeypatch, *, leer: bool = False):
    for name, body in (("ahorn", MANIFEST_AHORN), ("nightshift", MANIFEST_NACHT)):
        ordner = tmp_path / "portals" / name
        ordner.mkdir(parents=True)
        (ordner / "portal.yml").write_text(body, encoding="utf-8")
        (ordner / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")

    monkeypatch.setenv("CL_DATA", str(tmp_path))
    import importlib

    from cinelounge.web import main

    importlib.reload(main)
    main.app.state.services = Services.from_path(tmp_path)
    d = main.app.state.services
    tokens: dict[str, str] = {}
    if not leer:
        d.people.create("Max", "admin", "1234")
        d.people.create("Sina", "adult", "5678")
        for wer in ("max", "sina"):
            o = d.devices.request_code(wer, "ios", "192.0.2.5")
            tokens[wer] = d.devices.redeem(o.token, user_id=wer)
        o = d.devices.request_code("Apple TV", "tv", "192.0.2.33")
        tokens["shared"] = d.devices.redeem(o.token, user_id=None)
    return TestClient(main.app), tokens, d


@pytest.fixture
def haus(tmp_path, monkeypatch):
    return _dienst(tmp_path, monkeypatch)


def _als(tokens, wer, **mehr):
    return {"X-CL-Device": tokens[wer], **mehr}


def _anfragen(client, **mehr):
    a = client.post("/join", json={**SELIN, "want": ["portals"], **mehr})
    assert a.status_code == 202, a.text
    return a.json()["request"]


def _freigeben(client, tokens, anfrage, role="adult", pin="1234", **mehr):
    return client.post(
        f"/household/joins/{anfrage}/approve",
        headers=_als(tokens, "max"),
        json={"role": role, "pin": pin, **mehr},
    )


def _code(a):
    return a.json()["error"]["code"]


# ── Die Anfrage ──────────────────────────────────────────────────────────────


def test_eine_anfrage_wird_angenommen_und_legt_nichts_an(haus):
    """Die Gegenprobe zuerst — sonst prüft der Rest nur, dass nichts geht."""
    client, tokens, d = haus
    anfrage = _anfragen(client)

    assert client.get(f"/join/{anfrage}").json()["state"] == "pending"
    offen = client.get("/household/joins", headers=_als(tokens, "max")).json()["requests"]
    assert [o["name"] for o in offen] == ["Selin"]
    assert offen[0]["from"] == "testclient" and offen[0]["device"] == "Selins iPhone"
    assert offen[0]["want"] == ["portals"] and offen[0]["color"] == "#4A90D9"
    assert 6 * 86400 < offen[0]["expires_in_s"] <= 7 * 86400
    assert d.people.by_id("selin") is None, "vor der Freigabe entsteht keine Person"


def test_unbekannte_wuensche_fallen_weg_und_ohne_wunsch_ist_schluss(haus):
    client, _, _ = haus
    a = client.post("/join", json={**SELIN, "want": ["portals", "live_shared"]})
    assert a.status_code == 202
    a = client.post("/join", json={**SELIN, "want": ["live_shared"]})
    assert a.status_code == 422 and _code(a) == "join.no_want"


def test_name_und_farbe_werden_geprueft(tmp_path):
    joins = Joins(Store(tmp_path / "h.sqlite"), People(Store(tmp_path / "h.sqlite")))
    joins.people.create("Max", "admin", "1234")
    with pytest.raises(f.Error) as e:
        joins.ask("   ", "#4A90D9", ["portals"], "", "", "a")
    assert e.value.code == "join.bad_name"
    with pytest.raises(f.Error) as e:
        joins.ask("Selin", "blau", ["portals"], "", "", "b")
    assert e.value.code == "join.bad_color"
    o = joins.ask("x" * 200, "#4a90d9", ["portals"], "", "", "c")
    assert len(o.name) == 60, "gekürzt, nicht abgesagt"


def test_ein_leerer_haushalt_nimmt_keine_anfrage(tmp_path, monkeypatch):
    """Sonst gehörte das Haus dem, der zuerst im WLAN ist."""
    client, _, d = _dienst(tmp_path, monkeypatch, leer=True)
    a = client.post("/join", json={**SELIN, "want": ["portals"]})
    assert a.status_code == 409 and _code(a) == "setup.required"
    assert d.people.is_empty()


def test_eine_rolle_in_der_anfrage_wird_nicht_gelesen(haus):
    """Was jemand *ist*, sagt der Verwalter — ein `role` im Rumpf zählt nicht."""
    client, tokens, d = haus
    anfrage = _anfragen(client, role="admin")
    assert _freigeben(client, tokens, anfrage, role="child").status_code == 200
    assert d.people.by_id("selin").role == "child"


# ── Drossel und Obergrenze ───────────────────────────────────────────────────


def test_die_drossel_greift_nach_drei_anfragen_in_der_stunde(haus):
    client, _, _ = haus
    for _ in range(3):
        _anfragen(client)
    a = client.post("/join", json={**SELIN, "want": ["portals"]})
    assert a.status_code == 429 and _code(a) == "join.too_often"
    assert 0 < a.json()["error"]["values"]["seconds"] <= 3600


def test_die_drossel_zaehlt_je_herkunft_und_ueberlebt_einen_neustart(tmp_path):
    """In der Ablage und nicht im Speicher: Watchtower startet den Container neu."""
    s = Store(tmp_path / "h.sqlite")
    People(s).create("Max", "admin", "1234")
    joins = Joins(s, People(s))
    for _ in range(3):
        joins.ask("Selin", "#4A90D9", ["portals"], "", "", "10.0.0.1")
    joins.ask("Eli", "#4A90D9", ["portals"], "", "", "10.0.0.2")  # andere Herkunft

    neu = Joins(Store(tmp_path / "h.sqlite"), People(Store(tmp_path / "h.sqlite")))
    with pytest.raises(f.Error) as e:
        neu.ask("Selin", "#4A90D9", ["portals"], "", "", "10.0.0.1")
    assert e.value.code == "join.too_often" and e.value.status == 429


def test_die_drossel_greift_auch_nach_zehn_am_tag(tmp_path):
    s = Store(tmp_path / "h.sqlite")
    People(s).create("Max", "admin", "1234")
    joins = Joins(s, People(s))
    vor_zwei_stunden = time.time() - 7200
    with s.connect() as v:
        for i in range(10):
            v.execute(
                "INSERT INTO throttle (scope, origin, at) VALUES ('join', '10.0.0.1', ?)",
                (vor_zwei_stunden + i,),
            )
    with pytest.raises(f.Error) as e:
        joins.ask("Selin", "#4A90D9", ["portals"], "", "", "10.0.0.1")
    assert e.value.code == "join.too_often"
    assert e.value.values["seconds"] > 3600, "frei erst, wenn der Tag herum ist"


def test_hoechstens_zehn_offene_anfragen(tmp_path):
    """Abgelehnt und nicht ersetzt: Die Liste des Verwalters ist das Gut."""
    s = Store(tmp_path / "h.sqlite")
    People(s).create("Max", "admin", "1234")
    joins = Joins(s, People(s))
    for i in range(MAX_OPEN):
        joins.ask(f"Gast {i}", "#4A90D9", ["portals"], "", "", f"10.0.0.{i}")
    with pytest.raises(f.Error) as e:
        joins.ask("Noch einer", "#4A90D9", ["portals"], "", "", "10.0.1.1")
    assert e.value.code == "join.too_many" and e.value.status == 409
    assert len(joins.open_requests()) == MAX_OPEN


# ── Frist ────────────────────────────────────────────────────────────────────


def test_eine_abgelaufene_anfrage_ist_unbekannt(haus):
    """Unbekannt und abgelaufen sind dieselbe Antwort — für den Server wie den Zuschauer."""
    client, tokens, d = haus
    anfrage = _anfragen(client)
    with d.store.connect() as v:
        v.execute("UPDATE join_request SET valid_until = ?", (time.time() - 1,))

    a = client.get(f"/join/{anfrage}")
    assert a.status_code == 404 and _code(a) == "join.unknown"
    assert client.get("/household/joins", headers=_als(tokens, "max")).json()["requests"] == []
    a = _freigeben(client, tokens, anfrage)
    assert a.status_code == 404 and _code(a) == "join.unknown"
    assert d.people.by_id("selin") is None


def test_nachfragen_mit_falscher_marke_wird_gedrosselt(haus):
    """Nur Fehlgriffe zählen — alle 15 Sekunden nachzufragen muss gehen."""
    client, _, _ = haus
    anfrage = _anfragen(client)
    for _ in range(20):
        assert client.get(f"/join/{anfrage}").status_code == 200
    for _ in range(3):
        assert client.get("/join/gibt-es-nicht").status_code == 404
    a = client.get(f"/join/{anfrage}")
    assert a.status_code == 429, "nach drei Fehlgriffen auch die richtige nicht mehr"


# ── Freigabe ─────────────────────────────────────────────────────────────────


def test_freigabe_ohne_gueltige_pin_des_verwalters_wird_abgewiesen(haus):
    client, tokens, d = haus
    anfrage = _anfragen(client)
    a = _freigeben(client, tokens, anfrage, pin="9999")
    assert a.status_code == 401 and _code(a) == "auth.bad_credentials"
    a = _freigeben(client, tokens, anfrage, pin="")
    assert a.status_code == 401
    assert d.people.by_id("selin") is None
    assert client.get(f"/join/{anfrage}").json()["state"] == "pending"


def test_freigabe_zaehlt_pin_fehlversuche_wie_die_anmeldung(haus):
    client, tokens, _ = haus
    anfrage = _anfragen(client)
    for _ in range(5):
        _freigeben(client, tokens, anfrage, pin="0000")
    a = _freigeben(client, tokens, anfrage, pin="1234")
    assert a.status_code == 429 and _code(a) == "auth.locked_out"


def test_freigabe_verlangt_eine_rolle_ohne_vorgabe(haus):
    client, tokens, d = haus
    anfrage = _anfragen(client)
    a = client.post(
        f"/household/joins/{anfrage}/approve", headers=_als(tokens, "max"), json={"pin": "1234"}
    )
    assert a.status_code == 422, "ohne Rolle sagt der Weg ab und rät nicht"
    for falsch in ("", "boss", "erwachsen"):
        a = _freigeben(client, tokens, anfrage, role=falsch)
        assert a.status_code == 422 and _code(a) == "household.unknown_role"
    assert d.people.by_id("selin") is None


def test_nur_der_verwalter_gibt_frei(haus):
    client, tokens, _ = haus
    anfrage = _anfragen(client)
    for weg, body in (
        ("GET", None),
        ("POST", {"role": "adult", "pin": "5678"}),
    ):
        pfad = "/household/joins" if weg == "GET" else f"/household/joins/{anfrage}/approve"
        a = client.request(weg, pfad, headers=_als(tokens, "sina"), json=body)
        assert a.status_code == 403 and _code(a) == "auth.forbidden"


def test_ein_geliehenes_profil_gibt_niemanden_frei(haus):
    """Wer am Wohnzimmerfernseher „Max“ wählt, ist nicht der Verwalter."""
    client, tokens, _ = haus
    anfrage = _anfragen(client)
    kopf = _als(tokens, "shared", **{"X-CL-Profile": "max"})
    a = client.post(
        f"/household/joins/{anfrage}/approve", headers=kopf, json={"role": "adult", "pin": "1234"}
    )
    assert a.status_code == 403 and _code(a) == "auth.borrowed_profile"
    for weg in ("POST", "DELETE"):
        a = client.request(weg, "/household/people/max/mark", headers=kopf)
        assert a.status_code == 403 and _code(a) == "auth.borrowed_profile", weg


def test_freigabe_legt_die_person_ohne_pin_an_und_das_geraet_kommt_herein(haus):
    client, tokens, _ = haus
    anfrage = _anfragen(client)
    a = _freigeben(client, tokens, anfrage)
    assert a.status_code == 200, a.text
    assert a.json()["person"] == {
        "id": "selin",
        "name": "Selin",
        "role": "adult",
        "color": "#4A90D9",
        "adult": True,
        "role_id": "adult",
        "console": False,
    }
    assert a.json()["portals"] == ["ahorn", "nightshift"]

    b = client.get(f"/join/{anfrage}").json()
    assert b["state"] == "approved" and b["person"]["id"] == "selin"
    assert b["person_mark"] and b["device_token"]
    ich = client.get("/household/me", headers={"X-CL-Device": b["device_token"]})
    assert ich.status_code == 200 and ich.json()["id"] == "selin"
    portale = client.get("/portals", headers={"X-CL-Device": b["device_token"]}).json()
    assert {p["id"] for p in portale["portals"]} >= {"ahorn"}
    assert client.get("/household/joins", headers=_als(tokens, "max")).json()["requests"] == []


def test_ein_kind_bekommt_kein_portal_ab_18_eingetragen(haus):
    client, tokens, d = haus
    anfrage = _anfragen(client)
    a = _freigeben(client, tokens, anfrage, role="child")
    assert a.json()["portals"] == ["ahorn"]
    # Since 09.11.2026 the role's list may name an 18+ portal; the age lock
    # (`view_adult`) keeps it out of what the child actually gets — above.
    assert "ahorn" in d.visibility.allowed_for("selin")


def test_ein_vergebener_name_wird_bei_der_freigabe_umbenannt(haus):
    """Kein Namensorakel bei der Anfrage — die Kollision sieht erst der Verwalter."""
    client, tokens, _ = haus
    anfrage = _anfragen(client, name="Sina")
    a = _freigeben(client, tokens, anfrage)
    assert a.status_code == 409 and _code(a) == "household.person_exists"
    a = _freigeben(client, tokens, anfrage, name="Sina K")
    assert a.status_code == 200 and a.json()["person"]["id"] == "sina-k"


def test_die_freigabe_ist_zweimal_abholbar_aber_nicht_den_ganzen_tag(haus):
    """Ein Absturz zwischen Antwort und Ablegen darf niemanden aussperren."""
    client, tokens, d = haus
    anfrage = _anfragen(client)
    _freigeben(client, tokens, anfrage)
    erste = client.get(f"/join/{anfrage}").json()
    zweite = client.get(f"/join/{anfrage}").json()
    assert erste["device_token"] == zweite["device_token"], "ein Gerät, nicht zwei"
    assert len([g for g in d.devices.list_all() if g.user_id == "selin"]) == 1
    with d.store.connect() as v:
        bis = v.execute("SELECT valid_until FROM join_request").fetchone()[0]
    assert bis <= time.time() + FETCH_GRACE_S + 1
    with d.store.connect() as v:
        v.execute("UPDATE join_request SET valid_until = ?", (time.time() - 1,))
    assert client.get(f"/join/{anfrage}").status_code == 404


def test_eine_ablehnung_ist_etwas_anderes_als_nichts(haus):
    client, tokens, d = haus
    anfrage = _anfragen(client)
    a = client.post(f"/household/joins/{anfrage}/decline", headers=_als(tokens, "max"))
    assert a.json() == {"declined": True}
    assert client.get(f"/join/{anfrage}").json() == {"state": "declined"}
    assert _freigeben(client, tokens, anfrage).status_code == 404
    assert d.people.by_id("selin") is None


# ── Die Personenmarke ────────────────────────────────────────────────────────


def _freigegeben(client, tokens):
    anfrage = _anfragen(client)
    _freigeben(client, tokens, anfrage)
    return client.get(f"/join/{anfrage}").json()


def test_mit_der_marke_meldet_sich_ein_weiteres_geraet_selbst_an(haus):
    client, tokens, _ = haus
    b = _freigegeben(client, tokens)
    a = client.post(
        "/device/enroll", json={"mark": b["person_mark"], "name": "Apple TV Selin", "kind": "tv"}
    )
    assert a.status_code == 200, a.text
    assert set(a.json()) == {"device_token", "person"}, "dieselbe Form wie /login und /redeem"
    assert a.json()["person"]["id"] == "selin"
    ich = client.get("/household/me", headers={"X-CL-Device": a.json()["device_token"]})
    assert ich.json()["id"] == "selin", "das Gerät gehört der Person, nicht dem Haushalt"


def test_eine_falsche_marke_bekommt_401_und_wird_gedrosselt(haus):
    client, tokens, _ = haus
    b = _freigegeben(client, tokens)
    for falsch in ("", "gibt-es-nicht", "x" * 43):
        a = client.post("/device/enroll", json={"mark": falsch})
        assert a.status_code == 401 and _code(a) == "enroll.unknown_mark"
    a = client.post("/device/enroll", json={"mark": b["person_mark"]})
    assert a.status_code == 429 and _code(a) == "enroll.too_often"


def test_der_widerruf_nimmt_jedes_geraet_der_marke_mit_und_gibt_eine_neue(haus):
    """Entscheidung 8.4: Der fremde Fernseher hat sich mit der alten Marke schon angemeldet."""
    client, tokens, d = haus
    b = _freigegeben(client, tokens)
    alt = b["person_mark"]
    ueber_marke = [b["device_token"]]
    for name in ("Apple TV Selin", "Fernseher der Oma"):
        a = client.post("/device/enroll", json={"mark": alt, "name": name})
        ueber_marke.append(a.json()["device_token"])
    # Ein Gerät, das anders hereinkam, bleibt.
    o = d.devices.request_code("Selins iPad", "ios", "")
    gekoppelt = d.devices.redeem(o.token, user_id="selin")

    a = client.delete("/household/people/selin/mark", headers=_als(tokens, "max"))
    assert a.status_code == 200, a.text
    neu = a.json()["mark"]
    assert a.json()["devices_removed"] == 3
    assert neu and neu != alt

    for t in ueber_marke:
        assert client.get("/household/me", headers={"X-CL-Device": t}).status_code == 401
    assert client.get("/household/me", headers={"X-CL-Device": gekoppelt}).status_code == 200
    assert client.post("/device/enroll", json={"mark": alt}).status_code == 401
    assert client.post("/device/enroll", json={"mark": neu}).status_code == 200


def test_die_eigene_marke_ja_die_fremde_nein(haus):
    """Das Teilen beendet die Person, der das Profil gehört — die muss kein Verwalter sein."""
    client, tokens, _ = haus
    eigene = client.post("/household/people/sina/mark", headers=_als(tokens, "sina"))
    assert eigene.status_code == 200 and eigene.json()["mark"]
    wieder = client.post("/household/people/sina/mark", headers=_als(tokens, "sina"))
    assert wieder.json()["mark"] == eigene.json()["mark"], "ausgeben ist nicht erneuern"
    for weg in ("POST", "DELETE"):
        a = client.request(weg, "/household/people/max/mark", headers=_als(tokens, "sina"))
        assert a.status_code == 403 and _code(a) == "auth.forbidden", weg
    erneuert = client.delete("/household/people/sina/mark", headers=_als(tokens, "sina"))
    assert erneuert.json()["mark"] != eigene.json()["mark"]


# ── Die Person ohne PIN ──────────────────────────────────────────────────────


def test_ein_leerer_pin_abdruck_gibt_401_und_nicht_500(haus):
    """Entscheidung 8.1 a: Ohne diese Abfrage wirft argon2 `InvalidHash`."""
    client, tokens, d = haus
    _freigegeben(client, tokens)
    with d.store.connect() as v:
        assert v.execute("SELECT pin_hash FROM person WHERE id = 'selin'").fetchone()[0] == ""
    for pin in ("", "1234", "0000"):
        a = client.post("/login", json={"name": "selin", "pin": pin})
        assert a.status_code == 401 and _code(a) == "auth.bad_credentials", pin


def test_ohne_pin_nur_ausdruecklich(tmp_path):
    """Ein leerer String bleibt ein Formfehler — „keine PIN“ sagt man mit `None`."""
    p = People(Store(tmp_path / "h.sqlite"))
    with pytest.raises(f.Error) as e:
        p.create("Selin", "adult", "")
    assert e.value.code == "auth.pin_format"


# ── Vertrag ──────────────────────────────────────────────────────────────────


def test_aeltere_apps_mit_fassung_eins_laufen_weiter(haus):
    """`Serverfassung.verstanden` sucht eine bekannte Zahl — die 1 muss bleiben."""
    client, tokens, _ = haus
    selbst = client.get("/.well-known/cinelounge").json()
    assert 1 in selbst["api"] and 2 in selbst["api"]
    assert set(selbst["capabilities"]) >= {"household", "portals", "state", "stream", "join"}

    a = client.post("/login", json={"name": "max", "pin": "1234"})
    assert set(a.json()) == {"device_token", "person"}
    assert set(a.json()["person"]) == {"id", "name", "role", "color", "adult"}
    o = client.post("/household/devices/code", headers=_als(tokens, "max")).json()
    a = client.post("/redeem", json={"token": o["code"], "name": "Apple TV", "kind": "tv"})
    assert set(a.json()) == {"device_token", "person"}
    ich = client.get("/household/me", headers=_als(tokens, "sina")).json()
    assert "mark" not in ich, "die Marke kommt nur über ihren eigenen Weg heraus"


# ── Migration 6 ──────────────────────────────────────────────────────────────


def test_migration_sechs_laeuft_ueber_einen_haushalt_von_fassung_fuenf(tmp_path):
    """Zusatzfelder und eine eigene Tabelle — die Prüfbedingung von `pending` bleibt."""
    pfad = tmp_path / "h.sqlite"
    v = sqlite3.connect(pfad)
    for i, schritt in enumerate(store_modul.MIGRATIONS[:5], start=1):
        v.executescript(schritt)
        v.execute(f"PRAGMA user_version = {i}")
    v.execute(
        "INSERT INTO person (id, name, role, pin_hash, color, created) "
        "VALUES ('max', 'Max', 'admin', 'x', '#E2564A', 1)"
    )
    v.execute(
        "INSERT INTO device (id, name, kind, person_id, token, paired) "
        "VALUES ('g1', 'TV', 'tv', NULL, 'merkmal', 1)"
    )
    vorher = v.execute("SELECT sql FROM sqlite_master WHERE name = 'pending'").fetchone()[0]
    v.commit()
    v.close()

    Store(pfad)
    v = sqlite3.connect(pfad)
    # Bis ans Ende der Liste — seit AP63 steht hinter der sechsten eine siebte.
    assert v.execute("PRAGMA user_version").fetchone()[0] == len(store_modul.MIGRATIONS)
    assert v.execute("SELECT sql FROM sqlite_master WHERE name = 'pending'").fetchone()[0] == vorher
    assert "CHECK (kind IN ('pairing', 'invite'))" in vorher
    assert v.execute("SELECT mark FROM person").fetchall() == [(None,)]
    assert v.execute("SELECT token, via_mark FROM device").fetchall() == [("merkmal", None)]
    tabellen = {r[0] for r in v.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert {"join_request", "throttle"} <= tabellen


def test_zwei_personen_haben_nie_dieselbe_marke(tmp_path):
    s = Store(tmp_path / "h.sqlite")
    p = People(s)
    p.create("Max", "admin", "1234")
    p.create("Sina", "adult", "1234")
    with s.connect() as v:
        v.execute("UPDATE person SET mark = 'm' WHERE id = 'max'")
    with pytest.raises(sqlite3.IntegrityError), s.connect() as v:
        v.execute("UPDATE person SET mark = 'm' WHERE id = 'sina'")


def test_die_sicherung_traegt_marke_und_herkunft_mit(tmp_path):
    """`person.mark` und `device.via_mark` wandern mit — `join_request` nicht, wie `pending`."""
    from cinelounge.household import backup

    s = Store(tmp_path / "h.sqlite")
    People(s).create("Max", "admin", "1234")
    joins = Joins(s, People(s))
    mark, _ = joins.issue_mark("max")
    token, _ = joins.enroll(mark, "TV", "tv", "a")
    daten = backup.export(s)
    assert "join_request" not in daten["tables"] and "throttle" not in daten["tables"]

    ziel = Store(tmp_path / "z.sqlite")
    backup.restore(ziel, daten)
    assert Devices(ziel).by_token(token) is not None
    zweit = Joins(ziel, People(ziel))
    assert zweit.renew_mark("max")[1] == 1, "nach dem Zurückspielen weiß das Gerät, woher es kam"


# ── Wettlauf gegen den Widerruf ──────────────────────────────────────────────
#
# **Befund der Gegenprüfung vom 24.09.2026.** `enroll` und `poll` lasen
# `person.mark` außerhalb einer Transaktion und schrieben das Gerät erst danach.
# Lief `renew_mark` genau dazwischen, entstand ein Gerät mit dem Abdruck der
# ALTEN Marke: Es überlebte den Widerruf, und kein späterer erwischte es je.
#
# Nachgestellt wird das deterministisch: Die Verbindung wird so umwickelt, dass
# der Widerruf in einem zweiten Faden mit eigener Verbindung genau vor dem
# ersten Schreiben läuft — nach dem Lesen der Marke. Hält das Lesen schon die
# Schreibsperre (`BEGIN IMMEDIATE`), wartet der Widerruf, bis das Gerät steht,
# und nimmt es mit.


class _Dazwischen:
    """Eine Verbindung, die vor einem bestimmten Befehl einmal etwas einschiebt."""

    def __init__(self, v, ausloeser, tat):
        self._v, self._ausloeser, self._tat = v, ausloeser, tat

    def execute(self, sql, *args):
        if self._tat[0] is not None and sql.lstrip().startswith(self._ausloeser):
            tat, self._tat[0] = self._tat[0], None
            tat()
        return self._v.execute(sql, *args)

    def __getattr__(self, name):
        return getattr(self._v, name)


def _widerruf_vor(monkeypatch, s, pfad, person_id, ausloeser):
    import threading
    from contextlib import contextmanager

    faeden: list[threading.Thread] = []

    def widerruf():
        # Eigene Verbindung, eigener Faden: So sähe es aus, wenn
        # `DELETE /household/people/{id}/mark` gleichzeitig ankommt.
        fremd = Joins(Store(pfad), People(Store(pfad)))
        t = threading.Thread(target=fremd.renew_mark, args=(person_id,))
        t.start()
        faeden.append(t)
        # Ohne Sperre ist der Widerruf in dieser halben Sekunde durch; mit
        # Sperre wartet er (busy timeout) und läuft erst nach dem Commit.
        t.join(0.5)

    echt = s.connect
    einmal = [widerruf]

    @contextmanager
    def connect(**k):
        with echt(**k) as v:
            yield _Dazwischen(v, ausloeser, einmal)

    monkeypatch.setattr(s, "connect", connect)
    return faeden


def test_ein_widerruf_zwischen_lesen_und_anlegen_erwischt_das_neue_geraet(tmp_path, monkeypatch):
    pfad = tmp_path / "h.sqlite"
    s = Store(pfad)
    People(s).create("Selin", "adult", "1234")
    joins = Joins(s, People(s))
    alt, _ = joins.issue_mark("selin")

    faeden = _widerruf_vor(monkeypatch, s, pfad, "selin", "INSERT INTO device")
    token, _ = joins.enroll(alt, "Fernseher der Oma", "tv", "10.0.0.7")
    for t in faeden:
        t.join(15)

    assert Devices(s).by_token(token) is None, "das Gerät kam über die alte Marke"
    with s.connect() as v:
        assert v.execute("SELECT COUNT(*) FROM device").fetchone()[0] == 0


def test_ein_widerruf_zwischen_freigabe_und_abholen_erwischt_das_geraet(tmp_path, monkeypatch):
    pfad = tmp_path / "h.sqlite"
    s = Store(pfad)
    People(s).create("Max", "admin", "1234")
    joins = Joins(s, People(s))
    o = joins.ask("Selin", "#4A90D9", ["portals"], "Selins iPhone", "web", "10.0.0.8")
    joins.approve(o.token, "adult")

    faeden = _widerruf_vor(monkeypatch, s, pfad, "selin", "UPDATE join_request SET fetched")
    antwort = joins.poll(o.token, "10.0.0.8")
    for t in faeden:
        t.join(15)

    assert antwort.state == "approved"
    assert Devices(s).by_token(antwort.device_token) is None


# ── Deckel: Geräte je Marke ──────────────────────────────────────────────────


def test_eine_marke_meldet_hoechstens_zehn_geraete_an(tmp_path):
    """Ein Treffer legt jedes Mal ein Gerät an — ohne Deckel ohne Ende.

    Die Drossel zählt bei `enroll` nur Fehlgriffe; wer die Marke hat, trifft
    immer. Gedeckelt wird der **Bestand** über die aktuelle Marke, nicht die
    Zahl am Tag: Ein Tageszähler ließe den Stapel jeden Tag um zehn wachsen.
    """
    from cinelounge.household import joins as joins_modul

    # Mit Rückfall, damit die Gegenprobe gegen den Stand ohne Deckel am
    # Verhalten scheitert und nicht am Import.
    MAX_DEVICES_PER_MARK = getattr(joins_modul, "MAX_DEVICES_PER_MARK", 10)
    assert MAX_DEVICES_PER_MARK == 10

    s = Store(tmp_path / "h.sqlite")
    People(s).create("Selin", "adult", "1234")
    joins = Joins(s, People(s))
    mark, _ = joins.issue_mark("selin")
    for i in range(MAX_DEVICES_PER_MARK):
        joins.enroll(mark, f"Gerät {i}", "tv", f"10.0.0.{i}")
    with pytest.raises(f.Error) as e:
        joins.enroll(mark, "Eins zu viel", "tv", "10.0.1.1")
    assert e.value.code == "enroll.too_many_devices" and e.value.status == 409
    assert e.value.values == {"max": MAX_DEVICES_PER_MARK}

    # Andere Wege zählen nicht mit, und der Widerruf setzt den Bestand zurück.
    o = Devices(s).request_code("iPad", "ios", "")
    Devices(s).redeem(o.token, user_id="selin")
    neu, weg = joins.renew_mark("selin")
    assert weg == MAX_DEVICES_PER_MARK
    joins.enroll(neu, "Wieder da", "tv", "10.0.2.1")


# ── Kein Kind mit Marke (Entscheidung 14) ────────────────────────────────────


def _kind_mit_geraet(d):
    d.people.create("Eli", "child", "1111")
    o = d.devices.request_code("Emirs iPad", "ios", "")
    return d.devices.redeem(o.token, user_id="eli")


def test_ein_kind_bekommt_keine_marke_auch_nicht_selbst(haus):
    """Ein Kindergerät koppelt der Verwalter am Gerät — wie bei der Einladung."""
    client, tokens, d = haus
    eli = _kind_mit_geraet(d)
    a = client.post("/household/people/eli/mark", headers={"X-CL-Device": eli})
    assert a.status_code == 403 and _code(a) == "mark.not_for_children"
    a = client.post("/household/people/eli/mark", headers=_als(tokens, "max"))
    assert a.status_code == 403 and _code(a) == "mark.not_for_children"
    with d.store.connect() as v:
        assert v.execute("SELECT mark FROM person WHERE id = 'eli'").fetchone()[0] is None


def test_eine_alte_marke_meldet_kein_kind_an(haus):
    """Wer erst erwachsen und dann Kind wurde, trägt vielleicht noch eine Marke."""
    client, tokens, d = haus
    _kind_mit_geraet(d)
    with d.store.connect() as v:
        v.execute("UPDATE person SET mark = 'alte-marke' WHERE id = 'eli'")
    a = client.post("/device/enroll", json={"mark": "alte-marke"})
    assert a.status_code == 401 and _code(a) == "enroll.unknown_mark"
    a = client.delete("/household/people/eli/mark", headers=_als(tokens, "max"))
    assert a.status_code == 200 and a.json()["mark"] is None, "widerrufen ja, neu ausgeben nein"


def test_die_freigabe_als_kind_gibt_ein_geraet_aber_keine_marke(haus):
    client, tokens, d = haus
    anfrage = _anfragen(client)
    assert _freigeben(client, tokens, anfrage, role="child").status_code == 200
    b = client.get(f"/join/{anfrage}").json()
    assert b["state"] == "approved" and b["person_mark"] is None
    ich = client.get("/household/me", headers={"X-CL-Device": b["device_token"]})
    assert ich.json()["id"] == "selin" and ich.json()["role"] == "child"
    with d.store.connect() as v:
        assert v.execute("SELECT mark FROM person WHERE id = 'selin'").fetchone()[0] is None


# ── Ein Verwalter nur mit PIN (Entscheidung 15) ──────────────────────────────


def test_ein_verwalter_wird_nur_mit_eigener_pin_aufgenommen(haus):
    client, tokens, d = haus
    anfrage = _anfragen(client)
    a = _freigeben(client, tokens, anfrage, role="admin")
    assert a.status_code == 422 and _code(a) == "join.admin_needs_pin"
    a = _freigeben(client, tokens, anfrage, role="admin", person_pin="12")
    assert a.status_code == 422 and _code(a) == "auth.pin_format"
    assert d.people.by_id("selin") is None

    a = _freigeben(client, tokens, anfrage, role="admin", person_pin="4321")
    assert a.status_code == 200, a.text
    assert client.post("/login", json={"name": "selin", "pin": "4321"}).status_code == 200


def test_andere_rollen_bleiben_ohne_pin(haus):
    """Entscheidung 1 a gilt weiter.

    Eine PIN für einen Erwachsenen wird abgewiesen, nicht still verschluckt.
    """
    client, tokens, d = haus
    anfrage = _anfragen(client)
    a = _freigeben(client, tokens, anfrage, role="adult", person_pin="4321")
    assert a.status_code == 422 and _code(a) == "join.pin_only_for_admin"
    assert d.people.by_id("selin") is None
