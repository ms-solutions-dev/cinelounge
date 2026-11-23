"""Network routes — reading them, their state, the registry's verdict, the API.

What is checked here is what would otherwise fail silently: a portal laid
onto a route nobody offers going out directly, a stored override with a typo
turning into a route, a relay fetching a routed portal's video over the
house's connection, a proxy password leaving through the API.

All names are made up; every proxy listens on 127.0.0.1 or nowhere.
"""

from __future__ import annotations

import http.server
import threading
from pathlib import Path

import pytest

from cinelounge.core import errors as f
from cinelounge.portalworks import extension as registries
from cinelounge.portalworks import routes
from cinelounge.portalworks.manifest import NET_OVERRIDE_KEY, allowed_keys, overlay, read
from cinelounge.portalworks.registry import Registry
from cinelounge.portalworks.runner import call as runner_call
from cinelounge.stream import proxy
from cinelounge.web import extension, telegram
from cinelounge.web import network as netz
from tests.test_web import world  # noqa: F401 — the fixture is needed

NATIVE = """
api: 1
id: {id}
name: {{en: {id}}}
kind: native
"""


def _portal(root: Path, id_: str, extra: str = "") -> Path:
    folder = root / "portals" / id_
    folder.mkdir(parents=True)
    (folder / "portal.yml").write_text(NATIVE.format(id=id_) + extra, encoding="utf-8")
    (folder / "portal.py").write_text("class Portal: pass\n", encoding="utf-8")
    return folder / "portal.yml"


@pytest.fixture(autouse=True)
def _keine_routen():
    """Every test starts without routes of the core — and leaves none behind."""
    routes.configure("")
    routes.set_saved([])
    yield
    routes.configure("")
    routes.set_saved([])


@pytest.fixture
def anbieter(monkeypatch):
    """Register route providers for one test, past the seal of the preload,
    and take them out again afterwards."""
    monkeypatch.setattr(registries, "_SEALED", False)
    added: list[routes.RouteProvider] = []

    def add(p: routes.RouteProvider) -> routes.RouteProvider:
        routes.register_provider(p)
        added.append(p)
        return p

    yield add
    for p in added:
        routes.PROVIDERS._items.remove(p)
    routes.forget_states()


class _Probe(routes.RouteProvider):
    """A provider with one route and a portal it chooses for."""

    def __init__(self) -> None:
        self.asked: list[str] = []

    def routes(self) -> list[routes.Route]:
        return [routes.Route("probe-weg", "http://127.0.0.1:1")]

    def status(self, route: routes.Route) -> dict:
        self.asked.append(route.name)
        return {"id": route.name, "state": "running", "ms": 3}

    def choose(self, m):
        return "probe-weg" if m.id == "birke" else None

    def details(self, name: str) -> dict:
        return {"merkmal": name}

    def reject(self, name: str) -> str | None:
        return "network.bad_route" if name.startswith("x") else None


# ── Reading CL_PROXIES ───────────────────────────────────────────────────────


def test_cl_proxies_werden_gelesen_und_unsinn_faellt_weg():
    found = routes.configure(
        "werkstatt=http://127.0.0.1:3128, nord=http://anna:geheim@proxy.example:8080 "
        "grüß=http://x direct=http://x leer= =http://x alt=ftp://x pfad=http://x/y"
    )
    assert set(found) == {"werkstatt", "nord"}
    assert routes.get("nord").proxy_url == "http://anna:geheim@proxy.example:8080"
    assert routes.get("nord").shown == "proxy.example:8080"
    assert routes.get("direct") is None and routes.get("") is None and routes.get(None) is None
    assert routes.exists("werkstatt") and not routes.exists("sued")
    assert routes.is_routed("nord") and not routes.is_routed("direct")
    assert not routes.is_routed(None)
    assert routes.source_of("werkstatt") == "environment"


def test_gespeicherte_proxies_kommen_dazu_aber_nie_ueber_die_umgebung():
    routes.configure("nord=http://127.0.0.1:3128")
    routes.set_saved([("nord", "http://127.0.0.1:9"), ("sued", "http://127.0.0.1:8"), ("X", "y")])
    assert [r.name for r in routes.all_routes()] == ["nord", "sued"]
    assert routes.get("nord").proxy_url == "http://127.0.0.1:3128", "the environment wins"
    assert routes.source_of("sued") == "console"
    assert [r.name for r in routes.saved()] == ["nord", "sued"]


# ── States ───────────────────────────────────────────────────────────────────


def test_ein_proxy_ohne_dienst_ist_unerreichbar_mit_grund():
    routes.configure("tot=http://127.0.0.1:1")
    z = routes.status(routes.get("tot"))
    assert z["state"] == "unreachable"
    assert z["why"]  # the kind of failure, not just "no"
    assert z["ms"] is None and z["host"] == "127.0.0.1:1" and z["source"] == "environment"


