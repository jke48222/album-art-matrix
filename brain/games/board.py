"""Drawing for the games: the same board at 64 and at 192.

Everything is laid out from a `scale` (1 at 64, 3 at 192) so a cell that
is 9 LEDs on the bench panel is 27 on the wall, letters go from the 5x7
font at 1x to 3x, and one description of a board serves both. Colours are
the games' own, restrained: a panel is bright, and a full grid of
saturated tiles reads as noise from across a room.
"""
from __future__ import annotations

import numpy as np

from ..art.pixelfont import draw_text, text_width

BLACK = (0, 0, 0)
INK = (235, 232, 225)
DIM = (120, 118, 112)
FAINT = (52, 52, 56)
EDGE = (70, 70, 76)
GREEN = (83, 141, 78)
YELLOW = (181, 159, 59)
GREY = (58, 58, 60)
BLUE = (72, 118, 200)
PURPLE = (146, 96, 180)
RED = (190, 60, 50)
ORANGE = (220, 140, 40)
WHITE = (250, 250, 250)


def scale_for(size: int) -> int:
    return 1 if size <= 96 else 3


def blank(size: int) -> np.ndarray:
    return np.zeros((size, size, 3), dtype=np.uint8)


def fill(canvas: np.ndarray, x: int, y: int, w: int, h: int, color):
    h_, w_ = canvas.shape[:2]
    x0, y0, x1, y1 = max(0, x), max(0, y), min(w_, x + w), min(h_, y + h)
    if x1 > x0 and y1 > y0:
        canvas[y0:y1, x0:x1] = color


def rect(canvas: np.ndarray, x: int, y: int, w: int, h: int, color, thick: int = 1):
    fill(canvas, x, y, w, thick, color)
    fill(canvas, x, y + h - thick, w, thick, color)
    fill(canvas, x, y, thick, h, color)
    fill(canvas, x + w - thick, y, thick, h, color)


def disc(canvas: np.ndarray, cx: float, cy: float, r: float, color):
    h, w = canvas.shape[:2]
    ys, xs = np.mgrid[0:h, 0:w]
    m = (xs + 0.5 - cx) ** 2 + (ys + 0.5 - cy) ** 2 <= r * r
    canvas[m] = color


def text(canvas: np.ndarray, s: str, x: int, y: int, color=INK, scale: int = 1):
    draw_text(canvas, s, x, y, color, scale)


def text_centred(canvas: np.ndarray, s: str, cx: int, y: int, color=INK, scale: int = 1):
    draw_text(canvas, s, int(cx - text_width(s, scale) / 2), y, color, scale)


def fit_text(s: str, width: int, scale: int = 1) -> str:
    """Cut a line to what fits, with a dot when it had to be."""
    if text_width(s, scale) <= width:
        return s
    while s and text_width(s + ".", scale) > width:
        s = s[:-1]
    return s + "."


def letter_tile(canvas: np.ndarray, x: int, y: int, cell: int, ch: str, back, ink=INK,
                scale: int = 1, edge=None):
    """A square tile with one big letter centred in it."""
    if back is not None:
        fill(canvas, x, y, cell, cell, back)
    if edge is not None:
        rect(canvas, x, y, cell, cell, edge, thick=max(1, scale // 2 if scale > 1 else 1))
    if ch:
        gw, gh = 5 * scale, 7 * scale
        text(canvas, ch.upper(), x + (cell - gw) // 2, y + (cell - gh) // 2, ink, scale)


def grid_geometry(size: int, cols: int, rows: int, cell: int, gap: int, top: int | None = None) -> tuple[int, int, int, int]:
    """(x0, y0, cell, gap) for a grid centred horizontally, at `top` or
    centred vertically."""
    w = cols * cell + (cols - 1) * gap
    h = rows * cell + (rows - 1) * gap
    x0 = (size - w) // 2
    y0 = (size - h) // 2 if top is None else top
    return x0, y0, cell, gap


def header(canvas: np.ndarray, size: int, left: str, right: str = "", scale: int = 1, y: int = 0, color=DIM):
    """A line of small text at the top (only at 192, where there is room)."""
    if size <= 96:
        return
    text(canvas, left, 6, y + 4, color, 1)
    if right:
        text(canvas, right, size - 6 - text_width(right, 1), y + 4, color, 1)


def scoreboard(size: int, title: str, lines: list[tuple[str, str]], t: float = 0.0) -> np.ndarray:
    """A face for between games: the title, then name and score pairs."""
    c = blank(size)
    s = scale_for(size)
    y = 4 * s
    text_centred(c, fit_text(title, size - 4, s), size // 2, y, INK, s)
    y += (7 + 4) * s
    for name, score in lines[: 4 if size <= 96 else 10]:
        text(c, fit_text(name, size // 2, s), 3 * s, y, DIM, s)
        text(c, score, size - 3 * s - text_width(score, s), y, INK, s)
        y += (7 + 2) * s
    return c
