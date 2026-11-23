"""3sat — the same interface as ZDF, different in three places.

**This is deliberately a copy of `zdf/portal.py` and not a shared library.**
The reason stands in `docs/SDK.md`: a portal is a folder with two files that
travels into a stranger's household as a single archive. A module shared between
two portal folders would turn two portals into one package — and the marketplace
could not install the one without the other.

The duplication is the price for that. What differs therefore stands in full up
here, so that nobody has to compare the files line by line.

## The three differences (measured 11.09.2026)

**1. One token instead of two.** ZDF keeps `appToken` for content and
`videoToken` for the stream lookup; mixing them up gets you a 403. 3sat makes do
with one — the same one opens search *and* `ptmd`. Verified with both tokens
found in the page against both endpoints.

**2. A different pattern in the page.** The ZDF page runs on a newer frontend
and carries the token as escaped JSON::

    \\"appToken\\":{\\"apiToken\\":\\"aa3noh…\\"}

3sat is still on the older version and writes it unnested::

    apiToken: '22918a9c7a733c027addbcc7d065d4349d375825',

Forty hex characters, single quotes, no `expiresAt` beside it.

**3. Different entry points.** Not guessed but tried out. Of fourteen search
terms these nine came back with at least twenty playable hits; `krimi` and
`kinder` — load-bearing entries at ZDF — delivered too little at 3sat to justify
a row.

## What is the same

The rest. `/search/documents`, `ptmd-template`, `priorityList`, the quality
order, the subtitles as WebVTT. Measured: three of nine items carry them, all in
German — enough that `subtitles` is not an empty promise.
"""

from __future__ import annotations

import json
import re
import time
import urllib.parse
import urllib.request
from typing import Any, ClassVar

from cinelounge.core.contract import Entry, Item, Page, Source, Stream

BASIS = "https://api.3sat.de"
SEITE = "https://www.3sat.de/"
KOPF = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}

#: How long the token is remembered.
#:
#: Unlike at ZDF there is no `expiresAt` beside it to read that off. One hour is
#: the assumption, and at worst it costs one page fetch — considerably less than
#: a 403 in the middle of a film.
MARKEN_HALTBAR = 3600.0

#: How the token stands in the page. Measured, not assumed.
MARKEN_MUSTER = re.compile(r"""apiToken['"]?\s*:\s*['"]([0-9a-f]{40})['"]""")

# What AVPlayer likes best, in this order. `vp9_opus_webm` stands in the answer
# too and is deliberately missing here: AVPlayer does not open it.
FORMATE = ("h264_aac_mp4_http_na_na", "h264_aac_ts_http_m3u8_http")
GUETE = ("fhd", "hd", "veryhigh", "high", "med", "low")

#: How a source id separates its two halves — as at ZDF.
#:
#: No whitespace, forbidden in a valid URL under RFC 3986, readable in a log
#: rather than invisible. The long reasoning stands in `zdf/portal.py`; it holds
#: here unchanged.
TRENNER = "|"

#: The entry points. **Tried out, not copied.**
#:
#: For each term 24 hits were fetched and counted for how many carry a
#: `ptmd-template` — that is, are really playable:
#:
#: | | playable out of 24 |
#: |---|---|
#: | wissenschaft | 24 |
#: | dokumentation | 23 |
#: | serie | 23 |
#: | musik | 23 |
#: | gesellschaft | 23 |
#: | kultur | 22 |
#: | kunst | 21 |
#: | `*` (new) | 21 |
#: | natur | 20 |
#: | spielfilm | **11** |
#:
#: `spielfilm` is in the list despite the eleven: a broadcaster without a film
#: row looks as if it had none, and eleven of 24 are still eleven films.
EINSTIEGE: list[tuple[str, str, str]] = [
    ("neu", "Neu bei 3sat", "🆕"),
    ("doku", "Dokumentation", "🌍"),
    ("kultur", "Kultur", "🎭"),
    ("wissen", "Wissenschaft", "🔬"),
    ("gesellschaft", "Gesellschaft", "🗣"),
    ("natur", "Natur", "🌿"),
    ("musik", "Musik", "🎵"),
    ("kunst", "Kunst", "🖼"),
    ("movie", "Spielfilm", "🎬"),
    ("series", "Serien", "📺"),
    ("suche", "Suche", "🔍"),
]

ABFRAGEN = {
    "neu": "*",
    "doku": "dokumentation",
    "kultur": "kultur",
    "wissen": "wissenschaft",
    "gesellschaft": "gesellschaft",
    "natur": "natur",
    "musik": "musik",
    "kunst": "kunst",
    "movie": "spielfilm",
    "series": "serie",
}


class _Marke:
    """The one access token, remembered until it grows old.

    **One, not two.** At ZDF `appToken` and `videoToken` are different and not
    interchangeable. At 3sat both tokens found in the page were checked against
    search *and* `ptmd` on 11.09.2026: both open both. So the first one that
    stands there is used here.
    """

    def __init__(self) -> None:
        self._bis = 0.0
        self._wert = ""

    def _holen(self) -> None:
        r = urllib.request.Request(SEITE, headers=KOPF)
        with urllib.request.urlopen(r, timeout=25) as a:
            page = a.read().decode("utf-8", "replace")
        gefunden = MARKEN_MUSTER.findall(page)
        if not gefunden:
            raise RuntimeError("3sat: kein Zugangsschluessel in der Seite gefunden")
        self._wert = gefunden[0]
        self._bis = time.time() + MARKEN_HALTBAR

    def __call__(self) -> str:
        if time.time() > self._bis:
            self._holen()
        return self._wert


_MARKE = _Marke()


def _hol(path: str) -> dict[str, Any]:
    kopf = dict(KOPF, **{"Api-Auth": "Bearer " + _MARKE()})
    r = urllib.request.Request(BASIS + path, headers=kopf)
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
        # Without a template there is no way to the stream. Measured, that
        # affects about one hit in ten — trailers, announcements, expired items.
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
    d = _hol(path)
    hits = d.get("http://zdf.de/rels/search/results") or []
    items = []
    for t in hits:
        i = _als_item(t.get("http://zdf.de/rels/target") or {})
        if i:
            items.append(i)
    next_page = str(page + 1) if d.get("next") else None
    return items, next_page


class Portal:
    """The contract's seven methods. A portal needs no more."""

    id = "3sat"
    name = "3sat"
    #: The same list as in `portal.yml` — the service does not reconcile them.
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
                return Page(items=[], needs_input="Suche bei 3sat")
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
        p = _hol(item.address.replace("{playerId}", "android_native_5"))
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
                            # The id carries both: template and address.
                            # `resolve()` gets only this one string from the
                            # server — without the template it would never reach
                            # the subtitles in the same answer again.
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

        **What does happen here are the subtitles.** Measured, three of nine
        items carry them, as WebVTT in German. It costs one request that
        `sources()` has already made anyway.
        """
        vorlage, _, address = source.id.partition(TRENNER)
        if not address:
            vorlage, address = "", source.id

        subtitles: list[dict[str, Any]] = []
        if vorlage:
            try:
                p = _hol(vorlage.replace("{playerId}", "android_native_5"))
                for c in p.get("captions") or []:
                    # WebVTT only: AVPlayer opens it, EBU-TT-D it does not.
                    if c.get("format") == "webvtt" and c.get("uri"):
                        subtitles.append(
                            {
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
        """An item belongs to no series with a language choice of its own.

        3sat broadcasts in German, and only in German. A central language choice
        would have nothing to choose.
        """
        return None
