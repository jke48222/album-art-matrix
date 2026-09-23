"""Tessera's weather hero, composed for both the phone and the wall.

The layout follows WeatherPage and the sky follows WeatherAtmosphere: place,
large Technor temperature, condition, high/low, and engraved hills. The 64-pixel
panel uses the city without its region and omits the micro heading. Typography
and clouds are supersampled; it is not a separate pixel-font weather face.
"""
from __future__ import annotations

from functools import lru_cache
import math
from pathlib import Path
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

NEW_MOON_EPOCH = 947182440.0
LUNAR_MONTH_S = 29.530588853 * 86400
FONTS = Path(__file__).resolve().parents[2] / "assets" / "fonts" / "weather"
WET = {51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99}
SNOW = {71, 73, 75, 77, 85, 86}
FOG = {45, 48}
STORM = {95, 96, 99}
INK = (255, 242, 222, 255)


def moon_phase(when: float | None = None) -> float:
    return (((time.time() if when is None else when) - NEW_MOON_EPOCH) / LUNAR_MONTH_S) % 1


def _noise(seed):
    n = math.sin((seed + 1) * 127.1) * 43758.5453
    return n - math.floor(n)


def _rgb(value):
    return np.array([(value >> 16) & 255, (value >> 8) & 255, value & 255], dtype=np.float32)


def _words(code, day):
    if code == 0:
        return "Clear sky" if day else "Clear night"
    if code in WET:
        return ("Thunderstorms" if code in STORM else "Freezing rain" if code in {56, 57, 66, 67}
                else "Drizzle" if code in {51, 53, 55} else "Showers" if code in {80, 81, 82} else "Rain")
    if code in SNOW:
        return "Snow"
    if code in FOG:
        return "Fog"
    return {1: "Mostly clear", 2: "Partly cloudy", 3: "Overcast"}.get(code, "Unavailable")


@lru_cache(maxsize=96)
def _font(name, size):
    return ImageFont.truetype(str(FONTS / name), size=max(1, size))


