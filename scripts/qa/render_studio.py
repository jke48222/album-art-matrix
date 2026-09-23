#!/usr/bin/env python3
"""Render matched lettering through old/new production Swift, without smoothing."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from PIL import Image

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, default=root/'qa/batch-05/renders')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
old = subprocess.check_output(['git','show','09b0baa:tessera/Tessera/Studio.swift'], cwd=root, text=True)
old = old[old.index('@MainActor\n@Observable\nfinal class WallCanvas'):old.index('// MARK: - Kept work')]
old = old.replace('final class WallCanvas', 'final class LegacyWallCanvas')
runner = r'''
import Foundation
@main struct Render {
    @MainActor static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let prior = Panel.side
        defer { Panel.learn(prior) }
        for side in [64, 192, 512] {
            Panel.learn(side)
            let base = [UInt8](repeating: 0, count: side * side * 3)
            let colors: [(UInt8,UInt8,UInt8)] = Array(repeating:(232,176,75),count:4) + Array(repeating:(247,237,220),count:5)
            let layout = LetteringLayout(text:"MAKE\nLIGHT",side:side,size:2)
            let pixels = layout.render(over:base,rgb:(255,255,255),colors:colors)
            try Data(pixels).write(to:folder.appendingPathComponent("lettering-\(side).rgb"))
            let legacy = LegacyWallCanvas()
            legacy.stamp(text:"MAKE\nLIGHT",over:base,rgb:(255,255,255),size:2,colors:colors)
            try Data(legacy.px).write(to:folder.appendingPathComponent("lettering-before-\(side).rgb"))
        }
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tessera-lettering-') as directory:
    folder=Path(directory)
    (folder/'Legacy.swift').write_text('import Foundation\nimport Observation\n'+old)
    (folder/'Render.swift').write_text(runner)
    binary=folder/'render'
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(folder/'Legacy.swift'),str(folder/'Render.swift'),
                    str(root/'tessera/Tessera/LetteringLayout.swift'),str(root/'tessera/Tessera/Panel.swift'),
                    str(root/'tessera/Tessera/PixelFont.swift'),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(args.output.resolve())],check=True)
manifest=[]
for side in [64,192,512]:
    for suffix in ['', '-before']:
        path=args.output/f'lettering{suffix}-{side}.rgb'
        image=Image.frombytes('RGB',(side,side),path.read_bytes())
        image.save(path.with_suffix('.png'))
        manifest.append({'file':path.with_suffix('.png').name,'side':side,'text':'MAKE\nLIGHT','size':2,'source':'09b0baa production WallCanvas' if suffix else 'production LetteringLayout'})
(args.output/'lettering-manifest.json').write_text(json.dumps({'frames':manifest,'inspection':'Native RGB; no smoothing or physical LED colour claim.'},indent=2)+'\n')
print(args.output)