def test_ein_proxy_der_http_spricht_laeuft():
    """Any HTTP answer shows a proxy listening — nothing goes out through it."""

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_HEAD(self):
            self.send_response(400)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        routes.configure(f"werkstatt=http://127.0.0.1:{server.server_port}")
        z = routes.status(routes.get("werkstatt"))
        assert z["state"] == "running"
        assert isinstance(z["ms"], int)
    finally:
        server.shutdown()


def test_zustaende_werden_parallel_gefragt_und_gemerkt(monkeypatch):
    """Owner, 09.11.2026: every page waited 5.6 s because two dead routes were
    asked one after the other. Now the slowest sets the pace, and the next page
    gets the remembered state."""
    import time as _time

    asked = []

    def slow(route, patience_s):
        asked.append(route.name)
        _time.sleep(0.5)
        return {"state": "unreachable", "ms": None}

    monkeypatch.setattr(routes, "_knock", slow)
    routes.configure("nord=http://127.0.0.1:1 sued=http://127.0.0.1:2")
    zwei = [routes.get("nord"), routes.get("sued")]
    t0 = _time.monotonic()
    assert [s["id"] for s in routes.statuses(zwei)] == ["nord", "sued"]
    assert _time.monotonic() - t0 < 0.9, "asked one after the other"
    t0 = _time.monotonic()
    routes.statuses(zwei)
    assert _time.monotonic() - t0 < 0.1 and sorted(asked) == ["nord", "sued"], "not remembered"


# ── The registry's verdict ───────────────────────────────────────────────────


def test_portal_auf_fehlendem_weg_ist_defekt_mit_grund(tmp_path):
    _portal(tmp_path, "linde")
    _portal(tmp_path, "zinne")
    stored = {"linde": {NET_OVERRIDE_KEY: "nord"}}
    r = Registry(tmp_path / "portals", overrides=lambda pid: stored.get(pid, {}))
    assert r.manifests["zinne"].is_ready
    assert r.manifests["linde"].broken_reason == "no exit for net: nord"

    # The route arrives — and the next reload says ready without anybody
    # touching the portal.
    routes.configure("nord=http://127.0.0.1:1")
    r.reload()
    assert r.manifests["linde"].is_ready
    assert r.manifests["linde"].exit_net == "nord"
    assert routes.proxy_for(r.manifests["linde"]) == "http://127.0.0.1:1"
    assert routes.proxy_for(r.manifests["zinne"]) is None


def test_der_betreiber_legt_ein_portal_auf_einen_weg(tmp_path):
    routes.configure("werkstatt=http://127.0.0.1:1")
    file = _portal(tmp_path, "zinne")
    m = read(file)
    assert m.exit_net == "direct" and m.net_override is None

    overlay(m, {NET_OVERRIDE_KEY: "werkstatt"})
    assert m.net_override == "werkstatt" and m.exit_net == "werkstatt"
    assert m.as_json()["exit_net"] == "werkstatt"
    assert m.as_json()["net_override"] == "werkstatt"

    # Not a name at all: nothing, the default applies.
    m2 = read(file)
    overlay(m2, {NET_OVERRIDE_KEY: "Kein Name!"})
    assert m2.net_override is None and m2.exit_net == "direct"

    # `direct` is always allowed.
    m3 = read(file)
    overlay(m3, {NET_OVERRIDE_KEY: "direct"})
    assert m3.net_override == "direct" and m3.exit_net == "direct"


def test_ein_altes_net_direct_wird_noch_gelesen(tmp_path):
    """Older manifests carried `net: direct`; such a folder must still read."""
    m = read(_portal(tmp_path, "zinne", "net: direct\n"))
    assert m.is_ready, m.broken_reason
    assert m.exit_net == "direct"
    if "net" not in allowed_keys():
        other = read(_portal(tmp_path, "linde", "net: werkstatt\n"))
        assert other.broken_reason == "unknown keys: net"


# ── The relay's way out ──────────────────────────────────────────────────────


def test_das_relais_merkt_sich_den_weg_je_host():
    proxy.allow("https://cdn.example.org/v/1.mp4", {"Referer": "x"}, "http://127.0.0.1:3128")
    assert proxy.via_for("https://cdn.example.org/other") == "http://127.0.0.1:3128"
    assert proxy.headers_for("https://cdn.example.org/other") == {"Referer": "x"}
    # Direct again takes the way out with it — a stale route would send the
    # next portal's video through another proxy.
    proxy.allow("https://cdn.example.org/v/2.mp4", {})
    assert proxy.via_for("https://cdn.example.org/v/2.mp4") is None


