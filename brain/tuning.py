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

from .art import pipeline

PATH = os.path.expanduser("~/.config/album-art-matrix/tuning.json")
ROOT = os.path.expanduser("~/album-art-matrix")

# name, group, kind, low, high, step, needs a renderer relaunch, what it does
SPECS = [
    ("bit_depth", "Panel", "int", 4, 64, 4, True,
     "Bit planes per frame. More colour in the dark end, a slower refresh."),
    ("dither", "Panel", "float", 0.0, 10.0, 0.1, False,
     "Spatial dithering. Buys colour below the panel's steps, and at the "
     "bottom of the range shows as single red LEDs in a grey field."),
    ("addr_settle_ns", "Panel", "int", 0, 2000, 25, True,
     "Dark time after every row address change. Kills the ghost a slow row "
     "driver leaves; costs refresh, and it is paid 2048 times a frame."),
    ("temporal_dither", "Panel", "bool", 0, 1, 1, True,
     "The renderer draws the held picture again at the panel's own frame "
     "rate and dithers every LED in time, so a colour can sit between two "
     "of the panel's brightness steps. Dark colours stop breaking into "
     "single primaries; the dimmest LEDs shimmer."),
    ("dither_min", "Panel", "float", 0.0, 0.5, 0.05, True,
     "Fractions of a step under this are rounded instead of dithered, which "
     "keeps the dimmest LEDs from blinking slowly. 0 dithers everything."),
    ("panel_type", "Panel", "int", 0, 7, 1, True,
     "The panel's row addressing. Wrong ones scramble or ghost rows."),

    ("gain_r", "Colour", "float", 0.20, 1.0, 0.01, False,
     "Red, in linear light. The panel's own primaries are green and blue "
     "biased; these pull them back to white."),
    ("gain_g", "Colour", "float", 0.20, 1.0, 0.01, False, "Green, in linear light."),
    ("gain_b", "Colour", "float", 0.20, 1.0, 0.01, False, "Blue, in linear light."),
    ("nearest_colour", "Colour", "bool", 0, 1, 1, False,
     "Below a few of the panel's brightness steps a colour's channels drop "
     "out one at a time, and a dark brown lights as a lone red. On, every "
     "dark pixel is sent as the nearest colour the panel can actually light. "
     "Stands down while the temporal dither is on, which does that in time."),

    ("black_point", "Dark end", "int", 0, 48, 1, False,
     "At and below this the pixel is off. A photograph's black is noise, "
     "and noise on a panel is LEDs flashing one at a time."),
    ("pic_black", "Dark end", "int", 0, 64, 1, False,
     "A picture's noise floor: below this, off."),
    ("pic_floor", "Dark end", "int", 0, 128, 1, False,
     "The dimmest a lit picture pixel is drawn at. High keeps shadows off "
     "the panel's ragged bottom; too high and everything greys."),
    ("pic_knee", "Dark end", "int", 32, 220, 1, False,
     "Above this a picture is drawn as it is. Between the floor and here it "
     "is compressed, in order."),
    ("low_end", "Dark end", "int", 0, 255, 5, False,
     "Below this level the dark-end lean starts, fully by the next knob."),
    ("low_full", "Dark end", "int", 0, 200, 5, False, "Where the lean is at full."),
    ("low_red", "Dark end", "float", 0.5, 1.5, 0.01, False,
     "Red at the dark end. A red LED reaches current soonest in a drive "
     "window, so dim pixels lean red; this pulls back."),
    ("low_blue", "Dark end", "float", 0.5, 1.8, 0.01, False,
     "Blue at the dark end, which arrives last and needs the help."),

    ("unsharp_radius", "Sharpness", "float", 0.0, 3.0, 0.1, False,
     "Unsharp radius, after the Lanczos downscale."),
    ("unsharp_percent", "Sharpness", "int", 0, 200, 5, False,
     "Unsharp strength. 0 turns it off."),

    ("video_tone_target", "Video", "int", 0, 200, 4, False,
     "Where a clip's 70th percentile is lifted to. 0 turns the lift off."),
    ("video_floor", "Video", "bool", 0, 1, 1, False,
     "Give video the same shadow lift a still sleeve gets. Off keeps its "
     "blacks black, which is what a night scene needs."),

    # The ear's knobs live here too: same store, same page on the phone,
    # nothing to restart. Levels are dB below the microphone's ceiling.
    ("hearing", "Hearing", "bool", 0, 1, 1, False,
     "Listen to the room through the wall's microphone and name what is "
     "playing. Off leaves the microphone open for the level meter only."),
    ("listen_for", "Hearing", "float", 3.0, 12.0, 0.5, False,
     "Seconds of the room sent to be named. Shorter answers sooner, longer "
     "is surer; the answer itself takes about two more."),
    ("room_gate", "Hearing", "int", -80, -20, 1, False,
     "How loud the room must be before the wall listens. The Hearing page "
     "shows the live level and the quiet-room floor next to this."),
    ("quiet_before_letting_go", "Hearing", "int", 3, 90, 1, False,
     "Seconds of quiet before a heard song is let go and the wall falls back "
     "to its other sources. The gaps between a record's tracks are two or three."),
    ("listen_again_every", "Hearing", "int", 10, 120, 5, False,
     "While a song is up, how often the wall checks whether the record has "
     "moved on. A gap between tracks triggers a check on its own."),
    ("retry_after_miss", "Hearing", "int", 2, 30, 1, False,
     "Seconds before another try when the room is loud but nothing was "
     "named. Every miss also makes the next clip longer, up to 12 s, "
     "which is what a noisy room needs."),
    ("keep_through_noise", "Hearing", "int", 30, 600, 30, False,
     "Once a song is named, how long the wall keeps it while the room stays "
     "loud but nothing can be named again, as with a TV on or people "
     "talking. Quiet still lets go sooner."),
    ("mic_gain", "Hearing", "int", 0, 100, 5, False,
     "The microphone's own gain."),
    ("mic_auto_gain", "Hearing", "bool", 0, 1, 1, False,
     "Let the microphone ride its own gain. Off keeps the level meter and "
     "the gate honest: with it on, a quiet room is slowly turned up."),
]
BY_NAME = {s[0]: s for s in SPECS}

