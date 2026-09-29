"""Every knob that decides what the LEDs actually do, in one place.

The wall's look is settled by numbers in three different worlds: the
renderer's launch flags (bit depth, dithering, how long the row address is
given to settle), the colour maths in art/pipeline.py (the gains, the black
point, the dark end's lift and lean), and the picture work either side of it
(the unsharp, a video's lift). They were spread across a config file, a
handful of files on the Pi and module constants, and tuning any of them
meant editing something and restarting by hand.

This is the store behind GET/POST /tuning. It knows each knob's range, what
it means, and whether changing it needs the renderer relaunched; it applies
what it can live and writes the rest where run_renderer.sh reads them.

It also knows whether the renderer came back. A launch flag only takes when
art_display starts again, so a change to one kills it and systemd brings it
back a second later. The sink counts every time a renderer attaches to the
pipe, and a restart is over when that count goes up. Until then another
restart is refused: SIGKILL on a renderer that is still starting walks
systemd towards its start limit, and past that the panel stays dark until a
reboot.

Kept in ~/.config/album-art-matrix/tuning.json, so a tuned wall comes back
tuned. Anything not in that file falls back to config.toml, then to the
value the code shipped with.
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import threading
import time
from typing import NamedTuple

from .art import pipeline

PATH = os.path.expanduser("~/.config/album-art-matrix/tuning.json")
ROOT = os.path.expanduser("~/album-art-matrix")

# The renderer's restart, read against the sink's connection count. Twenty
# seconds without a new connection is a renderer that is not coming back on
# its own (systemd waits one). Fifteen detached with no restart asked for is
# a renderer that is not running at all.
STALL_S = 20.0
STOPPED_S = 15.0
BUSY = "The panel is still restarting. Try again in a moment."

# Where a change shows. now: the next frame. restart: once the renderer is
# back. sleeves: album art only. next_sleeve: album art from the next song,
# video at once. next_video: the next clip. video: while a clip plays.
# listening: the microphone and the voice.
APPLIES = ("now", "restart", "sleeves", "next_sleeve", "next_video", "video", "listening")


class Spec(NamedTuple):
    """One knob. The first eight fields are the shape older apps and QA
    fixtures unpack by position, so new fields only ever go on the end."""
    name: str
    group: str
    kind: str
    lo: float
    hi: float
    step: float
    restart: bool
    note: str
    label: str
    unit: str | None
    applies: str


# key, title, what the group does, the phone's tab, the test pattern that
# shows it best ("wall" is the wall's own picture, None is no pattern).
GROUPS = [
    ("Panel", "Panel drive",
     "How the panel is scanned and how bright it may go. Settings with a "
     "Restarts panel badge turn the panel off for a few seconds.", "picture",
     "darkSteps"),
    ("Colour", "Colour",
     "The balance of red, green and blue on every picture.", "picture", "bars"),
    ("Dark end", "Dark end",
     "How the dimmest levels are drawn, where the panel has the fewest steps.",
     "picture", "darkColours"),
    ("Sharpness", "Sharpness",
     "Sharpening after album art and video are scaled to the panel.", "picture", "wall"),
    ("Video", "Video",
     "How clips are brightened and how their shadows are drawn.", "picture", "wall"),
    ("Shelf", "Shelf",
     "Marks on album art from your Discogs collection.", "picture", "wall"),
    ("Hearing", "Hearing",
     "Song recognition, knocks and whistles through the microphone.", "listening", None),
    ("Voice", "Voice",
     "The wake word and the speech model.", "listening", None),
]

SPECS = [
    Spec("bit_depth", "Panel", "int", 4, 64, 4, True,
         "More planes give smoother dim colours. Fewer planes refresh faster.",
         "Bit depth", "planes", "restart"),
    Spec("dither", "Panel", "float", 0.0, 10.0, 0.1, False,
         "Mixes neighbouring lights to make in-between colours. High values can "
         "show single red lights in dark grey.",
         "Spatial dither", None, "now"),
    Spec("addr_settle_ns", "Panel", "int", 0, 2000, 25, True,
         "A short pause after each row change that removes faint ghost rows. "
         "Longer pauses lower the refresh rate. Check it on the Grid pattern.",
         "Row settle time", "ns", "restart"),
    Spec("temporal_dither", "Panel", "bool", 0, 1, 1, True,
         "Redraws the picture every panel frame so a colour can sit between two "
         "brightness steps. The dimmest lights may shimmer.",
         "Time dithering", None, "restart"),
    Spec("dither_min", "Panel", "float", 0.0, 0.5, 0.05, True,
         "Steps smaller than this are rounded instead of dithered, which stops "
         "the dimmest lights blinking slowly. 0 dithers everything.",
         "Smallest dithered step", None, "restart"),
    Spec("panel_type", "Panel", "int", 0, 7, 1, True,
         "Must match the panel's driver. A wrong value scrambles or ghosts rows. "
         "Check it on the Grid pattern.",
         "Row addressing", None, "restart"),

    Spec("gain_r", "Colour", "float", 0.20, 1.0, 0.01, False,
         "Scales red in linear light. This panel leans green and blue, so these "
         "bring white back to neutral.",
         "Red gain", None, "now"),
    Spec("gain_g", "Colour", "float", 0.20, 1.0, 0.01, False,
         "Scales green in linear light.", "Green gain", None, "now"),
    Spec("gain_b", "Colour", "float", 0.20, 1.0, 0.01, False,
         "Scales blue in linear light.", "Blue gain", None, "now"),
    Spec("nearest_colour", "Colour", "bool", 0, 1, 1, False,
         "Sends very dark pixels as the closest colour the panel can light, so a "
         "dark brown does not show as a single red.",
         "Nearest colour when dim", None, "now"),

    Spec("black_point", "Dark end", "int", 0, 48, 1, False,
         "Each colour at or below this is switched off on everything the wall "
         "shows, and the rest is stretched back to full. Use it when photo "
         "noise lights single LEDs.",
         "Black point", "/255", "now"),
    # The display-session overlay goes through the same steady() that
    # zeroes these, so the test patterns lose them too.
    Spec("pic_black", "Dark end", "int", 0, 64, 1, False,
         "A whole pixel whose brightest colour is below this is switched off. "
         "Only album art, video and the test patterns use it.",
         "Picture noise floor", "/255", "now"),
    Spec("pic_floor", "Dark end", "int", 0, 128, 1, False,
         "The dimmest level a lit album art pixel is drawn at. Higher keeps "
         "shadows visible. Too high turns them grey.",
         "Shadow lift", "/255", "sleeves"),
    Spec("pic_knee", "Dark end", "int", 32, 220, 1, False,
         "Above this level album art is drawn as it is. Between the shadow lift "
         "and here, shadows are compressed in order.",
         "Shadow lift ends", "/255", "sleeves"),
    Spec("low_end", "Dark end", "int", 0, 255, 5, False,
         "Below this level the dim colour correction begins.",
         "Dim tint starts", "/255", "now"),
    Spec("low_full", "Dark end", "int", 0, 200, 5, False,
         "At and below this level the dim colour correction is at full strength.",
         "Dim tint full", "/255", "now"),
    Spec("low_red", "Dark end", "float", 0.5, 1.5, 0.01, False,
         "Red in dim pixels. Dim pixels drift red on this panel, so values under "
         "1 pull them back.",
         "Dim red", None, "now"),
    Spec("low_blue", "Dark end", "float", 0.5, 1.8, 0.01, False,
         "Blue in dim pixels. Blue fades first when a pixel is dim, so values "
         "over 1 bring it back.",
         "Dim blue", None, "now"),

    Spec("unsharp_radius", "Sharpness", "float", 0.0, 3.0, 0.1, False,
         "How far the sharpening reaches after the picture is scaled down.",
         "Sharpen radius", "px", "next_sleeve"),
    Spec("unsharp_percent", "Sharpness", "int", 0, 200, 5, False,
         "How strong the sharpening is. 0 turns it off.",
         "Sharpen strength", "%", "next_sleeve"),

    Spec("video_tone_target", "Video", "int", 0, 200, 4, False,
         "Dark clips are brightened until most of the picture reaches this "
         "level. 0 turns the lift off.",
         "Dark clip lift", "/255", "next_video"),
    Spec("video_floor", "Video", "bool", 0, 1, 1, False,
         "Gives video the same shadow lift as album art. Off keeps blacks black, "
         "which suits night scenes.",
         "Shadow lift in video", None, "video"),

    Spec("shelf_mark", "Shelf", "bool", 0, 1, 1, False,
         "A small record in the corner of album art you own on vinyl, from your "
         "Discogs shelf.",
         "Owned record mark", None, "sleeves"),

    # The ear's knobs live here too: same store, same page on the phone,
    # nothing to restart. Levels are dB below the microphone's ceiling.
    Spec("hearing", "Hearing", "bool", 0, 1, 1, False,
         "Uses the microphone to name the music in the room. Off keeps the "
         "microphone for the level meter only.",
         "Song recognition", None, "listening"),
    Spec("knock", "Hearing", "bool", 0, 1, 1, False,
         "Two knocks on the frame turn the wall off. Two more bring back what "
         "was showing.",
         "Two knocks", None, "listening"),
    Spec("knock_sensitivity", "Hearing", "int", 10, 40, 1, False,
         "How far a knock must rise above the last second of sound. Lower "
         "catches softer knocks and more false ones.",
         "Knock threshold", "dB", "listening"),
    Spec("whistle", "Hearing", "bool", 0, 1, 1, False,
         "A rising whistle turns the wall on. A falling whistle turns it off.",
         "Whistle", None, "listening"),
    Spec("teach", "Hearing", "bool", 0, 1, 1, False,
         "Checks the songs saved on the wall before asking Shazam. Songs Shazam "
         "misses are added from their iTunes previews.",
         "Song library first", None, "listening"),
    Spec("teach_by_ear", "Hearing", "bool", 0, 1, 1, False,
         "While another source names a song, saves how it sounds in this room. "
         "Only fingerprints are kept, never audio.",
         "Learn from the room", None, "listening"),
    Spec("teach_match_score", "Hearing", "int", 5, 60, 1, False,
         "Matching landmarks needed to name a song from the library. Lower names "
         "songs sooner and risks a wrong one. A real match scores in the dozens.",
         "Library match score", "points", "listening"),

    # The voice: the wake word and what the wall does with the words after it.
    Spec("wake", "Voice", "bool", 0, 1, 1, False,
         "Turns on the wake word. After it, a spoken command changes the wall and "
         "a question is answered in words on the panel.",
         "Wake word", None, "listening"),
    Spec("wake_threshold", "Voice", "float", 0.3, 0.95, 0.05, False,
         "How sure a match must be. Lower wakes more easily and more often by "
         "mistake. Saved for the wake word in use.",
         "Wake threshold", None, "listening"),
    Spec("speech_base", "Voice", "bool", 0, 1, 1, False,
         "Better with names and about twice as slow, 2.5 s a sentence instead "
         "of 1.5 s.",
         "Larger speech model", None, "listening"),
    Spec("listen_for", "Hearing", "float", 3.0, 12.0, 0.5, False,
         "Seconds of sound sent to be named. Shorter answers sooner, longer is "
         "surer. The answer takes about 2 s more.",
         "Clip length", "s", "listening"),
    Spec("room_gate", "Hearing", "int", -80, -20, 1, False,
         "How loud the room must be before recognition starts. Hearing & "
         "gestures shows the live level.",
         "Listening gate", "dB", "listening"),
    Spec("quiet_before_letting_go", "Hearing", "int", 3, 90, 1, False,
         "Seconds of quiet before a named song is released. Gaps between tracks "
         "last 2 or 3 s.",
         "Quiet before release", "s", "listening"),
    Spec("listen_again_every", "Hearing", "int", 10, 120, 5, False,
         "While a song is up, how often recognition checks whether the record "
         "has moved on. A gap between tracks also starts a check.",
         "Check again every", "s", "listening"),
    Spec("retry_after_miss", "Hearing", "int", 2, 30, 1, False,
         "Wait before trying again when the room is loud but nothing was named. "
         "Each miss also lengthens the next clip, up to 12 s.",
         "Retry after a miss", "s", "listening"),
    Spec("keep_through_noise", "Hearing", "int", 30, 600, 30, False,
         "How long a named song stays up while the room is loud but nothing new "
         "can be named, as with a TV or talking. Quiet releases it sooner.",
         "Hold through noise", "s", "listening"),
    Spec("mic_gain", "Hearing", "int", 0, 100, 5, False,
         "The microphone's input gain.",
         "Microphone gain", "%", "listening"),
    Spec("mic_auto_gain", "Hearing", "bool", 0, 1, 1, False,
         "Lets the microphone set its own gain. Off keeps the level meter and "
         "the gate accurate.",
         "Automatic gain", None, "listening"),
]
BY_NAME = {s.name: s for s in SPECS}

# what each panel knob is written to, for run_renderer.sh to read at launch
FILES = {"bit_depth": "bit-depth", "dither": "dither",
         "addr_settle_ns": "addr-settle-ns", "panel_type": "panel-type",
         "temporal_dither": "temporal-dither", "dither_min": "dither-min"}

# Why a knob does nothing on this wall right now. One reason per knob, the
# first that holds in this order: no microphone, no voice, no knock ear, no
# song library, then a switch it depends on being off.
NO_MIC = "This wall has no microphone."
NO_VOICE = "Voice is not set up on this wall."
NO_KNOCKS = "Knocks and whistles are off on this wall."
NO_LIBRARY = "The song library is off on this wall."
NEEDS = {
    "nearest_colour": "Not used while time dithering is on, which does the same job over time.",
    "dither_min": "Used only when Time dithering is on.",
    "knock_sensitivity": "Used only when Two knocks is on.",
    "teach_by_ear": "Used only when Song library first is on.",
    "teach_match_score": "Used only when Song library first is on.",
    "wake_threshold": "Used only when Wake word is on.",
}
_HEARING = [s.name for s in SPECS if s.group == "Hearing"]
_VOICE = [s.name for s in SPECS if s.group == "Voice"]
_KNOCKS = ("knock", "knock_sensitivity", "whistle")
_TEACH = ("teach", "teach_by_ear", "teach_match_score")

# The pipeline's own values, taken once at import. Tuning.apply rewrites
# these module constants, so reading them later gives the last wall's
# tuning back as "the default". A test run, or the QA fixture rebuilding its
# store after a tuned phase, would otherwise drift its defaults.
_PIPELINE_SHIPPED = {
    "black_point": int(pipeline.BLACK_POINT),
    "pic_black": int(pipeline.PIC_BLACK),
    "pic_floor": int(pipeline.PIC_FLOOR),
    "pic_knee": int(pipeline.PIC_KNEE),
    "low_end": int(pipeline.LOW_END),
    "low_full": int(pipeline.LOW_FULL),
    "low_red": float(pipeline.LOW_RED),
    "low_blue": float(pipeline.LOW_BLUE),
}

# Read through this rather than time.monotonic, so a test can move the
# renderer's clock without moving every other thread's.
_clock = time.monotonic


def _shipped(cfg: dict) -> dict:
    """Where a knob starts: config.toml if it says, else the code's own."""
    wb = cfg.get("whitebalance", {})
    pipe = cfg.get("pipeline", {})
    ears = cfg.get("ears", {})
    return {
        "hearing": bool(ears.get("on", True)),
        "listen_for": float(ears.get("listen_for", 6.0)),
        "room_gate": int(ears.get("room_gate", -52)),
        "quiet_before_letting_go": int(ears.get("quiet_before_letting_go", 10)),
        "listen_again_every": int(ears.get("listen_again_every", 25)),
        "retry_after_miss": int(ears.get("retry_after_miss", 4)),
        "keep_through_noise": int(ears.get("keep_through_noise", 180)),
        "mic_gain": int(ears.get("mic_gain", 100)),
        "knock": bool(ears.get("knock", True)),
        "knock_sensitivity": int(ears.get("knock_sensitivity", 20)),
        "whistle": bool(ears.get("whistle", True)),
        "teach": bool(ears.get("teach", True)),
        "teach_by_ear": bool(ears.get("teach_by_ear", True)),
        "teach_match_score": int(ears.get("teach_match_score", 15)),
        "wake": bool(cfg.get("voice", {}).get("wake", True)),
        "wake_threshold": float(cfg.get("voice", {}).get("wake_threshold", 0.5)),
        "speech_base": bool(cfg.get("voice", {}).get("speech_base", False)),
        "mic_auto_gain": bool(ears.get("mic_auto_gain", False)),
        "shelf_mark": bool(cfg.get("discogs", {}).get("mark", True)),
        "bit_depth": 64, "dither": 0.0, "addr_settle_ns": 0,
        "panel_type": 0, "temporal_dither": True, "dither_min": 0.2,
        "gain_r": float(wb.get("r", 1.0)),
        "gain_g": float(wb.get("g", 0.88)),
        "gain_b": float(wb.get("b", 0.83)),
        "nearest_colour": True,
        **_PIPELINE_SHIPPED,
        "unsharp_radius": float(pipe.get("unsharp_radius", 1.0)),
        "unsharp_percent": int(pipe.get("unsharp_percent", 60)),
        "video_tone_target": 112,
        "video_floor": False,
    }


