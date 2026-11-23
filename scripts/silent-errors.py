#!/usr/bin/env python3
"""Finds `catch` blocks that record nothing.

**Why this is checked and not merely agreed.** A rule is worth as much as it is
checked. "Whoever writes a `catch` writes a line into the ledger" is an agreement that
gets forgotten the twentieth time — and a swallowed error never reports itself. The
sister project lost time on exactly that: Three of the most important measurements
proved their own ineffectiveness and reported it as success.

**Both programs, all included sources** (review finding B4 of 27.09.2026): Until then
the script lived under `Phone/scripts/` and read `Phone/App/Sources` and
`Phone/Packages` — the flow logic had long since moved to `Packages/Flows`, `Core`,
`PlaylistKit` and the other shared packages, and the TV ran without the check. Green
meant "read nothing". Now the sources come from `programs.py`, like for the other
guards, and `--app` selects the program.

**What is checked:** Every `catch` block outside `Tests/`. In the block (up to the
matching brace, ``body``) or in the lines after it (``WINDOW``) there must be a call of
`Diagnose.`, `Diagnostics.`, `ImageMessage.` or a `PhoneEvent`. `Diagnostics.` is the
way of the packages that cannot link `Diagnose` (`Core` sits below it).

**What does not count as silent, and why:**

  * `catch is CancellationError` — a cancellation is not an error but the sign that
    nobody is waiting for the result any more.
  * A block that **passes the error on**: `throw`, `return error` or
    `.failure(error)`. Whoever receives it has to record it then — otherwise the same
    error would stand in the ledger twice.

**What is not checked, and why:**

  * `Tests/` — a test may expect an error and throw it away.
  * `try?` — it swallows just the same, but occurs in hundreds of places entirely
    rightly (a missing value that has a fallback). A check that fires there gets
    switched off within a week, and then nobody checks the `catch` blocks any more
    either.
  * `grundstock` is read but only **reported**: It is a repo of its own that StoryShelf
    also carries, and has its own check run. A red run here that only a change there can
    fix would stop both programs.

**The way out, with a reason:** Where silence is right, `// bewusst still:` stands with a
sentence behind it. The sentence is the point — an exception without a reason is not an
exception but a gap.

Return value: 0 if every block records, otherwise 1.
"""

from __future__ import annotations

import pathlib
import re
import sys

from programs import PROGRAMS, display, arguments

CATCH = re.compile(r"\bcatch\b")
RECORDS = ("Diagnose.", "Diagnostics.", "ImageMessage.", "PhoneEvent")
WAY_OUT = re.compile(r"bewusst still:", re.IGNORECASE)
CANCELLATION = re.compile(r"\bcatch\s+is\s+CancellationError\b")
PASSED_ON = re.compile(r"\bthrow\b|\breturn\s+error\b|\.failure\(error\)")

# This many lines from the `catch` on are searched for a recording. A block that is
# longer and only records at the bottom is one to split anyway.
WINDOW = 8


def body(text: str, start: int) -> str:
    """The block from the first `{` after `start` up to the matching `}`.

    >>> body("} catch { a { b } c } d", 2)
    '{ a { b } c }'
    """
    begin = text.find("{", start)
    if begin < 0:
        return ""
    depth = 0
    for i in range(begin, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[begin:i + 1]
    return text[begin:]


def silent(text: str) -> list[tuple[int, str]]:
    """The silent `catch` blocks of a source text — line number and line.

    >>> silent("do { x() } catch {\\n    wert = nil\\n}")
    [(1, 'do { x() } catch {')]
    >>> silent("do { x() } catch {\\n    Diagnose.fehler(.netz, \\"x\\", error)\\n}")
    []
    >>> silent("do { x() } catch {\\n    // bewusst still: der Rückfall ist richtig\\n}")
    []
    >>> silent("do { x() } catch is CancellationError {\\n}")
    []
    >>> silent("do { x() } catch {\\n    throw Fehler.netz(error)\\n}")
    []
    """
    lines = text.splitlines()
    starts = [0]
    for line in lines:
        starts.append(starts[-1] + len(line) + 1)
    findings = []
    for number, line in enumerate(lines):
        match = CATCH.search(line)
        if not match:
            continue
        # `catch` in the running text of a comment is not a block.
        if line.lstrip().startswith(("//", "///", "*")):
            continue
        if CANCELLATION.search(line):
            continue
        window = "\n".join(lines[number:number + WINDOW])
        block = body(text, starts[number] + match.end())
        if WAY_OUT.search(window):
            continue
        if any(word in window or word in block for word in RECORDS):
            continue
        if PASSED_ON.search(block):
            continue
        findings.append((number + 1, line.strip()))
    return findings


def foreign(path: pathlib.Path) -> bool:
    """Is the file outside this repo (`grundstock`)?

    The public copy carries grundstock inside, under `Packages/Grundstock`; it stays the
    other repo there too, so it is only reported, as next door.
    """
    root = pathlib.Path(__file__).resolve().parent.parent
    resolved = path.resolve()
    return not resolved.is_relative_to(root) or resolved.is_relative_to(root / "Packages" / "Grundstock")


def main() -> int:
    program = PROGRAMS[arguments(__doc__.splitlines()[0]).app]
    files = program.swift_files()
    own: list[str] = []
    others: list[str] = []
    for path in files:
        for number, line in silent(path.read_text(encoding="utf-8")):
            (others if foreign(path) else own).append(f"{display(path)}:{number}   {line[:70]}")

    if others:
        print(f"⚠ {len(others)} silent catch blocks in grundstock (separate repo, only reported)")
    if not own:
        print(f"✓ every catch block records ({len(files)} files, {program.name})")
        return 0

    print(f"✗ {len(own)} catch blocks record nothing:")
    for finding in own:
        print(f"    {finding}")
    print("\033[90m  Either a line into the ledger — or `// bewusst still: <reason>`.\033[0m")
    return 1


if __name__ == "__main__":
    sys.exit(main())
