#!/usr/bin/env python3
"""Loopback native QA with production display sessions and service validation.

Only authored pixels and synthetic account metadata are served. Credentials and
QR payloads are never included in the request receipt or read from this Mac.

The wall behind it is the production ControlState, DisplaySession and tuning
store (brain/tuning.py) in a temporary folder. Only the renderer is authored:
a fake that attaches, restarts and fails on command, and a process lookup that
never finds or signals a real art_display. /health answers authored bodies in
the brain's own schema (health_fixtures.json). POST /frame and /clip are
taken as control.py takes them, so a picture the app sends (a queued one
delivered on the way back, say) is shown, never turned down by a route the
fixture lacks.

QA controls, never recorded as wall writes:
  POST /qa/reset {phase}        connected, unlinked, offline (503 to every read),
                                tuned, notuning, slowtuning, badtuning,
                                tuning-changed, tuning-unsupported,
                                tuning-failing, tuning-slow
  POST /qa/reject {enabled}     every wall write answers 503
  POST /qa/interrupt            the wall switches to ambient, as another phone would
  POST /qa/health {preset}      the /health body. "fail" answers 500
  POST /qa/available {enabled, as, seconds}  the wall goes away without a
                                reset. as is silent (no answer for 3.5 s, then
                                the socket closes: the app times out), dropped
                                (the connection is accepted, then reset: the
                                app sees -1005), refused (nothing listens on
                                the port for `seconds`, 20 by default and at
                                most 120, so every connection is refused and
                                the app sees -1004, and the wall then answers
                                again) or http (503)
  POST /qa/delay {seconds}      hold GET /state this long, at most 2.8 s
  POST /qa/renderer {state}     running, restarting, stalled, stopped, absent
  POST /qa/occupy {purpose}     another phone's display session holds the wall,
                                with stripes of its own, so it never passes for
                                this phone's glow
  GET  /qa/status               everything a test asserts on
"""
from __future__ import annotations

import argparse
import collections
import copy
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import base64
import socket
import struct
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from brain import control as control_module
from brain import services as services_module
from brain import tuning as tuning_module
from brain.wall import Wall
from capture_home import artwork, fixture
from connections_fixtures import configure
from setup_fixtures import ABOUT_TUNED, last_picture_png

HEALTH = json.loads((Path(__file__).with_name("health_fixtures.json")).read_text())
UNAVAILABLE = ("silent", "dropped", "refused", "http")
# The modes whose loop calls pace() in brain/main.py. In every other mode
# the fixture shows one still picture (its clock never ticks).
ANIMATED = ("cd", "ambient", "ticker", "voice")
RENDERER_STATES = ("running", "restarting", "stalled", "stopped", "absent")
# Phases whose GET /tuning is not the store's answer.
NO_TUNING = ("notuning", "tuning-unsupported")
TUNING_DELAY = {"slowtuning": 6.0, "tuning-slow": 3.0}
# Changed knobs per phase. tuned moves three LED knobs, which is what the
# About page counts. tuning-changed also moves a launch flag and, through
# the seed below, the brightness ceiling.
TUNED = {"tuned": ABOUT_TUNED,
         "tuning-changed": {"bit_depth": 48, "black_point": 12, "gain_b": 0.78}}
OCCUPIER = "qa-occupied-by-another-phone"
FAKE_PID = 4242


class FakeRenderer:
    """The Pi renderer sink's status(). process says whether an art_display
    is running for the restart to find."""

    def __init__(self):
        self.attached, self.connects, self.gone_at, self.process = True, 1, None, True

    def __call__(self):
        return {"attached": self.attached, "connects": self.connects,
                "detached_s": None if self.attached else round(time.monotonic() - self.gone_at, 1),
                "pending_s": None}

    def leave(self, ago=0.0):
        self.attached, self.gone_at = False, time.monotonic() - ago


