"""The halo: a ring of addressable LEDs behind the object, matched to the art.

Every LED works out where it sits on the object's perimeter, and takes its
colour from the artwork at that exact point on the artwork's own edge. The top
left LED shows what the top left of the record shows. This is the same mapping
`design/photo.py:retint_halo` uses for the renders, so the object in the room
looks like the object in the catalogue.

Why these LEDs and not WS2812B on a GPIO pin
--------------------------------------------
The Pi is already driving nine HUB75 panels, and that library wants a core to
itself with the timing left alone. A WS2812B strip bit-banged off the same
chip is a fight over microseconds, and on a Pi 5 it is worse than that: the
old rpi_ws281x path does not work on the new I/O chip at all.

APA102 / SK9822 have a separate clock line, so they do not care about timing.
They go on hardware SPI, which is a peripheral the matrix library never
touches, and the two run side by side without either knowing. That is the
whole reason for choosing them over the cheaper three-wire strip.

    backend "apa102"  SK9822 or APA102 on SPI0. MOSI is pin 19 (GPIO 10),
                      SCLK is pin 23 (GPIO 11). Enable SPI with raspi-config.
    backend "pico"    a WS2812B strip on a Raspberry Pi Pico, colours sent
                      down USB serial. Use this if you already own WS2812B.
    backend "null"    prints nothing, does nothing. For working on a laptop.

Power
-----
Run the strip off the existing 5 V rail, not off the Pi's 5 V pin, and tie the
grounds together. A 113 LED ring at the brightness this runs at draws well
under an amp; flat out at white it would be about 6.8 A, which the supply has
but the Pi's header does not.
"""
from __future__ import annotations

import math
import time

# The halo rectangle, and the picture it samples. Both in millimetres, both
# taken from the models so the mapping is the object's real geometry.
BOARD = 550.0
HALO = BOARD - 80.0        # 470: the strip runs 40 mm in from the edge
PICTURE = 480.0

EDGE_FRACTION = 1.0 / 22   # the outer strip of the art each LED reads
FLOOR = 0.30               # a near black edge still has to make some light
GAMMA = 2.2
MIN_INTERVAL = 1.0 / 30    # no point pushing faster than this


def _clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


