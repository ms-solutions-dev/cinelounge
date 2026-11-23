"""Catch the stream the moment it opens — and serve range requests from it.

**What this was built for** (measured 29.08.2026): some sources hand out an
address that opens **exactly once** — the first request without a `Range`
gets the stream. Every further request goes to the origin afresh, and the
address is spent by then: **400**.

So it is not the relay that fails but the timing. The app's chain reads:
resolve → address to the player → HEAD → range request. By the HEAD the single
shot is already gone. A player that starts in the same breath as resolving
never notices.

**So the bridge takes on the player's role.** At the moment of resolving it
grabs the pre-opened stream itself and writes it to disk. Whatever the
television asks for afterwards — HEAD, seek, rewind — is served from the file.
The origin is asked exactly **once**.

**The limit, named honestly:** writing happens in order, from the front. A seek
to the end waits until the buffer gets there. For the kind of video at stake
(measured running times of seven to thirteen minutes) that does not weigh — the
buffer runs faster than playback. For a two-hour film it would be noticeable,
and then a method that loads in chunks rather than in one piece belongs here.

**Since 03.09. that method exists** — ``begin_chunked``. The occasion stands in
diagnosis F-004: one film took 8.2 s to picture, and eleven lines of "slow
range … 2–4 s" for one megabyte each say why — the file server delivers
**per connection** at 2–4 Mbit/s. Four connections are four times as fast.
The loader fetches the file in blocks with four workers, and
wherever the television is reading has priority: a seek to the end pulls the
next blocks there. The television reads out of the file at home-network speed as
soon as the loader is ahead of it — and it is, after the first block.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import threading
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import requests

# What marks a playlist — by content type, or by the path when the host says
# `application/octet-stream` about everything. Same pattern as the relay's.
_IST_LISTE = re.compile(r"mpegurl|x-mpegURL|vnd\.apple|dash\+xml", re.I)
_IST_LISTE_PFAD = re.compile(r"\.(m3u8|mpd)$", re.I)

_LOG = logging.getLogger("cinelounge.vorrat")

# How much space the buffers may occupy together. 450 GB are free, so this is
# no economy measure — it is the promise that a forgotten buffer will not eat
# the disk.
LIMIT_BYTES = 8 * 1024**3
# How long an **unfinished** buffer stays: one that was cut off or whose run
# ended in an error. A finished one is untouched by this — that one is stock.
TTL_S = 3600.0

# How much the **stock** may occupy.
#
# **What finished loading stays** (11.09.2026, Max's decision):
# `begin_chunked()` already **is** a downloader — it merely threw the result
# away after an hour, and a restart took everything with it anyway. Whoever
# watched half an episode in the evening and continued the next day fetched the
# host a second time.
#
# Twenty gigabytes, and the number is a promise, not a quota: on the mini PC a
# full disk has already been the reason for a total outage once. Once the limit
# is reached, **what has gone untouched the longest** falls first.
STOCK_LIMIT_BYTES = 20 * 1024**3
# How long a reader waits for data that has not been written yet.
PATIENCE_S = 30.0
# The chunked loader: block size and number of workers. At 2–4 Mbit/s per
# connection a megabyte is two to four seconds per block — that is the longest a
# seek waits for its first block. It was four megabytes until 04.09. (F-041:
# continuing a film, 22 seconds to the first picture — the block at the
# seek target alone took eight, and the four workers were still hanging on the
# blocks from the start of the file).
BLOCK_BYTES = 1 * 1024**2
# From how many blocks of distance on a worker drops the block it is loading,
# because the reader is waiting somewhere else.
DROP_DISTANCE = 2 * 4
WORKERS = 4
# How often a block is retried before the buffer gives up.
ATTEMPTS = 3


class Entry:
    """A running or finished buffer."""

    def __init__(self, path: Path, kind: str, length: int | None):
        self.path = path
        self.kind = kind
        # The total length comes from the host and is settled as it opens.
        # Without it the player could not seek — it would not know where to.
        self.length = length
        self.written = 0
        self.done = False
        self.errors: str | None = None
        self.beruehrt = time.time()
        self.wecker = threading.Condition()
        # Instead of a write edge the chunked loader keeps a set of finished
        # blocks — and the reader's wish, which steers the order.
        self.in_bloecken = False
        self.bloecke_fertig: set[int] = set()
        self.bloecke_laufend: set[int] = set()
        # How far a running block is written from its start (AP63, 01.10.2026):
        # a reader at the beginning of a block need not wait for the whole
        # megabyte. The app's container probe asks for 4 KB and waited 2.8 s.
        self.teil: dict[int, int] = {}
        self.wanted = 0

    def block(self, byte: int) -> int:
        return byte // BLOCK_BYTES

    @property
    def block_count(self) -> int:
        return (self.length + BLOCK_BYTES - 1) // BLOCK_BYTES if self.length else 0

    def available_until(self, byte: int) -> int | None:
        """Up to where it is written without gaps from `byte` — `None` if nothing."""
        if not self.in_bloecken:
            return self.written if self.written > byte else None
        index = self.block(byte)
        if index not in self.bloecke_fertig:
            angefangen = index * BLOCK_BYTES + self.teil.get(index, 0)
            return angefangen if angefangen > byte else None
        while index in self.bloecke_fertig:
            index += 1
        ende = index * BLOCK_BYTES + self.teil.get(index, 0)
        return min(ende, self.length or ende)

    def report(self, written: int, done: bool = False, errors: str | None = None) -> None:
        with self.wecker:
            self.written = written
            self.done = done or bool(errors)
            self.errors = errors
            self.beruehrt = time.time()
            self.wecker.notify_all()

    def warten_auf(self, byte: int) -> bool:
        """Until the byte is written — or it is settled that it will not come."""
        end = time.time() + PATIENCE_S
        with self.wecker:
            # The reader says where it is — the loader fetches the next blocks there.
            self.wanted = byte
            while self.available_until(byte) is None and not self.done:
                if not self.wecker.wait(timeout=max(0.1, end - time.time())) and (
                    time.time() >= end
                ):
                    return False
            return self.errors is None and (self.available_until(byte) is not None or self.done)

    def block_progress(self, index: int, written: int) -> None:
        """How far block `index` is written from its start — only ever forward.

        A retry writes the same bytes again; the edge does not move back for it.
        """
        with self.wecker:
            if index in self.bloecke_fertig or written <= self.teil.get(index, 0):
                return
            self.teil[index] = written
            self.wecker.notify_all()

    def block_done(self, index: int) -> None:
        with self.wecker:
            self.bloecke_laufend.discard(index)
            self.teil.pop(index, None)
            self.bloecke_fertig.add(index)
            self.written = min(len(self.bloecke_fertig) * BLOCK_BYTES, self.length or 0)
            self.beruehrt = time.time()
            if len(self.bloecke_fertig) >= self.block_count:
                self.done = True
            self.wecker.notify_all()

    def reader_elsewhere(self, index: int) -> bool:
        """Whether the reader waits far from `index` on a block nobody is fetching.

        Then the worker drops its block: a seek to the end must not wait until
        four workers have finished their blocks from the beginning (F-041).
        """
        with self.wecker:
            wanted = self.block(self.wanted)
            if abs(wanted - index) < DROP_DISTANCE:
                return False
            return any(
                candidate not in self.bloecke_fertig and candidate not in self.bloecke_laufend
                for candidate in range(wanted, min(wanted + WORKERS, self.block_count))
            )

    def drop_block(self, index: int) -> None:
        with self.wecker:
            self.bloecke_laufend.discard(index)

    def next_block(self) -> int | None:
        """Which block is next — the one at the reader first."""
        with self.wecker:
            if self.errors or self.block_count == 0:
                return None
            start = self.block(self.wanted)
            for index in list(range(start, self.block_count)) + list(range(0, start)):
                if index not in self.bloecke_fertig and index not in self.bloecke_laufend:
                    self.bloecke_laufend.add(index)
                    return index
            return None


_PUFFER: dict[str, Entry] = {}
_SPERRE = threading.Lock()
_ORDNER: Path | None = None


def set_folder(path: Path) -> None:
    global _ORDNER
    _ORDNER = path
    path.mkdir(parents=True, exist_ok=True)


def key_for(portal: str, source: str) -> str:
    return hashlib.sha1(f"{portal}|{source}".encode()).hexdigest()[:16]


def has(key: str) -> bool:
    with _SPERRE:
        item = _PUFFER.get(key)
    return item is not None and item.errors is None


def _proxies(via: str | None) -> dict[str, str] | None:
    """`via` is the route's proxy for a routed portal — or `None`, and then
    `requests` goes out the front door as before. **Explicit, not `trust_env`**:
    the API process has no `HTTP_PROXY` in its environment and must never get
    one; the way out is a property of the stream, not of the process."""
    return {"http": via, "https": via} if via else None


def begin(
    key: str, address: str, headers: dict[str, str] | None, via: str | None = None
) -> Entry | None:
    """Take the pre-opened stream and write it away in the background.

    The request goes out **without a `Range`**, and that is no sloppiness: a
    once-only address hands over its stream only to a plain request. A range
    request would go past it to the origin — and that one then answers 400.
    """
    if _ORDNER is None:
        return None

    with _SPERRE:
        present = _PUFFER.get(key)
        if present and present.errors is None and present.path.exists():
            present.beruehrt = time.time()
            return present

    try:
        answer = requests.get(
            address, headers=dict(headers or {}), stream=True, timeout=30, proxies=_proxies(via)
        )
    except Exception:  # the caller then takes the ordinary way
        return None
    if answer.status_code not in (200, 206):
        answer.close()
        return None

    length = answer.headers.get("Content-Length")
    item = Entry(
        path=_ORDNER / f"{key}.bin",
        kind=answer.headers.get("Content-Type", "video/mp4"),
        length=int(length) if length and length.isdigit() else None,
    )
    with _SPERRE:
        _PUFFER[key] = item

    def write_chunk() -> None:
        total = 0
        try:
            with item.path.open("wb") as file:
                for chunk in answer.iter_content(chunk_size=256 * 1024):
                    if not chunk:
                        continue
                    file.write(chunk)
                    file.flush()
                    total += len(chunk)
                    item.report(total)
            item.report(total, done=True)
            if item.length is None:
                item.length = total
            # **The docket last**, once the length is settled: with a stream
            # without `Content-Length` only this moment knows it.
            _schein_schreiben(key, item)
        except Exception as errors:
            item.report(total, errors=f"{type(errors).__name__}: {errors}")
        finally:
            answer.close()
            sweep()

    threading.Thread(target=write_chunk, name=f"puffer-{key}", daemon=True).start()
    return item


def begin_chunked(
    key: str, address: str, headers: dict[str, str] | None, via: str | None = None
) -> Entry | None:
    """Fetch a file with several range requests at once — see above.

    Returns `None` if the host does not serve ranges or does not name the
    length: then relaying stays as it is and the television fetches for itself.
    The first grab is a one-byte request — it says both.
    """
    if _ORDNER is None:
        return None

    with _SPERRE:
        present = _PUFFER.get(key)
        if present and present.errors is None and present.path.exists():
            present.beruehrt = time.time()
            return present

    head = dict(headers or {})
    try:
        probe = requests.get(
            address,
            headers=dict(head, Range="bytes=0-0"),
            stream=True,
            timeout=20,
            proxies=_proxies(via),
        )
    except Exception:
        return None
    range_ = probe.headers.get("Content-Range", "")
    kind = probe.headers.get("Content-Type", "video/mp4")
    probe.close()
    if probe.status_code != 206 or "/" not in range_:
        return None
    # **A playlist is not a file, even when the server serves it in ranges.**
    # Measured 16.09.2026 at one mirror: `master.m3u8` came
    # back `206` with a `Content-Range` like any video, was written to the
    # stock as a "file" — and reached the phone unrewritten, with
    # `stream_1/playlist.m3u8` resolved against `cl.example` → 404, shown as
    # "address expired". The relay rewrites playlists (`proxy.rewrite`);
    # the stock must leave them to it.
    if _IST_LISTE.search(kind) or _IST_LISTE_PFAD.search(address.split("?", 1)[0]):
        return None
    whole = range_.rsplit("/", 1)[1].strip()
    if not whole.isdigit() or int(whole) == 0:
        return None
    length = int(whole)

    item = Entry(path=_ORDNER / f"{key}.bin", kind=kind, length=length)
    item.in_bloecken = True
    with _SPERRE:
        _PUFFER[key] = item
    # Create the file at full length so every worker can write to its own
    # spot — only what is reported as finished is read anyway.
    with item.path.open("wb") as file:
        file.truncate(length)

    def workers() -> None:
        while True:
            index = item.next_block()
            if index is None:
                return
            from_ = index * BLOCK_BYTES
            until = min(from_ + BLOCK_BYTES, length) - 1
            ok = False
            for _ in range(ATTEMPTS):
                try:
                    answer = requests.get(
                        address,
                        headers=dict(head, Range=f"bytes={from_}-{until}"),
                        stream=True,
                        timeout=30,
                        proxies=_proxies(via),
                    )
                    if answer.status_code != 206:
                        answer.close()
                        continue
                    spot = from_
                    dropped = False
                    with item.path.open("r+b") as file:
                        for chunk in answer.iter_content(chunk_size=256 * 1024):
                            if chunk:
                                file.seek(spot)
                                file.write(chunk)
                                spot += len(chunk)
                                # The reader opens its own handle — what sits
                                # in this one's buffer it would read as zeros.
                                file.flush()
                                item.block_progress(index, spot - from_)
                            if item.reader_elsewhere(index):
                                dropped = True
                                break
                    answer.close()
                    if dropped:
                        # The block gets another turn later; what counts now
                        # is where the reader is waiting.
                        item.drop_block(index)
                        ok = True
                        break
                    if spot == until + 1:
                        ok = True
                        break
                except Exception:
                    continue
            if not ok:
                item.report(item.written, errors=f"block {index} could not be fetched")
                return
            item.block_done(index)
            if item.done:
                _schein_schreiben(key, item)
                sweep()
                return

    for number in range(WORKERS):
        threading.Thread(target=workers, name=f"puffer-{key}-{number}", daemon=True).start()
    return item


def finished(key: str) -> None:
    """A run is through — that belongs on disk, not only in memory.

    Called by both loaders when they are done. Without this step the stock would
    be empty again after the next restart: `_PUFFER` lives in the process, the
    file outlives it.
    """
    with _SPERRE:
        item = _PUFFER.get(key)
    if item is not None:
        _schein_schreiben(key, item)


def head(key: str) -> tuple[int, dict[str, str]] | None:
    """What a HEAD request has to answer."""
    with _SPERRE:
        item = _PUFFER.get(key)
    if not item or item.errors:
        return None
    headers = {"Content-Type": item.kind, "Accept-Ranges": "bytes"}
    if item.length is not None:
        headers["Content-Length"] = str(item.length)
    return 200, headers


def read_range(key: str, range_: str | None) -> tuple[int, dict[str, str], Iterator[bytes]] | None:
    """Serve from the buffer — including what is still being written.

    Returns `(status, headers, chunks)`. A range request is answered with 206,
    anything else with 200. Whoever reads past the edge of what is written waits
    — and only as long as ``PATIENCE_S`` allows; a player waiting into nothing
    looks worse than one that gets an error.
    """
    with _SPERRE:
        item = _PUFFER.get(key)
    if not item or item.errors:
        return None
    item.beruehrt = time.time()

    from_, until = 0, None
    if range_ and range_.startswith("bytes="):
        parts = range_.split("=", 1)[1].split("-", 1)
        if parts[0].strip().isdigit():
            from_ = int(parts[0])
            if len(parts) > 1 and parts[1].strip().isdigit():
                until = int(parts[1])
        elif len(parts) > 1 and parts[1].strip().isdigit() and item.length:
            # **`bytes=-N` means the last N bytes**, not "0 to N". That is how
            # it stood here until 04.09.: a player that wanted the end of the
            # file got the beginning — with a range header that claimed as much.
            from_ = max(0, item.length - int(parts[1]))
            until = item.length - 1

    if not item.warten_auf(from_):
        return None

    whole = item.length
    last = until if until is not None else (whole - 1 if whole else None)
    headers = {"Content-Type": item.kind, "Accept-Ranges": "bytes"}
    progress = 200
    if range_ and whole is not None and last is not None:
        progress = 206
        headers["Content-Range"] = f"bytes {from_}-{last}/{whole}"
        headers["Content-Length"] = str(last - from_ + 1)
    elif whole is not None:
        headers["Content-Length"] = str(whole - from_)

    def chunks() -> Iterator[bytes]:
        with_ = item.path.open("rb")
        try:
            with_.seek(from_)
            read_bytes = from_
            limit = last + 1 if last is not None else None
            while limit is None or read_bytes < limit:
                # **Read only what is reported as written.** The chunked loader
                # creates the file at full length; whoever read to the end of the
                # file would get zeros instead of video. With the sequential
                # buffer the limit is the write edge — same method, other number.
                present = item.available_until(read_bytes)
                if present is None or present <= read_bytes:
                    if item.done and item.errors is None and not item.in_bloecken:
                        return
                    if not item.warten_auf(read_bytes):
                        return
                    present = item.available_until(read_bytes)
                    if present is None or present <= read_bytes:
                        return
                how_much = min(256 * 1024, present - read_bytes)
                if limit is not None:
                    how_much = min(how_much, limit - read_bytes)
                chunk = with_.read(how_much)
                if not chunk:
                    return
                read_bytes += len(chunk)
                yield chunk
        finally:
            with_.close()

    return progress, headers, chunks()


def sweep() -> None:
    """Clear up — and keep two kinds apart while doing it.

    **A finished buffer is stock and does not age.** It only falls once
    `STOCK_LIMIT_BYTES` is reached, and then what has gone untouched the longest
    goes first. Until 11.09.2026 it flew out after an hour — a downloader that
    throws its result away.

    **An unfinished one keeps ageing.** A run that ended in an error or that
    nobody reads any more has, after `TTL_S`, nobody left waiting for it. And
    `LIMIT_BYTES` holds for everything together: the promise against the disk
    filling up is the one limit that knows no exception.
    """
    if _ORDNER is None:
        return
    with _SPERRE:
        items = sorted(_PUFFER.items(), key=lambda kv: kv[1].beruehrt)
    now = time.time()
    used_bytes = vorrat_bytes = 0
    for key, item in reversed(items):  # keep the most recently touched first
        size = item.path.stat().st_size if item.path.exists() else 0
        ist_vorrat = item.done and not item.errors

        zu_alt = not ist_vorrat and now - item.beruehrt > TTL_S
        zu_voll = used_bytes + size > LIMIT_BYTES
        vorrat_voll = ist_vorrat and vorrat_bytes + size > STOCK_LIMIT_BYTES

        if (zu_alt or zu_voll or vorrat_voll) and item.done:
            item.path.unlink(missing_ok=True)
            (_ORDNER / f"{key}.json").unlink(missing_ok=True)
            with _SPERRE:
                _PUFFER.pop(key, None)
            continue

        # A running buffer is not taken away — but its space counts.
        used_bytes += size
        if ist_vorrat:
            vorrat_bytes += size


def adopt_orphans() -> int:
    """At startup: adopt what is complete — and delete the rest.

    **`shutil.rmtree()` used to stand here.** "Whatever an earlier run left
    behind is worthless" held as long as a buffer lived one hour; for a stock it
    is the opposite: a restart of the service — and `deploy.sh` makes one on
    every change — threw away everything anybody had half watched.

    **What counts is the length.** Beside every finished file lies a
    `<key>.json` with kind and total length; if the file size matches it, the
    file is complete and gets adopted. Everything else — an aborted run, a file
    without a docket, a docket without a file — flies out. Half a film in the
    stock would be worse than none: the player would get it and stop in the
    middle.
    """
    if _ORDNER is None:
        return 0
    _ORDNER.mkdir(parents=True, exist_ok=True)

    uebernommen = 0
    gesehen: set[Path] = set()
    for schein in sorted(_ORDNER.glob("*.json")):
        datei = schein.with_suffix(".bin")
        gesehen.add(schein)
        try:
            d = json.loads(schein.read_text(encoding="utf-8"))
            laenge = int(d["length"])
            art = str(d.get("kind") or "application/octet-stream")
        except (OSError, ValueError, KeyError, TypeError):
            schein.unlink(missing_ok=True)
            datei.unlink(missing_ok=True)
            continue

        if not datei.is_file() or datei.stat().st_size != laenge:
            schein.unlink(missing_ok=True)
            datei.unlink(missing_ok=True)
            continue

        gesehen.add(datei)
        item = Entry(datei, art, laenge)
        item.written = laenge
        item.done = True
        item.beruehrt = float(d.get("touched") or datei.stat().st_mtime)
        with _SPERRE:
            _PUFFER[schein.stem] = item
        uebernommen += 1

    # Files without a docket are aborted runs from earlier.
    for uebrig in _ORDNER.iterdir():
        if uebrig not in gesehen and uebrig.is_file():
            uebrig.unlink(missing_ok=True)

    if uebernommen:
        _LOG.info("Stock: %d title(s) adopted.", uebernommen)
    return uebernommen


def _schein_schreiben(key: str, item: Entry) -> None:
    """Lay the docket beside the finished file.

    Without it there would be no telling after a restart whether the file is
    complete — and **what kind** it is: `video/mp4` and
    `application/vnd.apple.mpegurl` look the same on disk.
    """
    if _ORDNER is None or not item.done or item.errors or not item.length:
        return
    try:
        if item.path.stat().st_size != item.length:
            return
        (_ORDNER / f"{key}.json").write_text(
            json.dumps(
                {
                    "key": key,
                    "kind": item.kind,
                    "length": item.length,
                    "touched": item.beruehrt,
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
    except OSError as err:  # a missing docket costs only the stock
        _LOG.warning("Stock: docket for %s not written — %s", key, err)


# ── The sweeper runs by itself ──────────────────────────────────────────────

#: How often it is swept when nobody is writing.
#:
#: A minute is far shorter than `TTL_S` and far longer than a pass over a few
#: dozen entries costs. It need not be more precise: the limit is a promise
#: against filling up, not a quota.
SWEEP_EVERY_S = 60.0

_UHR: threading.Thread | None = None
_SCHLUSS = threading.Event()


def _uhrwerk() -> None:
    while not _SCHLUSS.wait(SWEEP_EVERY_S):
        try:
            sweep()
        except Exception:  # a sweeper must never be the reason
            # Why nothing is logged here: this thread runs forever. An error
            # that stays would otherwise write the same line every minute until
            # the disk is full — exactly what it stands against.
            pass


def start_sweeper() -> None:
    """Start the sweeper. Calling it repeatedly is allowed and does nothing.

    **Why it is needed.** Until 11.09.2026 `sweep()` hung on the write paths
    alone: things were cleared up while somebody was watching, and never again
    afterwards. The 8 GB limit was therefore not a promise but an observation —
    measured, 3.2 GB lay around on the bridge overnight, and the limit would
    only have shown up at the next film.

    **Why a thread and not a `lifespan`.** The service forks for every portal
    call (`runner/fork.py`). A thread does not survive `os.fork()` — in the
    child only the forking one runs. That is right here: the sweeper belongs in
    the parent process, and a child deleting files on the side would be a fault.

    The price stands in `_bei_fork_im_kind()`.
    """
    global _UHR
    if _UHR is not None and _UHR.is_alive():
        return
    _SCHLUSS.clear()
    _UHR = threading.Thread(target=_uhrwerk, name="buffer-sweeper", daemon=True)
    _UHR.start()


def stop_sweeper() -> None:
    """Stop and wait. For tests and a clean exit."""
    global _UHR
    _SCHLUSS.set()
    if _UHR is not None:
        _UHR.join(timeout=5.0)
        _UHR = None


def _bei_fork_im_kind() -> None:
    """After `os.fork()` in the child: no sweeper, no inherited lock.

    **The trap this stands against.** If a process forks while another thread
    holds `_SPERRE`, the child inherits it as *held* — by a holder that does not
    exist. The first access there blocks forever. That hits every fork that
    happens to fall into a running `sweep()`, and it looks like a hanging
    portal.

    `_PUFFER` is emptied in the child as well: the runner does not touch the
    buffer, and what it does not touch it should not know either.
    """
    global _UHR, _SPERRE
    _UHR = None
    _SPERRE = threading.Lock()
    _PUFFER.clear()


if hasattr(os, "register_at_fork"):
    os.register_at_fork(after_in_child=_bei_fork_im_kind)


def status() -> dict[str, Any]:
    """What the console shows in the status strip.

    English, because it stands in `/health` and is therefore a surface strangers
    see. `tests/test_translate.py` insists on it and reported it the moment this
    function was first wired up: `puffer` and `laufend` stood here because they
    never went out — the buffer did not run at all until 11.09.2026.
    """
    with _SPERRE:
        items = list(_PUFFER.values())
    vorrat = [e for e in items if e.done and not e.errors]
    return {
        "entries": len(items),
        "running": sum(1 for e in items if not e.done),
        "bytes": sum(e.written for e in items),
        # **The stock kept separate**, because it is something other than a
        # buffer: it is not waiting for a reader, it lies ready.
        "stock": len(vorrat),
        "stock_bytes": sum(e.written for e in vorrat),
        "stock_limit_bytes": STOCK_LIMIT_BYTES,
    }
