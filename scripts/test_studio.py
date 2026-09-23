#!/usr/bin/env python3
"""Compile and exercise the actual canvas model, including 192-pixel edges."""
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
source=(root/'tessera/Tessera/Studio.swift').read_text()
model=source[source.index('@MainActor\n@Observable\nfinal class WallCanvas'):source.index('// MARK: - Kept work')]
with tempfile.TemporaryDirectory(prefix='tessera-studio-') as tmp:
    folder=Path(tmp)
    (folder/'Canvas.swift').write_text('import Foundation\nimport Observation\n'+model)
    binary=folder/'studio-tests'
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(folder/'Canvas.swift'),str(root/'tessera/Tessera/Panel.swift'),str(root/'tessera/Tessera/PixelFont.swift'),str(root/'scripts/test_studio.swift'),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(root/'qa/batch-04/studio-tests.json')],check=True)
