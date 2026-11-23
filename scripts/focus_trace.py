#!/usr/bin/env python3
"""Reads the focus trace from the log and finds the corrections.

    ./scripts/focus_trace.py            last 15 minutes
    ./scripts/focus_trace.py 60m        last hour
    ./scripts/focus_trace.py --all    including the unremarkable paths
    ./scripts/focus_trace.py --file diagnose/2026-08-23_1804_diagnose.log

**What is searched for is a pattern and not a single place.** A key press moves the
focus once. If it appears a second time in the trace shortly afterwards, it was not
the viewer who moved it but the view — it corrects what tvOS assigned by geometry.
That is exactly what one sees on the TV as a flash: the wrong target stands there
brightly for one frame.

    [Key]  Detailseite  ↓
    [Focus]  Detailseite  play → season-s2       (+12 ms)
    [Focus]  Detailseite  season-s2 → season-s6  (+4 ms)   ← correction

The value of this tool is that it finds **all** such places and not the one where
someone happened to look. What it reports is not necessarily an error: A correction
that reaches no eye is merely a detour. It only becomes visible when a frame was drawn
between the two lines — at 60 frames per second that is from about 16 ms.
"""

import pathlib
import re
import subprocess
import sys

SUBSYSTEM = "dev.ms-solutions.cinelounge"

# From which gap a correction can become visible: one frame.
FRAME_MS = 16
# Up to which gap two lines still count as "one event". Above that it was a second
# action and not a correction.
#
# **400 ms was too wide** (re-measured on 26.08. on
# diagnose/2026-08-23_1804_diagnose.log): tvOS repeats a held press every 100 ms — 35
# of the 121 reported pairs lay at exactly 100 or 101 ms and were ordinary scrolling
# through the episode list. Between 63 and 79 ms there is no pair in this trace; 64 ms
# sits in that gap, two milliseconds above the next real value. Four frames separate
# the correction from the next step. Together with the folding in `merged` the reports
# of this trace fall from 121 to 11 — the limit alone brings 27, the folding alone 105.
TOGETHER_MS = 4 * FRAME_MS

# The dwell time ("dwelled X ms") is carried only by focus lines, and only since
# 15.08. — it therefore stays optional so that older traces remain readable.
# Since 04.09. (key ledger) the views' commands are called "Command", and focus lines
# as well as command lines carry their relation to the press ("+37 ms after ↑" or
# "no key") — for this tool a command remains a key.
LINE = re.compile(
    r"\[(?P<kind>Focus|Key|Command)\]\s+(?P<area>.+?)\s\s+(?P<content>.*?)"
    r"\s+\(\+(?P<ms>-?\d+) ms(?:, dwelled (?P<dwell>-?\d+) ms)?(?:, [^)]*)?\)"
)

# The same trace, different notation — this is how it appears in the report from the
# settings (`Diagnostics.Trace.Entry.reportLine`, Diagnostics.swift:141). The report is
# what remains of a session on the TV; `log show` does not exist there.
REPORT = re.compile(
    r"^\S+\t(?P<kind>Focus|Key|Command)\s\s+(?P<area>.+?)\s\s+[✓✗]\s(?P<content>.*?)"
    r"\s\s+(?:\+(?P<ms>-?\d+) ms(?: after \S+)?|no key)"
    r"(?:, dwelled (?P<dwell>-?\d+) ms)?\s*$"
)


def main_area(area: str) -> str:
    """The area without its subdivision.

    Focus and key lines of the same view do not carry the same area: The focus lines of
    the detail page come from `.focusTrail("Detailseite", …)` (DetailView.swift:253),
    but its key lines from the finer calls "Detailseite · Knöpfe" (:443) and
    "Detailseite · Staffeln" (:983). Compared for equality the two never find each
    other. On the trace of 23.08. that changes nothing (121 reports before as after) —
    it contains no season navigation. The rule is justified from the source and not
    from this measurement.

    >>> main_area("Detailseite · Staffeln"), main_area("Seitenleiste")
    ('Detailseite', 'Seitenleiste')
    """
    return area.split(" · ")[0].strip()


