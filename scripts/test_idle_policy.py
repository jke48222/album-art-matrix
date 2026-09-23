#!/usr/bin/env python3
"""Compile the production quiet-room policy model and verify API compatibility."""
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
    with tempfile.TemporaryDirectory(prefix="tessera-idle-policy-") as folder:
        binary = Path(folder) / "idle-policy"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                        str(root / "tessera/Tessera/IdlePolicy.swift"),
                        str(root / "scripts/test_idle_policy.swift"),
                        "-o", str(binary)], check=True, cwd=root)
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        if result.stderr:
            print(result.stderr, end="")
        report = json.loads(result.stdout)
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(report, indent=2) + "\n")
        print(f"IdlePolicy: {report['passed']} passed, {report['failed']} failed")
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
