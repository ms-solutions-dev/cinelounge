"""Login, administration, delivery — the routes the console uses.

**What is checked here is not that the interface is pretty.** It hides tabs a
person does not need; that is politeness. The lock sits at the server, and
this file insists on it: Sina is an adult but no admin — she may not switch a
portal, even if she knows the route.
"""

from __future__ import annotations

import re
from pathlib import Path

from tests.test_web import world  # noqa: F401 — the fixture is needed

CONSOLE = Path(__file__).resolve().parent.parent / "cinelounge" / "web" / "console"


# ── Signing in ───────────────────────────────────────────────────────────────


def test_wer_wohnt_hier_ist_offen_und_nennt_keine_kinder(world):  # noqa: F811
    """The names stand on every television anyway — the PIN protects, not the
    secrecy. Children do not appear: the console is no place for them."""
    client, _ = world
    a = client.get("/login/who")
    assert a.status_code == 200
    names = {p["id"] for p in a.json()["people"]}
    assert names == {"max", "sina"}
    assert a.json()["setup_required"] is False


def test_anmelden_gibt_ein_merkmal_das_danach_traegt(world):  # noqa: F811
    client, _ = world
    a = client.post("/login", json={"name": "max", "pin": "1234"})
    assert a.status_code == 200
    token = a.json()["device_token"]
    assert a.json()["person"]["role"] == "admin"

    b = client.get("/household/me", headers={"X-CL-Device": token})
    assert b.status_code == 200
    assert b.json()["rights"]["switch_portals"] is True


def test_falsche_pin_und_unbekannter_name_geben_denselben_code(world):  # noqa: F811
    """Over HTTP just as in the household — otherwise the route reveals which
    ids exist."""
    client, _ = world
    a = client.post("/login", json={"name": "max", "pin": "9999"})
    b = client.post("/login", json={"name": "gibtsnicht", "pin": "1234"})
    assert a.status_code == b.status_code == 401
    assert a.json()["error"]["code"] == b.json()["error"]["code"] == "auth.bad_credentials"


def test_abmelden_nimmt_dem_browser_das_geraet(world):  # noqa: F811
    client, _ = world
    token = client.post("/login", json={"name": "max", "pin": "1234"}).json()["device_token"]
    head = {"X-CL-Device": token}
    assert client.post("/logout", json={}, headers=head).status_code == 200
    # The device is gone, not only forgotten.
    assert client.get("/household/me", headers=head).status_code == 401


# ── Administration: the role decides, not the interface ──────────────────────


def test_sina_darf_kein_portal_schalten(world):  # noqa: F811
    """Adult is not admin. The interface does not show her the tab — but that
    is not the reason it does not work."""
    client, tokens = world
    a = client.post(
        "/household/portals/ahorn/switch",
        json={"on": False},
        headers={"X-CL-Device": tokens["sina"]},
    )
    assert a.status_code == 403
    assert a.json()["error"]["code"] == "auth.forbidden"


def test_admin_schaltet_und_die_sicht_folgt(world):  # noqa: F811
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}
    assert "ahorn" in [p["id"] for p in client.get("/portals", headers=head).json()["portals"]]

    client.post("/household/portals/ahorn/switch", json={"on": False}, headers=head)
    assert "ahorn" not in [p["id"] for p in client.get("/portals", headers=head).json()["portals"]]

    # For Sina too, who had it granted: the switch trumps the permission.
    sina = {"X-CL-Device": tokens["sina"]}
    assert "ahorn" not in [p["id"] for p in client.get("/portals", headers=sina).json()["portals"]]


def test_verwaltung_zeigt_auch_das_defekte_portal(world):  # noqa: F811
    """The difference to `/portals`: that one is a viewer's view. The admin has
    to see a broken portal, otherwise they go looking for it in the file
    system."""
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}
    list_all = client.get("/household/portals", headers=head).json()["portals"]
    broken = [p for p in list_all if p["state"] != "ready"]
    assert [p["id"] for p in broken] == ["broken"]
    assert broken[0]["reason"]


