#!/usr/bin/env python3
"""Compile the production Wall health model and check every rule and sentence.

The Swift checks read scripts/qa/health_fixtures.json, the readings the QA wall
serves, and compare them with the copy compiled into the app for captures
(HealthFixtures in WallVitals.swift). --write-fixtures rewrites that copy from
the JSON file, so the two are never edited by hand.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "tessera/Tessera/WallVitals.swift"
FIXTURES = ROOT / "scripts/qa/health_fixtures.json"
BEGIN = "    // BEGIN health_fixtures.json\n"
END = "    // END health_fixtures.json\n"


def write_fixtures():
    """One preset a line, minified, inside a raw string the model parses."""
    presets = json.loads(FIXTURES.read_text())
    lines = [f"    {json.dumps(name)}:{json.dumps(body, separators=(',', ':'))}" for name, body in presets.items()]
    block = (BEGIN
             + "    static let names = [" + ", ".join(json.dumps(name) for name in presets) + "]\n\n"
             + '    private static let source = #"""\n    {\n' + ",\n".join(lines) + '\n    }\n    """#\n'
             + END)
    source = MODEL.read_text()
    start, stop = source.index(BEGIN), source.index(END) + len(END)
    MODEL.write_text(source[:start] + block + source[stop:])
    print(f"Wrote {len(presets)} presets into {MODEL.relative_to(ROOT)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--write-fixtures", action="store_true")
    args = parser.parse_args()
    if args.write_fixtures:
        write_fixtures()
    with tempfile.TemporaryDirectory(prefix="tessera-vitals-") as folder:
        executable = Path(folder) / "wall-vitals"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-D", "DEBUG", str(MODEL),
                        str(ROOT / "scripts/test_wall_vitals.swift"), "-o", str(executable)], check=True)
        result = subprocess.run([str(executable), str(FIXTURES)], capture_output=True, text=True)
        if result.stderr:
            print(result.stderr, end="")
        report = json.loads(result.stdout)
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(report, indent=2) + "\n")
        for failed in (c for c in report["checks"] if not c["passed"]):
            print(f"FAILED: {failed['name']} {failed.get('detail', '')}".rstrip())
        print(f"Wall vitals: {report['passed']} passed, {report['failed']} failed")
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
