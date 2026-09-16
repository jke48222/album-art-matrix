"""A few large, quiet words, read a page at a time, then the room returns.

The answer is set in the wall's familiar font on black, with generous space
around the letters. Pages change every three seconds and the final page
rests for four more. Layout uses measured glyph widths: a 64-pixel wall
cannot fit ten 2x characters, so short lines continue on the next page.
The larger wall has its own margins and line count rather than a blow-up.
"""
import re

import numpy as np

from .pixelfont import draw_text, normalize, text_width
from .text_modes import wrap_text

PAGE_SECONDS = 3.0
FINAL_HOLD = 4.0
INK = (232, 226, 213)


class Answer:
    def __init__(self, size, text):
        self.size = size
        self.scale = 2 if size < 128 else 3
        self.margin = 1 if size < 128 else 12
        self.line_height = 8 * self.scale
        self.width = size - self.margin * 2
        self.rows = max(1, (size - self.margin * 2 + self.scale) // self.line_height)
        clean = str(text).replace(chr(0x2014), ', ').replace(chr(0x2013), '-')
        clean = re.sub(r'[`*#]', '', clean)
        self.text = normalize(' '.join(clean.split())[:600]) or "Sorry."
        self.lines = wrap_text(self.text, self.width, self.scale)
        self.pages = [self.lines[i:i+self.rows] for i in range(0, len(self.lines), self.rows)]
        self.duration = len(self.pages) * PAGE_SECONDS + FINAL_HOLD
        self._frames = [self._draw(page) for page in self.pages]

    def _draw(self, lines):
        canvas = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        height = len(lines) * self.line_height - self.scale
        y = max(self.margin, (self.size - height) // 2)
        for line in lines:
            x = max(self.margin, (self.size - text_width(line, self.scale)) // 2)
            draw_text(canvas, line, x, y, INK, self.scale)
            y += self.line_height
        return canvas

    def frame_at(self, t):
        index = min(len(self.pages) - 1, max(0, int(t / PAGE_SECONDS)))
        return self._frames[index].copy()
