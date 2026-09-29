#!/usr/bin/env python3
"""Run the seven native UI suites side by side on a pool of simulators.

    .venv/bin/python scripts/qa/run_ui_suites.py --app <Tessera.app> [--sims 3]
        [--suites setup widgets ...] [--out DIR] [--builds DIR] [--whole]

Run one after another on one simulator, the seven test_*_ui.py suites take
over an hour. This runs them at once, one job per simulator at a time:

1. sim_pool.ensure(N) boots N iPhone 17 Pro simulators on iOS 26.5. The first
   is 9108AFCE-..., the others "Tessera QA 2..N". The capture simulator
   (656AFBBD-...) is never used.
2. The app is installed once on each simulator, all at the same time.
3. Each suite's script runs as a job with its own fixture --port and its own
   --build-dir (generated project and derived data, kept in --builds between
   runs so an unchanged test bundle is not rebuilt), so no two jobs share a
   fixture or a build. The longest jobs start first. The setup suite holds
   about two thirds of all the test time, so unless --whole is given its five
   test classes run as five jobs, and the other suites fill in around them.
4. Every test that failed, or never finished because its run died, runs again
   once on its own (--only-testing) on the next free simulator. A test that
   passes then is recorded as flaky, not failed. A test the logs report but
   the source reading did not list is treated the same way. A run that
   produced no results at all (a build or fixture that failed to start) is
   retried once whole instead, and tests that pass only then are listed as
   rerun after an infrastructure failure, not as flaky.
5. DIR/receipt.json gets, per suite, the cases, passed, failed and flaky
   counts and the time its jobs took, then the sha256 of Tessera and
   Tessera.debug.dylib and the total wall time. Every job's receipt, xcodebuild
   log and script log sit beside it in DIR/jobs.

It exits 1 when a test failed on both tries (or a suite could not run). A
flaky test is named in the summary without failing the run, unless --strict
is given. The pool stays booted; sim_pool.py down shuts the extra simulators
down.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

import sim_pool

ROOT = Path(__file__).resolve().parents[2]
QA = ROOT / 'scripts/qa'


@dataclass(frozen=True)
class Suite:
    script: str
    port: int
    sources: tuple  # the Swift folders or files built into the bundle
    target: str     # the bundle's target, the first part of a test id


# The names match the "suites" keys in qa/batch-17/native-interactions.json.
# Each default port is the suite script's own, so a job that gets it starts
# its fixture exactly as a plain run of the script would.
SUITES = {
    'setup': Suite('test_setup_ui.py', 65367, ('setup-uitests',), 'SetupInteractionTests'),
    'widgets': Suite('test_widgets_ui.py', 65369, ('widgets-uitests', 'setup-uitests/SetupHarness.swift'),
                     'WidgetsPageTests'),
    'device_services': Suite('test_device_services_ui.py', 65365, ('device-services-uitests',), 'DeviceInteractionTests'),
    'service_details': Suite('test_service_details_ui.py', 65363, ('service-details-uitests',),
                             'ConnectionsInteractionTests'),
    'connections_arcade': Suite('test_connections_arcade_ui.py', 65361, ('connections-uitests',),
                                'ConnectionsInteractionTests'),
    'party_games': Suite('test_party_games_ui.py', 65359, ('party-uitests',), 'PartyInteractionTests'),
    'motion_games': Suite('test_motion_games_ui.py', 65357, ('uitests',), 'GameInteractionTests'),
}
# The suite whose classes run as separate jobs unless --whole is given.
SPLIT = 'setup'

# Ports for a job whose suite port is already taken, by a second setup class
# or a retry. Odd ports well clear of the suites' own and of 65368, which the
# batch 17 captures use.
SPARE_PORTS = range(65401, 65451, 2)

# Seconds each job took, build included, in the first three-simulator run
# (2026-09-29). Only the order jobs start in comes from these, longest first,
# so a stale figure costs a little wall time, never a result. A job not listed
# counts 15 s per test.
TYPICAL_SECONDS = {
    'setup': 1560,
    'setup/TuningInteractionTests': 460,
    'setup/AboutInteractionTests': 370,
    'setup/ConnectionInteractionTests': 280,
    'setup/SetupInteractionTests': 230,
    'setup/HealthInteractionTests': 220,
    'widgets': 200,
    'service_details': 195,
    'device_services': 155,
    'party_games': 120,
    'connections_arcade': 100,
    'motion_games': 95,
}

CASE = re.compile(r"Test Case '-\[(\w+)\.(\w+) (\w+)\]' (passed|failed) \((\d+(?:\.\d+)?) seconds\)")
# Declarations as the suites write them, with attributes (@MainActor,
# @available(...)) and modifiers in front.
ATTRIBUTES = r'(?:@\w+(?:\([^)]*\))?\s+)*'
CLASS = re.compile(rf'^\s*{ATTRIBUTES}(?:(?:final|public|internal|open|private|fileprivate)\s+)*class\s+(\w+)\s*:')
TEST = re.compile(rf'^\s*{ATTRIBUTES}(?:(?:nonisolated|public|internal|open|final|override)\s+)*func\s+(test\w*)\s*\(\s*\)')
# Looser shapes, to catch a declaration the two above would miss.
LOOSE_TEST = re.compile(r'\bfunc\s+test\w*\s*\(\s*\)')
LOOSE_CLASS = re.compile(r'\bclass\s+\w+\s*:\s*(?:XCTestCase|SetupHarnessCase)\b')


def expected_tests(name):
    """Every test id in a suite, read from its Swift sources: Target/Class/testMethod.

    A test is a method named test... with no parameters, as XCTest finds
    them, in the class declared above it. The shared harness declares none.
    A line that looks like a test or a test class but does not parse stops
    the run, so a test written in a new shape is never silently left out
    (which, with the setup suite split by class, would skip its whole class).
    """
    suite = SUITES[name]
    tests = []
    for source in suite.sources:
        path = QA / source
        files = sorted(path.glob('*.swift')) if path.is_dir() else [path]
        for file in files:
            owner = None
            for number, line in enumerate(file.read_text().splitlines(), start=1):
                if line.lstrip().startswith('//'):
                    continue
                declared = CLASS.match(line)
                if declared:
                    owner = declared.group(1)
                elif LOOSE_CLASS.search(line):
                    raise SystemExit(f'{file.name}:{number}: a test class this script cannot read: {line.strip()}')
                test = TEST.match(line)
                if test and owner:
                    tests.append(f'{suite.target}/{owner}/{test.group(1)}')
                elif LOOSE_TEST.search(line):
                    raise SystemExit(f'{file.name}:{number}: a test this script cannot place: {line.strip()}')
    return tests


@dataclass
class Job:
    suite: str
    label: str        # for logs and the receipt: setup, setup/AboutInteractionTests, ...
    tests: list       # the test ids this job is expected to report
    only: list        # --only-testing values; empty runs the whole suite
    retry: bool = False
    rerun: bool = False  # a retry of a whole job that produced no results
    weight: float = 0
    # Filled in when it runs.
    simulator: str = ''
    port: int = 0
    seconds: float = 0
    returncode: int = None
    passed: dict = field(default_factory=dict)   # test id -> seconds
    failed: dict = field(default_factory=dict)
    files: dict = field(default_factory=dict)


def first_jobs(names, whole):
    """The jobs a run starts with, longest first."""
    jobs = []
    for name in names:
        tests = expected_tests(name)
        if name == SPLIT and not whole:
            classes = []
            for test in tests:
                owner = test.split('/')[1]
                if owner not in classes:
                    classes.append(owner)
            for owner in classes:
                label = f'{name}/{owner}'
                mine = [test for test in tests if test.split('/')[1] == owner]
                jobs.append(Job(name, label, mine, [f'{SUITES[name].target}/{owner}'],
                                weight=TYPICAL_SECONDS.get(label, 15 * len(mine))))
        else:
            jobs.append(Job(name, name, tests, [], weight=TYPICAL_SECONDS.get(name, 15 * len(tests))))
    return sorted(jobs, key=lambda job: -job.weight)


def slug(label):
    return re.sub(r'[^A-Za-z0-9_.-]+', '-', label)


def port_answers(port):
    """True when something already accepts connections on the port."""
    try:
        socket.create_connection(('127.0.0.1', port), timeout=.3).close()
        return True
    except OSError:
        return False


def install(udid, app):
    subprocess.run(['xcrun', 'simctl', 'install', udid, str(app)], check=True, capture_output=True)


def stamp():
    return datetime.datetime.now().strftime('%H:%M:%S')


class Runner:
    def __init__(self, app, simulators, out, builds, timeout):
        self.app = app
        self.simulators = simulators
        self.out = out
        self.builds = builds
        self.timeout = timeout
        self.queue = []
        self.done = []
        self.running = {}         # simulator -> job
        self.ports = set()        # ports held by running jobs
        self.lock = threading.Condition()
        self.processes = set()

    def say(self, text):
        print(f'[{stamp()}] {text}', flush=True)

    def take(self, simulator):
        """The next job for this simulator, or None once nothing is left or can come."""
        with self.lock:
            while True:
                if self.queue:
                    job = self.queue.pop(0)
                    job.simulator = simulator
                    job.port = self.free_port(job.suite)
                    self.ports.add(job.port)
                    self.running[simulator] = job
                    return job
                # A running job can still queue retries, so wait for it.
                if not self.running:
                    return None
                self.lock.wait()

    def free_port(self, suite):
        """The suite's own port when no other job holds it, else a spare one."""
        for port in (SUITES[suite].port, *SPARE_PORTS):
            if port not in self.ports and not port_answers(port):
                return port
        raise RuntimeError('No free fixture port')

    def finish(self, job, retries):
        with self.lock:
            self.ports.discard(job.port)
            del self.running[job.simulator]
            self.done.append(job)
            # Retries join the queue by weight like any job; they are short,
            # so they run as simulators come free near the end.
            self.queue.extend(retries)
            self.queue.sort(key=lambda queued: -queued.weight)
            self.lock.notify_all()

    def run(self, job, slot):
        """Run one job's suite script and read what its log says each test did."""
        suite = SUITES[job.suite]
        name = slug(('retry ' if job.retry else '') + job.label)
        receipt = self.out / 'jobs' / f'{name}.json'
        script_log = self.out / 'jobs' / f'{name}.script.log'
        # One build folder per suite and simulator slot: jobs on one simulator
        # run one at a time, so a folder is never shared by two at once. The
        # folders outlive the run, so the next run (and a retry on the same
        # simulator) only rebuilds the test bundle when its Swift changed.
        build = self.builds / f'{job.suite}-sim{slot}'
        # A log left by an earlier run into the same --out must not be read
        # as this job's.
        for old in (receipt, receipt.with_suffix('.log')):
            old.unlink(missing_ok=True)
        command = [sys.executable, str(QA / suite.script), '--app', str(self.app), '--simulator', job.simulator,
                   '--port', str(job.port), '--build-dir', str(build), '--no-install', '--output', str(receipt)]
        for only in job.only:
            command += ['--only-testing', only]
        self.say(f'sim{slot} {"retry " if job.retry else ""}{job.label} on port {job.port}')
        started = time.monotonic()
        with script_log.open('w') as log:
            # Its own process group, so a timeout stops xcodebuild and the
            # fixture along with the script.
            process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            with self.lock:
                self.processes.add(process)
            try:
                job.returncode = process.wait(timeout=self.timeout)
            except subprocess.TimeoutExpired:
                job.returncode = end(process)
                log.write(f'\nrun_ui_suites.py stopped this job after {self.timeout} s\n')
            finally:
                with self.lock:
                    self.processes.discard(process)
        job.seconds = time.monotonic() - started
        xcode_log = receipt.with_suffix('.log')
        job.files = {'receipt': str(receipt), 'xcodebuild_log': str(xcode_log), 'script_log': str(script_log)}
        text = xcode_log.read_text(errors='replace') if xcode_log.exists() else ''
        for module, owner, method, outcome, seconds in CASE.findall(text):
            test = f'{module}/{owner}/{method}'
            # Should a test be reported twice, its last report counts.
            job.passed.pop(test, None)
            job.failed.pop(test, None)
            (job.passed if outcome == 'passed' else job.failed)[test] = float(seconds)
        missing = [test for test in job.tests if test not in job.passed and test not in job.failed]
        self.say(f'sim{slot} {"retry " if job.retry else ""}{job.label} done in {job.seconds:.0f} s: '
                 f'{len(job.passed)} passed, {len(job.failed)} failed, {len(missing)} without a result')
        return self.retries(job, missing)

    def retries(self, job, missing):
        """The jobs that give this job's failures their one more try."""
        if job.retry:
            return []
        if not job.passed and not job.failed and job.returncode:
            # Nothing ran: most likely the build or the fixture. Try the whole
            # job once more rather than every test on its own.
            return [Job(job.suite, job.label, job.tests, job.only, retry=True, rerun=True, weight=job.weight)]
        # Failures the source reading did not list are retried too.
        again = [test for test in job.tests if test in job.failed or test in missing]
        again += sorted(test for test in job.failed if test not in job.tests)
        # Labelled with the suite, since two suites have a ConnectionsInteractionTests class.
        return [Job(job.suite, f"{job.suite}/{test.split('/', 1)[1]}", [test], [test], retry=True, weight=30)
                for test in again]

    def worker(self, slot, simulator):
        while True:
            job = self.take(simulator)
            if job is None:
                return
            try:
                retries = self.run(job, slot)
            except Exception as error:  # a crashed job must not strand its simulator
                self.say(f'sim{slot} {job.label} could not run: {error}')
                job.returncode = job.returncode if job.returncode is not None else -1
                retries = self.retries(job, list(job.tests))
            self.finish(job, retries)

    def stop(self):
        with self.lock:
            processes = list(self.processes)
        for process in processes:
            end(process)


