"""The AirPlay receiver itself, run and watched by the brain.

Debian's shairport-sync (trixie, 4.3.7) is a classic AirPlay build, so it
needs no nqptp and no privileged port and runs as the pi user;
pi/install-airplay.sh unpacks it under ~/opt/shairport-sync without root.
The brain starts it with a config of its own: the name the phone chose,
the dummy output (the wall makes no sound; the room's speaker can be in
the same AirPlay group), the metadata pipe brain/nowplaying/airplay.py
reads, cover art on. It restarts the receiver when it stops, with a
growing pause, restarts it when the name changes, stops it when the phone
turns receiving off, and stops it with the brain. A shairport-sync the
system already runs is left alone, and read all the same.
"""
from __future__ import annotations

import atexit
import os
import subprocess
import threading
import time
from collections import deque

CANDIDATES = [os.path.expanduser("~/opt/shairport-sync/root/usr/bin/shairport-sync"),
              "/usr/bin/shairport-sync", "/usr/local/bin/shairport-sync"]
CONF_PATH = os.path.expanduser("~/.config/album-art-matrix/shairport-sync.conf")
PORT = 5000
BACKOFF_S = (2.0, 5.0, 15.0, 60.0)
# lines shairport-sync prints on every start that mean nothing here
QUIET = ("could not acquire a Shairport Sync native D-Bus interface",
         "could not acquire an MPRIS interface", "mqtt ", "convolution", "loudness",
         "interpolation has been chosen")


def find_binary(explicit: str | None = None) -> str | None:
    paths = ([os.path.expanduser(explicit)] if explicit else []) + CANDIDATES
    for p in paths:
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def lib_path(binary: str) -> str:
    """For a binary unpacked from its package (.../root/usr/bin/x), the
    library folders under that root, for LD_LIBRARY_PATH; "" otherwise."""
    root = os.path.dirname(os.path.dirname(os.path.dirname(binary)))
    lib = os.path.join(root, "usr", "lib")
    if not os.path.isdir(lib) or os.path.basename(root) != "root":
        return ""
    dirs = set()
    for dp, _, files in os.walk(lib):
        if any(".so" in f for f in files):
            dirs.add(dp)
    return ":".join(sorted(dirs))


