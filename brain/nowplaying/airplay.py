"""Add Wall to an AirPlay group and its sleeve follows the exact stream.

The receiver is silent by default. Shairport Sync sends names, artwork and
progress through a private pipe; the wall reads those on a worker and keeps
only the current cover in a temporary directory. Both receiver processes
belong to this build and stop when its feature is switched off. A missing
receiver or timing permission leaves all other music sources working.
"""
import base64
import hashlib
import io
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET

from PIL import Image
from . import NowPlaying, NowPlayingSource

ROOT = Path(__file__).resolve().parents[2]
MAX_ITEM = 8 * 1024 * 1024


class Metadata:
    """The pipe is a stream of XML items, not a single XML document."""
    def __init__(self, callback):
        self.callback = callback
        self.pending = b''

    def feed(self, data):
        self.pending += data
        if len(self.pending) > MAX_ITEM:
            self.pending = b''
            raise ValueError('metadata item too large')
        while b'</item>' in self.pending:
            end = self.pending.index(b'</item>') + 7
            raw, self.pending = self.pending[:end], self.pending[end:]
            start = raw.find(b'<item>')
            if start < 0:
                continue
            try:
                item = ET.fromstring(raw[start:])
                kind = bytes.fromhex(item.findtext('type', '').zfill(8)).decode('ascii')
                code = bytes.fromhex(item.findtext('code', '').zfill(8)).decode('ascii')
                payload = base64.b64decode(''.join(item.findtext('data', '').split()), validate=True)
                if len(payload) != int(item.findtext('length', '0')):
                    raise ValueError('metadata length mismatch')
                self.callback(kind, code, payload)
            except (ET.ParseError, ValueError, UnicodeError) as exc:
                print(f'[airplay] skipped malformed metadata: {type(exc).__name__}', flush=True)


