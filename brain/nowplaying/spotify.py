"""Spotify playback via PKCE, with bounded refresh and wall-owned credentials.

Token receipts are validated and saved atomically with mode 0600. Network
requests never hold the account lock; late responses cannot restore an account
that was disconnected or replace a newer sign-in.
"""
import base64
import hashlib
import json
import math
import tempfile
import os
import secrets
import threading
import time
import urllib.parse
import webbrowser
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer

import requests

from . import NowPlaying, NowPlayingSource

AUTH_URL = "https://accounts.spotify.com/authorize"
TOKEN_URL = "https://accounts.spotify.com/api/token"
API_CURRENT = "https://api.spotify.com/v1/me/player/currently-playing"
SCOPES = "user-read-currently-playing user-read-playback-state"
TOKEN_PATH = os.path.expanduser("~/.config/album-art-matrix/spotify_tokens.json")


class _CallbackHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        result = {k: v[0] for k, v in params.items() if len(v) == 1}
        valid = (parsed.path == "/callback" and result.get("state") == self.server.oauth_state
                 and bool(result.get("code") or result.get("error")))
        if valid:
            self.server.oauth_result = result
        self.send_response(200 if valid else 400)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"<html><body><p>You can return to Tessera.</p></body></html>" if valid
                         else b"<html><body><p>This sign-in request is no longer valid.</p></body></html>")

    def log_message(self, *args):
        pass


