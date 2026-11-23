"""arte — the German-French culture channel, without an access key.

**The simplest interface in the whole starter set.** No token, no key scraped
out of a page, no expiry. Two addresses are enough:

    /api/emac/v4/de/web/pages/<CODE>/     the pages and their zones
    /api/player/v2/config/de/<programId>  the stream

Both answer 200 to a bare GET. Measured 11.09.2026; `opa/v3` demands a key and
is not needed here.

## What `INHALTE.md` expected and what came out measured

It says: *"Two language versions per item — really serves `languages`."* The
first half holds, the second does not.

arte delivers **one** stream per item, and the versions sit in it as tracks.
From the manifest of "Zahl mich (wenn du kannst!)"::

    #EXT-X-MEDIA:TYPE=AUDIO,LANGUAGE="de",NAME="Deutsch"
    #EXT-X-MEDIA:TYPE=AUDIO,LANGUAGE="fr",NAME="Französisch"
    #EXT-X-MEDIA:TYPE=AUDIO,LANGUAGE="mul",NAME="Mehrsprachig"
    #EXT-X-MEDIA:TYPE=SUBTITLES,LANGUAGE="pl",NAME="Polnisch"
    …

Eight audio versions, six subtitle tracks, **one URL**. The player makes the
choice, not the server.

That is why `languages` is **not** among the capabilities. Declaring it would
promise the console a language choice that does nothing here — eight buttons
that all deliver the same address. What the versions are stands in
`Item.languages` instead: that is information, not a promise.

For the same reason `subtitles` is missing: the subtitles are tracks in the
manifest, not files beside it. `Stream.subtitles` wants addresses, and AVPlayer
finds the tracks by itself anyway.

## What else stood out

`geoblocking.code` stands at every entry. Three values were measured: `ALL`,
`SAT` (the satellite footprint) and `EUR_DE_FR`. The contract has no field for
it on `Item`, so it stays unused rather than standing somewhere nobody reads.
"""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from typing import Any, ClassVar

from cinelounge.core.contract import Entry, Item, Page, Source, Stream

BASIS = "https://api.arte.tv/api"
KOPF = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}

#: In which language arte delivers its labels.
#:
#: Affects **only** the labels: measured, `config/de/` and `config/fr/` give the
#: same stream URL, only with different names for the versions (`DE`/`FR`
#: against `VA`/`VOF`). The content is the same.
SPRACHE = "de"

#: Which image size the template becomes.
#:
#: `mainImage.url` ends in `__SIZE__`, and the placeholder is not one the server
#: resolves: a request with `__SIZE__` gives 404. Measured, `1920x1080`
#: (269 KB), `1280x720` (147 KB), `940x530` (82 KB) and `400x225` (17 KB) work.
#: 1280 is the tile size at which nothing visible is missing and nobody loads a
#: quarter of a megabyte for a thumbnail.
BILDGROESSE = "1280x720"

#: Entries of these kinds have something beneath them.
KOLLEKTIONEN = frozenset({"TV_SERIES", "TOPIC", "MAGAZINE", "SUBCOLLECTION"})

#: And these are playable.
ABSPIELBAR = frozenset({"SHOW"})

#: The entry points — page codes arte links itself.
#:
#: Not invented: every zone of the front page carries a `link.page`, and those
#: are the codes. Tried out on 11.09.2026, with usable entries per page
#: (`SHOW`, `TV_SERIES`, `TOPIC`, `MAGAZINE` — `EXTERNAL` are web links without
#: video and drop out):
#:
#: | code | page | usable |
#: |---|---|---|
#: | HOME | front page | 219 |
#: | CIN | films | 207 |
#: | SER | series | 162 |
#: | DOR | documentaries and reports | 140 |
#: | SCI | science | 110 |
#: | HIS | history | 81 |
#:
#: `ARS` gives 404 — the code stands nowhere, it was a guess.
EINSTIEGE: list[tuple[str, str, str]] = [
    ("HOME", "Neu auf arte", "🆕"),
    ("CIN", "Filme", "🎬"),
    ("SER", "Serien", "📺"),
    ("DOR", "Dokus und Reportagen", "🌍"),
    ("SCI", "Wissenschaft", "🔬"),
    ("HIS", "Geschichte", "🏛"),
    ("ARTE_CONCERT", "Konzerte", "🎵"),
    ("EMI", "Sendungen", "📚"),
    ("MOST_VIEWED", "Meistgesehen", "🔥"),
    ("suche", "Suche", "🔍"),
]


