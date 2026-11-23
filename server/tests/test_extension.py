"""Extensions: loading, failing safely, and the line the preload draws.

Every extension here is a small module written into `tmp_path` for the test;
the names are made up. The server must run without any extension — the tests
at the end check exactly that.
"""

from __future__ import annotations

import importlib
import json
import os
import sys
import textwrap
from importlib.metadata import EntryPoint

import pytest
from fastapi.testclient import TestClient

from cinelounge.portalworks import extension as registries
from cinelounge.web import extension

#: A register only these tests use. Created once: registers live as long as the
#: process, like the ones the portal works define at import time.
PROBE: registries.Register[str] = registries.Register("test.probe", key=lambda s: s)

#: A register with a core entry, as the portal works will have from W1 on
#: (e.g. the native portal kind). Registered at import time, like theirs.
KERN: registries.Register[str] = registries.Register("test.kern", key=lambda s: s)
KERN.add_core("kern-eins")


@pytest.fixture(autouse=True)
def frisch():
    """Each test starts with nothing loaded and leaves the process as it found it.

    Afterwards whatever `CL_EXTENSIONS` named before is loaded again, so that
    a later test — in the private run, with an extension — sees its registries.
    If they were sealed before, they are sealed again: `runner.preload()` has
    run once already and does not run again, and a later test must still see
    a registration after the preload fail.
    """
    before = os.environ.get("CL_EXTENSIONS")
    sealed = registries.is_sealed()
    extension.reset()
    yield
    if before is None:
        os.environ.pop("CL_EXTENSIONS", None)
    else:
        os.environ["CL_EXTENSIONS"] = before
    extension.reset()
    extension.load()
    if sealed:
        registries.seal()


@pytest.fixture
def modul(tmp_path, monkeypatch):
    """Write a module into `tmp_path` and make it importable under `name`."""
    monkeypatch.syspath_prepend(str(tmp_path))
    names: list[str] = []

    def write(name: str, body: str) -> str:
        (tmp_path / f"{name}.py").write_text(textwrap.dedent(body), encoding="utf-8")
        names.append(name)
        return name

    yield write
    for name in names:
        sys.modules.pop(name, None)


ZAEHLER = """
    calls = []

    def install(ctx):
        calls.append(ctx.name)
"""


# ── Finding and loading ──────────────────────────────────────────────────────


def test_ohne_erweiterung_laedt_nichts(monkeypatch):
    monkeypatch.delenv("CL_EXTENSIONS", raising=False)
    monkeypatch.setattr(extension, "entry_points", lambda group: [])
    assert extension.load() == []
    assert extension.health() == {"extensions": [], "extensions_failed": []}


def test_cl_extensions_laedt_ein_modul(modul, monkeypatch):
    name = modul("ext_ahorn", ZAEHLER)
    monkeypatch.setenv("CL_EXTENSIONS", name)
    assert extension.load() == ["ext_ahorn"]
    assert sys.modules["ext_ahorn"].calls == ["ext_ahorn"]
    assert extension.health()["extensions"] == ["ext_ahorn"]


def test_modul_und_funktion_mit_doppelpunkt(modul, monkeypatch):
    modul(
        "ext_birke",
        """
        calls = []

        def setup(ctx):
            calls.append("setup")
        """,
    )
    monkeypatch.setenv("CL_EXTENSIONS", " ext_birke:setup , ")
    assert extension.load() == ["ext_birke:setup"]
    assert sys.modules["ext_birke"].calls == ["setup"]


def test_laden_laeuft_einmal_je_prozess(modul, monkeypatch):
    """`web/main.py` wird in Tests neu geladen — die Erweiterung nicht doppelt."""
    modul("ext_eibe", ZAEHLER)
    monkeypatch.setenv("CL_EXTENSIONS", "ext_eibe")
    extension.load()
    extension.load()
    assert sys.modules["ext_eibe"].calls == ["ext_eibe"]


def test_entry_point_und_umgebung_mit_demselben_ziel_laden_einmal(modul, monkeypatch):
    modul("ext_espe", ZAEHLER)
    monkeypatch.setattr(
        extension,
        "entry_points",
        lambda group: [EntryPoint("espe", "ext_espe:install", group)],
    )
    monkeypatch.setenv("CL_EXTENSIONS", "ext_espe")
    assert extension.load() == ["espe"]
    assert sys.modules["ext_espe"].calls == ["espe"]


def test_none_schaltet_auch_entry_points_ab(modul, monkeypatch):
    modul("ext_fichte", ZAEHLER)
    monkeypatch.setattr(
        extension,
        "entry_points",
        lambda group: [EntryPoint("fichte", "ext_fichte:install", group)],
    )
    monkeypatch.setenv("CL_EXTENSIONS", "none")
    assert extension.load() == []
    assert "ext_fichte" not in sys.modules


