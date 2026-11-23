"""ZDF Mediathek — a portal of kind `native`.

**The example the SDK proves itself on.** Six methods, no adapter, no stand-ins, no
knowledge of the server. Whoever writes a portal of their own can copy this file
and swap the addresses.

Legally the simplest case in the whole area: a public-service media library, an
open interface, no sign-in, no resolver.

## How the interface works (measured 10.09.2026)

The access token stands **in the page itself** and expires::

    \\"appToken\\":{\\"apiToken\\":\\"aa3noh…\\",\\"expiresAt\\":\\"2026-09-11T18:17+02:00\\"}

There are **two** tokens, and they are not interchangeable: `appToken` for
search and content, `videoToken` for the stream lookup (`ptmd`). Mixing them up
gets you a 403 at one spot while everything else carries.

    /search/documents?q=…&contentTypes=episode      → hits
    …/mainVideoContent/…/ptmd-template              → template with {playerId}
    /tmd/2/<playerId>/vod/ptmd/…                    → priorityList → streams

**MP4 before HLS.** The answer carries both. `h264_aac_mp4_http_na_na` is a
finished file AVPlayer opens straight away and the buffer can pre-fetch in
blocks; the HLS version would be a second round trip for nothing.
"""

from __future__ import annotations

import json
import re
import time
import urllib.parse
import urllib.request
from typing import Any, ClassVar

from cinelounge.core.contract import Entry, Item, Page, Source, Stream

BASIS = "https://api.zdf.de"
KOPF = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}

# According to `expiresAt` the tokens are valid a good day. An hour is ample
# safety margin and costs one page fetch.
MARKEN_HALTBAR = 3600.0

# What AVPlayer likes best, in this order.
FORMATE = ("h264_aac_mp4_http_na_na", "h264_aac_ts_http_m3u8_http")
GUETE = ("fhd", "hd", "veryhigh", "high", "med", "low")

# How a source id separates its two halves.
#
# **No newline any more.** The first attempt took `\n`, because it occurs in
# neither address and survives URL encoding — both true. What it does not
# survive is everything afterwards: an id with a newline breaks one header into
# two, turns one log line into two, and in an error message it looks like two
# values. That does not show here — it shows wherever somebody passes the id on,
# and that is the app as soon as A2 stands.
#
# `\x1f` would be the character meant for this — but Python counts
# `\x1c`–`\x1f` as `str.isspace()`, so every `.strip()` along the way eats half
# the id. The same fault, quieter.
#
# `|` it became: no whitespace, forbidden in a valid URL under RFC 3986 (where
# it reads `%7C`), and readable in a log rather than invisible.
TRENNER = "|"

# What went out before 11.09.2026. Ids are transient: `progress.key` comes from
# `core.ids.key(portal, title, year)` and not from here, so nothing remembered
# hangs on it. An app still holding an old id across a restart should not grasp
# at nothing all the same.
TRENNER_ALT = "\n"

# The entry points. **No "all shows A–Z"**: under `contentTypes=brand` the
# interface returns, as measured, ARD collection pages rather than the ZDF shows
# — a list that shows something other than what its name says is worse than
# none.
EINSTIEGE: list[tuple[str, str, str]] = [
    ("neu", "Neu in der Mediathek", "🆕"),
    ("doku", "Dokumentation", "🌍"),
    ("krimi", "Krimi", "🔎"),
    ("movie", "Spielfilm", "🎬"),
    ("series", "Serien", "📺"),
    ("wissen", "Wissen", "🔬"),
    ("kinder", "Für Kinder", "🧸"),
    ("suche", "Suche", "🔍"),
]

ABFRAGEN = {
    "neu": "*",
    "doku": "dokumentation",
    "krimi": "krimi",
    "movie": "spielfilm",
    "series": "series",
    "wissen": "wissen terra x",
    "kinder": "kinder",
}


