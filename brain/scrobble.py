"""Keep the records the room actually heard in your ListenBrainz history.

Naming a record announces it straight away. Hearing half of it, or four
minutes for a long or unknown song, earns a listen dated to its first
hearing. Silence does not earn time, and recognition noise does not turn
one performance into several. Failed listens wait on the wall for up to a
week, then travel together when the connection returns. Only names and
listening times are stored here, never microphone audio or the user token.

All work runs on a dedicated worker. The JSON shape follows
https://listenbrainz.readthedocs.io/en/latest/users/json.html and the API is
https://api.listenbrainz.org/1/submit-listens. Requests already ships with
this brain. A timeout is retryable: the server may have accepted the listen,
so retries preserve its exact original timestamp and metadata.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
import unicodedata
from dataclasses import asdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import requests

API = "https://api.listenbrainz.org/1/submit-listens"
VERSION = "1.1.0"
UA = f"album-art-matrix/{VERSION} (https://github.com/jke48222/album-art-matrix)"
BACKOFF = (60, 300, 900, 3600)
MAX_AGE = 7 * 86400
BATCH = 50
TICK = 0.25


def threshold(duration_ms):
    return min(duration_ms / 2000.0, 240.0) if duration_ms and duration_ms > 0 else 240.0


def song_key(track):
    def plain(value):
        value = unicodedata.normalize("NFKC", value).casefold()
        value = re.sub(r"\s*[\[(][^\])]*[\])]", "", value)
        return " ".join(re.findall(r"\w+", value))
    return plain(track["artist"]) + "|" + plain(track["title"])


def listen(track, at=None):
    info = {"media_player": "Album Art Matrix", "submission_client": "album-art-matrix",
            "submission_client_version": VERSION, "music_service_name": "vinyl", "tags": ["wall"]}
    if track.get("isrc"):
        info["isrc"] = track["isrc"]
    if track.get("duration_ms"):
        info["duration_ms"] = track["duration_ms"]
    meta = {"track_name": track["title"], "artist_name": track["artist"], "additional_info": info}
    if track.get("album") and track["album"] != "?":
        meta["release_name"] = track["album"]
    result = {"track_metadata": meta}
    if at is not None:
        result["listened_at"] = int(at)
    return result


def atomic_json(path, value, lines=False):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w") as fh:
        os.chmod(tmp, 0o600)
        if lines:
            for row in value:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        else:
            json.dump(value, fh, ensure_ascii=False)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


class Scrobbler:
    def __init__(self, store, features, *, root=None, clock=time.time,
                 monotonic=time.monotonic, post=None, on_listen=None, sources=("ears",)):
        self.store, self.features = store, features
        self.root = Path(root or "~/.config/album-art-matrix").expanduser()
        self.queue_path = self.root / "scrobbles.jsonl"
        self.state_path = self.root / "scrobble-state.json"
        self.clock, self.monotonic = clock, monotonic
        self.post = post or requests.post
        self.on_listen = on_listen
        self.sources = frozenset(sources)
        self.queue, self.sessions = [], {}
        self.last_listen, self.problem = None, None
        self._active, self._last_mono = None, None
        self._held_identity, self._last_confirmed = None, None
        self._stop = threading.Event()
        self._status_lock = threading.Lock()
        self._snapshot = {"last_listen": None, "queued": 0, "problem": None}
        self._executor = None
        self._pending = None
        self._restore()
        self._publish()

    def _restore(self):
        try:
            for line in self.queue_path.read_text().splitlines():
                try:
                    row = json.loads(line)
                    if (isinstance(row, dict) and isinstance(row.get("payload"), dict)
                            and isinstance(row.get("at"), (int, float))
                            and row.get("kind") in ("playing_now", "single")
                            and isinstance(row.get("attempt"), int)
                            and isinstance(row.get("next"), (int, float))):
                        self.queue.append(row)
                except (ValueError, TypeError):
                    print("[scrobble] skipped damaged queue row", flush=True)
        except FileNotFoundError:
            pass
        except OSError:
            self.problem = "could not read scrobble queue"
        try:
            saved = json.loads(self.state_path.read_text())
            self.sessions = saved.get("sessions", {})
            self.last_listen = saved.get("last_listen")
            if not isinstance(self.sessions, dict):
                self.sessions = {}
        except (OSError, ValueError, AttributeError):
            pass
        self._prune()

    def _prune(self):
        oldest = self.clock() - MAX_AGE
        self.queue = [r for r in self.queue if r["at"] >= oldest]
        self.sessions = {k: v for k, v in self.sessions.items()
                         if isinstance(v, dict) and v.get("at", 0) >= oldest}

    def _save(self):
        self._prune()
        # Persist the listen before its dedupe receipt. A crash between these
        # files recovers the session from the queue rather than losing it.
        atomic_json(self.queue_path, self.queue, lines=True)
        atomic_json(self.state_path, {"sessions": self.sessions, "last_listen": self.last_listen})
        self._publish()

    def _publish(self):
        with self._status_lock:
            self._snapshot = {"last_listen": self.last_listen,
                              "queued": sum(r["kind"] == "single" for r in self.queue),
                              "problem": self.problem}

    def status(self):
        with self._status_lock:
            result = dict(self._snapshot)
        result.update(token_set=bool(self.store.get("listenbrainz", "token")),
                      enabled=self.features.enabled("scrobble"))
        if not result["token_set"] and result["enabled"]:
            result["problem"] = "Add your user token to scrobble records."
        return result

    def _enqueue(self, kind, session):
        ident = session["id"] + ":" + kind
        if not any(r["id"] == ident for r in self.queue):
            self.queue.append({"id": ident, "kind": kind, "at": session["at"],
                               "payload": listen(session["track"], session["at"] if kind == "single" else None),
                               "session": session["id"], "attempt": 0, "next": self.clock()})

    def observe(self, track, audible=True, confirmed=None, source="ears"):
        """Called on the worker, never the renderer. confirmed identifies a
        real recognizer hit, so holding a stale song cannot start a replay."""
        mono, now = self.monotonic(), self.clock()
        elapsed = 0 if self._last_mono is None else max(0, mono - self._last_mono)
        self._last_mono = mono
        if not self.features.enabled("scrobble") or not self.store.get("listenbrainz", "token"):
            self._active = None
            return
        if track is not None and not isinstance(track, dict):
            track = asdict(track)
        if (source not in self.sources or not track or not track.get("is_playing")
                or track.get("title") in (None, "", "?") or track.get("artist") in (None, "", "?")):
            self._active, self._held_identity = None, None
            return
        key = song_key(track)
        session = self.sessions.get(key)
        identity = (key, confirmed)
        fresh = identity != self._held_identity
        # An actual new hearing after the recording's end can be a replay.
        # The same held answer stays one listen for as long as it is held.
        expired = session and now >= session["end"]
        if session is None or (expired and fresh and confirmed != self._last_confirmed):
            duration = (track.get("duration_ms") or 240000) / 1000.0
            progress = max(0, (track.get("progress_ms") or 0) / 1000.0)
            at = int(now)
            ident = hashlib.sha256(f"{key}|{at}".encode()).hexdigest()[:24]
            session = {"id": ident, "at": at, "end": now + max(1, duration - progress),
                       "heard": 0.0, "qualified": False, "track": track}
            self.sessions[key] = session
            # After a crash the durable queue might be ahead of the receipt.
            prior = next((r for r in self.queue if r["session"] == ident and r["kind"] == "single"), None)
            session["qualified"] = prior is not None
            self._enqueue("playing_now", session)
            self._save()
        self._held_identity, self._last_confirmed = identity, confirmed
        if audible and self._active == session["id"]:
            # A stalled process did not hear the room. A transport timeout
            # also must not count an unseen silence as listening time.
            session["heard"] += min(elapsed, 1.0)
        self._active = session["id"] if audible else None
        if not session["qualified"] and session["heard"] >= threshold(track.get("duration_ms")):
            session["qualified"] = True
            self._enqueue("single", session)
            self._save()
        elif int(session["heard"]) // 5 != int(max(0, session["heard"] - min(elapsed, 1.0))) // 5:
            self._save()

    def _send(self, kind, rows, token):
        code, retry_after = None, 0.0
        try:
            response = self.post(API, json={"listen_type": kind, "payload": [r["payload"] for r in rows]},
                                 headers={"Authorization": "Token " + token, "User-Agent": UA}, timeout=(3, 5))
            code = response.status_code
            if code == 429:
                try:
                    retry_after = max(0, float(response.headers.get("Retry-After", 0)))
                except (ValueError, TypeError):
                    pass
        except requests.RequestException:
            pass
        return code, retry_after

    def deliver(self):
        now = self.clock()
        if self._pending is not None:
            future, rows = self._pending
            if not future.done():
                return
            self._pending = None
            code, retry_after = future.result()
        else:
            if not self.features.enabled("scrobble"):
                return
            token = self.store.get("listenbrainz", "token")
            if not token:
                return
            before = len(self.queue)
            self._prune()
            # Announcements are useful only while their session is in the room.
            self.queue = [r for r in self.queue if r["kind"] != "playing_now"
                          or (r["session"] == self._active and now - r["at"] < 240)]
            if before != len(self.queue):
                self._save()
            due = [r for r in self.queue if r["next"] <= now]
            if not due:
                return
            first = due[0]
            kind = first["kind"]
            rows = [first]
            if kind == "single" and first["attempt"] > 0:
                kind = "import"
                rows = [r for r in due if r["kind"] == "single" and r["attempt"] > 0][:BATCH]
            if self._executor is not None:
                self._pending = (self._executor.submit(self._send, kind, rows, token), rows)
                return
            code, retry_after = self._send(kind, rows, token)
        if code is None:
            self.problem = "ListenBrainz is unreachable; listens are kept on the wall."
        success = code is not None and 200 <= code < 300
        permanent = code is not None and 400 <= code < 500 and code != 429
        if success or permanent:
            if permanent:
                self.problem = f"ListenBrainz refused a submission (HTTP {code}); dropped."
                print(f"[scrobble] {self.problem}", flush=True)
            else:
                self.problem = None
                for row in rows:
                    if row["kind"] == "single":
                        meta = row["payload"]["track_metadata"]
                        last = {"title": meta["track_name"], "artist": meta["artist_name"], "at": row["at"]}
                        if not self.last_listen or last["at"] >= self.last_listen["at"]:
                            self.last_listen = last
                        if self.on_listen:
                            self.on_listen(row["session"], last)
                        print(f"[scrobble] listened: {last['artist']} - {last['title']}", flush=True)
            ids = {r["id"] for r in rows}
            self.queue = [r for r in self.queue if r["id"] not in ids]
        else:
            if code is not None:
                self.problem = f"ListenBrainz HTTP {code}; will retry."
            for row in rows:
                row["next"] = now + max(BACKOFF[min(row["attempt"], len(BACKOFF) - 1)], retry_after)
                row["attempt"] += 1
            print(f"[scrobble] {self.problem}", flush=True)
        self._save()

    def start(self, ear):
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="scrobble-post")
        def run():
            while not self._stop.is_set():
                try:
                    track, audible, confirmed = ear.scrobble_snapshot()
                    self.observe(track, audible, confirmed)
                    self.deliver()
                except Exception as exc:
                    # No response bodies or request objects here: either may
                    # contain an account token when a client raises an error.
                    self.problem = f"scrobbling paused: {type(exc).__name__}"
                    self._publish()
                    print(f"[scrobble] {self.problem}", flush=True)
                self._stop.wait(TICK)
        threading.Thread(target=run, name="scrobble", daemon=True).start()
        return self

    def close(self):
        self._stop.set()
        if self._executor is not None:
            self._executor.shutdown(wait=False, cancel_futures=True)
