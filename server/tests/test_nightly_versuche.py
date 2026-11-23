"""`portalworks/nightly.py` — further titles and entry points before red.

**With a stand-in runner, not the child process.** What is measured here is the
order of the attempts, not a portal: `runner.call` is replaced by a table of
answers, and the knock always carries. That keeps these tests off `fork` and
off the network.
"""

from __future__ import annotations

from pathlib import Path

import pytest

WURZEL = Path(__file__).resolve().parent.parent


@pytest.fixture()
def manifest():
    from cinelounge.portalworks import manifest as manifest_lesen

    m = manifest_lesen.read(WURZEL / "portals" / "beispiel" / "portal.yml")
    assert m.is_ready, m.broken_reason
    return m


class Runner:
    """Answers per method from a table and records every call."""

    def __init__(self, menu, listings, sources):
        self.menu = menu
        self.listings = listings
        self.sources = sources
        self.calls: list[tuple[str, str]] = []

    def __call__(self, m, method, arguments=None, *rest, **kw):
        arguments = arguments or {}
        if method == "menu":
            self.calls.append(("menu", ""))
            return self.menu
        if method == "listing":
            self.calls.append(("listing", arguments["entry"]))
            return {"items": self.listings.get(arguments["entry"], [])}
        if method == "sources":
            self.calls.append(("sources", arguments["address"]))
            return [
                {"id": f"{arguments['address']}#q", "name": "Q"}
                for _ in range(self.sources.get(arguments["address"], 0))
            ]
        if method == "resolve":
            self.calls.append(("resolve", arguments["source"]))
            return {"address": "https://cdn.example/" + arguments["source"], "resolved": True}
        raise AssertionError(method)

    def count(self, method: str) -> int:
        return sum(1 for c in self.calls if c[0] == method)


@pytest.fixture()
def einsetzen(monkeypatch):
    from cinelounge.portalworks import nightly
    from cinelounge.portalworks.runner import call as runner

    monkeypatch.setattr(nightly, "_klopfen", lambda address, headers, via: True)

    def setzen(r: Runner) -> Runner:
        monkeypatch.setattr(runner, "call", r)
        return r

    return setzen


def _titel(*namen: str) -> list[dict]:
    return [{"title": n, "address": n, "has_children": False} for n in namen]


def test_second_title_with_sources_is_green(manifest, einsetzen):
    """An announced film without sources on top, a real one below."""
    from cinelounge.portalworks import nightly

    r = einsetzen(
        Runner(
            menu=[{"id": "neu", "name": "Neue Filme"}],
            listings={"neu": _titel("kommt-bald", "laeuft")},
            sources={"laeuft": 1},
        )
    )
    ergebnis = nightly.check(manifest)

    assert ergebnis.ok, f"{ergebnis.step}: {ergebnis.reason}"
    assert ergebnis.address == "https://cdn.example/laeuft#q"
    assert r.count("sources") == 2


def test_next_entry_after_titles_without_sources(manifest, einsetzen):
    """Three empty titles in the first entry, a playable one in the second."""
    from cinelounge.portalworks import nightly

    r = einsetzen(
        Runner(
            menu=[{"id": "a", "name": "A"}, {"id": "b", "name": "B"}],
            listings={"a": _titel("a1", "a2", "a3", "a4"), "b": _titel("b1")},
            sources={"b1": 2},
        )
    )
    ergebnis = nightly.check(manifest)

    assert ergebnis.ok, f"{ergebnis.step}: {ergebnis.reason}"
    # a4 is not tried: three titles per entry.
    assert [c[1] for c in r.calls if c[0] == "sources"] == ["a1", "a2", "a3", "b1"]


def test_all_empty_is_red_with_attempt_count(manifest, einsetzen):
    from cinelounge.portalworks import nightly

    einsetzen(
        Runner(
            menu=[{"id": "a", "name": "A"}],
            listings={"a": _titel("a1", "a2")},
            sources={},
        )
    )
    ergebnis = nightly.check(manifest)

    assert not ergebnis.ok
    assert ergebnis.step == "sources"
    assert ergebnis.reason.startswith("2 titles tried"), ergebnis.reason
    assert "no sources" in ergebnis.reason


def test_attempts_stay_capped(manifest, einsetzen):
    """Four entries of five empty titles each — no more than `MAX_TITLES` asked."""
    from cinelounge.portalworks import nightly

    r = einsetzen(
        Runner(
            menu=[{"id": e, "name": e} for e in "abcde"],
            listings={e: _titel(*(f"{e}{i}" for i in range(5))) for e in "abcde"},
            sources={},
        )
    )
    ergebnis = nightly.check(manifest)

    assert not ergebnis.ok
    assert r.count("sources") == nightly.MAX_TITLES
    assert r.count("listing") <= nightly.TRY_ENTRIES
    assert ergebnis.reason.startswith(f"{nightly.MAX_TITLES} titles tried"), ergebnis.reason


