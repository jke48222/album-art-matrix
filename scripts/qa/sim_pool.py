#!/usr/bin/env python3
"""Keep a pool of booted iPhone 17 Pro simulators on iOS 26.5 for parallel UI tests.

The first simulator in the pool is the QA simulator every test_*_ui.py script
already defaults to (9108AFCE-...). The others are named "Tessera QA 2" up to
"Tessera QA N". Each is created the first time a pool that size is asked for
and kept afterwards, so a later pool only has to boot, not create. The capture
simulator (656AFBBD-...) is never created, booted, listed or shut down here.

    .venv/bin/python scripts/qa/sim_pool.py up 3      # create and boot three, print their ids
    .venv/bin/python scripts/qa/sim_pool.py list      # every pool simulator and its state
    .venv/bin/python scripts/qa/sim_pool.py down      # shut down all but the first
    .venv/bin/python scripts/qa/sim_pool.py down --keep 2

run_ui_suites.py imports ensure() from here, so it boots the same pool.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import sys
import time

FIRST = '9108AFCE-E437-42FF-A946-C41349BE6540'
# The capture simulator. Captures pin their frames and fixture to it, so the
# pool must never boot, shut down or install onto it.
CAPTURE = '656AFBBD-1ED1-4828-9692-59467A1E70E1'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5'
DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'
NAME = 'Tessera QA {}'


def simctl(*arguments, capture=True):
    """Run one simctl command. Refuses anything that names the capture simulator."""
    if CAPTURE in arguments:
        raise RuntimeError(f'{CAPTURE} is the capture simulator; the pool never touches it')
    result = subprocess.run(['xcrun', 'simctl', *arguments], text=True, capture_output=capture)
    if result.returncode:
        raise RuntimeError(f'simctl {" ".join(arguments)} failed: {(result.stderr or "").strip()}')
    return result.stdout


def devices():
    """Every available device on the iOS 26.5 runtime, by udid."""
    listing = json.loads(simctl('list', 'devices', '--json'))
    return {device['udid']: device for device in listing['devices'].get(RUNTIME, [])
            if device.get('isAvailable', True) and device['udid'] != CAPTURE}


def members(count):
    """The pool's udids in order, creating the missing "Tessera QA k" devices.

    A name is looked up only on the iOS 26.5 runtime and only as an iPhone 17
    Pro, so a same-named device on another runtime is never picked up.
    """
    known = devices()
    if FIRST not in known:
        raise RuntimeError(f'{FIRST} is not an available iOS 26.5 simulator')
    pool = [FIRST]
    for k in range(2, count + 1):
        name = NAME.format(k)
        found = [udid for udid, device in known.items()
                 if device['name'] == name and device['deviceTypeIdentifier'] == DEVICE_TYPE]
        if found:
            pool.append(sorted(found)[0])
        else:
            udid = simctl('create', name, DEVICE_TYPE, RUNTIME).strip()
            print(f'Created {name} ({udid})', file=sys.stderr, flush=True)
            pool.append(udid)
    return pool


def boot(udid):
    """Boot one simulator and wait until it has finished booting.

    bootstatus -b boots it if it is shut down and returns once SpringBoard and
    the data migration are done, which is when xcodebuild can use it. A device
    that is already booted returns at once.
    """
    started = time.monotonic()
    simctl('bootstatus', udid, '-b')
    return time.monotonic() - started


def ensure(count):
    """Create and boot a pool of count simulators and return their udids."""
    if count < 1:
        raise ValueError('A pool has at least one simulator')
    pool = members(count)
    # Boots run side by side: each is mostly waiting on its own launchd.
    with ThreadPoolExecutor(max_workers=len(pool)) as workers:
        seconds = list(workers.map(boot, pool))
    for udid, spent in zip(pool, seconds):
        if spent > 1:
            print(f'Booted {udid} in {spent:.0f} s', file=sys.stderr, flush=True)
    return pool


def number(name):
    """The k in "Tessera QA k", 0 for anything else."""
    tail = name.rsplit(' ', 1)[-1]
    return int(tail) if tail.isdigit() else 0


def listing():
    """Every pool simulator that exists now, first one first, with its state."""
    known = devices()
    rows = []
    if FIRST in known:
        rows.append((FIRST, known[FIRST]['name'], known[FIRST]['state']))
    extras = [(udid, device) for udid, device in known.items()
              if device['name'].startswith(NAME.format('')) and device['deviceTypeIdentifier'] == DEVICE_TYPE]
    # By number, so "Tessera QA 10" comes after "Tessera QA 9".
    extras.sort(key=lambda item: number(item[1]['name']))
    rows += [(udid, device['name'], device['state']) for udid, device in extras]
    return rows


def shut_down(keep):
    """Shut down every pool simulator after the first keep. The devices stay for next time."""
    if keep < 1:
        raise ValueError('The first simulator is shared with every test script; keep at least 1')
    stopped = []
    for udid, name, state in listing()[keep:]:
        if state != 'Shutdown':
            simctl('shutdown', udid)
            stopped.append((udid, name))
    return stopped


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    up = commands.add_parser('up', help='create and boot N simulators, then print their udids')
    up.add_argument('count', type=int)
    commands.add_parser('list', help='print every pool simulator and its state')
    down = commands.add_parser('down', help='shut down the pool simulators after the first --keep')
    down.add_argument('--keep', type=int, default=1)
    a = parser.parse_args()
    if a.command == 'up':
        for udid in ensure(a.count):
            print(udid)
    elif a.command == 'list':
        for udid, name, state in listing():
            print(f'{udid}  {state:<9} {name}')
    else:
        for udid, name in shut_down(a.keep):
            print(f'Shut down {name} ({udid})')


if __name__ == '__main__':
    main()
