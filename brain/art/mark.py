"""The shelf mark: a small record in the corner of a sleeve whose album is
on the owner's Discogs shelf. "You own this on vinyl."

A disc glyph, bottom right, 2 px in from the edges: 5x5 at 64, 11x11 at
192 with a one pixel outline. It is drawn in the sleeve's own ink, dark on
a light corner and light on a dark one, with the centre hole in the other
tone, so it reads on any cover. Stamped into the prepared sleeve by
main.py, so every face that shows the sleeve shows the mark.
"""
from __future__ import annotations

import numpy as np
from PIL import Image

INSET = 2


def geometry(size: int) -> tuple[int, int, float, bool]:
    """(diameter, inset, hole radius, outline) for a panel of this size."""
    if size <= 96:
        return 5, INSET, 0.6, False
    d = max(7, int(round(size / 17.5)) | 1)      # 11 at 192, odd
    return d, INSET * (size // 64), d / 7.0, True


def owned_mark(img, size: int | None = None):
    """The sleeve with the mark. Takes and returns the same kind of thing:
    a PIL image or an HxWx3 uint8 array."""
    pil = isinstance(img, Image.Image)
    a = np.array(img, dtype=np.uint8) if pil else np.asarray(img, dtype=np.uint8).copy()
    h, w = a.shape[:2]
    size = size or w
    d, inset, hole, outline = geometry(size)
    x1, y1 = w - inset, h - inset
    x0, y0 = x1 - d, y1 - d
    pad = 1 if outline else 0
    corner = a[max(0, y0 - pad):y1 + pad, max(0, x0 - pad):x1 + pad].astype(np.float32)
    lum = float((corner[..., 0] * 0.299 + corner[..., 1] * 0.587 + corner[..., 2] * 0.114).mean()) \
        if corner.size else 0.0
    ink = np.array([22, 22, 22] if lum > 118 else [236, 236, 236], dtype=np.uint8)
    other = np.array([236, 236, 236] if lum > 118 else [22, 22, 22], dtype=np.uint8)
    cx, cy = x0 + d / 2.0, y0 + d / 2.0
    r = d / 2.0
    ys, xs = np.mgrid[y0 - pad:y1 + pad, x0 - pad:x1 + pad]
    dist = np.sqrt((xs + 0.5 - cx) ** 2 + (ys + 0.5 - cy) ** 2)
    inside = (ys >= 0) & (ys < h) & (xs >= 0) & (xs < w)
    if outline:
        ring = (dist <= r + 1.0) & (dist > r) & inside
        a[ys[ring], xs[ring]] = other
    disc = (dist <= r) & inside
    a[ys[disc], xs[disc]] = ink
    centre = (dist <= hole) & inside
    a[ys[centre], xs[centre]] = other
    return Image.fromarray(a) if pil else a
