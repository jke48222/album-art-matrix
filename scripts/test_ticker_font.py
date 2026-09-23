#!/usr/bin/env python3
"""Compile the generated Swift font and compare real normalization to Python."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from brain.art.pixelfont import normalize


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    samples = [
        "", "MEET AT SIX", "I <3 YOU", "❤️A", "♥︎A", "❤❤ <3<3",
        "Cafe\u0301", "가나다", "가나", "Wé♥", "東京 カタカナ",
        "A\r\nB\rC\tD\u00a0E", "ONE\n\nTWO", "A\u200b\u200c\u200d\ufeffB\U000e0100",
        "A\x00B", "A\x1cB", "A\u2028B\u2029C", "A\u2060B",
        "A\ue000B", "A\u0378B", "👩‍🎨 art", "متن", "\t <3 \n",
    ]
    program = r'''
import Foundation
@main
struct FontParity {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let samples = try JSONDecoder().decode([String].self, from: data)
        let output = try JSONEncoder().encode(samples.map(PixelFont.normalize))
        FileHandle.standardOutput.write(output)
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="tessera-font-parity-") as directory:
        folder = Path(directory)
        harness, inputs, executable = folder / "Harness.swift", folder / "inputs.json", folder / "font-parity"
        harness.write_text(program)
        inputs.write_text(json.dumps(samples))
        subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                        str(ROOT / "tessera/Tessera/PixelFont.swift"), str(harness),
                        "-o", str(executable)], check=True)
        swift = json.loads(subprocess.check_output([str(executable), str(inputs)]))
    expected = [normalize(sample) for sample in samples]
    checks = [{"input": sample, "passed": actual == wanted,
               "swift": actual, "python": wanted}
              for sample, actual, wanted in zip(samples, swift, expected)]
    result = {"checks": len(checks), "passed": sum(check["passed"] for check in checks), "cases": checks}
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"{result['passed']}/{result['checks']} Swift/Python font normalization checks passed")
    failures = [check for check in checks if not check["passed"]]
    if failures:
        print(json.dumps(failures, ensure_ascii=False, indent=2))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
