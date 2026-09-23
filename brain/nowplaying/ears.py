"""The wall's ears: a microphone on the Pi, and Shazam to name what it hears.

For anything that plays out loud and will not say what it is: a record
player, a speaker fed by SoundCloud, the TV. The microphone is read the
whole time, so the wall always knows how loud the room is. When the room
is louder than the gate it takes the last few seconds off a ring buffer,
turns them into a Shazam signature (shazamio, in Rust) and asks. A hit
stands while the room stays loud, is checked again every so often, which
is how the next track on a record is caught, and is let go once the room
has been quiet for a while, so the wall falls back to its other sources.

A noisy room (a TV on, people talking over the record) is met three ways:
the clip grows on every miss, six seconds then nine then twelve, because
Shazam's match is a count of matching peaks and more seconds is more
peaks; a song once named is kept through misses for a while rather than
dropped at the first one; and a jump in level or a gap counts as a new
sound, so the quick tries start over the moment something changes.

Shazam is the engine the phone app uses, reached through shazamio with no
key and no account. It is not an offered API: the client was reverse
engineered, and Apple could change the service under it. AcoustID, which
this replaced, could not do the job at all: it identifies whole files, not
a few seconds of a room.

Needs on the Pi:  alsa-utils (arecord); pip install shazamio audioop-lts
Microphone:       "auto" picks the first USB capture device `arecord -l`
                  lists; or name one, e.g. "plughw:2,0"
Knobs:            the Hearing group in tuning.py, so they live on the phone
"""
from __future__ import annotations

import asyncio
import collections
import io
import math
import re
import subprocess
import threading
import time
import wave

import numpy as np
import requests

from . import NowPlaying, NowPlayingSource

RATE = 16000                 # Shazam's own working rate; less to read and ship
CHUNK_S = 0.1                # one ring entry
RING_S = 15.0                # the most anyone can ask for in one clip
MAX_CLIP_S = 12.0            # the longest clip a miss escalates to
ESCALATE_S = 3.0             # how much longer each miss makes the next clip
HYSTERESIS_DB = 3.0          # the gate closes this far below where it opened
FLOOR_WINDOW_S = 600.0       # the quiet-room floor is the softest second in this
GAP_S = 1.2                  # a pause at least this long reads as a track gap
ONSET_DB = 8.0               # a jump this far over the last ten seconds is a new sound
ONSET_TAU_S = 10.0           # how far back "the last ten seconds" looks
ITUNES = "https://itunes.apple.com/lookup"
_CARD = re.compile(r"card (\d+): (\S+) \[(.*?)\], device (\d+):")
_BRACKETS = re.compile(r"\s*[\[(][^\])]*[\])]")

# What the phone's Hearing knobs land on. Names match tuning.py's SPECS.
DEFAULTS = {
    "on": True,
    "clip_s": 6.0,        # listen_for
    "gate_db": -52.0,     # room_gate
    "silence_s": 10.0,    # quiet_before_letting_go
    "relisten_s": 25.0,   # listen_again_every
    "retry_s": 4.0,       # retry_after_miss
    "keep_s": 180.0,      # keep_through_noise
    "gain": 100,          # mic_gain
    "agc": False,         # mic_auto_gain
}


