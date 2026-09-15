"""A wake word of your own: the alignment, the calibration, the takes cut
from the stream, keeping and listing, and the wake word choices.

    .venv/bin/python -m pytest brain/tests/test_enroll.py -q
"""
import os
import sys

import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.voice import enroll as E                      # noqa: E402
from brain.voice import wake as W                        # noqa: E402

RATE = E.RATE
HOP = int(E.HOP_S * RATE)


def walk(rng, n, dim=96, step=0.6):
    """A smooth path through embedding space, like a phrase's frames."""
    x = rng.standard_normal(dim)
    out = []
    for _ in range(n):
        x = x + rng.standard_normal(dim) * step
        out.append(x.copy())
    return np.array(out, dtype=np.float32)


def stretched(seq, factor, rng, noise=0.35):
    idx = np.clip(np.round(np.arange(0, len(seq), 1.0 / factor)).astype(int), 0, len(seq) - 1)
    return seq[idx] + rng.standard_normal((len(idx), seq.shape[1])).astype(np.float32) * noise


def test_slug_and_core_frames():
    assert E.slug_of("Hey, Wall!") == "hey-wall" and E.slug_of("   ") == "wake"
    idx = E.core_frames(20, 0.5, 1.1)
    assert idx == sorted(idx) and len(idx) >= 3
    assert all(0.38 <= t * E.HOP_S + E.WIN_S / 2 <= 1.22 for t in idx)
    assert len(E.core_frames(10, 2.0, 2.05, margin_s=0.0)) == 3          # a very short phrase: three frames anyway


def test_alignment_knows_the_same_phrase_at_other_speeds():
    rng = np.random.default_rng(1)
    phrase, other = walk(rng, 12), walk(rng, 12)
    background = rng.standard_normal((8, 96)).astype(np.float32) * 3
    for factor in (0.7, 1.0, 1.4):
        live = np.concatenate([background, stretched(phrase, factor, rng)])
        same = E.subseq_dtw(phrase, live, E.END_SLACK)
        diff = E.subseq_dtw(other, live, E.END_SLACK)
        assert same < diff * 0.6, (factor, same, diff)
    # a phrase long gone does not count when the match must end now
    gone = np.concatenate([stretched(phrase, 1.0, rng), background, background])
    assert E.subseq_dtw(phrase, gone, E.END_SLACK) > E.subseq_dtw(phrase, gone, None) + 0.1
    assert E.subseq_dtw(np.zeros((0, 96)), gone) == 2.0


# a stand-in for the speech embedding: the pcm carries a symbol per 80 ms hop
# (its value), and each frame is that symbol's vector with a little noise
CODEBOOK = np.random.default_rng(7).standard_normal((40, 96)).astype(np.float32)


def sound(symbols, hop_s=E.HOP_S):
    return np.concatenate([np.full(int(hop_s * RATE), 100 * s, dtype=np.int16) for s in symbols])


