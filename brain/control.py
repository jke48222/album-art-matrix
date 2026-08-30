"""Wall control plane — a tiny HTTP API the iOS companion talks to.

Runs as a daemon thread inside the brain, so control works whenever the wall
is on — no Mac required.

  GET  /state   -> full control state + last-shown track (for the app's UI)
  POST /state   -> partial update, e.g. {"mode": "ambient", "brightness": 0.4}
  GET  /journal -> what the wall has worn, newest first (?limit=N, default 50)
  POST /replay  -> {"ts": <journal ts>} re-show that sleeve until next track
  POST /frame   -> {"px": base64 raw RGB, 64*64*3 bytes} — doodles and photos;
                   switches mode to "frame" so the push is visible immediately

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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

STATE_PATH = os.path.expanduser("~/.config/album-art-matrix/control.json")
JOURNAL_PATH = os.path.expanduser("~/.config/album-art-matrix/journal.jsonl")
JOURNAL_MAX = 500                     # rewrite the file when it grows past this

MODES = ("art", "cd", "ambient", "off", "frame", "ticker", "clock", "clip", "timer")
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
    "idle": "black",         # silence: black | hold | dim | ambient
    "away": "stay",          # phone gone >15 min: stay | off
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

    def __init__(self, seed: dict | None = None, frame_len: int = 64 * 64 * 3):
        """seed: config.toml defaults — used only when no saved state exists
        (a phone-set state should survive restarts over config defaults)."""
        self._lock = threading.Lock()
        self._s = dict(DEFAULTS)
        self.dirty = threading.Event()
        self.now_showing = {}        # main loop writes {title, artist, album}
        # Where the song is, so a client can run the same clock we do rather
        # than being told a number that is already stale by the time it lands.
        self.progress = {}           # {at, of, playing, stamped}
        self.art_colors = None       # main loop writes ("#rrggbb", "#rrggbb")
        self.frame_len = frame_len
        self.frame_override = None   # raw RGB bytes for mode "frame"
        self.clip = None             # {"fps": float, "frames": [bytes]}
        self.last_frame = None       # pre-WB RGB of whatever was last shown
        self.replay = None           # journal entry the main loop should re-show
        self.sleep = None            # {"t0": monotonic, "minutes": N} while fading
        self.timer = None            # {"end": monotonic, "total": s, "ret": mode}
        self.fps_last = 0.0          # main loop's sustained rate, for /health
        self.last_client = None      # monotonic of the app's last request
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
        if self._s["mode"] in ("frame", "clip"):   # overrides die with restart
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
                elif k == "wake_enabled":
                    self._s[k] = bool(v)
                elif k == "wake_time" and isinstance(v, str) and len(v) == 5 \
                        and v[2] == ":" and v[:2].isdigit() and v[3:].isdigit() \
                        and int(v[:2]) < 24 and int(v[3:]) < 60:
                    self._s[k] = v
                elif k == "wake_fade_min":
                    self._s[k] = _clamp(v, 1, 90)
                elif k in ("wb_r", "wb_g", "wb_b"):
                    self._s[k] = _clamp(v, 0.3, 1.0)
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
                    (here if here not in ("timer", "frame", "clip") else "clock")
                self.timer = {"end": time.monotonic() + minutes * 60,
                              "total": minutes * 60, "ret": ret}
                patch["mode"] = "timer"
            else:
                ret = self.timer["ret"] if self.timer else "clock"
                self.timer = None
                if self.get()["mode"] == "timer":
                    patch["mode"] = ret
        rejected = self._merge(patch)
        self.dirty.set()
        return rejected

    def public_state(self) -> dict:
        """What GET /state returns — settings plus live extras."""
        out = {**self.get(), "now_showing": self.now_showing,
               "progress": self.progress, "shown_seq": self.shown_seq}
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
        return out

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
        return {"fps": round(self.fps_last, 1), "temp_c": temp,
                "throttled": throttled,
                "uptime_s": int(time.monotonic() - _T0),
                "mode": self.get()["mode"]}

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

        def do_GET(self):
            u = urlparse(self.path)
            if u.path.startswith("/frame.raw"):
                px = ctrl.last_frame
                if px is None:
                    self._json(404, {"error": "nothing shown yet"})
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(px)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(px)
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
                if len(px) != ctrl.frame_len:
                    self._json(400, {"error":
                                     f"px must be {ctrl.frame_len} raw RGB "
                                     "bytes, base64-encoded"})
                    return
                ctrl.frame_override = px
                ctrl.shown_seq += 1
                ctrl.apply({"mode": "frame"})
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
                    if len(b) != ctrl.frame_len:
                        self._json(400, {"error":
                                         "every frame must be "
                                         f"{ctrl.frame_len} raw RGB bytes"})
                        return
                    frames.append(b)
                ctrl.clip = {"fps": _clamp(fps, 1, 24), "frames": frames}
                ctrl.shown_seq += 1
                ctrl.apply({"mode": "clip"})
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

            self._json(404, {"error": "not found"})

        def log_message(self, *args):
            pass

    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True,
                     name="control-api").start()
    print(f"[control] wall control API on 0.0.0.0:{port}")
    return httpd
