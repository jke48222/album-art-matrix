"""Wall control plane — a tiny HTTP API the iOS companion talks to.

Runs as a daemon thread inside the brain, so control works whenever the wall
is on — no Mac required.

  GET  /state   -> full control state + last-shown track (for the app's UI)
  POST /state   -> partial update, e.g. {"mode": "ambient", "brightness": 0.4}
  GET  /journal -> what the wall has worn, newest first (?limit=N, default 50)
  POST /replay  -> {"ts": <journal ts>} re-show that sleeve until next track
  POST /frame   -> {"px": base64 raw RGB, one wall's worth} — doodles and
                   photos; a smaller square is taken and scaled up;
                   switches mode to "frame" so the push is visible immediately
  POST /push    -> what the phone is playing: {track, artist, album, id?,
                   playing, progress_ms, duration_ms, art?}; 40 s TTL
  GET  /nowplaying -> what the chain currently answers, or 204
  GET  /services   -> which music services the wall can use, and their state;
                      "listenbrainz" carries the scrobbler's state too (token_set,
                      valid, playing, last_listen, queued, problem)
  POST /spotify/tokens -> {access_token, refresh_token, expires_in} from the
                   phone's PKCE sign-in; the wall polls Spotify from then on
  POST /spotify/unlink -> forget the Spotify account
  POST /services   -> {spotify: {client_id}, lastfm: {api_key, user},
                   listenbrainz: {user}, ears: {device}}: any
                   subset; kept in services.json, applied at once. This is
                   how every service gets connected from the phone alone.
  POST /video    -> {url, sound?, loop?}: a YouTube link, or any link ffmpeg
                   can read; the wall fetches it and plays it (mode "video").
                   With sound on, the wall makes an audio file for the phone
                   and waits for the phone's clock before it plays.
  GET  /video    -> where the video is: status, title, position, buffered
  GET  /video/audio -> the sound, as an m4a with byte ranges, for AVPlayer
  POST /video/clock -> {t, playing}: the phone's player says where it is;
                   the wall shows the frame for that moment
  POST /video/control -> {action: play|pause|seek, t?}: the wall's own clock
  GET  /tuning   -> every knob that decides what the LEDs do, with ranges
  POST /tuning   -> {knob: value, ...}; says which need the renderer back
  POST /tuning/reset   -> back to what the wall shipped with
  POST /tuning/restart -> relaunch the renderer so launch flags take
  POST /video/stop -> the video is over; back to what the wall was doing
  POST /video/upload?title=&clock=phone -> the body is a small mp4 the phone
                   made from a video of its own; the wall plays the picture
                   and the phone plays the sound it already has
  GET  /homekit  POST /homekit/show?s=  POST /homekit/hide  POST /homekit/refresh
  GET  /features -> the [features] switches and their state
  GET  /teach    -> the wall's own song library: songs, how learnt, matches
  POST /teach/learn {title, artist}   POST /teach/forget {id}   POST /teach/clear
  GET  /ask      -> how asking is going and the last questions and answers
  GET  /note     -> the note on the panel, if one is    GET /show -> the last thing shown by name
  POST /ask      -> {text, reply?: "wall"|"text"}: a question for Claude; the
                   answer comes back and goes on the panel unless reply is text
  POST /note     -> {text, minutes?}: words on the panel for a while
  POST /earworm  -> {words}: name a song from the words remembered; sleeve up
  POST /show     -> {query}: a cover by name    POST /play {query}: a video by name
  GET  /weather  -> the forecast the face draws, the place, its age
  POST /weather/place {query}  a place by name, geocoded   POST /weather/refresh
  GET  /shelf    -> the Discogs collection with plays per release; POST /shelf/sync
  GET  /art/airplay/<key>.jpg -> artwork that arrived over AirPlay, for the phone
  GET  /game/list  GET /game  POST /game/start {name, options, players}
  POST /game/move {player, move}  POST /game/hear {player, text}  POST /game/end
  POST /imagine {prompt} -> a picture from words, on the panel; GET /imagine lists them,
       GET /imagine/<id>.png is one, POST /imagine/show {id} shows it again, POST /imagine/forget {id}
  GET  /voice    -> the wake word, the listener and the last thing heard
  GET  /voice/meter -> the wake word's score and peak, quick, for the phone's meter
  POST /voice/wakeword {name?, threshold?}   POST /voice/wakeword/forget {name}
  POST /voice/enroll {phrase, samples?}: teach a wake word of your own   POST /voice/enroll/cancel
  GET  /airplay  -> the receiver and what is coming in   POST /airplay/restart
  POST /voice/wake  start listening as if the wake word came   POST /voice/say {text}

State persists to ~/.config/album-art-matrix/control.json so the wall comes
back the way you left it. Every accepted POST sets `dirty` (a threading.Event)
— the main loop waits on it instead of sleeping blind, so a slider move
re-renders immediately instead of at the next poll.

Transient things deliberately NOT persisted: the sleep fade (restarting the
wall cancels it), the frame override, a pending replay.
"""
import base64
import hashlib
import json
import math
import os
import threading
import time
import uuid
from dataclasses import asdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

STATE_PATH = os.path.expanduser("~/.config/album-art-matrix/control.json")
JOURNAL_PATH = os.path.expanduser("~/.config/album-art-matrix/journal.jsonl")
JOURNAL_MAX = 500                     # rewrite the file when it grows past this

# The app draws and reads at the wall's own size: what Tessera puts on the
# wall is what the wall shows, pixel for pixel. Anything sending a smaller
# square (an older build, the share extension, a script) is still taken and
# scaled up, and /frame.raw takes ?side=N for a caller that wants a small
# copy for a thumbnail. This is that fallback size, not a limit.
PHONE_SIDE = 64

MODES = ("art", "cd", "ambient", "off", "frame", "ticker", "clock", "clip", "timer", "nine", "lyrics", "video",
         "weather", "game", "imagine")
UPLOAD_MAX = 80_000_000               # a picture the phone sends up, at most
BODY_MAX = 32_000_000                 # the largest JSON body any POST will read
# One Shower serves four routes, but they are three switches: /show and /play
# are both the "show" feature. Route -> (switch, what to call it when it is off).
SHOWER_SWITCH = {
    "show": ("show", "showing a cover by name"),
    "play": ("show", "showing a cover by name"),
    "imagine": ("imagine", "drawing from words"),
    "earworm": ("earworm", "naming a song from the words you remember"),
}
EFFECTS = ("solid", "breathe", "pulse", "rainbow", "gradient", "plaid", "weave", "deco", "snake")
FINISHES = ("clean", "dither", "poster")
IDLES = ("black", "hold", "dim", "ambient", "weather")   # what the wall does in silence
AWAYS = ("stay", "off")                       # what it does when nobody is home

DEFAULTS = {
    "mode": "art",           # art | cd | ambient | off | frame
    "brightness": 1.0,       # 0.05-1.0, scales white-balance gains in linear
    "rpm": 7.5,              # cd mode spin rate (S4 beat grid will own this)
    "effect": "rainbow",     # ambient: solid | breathe | pulse | rainbow | gradient
    "color": "#4060ff",      # ambient solid/breathe/pulse/gradient base color
    "color2": "#ff2080",     # ambient gradient far color
    "speed": 1.0,            # ambient animation rate multiplier, 0.1-3.0
    "match_art": False,      # ambient colors follow the current sleeve
    "finish": "clean",       # art downscale finish: clean | dither | poster
    "ticker_text": "HELLO",  # ticker mode message (<= 120 chars)
    "ticker_loop": True,
    "ticker_style": "across",  # across (slide) | up (prompter) | tilt (crawl)
    "ticker_colors": [],       # per-glyph inks, in glyph order; [] = one ink     # loop, or scroll once then back to art
    "clock_24h": True,       # clock mode: 24-hour vs 12-hour + AM/PM
    "lyric_offset": 0.2,     # seconds the words run ahead of the song
    "spin_face": "pressing", # what the record turns: pressing | art
    "panel_brightness": 160, # the panel's own cap, 1-254; a renderer restart
    "panel_type": 0,         # the panel's row addressing, 0-7; ditto
    "idle": "black",         # silence: black | hold | dim | ambient
    "away": "stay",          # phone gone >15 min: stay | off
    "alarm_enabled": False,  # a time of day the wall rings: the timer's fireworks
    "alarm_time": "07:00",   # local HH:MM
    "wake_enabled": False,   # morning fade-up
    "wake_time": "07:00",    # local HH:MM
    "wake_fade_min": 20.0,   # how long the fade-up takes
    # Calibration multipliers on top of the config gains. Identity until a
    # camera has measured the wall; see the app's calibrate flow.
    "wb_r": 1.0, "wb_g": 1.0, "wb_b": 1.0,
    "sun": "off",            # evenings: follow the sun (needs lat/lon)
    "sun_night": 0.25,       # how much light after dark, share of full
    "lat": 999.0,            # 999 = never told; the app sets these once
    "lon": 999.0,
    "place": "",             # the weather's place, as the phone named it
    "weather_units": "f",    # f | c, for the weather face
    "airplay_receiver": True,  # the wall runs its AirPlay receiver
    "airplay_name": "Wall",  # what it is called in the AirPlay menu
}


_T0 = time.monotonic()               # process start, for /health uptime


def _clamp(v, lo, hi):
    return max(lo, min(hi, float(v)))


