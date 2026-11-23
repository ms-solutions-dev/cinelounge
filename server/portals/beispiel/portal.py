"""The example portal — seven methods, no adapter, no mocks, no server knowledge.

**This file is written in English, and that is the exception in this code
base.** Everything else here is German, because one household reads it. This
one is for strangers: it is meant to be copied, and it sits next to
`docs/SDK.md`, which is English for the same reason.

## What it demonstrates

A portal is a class named `Portal` with seven methods and three attributes. It
receives no configuration object, no database handle and no HTTP request. It
runs in a forked child process behind time and memory limits, and whatever it
returns is data — never HTML, never a widget of some player.

**It deliberately has no source of its own.** The catalogue below is a fixed
list of freely licensed films (Blender Open Movies, CC-BY) served from a public
test bucket. A worked example that scrapes a live site is broken within a year
and nobody notices; this one either works or the test says so.

## What a real portal does differently

Exactly one thing: `_CATALOGUE` comes from somewhere. Fetch it, parse it, cache
it — the seven methods below stay the same shape.

## The seven methods

| | |
|---|---|
| `menu()` | the rows on the entry screen |
| `listing()` | one page of a row, with an opaque marker for the next |
| `children()` | what is underneath an item — seasons, episodes |
| `sources()` | hosts or quality steps; still not a video address |
| `resolve()` | one source turned into something a player can open |
| `search()` | free text over whatever you have |
| `series()` | episode address → the series it belongs to, or `None` |
 *
 * Plus `configure()`, which is not one of the seven: it receives the
 * operator's settings before the first question. Optional.

## Three rules that are not obvious

**Never raise a sentence.** The household may run this in Turkish. Raise
`cinelounge.core.errors.Error` with a code and values; the app translates it.
A `RuntimeError("keine Quelle")` reaches a television as exactly that.

**`next_page` is opaque and stays opaque.** The server passes back whatever you
handed it and never interprets it. Here it is a page number; elsewhere it is a
cursor. Both are fine because nobody looks inside.

**An empty level is not an error.** A folder with nothing in it is normal — a
page past the last one, a category that emptied out. Return an empty `Page`,
optionally with `note`. Raising there puts a red error on a television for
something that is not one.
"""

from __future__ import annotations

from typing import Any, ClassVar

from cinelounge.core import errors as f
from cinelounge.core.contract import Entry, Item, Page, Source, Stream

#: Where the sample files live. One host, one path, nothing to scrape.
BUCKET = "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample"

#: How many items one page of a listing holds.
#:
#: Small on purpose: with six films and a page size of four, `paging` is
#: actually exercised instead of being a capability nobody ever reaches.
PAGE_SIZE = 4


def _film(
    key: str, title: str, year: int, minutes: int, blurb: str, *, wide: bool = True
) -> dict[str, Any]:
    return {
        "key": key,
        "title": title,
        "year": year,
        "minutes": minutes,
        "blurb": blurb,
        "kind": "film",
        "wide": wide,
    }


#: The catalogue. In a real portal this is fetched; here it is typed out.
#:
#: All of it is Blender Open Movies under CC-BY except the four `ForBigger*`
#: clips, which are Google's own sample files. The "series" they form below is
#: **invented** — there is no such show. It exists so that `children()` and the
#: `seasons` capability have something to return, and saying so here is
#: cheaper than letting the next reader wonder.
_FILMS: list[dict[str, Any]] = [
    _film(
        "BigBuckBunny",
        "Big Buck Bunny",
        2008,
        10,
        "A large rabbit deals with three rodents. The first film the Blender "
        "Foundation made to prove its own tools.",
    ),
    _film(
        "ElephantsDream",
        "Elephants Dream",
        2006,
        11,
        "Two men inside a machine that keeps rebuilding itself. The first "
        "open movie, and it shows.",
    ),
    _film(
        "Sintel",
        "Sintel",
        2010,
        15,
        "A girl looks for a dragon she raised. Fifteen minutes, and it earns the ending.",
    ),
    _film(
        "TearsOfSteel",
        "Tears of Steel",
        2012,
        12,
        "Live action and computer graphics in the same frame, made to find "
        "out whether that was possible yet.",
    ),
    _film("ForBiggerFun", "For Bigger Fun", 2013, 1, "A one-minute sample clip."),
    _film("VolkswagenGTIReview", "Volkswagen GTI Review", 2013, 1, "A one-minute sample clip."),
]

#: The invented series — see the note on `_FILMS`.
_SERIES = {
    "key": "bigger",
    "title": "Bigger Things",
    "year": 2013,
    "kind": "series",
    "blurb": "Four sample clips, grouped into a season that does not exist, so "
    "that this example has something with children in it.",
    "episodes": [
        {"key": "ForBiggerBlazes", "title": "Blazes", "number": 1, "minutes": 1},
        {"key": "ForBiggerEscapes", "title": "Escapes", "number": 2, "minutes": 1},
        {"key": "ForBiggerJoyrides", "title": "Joyrides", "number": 3, "minutes": 1},
        {"key": "ForBiggerMeltdowns", "title": "Meltdowns", "number": 4, "minutes": 1},
    ],
}

