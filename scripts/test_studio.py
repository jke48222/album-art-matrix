#!/usr/bin/env python3
"""Compile and exercise the actual canvas model, including 192-pixel edges."""
from pathlib import Path
import subprocess
import tempfile
import argparse
import shutil

parser=argparse.ArgumentParser()
parser.add_argument('--json',type=Path,default=Path('qa/batch-05/studio-tests.json'))
args=parser.parse_args()
args.json.parent.mkdir(parents=True,exist_ok=True)
root=Path(__file__).resolve().parents[1]
source=(root/'tessera/Tessera/Studio.swift').read_text()
model=source[source.index('@MainActor\n@Observable\nfinal class WallCanvas'):source.index('// MARK: - Kept work')]
with tempfile.TemporaryDirectory(prefix='tessera-studio-') as tmp:
    folder=Path(tmp)
    (folder/'Canvas.swift').write_text('import Foundation\nimport Observation\n'+model)
    binary=folder/'studio-tests'
    for font in ['World7.bin','Hangul7.bin']:
        shutil.copy2(root/'tessera/Tessera'/font,folder/font)
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(folder/'Canvas.swift'),str(root/'tessera/Tessera/Panel.swift'),str(root/'tessera/Tessera/PixelFont.swift'),str(root/'tessera/Tessera/LetteringLayout.swift'),str(root/'tessera/Tessera/MadeStore.swift'),str(root/'scripts/test_studio.swift'),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(args.json.resolve())],check=True)
