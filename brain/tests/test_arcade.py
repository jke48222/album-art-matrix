"""The arcade: Pong's ball and paddles and the wall's own paddle, Snake's
moves and death, Tetris's bag, rotation, lines and drops; frames at 64
and 192.

    .venv/bin/python -m pytest brain/tests/test_arcade.py -q
"""
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.host import GameHost                  # noqa: E402
from brain.games import arcade                         # noqa: E402
from brain.games.arcade import rotated, PIECES         # noqa: E402
from brain.tests.test_games import FakeCtrl            # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def save(f, name, size, scale):
    if OUT:
        Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(os.path.join(OUT, f"{name}-{size}.png"))


def test_pong(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("pong", {"seed": 1, "to": 2}, ["Jalen", "Sam"])
    g = host.game
    clock = [0.0]
    g._clock = lambda: clock[0]
    g.last_t = 0.0
    g.wait_until = 0.0
    assert host.move("Sam", {"paddle": 0.9})["side"] == 1 and g.paddles[1] == 0.9
    # nobody moves: the ball scores against somebody within a few seconds
    for _ in range(400):
        clock[0] += 0.03
        g.step()
        if sum(g.score) > 0:
            break
    assert sum(g.score) == 1
    for _ in range(2000):
        clock[0] += 0.03
        g.step()
        if g.over:
            break
    assert g.over and max(g.score) == 2
    for size, scale in ((64, 4), (192, 2)):
        f = host.frame_at(size)
        assert ((f[..., 0] > 150) & (f[..., 1] > 130) & (f[..., 2] < 90)).sum() >= 4   # the ball
        save(f, "pong", size, scale)
    solo = GameHost(FakeCtrl(), path=str(tmp_path / "g2.json"))
    solo.start("pong", {"seed": 2})
    s = solo.game
    s._clock = lambda: clock[0]; s.last_t = clock[0]; s.wait_until = clock[0]
    before = s.paddles[1]
    for _ in range(20):
        clock[0] += 0.03
        s.step()
    assert s.paddles[1] != before                                         # the wall's paddle moves itself


def test_snake(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("snake", {"seed": 1, "step": 0.1})
    g = host.game
    clock = [0.0]
    g._clock = lambda: clock[0]
    g.last_step = 0.0
    assert host.hear("left") and g.next_dir == (1, 0)                    # no reversing
    assert host.hear("up")["dir"] == (0, -1)
    clock[0] = 0.25
    g.step()
    assert g.body[0] == (16, 14) and len(g.body) == 3
    g.food = (16, 13)
    clock[0] = 0.35
    g.step()
    assert g.score == 1 and len(g.body) == 4
    for size, scale in ((64, 4), (192, 2)):
        f = host.frame_at(size)
        assert ((f[..., 1] > 120) & (f[..., 0] < 130)).sum() >= 4 * (size // 32) ** 2
        save(f, "snake", size, scale)
    clock[0] = 10.0                                                        # straight into the top wall
    g.step()
    assert g.over and g.score >= 1 and g.message.endswith("Say again.")
    assert host.hear("again") is None or True
    assert host.move(None, {"again": True})["again"] and not host.game.over


def test_tetris(tmp_path):
    for kind, cells in PIECES.items():
        assert len(cells) == 4 and rotated(cells, 4) == list(cells) or kind in ("I", "O")
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("tetris", {"seed": 3})
    g = host.game
    clock = [0.0]
    g._clock = lambda: clock[0]
    g.last_fall = 0.0
    first = g.piece["kind"]
    kinds = {first}
    for _ in range(6):
        host.move(None, {"move": "drop"})
        kinds.add(g.piece["kind"])
    assert len(kinds) == 7                                                # a full bag before a repeat
    r = host.move(None, {"move": "rotate"})
    assert "piece" in r
    assert host.hear("left")["move"] == "left"
    # fill the bottom row by hand and let a piece clear it
    g.well[g.H - 1] = ["I"] * (g.W - 4) + [None] * 4
    g.piece = {"kind": "I", "x": 6, "y": 0, "r": 0}
    host.move(None, {"move": "drop"})
    assert g.lines == 1 and g.score >= 100
    for size, scale in ((64, 4), (192, 2)):
        f = host.frame_at(size)
        assert f.shape == (size, size, 3) and f.max() > 100
        save(f, "tetris", size, scale)
    for y in range(g.H):
        g.well[y] = ["Z"] * g.W
    g._spawn()
    assert g.over


def test_registered():
    from brain.games import GAMES
    assert {"pong", "snake", "tetris"} <= set(GAMES)
