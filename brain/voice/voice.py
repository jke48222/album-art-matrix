"""The voice: what happens between the wake word and the wall's answer.

    idle        the wake word model listens; nothing is kept
    listening   the Horizon face is up; chunks are kept until 0.8 s of
                quiet after some speech, or 8 s
    thinking    the bead runs; a worker transcribes, matches a command or
                asks Claude
    answering   the answer face, a page at a time, then back to the wall
    opening     a command took effect; the line opens into the new face
    missed      nothing was understood; the line goes dashed and closes

The ear calls `feed` on its capture thread with the same chunks it keeps
for Shazam, so the timing is the ear's. The main loop asks `frame(t, size)`
every pass; a frame comes back while the face is up and None when the wall
should draw its own faces again. Nothing here blocks the render loop: the
transcriber and Claude run on the worker thread, and the loop only reads
state.

Testing without a microphone: `wake_now()` starts listening, `say(text)`
skips the microphone and feeds words straight to the thinking step, both
behind POST /voice/wake and POST /voice/say.
"""
from __future__ import annotations

import threading
import time

import numpy as np

from ..art.answer import AnswerFace
from ..art.horizon import COLLAPSE_S, MISSED_S, OPEN_S, Horizon, ink_of
from . import commands as cmds

END_SILENCE_S = 0.8            # quiet after speech that ends the listening
MIN_SPEECH_S = 0.3             # less than this heard: nothing was said
MAX_LISTEN_S = 8.0
VOICED_OVER_FLOOR_DB = 9.0     # a chunk this far over the room's floor is a voice
RATE = 16000


