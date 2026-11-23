#!/usr/bin/env python3
"""Checks that every opened sheet is also drawn.

**The finding of 12.09.2026, from the client, with a screenshot:** *"when I tap
the button at the top between profile and download this comes up … that doesn't
look right either."* The button for the playback target opened `.target`, and no
sheet host had a branch for it — so the developer placeholder appeared with
"target · portion 0.45" and two test buttons. The path had been wired since
06.09., the sheet (``TargetSheet``) stood finished, and one `case` was missing
in between.

**This is the same error type `catalog.py` already catches for views** — it
occurred three times there and has been checked ever since. For sheets the
check did not exist, and it occurred a fourth time. It compiles cleanly:
`default: placeholder` is a complete `switch`.

Procedure:
  1. Collect every ID that is opened anywhere (`open(.x)`).
  2. Collect every ID that a sheet host has a branch for.
  3. The difference is the finding.

**A branch only counts if it is not itself the placeholder.** `case .x:
placeholder` would be the gap with a name in front of it.

Return value: 0 if every opened ID has a branch, otherwise 1.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Packages/FeaturesPhone/Sources/FeaturesPhone"
IDS = SOURCE / "Models/SheetID.swift"

# The files that draw a sheet — each carries a `.sheet(` host or is the content
# of one. What is searched for is not the host but the `switch id`: the host
# hangs in ShellView, the content in TabPlaceholder.
HOSTS = ("Shell/TabPlaceholder.swift", "Detail/DetailView.swift", "Player/SpielerView.swift")

# **This gate does not ask the reverse question**, and that is a decision.
#
# "Which ID does nobody open?" sounds like the same check and is a different
# one: thirteen IDs would come out, and six of them (`signOut`,
# `catalogChoice`, `deleteList`, `portalChoice`, `channelGroups`) are perfectly
# well used — their view shows the sheet through its own state
# (`keyboardOpen` and the like) and reads only the height from the ID
# (`SheetID.x.portion`). So `open(.x)` is not the only way, and whoever
# declares it the only one demands a rewrite of seven views for a question
# nobody has asked.
#
# The remaining seven are a real finding (an ID that is neither opened nor read
# for a height), but a different one — it deserves to be looked at one by one
# and not put in an exception list that nobody reads. It stands as an open
# point in E75 of the roadmap.


def all_ids() -> set[str]:
    """Every `case` of the enumeration — also several on one line."""
    names: set[str] = set()
    for line in IDS.read_text().splitlines():
        match = re.match(r"\s*case ([\w, =\"]+)$", line)
        if match:
            names |= {n.split("=")[0].strip() for n in match.group(1).split(",") if n.strip()}
    return names


def opened() -> dict[str, set[str]]:
    """ID → where it is opened.

    **Comments do not count.** When this gate was built, the first finding was
    one from a `//` sentence that was just explaining the case — a gate that
    reports its own rationale as a finding is not usable.
    """
    found: dict[str, set[str]] = {}
    for file in sorted(SOURCE.rglob("*.swift")):
        for line in file.read_text().splitlines():
            if line.lstrip().startswith("//"):
                continue
            for name in re.findall(r"open\(\.(\w+)\)", line):
                found.setdefault(name, set()).add(file.name)
    return found


def drawn(open_ids: dict[str, set[str]]) -> set[str]:
    """IDs with a branch of their own — the placeholder does not count.

    **A `default` that draws something covers its host completely.**
    ``SpielerView`` carries `default: spurwahl`: there the track picker is the
    normal case and the other branches are the exceptions. Whoever does not count
    that reports a finding where there is none — and a gate that goes red
    without a finding costs more than it protects.
    """
    names: set[str] = set()
    for host in HOSTS:
        text = (SOURCE / host).read_text()
        for line in text.splitlines():
            match = re.match(r"\s*case ([\w., ]+):\s*(\w*)", line)
            if not match or match.group(2) == "placeholder":
                continue
            names |= {
                n.strip().lstrip(".")
                for n in match.group(1).split(",")
                if n.strip().startswith(".")
            }
        # A host with a drawn `default` lets no ID fall through.
        if re.search(r"\n\s*default:\s*(?!placeholder\b)\w+", text):
            file_name = pathlib.Path(host).name
            names |= {k for k, where in open_ids.items() if file_name in where}
    return names


def main() -> int:
    ids = all_ids()
    open_ids = opened()
    painted = drawn(open_ids)

    # The finding: opened, but without a branch — the placeholder catches it.
    into_void = sorted(k for k in open_ids if k not in painted and k in ids)

    if "--check" in sys.argv:
        if into_void:
            print(f"✗ {len(into_void)} sheet(s) end in the placeholder:")
            for k in into_void:
                print(f"    .{k:<22} opened in {', '.join(sorted(open_ids[k]))}")
            return 1
        print(f"✓ {len(open_ids)} opened sheets, each with a branch of its own")
        return 0

    print(f"{len(ids)} IDs, {len(open_ids)} opened, {len(painted)} drawn")
    for k in sorted(ids):
        where = ", ".join(sorted(open_ids.get(k, []))) or "— nobody —"
        print(f"  {'✓' if k in painted else '✗'} {k:<22} {where}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
