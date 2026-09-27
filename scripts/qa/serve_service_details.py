#!/usr/bin/env python3
"""Loopback native test server. Synthetic accounts, production field validation."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from brain import services as service_store
from capture_home import artwork, fixture
from service_details_fixtures import configure


class Session:
    def __init__(self):
        self.lock = threading.RLock()
        self.reset("connected")

    def reset(self, phase):
        self.payload = configure(SimpleNamespace(studies={}), phase)
        self.requests = []
        self.offline = False
        self.reject = False
        self.sync_end = None
        self.store = service_store.Services({})

    def status(self):
        if self.sync_end and time.monotonic() >= self.sync_end:
            self.payload["discogs"].update(syncing=False, completed_sync_id="qa-read", synced_at=time.time(), pages_read=4, pages_total=4, releases_read=163)
            self.sync_end = None
        return self.payload

    def update(self, body):
        changed, rejected = self.store.update(body)
        # The fixture models the public response only; raw values are never logged.
        for name, values in body.items():
            if name not in self.payload or not isinstance(values, dict):
                continue
            account = self.payload[name]
            for key, value in values.items():
                if f"{name}.{key}" in rejected:
                    continue
                if key == "user":
                    account["user"] = value
                    if name == "lastfm":
                        account.update(state="idle" if value else "unlinked", current=None)
                    if name == "listenbrainz":
                        account.update(read_state="ready" if value else "unlinked", read_playing=None)
                elif key in ("api_key", "token", "workspace"):
                    flag = {"api_key": "key_set", "token": "token_set", "workspace": "workspace_set"}[key]
                    account[flag] = bool(value)
                    if name == "claude" and key == "api_key":
                        account.update(ready=bool(value), problem=None)
                    if name == "listenbrainz" and key == "token":
                        account.update(valid=True if value else None, state="ready" if value else "unlinked", counting=False, playing=None)
        result = dict(self.status())
        result["rejected"] = list(rejected)
        return result


def handler(session):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, value, mime="application/json"):
            body = json.dumps(value).encode() if mime == "application/json" else value
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            path = urlsplit(self.path).path
            with session.lock:
                if path == "/qa/status":
                    self.reply(200, {"services": session.status(), "requests": session.requests})
                elif session.offline:
                    self.reply(503, {"error": "Wall offline"})
                elif path == "/services":
                    self.reply(200, session.status())
                elif path == "/state":
                    self.reply(200, fixture("live"))
                elif path == "/frame.raw":
                    self.reply(200, artwork(), "application/octet-stream")
                elif path == "/shelf":
                    self.reply(200, {**session.status()["discogs"], "releases": [], "total": 163})
                else:
                    self.reply(200, {})

        def do_POST(self):
            path = urlsplit(self.path).path
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or "{}")
            with session.lock:
                if path == "/qa/reset":
                    session.reset(body.get("phase", "connected"))
                    self.reply(200, {"ready": True})
                    return
                if path == "/qa/offline":
                    session.offline = True
                    self.reply(200, {"ready": True})
                    return
                if path == "/qa/reject":
                    session.reject = True
                    self.reply(200, {"ready": True})
                    return
                if session.offline:
                    self.reply(503, {"error": "Wall offline"})
                    return
                session.requests.append({"path": path, "fields": {name: list(values) for name, values in body.items() if isinstance(values, dict)}})
                if path == "/services":
                    self.reply(503, {"error": "Could not save"}) if session.reject else self.reply(200, session.update(body))
                elif path == "/lastfm/retry":
                    session.payload["lastfm"].update(state="idle", problem=None, current=None)
                    self.reply(200, session.status())
                elif path == "/listenbrainz/retry":
                    session.payload["listenbrainz"].update(read_state="ready", read_problem=None)
                    self.reply(200, session.status())
                elif path == "/shelf/sync":
                    session.payload["discogs"].update(syncing=True, sync_id="qa-read", completed_sync_id=None)
                    session.sync_end = time.monotonic() + 0.5
                    self.reply(200, {"accepted": True, "sync_id": "qa-read"})
                else:
                    self.reply(404, {"error": "Unknown fixture route"})
    return Handler


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="tessera-service-fixture-") as temporary:
        service_store.PATH = str(Path(temporary) / "services.json")
        ThreadingHTTPServer(("127.0.0.1", 65363), handler(Session())).serve_forever()
