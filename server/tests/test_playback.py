"""What the playback answer carries — and what it must not lose.

**The occasion, 11.09.2026.** `Stream.subtitles` has stood in the contract
from the start; `INHALTE.md` calls them "the cheapest visible improvement in
the whole project" and, for the family, probably the most useful. The ZDF
portal has filled them since 10.09. and pays one extra HTTP request per
playback for it.

Not one ever arrived. The answer was built field by field, and `subtitles`
was not in the list — no error, no warning, only a field that does not exist
on the other side. It came to light while reading up for R4, not through a
test.

So this file checks both: that the subtitles get through, and that no field of
the contract silently drops out. Then the chain itself: the chosen source
first, the cached list, DRM, the probe, and the steps of `PlaybackPolicy` in
the order they run. Portals and sources are made up.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from cinelounge.portalworks import playback
from cinelounge.portalworks.manifest import Manifest

VIDEO = "https://nrodl.zinne.de/none/zinne/24/12/241209/sendung_1496k_p13v17.mp4"
UNTERTITEL = [{"language": "deu", "format": "vtt", "address": "https://utreg.zinne.de/241209.vtt"}]


def _m(pid: str = "zinne") -> Manifest:
    return Manifest(id=pid, name={"en": pid.title()}, kind="native", folder=Path("."))


@pytest.fixture
def ohne_netz(monkeypatch):
    """Silence buffer, probe and relay — what is checked is the answer."""
    monkeypatch.setattr(playback.buffer, "key_for", lambda *_a: "puffer-1")
    monkeypatch.setattr(playback.buffer, "begin_chunked", lambda *_a, **_k: True)
    monkeypatch.setattr(playback.probe, "probe", lambda *_a, **_k: True)
    monkeypatch.setattr(playback.proxy, "allow", lambda *_a, **_k: None)
    playback._GEMERKT.clear()
    playback._QUELLEN.clear()


def _ausliefern(stream: dict) -> dict:
    fertig = playback.PlaybackPolicy().deliver(_m(), {"id": "q1", "name": "HD"}, stream, [])
    assert fertig is not None, "the build has to run through, otherwise the test checks nothing"
    return fertig


def test_die_untertitel_gehen_mit_hinaus(ohne_netz):
    """The finding itself — before, they fell on the floor here."""
    fertig = _ausliefern(
        {"address": VIDEO, "kind": "file", "resolved": True, "subtitles": UNTERTITEL}
    )
    assert fertig["subtitles"] == UNTERTITEL


def test_ohne_untertitel_steht_eine_leere_liste_da(ohne_netz):
    """Empty means "this portal delivers none", not "not loaded yet".

    So the field always has to stand there: otherwise the app cannot tell
    whether nothing came or nothing is coming.
    """
    fertig = _ausliefern({"address": VIDEO, "kind": "file", "resolved": True})
    assert fertig["subtitles"] == []


def test_die_untertitel_sind_eine_kopie(ohne_netz):
    """The answer is cached (`_merken`) — a shared list would be state a later
    call can still change."""
    quelle = list(UNTERTITEL)
    fertig = _ausliefern({"address": VIDEO, "kind": "file", "resolved": True, "subtitles": quelle})
    quelle.clear()
    assert fertig["subtitles"] == UNTERTITEL


def test_jedes_feld_des_vertrags_kommt_in_der_antwort_an(ohne_netz):
    """**The general form of the finding.**

    `answer` builds its answer field by field. What the contract carries and
    nobody picks up here vanishes silently — exactly how the subtitles got
    lost.

    Three fields are deliberately not included and therefore stand there by
    name: `resolved` is a question to the server and no information for the
    app (whatever arrives here is resolved), `resolution` carries the quality
    level the app already has from `/sources`, and `valid_until` is stamped on
    by `_merken` — the validity hangs on the cache and not on delivering.
    Whoever adds a fourth should have to give a reason.
    """
    from dataclasses import fields

    from cinelounge.core.contract import Stream

    absichtlich_daheim = {"resolved", "resolution", "valid_until"}
    fertig = _ausliefern({"address": VIDEO, "kind": "file", "resolved": True})

    fehlend = sorted(
        f.name for f in fields(Stream) if f.name not in fertig and f.name not in absichtlich_daheim
    )
    assert not fehlend, "in the contract but not in the answer: " + ", ".join(fehlend)


# ── Buffer, relay, probe ─────────────────────────────────────────────────────


def test_eine_datei_geht_in_den_puffer_und_braucht_keine_probe(ohne_netz, monkeypatch):
    monkeypatch.setattr(
        playback.probe, "probe", lambda *_a, **_k: pytest.fail("the buffer is the proof")
    )
    fertig = _ausliefern({"address": VIDEO, "kind": "file", "resolved": True})
    assert fertig["buffer"] == "puffer-1" and fertig["kind"] == "file"


def test_eine_liste_wird_an_der_endung_erkannt_und_geprobt(ohne_netz, monkeypatch):
    """A `.m3u8` without `kind` must not go into the buffer (16.09.2026)."""
    gepuffert: list[str] = []
    monkeypatch.setattr(playback.buffer, "begin_chunked", lambda *a, **_k: gepuffert.append(a[1]))
    fertig = _ausliefern({"address": "https://cdn.example/a/master.m3u8", "resolved": True})
    assert fertig["kind"] == "hls" and fertig["buffer"] is None
    assert not gepuffert


def test_ohne_puffer_entscheidet_die_probe(ohne_netz, monkeypatch):
    monkeypatch.setattr(playback.buffer, "begin_chunked", lambda *_a, **_k: None)
    monkeypatch.setattr(playback.probe, "probe", lambda *_a, **_k: False)
    failed: list[dict] = []
    fertig = playback.PlaybackPolicy().deliver(
        _m(), {"id": "q1", "name": "HD"}, {"address": VIDEO, "resolved": True}, failed
    )
    assert fertig is None
    assert failed == [{"host": "HD", "code": "stream.host_empty"}]


def test_eine_lokale_adresse_braucht_keine_probe(ohne_netz, monkeypatch):
    """An address a registered reader answers has no host to probe."""
    monkeypatch.setattr(playback.proxy, "_SCHEMATA", {"probe-lokal": lambda a: "#EXTM3U\n"})
    monkeypatch.setattr(playback.probe, "probe", lambda *_a, **_k: pytest.fail("nothing to probe"))
    fertig = _ausliefern({"address": "probe-lokal://k/liste.m3u8", "kind": "hls", "resolved": True})
    assert fertig["address"] == "probe-lokal://k/liste.m3u8"


# ── The chosen source and the way back ───────────────────────────────────────


def _mit_quellen(monkeypatch, traegt: set[str]):
    """Three sources; only those named in `traegt` resolve."""
    quellen = [
        {"id": "q-gold", "name": "Gold", "address": "", "language": "de"},
        {"id": "q-kiesel", "name": "kiesel", "address": "", "language": "de"},
        {"id": "q-moos", "name": "moos", "address": "", "language": "en"},
    ]
    monkeypatch.setattr(playback, "sources", lambda *_a, **_k: list(quellen))

    def call(_m, method, arguments=None, *_a, **_k):
        if method != "resolve":
            raise AssertionError(method)
        sid = arguments["source"]
        if sid not in traegt:
            raise playback.f.Error("run.crashed", {"text": "403"})
        return {"address": f"https://cdn.example/{sid}.mp4", "resolved": True, "headers": {}}

    monkeypatch.setattr(playback.runner, "call", call)
    playback._GEMERKT.clear()


def test_gewaehlte_quelle_zuerst_dann_die_uebrigen(ohne_netz, monkeypatch):
    _mit_quellen(monkeypatch, {"q-kiesel", "q-moos"})
    done = playback.resolve_play(_m("lerche"), address="f=titel", source="q-gold")
    assert done["source"] == "q-kiesel"
    assert done["switched"] is True


def test_gewaehlte_quelle_die_traegt_bleibt(ohne_netz, monkeypatch):
    _mit_quellen(monkeypatch, {"q-kiesel", "q-moos"})
    done = playback.resolve_play(_m("lerche"), address="f=titel", source="q-moos")
    assert done["source"] == "q-moos" and done["switched"] is False


def test_quelle_allein_bleibt_genau_diese(ohne_netz, monkeypatch):
    """Without the item's address there is nothing to fall back to — and the
    answer must not pretend otherwise."""
    _mit_quellen(monkeypatch, {"q-kiesel"})
    with pytest.raises(playback.f.Error) as err:
        playback.resolve_play(_m("lerche"), source="q-gold")
    assert err.value.code == "stream.no_host"
    assert [x["host"] for x in err.value.values["failures"]] == ["?"]


def test_die_sprache_wird_erst_gefragt_wenn_die_gewaehlte_quelle_nicht_traegt(
    ohne_netz, monkeypatch
):
    gefragt: list[str] = []

    def sprache() -> str:
        gefragt.append("ja")
        return "en"

    _mit_quellen(monkeypatch, {"q-kiesel", "q-moos"})
    m = _m("lerche")
    playback.resolve_play(m, address="f=titel", source="q-kiesel", language=sprache)
    assert not gefragt
    playback._GEMERKT.clear()
    done = playback.resolve_play(m, address="f=titel", source="q-gold", language=sprache)
    assert gefragt == ["ja"]
    assert done["source"] == "q-moos", "the language puts the English source first"


def test_drm_beendet_die_kette(ohne_netz, monkeypatch):
    """A second source does not help when the provider dictates the scheme."""
    _mit_quellen(monkeypatch, {"q-moos"})
    versucht: list[str] = []

    def call(_m, method, arguments=None, *_a, **_k):
        versucht.append(arguments["source"])
        raise playback.f.Error(playback.f.STREAM_DRM)

    monkeypatch.setattr(playback.runner, "call", call)
    with pytest.raises(playback.f.Error) as err:
        playback.resolve_play(_m("lerche"), address="f=titel")
    assert err.value.code == playback.f.STREAM_DRM
    assert versucht == ["q-gold"]


def test_eine_seite_statt_eines_videos_ist_kein_treffer(ohne_netz, monkeypatch):
    monkeypatch.setattr(playback, "policy_for", lambda m: playback.PlaybackPolicy())

    def call(_m, method, arguments=None, *_a, **_k):
        return {"address": "https://seite.example/titel", "resolved": False}

    monkeypatch.setattr(playback.runner, "call", call)
    with pytest.raises(playback.f.Error) as err:
        playback.resolve_play(_m("lerche"), source="q1")
    assert err.value.values["failures"] == [{"host": "?", "code": "stream.page_not_video"}]


# ── AP63: fewer rounds before the first picture ─────────────────────────────


def _zaehler(monkeypatch) -> dict[str, int]:
    """Counts the calls into the portal; `resolve` carries every source."""
    gezaehlt = {"sources": 0, "resolve": 0}

    def call(_m, method, arguments=None, *_a, **_k):
        gezaehlt[method] += 1
        if method == "sources":
            return [
                {"id": "q-tot", "name": "tot", "address": "", "blocked": True},
                {"id": "q-eins", "name": "Eins", "address": "", "language": "de"},
            ]
        return {"address": f"https://cdn.example/{arguments['source']}.mp4", "resolved": True}

    monkeypatch.setattr(playback.runner, "call", call)
    return gezaehlt


def test_die_quellenliste_wird_nicht_zweimal_geholt(ohne_netz, monkeypatch):
    """`/sources` and then `/play` loaded the same page twice — a second each."""
    gezaehlt = _zaehler(monkeypatch)
    m = _m("lerche")
    playback.sources(m, "f=titel&e=1")
    playback.resolve_play(m, address="f=titel&e=1", source="q-eins")
    assert gezaehlt["sources"] == 1


def test_die_quellenliste_ist_eine_kopie(ohne_netz, monkeypatch):
    _zaehler(monkeypatch)
    m = _m("lerche")
    playback.sources(m, "a")[0]["name"] = "verbogen"
    assert playback.sources(m, "a")[0]["name"] == "tot"


def test_eine_aufgeloeste_quelle_bleibt_gemerkt(ohne_netz, monkeypatch):
    """AVPlayer asks twice; the second ask must not burn a second token."""
    gezaehlt = _zaehler(monkeypatch)
    m = _m("lerche")
    playback.resolve_play(m, source="q-eins")
    assert playback.is_resolved(m, "q-eins")
    again = playback.resolve_play(m, source="q-eins")
    assert again["cached"] is True and gezaehlt["resolve"] == 1


# ── The steps of the policy ──────────────────────────────────────────────────


class _Protokoll(playback.PlaybackPolicy):
    """Records every step; behaves like the base class otherwise."""

    def __init__(self) -> None:
        self.schritte: list[str] = []

    def sources(self, m, address, title, limits):
        self.schritte.append("sources")
        return [{"id": "a", "name": "A"}, {"id": "b", "name": "B"}]

    def after_sources(self, m, address, found, limits):
        self.schritte.append("after_sources")

    def arrange(self, m, found):
        self.schritte.append("arrange")
        return list(reversed(found))

    def prepare(self, m, found, limits):
        self.schritte.append("prepare")

    def before_play(self, m):
        self.schritte.append("before_play")

    def prepared(self, m, source_id):
        self.schritte.append("prepared:" + source_id)
        return None

    def on_failure(self, m, candidate, err):
        self.schritte.append("on_failure:" + candidate["id"])

    def normalize(self, m, stream):
        self.schritte.append("normalize")
        return stream

    def on_outcome(self, m, candidate, ok):
        self.schritte.append(f"on_outcome:{candidate['id']}:{ok}")

    def last_resort(self, m, tried, unresolved, failed):
        self.schritte.append("last_resort:" + ",".join(k["id"] for k in tried))
        return None


def test_die_schritte_der_strategie_in_ihrer_reihenfolge(ohne_netz, monkeypatch):
    politik = _Protokoll()
    monkeypatch.setattr(playback, "policy_for", lambda m: politik)

    def call(_m, method, arguments=None, *_a, **_k):
        if arguments["source"] == "b":
            raise playback.f.Error("run.crashed", {"text": "nein"})
        return {"address": "https://cdn.example/a.mp4", "resolved": True}

    monkeypatch.setattr(playback.runner, "call", call)
    m = _m("lerche")
    gefunden = playback.sources(m, "f=titel")
    playback.prepare(m, gefunden)
    done = playback.resolve_play(m, address="f=titel")

    assert [k["id"] for k in gefunden] == ["b", "a"], "`arrange` sets the order"
    assert done["source"] == "a"
    assert politik.schritte == [
        "sources",
        "after_sources",
        "arrange",
        "prepare",
        "before_play",
        "arrange",
        "prepared:b",
        "on_failure:b",
        "on_outcome:b:False",
        "prepared:a",
        "normalize",
        "on_outcome:a:True",
    ]


def test_der_letzte_weg_kommt_erst_wenn_keine_quelle_traegt(ohne_netz, monkeypatch):
    politik = _Protokoll()

    def zuletzt(m, tried, unresolved, failed):
        politik.schritte.append("last_resort")
        assert [k["id"] for k in tried] == ["b", "a"]
        assert [(k["id"], a) for k, a in unresolved] == [("a", "https://seite.example/a")]
        return politik.deliver(m, {"id": "ersatz"}, {"address": VIDEO, "resolved": True}, failed)

    politik.last_resort = zuletzt
    monkeypatch.setattr(playback, "policy_for", lambda m: politik)

    def call(_m, method, arguments=None, *_a, **_k):
        if arguments["source"] == "b":
            raise playback.f.Error("run.crashed")
        return {"address": "https://seite.example/a", "resolved": False}

    monkeypatch.setattr(playback.runner, "call", call)
    done = playback.resolve_play(_m("lerche"), address="f=titel")
    assert done["fallback"] is True and done["source"] == "ersatz"
    assert playback._gemerkt("lerche|f=titel") is not None, "cached under the address"


def test_eine_strategie_die_ablehnt_beendet_alles(ohne_netz, monkeypatch):
    class Nein(playback.PlaybackPolicy):
        def before_play(self, m):
            raise playback.f.Error("play.refused", status=429)

    monkeypatch.setattr(playback, "policy_for", lambda m: Nein())
    monkeypatch.setattr(playback.runner, "call", lambda *a, **k: pytest.fail("nothing is resolved"))
    with pytest.raises(playback.f.Error) as err:
        playback.resolve_play(_m("lerche"), source="q1")
    assert err.value.code == "play.refused"


def test_ohne_registrierte_strategie_gilt_die_grundform(monkeypatch):
    monkeypatch.setattr(playback.extension, "policy", lambda kind: None)
    assert type(playback.policy_for(_m())) is playback.PlaybackPolicy


def test_die_registrierte_strategie_gilt_fuer_ihre_art(monkeypatch):
    eigene = playback.PlaybackPolicy()
    monkeypatch.setattr(
        playback.extension, "policy", lambda kind: eigene if kind == "native" else None
    )
    assert playback.policy_for(_m()) is eigene


def test_noch_einmal_aufloesen_gibt_die_neue_adresse_und_merkt_sie(ohne_netz, monkeypatch):
    erlaubt: list[tuple] = []
    monkeypatch.setattr(playback.proxy, "allow", lambda *a, **_k: erlaubt.append(a))
    monkeypatch.setattr(
        playback.runner,
        "call",
        lambda *a, **k: {"address": "https://cdn.example/neu.mp4", "resolved": True},
    )
    m = _m("lerche")
    assert playback.resolve_again(m, "q1") == "https://cdn.example/neu.mp4"
    assert erlaubt[0][0] == "https://cdn.example/neu.mp4"
    assert playback.is_resolved(m, "q1")
