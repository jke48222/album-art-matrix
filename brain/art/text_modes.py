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
        # The colon carries the whole gap: hours, a breath, two dots, a
        # breath, minutes. The old spread put 16px between the groups and
        # the face read as two separate numbers; 10px reads as one time.
        gap = 5 * self.SCALE
        total = digits_w * 2 + gap
        x = (self.size - total) // 2
        y = (self.size - 7 * self.SCALE) // 2 - (4 if suffix else 0)

        draw_text(canvas, hh, x, y, self.color, self.SCALE)
        if now.tm_sec % 2 == 0:                      # blink
            cx = x + digits_w + gap // 2 - 1
            cy = y + 2 * self.SCALE
            canvas[cy:cy + 2, cx:cx + 2] = self.color
            canvas[cy + 6:cy + 8, cx:cx + 2] = self.color
        draw_text(canvas, mm, x + digits_w + gap, y,
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
    is left is visible long before the digits are legible; what has run out
    is dark, since this panel shows a dim accent as red. The drain is
    continuous: the border's leading LED is lit by exactly the fraction of
    its share of the time that is left, and a soft bright head rides that
    edge, so the eye sees a point sliding round the panel rather than a
    light going out every so often.

    When it reaches zero the wall has no bell, and light is the loudest thing
    it can do: a white strike, then fireworks. Shells rise from the foot of
    the panel and burst in the accent and the ink, sparks fall and fade, the
    border flashes with every burst, and the digits stay up at 00:00 so a
    glance still says which timer this was. It runs for three minutes unless
    the phone stops it.
    """

    SCALE = 2
    GRAVITY = 26.0          # px/s^2 on sparks
    SHELL_GRAVITY = 30.0    # px/s^2 on a rising shell

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
        for y in range(n - 2, -1, -1):        # up the left, corner included
            path.append((0, y))
        for x in range(1, n // 2):
            path.append((x, 0))
        self._ring = path
        self._ring_x = np.array([x for x, _ in path], dtype=np.intp)
        self._ring_y = np.array([y for _, y in path], dtype=np.intp)
        self._ring_i = np.arange(len(path), dtype=np.float32)
        # the alarm's state: sparks in flight, shells on the way up
        self._rng = np.random.default_rng()
        self._last = None
        self._shells: list[dict] = []
        self._sparks = np.zeros((0, 4), dtype=np.float32)    # x y vx vy
        self._spark_rgb = np.zeros((0, 3), dtype=np.float32)
        self._spark_age = np.zeros(0, dtype=np.float32)
        self._spark_life = np.zeros(0, dtype=np.float32)
        self._next_launch = 0.0
        self._flash_at = -1e9
        self._flash_rgb = np.zeros(3, dtype=np.float32)
        self._flash_xy = (size // 2, size // 2)
        self._zero_at = None

    # -- counting down ------------------------------------------------------

    def frame_at(self, remaining: float, total: float) -> Image.Image:
        if remaining <= 0:
            return self._alarm(remaining)
        self._zero_at = None
        canvas = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        frac = max(0.0, min(1.0, remaining / max(1.0, total)))
        self._draw_ring(canvas, len(self._ring) * frac)
        self._digits(canvas, int(np.ceil(remaining)))
        return Image.fromarray(canvas, "RGB")

    def _draw_ring(self, canvas, pos: float, flash: float = 0.0):
        """The border with `pos` LEDs' worth of time left (a float: the
        LED at the edge is lit by its fraction), a bright head riding the
        edge, and an optional flash over the whole ring."""
        # The drained part is off, not dim. A quarter-strength accent was
        # the first try and the panel showed it red: at that level its red
        # LEDs light long before the green and blue do, so a dim yellow, or
        # a dim anything, comes out red. The edge LED fades to about a
        # quarter and then goes out for the same reason.
        accent = np.array(self.accent, dtype=np.float32)
        cover = np.clip(pos - self._ring_i, 0.0, 1.0)
        head = np.clip(1.0 - np.abs(self._ring_i + 0.5 - pos) / 3.0, 0.0, 1.0)
        rgb = accent * cover[:, None]
        rgb += accent * 0.5 * (head * cover)[:, None]
        rgb[rgb.max(axis=1) < 72.0] = 0.0
        if flash > 0:
            rgb += (np.array((255, 255, 255), np.float32) - rgb) * flash
        canvas[self._ring_y, self._ring_x] = np.clip(rgb, 0, 255).astype(np.uint8)

    def _digits(self, canvas, seconds: int, bright: bool = False,
                white: float = 0.0):
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
        if white > 0:
            color = tuple(int(c + (255 - c) * white) for c in color)
        draw_text(canvas, text, x, y, color, self.SCALE)

    # -- the alarm ----------------------------------------------------------

    def _alarm(self, remaining: float) -> Image.Image:
        now = time.monotonic()
        if self._zero_at is None:
            # the moment of zero: everything reset, the first shell already up
            self._zero_at = now - max(0.0, -remaining)
            self._last = now
            self._shells = []
            self._sparks = np.zeros((0, 4), dtype=np.float32)
            self._spark_rgb = np.zeros((0, 3), dtype=np.float32)
            self._spark_age = np.zeros(0, dtype=np.float32)
            self._spark_life = np.zeros(0, dtype=np.float32)
            self._next_launch = now + 0.05
            self._flash_at = -1e9
        dt = min(0.1, max(0.0, now - self._last))
        self._last = now
        since_zero = now - self._zero_at

        self._step(now, dt)

        acc = np.zeros((self.size, self.size, 3), dtype=np.float32)
        self._paint_sparks(acc, dt)
        self._paint_shells(acc)
        # the burst's own flash: a soft disc that is gone in a third of a second
        f_age = now - self._flash_at
        if f_age < 0.33:
            k = (1.0 - f_age / 0.33) ** 2
            self._paint_glow(acc, self._flash_xy, 11.0, self._flash_rgb * (1.1 * k))
        canvas = np.clip(acc, 0, 255).astype(np.uint8)

        # the strike: the whole panel white at zero, gone in a quarter second
        strike = max(0.0, 1.0 - since_zero / 0.25) ** 2 if since_zero < 0.25 else 0.0
        ring_flash = max(strike, 0.85 * max(0.0, 1.0 - f_age / 0.5) ** 2)
        self._draw_ring(canvas, float(len(self._ring)) * 0.0, flash=ring_flash)
        if strike > 0:
            canvas[:] = np.clip(canvas.astype(np.float32)
                                + (255 - canvas.astype(np.float32)) * strike,
                                0, 255).astype(np.uint8)
        # a dark plate under the digits keeps 00:00 legible through a burst
        w = text_width("00:00", self.SCALE)
        x0 = (self.size - w) // 2 - 1
        y0 = (self.size - 7 * self.SCALE) // 2 - 1
        plate = canvas[y0:y0 + 7 * self.SCALE + 2, x0:x0 + w + 2].astype(np.float32)
        canvas[y0:y0 + 7 * self.SCALE + 2, x0:x0 + w + 2] = (plate * 0.3).astype(np.uint8)
        self._digits(canvas, 0, bright=True,
                     white=max(strike, 0.6 * max(0.0, 1.0 - f_age / 0.4)))
        return Image.fromarray(canvas, "RGB")

    def _step(self, now: float, dt: float):
        rng = self._rng
        n = self.size
        # shells: launched from the foot, every so often, never two alike
        if now >= self._next_launch:
            x = float(rng.uniform(n * 0.2, n * 0.8))
            vy = -float(rng.uniform(46.0, 56.0))
            # accent and ink take turns, with a white-gold one now and then;
            # every third shell bursts as a ring instead of a ball
            self._launched = getattr(self, "_launched", 0) + 1
            rgb = [self.accent, (255, 236, 200), self.color][self._launched % 3]
            self._shells.append({"x": x, "y": float(n - 1), "vx": float(rng.uniform(-3, 3)),
                                 "vy": vy, "rgb": np.array(rgb, np.float32),
                                 "ring": self._launched % 3 == 1,
                                 "fuse": now + float(rng.uniform(1.0, 1.3))})
            self._next_launch = now + float(rng.uniform(0.45, 0.8))
        keep = []
        for sh in self._shells:
            sh["vy"] += self.SHELL_GRAVITY * dt
            sh["x"] += sh["vx"] * dt
            sh["y"] += sh["vy"] * dt
            if now >= sh["fuse"] or sh["vy"] >= -6.0:
                self._burst(sh["x"], sh["y"], sh["rgb"], now, ring=sh["ring"])
            else:
                keep.append(sh)
        self._shells = keep
        # sparks: gravity, a little drag, age
        if len(self._sparks):
            sp = self._sparks
            sp[:, 3] += self.GRAVITY * dt
            drag = float(np.exp(-1.3 * dt))
            sp[:, 2] *= drag
            sp[:, 3] *= drag
            sp[:, 0] += sp[:, 2] * dt
            sp[:, 1] += sp[:, 3] * dt
            self._spark_age += dt
            alive = (self._spark_age < self._spark_life) & (sp[:, 1] < n + 2)
            self._sparks = sp[alive]
            self._spark_rgb = self._spark_rgb[alive]
            self._spark_age = self._spark_age[alive]
            self._spark_life = self._spark_life[alive]

    def _burst(self, x: float, y: float, rgb: np.ndarray, now: float,
               ring: bool = False):
        rng = self._rng
        count = int(rng.integers(90, 130))
        ang = rng.uniform(0, 2 * np.pi, count)
        top = float(rng.uniform(30.0, 40.0))
        if ring:
            # one speed: the sparks stay a circle as it grows
            speed = np.full(count, top * 0.8, dtype=np.float32) \
                * rng.uniform(0.94, 1.06, count)
        else:
            speed = np.sqrt(rng.uniform(0.0, 1.0, count)) * top
        new = np.zeros((count, 4), dtype=np.float32)
        new[:, 0] = x
        new[:, 1] = y
        new[:, 2] = np.cos(ang) * speed
        new[:, 3] = np.sin(ang) * speed - 5.0
        # sparks start white-hot and settle to the shell's colour as they fall
        tint = np.tile(rgb, (count, 1)).astype(np.float32)
        white = rng.uniform(0.0, 0.7, count)[:, None]
        tint = tint + (255.0 - tint) * white
        self._sparks = np.vstack([self._sparks, new])
        self._spark_rgb = np.vstack([self._spark_rgb, tint])
        self._spark_age = np.concatenate([self._spark_age, np.zeros(count, np.float32)])
        self._spark_life = np.concatenate(
            [self._spark_life, rng.uniform(1.2, 2.2, count).astype(np.float32)])
        self._flash_at = now
        self._flash_rgb = rgb.astype(np.float32)
        self._flash_xy = (x, y)

    def _paint_sparks(self, acc: np.ndarray, dt: float):
        if not len(self._sparks):
            return
        n = self.size
        sp = self._sparks
        life = np.clip(1.0 - self._spark_age / self._spark_life, 0.0, 1.0)
        # bright for most of a life, out quickly at the end, and a twinkle
        glow = np.clip(life * 2.2, 0.0, 1.0) * (0.55 + 0.45 * life) \
            * self._rng.uniform(0.6, 1.0, len(life)).astype(np.float32)
        rgb = self._spark_rgb * glow[:, None]
        # the spark, and a fainter one where it was a frame ago: a short trail
        for back, k in ((0.0, 1.0), (1.0, 0.5), (2.0, 0.2)):
            xs = np.rint(sp[:, 0] - sp[:, 2] * dt * back).astype(np.intp)
            ys = np.rint(sp[:, 1] - sp[:, 3] * dt * back).astype(np.intp)
            ok = (xs >= 0) & (xs < n) & (ys >= 0) & (ys < n)
            np.add.at(acc, (ys[ok], xs[ok]), rgb[ok] * k)

    def _paint_shells(self, acc: np.ndarray):
        n = self.size
        for sh in self._shells:
            x, y = sh["x"], sh["y"]
            for back, k in ((0.0, 1.0), (1.2, 0.45), (2.4, 0.18)):
                yy = int(round(y + back))
                xx = int(round(x))
                if 0 <= xx < n and 0 <= yy < n:
                    acc[yy, xx] += np.array((255, 240, 210), np.float32) * k

    def _paint_glow(self, acc: np.ndarray, xy, radius: float, rgb: np.ndarray):
        n = self.size
        cx, cy = xy
        x0, x1 = max(0, int(cx - radius) - 1), min(n, int(cx + radius) + 2)
        y0, y1 = max(0, int(cy - radius) - 1), min(n, int(cy + radius) + 2)
        if x1 <= x0 or y1 <= y0:
            return
        ys, xs = np.mgrid[y0:y1, x0:x1]
        d = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2) / radius
        k = np.clip(1.0 - d, 0.0, 1.0) ** 2
        acc[y0:y1, x0:x1] += k[:, :, None] * rgb[None, None, :]


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
