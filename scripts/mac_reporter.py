#!/usr/bin/env python3
"""Now-playing reporter — runs on the Mac, polled by the Pi brain.

  GET  /nowplaying -> NowPlaying JSON, or 204 when nothing to show.
  POST /push       -> what the phone is playing (the iOS companion posts it)
  GET  /art/<key>  -> artwork the Mac's Now Playing handed over as bytes
                      (a browser tab, Spotify's app...), served for the Pi
  GET  /services   -> what this Mac can see: {"mac_media": true|false}

What it reads, first answer wins: the phone's push, then Music.app, then
anything else this Mac is playing (through media-control, when installed:
Spotify's app, TIDAL, a browser on YouTube Music or SoundCloud), then the
account's view across devices via the MusicKit helper.

stdlib-only (runs fine under /usr/bin/python3; the adapter's iTunes fallback
lazily imports requests and quietly skips if it's missing — the MusicKit
--cover path covers art in practice). First run triggers two one-time
prompts: Automation (control Music) and the macOS firewall (incoming
connections) — accept both.

Run:        python3 scripts/mac_reporter.py [port]      # default 8787
Autostart:  scripts/com.albumartmatrix.reporter.plist (optional; see notes)
"""
import base64
import binascii
import hashlib
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dataclasses import asdict, replace
from http.server import BaseHTTPRequestHandler, HTTPServer

from brain.nowplaying import NowPlaying
from brain.nowplaying.applemusic import AppleMusicSource
from brain.nowplaying.macmedia import MacMediaSource, app_name, bundle_of

MAC = MacMediaSource() if MacMediaSource.available() else None
SOURCE = AppleMusicSource(endpoint="", mac=MAC)

# Pushed state from the iOS companion (ios-companion/). Outranks everything —
# it's the only source that knows the iPhone in real time. Expires so a dead
# phone can't pin the wall: the app heartbeats every ~15s while music plays.
PUSH_TTL = 40.0
_push = {"at": 0.0, "data": None}

# Artwork that arrived as bytes (the Mac's Now Playing), kept for the Pi to
# fetch at /art/<key>. A handful is plenty: the wall wants the current one.
ART_KEEP = 6
_art = {}                # key -> (bytes, mime), insertion-ordered
_EXT = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}
_logged = {"key": None}  # last track written to the log, so it stays readable


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


def _served_art(now: NowPlaying, host: str) -> NowPlaying:
    """A data: URL is bytes in disguise; park them and hand out a link the
    Pi can fetch. Anything else passes through untouched."""
    url = now.art_url or ""
    if not url.startswith("data:"):
        return now
    head, _, payload = url.partition(",")
    mime = head[5:].split(";")[0] or "image/jpeg"
    try:
        data = base64.b64decode(payload)
    except (ValueError, binascii.Error):
        return replace(now, art_url=None)
    key = hashlib.sha1(data).hexdigest()[:16]
    _art[key] = (data, mime)
    while len(_art) > ART_KEEP:
        del _art[next(iter(_art))]
    return replace(now, art_url=f"http://{host}/art/{key}.{_EXT.get(mime, 'img')}")


def _tier(now: NowPlaying, pushed: bool) -> str:
    if pushed:
        return "iPhone push"
    bundle = bundle_of(now.track_id)
    return f"Mac: {app_name(bundle)}" if bundle else "Mac tiers"


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        # The web app (any origin) reads this over fetch; without this header
        # the browser throws the response away.
        self.send_header("Access-Control-Allow-Origin", "*")

    def _send(self, code, body=b"", ctype="application/json", extra=()):
        self.send_response(code)
        self._cors()
        for k, v in extra:
            self.send_header(k, v)
        if body:
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_POST(self):
        if not self.path.startswith("/push"):
            self._send(404)
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._send(400)
            return
        _push["at"], _push["data"] = time.monotonic(), data
        if data.get("track"):
            print(f"[reporter] push: {data.get('artist')} — {data['track']}"
                  f" ({'playing' if data.get('playing') else 'paused'})")
        self._send(204)

    def _phone_age(self):
        """Seconds since the phone last pushed, or None if it never has.
        Carried as a header so it survives a 204 with no body: this is how
        the wall knows whether anyone is home."""
        if _push["data"] is None:
            return None
        return time.monotonic() - _push["at"]

    def do_GET(self):
        if self.path.startswith("/art/"):
            key = self.path[5:].split(".", 1)[0]
            hit = _art.get(key)
            if hit is None:
                self._send(404, b'{"error": "no such artwork"}')
            else:
                self._send(200, hit[0], hit[1],
                           extra=[("Cache-Control", "max-age=86400")])
            return
        if self.path.startswith("/services"):
            self._send(200, json.dumps({"mac_media": MAC is not None,
                                        "music_app": True}).encode())
            return
        if not self.path.startswith("/nowplaying"):
            self._send(404)
            return
        try:
            pushed = _pushed_now()
            now = pushed or SOURCE.get_current()
        except Exception as exc:
            print(f"[reporter] {exc}")
            self._send(500)
            return
        age = self._phone_age()
        age_hdr = [("X-Phone-Age", f"{age:.0f}")] if age is not None else []
        if now is None:
            self._send(204, extra=age_hdr)
            return
        host = self.headers.get("Host") or f"127.0.0.1:{self.server.server_address[1]}"
        now = _served_art(now, host)
        tier = _tier(now, pushed is not None)
        if now.track_id != _logged["key"] and not pushed:
            _logged["key"] = now.track_id
            print(f"[reporter] {tier}: {now.artist} — {now.title}")
        payload = asdict(now)
        payload["tier"] = tier
        self._send(200, json.dumps(payload).encode(), extra=age_hdr)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    # Under launchd stdout is a file, and Python would sit on every line
    # until the buffer filled: the log read as empty while pushes landed.
    sys.stdout.reconfigure(line_buffering=True)
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    print(f"[reporter] Music now-playing on 0.0.0.0:{port} — ctrl-C to stop")
    print("[reporter] media-control: reading every app this Mac plays"
          if MAC else
          "[reporter] media-control not installed: only Music.app is read here"
          " (brew install media-control)")
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
