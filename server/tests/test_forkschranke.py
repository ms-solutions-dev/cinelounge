"""Nobody forks while a thread is inside SQLite (AP74, 11.10.2026)."""

from __future__ import annotations

import sqlite3
import threading
import time

from cinelounge.core.forkschranke import SCHRANKE, Forkschranke
from cinelounge.household.store import Store
from cinelounge.portalworks.runner import fork


def _laeuft(ziel, *args) -> threading.Thread:
    t = threading.Thread(target=ziel, args=args, daemon=True)
    t.start()
    return t


def test_fork_wartet_bis_niemand_mehr_in_sqlite_ist():
    s = Forkschranke()
    drin = threading.Event()

    def nutzer():
        with s.sqlite():
            drin.set()
            time.sleep(0.3)

    _laeuft(nutzer)
    assert drin.wait(1)
    start = time.monotonic()
    with s.fork():
        gewartet = time.monotonic() - start
    assert gewartet >= 0.25, f"nur {gewartet:.2f} s gewartet"
    assert s.frei()


def test_waehrend_eines_forks_kommt_niemand_in_sqlite():
    s = Forkschranke()
    angekommen: list[float] = []

    def nutzer():
        with s.sqlite():
            angekommen.append(time.monotonic())

    with s.fork():
        t = _laeuft(nutzer)
        time.sleep(0.2)
        assert not angekommen
        ende = time.monotonic()
    t.join(1)
    assert angekommen and angekommen[0] >= ende


def test_wer_selbst_in_sqlite_ist_darf_forken():
    s = Forkschranke()
    fertig = threading.Event()

    def eigener():
        with s.sqlite(), s.fork():
            fertig.set()

    _laeuft(eigener)
    assert fertig.wait(1), "eigene SQLite-Nutzung blockierte den Fork"
    assert s.frei()


def test_store_connect_steht_hinter_der_schranke(tmp_path):
    store = Store(tmp_path / "h.sqlite")
    durch = threading.Event()

    def forker():
        with SCHRANKE.fork():
            durch.set()

    with store.connect() as v:
        v.execute("SELECT 1")
        t = _laeuft(forker)
        assert not durch.wait(0.2), "der Fork lief, obwohl eine Verbindung offen war"
    t.join(1)
    assert durch.is_set()


def test_das_kind_beginnt_mit_freier_schranke():
    assert fork.run(SCHRANKE.frei) is True
    assert SCHRANKE.frei()


def test_forks_neben_sqlite_threads_haengen_nicht(tmp_path):
    """The reproduction from the container: 62 of 150 children hung in
    `sqlite3.connect` beside four threads hammering SQLite — none with the
    barrier in place."""
    eltern = tmp_path / "eltern.sqlite"
    kind = tmp_path / "kind.sqlite"
    for p in (eltern, kind):
        db = sqlite3.connect(p)
        db.execute("CREATE TABLE t (k, v)")
        db.commit()
        db.close()
    stop = threading.Event()

    def hammer():
        i = 0
        while not stop.is_set():
            with SCHRANKE.sqlite():
                db = sqlite3.connect(eltern, timeout=0.5)
                try:
                    db.execute("INSERT OR REPLACE INTO t VALUES (?, ?)", (i % 50, "x" * 200))
                    db.commit()
                except sqlite3.Error:
                    pass
                db.close()
            i += 1

    def im_kind() -> int:
        db = sqlite3.connect(kind, timeout=0.5)
        try:
            return int(db.execute("SELECT count(*) FROM t").fetchone()[0])
        finally:
            db.close()

    faeden = [_laeuft(hammer) for _ in range(4)]
    try:
        start = time.monotonic()
        for _ in range(40):
            assert fork.run(im_kind) == 0
        dauer = time.monotonic() - start
    finally:
        stop.set()
        for t in faeden:
            t.join(2)
    assert dauer < 15, f"{dauer:.1f} s für 40 Forks"
