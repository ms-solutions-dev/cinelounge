"""Check one portal end to end — from the menu to the video address.

**The check that counts.** Not whether the code imports, but whether there is
an address at the end that a player can open. The same chain as
`scripts/walkthrough.py`, but from the inside instead of over HTTP: the nightly
run belongs in the service, not in a tool somebody starts by hand.

## Why this lives here and not in `household`

Foreign code runs here. Every step goes through `runner.call()` into a child
process with a memory limit and a deadline; what comes back is JSON. The
household knows nothing about that and should not — it only keeps the book
(`household/nights.py`).

## What "carried" means

Four steps, and each has to carry the next:

| | |
|---|---|
| `menu` | the portal answers and names entry points |
| `listing` | an entry point yields items |
| `sources` | an item yields sources |
| `resolve` | a source becomes an address |

**Without `resolve` it has not carried.** A portal that browses but does not
play is exactly what `INHALTE.md` warns about for BBC iPlayer: a sidebar full
of titles, none of which start.

**The address is probed, with sixteen bytes** (since 08.11.2026). Before that
it was not fetched at all — "where `resolve()` hands back an address, the portal
has done its work". That was not always true: a source that hands out an HTML
page as a finished `stream` counts as resolved, and the book stayed green while
nothing played. One probe per portal and night is the price of the book
meaning what it says.

## Why several entry points are tried

A portal's first entry point is not always content: it can be a control panel
— switches, presets, a search history — with not a single video beneath it.
Whoever stops there reports a fault that is none.

## Why several titles are tried

A list of the newest titles often opens with titles announced but not out yet —
no source. One title per entry made such a list red every night while it played
on the television. Up to three titles per entry and six per portal, inside a
time budget: a green portal costs nothing extra, a red one a handful of calls.

## Extensions

A `NightlyHook` (`portalworks/extension.py`) may reorder the entry points a
check tries (`order_entries`), and hears what came out (`after`, called by
`web/nightwatch.py`).
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from typing import Any, Final

from cinelounge.core import errors as f
from cinelounge.portalworks import extension, routes
from cinelounge.portalworks.manifest import Manifest
from cinelounge.portalworks.runner import call as runner
from cinelounge.portalworks.runner.fork import Limits
from cinelounge.stream import probe

_LOG = logging.getLogger("cinelounge.nachtlauf")

#: How many entry points are tried at most.
#:
#: Four. Whoever has found nothing by then is looking at a portal that does not
#: carry its items in the first four rows — and that is a finding in itself.
TRY_ENTRIES: Final = 4

#: How deep collections are descended.
#:
#: Series → season → episode is three. Four leaves room for one intermediate
#: step (`All videos`, `Collection`), and no deeper than that: what lies
#: further down, a viewer will not find either.
MAX_DEPTH: Final = 4

#: A deadline of its own for the nightly run.
#:
#: More generous than in service (20 s): at night nobody is waiting, and a
#: portal that scrapes through during the day should not count as broken over
#: two seconds. Memory stays as it is — a higher limit at night would be a
#: different environment from the one being checked.
LIMITS: Final = Limits(deadline_s=45.0)

#: How many titles of one listing are tried before the next entry point.
#:
#: Three (16.11.2026). A list of new titles opened with titles that are
#: announced but not out yet — no sources — and the run went red on the
#: first of them every night while the same list played on the television.
TITLES_PER_ENTRY: Final = 3

#: How many titles are tried per portal and night, across all entry points.
#:
#: Six: a portal that is green costs exactly as many calls as before, and a
#: red one at most a handful more — `sources` per extra title, and `resolve`
#: for at most three of its sources.
MAX_TITLES: Final = 6

#: The time one portal may take in all, in seconds.
#:
#: Each call has its own deadline (`LIMITS`), but more attempts mean more
#: calls. Before every call it is checked whether the budget is spent; a call
#: already under way is not cut off, so the run ends at most one deadline
#: later.
BUDGET_S: Final = 300.0

#: Menu groups that are not content (`Entry.group`, `core/contract.py`).
#:
#: Favourites, a vault, "Clear cache": the app folds them away, and the night
#: has nothing to find there either.
NOT_CONTENT: Final = frozenset({"tools", "mine"})


@dataclass(frozen=True, slots=True)
class Result:
    """What one run produced."""

    portal_id: str
    ok: bool
    step: str
    """How far it got — including on success (`resolve`)."""
    reason: str
    ms: int
    address: str = ""
    """The address that came out. For looking at only; it is not fetched."""


def check(m: Manifest, limits: Limits | None = None, budget_s: float = BUDGET_S) -> Result:
    """Check one portal end to end. **Never raises.**

    A nightly run across eleven portals must not stop at the second one — what
    the third would have done is precisely the answer it runs for.

    **Green on the first title that delivers a video.** A title without
    sources, or whose sources all fail to resolve, sends the run to the next
    title of the same listing (`TITLES_PER_ENTRY`), then to the next entry
    point — at most `MAX_TITLES` titles and `budget_s` seconds in all. Red
    only when every attempt failed; the reason then names the last failure
    and how many titles were tried.
    """
    begonnen = time.monotonic()
    grenzen = limits or LIMITS

    def ueberzogen() -> bool:
        return time.monotonic() - begonnen >= budget_s

    def fertig(ok: bool, step: str, reason: str = "", address: str = "") -> Result:
        return Result(
            m.id, ok, step, reason[:300], round((time.monotonic() - begonnen) * 1000), address
        )

    if not m.is_ready:
        return fertig(False, "manifest", m.broken_reason or "broken")

    # ── menu ────────────────────────────────────────────────────────────────
    try:
        einstiege = runner.call(m, "menu", {}, grenzen) or []
    except f.Error as err:
        return fertig(False, "menu", _grund(err))
    except Exception as err:
        return fertig(False, "menu", type(err).__name__ + ": " + str(err))

    if not einstiege:
        return fertig(False, "menu", "no entries")

    # **Tools and the viewer's own areas are no entry points** (16.11.2026).
    # Menus that open with a vault, favourites and cache switches made the run
    # spend its four tries there. Should nothing else be left, they stay — a
    # red night over a filter would say nothing.
    menu = list(einstiege)
    einstiege = content_entries(menu)
    for hook in extension.NIGHTLY_HOOKS:
        try:
            einstiege = list(hook.order_entries(m, menu, einstiege, grenzen))
        except Exception as err:  # a hook must not turn the night red
            _LOG.warning("Nightly hook failed for %s: %s", m.id, type(err).__name__)

    # ── listing ─────────────────────────────────────────────────────────────
    letzter_grund = "no entry gave items"
    letzter_schritt = "listing"
    versuche = 0

    def gescheitert() -> Result:
        if not versuche:
            return fertig(False, letzter_schritt, letzter_grund)
        anzahl = f"{versuche} title" + ("" if versuche == 1 else "s")
        # The count goes first: the reason is cut at 300 characters.
        return fertig(False, letzter_schritt, f"{anzahl} tried; last: {letzter_grund}")

    for e in einstiege[:TRY_ENTRIES]:
        if versuche >= MAX_TITLES or ueberzogen():
            break
        try:
            seite = runner.call(m, "listing", {"entry": e.get("id", "")}, grenzen) or {}
        except f.Error as err:
            letzter_grund, letzter_schritt = _grund(err), "listing"
            continue
        except Exception as err:
            letzter_grund, letzter_schritt = type(err).__name__ + ": " + str(err), "listing"
            continue

        items = seite.get("items") or []
        if not items:
            # A level that wants input is not empty — it is waiting. That is
            # not a failure of the portal.
            letzter_grund = str(seite.get("needs_input") or seite.get("note") or "empty listing")
            letzter_schritt = "listing"
            continue

        titel = _hinab(m, items, grenzen, TITLES_PER_ENTRY)
        if not titel:
            letzter_grund = "no playable item within " + str(MAX_DEPTH) + " levels"
            letzter_schritt = "listing"
            continue

        for eintrag in titel:
            if versuche >= MAX_TITLES or ueberzogen():
                break
            versuche += 1

            # ── sources ─────────────────────────────────────────────────────
            try:
                quellen = (
                    runner.call(
                        m,
                        "sources",
                        {"address": eintrag.get("address", ""), "title": eintrag.get("title", "")},
                        grenzen,
                    )
                    or []
                )
            except f.Error as err:
                letzter_grund, letzter_schritt = _grund(err), "sources"
                continue
            except Exception as err:
                letzter_grund, letzter_schritt = type(err).__name__ + ": " + str(err), "sources"
                continue

            offen = [q for q in quellen if not q.get("blocked")]
            if not offen:
                gesperrt = len(quellen)
                letzter_grund = f"no open source ({gesperrt} blocked)" if gesperrt else "no sources"
                letzter_schritt = "sources"
                continue

            # ── resolve ─────────────────────────────────────────────────────
            gruende = []
            for q in offen[:3]:
                if ueberzogen():
                    gruende.append("time budget spent")
                    break
                try:
                    strom = runner.call(m, "resolve", {"source": q.get("id", "")}, grenzen) or {}
                except f.Error as err:
                    gruende.append(_grund(err))
                    continue
                except Exception as err:
                    gruende.append(type(err).__name__ + ": " + str(err))
                    continue

                adresse = str(strom.get("address") or "")
                if not (strom.get("resolved") and adresse):
                    gruende.append("not resolved: " + (q.get("name") or "?"))
                    continue
                # **An address is a claim; the probe is the proof** (08.11.2026).
                # Until then the run trusted any resolved address, and a source
                # that hands out an HTML page as `stream` counted as carried. One
                # probe per night and portal, through the portal's own route.
                if not _klopfen(adresse, dict(strom.get("headers") or {}), routes.proxy_for(m)):
                    gruende.append("no video behind: " + (q.get("name") or "?"))
                    continue
                return fertig(True, "resolve", "", adresse)

            letzter_grund = "; ".join(gruende) or "no source resolved"
            letzter_schritt = "resolve"

    if ueberzogen() and versuche < MAX_TITLES:
        letzter_grund += f" (time budget of {round(budget_s)} s spent)"
    return gescheitert()


def content_entries(menu: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The menu without tools and the viewer's own areas (`NOT_CONTENT`) — or
    the whole menu, should nothing else be left."""
    return [e for e in menu if e.get("group") not in NOT_CONTENT] or menu


