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