def test_freigabe_fuer_kind_bleibt_bei_ab_18_wirkungslos(world):  # noqa: F811
    """Since the child lock (09.11.2026) the grant is refused outright: the
    child role is locked, and an 18+ portal does not even go into its list.
    (Before, it was accepted and stayed without effect.)"""
    client, tokens = world
    a = client.post(
        "/household/people/eli/access",
        json={"portal": "nightshift", "allowed": True},
        headers={"X-CL-Device": tokens["max"]},
    )
    assert a.status_code == 409 and a.json()["error"]["code"] == "role.child_locked"


def test_einstellungen_nehmen_nur_bekannte_schluessel(world):  # noqa: F811
    """The same table holds values the service keeps for itself. An open route
    onto those would be a remote control for its innards."""
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}
    a = client.put(
        "/household/settings", json={"settings": {"haus.name": "Wohnzimmer"}}, headers=head
    )
    assert a.status_code == 200
    assert a.json()["settings"]["haus.name"] == "Wohnzimmer"

    b = client.put("/household/settings", json={"settings": {"schema.version": "0"}}, headers=head)
    assert b.status_code == 422
    assert b.json()["error"]["code"] == "settings.unknown_key"


# ── Pairing: both ways end in the same token ─────────────────────────────────


def test_code_und_einladung_enden_beide_in_einem_geraet(world):  # noqa: F811
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}

    code = client.post(
        "/household/devices/code", json={"name": "Apple TV", "kind": "tv"}, headers=head
    ).json()["code"]
    a = client.post("/redeem", json={"token": code.lower(), "kind": "tv"})
    assert a.status_code == 200, "the code may be typed in lower case too"
    assert a.json()["person"] is None, "a paired device is shared at first"

    link = client.post("/household/invite", json={"person": "sina"}, headers=head).json()
    b = client.post("/redeem", json={"token": link["token"], "kind": "ios"})
    assert b.status_code == 200
    assert b.json()["person"]["id"] == "sina", "the invitation brings its person along"

    # And exactly once.
    c = client.post("/redeem", json={"token": link["token"]})
    assert c.status_code == 410
    assert c.json()["error"]["code"] == "invite.used"


def test_keine_einladung_fuer_ein_kind(world):  # noqa: F811
    client, tokens = world
    a = client.post(
        "/household/invite", json={"person": "eli"}, headers={"X-CL-Device": tokens["max"]}
    )
    assert a.status_code == 403
    assert a.json()["error"]["code"] == "invite.not_for_children"


# ── The page itself ──────────────────────────────────────────────────────────


def test_der_einhaenger_verschluckt_keine_adresse(world):  # noqa: F811
    """A mount on `/` catches everything not answered before it. Standing at
    the top, HTML with status 200 would come here — the worst way to be
    broken."""
    client, tokens = world
    a = client.get("/portals", headers={"X-CL-Device": tokens["max"]})
    assert a.headers["content-type"].startswith("application/json")
    assert client.get("/health").json()["ok"] is True


# ── Multilingualism ──────────────────────────────────────────────────────────


def _flach(baum, vorsatz=""):
    """All leaves of a language tree as dotted paths."""
    out = set()
    for k, v in baum.items():
        if k.startswith("_"):
            continue
        path = f"{vorsatz}{k}"
        if isinstance(v, dict):
            out |= _flach(v, path + ".")
        else:
            out.add(path)
    return out


