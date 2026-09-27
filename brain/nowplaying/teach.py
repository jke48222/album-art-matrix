"""Teach the wall a song: its own fingerprint library, asked before Shazam.

Shazam knows almost everything, and the songs it does not know are exactly
the ones that matter most in this room: a friend's single, a pressing
nobody uploaded, a demo. For those the wall keeps a library of its own and
asks it first. A lookup here takes a few milliseconds and never leaves the
Pi; Shazam is asked only when the library has nothing to say.

How a song is known
-------------------
The same idea Shazam published in 2003 and Olaf and audfprint reuse: a
spectrogram is reduced to its peaks, peaks are paired into LANDMARKS (the
two frequencies and the time between them, packed into one number), and a
song is the bag of its landmarks with the time each one happened. A query
clip is reduced the same way; every landmark it shares with a stored song
votes for "this song, at this offset", and a real match is a pile of votes
on one offset, where noise scatters its few votes everywhere. Peaks survive
a room, a microphone and a cheap speaker far better than anything else in
the signal, which is why the trick works on a phone held up in a bar.

Why not Olaf: it wants Zig to build and the Pi's Debian has none; audfprint
is not packaged. This is a few hundred lines of numpy, tested, with the
thresholds in one place, and the library is small enough (a few hundred
songs, a few million landmarks) that sorted arrays and searchsorted are all
the database it needs.

How a song gets in
------------------
1. From a preview. When some other source (the Mac, the phone, AirPlay)
   names a song and the ear, listening to the same room, cannot, the wall
   fetches the song's 30 second iTunes preview and learns it. Next time the
   record plays with no other source in the room, the ear knows it.
2. From the room. While a source names a song and the room is loud, the
   ear's own recording of it (the last fifteen seconds of the ring) is
   learnt under the same name, so the library also knows the song the way
   this room and this microphone hear it. The knob `teach_by_ear` turns
   this off. Only fingerprints are kept, never audio.
3. By name. POST /teach/learn {title, artist} fetches the preview by name,
   for a song nobody in the room is playing from a source right now.

Storage: ~/.config/album-art-matrix/taught/library.npz holds metadata and
sorted landmarks in one atomic snapshot. Legacy songs.json/index.npz pairs
migrate on their next change. POST /teach/forget removes one song.
"""
from __future__ import annotations

import json
import copy
import os
import re
import subprocess
import threading
import time
import zipfile

import numpy as np
import requests

RATE = 16000
N_FFT = 1024
HOP = 512                          # 32 ms a frame
FRAME_S = HOP / RATE
MAX_BIN = 256                      # below 4 kHz: what a room and a mic keep
PEAK_T, PEAK_F = 3, 6              # a peak is the loudest in this neighbourhood
MEAN_T, MEAN_F = 12, 16            # ... and stands out from the mean over this one
PROMINENCE = 0.9                   # by this much, in log units
MAX_PER_FRAME = 2                  # peaks kept in one 32 ms frame
BLOCK, MAX_PER_BLOCK = 16, 12      # and in half a second, so a burst cannot flood the index
EDGE = 2                           # frames at either end are window artefacts, not peaks
FANOUT = 5                         # pairs per anchor peak
DT_MIN, DT_MAX = 2, 31             # frames apart: 64 ms to one second
DF_MAX = 48                        # bins apart, so a pair is a local shape
MIN_SCORE = 15                     # aligned landmarks that make a match (the knob's default)
MAX_SONGS = 1500
MIN_PCM_S = 3.0                    # shorter clips are not worth asking about

DIR = os.path.expanduser("~/.config/album-art-matrix/taught")
ITUNES_SEARCH = "https://itunes.apple.com/search"
UA = "album-art-matrix/1.0 (github.com/jke48222/album-art-matrix)"

_BRACKETS = re.compile(r"\s*[\[(][^\])]*[\])]")


