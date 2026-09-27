"""Vinyl scrobbling: every record the ear names goes into the owner's
ListenBrainz history, the way a streamed song would.

The streaming services already report themselves: Spotify through Last.fm,
Apple Music through the Mac, and so on. The one thing in the room nobody
reports is the record player. The wall's ear names what it hears, so the
wall is the only thing that can write a record down, and this module does
exactly that and nothing else: it watches the ear, and only the ear.

How a play becomes a listen
---------------------------
The ear holds a song while the room is loud; this module follows the ear's
hit as an EPISODE. When an episode starts, ListenBrainz is told the song is
"playing now" (a note that expires on its own). Time counts toward a listen
only while the ear's gate is open, so a record left on the platter with the
amp off does not keep counting. ListenBrainz's own rule decides when a play
is a listen: half the song's length, or four minutes, whichever comes
first. The length comes from the ear's iTunes dressing; a song without one
needs the full four minutes. A listen is posted once per episode, stamped
with the moment the song was first heard.

Held through a conversation, let go and heard again a minute later, an
episode is the same play: the ear keeps one song through noise, and a song
heard again before its own length has run out resumes the episode rather
than starting another. Heard again after that, it is a second play, and a
second listen.

When the network is away
------------------------
Listens that could not be posted wait in ~/.config/album-art-matrix/
scrobbles.jsonl and are retried after one, five and fifteen minutes, then
hourly, as one batch (an "import", up to fifty at a time), for up to seven
days. ListenBrainz keeps its own duplicate check, so a retry that in fact
landed the first time does no harm. A rejected token stops everything
until a new one arrives from the phone; a listen the service calls
malformed is logged and dropped rather than retried forever.

Settings
--------
The user token comes from listenbrainz.org/settings and is typed on the
phone's ListenBrainz page; it lives in services.json with the username,
never in config. `[scrobble] sources = ["ears"]` in config.toml names what
is reported; only the ear is offered, because the others report
themselves. `[features] scrobble = false` turns the whole thing off.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import threading
import time
import tempfile

import requests

API = "https://api.listenbrainz.org/1"
UA = "album-art-matrix/1.0 (github.com/jke48222/album-art-matrix)"
QUEUE_PATH = os.path.expanduser("~/.config/album-art-matrix/scrobbles.jsonl")

CLIENT = "album-art-matrix"
CLIENT_VERSION = "1.0"
POLL_S = 2.0                      # how often the ear is looked at
LISTEN_AFTER_S = 240.0            # ListenBrainz: four minutes, or half the song
REHEAR_GRACE_S = 600.0            # a song of unknown length: heard again within
                                  # this of its start is the same play
RETRY_S = (60.0, 300.0, 900.0)    # then every hour
RETRY_HOURLY_S = 3600.0
QUEUE_MAX_AGE_S = 7 * 86400.0
BATCH = 50                        # ListenBrainz takes up to this many per import
RATE_LIMIT_FALLBACK_S = 30.0


_BRACKETS = re.compile(r"\s*[\[(][^\])]*[\])]")


def _plain(s: str) -> str:
    """Lower case, without any bracketed part: the ear's own rule, so an
    "[Extended Edit]" heard mid-song is the same song, not a second play."""
    return _BRACKETS.sub("", s or "").strip().lower()


def _same_song(a, b) -> bool:
    """The ear's own rule for 'one song in the room': ignore the cut."""
    if a is None or b is None:
        return False
    if a.track_id == b.track_id:
        return True
    return _plain(a.title) == _plain(b.title) and \
        _plain(a.artist).split(",")[0] == _plain(b.artist).split(",")[0]


def listen_payload(track, isrc: str | None = None) -> dict:
    """One ListenBrainz `track_metadata` for a song the ear named."""
    info = {
        "media_player": "Album Art Matrix",
        "submission_client": CLIENT,
        "submission_client_version": CLIENT_VERSION,
        "music_service_name": "vinyl",
        "tags": ["wall"],
    }
    if isrc:
        info["isrc"] = isrc
    if track.duration_ms:
        info["duration_ms"] = int(track.duration_ms)
    meta = {"artist_name": track.artist or "?", "track_name": track.title or "?",
            "additional_info": info}
    if track.album and track.album != "?":
        meta["release_name"] = track.album
    return meta


