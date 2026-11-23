"""The probe — does a resolved address really carry a video?

**What the answer proves counts; what the address claims does not.** Every
address is requested once with `Range: bytes=0-15`, and only what answers with
`206`/`200` and a media type (or, where the type says nothing, the first bytes
of a video container) counts. That way a thumbnail called `preview.mp4.jpg`
drops out by itself, and an address without any suffix (`get_file/…`,
`stream.php?file=…`) gets through although there is nothing to see in it.

**Why every resolved address is probed.** A portal often lists several
sources for one title, and one of them is regularly dead: the portal builds an
address all the same, and only the television notices, blocks later, that a
`403` sits behind it. One probe costs one round trip and moves that knowledge
to the point where the server can still do something about it — try the next
source.

**It breaks nothing open.** A stream with rights management is recognised and
named (`DrmError`), never touched. The rule for that is word for word the
app's (`Stromliste.istRechteverwaltung`): an `#EXT-X-KEY:METHOD=AES-128` with
`KEYFORMAT=identity` is ordinary segment encryption and not rights management —
whoever throws both together refuses streams the player can handle by itself.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Final
from urllib.parse import urljoin, urlsplit

import requests

__all__ = ["DrmError", "Find", "probe"]

_ANFRAGEFRIST = 8.0
"""Seconds for a single request."""

_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)


# ── What counts as a media address ───────────────────────────────────────────
# Two witnesses, and the second is the only one that counts: the suffix is a
# suspicion, the server's answer is the proof.

_ENDUNGEN = {
    ".m3u8": "hls",
    ".m3u": "hls",
    ".mpd": "dash",
    ".mp4": "datei",
    ".m4v": "datei",
    ".webm": "datei",
    ".mkv": "datei",
    ".mov": "datei",
    ".ts": "datei",
}

_TYPEN = {
    "application/vnd.apple.mpegurl": "hls",
    "application/x-mpegurl": "hls",
    "audio/mpegurl": "hls",
    "audio/x-mpegurl": "hls",
    "application/dash+xml": "dash",
    "application/octet-stream": "datei",
}

# ── DRM ──────────────────────────────────────────────────────────────────────
# No circumventing. Recognise, name, leave it lying.

_DASH_RECHTE = re.compile(r"<[^>]*ContentProtection", re.I)
_MERKMAL = re.compile(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)')


class DrmError(Exception):
    """The address carries rights management and is not taken.

    An exception of its own and not `False`, because the difference matters on
    screen: "does not carry" means try the next source, "rights management"
    means stop. The app has a named refusal for it
    (`Lieferart.Absage.rechteverwaltung`).
    """


def _ist_rechteverwaltung(scheme: str, format_: str | None) -> bool:
    """Word for word `Stromliste.istRechteverwaltung` in the app.

    If server and app judged differently there would be streams one delivers
    and the other refuses — and nobody would know which one is right.
    """
    if scheme != "AES-128":
        return True
    if not format_:
        return False
    return format_.strip('"').casefold() != "identity"


def _hls_hat_rechte(text: str) -> bool:
    for line in text.splitlines():
        line = line.strip()
        if not (line.startswith("#EXT-X-KEY:") or line.startswith("#EXT-X-SESSION-KEY:")):
            continue
        tokens = {m.group(1): m.group(2) for m in _MERKMAL.finditer(line.split(":", 1)[1])}
        scheme = tokens.get("METHOD", "NONE").strip('"')
        if scheme != "NONE" and _ist_rechteverwaltung(scheme, tokens.get("KEYFORMAT")):
            return True
    return False


# ── The find ─────────────────────────────────────────────────────────────────


@dataclass(slots=True)
class Find:
    """An address the probe accepted — exactly as much as a stream needs."""

    address: str
    kind: str = "datei"
    headers: dict[str, str] = field(default_factory=dict)
    resolve_ms: int = 0
    # Which level of a page it lay on, for whoever searched for it: 0 the page
    # itself, 1 its embed, 2 that embed's embed. The probe leaves it at 0.
    level: int = 0


# ── The proof ────────────────────────────────────────────────────────────────


def _art_aus_adresse(address: str) -> str | None:
    """The suffix anywhere in the path, not only at its end.

    Video addresses often read `…/get_file/0/<token>.mp4/?token=…` — the
    suffix sits in the middle of the path, with another slash behind it.
    Whoever looks only at the path's end misses it: hosts hang tokens,
    sessions and quality levels behind the file name.
    """
    path = urlsplit(address).path.casefold()
    for chunk in reversed(path.split("/")):
        for suffix, kind in _ENDUNGEN.items():
            if chunk.endswith(suffix):
                return kind
    return None


#: What the proof asks for: sixteen bytes rather than two. Enough for the
#: container signatures in `_videokopf` (an MP4's `ftyp` stands at bytes 4–8),
#: and still nothing the host has to deliver in earnest.
_SPANNE: Final = "bytes=0-15"

#: Container signatures at the start of a file. Only consulted where the type
#: says nothing (`application/octet-stream`); `video/*` is believed as before.
_MP4_KAESTEN = (b"ftyp", b"styp", b"moov", b"mdat", b"free", b"skip", b"wide", b"sidx")


def _ist_beliebig(mime: str) -> bool:
    return (mime or "").split(";")[0].strip().casefold() == "application/octet-stream"


def _videokopf(start: bytes, address: str) -> bool:
    """Do the first bytes look like a video container?

    MP4/MOV (a box name at 4–8), Matroska/WebM, FLV, AVI, Ogg, and MPEG-TS.
    TS only has its sync byte `0x47` — one random byte in 256 has it too — so
    it counts only with a second sync byte 188 further on, or with `.ts` in
    the address.
    """
    if len(start) >= 8 and start[4:8] in _MP4_KAESTEN:
        return True
    if start[:4] in (b"\x1a\x45\xdf\xa3", b"RIFF", b"OggS") or start[:3] == b"FLV":
        return True
    if start[:1] == b"\x47":
        if len(start) > 188:
            return start[188:189] == b"\x47"
        return urlsplit(address).path.casefold().endswith(".ts")
    return False


def _art_aus_typ(mime: str) -> str | None:
    mime = (mime or "").split(";")[0].strip().casefold()
    if mime in _TYPEN:
        return _TYPEN[mime]
    if mime.startswith("video/"):
        return "datei"
    return None


def _probe(
    session: requests.Session,
    address: str,
    headers: dict[str, str],
    check_drm: bool = False,
) -> Find | None:
    """Fetch sixteen bytes and see what comes back.

    **The heart of the whole thing.** `Range: bytes=0-15` is the cheapest proof
    there is: the host has to open the file and name its type, but delivers
    nothing. Whatever answers with `206` or `200` and a media type is a video —
    no matter what the address is called.

    **Why not `HEAD`:** a good many hosts answer it with `405` or with an empty
    content type and deliver flawlessly on `GET`. A HEAD request saves nothing
    and sometimes lies — sixteen bytes do neither.

    With `check_drm`, raises `DrmError` if the find is protected.
    """
    # **The reading belongs inside the net too, and widely.**
    # `answer.raw.read()` goes past `requests` straight to `urllib3`, and its
    # `ReadTimeoutError` is **not** a `requests.RequestException`. A host that
    # accepted the connection and then went silent would otherwise throw the
    # exception right out into `/play` — and instead of a refusal the app got a
    # 500 with HTML in it.
    #
    # A proof that does not answer is a "no" and never a crash.
    try:
        answer = session.get(
            address,
            headers={**headers, "Range": _SPANNE},
            timeout=_ANFRAGEFRIST,
            stream=True,
            allow_redirects=True,
        )
        with answer:
            if answer.status_code not in (200, 206):
                return None
            mime = answer.headers.get("content-type", "")
            start = answer.raw.read(2048, decode_content=True) or b""
    except Exception:  # see above: urllib3 throws in here too
        return None

    kind = _art_aus_typ(mime)
    # **The content outranks the label.** Some hosts serve playlists as
    # `text/plain`, with no type, or as `application/octet-stream` — an HLS
    # list says what it is in its first line.
    if start.lstrip()[:7] == b"#EXTM3U":
        kind = "hls"
    elif not kind:
        return None
    elif _ist_beliebig(mime) and not _videokopf(start, address):
        # **`octet-stream` says nothing — so the bytes have to.** A speed-test
        # endpoint answers 200 with half a megabyte of random bytes as
        # `application/octet-stream`; taken as a film, the television played
        # noise.
        return None

    # **A video is never an HTML page.** Hosts like to answer an expired
    # address with 200 and an error page; without this check it would pass as a
    # find and the television would stay black. With `application/octet-stream`
    # that is not theory: the type says nothing.
    head = start.lstrip()[:64].lower()
    if head.startswith((b"<!doctype", b"<html", b"<?xml")) and kind != "dash":
        return None

    # **A master playlist that carries is not yet a video that carries.** A
    # signed `master.m3u8` can answer 200 while every variant beneath it
    # answers 403 — a sign-in the host wants. The phone then got the rewritten
    # master, a 403 on the first variant, and showed "address expired". One
    # more small request settles it: the first variant has to open too,
    # otherwise this address does not carry.
    if kind == "hls" and not _variante_traegt(session, address, headers):
        return None

    # **Only when asked, not on every probe** — and that is a division of
    # labour, not sloppiness. Whoever takes an address on their own initiative
    # asks "may we take this?"; `probe()` only asks "does it carry?" about an
    # address the portal delivered anyway. Whatever rights management gets
    # through there, the app refuses with a sentence of its own
    # (`Lieferart.Absage.rechteverwaltung`) — it reads the playlist itself and
    # by the same rule. Otherwise the server would load the playlist a second
    # time for **every** HLS title, only to establish something the player
    # establishes two seconds later anyway.
    if check_drm and kind in ("hls", "dash"):
        _rechte_pruefen(session, address, headers, kind)

    # **The address we asked for — not the one we ended up at.** A redirect
    # often leads to an address with a token that is valid briefly and for
    # this one request. Whoever passes it on hands out an address that is
    # already dead on the second grab. The original one, by contrast, produces
    # a fresh redirect on every request, and the relay follows it.
    keep = {k: v for k, v in headers.items() if k.casefold() in ("referer", "user-agent", "origin")}
    return Find(address=address, kind=kind, headers=keep)


def _variante_traegt(session: requests.Session, address: str, headers: dict[str, str]) -> bool:
    """Does the first variant of a master playlist open? Two bytes, like above.

    **The playlist is read whole first** — the probe above honours `Range` on
    hosts that honour it, and then holds sixteen bytes of a list. A media
    playlist (segments, no `#EXT-X-STREAM-INF`) needs no second look.

    Only the first variant: a master with one refused variant has them all
    refused in every case measured so far — the refusal is about the viewer,
    not the file. Unknown on any error, and unknown counts as yes: the probe
    must not turn a slow host into a dead one.
    """
    try:
        answer = session.get(address, headers=headers, timeout=_ANFRAGEFRIST)
        if answer.status_code >= 400:
            return True
        text = answer.text[:65536]
    except Exception:
        return True
    if "#EXT-X-STREAM-INF" not in text:
        return True
    first = next(
        (ln.strip() for ln in text.splitlines() if ln.strip() and not ln.startswith("#")), ""
    )
    if not first:
        return True
    try:
        probe = session.get(
            urljoin(address, first),
            headers={**headers, "Range": "bytes=0-1"},
            timeout=_ANFRAGEFRIST,
            stream=True,
            allow_redirects=True,
        )
        with probe:
            return probe.status_code in (200, 206)
    except Exception:
        return True


def _rechte_pruefen(
    session: requests.Session, address: str, headers: dict[str, str], kind: str
) -> None:
    """Read the playlist itself and look for rights management.

    Playlists only: an `.mp4` carries none, and its first bytes would say
    nothing about it anyway.
    """
    try:
        answer = session.get(address, headers=headers, timeout=_ANFRAGEFRIST)
    except requests.RequestException:
        return
    if answer.status_code >= 400:
        return
    text = answer.text[:200_000]
    if kind == "hls" and _hls_hat_rechte(text):
        raise DrmError("HLS with rights management")
    if kind == "dash" and _DASH_RECHTE.search(text):
        raise DrmError("MPEG-DASH with ContentProtection")


def _session(via: str | None) -> requests.Session:
    """A session that leaves through `via` — the portal's proxy for a routed
    portal — or, without one, directly. Every probe in here goes over the
    session, so this is the one place it is set."""
    session = requests.Session()
    if via:
        session.proxies = {"http": via, "https": via}
    return session


def probe(address: str, headers: dict[str, str] | None = None, via: str | None = None) -> bool:
    """Does this address really carry? Sixteen bytes, one answer.

    `via` is the proxy the portal's requests leave through (`routes.proxy_for`):
    the host that answers the portal must be asked the same way.

    Re-raises `DrmError` if the playlist behind it is protected — that is not a
    dead address but one we are not allowed to take, and the difference belongs
    on screen.

    **Where it is not needed:** where the server opens a real stream straight
    away anyway (`stream/buffer.py`) — its first grab is the better proof, it
    fetches bytes that are actually used.
    """
    if not address:
        return False
    head = {"User-Agent": _UA, **(headers or {})}
    try:
        with _session(via) as session:
            return _probe(session, address, head) is not None
    except DrmError:
        raise
    except Exception:  # a probe must never be the reason
        # **A timeout is a no** — `_probe` catches that itself and returns
        # `None`. What lands here is only what was never foreseen: a broken
        # address, a fault in the probe itself. About those it knows nothing
        # about the address, and then the portal's word counts.
        return True