def inactive(values: dict, ears=None) -> dict:
    """{knob: why it does nothing here}, for the knobs that do nothing."""
    out = {}
    if ears is None:
        for name in _HEARING + _VOICE:
            out.setdefault(name, NO_MIC)
    else:
        if getattr(ears, "voice", None) is None:
            for name in _VOICE:
                out.setdefault(name, NO_VOICE)
        if getattr(ears, "knocks", None) is None:
            for name in _KNOCKS:
                out.setdefault(name, NO_KNOCKS)
        if getattr(ears, "library", None) is None \
                and getattr(ears, "_library_kept", None) is None:
            for name in _TEACH:
                out.setdefault(name, NO_LIBRARY)
    if values.get("temporal_dither"):
        out.setdefault("nearest_colour", NEEDS["nearest_colour"])
    else:
        out.setdefault("dither_min", NEEDS["dither_min"])
    if not values.get("knock"):
        out.setdefault("knock_sensitivity", NEEDS["knock_sensitivity"])
    if not values.get("teach"):
        out.setdefault("teach_by_ear", NEEDS["teach_by_ear"])
        out.setdefault("teach_match_score", NEEDS["teach_match_score"])
    if not values.get("wake"):
        out.setdefault("wake_threshold", NEEDS["wake_threshold"])
    return out