def _plain(s: str) -> str:
    return _BRACKETS.sub("", s or "").strip().lower()


# ---- landmarks ----------------------------------------------------------------------
def spectrogram(pcm: np.ndarray) -> np.ndarray:
    """Log magnitude, frames x bins (below MAX_BIN), from 16 kHz int16."""
    x = pcm.astype(np.float32) / 32768.0
    if x.size < N_FFT:
        return np.zeros((0, MAX_BIN), dtype=np.float32)
    n = 1 + (x.size - N_FFT) // HOP
    idx = np.arange(N_FFT)[None, :] + HOP * np.arange(n)[:, None]
    frames = x[idx] * np.hanning(N_FFT).astype(np.float32)[None, :]
    mag = np.abs(np.fft.rfft(frames, axis=1))[:, :MAX_BIN]
    return np.log1p(mag * 200.0).astype(np.float32)


def peaks(spec: np.ndarray) -> np.ndarray:
    """(frame, bin) of the peaks worth keeping: the loudest in their
    neighbourhood, standing well above the mean around them, and never more
    than a couple a frame or a dozen a half-second. The caps are what make
    the same peaks come back through a room: without them a broadband
    moment (a drum, the first frame of a clip) throws off hundreds of
    landmarks that match any other broadband moment at any offset."""
    if spec.shape[0] <= 2 * EDGE + 1:
        return np.zeros((0, 2), dtype=np.int32)
    from numpy.lib.stride_tricks import sliding_window_view
    pt, pf = PEAK_T, PEAK_F
    padded = np.pad(spec, ((pt, pt), (pf, pf)), mode="constant", constant_values=-1.0)
    local_max = sliding_window_view(padded, (2 * pt + 1, 2 * pf + 1)).max(axis=(2, 3))
    mt, mf = MEAN_T, MEAN_F
    padm = np.pad(spec, ((mt, mt), (mf, mf)), mode="edge")
    local_mean = sliding_window_view(padm, (2 * mt + 1, 2 * mf + 1)).mean(axis=(2, 3))
    prom = spec - local_mean
    is_peak = (spec >= local_max) & (prom > PROMINENCE) & (spec > 0.1)
    is_peak[:EDGE, :] = False
    is_peak[-EDGE:, :] = False
    t, f = np.nonzero(is_peak)
    if t.size == 0:
        return np.zeros((0, 2), dtype=np.int32)
    strength = prom[t, f]
    keep = np.zeros(t.size, dtype=bool)
    # the strongest MAX_PER_FRAME in each frame
    order = np.lexsort((-strength, t))
    t_o, seen, count = t[order], -1, 0
    for k in range(t_o.size):
        if t_o[k] != seen:
            seen, count = t_o[k], 0
        if count < MAX_PER_FRAME:
            keep[order[k]] = True
            count += 1
    t, f, strength = t[keep], f[keep], strength[keep]
    # and the strongest MAX_PER_BLOCK in each half second
    block = t // BLOCK
    order = np.lexsort((-strength, block))
    keep = np.zeros(t.size, dtype=bool)
    b_o, seen, count = block[order], -1, 0
    for k in range(b_o.size):
        if b_o[k] != seen:
            seen, count = b_o[k], 0
        if count < MAX_PER_BLOCK:
            keep[order[k]] = True
            count += 1
    t, f = t[keep], f[keep]
    order = np.argsort(t, kind="stable")
    return np.stack([t[order], f[order]], axis=1).astype(np.int32)


