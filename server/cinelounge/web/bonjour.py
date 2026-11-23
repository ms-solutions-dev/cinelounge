"""Announcing ourselves on the home network.

**So that nobody types an address with a remote control.** On an Apple TV every
character is a crossing of a keyboard grid; entering `cl.example` once is
reasonable, `192.0.2.183:8100` is not. If the service announces itself, the
address is already in the field before anybody looks.

**Without a third-party package.** mDNS is a UDP broadcast to
`224.0.0.251:5353` with a DNS packet in it; the two answers it takes — PTR and
SRV/TXT/A — can be built by hand. One package fewer in the image is one package
fewer for somebody to maintain.

**It is a convenience, not a promise.** On a guest network mDNS does not reach,
and the Fritzbox shuffles it around port 5353 anyway. The address field in the
app stays the way that always carries — which is why this service fails
quietly and never loudly.

## Why this does not run inside the service itself (measured 10.09.2026)

It ran there first, and it ran too — only uselessly::

    own address in the container: 172.16.69.2
    Bonjour: cinelounge._cinelounge._tcp.local. on port 8099
    found on the network: 0

Two reasons, and both are fundamental: **multicast does not cross a Docker
bridge**, and the address the container knows of itself is a bridge address
that means nothing to anybody on the home network.

That is why the announcer runs as a **container of its own on the host network**
(`cinelounge-melder`). It speaks no HTTP, carries no Traefik label and knows the
service only as an address and a port — which also removes the trap
`network_mode: host` otherwise brings: Traefik loses the IP of a container that
hangs in the host network.

    python -m cinelounge.web.bonjour --name cinelounge --port 8100
"""

from __future__ import annotations

import contextlib
import logging
import os
import socket
import struct
import threading
import time
from typing import Final

_LOG = logging.getLogger("cinelounge.bonjour")

GROUP: Final = "224.0.0.251"
PORT: Final = 5353
SERVICE: Final = "_cinelounge._tcp.local."
TTL: Final = 120


def _name(parts: list[str]) -> bytes:
    """A DNS name in length-value form. No pointer compression — it saves a few
    bytes and costs this file's readability."""
    out = b""
    for t in parts:
        raw = t.encode("utf-8")
        out += bytes([len(raw)]) + raw
    return out + b"\x00"


def _eintrag(name: bytes, kind: int, daten: bytes, cache_flush: bool = True) -> bytes:
    cls_ = 0x8001 if cache_flush else 0x0001
    return name + struct.pack("!HHIH", kind, cls_, TTL, len(daten)) + daten


def answer_due(package: bytes, sender: str, wanted: bytes, own: str) -> bool:
    """Whether this packet may be answered.

    **This is the rule that was missing on 10.09.2026.** The announcer only
    checked whether the service name occurs in the packet — and it occurs in its
    *own answer*. It read that back, took it for a question and answered again.
    Measured: 3.2 MB of packets in five seconds, half a processor core
    permanently, and the mDNS queues of the Matter server and Home Assistant on
    the same network stood at ~180 KB. On stopping the announcer they fell to
    zero within three seconds.

    An announcer that floods the home network is worse than none. Three
    questions, in this order:

    1. **Is it a question at all?** The QR bit in the second header byte is set
       in an answer. That alone breaks the loop.
    2. **Does it come from us?** Second bolt — on the host network one sees
       one's own broadcasts.
    3. **Is it about us?** Whoever answers every packet is a jammer.
    """
    if len(package) < 12:
        return False
    if package[2] & 0x80:  # QR set = an answer, not a question
        return False
    if sender == own:
        return False
    return wanted in package


