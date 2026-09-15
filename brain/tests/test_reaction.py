"""Reaction knock and whistle bird: the ear's knocks and pitch reach the
running game through the host, false starts, the timing on the knock's
own clock, the bird's range and its death, the frames at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_reaction.py -q
"""
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.host import GameHost                    # noqa: E402
from brain.games import reaction, whistlebird            # noqa: E402,F401
from brain.tests.test_games import FakeCtrl              # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def test_reaction_rounds(tmp_path):
    ctrl = FakeCtrl()
    host = GameHost(ctrl, path=str(tmp_path / "g.json"))
    host.start("reaction", {"rounds": 2, "seed": 1}, ["Jalen", "Sam"])
    g = host.game
    clock = [1000.0]
    g._clock = lambda: clock[0]
    assert host.event("knock", {"t": clock[0]}) is False                   # nothing on yet
    assert host.hear("go")["phase"] == "red"
    assert host.event("double", {}) is True                                # swallowed, not a toggle
    clock[0] += 0.5
    assert host.event("knock", {"t": clock[0]}) is True and g.times["Jalen"] == [None]   # too soon
    assert g.phase == "shown"
    clock[0] += 3.0
    g.tick()                                                               # the next round begins itself
    assert g.phase == "red" and g.players[g.turn] == "Sam"
    clock[0] = g.t_go + 0.212
    g.tick()
    assert g.phase == "green"
    assert host.event("knock", {"t": g.t_go + 0.212}) is True
    assert g.times["Sam"] == [212] and g.last_ms == 212
    for _ in range(2):
        clock[0] += 3.0
        g.tick()
        clock[0] = g.t_go + 0.3
        g.tick()
        host.move(None, {"tap": True})
    assert g.over and g.winner == "Sam"
    st = host.status()["game"]
    assert st["best"]["Sam"] == 212


def test_reaction_frames(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    for size, scale in ((64, 4), (192, 2)):
        host.start("reaction", {"rounds": 1})
        g = host.game
        clock = [50.0]
        g._clock = lambda: clock[0]
        g.begin()
        red = host.frame_at(size)
        assert red[..., 0].mean() > 100 and red[..., 1].mean() < 40
        clock[0] = g.t_go + 0.01
        green = host.frame_at(size)
        assert green[..., 1].mean() > 100
        host.event("knock", {"t": g.t_go + 0.187})
        shown = host.frame_at(size)
        assert ((shown[..., 0] > 200) & (shown[..., 1] > 200)).sum() > 30      # the digits
        if OUT:
            Image.fromarray(shown).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"reaction-{size}.png"))


def test_whistle_bird_flies_and_dies(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("whistlebird", {"seed": 1})
    g = host.game
    clock = [0.0]
    g._clock = lambda: clock[0]
    g.last_t = 0.0
    assert host.event("pitch", {"hz": 1000.0, "t": 0.0}) is True
    assert g.target == 0.5                                                 # the range is not known yet
    host.event("pitch", {"hz": 1400.0, "t": 0.0})
    assert g.target == 0.0                                                 # the top of the range: up
    host.event("pitch", {"hz": 1000.0, "t": 0.0})
    assert g.target == 1.0
    host.event("pitch", {"hz": 1200.0, "t": 0.0})
    assert g.target == 0.5
    clock[0] = 0.1
    g.step()
    y0 = g.y
    for k in range(6):                                                     # silence: it sinks
        clock[0] += 0.1
        g.step()
    assert y0 < g.y < 0.99 and not g.dead
    # steer with the phone, fly a while, count pipes
    for k in range(400):
        clock[0] += 0.05
        nxt = next((p for p in g.pipes if p[0] > 0.2), None)
        host.move(None, {"y": nxt[1] if nxt else 0.5})
        g.step()
        if g.dead:
            break
    assert g.score >= 2
    st = host.status()["game"]
    assert "pipes" in st and st["range"] == [1000.0, 1400.0]
    for size, scale in ((64, 4), (192, 2)):
        f = host.frame_at(size)
        assert ((f[..., 1] > 120) & (f[..., 0] < 100)).sum() > 20            # pipes
        assert ((f[..., 0] > 150) & (f[..., 1] > 130) & (f[..., 2] < 90)).sum() >= 4   # the bird
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"whistlebird-{size}.png"))
    # into a pipe: dead
    g.dead = False
    g.y = 0.0
    g.pipes = [[0.25, 0.9, False]]
    g.step()
    assert g.dead and g.over
    assert host.hear("again") is None or host.game.dead is False