class Halo:
    """Maps a picture onto a ring of LEDs and pushes it to a strip."""

    def __init__(self, count=113, backend="null", brightness=0.55,
                 board=BOARD, start=0.0, clockwise=True, **kw):
        self.count = int(count)
        self.brightness = float(brightness)
        self.side = (board - 80.0)
        self.start = float(start)          # where LED 0 sits, 0..1 round the ring
        self.clockwise = bool(clockwise)
        self._last = 0.0
        self._pixels = [(0, 0, 0)] * self.count
        self._points = [self._perimeter(i) for i in range(self.count)]
        self._dev = self._open(backend, **kw)

    # ---------------------------------------------------------------- geometry
    def _perimeter(self, i):
        """Where LED `i` sits, as (u, v) in -0.5..0.5 with +v up.

        The ring is walked as one length of tape: along the bottom, up the
        right, back along the top, down the left, which is how it actually gets
        stuck down.
        """
        t = (i + 0.5) / self.count + self.start
        t -= math.floor(t)
        if not self.clockwise:
            t = 1.0 - t
        s = t * 4.0                        # which side, and how far along it
        side, f = int(s), s - int(s)
        if side == 0:                      # bottom, left to right
            return (-0.5 + f, -0.5)
        if side == 1:                      # right, bottom to top
            return (0.5, -0.5 + f)
        if side == 2:                      # top, right to left
            return (0.5 - f, 0.5)
        return (-0.5, 0.5 - f)             # left, top to bottom

    # ----------------------------------------------------------------- colour
    def sample(self, img):
        """One colour per LED, read off the artwork's own outer edge.

        `img` is the picture as shown, any size, PIL RGB. The halo sits outside
        the picture, so each LED reads the nearest edge strip rather than the
        pixel under it, which is what makes a bright top edge throw light up
        the wall and a dark one throw almost none.
        """
        w, h = img.size
        px = img.convert("RGB").load()
        d = max(2, int(w * EDGE_FRACTION))
        out = []
        for u, v in self._points:
            # the LED's position on the halo, expressed on the picture
            k = self.side / PICTURE
            pu = _clamp(u * k + 0.5, 0.0, 1.0)
            pv = _clamp(v * k + 0.5, 0.0, 1.0)
            # which edge is nearest, and the block of pixels to average
            if abs(u) >= abs(v):
                x0 = w - d if u > 0 else 0
                x1 = w if u > 0 else d
                cy = int((1.0 - pv) * (h - 1))
                y0, y1 = cy - d // 2, cy + d // 2 + 1
            else:
                y0 = 0 if v > 0 else h - d
                y1 = d if v > 0 else h
                cx = int(pu * (w - 1))
                x0, x1 = cx - d // 2, cx + d // 2 + 1
            x0, x1 = max(0, x0), min(w, max(1, x1))
            y0, y1 = max(0, y0), min(h, max(1, y1))
            r = g = b = n = 0
            for y in range(y0, y1):
                for x in range(x0, x1):
                    p = px[x, y]
                    r += p[0]; g += p[1]; b += p[2]; n += 1
            if not n:
                out.append((0, 0, 0))
                continue
            r, g, b = r / n / 255.0, g / n / 255.0, b / n / 255.0
            mx = max(r, g, b)
            if 0 < mx < FLOOR:            # keep the hue, lift the level
                k = FLOOR / mx
                r, g, b = r * k, g * k, b * k
            out.append(tuple(
                int(round(255 * _clamp(c, 0.0, 1.0) ** (1 / GAMMA) * self.brightness))
                for c in (r, g, b)))
        return out

    # ------------------------------------------------------------------ output
    def show(self, img, force=False):
        """Sample `img` and push it. Safe to call on every frame."""
        now = time.monotonic()
        if not force and now - self._last < MIN_INTERVAL:
            return
        self._last = now
        try:
            self._pixels = self.sample(img)
            self._dev(self._pixels)
        except Exception as exc:               # a halo must never take the wall down
            print("[halo] %s" % exc)

    def off(self):
        self._pixels = [(0, 0, 0)] * self.count
        try:
            self._dev(self._pixels)
        except Exception:
            pass

    # ---------------------------------------------------------------- backends
    def _open(self, backend, **kw):
        if backend == "apa102":
            return self._apa102(**kw)
        if backend == "pico":
            return self._pico(**kw)
        return lambda px: None

    def _apa102(self, bus=0, device=0, speed=8_000_000, **_):
        import spidev
        spi = spidev.SpiDev()
        spi.open(bus, device)
        spi.max_speed_hz = speed
        spi.mode = 0b00

        def push(px):
            buf = [0x00, 0x00, 0x00, 0x00]
            for r, g, b in px:
                buf += [0xFF, b, g, r]      # global brightness full, we scale in software
            buf += [0xFF] * ((len(px) + 15) // 16)   # the end frame the datasheet wants
            spi.writebytes2(buf)
        return push

    def _pico(self, port="/dev/ttyACM0", baud=921600, **_):
        import serial
        ser = serial.Serial(port, baud, timeout=0.2)

        def push(px):
            body = bytearray()
            for r, g, b in px:
                body += bytes((r, g, b))
            ser.write(b"\xA5" + len(px).to_bytes(2, "little") + body)
            ser.flush()
        return push


def from_config(cfg):
    """Build a Halo from the [halo] table, or None if there isn't one."""
    h = (cfg or {}).get("halo") or {}
    if not h.get("enabled"):
        return None
    return Halo(count=h.get("count", 113), backend=h.get("backend", "null"),
                brightness=h.get("brightness", 0.55), board=h.get("board", BOARD),
                start=h.get("start", 0.0), clockwise=h.get("clockwise", True),
                port=h.get("port", "/dev/ttyACM0"))
