"""A block that is still loading already serves its beginning (AP63, 01.10.2026).

The app's container probe asks for 4 KB and waited 2.8 s — until the whole first
megabyte had arrived. The bytes were on disk after a fraction of that.
"""

from __future__ import annotations

from pathlib import Path

from cinelounge.stream import buffer


def _eintrag() -> buffer.Entry:
    e = buffer.Entry(path=Path("/nirgends.bin"), kind="video/mp4", length=3 * buffer.BLOCK_BYTES)
    e.in_bloecken = True
    return e


def test_ein_angefangener_block_liefert_seinen_anfang() -> None:
    e = _eintrag()
    assert e.available_until(0) is None
    e.block_progress(0, 4096)
    assert e.available_until(0) == 4096
    assert e.available_until(4096) is None


def test_die_kante_geht_nur_vorwaerts() -> None:
    e = _eintrag()
    e.block_progress(0, 8192)
    e.block_progress(0, 4096)
    assert e.available_until(0) == 8192


def test_ein_fertiger_block_reicht_in_den_angefangenen_hinein() -> None:
    e = _eintrag()
    e.block_done(0)
    assert e.available_until(0) == buffer.BLOCK_BYTES
    e.block_progress(1, 500)
    assert e.available_until(0) == buffer.BLOCK_BYTES + 500
    e.block_done(1)
    assert e.available_until(0) == 2 * buffer.BLOCK_BYTES


def test_der_leser_wartet_nur_bis_zu_seinem_byte() -> None:
    e = _eintrag()
    e.block_progress(0, 4096)
    assert e.warten_auf(0) is True