class _Marken:
    """The two access tokens, remembered until they grow old."""

    def __init__(self) -> None:
        self._bis = 0.0
        self._app = ""
        self._video = ""

    def _holen(self) -> None:
        r = urllib.request.Request("https://www.zdf.de/", headers=KOPF)
        with urllib.request.urlopen(r, timeout=25) as a:
            page = a.read().decode("utf-8", "replace")
        found = dict(re.findall(r'\\"(\w+Token)\\":\{\\"apiToken\\":\\"([A-Za-z0-9]+)\\"', page))
        if "appToken" not in found or "videoToken" not in found:
            raise RuntimeError("ZDF: kein Zugangsschluessel in der Seite gefunden")
        self._app = found["appToken"]
        self._video = found["videoToken"]
        self._bis = time.time() + MARKEN_HALTBAR

    def app(self) -> str:
        if time.time() > self._bis:
            self._holen()
        return self._app

    def video(self) -> str:
        if time.time() > self._bis:
            self._holen()
        return self._video


_MARKEN = _Marken()


def _hol(path: str, token: str) -> dict[str, Any]:
    r = urllib.request.Request(BASIS + path, headers=dict(KOPF, **{"Api-Auth": "Bearer " + token}))
    with urllib.request.urlopen(r, timeout=30) as a:
        return json.loads(a.read().decode("utf-8", "replace"))  # type: ignore[no-any-return]


def _bild(target: dict[str, Any]) -> str | None:
    """The largest image on offer."""
    bilder = ((target.get("teaserImageRef") or {}).get("layouts")) or {}
    for key in ("1920x1080", "1280x720", "original", "768x432"):
        if key in bilder:
            return str(bilder[key])
    return next((str(v) for v in bilder.values()), None)


def _als_item(target: dict[str, Any]) -> Item | None:
    title = target.get("teaserHeadline") or target.get("title")
    if not title:
        return None
    mv = (target.get("mainVideoContent") or {}).get("http://zdf.de/rels/target") or {}
    vorlage = mv.get("http://zdf.de/rels/streams/ptmd-template")
    if not vorlage:
        return None
    # **The running time stands in `mainVideoContent`, not in `attributes`, and
    # it is in seconds.** `attributes.duration.value` used to stand here with a
    # division by 60000 — two faults that hid each other: `attributes` is `null`
    # on every item measured, so no number ever arrived, so the wrong unit never
    # showed. `None` stood on every tile.
    #
    # Measured 11.09.2026 across ten items from both broadcasters: 472 to 5313,
    # read as seconds 7.9 to 88.5 minutes. As milliseconds they would have been
    # fractions of a minute.
    duration = mv.get("duration")
    year = None
    datum = target.get("editorialDate") or ""
    if len(datum) >= 4 and datum[:4].isdigit():
        year = int(datum[:4])
    return Item(
        title=str(title),
        # The address **is** the template: it leads to the stream on its own,
        # and a portal is allowed to invent its own addresses.
        address=str(vorlage),
        kind="episode",
        year=year,
        description=target.get("teasertext"),
        image=_bild(target),
        image_source="portal",
        image_wide=True,
        duration_min=round(duration / 60) if duration else None,
        has_children=False,
    )


def _suchen(frage: str, limit: int = 40, page: int = 1) -> tuple[list[Item], str | None]:
    path = "/search/documents?" + urllib.parse.urlencode(
        {
            "q": frage,
            "limit": limit,
            "page": page,
            "contentTypes": "episode",
            # **`relevance` and not `date`.** `date` used to stand here,
            # carried over from browsing the categories — there "the newest
            # first" is right, in a search it is the difference between a hit
            # list and a news bulletin.
            #
            # Measured 11.09.2026 in the container, eight hits per run:
            #
            #     sortBy=date       "krimireihe" → 1 of 8 with the word in the title
            #     sortBy=relevance  "krimireihe" → 8 of 8
            #
            # With `date`, "Regionalmagazin West" stood in position 8 and "Krimireihe:
            # Das Haus am Kanal" was not in the list at all.
            "sortBy": "relevance",
            "sortOrder": "desc",
        }
    )
    d = _hol(path, _MARKEN.app())
    hits = d.get("http://zdf.de/rels/search/results") or []
    items = []
    for t in hits:
        i = _als_item(t.get("http://zdf.de/rels/target") or {})
        if i:
            items.append(i)
    next_page = str(page + 1) if d.get("next") else None
    return items, next_page


