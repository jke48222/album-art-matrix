"""Spotify adapter: OAuth Authorization Code + PKCE, /me/player/currently-playing.

Feb 2026 API reality (verified in research): currently-playing SURVIVES for a
personal Development Mode app with a Premium account. Audio Features/Analysis
are dead — all music analysis happens locally (stages S3/S4).

No client secret anywhere: PKCE only. Tokens live in
~/.config/album-art-matrix/spotify_tokens.json (chmod 600). Authorize once on
the Mac (needs a browser at http://127.0.0.1:<port>/callback); deploy.sh
copies the token file to the headless Pi, where refresh keeps it alive.
"""
import base64
import hashlib
import json
import os
import secrets
import threading
import time
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

import requests

from . import NowPlaying, NowPlayingSource

AUTH_URL = "https://accounts.spotify.com/authorize"
TOKEN_URL = "https://accounts.spotify.com/api/token"
API_CURRENT = "https://api.spotify.com/v1/me/player/currently-playing"
SCOPES = "user-read-currently-playing user-read-playback-state"
TOKEN_PATH = os.path.expanduser("~/.config/album-art-matrix/spotify_tokens.json")


class _CallbackHandler(BaseHTTPRequestHandler):
    result = {}

    def do_GET(self):
        query = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(query)
        _CallbackHandler.result = {k: v[0] for k, v in params.items()}
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(
            b"<html><body style='font-family:sans-serif'>"
            b"<h2>Authorized.</h2><p>You can close this tab &mdash; "
            b"the matrix has what it needs.</p></body></html>"
        )

    def log_message(self, *args):
        pass


class SpotifySource(NowPlayingSource):
    name = "spotify"

    def __init__(self, client_id: str, redirect_port: int = 8888):
        if not client_id or client_id.startswith("PASTE"):
            raise ValueError(
                "spotify.client_id missing — create an app at "
                "developer.spotify.com/dashboard with redirect URI "
                f"http://127.0.0.1:{redirect_port}/callback and paste the "
                "Client ID into config.toml"
            )
        self.client_id = client_id
        self.redirect_uri = f"http://127.0.0.1:{redirect_port}/callback"
        self.redirect_port = redirect_port
        self._tokens = self._load_tokens()
        self._backoff_until = 0.0

    # ---- token storage -------------------------------------------------
    def _load_tokens(self):
        try:
            with open(TOKEN_PATH) as fh:
                return json.load(fh)
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    def _save_tokens(self, tokens):
        tokens["expires_at"] = time.time() + tokens.get("expires_in", 3600)
        os.makedirs(os.path.dirname(TOKEN_PATH), exist_ok=True)
        with open(TOKEN_PATH, "w") as fh:
            json.dump(tokens, fh)
        os.chmod(TOKEN_PATH, 0o600)
        self._tokens = tokens

    # ---- auth ----------------------------------------------------------
    def ensure_auth(self, interactive: bool = True) -> bool:
        """True when we hold usable tokens; runs the PKCE dance if allowed."""
        if self._tokens:
            return True
        if not interactive:
            return False

        verifier = secrets.token_urlsafe(64)
        challenge = (
            base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
            .rstrip(b"=")
            .decode()
        )
        state = secrets.token_urlsafe(16)
        params = {
            "client_id": self.client_id,
            "response_type": "code",
            "redirect_uri": self.redirect_uri,
            "scope": SCOPES,
            "state": state,
            "code_challenge_method": "S256",
            "code_challenge": challenge,
        }
        url = AUTH_URL + "?" + urllib.parse.urlencode(params)

        server = HTTPServer(("127.0.0.1", self.redirect_port), _CallbackHandler)
        thread = threading.Thread(target=server.handle_request, daemon=True)
        thread.start()

        print("[spotify] opening browser for authorization…")
        print(f"[spotify] if nothing opens, visit:\n{url}")
        webbrowser.open(url)
        thread.join(timeout=300)
        server.server_close()

        result = _CallbackHandler.result
        if not result:
            print("[spotify] authorization timed out (5 min)")
            return False
        if result.get("state") != state:
            print("[spotify] state mismatch — refusing token exchange")
            return False
        if "error" in result:
            print(f"[spotify] authorization denied: {result['error']}")
            return False

        resp = requests.post(
            TOKEN_URL,
            data={
                "client_id": self.client_id,
                "grant_type": "authorization_code",
                "code": result["code"],
                "redirect_uri": self.redirect_uri,
                "code_verifier": verifier,
            },
            timeout=15,
        )
        resp.raise_for_status()
        self._save_tokens(resp.json())
        print("[spotify] authorized — tokens saved")
        return True

    def _refresh(self) -> bool:
        if not self._tokens or "refresh_token" not in self._tokens:
            return False
        resp = requests.post(
            TOKEN_URL,
            data={
                "client_id": self.client_id,
                "grant_type": "refresh_token",
                "refresh_token": self._tokens["refresh_token"],
            },
            timeout=15,
        )
        if resp.status_code != 200:
            print(f"[spotify] refresh failed: {resp.status_code} {resp.text[:200]}")
            return False
        fresh = resp.json()
        # Spotify may omit a new refresh_token; keep the old one then.
        fresh.setdefault("refresh_token", self._tokens["refresh_token"])
        self._save_tokens(fresh)
        return True

    def _access_token(self):
        if not self._tokens:
            return None
        if time.time() > self._tokens.get("expires_at", 0) - 60:
            if not self._refresh():
                return None
        return self._tokens.get("access_token")

    # ---- polling -------------------------------------------------------
    def get_current(self):
        if time.time() < self._backoff_until:
            return None
        token = self._access_token()
        if token is None:
            return None

        resp = requests.get(
            API_CURRENT,
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
        )
        if resp.status_code == 204:
            return None  # nothing playing
        if resp.status_code == 401:
            if self._refresh():
                return self.get_current()
            return None
        if resp.status_code == 429:
            wait = float(resp.headers.get("Retry-After", 30))
            self._backoff_until = time.time() + wait
            print(f"[spotify] rate limited — backing off {wait:.0f}s")
            return None
        resp.raise_for_status()

        data = resp.json()
        item = data.get("item")
        if not item or data.get("currently_playing_type") != "track":
            return None  # podcast/ad/unknown — let another adapter answer

        images = (item.get("album") or {}).get("images") or []
        art_url = images[0]["url"] if images else None  # images[0] is largest
        artists = ", ".join(a["name"] for a in item.get("artists", []))

        return NowPlaying(
            track_id=f"spotify:{item['id']}",
            title=item.get("name", "?"),
            artist=artists or "?",
            album=(item.get("album") or {}).get("name", "?"),
            art_url=art_url,
            progress_ms=data.get("progress_ms"),
            duration_ms=item.get("duration_ms"),
            is_playing=bool(data.get("is_playing")),
        )
