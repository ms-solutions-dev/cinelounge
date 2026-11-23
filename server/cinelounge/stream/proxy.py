"""The relay — the stream passes through the server for devices that cannot fetch it.

**Why there is a relay at all.** The obvious design hands the television the
host's address and steps aside. In practice an address the server resolved is
not always one the television can fetch:

- **IPv6.** Some hosts refuse IPv6 requests. The container usually has no IPv6
  and gets through; the television has it, prefers it, and gets a `403` for the
  same address in the same second. It cannot fall back to IPv4 by itself — an
  IP address instead of the name would bring the certificate down.
- **Headers a redirect does not carry.** A host that wants a `Referer` or a
  particular `User-Agent` answers the television's bare request with a refusal.
  A `302` cannot hand those headers along; the relay sends them itself.
- **Addresses only the server can reach.** A stream that exists only inside the
  container, or a playlist kept in memory (`register_scheme`), means nothing to
  the television.

**It holds for all portals**, and not per entry in the `portal.yml`. A list of
exceptions cannot be maintained: it only ever grows once something has already
gone wrong in the living room.

**Why it must not be a guess and cannot be a measurement either:** the server
does not see what the television sees. In the IPv6 case the container gets 200
and the television 403 — same address, same second. A probe from here would
therefore declare healthy exactly the case this module was built for.

What it costs deserves to be said plainly: for hosts the television could
reach directly, the detour is bandwidth spent on the home network.
"""

from __future__ import annotations

import re
import threading
from collections.abc import Callable, Iterator
from typing import Final
from urllib.parse import quote, urlsplit, urlunsplit

import requests

# What the television may send and what has to come back. Everything else stays
# outside: a relay that passes headers on indiscriminately tells the host more
# about the home network than it needs to know.
_HIN = ("range", "accept", "accept-encoding", "icy-metadata")
_ZURUECK = (
    "content-type",
    "content-length",
    "content-range",
    "accept-ranges",
    "cache-control",
    "etag",
    "last-modified",
)

# Addresses that may be relayed, together with the headers the host expects.
# **Without this list `/stream` would be an open forwarder** for every address
# in the world — an unnecessary gift inside one's own network. Only what `/play`
# resolved itself gets entered.
_ERLAUBT: dict[str, dict[str, str]] = {}
# **The way out, beside the headers.** A routed portal's video leaves the same
# way as its listing — the host answers the page and the segments alike. Keyed
# by host like the headers, and for the same reason: a playlist's segments come
# from the same host as the playlist.
_WEG: dict[str, str] = {}
_SPERRE = threading.Lock()

_IST_LISTE = re.compile(r"mpegurl|x-mpegURL|vnd\.apple", re.I)
_IST_LISTE_PFAD = re.compile(r"\.m3u8$", re.I)
# In an m3u8 links stand in two places: as a line of their own and as `URI="…"`
# inside a tag. Both have to be rewritten, otherwise the player fetches the
# audio track around the relay.
_URI_MARKE = re.compile(r'(URI=")([^"]+)(")')

# **Addresses answered from memory.** An extension may produce playlists that
# exist nowhere on the network — assembled, or read from a file inside the
# container, which the television cannot reach. It registers a scheme of its
# own and a reader for it (`register_scheme`); `fetch` and `head_only` then
# answer such an address with the reader's text and rewrite its links like
# those of any other list. The links inside it are ordinary addresses and go
# out as usual, through the way `allow` remembered for the list.
_SCHEMATA: dict[str, Callable[[str], str | None]] = {}

#: Schemes that stay with the network — a reader for them would quietly take
#: over every ordinary address.
_NETZ_SCHEMATA: Final = frozenset({"http", "https", "file", ""})


