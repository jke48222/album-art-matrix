"""Posters for what you watch.

When the Mac plays an episode or a film in a browser (Netflix, Paramount+,
Apple TV+, YouTube longer than a song), macOS's Now Playing names it but
hands over the browser's icon as artwork, so the reporter has always
dropped it and the wall stayed on whatever it had. Now the reporter passes
the show's name along (the X-Mac-Show header on an empty answer, so a
brain that does not know about shows sees nothing new), and this module
looks the name up on The Movie Database: television first, then films.
The poster becomes the sleeve, the answer counts as playing with art, and
the journal marks it kind "show". Lookups are kept for thirty days in
~/.config/album-art-matrix/posters.json, misses for a day; nothing found
means the answer stays sleeveless, as it always was.

The key is a TMDB API key (v3, 32 hex characters) or a read access token
(v4, a long JWT), from themoviedb.org/settings/api, set from the phone.
"""
from __future__ import annotations

import base64
import json
import os
import re
import threading
import time

import requests

from .nowplaying import NowPlaying, NowPlayingSource

API = "https://api.themoviedb.org/3"
IMAGE = "https://image.tmdb.org/t/p/w500"
PATH = os.path.expanduser("~/.config/album-art-matrix/posters.json")
HIT_TTL_S = 30 * 86400.0
MISS_TTL_S = 86400.0
SHOW_FRESH_S = 90.0          # a show the reporter saw longer ago than this is over

SITES = {"netflix", "paramount+", "paramount plus", "apple tv+", "apple tv", "hulu", "max", "hbo max",
         "disney+", "disney plus", "prime video", "amazon prime video", "amazon", "youtube", "peacock",
         "crunchyroll", "plex", "tubi", "pluto tv", "bbc iplayer", "iplayer", "itvx", "channel 4",
         "all 4", "mubi", "criterion channel", "vimeo", "twitch", "watch"}
_EPISODE = re.compile(r"\b(?:s(?:eason)?\s*\d+\s*[:,.]?\s*e(?:p(?:isode)?)?\s*\d+|season\s+\d+|"
                      r"episode\s+\d+|ep\.?\s*\d+|s\d+e\d+|e\d+)\b.*$", re.I)
_TRAILERS = re.compile(r"\s*[\(\[][^\)\]]*[\)\]]\s*$")
_SPLIT = re.compile(r"\s+[|•·–—-]\s+")


def _is_site(p: str) -> bool:
    q = p.lower().strip()
    return q in SITES or q.rstrip("+ ") in SITES


def clean_title(title: str) -> list[str]:
    """What to search for, best guess first: the tab title with "Watch",
    the site's name, season and episode numbers and bracketed tails taken
    off; then, as fallbacks, the pieces either side of a colon."""
    t = (title or "").strip()
    if not t:
        return []
    t = re.sub(r"^\s*(watch|now playing|playing)\s*[:\-–]?\s+", "", t, flags=re.I)
    pieces = [p.strip() for p in _SPLIT.split(t) if p.strip()]
    pieces = [p for p in pieces if not _is_site(p)]
    out: list[str] = []
    for p in pieces:
        q = _EPISODE.sub("", p).strip(" -:|,")
        q = _TRAILERS.sub("", q).strip(" -:|,")
        if len(q) >= 2 and not _is_site(q) and q not in out:
            out.append(q)
    if not out and pieces:
        out = [pieces[0]]
    # a dash is usually the site's separator, but it is also how a film
    # writes its subtitle, so the pieces together come first
    head = [" ".join(out)] if len(out) > 1 else []
    out.sort(key=len, reverse=True)
    extra: list[str] = []
    for q in out[:2]:
        for piece in re.split(r":\s+", q):
            piece = piece.strip(" -:|,")
            if len(piece) >= 2 and piece not in out and piece not in extra and not _is_site(piece):
                extra.append(piece)
    return (head + out[:2] + extra)[:4]


