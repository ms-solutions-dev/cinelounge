"""What a child was doing when the deadline struck — and how long each step took.

**The 20 seconds had no name** (AP74, 11.10.2026). 11 of 164 `/list` in 48 hours
ran into the deadline, in chains of three — three portals, each
20.6 s after the other — while the same lists answered in under a second two
minutes later. The access log said `504 run.timeout {'seconds': 20.0}` and
nothing more: the child is killed before it can log anything. AdGuard's query
log then showed that those children never even asked for a name — the time went
somewhere **before** the network. Reproduced the same afternoon: an EXCLUSIVE
lock on `tmdb.sqlite` turns a fully cached listing into a 20-second timeout.

So the child keeps a trail. Every step that can block — a name lookup, a
connect, a TLS handshake, waiting for a response, opening an SQLite file — is
noted the moment it starts and again when it ends, in two small files under
`/dev/shm`. The parent reads them when the deadline strikes and names the step
that was still open: `offen: sqlite tmdb.sqlite seit 19.4 s`. On a slow success
the same trail goes into the duration line. The hooks are installed in the child
only, so the parent's own requests stay out of it.
"""

from __future__ import annotations

import http.client
import os
import socket
import sqlite3
import ssl
import tempfile
import threading
import time
import uuid
from collections import OrderedDict
from pathlib import Path
from typing import Any

_AKTIV: Spur | None = None
_SPERRE = threading.Lock()
_ORIGINALE: dict[str, Any] = {}


def _ordner() -> Path:
    shm = Path("/dev/shm")
    return shm if shm.is_dir() and os.access(shm, os.W_OK) else Path(tempfile.gettempdir())


