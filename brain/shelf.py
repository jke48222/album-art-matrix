"""The shelf: the owner's Discogs collection, known to the wall.

Discogs is where a record collection is written down, release by release,
pressing by pressing. With a personal access token (Discogs > Settings >
Developers) and the username, the wall reads the collection's main folder
and keeps it in ~/.config/album-art-matrix/shelf.json: title, artists, year,
labels and catalogue numbers, formats, the cover, when it was added, the
owner's rating. It syncs when the token arrives and every six hours after,
paced under Discogs's sixty requests a minute.

What the wall does with it:

- When a streamed song is from an album on the shelf, the sleeve gets a
  small mark in its corner: you own this on vinyl. (main.py stamps it into
  the prepared sleeve, so every face that shows the sleeve shows the mark.)
- When a record plays (the ear, AirPlay) or any song from a shelf album is
  on the wall, /state carries `owned`: the pressing's year, label, catalogue
  number, country and the lowest price copies are going for, so the phone
  can show the pressing under the song.
- The Shelf page lists the collection, with how often each release has
  played on the wall, from the journal.

Matching is by album title and artist, folded the way people write them
differently: case, punctuation, "The", the "(2)" Discogs puts after an
artist's name to keep two of them apart, anything in brackets, "feat.".
"""
from __future__ import annotations

import difflib
import json
import os
import re
import threading
import time
import unicodedata

import requests

API = "https://api.discogs.com"
UA = "album-art-matrix/1.0 +https://github.com/jke48222/album-art-matrix"
PATH = os.path.expanduser("~/.config/album-art-matrix/shelf.json")
SYNC_EVERY_S = 6 * 3600.0
PAGE = 100
PACE_S = 1.1                    # sixty a minute, with room
PRICE_CACHE_S = 86400.0
DETAILS_CACHE_S = 30 * 86400.0

_BRACKETS = re.compile(r"\s*[\[(][^\])]*[\])]")
_DISCOGS_N = re.compile(r"\s*\(\d+\)$")
_FEAT = re.compile(r"\s+(?:feat\.?|featuring|ft\.?)\s.*$")
_PUNCT = re.compile(r"[^\w\s]")
_SPACES = re.compile(r"\s+")


_TAILS = re.compile(r"(?:^|[\s\-:,]+)(deluxe( edition| version)?|remastered( \d{4})?|expanded( edition)?|"
                    r"anniversary edition|special edition|bonus track version|ep|single|"
                    r"original motion picture soundtrack|explicit)\s*$")


def fold(s: str) -> str:
    """One spelling for the same name: lower, plain letters, no brackets,
    no punctuation, no leading The, no Discogs (2), no feat., no
    "Deluxe Edition" tail."""
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = _DISCOGS_N.sub("", s)
    s = _BRACKETS.sub("", s)
    s = _FEAT.sub("", s)
    s = s.replace("&", " and ")
    s = _PUNCT.sub(" ", s)
    s = _SPACES.sub(" ", s).strip()
    for _ in range(2):
        s = _TAILS.sub("", s).strip() or s
    if s.startswith("the "):
        s = s[4:]
    return s


_ARTIST_SEPS = re.compile(r", | & | and | x | with | feat\.? | featuring | ft\.? ")


def fold_artists(s: str) -> list[str]:
    """Every name in an artist line, folded. The split comes before the
    fold, since the fold takes the commas away."""
    return [n for n in (fold(part) for part in _ARTIST_SEPS.split((s or "").lower())) if n]


def fold_artist(s: str) -> str:
    """The first name when several are listed."""
    names = fold_artists(s)
    return names[0] if names else ""


def release_from_api(item: dict) -> dict:
    b = item.get("basic_information") or {}
    return {
        "id": b.get("id") or item.get("id"),
        "title": b.get("title") or "",
        "artists": [a.get("name", "") for a in (b.get("artists") or [])],
        "year": b.get("year") or 0,
        "labels": [{"name": l.get("name", ""), "catno": l.get("catno", "")} for l in (b.get("labels") or [])],
        "formats": [f.get("name", "") for f in (b.get("formats") or [])],
        "descriptions": sum([f.get("descriptions") or [] for f in (b.get("formats") or [])], []),
        "cover": b.get("cover_image") or b.get("thumb") or "",
        "genres": b.get("genres") or [],
        "added": item.get("date_added") or "",
        "rating": item.get("rating") or 0,
    }