class Portal:
    """The contract's six methods. A portal needs no more."""

    id = "zdf"
    name = "ZDF Mediathek"
    capabilities: ClassVar[set[str]] = {"search", "subtitles", "own_images", "paging"}

    def menu(self) -> list[Entry]:
        return [
            Entry(id=k, name=n, icon=z, group="curated" if k != "suche" else "library")
            for k, n, z in EINSTIEGE
        ]

    def listing(self, entry: str, next_page: str | None = None, user_input: str = "") -> Page:
        if entry == "suche":
            if not user_input:
                # **No screen, no keyboard.** The server says what was asked
                # for; the app asks the viewer and calls the same level again —
                # this time with an answer.
                return Page(items=[], needs_input="Suche in der ZDF Mediathek")
            items, naechste = _suchen(user_input, page=int(next_page or 1))
            return Page(items=items, next_page=naechste)

        frage = ABFRAGEN.get(entry)
        if frage is None:
            return Page(items=[], note="unbekannter Einstieg: " + entry)
        items, naechste = _suchen(frage, page=int(next_page or 1))
        return Page(items=items, next_page=naechste)

    def children(self, item: Item) -> list[Item]:
        """The media library is flat: an episode has nothing beneath it."""
        return []

    def sources(self, item: Item) -> list[Source]:
        """One source per quality — the choice stays, the order is fixed."""
        p = _hol(item.address.replace("{playerId}", "android_native_5"), _MARKEN.video())
        found: list[Source] = []
        for pl in p.get("priorityList") or []:
            for fo in pl.get("formitaeten") or []:
                if fo.get("type") not in FORMATE:
                    continue
                for q in fo.get("qualities") or []:
                    spuren = ((q.get("audio") or {}).get("tracks")) or []
                    if not spuren:
                        continue
                    found.append(
                        Source(
                            # **The id carries both: template and address.**
                            # `resolve()` gets only this one string from the
                            # server — without the template it would never reach
                            # the subtitles in the same answer again. The
                            # contract expressly allows this: what stands in an
                            # id is interpreted only by the portal that made it —
                            # exactly as with a page's continuation marker.
                            id=item.address + TRENNER + str(spuren[0]["uri"]),
                            name=str(q.get("quality") or "?").upper(),
                            address=str(spuren[0]["uri"]),
                        )
                    )
        found.sort(key=lambda q: GUETE.index(q.name.lower()) if q.name.lower() in GUETE else 99)
        return found

    def resolve(self, source: Source) -> Stream:
        """The media library hands out the video address ready-made.

        There is nothing to resolve — which is why `resolver` is not among the
        capabilities either: a source button would be a choice without options.

        **What does happen here are the subtitles.** `Stream.subtitles` has
        stood in the contract from the start and was never filled by any portal.
        The public broadcasters deliver them throughout as WebVTT, freely — it
        costs one request that `sources()` has already made anyway.
        """
        trenner = TRENNER if TRENNER in source.id else TRENNER_ALT
        vorlage, _, address = source.id.partition(trenner)
        if not address:
            vorlage, address = "", source.id

        subtitles: list[dict[str, Any]] = []
        if vorlage:
            try:
                p = _hol(vorlage.replace("{playerId}", "android_native_5"), _MARKEN.video())
                for c in p.get("captions") or []:
                    # WebVTT only: AVPlayer opens it, EBU-TT-D it does not.
                    if c.get("format") == "webvtt" and c.get("uri"):
                        subtitles.append(
                            {
                                # **English, like every surface strangers
                                # touch.** `sprache`/`art`/`adresse` used to
                                # stand here — a leftover from before the
                                # rename that only survived because the field
                                # never reached the app. As soon as it builds
                                # on it (A2), this becomes a migration across
                                # two repos; the same arithmetic as with the
                                # source id (R1).
                                #
                                # `format` and not `kind`: in the same object
                                # `kind` already means `file|hls|dash` — two
                                # meanings under one name are the trap of
                                # `modul` beside `module`.
                                "language": c.get("language") or "deu",
                                "format": "vtt",
                                "address": str(c["uri"]),
                            }
                        )
            except Exception:
                # The film runs without subtitles all the same. A failure here
                # must not prevent playback.
                pass

        return Stream(
            address=address,
            kind="hls" if ".m3u8" in address else "file",
            resolved=True,
            resolution=source.name or None,
            subtitles=subtitles,
        )

    def search(self, text: str) -> list[Item]:
        items, _ = _suchen(text, limit=30)
        return items

    def series(self, address: str) -> str | None:
        """An item belongs to no series with a language choice of its own."""
        return None
