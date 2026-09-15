"""The wake word, on the Pi, on the ear's stream.

openWakeWord: a shared mel front end and speech embedding (Google's,
frozen) with a tiny classifier head per phrase, all ONNX, all on the CPU,
a few milliseconds per 80 ms of sound. The heads it ships are the choices
on the phone: Hey Jarvis (the wall's first), Hey Mycroft, Hey Marvin,
Alexa. A phrase of your own is taught by saying it to the wall a few times
(brain/voice/enroll.py) and matched on the same embeddings, with no head
at all. The choice is kept in ~/.config/album-art-matrix/wake.json; with
none kept, `[voice] wake_word` in config.toml names it: a bundled name, a
path to an .onnx head, or own:<slug>. The same file keeps a sensitivity for
each word, since a phrase of your own scores on its own scale: 0.5 suits
the built-in heads, 0.75 a phrase of your own.

One front end serves every word for the life of the brain. A built-in
word is only its small head, an ONNX session run on the front end's last
frames exactly as the library's own Model does; switching words loads a
head of a megabyte or two, not a second copy of the front end, which on
the Pi's 1 GB cost 130 MB that never came back. A head the library ships
in another format falls back to the library's Model, whose constructor
has changed its keywords between versions, so each is tried. A model that
will not load is a `problem` in the status, not a crash: the wall keeps
working without the ears.
"""
from __future__ import annotations

import json
import os
import re
import time

import numpy as np

from . import enroll

FRAME = 1280                     # samples the model takes at a time: 80 ms
REFRACTORY_S = 3.0               # after a wake, ignore the model this long
PEAK_S = 1.5                     # the meter's peak holds this long
CHOICE_PATH = os.path.expanduser("~/.config/album-art-matrix/wake.json")
DEFAULT_THRESHOLD = 0.5          # the built-in heads
OWN_THRESHOLD = 0.75             # a phrase of your own (see docs/VOICE.md for how it was chosen)
LABELS = {"hey_jarvis": "Hey Jarvis", "alexa": "Alexa", "hey_mycroft": "Hey Mycroft",
          "hey_marvin": "Hey Marvin", "hey_rhasspy": "Hey Rhasspy"}
NOT_WAKE = {"melspectrogram", "embedding_model", "silero_vad", "timer", "weather"}
ORDER = ["hey_jarvis", "hey_mycroft", "hey_marvin", "alexa", "hey_rhasspy"]


def models_dir() -> str | None:
    try:
        import openwakeword
    except ImportError:
        return None
    return os.path.join(os.path.dirname(openwakeword.__file__), "resources", "models")


def bundled(directory: str | None = None) -> list[str]:
    """The wake phrases the installed library has heads for."""
    d = directory or models_dir()
    if not d or not os.path.isdir(d):
        return []
    names = []
    for f in os.listdir(d):
        if not f.endswith(".onnx"):
            continue
        n = re.sub(r"_v\d+(\.\d+)*$", "", f[:-5])
        if n not in NOT_WAKE and n not in names:
            names.append(n)
    return sorted(names, key=lambda n: (ORDER.index(n) if n in ORDER else len(ORDER), n))


def label_of(name: str, wake_dir: str | None = None) -> str:
    wake_dir = wake_dir or enroll.DIR
    if name.startswith("own:"):
        try:
            with open(os.path.join(wake_dir, name[4:] + ".json")) as fh:
                return json.load(fh).get("phrase") or name[4:]
        except (OSError, ValueError):
            return name[4:].replace("-", " ").title()
    base = os.path.basename(name)[:-5] if name.endswith(".onnx") else name
    base = re.sub(r"_v\d+(\.\d+)*$", "", base)
    return LABELS.get(base, base.replace("_", " ").title())


def choices(wake_dir: str | None = None, directory: str | None = None) -> list[dict]:
    wake_dir = wake_dir or enroll.DIR
    out = [{"name": n, "label": label_of(n), "kind": "bundled"} for n in bundled(directory)]
    return out + enroll.listing(wake_dir)


def _kept(path: str | None = None) -> dict:
    try:
        with open(path or CHOICE_PATH) as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _keep(d: dict, path: str | None = None):
    path = path or CHOICE_PATH
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(d, fh)
        os.replace(tmp, path)
    except OSError as exc:
        print(f"[voice] could not keep the wake word choice: {exc}", flush=True)


