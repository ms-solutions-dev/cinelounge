"""The contract — the one piece everything else turns on.

It says "give me entries", not "give me matches in the HTML". That is the
difference between a bridge that carries any portal and a scraper with a
server attached.

Same shape as ContentSource.swift on the app side: one contract, two languages,
HTTP in between.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol, runtime_checkable

from cinelounge.core.ids import key as _key
from cinelounge.core.ids import normalized as _normalized

# ── Capabilities ─────────────────────────────────────────────────────────────
#
# A portal declares what it can do. Without that the interface would have to
# guess — and a "Language: German" row on ARD is just as wrong as a missing
# source button on a portal that offers several sources per title.
#
# **The list lives in `portalworks/manifest.py`, not here.** Until 11 Sep 2026
# a second, German one sat here (`staffeln`, `aufloeser`) together with `KINDS`
# and `unknown_capabilities` — left over from before the rename, imported by
# nobody. Two truths are one too many: extend the dead list and nothing
# changes, and you only find out at the next portal.
#
# While clearing it out, one capability turned up that did not survive the
# rename: **`gesundheit`** ("12 of 12 fine") appears in none of the English
# lists and in no mapping of the manifest migration. Whether it is missing or
# deliberately gone was settled with B10 (nightly run per portal) — that is
# where it would have been the seal of quality. Until then it lives nowhere on
# purpose, rather than in a place nobody reads.


# ── Identity ─────────────────────────────────────────────────────────────────
# Trap 2 from the design: progress must not hang on the address. If a portal
# changes its URL scheme, "continue watching" would otherwise be gone for the
# entire library.

# **Both live in `core/ids.py` and are only passed on from here.**
#
# Until 11 Sep 2026 `normalized()` and `key()` stood in both files — word for
# word, character for character. Two truths about when two titles are the same
# one: improve one of them (roman numerals, a leading "The") and half the
# library would be filed differently from the other half — and "continue
# watching" hangs on exactly this key.
#
# They stay importable here so that a portal may write `from
# cinelounge.core.contract import normalized` without knowing two modules.
normalized = _normalized


key = _key


# ── The data that crosses the bridge ─────────────────────────────────────────


@dataclass(slots=True)
class Entry:
    """A row on the entry screen — what a portal announces about itself.

    The app shows only what comes back: the three portals cannot do the same
    things, and a fourth should not cost a line of Swift.
    """

    id: str
    name: str
    icon: str | None = None  # the glyph in front of the row, e.g. "🆕"
    count: int | None = None  # "214 today" — None means unknown, not zero
    group: str = "curated"  # "curated" above the rule, "library" below it


@dataclass(slots=True)
class Item:
    """One entry: a series, a film, a season or an episode.

    `address` is a hint for the portal, not an identifier — see `key()`.
    """

    title: str
    address: str
    #: What this entry belongs to — the series or programme title.
    #:
    #: **Without it a result list cannot be read.** Measured on 11 Sep 2026
    #: against the ARD search for "krimireihe": "Folge 41: Kreidespur (S04/E05)"
    #: and "Folge 51: Was weg ist, bleibt weg (S04/E11)". The broadcaster names
    #: the programmes right beside them — *Die Almwache* and
    #: *Ruhestandsrevier* — and the scraper threw that away.
    #:
    #: `None` means "belongs to nothing" (a film) **or** "the portal does not
    #: say". Telling those two apart is impossible and unnecessary: for the
    #: display they mean the same thing.
    show: str | None = None
    kind: str = "series"  # series | movie | season | episode | folder | collection
    year: int | None = None
    description: str | None = None
    image: str | None = None
    # Trap 3: whoever supplies the artwork should be recorded. Otherwise there
    # is no way to tell later why a poster is missing.
    image_source: str | None = None  # "portal" | "tmdb" | None
    # Whether the image is landscape (16:9) rather than portrait (2:3). `None`
    # means "cannot be determined" and is not the same as `False`: the app
    # deliberately tests for `== true` and `== false` only, so that a missing
    # answer never passes as a claim. The portal says it, or leaves it `None`.
    image_wide: bool | None = None
    languages: list[str] = field(default_factory=list)  # ["DE", "EN", "Ger-Sub"]
    rating: float | None = None
    # The TMDB id with its kind, the way TMDB builds its paths: "tv/1399" or
    # "movie/603" (29.09.2026). The app looks up the IMDb id through it and asks
    # OMDb for IMDb, Rotten Tomatoes and Metacritic — without it the detail page of
    # a portal title stayed thin although TMDB knew the title all along.
    tmdb_id: str | None = None
    duration_min: int | None = None
    number: int | None = None  # season or episode number
    # Whether anything sits below this entry. For portals that only know
    # folders and items, that is all one can say.
    has_children: bool = False

    def key(self, portal: str) -> str:
        return key(portal, self.title, self.year)


@dataclass(slots=True)
class Page:
    """A page of entries plus the marker for the next one.

    Trap 1: `next_page` is opaque. The bridge passes on whatever the portal
    gives it and does not interpret it — for one portal it is "?p=2", for the
    next a cursor.
    """

    items: list[Item]
    next_page: str | None = None
    total: int | None = None
    # What the portal had to say although nothing came back.
    #
    # **An empty level is not an error.** An empty folder is a normal case: a
    # person with no titles on this page, a page past the last one, a section
    # the site has emptied. Until 28 Aug 2026 the bridge raised a
    # `RuntimeError` for this, and the television read "list: RuntimeError:
    # the portal returned nothing" — a red error for something that is not one
    # (the same message in a dozen places).
    #
    # A real error stays one: if the portal crashes, the exception travels on
    # as before. Only "nothing there" now reads as "nothing there".
    note: str | None = None
    # The portal asked for input — a site's search box.
    #
    # There is no keyboard on the server, so the bridge says what was asked
    # for and the app asks the viewer. The answer comes back as `user_input`
    # and the same run happens again — this time with an answer to the
    # question.
    needs_input: str | None = None
    # What the input box was pre-filled with when the portal asked.
    #
    # **A suggestion only, never an answer.** A portal with a search history
    # may offer the last term; on the server that was enough, until 9 Sep
    # 2026, to keep the bridge from asking at all and to quietly return the
    # results of an old search (viewer report: "the search inside a section
    # does not work"). Now the question comes through, and this field says
    # what would have been in the box.
    #
    # **Optional and additive** (roadmap E26): whoever does not know the field
    # skips it — the television app notices nothing.
    input_suggestion: str | None = None
    # What the portal wanted confirmed — an open yes/no question.
    #
    # **It is not an empty result.** A "Clear Search History" entry may
    # return `items: []` and the sentence "Confirm: Are you sure you want to
    # clear the search history?"; without this field the app reads that as an
    # empty level (viewer report 9 Sep 2026).
    #
    # **Still without a way to answer.** Answering would need a parameter that
    # travels, like `user_input`, from the app all the way into
    # `Portal.listing`; until then the bridge says "no" and reports what was
    # asked.
    question: str | None = None


@dataclass(slots=True)
class Source:
    """A source or a quality step — not yet a video address.

    The question "which source?" becomes an order that the server works
    through itself. The choice remains, but behind a long press.
    """

    id: str
    name: str  # "Mirror 1", "1080p"
    address: str  # the source's page, not necessarily the video
    language: str | None = None
    blocked: bool = False  # the portal or the operator marked it unusable
    reason: str | None = None  # why it is blocked


@dataclass(slots=True)
class Stream:
    """The end of the chain: an address that can be played.

    `valid_until` is not a speed trick but a necessity — AVPlayer fetches an
    address twice (HEAD first, then GET), and many servers' one-shot tokens burn
    up in between.
    """

    address: str
    kind: str = "file"  # file | hls | dash
    # Whether the address is already playable. A broadcaster's library returns
    # the video address outright; other portals first return a page that still
    # has to be resolved into a video (`resolved: False`).
    resolved: bool = True
    resolution: str | None = None
    resolve_ms: int | None = None  # how long resolving took
    subtitles: list[dict[str, str]] = field(default_factory=list)
    headers: dict[str, str] = field(default_factory=dict)  # Referer and friends
    valid_until: float | None = None  # unix time; None means: do not cache


# ── What a portal has to be able to do ───────────────────────────────────────


@runtime_checkable
class Portal(Protocol):
    """Six methods. No HTML, no mocks in the contract.

    What a portal really offers out of these is declared in `capabilities` —
    stated, not guessed.
    """

    id: str
    name: str
    capabilities: set[str]

    def configure(self, settings: dict[str, str]) -> None:
        """What the operator entered — **optional, and before anything else**.

        The runner calls it exactly once per child process, before it asks the
        first question. A portal without settings of its own does not need it;
        the default here does nothing.

        **It did not exist until 11 Sep 2026**, and that was a gap with an
        announcement: `portalworks/manifest.py` reads `settings:`, the console
        shows them on the portal page, `overlay()` lays the household's values
        on top — and `_portal_bauen()` called `module.Portal()` with no
        arguments. Anyone following the SDK built a setting that never
        arrived.

        The values arrive flat, as `{"api.key": "…", "quality.max": "1080"}`.
        Whatever was not entered carries the author's default; whatever they
        left empty carries `""`.
        """
        return None

    def menu(self) -> list[Entry]: ...

    def listing(self, entry: str, next_page: str | None = None, user_input: str = "") -> Page: ...

    def children(self, item: Item) -> list[Item]: ...

    def sources(self, item: Item) -> list[Source]: ...

    def resolve(self, source: Source) -> Stream: ...

    def search(self, text: str) -> list[Item]: ...

    def series(self, address: str) -> str | None:
        """Which series this address belongs to — its title, or `None`.

        **The one question that makes a preference centrally settable at all**
        (viewer request, 28 Aug 2026: "instead of picking it for every single
        episode, can it be steered centrally?"). The language choice sits on
        the series' row; to find it when playing an **episode**, the episode's
        address has to be turned back into its series.

        Only the portal can answer that: how an address is built is known to
        the adapter that produced it and to nobody else. A portal without
        series returns `None`, and then there is nothing to steer centrally
        either.
        """
        return None
