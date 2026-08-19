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

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dataclasses import asdict
from http.server import BaseHTTPRequestHandler, HTTPServer

from brain.nowplaying.applemusic import AppleMusicSource

SOURCE = AppleMusicSource(endpoint="")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if not self.path.startswith("/nowplaying"):
            self.send_response(404)
            self.end_headers()
            return
        try:
            now = SOURCE.get_current()
        except Exception as exc:
            print(f"[reporter] {exc}")
            self.send_response(500)
            self.end_headers()
            return
        if now is None:
            self.send_response(204)
            self.end_headers()
            return
        body = json.dumps(asdict(now)).encode()
        self.send_response(200)
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
