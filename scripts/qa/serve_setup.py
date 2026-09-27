#!/usr/bin/env python3
"""Loopback native QA with production display sessions and service validation.

Only authored pixels and synthetic account metadata are served. Credentials and
QR payloads are never included in the request receipt or read from this Mac.
"""
from __future__ import annotations

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
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
from brain.wall import Wall
from capture_home import artwork, fixture
from connections_fixtures import configure
from setup_fixtures import last_picture_png


class Session:
    def __init__(self, side=64):
        self.lock = threading.RLock()
        self.ctrl = None
        # 64 is the bench panel, 192 the nine-panel wall (3 x 3 tiles of 64).
        self.side = side
        # The square the last picture left on the wall, made once at the wall's side.
        self.last_png = last_picture_png(side)
        self.reset("connected")

    def reset(self, phase="connected"):
        if self.ctrl is not None:
            self.ctrl.display_session.cancel()
        for filename in (control_module.STATE_PATH, services_module.PATH):
            Path(filename).unlink(missing_ok=True)
        self.ctrl = control_module.ControlState(seed={
            "mode": "clock", "brightness": 0.4, "wb_r": 0.92,
            "wb_g": 0.87, "wb_b": 0.8, "finish": "poster",
        }, frame_len=self.side * self.side * 3,
            wall=Wall(tile=64, cols=self.side // 64, rows=self.side // 64))
        authored = fixture("live")
        self.ctrl.now_showing = authored["now_showing"]
        self.ctrl.art_colors = authored["art_colors"]
        self.ctrl.shown_seq = authored["shown_seq"]
        self.ctrl.phone_side = 64
        self.services = configure(SimpleNamespace(studies={}), "connected")
        configured = phase != "unlinked"
        self.store = services_module.Services({"google": {
            "api_key": "AIza" + "Q" * 35 if configured else "",
            "cx": "qa_engine_12345" if configured else "",
        }})
        self.requests = []
        self.reject = False
        self.available = phase != "offline"
        # A real time a little before the reset, so the page shows a "Shown" line.
        self.last_at = int(time.time()) - 120
        self.refresh_services()
        self.initial = self.ctrl.get()

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
        result = self.ctrl.display_session.render((1.0, 1.0, 1.0))
        return result[0].tobytes() if result is not None else artwork(self.side)

    def snapshot(self):
        frame = self.frame()
        return {
            "state": self.state(), "initial": self.initial,
            "session": self.ctrl.display_session.status(), "services": self.services,
            "requests": self.requests,
            "frame": {"bytes": len(frame), "sha256": hashlib.sha256(frame).hexdigest(),
                      "first_rgb": list(frame[:3]), "uniform": len(set(zip(frame[::3], frame[1::3], frame[2::3]))) == 1},
        }

    def record(self, path, body):
        entry = {"path": path, "fields": sorted(body)}
        if path == "/services":
            entry["service_fields"] = {key: sorted(value) for key, value in body.items() if isinstance(value, dict)}
        if path == "/display-session":
            entry["purpose"] = body.get("purpose")
            entry["patch_fields"] = sorted(body.get("patch", {})) if isinstance(body.get("patch", {}), dict) else []
        self.requests.append(entry)


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

        def do_GET(self):
            path = urlsplit(self.path).path
            with session.lock:
                if path == "/qa/status":
                    self.reply(200, session.snapshot())
                elif not session.available:
                    self.reply(503, {"error": "Authored offline state"})
                elif path == "/state":
                    self.reply(200, session.state())
                elif path == "/display-session":
                    self.reply(200, session.ctrl.display_session.status())
                elif path == "/frame.raw":
                    self.reply(200, session.frame(), "application/octet-stream")
                elif path == "/services":
                    self.reply(200, session.services)
                elif path == "/pictures/last.png":
                    # Like the brain: the frame only while a last picture is reported.
                    if session.services["google"]["last"] is None:
                        self.reply(404, {"error": "No picture has been shown yet."})
                    else:
                        self.reply(200, session.last_png, "image/png")
                elif path == "/health":
                    self.reply(200, {"fps": 30, "temp_c": 43.2, "uptime_s": 7200, "loop_age_s": 0.1, "mode": session.ctrl.get()["mode"]})
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
                if path == "/qa/reset":
                    session.reset(body.get("phase", "connected")); self.reply(200, {"ready": True}); return
                if path == "/qa/reject":
                    session.reject = body.get("enabled", True); self.reply(200, {"ready": True}); return
                if path == "/qa/interrupt":
                    session.ctrl.apply({"mode": "ambient"}); self.reply(200, session.snapshot()); return
                session.record(path, body)
                if not session.available or session.reject:
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
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="tessera-setup-fixture-") as folder:
        control_module.STATE_PATH = str(Path(folder) / "state.json")
        control_module.JOURNAL_PATH = str(Path(folder) / "journal.jsonl")
        services_module.PATH = str(Path(folder) / "services.json")
        session = Session(args.side)
        server = ThreadingHTTPServer(("127.0.0.1", args.port), handler(session))
        try:
            server.serve_forever()
        finally:
            session.ctrl.display_session.cancel()
            server.server_close()


if __name__ == "__main__":
    main()
