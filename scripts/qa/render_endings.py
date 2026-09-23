#!/usr/bin/env python3
"""Matched native RGB from the previous and current production timer faces."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import types

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from brain.art.text_modes import Countdown


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline-ref", default="cb5acad")
    parser.add_argument("--output", type=Path, default=ROOT / "qa/batch-07/endings")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    source = subprocess.run(["git", "show", f"{args.baseline_ref}:brain/art/text_modes.py"],
                            cwd=ROOT, check=True, capture_output=True, text=True).stdout
    old = types.ModuleType("brain.art._baseline_endings")
    old.__package__ = "brain.art"
    exec(compile(source, "baseline_text_modes.py", "exec"), old.__dict__)
    cases = (("timer-complete", "countdown", False, -2.5, 600),
             ("alarm-ringing", "alarm", False, -2.5, 60),
             ("alarm-snoozed", "alarm", True, 300, 300))
    rows = []
    for name, kind, snoozed, remaining, total in cases:
        for side in (64, 192, 512):
            before = old.Countdown(side, "#e8b04b", "#668fc1").frame_at(remaining, total)
            after = Countdown(side, "#e8b04b", "#668fc1").frame_at(remaining, total, kind, snoozed)
            canvas = Image.new("RGB", (1048, 564), "#101319")
            draw = ImageDraw.Draw(canvas)
            for x, version, image in ((8, "before", before), (528, "after", after)):
                path = args.output / f"{name}-{side}-{version}.png"
                image.save(path)
                rows.append({"case": name, "side": side, "version": version, "file": path.name,
                             "kind": kind, "snoozed": snoozed, "remaining_s": remaining, "total_s": total,
                             "rgb_sha256": hashlib.sha256(image.tobytes()).hexdigest()})
                draw.text((x+4, 12), f"{version.upper()} / {name} / native {side}px", fill="#f4eddc")
                canvas.paste(image.resize((512, 512), Image.Resampling.NEAREST), (x, 44))
            canvas.save(args.output / f"{name}-{side}-comparison.png")
        if remaining < 0:
            renderer = Countdown(64)
            frames = [renderer.frame_at(-t/10, total, kind).resize((384, 384), Image.Resampling.NEAREST)
                      for t in range(120)]
            frames[0].save(args.output / f"{name}-motion.gif", save_all=True, append_images=frames[1:],
                           duration=100, loop=0, disposal=2)
    manifest = {"baseline_ref": args.baseline_ref, "native_frames": rows,
                "source_sha256": {"before": hashlib.sha256(source.encode()).hexdigest(),
                                  "after": hashlib.sha256((ROOT / "brain/art/text_modes.py").read_bytes()).hexdigest()},
                "limits": "Native RGB matches production rendering. Comparisons use nearest-neighbour enlargement. Physical LED color requires panel inspection. The previous renderer had no distinct alarm or snooze composition."}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"native_frames": len(rows), "comparisons": len(rows)//2, "motion_gifs": 2}))


if __name__ == "__main__":
    main()
