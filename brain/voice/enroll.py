"""Your own wake word: a phrase said a few times to the wall, and a
detector made from those takes.

The pretrained wake words (Hey Jarvis, Alexa, Hey Mycroft, Hey Marvin) are
classifier heads trained on thousands of synthetic voices. A phrase of your
own has no head, and training one takes a GPU and a day. What it does have
is the front end every head sits on: openWakeWord's melspectrogram and
Google's speech embedding, 96 numbers every 80 ms that describe the sound
of speech rather than who is speaking or how loud. So the wall keeps a few
takes of the phrase as sequences of those embeddings and matches the live
stream against them with dynamic time warping, which lets the phrase be
said a little faster or slower and still line up. Before any matching the
room's own sound is taken out: the mean embedding of everything heard while
teaching, takes and talk, is subtracted from the takes and from every live
window. A noisy or echoing room otherwise makes all speech look alike; with
it taken out, on a synthetic echoing room with noise 15 dB under the voice,
the false wakes from four minutes of household talk went from about one a
minute to none, and phrases sharing a word ("hey google" for "hey wall")
from three in four to one in five, with every take still heard.

Enrolling, the wall listens for six takes of the phrase, each cut from its
own stream by loudness with a little silence either side, then for ten
seconds of ordinary talk. From those it learns how close the takes come to
each other (each against the rest) and how close ordinary talk ever comes,
and sets its score so that 1 is as close as your own takes and 0 is as
close as the talk got; the threshold of 0.5 sits halfway. The takes are
kept in ~/.config/album-art-matrix/wakewords/<slug>.npz, their numbers in
<slug>.json.
"""
from __future__ import annotations

import json
import os
import re
import time
from collections import deque

import numpy as np

RATE = 16000
HOP_S = 0.08                  # one embedding every 80 ms
WIN_S = 0.775                 # each embedding hears this much sound
DIM = 96
VOICED_OVER_FLOOR_DB = 9.0    # the same bar the voice uses for "someone is talking"
PRE_ROLL_S = 0.5              # kept from before the voice starts
END_QUIET_S = 0.4             # this much quiet ends a take
MIN_TAKE_S = 0.25
MAX_TAKE_S = 2.2
TAKE_GAP_S = 0.6              # after a take, a moment before the next can start
TALK_S = 10.0
IDLE_S = 90.0                 # no voice at all this long while waiting for takes: stop
TAKES_MAX_S = 300.0           # and never wait for the takes longer than this
SAMPLES = 6
STAY_PENALTY = 0.10           # a template frame that does not move the window
SKIP_PENALTY = 0.04           # a template frame that moves it two
END_SLACK = 3                 # a live match must end within this many frames of now
TOP_K = 2                     # the distance is the mean of the two nearest takes
DIR = os.path.expanduser("~/.config/album-art-matrix/wakewords")


def slug_of(phrase: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (phrase or "").lower()).strip("-")
    return s[:40] or "wake"


def _unit(x) -> np.ndarray:
    x = np.asarray(x, dtype=np.float32)
    n = np.linalg.norm(x, axis=-1, keepdims=True)
    return x / np.maximum(n, 1e-6)


def core_frames(n_frames: int, start_s: float, end_s: float, margin_s: float = 0.12) -> list[int]:
    """The embedding frames that hear the phrase: those whose window's
    centre falls inside the voiced part, give or take a margin. At least
    three, taken nearest the middle when the phrase is very short."""
    idx = [t for t in range(n_frames)
           if start_s - margin_s <= t * HOP_S + WIN_S / 2 <= end_s + margin_s]
    if len(idx) >= 3 or n_frames == 0:
        return idx
    mid = (start_s + end_s) / 2
    order = sorted(range(n_frames), key=lambda t: abs(t * HOP_S + WIN_S / 2 - mid))
    return sorted(order[:min(3, n_frames)])


def subseq_dtw(template, window, end_slack: int | None = None,
               stay: float = STAY_PENALTY, skip: float = SKIP_PENALTY) -> float:
    """How far the whole template is from its best alignment with any
    stretch of the window, per template frame. Cosine distance; for each
    template frame the window moves 0, 1 or 2 frames, so the phrase may be
    said faster or up to twice as slow, the moves that are not one frame a
    little dearer. `end_slack` makes the alignment end within that many
    frames of the window's end: a phrase just finished, not one long gone."""
    T, W = len(template), len(window)
    if T == 0 or W == 0:
        return 2.0
    C = 1.0 - _unit(template) @ _unit(window).T           # T x W, 0..2
    INF = 1e9
    prev = C[0].astype(np.float64)                        # free start anywhere
    for i in range(1, T):
        stay_ = prev + stay
        diag = np.full(W, INF)
        diag[1:] = prev[:-1]
        skip_ = np.full(W, INF)
        skip_[2:] = prev[:-2] + skip
        prev = C[i] + np.minimum(np.minimum(stay_, diag), skip_)
    tail = prev if end_slack is None else prev[max(0, W - end_slack):]
    return float(tail.min() / T)