class Episode:
    """One play of one record, as the ear tells it."""

    def __init__(self, track, isrc, started_at: float, mono: float):
        self.track = track
        self.isrc = isrc
        self.started_at = started_at        # wall clock, the first hearing
        self.first_mono = mono
        self.last_mono = mono
        self.heard_s = 0.0                  # time with the gate open
        self.playing_now_sent = False
        self.listen_sent = False
        self.ended_mono = None

    @property
    def needs_s(self) -> float:
        dur = self.track.duration_ms
        if dur:
            return min(LISTEN_AFTER_S, dur / 2000.0)
        return LISTEN_AFTER_S

    def still_this_play(self, mono: float) -> bool:
        """Heard again: is it the same play, or has the song run out?"""
        dur = self.track.duration_ms
        span = dur / 1000.0 if dur else REHEAR_GRACE_S
        return mono - self.first_mono < span


class Scrobbler:
    """Follows the ear, posts to ListenBrainz, keeps a queue. One thread."""

    def __init__(self, ctrl, sources=("ears",), user: str = "", token: str = "",
                 queue_path: str = QUEUE_PATH, clock=None, mono=None, post=None,
                 gate=None, current=None):
        self.ctrl = ctrl
        self.sources = tuple(sources)
        self.user = (user or "").strip()
        self.token = (token or "").strip()
        self.queue_path = queue_path
        # the seams the tests use: real time, real network, the real ear
        self._clock = clock or time.time
        self._mono = mono or time.monotonic
        self._post = post or self._http_post
        self._gate = gate                    # () -> bool, the ear's gate
        self._current = current              # () -> NowPlaying | None
        self._lock = threading.RLock()
        self._tick_lock = threading.Lock()
        self._generation = 0
        self._validation_after = 0.0
        self._state = "checking" if self.token else "unlinked"
        self._checked_at = None
        self._retrying = False
        self._counting = False
        self._queue_saved = True
        self.episode: Episode | None = None
        self.recent: Episode | None = None   # the last episode, for the resume rule
        self.valid: bool | None = None
        self.user_name: str | None = None
        self.problem: str | None = None
        self.last_listen: dict | None = None
        self.playing_now: dict | None = None
        self.submitted = 0
        self._rate_limited_until = 0.0
        self._token_checked = None           # the token that was validated
        self._queue = self._load_queue()
        # Older releases did not record queue ownership. Never guess: those
        # listens stay held until expiry, even if credentials changed while off.
        migrated = False
        for item in self._queue:
            if "owner" not in item:
                item["owner"] = "unowned"
                migrated = True
        if migrated:
            self._save_queue()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, name="scrobble", daemon=True)

    @classmethod
    def from_config(cls, cfg: dict, ctrl) -> "Scrobbler":
        sc = (cfg or {}).get("scrobble") or {}
        sources = [str(s) for s in sc.get("sources", ["ears"])]
        for s in sources:
            if s != "ears":
                print(f"[scrobble] source {s!r} reports itself; only the ear is scrobbled here",
                      flush=True)
        store = getattr(ctrl, "services_store", None)
        user = store.get("listenbrainz", "user") if store else ""
        token = store.get("listenbrainz", "token") if store else ""
        return cls(ctrl, sources=sources, user=user, token=token)

    def start(self) -> "Scrobbler":
        self._thread.start()
        return self

    def stop(self):
        self._stop.set()

    # ---- settings from the phone ----------------------------------------------
    def _owner(self):
        return hashlib.sha256(self.token.encode("utf-8")).hexdigest() if self.token else "unowned"

    def configure(self, user=None, token=None):
        with self._lock:
            if user is not None:
                self.user = user.strip()
            if token is not None and token.strip() != self.token:
                self.token = token.strip()
                self._generation += 1
                self.valid = None
                self.user_name = self.problem = self._token_checked = None
                self._rate_limited_until = self._validation_after = 0.0
                self._state = "checking" if self.token else "unlinked"
                self._checked_at = None
                self.episode = self.recent = None
                self._counting = False
                self.last_listen = self.playing_now = None
                self.submitted = 0

    def retry(self):
        """Coalesced user retry. A provider rate limit is never bypassed."""
        with self._lock:
            if not self.token or self._retrying or self._mono() < self._rate_limited_until:
                return False
            self._retrying = True
            self._token_checked = None
            self._validation_after = 0.0
            self._state = "checking"
            generation = self._generation
        def check():
            try:
                with self._tick_lock:
                    self._check_token(generation)
                    with self._lock:
                        if generation != self._generation:
                            return
                        for item in self._queue:
                            if self._owns(item):
                                item["next"] = 0.0
                    self._retry_queue(generation)
            finally:
                with self._lock:
                    self._retrying = False
        threading.Thread(target=check, name="listenbrainz-write-check", daemon=True).start()
        return True

    def _owns(self, item):
        return bool(self.token) and (item.get("owner") == self._owner() or bool(
            self.valid is True and self.user_name and item.get("owner_name") == self.user_name))

    @property
    def configured(self) -> bool:
        return bool(self.token)

    # ---- the ear ----------------------------------------------------------------
    def _ear_current(self):
        if self._current is not None:
            return self._current()
        ear = getattr(self.ctrl, "ears", None)
        if ear is None:
            return None
        try:
            return ear.get_current()
        except Exception as exc:
            print(f"[scrobble] ear: {exc}", flush=True)
            return None

    def _ear_gate(self) -> bool:
        if self._gate is not None:
            return bool(self._gate())
        ear = getattr(self.ctrl, "ears", None)
        if ear is None:
            return False
        return bool(getattr(ear, "gate_open", False))

    def _ear_isrc(self, track) -> str | None:
        """The ear keeps the ISRC of its dressing per iTunes lookup; the
        NowPlaying does not carry it, so ask the ear's cache when it can."""
        ear = getattr(self.ctrl, "ears", None)
        cache = getattr(ear, "_itunes", None) if ear is not None else None
        if not cache:
            return None
        # the ear dresses a hit from its ISRC: the entry whose art is this hit's
        for isrc, (dur, art) in list(cache.items()):
            if art and art == track.art_url:
                return isrc
        return None

    # ---- the loop -----------------------------------------------------------------
    def _loop(self):
        last = self._mono()
        while not self._stop.is_set():
            self._stop.wait(POLL_S)
            now = self._mono()
            dt, last = now - last, now
            try:
                self.tick(dt)
            except Exception as exc:
                print(f"[scrobble] tick: {exc}", flush=True)

    def tick(self, dt: float):
        with self._tick_lock:
            self._tick(dt)

    def _tick(self, dt: float):
        mono = self._mono()
        with self._lock:
            generation = self._generation
            self._expire_queue()
        if self.configured:
            self._check_token(generation)
        cur = self._ear_current() if "ears" in self.sources else None
        counting = bool(cur is not None and cur.is_playing and self._ear_gate())
        with self._lock:
            if generation != self._generation:
                return
            ep = self.episode
            previous = ep
            self._counting = counting
            if cur is None:
                if ep is not None:
                    ep.ended_mono = mono
                    self.recent, self.episode = ep, None
                ep = None
            else:
                if ep is None or not _same_song(ep.track, cur):
                    rec = self.recent
                    if rec is not None and _same_song(rec.track, cur) and rec.still_this_play(mono):
                        ep = rec
                        ep.ended_mono = None
                        ep.playing_now_sent = False
                    else:
                        ep = Episode(cur, self._ear_isrc(cur), self._clock(), mono)
                    if self.episode is not None and self.episode is not ep:
                        self.episode.ended_mono = mono
                        self.recent = self.episode
                    elif ep is rec:
                        self.recent = None
                    self.episode = ep
                elif cur.duration_ms and not ep.track.duration_ms:
                    ep.track = cur
                ep.last_mono = mono
                # A blocked network request or a sleeping process is not
                # evidence of listening. New tracks do not inherit prior time.
                if counting and ep is previous and math.isfinite(dt) and 0 <= dt <= POLL_S * 3:
                    ep.heard_s += dt
        if not counting and self.configured:
            self._clear_playing_now(generation)
        if ep is not None and self.configured:
            if not ep.playing_now_sent and counting:
                self._send_playing_now(ep, generation)
            if not ep.listen_sent and ep.heard_s >= ep.needs_s:
                self._send_listen(ep, generation)
        if self.configured:
            self._retry_queue(generation)

    # ---- posting ------------------------------------------------------------------
    def _headers(self, token) -> dict:
        return {"Authorization": f"Token {token}", "User-Agent": UA,
                "Content-Type": "application/json"}

    def _http_post(self, path: str, body: dict | None, method: str = "POST", token=None):
        """(status code, json or None). Network errors are status 0."""
        try:
            if method == "GET":
                r = requests.get(API + path, headers=self._headers(token if token is not None else self.token), timeout=10)
            else:
                r = requests.post(API + path, headers=self._headers(token if token is not None else self.token), json=body, timeout=15)
            try:
                data = r.json()
            except ValueError:
                data = None
            return r.status_code, data, r.headers
        except requests.RequestException as exc:
            return 0, {"error": str(exc)[:120]}, {}

    def _request(self, path, body, generation, method="POST"):
        with self._lock:
            if generation != self._generation or not self.token:
                return None
            token = self.token
        if self._post == self._http_post:
            result = self._http_post(path, body, method, token=token)
        else:
            result = self._post(path, body, method=method)
        with self._lock:
            return result if generation == self._generation else None

    def _check_token(self, generation):
        with self._lock:
            if generation != self._generation or self._token_checked == self.token or self._mono() < self._validation_after:
                return
        result = self._request("/validate-token", None, generation, method="GET")
        if result is None:
            return
        code, data, headers = result
        with self._lock:
            if generation != self._generation:
                return
            self._checked_at = self._clock()
            if code == 200 and isinstance(data, dict) and isinstance(data.get("valid"), bool):
                self.valid = data["valid"]
                name = data.get("user_name")
                if self.valid and (not isinstance(name, str) or not name.strip()):
                    self.valid = None
                    self._state = "unavailable"
                    self.problem = "ListenBrainz did not identify the token’s account."
                    self._validation_after = self._mono() + 60
                    return
                self.user_name = name if self.valid else None
                self._token_checked = self.token
                self.problem = None if self.valid else "ListenBrainz rejected this user token. Replace it in Writing."
                self._state = "ready" if self.valid else "refused"
            else:
                self.valid = None
                self._validation_after = self._mono() + 60
                self._note_failure(code, data, headers, "token check")

    def _send_playing_now(self, ep: Episode, generation):
        with self._lock:
            if generation != self._generation or self.valid is not True or self._mono() < self._rate_limited_until:
                return
        body = {"listen_type": "playing_now",
                "payload": [{"track_metadata": listen_payload(ep.track, ep.isrc)}]}
        result = self._request("/submit-listens", body, generation)
        with self._lock:
            if result is None or generation != self._generation:
                return
            code, data, headers = result
            ep.playing_now_sent = True
            if code == 200:
                self.playing_now = {"title": ep.track.title, "artist": ep.track.artist,
                                    "at": int(self._clock())}
                self._state = "ready"
                self.problem = None
            else:
                self._note_failure(code, data, headers, "playing now")

    def _clear_playing_now(self, generation):
        with self._lock:
            if generation != self._generation or self.playing_now is None or self.valid is not True:
                return
            # A playing-now notice is temporary. Clear only this client's
            # notice, never one recently sent by the user's music player.
            self.playing_now = None
            if self.episode:
                self.episode.playing_now_sent = False
            if self._mono() < self._rate_limited_until:
                return
        result = self._request("/playing-now/delete", {"client": CLIENT}, generation)
        with self._lock:
            if result is None or generation != self._generation:
                return
            code, data, headers = result
            if code not in (200, 404):
                self._note_failure(code, data, headers, "clear playing now")

    def _send_listen(self, ep: Episode, generation):
        with self._lock:
            if generation != self._generation or not self.token or ep.listen_sent:
                return
            ep.listen_sent = True
            item = {"kind": "single",
                    "payload": {"listened_at": int(ep.started_at),
                                "track_metadata": listen_payload(ep.track, ep.isrc)},
                    "queued_at": self._clock(), "tries": 0, "next": 0.0,
                    "owner": self._owner(), "owner_name": self.user_name}
            if self.valid is not True or self._mono() < self._rate_limited_until:
                self._enqueue(item)
                return
            # Save before transmission. A retry uses the same timestamp and
            # metadata so ListenBrainz can recognize duplicate submissions.
            self._queue.append(item)
            self._save_queue()
        body = {"listen_type": "single", "payload": [item["payload"]]}
        result = self._request("/submit-listens", body, generation)
        with self._lock:
            if result is None or generation != self._generation:
                return
            code, data, headers = result
            if code == 200:
                self._landed([item])
                self._remove_items([item])
            elif self._retryable(code):
                self._note_failure(code, data, headers, "listen")
                self._enqueue(item)
            else:
                self._remove_items([item])
                self._note_failure(code, data, headers, "listen")

    def _retryable(self, code: int) -> bool:
        return code in (0, 401, 403, 429) or code >= 500

    def _note_failure(self, code, data, headers, what):
        if code in (401, 403):
            self.valid = False
            self._state = "refused"
            self.problem = "ListenBrainz rejected the token. Replace it in Writing."
        elif code == 429:
            try:
                wait = float((headers or {}).get("X-RateLimit-Reset-In", RATE_LIMIT_FALLBACK_S))
            except (TypeError, ValueError):
                wait = RATE_LIMIT_FALLBACK_S
            wait = min(3600.0, max(1.0, wait)) if math.isfinite(wait) else RATE_LIMIT_FALLBACK_S
            self._rate_limited_until = self._mono() + wait
            self._state = "rate_limited"
            self.problem = f"ListenBrainz is rate limited; retry in {int(wait)} seconds."
        elif code == 0:
            self._state = "offline"
            self.problem = "ListenBrainz has no network connection. Counted listens wait here."
        else:
            self._state = "unavailable"
            self.problem = "ListenBrainz could not accept the request. Try again."
        # Never echo provider error bodies: they can contain credentials.
        print(f"[scrobble] {what} failed: HTTP {code}", flush=True)

    def _landed(self, items: list[dict]):
        self.problem = None
        self._state = "ready"
        for it in items:
            tm = it["payload"]["track_metadata"]
            self.submitted += 1
            self.last_listen = {"title": tm["track_name"], "artist": tm["artist_name"],
                                "album": tm.get("release_name", ""),
                                "at": it["payload"]["listened_at"],
                                "kind": it["kind"]}
            print(f"[scrobble] listen: {tm['artist_name']} - {tm['track_name']}", flush=True)
            self._mark_journal(tm["track_name"], tm["artist_name"], it["payload"]["listened_at"])

    def _mark_journal(self, title, artist, since_ts):
        mark = getattr(self.ctrl, "journal_mark", None)
        if mark is None:
            return
        try:
            mark(title, artist, since_ts, {"scrobbled": True})
        except Exception as exc:
            print(f"[scrobble] journal: {exc}", flush=True)

    # ---- the queue ------------------------------------------------------------------
    def _load_queue(self) -> list[dict]:
        items = []
        try:
            with open(self.queue_path) as fh:
                for line in fh:
                    try:
                        item = json.loads(line)
                        payload = item.get("payload", {})
                        meta = payload.get("track_metadata", {})
                        if not isinstance(meta.get("track_name"), str) or not isinstance(meta.get("artist_name"), str):
                            continue
                        if not isinstance(payload.get("listened_at"), (int, float)):
                            continue
                        if not all(isinstance(item.get(k, 0), (int, float)) and math.isfinite(item.get(k, 0)) for k in ("queued_at", "tries", "next")):
                            continue
                        items.append(item)
                    except (ValueError, TypeError, AttributeError):
                        continue
        except OSError:
            pass
        return items

    def _save_queue(self):
        tmp = None
        try:
            directory = os.path.dirname(self.queue_path) or "."
            os.makedirs(directory, exist_ok=True)
            fd, tmp = tempfile.mkstemp(prefix=".scrobbles-", dir=directory)
            with os.fdopen(fd, "w") as fh:
                for it in self._queue:
                    fh.write(json.dumps(it) + "\n")
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, self.queue_path)
            self._queue_saved = True
        except OSError:
            self._queue_saved = False
            print("[scrobble] could not save the listening queue", flush=True)
        finally:
            if tmp and os.path.exists(tmp):
                os.unlink(tmp)

    def _remove_items(self, items):
        with self._lock:
            self._queue = [it for it in self._queue if all(it is not item for item in items)]
            self._save_queue()

    def _enqueue(self, item: dict):
        item["tries"] = item.get("tries", 0) + 1
        step = min(item["tries"], len(RETRY_S)) - 1
        wait = RETRY_S[step] if item["tries"] <= len(RETRY_S) else RETRY_HOURLY_S
        item["next"] = self._clock() + wait
        with self._lock:
            if not any(it is item for it in self._queue):
                self._queue.append(item)
            self._save_queue()
        print(f"[scrobble] queued ({len(self._queue)} waiting), next try in {int(wait)} s",
              flush=True)

    def _expire_queue(self):
        now = self._clock()
        kept = [item for item in self._queue if now - item.get("queued_at", now) <= QUEUE_MAX_AGE_S]
        if len(kept) != len(self._queue):
            self._queue = kept
            self._save_queue()

    def _retry_queue(self, generation):
        with self._lock:
            if generation != self._generation or not self._queue or self.valid is not True or self._mono() < self._rate_limited_until:
                return
            now = self._clock()
            kept = [it for it in self._queue if now - it.get("queued_at", now) <= QUEUE_MAX_AGE_S]
            if len(kept) != len(self._queue):
                self._queue = kept
                self._save_queue()
            batch = [it for it in self._queue if self._owns(it) and it.get("next", 0) <= now][:BATCH]
        if not batch:
            return
        body = {"listen_type": "import", "payload": [it["payload"] for it in batch]}
        result = self._request("/submit-listens", body, generation)
        if result is None:
            return
        with self._lock:
            if generation != self._generation:
                return
            code, data, headers = result
            if code == 200:
                self._landed(batch)
                self._remove_items(batch)
            elif self._retryable(code):
                self._note_failure(code, data, headers, "retry")
                for item in batch:
                    self._enqueue(item)
            else:
                self._note_failure(code, data, headers, "retry")
                self._remove_items(batch)

    # ---- for /services --------------------------------------------------------------
    def status(self) -> dict:
        with self._lock:
            ep = self.episode
            queued = sum(1 for item in self._queue if self._owns(item))
            return {
                "user": self.user, "token_set": bool(self.token), "valid": self.valid,
                "user_name": self.user_name, "sources": list(self.sources),
                "state": self._state, "checked_at": self._checked_at,
                "counting": self._counting,
                "retry_after": max(0, int(math.ceil(self._rate_limited_until - self._mono()))),
                "playing": ({"title": ep.track.title, "artist": ep.track.artist,
                             "heard_s": int(ep.heard_s), "needs_s": int(math.ceil(ep.needs_s)),
                             "listened": ep.listen_sent} if ep is not None else None),
                "last_listen": self.last_listen, "queued": queued,
                "held_queued": len(self._queue) - queued,
                "legacy_queued": sum(1 for item in self._queue if item.get("owner") == "unowned"),
                "queue_saved": self._queue_saved,
                "submitted": self.submitted, "problem": self.problem,
            }
