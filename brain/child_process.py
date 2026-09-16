"""Keep a receiver helper tied to the brain, including after a hard restart.

The Pi restarts the brain with SIGKILL, which bypasses normal cleanup. This
small supervisor notices that its parent has gone and terminates its own
native child. It never searches for or kills another build's processes.
"""
import os
import signal
import subprocess
import sys
import time


def main():
    parent = int(sys.argv[1])
    child = subprocess.Popen(sys.argv[2:])
    def stop(*_):
        if child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while child.poll() is None:
        if os.getppid() != parent:
            stop()
        time.sleep(.2)
    raise SystemExit(child.returncode)


if __name__ == '__main__':
    main()