class Matcher:
    """A few takes of a phrase, and where on the scale a live window falls."""

    def __init__(self, templates, pos_ref: float, neg_ref: float, top_k: int = TOP_K,
                 stay: float = STAY_PENALTY, skip: float = SKIP_PENALTY, mean=None):
        self.templates = [_unit(t) for t in templates if len(t)]
        # the room's sound, taken out of each live window; the templates come without it
        self.mean = None if mean is None else np.asarray(mean, dtype=np.float32).reshape(DIM)
        if not self.templates:
            raise ValueError("no takes")
        self.pos_ref = float(pos_ref)
        self.neg_ref = float(neg_ref)
        self.top_k = max(1, int(top_k))
        self.stay, self.skip = float(stay), float(skip)
        self.max_len = max(len(t) for t in self.templates)
        self.window = int(round(self.max_len * 1.8)) + END_SLACK

    def distance(self, window, end_slack: int | None = END_SLACK) -> float:
        if self.mean is not None:
            window = np.asarray(window, dtype=np.float32) - self.mean
        ds = sorted(subseq_dtw(t, window, end_slack, self.stay, self.skip) for t in self.templates)
        return float(np.mean(ds[:min(self.top_k, len(ds))]))

    def score_of(self, d: float) -> float:
        span = max(1e-6, self.neg_ref - self.pos_ref)
        return float(np.clip((self.neg_ref - d) / span, 0.0, 1.0))

    def score(self, window) -> float:
        return self.score_of(self.distance(window))


def calibrate(templates, take_windows, negative_windows, top_k: int = TOP_K,
              stay: float = STAY_PENALTY, skip: float = SKIP_PENALTY) -> dict:
    """Where the scale's ends go: `pos_ref` the typical distance of a take
    from the other takes, `neg_ref` the nearest ordinary talk ever came."""
    pos = []
    for k, win in enumerate(take_windows):
        others = [t for j, t in enumerate(templates) if j != k]
        if not others:
            continue
        ds = sorted(subseq_dtw(t, win, None, stay, skip) for t in others)
        pos.append(float(np.mean(ds[:min(top_k, len(ds))])))
    m = Matcher(templates, 0.0, 1.0, top_k, stay, skip)
    neg = [m.distance(w, END_SLACK) for w in negative_windows]
    pos_ref = float(np.median(pos)) if pos else 0.3
    neg_ref = float(np.percentile(neg, 2)) if neg else pos_ref * 1.8
    separation = (neg_ref - pos_ref) / max(1e-6, pos_ref)
    if neg_ref <= pos_ref * 1.02:
        neg_ref = pos_ref * 1.1                    # keep a scale; the quality says it is weak
    # a quiet room gives about 1.7 on synthetic voices, an echoing one with noise about 0.7
    quality = "good" if separation >= 1.0 else "fair" if separation >= 0.5 else "poor"
    return {"pos_ref": pos_ref, "neg_ref": neg_ref, "separation": round(float(separation), 3),
            "quality": quality, "pos": [round(p, 4) for p in pos],
            "neg_min": round(float(min(neg)), 4) if neg else None, "top_k": top_k,
            "stay": stay, "skip": skip}