def landmarks(pk: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """(hashes uint32, frame of the anchor): every anchor paired with up to
    FANOUT later peaks that are DT_MIN..DT_MAX frames on and within DF_MAX
    bins. hash = f1 << 13 | f2 << 5 | dt, 21 bits."""
    if pk.shape[0] < 2:
        return np.zeros(0, dtype=np.uint32), np.zeros(0, dtype=np.int32)
    t, f = pk[:, 0], pk[:, 1]
    hs, ts = [], []
    n = pk.shape[0]
    for i in range(n):
        got = 0
        j = i + 1
        while j < n and got < FANOUT:
            dt = t[j] - t[i]
            if dt > DT_MAX:
                break
            if dt >= DT_MIN and abs(int(f[j]) - int(f[i])) <= DF_MAX:
                hs.append((int(f[i]) << 13) | (int(f[j]) << 5) | int(dt))
                ts.append(int(t[i]))
                got += 1
            j += 1
    return np.asarray(hs, dtype=np.uint32), np.asarray(ts, dtype=np.int32)


def fingerprint(pcm: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    return landmarks(peaks(spectrogram(pcm)))


def pcm_from_bytes(raw: bytes) -> np.ndarray:
    return np.frombuffer(raw, dtype=np.int16)


# ---- the library ---------------------------------------------------------------------
def _pair_keys(hashes: np.ndarray, times: np.ndarray) -> np.ndarray:
    """(hash, time) pairs as one sortable 64 bit key each."""
    return (np.asarray(hashes).astype(np.uint64) << np.uint64(32)) | \
        np.asarray(times).astype(np.int64).astype(np.uint64) & np.uint64(0xFFFFFFFF)


class TeachBusy(RuntimeError):
    """A preview or room recording already owns the teacher."""


class TeachTooShort(RuntimeError):
    """A preview was found but held too little distinct sound to learn."""


class Match:
    def __init__(self, song: dict, score: int, offset_s: float, song_id: str):
        self.song, self.score, self.offset_s, self.id = song, score, offset_s, song_id


class Library:
    """Songs and their landmarks, sorted by hash so a query is one
    searchsorted per landmark. Everything under `path`."""

    def __init__(self, path: str = DIR, min_score: int = MIN_SCORE):
        self.path = path
        self.min_score = int(min_score)
        self._lock = threading.RLock()
        self._generation = 0
        self.songs: dict[str, dict] = {}
        self._hash = np.zeros(0, dtype=np.uint32)
        self._song = np.zeros(0, dtype=np.int32)     # index into self._ids
        self._time = np.zeros(0, dtype=np.int32)
        self._ids: list[str] = []
        self.last_match: dict | None = None
        self.problem: str | None = None
        self._load_failed = False
        self._load()

    # ---- disk -----------------------------------------------------------------------
    def _load(self):
        # One replacement commits metadata and fingerprints together. Legacy
        # two-file libraries are read once and migrate on their next change.
        snapshot = os.path.join(self.path, "library.npz")
        try:
            if os.path.exists(snapshot):
                with np.load(snapshot, allow_pickle=False) as z:
                    data = json.loads(str(z["metadata"].item()))
                    hashes, songs, times = z["hash"], z["song"], z["time"]
            else:
                with open(os.path.join(self.path, "songs.json")) as fh:
                    data = json.load(fh)
                with np.load(os.path.join(self.path, "index.npz"), allow_pickle=False) as z:
                    hashes, songs, times = z["hash"], z["song"], z["time"]
            metadata, ids = data["songs"], data["ids"]
            if (not isinstance(metadata, dict) or not isinstance(ids, list)
                    or len(ids) != len(set(ids)) or set(ids) != set(metadata)
                    or any(not isinstance(song, dict) or not isinstance(song.get("title"), str)
                           or not isinstance(song.get("artist"), str) for song in metadata.values())
                    or hashes.ndim != 1 or songs.shape != hashes.shape or times.shape != hashes.shape
                    or (songs.size and (songs.min() < 0 or songs.max() >= len(ids)))
                    or (hashes.size > 1 and np.any(hashes[1:] < hashes[:-1]))):
                raise ValueError("inconsistent song library")
            self.songs, self._ids = metadata, ids
            self._hash, self._song, self._time = hashes, songs, times
        except FileNotFoundError:
            if any(os.path.exists(os.path.join(self.path, name))
                   for name in ("library.npz", "songs.json", "index.npz")):
                self._load_failed = True
                self.problem = "The saved song library is incomplete. Restore its missing file before learning more songs."
            return
        except (OSError, ValueError, KeyError, TypeError, EOFError, zipfile.BadZipFile) as exc:
            self._load_failed = True
            # The phone shows this. The exception's own words stay in the log.
            print(f"[teach] could not read the song library: {type(exc).__name__}: {exc}", flush=True)
            self.problem = ("The saved song library could not be read. Repair or restore it "
                            "before adding or removing songs.")

    def _save(self):
        if self._load_failed:
            raise RuntimeError("The saved library could not be read. Repair or restore it before adding or removing songs.")
        try:
            os.makedirs(self.path, exist_ok=True)
            tmp = os.path.join(self.path, "library.tmp.npz")
            with open(tmp, "wb") as fh:
                np.savez(fh, metadata=json.dumps({"songs": self.songs, "ids": self._ids}),
                         hash=self._hash, song=self._song, time=self._time)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, os.path.join(self.path, "library.npz"))
            self.problem = None
        except OSError as exc:
            self.problem = "The wall could not save its song library. Check its free space and try again."
            raise RuntimeError(self.problem) from exc

    def _snapshot(self):
        return (copy.deepcopy(self.songs), list(self._ids), self._hash, self._song,
                self._time, copy.deepcopy(self.last_match), self._generation)

    def _restore(self, snapshot):
        (self.songs, self._ids, self._hash, self._song, self._time,
         self.last_match, self._generation) = snapshot

    @property
    def generation(self):
        # No lock: the render loop reads this every pass (Teacher.observe),
        # and an int read is atomic. learn() holds the lock through a save.
        return self._generation

    # ---- songs ----------------------------------------------------------------------
    @staticmethod
    def song_id(title: str, artist: str) -> str:
        return f"{_plain(artist).split(',')[0]}|{_plain(title)}"

    def has(self, title: str, artist: str, how: str | None = None) -> bool:
        # No lock, for the same reason as generation: a dict get and a list
        # membership test are atomic, and the render loop must never wait
        # for learn() to finish writing the library to the SD card.
        s = self.songs.get(self.song_id(title, artist))
        if s is None:
            return False
        return True if how is None else how in list(s.get("how", []))

    def configure(self, min_score=None):
        if min_score is not None:
            with self._lock:
                self.min_score = max(5, min(60, int(min_score)))

    def learn(self, pcm: np.ndarray, title: str, artist: str, album: str = "",
              art_url: str | None = None, isrc: str | None = None,
              duration_ms: int | None = None, how: str = "preview",
              expected_generation: int | None = None) -> dict | None:
        """Fingerprint `pcm` (16 kHz int16) and file it under the song. A
        song already known gets the new recording added to it, so a
        preview and the room's own hearing can both vouch for it."""
        hs, ts = fingerprint(pcm)
        if hs.size < 20:
            print(f"[teach] {artist} - {title}: too little to learn ({hs.size} landmarks)",
                  flush=True)
            return None
        sid = self.song_id(title, artist)
        with self._lock:
            if expected_generation is not None and expected_generation != self._generation:
                raise RuntimeError("The library changed while learning. Try teaching the song again.")
            snapshot = self._snapshot()
            if sid not in self.songs:
                if len(self.songs) >= MAX_SONGS:
                    self._evict_oldest()
                self._ids.append(sid)
                self.songs[sid] = {"title": title, "artist": artist, "album": album or "",
                                   "art_url": art_url, "isrc": isrc, "duration_ms": duration_ms,
                                   "how": [], "added": int(time.time()), "matched": 0,
                                   "last_matched": None, "landmarks": 0}
            song = self.songs[sid]
            if how not in song["how"]:
                song["how"].append(how)
            for k, v in (("album", album), ("art_url", art_url), ("isrc", isrc),
                         ("duration_ms", duration_ms)):
                if v and not song.get(k):
                    song[k] = v
            idx = self._ids.index(sid)
            # Re-teaching a preview must not inflate a future match's votes,
            # so only this clip's new (hash, time) pairs for this song go in.
            # They are merged into the hash-sorted arrays in place of order:
            # one pass over the library, where sorting all of it again
            # (np.unique over millions of rows) held this lock for a second
            # and took hundreds of MB on a 990 MB Pi.
            mine = self._song == idx
            known = _pair_keys(self._hash[mine], self._time[mine])
            new = np.unique(_pair_keys(hs, ts))
            if known.size:
                new = new[~np.isin(new, known)]
            new_hash = (new >> np.uint64(32)).astype(np.uint32)
            new_time = (new & np.uint64(0xFFFFFFFF)).astype(np.uint32).astype(np.int32)
            at = np.searchsorted(self._hash, new_hash, side="right")
            self._hash = np.insert(self._hash, at, new_hash).astype(np.uint32, copy=False)
            self._song = np.insert(self._song, at, np.full(new.size, idx, dtype=np.int32)).astype(np.int32, copy=False)
            self._time = np.insert(self._time, at, new_time).astype(np.int32, copy=False)
            song["landmarks"] = int(np.count_nonzero(mine)) + int(new.size)
            try:
                self._save()
            except RuntimeError:
                self._restore(snapshot)
                raise
            result = copy.deepcopy(song)
        print(f"[teach] learnt {artist} - {title} from {how}: {hs.size} landmarks "
              f"({len(self.songs)} songs)", flush=True)
        return result

    def _evict_oldest(self):
        oldest = min(self.songs, key=lambda k: self.songs[k].get("last_matched")
                     or self.songs[k].get("added", 0))
        self._drop(oldest)

    def _drop(self, sid: str):
        if sid not in self.songs:
            return
        idx = self._ids.index(sid)
        keep = self._song != idx
        self._hash, self._song, self._time = self._hash[keep], self._song[keep], self._time[keep]
        self._song = np.where(self._song > idx, self._song - 1, self._song).astype(np.int32)
        del self._ids[idx]
        del self.songs[sid]
        if self.last_match and self.last_match.get("id") == sid:
            self.last_match = None

    def forget(self, sid: str) -> bool:
        with self._lock:
            if sid not in self.songs:
                return False
            snapshot = self._snapshot()
            self._drop(sid)
            self._generation += 1
            if self.last_match and self.last_match.get("id") == sid:
                self.last_match = None
            try:
                self._save()
            except RuntimeError:
                self._restore(snapshot)
                raise
        return True

    def clear(self):
        with self._lock:
            snapshot = self._snapshot()
            self.songs, self._ids = {}, []
            self._hash = np.zeros(0, dtype=np.uint32)
            self._song = np.zeros(0, dtype=np.int32)
            self._time = np.zeros(0, dtype=np.int32)
            self.last_match = None
            self._generation += 1
            try:
                self._save()
            except RuntimeError:
                self._restore(snapshot)
                raise

    # ---- asking ----------------------------------------------------------------------
    def query(self, pcm: np.ndarray) -> Match | None:
        """The song the clip is from, if the votes say so."""
        if pcm.size < int(MIN_PCM_S * RATE) or self._hash.size == 0:
            return None
        hs, ts = fingerprint(pcm)
        if hs.size == 0:
            return None
        with self._lock:
            H, S, T = self._hash, self._song, self._time
            ids = list(self._ids)
            generation, threshold = self._generation, self.min_score
        lo = np.searchsorted(H, hs, side="left")
        hi = np.searchsorted(H, hs, side="right")
        n = hi - lo
        if not n.any():
            return None
        # every stored landmark with the same hash votes for (song, offset)
        rep = np.repeat(np.arange(hs.size), n)
        pos = np.concatenate([np.arange(a, b) for a, b in zip(lo, hi) if b > a])
        votes_song = S[pos]
        votes_off = T[pos] - ts[rep]
        key = votes_song.astype(np.int64) * 1_000_000 + (votes_off + 500_000)
        uniq, counts = np.unique(key, return_counts=True)
        best = int(np.argmax(counts))
        score = int(counts[best])
        # the neighbouring offsets are the same alignment, a frame off
        k = uniq[best]
        for d in (-1, 1):
            j = np.searchsorted(uniq, k + d)
            if j < uniq.size and uniq[j] == k + d:
                score += int(counts[j])
        song_idx = int(uniq[best] // 1_000_000)
        offset_frames = int(uniq[best] % 1_000_000) - 500_000
        if score < threshold or song_idx >= len(ids):
            return None
        sid = ids[song_idx]
        with self._lock:
            song = self.songs.get(sid)
            if song is None or generation != self._generation:
                return None
            song["matched"] = song.get("matched", 0) + 1
            song["last_matched"] = int(time.time())
            self.last_match = {"id": sid, "title": song["title"], "artist": song["artist"],
                               "score": score, "at": song["last_matched"]}
            return Match(copy.deepcopy(song), score, offset_frames * FRAME_S, sid)

    # ---- for the phone -------------------------------------------------------------
    def listing(self) -> list[dict]:
        with self._lock:
            out = [{"id": sid, **copy.deepcopy(song)} for sid, song in self.songs.items()]
        out.sort(key=lambda s: s.get("last_matched") or s.get("added") or 0, reverse=True)
        return out

    def status(self) -> dict:
        with self._lock:
            return {"songs": len(self.songs), "landmarks": int(self._hash.size),
                    "min_score": self.min_score, "last_match": copy.deepcopy(self.last_match),
                    "problem": self.problem}


# ---- the teacher ---------------------------------------------------------------------
def pick_preview(results: list, title: str, artist: str) -> dict | None:
    """The result that is this song: the title AND the artist must each
    match, exactly or one inside the other. An artist's other song is not
    a preview of this one (the wall once learnt White Ferrari for Nights)."""
    want_t, want_a = _plain(title), _plain(artist).split(",")[0].split(" & ")[0].strip()
    best, best_score = None, 0
    for x in results:
        if x.get("wrapperType") != "track" or not x.get("previewUrl"):
            continue
        t, a = _plain(x.get("trackName")), _plain(x.get("artistName"))
        if not t or not a:
            continue
        ts = 2 if t == want_t else 1 if (want_t and (want_t in t or t in want_t)) else 0
        sc = 2 if a == want_a else 1 if (want_a and (want_a in a or a in want_a)) else 0
        if ts == 0 or sc == 0:
            continue
        if ts + sc > best_score:
            best, best_score = x, ts + sc
    return best


def itunes_preview(title: str, artist: str) -> dict | None:
    """The best iTunes match for a song by name: preview url, art, length."""
    try:
        r = requests.get(ITUNES_SEARCH, params={"term": f"{artist} {title}", "entity": "song",
                                                "limit": 8}, headers={"User-Agent": UA},
                         timeout=10)
        r.raise_for_status()
        results = r.json().get("results", [])
    except (requests.RequestException, ValueError) as exc:
        print(f"[teach] itunes: {exc}", flush=True)
        raise RuntimeError("The preview catalogue isn't answering. Check the wall's internet connection and try again.") from exc
    best = pick_preview(results, title, artist)
    if best is None:
        return None
    return {"preview": best["previewUrl"], "title": best.get("trackName") or title,
            "artist": best.get("artistName") or artist, "album": best.get("collectionName") or "",
            "art_url": (best.get("artworkUrl100") or "").replace("100x100bb", "600x600bb") or None,
            "duration_ms": best.get("trackTimeMillis")}


def decode_to_pcm(url_or_path: str, seconds: float = 40.0) -> np.ndarray | None:
    """ffmpeg reads the preview (a URL is fine) into 16 kHz mono int16."""
    try:
        result = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-t", str(seconds),
                              "-i", url_or_path, "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"],
                             capture_output=True, timeout=60)
        if result.returncode != 0:
            return None
        out = result.stdout
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"[teach] ffmpeg: {exc}", flush=True)
        return None
    if len(out) < RATE * 2 * 2 or len(out) % 2:
        return None
    return np.frombuffer(out, dtype=np.int16)


