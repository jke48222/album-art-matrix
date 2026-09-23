"""Show me, play me, and the earworm finder.

    show("the Eiffel Tower")     a picture of it, from Wikipedia (its page's
                                 lead image) or failing that Openverse, in the
                                 frame face for ten minutes or until something
                                 else is chosen
    show("the Blond cover")      iTunes finds the album, the sleeve goes up the
                                 same way. Plain words go to a picture unless
                                 they name a record the wall knows; "cover",
                                 "sleeve", "album", "by <artist>" ask for a
                                 sleeve, "a picture of" asks for a picture
    play("the Gameboy video")    yt-dlp finds the video by name, the wall's
                                 video face plays it with the phone as the
                                 speaker, as a pasted link would
    earworm("I can't stop...")   Claude names the song from the words, the
                                 sleeve goes up for eight seconds with the
                                 name running under it, the phone gets the
                                 alternatives
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
import re
import subprocess
import threading
import time

import numpy as np
import requests
from PIL import Image

from .art.fetch import fetch_art
from .art.pipeline import prepare
from .video import ytdlp

SHOW_S = 600.0                  # a cover asked for stays this long
EARWORM_S = 8.0                 # the found song's sleeve, before its name runs
ITUNES = "https://itunes.apple.com/search"
WIKIPEDIA = "https://en.wikipedia.org/w/api.php"
OPENVERSE = "https://api.openverse.org/v1/images/"
UA = "album-art-matrix/1.0 (github.com/jke48222/album-art-matrix)"

# Words that say a sleeve is wanted, and words that say a picture is.
_COVER_CUES = re.compile(r"\b(cover|sleeve|album|record|song|track|single|ep|lp|vinyl)\b|\bby\b")
_PICTURE_OF = re.compile(r"^(?:a |an |the |some )?(?:picture|photo|photograph|image|pic|pictures|photos)s?"
                         r" (?:of |for )(.+)$", re.I)
_COVER_OF = re.compile(r"^(?:the )?(?:cover|sleeve|album art|art|artwork) (?:of |for )(.+)$", re.I)


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
            if q in name or name in q:
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
            return {"title": p.get("title") or query, "art_url": pic,
                    "credit": "Wikipedia", "source": "wikipedia"}
    return None


def openverse_picture(query: str) -> dict | None:
    """An openly licensed photograph, for the things Wikipedia has no page
    for. Anonymous use is allowed and enough for a wall."""
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
        return {"title": x.get("title") or query, "art_url": pic,
                "credit": credit or "Openverse", "source": "openverse"}
    return None


def find_picture(query: str) -> dict | None:
    return wikipedia_picture(query) or openverse_picture(query)


class Shower:
    def __init__(self, ctrl, asker=None):
        self.ctrl = ctrl
        self.asker = asker
        self._ret = None
        self._until = 0.0
        self.last = None

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
        here = ctrl.get()["mode"]
        if here != "frame" or self._ret is None:
            self._ret = here if here not in ("frame", "clip", "timer", "video") else "art"
        ctrl.frame_override = px
        ctrl.shown_seq += 1
        ctrl.apply({"mode": "frame"})
        self._until = time.monotonic() + seconds
        t = threading.Timer(seconds, self._take_down)
        t.daemon = True
        t.start()
        return True

    def _take_down(self):
        if time.monotonic() < self._until - 1.0:
            return                                 # a later showing took over
        if self.ctrl.get()["mode"] == "frame":
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

    # ---- the four ---------------------------------------------------------------------------------
    def show(self, query: str, kind: str = "any") -> dict:
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

        pic = find_picture(q)
        if pic is not None:
            if not self._put_up(pic["art_url"], SHOW_S):
                return {"error": f"I found a picture of {pic['title']} but could not fetch it."}
            out = {"what": "show", "kind": "picture", "title": pic["title"], "artist": pic["credit"],
                   "album": "", "art_url": pic["art_url"], "credit": pic["credit"],
                   "source": pic["source"]}
            self.last = out
            print(f"[show] a picture of {pic['title']} ({pic['source']}) on the wall", flush=True)
            return {"shown": True, **out, "seconds": SHOW_S}
        if found is not None:
            return self._show_cover(found)
        return {"error": f"I could not find a picture or a cover for {q}."}

    def _show_cover(self, found: dict) -> dict:
        if not self._put_up(found["art_url"], SHOW_S):
            return {"error": f"I found {found['title']} but could not fetch its cover."}
        out = {"what": "show", "kind": "cover", **{k: v for k, v in found.items() if k != "score"}}
        self.last = out
        print(f"[show] {found['artist']} - {found['title']} on the wall", flush=True)
        return {"shown": True, **out, "seconds": SHOW_S}

    def play(self, query: str) -> dict:
        ctrl = self.ctrl
        if ctrl.video is None:
            return {"error": "This wall cannot play video."}
        bin_ = ytdlp.binary()
        if not bin_:
            return {"error": "Finding a video by name needs yt-dlp, which this wall does not have."}
        try:
            out = subprocess.run([bin_, "--default-search", "ytsearch1", "--no-playlist",
                                  "--skip-download", "--print", "id", "--print", "title", query],
                                 capture_output=True, text=True, timeout=40)
            lines = [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"The video search failed: {str(exc)[:80]}"}
        if len(lines) < 1:
            return {"error": f"I could not find a video for {query}."}
        vid, title = lines[0], (lines[1] if len(lines) > 1 else query)
        url = f"https://www.youtube.com/watch?v={vid}"
        problem = ctrl.video_start(url, sound=True, loop=False, clock="auto", title=title)
        if problem:
            return {"error": str(problem)}
        self.last = {"what": "play", "title": title, "url": url}
        print(f"[show] playing {title!r} ({url})", flush=True)
        return {"playing": True, "title": title, "url": url}

    def earworm(self, words: str) -> dict:
        if self.asker is None or not self.asker.ready:
            return {"error": "Naming a song from its words needs the Claude key, set under Services."}
        got = self.asker.earworm(words)
        if not got or not got.get("title"):
            return {"error": "I could not place those words."}
        found = find_art(f"{got['artist']} {got['title']}") or {}
        art = found.get("art_url")
        shown = False
        if art:
            # the sleeve with the name on a band along its foot, the artist
            # under the title at 192, for a while
            try:
                from .games.board import banner, INK, fit_text, text_centred
                ctrl = self.ctrl
                tune = getattr(ctrl, "tuning", None)
                pre = prepare(fetch_art(art), ctrl.wall.width,
                              unsharp_radius=tune.get("unsharp_radius") if tune else 1.0,
                              unsharp_percent=tune.get("unsharp_percent") if tune else 60)
                f = np.asarray(pre, dtype=np.uint8).copy()
                size = f.shape[0]
                if size > 96:
                    band = 26
                    f[size - band:] = (f[size - band:] * 0.25).astype(np.uint8)
                    f[size - band] = (f[size - band] * 0.5 + 60).astype(np.uint8)
                    text_centred(f, fit_text(got["title"], size - 8, 2), size // 2, size - band + 4, INK, 2)
                    text_centred(f, fit_text(got["artist"], size - 8, 1), size // 2, size - 9, (170, 166, 156), 1)
                else:
                    banner(f, size, got["title"], INK, (18, 18, 24))
                shown = self.show_frame(f, EARWORM_S + 6.0)
            except Exception as exc:
                print(f"[show] earworm sleeve: {exc}", flush=True)
                shown = bool(self._put_up(art, EARWORM_S))
        self.last = {"what": "earworm", **got, "art_url": art}
        print(f"[show] earworm {words!r} -> {got['artist']} - {got['title']} "
              f"({got.get('confidence')})", flush=True)
        return {"shown": shown, **got, "art_url": art}

    def imagine(self, prompt: str) -> dict:
        im = getattr(self.ctrl, "imaginer", None)
        if im is None:
            return {"error": "Drawing from words is off on this wall."}
        return im.imagine(prompt)
