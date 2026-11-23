#!/usr/bin/env python3
"""Checks that no font size is set past the scale.

`Font.system(size:)` is **fixed** in SwiftUI. It compiles cleanly, looks right with
the default system font — and does not grow with it. Whoever sets the font to
`accessibilityExtraExtraExtraLarge` gets an app in which the text grows to 48 points
and the chevron next to it stays at eleven. Not just small: at that setting simply
no longer visible.

The finding of 10.09. (AP5): The phone's scale (then ``Typografie``, since AP58
``TypeLevel`` with the variant `.handy`) is built correctly — `largeTitle`,
`title`, `headline`, all text styles, all scaling. **38 places went around it.** None
of them was a slip on its own; together they were the biggest item of accessibility.

Two ways are allowed:
  * ``TypeLevel`` — the scale itself, for text (`TypeLevel.header.font`).
  * ``iconSize(_:weight:gestalt:)`` — a fixed base size that grows along via
    `ScaledMetric`. For glyphs that should be smaller than the text next to them, and
    for digits whose shape carries the information.

Exceptions carry the marker `// festeschrift:` with a reason, in the line itself or in
the six above it. They really exist: A glyph that fills a tile hangs on the tile and
not on the text; a preview of the subtitle size would otherwise show something other
than the film.

**On the TV a different rule applies** (26.09.2026, AP58). tvOS has no dynamic type:
nobody makes the system font larger there, and `TypeLevel` is therefore deliberately a
scale of **fixed** numbers (76/57/48/38/29/27/25) there, measured for three metres of
distance. `.system(size:)` on the TV is thus not an accessibility error — it is the way
the scale itself is built. Applying the phone rule there would mean putting a marker on
62 places that says nothing true.

What can still go wrong on the TV is **proliferation**: text in a size next to the
scale — 31 here, 26 there — until the ranking between heading and body text can no
longer be read from three metres. The TV rule is therefore:

  * **Text** takes its size from `TypeLevel` (package `Styling`, since AP58) — as a
    finished font (`TypeLevel.text.font`) or as a number
    (`.system(size: TypeLevel.text.points, weight: .medium)`) when only the weight
    differs.
  * **Symbols** (`Image(systemName:)` with the size as the immediate modifier) are
    free. A glyph follows its tile or row and not the text — a symbol on an empty page
    is 64, one in a list row is 22, and neither of them is a text level.
  * Everything else carries `// festeschrift:` with a reason — the code digits of the
    sign-in, which have to be larger than any heading from three metres; the subtitle
    preview, which the viewer sets in percent.
  * `TypeLevel.swift` in `Styling` is exempt: that is where the scale is built.

Shared code (`Packages/` except the TV packages, `grundstock`) runs on both devices and
is subject to both rules — so in practice the stricter phone one.

**Multi-line too** (26.09.2026): `.system(` and `size:` on two lines — the way
swift-format formats a long call — slipped through until then. The search therefore
runs over the whole text and not line by line.

Usage:        python3 scripts/type_scale.py --app tv|handy
Return value: 0 if every fixed size carries its reason, otherwise 1.
"""

import re
import sys

from programs import PROGRAMS, ROOT, display, arguments, justified

FIXED_SIZE = re.compile(r"\.system\(\s*size:\s*")
MARKER = re.compile(r"//\s*festeschrift:")

# Per program: files in which the only allowed fixed size is built.
EXEMPT = {
    # The modifier sets the fixed size that grows along via `ScaledMetric`.
    "phone": {"IconSize.swift"},
    # Since AP58 the scale lives in `Styling` (see `SCALE_FILES`).
    "tv": set(),
}
# **The scale of both devices** (AP58, 26.09.2026): Since the `Styling` package the TV
# scale is built there, in exactly one file, and that one is in BOTH programs. It is
# exempt by path and not by file name — a second `TypeLevel.swift` elsewhere would
# otherwise get the exemption for free.
SCALE_FILES = {ROOT / "Packages/Styling/Sources/Styling/TypeLevel.swift"}
# Text on the TV takes its size from the scale (`TypeLevel.x.points`).
SCALE = ("TypeLevel.",)
SYMBOL_IMAGE = re.compile(r"\bImage\(systemName:")


def strip_comments(text: str) -> str:
    """Replace comments with blank space — the line numbers stay in place."""
    return re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), text)


def is_symbol(lines: list[str], number: int) -> bool:
    """Is the size attached directly to an `Image(systemName:)`?

    Walks upwards over the modifiers of the chain (lines that start with `.`, and
    comments) to the first line that is not one — that one carries the building block.
    A stack with several glyphs in it (`HStack { Image … }.font(…)`) does not count:
    there a `}` precedes the modifier, and what else may be in the stack cannot be
    seen from here.
    """
    i = number
    while i >= 0:
        line = lines[i].strip()
        if i == number or line.startswith(".") or line.startswith("//") or not line:
            if i != number and SYMBOL_IMAGE.search(line):
                return True
            i -= 1
            continue
        return bool(SYMBOL_IMAGE.search(line))
    return False


def allowed_without_marker(program: str, lines: list[str], number: int, argument: str) -> bool:
    if program != "tv":
        return False
    return argument.startswith(SCALE) or is_symbol(lines, number)


def main() -> int:
    program = PROGRAMS[arguments("Fixed font sizes without a reason").app]
    findings = []
    counted = free = 0
    for path in program.swift_files():
        if path.name in EXEMPT[program.name] or path.resolve() in SCALE_FILES:
            continue
        text = path.read_text(encoding="utf-8")
        lines = text.split("\n")
        bare = strip_comments(text)
        for match in FIXED_SIZE.finditer(bare):
            number = bare.count("\n", 0, match.start())
            counted += 1
            argument = bare[match.end():match.end() + max(map(len, SCALE))]
            if allowed_without_marker(program.name, lines, number, argument):
                free += 1
                continue
            if not justified(lines, number, MARKER):
                findings.append(f"{display(path)}:{number + 1}: {lines[number].strip()}")

    if findings:
        if program.name == "tv":
            print("Fixed font size next to the scale — text takes `TypeLevel`,")
            print("otherwise `// festeschrift: <reason>` (symbols are free):")
        else:
            print("Fixed font size without a reason — expected `// festeschrift: <reason>`,")
            print("otherwise `TypeLevel` or `iconSize(_:)`:")
        for finding in findings:
            print(f"  {finding}")
        return 1

    if program.name == "tv":
        print(f"{counted} fixed font sizes: {free} symbols or scale, "
              f"{counted - free} with a reason")
    else:
        print(f"{counted} fixed font sizes, each with a reason")
    return 0


if __name__ == "__main__":
    sys.exit(main())