def test_time_budget_stops_further_attempts(manifest, einsetzen):
    """A spent budget asks for nothing more — the reason says why."""
    from cinelounge.portalworks import nightly

    r = einsetzen(
        Runner(
            menu=[{"id": "a", "name": "A"}],
            listings={"a": _titel("a1", "a2", "a3")},
            sources={},
        )
    )
    ergebnis = nightly.check(manifest, budget_s=0.0)

    assert not ergebnis.ok
    assert r.count("listing") == 0
    assert "time budget" in ergebnis.reason, ergebnis.reason


def test_tools_and_own_areas_are_skipped(manifest, einsetzen):
    """A vault and favourites first in the menu, the content after them."""
    from cinelounge.portalworks import nightly

    r = einsetzen(
        Runner(
            menu=[
                {"id": "vault", "name": "Vault", "group": "mine"},
                {"id": "cache", "name": "Clear cache", "group": "tools"},
                {"id": "sites", "name": "Sites", "group": "curated"},
            ],
            listings={"sites": _titel("v1")},
            sources={"v1": 1},
        )
    )
    ergebnis = nightly.check(manifest)

    assert ergebnis.ok, f"{ergebnis.step}: {ergebnis.reason}"
    assert [c[1] for c in r.calls if c[0] == "listing"] == ["sites"]


def test_separators_are_not_titles(manifest, einsetzen):
    from cinelounge.portalworks import nightly

    r = einsetzen(
        Runner(
            menu=[{"id": "a", "name": "A"}],
            listings={
                "a": [
                    {"title": "Meine Bereiche", "address": "", "kind": "separator"},
                    *_titel("v1"),
                ]
            },
            sources={"v1": 1},
        )
    )
    ergebnis = nightly.check(manifest)

    assert ergebnis.ok, f"{ergebnis.step}: {ergebnis.reason}"
    assert [c[1] for c in r.calls if c[0] == "sources"] == ["v1"]


# ── Nightly hooks ────────────────────────────────────────────────────────────


@pytest.fixture()
def haken(monkeypatch):
    """A made-up hook in the register for one test, the register as it was afterwards."""
    from cinelounge.portalworks import extension

    eingesetzt: list = []

    def einsetzen(hook):
        monkeypatch.setattr(extension.NIGHTLY_HOOKS, "_items", [*extension.NIGHTLY_HOOKS._items])
        extension.NIGHTLY_HOOKS._items.append(hook)
        eingesetzt.append(hook)
        return hook

    return einsetzen


def test_a_hook_orders_the_entries(manifest, einsetzen, haken):
    """The hook sees the whole menu and what the core would try — tools left out."""
    from cinelounge.portalworks import nightly
    from cinelounge.portalworks.extension import NightlyHook

    gesehen = {}

    class Rueckwaerts(NightlyHook):
        def order_entries(self, m, menu, entries, limits):
            gesehen["menu"] = [e["id"] for e in menu]
            gesehen["entries"] = [e["id"] for e in entries]
            return list(reversed(entries))

    haken(Rueckwaerts())
    r = einsetzen(
        Runner(
            menu=[
                {"id": "a", "name": "A"},
                {"id": "werkzeug", "name": "W", "group": "tools"},
                {"id": "b", "name": "B"},
            ],
            listings={"a": _titel("va"), "b": _titel("vb")},
            sources={"va": 1, "vb": 1},
        )
    )
    ergebnis = nightly.check(manifest)

    assert ergebnis.ok
    assert gesehen == {"menu": ["a", "werkzeug", "b"], "entries": ["a", "b"]}
    assert [c[1] for c in r.calls if c[0] == "listing"] == ["b"]


def test_a_hook_that_raises_leaves_the_order_alone(manifest, einsetzen, haken):
    from cinelounge.portalworks import nightly
    from cinelounge.portalworks.extension import NightlyHook

    class Kaputt(NightlyHook):
        def order_entries(self, m, menu, entries, limits):
            raise RuntimeError("kaputt")

    haken(Kaputt())
    r = einsetzen(
        Runner(menu=[{"id": "a", "name": "A"}], listings={"a": _titel("v1")}, sources={"v1": 1})
    )
    assert nightly.check(manifest).ok
    assert [c[1] for c in r.calls if c[0] == "listing"] == ["a"]


def test_the_night_watch_tells_the_hooks_what_came_out(manifest, einsetzen, haken, tmp_path):
    """`after` hears every portal checked — carried or not; one that raises is skipped."""
    from cinelounge.household.nights import Nights
    from cinelounge.household.store import Store
    from cinelounge.portalworks.extension import NightlyHook
    from cinelounge.web import nightwatch

    gehoert = []

    class Ohr(NightlyHook):
        def after(self, m, result):
            gehoert.append((m.id, result.ok))

    class Kaputt(NightlyHook):
        def after(self, m, result):
            raise RuntimeError("kaputt")

    haken(Kaputt())
    haken(Ohr())
    einsetzen(
        Runner(menu=[{"id": "a", "name": "A"}], listings={"a": _titel("v1")}, sources={"v1": 1})
    )

    from types import SimpleNamespace

    bestand = SimpleNamespace(manifests={manifest.id: manifest})
    d = nightwatch.run_once(bestand, Nights(Store(tmp_path / "h.sqlite")), gap_s=0)

    assert d["carried"] == [manifest.id]
    assert gehoert == [(manifest.id, True)]
