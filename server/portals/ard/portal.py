"""The ARD Mediathek — the portal that proves the contract.

**What it is for.** As long as the only portals were scrapers, it stayed open
whether the contract really is one or merely the shape of the first scraper.
Here the bridge speaks directly to an official interface — the same six
methods, no adapter, no stand-in.

## What the media library does differently from a scraper

**It hands out the video address ready-made.** There is no mirror, no choice
and nothing to resolve; ``resolve()`` passes through what ``sources()`` already
knew. That is exactly why ``portal.yml`` does **not** declare the capability
``resolver`` — a source button would be a choice without options.

**And it is a page of tiles, not a directory.** The front page delivers widgets;
every widget is a row. The contract has precisely the right word for that: an
``Entry`` is such a row, and what lies in it is fetched by ``listing()``.

## Where the shapes come from

The fixtures under ``vorlagen/`` have the shape of answers fetched on
02.09.2026 and 16.11.2026, with invented titles (written by a generator in the
private source). The tests read those exclusively: **a test should say the same
thing when something outside is down**, and the same rule already stands at the
other portals' tests.
"""

from __future__ import annotations

import urllib.parse
from typing import Any, ClassVar

from cinelounge.core.contract import Entry, Item, Page, Source, Stream

BASIS = "https://api.ardmediathek.de/page-gateway"
KUNDE = "ard"

# The id of the menu row on the front page. It is stable — unlike the ids of
# the content rows, which change with every editorial shift.
MENUE_WIDGET = "1FdQ5oz2JK6o2qmyqMsqiI:-7294599990048467640"

# How long the media library is waited for. Twelve seconds: the front page
# weighs 44 kilobytes and arrives in under a second; whatever takes longer is
# down, not slow.
DEADLINE = 12


class Portal:
    """Six methods against the official interface."""

    id = "ard"
    name = "ARD Mediathek"
    # **The same list as in `portal.yml`, and that is mandatory.** The service
    # does not reconcile the two: it reads the manifest for the console and
    # calls the class for the data. Until 11.09.2026 German names from before
    # the rename stood here — the file was not in the repo, so no renamer
    # touched it.
    capabilities: ClassVar[set[str]] = {
        "search",
        "seasons",
        "subtitles",
        "own_images",
        "paging",
    }

    def __init__(self, fetch=None) -> None:
        # Fetching as a dependency: the tests put the fixtures in and never go
        # onto the network.
        self._hole = fetch or _hole_json

    # ── Menu ────────────────────────────────────────────────────────────────

    def menu(self) -> list[Entry]:
        """The library's categories — from its own menu, not guessed.

        **Copying them out would be wrong the moment the editors rebuild.** What
        comes out here is the front page's menu row; if a category is added, it
        stands on the television without anybody changing anything.
        """
        daten = self._hole(
            f"{BASIS}/widgets/{KUNDE}/editorials/"
            f"{urllib.parse.quote(MENUE_WIDGET, safe='')}"
            "?pageNumber=0&pageSize=100"
        )
        entries: list[Entry] = []
        for kachel in daten.get("teasers") or []:
            target = _ziel(kachel)
            ident = _rubrik(target)
            if not ident:
                continue
            entries.append(
                Entry(
                    id=ident,
                    name=_titel(kachel) or ident,
                    group="curated",
                )
            )
        return entries

    # ── Listing ─────────────────────────────────────────────────────────────

    def listing(self, entry: str, next_page: str | None = None, user_input: str = "") -> Page:
        """One category as one page of entries.

        **The rows are merged, not offered one by one.** A category of the
        library consists of twenty rows of twenty tiles each; as an entry each,
        that would be four hundred levels for a viewer who pressed "Serien". The
        contract knows a page with a continuation marker — so it is paged, and
        row by row: ``next_page`` is the number of the next row.

        The marker stays opaque all the same: the app hands it back without
        interpreting it.
        """
        page = self._hole(
            f"{BASIS}/pages/{KUNDE}/editorial/{urllib.parse.quote(entry, safe='')}?embedded=true"
        )
        reihen = [w for w in (page.get("widgets") or []) if w.get("teasers")]

        ab = _zahl(next_page, 0)
        items: list[Item] = []
        naechste: str | None = None
        for number, reihe in enumerate(reihen):
            if number < ab:
                continue
            for kachel in reihe.get("teasers") or []:
                item = _item(kachel)
                if item:
                    items.append(item)
            # One row per grab is enough: the view shows a grid, and twenty
            # tiles fill it.
            if items:
                naechste = str(number + 1) if number + 1 < len(reihen) else None
                break

        return Page(items=items, next_page=naechste, total=None)

    # ── Children ────────────────────────────────────────────────────────────

    def children(self, item: Item) -> list[Item]:
        """What lies beneath a series — its episodes.

        The library calls a series a "group" and hangs its items beneath it as
        rows. Seasons stand at the entry as ``availableSeasons``; the episodes
        themselves do not carry their number, so **none** is invented here.
        """
        daten = self._hole(_gruppenadresse(item.address))
        children: list[Item] = []
        for reihe in daten.get("widgets") or []:
            for kachel in reihe.get("teasers") or []:
                item = _item(kachel)
                if item:
                    children.append(item)
        return children

    # ── Sources and resolving ───────────────────────────────────────────────

    def sources(self, item: Item) -> list[Source]:
        """An item's versions — here: the resolution steps.

        **Not empty and not one.** The library delivers the same item in four
        sizes; the best is almost always right, but over a narrow line it is
        not. The contract already has the shape for it, and the order is the
        recommendation: best first.
        """
        daten = self._hole(_eintragsadresse(item.address))
        sources: list[Source] = []
        for stufe in _medien(daten):
            address = stufe.get("url")
            if not address:
                continue
            sources.append(
                Source(
                    id=str(address),
                    name=_stufenname(stufe),
                    address=str(address),
                )
            )
        sources.sort(key=lambda q: (-_hoehe(q.name), q.name))
        return sources

    def resolve(self, source: Source) -> Stream:
        """Pass through — there is nothing to resolve.

        **And therefore no expiry either.** ``valid_until`` stays empty: the
        library's address is not a host's one-shot token but a file that will
        still lie there tomorrow. A cache that keeps it saves nothing and only
        hides the case where it does change after all.
        """
        # **The id IS the address** (CN6C-CM, 04.09.): if the request arrives
        # with `source=`, the bridge builds `Source(id=…, address="")` — and
        # `source.address` was empty. The relay got `stream?address=` with no
        # value, answered 403, and the television reported -1102.
        return Stream(address=source.address or source.id, kind="file", resolved=True)

    # ── Search ──────────────────────────────────────────────────────────────

    def search(self, text: str) -> list[Item]:
        text = (text or "").strip()
        if not text:
            return []
        daten = self._hole(
            f"{BASIS}/widgets/{KUNDE}/search/vod"
            f"?searchString={urllib.parse.quote(text)}&pageSize=40"
        )
        found = [_item(k) for k in (daten.get("teasers") or [])]
        return [i for i in found if i]

    def series(self, address: str) -> str | None:
        """The library knows no per-series language choice — nothing to bind."""
        return None


