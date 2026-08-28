#!/usr/bin/env python3
"""Tessera's mark: one lit tile in a dark lattice.

The icon is drawn with the same rules the app draws the wall with, so the
mark on the home screen and the object inside the app are the same thing:
round emitters on near-black, a dark lattice that exists whether lit or not,
and an additive halo around anything emitting. One tessera is lit, warm,
off-centre, the way a single LED looks when a panel first takes power.

    python3 tessera/Tools/make_icon.py
"""
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
GROUND = (11, 10, 9)
UNLIT = (34, 32, 28)
LIT = (232, 176, 75)      # Ink.tile
GRID = 7                  # 7x7 emitters still reads at 60px; 64 would be mud


def render(size: int = SIZE) -> Image.Image:
    img = Image.new("RGB", (size, size), GROUND)
    glow = Image.new("RGB", (size, size), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    d = ImageDraw.Draw(img)

    margin = size * 0.19
    span = size - margin * 2
    cell = span / GRID
    r = cell * 0.34

    # The lit tile sits one step up and left of centre, so the mark has a
    # direction and never reads as a symmetric logo-grid.
    lit_x, lit_y = 2, 3

    for gy in range(GRID):
        for gx in range(GRID):
            cx = margin + gx * cell + cell / 2
            cy = margin + gy * cell + cell / 2
            box = (cx - r, cy - r, cx + r, cy + r)
            if (gx, gy) == (lit_x, lit_y):
                # the halo goes on the additive layer
                # A fully lit emitter blooms bigger than its dark neighbours.
                hr = r * 3.4
                gd.ellipse((cx - hr, cy - hr, cx + hr, cy + hr), fill=LIT)
                lr = r * 1.45
                d.ellipse((cx - lr, cy - lr, cx + lr, cy + lr), fill=LIT)
            else:
                # neighbours catch a little of it, falling off with distance
                dist = max(abs(gx - lit_x), abs(gy - lit_y))
                k = max(0.0, 1 - dist / 3.0) ** 2
                shade = tuple(
                    int(UNLIT[i] + (LIT[i] - UNLIT[i]) * 0.30 * k) for i in range(3)
                )
                d.ellipse(box, fill=shade)

    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.055))
    glow = Image.eval(glow, lambda v: int(v * 0.78))
    return add(img, glow)


def add(base: Image.Image, glow: Image.Image) -> Image.Image:
    """Light adds, it does not replace."""
    from PIL import ImageChops
    return ImageChops.add(base, glow)


if __name__ == "__main__":
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, "..", "Tessera", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(out_dir, exist_ok=True)
    icon = render()
    icon.save(os.path.join(out_dir, "AppIcon1024.png"))
    # a small copy for eyeballing legibility at home-screen size
    icon.resize((120, 120), Image.LANCZOS).save(
        os.path.join(here, "icon-preview-120.png")
    )
    print("wrote AppIcon1024.png")
