#!/usr/bin/env python3
"""Exercise production UIKit record rendering inside the iOS simulator."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator',default='9108AFCE-E437-42FF-A946-C41349BE6540')
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
    with tempfile.TemporaryDirectory(prefix='tessera-render-') as temp:
        binary=Path(temp)/'record-tests'
        files=[root/'tessera/Tessera'/f for f in ['Record.swift','RecordLabel.swift','RecordLabelStyles.swift']]
        intro=(root/'tessera/Tessera/RoomIntro.swift').read_text()
        extension=Path(temp)/'UIColor.swift'
        extension.write_text('import UIKit\n'+intro[intro.index('extension UIColor {'):intro.index('extension Color {')])
        files.append(extension)
        subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-sdk',sdk,'-target','arm64-apple-ios18.0-simulator',*map(str,files),str(root/'scripts/test_record_render.swift'),'-o',str(binary)],check=True)
        subprocess.run(['xcrun','simctl','spawn',args.simulator,str(binary),str(root),str(args.output.resolve())],check=True)
    return 0
if __name__=='__main__': raise SystemExit(main())