# ── Turning the shapes into the contract ────────────────────────────────────


def _hole_json(address: str) -> dict[str, Any]:
    """The only way outwards — and the only reason for ``requests``.

    **Imported here and not at the top.** The test against the fixtures puts in
    a fetcher of its own and never goes onto the network; an import at module
    level would demand the package all the same, and then a network-free test
    would need a network library in order to run.
    """
    import requests

    answer = requests.get(address, headers={"Accept": "application/json"}, timeout=DEADLINE)
    answer.raise_for_status()
    return answer.json()


def _ziel(kachel: dict[str, Any]) -> str:
    return str(((kachel.get("links") or {}).get("target") or {}).get("href") or "")


def _titel(kachel: dict[str, Any]) -> str:
    """The best title the tile gives up.

    Three fields, and they are not interchangeable: `longTitle` carries the full
    name including the suffix ("Kanalnacht | Alle vier Staffeln"),
    `mediumTitle` the same without it, `shortTitle` often only "Übersicht". The
    first one that says something is taken.
    """
    for feld in ("longTitle", "mediumTitle", "title", "shortTitle"):
        value = kachel.get(feld)
        if value:
            return str(value).strip()
    return ""


def _rubrik(target: str) -> str | None:
    """The category id out of a menu line's target address.

    `editorial` pages only: the menu item "Alle Rubriken" leads to a collection,
    and that has a different shape. Leaving it out is more honest than fetching
    it with the same query and coming back empty.
    """
    token = "/pages/ard/editorial/"
    if token not in target:
        return None
    remaining = target.split(token, 1)[1]
    return urllib.parse.unquote(remaining.split("?", 1)[0]) or None