class WeatherFace:
    def __init__(self, size: int):
        self.size = size
        # Three samples per LED at 64; two at 192. All geometry is normalized.
        self.res = max(192, size * 2)
        self._scene_key = None
        self._cloud_sprites = {}
        self._text_key = None
        self._text = None

    @staticmethod
    def _temp(c, units):
        try:
            c = float(c)
        except (TypeError, ValueError):
            return None
        if not math.isfinite(c):
            return None
        value = c * 9 / 5 + 32 if units == "f" else c
        # Swift's rounded() is nearest, ties away from zero, not Python's ties-even.
        return math.floor(value + .5) if value >= 0 else math.ceil(value - .5)

    def _prepare(self, code, day, golden):
        key = code, day, golden
        if self._scene_key == key:
            return
        self._scene_key = key
        s = self.res
        wet, snow, fog, storm = code in WET, code in SNOW, code in FOG, code in STORM
        self.top = _rgb(0x0C1526 if not day else 0x222B37 if storm else 0x263D48 if wet else
                        0x445C69 if snow else 0x344A53 if golden else 0x264D63)
        self.horizon = _rgb(0x3C5265 if not day else 0x779498 if wet else 0xBBCBCC if snow else
                            0xABB6AF if fog else 0xEAB17F if golden else 0xA9C6BD)
        self.accent = _rgb(0xC6DDE5 if snow else 0xA7CED4 if wet else 0xF0C384 if day else 0xB7C8EA)
        y, x = np.mgrid[:s, :s].astype(np.float32) / s
        weight = np.where(y <= .65, y / .65, (1 - y) / .35)[..., None]
        sky = self.top * (1 - weight) + self.horizon * weight
        glow = np.clip(1 - np.sqrt((x - .77) ** 2 + (y - .46) ** 2) / .85, 0, 1)[..., None]
        glow *= .32 if day else .1
        sky = sky * (1 - glow) + self.accent * glow
        self._sky = Image.fromarray(np.uint8(np.clip(sky, 0, 255))).convert("RGBA")
        # Continuous radial light, matching SwiftUI's atmosphere; no concentric
        # LED rings when the sun is visible in a clear sky.
        radius = .077 if day else .058
        distance = np.sqrt((x - .77) ** 2 + (y - .46) ** 2)
        alpha = np.interp(distance, [0, radius, radius * 3, radius * 5], [.40, .40, .08, 0])
        celestial = np.empty((s, s, 4), np.uint8)
        celestial[:, :, :3] = self.accent
        celestial[:, :, 3] = np.uint8(alpha * 255)
        disk = distance <= radius
        gradient = np.clip(np.sqrt((x - (.77 - radius * .2)) ** 2 +
                                   (y - (.46 - radius * .3)) ** 2) / (radius * 1.6), 0, 1)[..., None]
        colour = _rgb(0xFFF2D4) * (1 - gradient) + self.accent * gradient
        celestial[disk, :3] = np.uint8(colour[disk])
        celestial[disk, 3] = 255
        self._celestial = Image.fromarray(celestial)

        # Same ridgeline frequencies, phase and terrain colours as the phone.
        terrain = np.zeros((s, s, 4), np.uint8)
        colours = [self.horizon * .45 + self.top * .55, self.top * .55 + _rgb(0x1D302C) * .45,
                   _rgb(0x34464A if snow else 0x142723), _rgb(0x101C1B)]
        for layer in range(4):
            phase = layer * 1.7
            base = .72 + layer * .075  # Square crop of the taller native hero.
            ridge = base + np.sin(x * 5.2 + phase) * .042 + np.sin(x * 11.3 + phase * 2) * .017 + np.sin(x * 23 + phase) * .004
            mask = y >= ridge
            k = np.clip((y - base + .05) / (1 - base + .05), 0, 1)[..., None]
            col = colours[layer] * (1 - k) + _rgb(0x0E181A) * k
            contours = (np.mod(y - ridge, .011) < .0015) & (y - ridge < .095) & mask
            col[contours] += self.accent * .035
            terrain[mask, :3] = np.uint8(np.clip(col[mask], 0, 255))
            terrain[mask, 3] = 255
        self._terrain = Image.fromarray(terrain)
        # The phone's left and vertical scrims, with room for light at the right.
        a = .28 * np.clip(1 - x / .72, 0, 1)
        b = np.where(y < .45, .26 * (1 - y / .45), .60 * (y - .45) / .55)
        scrim = np.zeros((s, s, 4), np.uint8)
        scrim[:, :, 3] = np.uint8((1 - (1 - a) * (1 - b)) * 255)
        self._scrim = Image.fromarray(scrim)

        # Cache softly scalloped cloud banks. Drift changes placement, not texture.
        self._cloud_sprites.clear()
        clear = code in (0, 1)
        for bank in range((2 if code == 0 else 3) if clear else 7):
            mask = Image.new("L", (s * 2, s // 3))
            draw = ImageDraw.Draw(mask)
            spread = s * (.42 if clear else .65)
            for puff in range(16):
                u = puff / 15
                height = s * (.025 + _noise(bank * 30 + puff) * .055) * math.sin(math.pi * (.08 + u * .84))
                px = s + (u - .5) * spread
                py = s * .11 - height * .6
                draw.ellipse((px, py, px + spread * .3, py + height), fill=255)
            cloud_y = np.arange(s // 3, dtype=np.float32)[:, None, None] / s
            blend = np.clip((cloud_y - .05) / .11, 0, 1)
            tint = _rgb(0xE3D7BF if day else 0x8095AD)
            cloud_pixels = np.empty((s // 3, s * 2, 4), np.uint8)
            cloud_pixels[:, :, :3] = tint * (1 - blend) + self.top * blend
            cloud_pixels[:, :, 3] = np.uint8(np.asarray(mask) * (.24 if clear else .65 if day else .5))
            cloud = Image.fromarray(cloud_pixels)
            self._cloud_sprites[bank] = cloud.filter(ImageFilter.GaussianBlur(s * (.043 if fog else .018)))

    def _label(self, draw, text, x, y, size, font="Switzer-Medium.otf", fill=INK, max_width=.89):
        s = self.res
        pixels = max(1, round(size * s))
        face = _font(font, pixels)
        # Fit long places and negative / three-digit temperatures without clipping.
        while draw.textlength(text, font=face) > s * max_width and pixels > 2:
            pixels -= 1
            face = _font(font, pixels)
        draw.text((round(x * s), round(y * s)), text, font=face, fill=fill, anchor="lt")

    def _labels(self, data, units, place, stale):
        data = data or {}
        temp, high, low = (self._temp(data.get(k), units) for k in ("temp", "high", "low"))
        code, day = data.get("code"), bool(data.get("is_day", True))
        key = temp, high, low, code, day, place, stale, bool(data)
        if key == self._text_key:
            return self._text
        self._text_key = key
        img = Image.new("RGBA", (self.res, self.res))
        draw = ImageDraw.Draw(img)
        small = self.size <= 64
        degrees = lambda v: "—" if v is None else f"{v}°"
        if not small:
            heading = "LAST KNOWN WEATHER" if stale else "CURRENT CONDITIONS" if data else "WEATHER"
            self._label(draw, heading, .055, .06, .027, "MartianMono-Regular.ttf", (227, 232, 220, 255))
        city = place.split(",")[0].strip() if small else place
        self._label(draw, city or "Choose a place", .055, .15 if not small else .12,
                    .066 if not small else .109)
        self._label(draw, degrees(temp), .045, .35 if not small else .31,
                    .34 if not small else .43, "Technor-Medium.otf")
        condition = _words(code, day) if data else "No weather yet" if place else "Set in Tessera"
        self._label(draw, condition, .055, .67, .05 if not small else .10)
        # Switzer has no arrow glyphs; draw the same simple up/down marks as SF Symbols.
        y = .76 if not small else .79
        for value, x, up in ((high, .055, True), (low, .39 if small else .25, False)):
            length = .047 if small else .028
            cx = (x + length / 2) * self.res
            y0, y1 = y * self.res, (y + length) * self.res
            end, tail = (y0, y1) if up else (y1, y0)
            tip = length * self.res * .42
            colour = (225, 228, 219, 255)
            width = max(1, round(self.res * (.012 if small else .003)))
            draw.line((cx, tail, cx, end), fill=colour, width=width)
            draw.line((cx - tip, end + (tip if up else -tip), cx, end,
                       cx + tip, end + (tip if up else -tip)), fill=colour, width=width)
            self._label(draw, degrees(value), x + length + .018, y,
                        .075 if small else .038, fill=colour, max_width=.25)
        if stale and small:
            draw.ellipse((self.res * .89, self.res * .06, self.res * .95, self.res * .12), fill=(240, 195, 132, 255))
        self._text = img
        return img

    def frame_at(self, t: float, data: dict | None, units: str = "f", lat=None, lon=None,
                 stale: bool = False, place: str = "", now: float | None = None) -> np.ndarray:
        now = time.time() if now is None else now
        d = data or {}
        code, day = d.get("code"), bool(d.get("is_day", True))
        raw_wind = d.get("wind_kmh")
        wind = 8 if raw_wind is None else max(0, min(60, float(raw_wind)))
        golden = day and any(abs(now - d[k]) < 4500 for k in ("sunrise", "sunset") if d.get(k) is not None)
        self._prepare(code, day, golden)
        s = self.res
        frame = self._sky.copy()
        light = Image.new("RGBA", frame.size)
        draw = ImageDraw.Draw(light)
        if not day and code in (0, 1, 2):
            for i in range(65):
                x, y = _noise(i * 7) * s, _noise(i * 11 + 4) * s * .6
                r = s * (.003 if i % 7 == 0 else .0016)
                alpha = .3 + .35 * (.5 + .5 * math.sin(t * .45 + i))
                draw.ellipse((x, y, x + r * 2, y + r * 2), fill=(231, 233, 224, round(alpha * 255)))
        if code in (0, 1, 2, 45, 48):
            cx, cy, radius = s * .77, s * .46, s * (.077 if day else .058)
            light = Image.alpha_composite(light, self._celestial)
            draw = ImageDraw.Draw(light)
            if not day:
                phase = moon_phase(now)
                for y in range(-math.ceil(radius), math.ceil(radius) + 1):
                    half = math.sqrt(max(0, radius * radius - y * y))
                    edge = half * math.cos(phase * math.tau)
                    start = -half if phase < .5 else -edge
                    draw.line((cx + start, cy + y, cx + start + max(0, half + edge), cy + y),
                              fill=(*map(int, self.top), 235), width=1)
        frame = Image.alpha_composite(frame, light)
        for bank, cloud in self._cloud_sprites.items():
            drift = t * (.002 + wind * .00007) * (1 if bank % 2 == 0 else -.6)
            cx = ((_noise(bank + 40) + drift) % 1.7) * s - s * .35
            cy = s * (.21 + _noise(bank + 90) * .34)
            frame.alpha_composite(cloud, (round(cx - s), round(cy - s * .11)))
        frame = Image.alpha_composite(frame, self._terrain)
        atmosphere = Image.new("RGBA", frame.size)
        draw = ImageDraw.Draw(atmosphere)
        if code in FOG:
            for i in range(4):
                cy = s * (.45 + i * .1)
                x = math.sin(t * .12 + i) * s * .2
                draw.ellipse((x - s * .2, cy, x + s * 1.2, cy + s * .05), fill=(*map(int, self.horizon), 92))
            atmosphere = atmosphere.filter(ImageFilter.GaussianBlur(s * .05))
            draw = ImageDraw.Draw(atmosphere)
        if code in WET or code in SNOW:
            snow = code in SNOW
            for i in range(65 if snow else 90):
                depth = .4 + _noise(i + 77) * .6
                y = (_noise(i * 7) + t * (.035 if snow else .48) * depth) % 1 * s
                x = (_noise(i * 13) * s + math.sin(t * .4 + i) * s * (.03 if snow else .005)
                     + y * min(wind, 40) * .008) % s
                if snow:
                    r = s * (.0028 + depth * .0025)
                    draw.ellipse((x, y, x + r, y + r), fill=(255, 255, 255, round(depth * 191)))
                else:
                    draw.line((x, y, x + min(wind, 40) * .0003 * s, y + depth * .036 * s),
                              fill=(211, 230, 234, round(depth * 102)), width=max(1, round(s * .0017)))
        if code in STORM:
            pulse = max(0, math.sin(t * .35)) ** 18 * .10
            glow = Image.new("RGBA", frame.size, (255, 255, 255, round(pulse * 255)))
            atmosphere = Image.alpha_composite(atmosphere, glow)
        frame = Image.alpha_composite(frame, atmosphere)
        frame = Image.alpha_composite(frame, self._scrim)
        frame = Image.alpha_composite(frame, self._labels(data, units, place, stale))
        return np.asarray(frame.convert("RGB").resize((self.size, self.size), Image.Resampling.LANCZOS))
