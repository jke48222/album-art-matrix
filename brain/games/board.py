"""Drawing for the games: one design, two sizes.

Everything is laid out from a `scale` (1 at 64, 3 at 192) so a tile that
is 9 LEDs on the bench panel is 27 on the wall, letters go from the 5x7
font at 1x to 3x, and one description of a board serves both. The
palette is restrained on purpose: a panel is bright, and a full grid of
saturated tiles reads as noise from across a room. Tiles have a lit top
edge and a shaded bottom edge at 192, corners come off at both sizes,
and the pieces that move ease in and out rather than snapping.

The primitives here draw straight into an HxWx3 uint8 canvas; the few
that need real geometry (polygons, thick lines, arcs) go through Pillow
for a moment and come back.
"""
from __future__ import annotations

import math

import numpy as np
from PIL import Image, ImageDraw

from ..art.pixelfont import draw_text, text_width

# ---- the palette ----------------------------------------------------------------------
BLACK = (0, 0, 0)
INK = (236, 232, 222)              # warm white, the wall's text
DIM = (128, 124, 116)              # secondary text
FAINT = (46, 46, 52)               # empty tiles, rules
EDGE = (84, 84, 92)                # outlines
SLATE = (30, 30, 36)               # a resting tile
SLATE2 = (44, 44, 52)              # a raised tile
GREEN = (78, 150, 84)
YELLOW = (196, 166, 56)
HONEY = (232, 178, 44)
GREY = (66, 66, 70)
BLUE = (70, 122, 210)
PURPLE = (150, 100, 190)
RED = (200, 66, 56)
ORANGE = (226, 140, 46)
CYAN = (74, 196, 214)
WHITE = (252, 250, 246)


def scale_for(size: int) -> int:
    return 1 if size <= 96 else 3


def blank(size: int) -> np.ndarray:
    return np.zeros((size, size, 3), dtype=np.uint8)


# ---- easing ------------------------------------------------------------------------------------
def clamp01(t: float) -> float:
    return 0.0 if t < 0 else 1.0 if t > 1 else t


def ease_out(t: float) -> float:
    t = clamp01(t)
    return 1 - (1 - t) ** 3


def ease_in_out(t: float) -> float:
    t = clamp01(t)
    return t * t * (3 - 2 * t)


def breathe(t: float, period: float = 2.4) -> float:
    """0..1 slowly, for a cursor that is alive."""
    return 0.5 - 0.5 * math.cos(2 * math.pi * t / period)


def mix(a, b, f: float):
    f = clamp01(f)
    return tuple(int(round(a[i] + (b[i] - a[i]) * f)) for i in range(3))


def dimmed(color, f: float):
    return tuple(int(c * f) for c in color)


# ---- rectangles and tiles ---------------------------------------------------------------------
def fill(canvas: np.ndarray, x: int, y: int, w: int, h: int, color):
    h_, w_ = canvas.shape[:2]
    x0, y0, x1, y1 = max(0, int(x)), max(0, int(y)), min(w_, int(x + w)), min(h_, int(y + h))
    if x1 > x0 and y1 > y0:
        canvas[y0:y1, x0:x1] = color


def rect(canvas: np.ndarray, x: int, y: int, w: int, h: int, color, thick: int = 1):
    fill(canvas, x, y, w, thick, color)
    fill(canvas, x, y + h - thick, w, thick, color)
    fill(canvas, x, y, thick, h, color)
    fill(canvas, x + w - thick, y, thick, h, color)


def rounded(canvas: np.ndarray, x: int, y: int, w: int, h: int, color, r: int = 1):
    """A filled rectangle with its corners off: r=1 drops the corner
    pixel, r>1 rounds with a quarter circle."""
    if r <= 0 or w < 4 or h < 4:
        fill(canvas, x, y, w, h, color)
        return
    if r == 1:
        fill(canvas, x + 1, y, w - 2, h, color)
        fill(canvas, x, y + 1, 1, h - 2, color)
        fill(canvas, x + w - 1, y + 1, 1, h - 2, color)
        return
    H, W = canvas.shape[:2]
    ys, xs = np.mgrid[max(0, y):min(H, y + h), max(0, x):min(W, x + w)]
    if ys.size == 0:
        return
    cx0, cx1, cy0, cy1 = x + r, x + w - 1 - r, y + r, y + h - 1 - r
    dx = np.maximum(0, np.maximum(cx0 - xs, xs - cx1))
    dy = np.maximum(0, np.maximum(cy0 - ys, ys - cy1))
    m = dx * dx + dy * dy <= (r + 0.3) ** 2
    canvas[ys[m], xs[m]] = color


