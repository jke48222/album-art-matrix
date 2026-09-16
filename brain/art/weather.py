"""The weather face: the temperature, and a scene that IS the weather.

Not an icon. The sky is a real gradient for the hour: blue at noon, warm
at the horizon around sunrise and sunset, deep at night with stars that
twinkle. A clear day is a sun with a halo and slow rays, crossing the top
of the panel on its real arc between sunrise and sunset; a clear night is
the moon with tonight's phase and its seas. Clouds are stacked soft
puffs with lit tops and shaded bases, in two layers that drift at
different speeds, faster in wind. Rain is streaks that lean with the
wind and splash on the ground; drizzle is finer; showers come and go;
snow is flakes of two sizes that wander down and bank up on the hills;
fog is bands of haze drifting through a dimmed scene; thunder is a dark
deck, a forked bolt and a flash that fades. Rolling hills close the
bottom, in silhouette, taking the sky's colour. Every WMO code lands on
one of eleven scenes (weather.SCENES).

At 64: the temperature in 2x digits bottom left, outlined so it reads over
the hills, the scene above and around it. At 192: 4x digits, today's high
and low under them, the next six hours as a row of small scenes along the
bottom, and sunrise and sunset ticks where the sun's arc meets the
horizon. Fahrenheit or Celsius as the wall is told. A small hollow square
bottom right means the weather is over an hour old; no place set says so
in words.

Everything static for the hour (the sky, the hills, the stars) is drawn
once and kept; only the things that move are drawn each frame, so the
face runs at the render loop's rate at 192 without effort.
"""
from __future__ import annotations

import math
import random
import time

import numpy as np

from .pixelfont import draw_text, text_width
from ..weather import scene_for
from ..sun import sun_times

# (ground, sky accent, thing) per scene, day: kept for anyone reading the
# palette, and for the hour row's glyph colours
PALETTE_DAY = {
    "clear": ((6, 10, 26), (20, 40, 90), (255, 200, 80)),
    "mostly_clear": ((6, 10, 26), (20, 40, 90), (255, 200, 80)),
    "partly_cloudy": ((6, 10, 24), (18, 34, 76), (250, 195, 85)),
    "overcast": ((8, 9, 14), (40, 44, 56), (120, 124, 136)),
    "fog": ((10, 10, 12), (48, 48, 52), (150, 150, 150)),
    "drizzle": ((6, 8, 16), (30, 38, 60), (120, 150, 210)),
    "rain": ((5, 7, 16), (26, 34, 58), (110, 150, 230)),
    "freezing": ((6, 8, 18), (30, 40, 66), (170, 200, 255)),
    "snow": ((7, 8, 14), (40, 44, 60), (235, 240, 255)),
    "showers": ((5, 8, 18), (26, 36, 64), (120, 160, 235)),
    "thunder": ((4, 4, 10), (30, 26, 50), (255, 240, 180)),
}
NIGHT_GROUND = (2, 3, 8)
NIGHT_THING = (220, 225, 240)
INK = (235, 228, 210)
DIM = (110, 106, 96)
SUN = (255, 208, 96)
SUN_CORE = (255, 246, 210)
MOON = (222, 226, 238)

FLASH_EVERY_S = (5.0, 13.0)
NEW_MOON_EPOCH = 947182440.0          # 2000-01-06 18:14 UTC
LUNAR_MONTH_S = 29.530588853 * 86400

# how much of the sky each scene lets through, and how grey it goes
SKY_MOOD = {
    "clear": (1.0, 0.0), "mostly_clear": (0.95, 0.05), "partly_cloudy": (0.85, 0.15),
    "overcast": (0.45, 0.7), "fog": (0.4, 0.8), "drizzle": (0.5, 0.6), "rain": (0.38, 0.65),
    "freezing": (0.45, 0.55), "snow": (0.5, 0.6), "showers": (0.5, 0.55), "thunder": (0.22, 0.75),
}


