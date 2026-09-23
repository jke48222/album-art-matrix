#!/usr/bin/env python3
"""Verify every literal SF Symbol used by the app exists on the target OS."""
import argparse,json,re,subprocess,tempfile
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--json',type=Path,required=True);args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
names=sorted({name for file in (root/'tessera/Tessera').glob('*.swift') for name in re.findall(r'system(?:Name|Image):\s*"([\w.]+)"',file.read_text())})
with tempfile.TemporaryDirectory(prefix='tessera-symbols-') as temp:
 path=Path(temp);source=path/'main.swift';binary=path/'symbols'
 source.write_text('import UIKit\nlet names: [String] = '+json.dumps(names)+'\nlet missing = names.filter { UIImage(systemName:$0) == nil }\nlet data = try JSONSerialization.data(withJSONObject:["checked":names.count,"passed":names.count-missing.count,"missing":missing],options:[.prettyPrinted,.sortedKeys])\ntry data.write(to: URL(fileURLWithPath:CommandLine.arguments[1]))\nif !missing.isEmpty { exit(1) }\n')
 sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
 subprocess.run(['xcrun','swiftc','-sdk',sdk,'-target','arm64-apple-ios18.0-simulator',str(source),'-o',str(binary)],check=True)
 args.json.parent.mkdir(parents=True,exist_ok=True)
 subprocess.run(['xcrun','simctl','spawn','9108AFCE-E437-42FF-A946-C41349BE6540',str(binary),str(args.json.resolve())],check=True)
 print(args.json.read_text())
