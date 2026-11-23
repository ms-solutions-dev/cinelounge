"""The marketplace — sources, index and who the household believes.

**There is no official index, and that is the heart of it.** Whoever enters a
source decides for themselves who they believe. The service keeps no directory
of foreign content; it fetches what it is told, checks the shape and says
honestly what it checked and what not.

The three levels are the actual subject of this file: `signed`, `unsigned` and
`bad` — and that the last two are **not** the same.
"""

from __future__ import annotations

import base64
import json

import pytest

from cinelounge.core import errors as f
from cinelounge.household.store import Store
from cinelounge.market import index
from cinelounge.market.sources import Sources
from cinelounge.market.trust import BAD, SIGNED, UNSIGNED, Trust, fingerprint_of, signing_payload

SHA = "a" * 64


def _eintrag(**dazu):
    e = {
        "id": "zinne",
        "version": "1.0.0",
        "url": "https://example.test/zinne.tar.gz",
        "sha256": SHA,
    }
    e.update(dazu)
    return e


def _index(*eintraege, api=1, **dazu):
    d = {"api": api, "name": "Testquelle", "portals": list(eintraege)}
    d.update(dazu)
    return json.dumps(d)


@pytest.fixture
def store(tmp_path):
    return Store(tmp_path / "h.sqlite")


# ── The index ───────────────────────────────────────────────────────────────


def test_ein_gueltiger_index_wird_gelesen():
    """The cross-check first — otherwise the rest only checks that everything aborts."""
    d, klagen = index.read(_index(_eintrag()))

    assert not klagen
    assert d["name"] == "Testquelle"
    (e,) = d["portals"]
    assert e["id"] == "zinne"
    assert e["sha256"] == SHA
    assert e["name"] == {"en": "zinne"}, "without a name the entry carries its id"


def test_ein_kaputter_eintrag_nimmt_die_anderen_nicht_mit():
    """**The difference to the manifest.** There one folder is one portal; here
    dozens stand in one file, and whoever stops at the third line loses the
    others."""
    d, klagen = index.read(_index(_eintrag(), {"id": "kaputt"}, _eintrag(id="ahorn")))

    assert [e["id"] for e in d["portals"]] == ["zinne", "ahorn"]
    assert len(klagen) == 1
    assert "missing" in klagen[0]


def test_eine_fremde_fassung_wird_abgelehnt():
    d, klagen = index.read(_index(_eintrag(), api=99))

    assert d["portals"] == []
    assert "api 99 not supported" in klagen[0]


def test_unbekannte_schluessel_brechen_ab():
    """The same rule as with the manifest: a typo is meant to show."""
    _d, klagen = index.read('{"api": 1, "portale": []}')

    assert "unknown keys: portale" in klagen[0]


def test_eine_kennung_mit_pfad_ist_kein_portal():
    """**The id becomes a folder name.** An entry called `../../etc` is not a
    portal but an attempt."""
    _, klagen = index.read(_index(_eintrag(id="../../etc")))

    assert "not a plain name" in klagen[0]


def test_eine_pruefsumme_die_keine_ist():
    _, klagen = index.read(_index(_eintrag(sha256="kurz")))
    assert "sha256 is not a sha256" in klagen[0]


def test_eine_adresse_ins_dateisystem_wird_abgelehnt():
    """`file:` would be a way to "install" arbitrary files."""
    _, klagen = index.read(_index(_eintrag(url="file:///etc/passwd")))
    assert "neither https nor http" in klagen[0]


def test_dieselbe_kennung_zweimal():
    _, klagen = index.read(_index(_eintrag(), _eintrag()))
    assert "listed twice: zinne" in klagen[0]


def test_ein_unlesbarer_index_wirft_nicht():
    """A broken source must not take the others with it."""
    d, klagen = index.read("kein json")
    assert d["portals"] == []
    assert "unreadable" in klagen[0]


# ── Trust ───────────────────────────────────────────────────────────────────


@pytest.fixture
def schluessel():
    from nacl.signing import SigningKey

    sk = SigningKey.generate()
    return sk, base64.b64encode(bytes(sk.verify_key)).decode()


def test_eine_signatur_gegen_einen_hinterlegten_anker(store, schluessel):
    sk, pub = schluessel
    t = Trust(store)
    anker = t.add(pub, "Max")

    e = _eintrag()
    e["signature"] = base64.b64encode(sk.sign(signing_payload(e)).signature).decode()

    stufe, abdruck = t.check(e)
    assert stufe == SIGNED
    assert abdruck == anker.fingerprint == fingerprint_of(pub)


def test_ohne_signatur_ist_nicht_dasselbe_wie_mit_falscher(store, schluessel):
    """**The most expensive mistake would be treating both alike.**

    A portal without a signature is one nobody vouched for. A portal with a
    wrong signature is one where somebody tried and it does not add up — that
    is an attack or a fault, and both deserve to be seen.
    """
    sk, pub = schluessel
    t = Trust(store)
    t.add(pub)

    ohne = _eintrag()
    assert t.check(ohne) == (UNSIGNED, "")

    falsch = _eintrag()
    falsch["signature"] = base64.b64encode(sk.sign(signing_payload(falsch)).signature).decode()
    falsch["sha256"] = "b" * 64  # the file swapped
    assert t.check(falsch)[0] == BAD