def describe(values: dict, defaults: dict, *, ears=None, renderer=None) -> dict:
    """What GET /tuning answers, from values alone. Tuning.public() is this
    with the store's own values, ear and renderer. The QA fixtures call it
    directly, which never touches the pipeline's constants or the renderer's
    files the way building a Tuning does."""
    renderer = renderer or {"state": "absent", "down_s": None}
    return {
        "values": dict(values),
        "defaults": dict(defaults),
        "knobs": [{"name": s.name, "group": s.group, "kind": s.kind, "min": s.lo,
                   "max": s.hi, "step": s.step, "restart": s.restart, "note": s.note,
                   "label": s.label, "unit": s.unit, "applies": s.applies}
                  for s in SPECS],
        "groups": [{"key": key, "title": title, "summary": summary, "tab": tab,
                    "pattern": pattern}
                   for key, title, summary, tab, pattern in GROUPS],
        "inactive": inactive(values, ears),
        "renderer": renderer,
        # What the phone before the renderer's state knew to look for.
        "restarting": renderer.get("state") in ("restarting", "starting"),
    }


def find_renderer() -> list[int]:
    """The art_display processes running now. Raises when pgrep cannot run."""
    out = subprocess.run(["pgrep", "-f", "[a]rt_display"],
                         capture_output=True, text=True, timeout=5)
    return [int(x) for x in out.stdout.split()]


