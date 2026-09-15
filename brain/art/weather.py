"""The weather face: the temperature, and a scene that IS the weather.

Not an icon. A clear day is a sun that crosses the top of the panel between
sunrise and sunset, where the real sun is; a clear night is the moon with
tonight's phase. Clouds drift, faster in wind; rain falls with the
forecast's density and leans with the wind; snow falls slower and settles
on the bottom edge; fog dims the whole face and breathes; thunder flashes.
Every WMO code lands on one of eleven scenes (weather.SCENES).

At 64: the temperature in 2x digits bottom left, the scene above and
around it. At 192: 4x digits, today's high and low under them, the next six
hours as a row of small scenes along the bottom, and sunrise and sunset
ticks on the sun's arc. Fahrenheit or Celsius as the wall is told. A small
hollow square bottom right means the weather is over an hour old; no place
set says so in words.

Colours are a restrained palette per scene, dark grounds and a few bright
things, which is what an LED panel does best and what the room wants at
night. All drawing is plain sRGB numpy; the pipeline does the rest.
"""
from __future__ import annotations

import math
import random
import time

import numpy as np

from .pixelfont import draw_text, text_width
from ..weather import scene_for
from ..sun import sun_times

# (ground, sky accent, thing) per scene, day
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

FLASH_EVERY_S = (5.0, 13.0)
NEW_MOON_EPOCH = 947182440.0          # 2000-01-06 18:14 UTC
LUNAR_MONTH_S = 29.530588853 * 86400


def moon_phase(when: float | None = None) -> float:
    """0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter."""
    when = time.time() if when is None else when
    return ((when - NEW_MOON_EPOCH) / LUNAR_MONTH_S) % 1.0


def _disc(f: np.ndarray, cx: float, cy: float, r: float, colour, soft: float = 0.6):
    size = f.shape[0]
    y0, y1 = max(0, int(cy - r - 1)), min(size, int(cy + r + 2))
    x0, x1 = max(0, int(cx - r - 1)), min(size, int(cx + r + 2))
    if y1 <= y0 or x1 <= x0:
        return
    yy, xx = np.mgrid[y0:y1, x0:x1]
    d = np.sqrt((xx + 0.5 - cx) ** 2 + (yy + 0.5 - cy) ** 2)
    a = np.clip((r + soft - d) / max(soft, 1e-6), 0.0, 1.0)[..., None]
    f[y0:y1, x0:x1] = (f[y0:y1, x0:x1] * (1 - a) + np.array(colour, dtype=np.float32) * a)


def _moon(f: np.ndarray, cx: float, cy: float, r: float, phase: float, colour):
    """A disc lit on the side the phase says, the terminator an ellipse."""
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
    dark = np.array(colour, dtype=np.float32) * 0.12
    col = np.where((inside & lit)[..., None], np.array(colour, dtype=np.float32),
                   np.where(inside[..., None], dark, f[y0:y1, x0:x1]))
    f[y0:y1, x0:x1] = col


def _degree(f: np.ndarray, x: int, y: int, scale: int, colour):
    """A small hollow ring: the degree sign the 5x7 font has no glyph for."""
    s = max(1, scale)
    n = 2 * s + 1
    f[y:y + s, x:x + n] = colour
    f[y + n - s:y + n, x:x + n] = colour
    f[y:y + n, x:x + s] = colour
    f[y:y + n, x + n - s:x + n] = colour