class Announcer:
    """Announces the service for as long as it runs."""

    def __init__(self, name: str, port: int, address: str) -> None:
        self.name = name
        self.port = port
        self.address = address
        self._aus = threading.Event()
        self._faden: threading.Thread | None = None

    # ── The answer ───────────────────────────────────────────────────────────

    def _antwort(self) -> bytes:
        full = _name([self.name, "_cinelounge", "_tcp", "local"])
        dienst = _name(["_cinelounge", "_tcp", "local"])
        host = _name([self.name, "local"])

        # PTR: "under this service there is this instance"
        ptr = _eintrag(dienst, 12, full, cache_flush=False)
        # SRV: "this instance listens on this host and port"
        srv = _eintrag(full, 33, struct.pack("!HHH", 0, 0, self.port) + host)
        # TXT: what the app wants to know before it even asks
        text = b""
        for pair in (b"path=/.well-known/cinelounge", b"api=1", b"v=1"):
            text += bytes([len(pair)]) + pair
        txt = _eintrag(full, 16, text)
        # A: the address itself
        a = _eintrag(host, 1, socket.inet_aton(self.address))

        head = struct.pack("!HHHHHH", 0, 0x8400, 0, 4, 0, 0)
        return head + ptr + srv + txt + a

    # ── The run ──────────────────────────────────────────────────────────────

    def _laufen(self) -> None:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("", PORT))
        s.setsockopt(
            socket.IPPROTO_IP,
            socket.IP_ADD_MEMBERSHIP,
            socket.inet_aton(GROUP) + socket.inet_aton("0.0.0.0"),
        )
        s.settimeout(1.0)
        answer = self._antwort()

        # Announce twice unasked: whoever is searching right now finds us at
        # once instead of waiting for the next question.
        for _ in range(2):
            s.sendto(answer, (GROUP, PORT))
            self._aus.wait(0.4)

        wanted = _name(["_cinelounge", "_tcp", "local"])
        zuletzt = 0.0
        while not self._aus.is_set():
            try:
                package, sender = s.recvfrom(4096)
            except (TimeoutError, OSError):
                continue
            if not answer_due(package, sender[0], wanted, self.address):
                continue
            # **One answer per second.** Even if the rule above is wrong once,
            # no storm can come of it any more — an Apple TV asks once and
            # waits, no device needs more than that.
            jetzt = time.monotonic()
            if jetzt - zuletzt < 1.0:
                continue
            zuletzt = jetzt
            with contextlib.suppress(OSError):
                s.sendto(answer, (GROUP, PORT))
        s.close()

    def start(self) -> None:
        if self._faden:
            return
        self._faden = threading.Thread(target=self._laufen, name="bonjour", daemon=True)
        self._faden.start()

    def stop(self) -> None:
        self._aus.set()


def own_address() -> str:
    """The address at which the home network reaches us.

    The broadcast trick instead of `gethostbyname`: in a container the host name
    points at `127.0.0.1`, and an address only the container knows is worse as
    information than none.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.168.255.255", 9))
        return str(s.getsockname()[0])
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def report(name: str, port: int) -> Announcer | None:
    """Register the service — and **give up quietly** when it does not work.

    A container without network rights, a guest network, an occupied port 5353:
    all of those are a reason to go without a convenience, and none is a reason
    not to start the service.
    """
    try:
        m = Announcer(name, port, own_address())
        m.start()
        _LOG.info("Bonjour: %s.%s on port %d", name, SERVICE, port)
        return m
    except Exception as err:
        _LOG.info("Bonjour not possible (%s) — the address has to be typed", err)
        return None


def _hauptlauf() -> int:
    """Run as a process of its own — that is what the announcer container is for.

    It does exactly one thing and otherwise keeps out of the way: no HTTP, no
    access to the household, no secrets. If it fails, the address has to be
    typed, and nothing else.
    """
    import argparse
    import signal as sig

    p = argparse.ArgumentParser(description="mDNS announcer for CineLounge")
    p.add_argument("--name", default=os.environ.get("CL_NAME", "cinelounge"))
    p.add_argument("--port", type=int, default=int(os.environ.get("CL_PORT", "8100")))
    p.add_argument("--address", default=os.environ.get("CL_ADDRESS", ""))
    a = p.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    address = a.address or own_address()
    m = Announcer(a.name, a.port, address)
    m.start()
    _LOG.info("Announcer running: %s.%s -> %s:%d", a.name, SERVICE, address, a.port)

    ende = threading.Event()
    for s in (sig.SIGTERM, sig.SIGINT):
        sig.signal(s, lambda *_: ende.set())
    ende.wait()
    m.stop()
    _LOG.info("Announcer stopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(_hauptlauf())
