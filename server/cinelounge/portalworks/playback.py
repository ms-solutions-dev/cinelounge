"""From an item to an address a player can open.

**Why this lives here and not in `web` or `stream`.** The chain needs both: the
runner that asks a portal (`portalworks`) and the relay that serves the stream
(`stream`). The layer contract does not let `stream` reach into `portalworks` —
so the layer above orchestrates, and that is this one.

The order:

    fetch sources → order by language preference → resolve one after another
    → buffer a file in blocks, or probe the address → the next source if not

**What comes out is a code, not a sentence.** A refusal is an `f.Error` with a
code and values; the app turns it into a sentence in the viewer's language.

## Playback policies

The steps of the chain are methods of `PlaybackPolicy`. An extension can
register a subclass per portal kind (`register_policy`) and change single
steps — order the sources by what carried lately, keep a source ready before
it is asked for, try a last way when no source carried. Every portal without a
registered policy plays with `PlaybackPolicy()` itself.

The policy's methods run in the API process, on the request's thread. They are
never called while a lock of this module is held.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from typing import Any
from urllib.parse import urlsplit

from cinelounge.core import errors as f
from cinelounge.portalworks import extension, routes
from cinelounge.portalworks.manifest import Manifest
from cinelounge.portalworks.runner import call as runner
from cinelounge.portalworks.runner.fork import Limits
from cinelounge.stream import buffer, probe, proxy

__all__ = [
    "PlaybackPolicy",
    "answer",
    "complete_kind",
    "is_resolved",
    "policy_for",
    "prepare",
    "register_policy",
    "resolve_again",
    "resolve_play",
    "sources",
]

_LOG = logging.getLogger("cinelounge.playback")

# How long a resolved address stays valid.
#
# **Not a speed trick but a necessity:** AVPlayer fetches an address twice —
# a HEAD request first, then the real one. Resolving afresh each time burns
# one-shot tokens and yields a dead link on the second attempt. That looks like
# a broken source and is not one.
TTL_S = 300.0

_GEMERKT: dict[str, tuple[float, dict[str, Any]]] = {}


def _gemerkt(token: str) -> dict[str, Any] | None:
    item = _GEMERKT.get(token)
    if not item:
        return None
    until, stream = item
    if until < time.time():
        del _GEMERKT[token]
        return None
    return stream


def _merken(token: str, stream: dict[str, Any], until: float | None = None) -> None:
    endet = until or (time.time() + TTL_S)
    stream["valid_until"] = endet
    _GEMERKT[token] = (endet, stream)
    if len(_GEMERKT) > 500:
        now = time.time()
        for k in [k for k, (b, _) in _GEMERKT.items() if b < now]:
            _GEMERKT.pop(k, None)


def is_resolved(m: Manifest, source: str) -> bool:
    """Whether this source has a resolved address that is still valid."""
    return _gemerkt(m.id + "|" + source) is not None


# How long a list of sources stays (AP63, 01.10.2026).
#
# **The app asks twice within seconds.** It fetches `/sources` to pick a source
# and calls `/play` right after — and `resolve_play` fetched the very same
# page a second time, about a second each. Two minutes is long enough for that
# pair and short enough that a new source on the page shows up.
QUELLEN_TTL_S = 120.0

_QUELLEN: dict[str, tuple[float, list[dict[str, Any]]]] = {}


# ── The policy ───────────────────────────────────────────────────────────────


class PlaybackPolicy:
    """How a portal's items become playable addresses — step by step.

    Every method is one step of `sources`, `resolve_play` or `resolve_again`,
    called in the order they are listed here. The base class is the complete
    behaviour; a subclass overrides single steps and calls `super()` where it
    only adds to them.
    """

    def sources(
        self, m: Manifest, address: str, title: str, limits: Limits | None
    ) -> list[dict[str, Any]]:
        """Fetch the item's sources from the portal (cached by `sources()`)."""
        return list(runner.call(m, "sources", {"address": address, "title": title}, limits) or [])

    def after_sources(
        self, m: Manifest, address: str, found: list[dict[str, Any]], limits: Limits | None
    ) -> None:
        """A fresh list of sources arrived — not called for a cached one."""

    def arrange(self, m: Manifest, found: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """The order the sources go out in — the app takes the first one."""
        return found

    def prepare(self, m: Manifest, found: list[dict[str, Any]], limits: Limits | None) -> None:
        """The list went out to the app, which usually plays a source right after.

        A policy may start getting that source ready; `prepared` hands the
        result over. Must return at once.
        """

    def before_play(self, m: Manifest) -> None:
        """Before anything is resolved. May raise an `f.Error` to refuse."""

    def order(
        self, m: Manifest, candidates: list[dict[str, Any]], language: str
    ) -> list[dict[str, Any]]:
        """Move the sources in `language` to the front.

        **Move to the front, do not filter out.** A season is rarely complete
        in both languages; strict filtering leaves you stuck at the first
        episode without a matching source.
        """
        matching = [k for k in candidates if (k.get("language") or "") == language]
        if not matching:
            return candidates
        return matching + [k for k in candidates if k not in matching]

    def prepared(self, m: Manifest, source_id: str) -> dict[str, Any] | None:
        """A resolution made ahead of time for this source, or `None`."""
        return None

    def on_failure(self, m: Manifest, candidate: dict[str, Any], err: f.Error) -> None:
        """Resolving a source failed. Raising here ends the chain with that error."""

    def normalize(self, m: Manifest, stream: dict[str, Any]) -> dict[str, Any]:
        """The resolved stream, made fit for delivery. Unchanged by default."""
        return stream

    def route(self, m: Manifest, address: str) -> str | None:
        """The proxy an address of this portal is fetched through."""
        return routes.proxy_for(m)

    def deliver(
        self,
        m: Manifest,
        candidate: dict[str, Any],
        stream: dict[str, Any],
        failed: list[dict[str, Any]],
    ) -> dict[str, Any] | None:
        """Buffer, relay or probe — how the stream goes out.

        Returns the answer, or `None` after adding the reason to `failed`.
        """
        complete_kind(stream)
        address = stream["address"]
        head = stream.get("headers") or {}
        via = self.route(m, address)
        proven = False
        buffer_token = ""

        if stream.get("kind", "file") == "file":
            # Pull files ahead in blocks: file servers often cap each connection,
            # and four connections are four times as fast.
            buffer_token = buffer.key_for(m.id, candidate["id"])
            if buffer.begin_chunked(buffer_token, address, head, via):
                proven = True
            else:
                buffer_token = ""

        if proxy.is_local(address):
            # Answered from memory (`proxy.register_scheme`) — there is no host
            # to probe. The links inside it get their probe from the player.
            proven = True

        if not proven and not probe.probe(address, head, via):
            # **The probe.** A dead source is no rarity: a portal lists four,
            # one of them is dead. Without this, the television is the first
            # to notice — blocks later, into a picture that is already up.
            failed.append({"host": candidate.get("name") or "?", "code": f.STREAM_HOST_EMPTY})
            return None

        proxy.allow(address, head, via)
        return answer(m, candidate, stream, buffer_token)

    def on_outcome(self, m: Manifest, candidate: dict[str, Any], ok: bool) -> None:
        """A source was tried to the end: it carried (`ok`) or it did not."""

    def last_resort(
        self,
        m: Manifest,
        tried: list[dict[str, Any]],
        unresolved: list[tuple[dict[str, Any], str]],
        failed: list[dict[str, Any]],
    ) -> dict[str, Any] | None:
        """No source carried. A last way, or `None` for `stream.no_host`.

        `tried` are the sources tried, in order; `unresolved` pairs each source
        that came back without a video (`resolved: false`) with the address it
        named instead. An answer comes from `deliver`.
        """
        return None

    def again(self, m: Manifest, source: str, limits: Limits | None) -> str | None:
        """Resolve one source once more, for the relay's second attempt."""
        try:
            stream = runner.call(m, "resolve", {"source": source}, limits)
        except f.Error:
            return None
        if not stream.get("resolved") or not stream.get("address"):
            return None
        stream = self.normalize(m, stream)
        address = str(stream["address"])
        proxy.allow(address, stream.get("headers") or {}, self.route(m, address))
        _merken(
            m.id + "|" + source,
            {
                "address": stream["address"],
                "kind": stream.get("kind", "file"),
                "headers": {},
                "proxied": True,
                "buffer": None,
                "portal": m.id,
                "source": source,
                "language": "",
            },
            stream.get("valid_until"),
        )
        return str(stream["address"])


_STANDARD = PlaybackPolicy()


def register_policy(kind: str, policy: PlaybackPolicy) -> None:
    """Play portals of `kind` with `policy`. In an extension's `install` only."""
    extension.register_policy(kind, policy)


def policy_for(m: Manifest) -> PlaybackPolicy:
    found = extension.policy(str(getattr(m, "kind", "") or ""))
    return found if isinstance(found, PlaybackPolicy) else _STANDARD


# ── Building the answer ──────────────────────────────────────────────────────


def complete_kind(stream: dict[str, Any]) -> None:
    """**The kind from the address when the portal names none.**

    A `master.m3u8` without `kind` counted as a file, went into the buffer,
    and reached the player unrewritten (16.09.2026). `hls` keeps it out of the
    buffer and tells the app what it is.
    """
    if stream.get("kind", "file") == "file":
        path = urlsplit(stream["address"]).path.lower()
        if path.endswith(".m3u8"):
            stream["kind"] = "hls"
        elif path.endswith(".mpd"):
            stream["kind"] = "dash"


def answer(
    m: Manifest, candidate: dict[str, Any], stream: dict[str, Any], buffer_token: str
) -> dict[str, Any]:
    """The `/play` answer for a delivered stream — field by field, on purpose."""
    return {
        "address": stream["address"],
        "kind": stream.get("kind", "file"),
        "headers": {},
        "proxied": True,
        "buffer": buffer_token or None,
        "portal": m.id,
        "source": candidate["id"],
        "language": candidate.get("language") or "",
        "resolve_ms": stream.get("resolve_ms"),
        # **Die Untertitel fielen hier auf den Boden.**
        #
        # `Stream.untertitel` steht im Vertrag seit dem Anfang; `INHALTE.md`
        # nennt sie „die billigste sichtbare Verbesserung im ganzen Projekt".
        # Das ZDF-Portal fuellt sie seit dem 10.09.2026 und zahlt dafuer einen
        # zusaetzlichen HTTP-Abruf je Wiedergabe — und diese Funktion baute
        # ihre Antwort Feld fuer Feld auf, ohne sie. Gemessen kam bei der App
        # nie eine einzige an.
        "subtitles": list(stream.get("subtitles") or []),
    }


# ── The chain ────────────────────────────────────────────────────────────────


def sources(
    m: Manifest, address: str, title: str = "", limits: Limits | None = None
) -> list[dict[str, Any]]:
    policy = policy_for(m)
    key = m.id + "|" + address
    item = _QUELLEN.get(key)
    if item and item[0] > time.time():
        return policy.arrange(m, [dict(k) for k in item[1]])
    found = policy.sources(m, address, title, limits)
    _QUELLEN[key] = (time.time() + QUELLEN_TTL_S, [dict(k) for k in found])
    policy.after_sources(m, address, found, limits)
    if len(_QUELLEN) > 200:
        now = time.time()
        for k in [k for k, (b, _) in _QUELLEN.items() if b < now]:
            _QUELLEN.pop(k, None)
    return policy.arrange(m, found)


def prepare(m: Manifest, found: list[dict[str, Any]], limits: Limits | None = None) -> None:
    """`/sources` answered — the policy may get the likely choice ready."""
    policy_for(m).prepare(m, found, limits)


def resolve_play(
    m: Manifest,
    *,
    address: str = "",
    source: str = "",
    language: str | Callable[[], str] = "",
    limits: Limits | None = None,
) -> dict[str, Any]:
    """The address the television can really fetch.

    Returns a dictionary with `address`, `kind`, `headers`, `proxied` and
    `valid_until`. Raises `core.errors.Error` with a code, never with a
    sentence.
    """
    policy = policy_for(m)
    token = m.id + "|" + (source or address)
    cached = _gemerkt(token)
    if cached:
        return dict(cached, cached=True)
    policy.before_play(m)

    if source and not address:
        candidates = [{"id": source, "name": "", "address": "", "language": None}]
    elif address:
        candidates = [k for k in sources(m, address, limits=limits) if not k.get("blocked")]
        # **The language only orders the fallback** (AP63): with a chosen source it is
        # asked for once that one has failed — it costs a fork of its own.
        if not source and callable(language):
            language = language()
        if language and not callable(language):
            candidates = policy.order(m, candidates, language)
        if source:
            # **The chosen one first, the others behind it — not instead of
            # them.** Until 16.09.2026 a chosen source was the only candidate:
            # the phone picks the first source of the list, and when that one
            # does not carry (403 on every variant), the answer was
            # `stream.no_host` with seven working sources beside it. The app
            # has no way back from there; the server has. `switched` in the
            # answer says when it took a different one.
            chosen = [k for k in candidates if k.get("id") == source]
            rest = [k for k in candidates if k.get("id") != source]
            candidates = (
                chosen or [{"id": source, "name": "", "address": "", "language": None}]
            ) + rest
    else:
        raise f.Error("play.no_target", status=422)

    if not candidates:
        raise f.Error(f.STREAM_NO_HOST, {"tried": 0}, status=404)

    failed: list[dict[str, Any]] = []
    tried: list[dict[str, Any]] = []
    unresolved: list[tuple[dict[str, Any], str]] = []

    index = -1
    while index + 1 < len(candidates):
        index += 1
        if index == 1 and source and callable(language):
            # The chosen one did not carry; now the order of the rest matters.
            sprache = language()
            if sprache:
                candidates[1:] = policy.order(m, candidates[1:], sprache)
        k = candidates[index]
        tried.append(k)
        try:
            stream = policy.prepared(m, str(k["id"])) or runner.call(
                m, "resolve", {"source": k["id"]}, limits
            )
        except f.Error as err:
            # DRM ends the chain: a second source does not help when the
            # provider dictates the scheme.
            if err.code == f.STREAM_DRM:
                raise
            policy.on_failure(m, k, err)
            # **The reason has to travel out.** A bare `run.crashed` sends
            # the operator searching; what sits behind it is often a setting
            # (a missing API key), not a fault. What the portal said belongs
            # in the answer.
            failed.append(
                {
                    "host": k.get("name") or "?",
                    "code": err.code,
                    "detail": str(err.values.get("text") or err.values.get("why") or "")[:200],
                }
            )
            policy.on_outcome(m, k, False)
            continue

        stream = policy.normalize(m, stream)
        if not stream.get("resolved"):
            # Stay honest: this is a web page, not a video.
            unresolved.append((k, stream["address"]))
            failed.append({"host": k.get("name") or "?", "code": "stream.page_not_video"})
            policy.on_outcome(m, k, False)
            continue

        done = policy.deliver(m, k, stream, failed)
        policy.on_outcome(m, k, bool(done))
        if done:
            done["switched"] = bool(source) and k["id"] != source
            _merken(token, done, stream.get("valid_until"))
            return dict(done, cached=False)

    done = policy.last_resort(m, tried, unresolved, failed)
    if done:
        _merken(token, done)
        return dict(done, cached=False, fallback=True)

    raise f.Error(f.STREAM_NO_HOST, {"tried": len(candidates), "failures": failed}, status=502)


def resolve_again(m: Manifest, source: str, limits: Limits | None = None) -> str | None:
    """Resolve the same source once more — for the relay's second attempt.

    Some addresses live only seconds: a token that expires, a stream that
    exists only for one resolution. When the relay cannot open one any more,
    it asks for a fresh one here instead of giving up.
    """
    return policy_for(m).again(m, source, limits)