def outline(canvas: np.ndarray, x: int, y: int, w: int, h: int, color, r: int = 1, thick: int = 1):
    """A rounded outline: the rounded fill minus its inside."""
    tmp = canvas.copy()
    rounded(tmp, x, y, w, h, color, r)
    inner = tmp.copy()
    rounded(inner, x + thick, y + thick, w - 2 * thick, h - 2 * thick, (1, 2, 3), max(0, r - thick))
    m = (tmp != canvas).any(-1) & ~((inner != tmp).any(-1))
    canvas[m] = color


def tile(canvas: np.ndarray, x: int, y: int, w: int, h: int, color, scale: int = 1, r: int | None = None):
    """A tile: rounded, with a lighter top edge and a darker bottom edge
    at 192 so it sits on the wall like a key."""
    if r is None:
        r = 1 if scale == 1 else 3
    rounded(canvas, x, y, w, h, color, r)
    if scale > 1 and h > 6:
        lit, shade = mix(color, WHITE, 0.16), mix(color, BLACK, 0.28)
        fill(canvas, x + r, y, w - 2 * r, 1, lit)
        fill(canvas, x + r, y + h - 1, w - 2 * r, 1, shade)


def shade(canvas: np.ndarray, x: int, y: int, w: int, h: int, f: float):
    H, W = canvas.shape[:2]
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    if x1 > x0 and y1 > y0:
        canvas[y0:y1, x0:x1] = np.clip(canvas[y0:y1, x0:x1].astype(np.float32) * f, 0, 255).astype(np.uint8)


# ---- round things ---------------------------------------------------------------------------
def disc(canvas: np.ndarray, cx: float, cy: float, r: float, color, soft: float = 0.0):
    """A filled disc; `soft` in pixels blends its edge."""
    h, w = canvas.shape[:2]
    y0, y1 = max(0, int(cy - r - 2)), min(h, int(cy + r + 3))
    x0, x1 = max(0, int(cx - r - 2)), min(w, int(cx + r + 3))
    if y1 <= y0 or x1 <= x0:
        return
    ys, xs = np.mgrid[y0:y1, x0:x1]
    d = np.sqrt((xs + 0.5 - cx) ** 2 + (ys + 0.5 - cy) ** 2)
    if soft <= 0:
        m = d <= r
        canvas[ys[m], xs[m]] = color
        return
    a = np.clip((r + soft / 2 - d) / soft, 0, 1)[..., None]
    region = canvas[y0:y1, x0:x1].astype(np.float32)
    canvas[y0:y1, x0:x1] = (region * (1 - a) + np.array(color, np.float32) * a).astype(np.uint8)


def ring(canvas: np.ndarray, cx: float, cy: float, r: float, thick: float, color):
    h, w = canvas.shape[:2]
    ys, xs = np.mgrid[0:h, 0:w]
    d = np.sqrt((xs + 0.5 - cx) ** 2 + (ys + 0.5 - cy) ** 2)
    m = (d <= r) & (d > r - thick)
    canvas[m] = color


def glow(canvas: np.ndarray, cx: float, cy: float, radius: float, color, strength: float = 0.5):
    """Light added around a point, falling off to nothing at `radius`."""
    h, w = canvas.shape[:2]
    y0, y1 = max(0, int(cy - radius)), min(h, int(cy + radius + 1))
    x0, x1 = max(0, int(cx - radius)), min(w, int(cx + radius + 1))
    if y1 <= y0 or x1 <= x0:
        return
    ys, xs = np.mgrid[y0:y1, x0:x1]
    d = np.sqrt((xs + 0.5 - cx) ** 2 + (ys + 0.5 - cy) ** 2) / max(1.0, radius)
    a = np.clip(1 - d, 0, 1) ** 2 * strength
    region = canvas[y0:y1, x0:x1].astype(np.float32)
    canvas[y0:y1, x0:x1] = np.clip(region + np.array(color, np.float32) * a[..., None], 0, 255).astype(np.uint8)


