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

    # ---- plaid --------------------------------------------------------
    #
    # Built the way tartan is actually built, because the structure is what
    # makes it read as cloth rather than as a grid of squares:
    #
    #   a sett     one sequence of stripe widths and colours, mirrored, so
    #              the pattern reflects rather than merely repeating
    #   warp       the sett running down the columns
    #   weft       the SAME sett running across the rows
    #   twill      a 2/2 diagonal deciding which thread sits on top at each
    #              crossing, which is where plaid gets its texture and its
    #              half-tone blocks where two different colours cross
    #
    # It animates as weaving: the warp is laid down the panel, the weft is
    # thrown across it, the twill then travels diagonally the way a real
    # diagonal does under a moving eye, and a new sett is drafted.

    def _plaid(self, t):
        n = self.size

        # Ambient light should mostly sit still. The first version wove in,
        # tore itself down to black and rewove every ten seconds, which reads
        # as the wall glitching rather than as cloth. So: weave once on the
        # way in, then stay woven. The only continuous motion is the twill
        # travelling, and a new sett arrives by crossfade, never by blanking.
        weave_in = 2.4
        draft_len = 26.0
        blend = 3.0

        # Which draft, and how far into the crossfade toward the next.
        age = max(0.0, t - weave_in)
        draft = int(age // draft_len)
        into = age - draft * draft_len
        mix = 0.0 if into < draft_len - blend else (into - (draft_len - blend)) / blend

        cloth = self._plaid_cloth(draft, t, n)
        if mix > 0:
            cloth = cloth * (1 - mix) + self._plaid_cloth(draft + 1, t, n) * mix

        # The one-time weave: warp down the panel, then weft across it.
        if t < weave_in:
            half = weave_in * 0.45
            if t < half:                        # warp goes on
                k = t / half
                warp = self._plaid_warp(draft, n)
                return np.where((np.arange(n)[None, :, None] < k * n), warp, 0.0)
            k = (t - half) / (weave_in - half)  # weft crosses it
            front = k * n
            warp = self._plaid_warp(draft, n)
            out = np.where(np.arange(n)[:, None, None] < front, cloth, warp)
            row = int(front) - 1
            if 0 <= row < n:
                out[row] = np.minimum(255.0, out[row] * 1.5 + 55.0)
            return out

        return cloth

    def _plaid_draft(self, draft):
        rng = np.random.default_rng(draft * 104729)
        pal = np.asarray(self._weave_palette(rng), dtype=np.float32)
        return pal, self._sett(rng, len(pal), self.size)

    def _plaid_warp(self, draft, n):
        pal, sett = self._plaid_draft(draft)
        return pal[sett][None, :, :].repeat(n, axis=0)

    def _plaid_cloth(self, draft, t, n):
        pal, sett = self._plaid_draft(draft)
        y, x = np.mgrid[0:n, 0:n]
        warp_i, weft_i = sett[x], sett[y]

        # The twill travels, slowly. This is the whole of the motion once the
        # cloth is on: a diagonal moving under the eye, not a pattern change.
        offset = int(t * 1.5)
        over = ((x + y + offset) % 4) < 2
        out = pal[np.where(over, warp_i, weft_i)]

        # Where two different threads cross the eye reads a blend, which is
        # where tartan gets its extra colours without extra thread.
        mixed = (pal[warp_i] + pal[weft_i]) / 2
        crossing = warp_i != weft_i
        return np.where(crossing[..., None], out * 0.55 + mixed * 0.45, out)

    def _sett(self, rng, ncolors, n):
        """A reflective sett: stripe widths mirrored, then tiled to the panel.

        Mirroring is the part that matters. A sett that merely repeats reads
        as wallpaper; a sett that reflects reads as tartan.
        """
        widths = [1, 1, 2, 2, 3, 4, 6, 8]
        half, total = [], 0
        target = int(rng.integers(15, 23))
        while total < target:
            w = min(int(rng.choice(widths)), target - total)
            half.append((int(rng.integers(0, ncolors)), w))
            total += w
        line = np.concatenate([np.repeat([c for c, _ in half], [w for _, w in half])])
        full = np.concatenate([line, line[::-1]])
        reps = int(np.ceil(n / len(full))) + 1
        return np.tile(full, reps)[:n].astype(np.int32)

    def _weave_palette(self, rng):
        """Threads for a draft: the album's two, plus tints between them.

        match_art feeds c1/c2 from the sleeve, so the weave is made of what is
        playing. A dark third tone gives the pattern somewhere to breathe.
        """
        c1, c2 = self.c1, self.c2
        mid = (c1 + c2) / 2
        light = np.minimum(255.0, np.maximum(c1, c2) * 1.2 + 40.0)
        deep = np.minimum(c1, c2) * 0.22
        # The four figure tones shuffle; the dark ground stays last so the
        # border can always reach for it.
        pal = [c1, c2, mid, light]
        rng.shuffle(pal)
        return pal + [deep]

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
