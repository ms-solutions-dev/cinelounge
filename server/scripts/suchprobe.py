#!/usr/bin/env python3
"""Does a portal's search find what the portal itself offers?

**The case this script exists for.** The ZDF search sorted by date. A search
for "krimireihe" gave eight hits, one of which carried the word in its title — the
rest were the broadcaster's newest items, right across the schedule. Nobody
noticed: the nightly run checks `menu → listing → sources → resolve` and does
not touch the search, and a test for it would need the network.

## How it is checked

For every portal that can `search`:

1. Fetch an entry from its **own menu** — any list.
2. Take a **word from its title** as the search term (the longest one, so it
   says something: "Kreidespur" rather than "die").
3. Search — and see whether the title turns up again.

**No invented search term.** What the portal offers right now it must also
find; anything else is a claim about somebody else's catalogue.

**No verdict on zero hits.** Media libraries search descriptions too and have
items that vanish after days — what counts is the rate across several samples,
and that stands at the end.

    python scripts/suchprobe.py                    # all portals
    python scripts/suchprobe.py zdf 3sat           # only these
    python scripts/suchprobe.py --basis https://cl.example --pin 1234
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

#: Words that are useless as a search term.
#:
#: They occur in every second title; a hit with one says nothing about the
#: search, only about the size of the catalogue.
LEISE = {
    "der",
    "die",
    "das",
    "ein",
    "eine",
    "und",
    "oder",
    "mit",
    "von",
    "für",
    "auf",
    "aus",
    "bei",
    "dem",
    "den",
    "des",
    "ist",
    "nicht",
    "sich",
    "the",
    "and",
    "for",
    "folge",
    "teil",
    "staffel",
    "episode",
    "season",
}

_OHNE_PRUEFUNG = ssl.create_default_context()
_OHNE_PRUEFUNG.check_hostname = False
_OHNE_PRUEFUNG.verify_mode = ssl.CERT_NONE


def ruf(basis: str, pfad: str, merkmal: str | None = None, leib: dict | None = None):
    kopf = {"Content-Type": "application/json"}
    if merkmal:
        kopf["X-CL-Device"] = merkmal
    r = urllib.request.Request(
        basis + pfad,
        data=None if leib is None else json.dumps(leib).encode(),
        headers=kopf,
        method="GET" if leib is None else "POST",
    )
    with urllib.request.urlopen(r, timeout=120, context=_OHNE_PRUEFUNG) as a:
        return json.load(a)


def suchwort(titel: str) -> str | None:
    """The most telling word of a title — or none.

    The longest one that is not in `LEISE` and has at least four characters.
    Numbers drop out: "2026" finds half the catalogue.
    """
    woerter = [w.strip("„“\"'()[]:,.!?-–—") for w in titel.split()]
    taugliche = [
        w
        for w in woerter
        if len(w) >= 4 and w.lower() not in LEISE and not w.replace(".", "").isdigit()
    ]
    return max(taugliche, key=len) if taugliche else None


def probe(basis: str, merkmal: str, pid: str) -> tuple[int, int, list[str]]:
    """Three samples for one portal. Returns `(found, tried, lines)`."""
    zeilen: list[str] = []
    try:
        menu = ruf(basis, f"/p/{urllib.parse.quote(pid)}/menu", merkmal).get("entries") or []
    except urllib.error.HTTPError as err:
        return 0, 0, [f"  menu not reachable ({err.code})"]
    if not menu:
        return 0, 0, ["  kein Einstieg"]

    kandidaten: list[str] = []
    for eintrag in menu[:4]:
        if len(kandidaten) >= 3:
            break
        try:
            d = ruf(
                basis,
                f"/p/{urllib.parse.quote(pid)}/list?entry={urllib.parse.quote(eintrag['id'])}",
                merkmal,
            )
        except urllib.error.HTTPError:
            continue
        for i in d.get("items") or []:
            titel = str(i.get("title") or "")
            wort = suchwort(titel)
            if wort and titel not in [k[0] for k in kandidaten]:
                kandidaten.append((titel, wort))
            if len(kandidaten) >= 3:
                break

    if not kandidaten:
        return 0, 0, ["  nichts gefunden, wonach sich suchen liesse"]

    gefunden = 0
    for titel, wort in kandidaten:
        try:
            d = ruf(
                basis,
                f"/search?q={urllib.parse.quote(wort)}&portal={urllib.parse.quote(pid)}",
                merkmal,
            )
        except urllib.error.HTTPError as err:
            zeilen.append(f'  "{wort}" → error {err.code}')
            continue
        treffer = d.get("hits", {}).get(pid) or []
        titel_klein = titel.casefold()
        dabei = any(str(t.get("title") or "").casefold() == titel_klein for t in treffer)
        im_titel = sum(
            1 for t in treffer if wort.casefold() in str(t.get("title") or "").casefold()
        )
        gefunden += dabei
        marke = "✓" if dabei else "·"
        zeilen.append(
            f'  {marke} "{wort}" → {len(treffer):3} hits, {im_titel} with the word in the title'
            + ("" if dabei else f"  (was looking for: {titel[:40]})")
        )
    return gefunden, len(kandidaten), zeilen


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("portale", nargs="*", help="only these; without any, all with `search`")
    p.add_argument("--basis", default="https://cl.example")
    p.add_argument("--name", default=os.environ.get("CL_NAME", "admin"))
    # No default: the household PIN lives in `CL_PIN` or on the command line,
    # never in the repository. Same rule as in `screenshots.py`.
    p.add_argument("--pin", default=os.environ.get("CL_PIN", ""))
    args = p.parse_args()
    if not args.pin:
        print("no PIN: set CL_PIN in the environment or pass --pin", file=sys.stderr)
        return 2

    basis = args.basis.rstrip("/")
    try:
        merkmal = ruf(basis, "/login", leib={"name": args.name, "pin": args.pin})["device_token"]
    except OSError as err:
        print(f"{basis} does not answer: {err}", file=sys.stderr)
        return 2

    portale = args.portale
    if not portale:
        alle = ruf(basis, "/portals", merkmal).get("portals") or []
        portale = [x["id"] for x in alle if "search" in (x.get("capabilities") or [])]

    gesamt_gut = gesamt = 0
    for pid in portale:
        print(f"\n── {pid} " + "─" * (40 - len(pid)))
        gut, wie_viele, zeilen = probe(basis, merkmal, pid)
        print("\n".join(zeilen))
        gesamt_gut += gut
        gesamt += wie_viele

    print(f"\n{gesamt_gut} of {gesamt} samples found their own title again.")
    # **No return value other than 0, unless the service was unreachable.** A
    # rate is not a verdict: a portal that searches descriptions can have a poor
    # rate and still work correctly. Whoever reads this decides for themselves.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
