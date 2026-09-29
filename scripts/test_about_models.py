#!/usr/bin/env python3
"""Compile the About and App design models and check them."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="tessera-about-") as folder:
        executable = Path(folder) / "about-models"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                        str(root / "tessera/Tessera/HomeDesign.swift"),
                        str(root / "tessera/Tessera/AboutModels.swift"),
                        str(root / "tessera/Tessera/WallGrid.swift"),
                        str(root / "scripts/test_about_models.swift"), "-o", str(executable)], check=True)
        result = subprocess.run([str(executable)], capture_output=True, text=True)
        if result.stderr:
            print(result.stderr, end="")
        report = json.loads(result.stdout)
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(report, indent=2) + "\n")
        for check in report["checks"]:
            if not check["passed"]:
                print(f"FAILED: {check['name']}")
        print(f"About models: {report['passed']} passed, {report['failed']} failed")
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