def saved_choice(path: str | None = None) -> str | None:
    name = _kept(path).get("name")
    return str(name) if name else None


def save_choice(name: str, path: str | None = None):
    d = _kept(path)
    d["name"] = name
    _keep(d, path)


def saved_threshold(name: str, path: str | None = None) -> float | None:
    th = _kept(path).get("thresholds")
    try:
        return float(th[name]) if isinstance(th, dict) and name in th else None
    except (TypeError, ValueError):
        return None


def threshold_for(name: str, path: str | None = None) -> float:
    """How sure a wake word must be: what was set for it, or its kind's own
    default."""
    v = saved_threshold(name, path)
    if v is not None:
        return v
    return OWN_THRESHOLD if str(name).startswith("own:") else DEFAULT_THRESHOLD


def save_threshold(name: str, threshold: float, path: str | None = None):
    d = _kept(path)
    th = d.get("thresholds") if isinstance(d.get("thresholds"), dict) else {}
    th[name] = round(float(threshold), 3)
    d["thresholds"] = th
    _keep(d, path)


def forget_threshold(name: str, path: str | None = None):
    d = _kept(path)
    if isinstance(d.get("thresholds"), dict) and d["thresholds"].pop(name, None) is not None:
        _keep(d, path)


def release_memory():
    """After a word is swapped out: collect its models now, and hand the
    freed pages back to the system rather than keeping them in the
    allocator. The Pi has 1 GB, and its watchdog restarts it when memory
    runs out."""
    import gc
    gc.collect()
    try:
        import ctypes
        ctypes.CDLL("libc.so.6").malloc_trim(0)
    except (OSError, AttributeError):
        pass                                   # not glibc: nothing to hand back


def audio_features():
    """openWakeWord's front end on its own: the melspectrogram and the
    speech embedding, streaming."""
    from openwakeword.utils import AudioFeatures
    try:
        return AudioFeatures(inference_framework="onnx")
    except TypeError:
        return AudioFeatures()


def front_end_of(w):
    """The streaming front end a loaded wake word already has, to share
    rather than load a second copy: the Pi has 1 GB."""
    if w is None:
        return None
    front = getattr(w, "front", None)
    if hasattr(front, "get_features"):
        return front
    personal = getattr(w, "personal", None)
    if personal is not None:
        return personal[0]
    return getattr(getattr(w, "model", None), "preprocessor", None)


def make_embedder(front=None):
    """pcm -> (frames, 96): the embeddings of a whole clip, for teaching.
    `front` is a loaded front end to borrow. Its whole-clip embedding runs
    the two models and touches none of the streaming buffers, so borrowing
    it leaves the listening as it was."""
    af = front if hasattr(front, "_get_embeddings") else audio_features()

    def embed(pcm):
        pcm = np.asarray(pcm, dtype=np.int16)
        if pcm.size < 16000:
            pcm = np.concatenate([pcm, np.zeros(16000 - pcm.size, dtype=np.int16)])
        return np.asarray(af._get_embeddings(pcm), dtype=np.float32).reshape(-1, enroll.DIM)
    return embed


