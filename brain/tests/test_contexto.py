"""Contexto: the vector file, ranks, guesses by voice, giving up, the face
at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_contexto.py -q
"""
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.contexto import vectors, ranking, colour_of   # noqa: E402
from brain.games.host import GameHost                          # noqa: E402
from brain.tests.test_games import FakeCtrl                    # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def test_vectors_and_ranks():
    vocab, M, index = vectors()
    assert len(vocab) == 20000 and M.shape == (20000, 50)
    r = ranking("king")
    assert r[index["king"]] == 1 and r[index["queen"]] < 20 and r[index["banana"]] > 2000
    assert colour_of(1) == colour_of(300) and colour_of(301) != colour_of(300)


def test_play(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("contexto", {"word": "guitar"}, ["Jalen"])
    g = host.game
    r = host.hear("piano", "Jalen")
    assert r["rank"] < 60 and r["best"] == r["rank"]
    assert host.hear("what is the time", "Jalen") is None
    assert host.move("Jalen", {"word": "zzzq"})["error"].endswith("not in the list")
    r2 = host.move("Jalen", {"word": "banana"})
    assert r2["rank"] > r["rank"] and g.best == r["rank"]
    assert host.status()["game"]["guesses"][0]["word"] == "piano"          # best first
    assert host.hear("piano", "Jalen")["again"]
    r3 = host.hear("guitar", "Jalen")
    assert r3["rank"] == 1 and g.over and g.won and g.message == "GUITAR in 3."
    host.start("contexto", {"seed": 5})
    assert host.hear("give up")["secret"] == host.game.secret and host.game.over


def test_the_face_at_both_sizes(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("contexto", {"word": "guitar"})
    host.move(None, {"word": "banana"})
    for size, scale in ((64, 4), (192, 2)):
        f = host.frame_at(size)
        assert f.shape == (size, size, 3)
        assert ((f[..., 0] > 150) & (f[..., 1] < 90)).sum() > 10             # red digits, far away
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"contexto-{size}.png"))
