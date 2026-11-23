#!/usr/bin/env python3
"""One pass per portal — from the menu to the video address, over HTTP.

**The check that counts.** Not whether the code imports, but whether an
address a player can open stands at the end. It takes the same path as the
Apple TV and finishes with a HEAD request on whatever came out.

    docker compose exec -T cinelounge python scripts/walkthrough.py
    docker compose exec -T cinelounge python scripts/walkthrough.py zdf
    docker compose exec -T cinelounge python scripts/walkthrough.py zdf:<entry-id>

The third form picks the entry point. It is needed with portals that only know
"folder" and "playable" and mark their control panels as both: when "Global
Search" stands first, beneath it lie switches, presets and the search history,
not a single video.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

BASIS = os.environ.get("CL_BASIS", "http://127.0.0.1:8099")
MERKMAL = os.environ.get("CL_MERKMAL", "")


def hol(path: str, **frage: object) -> tuple[int, dict]:
    u = BASIS + path + ("?" + urllib.parse.urlencode(frage) if frage else "")
    r = urllib.request.Request(u, headers={"X-CL-Device": MERKMAL})
    try:
        with urllib.request.urlopen(r, timeout=120) as a:
            return a.status, json.load(a)
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.load(e)
        except Exception:
            return e.code, {}


def _hinab(pid: str, candidates: list[dict], depth: int = 0, watched: set | None = None):
    """Descend until something arrives that is no longer a folder.

    **With loop detection, and that is not convenience.** Where there are only
    "folder" and "playable", a search field looks like a folder and leads back
    to itself when opened: "Search 10 sources" three times in a row, five
    entries each time, the same ones each time.
    Whoever blindly follows the first child ends up checking an input field
    and reports an error that is none.

    Hence: try up to three siblings, remember titles, and give up instead of
    running in circles.
    """
    watched = watched if watched is not None else set()
    if depth > 3:
        return None
    for item in candidates[:3]:
        if not item.get("has_children"):
            return item
        token = (item.get("title") or "") + "|" + str(item.get("address") or "")[:80]
        if token in watched:
            continue
        watched.add(token)
        st, k = hol("/p/" + pid + "/children", address=item["address"], title=item.get("title", ""))
        if st != 200 or not k.get("items"):
            continue
        print(f'   children: {len(k["items"])} under "{item.get("title", "")}"')
        tiefer = _hinab(pid, k["items"], depth + 1, watched)
        if tiefer is not None:
            return tiefer
    return None


def durchgang(pid: str, nur_einstieg: str = "") -> bool:
    print("\n== " + pid)
    begonnen = time.time()

    st, d = hol("/p/" + pid + "/menu")
    if st != 200:
        print("   menu    : " + str(st) + " " + str(d.get("error", {}).get("code")))
        return False
    einstiege = d["entries"]
    erste = ", ".join(e["name"] for e in einstiege[:3])
    print(f"   menu    : {len(einstiege)} entries — {erste}")
    if not einstiege:
        return False

    # "Neue Folgen" leads to an episode by the shortest path: one step instead
    # of three. **Try several entry points, not only the first.** Sometimes
    # the first is called "Global Search" and is a control panel of the
    # portal — beneath it lie only switches, presets and the search history.
    # Whoever stops there reports an error that is none.
    if nur_einstieg:
        bevorzugt = [
            e for e in einstiege if nur_einstieg.lower() in (e["id"] + " " + e["name"]).lower()
        ]
    else:
        bevorzugt = [e for e in einstiege if "Folgen" in e["name"]]
        bevorzugt += [e for e in einstiege if e not in bevorzugt]

    item = None
    for e in bevorzugt[:4]:
        # `entry` and not `einstieg`: the server has spoken English since the
        # rename, this tool was not carried along. Every call came back 422,
        # and the walkthrough read that as "empty entry" (`list.no_entry`) —
        # eight portals thereby reported "no playable item reachable" although
        # the service was fine. Found 11.09.2026 while proving the buffer.
        st, d = hol("/p" + "/" + pid + "/list", entry=e["id"])
        if st != 200 or not d.get("items"):
            note = d.get("note") or d.get("needs_input") or d.get("error", {}).get("code")
            print('   list    : "{}" empty — {}'.format(e["name"][:24], note))
            continue
        items = d["items"]
        weiter = "yes" if d.get("next") else "no"
        print(f'   list    : {len(items)} items via "{e["name"]}" · next={weiter}')
        item = _hinab(pid, items)
        if item is not None:
            break
        print("             only folders and inputs beneath — next entry")

    if item is None:
        print("   ✗ no playable item reachable")
        return False

    print("   target  : {} ({})".format(item.get("title"), item.get("kind")))

    st, q = hol("/p/" + pid + "/sources", address=item["address"], title=item.get("title", ""))
    sources = q.get("sources") or []
    if st != 200 or not sources:
        print("   sources : {} · {}".format(st, q.get("error", {}).get("code") or "none"))
        return False
    namen = ", ".join((x["name"] or "?") + " " + (x.get("language") or "") for x in sources[:4])
    print(f"   sources : {len(sources)} — {namen}")

    t = time.time()
    st, p = hol("/play", portal=pid, source=sources[0]["id"])
    if st != 200:
        print("   play    : {} · {}".format(st, p.get("error", {}).get("code")))
        return False
    print(f"   play    : {(time.time() - t) * 1000:.0f} ms → {p['address'][:76]}")

    # The cross-check: is there really a video, or only a page?
    r = urllib.request.Request(p["address"], method="HEAD")
    try:
        with urllib.request.urlopen(r, timeout=60) as a:
            kind = a.headers.get("content-type", "?")
            size = int(a.headers.get("content-length") or 0)
            progress = a.status
    except Exception as err:
        print("   probe   : no HEAD — " + str(err)[:60])
        return False
    gut = kind.startswith("video/") or "mpegurl" in kind or "octet-stream" in kind
    urteil = "abspielbar" if gut else "kein Video"
    print(f"   probe   : {progress} · {kind} · {size // 1048576} MB · {urteil}")
    print(f"   ── {time.time() - begonnen:.1f} s in total")
    return gut


def main() -> int:
    if not MERKMAL:
        print("CL_MERKMAL missing — a device token is needed.")
        return 2
    st, d = hol("/portals")
    if st != 200:
        print("/portals: " + str(st) + " " + str(d))
        return 2
    # `portal:entry` picks deliberately. Where folders and items are all a
    # portal knows, no runner can tell a control panel from a folder — some
    # portals even mark their input fields as playable (`One time search`
    # comes with `kind: movie`). Measured 10.09.2026.
    gewuenscht = sys.argv[1:] or [p["id"] for p in d["portals"]]
    result = {}
    for wanted in gewuenscht:
        pid, _, ein = wanted.partition(":")
        try:
            result[pid] = durchgang(pid, ein)
        except Exception as err:
            print("   ✗ " + type(err).__name__ + ": " + str(err)[:150])
            result[pid] = False
    print("\n" + "=" * 58)
    for pid, gut in result.items():
        print("  " + ("ok  " if gut else "FAIL") + "  " + pid)
    return 0 if all(result.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
