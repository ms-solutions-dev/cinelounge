"""The announcer must not flood the home network.

**Why this file exists.** On 10.09.2026 the announcer ran for eight minutes
and burned half a processor core doing it. The reason was a single line: it
checked whether its service name occurs in the received packet — and it occurs
in its *own answer*. So it answered itself, again and again.

Measured on the home network: 3.2 MB of packets in five seconds. The mDNS
queues of the Matter server and Home Assistant stood at ~180 KB and fell to
zero within three seconds when the announcer was stopped.

That is the kind of fault no test finds that only asks "does it announce
itself?" — it did, even particularly eagerly. So the tests here do not check
*that* it answers, but **when it does not**.
"""

from __future__ import annotations

import struct

from cinelounge.web.bonjour import Announcer, _name, answer_due

WANTED = _name(["_cinelounge", "_tcp", "local"])
OWN = "192.0.2.183"


def _query(name: str = "_cinelounge._tcp.local") -> bytes:
    """An mDNS question as an Apple TV asks it (QR bit = 0)."""
    head = struct.pack("!6H", 0, 0, 1, 0, 0, 0)
    q = b"".join(bytes([len(t)]) + t.encode() for t in name.split(".") if t) + b"\x00"
    return head + q + struct.pack("!2H", 12, 1)


def test_auf_eine_frage_wird_geantwortet():
    """The normal case — otherwise the fix would only be a shutdown."""
    assert answer_due(_query(), "192.0.2.35", WANTED, OWN) is True


def test_auf_die_eigene_antwort_wird_nicht_geantwortet():
    """**The fault itself.** The announcer's answer, back to it.

    It contains the service name — that was the whole old check. What tells it
    from a question is the QR bit in the second header byte.
    """
    m = Announcer("cinelounge", 8100, OWN)
    eigene = m._antwort()
    assert WANTED in eigene, "otherwise this test checks nothing"
    assert answer_due(eigene, "192.0.2.35", WANTED, OWN) is False


def test_auch_die_antwort_eines_fremden_melders_loest_nichts_aus():
    """Two CineLounge servers on the same network would have wound each other up.

    The sender comparison alone would not have caught that — which is why the
    QR bit is the first question and not the second.
    """
    fremd = Announcer("cinelounge", 8100, "192.0.2.99")._antwort()
    assert answer_due(fremd, "192.0.2.99", WANTED, OWN) is False


def test_eigene_pakete_werden_uebergangen():
    """On the host network an announcer sees its own broadcasts — second bolt."""
    assert answer_due(_query(), OWN, WANTED, OWN) is False


def test_fremde_dienste_gehen_uns_nichts_an():
    """An announcer that answers every packet on the network is a jammer."""
    assert answer_due(_query("_airplay._tcp.local"), "192.0.2.35", WANTED, OWN) is False


def test_ein_abgeschnittenes_paket_wirft_nicht():
    """mDNS is UDP from the home network — whatever arrives, arrives."""
    assert answer_due(b"", "192.0.2.35", WANTED, OWN) is False
    assert answer_due(b"\x00\x00", "192.0.2.35", WANTED, OWN) is False


def test_der_melder_laesst_sich_starten_und_anhalten():
    """The tests were green while the announcer ran in a restart loop.

    **The second fault of the same evening, and the more instructive one.**
    The fix above accidentally put `answer_due` in the middle of the class and
    thereby ended its body — `start` and `stop` became module functions. The
    container no longer started:

        AttributeError: 'Announcer' object has no attribute 'start'

    And pytest was green, because no test ever started the announcer. Exactly
    the same gap as with the workshop pass that checks `/play?source=` and not
    `/play?address=`: a test that does not take the normal path does not guard
    it either.
    """
    m = Announcer("cinelounge-test", 8100, "127.0.0.1")
    m.start()
    try:
        assert m._faden is not None, "start() created no thread"
        m._faden.join(timeout=0.5)
        assert m._faden.is_alive(), "the thread died at startup"
    finally:
        m.stop()
        m._faden.join(timeout=3)
    assert not m._faden.is_alive(), "stop() did not end the thread"