def tools_present() -> tuple[bool, str | None]:
    """(ok, why not). arecord reads the microphone; shazamio names the clip."""
    try:
        subprocess.run(["arecord", "--version"], capture_output=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return False, "arecord is missing on the wall (apt install alsa-utils)"
    try:
        import shazamio  # noqa: F401  (pydub inside it needs audioop-lts on 3.13)
    except Exception as exc:  # ImportError, or the audioop hole on Python 3.13
        return False, f"shazamio is not installed on the wall ({exc.__class__.__name__}); pip install shazamio audioop-lts"
    return True, None


def find_mic():
    """(device, name, card) of the first USB capture device, else the first
    one at all, else None. `arecord -l` is the list ALSA keeps."""
    try:
        out = subprocess.run(["arecord", "-l"], capture_output=True, text=True,
                             timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    cards = [(f"plughw:{c},{d}", name, int(c)) for c, _, name, d in _CARD.findall(out)]
    if not cards:
        return None
    usb = [c for c in cards if "usb" in c[1].lower()]
    return (usb or cards)[0]


def _db(chunk: bytes) -> float:
    x = np.frombuffer(chunk, dtype=np.int16).astype(np.float32)
    if not len(x):
        return -120.0
    rms = math.sqrt(float(np.mean(x * x))) / 32768.0
    return 20.0 * math.log10(max(rms, 1e-6))


def _wav(pcm: bytes) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)
    return buf.getvalue()


def _plain(s: str) -> str:
    """'L'AMOUR DE MA VIE [OVER NOW EXTENDED EDIT]' and the album cut are one
    song to the person in the room; the wall should not flip between them."""
    return _BRACKETS.sub("", s or "").split(" - ")[0].strip().lower()


def _same_song(a: NowPlaying, b: NowPlaying) -> bool:
    return _plain(a.title) == _plain(b.title) and \
        _plain(a.artist).split(",")[0].split("&")[0].strip() == \
        _plain(b.artist).split(",")[0].split("&")[0].strip()


class EarsSource(NowPlayingSource):
    name = "ears"

    def __init__(self, device: str = "auto", on_change=None):
        self.device = (device or "").strip() or "auto"
        self._on_change = on_change     # the brain's nudge: poll now, not next tick
        self.knocks = None              # knock.KnockEar, when the wall's switch is on
        self.library = None             # teach.Library: the wall's own songs, asked first
        self.teacher = None             # teach.Teacher: fills the library from the sources
        self.voice = None               # voice.Voice: the wake word and what follows it
        self.settings = dict(DEFAULTS)
        self._lock = threading.Lock()

        # the room, as the capture thread hears it
        self._ring = collections.deque(maxlen=int(RING_S / CHUNK_S))
        self._recent = collections.deque(maxlen=int(1.0 / CHUNK_S))   # last second
        self._seconds = collections.deque(maxlen=int(FLOOR_WINDOW_S))  # 1 s levels
        self._sec_acc, self._sec_at = [], time.monotonic()
        self.level_db = None        # the last second
        self.floor_db = None        # the softest second lately
        self.gate_open = False
        self.loud_since = None
        self.quiet_since = None
        self.gap_at = None          # when sound came back after a gap, or jumped up
        self._slow_pw = None        # the room's power, averaged over ONSET_TAU_S
        self.mic_name = None
        self.mic_card = None
        self.capturing = False
        self._proc = None

        # what the ear has made of it
        self._hit = None            # NowPlaying, without progress
        self._hit_key = None
        self._offset = None         # seconds into the song at clip_start
        self._clip_start = None     # monotonic when the matched clip began
        self._heard_at = None       # the last time Shazam agreed about the song
        self._last_try = None
        self._misses = 0            # in a row, since the last hit or new sound
        self._pending = None        # heard once with no catalogue record behind it; waits for a second hearing
        self.last_heard = None      # the ear's last song on the wall, and how it ended
        self._named = []            # the last few songs named, newest first
        self.window_s = float(DEFAULTS["clip_s"])
        self.attempts = 0
        self.matches = 0
        self.state = "off"
        self.problem = None
        self._tools_ok, self._tools_why = tools_present()
        self._shazam = None
        self._loop = None
        self._itunes = {}           # isrc -> (duration_ms, art_url)

        threading.Thread(target=self._capture_loop, daemon=True, name="ears-mic").start()
        threading.Thread(target=self._think_loop, daemon=True, name="ears").start()

    # ---- configuration, live -------------------------------------------
    @property
    def configured(self) -> bool:
        return bool(self.settings["on"])

    def configure(self, device=None, **settings):
        """Knobs from tuning, the device from services. Applied at once."""
        if device is not None:
            device = device.strip() or "auto"
            if device != self.device:
                self.device = device
                self._stop_capture()          # the capture loop reopens it
        mixer = False
        for k, v in settings.items():
            if k not in DEFAULTS or v is None:
                continue
            v = bool(v) if isinstance(DEFAULTS[k], bool) else type(DEFAULTS[k])(v)
            if self.settings[k] != v:
                self.settings[k] = v
                mixer = mixer or k in ("gain", "agc")
        if mixer:
            self._set_mixer()
        if not self.settings["on"]:
            self._let_go("switched off")

    def _set_mixer(self):
        """The microphone's own gain and its automatic gain control. Off is
        the honest setting for a gate: with AGC on, a quiet room is slowly
        turned up until it looks loud."""
        card = self.mic_card
        if card is None:
            return
        for control, value in (("Mic", f"{int(self.settings['gain'])}%"),
                               ("Auto Gain Control", "on" if self.settings["agc"] else "off")):
            try:   # other microphones name their controls differently; not fatal
                subprocess.run(["amixer", "-q", "-c", str(card), "sset", control, value],
                               capture_output=True, timeout=5)
            except (OSError, subprocess.SubprocessError):
                pass

    # ---- status ----------------------------------------------------------
    def status(self) -> dict:
        with self._lock:
            hit, heard_at = self._hit, self._heard_at
            offset, clip_start = self._offset, self._clip_start
            pend, last, named = self._pending, self.last_heard, list(self._named)
        now = time.monotonic()
        s = self.settings

        def song(t):
            return {"title": t.title, "artist": t.artist, "album": t.album}

        listening = bool(s["on"] and self._tools_ok and self.capturing)
        return {
            "engine": "shazam",
            "on": bool(s["on"]),
            "tools": self._tools_ok,
            "device": self.device,
            "mic": self.mic_name,
            "listening": listening,
            "state": self.state,
            "level_db": None if self.level_db is None else round(self.level_db, 1),
            "floor_db": None if self.floor_db is None else round(self.floor_db, 1),
            "gate_db": float(s["gate_db"]),
            "gate_open": bool(self.gate_open),
            "loud_s": (None if not self.gate_open or self.loud_since is None
                       else int(now - self.loud_since)),
            "quiet_s": (None if self.gate_open or self.quiet_since is None
                        else int(now - self.quiet_since)),
            "window_s": self.window_s,
            "misses": self._misses,
            "heard_s": None if heard_at is None else int(now - heard_at),
            "heard": (None if hit is None else
                      {"title": hit.title, "artist": hit.artist, "album": hit.album,
                       "at_s": (None if offset is None else
                                int(offset + now - clip_start)),
                       "length_s": (None if not hit.duration_ms
                                    else int(hit.duration_ms / 1000))}),
            # heard once, with nothing in the catalogue behind it: not on the
            # wall yet, waiting to be heard again
            "pending": (None if pend is None else
                        {**song(pend["track"]), "heard_s": int(now - pend["at"])}),
            # the last song the ear put on the wall, and how that ended
            "last_heard": (None if last is None else
                           {**song(last["track"]),
                            "named_s": int(now - last["named_at"]),
                            "ended_s": (None if last["ended_at"] is None
                                        else int(now - last["ended_at"])),
                            "why": last["why"]}),
            "recent": [{**song(e["track"]), "ago_s": int(now - e["at"]),
                        "times": e["times"]} for e in named],
            "attempts": self.attempts,
            "matches": self.matches,
            # the switch, when the wall has one: counts and the last thing heard
            "knock": self.knocks.status() if self.knocks is not None else None,
            # the wall's own songs, and whether one is being learnt right now
            "taught": self.library.status() if self.library is not None else None,
            "teacher": self.teacher.status() if self.teacher is not None else None,
            "settings": {k: s[k] for k in ("clip_s", "silence_s", "relisten_s",
                                           "retry_s", "keep_s", "gain", "agc")},
            "problem": self.problem or (None if self._tools_ok else self._tools_why),
        }

    # ---- the microphone ---------------------------------------------------
    def _open_mic(self):
        if self.device != "auto":
            m = re.search(r"(\d+)", self.device)
            self.mic_card = int(m.group(1)) if m else None
            self.mic_name = self.device
            return self.device
        found = find_mic()
        if not found:
            self.mic_name, self.mic_card = None, None
            return None
        dev, self.mic_name, self.mic_card = found
        return dev

    def _stop_capture(self):
        p = self._proc
        if p is not None:
            try:
                p.kill()
            except OSError:
                pass

    def _capture_loop(self):
        """Read the room, 100 ms at a time, forever. The ring keeps the last
        RING_S seconds; the gate and the floor are kept here too, so the
        thinking thread only ever reads numbers."""
        chunk_bytes = int(RATE * CHUNK_S) * 2
        while True:
            if not self._tools_ok:
                self._tools_ok, self._tools_why = tools_present()
                time.sleep(30)
                continue
            dev = self._open_mic()
            if dev is None:
                self.state, self.problem = "no_mic", "no microphone found"
                self.capturing = False
                time.sleep(10)
                continue
            self._set_mixer()
            try:
                self._proc = subprocess.Popen(
                    ["arecord", "-q", "-D", dev, "-f", "S16_LE", "-r", str(RATE),
                     "-c", "1", "-t", "raw", "-"],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
            except OSError as exc:
                self.problem = f"arecord: {exc}"
                time.sleep(10)
                continue
            self.capturing = True
            self.problem = None
            print(f"[ears] listening on {self.mic_name} ({dev})")
            try:
                while True:
                    # a pipe hands back what it has, not what was asked for
                    chunk = b""
                    while len(chunk) < chunk_bytes:
                        part = self._proc.stdout.read(chunk_bytes - len(chunk))
                        if not part:
                            break
                        chunk += part
                    if len(chunk) < chunk_bytes:
                        break
                    self._hear(chunk)
            finally:
                err = b""
                try:
                    err = self._proc.stderr.read(400)
                except Exception:
                    pass
                self._proc = None
                self.capturing = False
                self.gate_open = False
                self.problem = (err.decode(errors="replace").strip().splitlines() or
                                ["microphone stopped answering"])[-1][:160]
                print(f"[ears] microphone gone: {self.problem}; looking again")
            time.sleep(3)

    def _hear(self, chunk: bytes):
        db = _db(chunk)
        self._ring.append(chunk)
        self._recent.append(db)
        # the last second, as one number
        pw = np.mean([10 ** (d / 10.0) for d in self._recent])
        self.level_db = 10.0 * math.log10(max(pw, 1e-12))
        now = time.monotonic()
        self._sec_acc.append(db)
        if now - self._sec_at >= 1.0:
            sec = 10.0 * math.log10(max(np.mean([10 ** (d / 10.0) for d in self._sec_acc]), 1e-12))
            self._seconds.append(sec)
            self._sec_acc, self._sec_at = [], now
            self.floor_db = min(self._seconds)
        gate = float(self.settings["gate_db"])
        if self.gate_open:
            if self.level_db < gate - HYSTERESIS_DB:
                self.gate_open, self.quiet_since = False, now
        elif self.level_db > gate:
            was_quiet = self.quiet_since is not None and now - self.quiet_since >= GAP_S
            self.gate_open, self.loud_since = True, now
            if was_quiet:
                self.gap_at = now
        # A room whose floor sits above the gate never closes it, so a gap
        # can never announce a new record. A jump in level does instead: the
        # needle dropping is many dB over the ten seconds before it.
        slow = self._slow_pw
        if slow is not None:
            jump = self.level_db - 10.0 * math.log10(max(slow, 1e-12))
            if jump >= ONSET_DB and (self.gap_at is None or
                                     now - self.gap_at >= float(self.settings["clip_s"])):
                self.gap_at = now
        alpha = CHUNK_S / ONSET_TAU_S
        self._slow_pw = pw if slow is None else slow + alpha * (pw - slow)
        # the switch: knocks and whistles, on the same chunk, same thread
        if self.knocks is not None:
            try:
                self.knocks.feed(chunk, self.gate_open, now)
            except Exception as exc:
                print(f"[ears] knock: {exc}", flush=True)
        # the voice: the wake word, then the words after it
        if self.voice is not None:
            try:
                self.voice.feed(chunk, self.level_db, self.floor_db, now)
            except Exception as exc:
                print(f"[ears] voice: {exc}", flush=True)

    # ---- thinking -------------------------------------------------------------
    def _think_loop(self):
        while True:
            try:
                self._think()
            except Exception as exc:
                self.problem = str(exc)[:160]
                print(f"[ears] {exc}")
                time.sleep(5)
            time.sleep(0.2)

    def _think(self):
        s = self.settings
        now = time.monotonic()
        if not s["on"]:
            self.state = "off"
            return
        if not (self._tools_ok and self.capturing):
            self.state = "no_mic" if self._tools_ok else "no_tools"
            return
        with self._lock:
            hit, heard_at = self._hit, self._heard_at
        if not self.gate_open:
            if self.quiet_since is not None \
                    and now - self.quiet_since >= float(s["silence_s"]):
                if hit is not None:
                    self._let_go(f"quiet for {int(s['silence_s'])} s")
                    hit = None
                self._pending = None
            self.state = "heard" if hit is not None else "quiet"
            return
        # Sound coming back after a gap, or jumping up, is a new event: the
        # quick tries and the short clip start over.
        if self.gap_at is not None and self._last_try is not None \
                and self.gap_at > self._last_try:
            self._misses = 0
        # A song is kept through misses while the room stays loud (a TV, a
        # conversation over the record), but not forever.
        if hit is not None and heard_at is not None \
                and now - heard_at >= float(s["keep_s"]):
            self._let_go(f"nothing named for {int(s['keep_s'])} s")
            hit = None
        # A faint hearing that never came back is forgotten.
        if self._pending is not None and \
                now - self._pending["at"] > max(60.0, 2 * float(s["relisten_s"])):
            self._pending = None
        # Every miss buys the next try a longer clip: more seconds is more
        # matching peaks, which is what a noisy room needs.
        win = min(MAX_CLIP_S, RING_S, float(s["clip_s"]) + ESCALATE_S * min(2, self._misses))
        self.window_s = win
        loud_for = now - (self.loud_since or now)
        if loud_for < win:
            self.state = self._idle_state()
            return                       # still gathering the clip
        if hit is None:
            gap = float(s["retry_s"]) * (1 if self._misses < 3 else 3)
            due = self._last_try is None or now - self._last_try >= gap
        else:
            fresh = self.gap_at is not None and self.gap_at > (self._last_try or 0) \
                and now - self.gap_at >= win
            due = fresh or now - self._last_try >= float(s["relisten_s"])
        if not due:
            self.state = self._idle_state()
            return
        self.state = "asking"
        n = int(win / CHUNK_S)
        clip = b"".join(list(self._ring)[-n:])
        clip_start = now - win
        self._last_try = now
        self.attempts += 1
        found = self._ask(clip)
        if found is None:
            self._misses += 1
            self.state = self._idle_state()
            return
        track, key, offset, isrc, aligned = found
        self._misses = 0
        self.matches += 1
        with self._lock:
            held, held_key = self._hit, self._hit_key
        if held is not None and key == held_key:
            # the same recording again: the song is confirmed and the clock
            # re-synced to where Shazam says the record is now
            with self._lock:
                self._offset, self._clip_start = offset, clip_start
                self._heard_at = time.monotonic()
        elif held is not None and _same_song(held, track):
            # another cut of the same song (an extended edit, a single):
            # the person in the room hears one song, so the wall keeps one
            with self._lock:
                self._heard_at = time.monotonic()
        elif held is None and not isrc and not self._heard_before(track, key):
            # No catalogue record behind it (no ISRC): the kind of match a
            # noisy room produces out of nothing, an obscure upload matched
            # to a TV. It is shown as faint and has to be heard twice before
            # it goes on the wall.
            self._pending = dict(track=track, key=key, at=time.monotonic())
            print(f"[ears] heard faintly {track.artist} — {track.title} "
                  f"({aligned} aligned, no catalogue record); waiting to hear it again")
            self.state = "faint"
            return
        else:
            self._pending = None
            if not key.startswith("taught:"):        # the library dressed its own
                track = self._dress(track, isrc)
            with self._lock:
                self._hit, self._hit_key = track, key
                self._offset, self._clip_start = offset, clip_start
                self._heard_at = time.monotonic()
                self.last_heard = dict(track=track, named_at=self._heard_at,
                                       ended_at=None, why=None)
                top = self._named[0] if self._named else None
                if top is not None and _same_song(top["track"], track):
                    top["times"] += 1
                    top["at"] = self._heard_at
                else:
                    self._named.insert(0, dict(track=track, at=self._heard_at, times=1))
                    del self._named[6:]
            where = "" if offset is None else f" ({int(offset)} s in)"
            print(f"[ears] heard {track.artist} — {track.title}{where}")
            self._changed()
        self.state = "heard"

    def _heard_before(self, track, key) -> bool:
        """Is this the faint hearing coming back? Same recording or same song."""
        p = self._pending
        return p is not None and (p["key"] == key or _same_song(p["track"], track))

    def _idle_state(self) -> str:
        if self._hit is not None:
            return "heard"
        return "faint" if self._pending is not None else "listening"

    def _let_go(self, why: str):
        with self._lock:
            had = self._hit
            self._hit = self._hit_key = None
            self._offset = self._clip_start = None
            if had is not None and self.last_heard is not None:
                self.last_heard["ended_at"] = time.monotonic()
                self.last_heard["why"] = why
        self._misses = 0
        if had is not None:
            print(f"[ears] let go of {had.artist} — {had.title}: {why}")
            self._changed()

    def _changed(self):
        if self._on_change is not None:
            try:
                self._on_change()
            except Exception as exc:
                print(f"[ears] on_change: {exc}")

    # ---- Shazam --------------------------------------------------------------
    def _ask(self, pcm: bytes):
        """(NowPlaying, shazam key, offset seconds, isrc, aligned matches)
        or None. Runs on the thinking thread; one event loop and one client
        live there for as long as they keep working.

        The wall's own library goes first: a few milliseconds, nothing sent
        anywhere, and the songs Shazam does not know. Its answer carries no
        offset (a preview is a slice from somewhere in the song) and an isrc
        stand-in, so the faint rule, meant for catalogue-less Shazam
        guesses, leaves a taught song alone."""
        lib = self.library
        if lib is not None:
            try:
                m = lib.query(np.frombuffer(pcm, dtype=np.int16))
            except Exception as exc:
                m = None
                print(f"[ears] library: {exc}", flush=True)
            if m is not None:
                s = m.song
                print(f"[ears] the library knows it: {s['artist']} - {s['title']} "
                      f"({m.score} aligned)", flush=True)
                self.problem = None
                return (NowPlaying(track_id=f"ears:taught:{m.id}", title=s["title"],
                                   artist=s["artist"], album=s.get("album") or "?",
                                   art_url=s.get("art_url"), progress_ms=None,
                                   duration_ms=s.get("duration_ms"), is_playing=True),
                        f"taught:{m.id}", None, s.get("isrc") or "taught", m.score)
        from shazamio import Shazam
        try:
            if self._loop is None:
                self._loop = asyncio.new_event_loop()
                self._shazam = Shazam()
            out = self._loop.run_until_complete(
                asyncio.wait_for(self._shazam.recognize(_wav(pcm)), timeout=15))
            self.problem = None
        except Exception as exc:
            self.problem = f"shazam: {str(exc)[:120]}"
            print(f"[ears] shazam: {exc}")
            self._shazam = None
            if self._loop is not None:
                try:
                    self._loop.close()
                except Exception:
                    pass
            self._loop = None
            return None
        track = out.get("track") or {}
        if not track.get("title"):
            return None
        meta = [m for sec in track.get("sections", []) for m in sec.get("metadata", [])]
        album = next((m.get("text") for m in meta if m.get("title") == "Album"), "") or ""
        images = track.get("images") or {}
        art = images.get("coverarthq") or images.get("coverart")
        matches = out.get("matches") or []
        offset = matches[0].get("offset") if matches else None
        key = str(track.get("key") or track["title"])
        return (NowPlaying(
            track_id=f"ears:{key}", title=track["title"],
            artist=track.get("subtitle") or "?", album=album or "?", art_url=art,
            progress_ms=None, duration_ms=None, is_playing=True,
        ), key, (float(offset) if offset is not None else None), track.get("isrc"),
            len(matches))

    def _dress(self, track: NowPlaying, isrc) -> NowPlaying:
        """Shazam says what; the iTunes catalogue, looked up by the
        recording's ISRC, says how long it is and has the bigger sleeve. One
        request per new song, remembered; the wall does without on a miss."""
        if not isrc:
            return track
        if isrc not in self._itunes:
            dur, art = None, None
            try:
                r = requests.get(ITUNES, params={"isrc": isrc, "entity": "song"}, timeout=6)
                hit = next((x for x in r.json().get("results", [])
                            if x.get("wrapperType") == "track"), None)
                if hit:
                    dur = hit.get("trackTimeMillis")
                    art = (hit.get("artworkUrl100") or "").replace("100x100bb", "600x600bb") or None
            except Exception as exc:
                print(f"[ears] itunes: {exc}")
            if len(self._itunes) > 200:
                self._itunes.clear()
            self._itunes[isrc] = (dur, art)
        dur, art = self._itunes[isrc]
        if dur is None and art is None:
            return track
        return NowPlaying(**{**track.__dict__, "duration_ms": dur or None,
                             "art_url": art or track.art_url})

    # ---- the answer ----------------------------------------------------------
    def get_current(self):
        with self._lock:
            hit, offset, start = self._hit, self._offset, self._clip_start
            heard_at = self._heard_at
        if hit is None:
            return None
        # An outsider's answer: the clock is a guess, and heard_at says how
        # fresh the evidence is, so the chain can tell a song still playing
        # from a hit kept through silence after the pause button.
        if offset is None:
            return NowPlaying(**{**hit.__dict__, "clock": "approx", "heard_at": heard_at})
        # Shazam says where in the song the clip began; the clock has run
        # since, so the wall knows where the record is, not just what it is.
        at = int((offset + time.monotonic() - start) * 1000)
        if hit.duration_ms:
            at = min(at, hit.duration_ms)
        return NowPlaying(**{**hit.__dict__, "progress_ms": at,
                             "clock": "approx", "heard_at": heard_at})
