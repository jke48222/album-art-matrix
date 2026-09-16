"""Sudoku on the wall.

The phone is where it is played, by touch: pick a cell, pick a digit. The
wall is the grid, big enough to read from the sofa: at 64 each cell is
7 pixels with the 3x3 boxes marked by brighter lines, digits in a 3x5
font; at 192 the cells are 21 pixels and the digits the 5x7 font at 2x.
Givens are white, the player's digits the accent, a wrong digit red, the
chosen cell lit. Voice works too: "row three column four is seven" or
"three four seven", and "clear three four".

Puzzles are our own: a full grid is made by a randomised backtracking
fill, then digits are removed one at a time while a counting solver still
finds exactly one solution. The difficulty is rated by how the counting
solver had to work: easy puzzles fall to single candidates, hard ones
need guessing. Options: {"difficulty": "easy" | "medium" | "hard",
"seed": n}.
"""
from __future__ import annotations

import random
import re


from . import Game, register
from .board import (BLACK, EDGE, INK, RED, WHITE, banner, blank, fill, header, mix,
                    text)

DIGITS_3X5 = {
    "1": ["010", "110", "010", "010", "111"],
    "2": ["111", "001", "111", "100", "111"],
    "3": ["111", "001", "111", "001", "111"],
    "4": ["101", "101", "111", "001", "001"],
    "5": ["111", "100", "111", "001", "111"],
    "6": ["111", "100", "111", "101", "111"],
    "7": ["111", "001", "001", "010", "010"],
    "8": ["111", "101", "111", "101", "111"],
    "9": ["111", "101", "111", "001", "111"],
}
ACCENT = (120, 180, 250)
CHOSEN = (40, 60, 90)
_SAY = re.compile(r"^(?:(clear|erase|remove)\s+)?(?:row\s+)?(\w+)\s*(?:,|and)?\s*(?:column\s+|col\s+)?(\w+)"
                  r"(?:\s*(?:is|equals|to|put|=)?\s*(\w+))?[.!?]*$")
_NUM = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "to": 2, "too": 2, "for": 4, "won": 1}


def _num(w: str) -> int | None:
    w = w.lower()
    if w.isdigit():
        n = int(w)
        return n if 1 <= n <= 9 else None
    return _NUM.get(w)