def register_scheme(scheme: str, reader: Callable[[str], str | None]) -> None:
    """Answer addresses of `scheme` from memory: `reader(address)` returns the
    playlist text, or `None` for an address it does not know.

    Called in an extension's `install`, i.e. in the API process before the
    first fork. A second registration of the same scheme replaces the first —
    an extension that is installed again (tests do that) brings the same
    reader. The reader is called outside every lock of this module and must
    not block.
    """
    scheme = scheme.casefold()
    if scheme in _NETZ_SCHEMATA:
        raise ValueError(f"scheme {scheme!r} belongs to the network")
    _SCHEMATA[scheme] = reader


def is_local(address: str) -> bool:
    """Whether a registered reader answers this address — there is no host to ask."""
    return urlsplit(address).scheme.casefold() in _SCHEMATA


def _local(address: str) -> str | None:
    """The reader's text for this address, `None` if it is no local one or unknown.

    Deliberately outside `_SPERRE`: the reader is an extension's code, and
    whatever lock it takes must never meet ours.
    """
    reader = _SCHEMATA.get(urlsplit(address).scheme.casefold())
    if reader is None:
        return None
    return reader(address)


def allow(address: str, headers: dict[str, str] | None, via: str | None = None) -> None:
    """Clear a resolved address for the relay — and remember its way out."""
    host = urlsplit(address).netloc
    if not host:
        return
    with _SPERRE:
        _ERLAUBT[host] = dict(headers or {})
        if via:
            _WEG[host] = via
        else:
            _WEG.pop(host, None)


def via_for(address: str) -> str | None:
    with _SPERRE:
        return _WEG.get(urlsplit(address).netloc)


def _proxies(address: str) -> dict[str, str] | None:
    via = via_for(address)
    return {"http": via, "https": via} if via else None


def is_allowed(address: str) -> bool:
    with _SPERRE:
        return urlsplit(address).netloc in _ERLAUBT


def headers_for(address: str) -> dict[str, str]:
    with _SPERRE:
        return dict(_ERLAUBT.get(urlsplit(address).netloc, {}))


def own_address(address: str, base: str, origin: dict[str, str] | None = None) -> str:
    """The address under which the television fetches this stream.

    ``origin`` (portal and source) is passed along only where the address can
    expire — with a proxy inside the container. That lets ``/stream`` resolve
    anew instead of knocking on a dead door.

    **Path and parameters are English**, like the whole HTTP surface. They were
    not for one run during the rebuild on 10.09.2026 — `/play` kept returning
    `/strom?adresse=`, and the HEAD request in the browser pass came back
    **404**. On the server everything was green: the address is built here, and
    here nobody had followed through.
    """
    parts = [f"address={quote(address, safe='')}"]
    for name, value in (origin or {}).items():
        if value:
            parts.append(f"{name}={quote(value, safe='')}")
    return f"{base}/stream?" + "&".join(parts)


def rewrite(text: str, address: str, base: str) -> str:
    """Bend every link in a playlist onto the relay.

    **Without this the relay is worth nothing.** Many playlists point at their
    segments with root-relative paths (`/hls/…`).
    If the television fetches the list from the server, it resolves `/hls/…`
    against the **server** — which does not know the path. Without rewriting,
    the list would arrive and not a single segment.
    """
    parts = urlsplit(address)
    root = urlunsplit((parts.scheme, parts.netloc, "", "", ""))
    folder = root + parts.path.rsplit("/", 1)[0] + "/"

    def full(link: str) -> str:
        link = link.strip()
        if link.startswith(("http://", "https://")):
            target = link
        elif link.startswith("//"):
            target = parts.scheme + ":" + link
        elif link.startswith("/"):
            target = root + link
        else:
            target = folder + link
        allow(target, headers_for(address), via_for(address))
        return own_address(target, base)

    rows = []
    for line in text.splitlines():
        trimmed = line.strip()
        if not trimmed:
            rows.append(line)
        elif trimmed.startswith("#"):
            rows.append(_URI_MARKE.sub(lambda m: m.group(1) + full(m.group(2)) + m.group(3), line))
        else:
            rows.append(full(trimmed))
    return "\n".join(rows) + "\n"


