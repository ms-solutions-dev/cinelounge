#!/usr/bin/env python3
"""Flattens the layered alternate icons into flat PNG files.

**Why this tool exists.** The four alternate icons live in the catalog as layered
image stacks — three layers that shift against each other on focus. That is the nicer
version, and it works on the device: ``setAlternateIconName`` finds the stacks in the
catalog and the tile switches.

App Store Connect still does not accept them. Measured and confirmed on 03.09.2026
(error 90471, "Missing Image Asset … Alternate Icon asset"):

* The primary icon appears in the catalog **twice** — as a ``tv`` stack 400×240 and as
  a ``marketing`` stack 1280×768. The second size comes from the ``Contents.json`` of
  the ``brandassets``, which assigns the image stack the role ``primary-app-icon`` with
  ``size: 1280x768``.
* An alternate icon cannot get this second size. A top-level image stack carries no
  role information, and a ``brandassets`` of its own per icon is **silently skipped**
  by ``actool`` on ``appletvos`` — even with ``--alternate-app-icon``. Verified: the
  catalog then shrinks from 5.2 to 2.3 MB, the icons drop out without replacement, and
  there is not even a warning.
* The build setting ``ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`` exists and looks
  like the solution. It is not, and it is more dangerous than it looks: it changes
  nothing in the catalog (both ``Assets.car`` have the same checksum), but it INJECTS
  the ``CFBundleAlternateIcons`` via the partial Info.plist of ``actool``. Whoever
  removes the declaration in project.yml and leaves this setting in place builds the
  icons back in unnoticed — and wonders about 90471 in a build that should no longer
  declare them at all.

What remains is the second way that Apple describes for tvOS anyway: loose PNG files in
the bundle, listed in ``CFBundleAlternateIcons`` as an array of file names (on tvOS an
array of strings, not the nested dictionaries of iOS). The price is the parallax — a
flat image does not tilt on focus.

The image stacks therefore remain the source and are not deleted: here things are only
derived. Should a way via the catalog be found after all, it is available again without
any image work.

    ./scripts/alternate_icons.py            generate
    ./scripts/alternate_icons.py --check  only report whether something is missing/outdated
"""

from __future__ import annotations

import io
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App/Resources/Assets.xcassets"
TARGET = ROOT / "App/Resources/AlternateIcons"

# The names are a contract with three places at once: the folder in the catalog,
# ``CFBundleAlternateIcons`` in project.yml and ``AppIcon.alternateName`` in
# Packages/Features/…/AppIconStore.swift. If one deviates, ``setAlternateIconName``
# reports an error that only shows on the device.
ICONS = ["SymbolSessel", "SymbolBogen", "SymbolNegativ", "SymbolNegativSchrift"]

# Back first: the order is that of the stack from bottom to top. The ``Contents.json``
# of the image stack lists them the other way round (front first) because it describes
# the view from the front — whoever takes that over paints the background over the
# motif.
LAYERS = ["Back", "Middle", "Front"]

# The tvOS tile measures 400×240 points. Loose files without a suffix in the name let
# the system pick the resolution itself: ``Name.png`` and ``Name@2x.png``.
SCALES = [("1x", ""), ("2x", "@2x")]


def layer_image(icon: str, layer: str, scale: str) -> Image.Image:
    short = layer.lower()
    path = (
        CATALOG
        / f"{icon}.imagestack"
        / f"{layer}.imagestacklayer"
        / "Content.imageset"
        / f"{short}@{scale}.png"
    )
    if not path.exists():
        raise SystemExit(f"Missing: {path}")
    return Image.open(path).convert("RGBA")


def flatten(icon: str, scale: str) -> Image.Image:
    image = layer_image(icon, LAYERS[0], scale)
    for layer in LAYERS[1:]:
        top = layer_image(icon, layer, scale)
        if top.size != image.size:
            raise SystemExit(
                f"{icon}: layer {layer} measures {top.size}, expected {image.size}"
            )
        image = Image.alpha_composite(image, top)
    # Without an alpha channel, and that is deliberate: An app icon is always
    # rectangular and opaque. A translucent edge goes unnoticed on the TV, but
    # App Store Connect rejects it.
    return image.convert("RGB")


def bytes_of(image: Image.Image) -> bytes:
    """The same bytes that ``main`` would write when generating.

    Computed and not read from disk: ``--check`` should not only report whether the
    files are THERE, but whether they still match the image stacks. Whoever changes a
    layer and forgets to generate notices it otherwise only at upload — and there it is
    expensive.
    """
    buffer = io.BytesIO()
    image.save(buffer, "PNG", optimize=True)
    return buffer.getvalue()


def main() -> int:
    only_check = "--check" in sys.argv[1:]
    TARGET.mkdir(parents=True, exist_ok=True)
    missing, outdated = [], []

    for icon in ICONS:
        for scale, suffix in SCALES:
            target = TARGET / f"{icon}{suffix}.png"
            fresh = bytes_of(flatten(icon, scale))
            if only_check:
                if not target.exists():
                    missing.append(target.name)
                elif target.read_bytes() != fresh:
                    outdated.append(target.name)
                continue
            target.write_bytes(fresh)
            print(f"  {target.name:<30} {len(fresh) / 1024:.0f} KB")

    if only_check:
        for title, names in (("Missing", missing), ("No longer current", outdated)):
            if names:
                print(f"{title}: {', '.join(names)}")
        if missing or outdated:
            print("Generate with:  ./scripts/alternate_icons.py")
            return 1
        print("All alternate icons are up to date with the image stacks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