def stop_renderer(pid: int) -> None:
    """SIGKILL, so systemd (Restart=on-failure) brings it back."""
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass


class Tuning:
    def __init__(self, cfg: dict):
        self._lock = threading.Lock()
        # Held from a restart guard's check through the values, the files and
        # the kill to the marker, so two phones cannot both pass the guard.
        self._restart_lock = threading.Lock()
        self.defaults = _shipped(cfg)
        self.values = dict(self.defaults)
        self.video = None            # the VideoPlayer, when there is one
        self.ears = None             # the EarsSource, when the wall has one
        # The sink's status(), set by main.py for the Pi's renderer. None is
        # a wall with no renderer to restart (the Mac's preview).
        self.renderer = None
        # {at, connects} from the last restart, until the count goes past it.
        self._restart = None
        try:
            with open(PATH) as fh:
                saved = json.load(fh)
            for k, v in saved.items():
                if k in BY_NAME:
                    self.values[k] = self._clean(k, v)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            pass
        self._wake_threshold_seen = self.values.get("wake_threshold")
        self.apply()

    # ---- reading -------------------------------------------------------
    def get(self, name):
        with self._lock:
            return self.values[name]

    @property
    def gains(self):
        return (self.get("gain_r"), self.get("gain_g"), self.get("gain_b"))

    def public(self) -> dict:
        with self._lock:
            vals = dict(self.values)
        return describe(vals, self.defaults, ears=self.ears,
                        renderer=self.renderer_state())

    def _renderer_status(self):
        if self.renderer is None:
            return None
        try:
            return self.renderer()
        except Exception:
            return None

    def renderer_state(self) -> dict:
        """{state, down_s}. running, starting, restarting, stalled, stopped,
        or absent when there is no renderer on this wall. down_s is how long
        the panel has been without one, None while it has one."""
        status = self._renderer_status()
        if status is None:
            return {"state": "absent", "down_s": None}
        mark = self._restart
        # A marker is spent once a renderer has attached since it was taken.
        # It is left in place rather than cleared here: this runs on HTTP
        # threads, and clearing could race the next restart's new marker.
        back = mark is not None and mark.get("connects") is not None \
            and status.get("connects", 0) > mark["connects"]
        if mark is not None and not back:
            down = _clock() - mark["at"]
            return {"state": "restarting" if down < STALL_S else "stalled",
                    "down_s": round(down, 1)}
        if status.get("attached"):
            return {"state": "running", "down_s": None}
        gone = float(status.get("detached_s") or 0.0)
        return {"state": "starting" if gone < STOPPED_S else "stopped",
                "down_s": round(gone, 1)}

    def _busy(self) -> bool:
        return self.renderer_state()["state"] in ("restarting", "starting")

    # ---- writing -------------------------------------------------------
    def _clean(self, name, v):
        spec = BY_NAME[name]
        kind, lo, hi, step = spec.kind, spec.lo, spec.hi, spec.step
        if kind == "bool":
            return bool(v)
        try:
            x = float(v)
        except (TypeError, ValueError):
            raise ValueError(name)
        x = max(lo, min(hi, x))
        if kind == "int":
            x = int(round(x / step) * step) if step > 1 else int(round(x))
            return max(int(lo), min(int(hi), x))
        return round(x, 3)

    def update(self, patch: dict):
        """Returns (changed, rejected, whether the renderer must relaunch).
        Raises RuntimeError, having changed nothing, when the patch moves a
        launch flag while the renderer is still coming back."""
        rejected, cleaned = [], {}
        for k, v in (patch or {}).items():
            if k not in BY_NAME:
                rejected.append(k)
                continue
            try:
                cleaned[k] = self._clean(k, v)
            except ValueError:
                rejected.append(k)
        with self._restart_lock:
            with self._lock:
                changed = {k: v for k, v in cleaned.items() if v != self.values[k]}
            restart = any(BY_NAME[k].restart for k in changed)
            if restart and self._busy():
                raise RuntimeError(BUSY)
            if changed:
                with self._lock:
                    self.values.update(changed)
                # The launch-flag files only when one of them moved: a live
                # knob dragged on the phone is several writes a second.
                self.apply(files=bool(set(changed) & set(FILES)))
                self._save()
            if restart:
                # Nobody should have to press a button to see what they just
                # turned. The launch flags are launch flags; the wall takes
                # the panel down and brings it back itself.
                print("[tuning] " + self._relaunch())
        return changed, rejected, restart

    def reset(self) -> str:
        with self._restart_lock:
            if self._busy():
                raise RuntimeError(BUSY)
            with self._lock:
                self.values = dict(self.defaults)
            self.apply()
            self._save()
            said = self._relaunch()
        print("[tuning] " + said)
        return said

    def restart_renderer(self) -> str:
        """Relaunch the renderer so the launch flags take. systemd brings it
        back; without systemd, run_renderer.sh has to be started by hand."""
        with self._restart_lock:
            if self._busy():
                raise RuntimeError(BUSY)
            return self._relaunch()

    def _relaunch(self) -> str:
        """The kill itself, under _restart_lock. The marker is taken first,
        with the connection count as it stands, so a renderer that is back
        before this returns still counts as back."""
        try:
            pids = find_renderer()
        except (OSError, subprocess.SubprocessError, ValueError):
            return "could not look for the renderer"
        if not pids:
            # Nothing to bring back. Dropping the marker lets the state fall
            # through to stopped, which is what the panel is.
            self._restart = None
            return "the renderer was not running"
        status = self._renderer_status()
        self._restart = {"at": _clock(),
                         "connects": status.get("connects") if status else None}
        for pid in pids:
            stop_renderer(pid)
        return f"renderer relaunching ({len(pids)} stopped)"

    # ---- making it so ---------------------------------------------------
    def apply(self, files: bool = True):
        with self._lock:
            v = dict(self.values)
        pipeline.BLACK_POINT = float(v["black_point"])
        pipeline.PIC_BLACK = int(v["pic_black"])
        pipeline.PIC_FLOOR = int(v["pic_floor"])
        pipeline.PIC_KNEE = int(v["pic_knee"])
        pipeline.LOW_END = float(v["low_end"])
        pipeline.LOW_FULL = float(v["low_full"])
        pipeline.LOW_RED = float(v["low_red"])
        pipeline.LOW_BLUE = float(v["low_blue"])
        # the renderer's temporal dither reaches the same colours in time,
        # and the two must not both round the same pixel
        pipeline.NEAREST_COLOUR = bool(v["nearest_colour"]) \
            and not bool(v["temporal_dither"])
        pipeline.BIT_DEPTH = int(v["bit_depth"])
        if self.video is not None:
            self.video.unsharp_radius = float(v["unsharp_radius"])
            self.video.unsharp_percent = int(v["unsharp_percent"])
            # Saved and shown on the phone for as long as the knob existed,
            # and never handed to the player, so it did nothing.
            self.video.tone_target = int(v["video_tone_target"])
        if self.ears is not None:
            self.ears.configure(on=v["hearing"], clip_s=v["listen_for"],
                                gate_db=v["room_gate"],
                                silence_s=v["quiet_before_letting_go"],
                                relisten_s=v["listen_again_every"],
                                retry_s=v["retry_after_miss"],
                                keep_s=v["keep_through_noise"],
                                gain=v["mic_gain"], agc=v["mic_auto_gain"])
            if getattr(self.ears, "knocks", None) is not None:
                self.ears.knocks.configure(knock=v["knock"],
                                           sensitivity_db=v["knock_sensitivity"],
                                           whistle=v["whistle"])
            lib = getattr(self.ears, "library", None)
            if lib is not None:
                lib.configure(min_score=v["teach_match_score"])
                # the knob turns the lookup off by hiding the library from the ear
                self.ears.library = lib if v["teach"] else None
                self.ears._library_kept = lib
            elif getattr(self.ears, "_library_kept", None) is not None and v["teach"]:
                self.ears.library = self.ears._library_kept
                self.ears.library.configure(min_score=v["teach_match_score"])
            if getattr(self.ears, "teacher", None) is not None:
                self.ears.teacher.configure(by_ear=v["teach_by_ear"])
            voice = getattr(self.ears, "voice", None)
            if voice is not None:
                voice.configure(on=v["wake"])
                if voice.wake is not None and v["wake_threshold"] != self._wake_threshold_seen:
                    # the knob is the wake word in use: a turn is kept for that
                    # word, and any other knob leaves the word's own alone
                    voice.wake.configure(threshold=v["wake_threshold"])
                    if getattr(voice.wake, "name", None):
                        from .voice import wake as wake_mod
                        wake_mod.save_threshold(voice.wake.name, v["wake_threshold"])
                if voice.transcriber is not None:
                    voice.transcriber.configure(size="base" if v["speech_base"] else "tiny")
        self._wake_threshold_seen = v["wake_threshold"]
        if not files:
            return
        for name, fname in FILES.items():
            val = v[name]
            if isinstance(val, bool):      # run_renderer.sh reads 1 or 0
                val = 1 if val else 0
            try:
                with open(os.path.join(ROOT, fname), "w") as fh:
                    fh.write(str(val))
            except OSError:
                pass

    def _save(self):
        with self._lock:
            snap = dict(self.values)
        try:
            os.makedirs(os.path.dirname(PATH), exist_ok=True)
            tmp = PATH + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(snap, fh, indent=2)
            os.replace(tmp, PATH)
        except OSError:
            pass