def trace(span: str) -> list[str]:
    """Fetches the trace lines from the running simulator."""
    return subprocess.run(
        [
            "xcrun", "simctl", "spawn", "booted", "log", "show",
            "--last", span, "--info",
            "--predicate", f'subsystem == "{SUBSYSTEM}" AND category == "focus"',
            "--style", "compact",
        ],
        capture_output=True, text=True,
    ).stdout.splitlines()


def parsed(lines: list[str]) -> list[dict]:
    r"""Turns trace lines into entries — both notations yield the same.

    >>> from_log = parsed(["[Focus]  Live  a → b  (+12 ms, dwelled 30 ms)"])
    >>> from_report = parsed(["2026-08-23T15:02:05Z\tFocus  Live  ✓ a → b  +12 ms, dwelled 30 ms"])
    >>> from_log == from_report
    True
    >>> from_log[0]["area"], from_log[0]["content"], from_log[0]["ms"], from_log[0]["dwell"]
    ('Live', 'a → b', 12, 30)
    """
    entries = []
    for line in lines:
        match = REPORT.match(line) or LINE.search(line)
        if not match:
            continue
        entries.append(
            {
                "kind": "Key" if match["kind"] == "Command" else match["kind"],
                "area": match["area"].strip(),
                "content": match["content"].strip(),
                "ms": int(match["ms"]) if match["ms"] else 0,
                "dwell": int(match["dwell"]) if match["dwell"] else None,
            }
        )
    return entries


# Up to which gap a key line AFTER its focus line still belongs to it. The
# `onMoveCommand` lines come in the middle of a list only after the focus change
# (measured on 15.08.: 4–180 ms) — a focus line with such a key immediately behind it is
# an ordinary step, not a correction.
STRAGGLER_MS = 200


def _source(entry: dict) -> str:
    return entry["content"].split(" → ")[0].strip()


def _target(entry: dict) -> str:
    return entry["content"].split(" → ")[-1].strip()


def merged(entries: list[dict]) -> list[dict]:
    """Folds the detour via "—" into a single step.

    The grid emits **two** focus lines per step because the binding runs back through
    nil: first `a → —`, then `— → b`. That is not a flash — as long as nobody has the
    focus, no wrong target lights up either, and that is exactly what this tool looks
    for.

    The entries are rebuilt in the process and not modified: `--all` still shows the
    raw trace as it was recorded.

    >>> raw = parsed([
    ...     "[Focus]  Raster  a → —  (+140 ms)",
    ...     "[Focus]  Raster  — → b  (+35 ms)",
    ... ])
    >>> [(e["content"], e["ms"]) for e in merged(raw)]
    [('a → b', 175)]
    """
    folded = []
    i = 0
    while i < len(entries):
        entry = entries[i]
        following = entries[i + 1] if i + 1 < len(entries) else None
        fits = (
            following is not None
            and entry["kind"] == "Focus"
            and following["kind"] == "Focus"
            and entry["area"] == following["area"]
            and _target(entry) == "—"
            and _source(following) == "—"
        )
        if fits:
            folded.append(
                {
                    "kind": "Focus",
                    "area": entry["area"],
                    "content": f"{_source(entry)} → {_target(following)}",
                    "ms": entry["ms"] + following["ms"],
                    "dwell": entry["dwell"],
                }
            )
            i += 2
            continue
        folded.append(entry)
        i += 1
    return folded


def _straggler(entries: list[dict], start: int, area: str) -> bool:
    """Is there still a key of the same main area shortly behind `start`?

    The search runs in a **window** and not at exactly one place: Between a focus line
    and its `onMoveCommand` key there is regularly another `Remote` line
    (RemoteKeyTrace.swift:76, GameController, reports before the focus engine). The real
    straggler then lies one line further.

    That too is justified from the source and not from the trace of 23.08.: there the
    same number comes out with and without the window.
    """
    wanted = main_area(area)
    total = 0
    for entry in entries[start:]:
        total += entry["ms"]
        if total > STRAGGLER_MS or entry["kind"] == "Focus":
            return False
        if main_area(entry["area"]) == wanted:
            return True
    return False


