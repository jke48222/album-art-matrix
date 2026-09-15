#!/usr/bin/env python3
"""Tessera's app icon: the Record mark, white on black.

The mark is drawn from the same geometry as the logo files and the in-app
mark (record_cells in tessera/Tools/logos.py), at the icon scale the Record
direction sets there, so the home screen, the logo sheet and the header
agree. Drawn four times larger, then reduced, so the tile edges stay crisp.

    python3 tessera/Tools/make_icon.py
"""
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import logos  # noqa: E402

SIZE = 1024
GROUND = (0, 0, 0)
GHOST = (0x1D, 0x1A, 0x17)     # the unlit lattice
LIT = (255, 255, 255)


def scale() -> float:
    """The Record direction's icon scale, set in logos.py."""
    return next(d["icon_scale"] for d in logos.DIRECTIONS if d["slug"] == "record")


def render(size: int = SIZE, ss: int = 4, k: float = None) -> Image.Image:
    k = scale() if k is None else k
    S = size * ss
    img = Image.new("RGB", (S, S), GROUND)
    d = ImageDraw.Draw(img)
    lattice, lit = logos.record_cells()
    unit = S * k / 100.0            # the mark's 0..100 box, centred
    off = S * (1 - k) / 2

    def tile(cx, cy, s, radius, fill):
        d.rounded_rectangle([off + (cx - s / 2) * unit, off + (cy - s / 2) * unit,
                             off + (cx + s / 2) * unit, off + (cy + s / 2) * unit],
                            radius=radius * unit, fill=fill)

    for cx, cy, s, _ in lattice:
        tile(cx, cy, s, 1.1, GHOST)
    for cx, cy, s, _, _ in lit:
        tile(cx, cy, s, min(1.1, s * 0.12), LIT)
    return img.resize((size, size), Image.LANCZOS)


if __name__ == "__main__":
    out_dir = os.path.join(HERE, "..", "Tessera", "Assets.xcassets", "AppIcon.appiconset")
    icon = render()
    icon.save(os.path.join(out_dir, "AppIcon1024.png"))
    # a small copy for eyeballing legibility at home-screen size
    icon.resize((120, 120), Image.LANCZOS).save(os.path.join(HERE, "icon-preview-120.png"))
    print(f"wrote AppIcon1024.png, the mark at {scale():.2f} of the icon")
