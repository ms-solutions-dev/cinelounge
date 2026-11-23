"""SVT Play — Sweden's public broadcaster, over GraphQL.

**The point on which this portal turns: more than half of the offering runs
only in Sweden.** Measured 11.09.2026 on the front page:

    Sweden only:   517
    freely open:   394

`INHALTE.md` says *"Sweden is the most open broadcaster in Europe"*. That holds
in comparison — and it still means 57 % blocked.

A portal that shows all 911 fills a sidebar with titles of which every second
one does not start. That is exactly what `INHALTE.md` says about BBC iPlayer,
and there it is the reason **not** to build it. So this portal filters
`restrictions.onlyAvailableInSweden` out.

**And it can be switched off**, because for a household in Sweden the filter is
wrong: the setting `sweden_only` turns it off. It is at the same time the first
example of a setting a `native` portal really reads — until 11.09.2026 that was
impossible, see `Portal.configure` in the contract.

## The interface

GraphQL, without a key, without a sign-in::

    POST https://api.svt.se/contento/graphql
    GET  https://api.svt.se/video/<svtId>      the streams

| query | for what |
|---|---|
| `startForSvtPlay` | the front page, 39 selections |
| `genresInMain` | 24 genres with `id` and `name` |
| `categoryPage(id)` | one genre |
| `searchPage(query)` | the search, over `flat.hits[].teaser.item` |
| `listablesBySlug(slugs)` | one series including its seasons |

Images carry no URL, only an `id` and a timestamp; the address is built.
Measured, `wide/992` (61 KB), `wide/1280` (87 KB) and `original/default`
(157 KB) work.

**Subtitles are real files**, unlike at arte: `subtitleReferences` with
`format: "webvtt"` and `language: "sv"`. That is why `subtitles` stands among
the capabilities here and not there.
"""

from __future__ import annotations

import json
import urllib.request
from typing import Any, ClassVar

from cinelounge.core.contract import Entry, Item, Page, Source, Stream

GRAPHQL = "https://api.svt.se/contento/graphql"
VIDEO = "https://api.svt.se/video/"
BILD = "https://www.svtstatic.se/image/wide/{breite}/{id}/{stand}"
KOPF = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
    "Content-Type": "application/json",
}

#: Which image width is built. Measured: 992 gives 61 KB, 1280 gives 87 KB.
BILDBREITE = 1280

#: Which stream format is taken, in this order.
#:
#: SVT delivers eleven versions — `hls`, `hls-ts-full`, `hls-cmaf-avc`, `dash`
#: and so on. `hls` is the plainest and the one AVPlayer opens without fuss; the
#: `dash` versions are not in the list because AVPlayer does not take them.
FORMATE = ("hls", "hls-ts-full", "hls-cmaf-full", "hls-cmaf-avc")

#: What counts as a collection and what as an item.
SAMMLUNGEN = frozenset({"TvSeries", "TvShow", "KidsTvShow", "Playlist"})
BEITRAEGE = frozenset({"Episode", "Single", "Clip", "Variant"})

#: The entry points. The genre ids come from `genresInMain` and are measured,
#: not translated — they are Swedish because SVT is Swedish.
EINSTIEGE: list[tuple[str, str, str]] = [
    ("start", "Neu bei SVT", "🆕"),
    ("dokumentar", "Dokumentationen", "🌍"),
    ("filmer", "Filme", "🎬"),
    ("serier", "Serien", "📺"),
    ("vetenskap", "Wissenschaft", "🔬"),
    ("djur-och-natur", "Tiere & Natur", "🌿"),
    ("historia", "Geschichte", "🏛"),
    ("kultur", "Kultur", "🎭"),
    ("musik", "Musik", "🎵"),
    ("samhalle", "Gesellschaft", "🗣"),
    ("suche", "Suche", "🔍"),
]