def corrections(entries: list[dict]) -> list[tuple[dict, dict]]:
    """Pairs of two focus lines that belong to ONE press.

    **The pairing knows the peculiarity of the key lines** (correction 15.08.):
    `onMoveCommand` reports in the middle of a list only AFTER the focus change. The old
    pattern — two focus lines close together — therefore fired wrongly at every
    wrap-around point: The wrap-around is followed by the next press, whose focus line
    comes before its own key line, and that looked like one press with two lines. A
    focus line whose key stands right behind it is therefore no longer attributed to an
    earlier press. The `Remote` lines (GameController, BEFORE the focus engine)
    are not stragglers themselves — but they **hide** some: They stand between focus line
    and key, and whoever only looks at `entries[i + 2]` does not find the key behind
    them. Hence a window (correction 26.08.).

    A key behind a `Remote` line is found nonetheless:

    >>> corrections(parsed([
    ...     "[Focus]  Detailseite  play → season-s2  (+12 ms)",
    ...     "[Focus]  Detailseite  season-s2 → season-s6  (+8 ms)",
    ...     "[Key]  Remote  ↓ pressed  (+1 ms)",
    ...     "[Key]  Detailseite · Staffeln  ↓  (+6 ms)",
    ... ]))
    []

    And likewise without it — the key's area is the finer one:

    >>> corrections(parsed([
    ...     "[Focus]  Detailseite  play → season-s2  (+12 ms)",
    ...     "[Focus]  Detailseite  season-s2 → season-s6  (+8 ms)",
    ...     "[Key]  Detailseite · Staffeln  ↓  (+6 ms)",
    ... ]))
    []

    The repeat rate of a held press is not a correction:

    >>> corrections(parsed([
    ...     "[Focus]  Detailseite  e1 → e2  (+100 ms)",
    ...     "[Focus]  Detailseite  e2 → e3  (+100 ms)",
    ... ]))
    []

    The real correction stays — the limit must not become too tight:

    >>> [n["content"] for _, n in corrections(parsed([
    ...     "[Focus]  Detailseite  play → season-s2  (+12 ms)",
    ...     "[Focus]  Detailseite  season-s2 → season-s6  (+8 ms)",
    ... ]))]
    ['season-s2 → season-s6']
    """
    entries = merged(entries)
    found = []
    for i, (before, after) in enumerate(zip(entries, entries[1:])):
        if before["kind"] != "Focus" or after["kind"] != "Focus":
            continue
        if after["ms"] > TOGETHER_MS:
            continue
        if main_area(before["area"]) != main_area(after["area"]):
            continue
        # If the second focus line has a trailing key of its own in the same area, it
        # was a press of its own — not a double.
        if _straggler(entries, i + 2, after["area"]):
            continue
        found.append((before, after))
    return found


def main() -> int:
    arguments = [a for a in sys.argv[1:] if a != "--all"]
    show_all = "--all" in sys.argv

    file = None
    if "--file" in arguments:
        position = arguments.index("--file")
        if position + 1 >= len(arguments):
            print("--file needs a path, for example diagnose/2026-08-23_1804_diagnose.log.")
            return 2
        file = arguments[position + 1]
        del arguments[position : position + 2]

    span = arguments[0] if arguments else "15m"
    source = file if file else f"the last {span}"

    if file:
        entries = parsed(pathlib.Path(file).read_text(encoding="utf-8").splitlines())
    else:
        entries = parsed(trace(span))

    if not entries:
        print(f"No focus trace in {source}.")
        if file:
            print("This file contains no focus trace — was")
            print('"ausführlich aufzeichnen" switched on?')
        else:
            print("Is the app running in the simulator? The trace is produced without a switch,")
            print("but only while the app is running.")
        return 0

    if show_all:
        print(f"▸ Focus trace from {source} — {len(entries)} lines\n")
        for e in entries:
            marker = "⌨" if e["kind"] == "Key" else " "
            dwell = f"  held {e['dwell']} ms" if e["dwell"] is not None else ""
            print(f"  {marker} {e['area']:<26} {e['content']:<44} +{e['ms']} ms{dwell}")
        print()

    pairs = corrections(entries)
    if not pairs:
        print(f"▸ No correction in {source}. Every press landed.")
        return 0

    print(f"▸ {len(pairs)} correction(s) — one press, two focus lines\n")
    for before, after in pairs:
        visible = "visible" if after["ms"] >= FRAME_MS else "under one frame"
        print(f"  {before['area']}")
        print(f"     assigned:     {before['content']}")
        print(f"     corrected:    {after['content']}   after {after['ms']} ms ({visible})")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
