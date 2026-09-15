"""Speech to text on the Pi.

faster-whisper (CTranslate2) with the tiny model, int8: a sentence of two
or three seconds comes back in about a second and a half on the Pi 5, after
a one-time load of about ten seconds. The base model is twice as slow and
noticeably surer of names; it is a knob. Loading is lazy and happens on the
voice thread the first time someone speaks, so the brain starts fast and
the first question of the evening takes a moment longer. The model stays
loaded afterwards (about 160 MB), because loading per question would cost
more than the question.
"""
from __future__ import annotations

import threading
import time

import numpy as np

SIZES = ("tiny", "base")


class Transcriber:
    def __init__(self, size: str = "tiny", threads: int = 3, language: str = "en"):
        self.size = size if size in SIZES else "tiny"
        self.threads = threads
        self.language = language
        self._model = None
        self._lock = threading.Lock()
        self.problem = None
        self.load_s = None
        self.last_s = None

    def configure(self, size=None):
        if size is not None and size in SIZES and size != self.size:
            with self._lock:
                self.size = size
                self._model = None            # reloaded on the next question

    @property
    def loaded(self) -> bool:
        return self._model is not None

    def load(self) -> bool:
        with self._lock:
            if self._model is not None:
                return True
            try:
                from faster_whisper import WhisperModel
            except ImportError as exc:
                self.problem = f"faster-whisper is not installed ({exc})"
                return False
            t0 = time.monotonic()
            try:
                self._model = WhisperModel(self.size, device="cpu", compute_type="int8",
                                           cpu_threads=self.threads)
            except Exception as exc:
                self.problem = f"speech model would not load: {str(exc)[:120]}"
                return False
            self.load_s = round(time.monotonic() - t0, 1)
            self.problem = None
            print(f"[voice] speech model {self.size} loaded in {self.load_s} s", flush=True)
            return True

    def transcribe(self, pcm: np.ndarray) -> str:
        """16 kHz int16 in, words out; "" when nothing was said."""
        if not self.load():
            return ""
        t0 = time.monotonic()
        audio = pcm.astype(np.float32) / 32768.0
        try:
            with self._lock:
                segments, _ = self._model.transcribe(audio, language=self.language, beam_size=1,
                                                     vad_filter=False, condition_on_previous_text=False)
                text = " ".join(s.text.strip() for s in segments).strip()
        except Exception as exc:
            self.problem = f"speech: {str(exc)[:120]}"
            return ""
        self.last_s = round(time.monotonic() - t0, 2)
        return text

    def status(self) -> dict:
        return {"model": self.size, "loaded": self.loaded, "load_s": self.load_s,
                "last_s": self.last_s, "problem": self.problem}
