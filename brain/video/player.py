"""The video player: a link in, frames out, nothing on the main loop.

The main loop asks one question, frame_at(), and gets a picture or None.
Everything slow happens on the player's own threads: resolving the link,
fetching the sound for the phone, and an ffmpeg that decodes the picture and
scales it to the panel, writing raw frames down a pipe. The reader keeps a
window of frames around the playhead (two minutes ahead, a little behind)
and lets ffmpeg block on the pipe beyond that, so a two-hour video costs no
more memory than a two-minute one.

Two clocks. With the sound on the phone, the phone's player is the clock:
it says where it is every second and the wall shows the frame for that
moment, so a pause, a scrub and any drift all follow the phone. With no
sound, the wall keeps its own clock.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import threading
import time

import requests
from PIL import Image, ImageDraw

from . import Media, ResolveError, direct, youtube

FPS = 15
AHEAD_S = 120           # decode this far past the playhead, then wait
BEHIND_S = 20           # keep this much behind it, for a scrub back
READY_S = 2.0           # picture buffered before the wall says "ready"
CHUNK = 1_000_000       # the sound comes down in ranged pieces this big
AUDIO_DIR = ("/dev/shm/album-art-matrix" if os.path.isdir("/dev/shm")
             else os.path.join(tempfile.gettempdir(), "album-art-matrix"))
_LOADING_INK = (232, 176, 75)


class VideoPlayer:
    def __init__(self, size: int, dirty: threading.Event, on_media=None):
        self.size = size
        self._dirty = dirty            # wakes the main loop
        self._on_media = on_media      # told the title once the link resolves
        self._lock = threading.Lock()
        self._gen = 0                  # every start or stop bumps it; old threads see it and leave
        self._proc = None
        self._blank()

    def _blank(self):
        self.status = "idle"           # idle fetching ready playing paused ended error
        self.error = None
        self.media = None
        self.url = ""
        self.sound = False
        self.loop = False
        self.phone_clock = False
        self._frames = {}              # frame index -> raw rgb
        self._first = 0                # lowest index still kept
        self._last = -1                # highest index decoded
        self._eof = None               # index count when ffmpeg finished cleanly
        self._clock = (0.0, time.monotonic(), False)     # (seconds, at, playing)
        self._shown = None             # the last picture handed out, for "same as before"
        self.audio_path = None
        self.audio_ready = False
        self.audio_got = 0
        self.audio_total = None

    # ---- what the API asks ------------------------------------------------
    @property
    def busy(self) -> bool:
        """A video is on, or on its way: the main loop skips the slow
        now-playing poll while this is true, so the picture never stutters
        for it."""
        return self.status in ("fetching", "ready", "playing", "paused")

    def public(self) -> dict:
        m = self.media
        with self._lock:
            head = self._playhead()
            last = self._last
        return {
            "status": self.status, "error": self.error, "url": self.url,
            "title": m.title if m else None, "author": m.author if m else None,
            "duration_s": m.duration_s if m else None,
            "position_s": round(head, 2),
            "buffered_s": round(max(0.0, (last + 1) / FPS - head), 1),
            "note": m.video_note if m else None,
            "sound": bool(m and m.audio_url and self.sound),
            "sound_ready": self.audio_ready,
            "sound_got": self.audio_got, "sound_total": self.audio_total,
            "loop": self.loop, "clock": "phone" if self.phone_clock else "wall",
        }

    # ---- start and stop -----------------------------------------------------
    def start(self, url: str, sound: bool = True, loop: bool = False):
        self.stop()
        with self._lock:
            self._gen += 1
            gen = self._gen
            self._blank()
            self.status, self.url, self.sound, self.loop = "fetching", url, sound, loop
        threading.Thread(target=self._run, args=(gen, url), daemon=True,
                         name="video-fetch").start()

    def stop(self, error: str | None = None):
        """Over. An error given here outlives the stop, so the phone can
        still read why the video never came."""
        with self._lock:
            self._gen += 1
            proc, path = self._proc, self.audio_path
            self._proc = None
            self._blank()
            self.error = error
        self._kill(proc)
        if path:
            try:
                os.remove(path)
            except OSError:
                pass
        self._dirty.set()

    def _current(self, gen) -> bool:
        return gen == self._gen

    @staticmethod
    def _kill(proc):
        if proc is None:
            return
        try:
            proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass

    def _fail(self, gen, why: str):
        with self._lock:
            if not self._current(gen):
                return
            self.status, self.error = "error", why[:200]
        print(f"[video] {why}")
        self._dirty.set()

    # ---- the fetch ----------------------------------------------------------
    def _run(self, gen, url):
        try:
            media = youtube.resolve(url) if youtube.video_id(url) else direct.resolve(url)
        except ResolveError as exc:
            self._fail(gen, str(exc))
            return
        except Exception as exc:
            self._fail(gen, f"could not read that link: {exc}")
            return
        with self._lock:
            if not self._current(gen):
                return
            self.media = media
            want_sound = self.sound and bool(media.audio_url)
            self.sound = want_sound
        print(f"[video] {media.title!r}: {media.video_note}, "
              f"{media.duration_s:.0f} s, sound {'yes' if want_sound else 'no'}")
        if self._on_media:
            try:
                self._on_media(media)
            except Exception:
                pass
        if want_sound:
            threading.Thread(target=self._fetch_audio, args=(gen, media), daemon=True,
                             name="video-audio").start()
        self._decode(gen, media, 0.0)
        # ready when a couple of seconds of picture are in and the sound is whole
        while self._current(gen):
            with self._lock:
                enough = self._last + 1 >= READY_S * FPS or self._eof is not None
                sound_ok = not self.sound or self.audio_ready
                if enough and sound_ok and self.status == "fetching":
                    if self.sound:
                        self.status = "ready"        # the phone starts the clock
                    else:
                        self.status = "playing"      # the wall's own clock, from now
                        self._clock = (0.0, time.monotonic(), True)
                    self._dirty.set()
                    return
                if self.status == "error":
                    return
            time.sleep(0.1)

    def _fetch_audio(self, gen, media: Media):
        os.makedirs(AUDIO_DIR, exist_ok=True)
        path = os.path.join(AUDIO_DIR, f"audio-{gen}.m4a")
        with self._lock:
            self.audio_path, self.audio_total = path, media.audio_bytes
        try:
            if media.audio_transcode:
                cmd = ["ffmpeg", "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                       "-user_agent", media.headers.get("User-Agent", "album-art-matrix"),
                       "-i", media.audio_url, "-vn", "-c:a", "aac", "-b:a", "96k",
                       "-movflags", "+faststart", path]
                if shutil.which("nice"):
                    cmd = ["nice", "-n", "10"] + cmd
                out = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
                if out.returncode != 0:
                    raise RuntimeError((out.stderr or "ffmpeg failed").strip().splitlines()[-1][:120])
            elif media.audio_bytes:
                # In pieces, each asked for by byte range: YouTube serves a
                # ranged megabyte at full speed and a whole file at a crawl
                # (3 MB/s against 32 KB/s, measured from the wall).
                total = media.audio_bytes
                with requests.Session() as sess, open(path, "wb") as fh:
                    sess.headers.update(media.headers)
                    got = 0
                    while got < total:
                        if not self._current(gen):
                            return
                        end = min(total, got + CHUNK) - 1
                        r = sess.get(media.audio_url, headers={"Range": f"bytes={got}-{end}"},
                                     timeout=30)
                        if r.status_code not in (200, 206) or not r.content:
                            raise RuntimeError(f"HTTP {r.status_code} at byte {got}")
                        fh.write(r.content)
                        got += len(r.content)
                        self.audio_got = got
            else:
                with requests.get(media.audio_url, headers=media.headers, stream=True,
                                  timeout=30) as r:
                    r.raise_for_status()
                    if self.audio_total is None and r.headers.get("Content-Length"):
                        self.audio_total = int(r.headers["Content-Length"])
                    with open(path, "wb") as fh:
                        for chunk in r.iter_content(262144):
                            if not self._current(gen):
                                return
                            fh.write(chunk)
                            self.audio_got += len(chunk)
            with self._lock:
                if self._current(gen):
                    self.audio_got = os.path.getsize(path)
                    self.audio_total = self.audio_got
                    self.audio_ready = True
        except Exception as exc:
            self._fail(gen, f"the sound did not come: {exc}")

    # ---- the picture --------------------------------------------------------
    def _decode(self, gen, media: Media, from_s: float):
        """Start (or restart) ffmpeg at from_s. Called under no lock."""
        with self._lock:
            old, self._proc = self._proc, None
            self._frames.clear()
            self._first = self._last = int(round(from_s * FPS))
            self._last -= 1
            self._eof = None
        self._kill(old)
        if not shutil.which("ffmpeg"):
            self._fail(gen, "ffmpeg is missing on the wall")
            return
        s = self.size
        cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
               "-threads", "1", "-filter_threads", "1",
               "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
        if media.headers.get("User-Agent"):
            cmd += ["-user_agent", media.headers["User-Agent"]]
        if from_s > 0.05:
            cmd += ["-ss", f"{from_s:.3f}"]
        cmd += ["-i", media.video_url, "-an",
                "-vf", f"crop=min(iw\\,ih):min(iw\\,ih),scale={s}:{s}:flags=area,unsharp=3:3:0.5",
                "-r", str(FPS), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
        if shutil.which("nice"):
            cmd = ["nice", "-n", "10"] + cmd
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    bufsize=0)
        except OSError as exc:
            self._fail(gen, f"ffmpeg would not start: {exc}")
            return
        with self._lock:
            if not self._current(gen):
                self._kill(proc)
                return
            self._proc = proc
        threading.Thread(target=self._read, args=(gen, proc, self._first), daemon=True,
                         name="video-decode").start()

    def _read(self, gen, proc, index):
        n = self.size * self.size * 3
        keep_behind = BEHIND_S * FPS
        ahead = AHEAD_S * FPS
        buf = bytearray()
        try:
            while self._current(gen) and proc is self._proc:
                # far enough ahead: let ffmpeg block on the pipe for a while
                with self._lock:
                    head_i = int(self._playhead() * FPS)
                if index - head_i > ahead:
                    time.sleep(0.25)
                    continue
                chunk = proc.stdout.read(n - len(buf))
                if not chunk:
                    break
                buf += chunk
                if len(buf) < n:
                    continue
                frame, buf = bytes(buf), bytearray()
                with self._lock:
                    if not self._current(gen) or proc is not self._proc:
                        return
                    self._frames[index] = frame
                    self._last = index
                    floor = head_i - keep_behind
                    while self._first < floor and self._first in self._frames:
                        del self._frames[self._first]
                        self._first += 1
                    self._first = max(self._first, min(self._frames) if self._frames else index)
                index += 1
                if index == 1 or index % FPS == 0:
                    self._dirty.set()
        finally:
            rc = None
            try:
                proc.stdout.close()
            except Exception:
                pass
            if proc is self._proc and self._current(gen):
                err = b""
                try:
                    err = proc.stderr.read()
                    rc = proc.wait(timeout=10)
                except Exception:
                    pass
                with self._lock:
                    if proc is self._proc and self._current(gen):
                        self._eof = index
                        self._proc = None
                if rc not in (0, None) and index <= self._first + 1:
                    tail = err.decode(errors="replace").strip().splitlines()
                    self._fail(gen, "the picture would not decode"
                               + (f": {tail[-1][:100]}" if tail else ""))
                self._dirty.set()

    # ---- the clock ----------------------------------------------------------
    def _playhead(self) -> float:
        """Seconds into the video now. Under the lock."""
        t, at, playing = self._clock
        if playing:
            t += time.monotonic() - at
        if self.media and self.media.duration_s > 0:
            t = min(t, self.media.duration_s)
        return max(0.0, t)

    def _ensure(self, gen, t: float):
        """Make sure the decoder is producing the frames around t. Under the
        lock; may hand back a restart to do outside it."""
        idx = int(t * FPS)
        if self._first <= idx <= self._last + 30 * FPS and (self._eof is None or idx < self._eof):
            return None
        if self._eof is not None and idx >= self._eof:
            return None
        return t

    def clock(self, t: float, playing: bool):
        """The phone's player says where it is. It is the clock from now on."""
        restart = None
        with self._lock:
            if self.status in ("idle", "fetching", "error"):
                return
            gen = self._gen
            self.phone_clock = True
            self._clock = (max(0.0, float(t)), time.monotonic(), bool(playing))
            self.status = "playing" if playing else "paused"
            restart = self._ensure(gen, t)
        if restart is not None and self.media:
            self._decode(gen, self.media, restart)
        self._dirty.set()

    def control(self, action: str, t=None):
        """play, pause, seek: the wall's own clock (or a nudge to the
        phone's, which will say its own next). stop is stop()."""
        restart = None
        with self._lock:
            if self.status in ("idle", "fetching", "error"):
                return
            gen = self._gen
            head = self._playhead()
            if action == "seek" and t is not None:
                head = max(0.0, float(t))
                self._clock = (head, time.monotonic(), self._clock[2])
                restart = self._ensure(gen, head)
            elif action == "play":
                self._clock = (head, time.monotonic(), True)
                self.status = "playing"
            elif action == "pause":
                self._clock = (head, time.monotonic(), False)
                self.status = "paused"
        if restart is not None and self.media:
            self._decode(gen, self.media, restart)
        self._dirty.set()

    # ---- what the main loop asks --------------------------------------------
    def frame_at(self):
        """(picture, seconds until the next one). The picture is a PIL image
        the size of the panel, the same object again while nothing has
        changed (so the loop can skip the resend), or None when the video is
        over and the wall should go back to what it was doing."""
        with self._lock:
            status = self.status
            if status in ("fetching", "error"):
                return (self._loading() if status == "fetching" else None), 0.25
            head = self._playhead()
            idx = int(head * FPS)
            over = self._eof is not None and idx >= self._eof
            if not over and self.media and self.media.duration_s > 0 \
                    and head >= self.media.duration_s and self._clock[2]:
                over = True
            if over:
                if self.loop and self.media:
                    self._clock = (0.0, time.monotonic(), True)
                    restart = self._ensure(self._gen, 0.0)
                    gen = self._gen
                else:
                    self.status = "ended"
                    return None, 0.0
            else:
                restart = None
            if restart is None:
                frame = self._frames.get(idx)
                if frame is None:
                    if idx > self._last and self._last >= self._first:
                        frame = self._frames.get(self._last)
                        # the wall's own clock waits for the picture; the
                        # phone's cannot be told to
                        if not self.phone_clock and self._clock[2] and self._eof is None:
                            self._clock = ((self._last + 1) / FPS, time.monotonic(), True)
                    elif self._frames:
                        frame = self._frames.get(self._first)
                if frame is None:
                    return self._loading(), 0.25
                img = self._shown
                if img is None or getattr(img, "_video_index", None) != idx \
                        or getattr(img, "_video_frame", None) is not frame:
                    img = Image.frombytes("RGB", (self.size, self.size), frame)
                    img._video_index, img._video_frame = idx, frame
                    self._shown = img
                if not self._clock[2]:
                    return img, 0.5
                nxt = (idx + 1) / FPS - head
                return img, max(0.005, min(nxt, 1.0 / FPS))
        # a loop restart, outside the lock
        self._decode(gen, self.media, restart)
        return self._loading(), 0.25

    def _loading(self):
        """A dark frame with a thin bar: how far along the fetch is."""
        if self.sound and self.audio_total:
            p = min(1.0, self.audio_got / max(1, self.audio_total))
        else:
            p = min(1.0, (self._last + 1) / (READY_S * FPS))
        s = self.size
        img = Image.new("RGB", (s, s), (0, 0, 0))
        d = ImageDraw.Draw(img)
        x0, x1, y = s // 4, s - s // 4, s // 2
        d.line([(x0, y), (x1, y)], fill=(28, 28, 28), width=2)
        if p > 0:
            d.line([(x0, y), (x0 + int((x1 - x0) * p), y)], fill=_LOADING_INK, width=2)
        return img
