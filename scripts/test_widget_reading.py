#!/usr/bin/env python3
"""Compile the production widget reading, snapshot store and /state mapping, and check every rule."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

SOURCES = ["tessera/Shared/Panel.swift", "tessera/Shared/WallFacts.swift",
           "tessera/Shared/WallSnapshot.swift", "tessera/Shared/WidgetReading.swift",
           "scripts/test_widget_reading.swift"]
# Every string literal on the widget and its page passes the same copy rules
# as the readings.
COPY = ["tessera/Tessera/WidgetsPage.swift", "tessera/Shared/WallWidgetViews.swift",
        "tessera/Shared/WidgetReading.swift", "tessera/TesseraWidgets/TesseraWidgets.swift"]
BANNED = ["\u2014", "\u2013", ";", "\u00b7", "\u00d7"]


def copy_checks(root):
    checks = []
    for name in COPY:
        text = (root / name).read_text()
        literals = [m for m in re.findall(r'"((?:[^"\\\n]|\\.)*)"', text) if re.search(r"[A-Za-z]{3}", m)]
        bad = [m for m in literals if any(b in m for b in BANNED) or "asleep" in m.lower()]
        checks.append({"name": f"copy rules hold in {name} ({len(literals)} strings)", "passed": not bad,
                       **({"detail": " | ".join(bad)} if bad else {})})
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="tessera-widget-reading-") as folder:
        binary = Path(folder) / "widget-reading"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", *[str(root / s) for s in SOURCES],
                        "-o", str(binary)], check=True, cwd=root)
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        if result.stderr:
            print(result.stderr, end="")
        report = json.loads(result.stdout)
        report["checks"] += copy_checks(root)
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
