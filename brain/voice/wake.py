"""The wake word, on the Pi, on the ear's stream.

openWakeWord: a shared mel front end and speech embedding (Google's, frozen)
with a tiny classifier head per phrase, all ONNX, all on the CPU, a few
milliseconds per 80 ms of sound. The pretrained heads it ships include
"hey jarvis", which is the wall's wake phrase until a "hey wall" head is
trained from synthetic speech (openwakeword-trainer, a notebook, no
recordings needed); `[voice] wake_word` in config.toml names the head, by
its bundled name or as a path to an .onnx file.

The installed library's constructor has changed its keyword between
versions, so both are tried. A model that will not load is a `problem` in
the status, not a crash: the wall keeps working without the ears.
"""
from __future__ import annotations

import os
import time

import numpy as np

FRAME = 1280                     # samples the model takes at a time: 80 ms
REFRACTORY_S = 3.0               # after a wake, ignore the model this long


class WakeWord:
    def __init__(self, name: str = "hey_jarvis", threshold: float = 0.5):
        self.name = name
        self.threshold = float(threshold)
        self.model = None
        self.key = None              # the model's own name for its score
        self.problem = None
        self.score = 0.0
        self.fires = 0
        self.last_fire = -1e9
        self._buf = np.zeros(0, dtype=np.int16)
        self._load()

    def configure(self, threshold=None):
        if threshold is not None:
            self.threshold = float(threshold)

    # ---- loading ------------------------------------------------------------------------
    def _path(self) -> str | None:
        if self.name.endswith(".onnx"):
            p = os.path.expanduser(self.name)
            return p if os.path.exists(p) else None
        try:
            import openwakeword
        except ImportError:
            return None
        base = os.path.join(os.path.dirname(openwakeword.__file__), "resources", "models")
        for cand in (f"{self.name}.onnx", f"{self.name}_v0.1.onnx"):
            p = os.path.join(base, cand)
            if os.path.exists(p):
                return p
        try:                                   # newer versions fetch heads on demand
            from openwakeword.utils import download_models
            download_models([self.name])
        except Exception:
            return None
        for cand in (f"{self.name}.onnx", f"{self.name}_v0.1.onnx"):
            p = os.path.join(base, cand)
            if os.path.exists(p):
                return p
        return None

    def _load(self):
        try:
            from openwakeword.model import Model
        except ImportError as exc:
            self.problem = f"openwakeword is not installed ({exc})"
            return
        path = self._path()
        if path is None:
            self.problem = f"no wake word model called {self.name!r}"
            return
        # the constructor's keywords have changed across versions: 0.6 takes
        # wakeword_models and inference_framework, 0.4 takes
        # wakeword_model_paths and knows only ONNX
        attempts = (
            lambda: Model(wakeword_models=[path], inference_framework="onnx"),
            lambda: Model(wakeword_model_paths=[path], inference_framework="onnx"),
            lambda: Model(wakeword_model_paths=[path]),
            lambda: Model(wakeword_models=[path]),
        )
        last = None
        for make in attempts:
            try:
                self.model = make()
                break
            except TypeError as exc:
                last = exc
                continue
            except Exception as exc:
                self.problem = f"wake word model would not load: {str(exc)[:120]}"
                self.model = None
                return
        if self.model is None:
            self.problem = f"wake word model would not load: {str(last)[:120]}"
            return
        self.key = os.path.splitext(os.path.basename(path))[0]
        self.problem = None

    # ---- listening ---------------------------------------------------------------------------
    def feed(self, chunk: bytes, now: float | None = None) -> bool:
        """One 100 ms chunk in; True the moment the phrase is heard."""
        if self.model is None:
            return False
        now = time.monotonic() if now is None else now
        self._buf = np.concatenate([self._buf, np.frombuffer(chunk, dtype=np.int16)])
        fired = False
        while self._buf.size >= FRAME:
            frame, self._buf = self._buf[:FRAME], self._buf[FRAME:]
            try:
                scores = self.model.predict(frame)
            except Exception as exc:
                self.problem = f"wake word: {str(exc)[:100]}"
                return False
            s = max(scores.values()) if scores else 0.0
            self.score = float(s)
            if s >= self.threshold and now - self.last_fire >= REFRACTORY_S:
                self.last_fire = now
                self.fires += 1
                fired = True
                try:
                    self.model.reset()          # forget the phrase, or it fires again
                except Exception:
                    pass
        return fired

    def status(self) -> dict:
        return {"model": self.name, "loaded": self.model is not None,
                "threshold": self.threshold, "score": round(self.score, 3),
                "fires": self.fires, "problem": self.problem}