class Voice:
    def __init__(self, ctrl, wake, transcriber, asker=None, size: int = 64,
                 teacher=None, shower=None, log=None):
        self.ctrl = ctrl
        self.wake = wake
        self.transcriber = transcriber
        self.asker = asker
        self.teacher = teacher                  # teach.Teacher, for "teach this"
        self.shower = shower                    # show.Shower, for "show" and "play" (item 15)
        self.size = size
        self.log = log or (lambda s: print(s, flush=True))
        self.on = True
        self.state = "idle"
        self.since = 0.0
        self.ink = (230, 220, 200)
        self.picture = None                     # what was up when the wake word came
        self.level_db = None
        self.floor_db = None
        self._speech = []
        self._speech_started = None
        self._voiced_s = 0.0
        self._quiet_s = 0.0
        self._face_answer = None                 # AnswerFace while answering
        self._horizon = None
        self.last_text = None
        self.last_answer = None
        self.last_command = None
        self.heard_at = None
        self.timings = {}
        self.problem = None
        self._lock = threading.Lock()
        self.wakes = 0

    def configure(self, on=None):
        if on is not None:
            self.on = bool(on)
            if not self.on and self.state != "idle":
                self._finish()

    # ---- the capture thread -----------------------------------------------------------
    def feed(self, chunk: bytes, level_db, floor_db, now: float):
        self.level_db, self.floor_db = level_db, floor_db
        if not self.on:
            return
        if self.state == "idle":
            if self.wake.feed(chunk, now):
                self.wake_now(now)
            return
        if self.state != "listening":
            return
        self._speech.append(chunk)
        voiced = (level_db is not None and floor_db is not None
                  and level_db - floor_db >= VOICED_OVER_FLOOR_DB)
        dt = len(chunk) / 2 / RATE
        if voiced:
            self._voiced_s += dt
            self._quiet_s = 0.0
        else:
            self._quiet_s += dt
        heard = now - self.since
        if (self._voiced_s >= MIN_SPEECH_S and self._quiet_s >= END_SILENCE_S) \
                or heard >= MAX_LISTEN_S:
            self._end_listening(now)

    def wake_now(self, now: float | None = None):
        """The wake word, or POST /voice/wake."""
        now = time.monotonic() if now is None else now
        with self._lock:
            if self.state != "idle":
                return
            self.wakes += 1
            self.heard_at = now
            pic = getattr(self.ctrl, "last_frame", None)
            self.picture = self._as_picture(pic)
            self.ink = ink_of(self.picture)
            self._speech, self._voiced_s, self._quiet_s = [], 0.0, 0.0
            self._horizon = Horizon(self.size)
            self.state, self.since = "listening", now
        self.log("[voice] listening")
        self._nudge()

    def _as_picture(self, raw):
        if raw is None:
            return None
        try:
            side = int(round((len(raw) / 3) ** 0.5))
            arr = np.frombuffer(raw, dtype=np.uint8).reshape(side, side, 3)
            if side != self.size:
                rows = np.linspace(0, side - 1, self.size).astype(int)
                arr = arr[rows][:, rows]
            return arr.copy()
        except (ValueError, TypeError):
            return None

    def _end_listening(self, now: float):
        with self._lock:
            if self.state != "listening":
                return
            pcm = np.frombuffer(b"".join(self._speech), dtype=np.int16)
            self._speech = []
            nothing = self._voiced_s < MIN_SPEECH_S
            if not nothing:
                self.state, self.since = "thinking", now
                self.timings = {"listened_s": round(now - self.heard_at, 2)}
        # the lock is not reentrant: _missed takes it again, so it is called
        # out here, not under it
        if nothing:
            self._missed(now, "nothing said")
            return
        threading.Thread(target=self._think, args=(pcm,), name="voice-think", daemon=True).start()

    def show_answer(self, text: str) -> bool:
        """An answer that arrived without the microphone (POST /ask): the
        line opens into it as if it had been asked out loud."""
        with self._lock:
            if self.state not in ("idle", "answering"):
                return False
            self.picture = self._as_picture(getattr(self.ctrl, "last_frame", None))
            self.ink = ink_of(self.picture)
            self._horizon = Horizon(self.size)
            self._face_answer = AnswerFace(self.size, text, ink=self.ink)
            self.state, self.since = "answering", time.monotonic()
        self._nudge()
        return True

    def say(self, text: str):
        """POST /voice/say: words without the microphone."""
        now = time.monotonic()
        with self._lock:
            if self.state not in ("idle", "listening"):
                return False
            if self.state == "idle":
                self.wakes += 1
                self.heard_at = now
                self.picture = self._as_picture(getattr(self.ctrl, "last_frame", None))
                self.ink = ink_of(self.picture)
                self._horizon = Horizon(self.size)
            self.state, self.since = "thinking", now
            self.timings = {"listened_s": 0.0}
        threading.Thread(target=self._think, args=(text,), name="voice-think", daemon=True).start()
        return True

    # ---- the worker ----------------------------------------------------------------------
    def _think(self, pcm_or_text):
        t0 = time.monotonic()
        try:
            if isinstance(pcm_or_text, str):
                text = pcm_or_text
            else:
                text = self.transcriber.transcribe(pcm_or_text)
                self.timings["transcribe_s"] = round(time.monotonic() - t0, 2)
            self.last_text = text
            self.log(f"[voice] heard: {text!r}")
            if not text.strip():
                self._missed(time.monotonic(), "nothing understood")
                return
            cmd = cmds.match(text)
            if cmd is not None:
                self.last_command = repr(cmd)
                self._do(cmd)
                return
            self._ask(text)
        except Exception as exc:
            self.problem = f"{type(exc).__name__}: {str(exc)[:120]}"
            self.log(f"[voice] {self.problem}")
            self._missed(time.monotonic(), "an error")

    def _do(self, cmd: cmds.Command):
        ctrl = self.ctrl
        name = cmd.name
        if name == "cancel":
            self._missed(time.monotonic(), "cancelled")
            return
        if name in ("art", "cd", "ambient", "clock", "lyrics", "nine"):
            ctrl.apply({"mode": name})
            self._open()
            return
        if name == "off":
            ctrl.knock_toggle("a word", want="off")
            self._finish()
            return
        if name == "on":
            ctrl.knock_toggle("a word", want="on")
            self._open()
            return
        if name == "video_off":
            if ctrl.video is not None and getattr(ctrl.video, "busy", False):
                ctrl.video.stop()
            self._open()
            return
        if name in ("brighter", "dimmer"):
            b = ctrl.get()["brightness"] + (0.15 if name == "brighter" else -0.15)
            ctrl.apply({"brightness": max(0.05, min(1.0, round(b, 2)))})
            self._open()
            return
        if name == "timer":
            ctrl.apply({"timer_min": cmd.args["minutes"]})
            self._open()
            return
        if name == "whatis":
            ns = ctrl.now_showing or {}
            if ns.get("title"):
                text = ns["title"] + (" by " + ns["artist"] if ns.get("artist") else "")
            else:
                text = "Nothing is playing that I know of."
            self._answer(text)
            return
        if name == "listen":
            ear = getattr(ctrl, "ears", None)
            if ear is not None:
                ear._last_try = None            # the next think asks at once
            ctrl.nudge()
            self._answer("Listening.")
            return
        if name == "note":
            ctrl.apply({"ticker_text": cmd.args["text"][:120], "ticker_loop": False,
                        "ticker_style": "across", "mode": "ticker"})
            self._open()
            return
        if name == "teach":
            if self.teacher is None:
                self._answer("I have no song library on this wall.")
                return
            song = self.teacher.learn_named(cmd.args["title"], cmd.args["artist"])
            self._answer(f"Learnt {song['title']} by {song['artist']}." if song
                         else f"I could not find {cmd.args['title']} by {cmd.args['artist']} to learn.")
            return
        if name in ("show", "play", "imagine", "earworm"):
            if self.shower is None or not hasattr(self.shower, name):
                self._answer("That is not built yet.")
                return
            result = getattr(self.shower, name)(cmd.args.get("query") or cmd.args.get("prompt")
                                                or cmd.args.get("words"))
            if isinstance(result, dict) and result.get("error"):
                self._answer(result["error"])
            elif isinstance(result, str):
                self._answer(result)
            else:
                self._open()
            return
        self._answer("I did not follow that.")

    def _ask(self, text: str):
        if self.asker is None or not self.asker.ready:
            self._answer("I have no Claude key yet. Set one on the phone, under Services.")
            return
        t0 = time.monotonic()
        answer = self.asker.ask(text, size=self.size)
        self.timings["ask_s"] = round(time.monotonic() - t0, 2)
        self.last_answer = answer
        self._answer(answer)

    # ---- outcomes --------------------------------------------------------------------------------
    def _answer(self, text: str):
        with self._lock:
            self._face_answer = AnswerFace(self.size, text, ink=self.ink)
            self.state, self.since = "answering", time.monotonic()
        self.log(f"[voice] answer: {text!r}")
        self._nudge()

    def _open(self):
        """A command took effect: hand the opening to the frame tee."""
        with self._lock:
            self.state = "idle"
        self.ctrl.transition = ("open", time.monotonic(), self.ink)
        self._nudge()

    def _missed(self, now: float, why: str):
        with self._lock:
            self.state, self.since = "missed", now
        self.log(f"[voice] missed: {why}")
        self._nudge()

    def _finish(self):
        with self._lock:
            self.state = "idle"
            self._face_answer = None
        self._nudge()

    def _nudge(self):
        try:
            self.ctrl.dirty.set()
        except Exception:
            pass

    # ---- the render loop ------------------------------------------------------------------
    def frame(self, t: float, size: int):
        """The overlay's frame at time t, or None when the wall is its own."""
        state = self.state
        if state == "idle":
            return None
        if self._horizon is None or self._horizon.size != size:
            self._horizon = Horizon(size)
        h = self._horizon
        el = t - self.since
        pic = self.picture if self.picture is not None and self.picture.shape[0] == size \
            else np.zeros((size, size, 3), dtype=np.uint8)
        if state == "listening":
            if el < COLLAPSE_S:
                return h.collapse(pic, el, self.ink)
            return h.listening(el, self.ink, self.level_db, self.floor_db)
        if state == "thinking":
            return h.thinking(el, self.ink)
        if state == "answering":
            a = self._face_answer
            if a is None:
                self._finish()
                return None
            if a.done(el - OPEN_S):
                self._finish()
                return None
            page = a.frame_at(max(0.0, el - OPEN_S))
            if el < OPEN_S:
                return h.opening(page, el, self.ink)
            return page
        if state == "missed":
            if el >= MISSED_S:
                self._finish()
                return None
            return h.missed(el, self.ink)
        return None

    def status(self) -> dict:
        return {"on": self.on, "state": self.state, "wakes": self.wakes,
                "last_text": self.last_text, "last_command": self.last_command,
                "last_answer": self.last_answer, "timings": self.timings,
                "wake": self.wake.status() if self.wake else None,
                "speech": self.transcriber.status() if self.transcriber else None,
                "ask": (self.asker.status() if self.asker else {"ready": False}),
                "problem": self.problem}
