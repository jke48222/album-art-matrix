"""The voice: the command grammar, the answer face, the Horizon face and
the state machine, with no microphone and no cloud.

    .venv/bin/python -m pytest brain/tests/test_voice.py -q
"""
import os
import sys
import threading
import time

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.voice import commands as C                                  # noqa: E402
from brain.voice.commands import Command                               # noqa: E402
from brain.art.answer import AnswerFace, layout, wrap, pages, PAGE_S, HOLD_S   # noqa: E402
from brain.art.horizon import Horizon, ink_of, COLLAPSE_S, OPEN_S, MISSED_S   # noqa: E402
from brain.voice.voice import Voice, END_SILENCE_S                     # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")     # a directory: PNG strips are written there


# ---- commands --------------------------------------------------------------------------------
CASES = [
    ("Hey Jarvis, turn the wall off.", Command("off")),
    ("turn off", Command("off")),
    ("Hey wall, lights out", Command("off")),
    ("wake up please", Command("on")),
    ("show the lyrics", Command("lyrics")),
    ("lirics", Command("lyrics")),
    ("Clock.", Command("clock")),
    ("spin the record", Command("cd")),
    ("brighter", Command("brighter")),
    ("turn it down", Command("dimmer")),
    ("What is this?", Command("whatis")),
    ("what song is playing", Command("whatis")),
    ("listen again", Command("listen")),
    ("timer ten minutes", Command("timer", minutes=10)),
    ("set a timer for 25 minutes", Command("timer", minutes=25)),
    ("teach this, it is Tower of Roses by MALI", Command("teach", title="tower of roses", artist="mali")),
    ("what song goes I can't stop the feeling", Command("earworm", words="i can't stop the feeling")),
    ("show me the Blond cover", Command("show", query="blond")),
    ("play the Gameboy video", Command("play", query="gameboy")),
    ("draw a purple elephant", Command("imagine", prompt="purple elephant")),
    ("note: back at six", Command("note", text="back at six")),
    ("never mind", Command("cancel")),
    ("", Command("cancel")),
    ("what played during dinner?", None),
    ("who produced this record", None),
    ("how long until sunset", None),
]


def test_commands():
    for text, want in CASES:
        got = C.match(text)
        assert got == want, f"{text!r}: got {got!r}, wanted {want!r}"


# ---- the answer face ----------------------------------------------------------------------------
def test_answer_layout_at_both_sizes():
    assert layout(64)[:3] == (1, 10, 6)        # 1x glyphs: ten characters, six lines
    assert layout(192)[:3] == (2, 15, 10)      # 2x: fifteen characters, ten lines
    assert wrap("the quick brown fox jumps", 10) == ["the quick", "brown fox", "jumps"]
    assert wrap("supercalifragilistic yes", 10) == ["supercalif", "ragilistic", "yes"]
    assert wrap("one\n\ntwo", 10) == ["one", "", "two"]
    p = pages(" ".join(["word"] * 40), 64)
    assert len(p) >= 2 and all(len(pg) <= 6 for pg in p)


def test_answer_face_pages_and_finishes():
    a = AnswerFace(64, "Rain by four, nineteen degrees, then clear all evening, and a cold night after that.")
    assert len(a.pages) == 2
    assert a.page_at(0.0) == 0 and a.page_at(PAGE_S + 0.1) == 1
    assert not a.done(a.total_s - 0.1) and a.done(a.total_s)
    f0 = a.frame_at(0.0)
    assert f0.shape == (64, 64, 3) and f0.max() > 0
    f1 = a.frame_at(PAGE_S + 0.1)
    assert (f0 != f1).any()
    big = AnswerFace(192, "Rain by four.")
    assert big.frame_at(0.0).shape == (192, 192, 3)
    assert len(big.pages) == 1


