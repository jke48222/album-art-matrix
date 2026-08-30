"""The last nine sleeves, as one frame.

A 3x3 of everything the wall has worn lately: newest first, reading order,
each sleeve reduced to a 20-pixel tile with a one-pixel breath between them.
Slots the journal cannot fill yet stay as faintly-marked empty tiles, so a
young wall reads as a grid filling up, not as a bug.

Art comes through the same fetch cache the main pipeline uses, and the
composition happens in a worker thread: nine fetches can be nine round
trips, and the render loop does not wait on anyone's CDN.
"""
import threading

import numpy as np
from PIL import Image

from .fetch import fetch_art

MARGIN, TILE, GUTTER = 1, 20, 1


def compose(images: list[Image.Image | None], size: int = 64) -> Image.Image:
    canvas = np.zeros((size, size, 3), dtype=np.uint8)
    for slot in range(9):
        row, col = divmod(slot, 3)
        x = MARGIN + col * (TILE + GUTTER)
        y = MARGIN + row * (TILE + GUTTER)
        img = images[slot] if slot < len(images) else None
        if img is None:
            # an empty slot is a place waiting, not a hole: corner ticks
            canvas[y, x] = canvas[y, x + TILE - 1] = (26, 24, 22)
            canvas[y + TILE - 1, x] = (26, 24, 22)
            canvas[y + TILE - 1, x + TILE - 1] = (26, 24, 22)
            continue
        tile = img.convert("RGB").resize((TILE, TILE), Image.LANCZOS)
        canvas[y:y + TILE, x:x + TILE] = np.asarray(tile, dtype=np.uint8)
    return Image.fromarray(canvas, "RGB")


class NineBuilder:
    """Rebuilds the grid when the journal's head moves, off-thread."""

    def __init__(self, size: int = 64):
        self.size = size
        self.frame: Image.Image | None = None
        self.built_for = None        # newest ts the current frame reflects
        self._building = False

    def ask(self, entries: list[dict]):
        """entries: journal rows, newest first."""
        newest = entries[0]["ts"] if entries else None
        if newest == self.built_for or self._building:
            return
        self._building = True

        def work():
            try:
                seen, urls = set(), []
                for e in entries:
                    u = e.get("art_url")
                    if u and u not in seen:
                        seen.add(u)
                        urls.append(u)
                    if len(urls) == 9:
                        break
                images = []
                for u in urls:
                    try:
                        images.append(fetch_art(u))
                    except Exception:
                        images.append(None)
                self.frame = compose(images, self.size)
                self.built_for = newest
            finally:
                self._building = False

        threading.Thread(target=work, daemon=True).start()
