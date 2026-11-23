#!/usr/bin/env python3
"""Checks that no scaffold claims something unfinished that is long since finished.

**The pattern in question.** For things not yet built, this project creates a file
with nothing but a comment — "Not built yet — scaffold after `entwuerfe/prototyp.html`".
That is deliberate and useful: the cut exists before the code does, and the directory
shows what is still missing. **There are fifty-six such files**, and most of them are
honest.

**The error is the aftermath.** Whoever then builds the thing — often elsewhere,
because it belongs there — leaves the scaffold standing. From then on it lies twice:
the thing has two files, and one of them has no thing. The second consequence is worse:
the sentence "Not built yet" is useless as an inventory once it has stood above
something finished — and an inventory is exactly what one reads it for.

**On 07.09. there were two**, and one of them was fresh: `Shell/LanguageChoice.swift`
stayed behind when `LanguageChoice` was built into `DesignSystemPhone` in E46. The
second, the volume-slider scaffold in the Remote folder, had stood for weeks next to a
built `VolumeSlider` in `Player/Volume.swift`.

**Two kinds of false alarm have been measured and are excluded:**

  * **The same name in separate packages is not a duplicate.** `Downloads.Cleanup`
    (download management) and `Diagnose.Cleanup` (error log) are two things with one
    name — which is why a hit only counts if the scaffold's package **imports** the other.
  * **Nested types do not count.** A nested `Item` of a storage snapshot is not the
    `Item` from the downloads; the search therefore covers only what stands at the start
    of a line.

Usage:   python3 scripts/scaffold.py            → list
         python3 scripts/scaffold.py --check  → only report (returns 1)
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCATIONS = ["App", "Packages"]


def files():
    for location in LOCATIONS:
        for path in sorted((ROOT / location).rglob("*.swift")):
            if "/.build/" in str(path) or "/Tests/" in str(path):
                continue
            yield path, path.read_text()


def module(path):
    """`Packages/X/Sources/Module/…` becomes `Module`; everything under `App/` is `App`."""
    parts = path.relative_to(ROOT).parts
    if parts[0] == "App":
        return "App"
    return parts[3] if len(parts) > 3 and parts[2] == "Sources" else parts[1]


def main():
    everything = list(files())

    # Which modules a module imports — from the `import` lines, not from Package.swift:
    # what a file really sees is written in it.
    imported = {}
    for path, text in everything:
        imported.setdefault(module(path), set()).update(re.findall(r"^import (\w+)", text, re.M))

    scaffolds = [
        (path, text)
        for path, text in everything
        if not re.sub(r"^\s*(//.*)?$", "", text, flags=re.M).strip()
    ]

    liars = []
    for path, _ in scaffolds:
        own = module(path)
        visible = {own} | imported.get(own, set())
        pattern = re.compile(
            rf"^(public |internal |private |final |@\w+ )*(struct|class|enum|actor|protocol)"
            rf"\s+{re.escape(path.stem)}\b",
            re.M)
        built = [
            q for q, t in everything
            if q != path and module(q) in visible and pattern.search(t)
        ]
        if built:
            liars.append((path, built))

    if "--check" in sys.argv:
        if liars:
            print(f"✗ {len(liars)} scaffold(s) claim something unfinished that is finished:")
            for path, built in liars:
                print(f"    {path.relative_to(ROOT)}")
                for q in built:
                    print(f"        built in {q.relative_to(ROOT)}")
            print("  Delete the scaffold and move its rationale to where the type lives.")
            return 1
        print(f"✓ {len(scaffolds)} scaffolds, none over something built")
        return 0

    for path, _ in scaffolds:
        print(f"  {path.relative_to(ROOT)}")
    print(f"\n{len(scaffolds)} scaffolds, {len(liars)} of them over something built")
    return 0


if __name__ == "__main__":
    sys.exit(main())
