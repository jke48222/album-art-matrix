#!/usr/bin/env python3
"""Now-playing reporter — runs on the Mac, polled by the Pi brain.

  GET /nowplaying -> NowPlaying JSON, or 204 when nothing to show.

stdlib-only (runs fine under /usr/bin/python3; the adapter's iTunes fallback
lazily imports requests and quietly skips if it's missing — the MusicKit
--cover path covers art in practice). First run triggers two one-time
prompts: Automation (control Music) and the macOS firewall (incoming
connections) — accept both.

Run:        python3 scripts/mac_reporter.py [port]      # default 8787
Autostart:  scripts/com.albumartmatrix.reporter.plist (optional; see notes)
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dataclasses import asdict
from http.server import BaseHTTPRequestHandler, HTTPServer

from brain.nowplaying import NowPlaying
from brain.nowplaying.applemusic import AppleMusicSource

SOURCE = AppleMusicSource(endpoint="")

# Pushed state from the iOS companion (ios-companion/). Outranks everything —
# it's the only source that knows the iPhone in real time. Expires so a dead
# phone can't pin the wall: the app heartbeats every ~15s while music plays.
PUSH_TTL = 40.0
_push = {"at": 0.0, "data": None}


def _pushed_now():
    if _push["data"] is None or time.monotonic() - _push["at"] > PUSH_TTL:
        return None
    d = _push["data"]
    if not d.get("playing") or not d.get("track"):
        return None
    art = d.get("art") or SOURCE._art_url(d["track"], d.get("artist", "?"),
                                          d.get("album", "?"))
    # The phone heartbeats every ~15s; replaying its progress frozen at push
    # time would make the brain's extrapolated needle (and the locked record
    # rotation) sawtooth between heartbeats. Age it by the time since push.
    prog = d.get("progress_ms")
    if prog is not None:
        prog = int(prog + (time.monotonic() - _push["at"]) * 1000)
        if d.get("duration_ms"):
            prog = min(prog, int(d["duration_ms"]))
    return NowPlaying(
        track_id="applemusic:" + (d.get("id")
                                  or f"{d.get('artist')}|{d.get('track')}"),
        title=d["track"], artist=d.get("artist", "?"),
        album=d.get("album", "?"), art_url=art,
        progress_ms=prog, duration_ms=d.get("duration_ms"),
        is_playing=True,
    )


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        # The web app (any origin) reads this over fetch; without this header
        # the browser throws the response away.
        self.send_header("Access-Control-Allow-Origin", "*")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_POST(self):
        if not self.path.startswith("/push"):
            self.send_response(404)
            self._cors()
            self.end_headers()
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self.send_response(400)
            self._cors()
            self.end_headers()
            return
        _push["at"], _push["data"] = time.monotonic(), data
        if data.get("track"):
            print(f"[reporter] push: {data.get('artist')} — {data['track']}"
                  f" ({'playing' if data.get('playing') else 'paused'})")
        self.send_response(204)
        self._cors()
        self.end_headers()

    def _phone_age(self):
        """Seconds since the phone last pushed, or None if it never has.
        Carried as a header so it survives a 204 with no body: this is how
        the wall knows whether anyone is home."""
        if _push["data"] is None:
            return None
        return time.monotonic() - _push["at"]

    def do_GET(self):
        if not self.path.startswith("/nowplaying"):
            self.send_response(404)
            self._cors()
            self.end_headers()
            return
        try:
            pushed = _pushed_now()
            now = pushed or SOURCE.get_current()
        except Exception as exc:
            print(f"[reporter] {exc}")
            self.send_response(500)
            self._cors()
            self.end_headers()
            return
        age = self._phone_age()
        if now is None:
            self.send_response(204)
            self._cors()
            if age is not None:
                self.send_header("X-Phone-Age", f"{age:.0f}")
            self.end_headers()
            return
        payload = asdict(now)
        payload["tier"] = "iPhone push" if pushed else "Mac tiers"
        body = json.dumps(payload).encode()
        self.send_response(200)
        self._cors()
        if age is not None:
            self.send_header("X-Phone-Age", f"{age:.0f}")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    print(f"[reporter] Music now-playing on 0.0.0.0:{port} — ctrl-C to stop")
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
