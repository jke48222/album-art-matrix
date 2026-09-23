#!/usr/bin/env python3
"""Compile and execute the production iPod wheel gesture reducer on macOS."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path, help="Write the complete assertion results to this file")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = root / "tessera/Tessera/IPodWheelInteraction.swift"
    tests = root / "scripts/test_ipod_wheel.swift"
    with tempfile.TemporaryDirectory(prefix="tessera-ipod-wheel-") as directory:
        binary = Path(directory) / "ipod-wheel-tests"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), str(tests),
                        "-o", str(binary)], check=True, cwd=root)
        run = subprocess.run([str(binary)], capture_output=True, text=True, cwd=root)
        if run.stderr:
            print(run.stderr, end="")
        result = json.loads(run.stdout)
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(f"IPodWheelInteraction: {result['passed']} passed; {result['failed']} failed")
        return run.returncode


if __name__ == "__main__":
    raise SystemExit(main())