class ControlState:
    """Thread-safe control state shared between the API and the main loop."""

    def __init__(self, seed: dict | None = None, frame_len: int = 64 * 64 * 3,
                 wall=None):
        """seed: config.toml defaults — used only when no saved state exists
        (a phone-set state should survive restarts over config defaults).

        wall: the panel arrangement. The app speaks 64x64 and the wall may be
        192x192, so every frame crossing this API is translated: what the
        phone sends is scaled up, what it reads back is scaled down."""
        self._lock = threading.RLock()
        self._s = dict(DEFAULTS)
        self.dirty = threading.Event()
        self.loop_beat = None        # main loop: last pass, for /health
        self.quiet_since = None      # main loop: when the music stopped
        self.idle_now = None         # main loop: idle face in force (black|dim|ambient)
        self.away_now = False
        self.display_mode = self._s["mode"]
        # dirty = redraw what is up; repoll = something may be PLAYING that
        # was not a moment ago (the phone pushed, the ear heard), so the
        # main loop leaves its render stint and asks the chain now.
        self.repoll = threading.Event()
        self.news = threading.Event()        # the poller has a fresh answer
        self.playing_identity = {}
        self.now_showing = {}        # main loop writes {title, artist, album}
        # Where the song is, so a client can run the same clock we do rather
        # than being told a number that is already stale by the time it lands.
        self.progress = {}           # {at, of, playing, stamped}
        self.art_colors = None       # main loop writes ("#rrggbb", "#rrggbb")
        self.frame_len = frame_len
        if wall is None:
            from .wall import Wall
            side = max(16, int(round((frame_len / 3) ** 0.5)))
            wall = Wall(tile=side, cols=1, rows=1)
        self.wall = wall
        self.phone_side = PHONE_SIDE
        self.frame_override = None   # raw RGB bytes for mode "frame"
        self.clip = None             # {"fps": float, "frames": [bytes]}
        self.last_frame = None       # pre-WB RGB of whatever was last shown
        # The record the phone is showing for this song, as raw RGB the size
        # of the panel. The spin face turns this when it is here, so the wall
        # and the room's deck are playing the same pressing.
        self.pressing = None         # (track_id, bytes)
        # Bumps only when the PICTURE changes. The spin face rebuilds its
        # record on this, not on every upload: the phone re-sends the same
        # pressing freely (once a second while it waits for the wall to say
        # it has it, ten times in the second a song changes), and rebuilding
        # the record for each one made the wall flicker between records.
        self.pressing_seq = 0
        # The picture a finish would act on for the face that is up: the
        # sleeve for art and words, the grid for the nine. /finishes renders
        # the three from this, so the phone shows what the wall would do
        # rather than its own guess at it.
        self._finish_base = None
        self.finish_seq = 0                 # bumped whenever the base changes
        self._finish_shots = (-1, None)     # (finish_seq, {name: b64})
        self.replay = None           # journal entry the main loop should re-show
        self.replay_active = False
        self.resume_music = False
        self.ticker_revision = 0
        self.lyric_book = None
        self._ambient_previews = (None, None)
        self.sleep = None            # {"t0": monotonic, "minutes": N} while fading
        self.timer = None            # {"end": monotonic, "total": s, "ret": mode}
        from .routines import RoutineEngine
        self.routines = RoutineEngine()
        self.fps_last = 0.0          # main loop's sustained rate, for /health
        self.last_client = None      # monotonic of the app's last request
        # The adapters, set by build_sources. Every one exists whether or
        # not it has its details yet, so the phone can hand them over later.
        self.pushed = None           # PushedSource
        self.spotify = None          # SpotifySource
        self.lastfm = None           # LastfmSource
        self.listenbrainz = None     # ListenBrainzSource
        self.shelf = None            # brain/shelf.py, the Discogs collection
        self.posters = None          # brain/posters.py, TMDB posters for shows
        self.imaginer = None         # brain/imagine.py, pictures from words
        self.airplay = None          # brain/nowplaying/airplay.py, the receiver
        self.airplay_receiver = None # brain/nowplaying/receiver.py, shairport-sync itself
        self.games = None            # brain/games/host.py, one game at a time
        self.ears = None             # EarsSource: the microphone, named by Shazam
        self.apple = None            # AppleMusicSource (remote mode knows the Mac)
        self.services_store = None   # services.Services: what the phone set
        self.source = None           # the whole chain, for /nowplaying
        self.video = None            # video.player.VideoPlayer, set by main
        self.video_ret = None        # the mode a video interrupted
        self.tuning = None           # tuning.Tuning: every LED knob
        self._showing_before = None  # now_showing from before the video
        # Bumps whenever new content lands (track change, replay, pushed frame
        # or clip) — never on a settings change. Clients key their arrival
        # animations on this instead of guessing from title strings.
        self.shown_seq = 0
        try:
            with open(STATE_PATH) as fh:
                self._merge(json.load(fh), persist=False)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            if seed:
                self._merge(seed, persist=False)
        if self._s["mode"] in ("frame", "clip", "video"):   # overrides die with restart
            self._s["mode"] = "art"

    def get(self) -> dict:
        with self._lock:
            return dict(self._s)

    def nudge(self):
        """A source changed its mind: poll again now, not next tick."""
        self.repoll.set()
        self.dirty.set()

    def _note_current(self) -> bool:
        return (getattr(self, "_note_until", None) is not None
                and self._s["mode"] == "ticker"
                and self.ticker_revision == getattr(self, "_note_revision", None))

    def _clear_note_metadata(self):
        timer = getattr(self, "_note_timer", None)
        if timer is not None and hasattr(timer, "cancel"):
            timer.cancel()
        self._note_timer = None
        self._note_until = None
        self._note_text = None
        self._note_id = None
        self._note_ret = None
        self._note_restore = None
        self._note_generation = getattr(self, "_note_generation", 0) + 1

    def _note_interrupted_by(self, patch: dict):
        # A new face or ticker is intentional, even if it has the same words.
        # The old note must never retake ownership when this face is revisited.
        if getattr(self, "_note_until", None) is not None and (
                ("ticker_text" in patch and isinstance(patch["ticker_text"], str))
                or (patch.get("mode") in MODES and patch["mode"] != "ticker")):
            self._clear_note_metadata()

    def note(self, text: str, minutes: float):
        """Replace the current note atomically, keeping its original return face."""
        with self._lock:
            if self._note_current():
                restore = dict(self._note_restore)
            else:
                here = self._s["mode"]
                previous = here
                if here == "timer":
                    previous = (self.timer or {}).get("ret", "clock")
                elif here == "video":
                    previous = self.video_ret or "art"
                if previous not in MODES or previous in ("timer", "video"):
                    previous = "art"
                restore = {"mode": previous}
                if here == "ticker":
                    restore.update({key: self._s[key] for key in
                                    ("ticker_text", "ticker_colors", "ticker_loop", "ticker_style")})
            self._clear_note_metadata()
            self.apply({"ticker_text": text, "ticker_colors": [], "ticker_loop": True,
                        "ticker_style": "across", "mode": "ticker"})
            self._note_restore = restore
            self._note_ret = restore["mode"]
            self._note_revision = self.ticker_revision
            self._note_id = str(uuid.uuid4())
            self._note_text = self._s["ticker_text"]
            self._note_until = time.monotonic() + minutes * 60.0
            generation = self._note_generation
            timer = threading.Timer(minutes * 60.0, lambda: self._note_over(generation))
            timer.daemon = True
            self._note_timer = timer
            timer.start()

    def clear_note(self, expected_id: str | None = None) -> bool:
        """Dismiss only a note that still owns the current display."""
        with self._lock:
            if expected_id is not None and expected_id != getattr(self, "_note_id", None):
                return False
            current = self._note_current()
            restore = dict(getattr(self, "_note_restore", None) or {"mode": "art"})
            self._clear_note_metadata()
            if current:
                self.apply(restore)
            return current

    def _note_over(self, generation=None):
        with self._lock:
            if generation is not None and generation != getattr(self, "_note_generation", None):
                return
            until = getattr(self, "_note_until", None)
            if until is None or time.monotonic() < until:
                return
            self.clear_note()

    def note_status(self) -> dict:
        with self._lock:
            if not self._note_current():
                self._clear_note_metadata()
                return {"text": None, "seconds_left": None, "active": False, "id": None}
            left = max(0, math.ceil(self._note_until - time.monotonic()))
            if left == 0:
                self.clear_note()
                return {"text": None, "seconds_left": 0, "active": False, "id": None}
            return {"text": self._note_text, "seconds_left": left, "active": True, "id": self._note_id}

    def knock_toggle(self, why: str, want: str | None = None) -> str:
        """Two knocks on the frame, or a whistle: off, or back to the face
        that was up (art when there was none worth keeping). `want` pins
        the direction (a rising whistle means on, a falling one off); a
        knock just flips. Returns "on" or "off", what the wall now is."""
        here = self.get()["mode"]
        going_off = (here != "off") if want is None else (want == "off")
        if going_off:
            if here == "off":
                return "off"
            self.knock_ret = here if here not in ("frame", "clip", "timer", "video") else "art"
            self.apply({"mode": "off"})
            print(f"[control] {why}: off (was {here})", flush=True)
            return "off"
        if here != "off":
            return "on"
        back = getattr(self, "knock_ret", None) or "art"
        self.apply({"mode": back})
        print(f"[control] {why}: on ({back})", flush=True)
        return "on"

    def _merge(self, patch: dict, persist: bool = True) -> dict:
        rejected = {}
        with self._lock:
            for k, v in patch.items():
                numeric = {"wake_fade_min", "wb_r", "wb_g", "wb_b", "sun_night", "lat", "lon",
                           "brightness", "rpm", "speed", "lyric_offset", "panel_brightness", "panel_type"}
                if k in numeric:
                    try:
                        if isinstance(v, bool) or not math.isfinite(float(v)):
                            raise ValueError()
                        v = float(v)
                    except (ValueError, TypeError, OverflowError):
                        rejected[k] = "Expected a finite number"
                        continue
                if k == "mode" and v in MODES:
                    self._s[k] = v
                elif k == "effect" and v in EFFECTS:
                    self._s[k] = v
                elif k == "finish" and v in FINISHES:
                    self._s[k] = v
                elif k == "idle" and v in IDLES:
                    self._s[k] = v
                elif k == "away" and v in AWAYS:
                    self._s[k] = v
                elif k in ("wake_enabled", "alarm_enabled") and isinstance(v, bool):
                    self._s[k] = v
                elif k == "alarm_time" and isinstance(v, str) and len(v) == 5 \
                        and v.isascii() and v[2] == ":" and v[:2].isdigit() and v[3:].isdigit() \
                        and int(v[:2]) < 24 and int(v[3:]) < 60:
                    self._s[k] = v
                elif k == "wake_time" and isinstance(v, str) and len(v) == 5 \
                        and v.isascii() and v[2] == ":" and v[:2].isdigit() and v[3:].isdigit() \
                        and int(v[:2]) < 24 and int(v[3:]) < 60:
                    self._s[k] = v
                elif k == "wake_fade_min":
                    self._s[k] = _clamp(v, 1, 90)
                elif k in ("wb_r", "wb_g", "wb_b"):
                    # Above 1.0 as well as below. config.toml's gains are a
                    # guess until a panel is measured, and if the guess
                    # over-corrects (green and blue pulled down too far,
                    # which reads warm and orange on everything) a cap of
                    # 1.0 leaves no way to dial it back from the phone. The
                    # colour is capped where it is applied, so nothing
                    # clips.
                    self._s[k] = _clamp(v, 0.3, 3.0)
                elif k == "sun" and v in ("off", "on"):
                    self._s[k] = v
                elif k == "sun_night":
                    self._s[k] = _clamp(v, 0.05, 1.0)
                elif k in ("lat", "lon"):
                    bound = 90 if k == "lat" else 180
                    if abs(v) <= bound or (not persist and v == 999):
                        self._s[k] = v
                    else:
                        rejected[k] = "Coordinate outside its valid range"
                elif k == "place" and isinstance(v, str):
                    self._s[k] = "".join(c for c in v if c.isprintable())[:64]
                elif k == "airplay_receiver" and isinstance(v, bool):
                    self._s[k] = v
                elif k == "airplay_name" and isinstance(v, str) and v.strip():
                    self._s[k] = "".join(ch for ch in v if ch.isprintable()).strip()[:40] or "Wall"
                elif k == "weather_units" and v in ("f", "c"):
                    self._s[k] = v
                elif k in ("match_art", "ticker_loop", "clock_24h") and isinstance(v, bool):
                    self._s[k] = v
                elif k == "ticker_style" and v in ("across", "up", "tilt"):
                    self._s[k] = v
                elif k == "ticker_colors" and isinstance(v, list) \
                        and len(v) <= 200 \
                        and all(isinstance(c, str) and len(c) == 7
                                and c.startswith("#")
                                and all(ch in "0123456789abcdefABCDEF"
                                        for ch in c[1:]) for c in v):
                    self._s[k] = [c.lower() for c in v]
                elif k == "ticker_text" and isinstance(v, str):
                    from .art.pixelfont import normalize
                    clean = normalize(v)[:120]
                    self._s[k] = clean if clean.strip() else "?"
                    self.ticker_revision += 1
                elif k == "brightness":
                    self._s[k] = _clamp(v, 0.05, 1.0)
                elif k == "rpm":
                    self._s[k] = _clamp(v, 0.5, 45.0)
                elif k == "speed":
                    self._s[k] = _clamp(v, 0.1, 3.0)
                elif k == "lyric_offset":
                    self._s[k] = _clamp(v, -2.0, 2.0)
                elif k == "panel_brightness":
                    self._s[k] = int(_clamp(v, 1, 254))
                elif k == "panel_type":
                    self._s[k] = int(_clamp(v, 0, 7))
                elif k == "spin_face":
                    if v in ("pressing", "art"):
                        self._s[k] = v
                    else:
                        rejected[k] = v
                elif k in ("color", "color2") and isinstance(v, str) \
                        and len(v) == 7 and v.startswith("#") \
                        and all(c in "0123456789abcdefABCDEF" for c in v[1:]):
                    self._s[k] = v.lower()
                else:
                    rejected[k] = v
            snap = dict(self._s)
        if persist:
            try:
                os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
                with open(STATE_PATH, "w") as fh:
                    json.dump(snap, fh, indent=2)
            except OSError:
                pass
        return rejected

    @property
    def finish_base(self):
        return self._finish_base

    @finish_base.setter
    def finish_base(self, img):
        """Counted, not identified. The previews were keyed on id(picture),
        and a per-frame picture is freed as the next one is made, so CPython
        handed out the same id again and the spinning record served the first
        frame it ever drew for as long as it turned."""
        self._finish_base = img
        self.finish_seq += 1

    def ring(self):
        """Start the daily alarm without losing its eventual return face."""
        with self._lock:
            here = self.get()["mode"]
            ret = self.timer["ret"] if self.timer else \
                (here if here not in ("timer", "video") else "clock")
            self.timer = {"end": time.monotonic(), "total": 60.0, "ret": ret,
                          "kind": "alarm", "id": str(uuid.uuid4()), "snoozed": False}
            self.apply({"mode": "timer"})

    def _timer_action(self, action, event_id):
        """Validate before mutating: a delayed phone tap cannot end a new cue."""
        timer = self.timer
        if not timer or not isinstance(event_id, str) or event_id != timer.get("id"):
            return "This timer has changed. Refresh before trying again."
        ringing = time.monotonic() >= timer["end"]
        if action == "stop":
            return None
        if action == "repeat" and ringing and timer.get("kind") == "countdown":
            return None
        if action == "snooze" and ringing and timer.get("kind") == "alarm":
            return None
        return "This action is not available for the current timer."

    def apply(self, patch: dict) -> dict:
        """Merge a patch, persist, wake the main loop. Returns rejected keys."""
        with self._lock:
            return self._apply_locked(dict(patch))

    def _apply_locked(self, patch: dict) -> dict:
        rejected_commands = {}
        if "timer_action" in patch:
            action = patch.pop("timer_action")
            event_id = patch.pop("timer_id", None)
            error = self._timer_action(action, event_id)
            if error or patch:
                return {"timer_action": error or "Send timer actions on their own."}
            timer = self.timer
            if action == "stop":
                self.timer = None
                patch["mode"] = timer["ret"]
            else:
                total = 300.0 if action == "snooze" else timer["total"]
                self.timer = {**timer, "end": time.monotonic() + total, "total": total,
                              "id": str(uuid.uuid4()), "snoozed": action == "snooze"}
                patch["mode"] = "timer"
        else:
            # An event identifier is a command precondition, never a setting.
            patch.pop("timer_id", None)
        for key in ("timer_min", "sleep_fade_min"):
            if key in patch:
                try:
                    value = patch[key]
                    if isinstance(value, bool) or not math.isfinite(float(value)) or not 0 <= float(value) <= 180:
                        raise ValueError()
                    patch[key] = float(value)
                except (TypeError, ValueError, OverflowError):
                    rejected_commands[key] = "Use a duration from 0 to 180 minutes"
                    patch.pop(key)
        if patch.pop("resume_music", False) or patch.get("mode") in ("art", "cd", "lyrics"):
            self.resume_music = True
            self.replay = None
            self.news.set()
        # sleep fade is a command, not a persisted setting
        if "sleep_fade_min" in patch:
            minutes = _clamp(patch.pop("sleep_fade_min"), 0, 180)
            # monotonic, not wall time: an NTP step on an RTC-less Pi must not
            # snap the fade to the end (or stall it) mid-way
            self.sleep = ({"t0": time.monotonic(), "minutes": minutes}
                          if minutes > 0 else None)
            self.routines.sleep_state = "fading" if minutes > 0 else "cancelled"
            self.routines.sleep_total = minutes * 60
            if minutes > 0:
                self.routines.wake = None
        # A countdown is a command too: it starts now, remembers what the
        # wall was doing, and puts that back when it is done.
        if "timer_min" in patch:
            minutes = _clamp(patch.pop("timer_min"), 0, 180)
            if minutes > 0:
                here = self.get()["mode"]
                ret = self.timer["ret"] if self.timer else \
                    (here if here not in ("timer", "video") else "clock")
                self.timer = {"end": time.monotonic() + minutes * 60,
                              "total": minutes * 60, "ret": ret, "kind": "countdown",
                              "id": str(uuid.uuid4()), "snoozed": False}
                patch["mode"] = "timer"
            else:
                ret = self.timer["ret"] if self.timer else "clock"
                self.timer = None
                if self.get()["mode"] == "timer":
                    patch.setdefault("mode", ret)
        # Leaving the timer is an explicit dismissal; a hidden expired timer
        # must not block the next daily alarm forever.
        if patch.get("mode") in MODES and patch["mode"] != "timer":
            self.timer = None
        if patch.get("mode") == "off":
            self.routines.wake = None
        want = patch.get("panel_brightness")
        if patch.get("panel_type") is not None:
            want = True
        self._note_interrupted_by(patch)
        rejected = {**rejected_commands, **self._merge(patch)}
        # Choosing any other face ends a video: nothing keeps decoding for a
        # picture nobody is looking at.
        if "mode" in patch and self._s["mode"] != "video" \
                and self.video is not None and self.video.busy:
            self.video.stop()
            self.video_ret = None
        # The cap rides on every frame's header now (see sinks/pi_renderer),
        # so a change reaches the panel on the next frame. It is still written
        # down for the renderer's launch, so a reboot starts at the same level.
        # Restarting the renderer here, as this used to, left half a frame in
        # the pipe and every frame after it shifted.
        if want is not None:
            try:
                root = os.path.expanduser("~/album-art-matrix")
                with open(os.path.join(root, "panel-brightness"), "w") as fh:
                    fh.write(str(self._s["panel_brightness"]))
                with open(os.path.join(root, "panel-type"), "w") as fh:
                    fh.write(str(self._s["panel_type"]))
            except Exception as exc:
                print(f"[control] panel brightness: {exc}")
        self.dirty.set()
        return rejected

    def public_state(self) -> dict:
        """What GET /state returns — settings plus live extras."""
        out = {**self.get(), "now_showing": self.now_showing,
               "progress": self.progress, "shown_seq": self.shown_seq,
               "replay_active": self.replay_active, "now_playing": self.playing_identity,
               "idle_active": self.idle_now, "away_active": self.away_now,
               "display_mode": self.display_mode,
               # The shape of the thing on the wall. /frame.raw still answers
               # in phone_side pixels unless asked for the full frame, so an
               # app that ignores these keys keeps working.
               "wall": {"width": self.wall.width, "height": self.wall.height,
                        "tile": self.wall.tile, "cols": self.wall.cols,
                        "rows": self.wall.rows, "frame_side": self.phone_side}}
        # which song the phone's pressing is for, so the app (and anyone
        # looking) can tell whether the spin face has one to turn
        if self.pressing is not None:
            out["pressing_for"] = self.pressing[0]
        # the pressing on the shelf for the song that is on, if it is there
        sh = getattr(self, "shelf", None)
        if sh is not None and sh.playing:
            out["owned"] = sh.playing
        if self.art_colors:
            out["art_colors"] = list(self.art_colors)
        with self._lock:
            out.update(self.routines.snapshot(self, time.time(), time.monotonic()))
        if self.video is not None and (self.video.status != "idle" or self.video.error):
            out["video"] = self.video.public()
        return out

    def tick_routines(self, now=None, mono=None) -> dict:
        now = time.time() if now is None else now
        mono = time.monotonic() if mono is None else mono
        with self._lock:
            self.routines.tick(self, now, mono)
            return self.routines.snapshot(self, now, mono)

    # ---- services -------------------------------------------------------
    def services(self) -> dict:
        """What the app shows on its Services page. No secrets: the Spotify
        client id is public by design (PKCE); keys come back as yes/no."""
        sp, lf, lb, ear, ap = (self.spotify, self.lastfm, self.listenbrainz,
                               self.ears, self.apple)
        hearing = ear.status() if ear else {
            "engine": "shazam", "on": False, "tools": False, "device": "",
            "mic": None, "listening": False, "state": "off", "level_db": None,
            "floor_db": None, "gate_db": None, "gate_open": False,
            "loud_s": None, "quiet_s": None, "heard_s": None, "heard": None,
            "attempts": 0, "matches": 0, "settings": {},
            "problem": "this wall has no ears"}
        return {
            "spotify": {"client_id": sp.client_id if sp else "",
                        "linked": bool(sp and sp.linked)},
            "lastfm": {"user": lf.user if lf else "",
                       "key_set": bool(lf and lf.api_key)},
            # reading needs the username; writing (the ear's listens) needs
            # the token, and the scrobbler says how that is going
            "listenbrainz": {"user": lb.user if lb else "",
                             **(self.scrobbler.status() if getattr(self, "scrobbler", None)
                                else {"token_set": False, "valid": None, "user_name": None,
                                      "sources": [], "playing": None, "last_listen": None,
                                      "queued": 0, "submitted": 0,
                                      "problem": "scrobbling is off on this wall"})},
            "hearing": hearing,
            # Ask the wall: whether a key is set, and how the asking has gone
            "claude": (self.asker.status() if getattr(self, "asker", None)
                       else {"ready": False, "problem": "asking is off on this wall"}),
            # AirPlay: is shairport-sync there, is a stream on, who is sending
            "airplay": ({**self.airplay.status(), "receiver": (self.airplay_receiver.status()
                         if getattr(self, "airplay_receiver", None) else None)}
                        if getattr(self, "airplay", None)
                        else {"running": False, "pipe_exists": False, "reading": False, "state": "off",
                              "error": "AirPlay is off on this wall"}),
            # imagine: which image model, whether its key is set, what it cost
            "images": (self.imaginer.status() if getattr(self, "imaginer", None)
                       else {"ready": False, "provider": "openai", "images": 0,
                             "problem": "drawing from words is off on this wall"}),
            # posters: whether a TMDB key is set and what was last found
            "tmdb": (self.posters.status() if getattr(self, "posters", None)
                     else {"key_set": False, "posters": 0, "known": 0, "last": None,
                           "problem": "posters are off on this wall"}),
            # pictures: whether Google is set up for "show me", and what was last found
            "google": (self.shower.status() if getattr(self, "shower", None)
                       else {"key_set": False, "cx_set": False, "pictures": 0, "last": None,
                             "problem": "show me is off on this wall"}),
            # the shelf: whose Discogs collection, how many releases, when synced
            "discogs": (self.shelf.status() if getattr(self, "shelf", None)
                        else {"user": "", "token_set": False, "releases": 0,
                              "synced_at": None, "syncing": False,
                              "problem": "the shelf is off on this wall"}),
            # the ear's earlier shape, for a phone not rebuilt yet. There is
            # no key any more, so a key is always "set".
            "acoustid": {"key_set": True, "device": hearing["device"],
                         "mic": hearing["mic"], "tools": hearing["tools"],
                         "listening": hearing["listening"],
                         "heard_s": hearing["heard_s"],
                         "problem": hearing["problem"]},
            "phone": {"age_s": (self.pushed.phone_age if self.pushed else None)},
            "mac": {"endpoint": (ap.endpoint if ap else ""),
                    "answering": (ap.answering if ap else None)},
            "ears": bool(hearing["tools"] and hearing["mic"]),
        }

    def apply_services(self, patch: dict) -> dict:
        """Details from the phone: keep them, hand them to the adapters
        now. Returns what was rejected (bad shape, bad value)."""
        store = self.services_store
        if store is None:
            return {"services": "not available"}
        changed, rejected = store.update(patch)
        if "spotify" in changed and self.spotify:
            self.spotify.set_client_id(store.get("spotify", "client_id"))
        if "lastfm" in changed and self.lastfm:
            self.lastfm.configure(store.get("lastfm", "api_key"),
                                  store.get("lastfm", "user"))
        if "listenbrainz" in changed and self.listenbrainz:
            self.listenbrainz.configure(store.get("listenbrainz", "user"))
        if "listenbrainz" in changed and getattr(self, "scrobbler", None):
            self.scrobbler.configure(user=store.get("listenbrainz", "user"),
                                     token=store.get("listenbrainz", "token"))
        if "claude" in changed and getattr(self, "asker", None):
            self.asker.configure(api_key=store.get("claude", "api_key"),
                                 workspace=store.get("claude", "workspace"))
        if "images" in changed and getattr(self, "imaginer", None):
            self.imaginer.configure(provider=store.get("images", "provider") or None,
                                    api_key=store.get("images", "api_key"),
                                    quality=store.get("images", "quality") or None,
                                    model=store.get("images", "model") or None)
        if "tmdb" in changed and getattr(self, "posters", None):
            self.posters.configure(api_key=store.get("tmdb", "api_key"))
        if "google" in changed and getattr(self, "shower", None):
            self.shower.configure(api_key=store.get("google", "api_key"),
                                  cx=store.get("google", "cx"))
        if "discogs" in changed and getattr(self, "shelf", None):
            self.shelf.configure(token=store.get("discogs", "token"),
                                 user=store.get("discogs", "user"))
        if ("ears" in changed or "acoustid" in changed) and self.ears:
            self.ears.configure(device=store.get("ears", "device")
                                or store.get("acoustid", "device"))
        if changed:
            print(f"[control] services set from the phone: "
                  f"{', '.join(changed)}")
            self.nudge()
        return rejected

    # ---- video ----------------------------------------------------------
    def video_start(self, url: str, sound: bool, loop: bool,
                    clock: str = "auto", title: str | None = None):
        """A link from the phone, or a file it sent up. Remembers the face
        that was up so the wall can go back to it when the video is over."""
        if self.video is None:
            return "video is not available on this wall"
        if clock == "auto" and sound:
            # Who keeps time depends on whether anyone is holding the phone.
            # A link shared from the share sheet arrives with no app open,
            # and a wall that waits for a clock nobody is keeping is a wall
            # that does not play. The sound is still fetched either way, so
            # the phone can pick it up when it does come along.
            recent = (self.last_client is not None
                      and time.monotonic() - self.last_client < 90)
            clock = "phone" if recent else "wall"
        here = self.get()["mode"]
        if here != "video":
            self.video_ret = here if here not in ("frame", "clip", "timer") else "art"
            self._showing_before = self.now_showing
        self.video.start(url, sound=sound, loop=loop, clock=clock, title=title)
        self.shown_seq += 1
        self.apply({"mode": "video"})
        return None

    def video_stop(self, error: str | None = None):
        """Over, stopped, or failed: back to what the wall was doing, and
        to the song that was showing."""
        if self.video is not None:
            self.video.stop(error=error)
        if self._showing_before is not None:
            self.now_showing, self._showing_before = self._showing_before, None
            self.shown_seq += 1
        ret, self.video_ret = (self.video_ret or "art"), None
        if self.get()["mode"] == "video":
            self.apply({"mode": ret})
        else:
            self.dirty.set()

    def video_media(self, media):
        """The player resolved the link: the wall now shows a title."""
        src = self.video.url if self.video else ""
        self.now_showing = {"title": media.title, "artist": media.author,
                            "album": ("YouTube" if "youtu" in src
                                      else "Video" if src.lower().startswith("http")
                                      else "From the phone")}
        self.shown_seq += 1
        self.dirty.set()

    # ---- health ---------------------------------------------------------
    def health(self) -> dict:
        """The Pi lives sealed behind panels; this is how you find out it is
        cooking before it matters. Every reading that does not exist on this
        machine is None rather than a guess."""
        temp = None
        try:
            with open("/sys/class/thermal/thermal_zone0/temp") as fh:
                temp = round(int(fh.read().strip()) / 1000.0, 1)
        except (OSError, ValueError):
            pass
        throttled = None
        try:
            import subprocess
            raw = subprocess.run(["vcgencmd", "get_throttled"],
                                 capture_output=True, text=True,
                                 timeout=2).stdout
            bits = int(raw.strip().split("=")[1], 16)
            throttled = {"now": bool(bits & 0x7),        # under-volt/capped/hot
                         "ever": bool(bits & 0x70000)}   # since boot
        except Exception:
            pass
        ytdlp_v = None
        try:
            from .video import ytdlp
            ytdlp_v = ytdlp.version()
        except Exception:
            pass
        return {"fps": round(self.fps_last, 1), "temp_c": temp,
                "throttled": throttled,
                "uptime_s": int(time.monotonic() - _T0),
                "loop_age_s": (None if self.loop_beat is None else round(time.monotonic() - self.loop_beat, 1)),
                "quiet_s": (None if self.quiet_since is None else int(time.monotonic() - self.quiet_since)),
                "idle": self.idle_now,
                "mode": self.get()["mode"],
                "ytdlp": ytdlp_v}

    # ---- journal --------------------------------------------------------
    def journal_append(self, entry: dict):
        """Main loop calls this once per shown sleeve."""
        try:
            os.makedirs(os.path.dirname(JOURNAL_PATH), exist_ok=True)
            with open(JOURNAL_PATH, "a") as fh:
                fh.write(json.dumps(entry) + "\n")
        except OSError:
            return
        try:                                     # occasional trim, best effort
            with open(JOURNAL_PATH) as fh:
                lines = fh.readlines()
            if len(lines) > JOURNAL_MAX:
                with open(JOURNAL_PATH, "w") as fh:
                    fh.writelines(lines[-JOURNAL_MAX:])
        except OSError:
            pass

    def journal_mark(self, title: str, artist: str, since_ts: int, patch: dict) -> int:
        """Add to the entries for a song written since `since_ts` (a small
        slack before it, since the sleeve goes up before the ear's clock
        is settled). Returns how many were marked. Rewrites the file: it is
        small (JOURNAL_MAX lines) and this happens a few times a night."""
        def plain(x):
            return (x or "").strip().lower()
        try:
            with open(JOURNAL_PATH) as fh:
                lines = fh.readlines()
        except OSError:
            return 0
        marked, out = 0, []
        for ln in lines:
            try:
                e = json.loads(ln)
            except json.JSONDecodeError:
                out.append(ln)
                continue
            if e.get("ts", 0) >= since_ts - 30 and plain(e.get("title")) == plain(title) \
                    and plain(e.get("artist")) == plain(artist):
                e.update(patch)
                marked += 1
                out.append(json.dumps(e) + "\n")
            else:
                out.append(ln)
        if marked:
            try:
                with open(JOURNAL_PATH, "w") as fh:
                    fh.writelines(out)
            except OSError:
                return 0
        return marked

    def play_sting(self):
        """The Tessera sting, once, on the wall's own dots (art/sting.py):
        at boot, or asked for with POST /sting. It plays as a clip that
        knows to stop, and hands back to the face it interrupted."""
        from .art.sting import FPS, Sting
        frames = Sting.get(self.wall.width).boot_frames()
        if not frames:
            return                     # no film to be had; the sting said why
        here = self.get()["mode"]
        ret = here if here not in ("clip", "frame", "timer", "video") else "art"
        self.clip = {"fps": FPS, "frames": frames, "once": True, "ret": ret}
        self.shown_seq += 1
        self.apply({"mode": "clip"})

    def journal_read(self, limit: int = 50) -> list[dict]:
        try:
            with open(JOURNAL_PATH) as fh:
                lines = fh.readlines()
        except OSError:
            return []
        out = []
        for ln in reversed(lines[-limit * 2:]):
            try:
                out.append(json.loads(ln))
            except json.JSONDecodeError:
                continue
            if len(out) >= limit:
                break
        return out