# ── Over HTTP ────────────────────────────────────────────────────────────────


def test_netz_ansicht_zuordnung_und_proxies_ueber_http(world, monkeypatch):  # noqa: F811
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}
    d = client.app.state.services
    ohne = [e["id"] for e in client.get("/network/exits", headers=head).json()["exits"]]

    # Nobody set up a route: a wish for one is a 422.
    a = client.get("/network/exits", headers=head)
    assert a.status_code == 200 and a.json()["without_exit"] == []
    b = client.post("/household/portals/ahorn/net", json={"net": "werkstatt"}, headers=head)
    assert b.status_code == 422
    assert b.json()["error"]["code"] == (routes.reject("werkstatt") or "network.no_exit")

    # A proxy saved in the console — the password never comes back.
    b = client.put(
        "/network/exits",
        json={"name": "werkstatt", "address": "http://anna:geheim@127.0.0.1:1"},
        headers=head,
    )
    assert b.status_code == 200, b.text
    assert "geheim" not in b.text
    karte = next(e for e in b.json()["exits"] if e["id"] == "werkstatt")
    assert karte["state"] == "unreachable" and karte["host"] == "127.0.0.1:1"
    assert karte["source"] == "console" and karte["portals"] == []
    assert [e["id"] for e in b.json()["exits"]] == [*ohne, "werkstatt"]
    assert "werkstatt" in d.store.read(netz.SAVED_KEY, "")

    # The portal onto the route.
    b = client.post("/household/portals/ahorn/net", json={"net": "werkstatt"}, headers=head)
    assert b.status_code == 200
    assert b.json()["exit_net"] == "werkstatt" and b.json()["net_override"] == "werkstatt"
    assert d.registry.manifests["ahorn"].exit_net == "werkstatt"
    a = client.get("/network/exits", headers=head)
    assert next(e for e in a.json()["exits"] if e["id"] == "werkstatt")["portals"] == ["ahorn"]

    # The probe tries every portal on the route.
    def call(m, method, arguments=None, *_a, **_k):
        if m.id == "ahorn":
            raise f.Error("run.failed", {"host": "zinne.example", "why": "kaputt"})
        return [{"id": "e1"}] if method == "menu" else {"items": []}

    monkeypatch.setattr(netz.runner, "call", call)
    p = client.post("/network/exits/werkstatt/probe", headers=head)
    assert p.status_code == 200
    (geprueft,) = p.json()["checked"]
    assert geprueft["portal"] == "ahorn" and geprueft["ok"] is False
    assert geprueft["code"] == "run.failed" and geprueft["host"] == "zinne.example"
    assert client.post("/network/exits/sued/probe", headers=head).status_code == 404

    # Survives a restart: laid in again from the household.
    routes.set_saved([])
    netz.load_saved(d)
    assert routes.exists("werkstatt")

    # Removed: the portal stays on it and is broken, with the route named.
    b = client.delete("/network/exits/werkstatt", headers=head)
    assert b.status_code == 200
    assert {"id": "ahorn", "net": "werkstatt"} in b.json()["without_exit"]
    assert d.registry.manifests["ahorn"].broken_reason == "no exit for net: werkstatt"

    # Handed back: direct again, and ready.
    b = client.post("/household/portals/ahorn/net", json={"net": ""}, headers=head)
    assert b.status_code == 200 and b.json()["exit_net"] == "direct"
    assert b.json()["state"] == "ready"

    codes = [e["code"] for e in d.events.recent()]
    assert "event.route_saved" in codes and "event.route_removed" in codes

    # Not for a viewer.
    z = client.get("/network/exits", headers={"X-CL-Device": tokens["sina"]})
    assert z.status_code == 403
    z = client.put(
        "/network/exits",
        json={"name": "x", "address": "http://127.0.0.1:1"},
        headers={"X-CL-Device": tokens["sina"]},
    )
    assert z.status_code == 403


def test_falsche_proxies_und_feste_namen_ueber_http(world):  # noqa: F811
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}
    for name, address in (
        ("Werkstatt!", "http://127.0.0.1:1"),
        ("direct", "http://127.0.0.1:1"),
        ("werkstatt", "ftp://127.0.0.1:1"),
        ("werkstatt", "http://"),
    ):
        b = client.put("/network/exits", json={"name": name, "address": address}, headers=head)
        assert b.status_code == 422 and b.json()["error"]["code"] == "network.bad_route", name

    # A name the environment offers is not the console's.
    routes.configure("fest=http://127.0.0.1:1")
    b = client.put(
        "/network/exits", json={"name": "fest", "address": "http://127.0.0.1:2"}, headers=head
    )
    assert b.status_code == 409 and b.json()["error"]["code"] == "network.route_taken"
    b = client.delete("/network/exits/fest", headers=head)
    assert b.status_code == 409 and b.json()["error"]["code"] == "network.route_taken"
    b = client.delete("/network/exits/nirgends", headers=head)
    assert b.status_code == 404 and b.json()["error"]["code"] == "network.no_exit"


