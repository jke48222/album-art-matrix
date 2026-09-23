"""The Tessera sting, drawn with the wall's own dots.

The logo is a record made of dots on a nine by nine lattice, and the sting
(tessera/Design/Logos/record/sting/record-sting.html) is that lattice fading
up, the sixty-eight white tiles popping in one after another in a spiral
from the outer ring while the whole disc spins to rest from two hundred
degrees, a halo, and the wordmark wiping in on the right as the disc slides
over to make room for it. The film of that is 1080p. On a panel of LEDs a
downscaled film is mush, and the design is already dots, so this draws the
same thing with the LEDs as the dots: one lattice dot every `pitch` LEDs,
the tile order, timings and easings taken from the CSS.

Two cuts. The whole sting once, for a boot (`boot_frames`). The icon alone,
going round, for the moments the wall is waiting on something, such as a
picture being drawn (`icon_frame`).
"""
from __future__ import annotations

import math
import threading

import numpy as np
from PIL import Image, ImageDraw

from .pixelfont import draw_text, text_width

# (col, row, pop delay in seconds) in the order the tiles arrive: the outer
# ring clockwise from the top, then the next ring, then the last four round
# the hole. Read off the SVG.
TILES = [
    (4, 0, 0.150), (5, 0, 0.165), (6, 0, 0.181), (7, 1, 0.197), (8, 2, 0.212),
    (8, 3, 0.227), (8, 4, 0.243), (8, 5, 0.259), (8, 6, 0.274), (7, 7, 0.289),
    (6, 8, 0.305), (5, 8, 0.321), (4, 8, 0.336), (3, 8, 0.352), (2, 8, 0.367),
    (1, 7, 0.382), (0, 6, 0.398), (0, 5, 0.413), (0, 4, 0.429), (0, 3, 0.445),
    (0, 2, 0.460), (1, 1, 0.476), (2, 0, 0.491), (3, 0, 0.506), (4, 1, 0.522),
    (5, 1, 0.537), (6, 1, 0.553), (6, 2, 0.569), (7, 2, 0.584), (7, 3, 0.600),
    (7, 4, 0.615), (7, 5, 0.630), (7, 6, 0.646), (6, 6, 0.661), (6, 7, 0.677),
    (5, 7, 0.693), (4, 7, 0.708), (3, 7, 0.724), (2, 7, 0.739), (2, 6, 0.755),
    (1, 6, 0.770), (1, 5, 0.785), (1, 4, 0.801), (1, 3, 0.817), (1, 2, 0.832),
    (2, 2, 0.848), (2, 1, 0.863), (3, 1, 0.879), (4, 2, 0.894), (5, 2, 0.909),
    (6, 3, 0.925), (6, 4, 0.941), (6, 5, 0.956), (5, 6, 0.972), (4, 6, 0.987),
    (3, 6, 1.002), (2, 5, 1.018), (2, 4, 1.033), (2, 3, 1.049), (3, 2, 1.065),
    (4, 3, 1.080), (5, 3, 1.095), (5, 4, 1.111), (5, 5, 1.127), (4, 5, 1.142),
    (3, 5, 1.157), (3, 4, 1.173), (3, 3, 1.188),
]
LATTICE = 9
LATTICE_DELAY = [0.02, 0.075, 0.13, 0.185, 0.24]   # by ring, the centre first
LATTICE_INK = (30, 30, 30)                           # #1E1E1E
TILE_INK = (252, 250, 246)
WORD_INK = (255, 255, 255)

FPS = 24
# The CSS timeline, in seconds from the start.
LATTICE_FADE_S = 0.3
SPIN_AT, SPIN_S = 0.15, 1.45        # rotate 200deg -> 0 by 84% of the way, scale .9 -> 1.03 -> 1
POP_S = 0.5                         # each tile: scale 0 -> 1 with an overshoot
HALO_AT, HALO_S = 1.4, 1.1
PULL_S, PULL_HOLD = 2.2, 0.62       # the disc sits centred for 62% of the pull, then slides left
WORD_AT, WIPE_S, SETTLE_S = 1.42, 0.62, 0.8
BOOT_S = 3.3                        # the whole sting, with a moment on the finished mark
LOOP_BUILD_S = 1.8                  # icon alone: everything is in by 1.19 + 0.5
LOOP_HOLD_S, LOOP_FADE_S = 0.5, 0.35
LOOP_S = LOOP_BUILD_S + LOOP_HOLD_S + LOOP_FADE_S