# ---- the Horizon face -----------------------------------------------------------------------------
def sleeve(size: int) -> np.ndarray:
    y, x = np.mgrid[0:size, 0:size]
    f = np.zeros((size, size, 3), dtype=np.uint8)
    f[..., 0] = (x * 255 // size).astype(np.uint8)
    f[..., 1] = 60
    f[..., 2] = (y * 255 // size).astype(np.uint8)
    return f


def strip(frames: list[np.ndarray], path: str, scale: int):
    from PIL import Image
    n = len(frames)
    size = frames[0].shape[0]
    canvas = np.zeros((size, n * size + (n - 1) * 4, 3), dtype=np.uint8)
    for i, f in enumerate(frames):
        canvas[:, i * (size + 4):i * (size + 4) + size] = f
    Image.fromarray(canvas).resize((canvas.shape[1] * scale, size * scale), Image.NEAREST).save(path)


def test_horizon_states_at_both_sizes():
    for size, scale in ((64, 4), (192, 2)):
        h = Horizon(size)
        pic = sleeve(size)
        ink = ink_of(pic)
        assert max(ink) == 255
        mid = size // 2
        c0 = h.collapse(pic, 0.0, ink)
        assert c0.shape == pic.shape and c0.max() > 0
        c1 = h.collapse(pic, COLLAPSE_S, ink)
        assert c1[mid].max() > 0 and c1[0].max() == 0 and c1[-1].max() == 0     # only the line
        quiet = h.listening(0.0, ink, level_db=-50.0, floor_db=-50.0)
        loud = h.listening(1.0, ink, level_db=-20.0, floor_db=-50.0)
        assert quiet[mid].max() > 0 and loud[mid].max() >= quiet[mid].max()
        b1 = h.thinking(0.0, ink)
        b2 = h.thinking(0.5, ink)
        assert (b1 != b2).any()
        o1 = h.opening(pic, OPEN_S, ink)
        assert (o1 == pic).all()
        o0 = h.opening(pic, 0.0, ink)
        assert o0[0].max() == 0 and o0[mid].max() > 0
        m0 = h.missed(0.0, ink)
        m1 = h.missed(MISSED_S * 0.9, ink)
        assert m0[mid].max() > m1[mid].max()
        assert (m0[mid] == 0).all(axis=1).any()                                  # dashed
        if OUT:
            strip([c0, c1, quiet, loud, b1, b2, o0, h.opening(pic, OPEN_S / 2, ink), o1, m0],
                  os.path.join(OUT, f"horizon-{size}.png"), scale)


# ---- the state machine -----------------------------------------------------------------------------
class FakeWake:
    def __init__(self):
        self.fire = False
        self.model = object()
        self.name = "hey_test"

    def feed(self, chunk, now):
        f, self.fire = self.fire, False
        return f

    def configure(self, **kw):
        pass

    def status(self):
        return {"model": self.name}


class FakeTranscriber:
    def __init__(self, text):
        self.text = text
        self.calls = 0

    def transcribe(self, pcm):
        self.calls += 1
        return self.text

    def configure(self, **kw):
        pass

    def status(self):
        return {}


class FakeAsker:
    def __init__(self, answer):
        self.answer, self.ready, self.asked = answer, True, []

    def ask(self, text, size=64):
        self.asked.append(text)
        return self.answer

    def status(self):
        return {"ready": True}


class FakeCtrl:
    def __init__(self):
        self.state = {"mode": "art", "brightness": 0.8}
        self.applied = []
        self.dirty = threading.Event()
        self.last_frame = sleeve(64).tobytes()
        self.now_showing = {"title": "Nights", "artist": "Frank Ocean"}
        self.transition = None
        self.video = None
        self.toggles = []

    def get(self):
        return dict(self.state)

    def apply(self, p):
        self.state.update(p)
        self.applied.append(p)
        return {}

    def knock_toggle(self, why, want=None):
        self.toggles.append(want)
        self.state["mode"] = "off" if want == "off" else "art"
        return "off" if want == "off" else "on"

    def nudge(self):
        pass


def chunk(voiced: bool) -> bytes:
    return (np.full(1600, 3000 if voiced else 10, dtype=np.int16)).tobytes()


def talk(v: Voice, t: float, voiced_s: float, quiet_s: float) -> float:
    """Feed voiced chunks, then quiet ones, 100 ms at a time."""
    for _ in range(int(voiced_s * 10)):
        t += 0.1
        v.feed(chunk(True), -20.0, -50.0, t)
    for _ in range(int(quiet_s * 10)):
        t += 0.1
        v.feed(chunk(False), -50.0, -50.0, t)
    return t


def settle(v: Voice, want: str, timeout: float = 3.0):
    t0 = time.monotonic()
    while v.state != want and time.monotonic() - t0 < timeout:
        time.sleep(0.02)
    assert v.state == want, f"state {v.state}, wanted {want}"


def test_a_command_ends_in_an_opening():
    ctrl = FakeCtrl()
    v = Voice(ctrl, FakeWake(), FakeTranscriber("show the clock"), asker=FakeAsker("x"), size=64,
              log=lambda s: None)
    t = 100.0
    v.wake.fire = True
    v.feed(chunk(False), -50.0, -50.0, t)
    assert v.state == "listening" and v.wakes == 1
    f = v.frame(t + 0.1, 64)
    assert f is not None and f.shape == (64, 64, 3)
    t = talk(v, t, 1.0, END_SILENCE_S + 0.2)
    settle(v, "idle")
    assert {"mode": "clock"} in ctrl.applied
    assert ctrl.transition is not None and ctrl.transition[0] == "open"
    assert v.frame(t + 1.0, 64) is None
    assert v.last_command == "Command(clock)"


def test_a_question_becomes_an_answer_face_then_returns():
    ctrl = FakeCtrl()
    ask = FakeAsker("Rain by four, then clear.")
    v = Voice(ctrl, FakeWake(), FakeTranscriber("what is the weather tonight"), asker=ask, size=64,
              log=lambda s: None)
    t = 100.0
    v.wake_now(t)
    t = talk(v, t, 1.5, END_SILENCE_S + 0.2)
    settle(v, "answering")
    assert ask.asked == ["what is the weather tonight"]
    since = v.since
    f0 = v.frame(since + 0.05, 64)                    # opening from the line
    assert f0 is not None and f0[0].max() == 0
    f1 = v.frame(since + OPEN_S + 0.2, 64)            # the words
    assert f1 is not None and f1.max() > 0
    assert v.frame(since + OPEN_S + v._face_answer.total_s + 0.1, 64) is None
    assert v.state == "idle"


def test_nothing_said_is_a_miss_that_fades():
    ctrl = FakeCtrl()
    v = Voice(ctrl, FakeWake(), FakeTranscriber("anything"), asker=FakeAsker("x"), size=64,
              log=lambda s: None)
    t = 100.0
    v.wake_now(t)
    t = talk(v, t, 0.0, 8.2)                           # eight seconds of nothing
    assert v.state == "missed"
    assert v.frame(v.since + 0.1, 64) is not None
    assert v.frame(v.since + MISSED_S + 0.1, 64) is None
    assert v.state == "idle"


def test_say_skips_the_microphone_and_what_is_this_answers():
    ctrl = FakeCtrl()
    v = Voice(ctrl, FakeWake(), FakeTranscriber("unused"), asker=FakeAsker("x"), size=64,
              log=lambda s: None)
    assert v.say("what is this")
    settle(v, "answering")
    assert "Nights by Frank Ocean" in v._face_answer.text
    v._finish()
    assert v.say("lights out")
    settle(v, "idle")
    assert ctrl.toggles == ["off"]


def test_without_a_key_a_question_says_so():
    ctrl = FakeCtrl()
    ask = FakeAsker("x")
    ask.ready = False
    v = Voice(ctrl, FakeWake(), FakeTranscriber("who made this"), asker=ask, size=192,
              log=lambda s: None)
    v.say("who made this")
    settle(v, "answering")
    assert "no Claude key" in v._face_answer.text
    assert v.frame(v.since + OPEN_S + 0.1, 192).shape == (192, 192, 3)


def test_show_answer_from_a_shortcut():
    ctrl = FakeCtrl()
    v = Voice(ctrl, FakeWake(), FakeTranscriber(""), asker=None, size=64, log=lambda s: None)
    assert v.show_answer("Back at six.")
    assert v.state == "answering"
    assert v.show_answer("Another")                # a newer answer takes the face
    assert v._face_answer.text == "Another"


# ---- a wake word of your own, taught through the voice -----------------------------------------
def test_teaching_a_wake_word_through_the_voice(tmp_path, monkeypatch):
    from brain.voice import enroll as E
    from brain.voice import wake as W

    code = np.random.default_rng(11).standard_normal((40, 96)).astype(np.float32)

    def fake_embed(pcm):                       # a symbol per 100 ms of pcm, a vector per symbol
        pcm = np.asarray(pcm, dtype=np.int16)
        n = max(1, int((len(pcm) / 16000 - E.WIN_S) / E.HOP_S) + 1)
        rng = np.random.default_rng(len(pcm))
        out = []
        for i in range(n):
            c = int((i * E.HOP_S + E.WIN_S / 2) * 16000)
            out.append(code[(int(pcm[min(c, len(pcm) - 1)]) // 100) % 40]
                       + rng.standard_normal(96).astype(np.float32) * 0.25)
        return np.array(out, dtype=np.float32)

    class Loaded:
        def __init__(self, name, threshold=0.5, wake_dir=None, front=None):
            self.name, self.label, self.threshold, self.loaded, self.problem = name, name, threshold, True, None
            self.fires, self.score, self.last_fire = 0, 0.0, 0.0

        def feed(self, chunk, now):
            return False

        def peak(self, now=None):
            return 0.0

        def configure(self, **kw):
            pass

        def status(self):
            return {"model": self.name, "loaded": True}

    borrowed = []
    monkeypatch.setattr(W, "make_embedder", lambda front=None: borrowed.append(front) or fake_embed)
    monkeypatch.setattr(W, "WakeWord", Loaded)
    monkeypatch.setattr(W, "models_dir", lambda: None)
    monkeypatch.setattr(W, "CHOICE_PATH", str(tmp_path / "wake.json"))

    v = Voice(FakeCtrl(), FakeWake(), FakeTranscriber(""), asker=None, size=64, log=lambda s: None)
    v.wake_dir = str(tmp_path / "own")
    assert v.enroll_start("Hey  Wall", samples=3)["enroll"]["stage"] == "takes"
    assert v.state == "enrolling" and v.enroll_start("again")["error"]
    assert v.enroll_start.__self__ is v and Voice.enroll_start(v, "x")["error"]      # too short a phrase
    t = 100.0

    def feed(symbols, voiced):
        nonlocal t
        for sym in symbols:
            t += 0.1
            v.feed(np.full(1600, 100 * sym, dtype=np.int16).tobytes(), -20.0 if voiced else -50.0, -50.0, t)

    frames = []
    for _ in range(3):
        feed([1] * 10, False)
        feed([5, 9, 13, 17, 21], True)
        frames.append(v.frame(t, 64))
        feed([1] * 10, False)
    assert v.enroller.stage == "talk" and len(v.enroller.takes) == 3
    assert v.meter()["enroll"]["talk_left"] is not None
    big = v.frame(t, 192)
    assert big is not None and big.shape == (192, 192, 3)
    rng = np.random.default_rng(2)
    feed([int(rng.choice([2, 3, 23, 30, 31])) for _ in range(101)], True)
    t0 = time.monotonic()
    while v.enroller.stage not in ("done", "failed") and time.monotonic() - t0 < 10:
        time.sleep(0.02)
    e = v.enroller
    assert e.stage == "done", e.problem
    assert v.wake.name == "own:hey-wall" and W.saved_choice(str(tmp_path / "wake.json")) == "own:hey-wall"
    assert borrowed == [None]                  # the fake wake word has no front end to lend
    st = v.status()
    assert any(c["name"] == "own:hey-wall" and c["label"] == "Hey Wall" for c in st["wake_choices"])
    assert st["enroll"]["stage"] == "done" and st["enroll"]["quality"] in ("good", "fair", "poor")
    assert all(f is not None and f.shape == (64, 64, 3) for f in frames)
    assert v.forget_wake("own:hey-wall")["error"]            # in use
    e.finished_at -= 4.0                                     # three seconds on, the wall is its own again
    assert v.frame(t, 64) is None and v.state == "idle"

    # taught again, then walked away from: it stops, and the wall listens again
    assert v.enroll_start("Okay Tessera", samples=3)["enroll"]["stage"] == "takes"
    feed([1] * int(E.IDLE_S * 10 + 5), False)
    assert v.state == "idle" and v.enroller.stage == "cancelled" and v.status()["enroll"]["event"] == "idle"
