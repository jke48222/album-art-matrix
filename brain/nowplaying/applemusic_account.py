"""Apple Music's account view, from the Pi, no Mac in the path.

Apple has no "currently playing" API; it has "recently played", which is the
same thing a track late. The phone push covers the live case, and this covers
the phone being asleep, off the network, or a HomePod playing on its own.

Reads the same MusicKit credentials the Mac's widgets use, copied once by
deploy.sh to ~/.config/album-art-matrix/musickit/:
  musickit.p8, musickit.json ({"teamId", "keyId"}), musickit-user-token.txt
The developer token is an ES256 JWT signed with openssl and cached.
"""
import base64
import json
import os
import subprocess
import time

import requests

from . import NowPlaying, NowPlayingSource

DIR = os.path.expanduser("~/.config/album-art-matrix/musickit")
P8 = os.path.join(DIR, "musickit.p8")
CONF = os.path.join(DIR, "musickit.json")
USERTOK = os.path.join(DIR, "musickit-user-token.txt")
DEVCACHE = os.path.join(DIR, "devtoken.json")
RECENT = "https://api.music.apple.com/v1/me/recent/played/tracks?limit=1"


def configured():
    return all(os.path.exists(p) for p in (P8, CONF, USERTOK))


def _b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _der_to_raw(der):
    # DER ECDSA signature -> raw r||s, 32 bytes each
    assert der[0] == 0x30
    i = 2
    assert der[i] == 0x02
    rl = der[i + 1]; r = der[i + 2:i + 2 + rl]; i += 2 + rl
    assert der[i] == 0x02
    sl = der[i + 1]; s = der[i + 2:i + 2 + sl]
    r = r[-32:].rjust(32, b"\0"); s = s[-32:].rjust(32, b"\0")
    return r + s


def dev_token():
    try:
        c = json.load(open(DEVCACHE))
        if c.get("token") and c.get("exp", 0) - time.time() > 7 * 86400:
            return c["token"]
    except Exception:
        pass
    conf = json.load(open(CONF))
    key_id = conf.get("keyId") or conf["key_id"]        # the Mac helper's spelling first
    team_id = conf.get("teamId") or conf["team_id"]
    now = int(time.time()); exp = now + 150 * 86400
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id}).encode())
    payload = _b64url(json.dumps({"iss": team_id, "iat": now, "exp": exp}).encode())
    signing_input = f"{header}.{payload}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", P8],
                         input=signing_input, capture_output=True, check=True).stdout
    token = signing_input.decode() + "." + _b64url(_der_to_raw(der))
    os.makedirs(DIR, exist_ok=True)
    json.dump({"token": token, "exp": exp}, open(DEVCACHE, "w"))
    return token


class AppleMusicAccountSource(NowPlayingSource):
    name = "applemusic-account"

    def __init__(self):
        self._last = None          # (track_id, NowPlaying, monotonic)
        self._backoff_until = 0.0

    def get_current(self):
        if time.time() < self._backoff_until:
            return None
        usr = open(USERTOK).read().strip()
        resp = requests.get(RECENT, headers={
            "Authorization": "Bearer " + dev_token(), "Music-User-Token": usr,
        }, timeout=10)
        if resp.status_code == 429:
            self._backoff_until = time.time() + 60
            return None
        if resp.status_code in (401, 403):
            self._backoff_until = time.time() + 300
            print("[applemusic-account] token refused; run musickit-setup on the Mac and redeploy")
            return None
        resp.raise_for_status()
        data = resp.json().get("data") or []
        if not data:
            return None
        a = data[0].get("attributes") or {}
        art = (a.get("artwork") or {}).get("url", "")
        art = art.replace("{w}", "600").replace("{h}", "600") or None
        tid = "applemusic:" + str(data[0].get("id") or f"{a.get('artistName')}|{a.get('name')}")
        # "Recently played" never says whether it is still playing. A track
        # that first appeared less than its own length ago is taken as on;
        # after that it is a memory, and the chain falls through to silence.
        dur = a.get("durationInMillis")
        now = time.monotonic()
        if self._last and self._last[0] == tid:
            first = self._last[2]
        else:
            first = now
        self._last = (tid, None, first)
        playing = dur is None or (now - first) * 1000 < dur + 15000
        if not playing:
            return None
        return NowPlaying(
            track_id=tid, title=a.get("name", "?"), artist=a.get("artistName", "?"),
            album=a.get("albumName", "?"), art_url=art,
            progress_ms=None, duration_ms=dur, is_playing=True,
        )