#: Quality steps offered per title. Both point at the same file — a real portal
#: would have one address per step. The point is the shape, not the bitrate.
_QUALITIES = (("1080", "1080p"), ("720", "720p"))


def _image(key: str) -> str:
    """The poster address for a catalogue key.

    Real portals almost always have images; declaring `own_images` and then
    returning `None` everywhere makes the console lay out space for nothing.
    """
    return f"{BUCKET}/images/{key}.jpg"


def _as_item(film: dict[str, Any]) -> Item:
    """One catalogue row as the contract wants it.

    Note what is **not** guessed: `image_wide` stays `None` when unknown rather
    than defaulting to `False`. The app reads `== true` and `== false`
    separately, so that a missing answer never passes as a claim.
    """
    return Item(
        title=film["title"],
        # The address is a hint for this portal and nothing else. Watch
        # progress hangs off `Item.key()`, which is built from title and year —
        # so changing your address scheme later does not orphan anything.
        address=f"film/{film['key']}",
        kind=film["kind"],
        year=film["year"],
        description=film["blurb"],
        image=_image(film["key"]),
        image_source="portal",
        image_wide=film.get("wide"),
        duration_min=film["minutes"],
        languages=["EN"],
    )


def _series_item() -> Item:
    return Item(
        title=_SERIES["title"],
        address="series/bigger",
        kind="series",
        year=_SERIES["year"],
        description=_SERIES["blurb"],
        image=_image("ForBiggerBlazes"),
        image_source="portal",
        image_wide=True,
        languages=["EN"],
        has_children=True,
    )


def _all_items() -> list[Item]:
    return [_series_item()] + [_as_item(f) for f in _FILMS]


def _episode(key: str) -> dict[str, Any] | None:
    for e in _SERIES["episodes"]:
        if e["key"] == key:
            return e
    return None


def _key_of(address: str) -> str:
    """The catalogue key behind an address this portal handed out.

    Everything arriving here was produced by this portal, so the parsing is
    trivial — but it is still parsing, and it still has to survive an address
    it never produced. Whoever calls a portal is allowed to be wrong.
    """
    return address.rsplit("/", 1)[-1] if "/" in address else address