def end(process, grace=10):
    """Stop a job's process group: SIGTERM first, so the suite script's
    cleanup (fixture, temporary folder) runs, then SIGKILL if it lingers."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break
        try:
            return process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            continue
    return process.wait()


def summarise(names, jobs):
    """Per suite: cases, passed, failed, flaky and time, from the first tries and the retries."""
    suites = {}
    for name in names:
        mine = [job for job in jobs if job.suite == name]
        first = [job for job in mine if not job.retry]
        again = [job for job in mine if job.retry and not job.rerun]
        rerun = [job for job in mine if job.rerun]
        tests = expected_tests(name)
        # Reported by a log but not found in the sources: counted like any
        # other test, and listed so the source reading can be fixed.
        extra = sorted({test for job in mine for test in (*job.passed, *job.failed)} - set(tests))
        everything = tests + extra
        passed_first = {test for job in first for test in job.passed}
        passed_again = {test for job in again for test in job.passed}
        passed_rerun = {test for job in rerun for test in job.passed}
        flaky = sorted(test for test in everything if test not in passed_first and test in passed_again)
        after_infra = sorted(test for test in everything
                             if test not in passed_first and test not in passed_again and test in passed_rerun)
        failed = sorted(test for test in everything
                        if test not in passed_first | passed_again | passed_rerun)
        suites[name] = {
            'cases': len(everything),
            'passed': len(everything) - len(failed),  # flaky tests included
            'passed_first_try': len(passed_first & set(everything)),
            'failed': len(failed),
            'flaky': len(flaky),
            'rerun_after_infrastructure_failure': after_infra,
            'duration_s': round(sum(job.seconds for job in mine), 1),
            'retry_s': round(sum(job.seconds for job in again), 1),
            'failed_tests': failed,
            'flaky_tests': flaky,
            'undeclared_tests': extra,
            'jobs': [{'label': job.label, 'retry': job.retry, 'simulator': job.simulator, 'port': job.port,
                      'seconds': round(job.seconds, 1), 'returncode': job.returncode,
                      'passed': len(job.passed), 'failed': sorted(job.failed), **job.files} for job in mine],
            'test_seconds': {test: seconds for job in first for test, seconds in sorted(job.passed.items())},
        }
    return suites


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, required=True, help='the built Tessera.app for the simulator')
    parser.add_argument('--sims', type=int, default=3, help='how many simulators to run on at once (3 by default)')
    parser.add_argument('--suites', nargs='+', choices=list(SUITES), default=list(SUITES))
    parser.add_argument('--out', type=Path, help='where the receipt and logs go '
                        '(a new folder under the temporary directory by default)')
    parser.add_argument('--builds', type=Path, default=Path(tempfile.gettempdir()) / 'tessera-ui-builds',
                        help='where each suite keeps its generated test project and derived data between runs '
                             '(tessera-ui-builds under the temporary directory by default). One run at a time.')
    parser.add_argument('--whole', action='store_true', help=f'run {SPLIT} as one job instead of one per class')
    parser.add_argument('--job-timeout', type=int, default=45, help='minutes before a job is stopped (45)')
    parser.add_argument('--strict', action='store_true', help='fail the run on a flaky test too')
    a = parser.parse_args()
    app = a.app.resolve()
    if not (app / 'Tessera').exists():
        parser.error(f'{app} is not a built Tessera.app')
    out = a.out or Path(tempfile.gettempdir()) / 'tessera-ui-runs' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    out = out.resolve()
    (out / 'jobs').mkdir(parents=True, exist_ok=True)
    began = time.monotonic()
    started_at = datetime.datetime.now().astimezone().isoformat(timespec='seconds')

    print(f'Pool of {a.sims}, output in {out}', flush=True)
    simulators = sim_pool.ensure(a.sims)
    with ThreadPoolExecutor(max_workers=len(simulators)) as workers:
        list(workers.map(lambda udid: install(udid, app), simulators))
    print(f'Installed on {len(simulators)} simulators in {time.monotonic() - began:.0f} s', flush=True)

    builds = a.builds.resolve()
    builds.mkdir(parents=True, exist_ok=True)
    runner = Runner(app, simulators, out, builds, a.job_timeout * 60)
    runner.queue = first_jobs(a.suites, a.whole)
    threads = [threading.Thread(target=runner.worker, args=(slot, udid), daemon=True)
               for slot, udid in enumerate(simulators, start=1)]

    def stopped(signum, frame):
        raise KeyboardInterrupt
    # A SIGTERM from outside stops the jobs the same way Ctrl-C does; each job
    # runs in its own session, so nothing else would reach them.
    signal.signal(signal.SIGTERM, stopped)
    try:
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
    except KeyboardInterrupt:
        runner.stop()
        raise

    suites = summarise(a.suites, runner.done)
    hashes = {name: hashlib.sha256((app / name).read_bytes()).hexdigest()
              for name in ('Tessera', 'Tessera.debug.dylib') if (app / name).exists()}
    failed = sum(suite['failed'] for suite in suites.values())
    flaky = sum(suite['flaky'] for suite in suites.values())
    receipt = {
        'passed': failed == 0 and not (a.strict and flaky),
        'strict': a.strict,
        'wall_seconds': round(time.monotonic() - began, 1),
        'started': started_at,
        'simulators': simulators,
        'split': None if a.whole else SPLIT,
        'totals': {key: sum(suite[key] for suite in suites.values()) for key in ('cases', 'passed', 'failed', 'flaky')},
        'suites': suites,
        'app': str(app),
        'app_sha256': hashes,
        'scope': 'The seven test_*_ui.py suites, unchanged, run side by side: one job per simulator at a time, '
                 'each with its own loopback fixture port and derived data. Failed tests ran once more on their '
                 'own; one that passed then is flaky, not failed.',
    }
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    for name, suite in suites.items():
        print(f'{name:<20} {suite["passed"]:>3}/{suite["cases"]:<3} passed  {suite["failed"]} failed  '
              f'{suite["flaky"]} flaky  {suite["duration_s"]:>6.0f} s', flush=True)
        for label, tests in (('FAILED', suite['failed_tests']), ('flaky', suite['flaky_tests']),
                             ('rerun after a failed start', suite['rerun_after_infrastructure_failure']),
                             ('not in the sources', suite['undeclared_tests'])):
            for test in tests:
                print(f'    {label}: {test}', flush=True)
    print(f'Wall time {receipt["wall_seconds"] / 60:.1f} min. Receipt: {out / "receipt.json"}', flush=True)
    raise SystemExit(0 if receipt['passed'] else 1)


if __name__ == '__main__':
    main()
