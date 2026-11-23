"""The fork runner — the one boundary foreign code runs behind.

**Why it exists.** Loading third-party Python code into the same process as
the API and tidying up `sys.modules` afterwards works for a handful of portals
you vetted yourself. For a marketplace it means: *running foreign code is the
feature.* An in-process loader pays for that with crashes that take the API
along and a permanent fight over common top-level package names.

**Why it is cheap.** A portal call is stateless like a CGI program — it gets
its arguments, returns a list and ends. Exactly that property makes process
isolation affordable.

**The trick is `fork()` after preloading.** Whatever all portals share —
``requests``, the standard library, whatever an installed extension lists in
its preload — is imported once at startup. Every child inherits it
copy-on-write for practically nothing. And it has its **own `sys.modules`**:
no clean-up gymnastics, no namespace-package trap.

Three problems, one move:

* crash = dead child, not a dead container
* memory leak = handed back when the child dies
* name collision between two portals' packages = structurally impossible

**POSIX only.** ``os.fork`` does not exist on Windows; that is where
development happens, not operation. ``available()`` says so instead of failing
on import.
"""

from __future__ import annotations

import json
import os
import pickle
import signal
import sys
import time

# `resource` and `fork` do not exist on Windows. That is where development
# happens, not operation — but the service has to stay startable, otherwise not
# even the self-description can be checked. `available()` says so instead of
# failing on import.
try:
    import resource
except ImportError:  # pragma: no cover — Windows only
    resource = None  # type: ignore[assignment]
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Final

from cinelounge.core import errors as f
from cinelounge.core.forkschranke import SCHRANKE

# What a single run may consume at most. All of it is a household setting and
# stands here only as the default.
MEMORY_MB: Final = 256
CPU_S: Final = 25
DEADLINE_S: Final = 20.0

# How many bytes the child may hand back at most. A level with 277 entries is
# a few hundred kilobytes; a megabyte is generous and keeps a portal from
# filling the parent process with an endless list.
ANSWER_MAX: Final = 1024 * 1024


def available() -> bool:
    """Whether this machine knows fork and resource limits. On Windows: no."""
    return hasattr(os, "fork") and resource is not None


@dataclass(frozen=True, slots=True)
class Limits:
    memory_mb: int = MEMORY_MB
    cpu_s: int = CPU_S
    deadline_s: float = DEADLINE_S


def _adressraum_jetzt() -> int:
    """The process's virtual size right now, in bytes — what `RLIMIT_AS` counts.

    **Measured on 12.10.2026:** the service process stands at 2.2 GB of virtual
    memory (glibc reserves an arena per thread, and AP74 brought threads), and the
    child inherits every byte of it. A ceiling of 256 MB *in total* was therefore
    below the floor from the first instruction: no thread could start (`can't
    start new thread`), a 20 MB allocation raised `MemoryError`, and any portal
    code that works with threads failed on every call as `run.timeout`.
    Only small allocations inside arenas the parent had already mapped went
    through, which is why listings mostly survived and resolves did not. The
    limit is a headroom above what is inherited, not an absolute figure.

    `/proc/self/statm` is Linux; without it (no `/proc`) the headroom counts
    from zero, as before.
    """
    try:
        with open("/proc/self/statm", encoding="ascii") as f:
            pages = int(f.read().split()[0])
        return pages * os.sysconf("SC_PAGE_SIZE")
    except (OSError, ValueError, IndexError):
        return 0


