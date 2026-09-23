"""Ticker and clock — the wall speaks and tells time.

Same frame_at(t) contract as DiscAnimator and Ambient, so the main loop
treats every mode the same way: generate, white-balance, ship.
"""
import time

import numpy as np
from PIL import Image, ImageDraw

from .effects import _hex_rgb
from .pixelfont import cell, draw_text, normalize, text_width


def _vertical_bounds(text: str) -> tuple[int, int]:
    """The font's baseline band plus accents and descenders in this line."""
    top, bottom = 0, 7
    for ch in text:
        glyph = cell(ch)
        if glyph is not None:
            rows, _, _, dy = glyph
            top = min(top, dy)
            bottom = max(bottom, dy + len(rows))
    return top, bottom


def wrap_text(text: str, width_px: int, scale: int) -> list[str]:
    """Greedy word wrap against the pixel font's real widths. A word wider
    than the whole line is broken hard rather than dropped."""
    lines = []
    for paragraph in text.split("\n"):
        cur = ""
        words = paragraph.split()
        if not words:
            lines.append("")
            continue
        for word in words:
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

    # Glyphs are drawn at SCALE times the 5x7 font. Two was the whole story
    # when the wall was one 64 pixel panel; a nine panel wall is three times
    # as wide and the same two would put a postage stamp in the middle of it,
    # so the scale follows the panel count and the layout, which is all
    # centred arithmetic, follows the scale.
    @staticmethod
    def _scale_for(size: int) -> int:
        return max(2, 2 * size // 64)

    def __init__(self, size: int, text: str, color: str = "#f4f1ea",
                 speed: float = 1.0, loop: bool = True,
                 colors: list | None = None):
        self.size = size
        self.SCALE = self._scale_for(size)
        self.text = normalize(text).replace("\n", " ") or "?"
        self.color = _hex_rgb(color)
        self.colors = [_hex_rgb(c) for c in (colors or [])]
        self.unit = max(1, size // 64)
        self.px_per_s = 18.0 * max(0.1, speed) * self.unit
        self.loop = loop
        self.width = text_width(self.text, self.SCALE)
        self.travel = self.width + self.size + 4 * self.unit
        top, bottom = _vertical_bounds(self.text)
        self.baseline = (size - (bottom - top) * self.SCALE) // 2 - top * self.SCALE

    def done(self, t: float) -> bool:
        if self.loop:
            return False
        return t * self.px_per_s >= self.travel

    def frame_at(self, t: float) -> Image.Image:
        canvas = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        offset = (max(0.0, t) * self.px_per_s) % self.travel if self.loop \
            else min(max(0.0, t) * self.px_per_s, self.travel)
        x = self.size - int(offset)
        y = self.baseline
        if not self.colors:
            draw_text(canvas, self.text, x, y, self.color, self.SCALE)
        else:
            gi = 0
            for ch in self.text:
                if ch != " ":
                    ink = self.colors[gi] if gi < len(self.colors) else self.color
                    draw_text(canvas, ch, x, y, ink, self.SCALE)
                    gi += 1
                glyph = cell(ch)
                x += (glyph[2] if glyph else 6) * self.SCALE
        return Image.fromarray(canvas, "RGB")


class _TimeFace:
    """One proportioned composition at panel and phone resolutions."""
    def __init__(self, size: int, color: str):
        self.size = size
        self.unit = max(1, size // 64)
        self.scale = max(1, int(size * 3 / 64))
        ink = _hex_rgb(color)
        peak = max(ink)
        self.color = ((190, 201, 214) if peak == 0 else
                      tuple(int(c * 230 / peak) for c in ink) if peak < 230 else ink)
        self.paper = (244, 237, 220)

    def canvas(self):
        return np.zeros((self.size, self.size, 3), dtype=np.uint8)

    def text(self, canvas, text, y, color=None, scale=None, x=None):
        scale = self.unit if scale is None else scale
        if x is None:
            # Snap centered labels to the native 64-pixel design grid so a
            # 192/512 wall has exactly the same balance as its phone preview.
            x = ((self.size // self.unit - text_width(text, scale) // self.unit) // 2) * self.unit
        draw_text(canvas, text, x, round(y * self.size / 64), color or self.paper, scale)

    def pair(self, canvas, top, bottom, labels=None):
        if labels:
            x = round(9 * self.size / 64)
            self.text(canvas, top, 15, self.paper, self.scale, x)
            self.text(canvas, bottom, 38, self.color, self.scale, x)
            self.text(canvas, labels[0], 23, self.paper, self.unit, round(self.size * 51 / 64))
            self.text(canvas, labels[1], 46, self.color, self.unit, round(self.size * 51 / 64))
        else:
            self.text(canvas, top, 15, self.paper, self.scale)
            self.text(canvas, bottom, 38, self.color, self.scale)


class Clock(_TimeFace):
    """An editorial clock: calendar, stacked time and a quiet seconds rail."""
    def __init__(self, size: int, color: str = "#f4f1ea", twenty_four: bool = True):
        super().__init__(size, color)
        self.twenty_four = twenty_four

    def frame_at(self, t: float, when: float | None = None) -> Image.Image:
        now = time.localtime(time.time() if when is None else when)
        hour = now.tm_hour if self.twenty_four else (now.tm_hour % 12 or 12)
        canvas = self.canvas()
        day = ("MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN")[now.tm_wday]
        header = f"{day} {now.tm_mday:02d}"
        if self.twenty_four:
            self.text(canvas, header, 3)
        else:
            self.text(canvas, header, 3, x=4 * self.unit)
            self.text(canvas, "AM" if now.tm_hour < 12 else "PM", 3,
                      self.color, x=self.size - 15 * self.unit)
        self.pair(canvas, f"{hour:02d}", f"{now.tm_min:02d}")
        left, right = 4 * self.unit, self.size - 4 * self.unit
        y = self.size - 2 * self.unit
        canvas[y:y + self.unit, left:right] = (30, 33, 38)
        head = left + round((right - left - self.unit) * now.tm_sec / 59)
        canvas[y:y + self.unit, head:head + self.unit] = self.color
        return Image.fromarray(canvas, "RGB")


class Countdown(_TimeFace):
    """A time stack that resolves into a crafted light ceremony at zero.

    Completion keeps its meaning visible while slow orbital accents move
    around it. Alarms have a separate amber bell; no all-panel flashes.
    """
    def __init__(self, size: int, color: str = "#f4f1ea", accent: str = "#e8b04b"):
        super().__init__(size, color)
        self.accent = _hex_rgb(accent)
        inset = self.unit
        end = size - inset - 1
        mid = size // 2
        self.path = ([(x, inset) for x in range(mid, end + 1)] +
                     [(end, y) for y in range(inset + 1, end + 1)] +
                     [(x, end) for x in range(end - 1, inset - 1, -1)] +
                     [(inset, y) for y in range(end - 1, inset - 1, -1)] +
                     [(x, inset) for x in range(inset + 1, mid)])
        axis = (np.arange(size) + .5) * 64 / size - 32
        self._x, self._y = np.meshgrid(axis, axis)
        self._radius = np.hypot(self._x, self._y)
        self._angle = np.arctan2(self._y, self._x)

    def frame_at(self, remaining: float, total: float, kind: str = "countdown",
                 snoozed: bool = False) -> Image.Image:
        if remaining <= 0:
            return self._ending(max(0.0, -remaining), kind == "alarm")
        canvas = self.canvas()
        frac = max(0, min(1, remaining / max(1, total)))
        fill = round(len(self.path) * frac)
        color = (236, 174, 90) if snoozed else self.accent
        for index, (x, y) in enumerate(self.path):
            if index < fill:
                canvas[y:y + self.unit, x:x + self.unit] = color
        # Header sits just inside the perimeter and never shares its pixels.
        self.text(canvas, "SNOOZE" if snoozed else "REMAIN", 5, self.paper)
        seconds = int(np.ceil(max(0, remaining)))
        minutes, seconds = divmod(seconds, 60)
        top, bottom, labels = f"{minutes:02d}", f"{seconds:02d}", ("M", "S")
        if minutes > 99:
            hour, minutes = divmod(minutes, 60)
            top, bottom, labels = f"{hour:02d}", f"{minutes:02d}", ("H", "M")
        self.pair(canvas, top, bottom, labels)
        return Image.fromarray(canvas, "RGB")

    def _ending(self, elapsed: float, alarm: bool) -> Image.Image:
        canvas = self.canvas()
        jewel = np.array((239, 175, 89) if alarm else (127, 208, 186), dtype=float)
        # The rings occupy only the quiet middle band. Labels remain crisp
        # and still, even on the smallest panel and at the dimmest setting.
        band = (self._y > -20) & (self._y < 20)
        halo = np.exp(-((self._radius - 16.5) / 4.0) ** 2) * .07
        canvas[:] = np.round(halo[..., None] * jewel).astype(np.uint8)
        canvas[~band] = 0
        disk = self._radius < 13.8
        canvas[disk] = (10, 16, 18) if not alarm else (19, 14, 10)

        phase = elapsed * 2 * np.pi / (10 if alarm else 12)
        # Two broad, softly tailed light arcs orbit in opposite directions.
        # Their total brightness stays steady; movement provides the cue.
        for radius, direction, offset, strength in ((16.5, 1, 0, 1.0), (20.5, -1, np.pi, .5)):
            ring = (np.abs(self._radius - radius) < .65) & band
            distance = np.mod(self._angle * direction - phase + offset, 2 * np.pi)
            trail = .16 + .84 * np.exp(-distance * 1.2)
            light = jewel[None, None, :] * trail[..., None] * strength
            canvas[ring] = np.round(light[ring]).astype(np.uint8)
        # A permanent four-point dial makes the artwork feel resolved rather
        # than a loading spinner. Outer points never cross either label.
        for angle in (0, np.pi):
            for radius in (25, 27):
                x, y = np.cos(angle) * radius, np.sin(angle) * radius
                mark = (np.abs(self._x - x) < .7) & (np.abs(self._y - y) < .7)
                canvas[mark] = np.round(jewel * .4).astype(np.uint8)

        image = Image.fromarray(canvas, "RGB")
        draw = ImageDraw.Draw(image)
        scale = self.size / 64
        point = lambda x, y: (round(x * scale), round(y * scale))
        box = lambda x0, y0, x1, y1: (*point(x0, y0), *point(x1, y1))
        width = max(1, round(2 * scale))
        if alarm:
            # The bell's solid footing and two curved shoulders remain
            # recognizable at 64px; unlike a glyph, none of it can truncate.
            draw.arc(box(25, 23, 39, 37), 180, 360, fill=self.paper, width=width)
            draw.line([point(25, 30), point(25, 35), point(22, 39), point(42, 39),
                       point(39, 35), point(39, 30)], fill=self.paper, width=width)
            draw.line([point(29, 43), point(35, 43)], fill=tuple(jewel.astype(int)), width=width)
            draw.line([point(32, 20), point(32, 22)], fill=tuple(jewel.astype(int)), width=width)
        else:
            draw.line([point(23, 32), point(29, 38), point(41, 26)],
                      fill=self.paper, width=max(2, round(3 * scale)), joint="curve")
        canvas = np.asarray(image).copy()
        self.text(canvas, "ALARM" if alarm else "TIME UP", 3, self.paper)
        self.text(canvas, "YOUR CUE" if alarm else "ALL DONE", 55, tuple(jewel.astype(int)))
        return Image.fromarray(canvas, "RGB")


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
        self.px_per_s = 5.5 * max(0.1, speed) * max(1, size // 64)

        base = _hex_rgb(color)
        inks = [_hex_rgb(c) for c in (colors or [])]
        # The glyph grows with the wall: a line of 1x text that filled a 64
        # pixel panel is a thread across a 192 pixel one, and a crawl nobody
        # can read from the sofa is not a crawl.
        sc = max(1, size // 64)
        lines = wrap_text(normalize(text) or "?", size - 4 * sc, sc)
        # Ordinary and intentionally blank lines keep their nine-cell cadence.
        # Extended glyphs can rise above the baseline or descend below seven;
        # give that line its actual ink height and the same two-cell leading.
        bounds = [_vertical_bounds(line) for line in lines]
        line_heights = [(bottom - top + 2) * sc for top, bottom in bounds]
        h = sum(line_heights) + sc
        rgb = np.zeros((h, size, 3), dtype=np.uint8)
        # Glyph inks are baked into the plane itself; the resampler then
        # only ever moves and fades what is already the right colour. The
        # glyph counter runs across lines, so a wrapped word keeps its inks.
        gi, y = 0, 0
        for i, ln in enumerate(lines):
            x = (size - text_width(ln, sc)) // 2
            baseline = y - bounds[i][0] * sc
            for ch in ln:
                if ch != " ":
                    ink = inks[gi] if gi < len(inks) else base
                    draw_text(rgb, ch, x, baseline, ink, sc)
                    gi += 1
                glyph = cell(ch)
                x += (glyph[2] if glyph else 6) * sc
            y += line_heights[i]
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
        self.travel = self.h + self.span + 8 * sc

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
        return t * self.px_per_s >= self.travel

    def frame_at(self, t: float) -> Image.Image:
        p = (max(0.0, t) * self.px_per_s) % self.travel if self.loop else max(0.0, t) * self.px_per_s
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
