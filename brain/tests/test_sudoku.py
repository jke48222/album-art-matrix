"""Sudoku: the generator makes puzzles with one solution in the band asked
for, moves and spoken moves, the finish, the grid at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_sudoku.py -q
"""
import os
import random
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.sudoku import (full_grid, make_puzzle, count_solutions, solve, rate)   # noqa: E402
from brain.games.host import GameHost                                                        # noqa: E402
from brain.tests.test_games import FakeCtrl                                                  # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def valid(grid):
    for r in range(9):
        if sorted(grid[r * 9:(r + 1) * 9]) != list(range(1, 10)):
            return False
    for c in range(9):
        if sorted(grid[c::9]) != list(range(1, 10)):
            return False
    for br in range(3):
        for bc in range(3):
            box = [grid[(br * 3 + i) * 9 + bc * 3 + j] for i in range(3) for j in range(3)]
            if sorted(box) != list(range(1, 10)):
                return False
    return True


def test_full_grids_are_valid_and_puzzles_unique():
    for seed in range(3):
        rng = random.Random(seed)
        g = full_grid(rng)
        assert valid(g)
        puzzle, solution, rating = make_puzzle(rng, "easy")
        assert valid(solution) and count_solutions(puzzle) == 1 and solve(puzzle) == solution
        assert all(p == 0 or p == s for p, s in zip(puzzle, solution))
        assert 25 <= sum(1 for v in puzzle if v) <= 45
        assert rating in ("easy", "medium", "hard")


def test_difficulty_bands():
    easy = make_puzzle(random.Random(7), "easy")
    hard = make_puzzle(random.Random(7), "hard")
    assert sum(1 for v in easy[0] if v) > sum(1 for v in hard[0] if v)
    assert rate(easy[0])[1] <= rate(hard[0])[1]


def test_play_by_touch_and_voice(tmp_path):
    ctrl = FakeCtrl()
    host = GameHost(ctrl, path=str(tmp_path / "g.json"))
    st = host.start("sudoku", {"seed": 1, "difficulty": "easy"})
    g = host.game
    assert st["game"]["rating"] == g.rating and len(st["game"]["grid"]) == 81 and st["game"]["solution"] is None
    empty = next(i for i in range(81) if g.puzzle[i] == 0)
    r, c = divmod(empty, 9)
    wrong = next(d for d in range(1, 10) if d != g.solution[empty])
    res = host.move(None, {"cell": empty, "digit": wrong})
    assert res["right"] is False and empty in g.wrong and "wrong" in g.message
    res = host.hear(f"row {r + 1} column {c + 1} is {g.solution[empty]}")
    assert res["right"] is True and empty not in g.wrong
    given = next(i for i in range(81) if g.puzzle[i])
    assert host.move(None, {"cell": given, "digit": 5})["error"] == "that one is given"
    assert host.hear("what is the weather") is None
    assert host.hear(f"clear {r + 1} {c + 1}")["digit"] == 0
    # fill the rest from the solution
    for i in range(81):
        if g.puzzle[i] == 0:
            host.move(None, {"cell": i, "digit": g.solution[i]})
    assert g.over and g.won and host.status()["game"]["solution"] == "".join(map(str, g.solution))


def test_the_grid_at_both_sizes(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("sudoku", {"seed": 2, "difficulty": "medium"})
    g = host.game
    empty = [i for i in range(81) if g.puzzle[i] == 0]
    host.move(None, {"cell": empty[0], "digit": g.solution[empty[0]]})
    host.move(None, {"cell": empty[1], "digit": (g.solution[empty[1]] % 9) + 1})
    for size, scale in ((64, 4), (192, 2)):
        f = host.frame_at(size)
        assert f.shape == (size, size, 3)
        assert ((f[..., 0] > 200) & (f[..., 1] > 200)).sum() > 100          # white givens
        assert ((f[..., 0] > 150) & (f[..., 1] < 90)).sum() > 3               # the red one
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"sudoku-{size}.png"))
