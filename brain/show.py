"""Show me, play me, and the earworm finder.

    show("the Eiffel Tower")     a picture of it: Google Images when a key and
                                 search engine are on the wall, otherwise the
                                 web through DuckDuckGo's image search (no
                                 key), then the lead image of its Wikipedia
                                 page, then Openverse; in the frame face for
                                 ten minutes or until something else is chosen
    show("the Blond cover")      iTunes finds the album, the sleeve goes up the
                                 same way. Plain words go to a picture unless
                                 they name a record the wall knows; "cover",
                                 "sleeve", "album", "by <artist>" ask for a
                                 sleeve, "a picture of" asks for a picture
    play("the Gameboy video")    yt-dlp finds the video by name, the wall's
                                 video face plays it with the phone as the
                                 speaker, as a pasted link would
    earworm("I can't stop...")   Claude names the song from the words, the
                                 sleeve goes up for ten minutes; the phone
                                 shows the same composition, song identity,
                                 and clearly labeled alternatives
    imagine("a purple elephant") a picture from words, by brain/imagine.py:
                                 Claude writes the prompt for a panel, an
                                 image model draws it, the frame face shows
                                 it for ten minutes

Everything returns a dict: {"error": words} when nothing could be done,
which the voice reads out and the phone shows, or the thing that was done.
Nothing here blocks the render loop: searches run on the caller's thread,
which is the voice's worker or a request handler.
"""
from __future__ import annotations

import difflib
import base64
import io
import math
import re
import subprocess
import threading
import time
import uuid

import numpy as np
import requests
from PIL import Image

from .art.fetch import fetch_art
from .art.pipeline import prepare
from .video import ytdlp

SHOW_S = 600.0                  # a cover asked for stays this long
ITUNES = "https://itunes.apple.com/search"
GOOGLE = "https://www.googleapis.com/customsearch/v1"
WIKIPEDIA = "https://en.wikipedia.org/w/api.php"
OPENVERSE = "https://api.openverse.org/v1/images/"
UA = "album-art-matrix/1.0 (github.com/jke48222/album-art-matrix)"

# Words that say a sleeve is wanted, and words that say a picture is.
_COVER_CUES = re.compile(r"\b(cover|sleeve|album|record|song|track|single|ep|lp|vinyl)\b|\bby\b")
_PICTURE_OF = re.compile(r"^(?:a |an |the |some )?(?:picture|photo|photograph|image|pic|pictures|photos)s?"
                         r" (?:of |for )(.+)$", re.I)
_COVER_OF = re.compile(r"^(?:the )?(?:cover|sleeve|album art|art|artwork) (?:of |for )(.+)$", re.I)


class DisplayChanged(RuntimeError):
    """A selection made during discovery takes precedence over its late result."""


def _plain(s: str) -> str:
    return (s or "").strip().lower()


def itunes(query: str, entity: str, limit: int = 5) -> list[dict]:
    try:
        r = requests.get(ITUNES, params={"term": query, "entity": entity, "limit": limit},
                         headers={"User-Agent": UA}, timeout=10)
        return [x for x in r.json().get("results", []) if x.get("artworkUrl100")]
    except (requests.RequestException, ValueError) as exc:
        print(f"[show] itunes: {exc}", flush=True)
        return []


def find_art(query: str) -> dict | None:
    """The best sleeve for some words: an album first, then a song. Returns
    {title, artist, album, art_url, score} or None."""
    q = _plain(query)
    best, best_score = None, 0.0
    for entity, name_key in (("album", "collectionName"), ("song", "trackName")):
        for x in itunes(query, entity):
            name = _plain(x.get(name_key))
            artist = _plain(x.get("artistName"))
            score = max(difflib.SequenceMatcher(None, q, name).ratio(),
                        difflib.SequenceMatcher(None, q, f"{name} {artist}").ratio(),
                        difflib.SequenceMatcher(None, q, f"{artist} {name}").ratio())
            if name and (q in name or name in q):
                score = max(score, 0.9)
            if score > best_score:
                best, best_score = x, score
                best["_entity"] = entity
        if best is not None and best_score >= 0.85:
            break
    if best is None or best_score < 0.5:
        return None
    return {"title": best.get("trackName") or best.get("collectionName") or query,
            "artist": best.get("artistName") or "",
            "album": best.get("collectionName") or "",
            "art_url": best["artworkUrl100"].replace("100x100bb", "600x600bb"),
            "score": round(best_score, 3)}


