#!/usr/bin/env python3
"""Run production media crop/byte rendering and malformed-state checks on iOS."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', default='9108AFCE-E437-42FF-A946-C41349BE6540')
    parser.add_argument('--output', type=Path, default=Path('qa/batch-05/media-tests'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    media = (root/'tessera/Tessera/MediaImport.swift').read_text()
    framing = (root/'tessera/Tessera/Framing.swift').read_text()
    video = (root/'tessera/Tessera/Video.swift').read_text()
    with tempfile.TemporaryDirectory(prefix='tessera-media-tests-') as tmp:
        folder = Path(tmp)
        model = folder/'Models.swift'
        model.write_text('import UIKit\n' + declaration(media, 'struct MediaCrop:') + '\n' +
                         declaration(media, 'enum MediaRaster {') + '\nenum Framing {\n' +
                         declaration(framing, 'static func sample(') + '\n}\n' +
                         declaration(video, 'struct WallVideo:'))
        binary = folder/'media-tests'
        subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-sdk', sdk,
                        '-target', 'arm64-apple-ios18.0-simulator', str(model),
                        '-D', 'DEBUG', str(root/'tessera/Tessera/Panel.swift'), str(root/'tessera/Tessera/MediaQA.swift'), str(root/'tessera/Shared/VideoPicture.swift'), str(root/'scripts/test_media.swift'),
                        '-o', str(binary)], check=True)
        subprocess.run(['xcrun', 'simctl', 'spawn', args.simulator, str(binary), str(args.output.resolve())], check=True)


if __name__ == '__main__': main()
