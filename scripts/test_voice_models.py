#!/usr/bin/env python3
"""Compile and exercise production Foundation voice response models."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--json', type=Path, default=Path('qa/batch-08/voice-native-tests.json'))
args = parser.parse_args()
args.json.parent.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='tessera-voice-models-') as directory:
    binary = Path(directory) / 'voice-model-tests'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                    str(root / 'tessera/Tessera/VoiceModels.swift'),
                    str(root / 'scripts/test_voice_models.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(args.json.resolve())], check=True)
