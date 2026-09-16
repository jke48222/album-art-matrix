"""Teach the wall the records its online recognizer has never heard of.

When another player names a song, the wall can learn twenty seconds of the
room, or fetch a short catalogue preview after three failed recognitions.
Only fingerprints and the song's name remain. The next time that recording
plays, the wall tries its small library before asking Shazam. The Hearing
page lists every taught song and can forget one or erase the whole library.

Olaf's native C core extracts and matches the fingerprints. Audio is piped
through standard input and never written to disk. An extra native helper
removes a song's cached fingerprint hashes, so deletion needs no recording.
Both binaries are built by pi/install-olaf.sh from a pinned AGPL revision.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import time
from dataclasses import asdict

import numpy as np
import requests

from .nowplaying import NowPlaying
from .scrobble import atomic_json, song_key

RATE = 16000
LEARN_SECONDS = 20
PREVIEW_LIMIT = 6_000_000
ITUNES = "https://itunes.apple.com/search"
BIN = Path(__file__).resolve().parent.parent / "bin" / "olaf"


def fingerprint_id(track):
    return hashlib.sha256(song_key(track).encode()).hexdigest()[:24]


def raw_float(pcm):
    return (np.frombuffer(pcm, dtype='<i2').astype('<f4') / 32768).tobytes()


def parse_matches(text):
    result = []
    for row in csv.reader(io.StringIO(text), skipinitialspace=True):
        if len(row) < 7:
            continue
        try:
            score = int(row[0])
            if score <= 0:
                continue
            result.append({"score": score, "id": str(int(row[-3])),
                           "offset": max(0, float(row[-2]) - float(row[1]))})
        except (ValueError, IndexError):
            continue
    return sorted(result, key=lambda m: m["score"], reverse=True)


class Library:
    def __init__(self, root=None, binary=BIN):
        self.root = Path(root or "~/.config/album-art-matrix/olaf").expanduser()
        self.binary = Path(binary)
        self.path = self.root / "library.json"
        self.lock = threading.Lock()
        self.entries = {}
        self.problem = None
        try:
            data = json.loads(self.path.read_text())
            if isinstance(data, dict):
                self.entries = data
        except (OSError, ValueError):
            pass

    @property
    def available(self):
        return self.binary.is_file() and os.access(self.binary, os.X_OK)

    def public(self):
        return {"engine": "Olaf", "available": self.available,
                "songs": sorted((dict(e) for e in self.entries.values()), key=lambda e: e["added"], reverse=True),
                "problem": self.problem or (None if self.available else "Install Olaf on the wall to teach songs.")}

    def _run(self, args, raw=None, timeout=10):
        (self.root / "db").mkdir(parents=True, exist_ok=True)
        env = {**os.environ, "OLAF_DB_ROOT": str(self.root)}
        result = subprocess.run([str(self.binary), *args], input=raw,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=env, timeout=timeout, check=True)
        return result.stdout.decode(errors="replace")

    def _save(self):
        atomic_json(self.path, self.entries)

    def store(self, track, pcm, how):
        ident = fingerprint_id(track)
        with self.lock:
            if ident in self.entries:
                return ident
            label = (f"{track['artist']} - {track['title']} | {track.get('album', '')} | "
                     f"{track.get('isrc') or ''} | {track.get('art_url') or ''}")
            label = " ".join(label.split())[:480]
            raw = raw_float(pcm)
            fingerprints = self._run(["print", "/dev/stdin", label], raw)
            rows = [line for line in fingerprints.splitlines() if line.split(",", 1)[0].isdigit()]
            if len(rows) < 10:
                raise ValueError("not enough distinct sound to learn")
            numeric = self._run(["name_to_id", label]).strip()
            if any(e["native_id"] == numeric for e in self.entries.values()):
                raise ValueError("fingerprint identifier collision")
            # Save the hashes first. A failed store can then be cleaned up
            # without retaining or reconstructing the person's recording.
            cache = self.root / (ident + ".csv")
            cache.write_text("\n".join(rows) + "\n")
            os.chmod(cache, 0o600)
            self._run(["store", "/dev/stdin", label], raw)
            entry = {"id": ident, "name": label, "added": int(time.time()), "how": how,
                     "times_matched": 0, "native_id": numeric, **track}
            self.entries = {**self.entries, ident: entry}
            self._save()
            self.problem = None
            return ident

    def query(self, pcm, minimum=12):
        # Learning can take longer than lookup. An online recognizer may
        # answer meanwhile; the microphone never waits for a library writer.
        if not self.entries or not self.available or not self.lock.acquire(blocking=False):
            return None
        try:
            matches = parse_matches(self._run(["query", "/dev/stdin", "room"], raw_float(pcm), timeout=1))
            by_native = {e["native_id"]: e for e in self.entries.values()}
            for match in matches:
                entry = by_native.get(match["id"])
                if entry and match["score"] >= minimum:
                    updated = {**entry, "times_matched": entry["times_matched"] + 1}
                    self.entries = {**self.entries, entry["id"]: updated}
                    self._save()
                    track = NowPlaying(track_id="ears:local-" + entry["id"], title=entry["title"],
                                       artist=entry["artist"], album=entry.get("album") or "?",
                                       art_url=entry.get("art_url"), progress_ms=None,
                                       duration_ms=entry.get("duration_ms"), is_playing=True,
                                       isrc=entry.get("isrc"))
                    return track, "local-" + entry["id"], match["offset"], entry.get("isrc"), match["score"]
        except (OSError, subprocess.SubprocessError, ValueError) as exc:
            self.problem = f"Local lookup unavailable: {type(exc).__name__}"
            print(f"[teach] {self.problem}", flush=True)
        finally:
            self.lock.release()
        return None

    def forget(self, ident):
        with self.lock:
            entry = self.entries.get(ident)
            if entry is None:
                return
            helper = self.binary.with_name("olaf-forget")
            subprocess.run([str(helper), str(self.root / "db"), str(self.root / (ident + ".csv")),
                            entry["native_id"]], check=True, capture_output=True, timeout=10)
            self.entries = {k: v for k, v in self.entries.items() if k != ident}
            self._save()
            (self.root / (ident + ".csv")).unlink(missing_ok=True)

    def clear(self):
        with self.lock:
            self.entries = {}
            self._save()
            # All paths here are fixed feature paths, not names from a phone.
            shutil.rmtree(self.root / "db", ignore_errors=True)
            for cache in self.root.glob("*.csv"):
                cache.unlink()
            self.problem = None


def find_preview(track):
    response = requests.get(ITUNES, params={"term": f"{track['artist']} {track['title']}",
                                          "entity": "song", "limit": 15}, timeout=(3, 5))
    response.raise_for_status()
    key = song_key(track)
    for item in response.json().get("results", []):
        candidate = {"title": item.get("trackName", ""), "artist": item.get("artistName", "")}
        if item.get("previewUrl") and song_key(candidate) == key:
            return item["previewUrl"]
    return None


def preview_pcm(url):
    with requests.get(url, timeout=(3, 10), stream=True) as response:
        response.raise_for_status()
        data = bytearray()
        for part in response.iter_content(65536):
            data.extend(part)
            if len(data) > PREVIEW_LIMIT:
                raise ValueError("preview is too large")
    result = subprocess.run(["ffmpeg", "-v", "error", "-threads", "1", "-i", "pipe:0", "-t", "30",
                             "-ac", "1", "-ar", str(RATE), "-f", "s16le", "pipe:1"],
                            input=data, capture_output=True, check=True, timeout=15)
    return result.stdout


class Teacher:
    def __init__(self, ctrl, library=None, start=True):
        self.ctrl = ctrl
        self.library = library or Library()
        self.jobs = queue.Queue(maxsize=2)
        self._key, self._parts, self._bytes = None, [], 0
        self._attempted = {}
        self._generation = 0
        self._manual = None
        self.busy = False
        if start:
            threading.Thread(target=self._work, name="teach", daemon=True).start()

    def enabled(self):
        return bool(self.ctrl.features and self.ctrl.features.enabled("teach"))

    def manual(self, track):
        self._manual = (asdict(track), time.monotonic() + 90)
        self._key, self._parts, self._bytes = None, [], 0

    def named(self):
        if self._manual and time.monotonic() < self._manual[1]:
            return self._manual[0]
        poller = getattr(self.ctrl, "poller", None)
        now = poller.latest if poller else None
        if (not now or not now.is_playing or now.title in ("", "?") or now.artist in ("", "?")
                or now.track_id.startswith("ears:")
                or not poller.asked_at or time.monotonic() - poller.asked_at > 8):
            return None
        return asdict(now)

    def public(self):
        return {**self.library.public(), "enabled": self.enabled(), "busy": self.busy or not self.jobs.empty()}

    def enqueue(self, action, payload):
        try:
            self.jobs.put_nowait((action, payload, self._generation))
            return True
        except queue.Full:
            return False

    def feed(self, pcm, settings, audible):
        track = self.named() if self.enabled() and (settings["teach_by_ear"] or self._manual) and audible else None
        key = fingerprint_id(track) if track else None
        if key != self._key or key is None:
            self._key, self._parts, self._bytes = key, [], 0
        if not key or key in self.library.entries or time.monotonic() < self._attempted.get(key, 0):
            return
        self._parts.append(pcm)
        self._bytes += len(pcm)
        if self._bytes >= LEARN_SECONDS * RATE * 2:
            if self.enqueue("ear", (track, b"".join(self._parts))):
                self._attempted[key] = time.monotonic() + 3600
                self._manual = None
            self._parts, self._bytes = [], 0

    def miss(self, count):
        track = self.named() if self.enabled() and count >= 3 else None
        if track is None:
            return
        key = fingerprint_id(track)
        retry_key = "preview:" + key
        if key not in self.library.entries and time.monotonic() >= self._attempted.get(retry_key, 0):
            if self.enqueue("preview", track):
                self._attempted[retry_key] = time.monotonic() + 3600

    def manage(self, action, ident=None):
        if action == "forget" and ident not in self.library.entries:
            return False
        self._manual = None
        self._generation += 1
        self._parts, self._bytes = [], 0
        if action == "forget":
            self._attempted[ident] = float("inf")
            self._attempted["preview:" + ident] = float("inf")
        else:
            for key in self.library.entries:
                self._attempted[key] = float("inf")
                self._attempted["preview:" + key] = float("inf")
        return self.enqueue(action, ident)

    def _work(self):
        while True:
            action, payload, generation = self.jobs.get()
            self.busy = True
            try:
                if action in ("ear", "preview") and (not self.enabled() or generation != self._generation):
                    continue
                if action == "ear":
                    track, pcm = payload
                    self.library.store(track, pcm, "room")
                elif action == "preview":
                    url = find_preview(payload)
                    if not url:
                        raise ValueError("no matching catalogue preview")
                    pcm = preview_pcm(url)
                    if self.enabled() and generation == self._generation:
                        self.library.store(payload, pcm, "preview")
                elif action == "forget":
                    self.library.forget(payload)
                elif action == "clear":
                    self.library.clear()
                self.ctrl.nudge()
            except (OSError, subprocess.SubprocessError, requests.RequestException, ValueError) as exc:
                self.library.problem = f"Could not teach or update library: {type(exc).__name__}"
                print(f"[teach] {self.library.problem}", flush=True)
            finally:
                # The worker releases its last audio buffer immediately.
                payload = None
                if 'pcm' in locals():
                    pcm = None
                self.busy = False
                self.jobs.task_done()
