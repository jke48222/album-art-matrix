"""The answer face: words on the panel, a page at a time.

Claude's answer, a note left from a Shortcut, the name of the song, all
arrive here as text and leave as pages of the 5x7 pixel font. At 64 the
glyphs are drawn 1x (ten characters a line, six lines a page, readable at
arm's length); at 192 at 2x (fifteen characters, ten lines, readable across
a room). Words wrap at spaces; a word longer than a line is broken. Pages
turn every PAGE_S; after the last page the face holds for HOLD_S and says
it is done, and the wall goes back to what it was doing.
"""
from __future__ import annotations

import numpy as np

from .pixelfont import draw_text, normalize, text_width

PAGE_S = 3.0
HOLD_S = 4.0
LEADING = 2                      # pixels between lines, before scaling


def layout(size: int) -> tuple[int, int, int, int]:
    """(scale, chars per line, lines per page, margin) for a wall side.

    At 64 the font is drawn 1x: ten characters a line, six lines, glyphs
    12 mm tall on a P2.5 panel, readable at arm's length. 2x would give
    five characters a line, which is a ticker, not an answer. At 192 it is
    2x: fifteen characters, ten lines, glyphs 35 mm tall, readable across
    a room."""
    if size <= 96:
        scale, margin = 1, 2
    else:
        scale, margin = 2, 6
    glyph_w = 6 * scale           # 5 px plus the 1 px space
    line_h = (7 + LEADING) * scale
    chars = max(1, (size - 2 * margin) // glyph_w)
    lines = max(1, (size - 2 * margin) // line_h)
    return scale, chars, lines, margin


def wrap(text: str, chars: int) -> list[str]:
    out: list[str] = []
    for para in normalize(text or "").replace("\r", "").split("\n"):
        words = para.split()
        if not words:
            out.append("")
            continue
        line = ""
        for w in words:
            while len(w) > chars:                  # a word longer than a line
                if line:
                    out.append(line)
                    line = ""
                out.append(w[:chars])
                w = w[chars:]
            if not line:
                line = w
            elif len(line) + 1 + len(w) <= chars:
                line += " " + w
            else:
                out.append(line)
                line = w
        out.append(line)
    while out and out[-1] == "":
        out.pop()
    return out


def pages(text: str, size: int) -> list[list[str]]:
    scale, chars, lines, _ = layout(size)
    ls = wrap(text, chars) or [""]
    return [ls[i:i + lines] for i in range(0, len(ls), lines)]


class AnswerFace:
    def __init__(self, size: int, text: str, ink=(230, 220, 200), page_s: float = PAGE_S):
        self.size = size
        self.text = text
        self.ink = ink
        self.page_s = page_s
        self.scale, self.chars, self.lines, self.margin = layout(size)
        self.pages = pages(text, size)

    @property
    def total_s(self) -> float:
        return len(self.pages) * self.page_s + HOLD_S

    def page_at(self, t: float) -> int:
        return min(len(self.pages) - 1, max(0, int(t // self.page_s)))

    def done(self, t: float) -> bool:
        return t >= self.total_s

    def frame_at(self, t: float) -> np.ndarray:
        f = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        page = self.pages[self.page_at(t)]
        line_h = (7 + LEADING) * self.scale
        y = self.margin
        for line in page:
            draw_text(f, line, self.margin, y, self.ink, self.scale)
            y += line_h
        # more pages: a row of dots at the bottom right, the current one lit
        if len(self.pages) > 1:
            n = len(self.pages)
            cur = self.page_at(t)
            dot = self.scale
            x = self.size - self.margin - n * (dot + 1)
            yy = self.size - self.margin - dot
            for i in range(n):
                col = self.ink if i == cur else tuple(int(c * 0.25) for c in self.ink)
                f[yy:yy + dot, x + i * (dot + 1):x + i * (dot + 1) + dot] = col
        return f
