#!/usr/bin/env python3
"""Render each Tessera sting to MP4.

The stings are CSS animations in the render pages logos.py writes. Playwright
drives the installed Chrome, pauses every animation on the page and seeks it
to each frame's time, so the video is exactly what the board plays, at 30 fps
and 1920 x 1080, with nothing depending on wall-clock timing. ffmpeg encodes
the frames and concatenates the six into a reel.

    python3 tessera/Tools/logos_video.py [frames dir]
"""
import os
import subprocess
import sys
import tempfile

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
LOGOS = os.path.join(HERE, "..", "Design", "Logos")
RENDER = os.path.join(LOGOS, "render")
VIDEO = os.path.join(LOGOS, "video")
FPS, DUR = 30, 4.5                       # seconds per sting, hold included
SLUGS = ["emitter", "mosaic", "record", "handset", "triad", "cover"]
STORY_T = [0.3, 0.7, 1.1, 1.6, 2.4]      # frames the storyboard shows
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def main():
    frames_root = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="tessera-frames-")
    os.makedirs(VIDEO, exist_ok=True)
    story = []
    with sync_playwright() as pw:
        try:
            browser = pw.chromium.launch(channel="chrome")
        except Exception:
            browser = pw.chromium.launch(executable_path=CHROME)
        page = browser.new_page(viewport={"width": 1920, "height": 1080}, device_scale_factor=1)
        for slug in SLUGS:
            page.goto("file://" + os.path.abspath(os.path.join(RENDER, slug + ".html")))
            n = page.evaluate("document.getAnimations().length")
            fdir = os.path.join(frames_root, slug)
            os.makedirs(fdir, exist_ok=True)
            total = int(DUR * FPS)
            for f in range(total):
                t = f / FPS * 1000
                page.evaluate("t => document.getAnimations().forEach(a => { a.pause(); a.currentTime = t; })", t)
                page.screenshot(path=os.path.join(fdir, f"{f:04d}.png"))
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", str(FPS),
                            "-i", os.path.join(fdir, "%04d.png"), "-c:v", "libx264",
                            "-pix_fmt", "yuv420p", "-crf", "18", "-movflags", "+faststart",
                            os.path.join(VIDEO, slug + ".mp4")], check=True)
            story.append([Image.open(os.path.join(fdir, f"{int(t * FPS):04d}.png")).convert("RGB")
                          for t in STORY_T])
            print(f"{slug}: {n} animations, {total} frames")
        browser.close()
    lst = os.path.join(frames_root, "reel.txt")
    with open(lst, "w") as fh:
        fh.write("".join(f"file '{os.path.abspath(os.path.join(VIDEO, s + '.mp4'))}'\n" for s in SLUGS))
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst,
                    "-c", "copy", os.path.join(VIDEO, "tessera-stings-reel.mp4")], check=True)
    W, H = 600, 338
    board = Image.new("RGB", (W * len(STORY_T), H * len(SLUGS)), (11, 10, 9))
    for r, row in enumerate(story):
        for c, im in enumerate(row):
            board.paste(im.resize((W, H), Image.LANCZOS), (c * W, r * H))
    board.save(os.path.join(VIDEO, "storyboard.png"))
    print("wrote", VIDEO)


if __name__ == "__main__":
    main()