# ── Providers of extensions ──────────────────────────────────────────────────


def test_ein_anbieter_bringt_wege_wahl_und_zusatzfelder(world, anbieter):  # noqa: F811
    probe = anbieter(_Probe())
    client, tokens = world
    head = {"X-CL-Device": tokens["max"]}

    assert routes.exists("probe-weg")
    assert routes.source_of("probe-weg") == "extension"
    a = client.get("/network/exits", headers=head).json()
    karte = next(e for e in a["exits"] if e["id"] == "probe-weg")
    assert karte["state"] == "running" and karte["merkmal"] == "probe-weg"
    assert probe.asked == ["probe-weg"]
    # Remembered: the second look does not ask again.
    client.get("/network/exits", headers=head)
    assert probe.asked == ["probe-weg"]

    # A name a provider objects to gets that provider's code.
    assert routes.reject("xweg") is not None
    b = client.post("/household/portals/ahorn/net", json={"net": "xweg"}, headers=head)
    assert b.status_code == 422 and b.json()["error"]["code"] == routes.reject("xweg")
    # A name the console offers cannot be taken by the console twice.
    b = client.put(
        "/network/exits", json={"name": "probe-weg", "address": "http://127.0.0.1:2"}, headers=head
    )
    assert b.status_code == 409


def test_die_wahl_des_anbieters_gilt_ohne_betreiberwahl(anbieter, tmp_path):
    anbieter(_Probe())
    m = read(_portal(tmp_path, "birke"))
    assert m.exit_net == "probe-weg"
    assert routes.proxy_for(m) == "http://127.0.0.1:1"
    overlay(m, {NET_OVERRIDE_KEY: "direct"})
    assert m.exit_net == "direct", "the operator's choice wins"


# ── The other hooks of this wave ─────────────────────────────────────────────


@pytest.fixture
def beobachter(monkeypatch):
    monkeypatch.setattr(registries, "_SEALED", False)
    seen: list[tuple[str, str, str | None]] = []

    def observe(m, method, err):
        seen.append((m.id, method, err.code if err else None))

    def kaputt(m, method, err):
        raise RuntimeError("observer down")

    registries.register_call_observer(kaputt)
    registries.register_call_observer(observe)
    yield seen
    registries.CALL_OBSERVERS._items.remove(kaputt)
    registries.CALL_OBSERVERS._items.remove(observe)


def test_aufrufbeobachter_hoeren_erfolg_und_fehler(beobachter, tmp_path, monkeypatch):
    m = read(_portal(tmp_path, "zinne"))
    monkeypatch.setattr(runner_call, "run", lambda work, limits=None: ["ok"])
    assert runner_call.call(m, "menu") == ["ok"]

    def failing(work, limits=None):
        raise f.Error("run.failed", {"why": "x"})

    monkeypatch.setattr(runner_call, "run", failing)
    with pytest.raises(f.Error):
        runner_call.call(m, "listing")
    assert beobachter == [("zinne", "menu", None), ("zinne", "listing", "run.failed")]


@pytest.fixture
def beitrag():
    """An extension context that counts as installed for one test."""
    ctx = extension.ExtensionContext("probe")
    extension._STATE.installed.append(ctx)
    yield ctx
    extension._STATE.installed.remove(ctx)


def test_fehlerbeobachter_sieht_jede_fehlerantwort(beitrag, world):  # noqa: F811
    client, tokens = world
    seen = []
    beitrag.error_observer(lambda request, err: seen.append((request.url.path, err.code)))
    beitrag.error_observer(lambda request, err: 1 / 0)  # a failing one changes nothing
    b = client.delete("/network/exits/nirgends", headers={"X-CL-Device": tokens["max"]})
    assert b.status_code == 404 and b.json()["error"]["code"] == "network.no_exit"
    assert seen == [("/network/exits/nirgends", "network.no_exit")]


def test_texte_einer_erweiterung_ersetzen_die_des_kerns(beitrag):
    neutral = telegram._texts("de")["exit_down"]
    assert "{exit}" in neutral
    beitrag.event_texts({"de": {"exit_down": "Probe {exit}"}}, {"exit_down": {"exit": "west"}})
    assert telegram._texts("de")["exit_down"] == "Probe {exit}"
    assert telegram._texts("en")["exit_down"] != "Probe {exit}"
    assert extension.event_examples()["exit_down"] == {"exit": "west"}
