"""Send a full-white frame (no white balance) to the configured sink — the
target for WB measurement. Usage:
    .venv/bin/python scripts/show_white.py [--config config.toml] [--sink pi]
"""
import argparse
import os
import sys
import tomllib

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from brain.main import make_sink  # noqa: E402
from PIL import Image  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--config", default="config.toml")
ap.add_argument("--sink", choices=["preview", "pi"])
args = ap.parse_args()

with open(args.config, "rb") as fh:
    cfg = tomllib.load(fh)
size = int(cfg["panel"]["width"])
sink = make_sink(cfg, args.sink)
white = b"\xff" * (size * size * 3)
sink.show(white, pre_wb_img=Image.new("RGB", (size, size), (255, 255, 255)))
print(f"[white] {size}x{size} full-white frame sent — measure now")
