#!/usr/bin/env python3
"""Exercise the production Foundation countdown and Ask/Note API response model."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--json', type=Path, default=Path('qa/batch-07/ask-notes-native-tests.json'))
args = parser.parse_args()
args.json.parent.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='tessera-ask-notes-') as directory:
    binary = Path(directory) / 'message-tests'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                    str(root / 'tessera/Tessera/AskNoteModels.swift'),
                    str(root / 'scripts/test_ask_notes.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(args.json.resolve())], check=True)
