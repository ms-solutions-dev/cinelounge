"""The child's memory limit is a headroom, not a ceiling below the floor.

**12.10.2026, in the container log:** `Exception ignored in thread started by:
<object repr() failed>` / `MemoryError:` — three times a minute, every
`resolve` of one portal ending as `run.timeout`. Reproduced in the container:
with 2.2 GB inherited and `RLIMIT_AS` at 256 MB the child could neither start a
thread nor allocate 20 MB. These three tests hold the fix in place.
"""

from __future__ import annotations

import threading

import pytest

from cinelounge.core import errors as f
from cinelounge.portalworks.runner import fork

pytestmark = pytest.mark.skipif(not fork.available(), reason="needs fork and resource")

MB = 1024 * 1024


def _thread_im_kind() -> list[int]:
    out: list[int] = []
    t = threading.Thread(target=lambda: out.append(1))
    t.start()
    t.join()
    return out


def _zwanzig_mb() -> int:
    return len(bytearray(20 * MB))


def _vierhundert_mb() -> int:
    return len(bytearray(400 * MB))


def test_das_kind_kann_einen_thread_starten() -> None:
    """Portal code may work with threads — without this, such a portal never resolves."""
    assert fork.run(_thread_im_kind) == [1]


def test_zwanzig_megabyte_liegen_im_spielraum() -> None:
    assert fork.run(_zwanzig_mb) == 20 * MB


def test_ueber_dem_spielraum_heisst_out_of_memory() -> None:
    """The limit still bites — as a headroom above the inherited size."""
    with pytest.raises(f.Error) as err:
        fork.run(_vierhundert_mb, fork.Limits(memory_mb=64))
    assert err.value.code == f.RUN_OUT_OF_MEMORY