# ---- pictures of things -------------------------------------------------------------------
# Each finder returns a list of candidates, best first: {title, art_url,
# thumb (a smaller copy, or None), credit, source}. The first that can be
# fetched is the one shown.

def google_pictures(query: str, api_key: str, cx: str) -> list[dict]:
    """Google Images, through the Custom Search JSON API: a key from the
    Cloud console and a Programmable Search Engine that searches the whole
    web with image search on. A hundred searches a day are free."""
    if not api_key or not cx:
        return []
    try:
        r = requests.get(GOOGLE, params={
            "key": api_key, "cx": cx, "q": query, "searchType": "image",
            "num": 6, "safe": "active", "imgSize": "large",
        }, headers={"User-Agent": UA}, timeout=10)
        body = r.json()
        if r.status_code != 200:
            why = (body.get("error") or {}).get("message", f"http {r.status_code}")
            print(f"[show] google: {why}", flush=True)
            return []
        items = body.get("items", [])
    except (requests.RequestException, ValueError) as exc:
        print(f"[show] google: {exc}", flush=True)
        return []
    out = []
    for x in items:
        link = x.get("link")
        if not link:
            continue
        out.append({"title": x.get("title") or query, "art_url": link,
                    "thumb": (x.get("image") or {}).get("thumbnailLink"),
                    "credit": x.get("displayLink") or "Google", "source": "google"})
    return out


def web_pictures(query: str) -> list[dict]:
    """The web's image search without a key, through DuckDuckGo (the ddgs
    package; its results come from Bing's index). Unofficial, so a change
    on their side is a quiet empty list here, not a broken wall."""
    try:
        from ddgs import DDGS
    except ImportError:
        return []
    try:
        results = DDGS().images(query, max_results=6, safesearch="moderate") or []
    except Exception as exc:
        print(f"[show] web: {exc}", flush=True)
        return []
    out = []
    for x in results:
        link = x.get("image")
        if not link:
            continue
        out.append({"title": x.get("title") or query, "art_url": link,
                    "thumb": x.get("thumbnail"),
                    "credit": x.get("source") or "the web", "source": "web"})
    return out


def wikipedia_picture(query: str) -> dict | None:
    """The lead image of the Wikipedia page the words find, skipping
    disambiguation pages. A landmark, a person, an animal, a painting: the
    page's own picture is the one anyone would expect."""
    try:
        r = requests.get(WIKIPEDIA, params={
            "action": "query", "generator": "search", "gsrsearch": query,
            "gsrlimit": 4, "gsrnamespace": 0,
            "prop": "pageimages|pageprops", "piprop": "thumbnail|original",
            "pithumbsize": 1024, "ppprop": "disambiguation",
            "format": "json", "formatversion": 2,
        }, headers={"User-Agent": UA}, timeout=10)
        pages = r.json().get("query", {}).get("pages", [])
    except (requests.RequestException, ValueError) as exc:
        print(f"[show] wikipedia: {exc}", flush=True)
        return None
    for p in sorted(pages, key=lambda p: p.get("index", 99)):
        if "disambiguation" in (p.get("pageprops") or {}):
            continue
        pic = (p.get("thumbnail") or p.get("original") or {}).get("source")
        if pic:
            return {"title": p.get("title") or query, "art_url": pic, "thumb": None,
                    "credit": "Wikipedia", "source": "wikipedia"}
    return None