def serve(ctrl: ControlState, port: int) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        # Keep the connection open between requests. On HTTP/1.0 every call
        # closed its socket, so the phone resolved album-matrix.local afresh
        # each time: a request that costs ten milliseconds on the wire spent
        # two hundred more on mDNS, and the app, polling several times a
        # second, spent its life waiting on name lookups.
        protocol_version = "HTTP/1.1"

        def _json(self, code: int, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            # The web control plane calls this API from a browser; without
            # CORS headers the browser refuses to deliver the response.
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def _empty(self, code: int, extra=()):
            self.send_response(code)
            self.send_header("Access-Control-Allow-Origin", "*")
            # keep-alive needs every response to say how long it is, and a
            # 204 says it by being defined as empty
            if code != 204:
                self.send_header("Content-Length", "0")
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()

        def do_OPTIONS(self):
            # Preflight for browser POSTs (application/json).
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.end_headers()

        def _body(self) -> dict | None:
            # Capped the way /video/upload is. The Pi has under a gigabyte and
            # a one-minute watchdog: a client claiming half of it in a
            # Content-Length should be refused, not read into memory.
            try:
                n = int(self.headers.get("Content-Length", 0))
            except ValueError:
                self._json(400, {"error": "body must be a JSON object"})
                return None
            if n > BODY_MAX:
                self._json(413, {"error": f"the body must be under {BODY_MAX // 1_000_000} MB"})
                return None
            try:
                patch = json.loads(self.rfile.read(n) or b"{}")
                if not isinstance(patch, dict):
                    raise ValueError
                return patch
            except (ValueError, json.JSONDecodeError):
                self._json(400, {"error": "body must be a JSON object"})
                return None

        def _switched_off(self, name: str, what: str) -> bool:
            """Ask a feature's switch at the moment it would act, the way
            features.py says every feature should. Features that own an
            object (the shower, the games) are already gated by main.py
            never building it; this is for the ones that act on ctrl
            directly, or that share another feature's object."""
            fe = getattr(ctrl, "features", None)
            if fe is not None and not fe.on(name):
                self._json(404, {"error": f"{what} is off on this wall"})
                return True
            return False

        def _send_file(self, path, ctype: str, head: bool = False):
            """A file with byte ranges, which is how AVPlayer reads sound:
            a few bytes first, then pieces, then wherever a scrub lands."""
            try:
                size = os.path.getsize(path)
            except OSError:
                self._json(404, {"error": "no sound yet"})
                return
            start, end, code = 0, size - 1, 200
            rng = self.headers.get("Range", "")
            if rng.startswith("bytes="):
                a, _, b = rng[6:].partition("-")
                try:
                    if a:
                        start, end = int(a), (int(b) if b else size - 1)
                    else:
                        start = max(0, size - int(b))
                except ValueError:
                    start, end = 0, size - 1
                end = min(end, size - 1)
                if start > end or start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                code = 206
            length = end - start + 1
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Access-Control-Allow-Origin", "*")
            if code == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if head:
                return
            try:
                with open(path, "rb") as fh:
                    fh.seek(start)
                    left = length
                    while left > 0:
                        chunk = fh.read(min(65536, left))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        left -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass          # the player stopped asking; that is its right

        def do_HEAD(self):
            if self.path.startswith("/video/audio") and ctrl.video is not None \
                    and ctrl.video.audio_path and ctrl.video.audio_ready:
                self._send_file(ctrl.video.audio_path, "audio/mp4", head=True)
                return
            self._empty(404)

        def do_GET(self):
            u = urlparse(self.path)
            if u.path.startswith("/video/audio"):
                v = ctrl.video
                if v is None or not v.audio_path or not v.audio_ready:
                    self._json(404, {"error": "no sound yet"})
                    return
                self._send_file(v.audio_path, "audio/mp4")
                return
            if u.path.startswith("/video"):
                self._json(200, ctrl.video.public() if ctrl.video is not None
                           else {"status": "idle"})
                return
            if u.path.startswith("/tuning"):
                if ctrl.tuning is None:
                    self._json(503, {"error": "tuning is not available on this wall"})
                    return
                self._json(200, ctrl.tuning.public())
                return
            if u.path.startswith("/frame.raw"):
                px = ctrl.last_frame
                if px is None:
                    self._json(404, {"error": "nothing shown yet"})
                    return
                # The wall's own frame, at the wall's own size. A caller that
                # wants a small copy (a thumbnail, a list) asks for ?side=64
                # and gets a box average rather than every ninth LED.
                side = ctrl.wall.width
                want = parse_qs(u.query).get("side", [""])[0]
                if want.isdigit() and 16 <= int(want) < ctrl.wall.width:
                    side = int(want)
                    px = ctrl.wall.phone_view(px, side)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(px)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("X-Frame-Width", str(side))
                self.send_header("X-Frame-Height", str(side))
                self.end_headers()
                self.wfile.write(px)
                return
            if u.path == "/lyrics":
                book = ctrl.lyric_book
                self._json(200, book.snapshot() if book else {"state": "idle", "lines": []})
                return
            if u.path == "/ambient/previews":
                from .art.effects import Ambient
                state = ctrl.get()
                colors = ctrl.art_colors if state["match_art"] and ctrl.art_colors else [state["color"], state["color2"]]
                c1, c2 = colors[0], colors[-1]
                # One fixed moment, produced by exactly the renderer on the wall.
                key = (c1, c2, state["speed"])
                cached_key, cached = ctrl._ambient_previews
                if key == cached_key:
                    self._json(200, cached)
                    return
                shots = {name: base64.b64encode(Ambient(64, name, c1, c2, state["speed"])
                         .frame_at(8).tobytes()).decode() for name in
                         ("solid", "breathe", "pulse", "rainbow", "gradient", "plaid", "weave", "deco", "snake")}
                ctrl._ambient_previews = (key, shots)
                self._json(200, shots)
                return
            if u.path.startswith("/finishes"):
                # What each finish would look like, on the sleeve that is on,
                # rendered by the wall itself. The phone used to draw these
                # from its own copy of the art and they never quite matched:
                # a different downscale, no unsharp, no white balance.
                base = ctrl.finish_base
                if base is None:
                    self._json(404, {"error": "nothing prepared yet"})
                    return
                # Rendered when the picture changes, not when asked: the phone
                # asks twice a second and three quantisations per request, on a
                # wall already drawing sixty frames a second, is how a preview
                # comes back late or not at all.
                key, shots = ctrl._finish_shots
                if key != ctrl.finish_seq:
                    from .art.pipeline import apply_finish
                    # Full size, because a finish IS a quantisation: shrink
                    # it for the phone and a box average smooths the dither
                    # back into the flat picture it was meant to be told from.
                    shots = {n: base64.b64encode(
                        apply_finish(base, n).convert("RGB").tobytes()).decode()
                        for n in ("clean", "dither", "poster")}
                    ctrl._finish_shots = (ctrl.finish_seq, shots)
                self._json(200, shots)
                return

            if u.path.startswith("/voice/meter"):
                v = getattr(ctrl, "voice", None)
                self._json(200, v.meter() if v is not None else {"state": "off"})
                return
            if u.path.startswith("/voice"):
                v = getattr(ctrl, "voice", None)
                self._json(200, v.status() if v is not None else {"on": False, "state": "off"})
                return
            if u.path.startswith("/weather"):
                w = getattr(ctrl, "weather", None)
                self._json(200, w.status() if w is not None else {"problem": "the weather is off on this wall"})
                return
            if u.path.startswith("/game"):
                gh = getattr(ctrl, "games", None)
                if gh is None:
                    self._json(200, {"running": False, "games": [], "problem": "games are off on this wall"})
                    return
                if u.path.startswith("/game/list"):
                    self._json(200, {"games": gh.listing(), **gh.status()})
                    return
                self._json(200, gh.status())
                return
            if u.path.startswith("/airplay"):
                ap = getattr(ctrl, "airplay", None)
                rx = getattr(ctrl, "airplay_receiver", None)
                self._json(200, {**(ap.status() if ap is not None else {"state": "off"}),
                                 "receiver": rx.status() if rx is not None else None})
                return
            if u.path.startswith("/art/airplay/"):
                ap = getattr(ctrl, "airplay", None)
                key = u.path.rsplit("/", 1)[1].split(".")[0]
                hit = ap.art(key) if ap is not None else None
                if hit is None:
                    self._json(404, {"error": "no such artwork"})
                    return
                data, mime = hit
                self.send_response(200)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "max-age=86400")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(data)
                return
            if u.path.startswith("/imagine"):
                im = getattr(ctrl, "imaginer", None)
                if im is None:
                    self._json(200, {"ready": False, "images": [], "problem": "drawing from words is off on this wall"})
                    return
                tail = u.path[len("/imagine"):].strip("/")
                if tail.endswith(".png"):
                    path = im.image_path(tail[:-4])
                    if path is None:
                        self._json(404, {"error": "no such picture"})
                        return
                    with open(path, "rb") as fh:
                        data = fh.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "image/png")
                    self.send_header("Content-Length", str(len(data)))
                    self.send_header("Cache-Control", "max-age=86400")
                    self.send_header("Access-Control-Allow-Origin", "*")
                    self.end_headers()
                    self.wfile.write(data)
                    return
                self._json(200, {**im.status(), "images": im.listing()})
                return
            if u.path.startswith("/ask"):
                a = getattr(ctrl, "asker", None)
                self._json(200, a.status() if a is not None else {"ready": False, "problem": "asking is off on this wall"})
                return
            if u.path.startswith("/note"):
                if self._switched_off("note", "notes"):
                    return
                self._json(200, ctrl.note_status())
                return
            if u.path.startswith("/show"):
                sh = getattr(ctrl, "shower", None)
                self._json(200, {"last": getattr(sh, "last", None)} if sh is not None else {"last": None})
                return
            if u.path.startswith("/shelf"):
                sh = getattr(ctrl, "shelf", None)
                if sh is None:
                    self._json(200, {"releases": [], "problem": "the shelf is off on this wall"})
                    return
                self._json(200, {**sh.status(), "releases": sh.listing(ctrl.journal_read(500))})
                return
            if u.path.startswith("/teach"):
                # the wall's own song library: what it knows and how it learnt it
                ear = ctrl.ears
                lib = getattr(ear, "_library_kept", None) if ear is not None else None
                if lib is None:
                    self._json(200, {"enabled": False, "songs": []})
                    return
                self._json(200, {"enabled": ear.library is not None, **lib.status(),
                                 "teacher": (ear.teacher.status() if ear.teacher else None),
                                 "songs": lib.listing()})
                return
            if u.path.startswith("/journal"):
                try:
                    limit = int(parse_qs(u.query).get("limit", ["50"])[0])
                except ValueError:
                    limit = 50
                self._json(200, {"entries": ctrl.journal_read(limit)})
                return
            if u.path.startswith("/homekit"):
                hk = getattr(ctrl, "homekit", None)
                self._json(200, hk.status() if hk is not None else {"enabled": False})
                return
            if u.path.startswith("/features"):
                fe = getattr(ctrl, "features", None)
                self._json(200, fe.public() if fe is not None else {"features": [], "off": []})
                return
            if u.path.startswith("/health"):
                self._json(200, ctrl.health())
                return
            if u.path.startswith("/state"):
                ctrl.last_client = time.monotonic()
                self._json(200, ctrl.public_state())
                return
            if u.path.startswith("/services"):
                self._json(200, ctrl.services())
                return
            if u.path.startswith("/nowplaying"):
                try:
                    now = ctrl.source.get_current() if ctrl.source else None
                except Exception as exc:
                    self._json(500, {"error": str(exc)[:200]})
                    return
                age = ctrl.pushed.phone_age if ctrl.pushed else None
                hdr = [("X-Phone-Age", f"{age:.0f}")] if age is not None else []
                if now is None:
                    self._empty(204, hdr)
                    return
                self.send_response(200)
                body = json.dumps(asdict(now)).encode()
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Access-Control-Allow-Origin", "*")
                for k, v in hdr:
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)
                return
            self._json(404, {"error": "not found"})

        def do_POST(self):
            if self.path == "/routines/preview":
                patch = self._body()
                if patch is None:
                    return
                try:
                    from .art.text_modes import Clock, Countdown
                    face = patch.get("face", "clock")
                    at = float(patch.get("at", time.time()))
                    remaining = float(patch.get("remaining_s", 300))
                    total = float(patch.get("total_s", max(1, remaining)))
                    kind = patch.get("kind", "countdown")
                    snoozed = patch.get("snoozed", False)
                    twenty_four = patch.get("twenty_four", ctrl.get()["clock_24h"])
                    if (face not in ("clock", "timer") or not isinstance(twenty_four, bool)
                            or kind not in ("countdown", "alarm") or not isinstance(snoozed, bool)):
                        raise ValueError()
                    if not all(math.isfinite(v) for v in (at, remaining, total)) or not -180 <= remaining <= 10800 or not 0 < total <= 10800:
                        raise ValueError()
                    side = ctrl.wall.width
                    state = ctrl.get()
                    ink = ctrl.art_colors[0] if state["match_art"] and ctrl.art_colors else state["color"]
                    frame = (Clock(side, ink, twenty_four).frame_at(0, when=at) if face == "clock"
                             else Countdown(side, ink, state["color2"]).frame_at(remaining, total, kind, snoozed))
                    if face == "clock":
                        from .art.pipeline import apply_finish
                        frame = apply_finish(frame, state["finish"])
                    self._json(200, {"px": base64.b64encode(frame.tobytes()).decode(), "side": side, "at": at})
                except (TypeError, ValueError, OverflowError, OSError):
                    self._json(400, {"error": "Check the face, time and duration."})
                return
            if self.path == "/ticker/preview":
                patch = self._body()
                if patch is None:
                    return
                from .art.text_modes import Ticker, Crawl
                from .art.pixelfont import normalize
                try:
                    text = patch.get("text", "")
                    style = patch.get("style", "across")
                    colors = patch.get("colors", [])
                    color = patch.get("color", "#f4f1ea")
                    speed = float(patch.get("speed", 1))
                    phase = float(patch.get("phase", 0.35))
                    valid_color = lambda c: isinstance(c, str) and len(c) == 7 and c[0] == "#" and all(ch in "0123456789abcdefABCDEF" for ch in c[1:])
                    if not isinstance(text, str) or len(text) > 600 or style not in ("across", "up", "tilt"):
                        raise ValueError("Invalid message or motion")
                    if not isinstance(colors, list) or len(colors) > 200 or not all(valid_color(c) for c in colors) or not valid_color(color):
                        raise ValueError("Invalid letter colours")
                    if not math.isfinite(speed) or not math.isfinite(phase):
                        raise ValueError("Invalid preview position")
                    size = ctrl.wall.width
                    args = dict(color=color, speed=max(0.1, min(3, speed)), loop=False, colors=colors)
                    text = normalize(text)[:120]
                    renderer = Ticker(size, text, **args) if style == "across" else Crawl(size, text, tilt=style == "tilt", **args)
                    travel = renderer.travel
                    duration = travel / renderer.px_per_s
                    t = max(0, min(1, phase)) * duration
                    pixels = renderer.frame_at(t).tobytes() if text.strip() else bytes(size * size * 3)
                    self._json(200, {"px": base64.b64encode(pixels).decode(), "side": size, "duration": duration, "time": t})
                except (TypeError, ValueError, OverflowError):
                    self._json(400, {"error": "Check the message, colours and preview position."})
                return
            if self.path.startswith("/homekit/"):
                # the pairing code, drawn on the panel; and taken down
                hk = getattr(ctrl, "homekit", None)
                if hk is None:
                    self._json(404, {"error": "homekit is off in config.toml"})
                    return
                if self.path.startswith("/homekit/show"):
                    # ?s=900 keeps the code up longer than the default three
                    # minutes, for a pairing that is being sorted out slowly
                    try:
                        secs = float(parse_qs(urlparse(self.path).query).get("s", ["180"])[0])
                    except ValueError:
                        secs = 180.0
                    ok = hk.show_code(max(30.0, min(1800.0, secs)))
                    self._json(200 if ok else 503, hk.status())
                    return
                if self.path.startswith("/homekit/hide"):
                    hk.hide_code()
                    self._json(200, hk.status())
                    return
                if self.path.startswith("/homekit/refresh"):
                    ok = hk.refresh()
                    self._json(200 if ok else 503, hk.status())
                    return
                self._json(404, {"error": "not found"})
                return
            if self.path.startswith("/ask"):
                patch = self._body()
                if patch is None:
                    return
                text = patch.get("text", "")
                if not isinstance(text, str) or not text.strip() or len(text) > 2000:
                    self._json(400, {"error": "Write a question from 1 to 2000 characters."})
                    return
                reply_mode = patch.get("reply", "wall")
                if reply_mode not in ("wall", "text"):
                    self._json(400, {"error": "Choose wall or text for the answer."})
                    return
                asker = getattr(ctrl, "asker", None)
                if asker is None or not asker.ready:
                    self._json(503, {"error": "Add your Claude key in Services to begin."})
                    return
                reply = asker.ask_reply(text.strip(), size=ctrl.wall.width)
                if reply.get("busy") or reply.get("error"):
                    self._json(409 if reply.get("busy") else 502, {"error": reply["error"]})
                    return
                answer = reply["answer"]
                shown = False
                voice = getattr(ctrl, "voice", None)
                if reply_mode == "wall" and voice is not None:
                    with ctrl._lock:
                        if ctrl.get()["mode"] != "off" and ctrl.display_mode != "off" and ctrl.timer is None:
                            shown = voice.show_answer(answer)
                self._json(200, {"answer": answer, "shown": shown})
                return
            if self.path.startswith("/note"):
                if self._switched_off("note", "notes"):
                    return
                patch = self._body()
                if patch is None:
                    return
                if patch.get("clear") is True:
                    note_id = patch.get("id")
                    if not isinstance(note_id, str) or not note_id:
                        self._json(400, {"error": "Refresh the current note before taking it down."})
                        return
                    with ctrl._lock:
                        current = ctrl.note_status()
                        if current.get("id") != note_id:
                            self._json(409, {"error": "The note has changed. Refresh before taking it down."})
                            return
                        cleared = ctrl.clear_note(expected_id=note_id)
                        self._json(200, {"cleared": cleared, **ctrl.note_status()})
                    return
                text = patch.get("text", "")
                if not isinstance(text, str) or not text.strip():
                    self._json(400, {"error": "Write a message first."})
                    return
                from .art.pixelfont import normalize
                text = normalize(text.strip())[:120]
                try:
                    raw_minutes = patch.get("minutes", 30)
                    if isinstance(raw_minutes, bool):
                        raise ValueError()
                    minutes = float(raw_minutes)
                    if not math.isfinite(minutes) or not 0.5 <= minutes <= 720:
                        raise ValueError()
                except (TypeError, ValueError, OverflowError):
                    self._json(400, {"error": "Choose a duration from 0.5 to 720 minutes."})
                    return
                ctrl.note(text, minutes)
                self._json(200, {"shown": True, "minutes": minutes, **ctrl.note_status()})
                return
            if self.path.startswith("/airplay/restart"):
                rx = getattr(ctrl, "airplay_receiver", None)
                if rx is None:
                    self._json(404, {"error": "AirPlay is off on this wall"})
                    return
                rx.restart()
                self._json(200, {"restarting": True, "receiver": rx.status()})
                return
            if self.path.startswith("/game/"):
                gh = getattr(ctrl, "games", None)
                if gh is None:
                    self._json(404, {"error": "games are off on this wall"})
                    return
                patch = self._body()
                if patch is None:
                    return
                player = str(patch.get("player") or "")
                if self.path.startswith("/game/start"):
                    players = patch.get("players")
                    if not isinstance(players, list):
                        players = [player] if player else None
                    result = gh.start(str(patch.get("name") or ""), patch.get("options") or {}, players)
                elif self.path.startswith("/game/move"):
                    mv = patch.get("move")
                    result = gh.move(player, mv if isinstance(mv, dict) else {"guess": mv})
                elif self.path.startswith("/game/hear"):
                    heard = gh.hear(str(patch.get("text") or ""), player)
                    result = heard if heard is not None else {"error": "not a move in this game", **gh.status()}
                elif self.path.startswith("/game/end"):
                    result = gh.end()
                else:
                    self._json(404, {"error": "not found"})
                    return
                self._json(404 if result.get("error") else 200, result)
                return
            if self.path.startswith("/imagine/"):
                im = getattr(ctrl, "imaginer", None)
                if im is None:
                    self._json(404, {"error": "drawing from words is off on this wall"})
                    return
                patch = self._body()
                if patch is None:
                    return
                image_id = str(patch.get("id") or "").strip()
                if self.path.startswith("/imagine/show"):
                    result = im.show_again(image_id)
                elif self.path.startswith("/imagine/forget"):
                    result = im.forget(image_id)
                else:
                    self._json(404, {"error": "not found"})
                    return
                self._json(404 if result.get("error") else 200, result)
                return
            if self.path.startswith("/earworm") or self.path.startswith("/show") \
                    or self.path.startswith("/play") or self.path.startswith("/imagine"):
                sh = getattr(ctrl, "shower", None)
                if sh is None:
                    self._json(404, {"error": "this wall cannot do that yet"})
                    return
                what = self.path.strip("/").split("/")[0].split("?")[0]
                # The shower answers for four routes but they are three
                # features: show and play are both "show". Without this,
                # "show = false" took earworm down with it and
                # "earworm = false" did nothing at all.
                # .get, not [what]: startswith means "/showtime" reaches here
                # too, and an unknown tail should be a 404 rather than a 500.
                known = SHOWER_SWITCH.get(what)
                if known is None or not hasattr(sh, what):
                    self._json(404, {"error": "this wall cannot do that yet"})
                    return
                if self._switched_off(*known):
                    return
                patch = self._body()
                if patch is None:
                    return
                text = str(patch.get("text") or patch.get("query") or patch.get("words")
                           or patch.get("prompt") or "").strip()
                if not text:
                    self._json(400, {"error": "some words, please"})
                    return
                if what == "show":
                    # "picture", "cover" or "any": what the words are for
                    result = sh.show(text, kind=str(patch.get("kind") or "any"))
                else:
                    result = getattr(sh, what)(text)
                code = 200 if not (isinstance(result, dict) and result.get("error")) else 404
                self._json(code, result if isinstance(result, dict) else {"said": result})
                return
            if self.path.startswith("/shelf/sync"):
                sh = getattr(ctrl, "shelf", None)
                if sh is None:
                    self._json(404, {"error": "the shelf is off on this wall"})
                    return
                if not sh.configured:
                    self._json(400, {"error": "set the Discogs token and username first", **sh.status()})
                    return
                sh.sync_soon()
                self._json(200, {**sh.status(), "syncing": True})
                return
            if self.path.startswith("/weather/"):
                w = getattr(ctrl, "weather", None)
                if w is None:
                    self._json(404, {"error": "the weather is off on this wall"})
                    return
                patch = self._body()
                if patch is None:
                    return
                if self.path.startswith("/weather/place"):
                    # a place by name, geocoded once; the face follows within seconds
                    q = str(patch.get("query") or patch.get("place") or "").strip()
                    if not q:
                        self._json(400, {"error": "a place name, please"})
                        return
                    found = w.set_place(q)
                    if found is None:
                        self._json(404, {"error": f"no place called {q}"})
                        return
                    self._json(200, {"place": found, **w.status()})
                    return
                if self.path.startswith("/weather/refresh"):
                    w.refresh()
                    self._json(200, w.status())
                    return
                self._json(404, {"error": "not found"})
                return
            if self.path.startswith("/voice/"):
                v = getattr(ctrl, "voice", None)
                if v is None:
                    self._json(404, {"error": "the voice is off on this wall"})
                    return
                patch = self._body()
                if patch is None:
                    return
                if self.path.startswith("/voice/wakeword/forget"):
                    r = v.forget_wake(str(patch.get("name", "")))
                    self._json(404 if r.get("error") else 200, {**v.status(), **r})
                    return
                if self.path.startswith("/voice/wakeword"):
                    out = {}
                    if patch.get("threshold") is not None:
                        try:
                            th = round(max(0.3, min(0.95, float(patch["threshold"]))), 3)
                        except (TypeError, ValueError):
                            self._json(400, {"error": "a threshold from 0.3 to 0.95"})
                            return
                        if v.wake is not None:
                            from .voice import wake as wake_mod
                            v.wake.configure(threshold=th)
                            wake_mod.save_threshold(v.wake.name, th)
                        tune = getattr(ctrl, "tuning", None)
                        if tune is not None:
                            try:
                                tune.update({"wake_threshold": th})
                            except Exception as exc:
                                print(f"[control] wake threshold not kept: {exc}", flush=True)
                        out["threshold"] = th
                    if patch.get("name"):
                        r = v.set_wake(str(patch["name"]))
                        if r.get("error"):
                            self._json(404, {**v.status(), **r})
                            return
                        out.update(r)
                    self._json(200, {**v.status(), **out})
                    return
                if self.path.startswith("/voice/enroll/cancel"):
                    self._json(200, {**v.status(), **v.enroll_cancel()})
                    return
                if self.path.startswith("/voice/enroll"):
                    try:
                        samples = int(patch.get("samples") or 6)
                    except (TypeError, ValueError):
                        samples = 6
                    r = v.enroll_start(str(patch.get("phrase", "")), samples)
                    self._json(409 if r.get("error") else 200, {**v.status(), **r})
                    return
                if self.path.startswith("/voice/wake"):
                    v.wake_now()
                    self._json(200, v.status())
                    return
                if self.path.startswith("/voice/say"):
                    ok = v.say(str(patch.get("text", "")))
                    self._json(200 if ok else 409, v.status())
                    return
                self._json(404, {"error": "not found"})
                return
            if self.path.startswith("/teach/"):
                ear = ctrl.ears
                lib = getattr(ear, "_library_kept", None) if ear is not None else None
                if lib is None:
                    self._json(404, {"error": "this wall has no song library"})
                    return
                patch = self._body()
                if patch is None:
                    return
                if self.path.startswith("/teach/forget"):
                    ok = lib.forget(str(patch.get("id", "")))
                    self._json(200 if ok else 404, {"forgot": ok, **lib.status()})
                    return
                if self.path.startswith("/teach/clear"):
                    lib.clear()
                    self._json(200, lib.status())
                    return
                if self.path.startswith("/teach/learn"):
                    # by name: the preview is fetched now, on this request
                    title, artist = str(patch.get("title", "")).strip(), str(patch.get("artist", "")).strip()
                    if not title or not artist or ear.teacher is None:
                        self._json(400, {"error": "title and artist, please"})
                        return
                    song = ear.teacher.learn_named(title, artist)
                    if song is None:
                        self._json(404, {"error": f"iTunes has no preview for {artist} - {title}"})
                        return
                    self._json(200, {"learnt": song, **lib.status()})
                    return
                self._json(404, {"error": "not found"})
                return
            if self.path == "/lyrics/retry":
                if ctrl.lyric_book is not None and ctrl.lyric_book.state in ("none", "error"):
                    ctrl.lyric_book.track = None
                    ctrl.nudge()
                self._json(200, {"requested": True})
                return
            if self.path.startswith("/replay"):
                patch = self._body()
                if patch is None:
                    return
                ts = patch.get("ts")
                entry = next((e for e in ctrl.journal_read(200)
                              if e.get("ts") == ts and all(patch.get(k) is None or e.get(k) == patch[k]
                              for k in ("title", "artist", "art_url"))), None)
                if entry is None:
                    self._json(404, {"error": "no such journal entry"})
                    return
                ctrl.apply({"mode": "art"})
                ctrl.resume_music = False
                ctrl.replay = entry
                ctrl.replay_active = True
                ctrl.news.set()
                self._json(200, ctrl.public_state())
                return

            if self.path.startswith("/frame"):
                patch = self._body()
                if patch is None:
                    return
                try:
                    px = base64.b64decode(patch.get("px", ""), validate=True)
                except (ValueError, TypeError):
                    px = b""
                px = ctrl.wall.fit(px)
                if px is None:
                    self._json(400, {"error":
                                     f"px must be square raw RGB, "
                                     f"{ctrl.phone_side}x{ctrl.phone_side} or "
                                     f"{ctrl.wall.width}x{ctrl.wall.height}, "
                                     "base64-encoded"})
                    return
                ctrl.frame_override = px
                ctrl.shown_seq += 1
                ctrl.apply({"mode": "frame"})
                self._json(200, ctrl.public_state())
                return

            if self.path.startswith("/pressing"):
                # The record the phone drew for the song that is on: raw RGB,
                # panel-sized, base64. Kept until the song changes.
                data = self._body()
                if data is None:
                    return
                try:
                    px = base64.b64decode(data.get("px", ""), validate=True)
                except (ValueError, TypeError):
                    px = b""
                px = ctrl.wall.fit(px)
                if px is None:
                    self._json(400, {"error":
                                     f"px must be square raw RGB, "
                                     f"{ctrl.phone_side}x{ctrl.phone_side} or "
                                     f"{ctrl.wall.width}x{ctrl.wall.height}, "
                                     "base64-encoded"})
                    return
                track = str(data.get("track") or "")
                cur = ctrl.pressing
                same = cur is not None and cur[1] == px
                if same and cur[0] == track:
                    self._empty(204)          # the wall already has this one
                    return
                if not same:
                    ctrl.pressing_seq += 1
                    print(f"[pressing] {track or 'unnamed'}: picture #{ctrl.pressing_seq} "
                          f"({hashlib.md5(px).hexdigest()[:6]}) from {self.client_address[0]}")
                ctrl.pressing = (track, px)
                if not same:
                    ctrl.dirty.set()
                self._empty(204)
                return

            if self.path.startswith("/sting"):
                # the logo, on request: the same cut the wall plays at boot
                if self._switched_off("sting", "the logo on the wall"):
                    return
                ctrl.play_sting()
                self._json(200, ctrl.public_state())
                return

            if self.path.startswith("/clip"):
                patch = self._body()
                if patch is None:
                    return
                raw = patch.get("frames")
                fps = patch.get("fps", 12)
                if not isinstance(raw, list) or not 1 <= len(raw) <= 240:
                    self._json(400, {"error": "frames must be 1-240 items"})
                    return
                frames = []
                for f in raw:
                    try:
                        b = base64.b64decode(f, validate=True)
                    except (ValueError, TypeError):
                        b = b""
                    b = ctrl.wall.fit(b)
                    if b is None:
                        self._json(400, {"error":
                                         "every frame must be square raw RGB, "
                                         f"{ctrl.phone_side}x{ctrl.phone_side} "
                                         f"or {ctrl.wall.width}x{ctrl.wall.height}"})
                        return
                    frames.append(b)
                ctrl.clip = {"fps": _clamp(fps, 1, 24), "frames": frames}
                ctrl.shown_seq += 1
                ctrl.apply({"mode": "clip"})
                self._json(200, ctrl.public_state())
                return

            if self.path.startswith("/tuning/restart"):
                if ctrl.tuning is None:
                    self._json(503, {"error": "tuning is not available on this wall"})
                    return
                said = ctrl.tuning.restart_renderer()
                print(f"[tuning] {said}")
                self._json(200, {"said": said})
                return

            if self.path.startswith("/tuning/reset"):
                if ctrl.tuning is None:
                    self._json(503, {"error": "tuning is not available on this wall"})
                    return
                ctrl.tuning.reset()
                ctrl.last_frame = None
                ctrl.dirty.set()
                print("[tuning] back to what the wall shipped with")
                out = ctrl.tuning.public()
                out["restarting"] = True     # the wall took the panel down itself
                self._json(200, out)
                return

            if self.path.startswith("/tuning"):
                patch = self._body()
                if patch is None:
                    return
                if ctrl.tuning is None:
                    self._json(503, {"error": "tuning is not available on this wall"})
                    return
                changed, rejected, restart = ctrl.tuning.update(patch)
                if changed:
                    # a colour or dark-end knob changes the picture that is
                    # already up, so it has to be drawn again
                    ctrl.last_frame = None
                    ctrl.dirty.set()
                    print(f"[tuning] {', '.join(f'{k}={v}' for k, v in changed.items())}")
                out = ctrl.tuning.public()
                out["restarting"] = restart
                if rejected:
                    out["rejected"] = sorted(rejected)
                self._json(200, out)
                return

            if self.path.startswith("/video/clock"):
                data = self._body()
                if data is None:
                    return
                if ctrl.video is None:
                    self._json(404, {"error": "video is not available on this wall"})
                    return
                if "url" in data and data["url"] != ctrl.video.url:
                    self._json(409, {"error": "video changed"})
                    return
                try:
                    position = float(data.get("t", 0.0))
                    if not math.isfinite(position):
                        raise ValueError("nonfinite position")
                    ctrl.video.clock(position, bool(data.get("playing", True)))
                except (TypeError, ValueError):
                    self._json(400, {"error": "t must be a number"})
                    return
                ctrl.last_client = time.monotonic()
                self._json(200, ctrl.video.public())
                return

            if self.path.startswith("/video/control"):
                data = self._body()
                if data is None:
                    return
                if ctrl.video is None:
                    self._json(404, {"error": "video is not available on this wall"})
                    return
                action = data.get("action")
                if action not in ("play", "pause", "seek"):
                    self._json(400, {"error": "action must be play, pause or seek"})
                    return
                try:
                    t = float(data["t"]) if "t" in data else None
                except (TypeError, ValueError):
                    self._json(400, {"error": "t must be a number"})
                    return
                ctrl.video.control(action, t)
                self._json(200, ctrl.video.public())
                return

            if self.path.startswith("/video/stop"):
                ctrl.video_stop()
                self._json(200, ctrl.public_state())
                return

            if self.path.startswith("/video/upload"):
                # A small mp4 the phone made from a video of its own: the
                # picture, square, at a size the wall decodes for nothing.
                # The phone keeps the original and plays its sound itself.
                if ctrl.video is None:
                    self._json(404, {"error": "video is not available on this wall"})
                    return
                try:
                    n = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    n = 0
                if not 1000 <= n <= UPLOAD_MAX:
                    self._json(413 if n > UPLOAD_MAX else 400,
                               {"error": f"the picture must be under {UPLOAD_MAX // 1_000_000} MB"})
                    return
                from .video.player import WORK_DIR
                os.makedirs(WORK_DIR, exist_ok=True)
                path = os.path.join(WORK_DIR, f"upload-{int(time.time())}.mp4")
                left = n
                try:
                    with open(path, "wb") as fh:
                        while left > 0:
                            chunk = self.rfile.read(min(1 << 20, left))
                            if not chunk:
                                break
                            fh.write(chunk)
                            left -= len(chunk)
                except OSError as exc:
                    self._json(500, {"error": f"could not keep the picture: {exc}"[:120]})
                    return
                if left > 0:
                    os.remove(path)
                    self._json(400, {"error": "the upload stopped short"})
                    return
                q = parse_qs(urlparse(self.path).query)
                title = (q.get("title") or [""])[0].strip()[:120] or None
                clock = (q.get("clock") or ["phone"])[0]
                why = ctrl.video_start(path, sound=False, loop=False,
                                       clock=clock if clock in ("phone", "wall") else "phone",
                                       title=title)
                if why:
                    self._json(503, {"error": why})
                    return
                ctrl.last_client = time.monotonic()
                self._json(200, ctrl.public_state())
                return

            if self.path.startswith("/video"):
                data = self._body()
                if data is None:
                    return
                url = data.get("url")
                if not isinstance(url, str) or not 8 <= len(url.strip()) <= 4096 \
                        or not url.strip().lower().startswith(("http://", "https://")):
                    self._json(400, {"error": "url must be an http(s) link"})
                    return
                why = ctrl.video_start(url.strip(), bool(data.get("sound", True)),
                                       bool(data.get("loop", False)))
                if why:
                    self._json(503, {"error": why})
                    return
                ctrl.last_client = time.monotonic()
                self._json(200, ctrl.public_state())
                return

            if self.path.startswith("/state"):
                ctrl.last_client = time.monotonic()
                patch = self._body()
                if patch is None:
                    return
                rejected = ctrl.apply(patch)
                resp = ctrl.public_state()
                if rejected:
                    resp["rejected"] = rejected
                self._json(200, resp)
                return

            if self.path.startswith("/push"):
                # What the phone is playing. Trusted for a short while, then
                # forgotten, so a dead phone cannot pin the wall to a song.
                data = self._body()
                if data is None:
                    return
                if ctrl.pushed is None:
                    self._json(404, {"error": "phone push is not in the chain"})
                    return
                ctrl.pushed.push(data)
                ctrl.last_client = time.monotonic()
                ctrl.nudge()              # show the new song now, not next poll
                self._empty(204)
                return

            if self.path.startswith("/services"):
                patch = self._body()
                if patch is None:
                    return
                rejected = ctrl.apply_services(patch)
                resp = ctrl.services()
                if rejected:
                    resp["rejected"] = sorted(rejected)   # names only, never values
                self._json(200, resp)
                return

            if self.path.startswith("/spotify/tokens"):
                tokens = self._body()
                if tokens is None:
                    return
                # The phone sends the app id the tokens belong to; a wall
                # that has none (or another) takes it first, since refresh
                # only works with the id that issued them.
                cid = tokens.pop("client_id", None)
                if isinstance(cid, str) and cid.strip() and ctrl.spotify is not None \
                        and cid.strip() != ctrl.spotify.client_id:
                    ctrl.apply_services({"spotify": {"client_id": cid.strip()}})
                if ctrl.spotify is None or not ctrl.spotify.client_id:
                    self._json(409, {"error": "the wall has no Spotify app id yet"})
                    return
                if not tokens.get("access_token") or not tokens.get("refresh_token"):
                    self._json(400, {"error": "access_token and refresh_token needed"})
                    return
                ctrl.spotify.accept_tokens(tokens)
                ctrl.dirty.set()
                print("[control] Spotify linked from the phone")
                self._json(200, ctrl.services())
                return

            if self.path.startswith("/spotify/unlink"):
                if ctrl.spotify is not None:
                    ctrl.spotify.unlink()
                    print("[control] Spotify unlinked from the phone")
                self._json(200, ctrl.services())
                return

            self._json(404, {"error": "not found"})

        def log_message(self, *args):
            pass

    class Quiet(ThreadingHTTPServer):
        # A phone that drops a kept-alive connection, or a player that
        # abandons a byte-range request mid-way, is not an error worth a
        # traceback in the journal. Everything else still is.
        def handle_error(self, request, client_address):
            import sys
            if isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError,
                                              TimeoutError)):
                return
            super().handle_error(request, client_address)

    httpd = Quiet(("0.0.0.0", port), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True,
                     name="control-api").start()
    print(f"[control] wall control API on 0.0.0.0:{port}")
    return httpd