def _hol(pfad_oder_url: str) -> dict[str, Any]:
    url = pfad_oder_url if pfad_oder_url.startswith("http") else BASIS + pfad_oder_url
    r = urllib.request.Request(url, headers=KOPF)
    with urllib.request.urlopen(r, timeout=30) as a:
        return json.loads(a.read().decode("utf-8", "replace"))  # type: ignore[no-any-return]


def _bild(eintrag: dict[str, Any]) -> str | None:
    url = (eintrag.get("mainImage") or {}).get("url")
    return str(url).replace("__SIZE__", BILDGROESSE) if url else None


def _sprachen(eintrag: dict[str, Any]) -> list[str]:
    """Which versions exist — as information, not as a choice.

    `audioVersions` stands at every playable entry: `[{code: "DE", label:
    "Synchronisation"}, {code: "AD", …}]`. The codes are arte's own (`DE`, `FR`,
    `OV`, `AD`, `STM`, `OmU-POL`), so they come out as they stand — the contract
    prescribes nothing for `Item.languages` and the bridge only displays them.
    """
    return [str(v["code"]) for v in (eintrag.get("audioVersions") or []) if v.get("code")]


def _als_item(e: dict[str, Any]) -> Item | None:
    """A zone entry as a contract object — or `None`.

    Dropped: `EXTERNAL` (web links without video, seven measured on the front
    page) and everything without a `programId` — without one no address leads
    anywhere.
    """
    art = (e.get("kind") or {}).get("code") or ""
    programm = e.get("programId")
    if not programm or (art not in ABSPIELBAR and art not in KOLLEKTIONEN):
        return None

    titel = e.get("title")
    if not titel:
        return None
    unterzeile = e.get("subtitle")
    ist_sammlung = art in KOLLEKTIONEN

    dauer = e.get("duration")
    return Item(
        title=str(titel) + (f" — {unterzeile}" if unterzeile and not ist_sammlung else ""),
        # The kind stands **in** the address. `children()` and `sources()` get
        # only this string and have to infer from it whether a collection is to
        # be unfolded or a stream to be fetched.
        address=("collection/" if ist_sammlung else "show/") + str(programm),
        kind="series" if ist_sammlung else "episode",
        description=e.get("shortDescription"),
        image=_bild(e),
        image_source="portal",
        image_wide=True,
        # Measured in seconds: 2783 for 47 minutes, 3118 for 52.
        duration_min=round(dauer / 60) if dauer else None,
        languages=_sprachen(e),
        has_children=ist_sammlung,
    )


def _aus_zonen(d: dict[str, Any]) -> tuple[list[Item], str | None]:
    """All zones of a page into one list, without duplicates.

    **An arte page is not a list but a shelf.** The films page carries 24 zones
    — "Unsere Empfehlungen", "Neu im Kino", "Meistgesehen" — and the same film
    stands in three of them. For the television view that is one list, and a
    title in it once.

    The continuation marker comes from the **first** zone that has one. That is
    a simplification: with 24 zones there are 24 paginations, and adding them up
    into one would be bookkeeping without benefit — the category pages deliver
    between 81 and 219 entries in one go. Where paging really counts, in the
    search, there is exactly one zone.
    """
    gesehen: set[str] = set()
    heraus: list[Item] = []
    weiter: str | None = None

    for zone in d.get("zones") or []:
        inhalt = zone.get("content") or {}
        for e in inhalt.get("data") or []:
            item = _als_item(e)
            if item is None or item.address in gesehen:
                continue
            gesehen.add(item.address)
            heraus.append(item)
        if weiter is None:
            naechste = ((inhalt.get("pagination") or {}).get("links") or {}).get("next")
            if naechste:
                weiter = str(naechste)

    return heraus, weiter