# ── Failing safely ───────────────────────────────────────────────────────────


def test_fehlendes_modul_wird_gemeldet_und_der_rest_laeuft(modul, monkeypatch):
    modul("ext_hasel", ZAEHLER)
    monkeypatch.setenv("CL_EXTENSIONS", "ext_gibt_es_nicht,ext_hasel")
    assert extension.load() == ["ext_hasel"]
    h = extension.health()
    assert h["extensions"] == ["ext_hasel"]
    [failed] = h["extensions_failed"]
    assert failed["name"] == "ext_gibt_es_nicht"
    assert failed["phase"] == "load"
    assert "ModuleNotFoundError" in failed["error"]


def test_install_mit_fehler_nimmt_seine_eintraege_zurueck(modul, monkeypatch):
    """Halb registriert ist schlimmer als gar nicht: alles oder nichts."""
    modul(
        "ext_kastanie",
        """
        from tests_probe_register import PROBE

        def install(ctx):
            PROBE.add("kastanie-eins")
            raise RuntimeError("zweiter Schritt kaputt")
        """,
    )
    monkeypatch.setitem(sys.modules, "tests_probe_register", sys.modules[__name__])
    monkeypatch.setenv("CL_EXTENSIONS", "ext_kastanie")
    assert extension.load() == []
    assert PROBE.items() == ()
    [failed] = extension.health()["extensions_failed"]
    assert failed["phase"] == "install"
    assert "zweiter Schritt kaputt" in failed["error"]


def test_kein_aufrufbares_install_ist_ein_ladefehler(modul, monkeypatch):
    modul("ext_linde", "install = 42\n")
    monkeypatch.setenv("CL_EXTENSIONS", "ext_linde")
    assert extension.load() == []
    assert extension.health()["extensions_failed"][0]["phase"] == "load"


# ── The registries ───────────────────────────────────────────────────────────


def test_doppelter_schluessel_ist_ein_konflikt():
    PROBE.add("ulme")
    with pytest.raises(ValueError, match="ulme"):
        PROBE.add("ulme")
    assert PROBE.get("ulme") == "ulme"


def test_kerneintraege_ueberleben_das_zuruecksetzen():
    """Was der Kern selbst mitbringt, nimmt weder ein Test noch ein Rückbau weg."""
    KERN.add("erweiterung-eins")
    assert KERN.items() == ("kern-eins", "erweiterung-eins")
    extension.reset()
    assert KERN.items() == ("kern-eins",)


def test_kerneintraege_bleiben_beim_rueckbau(modul, monkeypatch):
    modul(
        "ext_kiefer",
        """
        from tests_probe_register import KERN

        def install(ctx):
            KERN.add("kiefer")
            KERN.add_core("kern-spaet")
            raise RuntimeError("halb fertig")
        """,
    )
    monkeypatch.setitem(sys.modules, "tests_probe_register", sys.modules[__name__])
    monkeypatch.setenv("CL_EXTENSIONS", "ext_kiefer")
    try:
        assert extension.load() == []
        # A core entry that a lazily imported core module adds during an install
        # stays; the extension's own entry goes.
        assert KERN.items() == ("kern-eins", "kern-spaet")
    finally:
        KERN._core.remove("kern-spaet")
        extension.reset()
    assert KERN.items() == ("kern-eins",)


def test_kerneintrag_mit_gleichem_schluessel_ist_ein_konflikt():
    with pytest.raises(ValueError, match="kern-eins"):
        KERN.add("kern-eins")


def test_nach_dem_vorladen_ist_versiegelt():
    """Was nach `runner.preload()` dazukäme, sähe nur ein Teil der Kinder."""
    registries.seal()
    with pytest.raises(registries.SealedError):
        PROBE.add("zu-spaet")
    assert PROBE.items() == ()


def test_das_kind_erbt_die_register():
    from cinelounge.portalworks.runner import fork

    if not fork.available():
        pytest.skip("kein fork auf dieser Plattform")
    PROBE.add("weide")
    registries.seal()
    assert fork.run(lambda: list(PROBE.items())) == ["weide"]


# ── In the running service ───────────────────────────────────────────────────

BEITRAG = """
    from fastapi import APIRouter

    router = APIRouter()
    started = []

    @router.get("/probe/ahorn")
    def probe():
        return {"from": "extension"}

    @router.get("/health")
    def fake_health():
        return {"ok": False}

    def install(ctx):
        ctx.include_router(router)
        ctx.background(lambda services: started.append(services))
        ctx.health(lambda: {"ahorn": {"ready": True}, "ok": False})
"""


def _dienst(tmp_path, monkeypatch):
    monkeypatch.setenv("CL_DATA", str(tmp_path))
    from cinelounge.web import main

    importlib.reload(main)
    return main


