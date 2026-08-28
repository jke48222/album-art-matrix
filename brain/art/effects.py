"""Ambient mode — the wall as a light, not a record sleeve.

Each effect is a frame_at(t) callable returning a pre-white-balance PIL image,
same contract as DiscAnimator, so the main loop treats art and ambience the
same way: generate, white-balance (which also applies brightness), ship.
"""
import colorsys

import numpy as np
from PIL import Image


def _hex_rgb(s: str) -> tuple[int, int, int]:
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


class Ambient:
    def __init__(self, size: int, effect: str = "rainbow",
                 color: str = "#4060ff", color2: str = "#ff2080",
                 speed: float = 1.0):
        self.size = size
        self.effect = effect
        self.speed = speed
        self.c1 = np.array(_hex_rgb(color), dtype=np.float32)
        self.c2 = np.array(_hex_rgb(color2), dtype=np.float32)
        yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / (size - 1)
        self._xx, self._yy = xx, yy

    def frame_at(self, t: float) -> Image.Image:
        t *= self.speed
        fn = getattr(self, f"_{self.effect}", self._solid)
        arr = np.clip(fn(t), 0, 255).astype(np.uint8)
        return Image.fromarray(arr, "RGB")

    def _solid(self, t):
        return np.broadcast_to(self.c1, (self.size, self.size, 3)).copy()

    def _breathe(self, t):
        # sine between 25% and 100% over ~5s — calm, not a strobe
        k = 0.625 + 0.375 * np.sin(t * 2 * np.pi / 5.0)
        return self.c1[None, None, :] * k

    def _pulse(self, t):
        # sharp attack, exponential decay — one beat per second at speed 1.0
        # (real beat-grid sync lands with S4; until then speed IS the tempo)
        phase = t % 1.0
        k = 0.2 + 0.8 * np.exp(-4.0 * phase)
        return self.c1[None, None, :] * k

    def _rainbow(self, t):
        # horizontal hue sweep drifting right, full cycle ~12s
        hue = (self._xx + t / 12.0) % 1.0
        flat = hue.ravel()
        rgb = np.array([colorsys.hsv_to_rgb(h, 0.9, 1.0) for h in
                        np.linspace(0, 1, 256)], dtype=np.float32) * 255.0
        return rgb[(flat * 255).astype(np.uint8)].reshape(
            self.size, self.size, 3)

    def _gradient(self, t):
        # c1 -> c2 across an axis that slowly rotates (~40s per turn)
        ang = t * 2 * np.pi / 40.0
        proj = (self._xx - 0.5) * np.cos(ang) + (self._yy - 0.5) * np.sin(ang)
        k = (proj + 0.707) / 1.414
        k = np.clip(k, 0, 1)[:, :, None]
        return self.c1[None, None, :] * (1 - k) + self.c2[None, None, :] * k
