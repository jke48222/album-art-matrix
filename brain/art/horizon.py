"""Horizon: the face the wall shows while it listens to a person.

Only on the wake word, never as an idle face. The picture that is up
collapses to a line, the way a CRT switched off; the line is the wall's
ear, and everything it hears grows out of it.

    collapse   the picture folds to a one pixel line in the ink of the last
               sleeve (its brightest saturated colour), top and bottom
               meeting in the middle
    listening  the line's brightness follows the voice, fast up, slow down;
               it ripples along its length as the voice rises, still at
               both ends like a plucked string, with a soft light under it
    thinking   a bright bead runs the line left to right with a tail of
               light, once every 1.2 s, while the line breathes
    opening    the line opens vertically into the next picture: the answer,
               or the face a command asked for
    missed     the line goes dashed for a moment and closes to black; the
               old face then comes back on its own

Every timing is a constant at the top. At 64 the line is one pixel and the
bead six; at 192 the line is three pixels and the bead eighteen. The face
draws in plain sRGB and hands the frame to the pipeline like every other.
"""
from __future__ import annotations

import math

import numpy as np

COLLAPSE_S = 0.25
OPEN_S = 0.40
MISSED_S = 0.80
BEAD_PERIOD_S = 1.2
ATTACK_S = 0.03
RELEASE_S = 0.40
DASH_ON, DASH_OFF = 3, 2
FRAY_DB = 8.0                 # louder than the mean by this much: the ends fray
IDLE_LEVEL = 0.22             # the line's brightness with nobody talking
FULL_LEVEL = 1.0


def ink_of(img: np.ndarray | None) -> tuple[int, int, int]:
    """The sleeve's brightest saturated colour, brightened to full: the
    last record's memory, carried by the line."""
    if img is None or img.size == 0:
        return (230, 220, 200)
    px = img.reshape(-1, 3).astype(np.float32)
    sat = px.max(1) - px.min(1)
    pick = px[int(np.argmax(sat + 0.3 * px.max(1)))]
    scale = 255.0 / max(float(pick.max()), 1.0)
    c = np.clip(pick * scale, 0, 255)
    if sat.max() < 24:                         # a grey sleeve: a warm white line
        return (230, 220, 200)
    return (int(c[0]), int(c[1]), int(c[2]))