def test_eine_signatur_ohne_passenden_anker_ist_bad(store, schluessel):
    """Not `unsigned`: there *is* a signature, it just does not verify."""
    sk, _ = schluessel
    t = Trust(store)  # no anchor stored

    e = _eintrag()
    e["signature"] = base64.b64encode(sk.sign(signing_payload(e)).signature).decode()
    assert t.check(e)[0] == BAD


def test_die_signatur_deckt_kennung_fassung_und_pruefsumme(store, schluessel):
    """The rest of the entry is information and not a promise.

    Whoever changes the description does not break the signature — whoever
    swaps the version or the file does.
    """
    sk, pub = schluessel
    t = Trust(store)
    t.add(pub)

    e = _eintrag()
    e["signature"] = base64.b64encode(sk.sign(signing_payload(e)).signature).decode()

    e["name"] = {"de": "Ganz anderer Name"}
    e["capabilities"] = ["search"]
    assert t.check(e)[0] == SIGNED, "advertising may change"

    e["version"] = "9.9.9"
    assert t.check(e)[0] == BAD, "the version may not"


def test_ein_anker_zweimal_ist_derselbe(store, schluessel):
    """Whoever enters an anchor again does not mean "one more"."""
    _, pub = schluessel
    t = Trust(store)
    t.add(pub, "erst so")
    t.add(pub, "dann so")

    (a,) = t.list_all()
    assert a.name == "dann so"


def test_ein_schluessel_der_keiner_ist_wird_abgelehnt(store):
    t = Trust(store)
    with pytest.raises(f.Error) as err:
        t.add("kein schluessel")
    assert err.value.code == "trust.bad_key"


def test_kaputte_signatur_stuerzt_nicht(store, schluessel):
    """Base64 that is none is `bad` and not an exception."""
    _, pub = schluessel
    t = Trust(store)
    t.add(pub)
    assert t.check(_eintrag(signature="!!! kein base64 !!!"))[0] == BAD


# ── Sources ─────────────────────────────────────────────────────────────────


def test_eine_quelle_eintragen_und_wieder_weg(store):
    q = Sources(store)
    q.add("https://example.test/index.json", "Maxs Portale")

    (s,) = q.list_all()
    assert s.url == "https://example.test/index.json"
    assert s.name == "Maxs Portale"
    assert s.stale_s is None, "never fetched yet"

    assert q.remove(s.url)
    assert q.list_all() == []


def test_eine_adresse_die_keine_ist(store):
    with pytest.raises(f.Error) as err:
        Sources(store).add("nicht mal eine URL")
    assert err.value.code == "market.bad_url"


def test_der_zwischenspeicher_haelt_die_liste_wenn_die_quelle_schweigt(store, monkeypatch):
    """**The heart of the cache.**

    A source that is not answering right now must not empty the marketplace.
    Otherwise a network outage looks like a withdrawn portal — and whoever has
    seen that twice stops trusting the list.
    """
    import cinelounge.market.sources as modul

    q = Sources(store)
    q.add("https://example.test/index.json")

    class Antwort:
        class raw:  # mirrors `requests`
            @staticmethod
            def read(n, decode_content=True):
                return _index(_eintrag()).encode()

        @staticmethod
        def raise_for_status():
            return None

    monkeypatch.setattr(modul.requests, "get", lambda *a, **k: Antwort())
    d, klagen = q.fetch("https://example.test/index.json")
    assert [e["id"] for e in d["portals"]] == ["zinne"]
    assert not klagen

    # And now it goes silent.
    def schweigt(*a, **k):
        raise OSError("Name or service not known")

    monkeypatch.setattr(modul.requests, "get", schweigt)
    d, klagen = q.fetch("https://example.test/index.json")

    assert [e["id"] for e in d["portals"]] == ["zinne"], "out of the cache"
    assert klagen and "Name or service not known" in klagen[0], "and the reason stands beside it"
    assert q.list_all()[0].stale_s is not None, "the age is known"


def test_ohne_zwischenspeicher_bleibt_nur_der_grund(store, monkeypatch):
    """An empty cache and a stale one are two different things."""
    import cinelounge.market.sources as modul

    q = Sources(store)
    q.add("https://example.test/index.json")

    def schweigt(*a, **k):
        raise OSError("weg")

    monkeypatch.setattr(modul.requests, "get", schweigt)
    d, klagen = q.fetch("https://example.test/index.json")

    assert d["portals"] == []
    assert klagen == ["OSError: weg"]


def test_jeder_eintrag_weiss_aus_welcher_quelle_er_kommt(store, monkeypatch):
    """With two sources offering the same portal that is the only question the
    marketplace has to answer."""
    import cinelounge.market.sources as modul

    q = Sources(store)
    q.add("https://a.test/i.json", "A")
    q.add("https://b.test/i.json", "B")

    class Antwort:
        class raw:
            @staticmethod
            def read(n, decode_content=True):
                return _index(_eintrag()).encode()

        @staticmethod
        def raise_for_status():
            return None

    monkeypatch.setattr(modul.requests, "get", lambda *a, **k: Antwort())
    alles, klagen = q.fetch_all()

    assert not klagen
    assert sorted(e["source_name"] for e in alles) == ["A", "B"]