SS = 4                              # supersampling for the moving dots


def _clamp(x: float) -> float:
    return 0.0 if x < 0 else 1.0 if x > 1 else x


def _ease_out(x: float, p: float = 3.0) -> float:
    x = _clamp(x)
    return 1.0 - (1.0 - x) ** p


def _pop(x: float) -> float:
    """cubic-bezier(.25,1.7,.4,1): up fast, past one, back to one."""
    x = _clamp(x)
    if x >= 1.0:
        return 1.0
    return _ease_out(x, 2.2) * (1.0 + 0.2 * math.sin(math.pi * x))


def _spin(t: float) -> tuple[float, float]:
    """(angle in degrees, scale) of the disc at t."""
    x = _clamp((t - SPIN_AT) / SPIN_S)
    if x <= 0.84:
        k = _ease_out(x / 0.84, 4.0)          # cubic-bezier(.05,.7,.1,1): almost all at the start
        return 200.0 * (1.0 - k), 0.9 + 0.13 * k
    k = (x - 0.84) / 0.16
    return 0.0, 1.03 - 0.03 * (0.5 - 0.5 * math.cos(math.pi * k))


class Sting:
    """One per wall size. Frames are rendered once and kept."""

    _cache: dict[int, "Sting"] = {}
    _lock = threading.Lock()

    @classmethod
    def get(cls, size: int) -> "Sting":
        with cls._lock:
            s = cls._cache.get(size)
            if s is None:
                s = cls._cache[size] = Sting(size)
            return s

    def __init__(self, size: int):
        self.size = size
        self.pitch = max(2, size // 32)           # 64 -> 2 LEDs a dot, 192 -> 6
        self.dot = max(1, self.pitch - 1)         # the design's dots are 86% of the pitch
        self.icon = LATTICE * self.pitch
        self.word_scale = max(1, size // 64)
        gap = self.pitch * 2
        word_w = text_width("TESSERA", self.word_scale)
        while self.word_scale > 1 and self.icon + gap + word_w > size:
            self.word_scale -= 1
            word_w = text_width("TESSERA", self.word_scale)
        total = self.icon + gap + word_w
        margin = max(0, (size - total) // 2)
        self.cx_end = margin + self.icon / 2      # where the disc ends up
        self.cx_mid = size / 2                    # where it starts, and stays for the icon cut
        self.cy = size / 2
        self.word_x = margin + self.icon + gap
        self.word_y = int(round(self.cy - 7 * self.word_scale / 2))
        self._boot: list[bytes] | None = None
        self._loop: list[np.ndarray] | None = None

    # ---- drawing ------------------------------------------------------------
    def _icon(self, canvas: ImageDraw.ImageDraw, t: float, cx: float, fade: float = 1.0):
        """The lattice and the disc at time t, centred on cx, into a
        supersampled canvas."""
        size, pitch, dot = self.size, self.pitch, self.dot
        half = (LATTICE - 1) / 2
        ss = SS
        # the dark lattice, ring by ring
        for r in range(LATTICE):
            for c in range(LATTICE):
                ring = max(abs(c - half), abs(r - half))
                k = _ease_out((t - LATTICE_DELAY[int(ring)]) / LATTICE_FADE_S) * fade
                if k <= 0:
                    continue
                # + 0.5: a dot sits on an LED's centre, not on the line
                # between two, or every dot lands half on each of a pair
                x = (cx + 0.5 + (c - half) * pitch) * ss
                y = (self.cy + 0.5 + (r - half) * pitch) * ss
                d = dot * ss / 2
                ink = tuple(int(v * k) for v in LATTICE_INK)
                canvas.rectangle((x - d, y - d, x + d - 1, y + d - 1), fill=ink)
        # the disc: tiles popping in, the whole group turning to rest
        angle, scale = _spin(t)
        a = math.radians(angle)
        ca, sa = math.cos(a), math.sin(a)
        for c, r, delay in TILES:
            p = _pop((t - delay) / POP_S)
            if p <= 0:
                continue
            ox, oy = (c - half) * pitch * scale, (r - half) * pitch * scale
            x = (cx + 0.5 + ox * ca - oy * sa) * ss
            y = (self.cy + 0.5 + ox * sa + oy * ca) * ss
            d = dot * ss / 2 * p * scale
            alpha = min(1.0, p / 0.3) * fade
            ink = tuple(int(v * alpha) for v in TILE_INK)
            # a square that turns with the disc
            pts = []
            for dx, dy in ((-d, -d), (d, -d), (d, d), (-d, d)):
                pts.append((x + dx * ca - dy * sa, y + dx * sa + dy * ca))
            canvas.polygon(pts, fill=ink)

    def _halo(self, f: np.ndarray, t: float, cx: float, fade: float = 1.0):
        k = _ease_out((t - HALO_AT) / HALO_S) * fade
        if k <= 0:
            return
        size = self.size
        r = self.icon * 62 / 120 * (0.4 + 0.6 * k)
        yy, xx = np.mgrid[0:size, 0:size]
        d = np.sqrt((xx - cx) ** 2 + (yy - self.cy) ** 2) / max(r, 1e-6)
        # the SVG's radial gradient: .26 at the centre, .07 at 55%, 0 at the edge
        g = np.where(d < 0.55, 0.26 - (0.26 - 0.07) * (d / 0.55),
                     np.where(d < 1.0, 0.07 * (1.0 - (d - 0.55) / 0.45), 0.0))
        lift = (g * k * 255).astype(np.int16)
        f[...] = np.clip(f.astype(np.int16) + lift[:, :, None], 0, 255).astype(np.uint8)

    def _word(self, f: np.ndarray, t: float):
        k = _clamp((t - WORD_AT) / WIPE_S)
        if k <= 0:
            return
        settle = -int(round(16 / 430 * self.size * (1.0 - _ease_out((t - WORD_AT) / SETTLE_S, 4.0))))
        layer = np.zeros_like(f)
        draw_text(layer, "TESSERA", self.word_x + settle, self.word_y, WORD_INK, self.word_scale)
        # the wipe: revealed from the left, with a soft edge a few LEDs wide
        w = text_width("TESSERA", self.word_scale)
        edge = max(1, self.size // 24)
        front = self.word_x + settle - edge + (w + 2 * edge) * _ease_out(k, 2.0)
        xs = np.arange(self.size)
        mask = np.clip((front - xs) / edge, 0.0, 1.0)[None, :, None]
        f[...] = np.clip(f + layer * mask, 0, 255).astype(np.uint8)

    def frame(self, t: float, cut: str = "boot") -> np.ndarray:
        """One frame at t seconds, as an RGB array the wall's size."""
        size = self.size
        if cut == "boot":
            # the disc sits centred for the first 62% of the pull, then
            # slides left as the wordmark wipes in
            k = _ease_out((t - PULL_S * PULL_HOLD) / (PULL_S * (1 - PULL_HOLD)), 3.0)
            cx = self.cx_mid + (self.cx_end - self.cx_mid) * k
            fade = 1.0
        else:
            cx = self.cx_mid
            # the icon alone goes round: build, a breath, a fade, again
            t = t % LOOP_S
            fade = 1.0 if t < LOOP_BUILD_S + LOOP_HOLD_S else \
                1.0 - _clamp((t - LOOP_BUILD_S - LOOP_HOLD_S) / LOOP_FADE_S)
        im = Image.new("RGB", (size * SS, size * SS), (0, 0, 0))
        self._icon(ImageDraw.Draw(im), t, cx, fade)
        f = np.asarray(im.resize((size, size), Image.BOX), dtype=np.uint8).copy()
        self._halo(f, t, cx, fade)
        if cut == "boot":
            self._word(f, t)
        return f

    # ---- the two cuts, rendered once ----------------------------------------
    def boot_frames(self) -> list[bytes]:
        if self._boot is None:
            n = int(BOOT_S * FPS)
            self._boot = [self.frame(i / FPS, "boot").tobytes() for i in range(n)]
        return self._boot

    def icon_frame(self, t: float) -> np.ndarray:
        if self._loop is None:
            n = int(LOOP_S * FPS)
            self._loop = [self.frame(i / FPS, "loop") for i in range(n)]
        return self._loop[int(t * FPS) % len(self._loop)]
