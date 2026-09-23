#!/usr/bin/env python3
"""Execute the production Foundation model declarations without launching iOS."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def declarations(path: Path, start: str, end: str) -> str:
    source = path.read_text()
    # Slice exact production declarations; never maintain a second test model.
    begin = source.index(start)
    finish = source.index(end, begin)
    return source[begin:finish]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    app = root / "tessera/Tessera"
    model = "import Foundation\n" + "\n".join([
        declarations(app / "WallLink.swift", "struct WallState:", "// MARK: - Session"),
        declarations(app / "Video.swift", "struct WallVideo:", "// MARK: - Talking to the wall"),
        declarations(app / "NowPlayingIdentity.swift", "struct PlaybackIdentity:", "struct NowPlayingIdentity: View"),
    ])
    with tempfile.TemporaryDirectory(prefix="tessera-playback-identity-") as directory:
        directory = Path(directory)
        source = directory / "ProductionModels.swift"
        source.write_text(model)
        binary = directory / "playback-identity-tests"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), str(app / "Panel.swift"),
                        str(root / "scripts/test_playback_identity.swift"), "-o", str(binary)], check=True, cwd=root)
        run = subprocess.run([str(binary)], capture_output=True, text=True, cwd=root)
        if run.stderr:
            print(run.stderr, end="")
        result = json.loads(run.stdout)
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(f"PlaybackIdentity: {result['passed']} passed; {result['failed']} failed")
        return run.returncode


if __name__ == "__main__":
    raise SystemExit(main())
