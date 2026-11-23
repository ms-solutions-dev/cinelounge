"""The buffer cleans up by itself — and survives a `fork`.

**Two findings of 11.09.2026 are in here.**

The first: `sweep()` hung on the write paths alone. Things were cleared up
while somebody was watching, and never again afterwards. The 8 GB limit was
therefore not a promise but an observation — measured, 3.2 GB lay around on the
bridge overnight, and it would only have shown at the next film.

The second, bigger: **the buffer did not run at all.** Nobody called
`set_folder()`, `_ORDNER` stayed `None`, and so `begin()` and `begin_chunked()`
returned `None` immediately. Checked on the data volume — under `/data/cache`
lay only portal caches and not a single `.bin`. Playback ran all the same,
only over a single connection instead of four, and that looks like a slow server.
"""

from __future__ import annotations

import os
import threading
import time

import pytest

from cinelounge.stream import buffer


@pytest.fixture
def puffer(tmp_path, monkeypatch):
    """A folder of its own per test, and the sweeper stops afterwards."""
    monkeypatch.setattr(buffer, "_PUFFER", {})
    buffer.set_folder(tmp_path / "buffer")
    yield tmp_path / "buffer"
    buffer.stop_sweeper()


def _ablegen(ordner, key: str, bytes_: int, *, alter_s: float = 0.0, done: bool = True):
    """Put down a finished buffer as if somebody had written it."""
    pfad = ordner / f"{key}.bin"
    pfad.write_bytes(b"\0" * bytes_)
    item = buffer.Entry(path=pfad, kind="file", length=bytes_)
    item.done = done
    item.written = bytes_
    item.beruehrt = time.time() - alter_s
    buffer._PUFFER[key] = item
    return item


def test_ein_alter_abgebrochener_puffer_wird_weggeraeumt(puffer):
    """Older than `TTL_S` and ended in an error — nobody is waiting for that.

    **A finished one no longer ages** (11.09.2026): it is stock, and that only
    falls at the stock limit. Until then it flew out after an hour too — a
    downloader that throws its result away.
    """
    kaputt = _ablegen(puffer, "alt", 1024, alter_s=buffer.TTL_S + 60)
    kaputt.errors = "ConnectionError: weg"
    _ablegen(puffer, "frisch", 1024)

    buffer.sweep()

    assert "alt" not in buffer._PUFFER
    assert not (puffer / "alt.bin").exists()
    assert "frisch" in buffer._PUFFER, "the cross-check — otherwise it simply clears everything"


def test_ein_fertiger_puffer_bleibt_als_vorrat(puffer):
    """**Throwing the result away was the whole shortcoming of B12.**

    Whoever watched half an episode in the evening and continued the next day
    fetched the host a second time.
    """
    _ablegen(puffer, "gestern", 1024, alter_s=buffer.TTL_S * 24)

    buffer.sweep()

    assert "gestern" in buffer._PUFFER
    assert (puffer / "gestern.bin").exists()


def test_der_vorrat_hat_eine_grenze_und_das_aelteste_faellt(puffer, monkeypatch):
    """Twenty gigabytes are a promise, not a quota.

    On the mini PC a full disk has already been the reason for a total outage
    once — and what falls is what has gone untouched the longest.
    """
    monkeypatch.setattr(buffer, "STOCK_LIMIT_BYTES", 2048)
    _ablegen(puffer, "alt", 1024, alter_s=900)
    _ablegen(puffer, "mittel", 1024, alter_s=600)
    _ablegen(puffer, "neu", 1024, alter_s=1)

    buffer.sweep()

    assert "neu" in buffer._PUFFER
    assert "mittel" in buffer._PUFFER
    assert "alt" not in buffer._PUFFER, "the wrong one fell"


