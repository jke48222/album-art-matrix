"""A found sleeve gets eight quiet seconds on the wall, with its name.

One result gives the artwork most of the panel and moves the title through
the strip below it. Two uncertain results sit together on the larger wall;
the 64-pixel wall alternates them because two thumbnail labels cannot be
read at arm's length. Images are prepared before this face reaches the
render loop, so every frame is array arithmetic and cached type.
"""
import numpy as np
from PIL import Image

from .pipeline import prepare
from .pixelfont import draw_text, normalize, text_width

DURATION = 8.0
INK = (236, 231, 220)


class ResultFace:
    def __init__(self, size, items):
        if not items or len(items) > 2:
            raise ValueError("a result face needs one or two items")
        self.size = size
        self.items = items
        self.frames = [self._prepare(item) for item in items]

    def _prepare(self, item):
        art = item["image"].convert("RGB")
        if len(self.items) == 2 and self.size >= 128:
            side = (self.size - 12) // 2
        else:
            side = self.size - (12 if self.size < 128 else 36)
        return prepare(art, side)

    def _single(self, index, t):
        canvas = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        art = np.asarray(self.frames[index])
        side = art.shape[0]
        x = (self.size - side) // 2
        canvas[:side, x:x + side] = art
        scale = 1 if self.size < 128 else 3
        label = normalize(f"{self.items[index]['title']}  {self.items[index]['artist']}")
        width = text_width(label, scale)
        speed = 12 if self.size < 128 else 30
        offset = int(t * speed) % max(1, width + self.size)
        draw_text(canvas, label, self.size - offset,
                  self.size - 7 * scale - (1 if self.size < 128 else 7), INK, scale)
        return canvas

    def frame_at(self, t):
        if len(self.items) == 1 or self.size < 128:
            return self._single(0 if len(self.items) == 1 else int(t // 2) % 2, t)
        canvas = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        scale = 2
        side = self.frames[0].width
        for index, image in enumerate(self.frames):
            x = 4 + index * (side + 4)
            canvas[16:16 + side, x:x + side] = np.asarray(image)
            label = normalize(self.items[index]["title"])
            while text_width(label, scale) > side and len(label) > 1:
                label = label[:-1]
            draw_text(canvas, label, x + max(0, (side - text_width(label, scale)) // 2),
                      16 + side + 7, INK, scale)
        return canvas