class Teacher:
    """Watches the sources beside the ear and teaches the library when the
    ear could not name what the room was playing."""

    MISSES_BEFORE_PREVIEW = 3
    LOUD_BEFORE_EAR_S = 15.0
    NEGATIVE_CACHE_S = 86400.0

    def __init__(self, library: Library, ear, by_ear: bool = True, fetch=None):
        self.library = library
        self.ear = ear
        self.by_ear = bool(by_ear)
        self._fetch = fetch or self._fetch_preview     # (title, artist) -> (pcm, meta) | None
        self._current_id = None                         # the source's song being watched
        self._current_since = 0.0
        self._attempts_at_start = 0
        self._loud_since = None
        self._ear_taught: dict[str, int] = {}
        self._tried: dict[str, float] = {}              # song id -> when a preview was tried
        self._busy = threading.Lock()
        self.learning: str | None = None
        self.problem: str | None = None
        self.last_learned: dict | None = None
        self._state_lock = threading.Lock()
        self._job_generation = 0

    def configure(self, by_ear=None):
        if by_ear is not None:
            self.by_ear = bool(by_ear)

    # ---- the main loop calls this once a poll -----------------------------------------
    def observe(self, now, mono: float | None = None):
        mono = time.monotonic() if mono is None else mono
        ear = self.ear
        if now is None or not now.is_playing or not now.title or not now.artist \
                or (now.track_id or "").startswith("ears:"):
            self._current_id = None
            return
        sid = Library.song_id(now.title, now.artist)
        if sid != self._current_id:
            self._current_id, self._current_since = sid, mono
            self._attempts_at_start = getattr(ear, "attempts", 0)
            self._loud_since = None
        gate = bool(getattr(ear, "gate_open", False))
        if not gate:
            self._loud_since = None
            return
        if self._loud_since is None:
            self._loud_since = mono
        ear_hit = getattr(ear, "_hit", None)
        ear_named_it = ear_hit is not None and Library.song_id(ear_hit.title, ear_hit.artist) == sid
        # 1. the ear keeps missing what the room is playing: learn the preview
        misses = getattr(ear, "attempts", 0) - self._attempts_at_start
        if (ear_hit is None and misses >= self.MISSES_BEFORE_PREVIEW
                and not self.library.has(now.title, now.artist, "preview")
                and mono - self._tried.get(sid, -1e9) > self.NEGATIVE_CACHE_S):
            if self._start(self._learn_preview, now):
                self._tried[sid] = mono
        # 2. the room has been loud with this song for a while: learn the room's hearing
        if (self.by_ear and mono - self._loud_since >= self.LOUD_BEFORE_EAR_S
                and self._ear_taught.get(sid) != self.library.generation and not self.library.has(now.title, now.artist, "ear")
                and (ear_hit is None or ear_named_it)):
            if self._start(self._learn_ear, now):
                self._ear_taught[sid] = self.library.generation

    def _begin(self, title, artist, manual=False):
        if not self._busy.acquire(blocking=False):
            return False
        self._job_generation = self.library.generation
        with self._state_lock:
            self.learning = f"{title} by {artist}"
            if manual:
                self.problem = None
        return True

    def _finish(self, song=None, problem=None, manual=False):
        """problem is shown on the phone only for a song someone asked the
        wall to learn. Learning from the room happens on its own, and its
        failures (a network blip, a preview nobody asked for) are logged,
        not left on the page as a problem nobody made."""
        with self._state_lock:
            if song:
                self.last_learned = {"id": Library.song_id(song["title"], song["artist"]),
                                     "title": song["title"], "artist": song["artist"],
                                     "at": int(time.time())}
            if manual:
                self.problem = problem
            self.learning = None
        self._busy.release()

    def _start(self, fn, now):
        if not self._begin(now.title, now.artist):
            return False
        try:
            threading.Thread(target=self._run, args=(fn, now), name="teach", daemon=True).start()
        except RuntimeError:
            self._finish(problem="The wall could not start learning. Try again.")
            return False
        return True

    def _run(self, fn, now):
        song, problem = None, None
        try:
            song = fn(now)
        except Exception as exc:
            problem = str(exc)
            print(f"[teach] {exc}", flush=True)
        finally:
            self._finish(song, problem)

    def _fetch_preview(self, title, artist):
        meta = itunes_preview(title, artist)
        if meta is None:
            print(f"[teach] no preview on iTunes for {artist} - {title}", flush=True)
            return None
        pcm = decode_to_pcm(meta["preview"])
        if pcm is None:
            raise RuntimeError("The matching preview could not be read. Check the wall's connection and try again.")
        return pcm, meta

    def _learn_preview(self, now):
        got = self._fetch(now.title, now.artist)
        if got is None:
            return
        pcm, meta = got
        return self.library.learn(pcm, meta.get("title") or now.title, meta.get("artist") or now.artist,
                           album=meta.get("album") or now.album, art_url=meta.get("art_url") or now.art_url,
                           duration_ms=meta.get("duration_ms") or now.duration_ms, how="preview",
                           expected_generation=self._job_generation)

    def _learn_ear(self, now):
        ring = getattr(self.ear, "_ring", None)
        if not ring:
            return
        pcm = pcm_from_bytes(b"".join(list(ring)))
        return self.library.learn(pcm, now.title, now.artist, album=now.album, art_url=now.art_url,
                                  duration_ms=now.duration_ms, how="ear",
                                  expected_generation=self._job_generation)

    def learn_named(self, title: str, artist: str) -> dict | None:
        """Manual learning shares admission and status with automatic learning."""
        if not isinstance(title, str) or not isinstance(artist, str):
            raise ValueError("Enter a song title and artist.")
        title, artist = title.strip(), artist.strip()
        if not title or not artist or len(title) > 200 or len(artist) > 200:
            raise ValueError("Enter a song title and artist, up to 200 characters each.")
        if not self._begin(title, artist, manual=True):
            raise TeachBusy("The wall is learning another song. Try again when it finishes.")
        song, problem = None, None
        try:
            got = self._fetch(title, artist)
            if got is None:
                problem = "No matching preview is available. Check the title and artist, or let the wall learn it from the room."
                return None
            pcm, meta = got
            song = self.library.learn(pcm, meta.get("title") or title, meta.get("artist") or artist,
                                      album=meta.get("album") or "", art_url=meta.get("art_url"),
                                      duration_ms=meta.get("duration_ms"), how="told",
                                      expected_generation=self._job_generation)
            if song is None:
                # Found but unusable, which is not "no preview": its own error
                # so the phone (a RuntimeError is a 502 with these words) and
                # the voice say what really happened.
                problem = "The preview did not contain enough distinct sound to learn. Try another recording."
                raise TeachTooShort(problem)
            return song
        except TeachTooShort:
            raise
        except Exception as exc:
            problem = str(exc)
            raise
        finally:
            self._finish(song, problem, manual=True)

    def status(self) -> dict:
        with self._state_lock:
            return {"by_ear": self.by_ear, "learning": self.learning,
                    "problem": self.problem, "last_learned": copy.deepcopy(self.last_learned)}
