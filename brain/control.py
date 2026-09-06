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
  GET  /services   -> which music services the wall can use, and their state
  POST /spotify/tokens -> {access_token, refresh_token, expires_in} from the
                   phone's PKCE sign-in; the wall polls Spotify from then on
  POST /spotify/unlink -> forget the Spotify account
  POST /services   -> {spotify: {client_id}, lastfm: {api_key, user},
                   listenbrainz: {user}, acoustid: {api_key, device}}: any
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

State persists to ~/.config/album-art-matrix/control.json so the wall comes
back the way you left it. Every accepted POST sets `dirty` (a threading.Event)
— the main loop waits on it instead of sleeping blind, so a slider move
re-renders immediately instead of at the next poll.

Transient things deliberately NOT persisted: the sleep fade (restarting the
wall cancels it), the frame override, a pending replay.
"""
import base64
import json
import os
import threading
import time
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

MODES = ("art", "cd", "ambient", "off", "frame", "ticker", "clock", "clip", "timer", "nine", "lyrics", "video")
UPLOAD_MAX = 80_000_000               # a picture the phone sends up, at most
EFFECTS = ("solid", "breathe", "pulse", "rainbow", "gradient", "plaid", "weave", "deco", "snake")
FINISHES = ("clean", "dither", "poster")
IDLES = ("black", "hold", "dim", "ambient")   # what the wall does in silence
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
        self._lock = threading.Lock()
        self._s = dict(DEFAULTS)
        self.dirty = threading.Event()
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
        # The picture a finish would act on for the face that is up: the
        # sleeve for art and words, the grid for the nine. /finishes renders
        # the three from this, so the phone shows what the wall would do
        # rather than its own guess at it.
        self._finish_base = None
        self.finish_seq = 0                 # bumped whenever the base changes
        self._finish_shots = (-1, None)     # (finish_seq, {name: b64})
        self.replay = None           # journal entry the main loop should re-show
        self.sleep = None            # {"t0": monotonic, "minutes": N} while fading
        self.timer = None            # {"end": monotonic, "total": s, "ret": mode}
        self.fps_last = 0.0          # main loop's sustained rate, for /health
        self.last_client = None      # monotonic of the app's last request
        # The adapters, set by build_sources. Every one exists whether or
        # not it has its details yet, so the phone can hand them over later.
        self.pushed = None           # PushedSource
        self.spotify = None          # SpotifySource
        self.lastfm = None           # LastfmSource
        self.listenbrainz = None     # ListenBrainzSource
        self.acoustid = None         # AcoustidSource
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

    def _merge(self, patch: dict, persist: bool = True) -> dict:
        rejected = {}
        with self._lock:
            for k, v in patch.items():
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
                elif k in ("wake_enabled", "alarm_enabled"):
                    self._s[k] = bool(v)
                elif k == "alarm_time" and isinstance(v, str) and len(v) == 5 \
                        and v[2] == ":" and v[:2].isdigit() and v[3:].isdigit() \
                        and int(v[:2]) < 24 and int(v[3:]) < 60:
                    self._s[k] = v
                elif k == "wake_time" and isinstance(v, str) and len(v) == 5 \
                        and v[2] == ":" and v[:2].isdigit() and v[3:].isdigit() \
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
                elif k == "lat":
                    self._s[k] = _clamp(v, -90.0, 90.0)
                elif k == "lon":
                    self._s[k] = _clamp(v, -180.0, 180.0)
                elif k in ("match_art", "ticker_loop", "clock_24h"):
                    self._s[k] = bool(v)
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
                    clean = "".join(c for c in v if c.isprintable())[:120]
                    self._s[k] = clean or "?"
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
        """The alarm: straight to the timer's zero, fireworks and all, and
        back to whatever the wall was doing when it is done."""
        here = self.get()["mode"]
        ret = self.timer["ret"] if self.timer else \
            (here if here not in ("timer", "frame", "clip") else "clock")
        self.timer = {"end": time.monotonic(), "total": 60.0, "ret": ret}
        self.apply({"mode": "timer"})

    def apply(self, patch: dict) -> dict:
        """Merge a patch, persist, wake the main loop. Returns rejected keys."""
        # sleep fade is a command, not a persisted setting
        if "sleep_fade_min" in patch:
            minutes = _clamp(patch.pop("sleep_fade_min"), 0, 180)
            # monotonic, not wall time: an NTP step on an RTC-less Pi must not
            # snap the fade to the end (or stall it) mid-way
            self.sleep = ({"t0": time.monotonic(), "minutes": minutes}
                          if minutes > 0 else None)
        # A countdown is a command too: it starts now, remembers what the
        # wall was doing, and puts that back when it is done.
        if "timer_min" in patch:
            minutes = _clamp(patch.pop("timer_min"), 0, 180)
            if minutes > 0:
                here = self.get()["mode"]
                ret = self.timer["ret"] if self.timer else \
                    (here if here not in ("timer", "frame", "clip", "video") else "clock")
                self.timer = {"end": time.monotonic() + minutes * 60,
                              "total": minutes * 60, "ret": ret}
                patch["mode"] = "timer"
            else:
                ret = self.timer["ret"] if self.timer else "clock"
                self.timer = None
                if self.get()["mode"] == "timer":
                    patch["mode"] = ret
        want = patch.get("panel_brightness")
        if patch.get("panel_type") is not None:
            want = True
        rejected = self._merge(patch)
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
        if self.art_colors:
            out["art_colors"] = list(self.art_colors)
        sl = self.sleep              # snapshot: the render thread can null it
        if sl:
            left = sl["minutes"] * 60 - (time.monotonic() - sl["t0"])
            out["sleep_remaining_s"] = max(0, int(left))
        tm = self.timer
        if tm:
            out["timer_remaining_s"] = max(0, int(tm["end"] - time.monotonic()))
            out["timer_total_s"] = int(tm["total"])
        if self.video is not None and (self.video.status != "idle" or self.video.error):
            out["video"] = self.video.public()
        return out

    # ---- services -------------------------------------------------------
    def services(self) -> dict:
        """What the app shows on its Services page. No secrets: the Spotify
        client id is public by design (PKCE); keys come back as yes/no."""
        sp, lf, lb, ac, ap = (self.spotify, self.lastfm, self.listenbrainz,
                              self.acoustid, self.apple)
        ears = ac.status() if ac else {
            "key_set": False, "device": "", "mic": None, "tools": False,
            "listening": False, "heard_s": None, "problem": None}
        return {
            "spotify": {"client_id": sp.client_id if sp else "",
                        "linked": bool(sp and sp.linked)},
            "lastfm": {"user": lf.user if lf else "",
                       "key_set": bool(lf and lf.api_key)},
            "listenbrainz": {"user": lb.user if lb else ""},
            "acoustid": ears,
            "phone": {"age_s": (self.pushed.phone_age if self.pushed else None)},
            "mac": {"endpoint": (ap.endpoint if ap else ""),
                    "answering": (ap.answering if ap else None)},
            "ears": bool(ears["key_set"] and ears["tools"]),
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
        if "acoustid" in changed and self.acoustid:
            self.acoustid.configure(store.get("acoustid", "api_key"),
                                    store.get("acoustid", "device"))
        if changed:
            print(f"[control] services set from the phone: "
                  f"{', '.join(changed)}")
            self.dirty.set()
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
            try:
                n = int(self.headers.get("Content-Length", 0))
                patch = json.loads(self.rfile.read(n) or b"{}")
                if not isinstance(patch, dict):
                    raise ValueError
                return patch
            except (ValueError, json.JSONDecodeError):
                self._json(400, {"error": "body must be a JSON object"})
                return None

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

            if u.path.startswith("/journal"):
                try:
                    limit = int(parse_qs(u.query).get("limit", ["50"])[0])
                except ValueError:
                    limit = 50
                self._json(200, {"entries": ctrl.journal_read(limit)})
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
            if self.path.startswith("/replay"):
                patch = self._body()
                if patch is None:
                    return
                ts = patch.get("ts")
                entry = next((e for e in ctrl.journal_read(200)
                              if e.get("ts") == ts), None)
                if entry is None:
                    self._json(404, {"error": "no such journal entry"})
                    return
                ctrl.replay = entry
                ctrl.apply({"mode": "art"})
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
                ctrl.pressing = (str(data.get("track") or ""), px)
                ctrl.dirty.set()
                self._empty(204)
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
                try:
                    ctrl.video.clock(float(data.get("t", 0.0)), bool(data.get("playing", True)))
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
                ctrl.dirty.set()          # show the new song now, not next poll
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
