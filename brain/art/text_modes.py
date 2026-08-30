"""Ticker and clock — the wall speaks and tells time.

Same frame_at(t) contract as DiscAnimator and Ambient, so the main loop
treats every mode the same way: generate, white-balance, ship.
"""
import time

import numpy as np
from PIL import Image

from .effects import _hex_rgb
from .pixelfont import draw_text, normalize, text_width


def wrap_text(text: str, width_px: int, scale: int) -> list[str]:
    """Greedy word wrap against the pixel font's real widths. A word wider
    than the whole line is broken hard rather than dropped."""
    lines, cur = [], ""
    for word in text.split():
        cand = word if not cur else cur + " " + word
        if text_width(cand, scale) <= width_px:
            cur = cand
            continue
        if cur:
            lines.append(cur)
        while text_width(word, scale) > width_px:
            k = 1
            while k < len(word) and text_width(word[:k + 1], scale) <= width_px:
                k += 1
            lines.append(word[:k])
            word = word[k:]
        cur = word
    if cur:
        lines.append(cur)
    return lines or ["?"]


class Ticker:
    """Text scrolling right to left, 2x glyphs, vertically centered.

    speed is the control-state multiplier (0.1-3.0); 1.0 ≈ 18 px/s,
    which reads comfortably at 64 px wide.

    colors, when given, ink the visible glyphs one by one in order; spaces
    consume nothing, so the same array means the same thing in every style
    and survives any wrapping. Glyphs past the end wear the base ink.
    """

    SCALE = 2

    def __init__(self, size: int, text: str, color: str = "#f4f1ea",
                 speed: float = 1.0, loop: bool = True,
                 colors: list | None = None):
        self.size = size
        self.text = normalize(text) or "?"
        self.color = _hex_rgb(color)
        self.colors = [_hex_rgb(c) for c in (colors or [])]
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
        if not self.colors:
            draw_text(canvas, self.text, x, y, self.color, self.SCALE)
        else:
            gi = 0
            for ch in self.text:
                if ch != " ":
                    ink = self.colors[gi] if gi < len(self.colors) else self.color
                    draw_text(canvas, ch, x, y, ink, self.SCALE)
                    gi += 1
                x += 6 * self.SCALE
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


class Crawl:
    """Long text up the panel: flat like a teleprompter, or tilted away like
    the opening of a film.

    The text is rasterised once into a tall mask, and each frame is a
    resampling of it: every output row knows which source row it shows and
    how wide the plane is there. Flat mode is the identity version of the
    same machinery. Tilt compresses rows toward a vanishing point at the top
    and fades them out just before they reach it, which is the whole trick;
    at 64 pixels nothing more is needed and nothing more would fit.

    Rows are blended between their two nearest source rows, because at a few
    pixels a second nearest-neighbour stepping reads as a tick, and a crawl
    should pour.
    """

    def __init__(self, size: int, text: str, color: str = "#f4f1ea",
                 speed: float = 1.0, loop: bool = True, tilt: bool = False,
                 colors: list | None = None):
        self.size = size
        self.loop = loop
        # Reading several lines is slower work than watching one slide by.
        self.px_per_s = 5.5 * max(0.1, speed)

        base = _hex_rgb(color)
        inks = [_hex_rgb(c) for c in (colors or [])]
        lines = wrap_text(normalize(text) or "?", size - 4, 1)
        line_h = 9                      # 7 px of glyph, 2 of leading
        h = len(lines) * line_h + 1
        rgb = np.zeros((h, size, 3), dtype=np.uint8)
        # Glyph inks are baked into the plane itself; the resampler then
        # only ever moves and fades what is already the right colour. The
        # glyph counter runs across lines, so a wrapped word keeps its inks.
        gi = 0
        for i, ln in enumerate(lines):
            x = (size - text_width(ln, 1)) // 2
            for ch in ln:
                if ch != " ":
                    ink = inks[gi] if gi < len(inks) else base
                    draw_text(rgb, ch, x, i * line_h, ink, 1)
                    gi += 1
                x += 6
        self.mask = rgb.astype(np.float32) / 255.0
        self.h = h

        ys = np.arange(size, dtype=np.float32)
        d = ys / (size - 1)             # 0 at the top row, 1 at the bottom
        if tilt:
            scale = 0.28 + 0.87 * d ** 1.35   # >1 at the bottom: the near line overflows
            self.fade = np.clip((d - 0.05) / 0.30, 0.0, 1.0) ** 1.2
        else:
            scale = np.ones(size, dtype=np.float32)
            # a soft entrance and exit, the way a prompter masks its glass
            self.fade = np.minimum(1.0, np.minimum(d / 0.08, (1 - d) / 0.08))

        # One output row advances 1/scale source rows; walking that from the
        # bottom of the view upward gives each row its distance behind the
        # front of the crawl.
        step = 1.0 / scale
        rev = np.concatenate([[0.0], np.cumsum(step[::-1][:-1])])
        self.offset = rev[::-1].astype(np.float32)
        self.span = float(self.offset[0])

        # Horizontal resampling per row: where each output pixel reads from,
        # and whether that lands on the plane at all.
        c = (size - 1) / 2.0
        xs = np.arange(size, dtype=np.float32)
        self.xi = np.zeros((size, size), dtype=np.int32)
        self.xok = np.zeros((size, size), dtype=bool)
        for y in range(size):
            src = (xs - c) / scale[y] + c
            idx = np.round(src).astype(np.int32)
            ok = (idx >= 0) & (idx < size)
            self.xi[y] = np.clip(idx, 0, size - 1)
            self.xok[y] = ok

    def done(self, t: float) -> bool:
        if self.loop:
            return False
        return t * self.px_per_s > self.h + self.span + 8

    def frame_at(self, t: float) -> Image.Image:
        travel = self.h + self.span + 8
        p = (t * self.px_per_s) % travel if self.loop else t * self.px_per_s
        src = p - self.offset           # source row per output row, floats
        out = np.zeros((self.size, self.size, 3), dtype=np.float32)
        for y in range(self.size):
            lo = int(np.floor(src[y]))
            frac = src[y] - lo
            row = np.zeros((self.size, 3), dtype=np.float32)
            if 0 <= lo < self.h:
                row += self.mask[lo] * (1.0 - frac)
            if 0 <= lo + 1 < self.h:
                row += self.mask[lo + 1] * frac
            if not row.any():
                continue
            vals = np.where(self.xok[y][:, None], row[self.xi[y]], 0.0)
            out[y] = vals * self.fade[y] * 255.0
        return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGB")
