#!/usr/bin/env python3
"""How many frames per second can this machine actually produce?

Refresh rate and frame rate are different numbers and the difference matters
here. The panel library's 9600 Hz is the BCM bit-plane refresh: how fast a row
is rescanned to build colour depth. Frame rate is how often NEW content
reaches the panel, and it is bounded by whatever is slowest of:

    1. producing the frame          (this script measures it)
    2. white balance + tobytes      (measured here too, it is in the loop)
    3. the FIFO write and the renderer's swap
    4. the panel's own ability to show a new frame

This script measures 1 and 2, which are the only parts that run in Python and
the only parts that were ever likely to be the bottleneck. Run it on the Pi to
get the number that matters; the figure from a Mac is an upper bound.

    .venv/bin/python scripts/bench_frames.py
"""
import argparse
import os
import platform
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from PIL import Image

from brain.art.disc import DiscAnimator
from brain.art.effects import Ambient
from brain.art.pipeline import white_balance

GAINS = (1.0, 0.75, 0.55)


def bench(label, fn, seconds=1.5):
    fn()                                     # warm caches
    n, t0 = 0, time.perf_counter()
    while time.perf_counter() - t0 < seconds:
        fn()
        n += 1
    dt = (time.perf_counter() - t0) / n
    print(f"  {label:<34s} {dt * 1000:6.2f} ms/frame   {1 / dt:7.0f} fps")
    return 1 / dt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=64)
    args = ap.parse_args()
    size = args.size

    art = Image.new("RGB", (size, size))
    for y in range(size):                    # a gradient, so nothing optimises away
        for x in range(size):
            art.putpixel((x, y), (x * 4 % 256, y * 4 % 256, (x + y) * 2 % 256))

    print(f"{platform.machine()} · {platform.system()} · panel {size}x{size}")
    print("full pipeline per frame, animation modes only:\n")

    rates = {}
    disc = DiscAnimator(art, size=size)
    rates["cd"] = bench(
        "cd (spinning disc)",
        lambda: white_balance(disc.frame_at(time.monotonic()), GAINS).tobytes(),
    )
    for effect in ("rainbow", "gradient", "breathe", "pulse", "solid"):
        amb = Ambient(size, effect, "#4060ff", "#ff2080", 1.0)
        rates[effect] = bench(
            f"ambient {effect}",
            lambda a=amb: white_balance(a.frame_at(time.monotonic()), GAINS).tobytes(),
        )

    worst_name = min(rates, key=rates.get)
    worst = rates[worst_name]
    print(f"\nslowest mode: {worst_name} at {worst:.0f} fps")
    print(f"a safe [animation] fps with 2x headroom is {int(worst / 2)}")
    print(
        "\nThis bounds the producer only. The panel's own frame ceiling is a\n"
        "separate number and this repository has never measured it."
    )


if __name__ == "__main__":
    main()