def _grenzen_setzen(g: Limits) -> None:
    """Inside the child, immediately after the fork.

    ``RLIMIT_AS`` rather than ``RLIMIT_DATA``: a portal that puts a large file
    into memory does so through ``mmap`` — and that only counts against ``AS``.
    ``RLIMIT_CPU`` additionally catches the endless loop, against which a
    deadline from outside achieves nothing while the child is busy computing.

    The memory limit is `memory_mb` **above** what the child inherits — see
    ``_adressraum_jetzt``.
    """
    limit = _adressraum_jetzt() + g.memory_mb * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_AS, (limit, limit))
    resource.setrlimit(resource.RLIMIT_CPU, (g.cpu_s, g.cpu_s))
    # No core dump: a crashed portal should not drop 256 MB onto the disk, and
    # certainly not with somebody's credentials inside.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run(
    work: Callable[[], Any],
    limits: Limits | None = None,
) -> Any:
    """Run `work` in a child process and return its result.

    The result has to survive ``pickle`` — with the core's contracts it does,
    because they are data classes without behaviour.

    Raises ``core.errors.Error`` with ``run.timeout``, ``run.out_of_memory`` or
    ``run.crashed``. **Three codes rather than one**: whoever sees them has
    nothing to investigate. A memory limit set too tight is a number in the
    settings and would otherwise look like a broken portal.
    """
    if not available():
        raise f.Error("run.no_fork", {"platform": sys.platform}, status=500)

    g = limits or Limits()
    read_range, write_chunk = os.pipe()

    # **Nobody forks while another thread is inside SQLite** (AP74, 11.10.2026):
    # the child would inherit a locked SQLite mutex and hang in its first
    # `connect` until the deadline — see `core/forkschranke.py`.
    with SCHRANKE.fork():
        kind = os.fork()
    if kind == 0:  # ── inside the child ────────────────────────────────────
        SCHRANKE.im_kind_zuruecksetzen()
        # From here on nothing is cleaned up and nothing is handed back: the
        # process ends in a moment either way. `os._exit` skips the parent's
        # `atexit` handling, which we inherited.
        rueckgabe = 0
        try:
            os.close(read_range)
            _grenzen_setzen(g)
            result = work()
            package = pickle.dumps(result, protocol=pickle.HIGHEST_PROTOCOL)
            if len(package) > ANSWER_MAX:
                package = pickle.dumps(f.Error("run.answer_too_large", {"bytes": len(package)}))
            os.write(write_chunk, package)
        except MemoryError:
            os.write(
                write_chunk, pickle.dumps(f.Error(f.RUN_OUT_OF_MEMORY, {"limit_mb": g.memory_mb}))
            )
        except f.Error as err:
            # **Our own codes travel out as what they are.** Until 16.09.2026
            # every exception became `run.crashed` with its text — a coded
            # error raised by a child-setup hook would have arrived as
            # "crashed: Error: <code>", untranslatable and unattributable.
            os.write(write_chunk, pickle.dumps(err))
            rueckgabe = 1
        except BaseException as err:  # the reason belongs outside
            os.write(
                write_chunk,
                pickle.dumps(
                    f.Error(f.RUN_CRASHED, {"kind": type(err).__name__, "text": str(err)[:400]})
                ),
            )
            rueckgabe = 1
        finally:
            os.close(write_chunk)
        os._exit(rueckgabe)

    # ── inside the parent ───────────────────────────────────────────────────
    os.close(write_chunk)
    end = time.monotonic() + g.deadline_s
    chunks: list[bytes] = []
    try:
        os.set_blocking(read_range, False)
        while True:
            remaining = end - time.monotonic()
            if remaining <= 0:
                _abwuergen(kind)
                raise f.Error(f.RUN_TIMEOUT, {"seconds": g.deadline_s}, status=504)
            import select

            is_ready, _, _ = select.select([read_range], [], [], min(remaining, 0.5))
            if not is_ready:
                continue
            part = os.read(read_range, 65536)
            if not part:
                break
            chunks.append(part)
    finally:
        os.close(read_range)

    _, progress = os.waitpid(kind, 0)
    raw = b"".join(chunks)

    if not raw:
        # Nothing came back. This is the case where the kernel felled the child
        # — with RLIMIT_AS usually as SIGKILL, before the child got round to
        # writing anything.
        if os.WIFSIGNALED(progress) and os.WTERMSIG(progress) in (signal.SIGKILL, signal.SIGSEGV):
            raise f.Error(f.RUN_OUT_OF_MEMORY, {"limit_mb": g.memory_mb}, status=507)
        raise f.Error(f.RUN_CRASHED, {"exit": progress}, status=502)

    result = pickle.loads(raw)  # our own data out of our own child
    if isinstance(result, f.Error):
        raise result
    return result


def _abwuergen(kind: int) -> None:
    """Politely first, then not.

    ``SIGTERM`` gives a portal the chance to close a connection; whoever is
    still alive afterwards is stuck and gets ``SIGKILL``. Half a second of
    patience is enough — this is not about a clean shutdown but about leaving
    no child behind.
    """
    try:
        os.kill(kind, signal.SIGTERM)
        for _ in range(5):
            time.sleep(0.1)
            if os.waitpid(kind, os.WNOHANG)[0]:
                return
        os.kill(kind, signal.SIGKILL)
        os.waitpid(kind, 0)
    except (ProcessLookupError, ChildProcessError):
        pass


def as_json(result: Any) -> str:
    """For the case where a runner runs as its own process rather than a fork."""
    return json.dumps(result, ensure_ascii=False, default=str)
