"""Ticker and clock — the wall speaks and tells time.

Same frame_at(t) contract as DiscAnimator and Ambient, so the main loop
treats every mode the same way: generate, white-balance, ship.
"""
import time

import numpy as np
from PIL import Image

from .effects import _hex_rgb
from .pixelfont import draw_text, normalize, text_width


class Ticker:
    """Text scrolling right to left, 2x glyphs, vertically centered.

    speed is the control-state multiplier (0.1-3.0); 1.0 ≈ 18 px/s,
    which reads comfortably at 64 px wide.
    """

    SCALE = 2

    def __init__(self, size: int, text: str, color: str = "#f4f1ea",
                 speed: float = 1.0, loop: bool = True):
        self.size = size
        self.text = normalize(text) or "?"
        self.color = _hex_rgb(color)
        self.px_per_s = 18.0 * max(0.1, speed)
        self.loop = loop
        self.width = text_width(self.text, self.SCALE)

    def done(self, t: float) -> bool:
        if self.loop:
            return False
        return t * self.px_per_s > self.width + self.size + 4

    def frame_at(self, t: float) -> Image.Image:
        canvas = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        travel = self.width + self.size + 4
        offset = (t * self.px_per_s) % travel if self.loop \
            else min(t * self.px_per_s, travel)
        x = self.size - int(offset)
        y = (self.size - 7 * self.SCALE) // 2
        draw_text(canvas, self.text, x, y, self.color, self.SCALE)
        return Image.fromarray(canvas, "RGB")


class Clock:
    """HH:MM in 2x glyphs, colon blinking once a second."""

    SCALE = 2

    def __init__(self, size: int, color: str = "#f4f1ea",
                 twenty_four: bool = True):
        self.size = size
        self.color = _hex_rgb(color)
        self.twenty_four = twenty_four

    def frame_at(self, t: float) -> Image.Image:
        canvas = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        now = time.localtime()
        hour = now.tm_hour
        suffix = None
        if not self.twenty_four:
            suffix = "AM" if hour < 12 else "PM"
            hour = hour % 12 or 12
        hh, mm = f"{hour:02d}", f"{now.tm_min:02d}"

        digits_w = text_width(hh, self.SCALE)
        colon_w = 4 * self.SCALE
        total = digits_w * 2 + colon_w + 4 * self.SCALE
        x = (self.size - total) // 2
        y = (self.size - 7 * self.SCALE) // 2 - (4 if suffix else 0)

        draw_text(canvas, hh, x, y, self.color, self.SCALE)
        if now.tm_sec % 2 == 0:                      # blink
            cx = x + digits_w + 2 * self.SCALE
            cy = y + 2 * self.SCALE
            canvas[cy:cy + 2, cx:cx + 2] = self.color
            canvas[cy + 6:cy + 8, cx:cx + 2] = self.color
        draw_text(canvas, mm, x + digits_w + colon_w + 4 * self.SCALE, y,
                  self.color, self.SCALE)
        if suffix:
            sw = text_width(suffix, 1)
            draw_text(canvas, suffix, (self.size - sw) // 2,
                      y + 7 * self.SCALE + 5, self.color, 1)
        return Image.fromarray(canvas, "RGB")


class Countdown:
    """A kitchen timer you can read from the far side of the room.

    MM:SS in 2x glyphs, and the panel's border is the vessel: it starts full
    and drains clockwise from the top as the time runs, so the shape of what
    is left is visible long before the digits are legible. When it reaches
    zero the whole panel breathes in the accent for a while, because a wall
    has no bell and light is the loudest thing it can do.
    """

    SCALE = 2

    def __init__(self, size: int, color: str = "#f4f1ea",
                 accent: str = "#e8b04b"):
        self.size = size
        self.color = _hex_rgb(color)
        self.accent = _hex_rgb(accent)
        # The border, as an ordered walk: top edge from the middle out, then
        # down the right, across the bottom, up the left, back to the top
        # middle. Draining clockwise from 12 o'clock is how every dial a
        # person has ever cooked with does it.
        n = size
        path = []
        for x in range(n // 2, n):
            path.append((x, 0))
        for y in range(1, n):
            path.append((n - 1, y))
        for x in range(n - 2, -1, -1):
            path.append((x, n - 1))
        for y in range(n - 2, 0, -1):
            path.append((0, y))
        for x in range(1, n // 2):
            path.append((x, 0))
        self._ring = path

    def frame_at(self, remaining: float, total: float) -> Image.Image:
        canvas = np.zeros((self.size, self.size, 3), dtype=np.uint8)

        if remaining <= 0:
            # Done: breathe. Digits stay up so a glance still says which
            # timer this was (00:00, not a lamp).
            k = 0.35 + 0.65 * (0.5 + 0.5 * np.sin(time.monotonic() * 5.0))
            glow = tuple(int(c * k * 0.55) for c in self.accent)
            canvas[:, :] = glow
            self._digits(canvas, 0, bright=True)
            return Image.fromarray(canvas, "RGB")

        frac = max(0.0, min(1.0, remaining / max(1.0, total)))
        lit = int(len(self._ring) * frac)
        dim = tuple(int(c * 0.25) for c in self.accent)
        for i, (x, y) in enumerate(self._ring):
            canvas[y, x] = self.accent if i < lit else dim
        # the leading edge burns brighter: that point is "now"
        if 0 < lit < len(self._ring):
            x, y = self._ring[lit - 1]
            canvas[y, x] = tuple(min(255, int(c * 1.4)) for c in self.accent)

        self._digits(canvas, int(remaining))
        return Image.fromarray(canvas, "RGB")

    def _digits(self, canvas, seconds: int, bright: bool = False):
        m, s = divmod(max(0, seconds), 60)
        if m > 99:
            text = f"{m // 60}H{m % 60:02d}"
        else:
            text = f"{m:02d}:{s:02d}"
        w = text_width(text, self.SCALE)
        x = (self.size - w) // 2
        y = (self.size - 7 * self.SCALE) // 2
        color = tuple(min(255, int(c * 1.15)) for c in self.color) if bright \
            else self.color
        draw_text(canvas, text, x, y, color, self.SCALE)