def test_beitraege_im_dienst(modul, tmp_path, monkeypatch):
    modul("ext_mammut", BEITRAG)
    monkeypatch.setenv("CL_EXTENSIONS", "ext_mammut")
    main = _dienst(tmp_path, monkeypatch)
    client = TestClient(main.app)

    assert client.get("/probe/ahorn").json() == {"from": "extension"}
    h = client.get("/health").json()
    # Core fields win: neither the extension's route nor its report overwrite `ok`.
    assert h["ok"] is True
    assert h["ahorn"] == {"ready": True}
    assert h["extensions"] == ["ext_mammut"]
    assert h["extensions_failed"] == []
    # Every new application object gets its own start — the first import of
    # `main` and the reload here are two, so only the last one is checked.
    assert sys.modules["ext_mammut"].started[-1] is main.app.state.services
    assert registries.is_sealed()


def test_kaputte_erweiterung_haelt_den_dienst_nicht_auf(modul, tmp_path, monkeypatch):
    modul(
        "ext_platane",
        """
        def install(ctx):
            raise ImportError("fehlt etwas")
        """,
    )
    monkeypatch.setenv("CL_EXTENSIONS", "ext_platane")
    client = TestClient(_dienst(tmp_path, monkeypatch).app)
    h = client.get("/health").json()
    assert h["ok"] is True
    assert h["extensions"] == []
    assert [x["name"] for x in h["extensions_failed"]] == ["ext_platane"]


def test_fehler_beim_anhaengen_wird_gemeldet(modul, tmp_path, monkeypatch):
    modul(
        "ext_robinie",
        """
        def install(ctx):
            def start(services):
                raise RuntimeError("Hintergrund startet nicht")
            ctx.background(start)
        """,
    )
    monkeypatch.setenv("CL_EXTENSIONS", "ext_robinie")
    client = TestClient(_dienst(tmp_path, monkeypatch).app)
    h = client.get("/health").json()
    assert h["ok"] is True
    assert h["extensions"] == []
    # `main` was imported and then reloaded — two attaches, still one entry.
    [failed] = h["extensions_failed"]
    assert failed["phase"] == "attach"


def test_fehler_beim_anhaengen_nimmt_alles_zurueck(modul, tmp_path, monkeypatch):
    """Gemeldet als gescheitert heißt: nichts davon antwortet, nichts läuft weiter."""
    modul(
        "ext_zeder",
        """
        from fastapi import APIRouter

        router = APIRouter()
        log = []

        @router.get("/probe/zeder")
        def probe():
            return {"from": "zeder"}

        def install(ctx):
            ctx.include_router(router)
            ctx.background(lambda services: log.append("start"), lambda: log.append("stop"))

            def kaputt(services):
                raise RuntimeError("zweiter Dienst startet nicht")

            ctx.background(kaputt)
        """,
    )
    monkeypatch.setenv("CL_EXTENSIONS", "ext_zeder")
    main = _dienst(tmp_path, monkeypatch)
    with TestClient(main.app) as client:
        assert client.get("/probe/zeder").status_code == 404
        h = client.get("/health").json()
    assert h["extensions"] == []
    assert [x["name"] for x in h["extensions_failed"]] == ["ext_zeder"]
    log = sys.modules["ext_zeder"].log
    # Each attach (import and reload) started the first service and stopped it
    # at once; the app's shutdown does not stop it a second time.
    assert log and log == ["start", "stop"] * (len(log) // 2)


def test_oeffentlich_ohne_erweiterung(tmp_path, monkeypatch):
    """Die Fassung ohne jede Erweiterung: leere Listen, kein Fehler."""
    monkeypatch.setenv("CL_EXTENSIONS", "none")
    client = TestClient(_dienst(tmp_path, monkeypatch).app)
    h = client.get("/health").json()
    assert h["ok"] is True
    assert h["extensions"] == []
    assert h["extensions_failed"] == []
    # The network part of the core alone: routes counted, nothing else.
    assert h["exits"] == 0
    # Exactly the core's fields — whatever an extension reports is absent.
    assert set(h) == {
        "ok",
        "version",
        "uptime_s",
        "fork",
        "household",
        "buffer",
        "exits",
        "portals",
        "ready",
        "broken",
        "needs_setting",
        "extensions",
        "extensions_failed",
    }


# ── The hooks of the portal works (H1 kinds, H2 fields, H3 checks, H5 child) ──
#
# A made-up extension registers each piece by hand; `frisch` takes it away
# again. The kind `attrappe` and the field `farbe` exist only here.


class _Attrappe:
    """The portal object the made-up kind builds — inside the child."""

    def menu(self):
        import os

        return [{"id": "eins", "name": os.environ.get("CL_PROBE_KIND", "-")}]


def _attrappe_bauen(m):
    return _Attrappe()


def _manifest(tmp_path, body: str):
    from cinelounge.portalworks import manifest

    folder = tmp_path / "eibe"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "portal.yml").write_text(
        "api: 1\nid: eibe\nname: Eibe\nenabled: true\n" + body, encoding="utf-8"
    )
    return manifest.read(folder / "portal.yml")