# ---- geometry through Pillow ---------------------------------------------------------------
def _draw(canvas: np.ndarray):
    img = Image.fromarray(canvas)
    return img, ImageDraw.Draw(img)


def _back(canvas: np.ndarray, img: Image.Image):
    canvas[...] = np.asarray(img, dtype=np.uint8)


def polygon(canvas: np.ndarray, points, color):
    img, d = _draw(canvas)
    d.polygon([(float(x), float(y)) for x, y in points], fill=color)
    _back(canvas, img)


def hexagon(canvas: np.ndarray, cx: float, cy: float, r: float, color, pointy: bool = True):
    pts = []
    for k in range(6):
        a = math.pi / 3 * k + (math.pi / 6 if pointy else 0.0) - (math.pi / 2 if pointy else 0.0)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    polygon(canvas, pts, color)


def line(canvas: np.ndarray, p0, p1, color, width: int = 1):
    img, d = _draw(canvas)
    d.line([(float(p0[0]), float(p0[1])), (float(p1[0]), float(p1[1]))], fill=color, width=max(1, int(width)))
    _back(canvas, img)


def arc(canvas: np.ndarray, cx: float, cy: float, r: float, start_deg: float, end_deg: float, color, width: int = 1):
    """An arc clockwise from `start_deg` (0 is up)."""
    img, d = _draw(canvas)
    box = [cx - r, cy - r, cx + r, cy + r]
    d.arc(box, start=start_deg - 90, end=end_deg - 90, fill=color, width=max(1, int(width)))
    _back(canvas, img)


# ---- text ----------------------------------------------------------------------------------------
def text(canvas: np.ndarray, s: str, x: int, y: int, color=INK, scale: int = 1):
    draw_text(canvas, s, int(x), int(y), color, scale)


def text_centred(canvas: np.ndarray, s: str, cx: int, y: int, color=INK, scale: int = 1):
    draw_text(canvas, s, int(cx - text_width(s, scale) / 2), int(y), color, scale)


def text_right(canvas: np.ndarray, s: str, right: int, y: int, color=INK, scale: int = 1):
    draw_text(canvas, s, int(right - text_width(s, scale)), int(y), color, scale)


