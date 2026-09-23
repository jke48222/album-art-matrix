#!/usr/bin/env python3
"""Compile and test Tessera's production archive, listening and pressing models."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def portion(path, start, end):
    text = path.read_text()
    return text[text.index(start):text.index(end, text.index(start))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    app = root / 'tessera/Tessera'
    sources = 'import Foundation\n' + '\n'.join([
        portion(app/'WornStats.swift', 'struct WornStats {', '// MARK: - The band'),
        portion(app/'Sleeve.swift', 'enum SleeveMatch {', 'extension UIImage'),
        portion(app/'Record.swift', 'struct Pressing: Equatable {', '    static func make(') + '\n}',
        portion(app/'RecordLabelStyles.swift', 'enum LabelStyle:', 'extension RecordLabel'),
        portion(app/'PressingStore.swift', 'struct PressingChoice:', '/// A pressing kept'),
    ])
    with tempfile.TemporaryDirectory(prefix='tessera-archive-') as directory:
        directory = Path(directory)
        models = directory/'Models.swift'; models.write_text(sources)
        binary = directory/'tests'
        subprocess.run(['xcrun','swiftc','-parse-as-library',str(models),str(app/'ArchiveModels.swift'),
                        str(app/'ListeningClock.swift'),str(root/'scripts/test_archive.swift'),'-o',str(binary)],check=True)
        result = subprocess.run([str(binary)],capture_output=True,text=True)
        if result.stderr: print(result.stderr,end='')
        report=json.loads(result.stdout)
        if args.json:
            args.json.parent.mkdir(parents=True,exist_ok=True)
            args.json.write_text(json.dumps(report,indent=2)+'\n')
        print(f"Archive, listening, pressing: {report['passed']} passed, {report['failed']} failed")
        return result.returncode

if __name__ == '__main__': raise SystemExit(main())