class WeatherFace:
    def __init__(self, size: int, seed: int = 7):
        self.size = size
        self.big = size > 96
        self.scale = 4 if self.big else 2
        self._rng = random.Random(seed)
        self._drops = None
        self._flakes = None
        self._clouds = None
        self._settled = 0.0
        self._snow_since = None
        self._next_flash = None
        self._flash_until = -1.0
        self._last_scene = None

    # ---- helpers ------------------------------------------------------------------------------
    def _temp(self, c, units: str):
        if c is None:
            return None
        return round(c * 9 / 5 + 32) if units == "f" else round(c)

    def _sun_pos(self, t_now: float, lat, lon):
        """(x, y) of the sun on its arc across the top, or None at night."""
        size = self.size
        try:
            rise, set_ = sun_times(lat, lon, t_now)
        except Exception:
            return None
        if not isinstance(rise, (int, float)) or set_ <= rise:
            return None
        k = (t_now - rise) / (set_ - rise)
        if k < 0 or k > 1:
            return None
        margin = size * 0.12
        x = margin + k * (size - 2 * margin)
        top = size * (0.16 if not self.big else 0.14)
        y = top + (size * 0.20) * (1 - math.sin(math.pi * k))
        return x, y

    def _ensure(self, scene: str, intensity: float, wind: float):
        size = self.size
        rng = self._rng
        if scene != self._last_scene:
            self._last_scene = scene
            self._drops = self._flakes = self._clouds = None
        if scene in ("drizzle", "rain", "showers", "freezing", "thunder") and self._drops is None:
            n = int((8 if not self.big else 40) * (0.4 + intensity))
            self._drops = [[rng.uniform(0, size), rng.uniform(0, size), rng.uniform(0.7, 1.3)]
                           for _ in range(n)]
        if scene == "snow" and self._flakes is None:
            n = int((10 if not self.big else 60) * (0.4 + intensity))
            self._flakes = [[rng.uniform(0, size), rng.uniform(0, size), rng.uniform(0, 6.3)]
                            for _ in range(n)]
            self._snow_since = time.monotonic()
        if scene in ("partly_cloudy", "overcast", "mostly_clear", "drizzle", "rain", "showers",
                     "thunder", "freezing", "snow") and self._clouds is None:
            n = {"mostly_clear": 1, "partly_cloudy": 2}.get(scene, 3 if not self.big else 4)
            self._clouds = [[rng.uniform(0, size), rng.uniform(size * 0.08, size * 0.32),
                             rng.uniform(size * 0.10, size * 0.18)] for _ in range(n)]

    # ---- the frame --------------------------------------------------------------------------------
    def frame_at(self, t: float, data: dict | None, units: str = "f", lat=None, lon=None,
                 stale: bool = False, place: str = "", now: float | None = None) -> np.ndarray:
        size = self.size
        f = np.zeros((size, size, 3), dtype=np.float32)
        now = time.time() if now is None else now
        if data is None:
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
        ground, sky, thing = PALETTE_DAY.get(scene, PALETTE_DAY["overcast"])
        if not is_day:
            ground = NIGHT_GROUND
        f[:] = ground
        self._ensure(scene, intensity, wind)
        wind_px = min(3.0, wind / 20.0)            # a lean, and a drift, in pixels a second-ish

        # the sky: a faint band across the top for daytime scenes
        if is_day and scene in ("clear", "mostly_clear", "partly_cloudy"):
            band = int(size * 0.45)
            fade = np.linspace(1.0, 0.0, band)[:, None, None]
            f[:band] = f[:band] * (1 - fade * 0.6) + np.array(sky, dtype=np.float32) * fade * 0.6

        # the sun or the moon
        if scene in ("clear", "mostly_clear", "partly_cloudy"):
            r = size * (0.075 if not self.big else 0.06)
            if is_day and lat is not None and lon is not None:
                pos = self._sun_pos(now, lat, lon)
                if pos is not None:
                    _disc(f, pos[0], pos[1], r, thing)
            elif is_day:
                _disc(f, size * 0.5, size * 0.22, r, thing)
            else:
                _moon(f, size * 0.72, size * 0.24, r, moon_phase(now), NIGHT_THING)
                # a few stars
                rng = random.Random(int(now // 3600))
                for _ in range(6 if not self.big else 24):
                    sx, sy = rng.randrange(size), rng.randrange(int(size * 0.5))
                    f[sy, sx] = np.maximum(f[sy, sx], (90, 92, 110))

        # clouds drift right; wind hurries them
        if self._clouds is not None:
            speed = (0.8 + wind_px) * (1.0 if not self.big else 3.0)
            col = np.array(thing if scene in ("overcast", "fog") else (150, 156, 176), dtype=np.float32)
            if not is_day:
                col = col * 0.55
            for c in self._clouds:
                cx = (c[0] + t * speed) % (size + 2 * c[2]) - c[2]
                for k, (ox, oy, rr) in enumerate(((0, 0, 1.0), (-0.8, 0.25, 0.75), (0.8, 0.3, 0.7))):
                    _disc(f, cx + ox * c[2], c[1] + oy * c[2], c[2] * rr,
                          col * (0.9 if k == 0 else 0.8), soft=1.2)

        # rain: drops fall, lean with the wind
        if self._drops is not None and scene != "snow":
            speed = (28 if not self.big else 90) * (0.7 + 0.6 * intensity)
            length = 2 if not self.big else 5
            col = np.array(thing, dtype=np.float32)
            for d in self._drops:
                y = (d[1] + t * speed * d[2]) % (size + length)
                x = (d[0] + (y * wind_px * 0.35)) % size
                for i in range(length):
                    yy = int(y) - i
                    if 0 <= yy < size:
                        f[yy, int(x)] = col * (1.0 - i / (length + 1))

        # snow: flakes fall slowly and wander, and settle on the bottom edge
        if self._flakes is not None:
            speed = (7 if not self.big else 22) * (0.7 + 0.5 * intensity)
            col = np.array(thing, dtype=np.float32)
            for fl in self._flakes:
                y = (fl[1] + t * speed) % size
                x = (fl[0] + math.sin(t * 0.8 + fl[2]) * 2.0 + y * wind_px * 0.2) % size
                f[int(y), int(x)] = col
            since = time.monotonic() - (self._snow_since or time.monotonic())
            depth = min(3 if not self.big else 9, int(since / 120.0) + 1)
            f[size - depth:] = np.maximum(f[size - depth:], col * 0.7)

        # fog: the whole face dimmed, a haze that breathes across the middle
        if scene == "fog":
            f *= 0.55
            band = int(size * 0.3)
            y0 = int(size * 0.35)
            haze = 40 + 25 * math.sin(t * 0.4)
            f[y0:y0 + band] = np.maximum(f[y0:y0 + band], haze)

        # thunder: a flash now and then
        if scene == "thunder":
            if self._next_flash is None or t > self._next_flash + 0.3:
                if self._next_flash is not None and t > self._next_flash:
                    self._flash_until = t + 0.12
                self._next_flash = t + self._rng.uniform(*FLASH_EVERY_S)
            if t < self._flash_until:
                f = np.minimum(255, f + 150)

        # the temperature
        temp = self._temp(data.get("temp"), units)
        sc = self.scale
        if temp is not None:
            txt = str(temp)
            w = text_width(txt, sc)
            x = 2 if not self.big else 8
            y = size - 7 * sc - (3 if not self.big else 10)
            draw_text(f, txt, x, y, INK, sc)
            _degree(f, x + w + 1, y, max(1, sc // 2), INK)
        if self.big:
            hi, lo = self._temp(data.get("high"), units), self._temp(data.get("low"), units)
            if hi is not None and lo is not None:
                line = f"{hi} {lo}"
                draw_text(f, line, 8, size - 7 * 2 - 1 - 7 * sc - 10 - 6, DIM, 2)
            # the next six hours: small scenes along the bottom right
            hours = data.get("hours") or []
            cell = 22
            x0 = size - 8 - cell * min(6, len(hours))
            for i, h in enumerate(hours[:6]):
                hs, hint = scene_for(h.get("code"))
                _, _, hthing = PALETTE_DAY.get(hs, PALETTE_DAY["overcast"])
                cx = x0 + i * cell + cell // 2
                cy = size - 16
                if hs in ("clear", "mostly_clear"):
                    _disc(f, cx, cy - 8, 4, hthing if h.get("is_day", True) else NIGHT_THING)
                elif hs in ("rain", "showers", "drizzle", "freezing", "thunder"):
                    for k in range(3):
                        f[cy - 12 + k * 3:cy - 10 + k * 3, cx - 4 + k * 4] = hthing
                elif hs == "snow":
                    for k in range(3):
                        f[cy - 11 + (k % 2) * 4, cx - 4 + k * 4] = hthing
                else:
                    _disc(f, cx, cy - 8, 4, (110, 114, 126), soft=1.0)
                ht = self._temp(h.get("temp"), units)
                if ht is not None:
                    s_ = str(ht)
                    draw_text(f, s_, cx - text_width(s_, 1) // 2, cy - 2, DIM, 1)
            # sunrise and sunset ticks where the arc begins and ends
            if lat is not None and lon is not None and is_day:
                for k in (0.0, 1.0):
                    margin = size * 0.12
                    x = int(margin + k * (size - 2 * margin))
                    y = int(size * 0.14 + size * 0.20)
                    f[y:y + 3, x] = (140, 120, 80)

        if stale:
            s_ = 3 if not self.big else 7
            x0, y0 = size - s_ - 2, size - s_ - 2
            f[y0:y0 + s_, x0:x0 + s_] = DIM
            f[y0 + 1:y0 + s_ - 1, x0 + 1:x0 + s_ - 1] = ground
        return np.clip(f, 0, 255).astype(np.uint8)