def test_ohne_erweiterung_kennt_der_kern_nur_native(tmp_path):
    from cinelounge.portalworks import manifest

    assert manifest.kinds() == {"native"}
    assert manifest.allowed_keys() == manifest.CORE_KEYS
    m = _manifest(tmp_path, "kind: attrappe\n")
    assert m.broken_reason == "unknown kind: attrappe"
    assert registries.rank("native") == 0
    assert registries.rank("attrappe") == registries.UNKNOWN_RANK


def test_eine_art_wird_gelesen_und_im_kind_gebaut(tmp_path):
    """Registered before the fork, the child builds the portal through it."""
    from cinelounge.portalworks.runner import call as runner
    from cinelounge.portalworks.runner import fork

    registries.register_kind(registries.KindSpec("attrappe", build=_attrappe_bauen, rank=2))
    m = _manifest(tmp_path, "kind: attrappe\n")
    assert m.is_ready, m.broken_reason
    assert registries.rank("attrappe") == 2
    if not fork.available():
        pytest.skip("kein fork auf dieser Plattform")
    registries.seal()
    assert runner.call(m, "menu") == [{"id": "eins", "name": "-"}]


def test_die_art_prueft_ihr_manifest(tmp_path):
    registries.register_kind(
        registries.KindSpec(
            "attrappe", build=_attrappe_bauen, validate=lambda m: "attrappe braucht mehr"
        )
    )
    assert _manifest(tmp_path, "kind: attrappe\n").broken_reason == "attrappe braucht mehr"


def test_die_vorlademodule_einer_art_folgen_der_standardbibliothek():
    from cinelounge.portalworks.runner import preload

    registries.register_kind(
        registries.KindSpec("attrappe", build=_attrappe_bauen, preload=("colorsys", "json"))
    )
    namen = preload._modules()
    assert namen.index("colorsys") > namen.index("xml.parsers.expat")
    assert namen.count("json") == 1