#: The fields fetched from every entry. Written once, because they read the
#: same in four queries.
#:
#: **Filled in with `%s` and not with `.format()` or an f-string.** GraphQL
#: consists of curly braces; both other ways would read every one of them as a
#: placeholder and demand `{{` everywhere. The linter dislikes that (`UP031`)
#: and is wrong here.
EINTRAG = """__typename
  ... on Listable { id svtId name shortDescription image { id changed }
    urls { svtplay } restrictions { onlyAvailableInSweden } }
  ... on Playable { duration }"""


# **The queries stand here and not in the methods.** Built once, used four
# times — and the explanation for them stands once instead of four times.
#
# **Concatenated and not formatted.** GraphQL consists of curly braces; an
# f-string or `.format()` reads every one of them as a placeholder and would
# demand `{{` everywhere. `%s` would work but is rightly flagged by the linter
# (`UP031`). A `+` does the same and needs no excuse.
ABFRAGE_START = "{ startForSvtPlay { selections { id name items { item { " + EINTRAG + " } } } } }"

ABFRAGE_KATEGORIE = (
    "query($i:String!){ categoryPage(id:$i){ id heading "
    "flat { ... on Selection { id name items { item { " + EINTRAG + " } } } } } }"
)

# Three fragments, because a collection can be `TvSeries`, `TvShow` or
# `KidsTvShow` and GraphQL knows the field only on the concrete type.
ABFRAGE_SERIE = (
    "query($s:[String!]!){ listablesBySlug(slugs:$s){ __typename "
    "... on TvSeries { associatedContent { id name items { item { " + EINTRAG + " } } } } "
    "... on TvShow { associatedContent { id name items { item { " + EINTRAG + " } } } } "
    "... on KidsTvShow { associatedContent { id name items { item { " + EINTRAG + " } } } } } }"
)

ABFRAGE_SUCHE = (
    "query($q:String!){ searchPage(query:$q){ flat { hits { "
    "teaser { item { " + EINTRAG + " } } } } } }"
)


def _fragen(frage: str, variablen: dict[str, Any] | None = None) -> dict[str, Any]:
    daten = json.dumps({"query": frage, "variables": variablen or {}}).encode()
    r = urllib.request.Request(GRAPHQL, data=daten, headers=KOPF)
    with urllib.request.urlopen(r, timeout=30) as a:
        antwort = json.loads(a.read().decode("utf-8", "replace"))

    if antwort.get("errors"):
        # **The reason belongs on the way out.** GraphQL answers 200 and puts
        # the error in the body; whoever checks only the status gets an empty
        # result and no idea why.
        erste = (antwort["errors"] or [{}])[0].get("message", "")
        raise RuntimeError("SVT: " + str(erste)[:200])
    return antwort.get("data") or {}


def _hol_video(svt_id: str) -> dict[str, Any]:
    r = urllib.request.Request(VIDEO + urllib.request.quote(svt_id), headers=KOPF)
    with urllib.request.urlopen(r, timeout=30) as a:
        return json.loads(a.read().decode("utf-8", "replace"))  # type: ignore[no-any-return]


def _bild(e: dict[str, Any]) -> str | None:
    bild = e.get("image") or {}
    if not bild.get("id"):
        return None
    return BILD.format(breite=BILDBREITE, id=bild["id"], stand=bild.get("changed") or "")


def _slug(e: dict[str, Any]) -> str:
    """The slug out of the play address — `/diagnoser` becomes `diagnoser`.

    That is all the seasons need: `listablesBySlug` takes it, `svtId` it does
    not.
    """
    weg = (e.get("urls") or {}).get("svtplay") or ""
    return str(weg).strip("/").split("/")[0]