def test_fehlercodes_werden_uebersetzt_und_nicht_roh_gezeigt():
    """**The half of multilingualism that counts — and that already stands.**

    The errors. They come from the server as a code (`core/errors.py`) and
    become a sentence in `core/language.js` — that is exactly what codes are
    for. This test insists that no view goes past it: whoever displays
    `fehl.message` puts `stream.drm` on the screen of a household operating in
    Turkish.

    (The static markup text was keyed with `data-t` on 11.09.2026 — see
    `test_jede_data_t_marke_hat_einen_satz` further down.)
    """

    verstoesse = []
    for file in (CONSOLE / "js").rglob("*.js"):
        if file.name in ("draht.js", "sprache.js"):
            continue
        # The waiver holds until the next statement — the reasoning stands
        # as a comment block above and is more than one line long.
        gedeckt = False
        for nr, line in enumerate(file.read_text(encoding="utf-8").splitlines(), 1):
            # `// roh:` is the only exception, and it has to stand reasoned
            # above the line. The workshop console deliberately shows what the
            # browser says: a HEAD request goes directly to the host, and what
            # fails there has no error code but a browser message — exactly
            # the one you want to see in the workshop.
            if "// roh:" in line:
                gedeckt = True
            ohne_kommentar = re.sub(r"//.*$", "", line)
            if gedeckt:
                # After the first statement the waiver is used up.
                if ohne_kommentar.strip():
                    gedeckt = False
                continue
            if re.search(r"\bfehl(er)?\.message\b", ohne_kommentar):
                verstoesse.append(file.name + ":" + str(nr) + " " + line.strip())
    assert not verstoesse, "error text instead of error code, use errorText():\n" + "\n".join(
        verstoesse
    )


def test_die_navigation_zeigt_auf_vorhandene_ansichten():
    """A tab leading nowhere is worse than none."""

    page = (CONSOLE / "index.html").read_text(encoding="utf-8")
    ziele = set(re.findall(r'data-zu="([a-z]+)"', page))
    present = set(re.findall(r'class="view[^"]*" id="v-([a-z_]+)"', page))
    assert ziele <= present, "tab without a view: " + str(sorted(ziele - present))


def test_jede_kennung_im_markup_kommt_genau_einmal_vor():
    """Two identical ids are invalid, and the second reference reaches the
    first.

    Found while adopting the design: `clipPath id="tuete"` stood twice — in
    the bar and in the login sheet. Such a thing only becomes visible when one
    of the two is missing.
    """
    from collections import Counter

    page = (CONSOLE / "index.html").read_text(encoding="utf-8")
    zaehlung = Counter(re.findall(r'\sid="([^"]+)"', page))
    doppelt = sorted(k for k, n in zaehlung.items() if n > 1)
    assert not doppelt, "id assigned more than once: " + str(doppelt)


def test_jeder_import_findet_seinen_export():
    """**The price of them being modules — and the return.**

    A typo in an import name only shows in the browser when the page loads, and
    then as a white area with one line in a console nobody has open. The build
    step that otherwise catches it deliberately does not exist here: 18 modules
    without a toolchain. So this test catches it.
    """

    name = r"[\w$]+"
    exporte = {}
    for file in (CONSOLE / "js").rglob("*.js"):
        text = file.read_text(encoding="utf-8")
        names = set()
        names |= set(re.findall(r"^export\s+(?:async\s+)?function\s+(" + name + ")", text, re.M))
        names |= set(re.findall(r"^export\s+(?:const|let|var)\s+(" + name + ")", text, re.M))
        names |= set(re.findall(r"^export\s+class\s+(" + name + ")", text, re.M))
        for block in re.findall(r"^export\s*\{([^}]*)\}", text, re.M):
            names |= {x.strip().split(" as ")[-1].strip() for x in block.split(",") if x.strip()}
        exporte[file.resolve()] = names

    missing = []
    for file in (CONSOLE / "js").rglob("*.js"):
        text = file.read_text(encoding="utf-8")
        for block, path in re.findall(r'import\s*\{([^}]*)\}\s*from\s*"([^"]+)"', text, re.S):
            target = (file.parent / path).resolve()
            if target not in exporte:
                missing.append(file.name + ": Datei fehlt -> " + path)
                continue
            gewuenscht = [
                x.strip().split(" as ")[0].strip()
                for x in block.replace("\n", " ").split(",")
                if x.strip()
            ]
            for n in gewuenscht:
                if n not in exporte[target]:
                    missing.append(file.name + ": `" + n + "` fehlt in " + path)
        for path in re.findall(r"import\s+\*\s+as\s+" + name + r'\s+from\s*"([^"]+)"', text):
            if (file.parent / path).resolve() not in exporte:
                missing.append(file.name + ": Datei fehlt -> " + path)

    assert not missing, "Gebrochene Importe:\n" + "\n".join(missing)