def test_ein_laufender_puffer_bleibt_liegen(puffer):
    """Whoever is writing right now is not taken away from under their hands."""
    _ablegen(puffer, "laeuft", 1024, alter_s=buffer.TTL_S + 60, done=False)

    buffer.sweep()

    assert "laeuft" in buffer._PUFFER
    assert (puffer / "laeuft.bin").exists()


def test_die_grenze_nimmt_den_aeltesten_zuerst(puffer, monkeypatch):
    """Above the limit, what has gone untouched the longest falls.

    The order is the statement: whoever is watching right now should keep their
    buffer, even if too much stands there in total.
    """
    monkeypatch.setattr(buffer, "LIMIT_BYTES", 2500)
    _ablegen(puffer, "aeltest", 1000, alter_s=300)
    _ablegen(puffer, "mittel", 1000, alter_s=200)
    _ablegen(puffer, "juengst", 1000, alter_s=100)

    buffer.sweep()

    assert "juengst" in buffer._PUFFER
    assert "mittel" in buffer._PUFFER
    assert "aeltest" not in buffer._PUFFER


def test_der_aufraeumer_laeuft_von_selbst(puffer, monkeypatch):
    """**The finding itself.** Without a thread nobody cleans up when nobody writes."""
    gelaufen = threading.Event()
    monkeypatch.setattr(buffer, "SWEEP_EVERY_S", 0.02)
    monkeypatch.setattr(buffer, "sweep", gelaufen.set)

    buffer.start_sweeper()

    assert gelaufen.wait(timeout=5.0), "the sweeper never swept"


def test_zweimal_anwerfen_gibt_keinen_zweiten_faden(puffer, monkeypatch):
    """Start can be called repeatedly — otherwise every restart in a test would
    be one more thread running until the process ends."""
    monkeypatch.setattr(buffer, "SWEEP_EVERY_S", 30.0)
    buffer.start_sweeper()
    erster = buffer._UHR
    buffer.start_sweeper()

    assert buffer._UHR is erster


def test_ein_fehler_beim_aufraeumen_beendet_den_faden_nicht(puffer, monkeypatch):
    """A sweeper that dies at the first error is worse than none: it runs
    exactly until something sticks once, and is silent afterwards."""
    rufe = []
    monkeypatch.setattr(buffer, "SWEEP_EVERY_S", 0.02)

    def stolpert():
        rufe.append(1)
        if len(rufe) == 1:
            raise OSError("Platte weg")

    monkeypatch.setattr(buffer, "sweep", stolpert)
    buffer.start_sweeper()

    for _ in range(200):
        if len(rufe) >= 3:
            break
        time.sleep(0.02)
    assert len(rufe) >= 3, f"did not carry on after the error ({len(rufe)} calls)"


@pytest.mark.skipif(not hasattr(os, "register_at_fork"), reason="POSIX-only")
def test_nach_dem_fork_gibt_es_im_kind_keinen_aufraeumer(puffer, monkeypatch):
    """**The trap `_bei_fork_im_kind` stands against.**

    If a process forks while another thread holds `_SPERRE`, the child inherits
    it as *held* — by a holder that does not exist. The first access there
    blocks forever, and it looks like a hanging portal.

    The test calls the hook directly: a real `fork` in the middle of a
    `sweep()` would be a lucky hit, and what holds in the child afterwards is
    the actual promise.
    """
    monkeypatch.setattr(buffer, "SWEEP_EVERY_S", 30.0)
    buffer.start_sweeper()
    _ablegen(puffer, "eins", 1024)

    # This is what it looks like when the fork catches a running `sweep()`.
    buffer._SPERRE.acquire()
    try:
        buffer._bei_fork_im_kind()
    finally:
        pass  # the old lock belongs to the parent; the child has a new one

    assert buffer._UHR is None, "no sweeper may run in the child"
    assert buffer._PUFFER == {}, "the child does not know the buffer"
    assert buffer._SPERRE.acquire(blocking=False), "the lock in the child has to be free"
    buffer._SPERRE.release()
