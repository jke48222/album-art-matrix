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

import json
import os
import re
import threading
import time

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
        self._lock = threading.Lock()
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
    def configure(self, user=None, token=None):
        with self._lock:
            if user is not None:
                self.user = user.strip()
            if token is not None and token.strip() != self.token:
                self.token = token.strip()
                self.valid = None
                self.user_name = None
                self.problem = None
                self._token_checked = None
                self._rate_limited_until = 0.0

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
        """One look at the ear, `dt` seconds after the last. Public so the
        tests can drive it with a fake clock."""
        mono = self._mono()
        if self.configured:
            self._check_token()
        cur = self._ear_current()
        ep = self.episode
        if cur is None:
            if ep is not None:
                ep.ended_mono = mono
                self.recent, self.episode = ep, None
                print(f"[scrobble] {ep.track.artist} - {ep.track.title}: play over "
                      f"after {int(ep.heard_s)} s heard", flush=True)
        else:
            if ep is None or not _same_song(ep.track, cur):
                rec = self.recent
                if rec is not None and _same_song(rec.track, cur) and rec.still_this_play(mono):
                    ep = rec                         # the same play, heard again
                    ep.ended_mono = None
                    ep.playing_now_sent = False      # ListenBrainz's note expired
                    print(f"[scrobble] {cur.artist} - {cur.title}: heard again, same play",
                          flush=True)
                else:
                    ep = Episode(cur, self._ear_isrc(cur), self._clock(), mono)
                    print(f"[scrobble] {cur.artist} - {cur.title}: new play", flush=True)
                if self.episode is not None and self.episode is not ep:
                    self.episode.ended_mono = mono   # replaced mid-play: it may come back
                    self.recent = self.episode
                elif ep is rec:
                    self.recent = None
                self.episode = ep
            elif cur.duration_ms and not ep.track.duration_ms:
                ep.track = cur                       # the dressing arrived late
            ep.last_mono = mono
            if self._ear_gate():
                ep.heard_s += dt
            if self.configured:
                if not ep.playing_now_sent:
                    ep.playing_now_sent = True       # once, whatever happens to it
                    self._send_playing_now(ep)
                if not ep.listen_sent and ep.heard_s >= ep.needs_s:
                    ep.listen_sent = True
                    self._send_listen(ep)
        if self.configured:
            self._retry_queue()

    # ---- posting ------------------------------------------------------------------
    def _headers(self) -> dict:
        return {"Authorization": f"Token {self.token}", "User-Agent": UA,
                "Content-Type": "application/json"}

    def _http_post(self, path: str, body: dict | None, method: str = "POST"):
        """(status code, json or None). Network errors are status 0."""
        try:
            if method == "GET":
                r = requests.get(API + path, headers=self._headers(), timeout=10)
            else:
                r = requests.post(API + path, headers=self._headers(), json=body, timeout=15)
            try:
                data = r.json()
            except ValueError:
                data = None
            return r.status_code, data, r.headers
        except requests.RequestException as exc:
            return 0, {"error": str(exc)[:120]}, {}

    def _check_token(self):
        if self._token_checked == self.token:
            return
        self._token_checked = self.token
        code, data, _ = self._post("/validate-token", None, method="GET")
        if code == 200 and isinstance(data, dict):
            self.valid = bool(data.get("valid"))
            self.user_name = data.get("user_name") or None
            self.problem = None if self.valid else "the token is not one ListenBrainz knows"
            print(f"[scrobble] token {'valid' if self.valid else 'REJECTED'}"
                  f"{' for ' + self.user_name if self.user_name else ''}", flush=True)
        elif code == 0:
            self._token_checked = None           # ask again when the network is back
        else:
            self.valid = None
            self.problem = f"validate-token answered {code}"

    def _send_playing_now(self, ep: Episode):
        if self.valid is False or self._mono() < self._rate_limited_until:
            return
        body = {"listen_type": "playing_now",
                "payload": [{"track_metadata": listen_payload(ep.track, ep.isrc)}]}
        code, data, headers = self._post("/submit-listens", body)
        if code == 200:
            self.playing_now = {"title": ep.track.title, "artist": ep.track.artist,
                                "at": int(self._clock())}
        else:
            self._note_failure(code, data, headers, "playing now")
        # a playing-now that failed is not queued: it is about this minute

    def _send_listen(self, ep: Episode):
        item = {"kind": "single",
                "payload": {"listened_at": int(ep.started_at),
                            "track_metadata": listen_payload(ep.track, ep.isrc)},
                "queued_at": self._clock(), "tries": 0, "next": 0.0}
        if self.valid is False or self._mono() < self._rate_limited_until:
            self._enqueue(item)
            return
        body = {"listen_type": "single", "payload": [item["payload"]]}
        code, data, headers = self._post("/submit-listens", body)
        if code == 200:
            self._landed([item])
        elif self._retryable(code):
            self._note_failure(code, data, headers, "listen")
            self._enqueue(item)
        else:
            self._note_failure(code, data, headers, "listen")
            print(f"[scrobble] dropped: {ep.track.artist} - {ep.track.title} "
                  f"({code} {data})", flush=True)

    def _retryable(self, code: int) -> bool:
        return code == 0 or code == 429 or code >= 500

    def _note_failure(self, code, data, headers, what):
        if code == 401:
            self.valid = False
            self.problem = "ListenBrainz rejected the token"
        elif code == 429:
            try:
                wait = float((headers or {}).get("X-RateLimit-Reset-In", RATE_LIMIT_FALLBACK_S))
            except (TypeError, ValueError):
                wait = RATE_LIMIT_FALLBACK_S
            self._rate_limited_until = self._mono() + wait
            self.problem = f"rate limited, {int(wait)} s"
        elif code == 0:
            self.problem = "no network; listens are kept for later"
        else:
            self.problem = f"ListenBrainz answered {code}"
        print(f"[scrobble] {what} failed: {code} {data}", flush=True)

    def _landed(self, items: list[dict]):
        self.problem = None
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
        try:
            with open(self.queue_path) as fh:
                return [json.loads(ln) for ln in fh if ln.strip()]
        except (OSError, json.JSONDecodeError):
            return []

    def _save_queue(self):
        try:
            os.makedirs(os.path.dirname(self.queue_path), exist_ok=True)
            tmp = self.queue_path + ".tmp"
            with open(tmp, "w") as fh:
                for it in self._queue:
                    fh.write(json.dumps(it) + "\n")
            os.replace(tmp, self.queue_path)
        except OSError as exc:
            print(f"[scrobble] queue: {exc}", flush=True)

    def _enqueue(self, item: dict):
        item["tries"] = item.get("tries", 0) + 1
        step = min(item["tries"], len(RETRY_S)) - 1
        wait = RETRY_S[step] if item["tries"] <= len(RETRY_S) else RETRY_HOURLY_S
        item["next"] = self._clock() + wait
        with self._lock:
            self._queue.append(item)
            self._save_queue()
        print(f"[scrobble] queued ({len(self._queue)} waiting), next try in {int(wait)} s",
              flush=True)

    def _retry_queue(self):
        if not self._queue or self.valid is False or self._mono() < self._rate_limited_until:
            return
        now = self._clock()
        with self._lock:
            keep, due = [], []
            for it in self._queue:
                if now - it.get("queued_at", now) > QUEUE_MAX_AGE_S:
                    print(f"[scrobble] gave up after a week: "
                          f"{it['payload']['track_metadata']['track_name']}", flush=True)
                    continue
                (due if it.get("next", 0) <= now else keep).append(it)
            if len(keep) + len(due) != len(self._queue):
                self._queue = keep + due          # something aged out: say so on disk
                self._save_queue()
            if not due:
                return
            batch, later = due[:BATCH], due[BATCH:]
            self._queue = keep + later
            self._save_queue()
        body = {"listen_type": "import", "payload": [it["payload"] for it in batch]}
        code, data, headers = self._post("/submit-listens", body)
        if code == 200:
            self._landed(batch)
            if later:
                return                           # the rest on the next tick
        elif self._retryable(code):
            self._note_failure(code, data, headers, "retry")
            for it in batch:
                self._enqueue(it)
        else:
            self._note_failure(code, data, headers, "retry")
            print(f"[scrobble] dropped {len(batch)} queued listens ({code})", flush=True)

    # ---- for /services --------------------------------------------------------------
    def status(self) -> dict:
        ep = self.episode
        return {
            "user": self.user,
            "token_set": bool(self.token),
            "valid": self.valid,
            "user_name": self.user_name,
            "sources": list(self.sources),
            "playing": ({"title": ep.track.title, "artist": ep.track.artist,
                         "heard_s": int(ep.heard_s), "needs_s": int(ep.needs_s),
                         "listened": ep.listen_sent} if ep is not None else None),
            "last_listen": self.last_listen,
            "queued": len(self._queue),
            "submitted": self.submitted,
            "problem": self.problem,
        }
