#!/usr/bin/env python3
"""The sidebar's brand mark — generated, not painted.

The same rule as for the alternate icons (`alternate_icons.py`): Whoever changes the
logo runs the script. A PNG placed by hand drifts apart on the first day someone
redraws the symbol — and unnoticed, because an old mark looks like a right one.

**The source is the app icon's image stack and not `design/logo.svg`** (AP27,
11.09.2026). Both show the same motif, but the stack lives **in this project** and is
already rasterized at the resolution tvOS needs; an SVG would need a rasterizer that
does not exist here. `Middle` and `Front` are taken — the two layers that carry the
motif; `Back` is the background and stays out.

**Why the mark is needed at all:** In the **collapsed** sidebar it is the only visible
part of the brand. Until 11.09. `popcorn.fill` stood there — a system symbol that any
other app can have just the same, and the only place where it was used in the whole
project. The own mark lay drawn next to it and did not appear in the running UI.

Usage:   python3 scripts/brand_mark.py
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App/Resources/Assets.xcassets"
SOURCE = CATALOG / "SymbolSessel.imagestack"
TARGET = CATALOG / "BrandMark.imageset"

# **Forty and not twenty-six.** 26 pt is about 19 arcminutes at three metres — that
# carries as a shape, not as an image: One sees that something is there, and does not
# recognize what. Forty is about 29′ and thus legible.
#
# **And no more:** The collapsed bar measures 116 pt, of which 2 × 16 pt of padding
# are deducted. At an aspect ratio of 1.71 the mark at 40 pt height is 68 pt wide —
# sixteen points of air. At 44 it would be nine, and that is the distance at which a
# translation or a redrawn logo falls out of the picture.
HEIGHT = 40

# Back stays out: `Back` is the tile's ground, not the motif.
LAYERS = ["Middle", "Front"]

SCALES = [("", 1), ("@2x", 2)]


def layer_image(name: str) -> Image.Image:
    path = SOURCE / f"{name}.imagestacklayer" / "Content.imageset" / f"{name.lower()}@2x.png"
    if not path.exists():
        raise SystemExit(f"Missing: {path}")
    return Image.open(path).convert("RGBA")


def main() -> int:
    motif = layer_image(LAYERS[0])
    for name in LAYERS[1:]:
        motif = Image.alpha_composite(motif, layer_image(name))

    # **Cut out and not left in the tile.** The tile is 400 × 240 and holds the motif
    # centered; whoever takes it unchanged gets a mark that consists of two thirds air
    # and looks correspondingly small.
    bounds = motif.getchannel("A").getbbox()
    if bounds is None:
        raise SystemExit("The motif is empty — is the image stack right?")
    motif = motif.crop(bounds)
    ratio = motif.width / motif.height

    TARGET.mkdir(parents=True, exist_ok=True)
    wanted = set()
    for suffix, factor in SCALES:
        height = HEIGHT * factor
        width = round(height * ratio)
        file = f"brandmark{suffix}.png"
        motif.resize((width, height), Image.LANCZOS).save(TARGET / file)
        wanted.add(file)

    (TARGET / "Contents.json").write_text(
        json.dumps(
            {
                "images": [
                    {"filename": "brandmark.png", "idiom": "tv", "scale": "1x"},
                    {"filename": "brandmark@2x.png", "idiom": "tv", "scale": "2x"},
                ],
                "info": {"author": "xcode", "version": 1},
            },
            indent=2,
        )
        + "\n"
    )

    for file in sorted(TARGET.iterdir()):
        if file.suffix == ".png" and file.name not in wanted:
            file.unlink()

    width = round(HEIGHT * ratio)
    print(f"Brand mark {HEIGHT}×{width} pt (two resolutions) → {TARGET.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
