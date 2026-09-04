"""The wall's own ears: a microphone on the Pi, Chromaprint, AcoustID.

For everything that will not say what it is playing (SoundCloud, YouTube, a
record player) but is playing out loud in the room. A background thread
records a few seconds, fingerprints them with fpcalc, and asks AcoustID which
recording that is; the answer stands for a minute and then it listens again.

Needs on the Pi:  apt install libchromaprint-tools alsa-utils (bootstrap does)
Key:              acoustid.org/new-application, set from the phone or
                  [acoustid] api_key in config.toml
Microphone:       "auto" picks the first USB capture device `arecord -l`
                  lists; or name one, e.g. "plughw:1,0"
The key can arrive after start (the phone posts it); the ear starts then.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time

import requests

from . import NowPlaying, NowPlayingSource
from .applemusic import _itunes_art

LOOKUP = "https://api.acoustid.org/v2/lookup"
SECONDS = 12          # AcoustID wants at least ~10 s of audio
HOLD = 60.0           # how long one answer stands before listening again
_CARD = re.compile(r"card (\d+): (\S+) \[(.*?)\], device (\d+):")


def tools_present() -> bool:
    return bool(shutil.which("fpcalc")) and bool(shutil.which("arecord"))


def find_mic():
    """(device, name) of the first USB capture device, else the first one
    at all, else None. `arecord -l` is the list ALSA keeps."""
    try:
        out = subprocess.run(["arecord", "-l"], capture_output=True, text=True,
                             timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    cards = [(f"plughw:{c},{d}", name) for c, _, name, d in _CARD.findall(out)]
    if not cards:
        return None
    usb = [c for c in cards if "usb" in c[1].lower()]
    return (usb or cards)[0]


class AcoustidSource(NowPlayingSource):
    name = "acoustid"

    def __init__(self, api_key: str = "", device: str = "auto"):
        self.api_key = (api_key or "").strip()
        self.device = (device or "").strip() or "auto"
        self._lock = threading.Lock()
        self._hit = None          # (NowPlaying, monotonic)
        self._heard_at = None     # monotonic of the last identification
        self._thread = None
        self._problem = None      # the last thing that went wrong, in words
        if self.api_key:
            self._start()

    # ---- configuration, live -------------------------------------------
    @property
    def configured(self) -> bool:
        return bool(self.api_key)

    def configure(self, api_key=None, device=None):
        if api_key is not None:
            self.api_key = api_key.strip()
        if device is not None:
            self.device = device.strip() or "auto"
        with self._lock:
            self._hit = None
        if self.api_key:
            self._start()

    def _start(self):
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._loop, daemon=True,
                                        name="acoustid")
        self._thread.start()

    def _mic(self):
        if self.device != "auto":
            return self.device
        found = find_mic()
        return found[0] if found else None

    def status(self) -> dict:
        """What the app shows: is there a key, a microphone, the tools, and
        is the ear actually running."""
        mic = find_mic() if tools_present() else None
        with self._lock:
            heard = self._heard_at
        return {
            "key_set": bool(self.api_key),
            "device": self.device,
            "mic": mic[1] if mic else None,
            "tools": tools_present(),
            "listening": bool(self.api_key and self._thread
                              and self._thread.is_alive() and tools_present()
                              and (mic or self.device != "auto")),
            "heard_s": (None if heard is None
                        else int(time.monotonic() - heard)),
            "problem": self._problem,
        }

    # ---- the ear -----------------------------------------------------------
    def _record(self, path, device):
        cmd = ["arecord", "-q", "-D", device, "-f", "S16_LE", "-r", "44100",
               "-c", "1", "-d", str(SECONDS), path]
        subprocess.run(cmd, check=True, capture_output=True, timeout=SECONDS + 10)

    def _fingerprint(self, path):
        out = subprocess.run(["fpcalc", "-json", path], capture_output=True,
                             text=True, timeout=30, check=True).stdout
        d = json.loads(out)
        return d["duration"], d["fingerprint"]

    def _lookup(self, duration, fp):
        resp = requests.get(LOOKUP, params={
            "client": self.api_key, "duration": int(duration), "fingerprint": fp,
            "meta": "recordings+releasegroups+compress",
        }, timeout=15)
        resp.raise_for_status()
        results = resp.json().get("results") or []
        best = max(results, key=lambda r: r.get("score", 0), default=None)
        if not best or best.get("score", 0) < 0.5:
            return None
        recs = best.get("recordings") or []
        rec = next((r for r in recs if r.get("title")), None)
        if not rec:
            return None
        title = rec["title"]
        artist = ", ".join(a.get("name", "") for a in rec.get("artists") or []) or "?"
        groups = rec.get("releasegroups") or []
        album = next((g.get("title") for g in groups if g.get("type") == "Album"), None) \
            or (groups[0].get("title") if groups else "")
        art = None
        if groups:
            art = f"https://coverartarchive.org/release-group/{groups[0]['id']}/front-500"
            try:
                if requests.head(art, timeout=8, allow_redirects=True).status_code != 200:
                    art = None
            except requests.RequestException:
                art = None
        art = art or _itunes_art(f"{artist} {album}", "album") \
            or _itunes_art(f"{artist} {title}", "song")
        return NowPlaying(
            track_id=f"acoustid:{rec.get('id', title)}",
            title=title, artist=artist, album=album or "?", art_url=art,
            progress_ms=None, duration_ms=None, is_playing=True,
        )

    def _loop(self):
        while True:
            if not self.api_key:
                time.sleep(5)
                continue
            if not tools_present():
                self._problem = "fpcalc or arecord missing on the wall"
                time.sleep(60)
                continue
            device = self._mic()
            if not device:
                self._problem = "no microphone found"
                time.sleep(30)
                continue
            try:
                with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as fh:
                    path = fh.name
                try:
                    self._record(path, device)
                    duration, fp = self._fingerprint(path)
                finally:
                    try:
                        os.unlink(path)
                    except OSError:
                        pass
                hit = self._lookup(duration, fp)
                self._problem = None
                with self._lock:
                    if hit is not None:
                        self._hit = (hit, time.monotonic())
                        self._heard_at = time.monotonic()
                    elif self._hit and time.monotonic() - self._hit[1] > HOLD:
                        self._hit = None
                time.sleep(20 if hit is None else HOLD - SECONDS)
            except Exception as exc:
                self._problem = str(exc)[:160]
                print(f"[acoustid] {exc}")
                time.sleep(30)

    def get_current(self):
        with self._lock:
            if self._hit and time.monotonic() - self._hit[1] < HOLD + SECONDS:
                return self._hit[0]
        return None
