#!/usr/bin/env python3
"""Compile and exercise the production Foundation collection and receipt models."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--json', type=Path, default=Path('qa/batch-09/shelf-native-tests.json'))
args = parser.parse_args()
args.json.parent.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='tessera-shelf-') as directory:
    binary = Path(directory) / 'shelf-tests'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                    str(root / 'tessera/Tessera/ShelfModels.swift'),
                    str(root / 'scripts/test_shelf_models.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(args.json.resolve())], check=True)