def moon_phase(when: float | None = None) -> float:
    """0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter."""
    when = time.time() if when is None else when
    return ((when - NEW_MOON_EPOCH) / LUNAR_MONTH_S) % 1.0


def _lerp(a, b, k: float):
    k = 0.0 if k < 0 else 1.0 if k > 1 else k
    return tuple(a[i] + (b[i] - a[i]) * k for i in range(3))


def _disc(f: np.ndarray, cx: float, cy: float, r: float, colour, soft: float = 0.6, alpha: float = 1.0):
    size = f.shape[0]
    y0, y1 = max(0, int(cy - r - soft - 1)), min(size, int(cy + r + soft + 2))
    x0, x1 = max(0, int(cx - r - soft - 1)), min(size, int(cx + r + soft + 2))
    if y1 <= y0 or x1 <= x0:
        return
    yy, xx = np.mgrid[y0:y1, x0:x1]
    d = np.sqrt((xx + 0.5 - cx) ** 2 + (yy + 0.5 - cy) ** 2)
    a = np.clip((r + soft - d) / max(soft, 1e-6), 0.0, 1.0)[..., None] * alpha
    f[y0:y1, x0:x1] = (f[y0:y1, x0:x1] * (1 - a) + np.array(colour, dtype=np.float32) * a)


def _glow(f: np.ndarray, cx: float, cy: float, radius: float, colour, strength: float):
    """Light added around a point, falling off to nothing at `radius`."""
    size = f.shape[0]
    y0, y1 = max(0, int(cy - radius)), min(size, int(cy + radius + 1))
    x0, x1 = max(0, int(cx - radius)), min(size, int(cx + radius + 1))
    if y1 <= y0 or x1 <= x0:
        return
    yy, xx = np.mgrid[y0:y1, x0:x1]
    d = np.sqrt((xx + 0.5 - cx) ** 2 + (yy + 0.5 - cy) ** 2) / max(1.0, radius)
    a = np.clip(1 - d, 0, 1) ** 2 * strength
    f[y0:y1, x0:x1] = np.minimum(255, f[y0:y1, x0:x1] + np.array(colour, np.float32) * a[..., None])


def _moon(f: np.ndarray, cx: float, cy: float, r: float, phase: float, colour):
    """A disc lit on the side the phase says, the terminator an ellipse,
    and the seas as darker patches on the lit part."""
    size = f.shape[0]
    y0, y1 = max(0, int(cy - r - 1)), min(size, int(cy + r + 2))
    x0, x1 = max(0, int(cx - r - 1)), min(size, int(cx + r + 2))
    yy, xx = np.mgrid[y0:y1, x0:x1]
    dx = (xx + 0.5 - cx) / r
    dy = (yy + 0.5 - cy) / r
    inside = dx * dx + dy * dy <= 1.0
    half = np.sqrt(np.clip(1.0 - dy * dy, 0.0, 1.0))
    c = math.cos(2 * math.pi * phase)
    if phase < 0.5:
        lit = dx >= half * c
    else:
        lit = dx <= -half * c
    col = np.array(colour, dtype=np.float32)
    # the seas: three soft patches, a shade darker
    seas = np.zeros_like(dx)
    for sx, sy, sr in ((-0.35, -0.25, 0.42), (0.2, 0.15, 0.3), (0.35, -0.4, 0.22)):
        seas = np.maximum(seas, np.clip(1 - np.sqrt((dx - sx) ** 2 + (dy - sy) ** 2) / sr, 0, 1))
    face = col * (1 - 0.22 * seas[..., None])
    dark = col * 0.10
    out = np.where((inside & lit)[..., None], face, np.where(inside[..., None], dark, f[y0:y1, x0:x1]))
    f[y0:y1, x0:x1] = out


def _degree(f: np.ndarray, x: int, y: int, scale: int, colour):
    """A small hollow ring: the degree sign the 5x7 font has no glyph for."""
    s = max(1, scale)
    n = 2 * s + 1
    f[y:y + s, x:x + n] = colour
    f[y + n - s:y + n, x:x + n] = colour
    f[y:y + n, x:x + s] = colour
    f[y:y + n, x + n - s:x + n] = colour