class Portal:
    """Seven methods. That is the whole interface.

    `id` must match `id:` in `portal.yml`; `capabilities` must match the list
    there. The server does not reconcile the two for you — it reads the
    manifest for the console and calls this class for the data, and a portal
    that claims `search` here but not there simply never gets asked.
    """

    id = "beispiel"
    name = "Example Portal"
    # `ClassVar` because this set is shared by every instance and never
    # reassigned. Python does not care; the linter does, and a template that
    # arrives with a warning teaches the warning.
    capabilities: ClassVar[set[str]] = {"search", "seasons", "paging", "own_images", "subtitles"}

    def __init__(self) -> None:
        #: How many items one page holds. Overridden by `configure()`.
        self._page_size = PAGE_SIZE

    def configure(self, settings: dict[str, str]) -> None:
        """What the operator filled in — **optional, and called before anything else.**

        The runner calls this once per child process with the values from
        `portal.yml`, the operator's entries already merged over your defaults.
        A portal without settings does not need this method at all.

        Note what it does **not** do: it does not validate. A `page_size` of
        `"banana"` falls back to the default rather than raising — the operator
        typed it into a text field, and a portal that refuses to start over a
        typo is a portal nobody can fix from the console.
        """
        try:
            gewuenscht = int(settings.get("page_size", "") or PAGE_SIZE)
        except ValueError:
            gewuenscht = PAGE_SIZE
        self._page_size = max(1, min(50, gewuenscht))

    # ── The entry screen ────────────────────────────────────────────────────

    def menu(self) -> list[Entry]:
        """The rows a viewer sees first.

        `group` sorts them: `curated` above the line, `library` below it.
        `count` is a number the viewer can trust or `None` — and `None` means
        "unknown", never zero. A confident 0 next to a row that has items is
        worse than no number at all.
        """
        return [
            Entry(id="films", name="Films", icon="🎬", count=len(_FILMS), group="curated"),
            Entry(id="series", name="Series", icon="📺", count=1, group="curated"),
            Entry(id="all", name="Everything", icon="🗂", count=len(_FILMS) + 1, group="library"),
        ]

    def listing(self, entry: str, next_page: str | None = None, user_input: str = "") -> Page:
        """One page of a row.

        `next_page` is whatever this portal put there last time — here a page
        number as text. The server hands it back untouched and never looks
        inside it, which is why a cursor works just as well.

        `user_input` carries an answer to a question this portal asked via
        `Page.needs_input`. This example never asks, so it is unused — the
        parameter stays in the signature because the server always passes it.
        """
        if entry == "films":
            pool = [_as_item(f) for f in _FILMS]
        elif entry == "series":
            pool = [_series_item()]
        elif entry == "all":
            pool = _all_items()
        else:
            # **An unknown entry is a caller error and gets a code.** Not an
            # empty page: that would look like a row that emptied out, and the
            # operator would go looking at the wrong end.
            raise f.Error("portal.unknown_entry", {"entry": entry[:40]}, status=404)

        seite = max(1, int(next_page) if (next_page or "").isdigit() else 1)
        von = (seite - 1) * self._page_size
        stueck = pool[von : von + self._page_size]

        # An empty level is not an error — see the note at the top of the file.
        if not stueck:
            return Page(items=[], note="Nothing on this page.")

        weiter = str(seite + 1) if von + self._page_size < len(pool) else None
        return Page(items=stueck, next_page=weiter, total=len(pool))

    # ── Down one level ──────────────────────────────────────────────────────

    def children(self, item: Item) -> list[Item]:
        """What lies underneath — here: the episodes of the one series.

        A film has nothing underneath, and that is an empty list, not an error.
        """
        if not item.address.startswith("series/"):
            return []
        return [
            Item(
                title=e["title"],
                address=f"episode/{e['key']}",
                kind="episode",
                number=e["number"],
                year=_SERIES["year"],
                duration_min=e["minutes"],
                image=_image(e["key"]),
                image_source="portal",
                image_wide=True,
                languages=["EN"],
            )
            for e in _SERIES["episodes"]
        ]

    # ── Towards something playable ──────────────────────────────────────────

    def sources(self, item: Item) -> list[Source]:
        """The sources or quality steps behind an item — still not a video.

        Splitting this off from `resolve()` is what lets the server work
        through a list: when the first source is dead, it tries the second
        without asking the viewer anything.

        A source that cannot work says so with `blocked` and a `reason`. It
        stays in the list on purpose — a source that needs an account the
        household has not set up is something the viewer should see, not
        something that silently is not there.
        """
        key = _key_of(item.address)
        bekannt = {f["key"] for f in _FILMS} | {e["key"] for e in _SERIES["episodes"]}
        if key not in bekannt:
            raise f.Error("portal.unknown_item", {"address": item.address[:60]}, status=404)

        return [
            Source(
                id=f"{key}:{stufe}",
                name=beschriftung,
                # The page a human would open, not the video. A playback
                # policy may use it as a last way (`PlaybackPolicy.last_resort`).
                address=f"{BUCKET}/{key}.mp4",
                language="EN",
            )
            for stufe, beschriftung in _QUALITIES
        ]

    def resolve(self, source: Source) -> Stream:
        """One source turned into an address a player can open.

        `resolved=True` means the address is the video. A scraper that only
        gets as far as a host page returns `resolved=False` with that page, and
        the server takes it from there.

        `valid_until` is not a performance trick. A player fetches an address
        twice — a HEAD, then the GET — and single-use host tokens burn on the
        first of those. `None` means "do not cache", which is the safe answer
        when you do not know.
        """
        key = source.id.split(":", 1)[0]
        return Stream(
            address=f"{BUCKET}/{key}.mp4",
            kind="file",
            resolved=True,
            resolution="1080p" if source.id.endswith(":1080") else "720p",
            # Declared `subtitles` in the manifest, so return the field even
            # when a title has none — an empty list is an answer, a missing
            # field is a question.
            subtitles=self._subtitles(key),
            headers={},
            valid_until=None,
        )

    @staticmethod
    def _subtitles(key: str) -> list[dict]:
        """Subtitles for a catalogue key, in the shape the app expects.

        Three fields, all English-named: `language`, `format`, `address`.
        Only the films carry them here; the one-minute clips do not, and an
        empty list says that plainly.
        """
        if key not in {"BigBuckBunny", "Sintel", "TearsOfSteel", "ElephantsDream"}:
            return []
        return [{"language": "en", "format": "vtt", "address": f"{BUCKET}/{key}.vtt"}]

    # ── Finding things ──────────────────────────────────────────────────────

    def search(self, text: str) -> list[Item]:
        """Free text over the catalogue.

        Case-folded substring matching, which is the least a portal can do and
        still be honest about declaring `search`. No results is an empty list,
        not an error.
        """
        frage = text.strip().casefold()
        if not frage:
            return []
        return [
            item
            for item in _all_items()
            if frage in item.title.casefold() or frage in (item.description or "").casefold()
        ]

    def series(self, address: str) -> str | None:
        """Which series an address belongs to — its title, or `None`.

        **This is the one question that makes a per-series language preference
        possible at all.** The preference sits on the series row; to find it
        while playing an *episode*, the episode address has to become its
        series. Only the portal can answer that, because only the portal knows
        how its own addresses are built.

        A portal without series returns `None`, and then there is nothing to
        steer centrally either.
        """
        if address.startswith("series/"):
            return str(_SERIES["title"])
        if address.startswith("episode/") and _episode(_key_of(address)):
            return str(_SERIES["title"])
        return None