class Posters:
    def __init__(self, api_key: str = "", path: str = PATH, fetch=None, clock=None):
        self.api_key = (api_key or "").strip()
        self.path = path
        self._fetch = fetch or self._http_get
        self._clock = clock or time.time
        self._lock = threading.Lock()
        self._cache: dict[str, dict] = {}
        self.count = 0
        self.last: dict | None = None
        self.problem: str | None = None
        self._load()

    # ---- settings ------------------------------------------------------------------------
    @property
    def ready(self) -> bool:
        return bool(self.api_key)

    def configure(self, api_key=None):
        if api_key is not None and api_key.strip() != self.api_key:
            self.api_key = api_key.strip()
            self.problem = None
            # a new key deserves a fresh look at the misses
            with self._lock:
                self._cache = {k: v for k, v in self._cache.items() if v.get("hit")}
                self._save()

    def status(self) -> dict:
        return {"key_set": self.ready, "posters": self.count, "last": self.last,
                "known": sum(1 for v in self._cache.values() if v.get("hit")),
                "problem": self.problem}

    # ---- disk ----------------------------------------------------------------------------
    def _load(self):
        try:
            with open(self.path) as fh:
                d = json.load(fh)
            self._cache = d.get("cache", {})
            self.count = int(d.get("count", 0))
            self.last = d.get("last")
        except (OSError, ValueError, TypeError):
            self._cache = {}

    def _save(self):
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            tmp = self.path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump({"cache": self._cache, "count": self.count, "last": self.last}, fh)
            os.replace(tmp, self.path)
        except OSError as exc:
            print(f"[posters] could not save: {exc}", flush=True)

    # ---- TMDB ----------------------------------------------------------------------------
    def _http_get(self, path: str, params: dict):
        headers = {"Accept": "application/json"}
        params = dict(params)
        if self.api_key.startswith("eyJ"):
            headers["Authorization"] = f"Bearer {self.api_key}"
        else:
            params["api_key"] = self.api_key
        r = requests.get(API + path, params=params, headers=headers, timeout=12)
        if r.status_code == 401:
            raise PermissionError("TMDB rejected the key")
        r.raise_for_status()
        return r.json()

    def _search(self, kind: str, query: str) -> dict | None:
        data = self._fetch(f"/search/{kind}", {"query": query, "include_adult": "false", "language": "en-US"})
        for item in data.get("results") or []:
            if not item.get("poster_path"):
                continue
            name = item.get("name") if kind == "tv" else item.get("title")
            date = item.get("first_air_date") if kind == "tv" else item.get("release_date")
            return {"kind": kind, "id": item.get("id"), "name": name or query,
                    "year": int(date[:4]) if date and date[:4].isdigit() else None,
                    "poster": IMAGE + item["poster_path"],
                    "overview": (item.get("overview") or "")[:300]}
        return None

    def lookup(self, title: str, artist: str = "") -> dict | None:
        """The poster for a show or film named like this, or None."""
        if not self.ready:
            return None
        queries = []
        if artist and artist != "?":
            queries.extend(clean_title(artist))
        for q in clean_title(title):
            if q not in queries:
                queries.append(q)
        if not queries:
            return None
        key = "|".join(q.lower() for q in queries)
        now = self._clock()
        with self._lock:
            c = self._cache.get(key)
        if c and now - c.get("at", 0) <= (HIT_TTL_S if c.get("hit") else MISS_TTL_S):
            return c["hit"]
        hit = None
        try:
            for q in queries:
                hit = self._search("tv", q) or self._search("movie", q)
                if hit:
                    break
            self.problem = None
        except PermissionError as exc:
            self.problem = str(exc)
            print(f"[posters] {exc}", flush=True)
            return None
        except Exception as exc:
            print(f"[posters] lookup {queries[0]!r}: {exc}", flush=True)
            return None                                   # not cached: try again next poll
        with self._lock:
            self._cache[key] = {"at": now, "hit": hit}
            if hit:
                self.count += 1
                self.last = {"title": hit["name"], "kind": hit["kind"], "year": hit["year"], "at": int(now)}
            self._save()
        print(f"[posters] {queries[0]!r}: " + (f"{hit['kind']} {hit['name']} ({hit['year']})" if hit
                                              else "nothing on TMDB"), flush=True)
        return hit


class PosterSource(NowPlayingSource):
    """Sits right after the Mac in the chain. When the Mac saw a show a
    moment ago and TMDB knows it, this is a playing answer with the poster
    as its art; otherwise nothing, and the chain moves on as before."""
    name = "posters"

    def __init__(self, mac, posters: Posters, clock=None):
        self.mac = mac                  # anything with a .show dict, or None
        self.posters = posters
        self._clock = clock or time.time
        self._last = None               # (show key, NowPlaying) so a poll is cheap

    def get_current(self):
        show = getattr(self.mac, "show", None)
        if not show or not self.posters.ready:
            return None
        seen = show.get("seen")
        if seen is not None and self._clock() - float(seen) > SHOW_FRESH_S:
            return None
        key = (show.get("title", ""), show.get("artist", ""), show.get("bundle", ""))
        if self._last and self._last[0] == key:
            np_ = self._last[1]
            if np_ is None:
                return None
        else:
            hit = self.posters.lookup(show.get("title", ""), show.get("artist", ""))
            if hit is None:
                self._last = (key, None)
                return None
            np_ = NowPlaying(
                track_id=f"show:{hit['kind']}:{hit['id']}",
                title=hit["name"],
                artist=("Series" if hit["kind"] == "tv" else "Film") + (f", {hit['year']}" if hit.get("year") else ""),
                album="", art_url=hit["poster"], progress_ms=None, duration_ms=None, is_playing=True)
            self._last = (key, np_)
        prog = show.get("progress_ms")
        dur = show.get("duration_ms")
        return NowPlaying(**{**np_.__dict__, "progress_ms": prog if isinstance(prog, int) else None,
                             "duration_ms": dur if isinstance(dur, int) else None})


def encode_show(show: dict) -> str:
    """The show as one header value (the reporter's side)."""
    return base64.b64encode(json.dumps(show, separators=(",", ":")).encode()).decode()


def decode_show(value: str | None) -> dict | None:
    if not value:
        return None
    try:
        d = json.loads(base64.b64decode(value))
        return d if isinstance(d, dict) and d.get("title") else None
    except (ValueError, TypeError):
        return None