class SpotifySource(NowPlayingSource):
    name = "spotify"

    def __init__(self, client_id: str = "", redirect_port: int = 8888):
        self.client_id = client_id.strip() if isinstance(client_id, str) and not client_id.startswith("PASTE") else ""
        self.redirect_uri = f"http://127.0.0.1:{redirect_port}/callback"
        self.redirect_port = redirect_port
        self._lock = threading.RLock()
        self._refresh_lock = threading.Lock()
        self._poll_lock = threading.Lock()
        self._checking = False
        self._generation = 0
        self._tokens = self._load_tokens()
        self._token_mtime = self._mtime()
        self._backoff_until = 0.0
        self._state = "ready" if self._tokens else "unlinked"
        self._problem = None
        self._checked_at = None

    def _mtime(self):
        try:
            stat = os.stat(TOKEN_PATH)
            return stat.st_mtime_ns, stat.st_size, stat.st_ino
        except OSError:
            return None

    @staticmethod
    def validate_tokens(tokens):
        if not isinstance(tokens, dict):
            raise ValueError("Spotify tokens must be an object")
        clean = {}
        for key in ("access_token", "refresh_token"):
            value = tokens.get(key)
            if not isinstance(value, str) or not value.strip() or len(value) > 8192:
                raise ValueError("valid access_token and refresh_token are required")
            clean[key] = value.strip()
        lifetime = tokens.get("expires_in", 3600)
        if type(lifetime) not in (int, float) or not math.isfinite(lifetime) or not 1 <= lifetime <= 86400:
            raise ValueError("expires_in must be between 1 and 86400 seconds")
        clean["expires_in"] = lifetime
        for key in ("scope", "token_type", "account_name"):
            value = tokens.get(key)
            if isinstance(value, str):
                clean[key] = value[:512 if key == "scope" else 120]
        return clean

    def accept_tokens(self, tokens: dict, client_id=None):
        """Commit a validated receipt only to its explicitly configured app."""
        clean = self.validate_tokens(tokens)
        with self._lock:
            if client_id is not None and client_id != self.client_id:
                raise ValueError("The Spotify app ID changed. Sign in again.")
            self._save_tokens(clean)
            self._generation += 1
            self._backoff_until = 0.0
            self._state, self._problem, self._checked_at = "ready", None, None

    @contextmanager
    def client_id_transaction(self, client_id):
        """Detach credentials reversibly while the service store commits.

        Renaming within the same directory keeps rollback possible even when a
        full disk prevents writing the new services file. Stale network replies
        remain blocked until both credential files agree.
        """
        client_id = (client_id or "").strip()
        with self._lock:
            if client_id == self.client_id:
                yield
                return
            backup = None
            if os.path.exists(TOKEN_PATH):
                fd, backup = tempfile.mkstemp(prefix=".spotify-detached-", dir=os.path.dirname(TOKEN_PATH))
                os.close(fd)
                try:
                    os.replace(TOKEN_PATH, backup)
                except BaseException:
                    os.unlink(backup)
                    raise
            try:
                yield
            except BaseException:
                if backup:
                    os.replace(backup, TOKEN_PATH)
                self._token_mtime = self._mtime()
                raise
            else:
                self.client_id, self._tokens = client_id, None
                self._generation += 1
                self._token_mtime, self._backoff_until = self._mtime(), 0
                self._state, self._problem, self._checked_at = "unlinked", None, None
                if backup:
                    try:
                        os.unlink(backup)
                    except OSError:
                        # A private, detached file is never read as active tokens.
                        # The new account is committed; do not report a false failure.
                        print("[spotify] could not remove a detached credential file")

    def set_client_id(self, client_id: str):
        with self.client_id_transaction(client_id):
            pass

    def unlink(self):
        with self._lock:
            try:
                os.remove(TOKEN_PATH)
            except FileNotFoundError:
                pass
            # Do not acknowledge a disconnect if persisted tokens remain.
            self._tokens = None
            self._generation += 1
            self._token_mtime = self._mtime()
            self._backoff_until = 0
            self._state, self._problem, self._checked_at = "unlinked", None, None

    @property
    def configured(self) -> bool:
        return bool(self.client_id)

    @property
    def linked(self) -> bool:
        with self._lock:
            return bool(self._tokens and self._tokens.get("refresh_token"))

    def status(self):
        with self._lock:
            state = self._state if self.linked else "unlinked" if self.client_id else "unconfigured"
            wait = max(0, self._backoff_until - time.time())
            if state in ("playing", "paused", "idle") and self._checked_at and time.time() - self._checked_at > 120:
                state = "ready"  # a higher-priority source may have stopped Spotify polling
            return {"client_id": self.client_id, "linked": self.linked, "state": state,
                    "problem": self._problem, "checked_at": self._checked_at,
                    "retry_after": round(wait, 1) if wait else None,
                    "account_name": (self._tokens or {}).get("account_name") or None,
                    "can_retry": self.linked and state != "expired" and not self._checking and not (state == "rate_limited" and wait > 0)}

    def retry(self):
        with self._lock:
            if not self.status()["can_retry"]:
                return False
            self._backoff_until = 0
            self._state, self._problem, self._checking = "checking", None, True
            generation = self._generation
        def check():
            try:
                self.get_current()
            finally:
                with self._lock:
                    self._checking = False
                    if generation == self._generation and self._state == "checking":
                        self._state = "ready"
        threading.Thread(target=check, name="spotify-check", daemon=True).start()
        return True

    def _load_tokens(self):
        try:
            with open(TOKEN_PATH) as fh:
                tokens = json.load(fh)
            clean = self.validate_tokens(tokens)
            expiry = tokens.get("expires_at", 0)
            clean["expires_at"] = expiry if type(expiry) in (int, float) and math.isfinite(expiry) else 0
            return clean
        except (OSError, ValueError, TypeError):
            return None

    def _save_tokens(self, tokens):
        clean = self.validate_tokens(tokens)
        clean["expires_at"] = time.time() + clean["expires_in"]
        directory = os.path.dirname(TOKEN_PATH)
        os.makedirs(directory, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".spotify-", dir=directory)
        try:
            with os.fdopen(fd, "w") as fh:
                os.fchmod(fh.fileno(), 0o600)
                json.dump(clean, fh)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(temporary, TOKEN_PATH)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        self._tokens = clean
        self._token_mtime = self._mtime()

    def ensure_auth(self, interactive: bool = True) -> bool:
        if self.linked and self._state != "expired":
            return True
        if not interactive or not self.client_id:
            return False
        client_id = self.client_id
        verifier, state = secrets.token_urlsafe(64), secrets.token_urlsafe(16)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        params = {"client_id": client_id, "response_type": "code", "redirect_uri": self.redirect_uri,
                  "scope": SCOPES, "state": state, "code_challenge_method": "S256", "code_challenge": challenge}
        with HTTPServer(("127.0.0.1", self.redirect_port), _CallbackHandler) as server:
            server.oauth_state, server.oauth_result, server.timeout = state, None, 1
            url = AUTH_URL + "?" + urllib.parse.urlencode(params)
            print("[spotify] opening browser for authorization…")
            webbrowser.open(url)
            deadline = time.monotonic() + 300
            while not server.oauth_result and time.monotonic() < deadline:
                server.handle_request()
            result = server.oauth_result
        if not result or result.get("error") or not result.get("code"):
            return False
        try:
            response = requests.post(TOKEN_URL, data={"client_id": client_id, "grant_type": "authorization_code",
                "code": result["code"], "redirect_uri": self.redirect_uri, "code_verifier": verifier}, timeout=15)
            response.raise_for_status()
            self.accept_tokens(response.json(), client_id=client_id)
            return True
        except (requests.RequestException, ValueError, OSError):
            return False

    def _issue(self, generation, state, message, delay=30):
        with self._lock:
            if generation != self._generation:
                return
            self._state, self._problem = state, message
            self._checked_at = time.time()
            self._backoff_until = time.time() + delay

    def _refresh(self) -> bool:
        # Polling and phone actions may overlap; no network request holds _lock.
        if not self._refresh_lock.acquire(blocking=False):
            return False
        try:
            with self._lock:
                if not self.linked:
                    return False
                generation, client_id, old = self._generation, self.client_id, dict(self._tokens)
            try:
                response = requests.post(TOKEN_URL, data={"client_id": client_id, "grant_type": "refresh_token",
                    "refresh_token": old["refresh_token"]}, timeout=15)
                if response.status_code != 200:
                    try:
                        code = response.json().get("error")
                    except (ValueError, AttributeError):
                        code = None
                    if code in ("invalid_grant", "invalid_client") or response.status_code == 401:
                        self._issue(generation, "expired", "Spotify needs a fresh sign-in. Connect again to resume.", 3600)
                    elif response.status_code == 429:
                        self._rate_limit(response, generation)
                    else:
                        self._issue(generation, "unavailable", "Spotify could not refresh the connection. Try again shortly.")
                    return False
                fresh = response.json()
                if not isinstance(fresh, dict):
                    raise ValueError("invalid token response")
                fresh.setdefault("refresh_token", old["refresh_token"])
                fresh.setdefault("account_name", old.get("account_name", ""))
                with self._lock:
                    if generation != self._generation or client_id != self.client_id:
                        return False
                    self._save_tokens(fresh)
                    self._state, self._problem = "ready", None
                return True
            except (requests.RequestException, ValueError, OSError):
                self._issue(generation, "unavailable", "Spotify could not refresh the connection. Try again shortly.")
                return False
        finally:
            self._refresh_lock.release()

    def _access_token(self):
        with self._lock:
            if not self._tokens or self._state == "expired":
                return None
            expired = time.time() >= self._tokens.get("expires_at", 0) - 60
        if expired and not self._refresh():
            return None
        with self._lock:
            return (self._tokens or {}).get("access_token")

    def _rate_limit(self, response, generation):
        try:
            wait = float(response.headers.get("Retry-After", 30))
            if not math.isfinite(wait):
                raise ValueError()
            wait = min(86400, max(1, wait))
        except (TypeError, ValueError):
            wait = 30
        self._issue(generation, "rate_limited", "Spotify is limiting requests. The wall will retry automatically.", wait)

    def get_current(self):
        if not self._poll_lock.acquire(blocking=False):
            return None
        try:
            return self._get_current()
        finally:
            self._poll_lock.release()

    def _get_current(self):
        with self._lock:
            if self._mtime() != self._token_mtime:
                self._tokens = self._load_tokens()
                self._token_mtime = self._mtime()
                self._generation += 1
                self._backoff_until = 0
                self._state, self._problem = "ready" if self._tokens else "unlinked", None
            if not self.client_id or time.time() < self._backoff_until:
                return None
        # One refresh and one retry at most; persistent 401s cannot recurse.
        for attempt in range(2):
            with self._lock:
                generation = self._generation
            token = self._access_token()
            if token is None:
                return None
            with self._lock:
                if generation != self._generation:
                    return None
            try:
                response = requests.get(API_CURRENT, headers={"Authorization": f"Bearer {token}"}, timeout=10)
            except requests.RequestException:
                self._issue(generation, "unavailable", "Spotify could not be reached. Your account is still saved.")
                return None
            with self._lock:
                if generation != self._generation:
                    return None
            if response.status_code == 401:
                if attempt == 0:
                    if self._refresh():
                        continue
                    return None
                self._issue(generation, "expired", "Spotify needs a fresh sign-in. Connect again to resume.", 3600)
                return None
            if response.status_code == 429:
                self._rate_limit(response, generation)
                return None
            if response.status_code == 403:
                self._issue(generation, "refused", "Spotify refused access. Check the app owner's Premium plan and this account's access in the Spotify developer dashboard.", 600)
                return None
            if response.status_code not in (200, 204):
                self._issue(generation, "unavailable", "Spotify could not read playback. Try again shortly.")
                return None
            try:
                data = response.json() if response.status_code == 200 else {}
                if not isinstance(data, dict):
                    raise ValueError()
                item = data.get("item")
                track = self._track(data, item) if isinstance(item, dict) and data.get("currently_playing_type") == "track" else None
            except (ValueError, TypeError, KeyError):
                self._issue(generation, "unavailable", "Spotify sent an unreadable playback update. The wall will retry.")
                return None
            with self._lock:
                if generation != self._generation:
                    return None
                self._state = "playing" if track and track.is_playing else "paused" if track else "idle"
                self._problem, self._checked_at, self._backoff_until = None, time.time(), 0
            return track
        return None

    @staticmethod
    def _track(data, item):
        if not isinstance(item.get("id"), str) or not item["id"]:
            return None
        album = item.get("album") if isinstance(item.get("album"), dict) else {}
        images = album.get("images") or []
        art_url = next((i["url"] for i in images if isinstance(i, dict) and isinstance(i.get("url"), str)), None)
        artists = ", ".join(a["name"] for a in item.get("artists", []) if isinstance(a, dict) and isinstance(a.get("name"), str))
        def milliseconds(value):
            return max(0, int(value)) if type(value) in (int, float) and math.isfinite(value) else None
        return NowPlaying(track_id=f"spotify:{item['id']}", title=item.get("name") or "Unknown song",
            artist=artists or "Unknown artist", album=album.get("name") or "", art_url=art_url,
            progress_ms=milliseconds(data.get("progress_ms")), duration_ms=milliseconds(item.get("duration_ms")),
            is_playing=data.get("is_playing") is True)
