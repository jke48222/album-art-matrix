#!/usr/bin/env python3
"""Compile the Connection page's models and check every rule they carry.

ConnectionModels.swift (addresses, the four-step check, the page's words)
and LinkRecords.swift (why the wall stopped, the history, the outbox's
names) are Foundation only, so they build on the Mac with the checks in
scripts/test_connection_models.swift, which print a JSON report.
"""
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
    with tempfile.TemporaryDirectory(prefix="tessera-connection-") as folder:
        executable = Path(folder) / "connection-models"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                        str(root / "tessera/Tessera/LinkRecords.swift"),
                        str(root / "tessera/Tessera/ConnectionModels.swift"),
                        str(root / "scripts/test_connection_models.swift"), "-o", str(executable)], check=True)
        result = subprocess.run([str(executable)], capture_output=True, text=True)
        if result.stderr:
            print(result.stderr, end="")
        report = json.loads(result.stdout)
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(report, indent=2) + "\n")
        for entry in report["checks"]:
            if not entry["passed"]:
                print(f"FAILED {entry['name']}: got {entry.get('got')}")
        print(f"Connection models: {report['passed']} passed, {report['failed']} failed")
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
