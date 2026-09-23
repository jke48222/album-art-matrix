"""Nine most recent distinct sleeves. One composition at every panel size."""
import threading
import time

from PIL import Image, ImageDraw, ImageOps

from .fetch import fetch_art


def compose(images: list[Image.Image | None], size: int = 64) -> Image.Image:
    if size < 16:
        raise ValueError("Nine needs at least 16 pixels per side")
    canvas = Image.new("RGB", (size, size), (8, 10, 10))
    draw = ImageDraw.Draw(canvas)
    gutter = max(1, round(size / 64))
    # Rounded boundaries distribute spare pixels without leaving a short edge.
    edges = [round(i * (size - gutter) / 3) + gutter for i in range(4)]
    for slot in range(9):
        row, col = divmod(slot, 3)
        x, y = edges[col], edges[row]
        w, h = edges[col + 1] - x - gutter, edges[row + 1] - y - gutter
        img = images[slot] if slot < len(images) else None
        if img is not None:
            canvas.paste(ImageOps.fit(img.convert("RGB"), (w, h), Image.Resampling.LANCZOS), (x, y))
        else:
            draw.rectangle((x, y, x + w - 1, y + h - 1), fill=(18, 21, 21))
            arm = max(1, round(size / 32))
            for cx, cy, dx, dy in [(x,y,1,1),(x+w-1,y,-1,1),(x,y+h-1,1,-1),(x+w-1,y+h-1,-1,-1)]:
                draw.line((cx,cy,cx+dx*arm,cy), fill=(47,51,49), width=gutter)
                draw.line((cx,cy,cx,cy+dy*arm), fill=(47,51,49), width=gutter)
    return canvas


class NineBuilder:
    """Coalesces changes while fetching; never publishes a superseded grid."""
    def __init__(self, size: int = 64):
        self.size = size
        self.frame = None
        self.built_for = None
        self._wanted = None
        self._building = False
        self._retry_at = 0
        self._lock = threading.Lock()

    def ask(self, entries: list[dict]):
        urls = tuple(dict.fromkeys(e["art_url"] for e in entries if e.get("art_url")))[:9]
        with self._lock:
            self._wanted = urls
            if self._building or (urls == self.built_for and time.monotonic() < self._retry_at):
                return
            self._building = True
        threading.Thread(target=self._work, name="nine", daemon=True).start()

    def _work(self):
        try:
            while True:
                with self._lock:
                    urls = self._wanted
                images = []
                for url in urls:
                    try:
                        images.append(fetch_art(url))
                    except Exception:
                        images.append(None)
                frame = compose(images, self.size)
                with self._lock:
                    if urls != self._wanted:
                        continue
                    self.frame, self.built_for = frame, urls
                    self._retry_at = time.monotonic() + 30 if any(image is None for image in images) else float("inf")
                    self._building = False
                    return
        except Exception:
            with self._lock:
                self._building = False
            raise
