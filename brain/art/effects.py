"""Ambient mode — the wall as a light, not a record sleeve.

Each effect is a frame_at(t) callable returning a pre-white-balance PIL image,
same contract as DiscAnimator, so the main loop treats art and ambience the
same way: generate, white-balance (which also applies brightness), ship.
"""
import colorsys
import random

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
        # Per-draft caches: a plaid/weave draft is fixed for ~25 s, so its
        # palette, sett, and index grids are built once, not per frame.
        self._plaid_cache = {}
        self._cloth_cache = {}
        self._weave_cache = {}
        self._snake = None           # built on first snake frame
        # 256-entry hue table; constant, so never rebuilt in the frame loop
        self._rainbow_lut = np.array(
            [colorsys.hsv_to_rgb(h, 0.9, 1.0) for h in np.linspace(0, 1, 256)],
            dtype=np.float32) * 255.0

    def frame_at(self, t: float) -> Image.Image:
        t *= self.speed
        fn = (self._snake_frame if self.effect == "snake"
              else getattr(self, f"_{self.effect}", self._solid))
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
        got = self._plaid_cache.get(draft)
        if got is None:
            rng = np.random.default_rng(draft * 104729)
            pal = np.asarray(self._weave_palette(rng), dtype=np.float32)
            got = (pal, self._sett(rng, len(pal), self.size))
            self._plaid_cache[draft] = got
            while len(self._plaid_cache) > 4:
                self._plaid_cache.pop(min(self._plaid_cache))
        return got

    def _plaid_warp(self, draft, n):
        pal, sett = self._plaid_draft(draft)
        return pal[sett][None, :, :].repeat(n, axis=0)

    def _plaid_cloth(self, draft, t, n):
        got = self._cloth_cache.get(draft)
        if got is None:
            pal, sett = self._plaid_draft(draft)
            y, x = np.mgrid[0:n, 0:n]
            warp_i, weft_i = sett[x], sett[y]
            # Where two different threads cross the eye reads a blend, which
            # is where tartan gets its extra colours without extra thread.
            mixed = (pal[warp_i] + pal[weft_i]) / 2
            crossing = (warp_i != weft_i)[..., None]
            got = (x + y, pal[warp_i], pal[weft_i], mixed, crossing)
            self._cloth_cache[draft] = got
            while len(self._cloth_cache) > 4:
                self._cloth_cache.pop(min(self._cloth_cache))
        xy, warp_c, weft_c, mixed, crossing = got

        # The twill travels, slowly. This is the whole of the motion once the
        # cloth is on: a diagonal moving under the eye, not a pattern change.
        over = (((xy + int(t * 1.5)) % 4) < 2)[..., None]
        out = np.where(over, warp_c, weft_c)
        return np.where(crossing, out * 0.55 + mixed * 0.45, out)

    # ---- weave --------------------------------------------------------
    #
    # The geometric draft: a bordered field with a central medallion, the
    # composition of a lot of woven and tiled ornament, Roman tesserae
    # included. Plain geometry deliberately, not an imitation of any one
    # culture's designs.

    def _weave(self, t):
        n = self.size
        weave_in, draft_len, blend = 2.4, 24.0, 3.0
        age = max(0.0, t - weave_in)
        draft = int(age // draft_len)
        into = age - draft * draft_len
        mix = 0.0 if into < draft_len - blend else (into - (draft_len - blend)) / blend

        cloth = self._weave_field(draft, t, n)
        if mix > 0:
            cloth = cloth * (1 - mix) + self._weave_field(draft + 1, t, n) * mix

        if t < weave_in:                       # one pass of the loom
            front = (t / weave_in) * n
            rows = np.arange(n)[:, None, None]
            cloth = cloth * np.clip((front - rows) / 3.0, 0.0, 1.0)
            row = int(front) - 1
            if 0 <= row < n:
                cloth[row] = np.minimum(255.0, cloth[row] * 1.5 + 55.0)
        return cloth

    def _weave_field(self, draft, t, n):
        got = self._weave_cache.get(draft)
        if got is not None:
            pal, idx = got
            return pal[(idx + int(t * 0.6)) % len(pal)]
        rng = np.random.default_rng(draft * 7919)
        pal = np.asarray(self._weave_palette(rng), dtype=np.float32)
        y, x = np.mgrid[0:n, 0:n]
        xm = np.minimum(x, n - 1 - x).astype(np.int32)
        ym = np.minimum(y, n - 1 - y).astype(np.int32)

        border, band = 2, 6
        field0, field1 = border + band, n - border - band

        motif = int(rng.integers(0, 4))
        s1 = int(rng.integers(4, 8))
        if motif == 0:
            idx = ((xm + ym) // s1) % len(pal)
        elif motif == 1:
            idx = (np.maximum(xm, ym) // s1) % len(pal)
        elif motif == 2:
            idx = ((np.abs(xm - ym) // s1) + (np.minimum(xm, ym) // s1)) % len(pal)
        else:
            idx = ((np.minimum(xm, ym) // s1) * 2 + (xm + ym) // (s1 * 2)) % len(pal)

        s2 = int(rng.integers(3, 6))
        bmotif = int(rng.integers(0, 3))
        if bmotif == 0:
            bidx = (xm // s2) % 2
        elif bmotif == 1:
            bidx = ((xm + ym) // s2) % 2
        else:
            bidx = ((xm // s2) + (ym // s2)) % 2
        ba, bb = int(rng.integers(0, len(pal))), int(rng.integers(0, len(pal)))
        band_vals = np.where(bidx == 1, ba, bb)
        idx[border:field0] = band_vals[border:field0]
        idx[field1:n - border] = band_vals[field1:n - border]

        deep = len(pal) - 1
        idx[:border] = deep
        idx[n - border:] = deep
        idx[:, :border] = deep
        idx[:, n - border:] = deep

        self._weave_cache[draft] = (pal, idx)
        while len(self._weave_cache) > 4:
            self._weave_cache.pop(min(self._weave_cache))
        return pal[(idx + int(t * 0.6)) % len(pal)]

    # ---- deco ---------------------------------------------------------
    #
    # Mid-century modern geometric, the Girard/atomic-age vocabulary: flat
    # bold shapes on a grid, circles and half-circles and fans and chevrons,
    # a tight palette, no gradients. It animates like a split-flap board:
    # one cell at a time swaps its motif, in a scattered order, so the field
    # is always changing and never all changing.

    _DECO_MOTIFS = 7

    def _deco(self, t):
        n = self.size
        cells = 4                              # 4x4 of 16px, big and flat
        c = n // cells
        rng = np.random.default_rng(11)
        pal = np.asarray(self._weave_palette(np.random.default_rng(3)), dtype=np.float32)

        # A scattered order the flips follow, fixed for the session.
        order = rng.permutation(cells * cells)
        flips = int(t / 0.55)                   # one cell every 0.55s

        out = np.zeros((n, n, 3), dtype=np.float32)
        yy, xx = np.mgrid[0:c, 0:c].astype(np.float32)

        for k in range(cells * cells):
            cy, cx = divmod(k, cells)
            # how many times this cell has flipped so far
            seen = (flips - int(np.where(order == k)[0][0])) // (cells * cells) + 1
            gen = np.random.default_rng(k * 131 + max(0, seen) * 17)
            motif = int(gen.integers(0, self._DECO_MOTIFS))
            fg = pal[int(gen.integers(0, len(pal) - 1))]
            bg = pal[len(pal) - 1] if gen.random() < 0.55 else pal[int(gen.integers(0, len(pal) - 1))]

            tile = self._deco_tile(motif, c, yy, xx, fg, bg)

            # the flip itself: the cell squashes and comes back
            since = t - (int(np.where(order == k)[0][0]) + max(0, seen - 1) * cells * cells) * 0.55
            if 0 <= since < 0.35:
                k2 = abs(since / 0.35 - 0.5) * 2      # 1 -> 0 -> 1
                h = max(1, int(c * k2))
                pad = (c - h) // 2
                squashed = np.zeros_like(tile)
                if h > 0:
                    resized = tile[np.linspace(0, c - 1, h).astype(int)]
                    squashed[pad:pad + h] = resized
                tile = squashed

            out[cy * c:(cy + 1) * c, cx * c:(cx + 1) * c] = tile

        return out

    def _deco_tile(self, motif, c, yy, xx, fg, bg):
        r = c / 2.0
        d = np.hypot(xx - r + 0.5, yy - r + 0.5)
        tile = np.broadcast_to(bg, (c, c, 3)).copy()

        if motif == 0:                          # circle
            m = d < r * 0.72
        elif motif == 1:                        # half circle
            m = (d < r * 0.92) & (yy >= r)
        elif motif == 2:                        # quarter fan
            m = (np.hypot(xx, yy) < c * 0.85) & (np.hypot(xx, yy) > c * 0.45)
        elif motif == 3:                        # triangle
            m = (yy >= c - 1 - 2 * np.abs(xx - r + 0.5))
        elif motif == 4:                        # cross
            m = (np.abs(xx - r + 0.5) < c * 0.16) | (np.abs(yy - r + 0.5) < c * 0.16)
        elif motif == 5:                        # starburst
            ang = np.arctan2(yy - r + 0.5, xx - r + 0.5)
            m = (np.cos(ang * 8) > 0.25) & (d < r * 0.95)
        else:                                   # stacked chevrons
            m = ((yy + np.abs(xx - r + 0.5)).astype(int) // max(1, c // 4)) % 2 == 0

        tile[m] = fg
        return tile

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
        return np.broadcast_to(self.c1 * k,
                               (self.size, self.size, 3)).copy()

    def _pulse(self, t):
        # sharp attack, exponential decay — one beat per second at speed 1.0
        # (real beat-grid sync lands with S4; until then speed IS the tempo)
        phase = t % 1.0
        k = 0.2 + 0.8 * np.exp(-4.0 * phase)
        return np.broadcast_to(self.c1 * k,
                               (self.size, self.size, 3)).copy()

    def _rainbow(self, t):
        # horizontal hue sweep drifting right, full cycle ~12s
        hue = (self._xx + t / 12.0) % 1.0
        flat = hue.ravel()
        return self._rainbow_lut[(flat * 255).astype(np.uint8)].reshape(
            self.size, self.size, 3)

    def _gradient(self, t):
        # c1 -> c2 across an axis that slowly rotates (~40s per turn)
        ang = t * 2 * np.pi / 40.0
        proj = (self._xx - 0.5) * np.cos(ang) + (self._yy - 0.5) * np.sin(ang)
        k = (proj + 0.707) / 1.414
        k = np.clip(k, 0, 1)[:, :, None]
        return self.c1[None, None, :] * (1 - k) + self.c2[None, None, :] * k


# ---- snake ---------------------------------------------------------------
#
# The wall playing itself. Same rules as the app's game: a 32x32 torus, the
# only death is meeting yourself, a flood-fill greedy that chases the meal
# without walling itself in. It is a lamp effect rather than a game because
# that is what it turned out to be: a thing the wall does, in the album's
# colours, that happens to be Snake.


class _SnakeState:
    N = 32
    TICK = 0.13

    def __init__(self):
        self.rng = random.Random()
        self.last = 0.0
        self.deal()

    def deal(self):
        n = self.N
        self.body = [(n // 2 - i, n // 2) for i in range(4)]
        self.dir = (1, 0)
        self.grow = 0
        self.dead = 0.0              # >0: unravel clock
        self.drop_food()

    def drop_food(self):
        while True:
            p = (self.rng.randrange(self.N), self.rng.randrange(self.N))
            if p not in self.body:
                self.food = p
                return

    def pilot(self):
        n = self.N
        head = self.body[0]
        occupied = set(self.body[:-1] if self.grow == 0 else self.body)
        occupied.discard(head)

        def wrap(p):
            return (p[0] % n, p[1] % n)

        def room(start):
            want = len(self.body) + 8
            seen = {start}
            queue = [start]
            i = 0
            while i < len(queue) and len(seen) < want:
                c = queue[i]; i += 1
                for d in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    q = wrap((c[0] + d[0], c[1] + d[1]))
                    if q not in occupied and q not in seen:
                        seen.add(q)
                        queue.append(q)
            return len(seen)

        def span(a, b):
            d = abs(a - b)
            return min(d, n - d)

        options = []
        for d in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            if d == (-self.dir[0], -self.dir[1]):
                continue
            p = wrap((head[0] + d[0], head[1] + d[1]))
            if p not in occupied:
                options.append((d, p))
        if not options:
            return None
        need = len(self.body) + 4
        scored = [(d, room(p), span(p[0], self.food[0]) + span(p[1], self.food[1]),
                   0 if d == self.dir else 1) for d, p in options]
        roomy = [s for s in scored if s[1] >= need]
        pool = roomy or scored
        return min(pool, key=lambda s: (s[2], s[3]))[0]

    def tick(self):
        if self.dead > 0:
            if len(self.body) > 3:
                del self.body[-3:]
            elif self.body:
                self.body.clear()
            else:
                self.dead += 1
                if self.dead > 10:   # a beat of dark, then again
                    self.deal()
            return
        d = self.pilot()
        if d:
            self.dir = d
        n = self.N
        head = ((self.body[0][0] + self.dir[0]) % n,
                (self.body[0][1] + self.dir[1]) % n)
        check = self.body if self.grow else self.body[:-1]
        if head in check:
            self.dead = 1.0
            return
        self.body.insert(0, head)
        if head == self.food:
            self.grow += 2
            self.drop_food()
        if self.grow:
            self.grow -= 1
        else:
            self.body.pop()


def _snake_frame(self, t):
    if self._snake is None:
        self._snake = _SnakeState()
        self._snake.last = t
    sn = self._snake
    # advance on the game's own clock, however often frames are asked for
    while t - sn.last >= sn.TICK:
        sn.last += sn.TICK
        sn.tick()

    arr = np.zeros((self.size, self.size, 3), dtype=np.float32)

    def block(p, col):
        x, y = p[0] * 2, p[1] * 2
        arr[y:y + 2, x:x + 2] = col

    if not sn.dead:
        block(sn.food, self.c2)
    count = max(1, len(sn.body))
    for i, seg in enumerate(sn.body):
        k = 1.0 - 0.55 * i / count
        block(seg, self.c1 * k)
    if sn.body:
        block(sn.body[0], np.clip(self.c1 * 1.25 + 40, 0, 255))
    return arr


Ambient._snake_frame = _snake_frame
