"""Ambient mode — the wall as a light, not a record sleeve.

Each effect is a frame_at(t) callable returning a pre-white-balance PIL image,
same contract as DiscAnimator, so the main loop treats art and ambience the
same way: generate, white-balance (which also applies brightness), ship.
"""
import colorsys

import numpy as np
from PIL import Image


def _hex_rgb(s: str) -> tuple[int, int, int]:
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


class Ambient:
    def __init__(self, size: int, effect: str = "rainbow",
                 color: str = "#4060ff", color2: str = "#ff2080",
                 speed: float = 1.0):
        self.size = size
        self.effect = effect
        self.speed = speed
        self.c1 = np.array(_hex_rgb(color), dtype=np.float32)
        self.c2 = np.array(_hex_rgb(color2), dtype=np.float32)
        yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / (size - 1)
        self._xx, self._yy = xx, yy

    def frame_at(self, t: float) -> Image.Image:
        t *= self.speed
        fn = getattr(self, f"_{self.effect}", self._solid)
        arr = np.clip(fn(t), 0, 255).astype(np.uint8)
        return Image.fromarray(arr, "RGB")

    def _solid(self, t):
        return np.broadcast_to(self.c1, (self.size, self.size, 3)).copy()

    # ---- mosaic -------------------------------------------------------
    #
    # The wall is a mosaic of 4,096 tesserae, so one ambient mode makes the
    # wall behave like what it is: a geometric weave built out of its own
    # tiles, in the colours of whatever is playing.
    #
    # The vocabulary here is plain geometry — mirrored quadrants, banded
    # rows, diamonds, chevrons, stepped frets — which is the common ground of
    # woven and tiled ornament in a lot of places, Roman tesserae included.
    # It is deliberately not an imitation of any particular culture's designs.
    #
    # It animates as a loom: the pattern weaves in row by row, holds while the
    # colours drift along the band, then unweaves and picks a new draft.

    def _mosaic(self, t):
        n = self.size
        weave, hold, unweave = 3.2, 6.0, 1.6
        cycle = weave + hold + unweave
        draft = int(t // cycle)
        phase = t - draft * cycle

        rng = np.random.default_rng(draft * 7919)
        pal = self._mosaic_palette(rng)

        y, x = np.mgrid[0:n, 0:n]
        # Mirror into quadrants. Symmetry is what separates ornament from noise.
        xm = np.minimum(x, n - 1 - x).astype(np.int32)
        ym = np.minimum(y, n - 1 - y).astype(np.int32)

        idx = np.zeros((n, n), dtype=np.int32)

        # A fixed architecture rather than stacked random strips: border, a
        # narrow band, the field, and the band and border again by symmetry.
        # Composition is why this reads as designed instead of generated.
        border, band = 2, 6
        field0, field1 = border + band, n - border - band

        # --- the field ---------------------------------------------------
        motif = int(rng.integers(0, 4))
        s1 = int(rng.integers(4, 8))          # never below 4: tighter moires
        if motif == 0:                        # concentric diamonds
            idx = ((xm + ym) // s1) % len(pal)
        elif motif == 1:                      # stepped medallion
            idx = (np.maximum(xm, ym) // s1) % len(pal)
        elif motif == 2:                      # lozenge lattice
            idx = ((np.abs(xm - ym) // s1) + (np.minimum(xm, ym) // s1)) % len(pal)
        else:                                 # nested squares
            idx = ((np.minimum(xm, ym) // s1) * 2 + (xm + ym) // (s1 * 2)) % len(pal)

        # --- the bands ---------------------------------------------------
        s2 = int(rng.integers(3, 6))
        bmotif = int(rng.integers(0, 3))
        if bmotif == 0:
            bidx = (xm // s2) % 2
        elif bmotif == 1:
            bidx = ((xm + ym) // s2) % 2
        else:
            bidx = ((xm // s2) + (ym // s2)) % 2
        band_a, band_b = rng.integers(0, len(pal)), rng.integers(0, len(pal))
        band_vals = np.where(bidx == 1, band_a, band_b)

        idx[border:field0] = band_vals[border:field0]
        idx[field1:n - border] = band_vals[field1:n - border]

        # --- the border --------------------------------------------------
        deep = len(pal) - 1                   # the dark tone, kept last
        idx[:border] = deep
        idx[n - border:] = deep
        idx[:, :border] = deep
        idx[:, n - border:] = deep

        # Colours travel around the palette so a held draft still breathes.
        shift = int(t * 0.9)
        out = np.asarray(pal, dtype=np.float32)[(idx + shift) % len(pal)]

        # --- the loom ----------------------------------------------------
        if phase < weave:
            front = (phase / weave) * n
        elif phase < weave + hold:
            front = float(n)
        else:
            front = (1.0 - (phase - weave - hold) / unweave) * n

        rowsy = np.arange(n)[:, None, None]
        out *= np.clip((front - rowsy) / 3.0, 0.0, 1.0).astype(np.float32)

        # The shuttle: one bright pass riding the weave front.
        if 0 < front < n:
            row = int(front) - 1
            if 0 <= row < n:
                out[row] = np.minimum(255.0, out[row] * 1.5 + 55.0)

        return out

    def _mosaic_palette(self, rng):
        """Colours for a draft: the album's two, plus tints between them.

        match_art feeds c1/c2 from the sleeve, so the weave is made of what is
        playing. A dark third tone gives the pattern somewhere to breathe.
        """
        c1, c2 = self.c1, self.c2
        mid = (c1 + c2) / 2
        light = np.minimum(255.0, np.maximum(c1, c2) * 1.2 + 40.0)
        deep = np.minimum(c1, c2) * 0.22
        # The four figure tones shuffle; the dark ground stays last so the
        # border can always reach for it.
        pal = [c1, c2, mid, light]
        rng.shuffle(pal)
        return pal + [deep]

    def _breathe(self, t):
        # sine between 25% and 100% over ~5s — calm, not a strobe
        k = 0.625 + 0.375 * np.sin(t * 2 * np.pi / 5.0)
        return self.c1[None, None, :] * k

    def _pulse(self, t):
        # sharp attack, exponential decay — one beat per second at speed 1.0
        # (real beat-grid sync lands with S4; until then speed IS the tempo)
        phase = t % 1.0
        k = 0.2 + 0.8 * np.exp(-4.0 * phase)
        return self.c1[None, None, :] * k

    def _rainbow(self, t):
        # horizontal hue sweep drifting right, full cycle ~12s
        hue = (self._xx + t / 12.0) % 1.0
        flat = hue.ravel()
        rgb = np.array([colorsys.hsv_to_rgb(h, 0.9, 1.0) for h in
                        np.linspace(0, 1, 256)], dtype=np.float32) * 255.0
        return rgb[(flat * 255).astype(np.uint8)].reshape(
            self.size, self.size, 3)

    def _gradient(self, t):
        # c1 -> c2 across an axis that slowly rotates (~40s per turn)
        ang = t * 2 * np.pi / 40.0
        proj = (self._xx - 0.5) * np.cos(ang) + (self._yy - 0.5) * np.sin(ang)
        k = (proj + 0.707) / 1.414
        k = np.clip(k, 0, 1)[:, :, None]
        return self.c1[None, None, :] * (1 - k) + self.c2[None, None, :] * k
