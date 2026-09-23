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

import math
import threading
import time

import numpy as np

from ..art.answer import AnswerFace
from ..art.horizon import COLLAPSE_S, MISSED_S, OPEN_S, Horizon, ink_of
from . import enroll as enroll_mod
from . import wake as wake_mod
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
        self.enroller = None                    # enroll.Enroller while a phrase is being taught
        self._building = False
        self.wake_dir = enroll_mod.DIR
        self.wake_problem = None
        self._wake_loading = None

    def configure(self, on=None):
        if on is not None:
            self.on = bool(on)
            if not self.on and self.state != "idle":
                self._finish()

    # ---- the capture thread -----------------------------------------------------------
    def feed(self, chunk: bytes, level_db, floor_db, now: float):
        self.level_db, self.floor_db = level_db, floor_db
        if self.state == "enrolling":
            self._feed_enroll(chunk, level_db, floor_db, now)
            return
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

    # ---- the wake word, chosen and taught -------------------------------------------------
    def set_wake(self, name: str, wait: bool = False) -> dict:
        """Use another wake word from the next chunk on: a bundled one or
        one of your own. Loading takes a moment, so it happens off the
        capture thread unless `wait`."""
        name = str(name or "").strip()
        if not name:
            return {"error": "which wake word?"}
        known = {c["name"] for c in wake_mod.choices(self.wake_dir)}
        if name not in known and not name.endswith(".onnx"):
            return {"error": f"no wake word called {name}"}

        def load() -> bool:
            w = wake_mod.WakeWord(name, threshold=wake_mod.threshold_for(name), wake_dir=self.wake_dir,
                                  front=wake_mod.front_end_of(self.wake))
            self._wake_loading = None
            if not w.loaded:
                self.wake_problem = w.problem or "it would not load"
                self.log(f"[voice] wake word {name!r} would not load: {self.wake_problem}")
                return False
            old, self.wake = self.wake, w
            self.wake_problem = None
            del old
            wake_mod.release_memory()
            wake_mod.save_choice(name)
            tune = getattr(self.ctrl, "tuning", None)
            if tune is not None:                 # the tuning page's knob is the word in use
                try:
                    tune.update({"wake_threshold": w.threshold})
                except Exception as exc:
                    self.log(f"[voice] the tuning page keeps the old sensitivity: {exc}")
            self.log(f"[voice] the wake word is now {w.label!r}")
            self._nudge()
            return True

        self._wake_loading = name
        if wait:
            ok = load()
            return {"ok": ok, "error": None if ok else self.wake_problem}
        threading.Thread(target=load, name="wake-load", daemon=True).start()
        return {"loading": name}

    def forget_wake(self, name: str) -> dict:
        name = str(name or "")
        if not name.startswith("own:"):
            return {"error": "only a wake word of your own can be forgotten"}
        if self.wake is not None and self.wake.name == name:
            return {"error": "that one is in use; choose another first"}
        gone = enroll_mod.forget(name[4:], self.wake_dir)
        if gone:
            wake_mod.forget_threshold(name)
        return {"forgotten": gone}

    def enroll_start(self, phrase: str, samples: int = enroll_mod.SAMPLES) -> dict:
        phrase = " ".join((phrase or "").split())[:40]
        if len(phrase) < 3:
            return {"error": "a phrase of a word or two, please"}
        if len(phrase.split()) > 5:
            return {"error": "a short phrase works best: two or three words"}
        now = time.monotonic()
        with self._lock:
            if self.state != "idle":
                return {"error": "the wall is busy listening; try again in a moment"}
            self.enroller = enroll_mod.Enroller(phrase, samples)
            self.picture = self._as_picture(getattr(self.ctrl, "last_frame", None))
            self.ink = ink_of(self.picture)
            self._horizon = Horizon(self.size)
            self.state, self.since = "enrolling", now
        self.log(f"[voice] learning a wake word: {phrase!r}")
        self._nudge()
        return {"enroll": self.enroller.public(now)}

    def enroll_cancel(self) -> dict:
        with self._lock:
            e = self.enroller
            if self.state == "enrolling" and e is not None and e.stage in ("takes", "talk"):
                e.stage = "cancelled"
                e.message = "Stopped."
                e.finished_at = time.monotonic()
                self.state, self.since = "idle", time.monotonic()
        self._nudge()
        return {"cancelled": True}

    def _feed_enroll(self, chunk, level_db, floor_db, now):
        e = self.enroller
        if e is None:
            return
        before = (len(e.takes), e.rejected, e.stage)
        e.feed(chunk, level_db, floor_db, now)
        if e.stage == "cancelled":                    # nobody spoke for a long while
            with self._lock:
                e.finished_at = time.monotonic()
                if self.state == "enrolling":
                    self.state, self.since = "idle", time.monotonic()
            self.log(f"[voice] stopped learning {e.phrase!r}: {e.message}")
            self._nudge()
            return
        if e.stage == "building" and not self._building:
            self._building = True
            threading.Thread(target=self._build_wake, args=(e,), name="wake-build", daemon=True).start()
        if (len(e.takes), e.rejected, e.stage) != before:
            self._nudge()

    def _build_wake(self, e):
        try:
            embed = wake_mod.make_embedder(wake_mod.front_end_of(self.wake))   # borrowed, not a second copy
            talk = np.frombuffer(b"".join(e.talk), dtype=np.int16)
            model = enroll_mod.build(e.phrase, e.takes, talk, embed)
            name = enroll_mod.save(model, self.wake_dir)
            e.result = {k: model[k] for k in ("quality", "separation", "pos_ref", "neg_ref")}
            e.name = name
            got = self.set_wake(name, wait=True)
            if not got.get("ok"):
                raise RuntimeError(self.wake_problem or "the new wake word would not load")
            e.stage = "done"
            e.message = f'Ready. Say "{e.phrase}".'
            self.log(f"[voice] learnt {e.phrase!r}: {model['quality']} (separation {model['separation']})")
        except Exception as exc:
            e.stage = "failed"
            e.problem = f"{type(exc).__name__}: {str(exc)[:160]}"
            e.message = "Could not learn it. Try again, a little closer to the wall."
            self.log(f"[voice] could not learn {e.phrase!r}: {e.problem}")
        finally:
            e.finished_at = time.monotonic()
            self._building = False
            self._nudge()

    def meter(self) -> dict:
        """Small and quick, for the phone's live meter."""
        w = self.wake
        e = self.enroller
        over = None if self.level_db is None or self.floor_db is None else round(self.level_db - self.floor_db, 1)
        score = float(getattr(w, "score", 0.0) or 0.0)
        peak = w.peak() if callable(getattr(w, "peak", None)) else score
        fires = int(getattr(w, "fires", 0) or 0)
        last = getattr(w, "last_fire", None)
        return {"state": self.state, "label": getattr(w, "label", None),
                "score": round(score, 3), "peak": round(float(peak), 3),
                "threshold": getattr(w, "threshold", None), "fires": fires,
                "last_fire_ago": round(time.monotonic() - last, 1) if fires and last is not None else None,
                "level_over": over,
                "enroll": e.public() if e is not None and self.state == "enrolling" else None}

    def _enroll_face(self, el: float, size: int):
        """The line listens while the takes come in and a row of dots under
        it lights one by one; a thin bar fills through the talk; the bead
        runs while it learns; all bright when it is done."""
        e = self.enroller
        h = self._horizon
        now = time.monotonic()
        if e is None or e.stage == "cancelled" or (
                e.stage in ("done", "failed") and e.finished_at is not None and now - e.finished_at > 3.0):
            with self._lock:
                if self.state == "enrolling":
                    self.state, self.since = "idle", now
            return None
        ink = self.ink
        if e.stage == "building":
            f = h.thinking(el, ink)
        elif e.stage == "failed":
            f = h.missed(min(MISSED_S * 0.9, now - (e.finished_at or now)), ink)
        elif e.stage == "done":
            f = h.listening(el, ink, -12.0, -60.0)
        else:
            f = h.listening(el, ink, self.level_db, self.floor_db)
        big = size > 96
        dot = 5 if big else 2
        gap = 16 if big else 6
        n, got = e.samples, len(e.takes)
        y = size // 2 + (20 if big else 7)
        x0 = size // 2 - ((n - 1) * gap + dot) // 2
        col = np.array(ink, dtype=np.float32)
        pulse = 0.5 - 0.5 * math.cos(el * 5.0)
        for i in range(n):
            if i < got or e.stage == "done":
                c = col
                if i == got - 1 and e.last_event == "take" and now - e.event_at < 0.35:
                    c = np.minimum(255.0, col + 90.0)
            elif i == got and e.stage == "takes":
                c = col * (0.22 + 0.38 * pulse)
            else:
                c = col * 0.14
            x = x0 + i * gap
            grow = 1 if (i == got - 1 and e.last_event == "take" and now - e.event_at < 0.35) else 0
            f[y - grow:y + dot + grow, x - grow:x + dot + grow] = c.astype(np.uint8)
        if e.stage == "takes" and e.last_event in ("short", "long") and now - e.event_at < 0.5:
            yy = size // 2
            band = 3 if big else 1
            f[max(0, yy - band):yy + band + 1] = np.maximum(f[max(0, yy - band):yy + band + 1],
                                                            np.array((150, 34, 22), np.uint8))
        if e.stage == "talk" and e.talk_started is not None:
            frac = min(1.0, (now - e.talk_started) / max(1.0, e.talk_s))
            yb = y + dot + (12 if big else 4)
            xb = 24 if big else 8
            th = 3 if big else 1
            f[yb:yb + th, xb:size - xb] = (col * 0.15).astype(np.uint8)
            f[yb:yb + th, xb:xb + int(round((size - 2 * xb) * frac))] = (col * 0.85).astype(np.uint8)
        if big:
            from ..art.pixelfont import draw_text, text_width
            words = {"takes": f'"{e.phrase}"', "talk": "now talk normally", "building": "learning",
                     "done": f'"{e.phrase}"', "failed": "try again"}.get(e.stage, "")
            if words:
                draw_text(f, words, (size - text_width(words, 1)) // 2, size // 2 - 24,
                          tuple(int(v * 0.8) for v in ink), 1)
        return f

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
            # a game on the wall gets the first look: "crane" is a guess
            games = getattr(self.ctrl, "games", None)
            if games is not None and games.game is not None and not games.game.over:
                heard = games.hear(text)
                if heard is not None:
                    # the board shows the move itself; only a refusal is read back
                    self.last_command = f"game: {text!r}"
                    if heard.get("error"):
                        self._answer(heard["error"])
                    else:
                        self._open()
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

    # Spoken commands whose feature owns no object of its own, so nothing
    # else would refuse them: note acts straight on ctrl, and earworm shares
    # the shower with show and play. Everything else here is already gated by
    # main.py never building the thing it needs.
    _SWITCHED = {"note": "Notes are off on this wall.",
                 "earworm": "Naming a song from its words is off on this wall.",
                 "imagine": "Drawing from words is off on this wall."}

    def _do(self, cmd: cmds.Command):
        ctrl = self.ctrl
        name = cmd.name
        feats = getattr(ctrl, "features", None)
        if name in self._SWITCHED and feats is not None and not feats.on(name):
            self._answer(self._SWITCHED[name])
            return
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
            words = cmd.args.get("query") or cmd.args.get("prompt") or cmd.args.get("words")
            if name == "show":
                result = self.shower.show(words, kind=cmd.args.get("kind") or "any")
            else:
                result = getattr(self.shower, name)(words)
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
        if state == "enrolling":
            return self._enroll_face(el, size)
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
                "wake_choices": wake_mod.choices(self.wake_dir),
                "wake_loading": self._wake_loading, "wake_problem": self.wake_problem,
                "enroll": (self.enroller.public() if self.enroller is not None and (
                    self.state == "enrolling" or (self.enroller.finished_at is not None
                                                  and time.monotonic() - self.enroller.finished_at < 30))
                    else None),
                "speech": self.transcriber.status() if self.transcriber else None,
                "ask": (self.asker.status() if self.asker else {"ready": False}),
                "problem": self.problem}