def test_ich_nennt_jedes_recht_das_es_gibt(world):  # noqa: F811
    """**A selection was a fault here.**

    `/household/me` named six of nine rights. The interface read `undefined`
    for `install_portals`, took it for "may not" and hid the marketplace tab —
    from an admin who has it. Found in the browser pass, not by reading.
    """
    from cinelounge.household.people import RIGHTS

    client, tokens = world
    d = client.get("/household/me", headers={"X-CL-Device": tokens["max"]}).json()
    assert set(d["rights"]) == set(RIGHTS), "every right, and each with an English name"
    assert all(d["rights"].values()), "an admin has every right"

    kind = client.get("/household/me", headers={"X-CL-Device": tokens["eli"]}).json()
    assert kind["rights"]["watch"] is True
    assert kind["rights"]["switch_portals"] is False


# ── Getting rid of a person again ────────────────────────────────────────────


def test_person_entfernen_nimmt_stand_und_geraete_mit(world):  # noqa: F811
    """**There is no wastebasket, and that is the decision.**

    A half-deleted resident would be a profile nobody sees whose devices still
    have access. So everything goes along — the test insists on it because
    `ON DELETE CASCADE` stands in the schema and not in the code: whoever
    recreates the table later and forgets it would otherwise never notice.
    """
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}

    # Sina has progress and a device.
    client.post(
        "/state",
        json={"key": "ahorn:krimireihe:", "position_s": 60.0, "duration_s": 3000.0},
        headers={"X-CL-Device": tokens["sina"]},
    )
    assert (
        client.get(
            "/state?key=ahorn:krimireihe:", headers={"X-CL-Device": tokens["sina"]}
        ).status_code
        == 200
    )

    a = client.delete("/household/people/sina", headers=head)
    assert a.status_code == 200
    assert a.json()["removed"] == "sina"
    assert a.json()["devices"] == 1, "her device counts"

    # Out of the list, and her token no longer carries.
    names = [p["id"] for p in client.get("/household/people", headers=head).json()["people"]]
    assert "sina" not in names
    assert client.get("/portals", headers={"X-CL-Device": tokens["sina"]}).status_code == 401


def test_niemand_entfernt_sich_selbst(world):  # noqa: F811
    """Whoever did would be locked out the same instant."""
    client, tokens = world
    a = client.delete("/household/people/max", headers={"X-CL-Device": tokens["max"]})
    assert a.status_code == 409
    assert a.json()["error"]["code"] == "household.not_yourself"


def test_der_letzte_admin_bleibt(world):  # noqa: F811
    """A household without an admin can no longer be administered — the only
    way back would be an intervention in the database, and that is no
    operation."""
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}
    client.post(
        "/household/people",
        json={"name": "Zweitadmin", "role": "admin", "pin": "4321"},
        headers=head,
    )

    # Now there are two — the second may go.
    assert client.delete("/household/people/zweitadmin", headers=head).status_code == 200

    # And Max does not remove himself anyway; so check via a second admin
    # that the last one stays.
    client.post(
        "/household/people", json={"name": "Dritt", "role": "admin", "pin": "4321"}, headers=head
    )
    second = client.post("/login", json={"name": "dritt", "pin": "4321"}).json()["device_token"]
    assert (
        client.delete("/household/people/max", headers={"X-CL-Device": second}).status_code == 200
    )
    a = client.delete("/household/people/dritt", headers={"X-CL-Device": second})
    assert a.status_code == 409
    assert a.json()["error"]["code"] == "household.not_yourself"


# ── Changing a role afterwards ───────────────────────────────────────────────