def _quote(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def clean_name(name) -> str:
    s = "".join(ch for ch in str(name or "") if ch.isprintable()).strip()
    return s[:40] or "Wall"


def config_text(name: str, pipe: str, port: int = PORT) -> str:
    return f'''// Written by the wall's brain (brain/nowplaying/receiver.py) each time it
// starts the receiver; edits here are overwritten. Change the name from the
// phone: Settings, Services, AirPlay.
general =
{{
  name = "{_quote(clean_name(name))}";
  output_backend = "dummy";
  port = {int(port)};
  mdns_backend = "avahi";
  interpolation = "soxr";
}};

metadata =
{{
  enabled = "yes";
  include_cover_art = "yes";
  cover_art_cache_directory = "";
  pipe_name = "{_quote(pipe)}";
  pipe_timeout = 5000;
}};

sessioncontrol =
{{
  allow_session_interruption = "yes";
  session_timeout = 20;
}};
'''


def _running_elsewhere(own_pid: int | None) -> bool:
    try:
        out = subprocess.run(["pgrep", "-x", "shairport-sync"], capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return False
    pids = {int(p) for p in out.stdout.split() if p.strip().isdigit()}
    if own_pid is not None:
        pids.discard(own_pid)
    return bool(pids)


class Receiver:
    def __init__(self, pipe: str, settings=None, binary: str | None = None, conf_path: str = CONF_PATH,
                 port: int = PORT, sleep=time.sleep, clock=time.monotonic, elsewhere=None, log=None):
        self.pipe = pipe
        self.settings = settings or (lambda: {})
        self.explicit = binary
        self.conf_path = conf_path
        self.port = port
        self._sleep = sleep
        self._clock = clock
        self._elsewhere = elsewhere or _running_elsewhere
        self.log = log or (lambda s: print(s, flush=True))
        self.proc: subprocess.Popen | None = None
        self.started_at: float | None = None
        self.restarts = 0
        self.lines: deque = deque(maxlen=40)
        self.version: str | None = None
        self.problem: str | None = None
        self.external = False
        self.on = True
        self.name = "Wall"
        self._stopping = False
        self._restart = threading.Event()
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._loop, name="airplay-receiver", daemon=True)

    def start(self) -> "Receiver":
        atexit.register(self.stop)
        self._thread.start()
        return self

    def restart(self):
        self._restart.set()

    def _wanted(self) -> tuple[bool, str]:
        try:
            s = self.settings() or {}
        except Exception:
            s = {}
        return bool(s.get("airplay_receiver", True)), clean_name(s.get("airplay_name") or "Wall")

    # ---- the watch ----------------------------------------------------------------------------
    def _loop(self):
        fails = 0
        while not self._stopping:
            try:
                fails = self._tick(fails)
            except Exception as exc:
                self.problem = f"{type(exc).__name__}: {str(exc)[:160]}"
                self.log(f"[airplay] receiver: {self.problem}")
                self._sleep(5.0)

    def _tick(self, fails: int) -> int:
        on, name = self._wanted()
        proc = self.proc
        if proc is not None:
            code = proc.poll()
            if code is not None:
                self._reaped(code)
                fails += 1
                self._sleep(BACKOFF_S[min(fails - 1, len(BACKOFF_S) - 1)])
                return fails
            if not on or name != self.name or self._restart.is_set():
                self._restart.clear()
                why = "turned off" if not on else "renamed" if name != self.name else "restarting"
                self.log(f"[airplay] receiver {why}")
                self._terminate()
                return 0
            if self.started_at is not None and self._clock() - self.started_at > 60:
                fails = 0
            self._sleep(1.0)
            return fails
        self.on, self.name = on, name
        if not on:
            self.problem = None
            self.external = False
            self._sleep(1.0)
            return 0
        binary = find_binary(self.explicit)
        if binary is None:
            self.problem = "shairport-sync is not installed; run pi/install-airplay.sh on the Pi"
            self._sleep(10.0)
            return fails
        if self._elsewhere(None):
            self.external = True
            self.problem = None
            self._sleep(10.0)
            return fails
        self.external = False
        if self._launch(binary, name):
            return fails
        fails += 1
        self._sleep(BACKOFF_S[min(fails - 1, len(BACKOFF_S) - 1)])
        return fails

    def _env(self, binary: str) -> dict:
        env = dict(os.environ)
        libs = lib_path(binary)
        if libs:
            env["LD_LIBRARY_PATH"] = libs + (":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else "")
        return env

    def _launch(self, binary: str, name: str) -> bool:
        env = self._env(binary)
        if self.version is None:
            try:
                out = subprocess.run([binary, "-V"], capture_output=True, text=True, timeout=5, env=env)
                self.version = (out.stdout or out.stderr).strip().splitlines()[0] if (out.stdout or out.stderr) else None
            except (OSError, subprocess.SubprocessError, IndexError):
                self.version = None
        try:
            os.makedirs(os.path.dirname(self.conf_path), exist_ok=True)
            with open(self.conf_path, "w") as fh:
                fh.write(config_text(name, self.pipe, self.port))
        except OSError as exc:
            self.problem = f"could not write the receiver's config: {exc}"
            return False
        try:
            proc = subprocess.Popen([binary, "-c", self.conf_path], stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, env=env, text=True, bufsize=1)
        except OSError as exc:
            self.problem = f"could not start shairport-sync: {exc}"
            return False
        with self._lock:
            self.proc = proc
            self.started_at = self._clock()
            self.name = name
            self.problem = None
        threading.Thread(target=self._read, args=(proc,), name="airplay-receiver-out", daemon=True).start()
        self.log(f"[airplay] receiver up as {name!r} on port {self.port} (pid {proc.pid})")
        return True

    def _read(self, proc: subprocess.Popen):
        try:
            for line in proc.stdout:
                line = line.rstrip()
                if not line:
                    continue
                self.lines.append(line)
                low = line.lower()
                if any(q.lower() in low for q in QUIET):
                    continue
                if "error" in low or "fatal" in low or "warning" in low or "could not" in low:
                    self.log(f"[airplay] {line.strip()[:200]}")
        except (OSError, ValueError):
            pass

    def _reaped(self, code: int):
        with self._lock:
            self.proc = None
            self.started_at = None
            self.restarts += 1
            tail = " / ".join(list(self.lines)[-2:])
            self.problem = f"shairport-sync stopped (exit {code})" + (f": {tail[:160]}" if tail else "")
        self.log(f"[airplay] {self.problem}")

    def _terminate(self):
        with self._lock:
            proc, self.proc = self.proc, None
            self.started_at = None
        if proc is None:
            return
        try:
            proc.terminate()
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        except OSError:
            pass

    def stop(self):
        self._stopping = True
        self._terminate()

    # ---- for the phone ------------------------------------------------------------------------
    def status(self) -> dict:
        binary = find_binary(self.explicit)
        proc = self.proc
        running = proc is not None and proc.poll() is None
        return {"installed": binary is not None, "binary": binary, "version": self.version,
                "on": self.on, "name": self.name, "port": self.port, "running": running,
                "pid": proc.pid if running else None,
                "up_s": int(self._clock() - self.started_at) if running and self.started_at else None,
                "restarts": self.restarts, "external": self.external, "problem": self.problem}
