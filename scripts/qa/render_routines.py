#!/usr/bin/env python3
"""Render real old/new time faces at identical data, without resized source files."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time
from unittest.mock import patch

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from brain.art import text_modes


def load_baseline(root):
    path = root / "brain/art/text_modes.py"
    spec = importlib.util.spec_from_file_location("brain.art._baseline_routines", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module, path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "qa/batch-06/renders")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    old, old_path = load_baseline(args.baseline)
    data = {"local_time": "2026-09-23 07:30:24", "remaining_s": 462,
            "total_s": 600, "ringing_remaining_s": -1.0,
            "color": "#e8b04b", "accent": "#668fc1", "sizes": [64, 192, 512]}
    local = time.struct_time((2026, 9, 23, 7, 30, 24, 2, 266, 1))
    rows = []
    # Only time and the legacy firework RNG are controlled; both sides use
    # their shipping renderer, and native images are never resampled.
    for name in ("clock-24", "clock-12", "timer", "ringing"):
        for side in data["sizes"]:
            outputs = []
            for label, module in (("before", old), ("after", text_modes)):
                with patch("time.localtime", return_value=local), patch("time.monotonic", return_value=1000):
                    if name.startswith("clock"):
                        renderer = module.Clock(side, data["color"], name == "clock-24")
                        img = renderer.frame_at(0)
                    else:
                        renderer = module.Countdown(side, data["color"], data["accent"])
                        if hasattr(renderer, "_rng"):
                            renderer._rng = np.random.default_rng(20260923)
                        img = renderer.frame_at(data["ringing_remaining_s"] if name == "ringing" else data["remaining_s"], data["total_s"])
                destination = args.output / f"{name}-{side}-{label}.png"
                img.save(destination)
                outputs.append(img)
                rows.append({"face": name, "side": side, "version": label,
                             "file": destination.name, "rgb_sha256": hashlib.sha256(img.tobytes()).hexdigest()})
            canvas = Image.new("RGB", (1048, 564), "#101319")
            draw = ImageDraw.Draw(canvas)
            draw.text((12, 12), f"BEFORE / {name} / native {side}px", fill="#f4eddc")
            draw.text((536, 12), f"AFTER / {name} / native {side}px", fill="#f4eddc")
            for x, img in zip((8, 528), outputs):
                canvas.paste(img.resize((512, 512), Image.Resampling.NEAREST), (x, 44))
            canvas.save(args.output / f"{name}-{side}-comparison.png")
    manifest = {"data": data, "native_frames": rows,
                "source_sha256": {"before": hashlib.sha256(old_path.read_bytes()).hexdigest(),
                                   "after": hashlib.sha256((ROOT / "brain/art/text_modes.py").read_bytes()).hexdigest()},
                "note": "Native PNGs are actual production RGB. Comparison PNGs enlarge using nearest-neighbour only; physical LED color requires the panel."}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"native_frames": len(rows), "comparisons": len(rows)//2, "output": str(args.output)}))


if __name__ == "__main__":
    main()
