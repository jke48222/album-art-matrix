"""HomeKit: the wall in the Home app, and so on Siri, the Watch and in
Control Centre.

One bridge, four things behind it:

    Wall          a light. On, off, brightness, and a colour, which is the
                  ambient face's colour. "Hey Siri, wall to thirty percent."
    Wall Remote   a television. The faces are its inputs, and the Apple TV
                  Remote in Control Centre drives it: the arrows change the
                  face, play/pause turns the ears on and off, back goes to
                  the art, info runs the song's name across, and the volume
                  keys dim and brighten.
    Wall Sound    an occupancy sensor. The ear's gate is open, or was within
                  the last half minute. For automations: lamps when the room
                  has voices, a notification when it has any and nobody is
                  home.
    Wall Music    a motion sensor. A playing song with a sleeve is on the
                  wall. "When music starts, dim the lamps."

Siri knows a light's words (on, off, percent, colours, rooms) and a TV's
(on, off, pause, mute). Apple gave it no words for inputs, so the Home tile
and the Control Centre remote change faces, and the wall's own ears do the
rest. Automations, control from outside the house and Siri on a HomePod all
need a home hub (a HomePod, Apple TV or iPad); pairing and Siri from a phone
on this Wi-Fi do not.

The library is HAP-python. It runs on its own thread and event loop inside
the brain, advertises over mDNS with python-zeroconf (avahi may run beside
it; they share the port), and keeps its pairing in
~/.config/album-art-matrix/homekit.state. Delete that file to unpair.

Pairing: the wall draws its own setup code on the panel as a QR, for three
minutes at boot while unpaired and whenever POST /homekit/show asks. GET
/homekit gives the same code as text for typing into the Home app.
"""
from __future__ import annotations

import colorsys
import logging
import os
import sys
import threading
import time

import numpy as np

STATE_PATH = os.path.expanduser("~/.config/album-art-matrix/homekit.state")


def _log_pairing(level: str = "info"):
    """HAP-python talks through `logging`, which the brain never configured,
    so a pairing that failed left nothing behind. Its INFO lines (pair
    setup, pair verify, who connected) go to stderr, which systemd keeps
    unbuffered in the journal; the QR is still printed by the library.
    `[homekit] log = "debug"` adds every request the phone makes."""
    lg = logging.getLogger("pyhap")
    if not lg.handlers:
        h = logging.StreamHandler(sys.stderr)
        h.setFormatter(logging.Formatter("[homekit] %(name)s: %(message)s"))
        lg.addHandler(h)
        lg.propagate = False
    lg.setLevel(logging.DEBUG if str(level).lower() == "debug" else logging.INFO)

# The faces the remote can pick, in the order the arrows walk them.
# (identifier the Home app uses, its name there, the wall's mode)
FACES = [
    (1, "Art", "art"),
    (2, "Disc", "cd"),
    (3, "Ambient", "ambient"),
    (4, "Clock", "clock"),
    (5, "Lyrics", "lyrics"),
    (6, "Nine", "nine"),
    (7, "Ticker", "ticker"),
]
FACE_MODES = [m for _, _, m in FACES]

SOUND_HOLD_S = 30.0    # "sound in the room" stays on this long after the gate shuts
CODE_SHOW_S = 180.0    # how long the pairing code stays on the panel
POLL_S = 0.5           # how often the wall's state is read for the Home app
STEP = 0.10            # a volume key moves the brightness this much

# HAP RemoteKey values
K_REWIND, K_FF, K_NEXT, K_PREV = 0, 1, 2, 3
K_UP, K_DOWN, K_LEFT, K_RIGHT, K_SELECT, K_BACK, K_EXIT, K_PLAY, K_INFO = \
    4, 5, 6, 7, 8, 9, 10, 11, 15