def openverse_picture(query: str) -> dict | None:
    """An openly licensed photograph, for the things nothing else has.
    Anonymous use is allowed and enough for a wall."""
    try:
        r = requests.get(OPENVERSE, params={"q": query, "page_size": 6, "mature": "false"},
                         headers={"User-Agent": UA}, timeout=10)
        results = r.json().get("results", [])
    except (requests.RequestException, ValueError) as exc:
        print(f"[show] openverse: {exc}", flush=True)
        return None
    for x in results:
        pic = x.get("thumbnail") or x.get("url")
        if not pic:
            continue
        who = x.get("creator") or ""
        lic = (x.get("license") or "").upper()
        credit = ", ".join(s for s in (who, f"CC {lic}" if lic and lic != "PDM" else lic) if s)
        return {"title": x.get("title") or query, "art_url": pic, "thumb": None,
                "credit": credit or "Openverse", "source": "openverse"}
    return None


class Shower:
    def __init__(self, ctrl, asker=None, google_key: str = "", google_cx: str = ""):
        self.ctrl = ctrl
        self.asker = asker
        self._ret = None
        self._until = 0.0
        self.last = None
        self.google_key, self.google_cx = google_key or "", google_cx or ""
        self.pictures = 0            # pictures put up, for the phone's page
        self.last_picture = None     # {title, source}
        self.last_show = None
        self.last_earworm = None
        self._work_lock = threading.Lock()
        self._frame_lock = threading.RLock()
        self._timer = None
        self._frame_seq = None
        self._frame_bytes = None
        self.pending = None
        self.problem = None
        self._problem_kind = None
        self._local = threading.local()

    def configure(self, api_key: str | None = None, cx: str | None = None):
        """The Google key and search engine, from the phone's Services page."""
        self.google_key = (api_key or "").strip()
        self.google_cx = (cx or "").strip()

    def status(self) -> dict:
        """For GET /services: whether Google is set, and what was last found."""
        return {"key_set": bool(self.google_key), "cx_set": bool(self.google_cx),
                "pictures": self.pictures, "last": self.last_picture, "problem": None}

    def _receipt(self, value: dict | None) -> dict | None:
        if value is None:
            return None
        result = dict(value)
        active = (value.get("shown") is True and value.get("frame_seq") == self.ctrl.shown_seq
                  and self.ctrl.get()["mode"] == "frame"
                  and time.monotonic() < self._until)
        if value.get("what") == "play":
            active = self.ctrl.get()["mode"] == "video" and value.get("frame_seq") == self.ctrl.shown_seq
        result["active"] = active
        result["seconds_left"] = max(0, int(self._until - time.monotonic())) if active and value.get("what") != "play" else 0
        return result

    def discovery_status(self) -> dict:
        with self._frame_lock:
            return {"last": self._receipt(self.last_show), "pending": self.pending in ("show", "play"),
                    "problem": self.problem if self._problem_kind in ("show", "play") else None,
                    "picture_provider": "Google Images" if self.google_key and self.google_cx else "Web search",
                    "video_available": getattr(self.ctrl, "video", None) is not None}

    def earworm_status(self) -> dict:
        with self._frame_lock:
            return {"last": self._receipt(self.last_earworm), "pending": self.pending == "earworm",
                    "ready": self.asker is not None and self.asker.ready,
                    "problem": self.problem if self._problem_kind == "earworm" else None}

    def _remember(self, out: dict, *, earworm: bool = False) -> dict:
        with self._frame_lock:
            out = {"id": str(uuid.uuid4()), "created_at": int(time.time()), **out}
            receipt = getattr(self._local, "receipt", None)
            if out.get("shown") and receipt is not None:
                sequence, pixels = receipt
                size = self.ctrl.wall.width
                buffer = io.BytesIO()
                Image.frombytes("RGB", (size, size), pixels).save(buffer, format="PNG")
                out.update(preview_png=base64.b64encode(buffer.getvalue()).decode("ascii"),
                           preview_size=size, frame_seq=sequence)
            self.last = out
            if earworm:
                self.last_earworm = out
            else:
                self.last_show = out
            return self._receipt(out)

    def _run(self, kind: str, work) -> dict:
        if not self._work_lock.acquire(blocking=False):
            return {"error": "The wall is finishing another discovery. Try again in a moment.", "code": 409}
        self.pending, self.problem, self._problem_kind = kind, None, kind
        self._local.selection = (self.ctrl.get()["mode"], self.ctrl.shown_seq)
        self._local.receipt = None
        try:
            result = work()
            if result.get("error"):
                self.problem = result["error"]
            return result
        except DisplayChanged:
            self.problem = "Your wall changed while the search was running. Search again when you're ready to replace it."
            return {"error": self.problem, "code": 409}
        except Exception as exc:
            print(f"[show] {kind}: {type(exc).__name__}: {exc}", flush=True)
            self.problem = "The search service could not finish. Your words are safe; try again."
            return {"error": self.problem, "code": 502}
        finally:
            self.pending = None
            self._local.selection = None
            self._work_lock.release()

    def _check_selection(self):
        expected = getattr(self._local, "selection", None)
        if expected is not None and expected != (self.ctrl.get()["mode"], self.ctrl.shown_seq):
            raise DisplayChanged()

    # ---- the frame face, for a while --------------------------------------------------------
    def _put_up(self, art_url: str, seconds: float) -> bool:
        try:
            img = fetch_art(art_url)
        except Exception as exc:
            print(f"[show] art: {exc}", flush=True)
            return False
        return self.show_image(img, seconds)

    def show_image(self, img, seconds: float) -> bool:
        """A picture already in hand (a found sleeve, an imagined one): the
        sleeve pipeline at the wall's size, then the frame face for a while."""
        ctrl = self.ctrl
        tune = getattr(ctrl, "tuning", None)
        pre = prepare(img, ctrl.wall.width,
                      unsharp_radius=tune.get("unsharp_radius") if tune else 1.0,
                      unsharp_percent=tune.get("unsharp_percent") if tune else 60)
        return self.show_frame(pre, seconds)

    def show_frame(self, frame, seconds: float) -> bool:
        """A frame already at the wall's size (a PIL image or an array),
        as it is, in the frame face for a while."""
        ctrl = self.ctrl
        pre = frame if hasattr(frame, "tobytes") and not hasattr(frame, "shape") else Image.fromarray(np.asarray(frame, dtype=np.uint8))
        px = ctrl.wall.fit(pre.tobytes())
        if px is None:
            return False
        if not math.isfinite(seconds) or seconds <= 0:
            return False
        with self._frame_lock, ctrl._lock:
            self._check_selection()
            here = ctrl.get()["mode"]
            if here != "frame" or self._ret is None or ctrl.shown_seq != self._frame_seq:
                self._ret = here if here not in ("frame", "clip", "timer", "video") else "art"
            ctrl.frame_override = px
            ctrl.shown_seq += 1
            self._frame_seq, self._frame_bytes = ctrl.shown_seq, bytes(px)
            self._local.receipt = (self._frame_seq, self._frame_bytes)
            self._local.selection = ("frame", ctrl.shown_seq) if getattr(self._local, "selection", None) is not None else None
            ctrl.apply({"mode": "frame"})
            self._until = time.monotonic() + seconds
            if self._timer is not None:
                self._timer.cancel()
            self._timer = threading.Timer(seconds, self._take_down, args=(self._frame_seq,))
            self._timer.daemon = True
            self._timer.start()
        return True

    def _take_down(self, sequence=None):
        with self._frame_lock, self.ctrl._lock:
            if sequence is not None and sequence != self._frame_seq:
                return
            if time.monotonic() < self._until - 0.05:
                return
            # A drawing, archive selection, or a newer showing owns the wall
            # now. An old expiry must never remove someone else's artwork.
            if (self.ctrl.get()["mode"] == "frame" and self.ctrl.shown_seq == self._frame_seq
                    and self.ctrl.frame_override == self._frame_bytes):
                self.ctrl.apply({"mode": self._ret or "art"})
            self._ret = None

    # ---- which is meant: a record the wall knows, or a thing in the world ------------------
    def _knows(self, found: dict) -> bool:
        """Whether the wall has met this artist: in its journal of what it
        has worn, or on the shelf. "Show me Blond" means the record when
        Frank Ocean has been on the wall; "show me the Eiffel Tower" does
        not mean the song of that name by someone it has never played."""
        artist = _plain(found.get("artist"))
        if not artist:
            return False
        ctrl = self.ctrl
        try:
            for e in ctrl.journal_read(200):
                if _plain(e.get("artist")) == artist:
                    return True
        except Exception:
            pass
        shelf = getattr(ctrl, "shelf", None)
        if shelf is not None:
            try:
                if shelf.match(found.get("album") or "", found.get("artist") or ""):
                    return True
            except Exception:
                pass
        return False

    def find_pictures(self, query: str) -> list[dict]:
        """Candidates for a picture of the words, best first: Google when it
        is set up, the web, Wikipedia's page, Openverse."""
        out = google_pictures(query, self.google_key, self.google_cx)
        out += web_pictures(query)
        for one in (wikipedia_picture(query), openverse_picture(query)):
            if one is not None:
                out.append(one)
        return out

    def _show_picture(self, query: str) -> dict | None:
        """The first candidate that can be fetched and shown, or None."""
        for pic in self.find_pictures(query):
            # the picture itself, or its smaller copy when a site will not
            # hand the picture over (hotlinking refused, a login wall)
            for url in (u for u in (pic["art_url"], pic.get("thumb")) if u):
                if self._put_up(url, SHOW_S):
                    self.pictures += 1
                    self.last_picture = {"title": pic["title"], "source": pic["source"]}
                    out = {"what": "show", "kind": "picture", "title": pic["title"],
                           "artist": pic["credit"], "album": "", "art_url": url,
                           "credit": pic["credit"], "source": pic["source"]}
                    print(f"[show] a picture of {pic['title']!r} ({pic['source']}) on the wall", flush=True)
                    return self._remember({"shown": True, **out, "seconds": SHOW_S})
        return None

    # ---- the four ---------------------------------------------------------------------------------
    def show(self, query: str, kind: str = "any") -> dict:
        if not isinstance(query, str) or not query.strip() or len(query) > 500:
            return {"error": "Use a search from 1 to 500 characters.", "code": 400}
        if kind not in ("any", "picture", "cover"):
            return {"error": "Choose a picture or a cover.", "code": 400}
        return self._run("show", lambda: self._show(query, kind))

    def _show(self, query: str, kind: str = "any") -> dict:
        """kind is "cover", "picture" or "any". The words themselves can say:
        "a picture of X" asks for a picture, "the cover of X" or a cover cue
        in the words asks for a sleeve. Left to "any", a record the wall
        knows wins, otherwise a picture, and a sleeve only if there is no
        picture to be had."""
        q = (query or "").strip()
        m = _PICTURE_OF.match(q)
        if m:
            kind, q = "picture", m.group(1).strip()
        else:
            m = _COVER_OF.match(q)
            if m:
                kind, q = "cover", m.group(1).strip()
            elif kind == "any" and _COVER_CUES.search(q.lower()):
                kind = "cover"

        found = find_art(q) if kind != "picture" else None
        if kind == "cover" or (kind == "any" and found is not None
                               and found["score"] >= 0.85 and self._knows(found)):
            if found is None:
                return {"error": f"I could not find a cover for {q}."}
            return self._show_cover(found)

        shown = self._show_picture(q)
        if shown is not None:
            return shown
        if found is not None:
            return self._show_cover(found)
        return {"error": f"I could not find a picture or a cover for {q}."}

    def _show_cover(self, found: dict) -> dict:
        if not self._put_up(found["art_url"], SHOW_S):
            return {"error": f"I found {found['title']} but could not fetch its cover."}
        out = {"what": "show", "kind": "cover", **{k: v for k, v in found.items() if k != "score"}}
        print(f"[show] {found['artist']} - {found['title']} on the wall", flush=True)
        return self._remember({"shown": True, **out, "source": "iTunes", "seconds": SHOW_S})

    def play(self, query: str) -> dict:
        if not isinstance(query, str) or not query.strip() or len(query) > 500:
            return {"error": "Use a video search from 1 to 500 characters.", "code": 400}
        return self._run("play", lambda: self._play(query.strip()))

    def _play(self, query: str) -> dict:
        ctrl = self.ctrl
        if ctrl.video is None:
            return {"error": "This wall cannot play video."}
        bin_ = ytdlp.binary()
        if not bin_:
            return {"error": "Finding a video by name needs yt-dlp, which this wall does not have."}
        try:
            out = subprocess.run([bin_, "--default-search", "ytsearch1", "--no-playlist",
                                  "--skip-download", "--print", "id", "--print", "title", "--", query],
                                 capture_output=True, text=True, timeout=40)
            lines = [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"The video search failed: {str(exc)[:80]}"}
        if out.returncode != 0 or len(lines) < 1 or not re.fullmatch(r"[A-Za-z0-9_-]{11}", lines[0]):
            return {"error": f"I could not find a video for {query}."}
        vid, title = lines[0], (lines[1] if len(lines) > 1 else query)
        url = f"https://www.youtube.com/watch?v={vid}"
        self._check_selection()
        problem = ctrl.video_start(url, sound=True, loop=False, clock="auto", title=title)
        if problem:
            return {"error": str(problem)}
        print(f"[show] playing {title!r} ({url})", flush=True)
        return self._remember({"what": "play", "kind": "video", "playing": True, "title": title,
                               "url": url, "source": "YouTube", "frame_seq": ctrl.shown_seq})

    def earworm(self, words: str) -> dict:
        if not isinstance(words, str) or not words.strip() or len(words) > 2000:
            return {"error": "Use remembered words from 1 to 2,000 characters.", "code": 400}
        return self._run("earworm", lambda: self._earworm(words.strip()))

    def _earworm(self, words: str) -> dict:
        if self.asker is None or not self.asker.ready:
            return {"error": "Naming a song from its words needs the Claude key, set under Services."}
        got = self.asker.earworm(words)
        if not got or not got.get("title"):
            return {"error": getattr(self.asker, "problem", None) or "I could not place those words. Try another line or add the artist or decade.", "code": 502}
        found = find_art(f"{got['artist']} {got['title']}") or {}
        art = found.get("art_url")
        shown = False
        if art:
            # The artwork is the same square composition on wall and phone;
            # song identity and actions remain outside the artwork on phone.
            try:
                ctrl = self.ctrl
                tune = getattr(ctrl, "tuning", None)
                pre = prepare(fetch_art(art), ctrl.wall.width,
                              unsharp_radius=tune.get("unsharp_radius") if tune else 1.0,
                              unsharp_percent=tune.get("unsharp_percent") if tune else 60)
                shown = self.show_frame(pre, SHOW_S)
            except DisplayChanged:
                raise
            except Exception as exc:
                print(f"[show] earworm sleeve: {exc}", flush=True)
                shown = bool(self._put_up(art, SHOW_S))
        print(f"[show] earworm {words!r} -> {got['artist']} - {got['title']} "
              f"({got.get('confidence')})", flush=True)
        return self._remember({"what": "earworm", "shown": shown, **got, "art_url": art,
                               "album": found.get("album"), "seconds": SHOW_S if shown else 0,
                               "words": words}, earworm=True)

    def show_earworm(self, result_id: str) -> dict:
        def work():
            result = self.last_earworm
            if not result or not result_id or result_id != result.get("id"):
                return {"error": "That discovery has changed. Refresh before showing it again.", "code": 409}
            art = result.get("art_url")
            if not art or not self._put_up(art, SHOW_S):
                return {"error": "The song was identified, but its cover is unavailable. Try again shortly.", "code": 502}
            return self._remember({**result, "shown": True, "seconds": SHOW_S}, earworm=True)
        return self._run("earworm", work)

    def imagine(self, prompt: str) -> dict:
        im = getattr(self.ctrl, "imaginer", None)
        if im is None:
            return {"error": "Drawing from words is off on this wall."}
        return im.imagine(prompt)
