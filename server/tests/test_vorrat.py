"""The stock survives a restart — or it is no stock.

**`begin_chunked()` has been a downloader since 03.09.2026**: four workers, one
megabyte per block, the whole file onto the disk. The result was thrown away
all the same — after an hour by the sweeper, and at the latest at the next
restart by `drop_orphans()`, which deleted the whole folder. `deploy.sh`
restarts the service on every change.

Decision of 11.09.2026: **what finished loading stays** — up to the stock
limit, and then what has gone untouched the longest falls.

Checked here is the part that works without the network: adopting at startup.
What counts there is the **length** — half a film in the stock would be worse
than none, because the player would get it and stop in the middle.
"""

from __future__ import annotations

import json

import pytest

from cinelounge.stream import buffer


@pytest.fixture()
def ordner(tmp_path):
    buffer._PUFFER.clear()
    buffer.set_folder(tmp_path / "buffer")
    yield tmp_path / "buffer"
    buffer._PUFFER.clear()


def _hinlegen(ordner, key: str, inhalt: bytes, *, schein: dict | None = None):
    """A file as an earlier run would have left it."""
    ordner.mkdir(parents=True, exist_ok=True)
    (ordner / f"{key}.bin").write_bytes(inhalt)
    if schein is not None:
        (ordner / f"{key}.json").write_text(json.dumps(schein), encoding="utf-8")


# ── What gets adopted ───────────────────────────────────────────────────────


def test_eine_vollstaendige_datei_wird_uebernommen(ordner):
    _hinlegen(
        ordner,
        "abc",
        b"\0" * 500,
        schein={"key": "abc", "kind": "video/mp4", "length": 500, "touched": 1_700_000_000},
    )

    assert buffer.adopt_orphans() == 1
    assert buffer.has("abc")

    item = buffer._PUFFER["abc"]
    assert item.done and item.length == 500
    assert item.kind == "video/mp4", "the kind stands in the docket — on disk it cannot be seen"
    assert item.beruehrt == 1_700_000_000, "otherwise everything is equally old after a restart"


def test_der_vorrat_ist_danach_lesbar(ordner):
    """The real test: does reading give back what was written in?"""
    _hinlegen(
        ordner,
        "abc",
        bytes(range(256)),
        schein={"key": "abc", "kind": "video/mp4", "length": 256},
    )
    buffer.adopt_orphans()

    antwort = buffer.read_range("abc", None)
    assert antwort is not None
    progress, _headers, stuecke = antwort
    assert progress == 200
    assert b"".join(stuecke) == bytes(range(256))


# ── And what does not ───────────────────────────────────────────────────────


def test_eine_halbe_datei_fliegt_raus(ordner):
    """**Half a film in the stock is worse than none.**

    The player would get it, start playing and stop in the middle — and nobody
    would know whether the host is to blame or we are.
    """
    _hinlegen(
        ordner,
        "halb",
        b"\0" * 120,
        schein={"key": "halb", "kind": "video/mp4", "length": 500},
    )

    assert buffer.adopt_orphans() == 0
    assert not (ordner / "halb.bin").exists()
    assert not (ordner / "halb.json").exists()


def test_eine_datei_ohne_schein_fliegt_raus(ordner):
    """An aborted run from earlier: whether it is complete, nobody knows."""
    _hinlegen(ordner, "waise", b"\0" * 500)

    assert buffer.adopt_orphans() == 0
    assert not (ordner / "waise.bin").exists()


def test_ein_schein_ohne_datei_fliegt_raus(ordner):
    ordner.mkdir(parents=True, exist_ok=True)
    (ordner / "leer.json").write_text(json.dumps({"length": 10, "kind": "x"}), encoding="utf-8")

    assert buffer.adopt_orphans() == 0
    assert not (ordner / "leer.json").exists()


def test_ein_kaputter_schein_nimmt_den_dienst_nicht_mit(ordner):
    """At startup every raise is a service that does not come up."""
    _hinlegen(ordner, "kaputt", b"\0" * 10)
    (ordner / "kaputt.json").write_text("{kein json", encoding="utf-8")

    assert buffer.adopt_orphans() == 0
    assert not (ordner / "kaputt.bin").exists()


# ── The status strip ────────────────────────────────────────────────────────


def test_status_nennt_den_vorrat_getrennt(ordner):
    """It is something other than a buffer: it does not wait, it lies ready."""
    _hinlegen(
        ordner,
        "abc",
        b"\0" * 500,
        schein={"key": "abc", "kind": "video/mp4", "length": 500},
    )
    buffer.adopt_orphans()

    d = buffer.status()
    assert d["stock"] == 1
    assert d["stock_bytes"] == 500
    assert d["stock_limit_bytes"] == buffer.STOCK_LIMIT_BYTES
