"""A source id must not carry a newline.

**Why this is a test of its own.** The ZDF id is made of two parts — the
template for the subtitles and the video address — and the first attempt
separated them with `\\n`. Inside this portal that is watertight: the newline
occurs in neither address and survives URL encoding. Both true, and neither is
the place where it goes wrong.

It goes wrong where the id is *passed on*. The server hands it to the app, the
app hands it back, and along the way it stands in headers and log lines. An id
with a newline turns one log line into two and looks like two values in an
error message. With A2 the app builds on it — after that it is a change across
two repos.

So the test pins down two things: what goes out today carries no whitespace.
And what went out yesterday is still understood.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

WURZEL = Path(__file__).resolve().parent.parent


def _portal_modul():
    """`portals/zdf/portal.py` lies outside the package — as with the runner."""
    file = WURZEL / "portals" / "zdf" / "portal.py"
    spec = importlib.util.spec_from_file_location("zdf_portal_test", file)
    assert spec and spec.loader
    modul = importlib.util.module_from_spec(spec)
    sys.modules["zdf_portal_test"] = modul
    spec.loader.exec_module(modul)
    return modul


VORLAGE = "/tmd/2/android_native_5/vod/ptmd/mediathek/241209_sendung_abc"
VIDEO = "https://nrodl.zdf.de/none/zdf/24/12/241209_sendung/1/sendung_1496k_p13v17.mp4"

# This is how the stream lookup answers — trimmed to one format and one quality.
PTMD = {
    "priorityList": [
        {
            "formitaeten": [
                {
                    "type": "h264_aac_mp4_http_na_na",
                    "qualities": [{"quality": "hd", "audio": {"tracks": [{"uri": VIDEO}]}}],
                }
            ]
        }
    ],
    "captions": [
        {"format": "webvtt", "uri": "https://utreg.zdf.de/241209.vtt", "language": "deu"},
        {"format": "ebu-tt-d-basic-de", "uri": "https://utreg.zdf.de/241209.xml"},
    ],
}


@pytest.fixture
def zdf(monkeypatch):
    """The portal without the network: fixed keys, one fixed answer."""
    modul = _portal_modul()
    gerufen: list[str] = []

    def _hol(path: str, token: str):
        gerufen.append(path)
        return PTMD

    monkeypatch.setattr(modul, "_hol", _hol)
    monkeypatch.setattr(modul._MARKEN, "_bis", float("inf"))
    monkeypatch.setattr(modul._MARKEN, "_app", "app-marke")
    monkeypatch.setattr(modul._MARKEN, "_video", "video-marke")
    return modul, gerufen


def test_die_kennung_traegt_keinen_whitespace(zdf):
    """The actual finding — and it holds for every character, not only `\\n`.

    **This test knocked the second attempt straight over again.** `\\x1f` is
    the separator meant for exactly this — but Python counts `\\x1c`–`\\x1f`
    as `str.isspace()`. A `.strip()` somewhere along the way would have halved
    the id without anybody seeing it: the same fault, only quieter. So the test
    checks both — no whitespace, and `.strip()` changes nothing.
    """
    modul, _ = zdf
    item = modul.Item(title="Sendung", address=VORLAGE, kind="episode")

    quellen = modul.Portal().sources(item)
    assert quellen, "without a source the test checks nothing"
    for q in quellen:
        gefunden = [c for c in q.id if c.isspace()]
        assert not gefunden, "id contains whitespace: " + repr(q.id)
        assert q.id.strip() == q.id, "strip() must not change the id"


def test_der_rundlauf_findet_beide_haelften_wieder(zdf):
    """The new separator has to be able to split the id again, too.

    Checked cross-check: without the template `subtitles` would stay empty — so
    the test would be green without it as well if it only checked the address.
    """
    modul, gerufen = zdf
    item = modul.Item(title="Sendung", address=VORLAGE, kind="episode")

    quelle = modul.Portal().sources(item)[0]
    gerufen.clear()
    strom = modul.Portal().resolve(quelle)

    assert strom.address == VIDEO
    assert gerufen == [VORLAGE], "the template has to arrive intact at the request"
    # WebVTT only — AVPlayer does not open EBU-TT-D.
    assert strom.subtitles == [
        {
            "language": "deu",
            "format": "vtt",
            "address": "https://utreg.zdf.de/241209.vtt",
        }
    ]


def test_eine_kennung_von_gestern_wird_noch_verstanden(zdf):
    """Ids are transient, but not gone in an instant.

    `progress.key` comes from `core.ids.key(portal, title, year)` and not from
    here — so nothing remembered hangs on the id. An app that survives the
    restart with an old id in hand should not grasp at nothing all the same.
    """
    modul, gerufen = zdf
    alt = modul.Source(id=VORLAGE + "\n" + VIDEO, name="HD", address=VIDEO)

    strom = modul.Portal().resolve(alt)

    assert strom.address == VIDEO
    assert gerufen == [VORLAGE]
    assert strom.subtitles, "the old id must still reach the subtitles, too"


def test_eine_kennung_ohne_trenner_bleibt_die_adresse(zdf):
    """The fallback from the old catalogue: id == address, no template."""
    modul, gerufen = zdf
    strom = modul.Portal().resolve(modul.Source(id=VIDEO, name="HD", address=VIDEO))

    assert strom.address == VIDEO
    assert gerufen == [], "without a template no request may happen"
    assert strom.subtitles == []
