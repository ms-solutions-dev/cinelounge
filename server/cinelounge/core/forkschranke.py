"""The fork barrier: nobody forks while another thread is inside SQLite.

**The deadlock behind the timeout chains** (AP74, 11.10.2026, evening). The
runner forks a child for every portal call; FastAPI's thread pool meanwhile
reports progress and devices into `household.sqlite`. SQLite protects its
allocator and its lock table with process-wide mutexes. A fork that lands while
another thread holds one of them copies the mutex *locked* into the child —
where no thread will ever release it. The child's first `sqlite3.connect`
(the TMDB cache) then waits for good, and the parent kills it at the deadline:
`offen: sqlite tmdb.sqlite seit 20.4 s`, no name lookup before it. Measured in
the container: 0 of 150 children hung without SQLite threads in the parent,
62 of 150 with them. It struck in clusters at app start, when both sides are
busiest — 14 times during one device test.

**The rule is a readers-writer lock.** SQLite users are the readers: as many as
you like at once, each for a few milliseconds. A fork is the writer: it waits
until nobody is inside, then nothing new enters until the fork has happened.
Whoever forks while inside SQLite themselves is not waited for — a thread cannot
hold a SQLite mutex and call `fork()` at the same time, so its own connection is
harmless. The child resets its copy, which was taken mid-fork.
"""

from __future__ import annotations

import threading
from collections.abc import Iterator
from contextlib import contextmanager


class Forkschranke:
    def __init__(self) -> None:
        self._frisch()

    def _frisch(self) -> None:
        self._bedingung = threading.Condition()
        self._drinnen = 0
        self._forkt = False
        self._wartende_forks = 0
        self._eigene = threading.local()

    def _eigene_tiefe(self) -> int:
        return int(getattr(self._eigene, "tiefe", 0))

    @contextmanager
    def sqlite(self) -> Iterator[None]:
        """Around every SQLite use in the parent — `Store.connect()` does it."""
        with self._bedingung:
            # A thread already inside may go deeper: a fork cannot be waiting on
            # it, and waiting for the fork would wait for itself.
            if self._eigene_tiefe() == 0:
                while self._forkt or self._wartende_forks:
                    self._bedingung.wait()
            self._drinnen += 1
            self._eigene.tiefe = self._eigene_tiefe() + 1
        try:
            yield
        finally:
            with self._bedingung:
                self._drinnen -= 1
                self._eigene.tiefe = self._eigene_tiefe() - 1
                if self._drinnen == 0:
                    self._bedingung.notify_all()

    @contextmanager
    def fork(self) -> Iterator[None]:
        """Around `os.fork()` — the runner does it."""
        with self._bedingung:
            self._wartende_forks += 1
            try:
                while self._forkt or self._drinnen - self._eigene_tiefe() > 0:
                    self._bedingung.wait()
            finally:
                self._wartende_forks -= 1
            self._forkt = True
        try:
            yield
        finally:
            with self._bedingung:
                self._forkt = False
                self._bedingung.notify_all()

    def im_kind_zuruecksetzen(self) -> None:
        """The child inherits a barrier taken mid-fork; it starts over."""
        self._frisch()

    def frei(self) -> bool:
        with self._bedingung:
            return not self._forkt and self._drinnen == 0 and self._wartende_forks == 0


SCHRANKE = Forkschranke()