def _outlined(f: np.ndarray, txt: str, x: int, y: int, colour, scale: int, back=(0, 0, 0)):
    """Text with a one pixel dark edge, so it reads over anything."""
    for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        draw_text(f, txt, x + dx, y + dy, back, scale)
    draw_text(f, txt, x, y, colour, scale)


class WeatherFace:
    def __init__(self, size: int, seed: int = 7):
        self.size = size
        self.big = size > 96
        self.scale = 4 if self.big else 2
        self.s = 3 if self.big else 1
        self._rng = random.Random(seed)
        self._drops = None
        self._flakes = None
        self._clouds = None
        self._settled = 0.0
        self._snow_since = None
        self._next_flash = None
        self._flash_until = -1.0
        self._bolt = None
        self._last_scene = None
        self._splashes: list[list[float]] = []
        # static layers, remade when the hour or the scene changes
        self._sky_key = None
        self._sky = None
        self._hills = self._make_hills()
        self._stars = self._make_stars()

    # ---- helpers ------------------------------------------------------------------------------
    def _temp(self, c, units: str):
        if c is None:
            return None
        return round(c * 9 / 5 + 32) if units == "f" else round(c)

    def _day_fraction(self, t_now: float, lat, lon):
        """Where the sun is in its day: (k, rise, set) with k 0..1 between
        sunrise and sunset, under 0 before, over 1 after; None unknown."""
        if lat is None or lon is None:
            return None
        try:
            rise, set_ = sun_times(lat, lon, t_now)
        except Exception:
            return None
        if not isinstance(rise, (int, float)) or not isinstance(set_, (int, float)) or set_ <= rise:
            return None
        return (t_now - rise) / (set_ - rise), rise, set_

    def _horizon(self) -> int:
        return int(self.size * 0.80)

    def _arc(self, k: float) -> tuple[float, float]:
        """The sun's place for a fraction k of its day."""
        size = self.size
        margin = size * 0.10
        x = margin + k * (size - 2 * margin)
        top = size * 0.10
        y = top + (self._horizon() - top) * (1 - math.sin(math.pi * min(1.0, max(0.0, k))))
        return x, y

    def _sun_pos(self, t_now: float, lat, lon):
        """(x, y) of the sun on its arc across the top, or None at night."""
        d = self._day_fraction(t_now, lat, lon)
        if d is None:
            return None
        k = d[0]
        if k < 0 or k > 1:
            return None
        return self._arc(k)

    def _make_hills(self) -> np.ndarray:
        """The ground line, a row of heights: rolling, never the same twice
        across the panel."""
        size = self.size
        rng = random.Random(11)
        xs = np.arange(size, dtype=np.float32) / size
        h = np.zeros(size, dtype=np.float32)
        for freq, amp in ((1.3, 0.05), (2.9, 0.03), (5.7, 0.015), (11.0, 0.006)):
            h += amp * np.sin(2 * math.pi * freq * xs + rng.uniform(0, 6.3))
        return self._horizon() + (h - h.min()) * size * 0.9 - size * 0.03

    def _make_stars(self):
        rng = random.Random(23)
        n = 14 if not self.big else 60
        return [(rng.randrange(self.size), rng.randrange(int(self._horizon() * 0.9)), rng.uniform(0, 6.3),
                 rng.uniform(0.5, 1.0)) for _ in range(n)]

    def _sky_colours(self, k, scene: str, is_day: bool):
        """(top, horizon) for this hour: noon blue, warm at the edges of the
        day, night deep; greyed by cloud."""
        let, grey = SKY_MOOD.get(scene, SKY_MOOD["overcast"])
        night_top, night_hor = (2, 3, 10), (8, 10, 30)
        if k is None:
            if is_day:
                top, hor = (16, 40, 96), (46, 96, 156)
            else:
                top, hor = night_top, night_hor
        else:
            alt = math.sin(math.pi * min(1.0, max(0.0, k)))       # 0 at the edges of the day, 1 at noon
            if k < -0.06 or k > 1.06:
                top, hor = night_top, night_hor
            else:
                edge = 1.0 - min(1.0, abs(k - 0.5) * 2)          # 1 at noon, 0 at the horizon
                day_top, day_hor = (14, 38, 96), (50, 100, 160)
                dusk_top, dusk_hor = (30, 18, 52), (200, 96, 40)
                w = min(1.0, edge * 3.0)                          # dusk within the last sixth of the day
                top = _lerp(dusk_top, day_top, w)
                hor = _lerp(dusk_hor, day_hor, w)
                if k < 0 or k > 1:                                # the glow after the sun has gone
                    over = min(1.0, (abs(k - 0.5) - 0.5) / 0.06)
                    top = _lerp(top, night_top, over)
                    hor = _lerp(hor, night_hor, over)
                if not is_day and 0 <= k <= 1:
                    top, hor = _lerp(top, night_top, 0.5), _lerp(hor, night_hor, 0.5)
                top = tuple(c * (0.55 + 0.45 * alt) for c in top) if 0 <= k <= 1 else top
        top = _lerp(top, (sum(top) / 3,) * 3, grey)
        hor = _lerp(hor, (sum(hor) / 3,) * 3, grey)
        return tuple(c * let + (1 - let) * c * 0.5 for c in top), tuple(c * let + (1 - let) * c * 0.5 for c in hor)

    def _make_sky(self, key, k, scene: str, is_day: bool) -> np.ndarray:
        size = self.size
        top, hor = self._sky_colours(k, scene, is_day)
        hz = self._horizon()
        rows = np.linspace(0.0, 1.0, hz, dtype=np.float32) ** 1.4
        sky = np.empty((size, size, 3), dtype=np.float32)
        band = np.array(top, np.float32)[None, :] * (1 - rows[:, None]) + np.array(hor, np.float32)[None, :] * rows[:, None]
        sky[:hz] = band[:, None, :]
        # the ground: the hills in silhouette, the sky's colour gone dark
        ground = np.array(_lerp(hor, (0, 0, 0), 0.82), np.float32)
        sky[hz:] = ground
        ys = np.arange(size)[:, None]
        mask = ys >= self._hills[None, :]
        sky[mask] = ground * 0.9
        # a lighter line where the hills meet the sky
        for x in range(size):
            y = int(self._hills[x])
            if 0 <= y < size:
                sky[y, x] = np.array(_lerp(hor, (0, 0, 0), 0.6), np.float32)
        return sky

    def _ensure(self, scene: str, intensity: float, wind: float):
        size = self.size
        rng = self._rng
        if scene != self._last_scene:
            self._last_scene = scene
            self._drops = self._flakes = self._clouds = None
            self._splashes = []
        wet = scene in ("drizzle", "rain", "showers", "freezing", "thunder")
        if wet and self._drops is None:
            n = int((10 if not self.big else 60) * (0.4 + intensity) * (0.6 if scene == "drizzle" else 1.0))
            self._drops = [[rng.uniform(0, size), rng.uniform(0, size), rng.uniform(0.6, 1.4), rng.random() < 0.4]
                           for _ in range(n)]
        if scene == "snow" and self._flakes is None:
            n = int((14 if not self.big else 80) * (0.4 + intensity))
            self._flakes = [[rng.uniform(0, size), rng.uniform(0, size), rng.uniform(0, 6.3), rng.random() < 0.35]
                            for _ in range(n)]
            self._snow_since = time.monotonic()
        cloudy = scene in ("partly_cloudy", "overcast", "mostly_clear", "drizzle", "rain", "showers",
                           "thunder", "freezing", "snow")
        if cloudy and self._clouds is None:
            deck = scene in ("overcast", "drizzle", "rain", "showers", "thunder", "freezing", "snow")
            n = {"mostly_clear": 1, "partly_cloudy": 3}.get(scene, 5 if not self.big else 7)
            self._clouds = []
            for i in range(n):
                far = (i % 2 == 1) and not deck
                w = rng.uniform(size * 0.16, size * 0.30) * (0.7 if far else 1.0) * (1.25 if deck else 1.0)
                y = rng.uniform(size * 0.06, size * 0.26) if not deck else rng.uniform(size * 0.02, size * 0.16)
                self._clouds.append([rng.uniform(0, size), y, w, far, rng.uniform(0, 6.3)])

    # ---- the pieces ------------------------------------------------------------------------------
    def _draw_cloud(self, f, cx, y, w, colour_top, colour_base, phase):
        """A cloud: puffs in a row, the tallest in the middle, a lit crown
        and a flat shaded base."""
        n = 5
        for i in range(n):
            u = (i - (n - 1) / 2) / ((n - 1) / 2)                   # -1..1
            r = w * (0.34 - 0.13 * abs(u)) * (1 + 0.06 * math.sin(phase + i))
            x = cx + u * w * 0.42
            yy = y + w * 0.08 * abs(u)
            _disc(f, x, yy, r, colour_top, soft=1.2 if not self.big else 2.0)
        # the base: a flat shaded band along the bottom of the puffs
        r0 = w * 0.34
        _disc(f, cx, y + r0 * 0.55, r0 * 1.15, colour_base, soft=1.0 if not self.big else 2.0, alpha=0.75)
        _disc(f, cx - w * 0.3, y + r0 * 0.5, r0 * 0.8, colour_base, soft=1.0, alpha=0.6)
        _disc(f, cx + w * 0.3, y + r0 * 0.5, r0 * 0.8, colour_base, soft=1.0, alpha=0.6)

    def _draw_sun(self, f, x, y, t, r, through: float = 1.0):
        s = self.s
        _glow(f, x, y, r * 4.0, SUN, 0.35 * through)
        # slow rays, faint, turning
        if through > 0.6:
            for i in range(8):
                a = t * 0.15 + i * math.pi / 4
                for k in range(int(r * 1.5), int(r * 3.2)):
                    px, py = x + math.cos(a) * k, y + math.sin(a) * k
                    xi, yi = int(px), int(py)
                    if 0 <= xi < self.size and 0 <= yi < self.size:
                        fade = (1 - (k - r * 1.5) / (r * 1.7)) * 0.35 * through
                        f[yi, xi] = np.minimum(255, f[yi, xi] + np.array(SUN, np.float32) * fade)
        _disc(f, x, y, r, tuple(c * through + (1 - through) * 120 for c in SUN), soft=0.9 * s)
        _disc(f, x, y, r * 0.55, SUN_CORE, soft=0.8 * s, alpha=through)

    def _draw_bolt(self, f, bolt, brightness: float):
        col = np.array((255, 250, 210), np.float32) * brightness
        for (x0, y0, x1, y1) in bolt:
            n = max(1, int(max(abs(x1 - x0), abs(y1 - y0))))
            for k in range(n + 1):
                xi = int(round(x0 + (x1 - x0) * k / n))
                yi = int(round(y0 + (y1 - y0) * k / n))
                if 0 <= xi < self.size and 0 <= yi < self.size:
                    f[yi, xi] = np.maximum(f[yi, xi], col)
                    if self.big:
                        for dx in (-1, 1):
                            if 0 <= xi + dx < self.size:
                                f[yi, xi + dx] = np.maximum(f[yi, xi + dx], col * 0.5)

    def _new_bolt(self):
        rng = self._rng
        size = self.size
        x = rng.uniform(size * 0.2, size * 0.8)
        y = size * 0.14
        segs = []
        while y < self._horizon():
            nx = x + rng.uniform(-size * 0.08, size * 0.08)
            ny = y + rng.uniform(size * 0.06, size * 0.12)
            segs.append((x, y, nx, ny))
            if rng.random() < 0.3:
                bx, by = nx + rng.uniform(-size * 0.15, size * 0.15), ny + rng.uniform(size * 0.08, size * 0.16)
                segs.append((nx, ny, bx, by))
            x, y = nx, ny
        return segs

    # ---- the frame --------------------------------------------------------------------------------
    def frame_at(self, t: float, data: dict | None, units: str = "f", lat=None, lon=None,
                 stale: bool = False, place: str = "", now: float | None = None) -> np.ndarray:
        size = self.size
        s = self.s
        now = time.time() if now is None else now
        if data is None:
            f = np.zeros((size, size, 3), dtype=np.float32)
            f[:] = (4, 4, 6)
            msg = "no place" if not place else "no weather"
            msg2 = "set" if not place else "yet"
            sc = 1 if not self.big else 2
            draw_text(f, msg, (size - text_width(msg, sc)) // 2, size // 2 - 8 * sc, DIM, sc)
            draw_text(f, msg2, (size - text_width(msg2, sc)) // 2, size // 2 + 2 * sc, DIM, sc)
            return f.astype(np.uint8)
        scene, intensity = scene_for(data.get("code"))
        is_day = bool(data.get("is_day", True))
        wind = float(data.get("wind_kmh") or 0.0)
        day = self._day_fraction(now, lat, lon)
        k = day[0] if day else None
        # the sky and the hills, kept for the hour
        key = (scene, is_day, None if k is None else round(k, 2))
        if key != self._sky_key:
            self._sky_key = key
            self._sky = self._make_sky(key, k, scene, is_day)
        f = self._sky.copy()
        self._ensure(scene, intensity, wind)
        wind_px = min(3.0, wind / 20.0)
        hz = self._horizon()
        night = not is_day

        # stars, above the hills, twinkling; fewer when it is cloudy
        if night and scene in ("clear", "mostly_clear", "partly_cloudy"):
            for (sx, sy, ph, br) in self._stars:
                tw = 0.55 + 0.45 * math.sin(t * 1.3 + ph)
                v = 60 + 130 * br * tw
                f[sy, sx] = np.maximum(f[sy, sx], (v * 0.85, v * 0.88, v))

        # the sun or the moon
        if scene in ("clear", "mostly_clear", "partly_cloudy", "fog", "overcast"):
            r = size * (0.075 if not self.big else 0.06)
            through = {"fog": 0.35, "overcast": 0.0}.get(scene, 1.0)
            if is_day:
                pos = self._sun_pos(now, lat, lon) if k is not None else (size * 0.5, size * 0.22)
                if pos is not None and through > 0:
                    self._draw_sun(f, pos[0], pos[1], t, r, through)
            elif scene in ("clear", "mostly_clear", "partly_cloudy"):
                mx, my = size * 0.72, size * 0.22
                _glow(f, mx, my, r * 3.5, MOON, 0.22)
                _moon(f, mx, my, r, moon_phase(now), MOON)

        # clouds: two layers, the far ones smaller, slower and dimmer
        if self._clouds is not None:
            let, grey = SKY_MOOD.get(scene, SKY_MOOD["overcast"])
            top_col = (208, 212, 224) if is_day else (96, 100, 118)
            base_col = (120, 126, 146) if is_day else (44, 48, 62)
            if scene in ("overcast", "drizzle", "rain", "showers", "freezing", "snow", "thunder"):
                top_col = (150, 154, 168) if is_day else (60, 62, 74)
                base_col = (74, 78, 92) if is_day else (26, 28, 36)
            if scene == "thunder":
                top_col, base_col = ((92, 90, 104) if is_day else (46, 44, 56)), ((38, 36, 48) if is_day else (16, 16, 22))
            for c in self._clouds:
                far = c[3]
                speed = (0.6 + wind_px) * (1.0 if not self.big else 3.0) * (0.45 if far else 1.0)
                cx = (c[0] + t * speed) % (size + 2 * c[2]) - c[2]
                dim = 0.72 if far else 1.0
                self._draw_cloud(f, cx, c[1], c[2], tuple(v * dim for v in top_col), tuple(v * dim for v in base_col), c[4])

        # rain: streaks that lean with the wind, and splashes where they land
        if self._drops is not None and scene != "snow":
            gust = 1.0 if scene != "showers" else 0.35 + 0.65 * max(0.0, math.sin(t * 0.25))
            speed = (30 if not self.big else 95) * (0.7 + 0.6 * intensity)
            length = (2 if not self.big else 6) if scene != "drizzle" else (1 if not self.big else 3)
            col = np.array((150, 180, 240) if scene != "freezing" else (200, 225, 255), np.float32)
            if night:
                col = col * 0.75
            for d in self._drops:
                if gust < 1.0 and d[3] and gust < 0.7:
                    continue
                y = (d[1] + t * speed * d[2]) % (hz + length)
                x = (d[0] + (y * wind_px * 0.35)) % size
                depth = 0.55 if d[3] else 1.0
                for i in range(length):
                    yy = int(y) - i
                    xx = int(x - i * wind_px * 0.35)
                    if 0 <= yy < hz and 0 <= xx < size:
                        a = (1.0 - i / (length + 1)) * depth
                        f[yy, xx] = f[yy, xx] * (1 - a) + col * a
                if y >= hz - 1 and not d[3] and self._rng.random() < 0.3:
                    self._splashes.append([x, t])
            self._splashes = [sp for sp in self._splashes if t - sp[1] < 0.25]
            for sp in self._splashes[-40:]:
                age = (t - sp[1]) / 0.25
                for dx in (-1, 1):
                    xi = int(sp[0] + dx * (1 + age * 2 * s))
                    yi = hz - 1 - int(age * 2 * s)
                    if 0 <= xi < size and 0 <= yi < size:
                        f[yi, xi] = np.maximum(f[yi, xi], col * (1 - age) * 0.7)

        # snow: two sizes of flake wander down; a bank grows on the hills
        if self._flakes is not None:
            speed = (7 if not self.big else 22) * (0.7 + 0.5 * intensity)
            col = np.array((240, 244, 255), np.float32) * (0.9 if is_day else 0.75)
            for fl in self._flakes:
                y = (fl[1] + t * speed * (1.3 if fl[3] else 1.0)) % size
                x = (fl[0] + math.sin(t * 0.8 + fl[2]) * (2.0 * s) + y * wind_px * 0.2) % size
                xi, yi = int(x), int(y)
                if yi < self._hills[xi]:
                    if fl[3] and self.big:
                        f[yi:yi + 2, xi:xi + 2] = col
                    else:
                        f[yi, xi] = col
            since = time.monotonic() - (self._snow_since or time.monotonic())
            depth = min(size * 0.08, 1 + since / 60.0 * s)
            bank = np.array((235, 238, 250), np.float32) * (0.85 if is_day else 0.6)
            for x in range(size):
                y0 = int(self._hills[x] - depth * (0.8 + 0.2 * math.sin(x * 0.4)))
                y1 = int(self._hills[x]) + 1
                f[max(0, y0):min(size, y1), x] = bank

        # fog: the scene dimmed, and soft banks of haze drifting through it
        if scene == "fog":
            f *= 0.6
            ys = np.arange(size, dtype=np.float32)[:, None]
            xs = np.arange(size, dtype=np.float32)[None, :]
            haze = np.zeros((size, size), dtype=np.float32)
            for i, (yy, hh, sp) in enumerate(((0.30, 0.09, 0.8), (0.47, 0.12, -0.5), (0.64, 0.09, 0.35))):
                cy = size * yy + size * 0.02 * math.sin(t * 0.3 + i)
                band = np.exp(-((ys - cy) / (size * hh)) ** 2)
                wave = 0.55 + 0.45 * np.sin(xs / size * 6.28 * 1.5 + t * sp + i)
                haze = np.maximum(haze, band * wave)
            f = f + (haze * 58)[..., None] * np.array((1.0, 1.0, 1.05), np.float32)

        # thunder: now and then a forked bolt, a flash that fades
        if scene == "thunder":
            if self._next_flash is None:
                self._next_flash = t + self._rng.uniform(1.0, 4.0)
            if t >= self._next_flash:
                self._bolt = self._new_bolt()
                self._flash_until = t + 0.35
                self._next_flash = t + self._rng.uniform(*FLASH_EVERY_S)
            if t < self._flash_until:
                left = (self._flash_until - t) / 0.35
                if self._bolt is not None and left > 0.45:
                    self._draw_bolt(f, self._bolt, 1.0)
                # the flash: the whole sky lit for an instant, gone in a third of a second
                f[:hz] = np.minimum(255, f[:hz] + 95 * left ** 3)
                f[hz:] = np.minimum(255, f[hz:] + 40 * left ** 3)

        # the temperature, outlined so it reads over the hills
        temp = self._temp(data.get("temp"), units)
        sc = self.scale
        if temp is not None:
            txt = str(temp)
            w = text_width(txt, sc)
            x = 3 if not self.big else 9
            y = size - 7 * sc - (3 if not self.big else 12)
            _outlined(f, txt, x, y, INK, sc)
            _degree(f, x + w + 2, y, max(1, sc // 2), INK)
        if self.big:
            hi, lo = self._temp(data.get("high"), units), self._temp(data.get("low"), units)
            if hi is not None and lo is not None:
                _outlined(f, f"{hi}  {lo}", 9, size - 7 * 2 - 7 * sc - 12 - 8, (160, 156, 146), 2)
            # the next six hours: small scenes along the bottom right
            hours = data.get("hours") or []
            cell = 22
            x0 = size - 8 - cell * min(6, len(hours))
            for i, h in enumerate(hours[:6]):
                hs, hint = scene_for(h.get("code"))
                cx = x0 + i * cell + cell // 2
                cy = size - 16
                hday = h.get("is_day", True)
                if hs in ("clear", "mostly_clear"):
                    _glow(f, cx, cy - 8, 7, SUN if hday else MOON, 0.3)
                    _disc(f, cx, cy - 8, 3.2, SUN if hday else MOON, soft=0.8)
                elif hs in ("rain", "showers", "drizzle", "freezing", "thunder"):
                    _disc(f, cx, cy - 12, 4, (120, 126, 146), soft=1.0)
                    for kk in range(3):
                        f[cy - 8 + kk * 2:cy - 6 + kk * 2, cx - 3 + kk * 3] = (150, 180, 240)
                elif hs == "snow":
                    _disc(f, cx, cy - 12, 4, (140, 146, 166), soft=1.0)
                    for kk in range(3):
                        f[cy - 7 + (kk % 2) * 3, cx - 3 + kk * 3] = (240, 244, 255)
                else:
                    _disc(f, cx, cy - 8, 4.5, (128, 132, 148), soft=1.2)
                ht = self._temp(h.get("temp"), units)
                if ht is not None:
                    s_ = str(ht)
                    _outlined(f, s_, cx - text_width(s_, 1) // 2, cy - 2, (170, 166, 156), 1)
            # sunrise and sunset ticks where the arc meets the hills
            if k is not None:
                for kk in (0.0, 1.0):
                    x, _ = self._arc(kk)
                    xi = int(x)
                    yi = int(self._hills[min(size - 1, max(0, xi))])
                    f[yi - 4:yi, xi] = (220, 170, 90)

        if stale:
            s_ = 3 if not self.big else 7
            x0, y0 = size - s_ - 2, size - s_ - 2
            f[y0:y0 + s_, x0:x0 + s_] = DIM
            f[y0 + 1:y0 + s_ - 1, x0 + 1:x0 + s_ - 1] = (0, 0, 0)
        return np.clip(f, 0, 255).astype(np.uint8)