# what each panel knob is written to, for run_renderer.sh to read at launch
FILES = {"bit_depth": "bit-depth", "dither": "dither",
         "addr_settle_ns": "addr-settle-ns", "panel_type": "panel-type",
         "temporal_dither": "temporal-dither", "dither_min": "dither-min"}


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
        "mic_auto_gain": bool(ears.get("mic_auto_gain", False)),
        "bit_depth": 64, "dither": 0.0, "addr_settle_ns": 0,
        "panel_type": 0, "temporal_dither": True, "dither_min": 0.2,
        "gain_r": float(wb.get("r", 1.0)),
        "gain_g": float(wb.get("g", 0.88)),
        "gain_b": float(wb.get("b", 0.83)),
        "nearest_colour": True,
        "black_point": int(pipeline.BLACK_POINT),
        "pic_black": int(pipeline.PIC_BLACK),
        "pic_floor": int(pipeline.PIC_FLOOR),
        "pic_knee": int(pipeline.PIC_KNEE),
        "low_end": int(pipeline.LOW_END),
        "low_full": int(pipeline.LOW_FULL),
        "low_red": float(pipeline.LOW_RED),
        "low_blue": float(pipeline.LOW_BLUE),
        "unsharp_radius": float(pipe.get("unsharp_radius", 1.0)),
        "unsharp_percent": int(pipe.get("unsharp_percent", 60)),
        "video_tone_target": 112,
        "video_floor": False,
    }


class Tuning:
    def __init__(self, cfg: dict):
        self._lock = threading.Lock()
        self.defaults = _shipped(cfg)
        self.values = dict(self.defaults)
        self.video = None            # the VideoPlayer, when there is one
        self.ears = None             # the EarsSource, when the wall has one
        try:
            with open(PATH) as fh:
                saved = json.load(fh)
            for k, v in saved.items():
                if k in BY_NAME:
                    self.values[k] = self._clean(k, v)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            pass
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
        return {
            "values": vals,
            "defaults": self.defaults,
            "knobs": [{"name": n, "group": g, "kind": k, "min": lo, "max": hi,
                       "step": st, "restart": rs, "note": note}
                      for n, g, k, lo, hi, st, rs, note in SPECS],
        }

    # ---- writing -------------------------------------------------------
    def _clean(self, name, v):
        _, _, kind, lo, hi, step, _, _ = BY_NAME[name]
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
        """Returns (changed, rejected, whether the renderer must relaunch)."""
        changed, rejected, restart = {}, [], False
        with self._lock:
            for k, v in (patch or {}).items():
                if k not in BY_NAME:
                    rejected.append(k)
                    continue
                try:
                    clean = self._clean(k, v)
                except ValueError:
                    rejected.append(k)
                    continue
                if clean != self.values[k]:
                    self.values[k] = clean
                    changed[k] = clean
                    if BY_NAME[k][6]:
                        restart = True
        if changed:
            self.apply()
            self._save()
        if restart:
            # Nobody should have to press a button to see what they just
            # turned. The launch flags are launch flags; the wall takes the
            # panel down and brings it back itself.
            print("[tuning] " + self.restart_renderer())
        return changed, rejected, restart

    def reset(self):
        with self._lock:
            self.values = dict(self.defaults)
        self.apply()
        self._save()
        print("[tuning] " + self.restart_renderer())

    # ---- making it so ---------------------------------------------------
    def apply(self):
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
        if self.ears is not None:
            self.ears.configure(on=v["hearing"], clip_s=v["listen_for"],
                                gate_db=v["room_gate"],
                                silence_s=v["quiet_before_letting_go"],
                                relisten_s=v["listen_again_every"],
                                retry_s=v["retry_after_miss"],
                                keep_s=v["keep_through_noise"],
                                gain=v["mic_gain"], agc=v["mic_auto_gain"])
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

    # ---- the renderer ---------------------------------------------------
    @staticmethod
    def restart_renderer() -> str:
        """Relaunch the renderer so the launch flags take. systemd brings it
        back; without systemd, run_renderer.sh has to be started by hand."""
        try:
            out = subprocess.run(["pgrep", "-f", "[a]rt_display"],
                                 capture_output=True, text=True, timeout=5)
            pids = [int(x) for x in out.stdout.split()]
        except (OSError, subprocess.SubprocessError, ValueError):
            return "could not look for the renderer"
        if not pids:
            return "the renderer was not running"
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        return f"renderer relaunching ({len(pids)} stopped)"
