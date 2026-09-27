#!/usr/bin/env python3
"""Compile the shipped Apple Music permission, URL and delivery models."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='tessera-apple-music-') as directory:
        executable = Path(directory) / 'checks'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                        str(root / 'tessera/Tessera/AppleMusicConnectionModels.swift'),
                        str(root / 'scripts/test_apple_music_connection.swift'), '-o', str(executable)], check=True)
        run = subprocess.run([str(executable)], capture_output=True, text=True, check=True)
        result = json.loads(run.stdout)
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(json.dumps(result, indent=2) + '\n')
        print(f"Apple Music: {result['assertions']} assertions; passed={result['passed']}")
        return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