def head_only(address: str) -> tuple[int, dict[str, str]]:
    """What a HEAD request has to answer — length, kind, and whether seeking is allowed.

    **Why this function exists** (measured 29.08.): `/stream` only knew GET, and
    a HEAD request got a 405. The per-portal pass therefore failed for **all**
    portals, including those that carried before — and a player begins with
    exactly that request. A relay without HEAD is no relay.

    Two ways, because not every host answers HEAD: HEAD first, and if that is
    refused, a one-byte grab. In its `Content-Range` the total length stands in
    the last field — that is the piece of information at stake.
    """
    if _local(address) is not None:
        return 200, {"Content-Type": "application/vnd.apple.mpegurl"}
    head = headers_for(address)
    answer = requests.head(
        address,
        headers=head,
        timeout=_geduld(address),
        allow_redirects=True,
        proxies=_proxies(address),
    )
    if answer.status_code < 400:
        back = {name: value for name, value in answer.headers.items() if name.lower() in _ZURUECK}
        return answer.status_code, back

    answer = requests.get(
        address,
        headers=dict(head, Range="bytes=0-0"),
        stream=True,
        timeout=_geduld(address),
        proxies=_proxies(address),
    )
    back = {name: value for name, value in answer.headers.items() if name.lower() in _ZURUECK}
    range_ = back.pop("Content-Range", None) or back.pop("content-range", None)
    if range_ and "/" in range_:
        whole = range_.rsplit("/", 1)[1].strip()
        if whole.isdigit():
            back["Content-Length"] = whole
    else:
        back.pop("Content-Length", None)
    answer.close()
    progress = 200 if answer.status_code in (200, 206) else answer.status_code
    return progress, back


# How long the first byte is waited for. **Two values, and the reason is
# measured:** a proxy inside the container answers in milliseconds or not at all
# — it runs on the same machine. When it hangs, waiting never helped; on 29.08.
# that is why 21.1 s of timeout stood in the diagnosis, and the viewer called it
# "forever". A host out on the network may take longer.
_GEDULD_HIER = 4
_GEDULD_DRAUSSEN = 20


def _geduld(address: str) -> int:
    here = urlsplit(address).hostname in ("127.0.0.1", "localhost", "::1")
    return _GEDULD_HIER if here else _GEDULD_DRAUSSEN


def fetch(
    address: str, range_: str | None, base: str
) -> tuple[int, dict[str, str], bytes | Iterator[bytes], bool]:
    """Fetch the stream and pass it on.

    A playlist is read whole and rewritten — it is a few kilobytes. Everything
    else flows through in chunks, so that neither the container's memory nor the
    player's patience is strained; `Range` travels in both directions, otherwise
    seeking would be impossible.
    """
    local = _local(address)
    if local is not None:
        text = rewrite(local, address, base)
        return 200, {"Content-Type": "application/vnd.apple.mpegurl"}, text.encode("utf-8"), True

    head = headers_for(address)
    if range_:
        head["Range"] = range_

    answer = requests.get(
        address, headers=head, stream=True, timeout=_geduld(address), proxies=_proxies(address)
    )
    back = {name: value for name, value in answer.headers.items() if name.lower() in _ZURUECK}

    # By content type — or by the path, for hosts that call everything
    # `application/octet-stream`. A list
    # that slips through here unrewritten reaches the player with relative
    # segment paths, and those resolve against this server: 404.
    if _IST_LISTE.search(answer.headers.get("Content-Type", "")) or _IST_LISTE_PFAD.search(
        urlsplit(address).path
    ):
        text = rewrite(answer.text, address, base)
        answer.close()
        back.pop("Content-Length", None)
        return answer.status_code, back, text.encode("utf-8"), True

    def chunks() -> Iterator[bytes]:
        try:
            for chunk in answer.iter_content(chunk_size=64 * 1024):
                if chunk:
                    yield chunk
        finally:
            answer.close()

    return answer.status_code, back, chunks(), False
