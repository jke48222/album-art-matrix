"""Render the spinning CD as an animated GIF using the CURRENT Apple Music
art (account tier works even when the Mac is idle). Falls back to the smoke
test's synthetic cover offline.

    .venv/bin/python scripts/spin_demo.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from brain.art.disc import DiscAnimator  # noqa: E402
from brain.art.fetch import fetch_art  # noqa: E402
from brain.art.pipeline import prepare  # noqa: E402
from brain.nowplaying.applemusic import AppleMusicSource  # noqa: E402
from PIL import Image  # noqa: E402

PANEL, SCALE, FPS, SECONDS = 64, 6, 15, 4

out_dir = "preview_out"
os.makedirs(out_dir, exist_ok=True)

art, title = None, "synthetic"
try:
    now = AppleMusicSource().get_current()
    if now and now.art_url:
        art = fetch_art(now.art_url)
        title = f"{now.artist} — {now.title}"
except Exception as exc:
    print(f"[spin] now-playing unavailable ({exc}); using synthetic cover")
if art is None:
    from smoke_test import fake_cover
    art = fake_cover()

pre = prepare(art, PANEL)                     # Lanczos + unsharp, same as the wall
disc = DiscAnimator(pre, PANEL, rpm=7.5)      # 7.5 rpm = 1 rev / 4 bars @ 120 BPM

frames = []
for i in range(FPS * SECONDS):
    f = disc.frame_at(i / FPS)
    frames.append(f.resize((PANEL * SCALE,) * 2, Image.NEAREST))
path = os.path.join(out_dir, "spin.gif")
frames[0].save(path, save_all=True, append_images=frames[1:],
               duration=int(1000 / FPS), loop=0)
print(f"[spin] {title} -> {path} ({len(frames)} frames)")
