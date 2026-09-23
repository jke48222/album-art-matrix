#!/usr/bin/env python3
"""Compile the production colour parser and scalar constraints, without iOS."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    app = root / "tessera/Tessera"
    colour = (app / "ColourBar.swift").read_text()
    scalar = (app / "WallValueSlider.swift").read_text()
    model = "import Foundation\n" + colour[colour.index("enum WallColourValue"):colour.index("/// Each segment")]
    model += scalar[scalar.index("struct WallSliderScale"):scalar.index("/// A native slider")]
    with tempfile.TemporaryDirectory(prefix="tessera-colour-tests-") as temp:
        temp = Path(temp)
        source = temp / "ProductionControls.swift"
        source.write_text(model)
        binary = temp / "colour-tests"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), str(root / "scripts/test_colour_controls.swift"), "-o", str(binary)], check=True)
        run = subprocess.run([str(binary)], capture_output=True, text=True)
        result = json.loads(run.stdout)
        if run.stderr:
            print(run.stderr, end="")
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(result, indent=2) + "\n")
        print(f"Colour controls: {result['passed']} passed; {result['failed']} failed")
        return run.returncode


if __name__ == "__main__":
    raise SystemExit(main())