# ---- the solver -----------------------------------------------------------------------------
def _peers():
    out = []
    for i in range(81):
        r, c = divmod(i, 9)
        s = set()
        for k in range(9):
            s.add(r * 9 + k)
            s.add(k * 9 + c)
        br, bc = (r // 3) * 3, (c // 3) * 3
        for rr in range(br, br + 3):
            for cc in range(bc, bc + 3):
                s.add(rr * 9 + cc)
        s.discard(i)
        out.append(sorted(s))
    return out


PEERS = _peers()


def candidates(grid: list[int], i: int) -> set[int]:
    return set(range(1, 10)) - {grid[p] for p in PEERS[i]}


def count_solutions(grid: list[int], limit: int = 2, work: list | None = None) -> int:
    """How many solutions, up to `limit`. `work` collects (guesses) for the
    rating: every branch the solver had to open."""
    grid = list(grid)
    # the emptiest cell first
    best, best_c = -1, None
    for i in range(81):
        if grid[i] == 0:
            c = candidates(grid, i)
            if not c:
                return 0
            if best_c is None or len(c) < len(best_c):
                best, best_c = i, c
                if len(c) == 1:
                    break
    if best < 0:
        return 1
    if work is not None and len(best_c) > 1:
        work.append(len(best_c))
    n = 0
    for v in sorted(best_c):
        grid[best] = v
        n += count_solutions(grid, limit - n, work)
        if n >= limit:
            break
    grid[best] = 0
    return n


def solve(grid: list[int]) -> list[int] | None:
    grid = list(grid)
    def go() -> bool:
        best, best_c = -1, None
        for i in range(81):
            if grid[i] == 0:
                c = candidates(grid, i)
                if not c:
                    return False
                if best_c is None or len(c) < len(best_c):
                    best, best_c = i, c
                    if len(c) == 1:
                        break
        if best < 0:
            return True
        for v in sorted(best_c):
            grid[best] = v
            if go():
                return True
        grid[best] = 0
        return False
    return grid if go() else None


def full_grid(rng: random.Random) -> list[int]:
    grid = [0] * 81
    def go(i: int) -> bool:
        if i == 81:
            return True
        vals = list(candidates(grid, i))
        rng.shuffle(vals)
        for v in vals:
            grid[i] = v
            if go(i + 1):
                return True
        grid[i] = 0
        return False
    go(0)
    return grid


def rate(puzzle: list[int]) -> tuple[str, int]:
    """("easy" | "medium" | "hard", guesses the counting solver needed)."""
    work: list = []
    count_solutions(puzzle, limit=1, work=work)
    guesses = len(work)
    if guesses == 0:
        return "easy", 0
    if guesses <= 6:
        return "medium", guesses
    return "hard", guesses


def make_puzzle(rng: random.Random, difficulty: str = "medium") -> tuple[list[int], list[int], str]:
    """(puzzle, solution, rating). Digits come out while the puzzle stays
    unique; the target number of givens sets the difficulty, checked by
    the rating, with a few tries to land in the band asked for."""
    targets = {"easy": 40, "medium": 32, "hard": 26}
    want = targets.get(difficulty, 32)
    best = None
    for _ in range(12):
        solution = full_grid(rng)
        puzzle = list(solution)
        order = list(range(81))
        rng.shuffle(order)
        givens = 81
        for i in order:
            if givens <= want:
                break
            keep = puzzle[i]
            puzzle[i] = 0
            if count_solutions(puzzle, limit=2) != 1:
                puzzle[i] = keep
            else:
                givens -= 1
        rating, guesses = rate(puzzle)
        if best is None or abs(guesses - {"easy": 0, "medium": 3, "hard": 12}[difficulty if difficulty in targets else "medium"]) \
                < abs(best[3] - {"easy": 0, "medium": 3, "hard": 12}[difficulty if difficulty in targets else "medium"]):
            best = (puzzle, solution, rating, guesses)
        if rating == difficulty:
            break
    return best[0], best[1], best[2]


@register
class Sudoku(Game):
    name = "sudoku"
    title = "Sudoku"
    blurb = "The grid on the wall, the digits from the phone. Easy, medium or hard."
    min_players = 1
    max_players = 1

    def setup(self):
        rng = random.Random(self.options.get("seed"))
        want = str(self.options.get("difficulty", "medium")).lower()
        if self.options.get("puzzle"):
            p = [int(ch) for ch in str(self.options["puzzle"]) if ch.isdigit()]
            if len(p) != 81:
                raise ValueError("a puzzle is 81 digits")
            sol = solve(p)
            if sol is None or count_solutions(p) != 1:
                raise ValueError("that puzzle has no single solution")
            self.puzzle, self.solution, self.rating = p, sol, rate(p)[0]
        else:
            self.puzzle, self.solution, self.rating = make_puzzle(rng, want)
        self.grid = list(self.puzzle)
        self.chosen: int | None = None
        self.wrong: set[int] = set()
        self.filled = 0
        self.message = f"{self.rating.capitalize()}. {81 - sum(1 for v in self.puzzle if v)} to fill."

    # ---- moves ----------------------------------------------------------------------------------
    def apply(self, move: dict, player: str) -> dict:
        if "choose" in move:
            i = self._cell(move.get("choose"))
            if i is None:
                return {"error": "row and column, one to nine"}
            self.chosen = i
            self.changed()
            return {"chosen": i}
        cell = move.get("cell", move.get("at"))
        i = self._cell(cell) if cell is not None else self.chosen
        if i is None:
            return {"error": "pick a cell first"}
        if self.puzzle[i]:
            return {"error": "that one is given"}
        v = move.get("digit", move.get("value"))
        if v in (None, 0, "0", "", "clear"):
            self.grid[i] = 0
            self.wrong.discard(i)
            self.chosen = i
            self.message = f"{sum(1 for x in self.grid if x == 0)} to fill."
            self.changed()
            return {"cell": i, "digit": 0}
        try:
            d = int(v)
        except (TypeError, ValueError):
            return {"error": "a digit, one to nine"}
        if not 1 <= d <= 9:
            return {"error": "a digit, one to nine"}
        self.grid[i] = d
        self.chosen = i
        if d != self.solution[i]:
            self.wrong.add(i)
            self.message = "That one is wrong."
        else:
            self.wrong.discard(i)
            left = sum(1 for x in self.grid if x == 0)
            self.message = f"{left} to fill." if left else ""
        if self.grid == self.solution:
            self.finish(won=True, message="Solved.")
        else:
            self.changed()
        return {"cell": i, "digit": d, "right": d == self.solution[i]}

    def hear(self, text: str, player: str) -> dict | None:
        m = _SAY.match(text.lower().strip())
        if not m:
            return None
        clear, r, c, d = m.groups()
        rn, cn = _num(r), _num(c)
        if rn is None or cn is None:
            return None
        i = (rn - 1) * 9 + (cn - 1)
        if clear:
            return self.apply({"cell": i, "digit": 0}, player)
        if d is None:
            return self.apply({"choose": i}, player)
        dn = _num(d)
        if dn is None:
            return None
        return self.apply({"cell": i, "digit": dn}, player)

    def _cell(self, v) -> int | None:
        if isinstance(v, int):
            return v if 0 <= v < 81 else None
        if isinstance(v, (list, tuple)) and len(v) == 2:
            r, c = v
            if isinstance(r, int) and isinstance(c, int) and 0 <= r < 9 and 0 <= c < 9:
                return r * 9 + c
        if isinstance(v, str) and v.isdigit() and 0 <= int(v) < 81:
            return int(v)
        return None

    def state(self) -> dict:
        return {"puzzle": "".join(str(v) for v in self.puzzle), "grid": "".join(str(v) for v in self.grid),
                "solution": "".join(str(v) for v in self.solution) if self.over else None,
                "wrong": sorted(self.wrong), "chosen": self.chosen, "rating": self.rating,
                "left": sum(1 for x in self.grid if x == 0)}

    def voice_words(self) -> list[str]:
        return ["row", "column", "clear"] + list(_NUM)[:9]

    # ---- the wall --------------------------------------------------------------------------------
    def frame_at(self, size: int, t: float):
        c = blank(size)
        big = size > 96
        cell = 21 if big else 7
        x0 = (size - 9 * cell) // 2
        y0 = (size - 9 * cell) // 2 if not big else 18
        # the chosen cell's row, column and box, faintly, then the cell
        if self.chosen is not None and not self.over:
            cr, cc = divmod(self.chosen, 9)
            fill(c, x0, y0 + cr * cell, 9 * cell, cell, (14, 16, 24))
            fill(c, x0 + cc * cell, y0, cell, 9 * cell, (14, 16, 24))
            fill(c, x0 + (cc // 3) * 3 * cell, y0 + (cr // 3) * 3 * cell, 3 * cell, 3 * cell, (16, 18, 28))
            fill(c, x0 + cc * cell, y0 + cr * cell, cell, cell, CHOSEN)
        for i in range(81):
            r, col = divmod(i, 9)
            x, y = x0 + col * cell, y0 + r * cell
            v = self.grid[i]
            if v:
                colour = WHITE if self.puzzle[i] else RED if i in self.wrong else ACCENT
                if big:
                    text(c, str(v), x + (cell - 10) // 2 + 1, y + (cell - 14) // 2, colour, 2)
                else:
                    rows = DIGITS_3X5[str(v)]
                    for dy, row in enumerate(rows):
                        for dx, bit in enumerate(row):
                            if bit == "1":
                                c[y + 1 + dy, x + 2 + dx] = colour
        # the lines: faint between cells, firm between boxes
        for k in range(10):
            strong = k % 3 == 0
            colour = EDGE if strong else (28, 28, 34)
            thick = (2 if big else 1) if strong else 1
            pos = k * cell
            fill(c, x0 + pos - (thick if k == 9 else 0), y0, thick, 9 * cell, colour)
            fill(c, x0, y0 + pos - (thick if k == 9 else 0), 9 * cell, thick, colour)
        left = sum(1 for x in self.grid if x == 0)
        if self.over:
            banner(c, size, "Solved.", INK, mix((40, 120, 70), BLACK, 0.45))
        header(c, size, "SUDOKU", f"{self.rating}, {left} left" if not self.over else "", 3 if big else 1, accent=ACCENT)
        return c