class Spur:
    """One trail per portal call: created in the parent, written in the child."""

    def __init__(self) -> None:
        kennung = uuid.uuid4().hex
        self.fertig = _ordner() / f"cl-spur-{kennung}"
        self.offen = _ordner() / f"cl-spur-{kennung}.offen"
        self._stapel: list[tuple[str, str, float]] = []

    # ── inside the child ────────────────────────────────────────────────────

    def einschalten(self) -> None:
        """Install the hooks in this process. Idempotent; never raises."""
        global _AKTIV
        with _SPERRE:
            if _AKTIV is not None:
                _AKTIV = self
                return
            _AKTIV = self
            try:
                _einhaengen()
            except Exception:  # a trail must never break the call it describes
                _AKTIV = None

    def _beginn(self, stufe: str, ziel: str) -> None:
        with _SPERRE:
            self._stapel.append((stufe, ziel, time.time()))
            self._schreibe_offen()

    def _ende(self, stufe: str, ziel: str) -> None:
        with _SPERRE:
            for i in range(len(self._stapel) - 1, -1, -1):
                s, z, seit = self._stapel[i]
                if s == stufe and z == ziel:
                    del self._stapel[i]
                    dauer = time.time() - seit
                    with open(self.fertig, "a", encoding="utf-8") as f:
                        f.write(f"{stufe}\t{ziel}\t{dauer:.3f}\n")
                    break
            self._schreibe_offen()

    def _schreibe_offen(self) -> None:
        text = "".join(f"{s}\t{z}\t{seit:.3f}\n" for s, z, seit in self._stapel)
        tmp = self.offen.with_suffix(".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, self.offen)

    # ── inside the parent ───────────────────────────────────────────────────

    def zusammenfassung(self, jetzt: float | None = None) -> str | None:
        """Completed steps grouped, then whatever was still open — or `None`."""
        jetzt = time.time() if jetzt is None else jetzt
        teile: list[str] = []
        gruppen: OrderedDict[tuple[str, str], tuple[int, float]] = OrderedDict()
        try:
            for zeile in self.fertig.read_text(encoding="utf-8").splitlines():
                stufe, ziel, dauer = zeile.split("\t")
                n, summe = gruppen.get((stufe, ziel), (0, 0.0))
                gruppen[(stufe, ziel)] = (n + 1, summe + float(dauer))
        except (OSError, ValueError):
            pass
        for (stufe, ziel), (n, summe) in gruppen.items():
            anzahl = f" x{n}" if n > 1 else ""
            teile.append(f"{stufe} {ziel}{anzahl} {summe:.2f} s")
        try:
            for zeile in self.offen.read_text(encoding="utf-8").splitlines():
                stufe, ziel, seit = zeile.split("\t")
                teile.append(f"offen: {stufe} {ziel} seit {jetzt - float(seit):.1f} s")
        except (OSError, ValueError):
            pass
        return "; ".join(teile) if teile else None

    def aufraeumen(self) -> None:
        for p in (self.fertig, self.offen, self.offen.with_suffix(".tmp")):
            try:
                p.unlink()
            except OSError:
                pass


# ── The hooks ───────────────────────────────────────────────────────────────


def _notiere(stufe: str, ziel: str) -> _Schritt:
    return _Schritt(stufe, ziel)


class _Schritt:
    def __init__(self, stufe: str, ziel: str) -> None:
        self.stufe, self.ziel = stufe, ziel

    def __enter__(self) -> None:
        if _AKTIV is not None:
            try:
                _AKTIV._beginn(self.stufe, self.ziel)
            except Exception:
                pass

    def __exit__(self, *_: object) -> None:
        if _AKTIV is not None:
            try:
                _AKTIV._ende(self.stufe, self.ziel)
            except Exception:
                pass


def _einhaengen() -> None:
    if _ORIGINALE:
        return
    _ORIGINALE["getaddrinfo"] = socket.getaddrinfo
    _ORIGINALE["create_connection"] = socket.create_connection
    _ORIGINALE["wrap_socket"] = ssl.SSLContext.wrap_socket
    _ORIGINALE["getresponse"] = http.client.HTTPConnection.getresponse
    _ORIGINALE["sqlite_connect"] = sqlite3.connect

    def getaddrinfo(host: Any, *a: Any, **kw: Any) -> Any:
        with _notiere("dns", str(host)):
            return _ORIGINALE["getaddrinfo"](host, *a, **kw)

    def create_connection(address: Any, *a: Any, **kw: Any) -> Any:
        with _notiere("connect", f"{address[0]}:{address[1]}"):
            return _ORIGINALE["create_connection"](address, *a, **kw)

    def wrap_socket(self: ssl.SSLContext, sock: Any, *a: Any, **kw: Any) -> Any:
        with _notiere("tls", str(kw.get("server_hostname") or "?")):
            return _ORIGINALE["wrap_socket"](self, sock, *a, **kw)

    def getresponse(self: http.client.HTTPConnection, *a: Any, **kw: Any) -> Any:
        with _notiere("antwort", str(getattr(self, "host", "?"))):
            return _ORIGINALE["getresponse"](self, *a, **kw)

    def sqlite_connect(database: Any, *a: Any, **kw: Any) -> Any:
        with _notiere("sqlite", os.path.basename(str(database))):
            return _ORIGINALE["sqlite_connect"](database, *a, **kw)

    socket.getaddrinfo = getaddrinfo
    socket.create_connection = create_connection
    ssl.SSLContext.wrap_socket = wrap_socket  # type: ignore[method-assign]
    http.client.HTTPConnection.getresponse = getresponse  # type: ignore[method-assign]
    sqlite3.connect = sqlite_connect
    # urllib3 (requests) connects through its own helper, not through
    # `socket.create_connection`; the name lookup above still sees it.
    try:
        from urllib3.util import connection as u3

        _ORIGINALE["u3_create_connection"] = u3.create_connection

        def u3_create_connection(address: Any, *a: Any, **kw: Any) -> Any:
            with _notiere("connect", f"{address[0]}:{address[1]}"):
                return _ORIGINALE["u3_create_connection"](address, *a, **kw)

        u3.create_connection = u3_create_connection
    except ImportError:
        pass


def ausschalten() -> None:
    """For tests: put the originals back and forget the trail."""
    global _AKTIV
    with _SPERRE:
        _AKTIV = None
        if not _ORIGINALE:
            return
        socket.getaddrinfo = _ORIGINALE["getaddrinfo"]
        socket.create_connection = _ORIGINALE["create_connection"]
        ssl.SSLContext.wrap_socket = _ORIGINALE["wrap_socket"]  # type: ignore[method-assign]
        http.client.HTTPConnection.getresponse = _ORIGINALE["getresponse"]  # type: ignore[method-assign]
        sqlite3.connect = _ORIGINALE["sqlite_connect"]
        if "u3_create_connection" in _ORIGINALE:
            from urllib3.util import connection as u3

            u3.create_connection = _ORIGINALE["u3_create_connection"]
        _ORIGINALE.clear()