def test_ein_kind_wird_erwachsen_und_sieht_ab_18_sofort(world):  # noqa: F811
    """**The lock follows the household, not the token.** Eli's device was
    paired as a child's; after the change the same token sees the 18+ portal
    — no new sign-in, no new pairing. And the progress stays, because nothing
    was removed."""
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}
    kind = {"X-CL-Device": tokens["eli"]}

    client.post(
        "/state",
        json={"key": "ahorn:krimireihe:", "position_s": 60.0, "duration_s": 3000.0},
        headers=kind,
    )
    assert client.get("/p/nightshift/menu", headers=kind).status_code == 403

    a = client.post("/household/people/eli/role", json={"role": "adult"}, headers=head)
    assert a.status_code == 200
    assert a.json()["role"] == "adult"
    assert a.json()["adult"] is True

    assert client.get("/p/nightshift/menu", headers=kind).status_code != 403
    assert "nightshift" in {p["id"] for p in client.get("/portals", headers=kind).json()["portals"]}
    assert client.get("/state?key=ahorn:krimireihe:", headers=kind).status_code == 200
    me = client.get("/household/me", headers=kind).json()
    assert me["rights"]["view_adult"] is True

    codes = [e["code"] for e in client.get("/household/events", headers=head).json()["events"]]
    assert "event.person_role_changed" in codes


def test_ein_erwachsener_wird_kind_und_die_tuer_geht_zu(world):  # noqa: F811
    """The other direction: Sina's permission for the 18+ portal stays as a
    row and stops counting."""
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}
    sina = {"X-CL-Device": tokens["sina"]}
    assert client.get("/p/nightshift/menu", headers=sina).status_code != 403

    a = client.post("/household/people/sina/role", json={"role": "child"}, headers=head)
    assert a.status_code == 200
    a = client.get("/p/nightshift/menu", headers=sina)
    assert a.status_code == 403
    assert "nightshift" not in {
        p["id"] for p in client.get("/portals", headers=sina).json()["portals"]
    }


def test_rolle_aendern_nur_admin_nicht_sich_selbst_nicht_erfunden(world):  # noqa: F811
    """Since 09.11.2026 a role is only what somebody sees — changing one's own
    role is harmless and allowed, console access stays where it was."""
    client, tokens = world
    a = client.post(
        "/household/people/eli/role",
        json={"role": "adult"},
        headers={"X-CL-Device": tokens["sina"]},
    )
    assert a.status_code == 403

    head = {"X-CL-Device": tokens["max"]}
    a = client.post("/household/people/max/role", json={"role": "adult"}, headers=head)
    assert a.status_code == 200
    assert a.json()["console"] is True
    assert client.get("/household/me", headers=head).json()["rights"]["change_access"] is True

    a = client.post("/household/people/eli/role", json={"role": "teen"}, headers=head)
    assert a.status_code == 422
    assert a.json()["error"]["code"] == "household.unknown_role"

    a = client.post("/household/people/niemand/role", json={"role": "adult"}, headers=head)
    assert a.status_code == 404


def test_der_haushalt_kann_sich_nicht_selbst_aussperren(world):  # noqa: F811
    """**The last person with console access keeps it.** Granting needs the
    decider's PIN; with two people holding it, one may give it up."""
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}
    a = client.post(
        "/household/people/max/console", json={"on": False, "my_pin": "1234"}, headers=head
    )
    assert a.status_code == 409
    assert a.json()["error"]["code"] == "household.last_admin"

    a = client.post(
        "/household/people/sina/console", json={"on": True, "my_pin": "0000"}, headers=head
    )
    assert a.status_code == 401, "the decider's PIN is checked first"
    a = client.post(
        "/household/people/sina/console", json={"on": True, "my_pin": "1234"}, headers=head
    )
    assert a.status_code == 200 and a.json()["console"] is True

    a = client.post(
        "/household/people/max/console", json={"on": False, "my_pin": "1234"}, headers=head
    )
    assert a.status_code == 200 and a.json()["console"] is False
    # Max no longer manages anything.
    a = client.post("/household/people/sina/role", json={"role": "child"}, headers=head)
    assert a.status_code == 403