def _klopfen(address: str, headers: dict[str, str], via: str | None) -> bool:
    """Does a video stand behind the address? A protected one counts as carried.

    DRM is a finding about the content, not a broken portal — the night book
    is not the place for it.
    """
    try:
        return probe.probe(address, headers, via)
    except probe.DrmError:
        return True


def _hinab(
    m: Manifest, items: list[dict[str, Any]], limits: Limits, count: int = 1
) -> list[dict[str, Any]]:
    """Find the first playable items — at most `count`, at most `MAX_DEPTH` levels down.

    **Breadth before depth would be the wrong way round.** A series has
    seasons, a season has episodes; the shortest path to something playable
    goes straight down and not through all the siblings. The further titles
    are the siblings of the first one, on the same level.

    Dividers (`kind == "separator"`) are no titles: a portal's level
    carries them between content, own areas and tools.
    """
    for tiefe in range(MAX_DEPTH):
        items = [i for i in items if i.get("kind") != "separator"]
        ohne_kinder = [i for i in items if not i.get("has_children")]
        if ohne_kinder:
            return ohne_kinder[:count]

        mit_kindern = [i for i in items if i.get("has_children")]
        if not mit_kindern or tiefe == MAX_DEPTH - 1:
            return []

        erster = mit_kindern[0]
        try:
            kinder = (
                runner.call(
                    m,
                    "children",
                    {"address": erster.get("address", ""), "title": erster.get("title", "")},
                    limits,
                )
                or []
            )
        except Exception:
            return []
        if not kinder:
            return []
        items = kinder
    return []


def _grund(err: f.Error) -> str:
    """An error code with its values, short enough for one line.

    **The code alone is not enough.** `run.crashed` sends the operator
    searching; what sits behind it is often something like "API key is not
    set" — a setting, not a fault.
    """
    werte = err.values or {}
    text = str(
        werte.get("text") or werte.get("why") or werte.get("reason") or werte.get("host") or ""
    )
    return err.code + (": " + text if text else "")