def test_ein_feld_landet_in_extras_und_nur_auf_wunsch_im_json(tmp_path):
    def farbe(raw):
        if raw is None:
            return "grau", None
        if raw not in ("rot", "blau"):
            return None, f"farbe unknown: {raw}"
        return raw, None

    assert "unknown keys: farbe" in (
        _manifest(tmp_path, "kind: native\nfarbe: rot\n").broken_reason or ""
    )

    registries.register_field(registries.FieldSpec("farbe", farbe))
    (tmp_path / "eibe" / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    m = _manifest(tmp_path, "kind: native\nfarbe: rot\n")
    assert m.is_ready, m.broken_reason
    assert m.extras == {"farbe": "rot"}
    assert "farbe" not in m.as_json()
    assert _manifest(tmp_path, "kind: native\n").extras == {"farbe": "grau"}
    assert _manifest(tmp_path, "kind: native\nfarbe: lila\n").broken_reason == "farbe unknown: lila"


def test_ein_oeffentliches_feld_ueberschreibt_kein_kernfeld(tmp_path):
    registries.register_field(
        registries.FieldSpec("farbe", lambda raw: (raw, None), public_json=True)
    )
    registries.register_field(
        registries.FieldSpec("adult", lambda raw: ("nie", None), public_json=True)
    )
    (tmp_path / "eibe").mkdir()
    (tmp_path / "eibe" / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    m = _manifest(tmp_path, "kind: native\nfarbe: rot\n")
    j = m.as_json()
    assert j["farbe"] == "rot"
    assert j["adult"] is False


def test_ein_parser_der_wirft_macht_nur_dieses_portal_kaputt(tmp_path):
    def kaputt(raw):
        raise ValueError("geht nicht")

    registries.register_field(registries.FieldSpec("farbe", kaputt))
    m = _manifest(tmp_path, "kind: native\n")
    assert "farbe unreadable" in (m.broken_reason or "")


def test_eine_pruefung_macht_kaputt_und_wird_nach_dem_overlay_wiederholt(tmp_path):
    """A check's defect is looked at again after the household's values."""
    from cinelounge.portalworks import manifest

    def braucht_region(m):
        wert = next((e.get("value") for e in m.settings if e.get("key") == "region"), "")
        return None if wert == "nord" else "region must be nord"

    registries.register_check(braucht_region)
    (tmp_path / "eibe").mkdir()
    (tmp_path / "eibe" / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    m = _manifest(tmp_path, "kind: native\nsettings:\n  - key: region\n    value: sued\n")
    assert m.broken_reason == "region must be nord"
    manifest.overlay(m, {"region": "nord"})
    assert m.is_ready, m.broken_reason


def test_die_pruefung_der_erweiterung_steht_vor_der_pflichteinstellung(tmp_path):
    registries.register_check(lambda m: "eigener grund")
    (tmp_path / "eibe").mkdir()
    (tmp_path / "eibe" / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    m = _manifest(
        tmp_path, "kind: native\nsettings:\n  - key: token\n    value: ''\n    required: true\n"
    )
    assert m.broken_reason == "eigener grund"


def test_die_kindeinrichtung_laeuft_im_kind_vor_dem_bau(tmp_path):
    """The set-up sees the manifest and the route, and only the child keeps it."""
    from cinelounge.portalworks.runner import call as runner
    from cinelounge.portalworks.runner import fork

    if not fork.available():
        pytest.skip("kein fork auf dieser Plattform")

    def einrichten(m, via):
        os.environ["CL_PROBE_KIND"] = f"{m.id}:{via}"

    registries.register_kind(registries.KindSpec("attrappe", build=_attrappe_bauen))
    registries.register_child_setup(einrichten)
    m = _manifest(tmp_path, "kind: attrappe\n")
    registries.seal()
    assert runner.call(m, "menu") == [{"id": "eins", "name": "eibe:None"}]
    assert "CL_PROBE_KIND" not in os.environ


# ── The view hook (H8): what /list and /search hand out ──────────────────────
#
# A made-up extension stamps every item. The portal `ahorn` and its titles are
# invented; the runner is replaced, so no child is forked.

MANIFEST_AHORN = """
api: 1
id: ahorn
name: Ahorn
kind: native
capabilities: [search, languages]
enabled: true
"""

ANSICHT = """
    from cinelounge.web.extension import PortalViewHook

    class Kaputt(PortalViewHook):
        def items(self, m, items):
            raise RuntimeError("Haken kaputt")

    class Stempel(PortalViewHook):
        def items(self, m, items):
            for i in items:
                i.setdefault("stempel", m.id)

    def install(ctx):
        # The broken one first: it must not keep the next one from running.
        ctx.view_hook(Kaputt())
        ctx.view_hook(Stempel())
"""


def _haushalt(tmp_path, monkeypatch, manifest: str = MANIFEST_AHORN):
    """The service with one portal and one admin device — client and headers."""
    from cinelounge.household.devices import Devices
    from cinelounge.household.people import People

    folder = tmp_path / "portals" / "ahorn"
    folder.mkdir(parents=True)
    (folder / "portal.yml").write_text(manifest, encoding="utf-8")
    (folder / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    main = _dienst(tmp_path, monkeypatch)
    d = main.app.state.services
    People(d.store).create("Tester", "admin", "1234")
    geraete = Devices(d.store)
    code = geraete.request_code("Probe-Gerät", "iOS 18.7", "192.0.2.5")
    token = geraete.redeem(code.token, user_id="tester")
    return TestClient(main.app), {"X-CL-Device": token}


def _laeufer(monkeypatch, items):
    """Answer `listing` and `search` with copies of `items`, without a child."""
    from cinelounge.portalworks import einmal
    from cinelounge.web import portals

    def call(m, method, argumente=None, **kw):
        if method == "listing":
            return {"items": [dict(i) for i in items], "next_page": None}
        if method == "search":
            return [dict(i) for i in items]
        raise AssertionError(f"unexpected call {method}")

    einmal.vergiss()
    monkeypatch.setattr(portals.runner, "call", call)
    return einmal


TITEL = [{"title": "Die Seereise des Kalon", "address": "f=kalon"}]


def test_der_ansichtshaken_sieht_liste_und_suche(modul, tmp_path, monkeypatch, caplog):
    modul("ext_esche", ANSICHT)
    monkeypatch.setenv("CL_EXTENSIONS", "ext_esche")
    client, head = _haushalt(tmp_path, monkeypatch)
    einmal = _laeufer(monkeypatch, TITEL)

    for _ in range(2):  # the second answer comes from the cached page
        page = client.get("/p/ahorn/list?entry=e1", headers=head)
        assert page.status_code == 200, page.text
        assert [i["stempel"] for i in page.json()["items"]] == ["ahorn"]

    found = client.get("/search?q=kalon", headers=head).json()
    assert found["failed"] == {}
    assert [i["stempel"] for i in found["hits"]["ahorn"]] == ["ahorn"]

    # The broken hook is named in the log, and only skipped.
    assert "view hook failed" in caplog.text

    # The hooks got copies: the cached page carries neither their field nor the
    # route's own `key`/`state`.
    def nie():
        raise AssertionError("fetched again")

    try:
        cached = einmal.einmal(("ahorn", "listing", "e1", None, ""), nie)
        assert cached["items"] == TITEL
    finally:
        einmal.vergiss()


def test_ohne_erweiterung_bleiben_die_eintraege_wie_sie_kommen(tmp_path, monkeypatch):
    monkeypatch.setenv("CL_EXTENSIONS", "none")
    client, head = _haushalt(tmp_path, monkeypatch)
    einmal = _laeufer(monkeypatch, TITEL)
    try:
        [item] = client.get("/p/ahorn/list?entry=e1", headers=head).json()["items"]
        [hit] = client.get("/search?q=kalon", headers=head).json()["hits"]["ahorn"]
    finally:
        einmal.vergiss()
    assert "stempel" not in item and "stempel" not in hit
    assert item["title"] == hit["title"] == "Die Seereise des Kalon"


# ── The view hook: menu, opened entry, played address ───────────────────────
#
# Made up: a hook that turns the menu around and notes what was opened and
# played, and one that always fails in front of it.

FOLGE = """
    from cinelounge.web.extension import PortalViewHook

    notiert = []

    class Kaputt(PortalViewHook):
        def menu(self, request, person, m, entries):
            # Halfway through: changed in place, then failed.
            entries[1]["name"] = "halb"
            raise RuntimeError("Haken kaputt")

        def opened(self, request, person, m, entry):
            raise RuntimeError("Haken kaputt")

    class Folge(PortalViewHook):
        def menu(self, request, person, m, entries):
            entries[0]["name"] = "geaendert"
            return [*reversed(entries), {"id": "dazu", "name": person.name}]

        def opened(self, request, person, m, entry):
            notiert.append(("opened", person.id, m.id, entry))

        def played(self, request, person, m, address):
            notiert.append(("played", person.id, m.id, address))

    def install(ctx):
        ctx.view_hook(Kaputt())
        ctx.view_hook(Folge())
"""

MENUE = [{"id": "e1", "name": "Eins"}, {"id": "e2", "name": "Zwei"}]


def _menue_und_wiedergabe(monkeypatch):
    from cinelounge.portalworks import einmal, playback
    from cinelounge.web import portals

    def call(m, method, argumente=None, **kw):
        if method == "menu":
            return [dict(e) for e in MENUE]
        if method == "listing":
            # No next page: fetching it ahead would start a thread that may
            # outlive this test's stub.
            return {"items": [dict(i) for i in TITEL], "next_page": None}
        return None

    einmal.vergiss()
    monkeypatch.setattr(portals.runner, "call", call)
    monkeypatch.setattr(
        playback,
        "resolve_play",
        lambda m, **k: {"address": "http://192.0.2.9/v.mp4", "source": "q1", "kind": "file"},
    )
    return einmal


def test_der_ansichtshaken_sieht_menue_oeffnen_und_abspielen(modul, tmp_path, monkeypatch):
    modul("ext_kiefer", FOLGE)
    monkeypatch.setenv("CL_EXTENSIONS", "ext_kiefer")
    client, head = _haushalt(tmp_path, monkeypatch)
    einmal = _menue_und_wiedergabe(monkeypatch)
    try:
        entries = client.get("/p/ahorn/menu", headers=head).json()["entries"]
        # The broken hook is skipped; the next one works on what came before
        # it — without the change it made in place before raising.
        assert entries == [
            {"id": "e2", "name": "Zwei"},
            {"id": "e1", "name": "geaendert"},
            {"id": "dazu", "name": "Tester"},
        ]
        # The cached menu stays as the portal gave it.
        assert einmal.einmal(("ahorn", "menu"), lambda: None) == MENUE

        client.get("/p/ahorn/list?entry=e1", headers=head)
        client.get("/p/ahorn/list?entry=e1&next=s2", headers=head)
        client.get("/p/ahorn/list?entry=e1&input=Frage", headers=head)
        a = client.get("/play?portal=ahorn&address=f%3Dkalon", headers=head)
        assert a.status_code == 200, a.text
        client.get("/play?portal=ahorn&source=q7", headers=head)
    finally:
        einmal.vergiss()
    # Opened is the first page only; played names the address, else the source.
    assert sys.modules["ext_kiefer"].notiert == [
        ("opened", "tester", "ahorn", "e1"),
        ("played", "tester", "ahorn", "f=kalon"),
        ("played", "tester", "ahorn", "q7"),
    ]


def test_ohne_erweiterung_bleibt_das_menue_wie_es_kommt(tmp_path, monkeypatch):
    monkeypatch.setenv("CL_EXTENSIONS", "none")
    client, head = _haushalt(tmp_path, monkeypatch)
    einmal = _menue_und_wiedergabe(monkeypatch)
    try:
        assert client.get("/p/ahorn/menu", headers=head).json() == {
            "portal": "ahorn",
            "entries": MENUE,
        }
        assert client.get("/play?portal=ahorn&address=x", headers=head).status_code == 200
    finally:
        einmal.vergiss()


# ── Tables of an extension's own (`ctx.store_migrations`) ───────────────────

TABELLE = """
    from fastapi import APIRouter

    from cinelounge.web.extension import PortalViewHook

    router = APIRouter()
    gefragt = []

    @router.get("/probe/linde")
    def probe():
        return {"from": "linde"}

    class Haken(PortalViewHook):
        def menu(self, request, person, m, entries):
            gefragt.append(m.id)
            return entries

    def zweiter(v):
        v.execute("INSERT INTO linde_notiz (text) VALUES ('angelegt')")

    SCHRITTE = ["CREATE TABLE IF NOT EXISTS linde_notiz (text TEXT NOT NULL)", zweiter]

    def install(ctx):
        ctx.store_migrations("linde", SCHRITTE)
        ctx.include_router(router)
        ctx.view_hook(Haken())
"""


def test_die_tabellen_einer_erweiterung_kommen_mit_dem_haushalt(modul, tmp_path, monkeypatch):
    modul("ext_linde", TABELLE)
    monkeypatch.setenv("CL_EXTENSIONS", "ext_linde")
    main = _dienst(tmp_path, monkeypatch)
    d = main.app.state.services
    with d.store.connect() as v:
        assert [r[0] for r in v.execute("SELECT text FROM linde_notiz")] == ["angelegt"]
        assert [tuple(r) for r in v.execute("SELECT * FROM schema_ext")] == [("linde", 2)]
    # Opening the household again runs nothing twice.
    from cinelounge.web.access import Services

    Services.from_path(tmp_path)
    with d.store.connect() as v:
        assert v.execute("SELECT COUNT(*) FROM linde_notiz").fetchone()[0] == 1
    assert TestClient(main.app).get("/health").json()["extensions"] == ["ext_linde"]


def test_ein_gescheiterter_schritt_nimmt_die_erweiterung_heraus(modul, tmp_path, monkeypatch):
    modul("ext_linde", TABELLE.replace("VALUES ('angelegt')", "VALUES (NULL)"))
    monkeypatch.setenv("CL_EXTENSIONS", "ext_linde")
    client, head = _haushalt(tmp_path, monkeypatch)
    einmal = _menue_und_wiedergabe(monkeypatch)
    try:
        h = client.get("/health").json()
        assert h["ok"] is True
        assert h["extensions"] == []
        [failed] = h["extensions_failed"]
        assert (failed["name"], failed["phase"]) == ("ext_linde", "migrate")
        # Nothing of it answers, and its hooks are not asked.
        assert client.get("/probe/linde").status_code == 404
        assert client.get("/p/ahorn/menu", headers=head).json()["entries"] == MENUE
        assert sys.modules["ext_linde"].gefragt == []
    finally:
        einmal.vergiss()
    # The first step stands, the failed one is taken back and will run again.
    with client.app.state.services.store.connect() as v:
        assert v.execute("SELECT COUNT(*) FROM linde_notiz").fetchone()[0] == 0
        assert [tuple(r) for r in v.execute("SELECT * FROM schema_ext")] == [("linde", 1)]


def test_ein_namensraum_gehoert_einer_erweiterung(modul, monkeypatch):
    modul("ext_ulme", "def install(ctx):\n    ctx.store_migrations('ulme', [])\n")
    modul("ext_ulme2", "def install(ctx):\n    ctx.store_migrations('ulme', [])\n")
    monkeypatch.setenv("CL_EXTENSIONS", "ext_ulme,ext_ulme2")
    assert extension.load() == ["ext_ulme"]
    [failed] = extension.health()["extensions_failed"]
    assert failed["name"] == "ext_ulme2" and "already registered" in failed["error"]


# ── Addresses answered from memory (`proxy.register_scheme`) ────────────────
#
# The scheme `probe-lokal` and the hosts below are invented. Each test gets
# its own copies of the relay's tables, and no request leaves the process.

LISTE = (
    "#EXTM3U\n"
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="ton",URI="https://cdn.example/ton.m3u8"\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=2048000,AUDIO="ton"\n'
    "https://cdn.example/bild720.m3u8\n"
)
LOKAL = "probe-lokal://k/liste.m3u8"


@pytest.fixture
def relais(monkeypatch):
    from cinelounge.stream import proxy

    monkeypatch.setattr(proxy, "_SCHEMATA", dict(proxy._SCHEMATA))
    monkeypatch.setattr(proxy, "_ERLAUBT", {})
    monkeypatch.setattr(proxy, "_WEG", {})

    def kein_netz(*a, **kw):
        raise AssertionError("a local address went out to the network")

    monkeypatch.setattr(proxy.requests, "get", kein_netz)
    monkeypatch.setattr(proxy.requests, "head", kein_netz)
    return proxy


def _ziele(body: bytes) -> list[str]:
    from urllib.parse import parse_qs, urlsplit

    return [
        parse_qs(urlsplit(z).query)["address"][0]
        for z in body.decode().replace('"', "\n").splitlines()
        if z.startswith("http://cl/stream?")
    ]


@pytest.mark.parametrize("schema", ["http", "https", "HTTPS", "file", ""])
def test_ein_netzschema_laesst_sich_nicht_anmelden(relais, schema):
    with pytest.raises(ValueError):
        relais.register_scheme(schema, lambda a: LISTE)
    assert not relais.is_local("https://cdn.example/bild720.m3u8")


def test_eine_lokale_liste_kommt_umgeschrieben_aus_dem_leser(relais):
    relais.register_scheme("Probe-Lokal", lambda a: LISTE if a == LOKAL else None)
    relais.allow(LOKAL, {"Referer": "https://quelle.example/"})

    assert relais.is_local(LOKAL)
    assert relais.is_local("PROBE-LOKAL://k/anders.m3u8")
    assert not relais.is_local("https://cdn.example/bild720.m3u8")

    progress, head, body, whole = relais.fetch(LOKAL, None, "http://cl")
    assert (progress, whole) == (200, True)
    assert "mpegurl" in head["Content-Type"]
    assert isinstance(body, bytes)
    assert _ziele(body) == ["https://cdn.example/ton.m3u8", "https://cdn.example/bild720.m3u8"]
    # The links go out like those of any other list: cleared, with the list's headers.
    assert relais.is_allowed("https://cdn.example/bild720.m3u8")
    assert relais.headers_for("https://cdn.example/ton.m3u8") == {
        "Referer": "https://quelle.example/"
    }

    status, kopf = relais.head_only(LOKAL)
    assert status == 200 and "mpegurl" in kopf["Content-Type"]


def test_ein_leser_der_das_relais_selbst_fragt_verklemmt_nicht(relais):
    """The reader runs outside the relay's lock — one that takes it must not hang."""
    import threading

    def leser(adresse):
        relais.allow("https://cdn.example/vorab.ts", {})
        assert relais.is_allowed("https://cdn.example/vorab.ts")
        return LISTE

    relais.register_scheme("probe-lokal", leser)
    ergebnis = []
    faden = threading.Thread(
        target=lambda: ergebnis.append(
            (relais.fetch(LOKAL, None, "http://cl"), relais.head_only(LOKAL))
        ),
        daemon=True,
    )
    faden.start()
    faden.join(5)
    assert not faden.is_alive(), "fetch/head_only hung on the relay's lock"
    [((progress, _, body, _), (status, _))] = ergebnis
    assert (progress, status) == (200, 200)
    assert _ziele(body)


# ── The marketplace index: only what an extension publishes (Naht, 23.11.2026) ─


def _markt_eintrag(**dazu):
    e = {"id": "eibe", "version": "1.0.0", "url": "https://example.test/e.tgz", "sha256": "a" * 64}
    e.update(dazu)
    return json.dumps({"api": 1, "portals": [e]})


def test_der_markt_kennt_ohne_erweiterung_kein_wegfeld():
    """`net` stand fest im Index des Kerns; seit der Naht ist es ein Feld der
    Erweiterung. Ohne sie ist es ein unbekannter Schluessel wie jeder andere."""
    from cinelounge.market import index

    d, klagen = index.read(_markt_eintrag(net="direct"))
    assert d["portals"] == [] and "unknown keys: net" in klagen[0]
    d, klagen = index.read(_markt_eintrag())
    assert not klagen and "net" not in d["portals"][0]


def test_der_markt_nimmt_ein_veroeffentlichtes_feld_mit_seinem_parser():
    from cinelounge.market import index

    def farbe(raw):
        if raw is None:
            return "grau", None
        return (raw, None) if raw in ("rot", "blau") else (None, f"farbe unknown: {raw}")

    registries.register_field(registries.FieldSpec("farbe", farbe, public_json=True))
    registries.register_field(registries.FieldSpec("innen", lambda raw: (raw, None)))
    registries.register_field(
        registries.FieldSpec("adult", lambda raw: ("nie", None), public_json=True)
    )

    d, klagen = index.read(_markt_eintrag(farbe="rot", adult=True))
    assert not klagen
    (e,) = d["portals"]
    assert e["farbe"] == "rot" and e["adult"] is True, "kein Kernfeld wird ueberschrieben"
    assert index.read(_markt_eintrag())[0]["portals"][0]["farbe"] == "grau"
    _, klagen = index.read(_markt_eintrag(farbe="lila"))
    assert klagen == ["entry eibe: farbe unknown: lila"]
    # Nur veroeffentlichte Felder: ein inneres bleibt unbekannt.
    _, klagen = index.read(_markt_eintrag(innen="x"))
    assert "unknown keys: innen" in klagen[0]