def test_ein_geraet_bekommt_den_namen_des_haushalts(world):  # noqa: F811
    """**"iPhone" is a model, not a name.**

    Two phones in the house both call themselves "iPhone"; the household tells
    them apart by what it calls them. The server keeps the name, the list
    shows it, the log says it — and a name that is only spaces is none.
    """
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}
    geraete = client.get("/household/devices", headers=head).json()["devices"]
    sinas = next(g for g in geraete if g["person"] == "sina")

    a = client.post(
        "/household/devices/" + sinas["id"] + "/name",
        json={"name": "  Sinas   iPhone  "},
        headers=head,
    )
    assert a.status_code == 200
    assert a.json()["name"] == "Sinas iPhone", "whitespace is folded, not kept"

    nachher = client.get("/household/devices", headers=head).json()["devices"]
    assert next(g for g in nachher if g["id"] == sinas["id"])["name"] == "Sinas iPhone"
    assert sum(g["name"] == "Sinas iPhone" for g in nachher) == 1, "only that one row"

    # The act stands in the book with the new name.
    buch = client.get("/household/events", headers=head).json()["events"]
    assert any(
        e["code"] == "event.device_renamed" and e["values"]["name"] == "Sinas iPhone" for e in buch
    )

    leer = client.post(
        "/household/devices/" + sinas["id"] + "/name", json={"name": "   "}, headers=head
    )
    assert leer.status_code == 422
    assert leer.json()["error"]["code"] == "household.device_no_name"

    weg = client.post("/household/devices/nie-gekoppelt/name", json={"name": "x"}, headers=head)
    assert weg.status_code == 404
    assert weg.json()["error"]["code"] == "household.unknown_device"


def test_sina_benennt_kein_geraet_um(world):  # noqa: F811
    """Renaming is pairing's sibling: whoever may not pair may not rename."""
    client, tokens = world
    a = client.post(
        "/household/devices/egal/name",
        json={"name": "x"},
        headers={"X-CL-Device": tokens["sina"]},
    )
    assert a.status_code == 403


def test_zweimal_anmelden_legt_kein_zweites_geraet_an(world):  # noqa: F811
    """**One browser, one row.**

    Measured 10.09.2026 in the live household: **40 device rows**, nearly all
    "Browser" and "Console in the browser", the same machine, the same person —
    every sign-in created a new one. A list meant to show who has access is
    then only paper.

    A browser is no television: it is not paired, it signs in.
    """
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}
    vorher = len(client.get("/household/devices", headers=head).json()["devices"])

    erste = client.post("/login", json={"name": "max", "pin": "1234"}).json()["device_token"]
    zweite = client.post("/login", json={"name": "max", "pin": "1234"}).json()["device_token"]
    assert erste == zweite, "the same browser gets the same token"

    nachher = client.get("/household/devices", headers=head).json()["devices"]
    assert len(nachher) == vorher + 1, "exactly one row was added, not two"


def test_abmelden_und_neu_anmelden_gibt_ein_frisches_merkmal(world):  # noqa: F811
    """Signing out **really** takes the access back.

    Otherwise "one browser, one row" would be a hole: whoever signs out would
    get back in with the old token afterwards.
    """
    client, _ = world
    erste = client.post("/login", json={"name": "max", "pin": "1234"}).json()["device_token"]
    client.post("/logout", json={}, headers={"X-CL-Device": erste})
    assert client.get("/household/me", headers={"X-CL-Device": erste}).status_code == 401

    zweite = client.post("/login", json={"name": "max", "pin": "1234"}).json()["device_token"]
    assert zweite != erste
    assert client.get("/household/me", headers={"X-CL-Device": zweite}).status_code == 200


# ── Getting rid of a portal again ────────────────────────────────────────────