def build(phrase: str, takes, talk, embed, top_k: int = TOP_K) -> dict:
    """A wake word from its takes. `takes` are (pcm int16, voiced start s,
    voiced end s); `talk` is ordinary speech as pcm; `embed(pcm)` gives the
    (frames, 96) embeddings."""
    heard = []
    for pcm, s0, s1 in takes:
        X = np.asarray(embed(pcm), dtype=np.float32).reshape(-1, DIM)
        if len(X) >= 3:
            heard.append((X, core_frames(len(X), s0, s1)))
    if len(heard) < 3:
        raise ValueError("not enough takes to learn from")
    talk = np.asarray(talk if talk is not None else [], dtype=np.int16)
    negE = (np.asarray(embed(talk), dtype=np.float32).reshape(-1, DIM) if talk.size >= RATE
            else np.zeros((0, DIM), np.float32))
    mean = np.concatenate([X for X, _ in heard] + [negE]).mean(axis=0).astype(np.float32)
    templates = [X[idx] - mean for X, idx in heard]
    windows = [X - mean for X, _ in heard]
    W = Matcher(templates, 0.0, 1.0, top_k).window
    negC = negE - mean
    neg_windows = [negC[j - W:j] for j in range(W, len(negC) + 1)]
    cal = calibrate(templates, windows, neg_windows, top_k)
    return {"phrase": " ".join(phrase.split()), "templates": templates, "mean": mean, **cal}


def matcher_of(model: dict) -> Matcher:
    return Matcher(model["templates"], model["pos_ref"], model["neg_ref"], model.get("top_k", TOP_K),
                   model.get("stay", STAY_PENALTY), model.get("skip", SKIP_PENALTY), model.get("mean"))


# ---- keeping them -------------------------------------------------------------------------
def save(model: dict, directory: str = DIR) -> str:
    os.makedirs(directory, exist_ok=True)
    slug = slug_of(model["phrase"])
    lengths = np.array([len(t) for t in model["templates"]], dtype=np.int32)
    frames = np.concatenate(model["templates"]).astype(np.float32)
    mean = np.asarray(model["mean"] if model.get("mean") is not None else np.zeros(DIM), dtype=np.float32)
    np.savez_compressed(os.path.join(directory, slug + ".npz"), lengths=lengths, frames=frames, mean=mean)
    meta = {k: model[k] for k in ("phrase", "pos_ref", "neg_ref", "separation", "quality", "top_k",
                                  "stay", "skip") if k in model}
    meta.update({"created": int(time.time()), "samples": int(len(lengths))})
    tmp = os.path.join(directory, slug + ".json.tmp")
    with open(tmp, "w") as fh:
        json.dump(meta, fh)
    os.replace(tmp, os.path.join(directory, slug + ".json"))
    return "own:" + slug


def load(slug: str, directory: str = DIR) -> tuple[dict, Matcher]:
    with open(os.path.join(directory, slug + ".json")) as fh:
        meta = json.load(fh)
    d = np.load(os.path.join(directory, slug + ".npz"))
    lengths, frames = d["lengths"], d["frames"]
    templates = np.split(frames, np.cumsum(lengths)[:-1])
    mean = d["mean"] if "mean" in d.files else None
    return meta, Matcher(templates, meta["pos_ref"], meta["neg_ref"], meta.get("top_k", TOP_K),
                         meta.get("stay", STAY_PENALTY), meta.get("skip", SKIP_PENALTY), mean)


def listing(directory: str = DIR) -> list[dict]:
    out = []
    try:
        names = sorted(f for f in os.listdir(directory) if f.endswith(".json"))
    except OSError:
        return out
    for f in names:
        slug = f[:-5]
        if not os.path.exists(os.path.join(directory, slug + ".npz")):
            continue
        try:
            with open(os.path.join(directory, f)) as fh:
                meta = json.load(fh)
        except (OSError, ValueError):
            continue
        out.append({"name": "own:" + slug, "label": meta.get("phrase") or slug, "kind": "own",
                    "quality": meta.get("quality"), "created": meta.get("created"),
                    "samples": meta.get("samples")})
    return out


def forget(slug: str, directory: str = DIR) -> bool:
    gone = False
    for ext in (".json", ".npz"):
        try:
            os.remove(os.path.join(directory, slug + ext))
            gone = True
        except OSError:
            pass
    return gone