class Shelf:
    def __init__(self, ctrl, token: str = "", user: str = "", path: str = PATH,
                 fetch=None, clock=None):
        self.ctrl = ctrl
        self.token = (token or "").strip()
        self.user = (user or "").strip()
        self.path = path
        self._fetch = fetch or self._http_get
        self._clock = clock or time.time
        self._lock = threading.Lock()
        self.releases: list[dict] = []
        self.synced_at: float | None = None
        self.syncing = False
        self.problem: str | None = None
        self._prices: dict[int, tuple[float, dict]] = {}
        self._details: dict[int, tuple[float, dict]] = {}
        self._wake = threading.Event()
        self._thread = threading.Thread(target=self._loop, name="shelf", daemon=True)
        # the pressing of the song that is on, when it is on the shelf; the
        # phone reads it from /state as `owned`
        self.playing: dict | None = None
        self._load()

    def start(self) -> "Shelf":
        self._thread.start()
        return self

    # ---- disk ----------------------------------------------------------------------------
    def _load(self):
        try:
            with open(self.path) as fh:
                d = json.load(fh)
            self.releases = d.get("releases", [])
            self.synced_at = d.get("synced_at")
            self._prices = {int(k): tuple(v) for k, v in (d.get("prices") or {}).items()}
            self._details = {int(k): tuple(v) for k, v in (d.get("details") or {}).items()}
        except (OSError, ValueError, TypeError):
            self.releases, self.synced_at = [], None

    def _save(self):
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            tmp = self.path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump({"releases": self.releases, "synced_at": self.synced_at,
                           "user": self.user, "prices": self._prices, "details": self._details},
                          fh)
            os.replace(tmp, self.path)
        except OSError as exc:
            print(f"[shelf] could not save: {exc}", flush=True)

    # ---- settings ---------------------------------------------------------------------------
    @property
    def configured(self) -> bool:
        return bool(self.token and self.user)

    def configure(self, token=None, user=None):
        changed = False
        if token is not None and token.strip() != self.token:
            self.token, changed = token.strip(), True
        if user is not None and user.strip() != self.user:
            self.user, changed = user.strip(), True
        if changed:
            self.problem = None
            self.sync_soon()

    def sync_soon(self):
        self._wake.set()

    # ---- Discogs -------------------------------------------------------------------------------
    def _headers(self) -> dict:
        h = {"User-Agent": UA, "Accept": "application/vnd.discogs.v2.discogs+json"}
        if self.token:
            h["Authorization"] = f"Discogs token={self.token}"
        return h

    def _http_get(self, path: str, params: dict | None = None):
        r = requests.get(API + path, params=params or {}, headers=self._headers(), timeout=20)
        if r.status_code == 429:
            time.sleep(float(r.headers.get("Retry-After", 60)))
            r = requests.get(API + path, params=params or {}, headers=self._headers(), timeout=20)
        if r.status_code == 401:
            raise PermissionError("Discogs rejected the token")
        if r.status_code == 404:
            raise LookupError("not on Discogs")
        r.raise_for_status()
        return r.json()

    def _loop(self):
        while True:
            try:
                self.tick()
            except Exception as exc:
                self.problem = f"{type(exc).__name__}: {str(exc)[:100]}"
                print(f"[shelf] {self.problem}", flush=True)
            self._wake.wait(SYNC_EVERY_S)
            self._wake.clear()

    def tick(self):
        if not self.configured:
            return
        due = self.synced_at is None or self._clock() - self.synced_at >= SYNC_EVERY_S - 5
        if due:
            self.sync()

    def sync(self) -> int:
        """Every release in folder 0, page by page. Returns how many."""
        if not self.configured:
            return 0
        self.syncing = True
        try:
            got, page, pages = [], 1, 1
            while page <= pages:
                data = self._fetch(f"/users/{self.user}/collection/folders/0/releases",
                                   {"per_page": PAGE, "page": page, "sort": "added", "sort_order": "desc"})
                pages = int((data.get("pagination") or {}).get("pages") or 1)
                got.extend(release_from_api(x) for x in data.get("releases") or [])
                page += 1
                if page <= pages:
                    time.sleep(PACE_S)
            with self._lock:
                self.releases = got
                self.synced_at = self._clock()
                self.problem = None
                self._save()
            print(f"[shelf] {len(got)} releases on the shelf for {self.user}", flush=True)
            return len(got)
        except PermissionError as exc:
            self.problem = str(exc)
            print(f"[shelf] {exc}", flush=True)
            return 0
        finally:
            self.syncing = False

    # ---- matching -----------------------------------------------------------------------------
    def match(self, album: str, artist: str) -> dict | None:
        """The release for an album and artist, or None. The title must be
        the same, nearly the same (Blonde, Blond), or contain the other
        when both are long; one of the artists named must be one of the
        release's, or the release is a various-artists one. Among the
        releases that pass, the exact title, the exact artist and the
        vinyl win."""
        a = fold(album)
        if not a:
            return None
        who = fold_artists(artist)
        with self._lock:
            rels = list(self.releases)
        best, best_score = None, 0
        for r in rels:
            rt = fold(r.get("title", ""))
            if not rt:
                continue
            if rt == a:
                ts = 4
            elif difflib.SequenceMatcher(None, a, rt).ratio() >= 0.92:
                ts = 3
            elif len(a) > 6 and len(rt) > 6 and (a in rt or rt in a) \
                    and min(len(a), len(rt)) >= 0.6 * max(len(a), len(rt)):
                ts = 2
            else:
                continue
            names = [fold_artist(n) for n in r.get("artists", [])]
            if any(w == n for w in who for n in names):
                arts = 2
            elif any(len(w) > 3 and len(n) > 3 and (w in n or n in w) for w in who for n in names):
                arts = 1
            elif "various" in names:
                arts = 1
            else:
                continue
            score = ts * 3 + arts + (1 if "Vinyl" in r.get("formats", []) else 0)
            if score > best_score:
                best, best_score = r, score
        return best

    def owned(self, now) -> dict | None:
        """The release a playing song belongs to, when it is on the shelf."""
        if now is None or not getattr(now, "album", None) or now.album == "?":
            return None
        r = self.match(now.album, now.artist)
        if r is None:
            return None
        return self.pressing(r)

    def note_playing(self, album: str, artist: str) -> dict | None:
        """A song went up: remember its pressing (None when it is not on
        the shelf) and fetch the country and the price on a worker, so the
        render loop never waits on Discogs."""
        r = self.match(album or "", artist or "") if album and album != "?" else None
        if r is None:
            self.playing = None
            return None
        self.playing = self.pressing(r)
        rid = int(r["id"])
        det, pr = self._details.get(rid), self._prices.get(rid)
        now = self._clock()
        fresh = (det is not None and now - det[0] <= DETAILS_CACHE_S
                 and pr is not None and now - pr[0] <= PRICE_CACHE_S)
        if self.configured and not fresh:
            def work():
                try:
                    p = self.enrich(rid)
                except Exception as exc:
                    print(f"[shelf] enrich {rid}: {exc}", flush=True)
                    return
                if self.playing is not None and self.playing.get("release_id") == rid:
                    self.playing = p
            threading.Thread(target=work, name="shelf-enrich", daemon=True).start()
        return self.playing

    def pressing(self, r: dict) -> dict:
        label = r["labels"][0] if r.get("labels") else {"name": "", "catno": ""}
        out = {"release_id": r["id"], "title": r["title"], "artists": r["artists"],
               "year": r.get("year") or None, "label": label.get("name", ""),
               "catno": label.get("catno", ""), "formats": r.get("formats", []),
               "descriptions": r.get("descriptions", []), "cover": r.get("cover", ""),
               "rating": r.get("rating", 0), "url": f"https://www.discogs.com/release/{r['id']}"}
        det = self._details.get(int(r["id"]))
        if det:
            out.update(det[1])
        pr = self._prices.get(int(r["id"]))
        if pr:
            out["price"] = pr[1]
        return out

    def enrich(self, release_id: int) -> dict:
        """Country, release date and the marketplace's lowest price, fetched
        once and kept; on a worker, never on the render loop."""
        rid = int(release_id)
        now = self._clock()
        det = self._details.get(rid)
        if det is None or now - det[0] > DETAILS_CACHE_S:
            try:
                d = self._fetch(f"/releases/{rid}", {})
                self._details[rid] = (now, {"country": d.get("country", ""),
                                            "released": d.get("released", ""),
                                            "notes": (d.get("notes") or "")[:200]})
            except Exception as exc:
                print(f"[shelf] release {rid}: {exc}", flush=True)
        pr = self._prices.get(rid)
        if pr is None or now - pr[0] > PRICE_CACHE_S:
            try:
                time.sleep(PACE_S)
                p = self._fetch(f"/marketplace/stats/{rid}", {"curr_abbr": "USD"})
                low = p.get("lowest_price") or {}
                self._prices[rid] = (now, {"lowest": low.get("value"), "currency": low.get("currency", "USD"),
                                           "for_sale": p.get("num_for_sale", 0)})
            except Exception as exc:
                print(f"[shelf] price {rid}: {exc}", flush=True)
        with self._lock:
            self._save()
        return self.pressing(next((r for r in self.releases if int(r["id"]) == rid), {"id": rid, "title": "", "artists": []}))

    # ---- for the phone ---------------------------------------------------------------------------
    def listing(self, journal: list[dict] | None = None) -> list[dict]:
        plays: dict[str, int] = {}
        for e in journal or []:
            key = fold(e.get("album", "")) + "|" + fold_artist(e.get("artist", ""))
            plays[key] = plays.get(key, 0) + 1
        out = []
        with self._lock:
            rels = list(self.releases)
        for r in rels:
            key = fold(r.get("title", "")) + "|" + fold_artist((r.get("artists") or [""])[0])
            out.append({**self.pressing(r), "plays": plays.get(key, 0), "added": r.get("added", "")})
        return out

    def status(self) -> dict:
        return {"user": self.user, "token_set": bool(self.token), "releases": len(self.releases),
                "synced_at": self.synced_at, "syncing": self.syncing, "problem": self.problem}
