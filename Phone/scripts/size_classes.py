#!/usr/bin/env python3
"""Checks that the size-class probe names every number that depends on the size class.

**Why this step exists.** `MetricClass` has decided since AP7 on the numbers that must
differ on the iPad from the phone, and the size-class probe
(`Shell/SizeClassProbe.swift`) is the only thing that triggers the switch in the
simulator at all. In doing so it writes the numbers into the log — and that is
exactly the trap: whoever adds an eighth number to `MetricClass` and does not touch the
probe has built a number that is **never** looked at in the half-width window. The
error does not announce itself; the recording merely looks unremarkable.

**The rule.** Every `static func` in `MetricClass` that takes a
`UserInterfaceSizeClass?` appears in `SizeClassProbe.numbers(forItem:)`. Conversely
the same: a name in the probe that `MetricClass` no longer knows is a line proving
something that does not exist.

**What expressly does not belong:** `static let readingWidth`. It takes no size class
because it is the same in both classes (on the phone the cap just never applies). A
number that does not change cannot be proven by a switch either.

Usage:   python3 scripts/size_classes.py   → returns 1 if something is missing
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Packages/FeaturesPhone/Sources/FeaturesPhone"
TABLE = SOURCE / "Components/MetricClass.swift"
PROBE = SOURCE / "Shell/SizeClassProbe.swift"

# `static func name(` … `UserInterfaceSizeClass?` in the same declaration. The head may
# be wrapped — which is why reading goes up to the closing parenthesis and not to the
# end of the line.
DECISION = re.compile(
    r"static func (\w+)\s*\(([^)]*UserInterfaceSizeClass\?[^)]*)\)", re.DOTALL)

# The numbers the probe queries from `MetricClass` (the names in the log are English strings).
NAMED = re.compile(r"MetricClass\.(\w+)\(")


def main() -> int:
    table = TABLE.read_text(encoding="utf-8")
    probe = PROBE.read_text(encoding="utf-8")

    decides = {match.group(1) for match in DECISION.finditer(table)}
    # Only the block of `numbers(forItem:)` — other pairs of parentheses in the file
    # must not count as a number.
    start = probe.find("static func numbers(forItem")
    if start < 0:
        print("✗ SizeClassProbe.numbers(forItem:) not found")
        return 1
    named = {match.group(1) for match in NAMED.finditer(probe[start:])}

    missing = sorted(decides - named)
    surplus = sorted(named - decides)

    if not decides:
        print("✗ MetricClass no longer holds a decision about the size class —")
        print("  either the table is gone or this checker does not read it.")
        return 1

    bad = False
    if missing:
        print(f"✗ {len(missing)} number(s) depend on the size class and are missing in the probe:")
        for name in missing:
            print(f"    MetricClass.{name}")
        print("  A number the probe does not name is never looked at in the half-width")
        print("  window — and only shows up on the device.")
        bad = True
    if surplus:
        print(f"✗ {len(surplus)} name(s) in the probe that MetricClass does not know:")
        for name in surplus:
            print(f"    {name}")
        bad = True
    if bad:
        return 1

    print(f"✓ {len(decides)} numbers per size class, each named by the probe")
    return 0


if __name__ == "__main__":
    sys.exit(main())
