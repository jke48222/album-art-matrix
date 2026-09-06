"""The wall's shape: how many panels, in what order, which way up.

One 64x64 panel needed none of this. Nine of them need all of it, because a
frame is no longer a picture the panel takes as-is: it is a picture cut into
tiles, and each tile has to reach the panel that is standing in that spot.

The renderer's library lays the canvas out one PORT per band, panel height
tall, with the chain running across that band in x order. Which end of the
band the first panel in the chain lands on is a property of the wiring, not
of the software, and the honest way to find it out is to light the tile map
pattern and look (scripts/panel_qa.py wall --only tilemap). Whatever comes
back, `order` and `rotate` here bend the frame to the wall that exists, so a
panel that ended up in the wrong place, or upside down because that was the
way the ribbon reached, is a line in config.toml rather than a rebuild.

The remap is a gather over a precomputed index, about 40 microseconds for a
192x192 frame, which is nothing next to the pipeline that made the frame.

The phone is a separate question. Tessera speaks 64x64 everywhere (12,288
raw bytes, checked in about thirty places), so the wall keeps talking to it
in 64x64: what it sends is scaled up to the wall, what it reads back is the
wall scaled down. `phone_view` and `fit` are that translation.
"""
from __future__ import annotations

import numpy as np


class Wall:
    """cols x rows tiles of tile x tile pixels, and the order they sit in."""

    def __init__(self, tile: int = 64, cols: int = 1, rows: int = 1,
                 order: list[int] | None = None,
                 rotate: list[int] | None = None):
        if tile % 16:
            raise ValueError(f"tile must be a multiple of 16, got {tile}")
        self.tile = int(tile)
        self.cols = int(cols)
        self.rows = int(rows)
        self.width = self.tile * self.cols
        self.height = self.tile * self.rows
        n = self.cols * self.rows
        # The library clocks three ports at once and cannot do a short one, so
        # every port carries the same chain length. That is also why the wall
        # is a rectangle of tiles and not an arrangement.
        if self.width % 32:
            raise ValueError(
                f"the renderer needs a width that is a multiple of 32; "
                f"{self.cols} x {self.tile} is {self.width}")
        self.order = tuple(order) if order else tuple(range(n))
        if sorted(self.order) != list(range(n)):
            raise ValueError(
                f"wall order must be a permutation of 0..{n - 1}, got {list(self.order)}")
        self.rotate = tuple(rotate) if rotate else (0,) * n
        if len(self.rotate) != n or any(r % 90 for r in self.rotate):
            raise ValueError("wall rotate wants one multiple of 90 per tile")
        self._gather = None if self.plain else self._build_gather()

    # ---- shape ----------------------------------------------------------
    @property
    def tiles(self) -> int:
        return self.cols * self.rows

    @property
    def plain(self) -> bool:
        """Nothing to bend: the frame goes to the renderer untouched."""
        return (self.order == tuple(range(self.tiles))
                and not any(r % 360 for r in self.rotate))

    @property
    def ports(self) -> int:
        return self.rows

    @property
    def chain(self) -> int:
        return self.cols

    def __str__(self) -> str:
        s = f"{self.cols}x{self.rows} of {self.tile}px = {self.width}x{self.height}"
        if not self.plain:
            s += " (remapped)"
        return s

    @classmethod
    def from_config(cls, cfg: dict) -> "Wall":
        """[wall] if it is there, otherwise one tile the size of [panel]."""
        panel = cfg.get("panel", {})
        w = int(panel.get("width", 64))
        h = int(panel.get("height", w))
        wall = cfg.get("wall", {})
        tile = int(wall.get("tile", 64 if wall else w))
        cols = int(wall.get("cols", max(1, w // tile)))
        rows = int(wall.get("rows", max(1, h // tile)))

        def nums(key):
            v = wall.get(key)
            if v in (None, "", []):
                return None
            if isinstance(v, str):
                v = [p for p in v.replace(",", " ").split() if p]
            return [int(x) for x in v]

        out = cls(tile=tile, cols=cols, rows=rows,
                  order=nums("order"), rotate=nums("rotate"))
        # [panel] stays the canvas of record, because everything else in the
        # brain sizes itself from it. If the two disagree, say so here rather
        # than letting the sink write frames the renderer will shred.
        if (out.width, out.height) != (w, h):
            raise ValueError(
                f"[panel] says {w}x{h} but [wall] describes {out.width}x{out.height}. "
                f"Set [panel] width and height to {out.width} and {out.height}.")
        return out

    # ---- bending the frame ----------------------------------------------
    def _build_gather(self) -> np.ndarray:
        """For every pixel the renderer will read, which pixel of ours it is.

        Built once as a flat index, so a frame costs one gather instead of
        nine slice copies and nine rotations.
        """
        t = self.tile
        src = np.arange(self.width * self.height, dtype=np.int32).reshape(
            self.height, self.width)
        out = np.empty_like(src)
        for logical, slot in enumerate(self.order):
            ly, lx = divmod(logical, self.cols)
            sy, sx = divmod(slot, self.cols)
            piece = src[ly * t:(ly + 1) * t, lx * t:(lx + 1) * t]
            turns = (self.rotate[logical] // 90) % 4
            if turns:
                piece = np.rot90(piece, -turns)   # clockwise, as a person means it
            out[sy * t:(sy + 1) * t, sx * t:(sx + 1) * t] = piece
        return out.reshape(-1)

    def remap(self, rgb888: bytes) -> bytes:
        """The frame as the renderer wants it, tiles moved and turned."""
        if self._gather is None:
            return rgb888
        arr = np.frombuffer(rgb888, dtype=np.uint8)
        if arr.size != self.width * self.height * 3:
            return rgb888                      # not ours to bend; pass it on
        return arr.reshape(-1, 3)[self._gather].tobytes()

    # ---- talking to a phone that only knows 64 --------------------------
    def phone_view(self, rgb888: bytes, side: int = 64) -> bytes:
        """The wall, scaled down to what the app reads.

        A box average, not a sample: at 3x1 a nearest-neighbour shrink throws
        away eight of every nine LEDs and the app shows a different picture
        from the wall.
        """
        n = self.width * self.height * 3
        if self.width == side and self.height == side:
            return rgb888
        if len(rgb888) != n:
            return rgb888
        arr = np.frombuffer(rgb888, dtype=np.uint8).reshape(
            self.height, self.width, 3)
        if self.width % side == 0 and self.height % side == 0:
            ky, kx = self.height // side, self.width // side
            small = arr.reshape(side, ky, side, kx, 3).mean(axis=(1, 3))
            return small.astype(np.uint8).tobytes()
        from PIL import Image
        return (Image.fromarray(arr, "RGB")
                .resize((side, side), Image.BOX).tobytes())

    def fit(self, px: bytes) -> bytes | None:
        """A square RGB payload from anywhere, at the wall's size.

        The phone draws on 64 squares and always will: a doodle is pixel art
        and one of its pixels becomes a 3x3 block of LEDs, sharp, which is
        the right answer for pixel art and the wrong one for a photograph.
        Photographs arrive from the phone as JPEG through their own paths and
        are resampled properly there.
        """
        want = self.width * self.height * 3
        if len(px) == want:
            return px
        if len(px) % 3:
            return None
        side = int(round((len(px) // 3) ** 0.5))
        if side * side * 3 != len(px) or side < 8:
            return None
        arr = np.frombuffer(px, dtype=np.uint8).reshape(side, side, 3)
        if self.width % side == 0 and self.height % side == 0:
            arr = np.repeat(np.repeat(arr, self.height // side, axis=0),
                            self.width // side, axis=1)
            return arr.tobytes()
        from PIL import Image
        return (Image.fromarray(arr, "RGB")
                .resize((self.width, self.height), Image.NEAREST).tobytes())
