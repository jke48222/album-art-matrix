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
    """A record, not a circular crop of a sleeve.

    What makes vinyl read as vinyl at a glance is grooves catching a light,
    so that is what this builds: concentric grooves across the play area, a
    paper label with the art on it, a lead-in band, a rim, and a fixed
    specular sweep that the grooves modulate as they pass under it. The art
    stays large because the wall exists to show album art, so the label is
    generous rather than accurate.

    Everything rotationally symmetric is baked into the rotating image, since
    rotating a concentric pattern changes nothing; only the sheen is held
    still, and that is what sells the spin.
    """

    def __init__(self, art: Image.Image, size: int, rpm: float = 7.5):
        self.size = size
        self.rpm = rpm
        big = size * SUPER
        r = big / 2.0
        art = art.convert("RGB").resize((big, big), Image.LANCZOS)
        arr = np.asarray(art, dtype=np.float32)

        yy, xx = np.mgrid[0:big, 0:big].astype(np.float32)
        rad = np.hypot(xx - r, yy - r) / r          # 0 at centre, 1 at rim
        ang = np.arctan2(yy - r, xx - r)

        LABEL, LEAD_IN, RIM = 0.34, 0.90, 0.985
        hole = 0.055

        # --- grooves ------------------------------------------------------
        # Fine concentric rings across the play area only. The period is set
        # in FINAL pixels, not supersampled ones, or they alias into moire.
        period = 2.2 * SUPER
        groove = np.sin(rad * r / period * 2 * math.pi) * 0.5 + 0.5
        play = np.clip((rad - LABEL) * 14, 0, 1) * np.clip((LEAD_IN - rad) * 14, 0, 1)
        arr *= (1.0 - 0.17 * groove * play)[:, :, None]

        # A darker lead-in band between label and grooves, and a lead-out at
        # the rim: real records have smooth land there and it frames the art.
        band = np.clip(1 - np.abs(rad - LABEL) * 26, 0, 1)
        band += np.clip(1 - np.abs(rad - LEAD_IN) * 22, 0, 1)
        arr *= (1.0 - 0.26 * np.clip(band, 0, 1))[:, :, None]

        # --- the label ----------------------------------------------------
        # The art continues onto it, lifted and slightly desaturated, so it
        # reads as printed paper rather than as more vinyl.
        lbl = np.clip((LABEL - rad) * 18, 0, 1)[:, :, None]
        grey = arr.mean(axis=2, keepdims=True)
        paper = np.clip(arr * 0.72 + grey * 0.22 + 30.0, 0, 255)
        arr = arr * (1 - lbl) + paper * lbl
        # the ring where paper meets vinyl
        edge = np.clip(1 - np.abs(rad - LABEL) * 40, 0, 1)
        arr = np.clip(arr + (edge * 26)[:, :, None], 0, 255)

        # --- the rim ------------------------------------------------------
        rim = np.clip(1 - np.abs(rad - RIM) * 28, 0, 1)
        arr = np.clip(arr + (rim * 40)[:, :, None], 0, 255)

        self._art = Image.fromarray(arr.astype(np.uint8), "RGB")

        # --- mask: the disc, with the spindle hole punched ----------------
        mask = np.clip((1.0 - rad) * r * 3.0, 0, 255)
        mask *= np.clip((rad - hole) * r * 1.2, 0, 1)
        self._mask = Image.fromarray(mask.astype(np.uint8), "L")

        # --- the light ----------------------------------------------------
        # One broad sweep and a weaker opposite one, gated to the play area
        # and modulated by the grooves, so the highlight breaks into fine
        # arcs the way it does on a real record. This stays still; the record
        # turns underneath it.
        sweep = np.cos(ang - 0.9) ** 12 + 0.45 * np.cos(ang + 2.3) ** 12
        sweep *= np.clip((rad - LABEL) * 5, 0, 1) * np.clip((1.0 - rad) * 8, 0, 1)
        sweep *= 0.55 + 0.45 * groove
        self._sheen = (np.clip(sweep, 0, 1) * 78).astype(np.uint8)

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