def text_scrolled(canvas: np.ndarray, s: str, x: int, y: int, w: int, t: float,
                  color=INK, scale: int = 1, speed: float = 9.0, height: int = 9):
    """A label wider than its box, travelling through it so all of it is read.

    On one 64x64 panel a Connections tile is four characters wide and most of
    its words are six, so the board used to cut them: PENCIL became PENC and
    BRIDGE became BRID, which is not a word game any more. Rather than cut,
    the word moves. Centred and still when it already fits, which is most
    labels and every label on the nine-panel wall.

    Only lit pixels are copied, so whatever the tile is painted stays behind
    the letters."""
    full = text_width(s, scale)
    if full <= w:
        text_centred(canvas, s, x + w // 2, y, color, scale)
        return
    gap = 5 * scale
    span = full + gap
    # A mask, drawn in white, rather than the glyph in its own colour: the
    # colour here is often BLACK (a picked tile is light with dark letters on
    # it) and a "copy the lit pixels" test would drop every one of them.
    mask = np.zeros((height * scale, span, 3), dtype=np.uint8)
    draw_text(mask, s, 0, 0, (255, 255, 255), scale)
    H, W = canvas.shape[:2]
    y0, y1 = max(0, y), min(H, y + height * scale)
    if y1 <= y0:
        return
    # A beat still at the start of every lap, so the eye can catch the first
    # letters before they move. A label that never stops is read twice as
    # slowly as one that waits a moment and then travels.
    hold = 1.1
    lap = hold + span / speed
    at = (t % lap) - hold
    off = 0 if at < 0 else int(at * speed) % span
    for col in range(w):
        xx = x + col
        if not (0 <= xx < W):
            continue
        lit = mask[(y0 - y):(y1 - y), (off + col) % span, 0] > 0
        if lit.any():
            canvas[y0:y1, xx][lit] = color


def fit_text(s: str, width: int, scale: int = 1) -> str:
    """Cut a line to what fits, with a dot when it had to be."""
    if text_width(s, scale) <= width:
        return s
    while s and text_width(s + ".", scale) > width:
        s = s[:-1]
    return s + "."


def wrap_text(s: str, width: int, scale: int = 1) -> list[str]:
    out, line_ = [], ""
    for w in s.split():
        cand = (line_ + " " + w).strip()
        if text_width(cand, scale) <= width or not line_:
            line_ = cand
        else:
            out.append(line_)
            line_ = w
    if line_:
        out.append(line_)
    return out


def letter_tile(canvas: np.ndarray, x: int, y: int, cell: int, ch: str, back, ink=INK,
                scale: int = 1, edge=None):
    """A square tile with one big letter centred in it."""
    if back is not None:
        tile(canvas, x, y, cell, cell, back, scale)
    if edge is not None:
        outline(canvas, x, y, cell, cell, edge, 1 if scale == 1 else 3, 1)
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


# ---- furniture ------------------------------------------------------------------------------------
HEADER_H = 14                       # at 192: the band the title sits in


def header(canvas: np.ndarray, size: int, left: str, right: str = "", scale: int = 1, y: int = 0,
           color=DIM, accent=None):
    """A line of small text at the top with a hairline under it (only at
    192, where there is room); `accent` colours a short mark at the left."""
    if size <= 96:
        return
    if accent is not None:
        fill(canvas, 4, y + 4, 2, 7, accent)
        text(canvas, left, 9, y + 4, color, 1)
    else:
        text(canvas, left, 4, y + 4, color, 1)
    if right:
        text_right(canvas, right, size - 4, y + 4, color, 1)
    fill(canvas, 4, y + HEADER_H - 1, size - 8, 1, FAINT)


def banner(canvas: np.ndarray, size: int, s: str, color=INK, back=SLATE2, scale: int | None = None):
    """A message strip along the bottom."""
    s_ = scale or (1 if size <= 96 else 1)
    h = 9 * s_ + 2 if size <= 96 else 16
    fill(canvas, 0, size - h, size, h, back)
    fill(canvas, 0, size - h, size, 1, mix(back, WHITE, 0.12))
    text_centred(canvas, fit_text(s, size - 4, s_), size // 2, size - h + (h - 7 * s_) // 2, color, s_)


def progress(canvas: np.ndarray, x: int, y: int, w: int, h: int, frac: float, color, back=FAINT, head=None):
    """A bar, with a brighter head pixel where it ends."""
    rounded(canvas, x, y, w, h, back, 1 if h > 2 else 0)
    n = int(round(w * clamp01(frac)))
    if n > 0:
        rounded(canvas, x, y, n, h, color, 1 if h > 2 else 0)
        if head is not None and n < w:
            fill(canvas, x + n - 1, y, 1, h, head)


def big_number(canvas: np.ndarray, s: str, cx: int, cy: int, scale: int, color):
    text_centred(canvas, s, cx, cy - 7 * scale // 2, color, scale)


def scoreboard(size: int, title: str, lines: list[tuple[str, str]], t: float = 0.0,
               accent=YELLOW) -> np.ndarray:
    """A face for between games: the title, then name and score pairs
    with a bar that fills in as the face appears."""
    c = blank(size)
    s = scale_for(size)
    big = size > 96
    y = 4 * s if not big else 10
    text_centred(c, fit_text(title.upper(), size - 8, s), size // 2, y, INK, s)
    y += 7 * s + 3 * s
    fill(c, size // 2 - 8 * s, y, 16 * s, 1, accent)
    y += 4 * s
    reveal = ease_out(t / 0.8)
    for i, (name, score) in enumerate(lines[: 4 if size <= 96 else 9]):
        text(c, fit_text(name, size // 2, s), 3 * s, y, DIM if i else INK, s)
        text_right(c, score, size - 3 * s, y, INK, s)
        if big:
            progress(c, 3 * s, y + 8, size - 6 * s, 2, reveal if i == 0 else reveal * 0.4, accent if i == 0 else EDGE)
        y += (7 + (6 if big else 2)) * s
    return c