class Horizon:
    def __init__(self, size: int):
        self.size = size
        self.thick = 1 if size <= 96 else 3
        self.bead = 6 if size <= 96 else 18
        self.mid = size // 2
        self._level = IDLE_LEVEL             # the smoothed voice level, 0..1
        self._last_t = None

    # ---- the line ---------------------------------------------------------------------
    def _line(self, k: float, ink, x0: int = 0, x1: int | None = None,
              dash: bool = False) -> np.ndarray:
        f = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        x1 = self.size if x1 is None else x1
        col = np.array(ink, dtype=np.float32) * max(0.0, min(1.0, k))
        y0 = self.mid - self.thick // 2
        for x in range(x0, x1):
            if dash and (x % (DASH_ON + DASH_OFF)) >= DASH_ON:
                continue
            f[y0:y0 + self.thick, x] = col
        return f

    def _follow(self, level_db: float | None, floor_db: float | None, t: float) -> float:
        """The voice, as a brightness: fast attack, slow release."""
        if level_db is None or floor_db is None:
            target = IDLE_LEVEL
        else:
            over = level_db - floor_db
            target = IDLE_LEVEL + (FULL_LEVEL - IDLE_LEVEL) * max(0.0, min(1.0, over / 30.0))
        dt = 0.0 if self._last_t is None else max(0.0, t - self._last_t)
        self._last_t = t
        tau = ATTACK_S if target > self._level else RELEASE_S
        a = 1.0 - math.exp(-dt / tau) if tau > 0 else 1.0
        self._level += (target - self._level) * a
        return self._level

    # ---- the states -----------------------------------------------------------------------
    def collapse(self, picture: np.ndarray, t: float, ink) -> np.ndarray:
        """t seconds into the collapse: the picture squeezed to the middle."""
        k = min(1.0, t / COLLAPSE_S)
        half = int(round((1.0 - k) * self.mid))
        f = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        if half > 0:
            # the picture, squeezed vertically to 2*half rows around the middle
            rows = np.linspace(0, self.size - 1, 2 * half).astype(int)
            band = picture[rows]
            y0 = self.mid - half
            f[y0:y0 + band.shape[0]] = (band * (1.0 - 0.6 * k)).astype(np.uint8)
        line = self._line(0.4 + 0.6 * k, ink)
        return np.maximum(f, line)

    def listening(self, t: float, ink, level_db=None, floor_db=None) -> np.ndarray:
        """The line, alive with the voice: it brightens with the level, and
        ripples along its length as the voice rises, the ends held still,
        with a soft light under it that grows with the sound."""
        k = self._follow(level_db, floor_db, t)
        f = self._line(k, ink)
        size = self.size
        amp = max(0.0, (k - IDLE_LEVEL) / (FULL_LEVEL - IDLE_LEVEL))
        col = np.array(ink, dtype=np.float32)
        y_mid = self.mid - self.thick // 2
        # the glow: a few rows either side, fading, stronger with the voice
        reach = (2 if size <= 96 else 6)
        for d in range(1, reach + 1):
            g = k * (0.10 + 0.30 * amp) * (1 - (d - 1) / reach) ** 2
            for yy in (y_mid - d, y_mid + self.thick - 1 + d):
                if 0 <= yy < size:
                    f[yy] = np.maximum(f[yy], (col * g).astype(np.uint8))
        if amp > 0.03:
            # the ripple: the line displaced by a wave whose height follows
            # the voice, still at both ends like a plucked string
            xs = np.arange(size, dtype=np.float32)
            env = np.sin(np.pi * xs / max(1, size - 1))
            wave = (np.sin(xs / size * 2 * np.pi * 2.2 + t * 7.0) * 0.6
                    + np.sin(xs / size * 2 * np.pi * 5.1 - t * 11.0) * 0.4)
            height = amp * (2.5 if size <= 96 else 8.0)
            off = wave * env * height
            for x in range(size):
                yy = int(round(y_mid + off[x]))
                for d in range(self.thick):
                    y = yy + d
                    if 0 <= y < size:
                        f[y, x] = np.maximum(f[y, x], (col * min(1.0, k * 1.05)).astype(np.uint8))
                # the trace between the resting line and the wave, faint
                lo, hi = sorted((y_mid, yy))
                if hi - lo > 1:
                    f[lo + 1:hi, x] = np.maximum(f[lo + 1:hi, x], (col * k * 0.22).astype(np.uint8))
        return f

    def thinking(self, t: float, ink) -> np.ndarray:
        """A bright bead runs the line with a tail of light behind it, and
        the line itself breathes a little while it waits."""
        breath = 0.36 + 0.06 * math.sin(t * 2.5)
        f = self._line(breath, ink)
        phase = (t % BEAD_PERIOD_S) / BEAD_PERIOD_S
        x = int(phase * (self.size + self.bead)) - self.bead
        col = np.array(ink, dtype=np.float32)
        y0 = self.mid - self.thick // 2
        reach = 1 if self.size <= 96 else 3
        for i in range(self.bead):
            xx = x + i
            if 0 <= xx < self.size:
                bright = 0.45 + 0.55 * (i / max(1, self.bead - 1)) ** 2
                f[y0:y0 + self.thick, xx] = (col * bright).astype(np.uint8)
                for d in range(1, reach + 1):
                    g = bright * 0.35 * (1 - (d - 1) / reach)
                    for yy in (y0 - d, y0 + self.thick - 1 + d):
                        if 0 <= yy < self.size:
                            f[yy, xx] = np.maximum(f[yy, xx], (col * g).astype(np.uint8))
        return f

    def opening(self, picture: np.ndarray, t: float, ink) -> np.ndarray:
        """t seconds into the opening: the line grows into the picture."""
        k = min(1.0, t / OPEN_S)
        half = max(1, int(round(k * self.mid)))
        f = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        rows = np.linspace(0, self.size - 1, 2 * half).astype(int)
        band = picture[rows]
        y0 = self.mid - half
        f[y0:y0 + band.shape[0]] = band
        if k < 1.0:
            col = (np.array(ink, dtype=np.float32) * (1.0 - k)).astype(np.uint8)
            edge_top = max(0, y0 - 1)
            edge_bot = min(self.size - 1, y0 + band.shape[0])
            f[edge_top] = np.maximum(f[edge_top], col)
            f[edge_bot] = np.maximum(f[edge_bot], col)
        return f

    def missed(self, t: float, ink) -> np.ndarray:
        """Dashed, fading to black over MISSED_S."""
        k = max(0.0, 1.0 - t / MISSED_S)
        return self._line(0.6 * k, ink, dash=True)
