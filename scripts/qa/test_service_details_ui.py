#!/usr/bin/env python3
"""Drive the installed production app through service setup, recovery and canonical navigation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[2]
SIMULATOR='9108AFCE-E437-42FF-A946-C41349BE6540'

def main():
    p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--output',type=Path,default=ROOT/'qa/batch-14/native-interactions.json');p.add_argument('--simulator',default=SIMULATOR);p.add_argument('--only-testing');a=p.parse_args()
    a.output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='tessera-native-services-') as temporary:
        work=Path(temporary);project=work/'project';project.mkdir()
        spec={'name':'TesseraInteractions','options':{'bundleIdPrefix':'com.jalenedusei.qa'},'settings':{'base':{'IPHONEOS_DEPLOYMENT_TARGET':'18.0','SWIFT_VERSION':'5.0','GENERATE_INFOPLIST_FILE':'YES','CODE_SIGNING_ALLOWED':'NO'}},
              'targets':{'ConnectionsInteractionTests':{'type':'bundle.ui-testing','platform':'iOS','sources':[str(ROOT/'scripts/qa/service-details-uitests')],'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':'com.jalenedusei.qa.games'}}}},
              'schemes':{'ConnectionsInteractionTests':{'build':{'targets':{'ConnectionsInteractionTests':['test']}},'test':{'targets':['ConnectionsInteractionTests']}}}}
        (work/'project.json').write_text(json.dumps(spec))
        subprocess.run(['xcodegen','generate','--spec',str(work/'project.json'),'--project',str(project)],check=True)
        subprocess.run(['xcrun','simctl','install',a.simulator,str(a.app.resolve())],check=True)
        with socket.socket() as probe:
            try:probe.bind(('127.0.0.1',65363))
            except OSError as error:raise RuntimeError('Port65363 is occupied; wait for the previous interaction test to finish') from error
        log=(work/'fixture.log').open('w')
        server=subprocess.Popen([sys.executable,str(ROOT/'scripts/qa/serve_service_details.py')],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
        try:
            for _ in range(50):
                if server.poll() is not None:raise RuntimeError('Fixture failed to start; port65363 must be free')
                try:
                    with socket.create_connection(('127.0.0.1',65363),timeout=.2):break
                except OSError:time.sleep(.1)
            command=['xcodebuild','-project',str(project/'TesseraInteractions.xcodeproj'),'-scheme','ConnectionsInteractionTests','-destination','id='+a.simulator,'-derivedDataPath',str(work/'build'),'-resultBundlePath',str(work/'run.xcresult'),'-collect-test-diagnostics','never','test']
            if a.only_testing:command.append('-only-testing:'+a.only_testing)
            with a.output.with_suffix('.log').open('w') as output:
                result=subprocess.run(command,stdout=output,stderr=subprocess.STDOUT)
            summary=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(work/'run.xcresult'),'--format','json'],text=True,capture_output=True)
            text=a.output.with_suffix('.log').read_text()
            passed=[line.strip() for line in text.splitlines() if "Test Case '-[" in line and " passed (" in line]
            hashes={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in a.app.iterdir() if f.name in ('Tessera','Tessera.debug.dylib')}
            receipt={'passed':result.returncode==0,'cases':passed,'app':str(a.app.resolve()),'app_sha256':hashes,'scope':'Real XCUITest taps and secure text input on production Swift; loopback fixture uses production service field validation and synthetic provider status. No real credential or account writes.',
                     'xcode_summary':json.loads(summary.stdout) if summary.returncode==0 else None}
            a.output.write_text(json.dumps(receipt,indent=2)+'\n')
            print(json.dumps({'passed':receipt['passed'],'cases':len(passed),'receipt':str(a.output)}),flush=True)
            if result.returncode:raise SystemExit(result.returncode)
        finally:
            server.terminate()
            try:server.wait(timeout=5)
            except subprocess.TimeoutExpired:server.kill();server.wait()
            log.close()
if __name__=='__main__':main()