# ---- taking the takes ---------------------------------------------------------------------
class Enroller:
    """The takes, cut from the ear's own stream by loudness, then the talk.

    Fed the ear's 100 ms chunks with the level and the room's floor. A take
    starts when the voice rises over the floor, carries half a second from
    before it, and ends after 0.4 s of quiet; too short or too long and it
    is refused with a word why. After the takes, ten seconds of whatever the
    room says is kept as the talk. Then the stage is "building", and whoever
    owns this builds the wake word from `takes` and `talk`. Nobody speaking
    for a minute and a half, or five minutes without the takes, and it
    stops by itself: the wall is not left waiting when the phone is put
    down."""

    def __init__(self, phrase: str, samples: int = SAMPLES, talk_s: float = TALK_S):
        self.phrase = " ".join((phrase or "").split())
        self.samples = max(3, min(10, int(samples)))
        self.talk_s = float(talk_s)
        self.stage = "takes"            # takes | talk | building | done | failed | cancelled
        self.takes: list[tuple[np.ndarray, float, float]] = []
        self.talk: list[bytes] = []
        self.talk_started: float | None = None
        self.message = f'Say "{self.phrase}".'
        self.rejected = 0
        self.last_event: str | None = None    # take | short | long
        self.event_at = 0.0
        self.level_over: float | None = None
        self.result: dict | None = None
        self.name: str | None = None
        self.problem: str | None = None
        self.finished_at: float | None = None
        self._ring: deque = deque(maxlen=int(round(PRE_ROLL_S / 0.1)) + 1)
        self._seg: list[tuple[bytes, bool]] | None = None
        self._quiet = 0.0
        self._cool_until = 0.0
        self._started: float | None = None
        self._heard: float | None = None

    def feed(self, chunk: bytes, level_db, floor_db, now: float):
        dt = len(chunk) / 2 / RATE
        if level_db is None or floor_db is None:
            self.level_over = None
            voiced = False
        else:
            self.level_over = float(level_db - floor_db)
            voiced = self.level_over >= VOICED_OVER_FLOOR_DB
        if self._started is None:
            self._started = self._heard = now
        if voiced:
            self._heard = now
        if self.stage == "talk":
            self.talk.append(chunk)
            if now - (self.talk_started or now) >= self.talk_s:
                self.stage = "building"
                self.message = "Learning it."
            return
        if self.stage != "takes":
            return
        if self._seg is None and (now - self._heard >= IDLE_S or now - self._started >= TAKES_MAX_S):
            self.stage = "cancelled"
            self._event(now, "idle", "Stopped: nothing heard for a while." if now - self._heard >= IDLE_S
                        else "Stopped: the takes took too long.")
            return
        if self._seg is None:
            self._ring.append((chunk, voiced))
            if voiced and now >= self._cool_until:
                self._seg = list(self._ring)
                self._quiet = 0.0
            return
        self._seg.append((chunk, voiced))
        self._quiet = 0.0 if voiced else self._quiet + dt
        too_long = len(self._seg) * dt >= PRE_ROLL_S + MAX_TAKE_S + END_QUIET_S + 0.6
        if self._quiet >= END_QUIET_S or too_long:
            self._close(now, dt)

    def _close(self, now: float, dt: float):
        seg, self._seg = self._seg, None
        self._ring.clear()
        self._cool_until = now + TAKE_GAP_S
        flags = [v for _, v in seg]
        if True not in flags:
            return
        first = flags.index(True)
        last = len(flags) - 1 - flags[::-1].index(True)
        voiced_len = (last - first + 1) * dt
        if voiced_len < MIN_TAKE_S:
            self.rejected += 1
            self._event(now, "short", "Too short. Say the whole phrase.")
            return
        if voiced_len > MAX_TAKE_S:
            self.rejected += 1
            self._event(now, "long", "Too long. Just the phrase, then stop.")
            return
        pcm = np.frombuffer(b"".join(c for c, _ in seg), dtype=np.int16).copy()
        self.takes.append((pcm, first * dt, (last + 1) * dt))
        left = self.samples - len(self.takes)
        if left <= 0:
            self.stage = "talk"
            self.talk_started = now
            self._event(now, "take", "Now talk normally for ten seconds, about anything but the phrase.")
        else:
            self._event(now, "take", f"Good. {left} more.")

    def _event(self, now: float, kind: str, message: str):
        self.last_event, self.event_at, self.message = kind, now, message

    def public(self, now: float | None = None) -> dict:
        now = time.monotonic() if now is None else now
        talk_left = None
        if self.stage == "talk" and self.talk_started is not None:
            talk_left = round(max(0.0, self.talk_s - (now - self.talk_started)), 1)
        return {"phrase": self.phrase, "stage": self.stage, "takes": len(self.takes),
                "samples": self.samples, "rejected": self.rejected, "message": self.message,
                "event": self.last_event,
                "event_ago": round(now - self.event_at, 2) if self.event_at else None,
                "talk_left": talk_left, "talk_s": self.talk_s,
                "level_over": None if self.level_over is None else round(self.level_over, 1),
                "recording": self._seg is not None,
                "quality": (self.result or {}).get("quality"),
                "separation": (self.result or {}).get("separation"),
                "name": self.name, "problem": self.problem}