def _item(kachel: dict[str, Any]) -> Item | None:
    """A tile becomes an item — or none.

    **Not every tile is content.** A category page carries its own navigation as
    tiles of type `editorialPage`; handed out as a series those would be items
    that show nothing when opened.

    **`poster` is a video, too.** Measured on 16.11.2026: the category "Filme"
    carried 465 tiles of type `poster` (core type `EPISODE`) against 12 of type
    `ondemand` — the library shows films as portrait tiles now. Their target is
    the same `/item/` page with the same media list. Left out, the first rows of
    "Filme" came back empty and the category opened on a row of series.
    """
    mime = str(kachel.get("type") or "")
    if mime not in {"ondemand", "poster", "grouping", "show", "live"}:
        return None
    title = _titel(kachel)
    target = _ziel(kachel)
    if not title or not target:
        return None

    core = str(kachel.get("coreAssetType") or "")
    # `INFINITE_SERIES` is a "Reihe" without seasons ("Die Verteidigerin |
    # Reihe"): a `/grouping/` page like any series. Taken for an episode, its
    # sources were asked of a group page and came back empty.
    ist_serie = core in {"SEASON_SERIES", "INFINITE_SERIES", "SERIES", "SHOW"} or mime == "grouping"

    return Item(
        title=title,
        address=target,
        # **The show stands beside it, in an object of its own.** Without it a
        # hit is called "Folge 41: Kreidespur (S04/E05)" and nothing else; with
        # it, "Die Almwache".
        show=_sendung(kachel) if not ist_serie else None,
        kind="series" if ist_serie else "episode",
        description=_text(kachel),
        image=_bild(kachel),
        image_source="portal" if _bild(kachel) else None,
        # **The library delivers landscape, not portrait.** All three aspect
        # ratios are 16x9, 16x7 and 1x1 — there is no 2:3 poster, and a view
        # expecting one cuts faces off.
        image_wide=True,
        duration_min=_minuten(kachel.get("duration")),
        has_children=ist_serie,
    )


def _sendung(kachel: dict[str, Any]) -> str | None:
    """Which show a tile belongs to.

    The library attaches the episode's `show` object; in it the name stands
    under `title`. `shortTitle` and `longTitle` are, as measured, always `null`
    there — what is there is taken.
    """
    sendung = kachel.get("show")
    if not isinstance(sendung, dict):
        return None
    for feld in ("title", "longTitle", "mediumTitle", "shortTitle"):
        value = sendung.get(feld)
        if value:
            return str(value).strip() or None
    return None


def _text(kachel: dict[str, Any]) -> str | None:
    for feld in ("synopsis", "shortSynopsis", "longSynopsis"):
        value = kachel.get(feld)
        if value:
            return str(value)
    return None


def _bild(kachel: dict[str, Any]) -> str | None:
    """The image address, with the width filled in.

    The library hands out `…/16x9?w={width}` — with the braces in it the address
    is **not** one but a template. Whoever passes it on unchecked gets an empty
    field on the television and goes looking for the fault in the image
    handling.
    """
    bilder = kachel.get("images") or {}
    for key in ("aspect16x9", "aspect16x7", "aspect1x1"):
        item = bilder.get(key) or {}
        address = item.get("src")
        if address:
            return str(address).replace("{width}", "1280")
    return None


def _minuten(sekunden: Any) -> int | None:
    if not isinstance(sekunden, (int, float)) or sekunden <= 0:
        return None
    return round(sekunden / 60)


def _medien(daten: dict[str, Any]) -> list[dict[str, Any]]:
    for widget in daten.get("widgets") or []:
        eingebettet = ((widget.get("mediaCollection") or {}).get("embedded")) or {}
        for stream in eingebettet.get("streams") or []:
            medien = stream.get("media") or []
            if medien:
                return list(medien)
    return []


# What the library calls its audio mixes, and what we call them.
#
# **Found in the run against the real interface** (02.09.): the list of steps
# came back with ten entries for four resolutions — "HD 1080p" twice, "HD 720p"
# twice and so on. At first glance duplicates to be thrown away. But they are
# **two audio mixes**: the ordinary broadcast sound and a version with raised
# speech that ARD offers for poor hearing.
#
# Throwing them away would mean withholding an offer from exactly those viewers
# least likely to find it themselves. So both stand there — and are named so
# that they can be told apart. The fixtures did not show this: they carry only
# an excerpt.
TONMISCHUNG = {
    "speech-optimized": "klare Sprache",
    "audio-description": "Audiodeskription",
}


def _stufenname(stufe: dict[str, Any]) -> str:
    """A step name like `HD 1080p` — or `HD 1080p · klare Sprache`."""
    reason = str(stufe.get("forcedLabel") or "Video")
    for ton in stufe.get("audios") or []:
        zusatz = TONMISCHUNG.get(str(ton.get("kind") or ""))
        if zusatz:
            return f"{reason} · {zusatz}"
    return reason


def _hoehe(bezeichnung: str) -> int:
    """`HD 1080p` becomes 1080 — for the order, not for display."""
    ziffern = "".join(z if z.isdigit() else " " for z in bezeichnung).split()
    return max((int(z) for z in ziffern), default=0)


def _zahl(value: Any, fallback: int) -> int:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return fallback


def _gruppenadresse(address: str) -> str:
    return address


def _eintragsadresse(address: str) -> str:
    """An item's address with the request for the media list.

    Without `mcV6=true` the old shape of the collection comes back — it does not
    carry the resolution steps.
    """
    getrennt = urllib.parse.urlsplit(address)
    values = dict(urllib.parse.parse_qsl(getrennt.query))
    values["mcV6"] = "true"
    values["embedded"] = "false"
    return urllib.parse.urlunsplit(getrennt._replace(query=urllib.parse.urlencode(values)))