class WakeWord:
    def __init__(self, name: str = "hey_jarvis", threshold: float = 0.5, wake_dir: str | None = None,
                 front=None):
        self.name = name
        self._front = front              # a loaded front end to share, for a phrase of your own
        self.threshold = float(threshold)
        self.wake_dir = wake_dir or enroll.DIR
        self.kind = "own" if name.startswith("own:") else "bundled"
        self.label = label_of(name, self.wake_dir)
        self.model = None                # the library's Model, for a head that is not ONNX
        self.head = None                 # (session, input name, frames) for a built-in word
        self.front = None                # the streaming front end, shared with the next word
        self.personal = None             # (front end, matcher) for a phrase of your own
        self._warm = 0
        self.meta: dict = {}
        self.key = None                  # the model's own name for its score
        self.problem = None
        self.score = 0.0
        self.fires = 0
        self.last_fire = -1e9
        self._peak = 0.0
        self._peak_at = -1e9
        self._buf = np.zeros(0, dtype=np.int16)
        self._load()

    @property
    def loaded(self) -> bool:
        return self.model is not None or self.head is not None or self.personal is not None

    def configure(self, threshold=None):
        if threshold is not None:
            self.threshold = float(threshold)

    # ---- loading ------------------------------------------------------------------------
    def _path(self) -> str | None:
        if self.name.endswith(".onnx"):
            p = os.path.expanduser(self.name)
            return p if os.path.exists(p) else None
        base = models_dir()
        if base is None:
            return None
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
        if self.kind == "own":
            try:
                self.meta, matcher = enroll.load(self.name[4:], self.wake_dir)
            except FileNotFoundError:
                self.problem = f"no wake word of your own called {self.label!r}"
                return
            except Exception as exc:
                self.problem = f"your wake word would not load: {str(exc)[:120]}"
                return
            try:
                pre = self._front if hasattr(self._front, "get_features") else audio_features()
                self.personal = (pre, matcher)
                self.front = pre
                self._front = None
                self.problem = None
            except ImportError as exc:
                self.problem = f"openwakeword is not installed ({exc})"
            except Exception as exc:
                self.problem = f"the wake word front end would not load: {str(exc)[:120]}"
            return
        try:
            from openwakeword.model import Model
        except ImportError as exc:
            self.problem = f"openwakeword is not installed ({exc})"
            return
        path = self._path()
        if path is None:
            self.problem = f"no wake word model called {self.name!r}"
            return
        if path.endswith(".onnx") and self._load_head(path):
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

    def _load_head(self, path: str) -> bool:
        """A built-in word as its head alone, on the shared front end."""
        try:
            import onnxruntime as ort
            opts = ort.SessionOptions()
            opts.inter_op_num_threads = 1
            opts.intra_op_num_threads = 1
            session = ort.InferenceSession(path, sess_options=opts, providers=["CPUExecutionProvider"])
            inp = session.get_inputs()[0]
            frames = int(inp.shape[1])
            front = self._front if hasattr(self._front, "get_features") else audio_features()
        except ImportError:
            return False                     # no onnxruntime of its own: the library's Model, below
        except Exception as exc:
            self.problem = f"wake word model would not load: {str(exc)[:120]}"
            return True
        self.head = (session, inp.name, frames)
        self.front = front
        self._front = None
        self._warm = 0
        self.key = os.path.splitext(os.path.basename(path))[0]
        self.problem = None
        return True

    # ---- listening ---------------------------------------------------------------------------
    def _predict(self, frame: np.ndarray) -> float:
        if self.head is not None:
            session, name, frames = self.head
            self.front(frame)
            out = session.run(None, {name: self.front.get_features(frames)})
            if self._warm < 5:                   # as the library does: nothing for the first frames
                self._warm += 1
                return 0.0
            return float(np.asarray(out[0]).reshape(-1)[0])
        if self.personal is not None:
            pre, matcher = self.personal
            pre(frame)
            feats = np.asarray(pre.get_features(matcher.window), dtype=np.float32).reshape(-1, enroll.DIM)
            return matcher.score(feats)
        scores = self.model.predict(frame)
        return float(max(scores.values())) if scores else 0.0

    def feed(self, chunk: bytes, now: float | None = None) -> bool:
        """One 100 ms chunk in; True the moment the phrase is heard."""
        if not self.loaded:
            return False
        now = time.monotonic() if now is None else now
        self._buf = np.concatenate([self._buf, np.frombuffer(chunk, dtype=np.int16)])
        fired = False
        while self._buf.size >= FRAME:
            frame, self._buf = self._buf[:FRAME], self._buf[FRAME:]
            try:
                s = self._predict(frame)
            except Exception as exc:
                self.problem = f"wake word: {str(exc)[:100]}"
                return False
            self.score = float(s)
            if self.score >= self._peak or now - self._peak_at > PEAK_S:
                self._peak, self._peak_at = self.score, now
            if s >= self.threshold and now - self.last_fire >= REFRACTORY_S:
                self.last_fire = now
                self.fires += 1
                fired = True
                if self.model is not None:
                    try:
                        self.model.reset()          # forget the phrase, or it fires again
                    except Exception:
                        pass
        return fired

    def peak(self, now: float | None = None) -> float:
        now = time.monotonic() if now is None else now
        return self._peak if now - self._peak_at <= PEAK_S else self.score

    def status(self) -> dict:
        return {"model": self.name, "label": self.label, "kind": self.kind, "loaded": self.loaded,
                "threshold": self.threshold,
                "default_threshold": OWN_THRESHOLD if self.kind == "own" else DEFAULT_THRESHOLD,
                "score": round(self.score, 3), "peak": round(self.peak(), 3),
                "fires": self.fires, "quality": self.meta.get("quality"), "problem": self.problem}
