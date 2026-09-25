#!/usr/bin/env python3
"""Run production discovery receipt and confidence model checks."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--json', type=Path, default=Path('qa/batch-08/discovery-native-tests.json'))
args = parser.parse_args()
args.json.parent.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='tessera-discovery-') as directory:
    binary = Path(directory) / 'discovery-tests'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                    str(root / 'tessera/Tessera/AskNoteModels.swift'),
                    str(root / 'tessera/Tessera/DiscoveryModels.swift'),
                    str(root / 'scripts/test_discovery.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(args.json.resolve())], check=True)