class Portal:
    """The contract's seven methods."""

    id = "svt"
    name = "SVT Play"
    #: The same list as in `portal.yml`.
    #:
    #: `subtitles` is in it because SVT delivers real WebVTT files — unlike
    #: arte, where they are tracks in the manifest.
    capabilities: ClassVar[set[str]] = {
        "search",
        "seasons",
        "subtitles",
        "own_images",
    }

    def __init__(self) -> None:
        #: Whether what runs only in Sweden is shown as well.
        #:
        #: Default `off`: 57 % of the offering is blocked, and a list in which
        #: every second title does not start is worse than a short one.
        self._auch_gesperrte = False

    def configure(self, settings: dict[str, str]) -> None:
        """What the operator entered.

        **The first setting in the project that a native portal reads.** Until
        11.09.2026 the runner called `module.Portal()` without arguments;
        `settings:` in the manifest never arrived at a native portal.
        """
        wert = (settings.get("sweden_only") or "").strip().lower()
        self._auch_gesperrte = wert in ("ja", "yes", "true", "1", "an", "on")

    def _erlaubt(self, e: dict[str, Any]) -> bool:
        if self._auch_gesperrte:
            return True
        return not (e.get("restrictions") or {}).get("onlyAvailableInSweden")

    def _als_item(self, e: dict[str, Any]) -> Item | None:
        art = e.get("__typename") or ""
        if art not in SAMMLUNGEN and art not in BEITRAEGE:
            return None
        if not e.get("name") or not self._erlaubt(e):
            return None

        ist_sammlung = art in SAMMLUNGEN
        if ist_sammlung:
            kurz = _slug(e)
            if not kurz:
                return None
            adresse = "series/" + kurz
        else:
            if not e.get("svtId"):
                return None
            adresse = "show/" + str(e["svtId"])

        dauer = e.get("duration")
        return Item(
            title=str(e["name"]),
            address=adresse,
            kind="series" if ist_sammlung else "episode",
            description=e.get("shortDescription") or None,
            image=_bild(e),
            image_source="portal",
            image_wide=True,
            # Measured in seconds: 3126 for 52 minutes.
            duration_min=round(dauer / 60) if dauer else None,
            languages=["SV"],
            has_children=ist_sammlung,
        )

    def _aus_auswahlen(self, auswahlen: list[dict[str, Any]]) -> list[Item]:
        """Several selections into one list, without duplicates.

        As at arte, an SVT page is a shelf: the front page carries 39
        selections, and the same title stands in several of them.
        """
        gesehen: set[str] = set()
        heraus: list[Item] = []
        for a in auswahlen or []:
            for eintrag in a.get("items") or []:
                item = self._als_item(eintrag.get("item") or {})
                if item is None or item.address in gesehen:
                    continue
                gesehen.add(item.address)
                heraus.append(item)
        return heraus

    # ── The entry points ────────────────────────────────────────────────────

    def menu(self) -> list[Entry]:
        return [
            Entry(id=k, name=n, icon=z, group="curated" if k != "suche" else "library")
            for k, n, z in EINSTIEGE
        ]

    def listing(self, entry: str, next_page: str | None = None, user_input: str = "") -> Page:
        if entry == "suche":
            if not user_input:
                return Page(items=[], needs_input="Suche bei SVT Play")
            return Page(items=self.search(user_input))

        if entry == "start":
            d = _fragen(ABFRAGE_START)
            auswahlen = (d.get("startForSvtPlay") or {}).get("selections") or []
        else:
            code = next((k for k, _, _ in EINSTIEGE if k == entry), None)
            if code is None:
                return Page(items=[], note="unbekannter Einstieg: " + entry)
            # **`flat`, not `selections`.** `CategoryPage` has no
            # `selections` — the field is called `flat` there and gives the same
            # `Selection` objects. The name `selections` holds only for
            # `startForSvtPlay`, and from outside the two look alike.
            d = _fragen(ABFRAGE_KATEGORIE, {"i": code})
            auswahlen = ((d.get("categoryPage") or {}).get("flat")) or []

        items = self._aus_auswahlen(auswahlen)
        # **No paging, and that is measured and not forgotten.** A selection
        # arrives complete; `startForSvtPlay` gave 911 entries in one go. Which
        # is why `paging` is not among the capabilities either.
        return Page(items=items, next_page=None, total=len(items))

    # ── One level deeper ────────────────────────────────────────────────────

    def children(self, item: Item) -> list[Item]:
        """A series' seasons and episodes.

        `associatedContent` carries more than the episodes: seasons
        (`season-1-<id>`), clips and a zone "Upptäck mer" with other series. The
        last one drops out — it does not belong beneath this entry, and whoever
        takes it along unfolds one series and finds another in it.
        """
        if not item.address.startswith("series/"):
            return []
        kurz = item.address.split("/", 1)[1]
        d = _fragen(ABFRAGE_SERIE, {"s": [kurz]})
        auswahlen: list[dict[str, Any]] = []
        for x in d.get("listablesBySlug") or []:
            for ac in x.get("associatedContent") or []:
                if str(ac.get("id") or "") == "related":
                    continue
                auswahlen.append(ac)
        return self._aus_auswahlen(auswahlen)

    # ── To the stream ───────────────────────────────────────────────────────

    def sources(self, item: Item) -> list[Source]:
        """One entry per format — but only those AVPlayer opens.

        SVT delivers eleven versions, six of them `dash`. Those are not in the
        list: a button leading to a format the player does not know is a trap
        with a label on it.
        """
        kennung = item.address.split("/", 1)[-1]
        p = _hol_video(kennung)

        heraus: list[Source] = []
        for name in FORMATE:
            for vr in p.get("videoReferences") or []:
                if vr.get("format") != name or not vr.get("url"):
                    continue
                heraus.append(
                    Source(
                        # The id carries both: the video and the address.
                        # Without the `svtId`, `resolve()` would never reach the
                        # subtitles in the same answer again.
                        id=kennung + "|" + str(vr["url"]),
                        name=str(name).upper(),
                        address=str(vr["url"]),
                        language="sv",
                    )
                )
        return heraus

    def resolve(self, source: Source) -> Stream:
        """The address is settled — what is still fetched are the subtitles.

        **Real files, not manifest innards.** `subtitleReferences` carries
        WebVTT with a language tag; measured, a Swedish item carries exactly
        one, in Swedish.
        """
        kennung, _, adresse = source.id.partition("|")
        if not adresse:
            kennung, adresse = "", source.id

        untertitel: list[dict[str, Any]] = []
        if kennung:
            try:
                p = _hol_video(kennung)
                for sr in p.get("subtitleReferences") or []:
                    if sr.get("format") == "webvtt" and sr.get("url"):
                        untertitel.append(
                            {
                                "language": sr.get("language") or "sv",
                                "format": "vtt",
                                "address": str(sr["url"]),
                            }
                        )
            except Exception:
                # The film runs without subtitles all the same.
                pass

        return Stream(
            address=adresse,
            kind="hls",
            resolved=True,
            resolution=None,
            subtitles=untertitel,
        )

    # ── Searching ───────────────────────────────────────────────────────────

    def search(self, text: str) -> list[Item]:
        """The hits sit two levels down: `flat.hits[].teaser.item`.

        `SearchPageHit` has no `item` — the way leads over `teaser`. A hit
        without a `teaser` is a category tile and not a title.
        """
        if not text.strip():
            return []
        d = _fragen(ABFRAGE_SUCHE, {"q": text.strip()})
        hits = ((d.get("searchPage") or {}).get("flat") or {}).get("hits") or []
        gesehen: set[str] = set()
        heraus: list[Item] = []
        for h in hits:
            item = self._als_item((h.get("teaser") or {}).get("item") or {})
            if item is None or item.address in gesehen:
                continue
            gesehen.add(item.address)
            heraus.append(item)
        return heraus

    def series(self, address: str) -> str | None:
        """An SVT address carries the series' slug, not its title.

        `show/jE4Rx1E` says nothing about the series above it;
        `series/diagnoser` would be derivable, but `diagnoser` is not the title
        `Provsvar` — and a misspelt title hits a different row from the one the
        preference stands on. One request per playback is not worth it: SVT
        broadcasts in Swedish, there would be nothing to choose.
        """
        return None