class AirPlaySource(NowPlayingSource):
    name = 'airplay'

    def __init__(self, ctrl, cfg=None, start=True, directory=None, clock=time.monotonic):
        self.ctrl, self.cfg, self.clock = ctrl, cfg or {}, clock
        self.title = self.artist = self.album = ''
        self.playing = False
        self.connected_from = None
        self.progress = None
        self.duration = None
        self.progress_at = self.clock()
        self.last = None
        self.art = None
        self.art_id = None
        self.problem = None
        self.running = False
        self._batch = None
        self._temporary = tempfile.TemporaryDirectory(prefix='matrix-airplay-', dir=directory)
        self.directory = Path(self._temporary.name)
        self.parser = Metadata(self.consume)
        self._processes = []
        self._lock = threading.RLock()
        if start:
            threading.Thread(target=self._work, name='airplay', daemon=True).start()

    def enabled(self):
        return bool(self.ctrl.features and self.ctrl.features.enabled('airplay'))

    def public(self):
        return {'name': 'Wall', 'running': self.running, 'enabled': self.enabled(),
                'connected_from': self.connected_from, 'last': self.last,
                'problem': self.problem, 'output': self.cfg.get('output', 'stdout')}

    def consume(self, kind, code, payload):
        if not self.enabled():
            return
        text = payload.decode(errors='replace').strip() if code != 'PICT' else ''
        with self._lock:
            if kind == 'core' and code in ('minm', 'asar', 'asal'):
                key = {'minm': 'title', 'asar': 'artist', 'asal': 'album'}[code]
                if self._batch is not None:
                    self._batch[key] = text
                else:
                    setattr(self, key, text)
            elif kind == 'ssnc':
                if code == 'mdst':
                    self._batch = {}
                elif code == 'mden' and self._batch is not None:
                    # Commit names together so a new title never borrows the
                    # previous song's artist for one poll.
                    changed = self._batch.get('title', self.title) != self.title
                    for key, value in self._batch.items(): setattr(self, key, value)
                    self._batch = None
                    if changed:
                        self.art, self.art_id = None, None
                elif code == 'PICT':
                    try:
                        image = Image.open(io.BytesIO(payload))
                        if image.width*image.height > 16_000_000:
                            raise ValueError('cover too large')
                        image.thumbnail((1200,1200))
                        buf = io.BytesIO()
                        image.convert('RGB').save(buf, format='JPEG', quality=92)
                        self.art = buf.getvalue()
                        self.art_id = hashlib.sha256(self.art).hexdigest()[:16]
                        path = self.directory/'cover.jpg'
                        path.write_bytes(self.art)
                    except (OSError, ValueError):
                        self.problem = 'Cover could not be read.'
                elif code == 'prgr':
                    try:
                        start, now, end = map(int, text.split('/'))
                        rate = max(8000, min(192000, int(self.cfg.get('sample_rate', 44100))))
                        self.progress = ((now-start) % 2**32)*1000/rate
                        self.duration = ((end-start) % 2**32)*1000/rate
                        self.progress_at = self.clock()
                    except (ValueError, TypeError):
                        self.problem = 'Progress metadata was invalid.'
                elif code in ('pbeg', 'pres', 'prsm', 'pffr'):
                    self.playing = True
                    self.progress_at = self.clock()
                elif code in ('paus', 'pend', 'aend', 'disc'):
                    if self.playing and self.progress is not None:
                        self.progress += (self.clock()-self.progress_at)*1000
                    self.playing = False
                    if code in ('pend', 'aend', 'disc'):
                        self.connected_from = None
                elif code in ('snam', 'clip'):
                    self.connected_from = text
                if code == 'disc':
                    self.title = self.artist = self.album = ''
                    self.art, self.art_id = None, None
            self.last = int(time.time())
        self.ctrl.nudge()

    def get_current(self):
        if not self.enabled() or not self.running:
            return None
        with self._lock:
            if not self.title:
                return None
            ident = hashlib.sha256(f'{self.artist}|{self.title}|{self.album}'.encode()).hexdigest()[:20]
            progress = self.progress
            if progress is not None and self.playing:
                progress += (self.clock()-self.progress_at)*1000
            if progress is not None and self.duration:
                progress = min(progress, self.duration)
            port = int(self.cfg.get('control_port', 8788))
            host = self.cfg.get('host', 'album-matrix.local')
            return NowPlaying('airplay:'+ident, self.title, self.artist, self.album,
                f'http://{host}:{port}/art/airplay.jpg?v={self.art_id}' if self.art else None,
                round(progress) if progress is not None else None,
                round(self.duration) if self.duration is not None else None, self.playing)

    def _start(self):
        for binary in ('nqptp', 'shairport-sync'):
            if not (ROOT/'bin'/binary).exists():
                raise FileNotFoundError('Run pi/install-airplay.sh on the Pi first.')
        pipe = self.directory/'metadata'
        if not pipe.exists(): os.mkfifo(pipe, 0o600)
        output = self.cfg.get('output', 'stdout')
        if output not in ('stdout', 'alsa'):
            raise ValueError('AirPlay output must be stdout or alsa')
        config = self.directory/'shairport.conf'
        config.write_text('general = { name = "Wall"; };\nmetadata = { enabled = "yes"; '
            f'include_cover_art = "yes"; pipe_name = "{pipe}"; }};\n')
        args = [[str(ROOT/'bin/nqptp')], [str(ROOT/'bin/shairport-sync'), '-c', str(config), '-o', output]]
        for command in args:
            proc = subprocess.Popen([sys.executable, '-m', 'brain.child_process', str(os.getpid()), *command],
                cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True)
            self._processes.append(proc)
            time.sleep(.3)
            if proc.poll() is not None:
                raise RuntimeError('Receiver exited. Check nqptp capability and whether ports 319/320 are already in use.')
        self.running, self.problem = True, None
        return os.open(pipe, os.O_RDONLY | os.O_NONBLOCK)

    def _stop(self):
        for proc in self._processes:
            if proc.poll() is None:
                try: os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                try: proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    try: os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
        self._processes.clear()
        self.running, self.playing = False, False
        self.title = self.artist = self.album = ''
        self.art, self.art_id = None, None
        self.parser.pending = b''
        self.connected_from = None
        self.progress, self.duration = None, None
        self._batch = None
        (self.directory/'cover.jpg').unlink(missing_ok=True)
        self.ctrl.nudge()

    def _work(self):
        while True:
            if not self.enabled():
                time.sleep(.5)
                continue
            fd = None
            try:
                fd = self._start()
                while self.enabled():
                    if any(p.poll() is not None for p in self._processes):
                        raise RuntimeError('AirPlay receiver stopped.')
                    ready, _, _ = select.select([fd], [], [], .3)
                    if ready:
                        data = os.read(fd, 65536)
                        if data: self.parser.feed(data)
                        else: time.sleep(.05)
            except (OSError, ValueError, RuntimeError) as exc:
                self.problem = str(exc)[:180]
                print(f'[airplay] {self.problem}', flush=True)
            finally:
                if fd is not None: os.close(fd)
                self._stop()
            time.sleep(3)