def listening_ear():
    """An ear with a microphone, knocks, a song library and a voice, so the
    Listening tab has live knobs."""
    def nothing(**_):
        return None
    return SimpleNamespace(configure=nothing, knocks=SimpleNamespace(configure=nothing),
                           library=SimpleNamespace(configure=nothing), _library_kept=None,
                           teacher=SimpleNamespace(configure=nothing),
                           voice=SimpleNamespace(configure=nothing, wake=None, transcriber=None))


class Session:
    def __init__(self, side=64):
        self.lock = threading.RLock()
        self.ctrl = None
        # 64 is the bench panel, 192 the nine-panel wall (3 x 3 tiles of 64).
        self.side = side
        # The server answering now, and how long the next refusal lasts
        # (POST /qa/available as refused). Set by main.
        self.server = None
        self.refuse_s = None
        # The square the last picture left on the wall, made once at the wall's side.
        self.last_png = last_picture_png(side)
        self.reset("connected")

    def reset(self, phase="connected"):
        if self.ctrl is not None:
            self.ctrl.display_session.cancel()
        for filename in (control_module.STATE_PATH, services_module.PATH, tuning_module.PATH):
            Path(filename).unlink(missing_ok=True)
        seed = {"mode": "clock", "brightness": 0.4, "wb_r": 0.92,
                "wb_g": 0.87, "wb_b": 0.8, "finish": "poster"}
        if phase == "tuning-changed":
            seed["panel_brightness"] = 140
        self.ctrl = control_module.ControlState(seed=seed, frame_len=self.side * self.side * 3,
            wall=Wall(tile=64, cols=self.side // 64, rows=self.side // 64))
        authored = fixture("live")
        self.ctrl.now_showing = authored["now_showing"]
        self.ctrl.art_colors = authored["art_colors"]
        self.ctrl.shown_seq = authored["shown_seq"]
        self.ctrl.phone_side = 64
        self.phase = phase
        self.renderer = FakeRenderer()
        self.restarts = []
        self.ctrl.tuning = None if phase in NO_TUNING else self.make_tuning(phase)
        self.services = configure(SimpleNamespace(studies={}), "connected")
        configured = phase != "unlinked"
        self.store = services_module.Services({"google": {
            "api_key": "AIza" + "Q" * 35 if configured else "",
            "cx": "qa_engine_12345" if configured else "",
        }})
        self.requests = []
        self.reject = False
        self.available = phase != "offline"
        # The reset's offline phase keeps answering 503, as batch 16's tests
        # expect. /qa/available chooses how a wall that is away behaves.
        self.unavailable_as = "http"
        self.delay_s = 0.0
        self.health_preset = "steady"
        self.health_reads = 0
        self.gets = collections.Counter()
        self.check_gets = 0
        # A real time a little before the reset, so the page shows a "Shown" line.
        self.last_at = int(time.time()) - 120
        self.refresh_services()
        self.initial = self.ctrl.get()

    def make_tuning(self, phase):
        store = tuning_module.Tuning({})
        store.ears = listening_ear()
        store.renderer = self.renderer
        changes = TUNED.get(phase)
        if changes:
            # Straight into the values: an update() would restart the fake
            # renderer, and a phase starts with the panel running.
            store.values.update(changes)
            store._save()
        store.apply()
        return store

    def refresh_services(self):
        key_set = bool(self.store.get("google", "api_key"))
        cx_set = bool(self.store.get("google", "cx"))
        self.services["google"] = {
            "key_set": key_set, "cx_set": cx_set, "ready": key_set and cx_set,
            "provider": "google" if key_set and cx_set else "web",
            "state": "saved" if key_set and cx_set else "unconfigured",
            "checking": False, "verified": False,
            "pictures": 4 if key_set and cx_set else 0,
            "problem": None,
            "last": {"title": "A quiet coastline", "source": "wikipedia", "at": self.last_at,
                     "frame": True} if key_set and cx_set else None,
        }

    def state(self):
        self.ctrl.display_session.status()
        self.ctrl.display_mode = self.ctrl.get()["mode"]
        return self.ctrl.public_state()

    def frame(self):
        """What the panels are lighting: a check's own pixels, a picture or
        clip the app sent, or the face."""
        result = self.ctrl.display_session.render((1.0, 1.0, 1.0))
        if result is not None:
            return result[0].tobytes()
        mode = self.ctrl.get()["mode"]
        if mode == "frame" and self.ctrl.frame_override is not None:
            return self.ctrl.frame_override
        if mode == "clip" and self.ctrl.clip:
            return self.ctrl.clip["frames"][0]
        return artwork(self.side)

    def fitted(self, value):
        """A base64 square from the app at the wall's size, or None, as
        control.py reads px."""
        try:
            px = base64.b64decode(value or "", validate=True)
        except (ValueError, TypeError):
            return None
        return self.ctrl.wall.fit(px)

    def show_frame(self, body):
        """POST /frame, as control.py answers it."""
        px = self.fitted(body.get("px"))
        if px is None:
            return 400, {"error": "px must be square raw RGB, base64-encoded"}
        self.ctrl.frame_override = px
        self.ctrl.shown_seq += 1
        self.ctrl.apply({"mode": "frame"})
        return 200, self.state()

    def show_clip(self, body):
        """POST /clip, as control.py answers it."""
        raw = body.get("frames")
        if not isinstance(raw, list) or not 1 <= len(raw) <= 240:
            return 400, {"error": "frames must be 1-240 items"}
        frames = [self.fitted(item) for item in raw]
        if any(item is None for item in frames):
            return 400, {"error": "every frame must be square raw RGB"}
        self.ctrl.clip = {"fps": control_module._clamp(body.get("fps", 12), 1, 24), "frames": frames}
        self.ctrl.shown_seq += 1
        self.ctrl.apply({"mode": "clip"})
        return 200, self.state()

    def reported_frame(self):
        """GET /frame.raw, as main.py reports it: during a guest code the
        frame from before it, so the password never leaves the wall. A wall
        switched off is dark, as the real renderer's frame is."""
        private, cover = self.ctrl.display_session.cover()
        if private:
            return cover if cover is not None else artwork(self.side)
        if self.ctrl.get()["mode"] == "off":
            return bytes(self.side * self.side * 3)
        return self.frame()

    def health(self):
        if self.health_preset == "fail":
            return 500, {"error": "Authored health failure"}
        body = copy.deepcopy(HEALTH[self.health_preset])
        if "mode" in body:
            body["mode"] = self.ctrl.get()["mode"]
            # main.py stamps fps_at only in pace(), which runs in the animated
            # modes alone, so a still wall's paced rate is old. Outside them
            # the fixture shows one still picture, clock included, so it
            # sends no frames either. The served reading then says Still,
            # which agrees with the frame the wall is showing.
            if body["mode"] not in ANIMATED:
                if body.get("fps_age_s") is not None:
                    body["fps_age_s"] = max(body["fps_age_s"], 1800.0)
                if body.get("sent_fps") is not None:
                    body["sent_fps"] = 0.0
        return 200, body

    def tuning_get(self):
        if self.phase == "tuning-failing":
            return 500, {"error": "Authored tuning failure"}
        if self.phase == "badtuning":
            return 200, {}
        if self.ctrl.tuning is None:
            return 503, {"error": control_module.ControlState._NO_TUNING}
        return 200, self.ctrl.tuning_public()

    def set_renderer(self, state):
        store = self.ctrl.tuning
        if store is None:
            raise ValueError("This phase has no tuning store.")
        r = self.renderer
        if state == "absent":
            store.renderer = None
            return
        store.renderer = r
        if state == "running":
            r.process = True
            if not r.attached:
                r.connects += 1
            r.attached = True
            store._restart = None
        elif state in ("restarting", "stalled"):
            r.process = True
            r.leave()
            store._restart = {"at": time.monotonic() - (21.0 if state == "stalled" else 0.0),
                              "connects": r.connects}
        elif state == "stopped":
            r.process = False
            r.leave(ago=16.0)
            store._restart = None

    def find_renderer(self):
        return [FAKE_PID] if self.renderer.process else []

    def stop_renderer(self, pid):
        self.restarts.append({"pid": pid, "at": time.time()})
        self.renderer.leave()

    def occupy(self, purpose):
        # Stripes, like the panel check's, so a capture of the wall held by
        # another phone never looks like this phone's own grey glow.
        pixels = bytearray()
        for y in range(self.side):
            for x in range(self.side):
                pixels += bytes((191, 64, 32)) if (x // 8) % 2 == 0 else bytes((24, 96, 191))
        return self.ctrl.display_session.begin({
            "token": OCCUPIER, "purpose": purpose, "seconds": 600,
            "px": base64.b64encode(pixels).decode(), "patch": {}})

    def snapshot(self):
        frame = self.frame()
        store = self.ctrl.tuning
        return {
            "state": self.state(), "initial": self.initial,
            "session": self.ctrl.display_session.status(), "services": self.services,
            "requests": self.requests,
            "gets": dict(self.gets), "check_gets": self.check_gets,
            "health_reads": self.health_reads, "health_preset": self.health_preset,
            "available": self.available, "unavailable_as": self.unavailable_as,
            "delay_s": self.delay_s, "phase": self.phase,
            "hostname": control_module._HOSTNAME,
            "tuning": None if store is None else {
                "values": store.public()["values"],
                "panel_brightness": self.ctrl.get()["panel_brightness"],
                "renderer": store.renderer_state(), "restarts": len(self.restarts)},
            "frame": {"bytes": len(frame), "sha256": hashlib.sha256(frame).hexdigest(),
                      "first_rgb": list(frame[:3]), "uniform": len(set(zip(frame[::3], frame[1::3], frame[2::3]))) == 1},
        }

    def record(self, path, body):
        entry = {"path": path, "fields": sorted(body),
                 # False for a write the app sent while the wall was away or
                 # refusing: tests count only what the wall actually took.
                 "served": self.available and not self.reject}
        if path == "/services":
            entry["service_fields"] = {key: sorted(value) for key, value in body.items() if isinstance(value, dict)}
        if path == "/display-session":
            entry["purpose"] = body.get("purpose")
            entry["patch_fields"] = sorted(body.get("patch", {})) if isinstance(body.get("patch", {}), dict) else []
        self.requests.append(entry)

    def gate(self):
        """None while the wall answers, else how it fails to."""
        return None if self.available else self.unavailable_as


def handler(session):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def reply(self, status, value, mime="application/json"):
            body = json.dumps(value).encode() if mime == "application/json" else value
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            if mime == "application/octet-stream":
                self.send_header("X-Frame-Width", str(session.side))
                self.send_header("X-Frame-Height", str(session.side))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def go_quiet(self, how):
            """A wall that is away. Silent answers nothing until the app's
            3 s timeout has passed. Dropped resets the accepted connection at
            once. Neither holds the session lock while it waits."""
            if how == "silent":
                time.sleep(3.5)
            else:
                try:
                    self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                               struct.pack("ii", 1, 0))
                except OSError:
                    pass
            self.close_connection = True

        def do_GET(self):
            path = urlsplit(self.path).path
            with session.lock:
                if path == "/qa/status":
                    self.reply(200, session.snapshot())
                    return
                session.gets[path] += 1
                if path == "/state" and self.headers.get("X-Tessera-Check"):
                    session.check_gets += 1
                if path == "/health":
                    session.health_reads += 1
                gate = session.gate()
                delay = (session.delay_s if path == "/state" else
                         TUNING_DELAY.get(session.phase, 0.0) if path == "/tuning" else 0.0)
            if gate in ("silent", "dropped"):
                self.go_quiet(gate)
                return
            if gate is None and delay:
                time.sleep(delay)            # outside the lock: nothing else waits
            with session.lock:
                if gate == "http":
                    self.reply(503, {"error": "Authored offline state"})
                elif path == "/state":
                    self.reply(200, session.state())
                elif path == "/display-session":
                    self.reply(200, session.ctrl.display_session.status())
                elif path == "/frame.raw":
                    self.reply(200, session.reported_frame(), "application/octet-stream")
                elif path == "/services":
                    self.reply(200, session.services)
                elif path == "/pictures/last.png":
                    # Like the brain: the frame only while a last picture is reported.
                    if session.services["google"]["last"] is None:
                        self.reply(404, {"error": "No picture has been shown yet."})
                    else:
                        self.reply(200, session.last_png, "image/png")
                elif path == "/health":
                    self.reply(*session.health())
                elif path == "/tuning":
                    self.reply(*session.tuning_get())
                elif path == "/journal":
                    self.reply(200, {"entries": []})
                elif path == "/features":
                    self.reply(200, {"features": [], "off": []})
                elif path == "/show":
                    self.reply(200, {"ready": True, "state": "idle", "last": None})
                elif path == "/homekit":
                    self.reply(200, {"enabled": False})
                else:
                    self.reply(200, {})

        def qa(self, path, body):
            """The fixture's own controls. True when path was one of them."""
            if path == "/qa/reset":
                session.reset(body.get("phase", "connected")); self.reply(200, {"ready": True})
            elif path == "/qa/reject":
                session.reject = body.get("enabled", True); self.reply(200, {"ready": True})
            elif path == "/qa/interrupt":
                session.ctrl.apply({"mode": "ambient"}); self.reply(200, session.snapshot())
            elif path == "/qa/health":
                preset = body.get("preset")
                if preset != "fail" and preset not in HEALTH:
                    self.reply(400, {"error": "Unknown health preset", "presets": ["fail", *HEALTH]})
                else:
                    session.health_preset = preset; self.reply(200, {"ready": True})
            elif path == "/qa/available":
                how = body.get("as", "silent")
                seconds = body.get("seconds", 20)
                if how not in UNAVAILABLE:
                    self.reply(400, {"error": "as is silent, dropped, refused or http"})
                elif isinstance(seconds, bool) or not isinstance(seconds, (int, float)):
                    self.reply(400, {"error": "seconds is a number"})
                elif how == "refused" and not body.get("enabled", True):
                    # Nothing may listen, so the port is closed outright and
                    # opened again after `seconds` (see main).
                    session.refuse_s = max(1.0, min(120.0, float(seconds)))
                    self.reply(200, {"ready": True, "seconds": session.refuse_s})
                    threading.Thread(target=session.server.shutdown, daemon=True).start()
                else:
                    session.available = bool(body.get("enabled", True))
                    session.unavailable_as = how
                    self.reply(200, {"ready": True})
            elif path == "/qa/delay":
                seconds = body.get("seconds", 0)
                if isinstance(seconds, bool) or not isinstance(seconds, (int, float)):
                    self.reply(400, {"error": "seconds is a number"})
                else:
                    # Under the app's 3 s timeout, so the read lands late, not lost.
                    session.delay_s = max(0.0, min(2.8, float(seconds)))
                    self.reply(200, {"ready": True, "seconds": session.delay_s})
            elif path == "/qa/renderer":
                state = body.get("state")
                if state not in RENDERER_STATES:
                    self.reply(400, {"error": "Unknown renderer state", "states": list(RENDERER_STATES)})
                else:
                    try:
                        session.set_renderer(state)
                    except ValueError as error:
                        self.reply(409, {"error": str(error)})
                    else:
                        self.reply(200, session.snapshot())
            elif path == "/qa/occupy":
                purpose = body.get("purpose", "panel")
                try:
                    self.reply(200, session.occupy(purpose))
                except RuntimeError as error:
                    self.reply(409, {"error": str(error)})
                except ValueError as error:
                    self.reply(400, {"error": str(error)})
            else:
                return False
            return True

        def do_POST(self):
            path = urlsplit(self.path).path
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 <= length <= 2_000_000:
                    raise ValueError()
                body = json.loads(self.rfile.read(length) or "{}")
                if not isinstance(body, dict):
                    raise ValueError()
            except (ValueError, json.JSONDecodeError):
                self.reply(400, {"error": "Send a JSON object"}); return
            with session.lock:
                if path.startswith("/qa/"):
                    if not self.qa(path, body):
                        self.reply(404, {"error": "Unknown fixture control"})
                    return
                session.record(path, body)
                gate = session.gate()
            if gate in ("silent", "dropped"):
                self.go_quiet(gate)
                return
            with session.lock:
                if gate is not None or session.reject:
                    self.reply(503, {"error": "The authored test wall could not confirm this change."}); return
                try:
                    if path == "/display-session":
                        self.reply(200, session.ctrl.display_session.begin(body))
                    elif path == "/display-session/end":
                        self.reply(200, session.ctrl.display_session.end(body))
                    elif path == "/state":
                        rejected = session.ctrl.apply(body)
                        self.reply(200, {**session.state(), "rejected": list(rejected)})
                    elif path == "/services":
                        _, rejected = session.store.update(body)
                        session.refresh_services()
                        self.reply(200, {**session.services, "rejected": list(rejected)})
                    elif path in ("/nowplaying", "/pressing"):
                        self.reply(200, {"accepted": True})
                    elif path == "/frame":
                        self.reply(*session.show_frame(body))
                    elif path == "/clip":
                        self.reply(*session.show_clip(body))
                    # The brain's own handlers (control.py), so the codes and
                    # bodies are the ones the wall sends.
                    elif path == "/tuning/restart":
                        self.reply(*session.ctrl.tuning_restart())
                    elif path == "/tuning/reset":
                        self.reply(*session.ctrl.tuning_reset())
                    elif path == "/tuning":
                        self.reply(*session.ctrl.tuning_write(body))
                    else:
                        self.reply(404, {"error": "Unknown fixture route"})
                except RuntimeError as error:
                    self.reply(409, {"error": str(error)})
                except ValueError as error:
                    self.reply(400, {"error": str(error)})
                except OSError:
                    self.reply(503, {"error": "The test wall could not persist this change."})
    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=65367)
    parser.add_argument("--side", type=int, choices=(64, 192), default=64,
                        help="The fixture wall's side in LEDs. 192 is the nine-panel wall.")
    parser.add_argument("--hostname", default="qa-wall",
                        help="The computer name GET /state reports as wall.name.")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="tessera-setup-fixture-") as folder:
        control_module.STATE_PATH = str(Path(folder) / "state.json")
        control_module.JOURNAL_PATH = str(Path(folder) / "journal.jsonl")
        # The ceiling and the launch flags are written beside the renderer.
        # Here that is the temporary folder, never ~/album-art-matrix.
        control_module.ROOT = folder
        control_module._HOSTNAME = args.hostname
        services_module.PATH = str(Path(folder) / "services.json")
        tuning_module.PATH = str(Path(folder) / "tuning.json")
        tuning_module.ROOT = folder
        # The restart looks for the fake renderer, never a real art_display.
        tuning_module.find_renderer = lambda: session.find_renderer()
        tuning_module.stop_renderer = lambda pid: session.stop_renderer(pid)
        session = Session(args.side)
        try:
            while True:
                server = ThreadingHTTPServer(("127.0.0.1", args.port), handler(session))
                server.daemon_threads = True
                session.server = server
                try:
                    server.serve_forever()
                finally:
                    server.server_close()
                # Only a refusal stops the server: nothing listens for its
                # seconds, then the same wall answers again.
                with session.lock:
                    pause, session.refuse_s = session.refuse_s, None
                if pause is None:
                    break
                time.sleep(pause)
                with session.lock:
                    session.available = True
        finally:
            session.ctrl.display_session.cancel()


if __name__ == "__main__":
    main()