def _hex_to_hs(color: str) -> tuple[float, float]:
    """'#rrggbb' -> (hue 0-360, saturation 0-100), the Home app's colour."""
    try:
        c = color.lstrip("#")
        r, g, b = (int(c[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
    except (ValueError, IndexError, AttributeError):
        return 0.0, 0.0
    h, s, _ = colorsys.rgb_to_hsv(r, g, b)
    return round(h * 360.0, 1), round(s * 100.0, 1)


def _hs_to_hex(hue: float, sat: float) -> str:
    r, g, b = colorsys.hsv_to_rgb(hue / 360.0, sat / 100.0, 1.0)
    return "#%02x%02x%02x" % (round(r * 255), round(g * 255), round(b * 255))


def code_frame(uri: str, side: int) -> bytes:
    """The setup code as a QR drawn for the panel: raw RGB, side x side.

    Two pixels a module on the 64, a white quiet zone all round, and the
    white held down to keep the LEDs from blooming into the black modules.
    The phone reads it from a foot or so away, where the dots blur into
    squares."""
    import pyqrcode
    q = pyqrcode.create(uri, error="M")       # M: 21 modules for a setup uri
    rows = q.code
    n = len(rows)
    scale = max(1, (side - 8) // n)
    off = (side - n * scale) // 2
    white = 150
    f = np.full((side, side, 3), white, dtype=np.uint8)
    for y, row in enumerate(rows):
        for x, dark in enumerate(row):
            if dark:
                y0, x0 = off + y * scale, off + x * scale
                f[y0:y0 + scale, x0:x0 + scale] = 0
    return f.tobytes()


class HomeKit:
    """The bridge and its four accessories, on their own thread."""

    def __init__(self, ctrl, name: str = "Wall", port: int = 51826,
                 pincode: str | None = None, state_path: str = STATE_PATH,
                 log: str = "info", television: bool = True, sensors: bool = True):
        self.ctrl = ctrl
        self.name = name
        self.port = port
        self.television = television     # the remote can be left out of the bridge
        self.sensors = sensors           # and so can the two sensors
        # HAP-python keeps its keys and pairings in the state file but NOT
        # the setup code: without one here, every restart draws a new code,
        # and a code read off the panel a minute ago stops working.
        self.pincode = pincode
        self.state_path = state_path
        self.log = log
        self.driver = None
        self.bridge = None
        self.error = None
        self.ready = threading.Event()
        self.ret = None              # the face "on" comes back to after "off"
        self._hue, self._sat = 0.0, 0.0
        self._code_until = 0.0
        self._code_ret = None
        self._last: dict[int, object] = {}
        self._chars: dict[str, object] = {}
        self._thread = threading.Thread(target=self._run, name="homekit", daemon=True)

    def start(self) -> "HomeKit":
        self._thread.start()
        return self

    # ---- the accessories ---------------------------------------------------
    def _run(self):
        try:
            import asyncio
            from pyhap.accessory import Accessory, Bridge
            from pyhap.accessory_driver import AccessoryDriver
            from pyhap.const import (CATEGORY_LIGHTBULB, CATEGORY_SENSOR,
                                     CATEGORY_TELEVISION)
        except ImportError as exc:
            self.error = (f"HAP-python is not installed ({exc}); "
                          "pip install 'HAP-python[QRCode]'")
            print("[homekit] " + self.error, flush=True)
            self.ready.set()
            return
        try:
            _log_pairing(self.log)
            os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            pin = self.pincode.encode() if self.pincode else None
            # The library brings its own mDNS responder (python-zeroconf) and
            # binds port 5353 beside avahi, which already answers for the
            # Pi's name. Once both are bound, a query for album-matrix.local
            # can land on the library's socket, which knows nothing of that
            # name, and the phone app that dials album-matrix.local:8788
            # stops finding the wall. Naming the HAP records after the Pi's
            # own hostname makes the library answer for that name too, with
            # the same address avahi gives, so whichever responder hears the
            # question, the wall is found.
            import socket
            host = socket.gethostname().split(".")[0] or "album-matrix"
            driver = AccessoryDriver(port=self.port, persist_file=self.state_path,
                                     pincode=pin, loop=loop,
                                     zeroconf_server=f"{host}.local.")
            self.driver = driver
            bridge = Bridge(driver, "Album Art Matrix")
            bridge.set_info_service(manufacturer="Album Art Matrix", model="Wall",
                                    serial_number=self._serial(),
                                    firmware_revision="1.0")
            c = self._chars

            # The light: what Siri is best at.
            light = Accessory(driver, self.name)
            light.category = CATEGORY_LIGHTBULB
            light.set_info_service(manufacturer="Album Art Matrix", model="Wall light",
                                   serial_number=self._serial() + "-L",
                                   firmware_revision="1.0")
            svc = light.add_preload_service("Lightbulb",
                                            chars=["Brightness", "Hue", "Saturation"],
                                            unique_id="light")
            c["on"] = svc.configure_char("On", value=True)
            c["bri"] = svc.configure_char("Brightness", value=100)
            c["hue"] = svc.configure_char("Hue", value=0.0)
            c["sat"] = svc.configure_char("Saturation", value=0.0)
            svc.setter_callback = self._light_set    # every changed char, one call

            # The television: the faces as inputs, and a remote.
            tv = Accessory(driver, self.name + " Remote")
            tv.category = CATEGORY_TELEVISION
            tv.set_info_service(manufacturer="Album Art Matrix", model="Wall faces",
                                serial_number=self._serial() + "-T",
                                firmware_revision="1.0")
            tvs = tv.add_preload_service("Television", chars=["Name", "RemoteKey"],
                                         unique_id="tv")
            tvs.configure_char("Name", value=self.name + " Remote")
            tvs.configure_char("ConfiguredName", value=self.name + " Remote")
            tvs.configure_char("SleepDiscoveryMode", value=1)
            c["active"] = tvs.configure_char("Active", value=1,
                                             setter_callback=self._tv_active)
            c["input"] = tvs.configure_char("ActiveIdentifier", value=1,
                                            setter_callback=self._tv_input)
            tvs.configure_char("RemoteKey", setter_callback=self._tv_key)
            for ident, label, mode in FACES:
                src = tv.add_preload_service("InputSource", chars=["Identifier", "Name"],
                                             unique_id=f"input-{mode}")
                src.configure_char("Identifier", value=ident)
                src.configure_char("Name", value=label)
                src.configure_char("ConfiguredName", value=label)
                src.configure_char("InputSourceType", value=3)   # the HDMI icon
                src.configure_char("IsConfigured", value=1)
                src.configure_char("CurrentVisibilityState", value=0)
                tvs.add_linked_service(src)
            spk = tv.add_preload_service("TelevisionSpeaker",
                                         chars=["Active", "VolumeControlType",
                                                "VolumeSelector"],
                                         unique_id="tv-speaker")
            spk.configure_char("Active", value=1)
            spk.configure_char("VolumeControlType", value=1)   # relative: keys only
            spk.configure_char("Mute", value=False, setter_callback=self._tv_mute)
            spk.configure_char("VolumeSelector", setter_callback=self._tv_volume)
            tvs.add_linked_service(spk)
            tv.set_primary_service(tvs)

            # The sensors: what the room is doing, for the rest of the house.
            room = Accessory(driver, self.name + " Sound")
            room.category = CATEGORY_SENSOR
            room.set_info_service(manufacturer="Album Art Matrix", model="Wall ear",
                                  serial_number=self._serial() + "-S",
                                  firmware_revision="1.0")
            occ = room.add_preload_service("OccupancySensor", chars=["StatusActive"],
                                           unique_id="sound")
            c["occ"] = occ.configure_char("OccupancyDetected", value=0)
            c["occ_active"] = occ.configure_char("StatusActive", value=False)

            music = Accessory(driver, self.name + " Music")
            music.category = CATEGORY_SENSOR
            music.set_info_service(manufacturer="Album Art Matrix", model="Wall sleeve",
                                   serial_number=self._serial() + "-M",
                                   firmware_revision="1.0")
            mo = music.add_preload_service("MotionSensor", unique_id="music")
            c["music"] = mo.configure_char("MotionDetected", value=False)

            for acc in (light, tv, room, music):
                if acc is tv and not self.television:
                    continue
                if acc in (room, music) and not self.sensors:
                    continue
                bridge.add_accessory(acc)
            driver.add_accessory(accessory=bridge)
            self.bridge = bridge
            self._sync()                       # the first values, before anyone asks
            threading.Thread(target=self._sync_loop, name="homekit-sync",
                             daemon=True).start()
            paired = driver.state.paired
            print(f"[homekit] {self.name!r} on port {self.port}, "
                  f"{'paired' if paired else 'NOT paired'}, code "
                  f"{driver.state.pincode.decode()}", flush=True)
            if not paired:
                self.show_code(CODE_SHOW_S)
            self.ready.set()
            driver.start()                     # the HAP loop, until the brain dies
        except Exception as exc:
            self.error = f"{type(exc).__name__}: {exc}"
            print(f"[homekit] failed: {self.error}", flush=True)
            self.ready.set()

    def _serial(self) -> str:
        try:
            import socket
            return socket.gethostname()[:24]
        except Exception:
            return "wall"

    # ---- what the Home app does to the wall ---------------------------------
    def _power(self, on: bool, patch: dict):
        s = self.ctrl.get()
        if on:
            if s["mode"] == "off":
                patch["mode"] = self.ret if self.ret in FACE_MODES else "art"
        elif s["mode"] != "off":
            self.ret = s["mode"] if s["mode"] in FACE_MODES else "art"
            patch["mode"] = "off"

    def _light_set(self, vals: dict):
        """The light's characteristics, as one write: On, Brightness, Hue,
        Saturation, whichever the Home app sent together."""
        patch = {}
        if "On" in vals:
            self._power(bool(vals["On"]), patch)
        if "Brightness" in vals:
            b = int(vals["Brightness"])
            if b <= 0:
                self._power(False, patch)
            else:
                patch["brightness"] = max(0.05, min(1.0, b / 100.0))
        if "Hue" in vals or "Saturation" in vals:
            self._hue = float(vals.get("Hue", self._hue))
            self._sat = float(vals.get("Saturation", self._sat))
            s = self.ctrl.get()
            patch["color"] = _hs_to_hex(self._hue, self._sat)
            patch["match_art"] = False
            if patch.get("mode", s["mode"]) != "off":
                patch["mode"] = "ambient"        # a colour asked for is a colour shown
            # A colour picked in the Home app is a lamp's colour: the wall
            # goes that colour, plainly. The ambient effect chosen on the
            # phone (plaid, weave, rainbow...) would have taken the colour as
            # its base and drawn its pattern in it, which reads as "the
            # colour did not work". The phone's own ambient page still sets
            # any effect it likes.
            if s["effect"] != "solid":
                patch["effect"] = "solid"
        if patch:
            self.ctrl.apply(patch)

    def _tv_active(self, value):
        self._light_set({"On": bool(value)})

    def _tv_mute(self, value):
        self._light_set({"On": not bool(value)})

    def _tv_input(self, ident):
        mode = next((m for i, _, m in FACES if i == int(ident)), None)
        if mode:
            self.ctrl.apply({"mode": mode})

    def _tv_volume(self, value):
        s = self.ctrl.get()
        b = s["brightness"] + (STEP if int(value) == 0 else -STEP)
        self.ctrl.apply({"brightness": max(0.05, min(1.0, round(b, 2)))})

    def _step(self, d: int):
        s = self.ctrl.get()
        i = FACE_MODES.index(s["mode"]) if s["mode"] in FACE_MODES else -1
        self.ctrl.apply({"mode": FACE_MODES[(i + d) % len(FACE_MODES)]})

    def _tv_key(self, key):
        key = int(key)
        if key in (K_RIGHT, K_DOWN, K_NEXT):
            self._step(+1)
        elif key in (K_LEFT, K_UP, K_PREV):
            self._step(-1)
        elif key in (K_BACK, K_EXIT):
            self.ctrl.apply({"mode": "art"})
        elif key == K_SELECT:
            self.ctrl.nudge()                  # ask the sources again, now
        elif key == K_PLAY:
            tune = getattr(self.ctrl, "tuning", None)
            if tune is not None:
                try:
                    tune.update({"hearing": not bool(tune.get("hearing"))})
                except Exception as exc:
                    print(f"[homekit] hearing: {exc}", flush=True)
        elif key == K_INFO:
            ns = self.ctrl.now_showing or {}
            if ns.get("title"):
                text = ns["title"] + (" - " + ns["artist"] if ns.get("artist") else "")
                self.ctrl.apply({"ticker_text": text[:120], "ticker_loop": False,
                                 "ticker_style": "across", "mode": "ticker"})
        elif key in (K_FF, K_REWIND):
            self._tv_volume(0 if key == K_FF else 1)

    # ---- what the wall tells the Home app -----------------------------------
    def _sync_loop(self):
        while True:
            time.sleep(POLL_S)
            try:
                self._sync()
            except Exception as exc:
                print(f"[homekit] sync: {exc}", flush=True)

    def _put(self, name: str, value):
        char = self._chars.get(name)
        if char is None or self._last.get(name) == value:
            return
        self._last[name] = value
        char.set_value(value)     # thread-safe: the notify hops to the HAP loop

    def _sync(self):
        ctrl = self.ctrl
        s = ctrl.get()
        on = s["mode"] != "off"
        self._put("on", on)
        self._put("active", 1 if on else 0)
        self._put("bri", max(1, int(round(s["brightness"] * 100))))
        h, sat = _hex_to_hs(s.get("color", ""))
        self._put("hue", h)
        self._put("sat", sat)
        ident = next((i for i, _, m in FACES if m == s["mode"]), None)
        if ident is not None:
            self._put("input", ident)
        ear = getattr(ctrl, "ears", None)
        st = None
        if ear is not None:
            try:
                st = ear.status()
            except Exception:
                st = None
        if st:
            live = bool(st.get("on") and st.get("mic") and st.get("tools"))
            quiet = st.get("quiet_s")
            loud = bool(st.get("gate_open")) or (quiet is not None and quiet < SOUND_HOLD_S)
            self._put("occ", 1 if live and loud else 0)
            self._put("occ_active", live)
        else:
            self._put("occ", 0)
            self._put("occ_active", False)
        playing = bool(ctrl.now_showing) and ctrl.quiet_since is None and on
        self._put("music", playing)
        if self._code_until and time.monotonic() > self._code_until:
            self.hide_code()

    # ---- the pairing code on the panel --------------------------------------
    def show_code(self, seconds: float = CODE_SHOW_S) -> bool:
        if self.bridge is None:
            return False
        ctrl = self.ctrl
        px = ctrl.wall.fit(code_frame(self.bridge.xhm_uri(), ctrl.phone_side))
        if px is None:
            return False
        s = ctrl.get()
        if not self._code_until:
            self._code_ret = s["mode"] if s["mode"] not in ("frame", "clip", "video") else "art"
        ctrl.frame_override = px
        ctrl.shown_seq += 1
        ctrl.apply({"mode": "frame"})
        self._code_until = time.monotonic() + seconds
        return True

    def hide_code(self):
        if not self._code_until:
            return
        self._code_until = 0.0
        if self.ctrl.get()["mode"] == "frame":
            self.ctrl.apply({"mode": self._code_ret or "art"})

    def refresh(self) -> bool:
        """Tell every paired phone to read the accessory list again: bumps
        the configuration number, saves it, and re-advertises. For when the
        Home app has not noticed a face or a sensor that is plainly there."""
        if self.driver is None:
            return False
        self.driver.config_changed()      # thread-safe: the advertisement hops to the HAP loop
        return True

    # ---- for GET /homekit ---------------------------------------------------
    def status(self) -> dict:
        d = self.driver
        return {
            "enabled": True,
            "ready": self.ready.is_set(),
            "error": self.error,
            "name": self.name,
            "port": self.port,
            "paired": bool(d and d.state.paired),
            "code": d.state.pincode.decode() if d else None,
            "uri": self.bridge.xhm_uri() if self.bridge else None,
            "showing_code": bool(self._code_until and time.monotonic() < self._code_until),
            "faces": [{"id": i, "name": n, "mode": m} for i, n, m in FACES],
        }


def from_config(cfg: dict, ctrl) -> HomeKit | None:
    """Build and start the bridge from the [homekit] table, or None."""
    h = (cfg or {}).get("homekit") or {}
    if not h.get("enabled"):
        return None
    return HomeKit(ctrl, name=str(h.get("name", "Wall")).strip() or "Wall",
                   port=int(h.get("port", 51826)),
                   pincode=(str(h["pincode"]).strip() if h.get("pincode") else None),
                   state_path=os.path.expanduser(h.get("state", STATE_PATH)),
                   log=str(h.get("log", "info")),
                   television=bool(h.get("television", True)),
                   sensors=bool(h.get("sensors", True))).start()
