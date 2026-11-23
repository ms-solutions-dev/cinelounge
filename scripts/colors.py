#!/usr/bin/env python3
"""Checks that no system color is drawn past the color board.

Why this is a step of its own: A system color compiles cleanly, looks right on one
color scheme and stays put when switching to another. That was exactly the finding of
10.09. (AP5): ``Material.kante()`` drew `Color.white` at 8 %, while `GESTALTUNG.md`
§6.3 has always demanded `#F7EBD6` there — that is, ``ColorRole/text``. White occurs
in **none** of the three color boards; under "Kontrast" the edge therefore glowed
colder than any text next to it, and under "Mitternacht" it stayed put while the rest
of the app switched boards.

The same lesson has stood on ``StripeBand`` since E41: *"The colors come from the
color board and not from the logo — otherwise the app would have a second cream color
that would stay put on a switch."* The sentence was there; what was missing was a
place where it cannot be bypassed.

Procedure:
  1. Search every Swift file of the program (``programs.Program.swift_files``: the
     own folders and everything included, with `Packages/` and `grundstock`) for
     `Color.<name>` and `Color(white:` — that is, the system colors that SwiftUI
     brings along.
  2. Every hit is an error, EXCEPT when the line or one of the six lines above it
     carries the marker `// systemfarbe:` with a reason.

Nothing is enumerated here. The reason belongs at the spot where drawing happens and
not in a list in this script that nobody reads — the same shape as in
`Phone/scripts/buttons.py`.

**The same rule on both devices** (26.09.2026, AP58). The TV has the same three color
schemes and the same switch; a system color stays put there just the same. Until then
the guard only ran on the phone, and on the TV 17 system colors stood without a
reason. Where a token exists that means the same, it has been substituted —
`ColorRole.reason.color` is `#000000` in all three schemes, so `Color.black` as a
darkening was only correct by coincidence. Where the color deliberately does NOT
follow the scheme (video surface, subtitles, background of a QR code), the marker
stands with a reason.

Usage:        python3 scripts/colors.py --app tv|handy
Return value: 0 if every system color carries its reason, otherwise 1.
"""

import re
import sys

from programs import PROGRAMS, display, arguments, justified

# The system colors one takes by accident. `Color.clear` is expressly not among them:
# it is not a color but a spacer.
SYSTEM_COLOR = re.compile(
    r"\bColor\.(white|black|gray|grey|red|blue|green|yellow|orange|pink|purple|brown|"
    r"primary|secondary|accentColor)\b|\bColor\(white:"
)
MARKER = re.compile(r"//\s*systemfarbe:")


def main() -> int:
    program = PROGRAMS[arguments("System colors without a reason").app]
    findings = []
    counted = 0
    for path in program.swift_files():
        lines = path.read_text(encoding="utf-8").split("\n")
        for number, line in enumerate(lines):
            # A hit in a comment is none — there it stands as an example.
            without_comment = line.split("//")[0]
            if not SYSTEM_COLOR.search(without_comment):
                continue
            counted += 1
            if not justified(lines, number, MARKER):
                findings.append(f"{display(path)}:{number + 1}: {line.strip()}")

    if findings:
        print(f"System color without a reason ({program.name}) — expected "
              "`// systemfarbe: <reason>`:")
        for finding in findings:
            print(f"  {finding}")
        return 1

    print(f"{counted} system colors, each with a reason")
    return 0


if __name__ == "__main__":
    sys.exit(main())
