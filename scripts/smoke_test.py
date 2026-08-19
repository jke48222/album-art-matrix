"""Offline smoke test: synthesize a 640x640 'album cover', run the full art
pipeline, write the panel preview plus a pre/post-white-balance comparison.
No network, no Spotify — proves the pipeline before hardware or credentials.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from PIL import Image, ImageDraw  # noqa: E402
import numpy as np  # noqa: E402

from brain.art.pipeline import process, prepare, white_balance  # noqa: E402
from brain.sinks.mac_preview import MacPreviewSink  # noqa: E402

SIZE, PANEL = 640, 64
GAINS = (1.00, 0.75, 0.55)  # research starting point


def fake_cover() -> Image.Image:
    """Sunset gradient + vinyl disc + fine text-like detail: exercises smooth
    ramps (banding), a circle (aliasing) and 1-px detail (downscale mush)."""
    y = np.linspace(0, 1, SIZE)[:, None]
    x = np.linspace(0, 1, SIZE)[None, :]
    r = 0.95 - 0.55 * y + 0.05 * np.sin(6.28 * x)
    g = 0.55 - 0.35 * y + 0 * x
    b = 0.45 + 0.35 * y + 0 * x
    arr = (np.clip(np.stack([r, g, b], -1), 0, 1) * 255).astype(np.uint8)
    img = Image.fromarray(arr)
    d = ImageDraw.Draw(img)
    cx, cy, rad = SIZE // 2, SIZE // 2, 190
    d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=(18, 16, 20))
    for rr in range(60, rad - 8, 14):
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=(45, 42, 50))
    d.ellipse([cx - 34, cy - 34, cx + 34, cy + 34], fill=(220, 80, 60))
    d.ellipse([cx - 6, cy - 6, cx + 6, cy + 6], fill=(0, 0, 0))
    for i, ch in enumerate("ALBUM ART MATRIX"):
        if ch != " ":
            x0 = 40 + i * 34
            d.rectangle([x0, 48, x0 + 22, 78], outline=(255, 255, 255), width=3)
    return img


def main():
    out_dir = "preview_out"
    cover = fake_cover()
    os.makedirs(out_dir, exist_ok=True)
    cover.save(os.path.join(out_dir, "smoke_source.png"))

    pre, frame = process(cover, PANEL, GAINS)
    assert len(frame) == PANEL * PANEL * 3, "frame size wrong"

    MacPreviewSink(out_dir).show(frame, pre_wb_img=pre)

    # Side-by-side: what we send WITHOUT step 4 vs WITH it (panel bytes).
    post = Image.frombytes("RGB", (PANEL, PANEL), frame)
    scale = 6
    combo = Image.new("RGB", (PANEL * scale * 2 + 12, PANEL * scale + 34), (24, 24, 24))
    combo.paste(pre.resize((PANEL * scale,) * 2, Image.NEAREST), (0, 34))
    combo.paste(post.resize((PANEL * scale,) * 2, Image.NEAREST), (PANEL * scale + 12, 34))
    d = ImageDraw.Draw(combo)
    d.text((6, 10), "no white balance (looks right on this screen, cyan on LEDs)", fill=(230, 230, 230))
    d.text((PANEL * scale + 18, 10), "WB R1.00/G0.75/B0.55 (what the panel is fed)", fill=(230, 230, 230))
    combo.save(os.path.join(out_dir, "wb_compare.png"))

    print("smoke test OK:")
    print("  preview_out/smoke_source.png  (synthetic 640x640 cover)")
    print("  preview_out/panel.png         (64x64 as the wall will see it)")
    print("  preview_out/wb_compare.png    (art pipeline step 4, before/after)")


if __name__ == "__main__":
    main()