class Portal:
    """The contract's seven methods."""

    id = "arte"
    name = "arte"
    #: The same list as in `portal.yml`.
    #:
    #: **Without `languages` and without `subtitles`** — see the head of this
    #: file: both sit in the HLS manifest, and the server cannot choose them. A
    #: declared capability that does nothing is a bug report from a stranger.
    capabilities: ClassVar[set[str]] = {"search", "seasons", "paging", "own_images"}

    # ── The entry points ────────────────────────────────────────────────────

    def menu(self) -> list[Entry]:
        return [
            Entry(id=k, name=n, icon=z, group="curated" if k != "suche" else "library")
            for k, n, z in EINSTIEGE
        ]

    def listing(self, entry: str, next_page: str | None = None, user_input: str = "") -> Page:
        # **`next_page` is a complete URL here**, namely the one arte names
        # itself under `pagination.links.next`. The contract expressly allows
        # that: what stands in it is interpreted only by the portal that made
        # it. Here it saves rebuilding the zone UUID.
        if next_page and next_page.startswith("http"):
            d = _hol(next_page)
            items = [i for i in (_als_item(e) for e in d.get("data") or []) if i]
            if not items:
                items, _ = _aus_zonen(d)
            naechste = ((d.get("pagination") or {}).get("links") or {}).get("next")
            return Page(items=items, next_page=str(naechste) if naechste else None)

        if entry == "suche":
            if not user_input:
                return Page(items=[], needs_input="Suche bei arte")
            d = _hol(
                f"/emac/v4/{SPRACHE}/web/pages/SEARCH/?"
                + urllib.parse.urlencode({"query": user_input})
            )
            items, weiter = _aus_zonen(d)
            return Page(items=items, next_page=weiter)

        code = next((k for k, _, _ in EINSTIEGE if k == entry), None)
        if code is None:
            return Page(items=[], note="unbekannter Einstieg: " + entry)

        d = _hol(f"/emac/v4/{SPRACHE}/web/pages/{code}/")
        items, weiter = _aus_zonen(d)
        return Page(items=items, next_page=weiter, total=len(items))

    # ── One level deeper ────────────────────────────────────────────────────

    def children(self, item: Item) -> list[Item]:
        """A collection's episodes.

        `collections/<id>` delivers several zones; the one with the episodes is
        called `collection_videos_<id>`. The first zone
        (`collection_content_<id>`) contains the collection itself — it drops
        out because its address is the same as the parent's and `_aus_zonen()`
        removes duplicates … but not against the parent. Hence explicitly here.
        """
        if not item.address.startswith("collection/"):
            return []
        kennung = item.address.split("/", 1)[1]
        d = _hol(f"/emac/v4/{SPRACHE}/web/collections/{urllib.parse.quote(kennung)}")
        kinder, _ = _aus_zonen(d)
        return [k for k in kinder if k.address != item.address]

    # ── To the stream ───────────────────────────────────────────────────────

    def sources(self, item: Item) -> list[Source]:
        """Exactly one source — and that is more honest than eight.

        arte gives one HLS stream per item. The versions are tracks in it; eight
        `Source` entries with the same address would be a choice without effect.
        """
        kennung = item.address.split("/", 1)[-1]
        d = _hol(f"/player/v2/config/{SPRACHE}/{urllib.parse.quote(kennung)}")
        attrs = (d.get("data") or {}).get("attributes") or {}

        fehler = attrs.get("error")
        if fehler:
            # The reason belongs on the way out. Measured, this happens with
            # items whose availability has run out — `rights.end` then lies in
            # the past, and that is not a fault.
            code = str((fehler or {}).get("code") or "unknown")
            raise RuntimeError(f"arte: kein Strom ({code})")

        heraus: list[Source] = []
        for s in attrs.get("streams") or []:
            url = s.get("url")
            if not url:
                continue
            # `dict.fromkeys` instead of `set`: the order is arte's, and that
            # one is sorted — German first, audio description last. Duplicates
            # occur all the same: `OmU` stands there twice as measured, once for
            # Polish and once for Italian subtitles, and both shorten to the
            # same tag.
            fassungen = list(
                dict.fromkeys(
                    str(v.get("shortLabel") or v.get("code"))
                    for v in s.get("versions") or []
                    if v.get("shortLabel") or v.get("code")
                )
            )
            heraus.append(
                Source(
                    id=str(url),
                    # What the viewer can choose in the player stands in the
                    # name — so that the versions are at least visible.
                    name=", ".join(fassungen[:4]) or "HLS",
                    address=str(url),
                    language=None,
                )
            )
        return heraus

    def resolve(self, source: Source) -> Stream:
        """The address is already settled — arte resolves nothing."""
        return Stream(
            address=source.id,
            kind="hls",
            resolved=True,
            # The resolution stands in the manifest (768x432 up to
            # 1920x1080) and is chosen by the player. A number here would be a
            # guess.
            resolution=None,
            subtitles=[],
        )

    # ── Searching ───────────────────────────────────────────────────────────

    def search(self, text: str) -> list[Item]:
        if not text.strip():
            return []
        d = _hol(
            f"/emac/v4/{SPRACHE}/web/pages/SEARCH/?"
            + urllib.parse.urlencode({"query": text.strip()})
        )
        items, _ = _aus_zonen(d)
        return items

    def series(self, address: str) -> str | None:
        """An arte address carries no series title.

        It carries a `programId` — `113566-001-F` for an episode, `RC-026891`
        for the series above it — and the one does not stand in the other.
        Finding out the title would cost one request per playback, and nothing
        could be chosen with it anyway: the version sits in the manifest, not in
        a source.
        """
        return None
