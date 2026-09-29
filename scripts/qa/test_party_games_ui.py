#!/usr/bin/env python3
"""Drive the installed production app through five games against isolated real rules.

The bundle is scripts/qa/party-uitests against the serve_party_games.py
fixture on 127.0.0.1:65359.
--port moves the fixture and the tests follow it (they read
TESSERA_QA_FIXTURE_PORT). That is how run_ui_suites.py runs all seven
suites side by side, one simulator each.

    .venv/bin/python scripts/qa/test_party_games_ui.py --app <Tessera.app> [--simulator UDID]
        [--port N] [--build-dir DIR] [--no-install] [--only-testing ID ...]
"""
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

ROOT = Path(__file__).resolve().parents[2]
SIMULATOR = '9108AFCE-E437-42FF-A946-C41349BE6540'
PORT = 65359

# party_games_fixtures.py pins Heardle's preview clip to
# http://127.0.0.1:65359/clip.wav. On any other port the fixture is started
# through this shim, which points the clip at the fixture's own port before
# serve_party_games.py builds a game, so the app still fetches the clip from
# this fixture. At 65359 the fixture starts exactly as before.
ON_PORT = """
import runpy, sys
port, script = sys.argv[1], sys.argv[2]
sys.path.insert(0, script.rsplit('/', 1)[0])
import party_games_fixtures
party_games_fixtures.OPTIONS['heardle']['preview'] = f'http://127.0.0.1:{port}/clip.wav'
sys.argv = [script, '--port', port]
runpy.run_path(script, run_name='__main__')
"""


def fixture_command(port):
    script = str(ROOT / 'scripts/qa/serve_party_games.py')
    if port == PORT:
        return [sys.executable, script]
    return [sys.executable, '-c', ON_PORT, str(port), script]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT / 'qa/batch-12/native-interactions.json')
    p.add_argument('--simulator', default=SIMULATOR)
    p.add_argument('--port', type=int, default=PORT, help=f'the fixture port, {PORT} by default')
    p.add_argument('--build-dir', type=Path,
                   help='keep the generated project and derived data here instead of a temporary folder, '
                        'so a later run only rebuilds what changed. One run at a time per folder.')
    p.add_argument('--no-install', action='store_true',
                   help='the app is already installed on this simulator (run_ui_suites.py installs it once)')
    p.add_argument('--only-testing', action='append',
                   help='for example PartyInteractionTests/PartyInteractionTests/testName; repeat for more')
    a = p.parse_args()
    a.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='tessera-native-games-') as temporary:
        work = Path(temporary)
        build = a.build_dir.resolve() if a.build_dir else work
        project = build / 'project'
        project.mkdir(parents=True, exist_ok=True)
        target = 'PartyInteractionTests'
        bundle = {'type': 'bundle.ui-testing', 'platform': 'iOS',
                  'sources': [str(ROOT / 'scripts/qa/party-uitests')],
                  'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'com.jalenedusei.qa.games'}}}
        spec = {'name': 'TesseraInteractions', 'options': {'bundleIdPrefix': 'com.jalenedusei.qa'},
                'settings': {'base': {'IPHONEOS_DEPLOYMENT_TARGET': '18.0', 'SWIFT_VERSION': '5.0',
                                      'GENERATE_INFOPLIST_FILE': 'YES', 'CODE_SIGNING_ALLOWED': 'NO'}},
                'targets': {target: bundle},
                'schemes': {target: {'build': {'targets': {target: ['test']}}, 'test': {'targets': [target]}}}}
        (work / 'project.json').write_text(json.dumps(spec))
        subprocess.run(['xcodegen', 'generate', '--spec', str(work / 'project.json'), '--project', str(project)],
                       check=True)
        if not a.no_install:
            subprocess.run(['xcrun', 'simctl', 'install', a.simulator, str(a.app.resolve())], check=True)
        # Anything already answering on the port would take the tests' calls.
        # A connection, not a bind, is the check: a fixture that just stopped
        # leaves the port in TIME_WAIT, which a bind reports as busy although
        # the next fixture (allow_reuse_address) can listen there at once.
        try:
            socket.create_connection(('127.0.0.1', a.port), timeout=.5).close()
            occupied = True
        except OSError:
            occupied = False
        if occupied:
            raise RuntimeError(f'Port {a.port} is occupied; wait for the previous interaction test to finish '
                               'or pass another --port')
        log = (work / 'fixture.log').open('w')
        server = subprocess.Popen(fixture_command(a.port), cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        try:
            # Up to 30 s: beside other suites the fixture's imports can take
            # longer than on an idle Mac. One that never answers stops here
            # rather than failing every test.
            for _ in range(150):
                if server.poll() is not None:
                    raise RuntimeError(f'Fixture failed to start; port {a.port} must be free')
                try:
                    with socket.create_connection(('127.0.0.1', a.port), timeout=.2):
                        break
                except OSError:
                    time.sleep(.2)
            else:
                raise RuntimeError(f'Fixture did not answer on port {a.port} within 30 s')
            command = ['xcodebuild', '-project', str(project / 'TesseraInteractions.xcodeproj'), '-scheme', target,
                       '-destination', 'id=' + a.simulator, '-derivedDataPath', str(build / 'build'),
                       '-resultBundlePath', str(work / 'run.xcresult'), '-collect-test-diagnostics', 'never', 'test']
            for only in a.only_testing or []:
                command.append('-only-testing:' + only)
            # xcodebuild hands every TEST_RUNNER_<NAME> variable to the test
            # runner as <NAME>. The Swift tests build the fixture address
            # from TESSERA_QA_FIXTURE_PORT.
            environment = dict(os.environ, TEST_RUNNER_TESSERA_QA_FIXTURE_PORT=str(a.port))
            with a.output.with_suffix('.log').open('w') as output:
                result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, env=environment)
            summary = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path',
                                      str(work / 'run.xcresult'), '--format', 'json'], text=True, capture_output=True)
            text = a.output.with_suffix('.log').read_text()
            passed = [line.strip() for line in text.splitlines() if "Test Case '-[" in line and ' passed (' in line]
            failed = [line.strip() for line in text.splitlines() if "Test Case '-[" in line and ' failed (' in line]
            hashes = {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in a.app.iterdir()
                      if f.name in ('Tessera', 'Tessera.debug.dylib')}
            receipt = {'passed': result.returncode == 0, 'cases': passed, 'failed_cases': failed,
                       'app': str(a.app.resolve()), 'app_sha256': hashes,
                       'simulator': a.simulator, 'fixture_port': a.port,
                       'scope': ('Real XCUITest taps/type input on production Swift; local HTTP fixture uses production '
                                'Python game rules. No physical phone or microphone claim.'),
                       'xcode_summary': json.loads(summary.stdout) if summary.returncode == 0 else None}
            a.output.write_text(json.dumps(receipt, indent=2) + '\n')
            print(json.dumps({'passed': receipt['passed'], 'cases': len(passed), 'failed': len(failed),
                              'receipt': str(a.output)}), flush=True)
            if result.returncode:
                raise SystemExit(result.returncode)
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
            log.close()


if __name__ == '__main__':
    main()