def test_portal_entfernen_nimmt_den_ordner_mit_aber_nicht_den_stand(world, tmp_path):  # noqa: F811
    """**No wastebasket — but no clear-cut either.**

    A portal that only disappears from the list still lies on the disk and
    comes back at the next read. So the folder goes along.

    The **progress stays**: whoever watched half the season watched it. If the
    same portal comes back from the marketplace later, it finds its keys again
    — they are called `portal:title:year` and do not hang on the folder.
    """
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}

    client.post(
        "/state",
        json={
            "key": "ahorn:krimireihe:",
            "portal": "ahorn",
            "position_s": 60.0,
            "duration_s": 3000.0,
        },
        headers=head,
    )

    a = client.delete("/household/portals/ahorn", headers=head)
    assert a.status_code == 200
    assert a.json()["removed"] == "ahorn"
    assert a.json()["progress_kept"] is True

    ids = [p["id"] for p in client.get("/household/portals", headers=head).json()["portals"]]
    assert "ahorn" not in ids, "out of the list"
    assert client.get("/p/ahorn/menu", headers=head).status_code == 404, "and out of the registry"

    from cinelounge.web import main

    kept = main.app.state.services.progress.by_id("max", "ahorn:krimireihe:")
    assert kept is not None and kept["position_s"] == 60.0, "the progress survives"
    # ...but stays in the drawer while the portal is gone (09.11.2026: nothing
    # from a portal one does not see gets out, not even one's own progress).
    assert client.get("/state?key=ahorn:krimireihe:", headers=head).status_code == 404


def test_ein_unbekanntes_portal_laesst_sich_nicht_entfernen(world):  # noqa: F811
    """Otherwise a typo would be a delete command for something or other."""
    client, tokens = world
    a = client.delete("/household/portals/gibtsnicht", headers={"X-CL-Device": tokens["max"]})
    assert a.status_code == 404
    assert a.json()["error"]["code"] == "portal.unknown"


def test_sina_darf_kein_portal_entfernen(world):  # noqa: F811
    """The same rule as with switching — and it sits at the server."""
    client, tokens = world
    a = client.delete("/household/portals/ahorn", headers={"X-CL-Device": tokens["sina"]})
    assert a.status_code == 403


def test_kein_haushalt_aus_dem_entwurf_steht_im_markup():
    """**A stranger should not see my household.**

    The design was built with real data, and that was right — a view with
    placeholders cannot be judged. What wandered from it into the markup was
    not: "Fuer Sina freigeben" stood in the install dialog, "8 Dateien mit 3,2
    GB" in the one that clears the buffer, and "Max · Haushalt-Admin" top
    right until the JavaScript replaced it.

    **The numbers are the more dangerous part.** A foreign name stands out. A
    size that looks plausible does not — it is right until somebody relies on
    it, and in the clean-up dialog it stood beside a button that deletes.

    What is **not** checked here are explanatory texts: "Gemessen 3,2 GB ueber
    Nacht" in a reasoning is evidence and no display. So the test looks only at
    text nodes standing as a value.
    """

    html = (CONSOLE / "index.html").read_text(encoding="utf-8")

    # Names from the household the design was built with.
    for name in ("Sina", "Eli"):
        assert name not in html, f"{name} stands in the markup — somebody else's household"

    # Values that look like measured sizes: in an element carrying a value,
    # not in a sentence.
    werte = re.findall(
        r'<(?:b|span|strong)[^>]*class="[^"]*(?:value|wert|tile-value|strip-value)[^"]*"[^>]*>'
        r"([^<]+)<",
        html,
    )
    werte += re.findall(r"<b>([^<]*\d[^<]*)</b>", html)
    verdaechtig = [
        w.strip()
        for w in werte
        if re.search(r"\d+[.,]\d+\s*(GB|MB)|\d+\s*(GB|MB|Folgen|Stunden)", w)
    ]
    assert not verdaechtig, "sizes in the markup nobody measured: " + ", ".join(verdaechtig)


