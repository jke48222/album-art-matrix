"""Say the wake phrase, then tell the wall what to do or ask a question.

The small wake detector runs locally. After waking, up to eight seconds of
speech stays in memory and Whisper turns it into words on the Pi. Familiar
commands work without the internet. Other questions use Ask. No voice clip
or transcript is saved. Jarvis is the shipped wake phrase; a separately
trained hey-wall model can be selected when installed.
"""
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path
import queue
import re
import subprocess
import threading
import time

import numpy as np

from .nowplaying import NowPlaying
from .nowplaying.ears import _db, _wav

ROOT = Path(__file__).resolve().parents[1]
MODELS = ROOT / "models" / "voice"
RATE = 16000
MAX_SPEECH = 8.0
SILENCE = .8
TRANSCRIBE_BUDGET = 2.9
WAKE_COOLDOWN = 2.0


@dataclass(frozen=True)
class Command:
    action: str
    value: object = None


PHRASES = {
    "off": Command("power", "off"), "turn off": Command("power", "off"),
    "on": Command("power", "on"), "turn on": Command("power", "on"),
    "art": Command("face", "art"), "cover": Command("face", "art"),
    "disc": Command("face", "cd"), "disk": Command("face", "cd"),
    "ambient": Command("face", "ambient"), "clock": Command("face", "clock"),
    "lyrics": Command("face", "lyrics"), "nine": Command("face", "nine"),
    "video off": Command("video_off"), "stop video": Command("video_off"),
    "brighter": Command("brightness", .1), "louder": Command("brightness", .1),
    "dimmer": Command("brightness", -.1), "quieter": Command("brightness", -.1),
    "what is this": Command("song"), "what's this": Command("song"),
    "listen": Command("listen"),
}
NUMBERS = {word: n for n, word in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split())}
NUMBERS.update({"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "a": 1, "an": 1})


def number(text):
    if re.fullmatch(r"\d+(?:\.\d+)?", text):
        return float(text)
    words = text.split()
    if text in NUMBERS:
        return NUMBERS[text]
    if len(words) == 2 and words[0] in NUMBERS and NUMBERS[words[0]] >= 20 and words[1] in NUMBERS and 0 < NUMBERS[words[1]] < 10:
        return NUMBERS[words[0]] + NUMBERS[words[1]]
    return None


def match_command(text):
    """Fuzz only complete short commands, never a word inside a question."""
    clean = re.sub(r"[^\w\s'.-]", " ", text.lower()).strip()
    clean = re.sub(r"\s+", " ", clean).strip(" .")
    clean = re.sub(r"^(?:hey (?:wall|jarvis)[ ,]*|please )", "", clean)
    clean = re.sub(r" please$", "", clean)
    earworm = re.fullmatch(r"(?:what song (?:goes|has the words)|find the song) (.+)", clean)
    if earworm:
        return Command("earworm", earworm[1].strip())
    display = re.fullmatch(r"show (?:me )?(.+)", clean)
    if display:
        return Command("show", display[1].strip())
    video = re.fullmatch(r"play (?:me )?(.+)", clean)
    if video:
        return Command("play", video[1].strip())
    taught = re.fullmatch(r"teach this(?: it is| it's)? (.+) by (.+)", clean)
    if taught:
        return Command("teach", (taught[1].strip(), taught[2].strip()))
    timer = re.fullmatch(r"(?:set (?:a )?)?timer(?: for)? (.+?) minutes?", clean)
    if timer:
        minutes = number(timer[1])
        if minutes is not None and 0 < minutes <= 180:
            return Command("timer", minutes)
        return None
    if clean in PHRASES:
        return PHRASES[clean]
    # Three-letter commands are too easy to confuse with ordinary speech.
    if 4 <= len(clean) <= 24 and len(clean.split()) <= 4:
        choices = sorted(((SequenceMatcher(None, clean, phrase).ratio(), phrase)
                          for phrase in PHRASES if len(phrase) >= 4), reverse=True)
        if choices[0][0] >= .84 and choices[0][0] - choices[1][0] >= .08:
            return PHRASES[choices[0][1]]
    return None


class Capture:
    """Sample counts make the silence deadline independent of worker jitter."""
    def __init__(self, gate=-45):
        self.gate = gate
        self.parts = []
        self.samples = self.quiet = 0
        self.spoke = False

    def feed(self, pcm):
        self.parts.append(pcm)
        count = len(pcm) // 2
        self.samples += count
        if _db(pcm) >= self.gate:
            self.quiet, self.spoke = 0, True
        else:
            self.quiet += count
        return self.samples >= MAX_SPEECH * RATE or self.quiet >= SILENCE * RATE

    def take(self):
        pcm = b"".join(self.parts) if self.spoke else b""
        self.parts.clear()
        return pcm[:int(MAX_SPEECH * RATE * 2)]


class Transcriber:
    def __init__(self, root=ROOT):
        self.root = Path(root)

    def transcribe(self, pcm, model="tiny"):
        if model not in ("tiny", "base"):
            raise ValueError("unknown speech model")
        result = subprocess.run([str(self.root / "bin/whisper-cli"),
            "-m", str(self.root / f"models/voice/ggml-{model}.bin"),
            "-f", "-", "-t", "2", "-ng", "-np", "-nt", "-l", "en",
            "-ac", str(min(512, max(256, int(len(pcm) / (RATE * 2) * 50) + 32))),
            "-bs", "1", "-bo", "1", "-otxt", "-of", "-"],
            input=_wav(pcm), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=TRANSCRIBE_BUDGET)
        if result.returncode:
            raise RuntimeError("Whisper could not transcribe")
        text = result.stdout.decode(errors="replace").strip()
        # Whisper labels non-speech in brackets and occasionally invents a
        # stock sign-off for silence. Neither should trigger a network ask.
        text = re.sub(r"\[[^]]*\]|\([^)]*\)", "", text).strip()
        if text.lower().strip(" .!") in ("thank you", "thanks for watching", "you"):
            return ""
        return text[:2000]


class WakeModel:
    def __init__(self, choice=0):
        from openwakeword.model import Model
        target = MODELS / ("hey_wall.onnx" if choice else "hey_jarvis_v0.1.onnx")
        if not target.exists():
            raise FileNotFoundError(f"Install {target.name} before selecting it")
        self.model = Model(wakeword_models=[str(target)], inference_framework="onnx",
            melspec_model_path=str(MODELS / "melspectrogram.onnx"),
            embedding_model_path=str(MODELS / "embedding_model.onnx"), ncpu=1)
        self.pending = b""

    def feed(self, pcm):
        self.pending += pcm
        score = 0.0
        while len(self.pending) >= 2560:
            frame, self.pending = self.pending[:2560], self.pending[2560:]
            scores = self.model.predict(np.frombuffer(frame, dtype="<i2"))
            score = max(score, max((float(v) for v in scores.values()), default=0))
        return score

    def reset(self):
        self.pending = b""
        self.model.reset()


def perform(ctrl, command):
    action, value = command.action, command.value
    if action == "power":
        ctrl.gesture_power(value)
    elif action == "face":
        ctrl.apply({"mode": value})
    elif action == "brightness":
        ctrl.apply({"brightness": max(.05, min(1, ctrl.get()["brightness"] + value))})
    elif action == "timer":
        ctrl.apply({"timer_min": value})
    elif action == "video_off":
        ctrl.video_stop()
    elif action == "song":
        song = ctrl.public_state().get("now_showing") or {}
        ctrl.show_answer(f"{song['title']} by {song.get('artist', '')}" if song.get("title") else "Nothing named yet")
    elif action == "listen":
        if ctrl.ears is None:
            raise ValueError("microphone is unavailable")
        ctrl.ears.force_ask()
    elif action == "teach":
        if ctrl.teach is None or not ctrl.teach.enabled():
            raise ValueError("teaching is off")
        title, artist = value
        ctrl.teach.manual(NowPlaying(track_id=f"voice:{artist}:{title}", title=title,
                                    artist=artist, album="", art_url=None, progress_ms=None, duration_ms=None, is_playing=True))
        ctrl.show_answer("Play it for twenty seconds")
    elif action == "earworm":
        ctrl.earworm.ask(value)
    elif action == "show":
        from .discover import show
        show(ctrl, value)
    elif action == "play":
        from .discover import play
        play(ctrl, value)


class Voice:
    def __init__(self, ctrl, start=True, transcriber=None):
        self.ctrl = ctrl
        self.transcriber = transcriber or Transcriber()
        self.jobs = queue.Queue(maxsize=4)
        self.state, self.problem = "off", None
        self.model = None
        self.choice = None
        self.capture = None
        self.revision = None
        self.retry_at = self.cooldown = 0.0
        self.last_transcribe_ms = None
        if start:
            threading.Thread(target=self._work, name="wake", daemon=True).start()

    def enabled(self):
        return bool(self.ctrl.features.enabled("wake") and self.ctrl.tuning and self.ctrl.tuning.get("wake"))

    def public(self):
        return {"enabled": self.enabled(), "state": self.state, "problem": self.problem,
                "wake_word": "hey wall" if self.ctrl.tuning and self.ctrl.tuning.get("wake_word") else "hey jarvis",
                "custom_available": (MODELS / "hey_wall.onnx").exists(),
                "last_transcribe_ms": self.last_transcribe_ms}

    def feed(self, pcm):
        if not self.enabled() or self.state == "thinking":
            return
        try:
            self.jobs.put_nowait((time.monotonic(), pcm))
        except queue.Full:
            # A stalled inference must lose the whole request, not silently
            # stitch speech across missing chunks into a different command.
            self.problem = "Speech fell behind. Please try again."
            self.revision = None

    def _valid(self):
        return self.enabled() and self.revision == self.ctrl.control_seq

    def _finish(self, pcm):
        self.state = "thinking"
        horizon = self.ctrl.horizon
        if horizon:
            horizon.think()
        try:
            if not pcm or not self._valid():
                raise ValueError("No speech caught")
            started = time.monotonic()
            text = self.transcriber.transcribe(pcm, "base" if self.ctrl.tuning.get("speech_model") else "tiny")
            self.last_transcribe_ms = round((time.monotonic() - started) * 1000)
            pcm = None
            if not text or not self._valid():
                raise ValueError("No speech caught or request cancelled")
            command = match_command(text)
            if command:
                # The command itself is a control change. Detach its own
                # animation so apply() cancels only an unrelated request.
                self.ctrl.horizon = None
                perform(self.ctrl, command)
                self.revision = self.ctrl.control_seq
            else:
                result = self.ctrl.asker.ask(text, "text")
                if not self._valid():
                    return
                self.ctrl.show_answer(result["answer"])
            if self._valid() and horizon:
                horizon.open()
                self.ctrl.horizon = horizon
                self.ctrl.dirty.set()
            self.problem = None
        except Exception as exc:
            self.problem = f"Could not catch that: {type(exc).__name__}"
            print(f"[voice] {self.problem}", flush=True)
            if self._valid() and horizon:
                horizon.fail()
                self.ctrl.horizon = horizon
                self.ctrl.dirty.set()
        finally:
            pcm = None
            self.state = "ready" if self.enabled() else "off"
            self.cooldown = time.monotonic() + WAKE_COOLDOWN
            if self.model:
                self.model.reset()

    def _work(self):
        while True:
            try:
                stamp, pcm = self.jobs.get(timeout=.2)
            except queue.Empty:
                if not self.enabled():
                    self.model, self.capture = None, None
                    self.state = "off"
                    self.ctrl.horizon = None
                continue
            try:
                if not self.enabled():
                    self.model, self.capture = None, None
                    self.state = "off"
                    continue
                if self.capture:
                    if not self._valid() or time.monotonic() - stamp > .35:
                        self.capture = None
                        self.ctrl.horizon = None
                        continue
                    if self.ctrl.horizon:
                        self.ctrl.horizon.level(_db(pcm))
                    if self.capture.feed(pcm):
                        captured, self.capture = self.capture.take(), None
                        self._finish(captured)
                        captured = None
                    continue
                if time.monotonic() < max(self.cooldown, self.retry_at):
                    continue
                choice = self.ctrl.tuning.get("wake_word")
                if self.model is None or self.choice != choice:
                    self.state = "loading"
                    self.model, self.choice = WakeModel(choice), choice
                    self.state, self.problem = "ready", None
                    # Loading may take longer than a frame. Drop old chunks.
                    continue
                if time.monotonic() - stamp > .35:
                    self.model.reset()
                    continue
                if self.model.feed(pcm) >= self.ctrl.tuning.get("wake_threshold"):
                    from .art.horizon import Horizon
                    self.revision = self.ctrl.control_seq
                    gate = self.ctrl.tuning.get("speech_gate")
                    self.capture = Capture(gate)
                    self.state = "listening"
                    if self.ctrl.features.enabled("horizon"):
                        self.ctrl.horizon = Horizon(self.ctrl.wall.width, self.ctrl.last_frame)
                    self.ctrl.dirty.set()
                    print("[voice] wake detected", flush=True)
            except Exception as exc:
                self.problem = f"Voice tools unavailable: {type(exc).__name__}"
                self.state = "unavailable"
                self.retry_at = time.monotonic() + 30
                self.model, self.capture = None, None
                print(f"[voice] {self.problem}", flush=True)
            finally:
                pcm = None
                self.jobs.task_done()
