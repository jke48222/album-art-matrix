"""Apple Music adapter — mirrors the proven now-playing.jsx widget stack.

Apple has no server-side currently-playing API, so this layers three sources
(first with an answer wins), exactly like the Übersicht widget:

  0. now-spinning state.json (Group Container) — companion-app push state,
     used when present and playing.
  1. osascript against Music.app — real-time local playback (incl. AirPlay
     FROM the Mac), playing or paused. Never launches Music.
  2. musickit-fetch.py --nowplaying — the account's most-recently-played
     track across ALL devices (this is what catches the iPhone), using the
     MusicKit credentials already set up in ~/.config/widgetsuite/.

Artwork is URL-based (MusicKit catalog --cover, then the iTunes Search
ladder) — never AppleScript raw bytes — so art/fetch.py caches it cleanly.

Modes:
  endpoint = ""                          local: brain runs on this Mac
  endpoint = "http://<mac>.local:8787"   remote: brain on the Pi polls
                                         scripts/mac_reporter.py on the Mac
"""
import json
import os
import subprocess
import sys
import time

from . import NowPlaying, NowPlayingSource

WIDGETSUITE = os.path.expanduser("~/.config/widgetsuite")
MUSICKIT_HELPER = os.path.join(WIDGETSUITE, "musickit-fetch.py")
STATE_JSON = os.path.expanduser(
    "~/Library/Group Containers/group.com.jalenedusei.widgetsuite/"
    "now-spinning/state.json")
# A crashed companion leaves state.json claiming "playing" forever, which
# would pin the wall on a dead track and shadow the live tiers below it
# (the reporter's push tier expires for exactly this reason). The file is
# rewritten on track changes, so 20 minutes of silence outlasts almost any
# song while still letting a corpse expire.
STATE_JSON_TTL_S = 20 * 60

# NB: "st" is a reserved word in macOS 27 AppleScript — hence pstate.
OSA_META = '''
if application "Music" is not running then return "state=not_running"
tell application "Music"
  set pstate to (player state as text)
  if pstate is not in {"playing", "paused"} then return "state=" & pstate
  set t to current track
  set pos to "?"
  set dur to "?"
  try
    set pos to (player position as text)
  end try
  try
    set dur to (duration of t as text)
  end try
  return "state=" & pstate & linefeed & (persistent ID of t) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & pos & linefeed & dur
end tell
'''


def _helper_python():
    return "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else sys.executable


def _run_helper(*args, timeout=20):
    if not os.path.exists(MUSICKIT_HELPER):
        return ""
    try:
        proc = subprocess.run([_helper_python(), MUSICKIT_HELPER, *args],
                              capture_output=True, text=True, timeout=timeout)
        return proc.stdout.strip()
    except Exception:
        return ""


def _ms(val):
    try:
        return int(float(val) * 1000)
    except (TypeError, ValueError):
        return None