def fake_embed(pcm):
    pcm = np.asarray(pcm, dtype=np.int16)
    n = max(1, int((len(pcm) / RATE - E.WIN_S) / E.HOP_S) + 1)
    rng = np.random.default_rng(len(pcm))
    out = []
    for t in range(n):
        centre = int((t * E.HOP_S + E.WIN_S / 2) * RATE)
        sym = int(pcm[min(centre, len(pcm) - 1)] // 100)
        out.append(CODEBOOK[sym % 40] + rng.standard_normal(96).astype(np.float32) * 0.25)
    return np.array(out, dtype=np.float32)


PHRASE = [5, 5, 9, 9, 13, 13, 17, 17]


def take(rng, speed=1.0):
    syms = [s for s in PHRASE for _ in range(1 if rng.random() > (speed - 0.9) else 2)]
    pad = [0] * 7
    pcm = sound(pad + syms + pad)
    return pcm, len(pad) * E.HOP_S, (len(pad) + len(syms)) * E.HOP_S


def talk(rng, seconds=10.0):
    return sound([int(rng.choice([1, 2, 3, 21, 22, 23, 30, 31])) for _ in range(int(seconds / E.HOP_S))])


def best_moment(m, embed, rng):
    """The live stream is scored every 80 ms, and a phrase scores best about
    half a second after it ends, once the frames that hear its end exist."""
    pre = talk(rng, 1.5)
    pcm, _, s1 = take(rng)
    full = np.concatenate([pre, pcm])
    end = len(pre) + int(s1 * RATE)
    return max(m.score(embed(full[:n])[-m.window:]) for n in range(end, len(full) + 1, HOP))


def worst_talk(m, embed, rng):
    frames = embed(talk(rng, 6.0))
    return max(m.score(frames[j - m.window:j]) for j in range(m.window, len(frames) + 1))


def test_build_calibrates_and_scores():
    rng = np.random.default_rng(3)
    takes = [take(rng, 1.0 + 0.05 * i) for i in range(6)]
    model = E.build("Hey Wall", takes, talk(rng), fake_embed)
    assert model["phrase"] == "Hey Wall" and len(model["templates"]) == 6
    assert model["neg_ref"] > model["pos_ref"] and model["quality"] == "good" and model["mean"].shape == (96,)
    m = E.matcher_of(model)
    assert best_moment(m, fake_embed, rng) >= 0.75 and worst_talk(m, fake_embed, rng) < 0.5
    with pytest.raises(ValueError):
        E.build("x", takes[:2], talk(rng), fake_embed)


def test_the_rooms_own_sound_is_taken_out():
    """A loud room adds the same thing to every frame; without taking it out,
    everything said in that room looks like the phrase."""
    rng = np.random.default_rng(6)
    room = np.random.default_rng(60).standard_normal(96).astype(np.float32) * 2.5

    def in_the_room(pcm):
        return fake_embed(pcm) + room

    model = E.build("Hey Wall", [take(rng, 1.0 + 0.05 * i) for i in range(6)], talk(rng), in_the_room)
    m = E.matcher_of(model)
    assert best_moment(m, in_the_room, rng) >= 0.75 and worst_talk(m, in_the_room, rng) < 0.5
    no = in_the_room(talk(rng, 3.0))
    plain = E.Matcher([t + model["mean"] for t in model["templates"]], 0.0, 1.0)     # the room left in
    assert plain.distance(no) < m.distance(no) * 0.7                                  # talk looks nearer


def test_keep_list_load_forget(tmp_path):
    rng = np.random.default_rng(4)
    model = E.build("Hey Wall", [take(rng) for _ in range(5)], talk(rng), fake_embed)
    name = E.save(model, str(tmp_path))
    assert name == "own:hey-wall"
    listed = E.listing(str(tmp_path))
    assert listed == [{"name": "own:hey-wall", "label": "Hey Wall", "kind": "own", "quality": model["quality"],
                       "created": listed[0]["created"], "samples": 5}]
    meta, m = E.load("hey-wall", str(tmp_path))
    assert meta["phrase"] == "Hey Wall" and len(m.templates) == 5 and m.pos_ref == pytest.approx(model["pos_ref"])
    assert np.allclose(m.mean, model["mean"])
    assert E.forget("hey-wall", str(tmp_path)) and E.listing(str(tmp_path)) == []
    assert not E.forget("hey-wall", str(tmp_path))


CHUNK = int(0.1 * RATE)


def chunks(seconds, level):
    return [(bytes(2 * CHUNK), level)] * int(round(seconds / 0.1))


def test_the_takes_are_cut_from_the_stream():
    en = E.Enroller("hey wall", samples=3, talk_s=1.0)
    t = 0.0
    def feed(seq):
        nonlocal t
        for ch, level in seq:
            en.feed(ch, level, -60.0, t)
            t += 0.1
    feed(chunks(1.0, -60) + chunks(0.6, -40) + chunks(0.6, -60))
    assert len(en.takes) == 1 and en.last_event == "take" and en.message == "Good. 2 more."
    pcm, start, end = en.takes[0]
    assert start == pytest.approx(0.5) and end == pytest.approx(1.1) and len(pcm) >= int(1.5 * RATE)
    feed(chunks(0.5, -60) + chunks(0.1, -40) + chunks(1.0, -60))     # past the pause, a knock, not a take
    assert en.rejected == 1 and en.last_event == "short"
    feed(chunks(2.6, -40) + chunks(1.0, -60))                        # talking on, not the phrase
    assert en.rejected == 2 and en.last_event == "long"
    feed(chunks(0.7, -40) + chunks(1.0, -60) + chunks(0.5, -40) + chunks(0.6, -60))
    assert len(en.takes) == 3 and en.stage == "talk" and en.public(t)["talk_left"] is not None
    feed(chunks(1.2, -45))
    assert en.stage == "building" and len(en.talk) >= 10
    pub = en.public(t)
    assert pub["takes"] == 3 and pub["samples"] == 3 and pub["rejected"] == 2 and pub["phrase"] == "hey wall"


def test_wake_word_choices_labels_and_the_kept_choice(tmp_path):
    models = tmp_path / "models"
    models.mkdir()
    for f in ("alexa_v0.1.onnx", "embedding_model.onnx", "hey_jarvis_v0.1.onnx", "timer_v0.1.onnx",
              "hey_marvin_v0.1.onnx", "melspectrogram.onnx"):
        (models / f).write_bytes(b"")
    assert W.bundled(str(models)) == ["hey_jarvis", "hey_marvin", "alexa"]
    assert W.label_of("hey_jarvis") == "Hey Jarvis" and W.label_of("/x/hey_marvin_v0.1.onnx") == "Hey Marvin"
    own = tmp_path / "own"
    rng = np.random.default_rng(5)
    E.save(E.build("Okay Tessera", [take(rng) for _ in range(4)], talk(rng), fake_embed), str(own))
    names = [c["name"] for c in W.choices(str(own), str(models))]
    assert names == ["hey_jarvis", "hey_marvin", "alexa", "own:okay-tessera"]
    assert W.label_of("own:okay-tessera", str(own)) == "Okay Tessera"
    kept = str(tmp_path / "wake.json")
    assert W.saved_choice(kept) is None
    W.save_choice("own:okay-tessera", kept)
    assert W.saved_choice(kept) == "own:okay-tessera"
    # each word keeps its own sensitivity, and the kinds have their own defaults
    assert W.threshold_for("own:okay-tessera", kept) == W.OWN_THRESHOLD
    assert W.threshold_for("hey_jarvis", kept) == W.DEFAULT_THRESHOLD
    W.save_threshold("own:okay-tessera", 0.82, kept)
    W.save_threshold("hey_jarvis", 0.4, kept)
    W.save_choice("hey_jarvis", kept)                                   # choosing keeps the sensitivities
    assert W.saved_choice(kept) == "hey_jarvis" and W.threshold_for("own:okay-tessera", kept) == 0.82
    assert W.threshold_for("hey_jarvis", kept) == 0.4
    W.forget_threshold("own:okay-tessera", kept)
    assert W.threshold_for("own:okay-tessera", kept) == W.OWN_THRESHOLD and W.saved_threshold("hey_jarvis", kept) == 0.4
    missing = W.WakeWord("own:nothing-here", wake_dir=str(own))
    assert not missing.loaded and missing.problem and missing.status()["kind"] == "own"


def test_teaching_stops_by_itself():
    en = E.Enroller("hey wall", samples=3)
    t = 0.0
    while en.stage == "takes" and t < E.IDLE_S + 5:                   # nobody says anything
        en.feed(bytes(2 * CHUNK), -60.0, -60.0, t)
        t += 0.1
    assert en.stage == "cancelled" and en.last_event == "idle" and E.IDLE_S <= t <= E.IDLE_S + 0.3
    en = E.Enroller("hey wall", samples=3)
    t = 0.0
    while en.stage == "takes" and t < E.TAKES_MAX_S + 10:             # a television, talking on
        for voiced in [True] * 30 + [False] * 6:
            en.feed(bytes(2 * CHUNK), -40.0 if voiced else -60.0, -60.0, t)
            t += 0.1
    assert en.stage == "cancelled" and "too long" in en.message and en.rejected > 50
