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
        self._fetch = fetch
        self._clock = clock or time.time
        self._lock = threading.RLock()
        self._cache: dict[str, dict] = {}
        self._generation = 0
        self._inflight: set[tuple[int, str]] = set()
        self._checking = False
        self._retry_at = 0.0
        self._verified = False
        self.checked_at = None
        self.state = "saved" if self.api_key else "unlinked"
        self.count = 0
        self.last: dict | None = None
        self.problem: str | None = None
        self._load()

    @property
    def ready(self) -> bool:
        return bool(self.api_key)

    @property
    def generation(self) -> int:
        with self._lock:
            return self._generation

    def configure(self, api_key=None):
        with self._lock:
            if isinstance(api_key, str) and api_key.strip() != self.api_key:
                self.api_key = api_key.strip()
                self._generation += 1
                self.problem = None
                self._verified = False
                self._checking = False
                self.checked_at = None
                self._retry_at = 0
                self.state = "saved" if self.ready else "unlinked"
                self._cache = {k: v for k, v in self._cache.items() if v.get("hit")}
                self._save()

    def status(self) -> dict:
        with self._lock:
            return {"key_set": self.ready, "posters": self.count,
                    "last": dict(self.last) if self.last else None,
                    "known": sum(1 for v in self._cache.values() if v.get("hit")),
                    "problem": self.problem, "state": self.state,
                    "checking": self._checking, "verified": self._verified,
                    "checked_at": self.checked_at,
                    "retry_after": max(0, int(self._retry_at - self._clock() + 0.999))}

    def _load(self):
        try:
            with open(self.path) as fh:
                d = json.load(fh)
            if not isinstance(d, dict):
                return
            cache = d.get("cache", {})
            self._cache = {k: v for k, v in cache.items() if isinstance(k, str) and isinstance(v, dict)} if isinstance(cache, dict) else {}
            self.count = max(0, int(d.get("count", 0)))
            last = d.get("last")
            self.last = last if isinstance(last, dict) and isinstance(last.get("title"), str) else None
        except (OSError, ValueError, TypeError):
            self._cache = {}

    def _save(self):
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            tmp = self.path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump({"cache": self._cache, "count": self.count, "last": self.last}, fh)
            os.replace(tmp, self.path)
        except OSError:
            print("[posters] could not save poster history", flush=True)

    def _http_get(self, path: str, params: dict, api_key: str):
        headers = {"Accept": "application/json"}
        params = dict(params)
        if api_key.startswith("eyJ"):
            headers["Authorization"] = f"Bearer {api_key}"
        else:
            params["api_key"] = api_key
        r = requests.get(API + path, params=params, headers=headers, timeout=12)
        if r.status_code in (401, 403):
            raise PermissionError("TMDB rejected the key")
        r.raise_for_status()
        return r.json()

    def _request(self, path, params, api_key):
        data = self._fetch(path, params) if self._fetch else self._http_get(path, params, api_key)
        if not isinstance(data, dict):
            raise ValueError("invalid TMDB response")
        return data

    def _search(self, kind: str, query: str, api_key: str) -> dict | None:
        data = self._request(f"/search/{kind}", {"query": query, "include_adult": "false", "language": "en-US"}, api_key)
        results = data.get("results")
        if not isinstance(results, list):
            raise ValueError("invalid TMDB response")
        for item in results:
            if not isinstance(item, dict):
                continue
            poster = item.get("poster_path")
            if not isinstance(poster, str) or not re.fullmatch(r"/[A-Za-z0-9._-]+", poster):
                continue
            identity = item.get("id")
            if not isinstance(identity, int) or isinstance(identity, bool) or identity <= 0:
                continue
            name = item.get("name") if kind == "tv" else item.get("title")
            date = item.get("first_air_date") if kind == "tv" else item.get("release_date")
            return {"kind": kind, "id": identity, "name": name if isinstance(name, str) and name else query,
                    "year": int(date[:4]) if isinstance(date, str) and date[:4].isdigit() else None,
                    "poster": IMAGE + poster,
                    "overview": str(item.get("overview") or "")[:300]}
        return None

    def _failure(self, exc: Exception, generation: int):
        with self._lock:
            if generation != self._generation:
                return
            status = getattr(getattr(exc, "response", None), "status_code", None)
            if isinstance(exc, PermissionError) or status in (401, 403):
                self.state, self.problem = "refused", "TMDB couldn't accept this key. Replace it, then check again."
                delay = 60
            elif status == 429:
                self.state, self.problem = "rate_limited", "TMDB is receiving too many requests. Try again shortly."
                try:
                    delay = min(3600, max(10, int(exc.response.headers.get("Retry-After", "60"))))
                except (ValueError, TypeError):
                    delay = 60
            else:
                self.state, self.problem = "unavailable", "TMDB couldn't be reached. Your saved key and poster history are unchanged."
                delay = 15
            self.checked_at = self._clock()
            self._retry_at = self._clock() + delay
            # Provider exceptions can contain the URL's API key. Never publish them.
            print(f"[posters] {self.state}", flush=True)

    def check(self, title: str | None = None) -> bool:
        """Check credentials or look up a title without taking over the wall."""
        if title is not None and (not isinstance(title, str) or not title.strip() or len(title.strip()) > 240 or not clean_title(title)):
            return False
        with self._lock:
            if not self.ready or self._checking or self._clock() < self._retry_at:
                return False
            generation, api_key = self._generation, self.api_key
            self._checking = True
            self.state, self.problem = "checking", None
        def work():
            try:
                if title:
                    self.lookup(title.strip(), force=True, expected_generation=generation)
                else:
                    data = self._request("/configuration", {}, api_key)
                    if not isinstance(data.get("images"), dict):
                        raise ValueError("invalid TMDB configuration")
                    with self._lock:
                        if generation == self._generation:
                            self.state, self.problem = "ready", None
                            self._verified = True
                            self.checked_at = self._clock()
                            self._retry_at = self._clock() + 3
            except Exception as exc:
                self._failure(exc, generation)
            finally:
                with self._lock:
                    if generation == self._generation:
                        self._checking = False
                        if self.state == "checking":
                            self.state = "ready" if self._verified else "saved"
        try:
            threading.Thread(target=work, name="posters-check", daemon=True).start()
        except RuntimeError as exc:
            self._failure(exc, generation)
            with self._lock:
                if generation == self._generation:
                    self._checking = False
            return False
        return True

    def lookup(self, title: str, artist: str = "", *, force=False, expected_generation=None) -> dict | None:
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
            if not self.ready:
                return None
            generation, api_key = self._generation, self.api_key
            if expected_generation is not None and expected_generation != generation:
                return None
            cached = self._cache.get(key)
            if not force and cached and isinstance(cached.get("at"), (int, float)) and now - cached["at"] <= (HIT_TTL_S if cached.get("hit") else MISS_TTL_S):
                return cached.get("hit")
            token = (generation, key)
            if token in self._inflight or now < self._retry_at:
                return None
            self._inflight.add(token)
        try:
            hit = None
            for query in queries:
                for kind in ("tv", "movie"):
                    with self._lock:
                        if generation != self._generation:
                            return None
                    hit = self._search(kind, query, api_key)
                    if hit:
                        break
                if hit:
                    break
            with self._lock:
                if generation != self._generation:
                    return None
                self.problem = None
                self.state = "matched" if hit else "no_match"
                self.checked_at = self._clock()
                self._verified = True
                if force:
                    self._retry_at = self._clock() + 3
                self._cache[key] = {"at": now, "hit": hit}
                if hit:
                    self.count += 1
                    self.last = {"title": hit["name"], "kind": hit["kind"], "year": hit["year"],
                                 "at": int(now), "poster": hit["poster"], "id": hit["id"], "overview": hit["overview"]}
                self._save()
            return hit
        except Exception as exc:
            self._failure(exc, generation)
            return None
        finally:
            with self._lock:
                self._inflight.discard(token)


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
        key = (show.get("title", ""), show.get("artist", ""), show.get("bundle", ""), self.posters.generation)
        if self._last and self._last[0] == key:
            np_ = self._last[1]
            if np_ is None:
                return None
        else:
            hit = self.posters.lookup(show.get("title", ""), show.get("artist", ""))
            if hit is None:
                # Lookup itself caches misses. A network failure must be retried
                # after its backoff even while the same film keeps playing.
                self._last = None
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
