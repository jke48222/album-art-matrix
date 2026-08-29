"""S5 preview: the spinning-CD renderer (research §19, art pipeline step 6).

Composites album art into a disc — circular crop, punched center hole, inner
label ring, a fixed specular sheen the art rotates beneath — and renders
frames at arbitrary time t. Rotation is supersampled (4x) then Lanczos'd
down, so a 64 px disc spins smoothly instead of crawling with jaggies.

Rotation is locked to the track, not to the wall clock: frame_at takes an
optional progress in seconds, and when it is given, the record's angle is a
function of where the song is. Seek the music and the record seeks. Pause it
and the record stops, which is the whole reason a record is the right object
for this: a spinning disc that keeps spinning through a pause is a screensaver.

The needle is the other half. It sits at a fixed angle, as a tonearm does,
and walks inward from the lead-in to the label across the length of the
track, so how far in you are is readable from across the room with no text.
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

        # Final-size polar coordinates, for the needle. Built once: it is the
        # only thing that changes per frame that cannot be baked.
        fy, fx = np.mgrid[0:size, 0:size].astype(np.float32)
        fr = size / 2.0
        self._frad = np.hypot(fx - fr, fy - fr) / fr
        self._fang = np.arctan2(fy - fr, fx - fr)
        self._label, self._lead = LABEL, LEAD_IN
        self._needle_cache = (None, None)

    def frame_at(self, t: float, progress_s: float | None = None,
                 fraction: float | None = None) -> Image.Image:
        """Disc at time t, returned at target size.

        progress_s locks the rotation to the track; without it the record
        free-runs on t, which is what happens when the source cannot say
        where the song is. fraction (0..1) places the needle; without it
        there is no needle, because a guessed one would be a lie.
        """
        spin = t if progress_s is None else progress_s
        angle = (spin * self.rpm / 60.0 * 360.0) % 360.0
        turned = self._art.rotate(-angle, resample=Image.BICUBIC,
                                  center=(self._art.width / 2, self._art.height / 2))
        frame = Image.composite(turned, self._bg, self._mask)
        arr = np.asarray(frame, dtype=np.uint16)
        arr = np.clip(arr + self._sheen[:, :, None], 0, 255).astype(np.uint8)
        out = Image.fromarray(arr).resize((self.size, self.size), Image.LANCZOS)
        if fraction is None:
            return out
        return Image.fromarray(
            np.clip(np.asarray(out, dtype=np.int16)
                    + self._needle(fraction)[:, :, None], 0, 255).astype(np.uint8)
        )

    def _needle(self, frac: float) -> np.ndarray:
        """A bright point on the arm's line, walking in as the song plays.

        Quantised to a pixel's worth of travel and cached: recomputing a
        gaussian every frame for a dot that moves once every few seconds is
        the kind of waste that costs frames on a Pi.
        """
        frac = min(1.0, max(0.0, frac))
        rp = self._lead - (self._lead - self._label) * frac
        key = round(rp * self.size)
        if self._needle_cache[0] == key:
            return self._needle_cache[1]
        # 0.9 rad is where the sheen is brightest: the light and the needle
        # belong at the same place or they read as two unrelated events.
        d_ang = np.abs(np.arctan2(np.sin(self._fang - 0.9), np.cos(self._fang - 0.9)))
        arm = np.exp(-(d_ang / 0.09) ** 2)
        dot = np.exp(-((self._frad - rp) / 0.045) ** 2)
        # the arm is a faint line, the point where it meets the groove is hot
        val = (arm * np.clip((self._frad - self._label) * 6, 0, 1)
               * np.clip((1.02 - self._frad) * 6, 0, 1)) * 26 + arm * dot * 150
        out = np.clip(val, 0, 255).astype(np.int16)
        self._needle_cache = (key, out)
        return out
