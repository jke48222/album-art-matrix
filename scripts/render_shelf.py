"""Render the shelf ownership mark on photographic sleeves at both sizes."""
from pathlib import Path

import numpy as np
from PIL import Image

from brain.art.pipeline import shelf_overlay
from brain.sinks.mac_preview import MacPreviewSink


def sleeve(size):
    y, x = np.mgrid[:size, :size]
    frame = np.zeros((size, size, 3), dtype=np.uint8)
    frame[..., 0] = 28 + (x * 92 // size)
    frame[..., 1] = 38 + (y * 66 // size)
    frame[..., 2] = 60 + ((x + y) * 55 // (2 * size))
    frame[size // 6:5 * size // 6, size // 3:2 * size // 3] = (188, 92, 50)
    return Image.fromarray(frame)


def main():
    root = Path("docs/verification/shelf")
    root.mkdir(parents=True, exist_ok=True)
    for size in (64, 192):
        base = sleeve(size)
        marked = shelf_overlay(base, "#f0e8d8")
        marked.save(root / f"owned-{size}.png")
        sink = MacPreviewSink(str(root / f"owned-{size}-preview"),
                              scale=8 if size == 64 else 4)
        sink.show(marked.tobytes(), pre_wb_img=marked)
    print("[shelf] ownership mark rendered at 64 and 192")


if __name__ == "__main__":
    main()
