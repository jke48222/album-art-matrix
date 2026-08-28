"""S5 preview: the spinning-CD renderer (research §19, art pipeline step 6).

Composites album art into a disc — circular crop, punched center hole, inner
label ring, a fixed specular sheen the art rotates beneath — and renders
frames at arbitrary time t. Rotation is supersampled (4x) then Lanczos'd
down, so a 64 px disc spins smoothly instead of crawling with jaggies.

Rotation-rate contract (the part that matters later): callers ask for
frame_at(t) with rpm set today; at S4 the beat grid replaces rpm with
one-revolution-per-four-bars locked to progress_ms — the API stays put.
"""
import math

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SUPER = 4  # supersample factor for rotation quality


class DiscAnimator:
    def __init__(self, art: Image.Image, size: int, rpm: float = 7.5):
        self.size = size
        self.rpm = rpm
        big = size * SUPER
        art = art.convert("RGB").resize((big, big), Image.LANCZOS)

        # circular disc mask with punched center hole
        mask = Image.new("L", (big, big), 0)
        d = ImageDraw.Draw(mask)
        r = big // 2
        d.ellipse([1, 1, big - 2, big - 2], fill=255)
        hole = int(big * 0.055)
        d.ellipse([r - hole, r - hole, r + hole, r + hole], fill=0)
        self._mask = mask

        # darken an inner "label ring" so the hole reads as a CD hub
        hub = Image.new("L", (big, big), 0)
        d = ImageDraw.Draw(hub)
        ring = int(big * 0.16)
        d.ellipse([r - ring, r - ring, r + ring, r + ring], fill=70)
        d.ellipse([r - hole * 2, r - hole * 2, r + hole * 2, r + hole * 2], fill=110)
        art = Image.composite(Image.new("RGB", (big, big), (12, 12, 14)), art,
                              hub.point(lambda v: min(v, 90)))
        self._art = art

        # fixed specular sheen: two soft radial wedges (light stays put,
        # the disc turns underneath — that's what makes it feel physical)
        yy, xx = np.mgrid[0:big, 0:big]
        ang = np.arctan2(yy - r, xx - r)
        sheen = (np.cos((ang - 0.7) * 2) ** 8 + 0.6 * np.cos((ang + 2.2) * 2) ** 8)
        rad = np.hypot(xx - r, yy - r) / r
        sheen *= np.clip((rad - 0.18) * 3, 0, 1) * np.clip((1.0 - rad) * 6, 0, 1)
        self._sheen = (np.clip(sheen, 0, 1) * 70).astype(np.uint8)

        self._bg = Image.new("RGB", (big, big), (0, 0, 0))

    def frame_at(self, t: float) -> Image.Image:
        """Disc at time t seconds, returned at target size."""
        angle = (t * self.rpm / 60.0 * 360.0) % 360.0
        turned = self._art.rotate(-angle, resample=Image.BICUBIC,
                                  center=(self._art.width / 2, self._art.height / 2))
        frame = Image.composite(turned, self._bg, self._mask)
        arr = np.asarray(frame, dtype=np.uint16)
        arr = np.clip(arr + self._sheen[:, :, None], 0, 255).astype(np.uint8)
        out = Image.fromarray(arr)
        return out.resize((self.size, self.size), Image.LANCZOS)
