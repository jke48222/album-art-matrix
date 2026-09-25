#!/usr/bin/env python3
"""Exercise the actual Foundation model used by the Imagine studio."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--json', type=Path, default=Path('qa/batch-08/imagine-native-tests.json'))
args = parser.parse_args()
args.json.parent.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='tessera-imagine-') as directory:
    binary = Path(directory) / 'imagine-tests'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                    str(root / 'tessera/Tessera/ImagineModels.swift'),
                    str(root / 'scripts/test_imagine_models.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(args.json.resolve())], check=True)