def test_kein_platzhalter_traegt_eine_marke():
    """What the JavaScript **labels** may have no `data-t`.

    `translate()` runs at startup and after every language switch — **after**
    the filling. A `data-t` on an element carrying data would write the
    placeholder back: "12 Portale" would become "2 neu" again, and the name of
    the signed-in person a dash.

    **The first version only asked whether the id occurs in the JavaScript at
    all.** That is too coarse: a button with only a listener attached is not
    labelled, and an input field whose `value` is set keeps its translated
    placeholder. On 11.09.2026 the test therefore demanded leaving three
    marketplace buttons untranslated — and next time would have led somebody to
    remove the `data-t` instead of looking for the fault. Now what counts is
    whether **text is assigned** to the element.
    """

    html = (CONSOLE / "index.html").read_text(encoding="utf-8")
    js = "\n".join(p.read_text(encoding="utf-8") for p in (CONSOLE / "js").rglob("*.js"))

    #: What overwrites a label. `.value` is **not** in it: it fills a field's
    #: content, not its placeholder, and the two stand side by side without
    #: disturbing each other.
    schreibt = (".textContent", ".innerHTML", ".innerText")

    def wird_beschriftet(kennung: str) -> bool:
        """Is text assigned to this element anywhere in the console?"""
        for waehler in (f'"#{kennung}"', f"'#{kennung}'"):
            for treffer in re.finditer(re.escape(waehler), js):
                # a) In one go: `$("#x").textContent = …`
                rest = js[treffer.end() : treffer.end() + 40].lstrip(") ")
                if any(rest.startswith(w) for w in schreibt):
                    return True

                # b) Via a name: `const a = $("#x"); … a.textContent = …`
                #    The more common case, and the one the coarse version
                #    actually meant to hit.
                zeile = js[js.rfind("\n", 0, treffer.start()) + 1 : treffer.start()]
                m = re.search(r"\b(?:const|let|var)\s+(\w+)\s*=\s*$", zeile.rstrip())
                if not m:
                    continue
                name = re.escape(m.group(1))
                zuweisung = (
                    r"\b"
                    + name
                    + r"(?:\?)?(?:"
                    + "|".join(re.escape(w) for w in schreibt)
                    + r")\s*=[^=]"
                )
                if re.search(zuweisung, js):
                    return True
        return False

    schuldig = []
    for zeile in html.split("\n"):
        # `data-t=` or `data-t-<something>=` — and **not** `data-thema`, which
        # the theme button carries. A search for the bare string `data-t` took
        # it along and pointed at a button that has no text at all.
        if not re.search(r"data-t(-[a-z]+)?=", zeile):
            continue
        for kennung in re.findall(r'id="([\w-]+)"[^>]*data-t|data-t[^>]*id="([\w-]+)"', zeile):
            name = kennung[0] or kennung[1]
            if wird_beschriftet(name):
                schuldig.append(name)

    assert not schuldig, (
        "Element mit data-t, dem das JS Text zuweist — translate() ueberschreibt die Daten: "
        + ", ".join(sorted(set(schuldig)))
    )


def test_ein_kaputtes_portal_ab_18_verraet_kindern_nichts(world):  # noqa: F811
    """A broken 18+ portal answered a child with 503 and its broken reason —
    readiness was checked before the permission. Now the child gets the same
    403 as for a working one, and the search does not list it as failed."""
    from cinelounge.web import main

    client, tokens = world
    main.app.state.services.registry.manifests["nightshift"].broken_reason = "probe"
    head = {"X-CL-Device": tokens["eli"]}
    a = client.get("/p/nightshift/menu", headers=head)
    assert a.status_code == 403
    assert "probe" not in a.text
    b = client.get("/search", params={"q": "x", "portal": "nightshift"}, headers=head)
    assert b.status_code == 200
    assert "nightshift" not in b.json().get("failed", {})
    c = client.get("/p/nightshift/menu", headers={"X-CL-Device": tokens["max"]})
    assert c.status_code == 503 and c.json()["error"]["code"] == "portal.broken"