def _osa_now():
    """Local Music.app state -> dict, or None when idle/stopped/not running."""
    try:
        proc = subprocess.run(["osascript", "-"], input=OSA_META,
                              capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        return None
    if proc.returncode != 0:
        err = proc.stderr.strip()
        if "-1743" in err:
            raise RuntimeError(
                "Automation permission denied — System Settings > Privacy & "
                "Security > Automation: allow this app to control Music")
        raise RuntimeError(f"osascript: {err[:160]}")
    out = proc.stdout.rstrip("\n")
    if "\n" not in out:
        return None
    fields = (out.split("\n") + ["?"] * 7)[:7]
    state, pid, title, artist, album, pos, dur = fields
    return {
        "state": state.split("=", 1)[1],
        "pid": pid, "title": title, "artist": artist, "album": album,
        "progress_ms": _ms(pos), "duration_ms": _ms(dur),
    }


def _itunes_art(term, entity):
    try:
        import requests  # lazy: keeps module import stdlib-only for the reporter
        resp = requests.get("https://itunes.apple.com/search",
                            params={"term": term, "entity": entity, "limit": 1},
                            timeout=10)
        resp.raise_for_status()
        results = resp.json().get("results") or []
        url = results[0].get("artworkUrl100") if results else None
        return url.replace("100x100bb", "600x600bb") if url else None
    except Exception:
        return None


class AppleMusicSource(NowPlayingSource):
    name = "applemusic"

    phone_age = None                 # seconds since the phone's last push

    def __init__(self, endpoint: str = ""):
        self.endpoint = (endpoint or "").rstrip("/")
        self._art_key = None
        self._art_url_cached = None
        self._warned = False

    # ---- artwork (the widget's fallback ladder, simplified) ------------
    def _art_url(self, title, artist, album):
        key = (artist, album, title)
        if key == self._art_key:
            return self._art_url_cached
        url = _run_helper("--cover", title, artist, album) or None
        if not url:
            clean_album = album.removesuffix(" - Single").removesuffix(" - EP")
            url = (_itunes_art(f"{artist} {clean_album}", "album")
                   or _itunes_art(f"{artist} {title}", "song")
                   or _itunes_art(title, "song"))
        if url:  # cache hits only, so misses retry next poll
            self._art_key, self._art_url_cached = key, url
        return url

    # ---- tiers ---------------------------------------------------------
    def _tier0_state_json(self):
        try:
            if time.time() - os.path.getmtime(STATE_JSON) > STATE_JSON_TTL_S:
                return None
            with open(STATE_JSON) as fh:
                s = json.load(fh)
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return None
        if not s.get("playing") or not s.get("track"):
            return None
        return NowPlaying(
            track_id="applemusic:" + (s.get("id")
                                      or f"{s.get('artist')}|{s.get('track')}"),
            title=s["track"], artist=s.get("artist", "?"),
            album=s.get("album", "?"), art_url=s.get("art"),
            progress_ms=None, duration_ms=None, is_playing=True,
        )

    def _tier1_mac(self):
        info = _osa_now()
        if info is None:
            return None, ("", "")
        art = self._art_url(info["title"], info["artist"], info["album"])
        now = NowPlaying(
            track_id=f"applemusic:{info['pid']}",
            title=info["title"], artist=info["artist"], album=info["album"],
            art_url=art, progress_ms=info["progress_ms"],
            duration_ms=info["duration_ms"],
            is_playing=info["state"] == "playing",
        )
        return now, (info["title"], info["artist"])

    def _tier2_account(self, mac_track="", mac_artist=""):
        out = _run_helper("--nowplaying", mac_track, mac_artist)
        if not out:
            return None
        try:
            s = json.loads(out)
        except json.JSONDecodeError:
            return None
        return NowPlaying(
            track_id=f"applemusic:{s.get('artist')}|{s.get('track')}",
            title=s.get("track", "?"), artist=s.get("artist", "?"),
            album=s.get("album", "?"), art_url=s.get("art"),
            progress_ms=None, duration_ms=None, is_playing=True,
        )

    def _local(self):
        now = self._tier0_state_json()
        if now:
            return now
        now, (mac_track, mac_artist) = self._tier1_mac()
        if now and now.is_playing:
            return now
        # Mac idle or paused: the account view catches iPhone playback; the
        # helper stays silent when the account track is just the Mac's paused
        # one, so the paused sleeve keeps the wall.
        return self._tier2_account(mac_track, mac_artist) or now

    def _remote(self):
        import requests  # lazy; the Pi venv has it
        try:
            resp = requests.get(self.endpoint + "/nowplaying", timeout=8)
        except requests.RequestException as exc:
            self.phone_age = None
            if not self._warned:
                print(f"[applemusic] reporter unreachable at {self.endpoint} "
                      f"({exc.__class__.__name__}) — start "
                      "scripts/mac_reporter.py on the Mac")
                self._warned = True
            return None
        self._warned = False
        # How long since the owner's phone last spoke to the reporter.
        # Presence, not music: the away behaviour reads this.
        age = resp.headers.get("X-Phone-Age")
        self.phone_age = float(age) if age is not None else None
        if resp.status_code != 200:
            return None
        try:
            data = resp.json()
        except ValueError:
            return None
        # The reporter decorates its payload (e.g. "tier"); take only the
        # dataclass's own fields so decoration never breaks this side.
        return NowPlaying(**{k: v for k, v in data.items()
                             if k in NowPlaying.__dataclass_fields__})

    def get_current(self):
        return self._remote() if self.endpoint else self._local()
