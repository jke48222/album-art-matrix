"""The halo, as a module every design can call.

`alt_model` grew a rear-facing halo and the two older wall scripts never had
one, so the objects that were drawn first are the only ones the wall does not
glow behind. This is that same halo, extracted: twelve zones, three to an edge,
each the average of the artwork's own outer strip, on emissive strips that face
the wall from inside the standoff gap.

It takes the host script's own `box`, `material` and `part` so the strips end up
in the same collection, under the same root, in the same millimetre frame as
everything else that script builds.
"""
import os

import bpy

SEGS = 3          # three zones to an edge, one per panel
SUB = 4           # each zone drawn as four short strips, so a corner reads


def colours(face_png):
    """Twelve zones sampled from the artwork's own edges, lifted and saturated.

    An average is duller than the picture it came from, and a dull halo reads as
    a fault rather than as light, which is why the lift is here.
    """
    flat = [(0.5, 0.5, 0.5)] * 12
    if not (face_png and os.path.exists(face_png)):
        return flat
    img = bpy.data.images.load(face_png)
    w, h = img.size
    if w < 8 or h < 8:
        return flat
    px = list(img.pixels)
    d = max(4, w // 10)

    def avg(x0, x1, y0, y1):
        r = g = b = 0.0
        n = 0
        for y in range(max(0, y0), min(h, y1)):
            row = y * w
            for x in range(max(0, x0), min(w, x1)):
                i = (row + x) * 4
                r += px[i]
                g += px[i + 1]
                b += px[i + 2]
                n += 1
        if not n:
            return (0.5, 0.5, 0.5)
        r, g, b = r / n, g / n, b / n
        mx = max(r, g, b, 1e-6)
        lift = min(1.0, 0.35 + mx) / mx
        mid = (r + g + b) / 3.0
        return tuple(min(1.0, mid + (c - mid) * 1.45) * lift for c in (r, g, b))

    third = w // 3
    out = []
    for k in range(3):                      # bottom, left to right
        out.append(avg(k * third, (k + 1) * third, 0, d))
    for k in range(3):                      # right, bottom to top
        out.append(avg(w - d, w, k * third, (k + 1) * third))
    for k in range(3):                      # top, left to right
        out.append(avg(k * third, (k + 1) * third, h - d, h))
    for k in range(3):                      # left, bottom to top
        out.append(avg(0, d, k * third, (k + 1) * third))
    return out


def add(box, material, part, col, w, h, z, face_png, lit=True,
        inset=12.0, strength=34.0, cx=0.0, cy=0.0, layer=6, prefix="Halo"):
    """Strips on a `w` by `h` rectangle at depth `z`, facing the wall."""
    cs = colours(face_png)
    hw, hh = w / 2, h / 2
    made = []
    for e, (px, py, ax) in enumerate((
            (cx, cy - hh + inset, "x"), (cx + hw - inset, cy, "y"),
            (cx, cy + hh - inset, "x"), (cx - hw + inset, cy, "y"))):
        span = (w if ax == "x" else h) - 2 * inset
        zl = span / SEGS
        for s in range(SEGS):
            off = -span / 2 + zl / 2 + s * zl
            colour = cs[(e * SEGS + s) % len(cs)]
            for u in range(SUB):
                sub = -zl / 2 + zl / (2 * SUB) + u * zl / SUB
                if ax == "x":
                    at, size = (px + off + sub, py, z), (zl / SUB - 3, 9.0, 4.0)
                else:
                    at, size = (px, py + off + sub, z), (9.0, zl / SUB - 3, 4.0)
                name = f"{prefix} {e}{s}{u}"
                m = material(name, (0.02, 0.02, 0.02), 0.5,
                             emit=colour if lit else (0.0, 0.0, 0.0),
                             emit_strength=strength if lit else 0.0)
                made.append(part(box(name, size, at, col, m), layer))
    return made
