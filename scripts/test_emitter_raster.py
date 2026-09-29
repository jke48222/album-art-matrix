#!/usr/bin/env python3
"""Compile Shared/EmitterRaster.swift and hold it to the pre-refactor EmitterTile raster, byte for byte.

EmitterTile.render (tessera/Tessera/Archive.swift before batch 17) is UIKit and
iOS only, so its loop is ported here: a 4 x 4 supersampled circle mask of
radius 0.35 cell, lit when any channel is 8 or more, unlit at 12.75, duty
clamped to 0.05...1 and applied to lit emitters only, and UInt8 truncation.
The capture_home artwork is rastered by both at 64@8, 64@3, 192@3 and 192@4,
at duty 1 and 0.55, and every byte must match.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/qa"))
from capture_home import artwork  # noqa: E402

SOURCES = ["tessera/Shared/Panel.swift", "tessera/Shared/EmitterRaster.swift", "scripts/test_emitter_raster.swift"]


def mask(cell):
    r = cell * 0.35
    mid = cell / 2
    ss = 4
    m = np.zeros((cell, cell))
    for y in range(cell):
        for x in range(cell):
            hit = 0
            for sy in range(ss):
                for sx in range(ss):
                    dx = x + (sx + 0.5) / ss - mid
                    dy = y + (sy + 0.5) / ss - mid
                    if dx * dx + dy * dy <= r * r:
                        hit += 1
            m[y, x] = hit / (ss * ss)
    return m


def legacy_tile(px: bytes, cell: int, duty: float) -> bytes:
    """The pre-refactor EmitterTile.render loop, as RGBX bytes."""
    n = int(round((len(px) // 3) ** 0.5))
    cell = max(1, min(cell, 768 // n))
    d = max(0.05, min(1.0, duty))
    arr = np.frombuffer(px, np.uint8).reshape(n, n, 3).astype(np.float64)
    lit = (arr >= 8).any(axis=2)
    emit = np.where(lit[..., None], arr * d, 12.75)
    m = mask(cell)
    big = emit[:, None, :, None, :] * m[None, :, None, :, None]
    out = np.floor(np.minimum(255.0, big)).astype(np.uint8).reshape(n * cell, n * cell, 3)
    rgba = np.full((n * cell, n * cell, 4), 255, np.uint8)
    rgba[..., :3] = out
    return rgba.tobytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="tessera-emitter-raster-") as folder:
        work = Path(folder)
        binary = work / "emitter-raster"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", *[str(ROOT / s) for s in SOURCES],
                        "-o", str(binary)], check=True, cwd=ROOT)
        sources = {"artwork64": artwork(64), "artwork192": artwork(192)}
        for name, px in sources.items():
            (work / f"{name}.raw").write_bytes(px)
        result = subprocess.run([str(binary), str(work)], capture_output=True, text=True)
        if result.stderr:
            print(result.stderr, end="")
        report = json.loads(result.stdout)
        golden = {}
        for name, cells in (("artwork64", (8, 3)), ("artwork192", (3, 4))):
            for cell in cells:
                for duty in (1.0, 0.55):
                    case = f"{name}-c{cell}-d{int(duty * 100)}"
                    swift = (work / f"{case}.rgba").read_bytes()
                    expected = legacy_tile(sources[name], cell, duty)
                    same = swift == expected
                    golden[case] = hashlib.sha256(expected).hexdigest()
                    detail = "" if same else f"{sum(a != b for a, b in zip(swift, expected))} bytes differ"
                    report["checks"].append({"name": f"matches the pre-refactor EmitterTile: {case}",
                                             "passed": same, **({"detail": detail} if detail else {})})
        report["golden_sha256"] = golden
        report["failed"] = sum(1 for c in report["checks"] if not c["passed"])
        report["passed"] = len(report["checks"]) - report["failed"]
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(report, indent=2) + "\n")
        for check in report["checks"]:
            if not check["passed"]:
                print("FAILED", check["name"], check.get("detail", ""))
        print(json.dumps({"suite": report["suite"], "passed": report["passed"], "failed": report["failed"]}))
        return 1 if report["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
