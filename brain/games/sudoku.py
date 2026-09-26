"""Sudoku on the wall.

The phone is where it is played, by touch: pick a cell, pick a digit. The
wall is the grid, fitted to the complete panel at 64, 192 and 512.
Givens are white, the player's digits blue, wrong digits red and
underlined. Selection lights the row, column, box and matching digits.
Pencil notes stay in each cell; entry and note edits can be undone. Voice works too: "row three column four is seven" or
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
from .board import WHITE, blank, fill, text

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
_SAY = re.compile(r"^(?:(clear|erase|remove)\s+)?(?:row\s+)?(\w+)\s*(?:,|and)?\s*(?:column\s+|col\s+)?(\w+)"
                  r"(?:\s*(?:is|equals|to|put|=)?\s*(\w+))?[.!?]*$")
_NUM = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "to": 2, "too": 2, "for": 4, "won": 1}


def _num(w: str) -> int | None:
    w = w.lower()
    if re.fullmatch(r"[0-9]", w):
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


def valid_grid(grid: list[int]) -> bool:
    """Reject malformed givens before either solver can accept a full board."""
    return (len(grid) == 81
            and all(type(value) is int and 0 <= value <= 9 for value in grid)
            and all(not value or all(grid[peer] != value for peer in PEERS[index])
                    for index, value in enumerate(grid)))


def count_solutions(grid: list[int], limit: int = 2, work: list | None = None) -> int:
    """Count up to limit; validate once, before descending into the search."""
    grid = list(grid)
    if not valid_grid(grid) or type(limit) is not int or limit < 1:
        return 0

    def count(cap: int) -> int:
        best, best_c = -1, None
        for index in range(81):
            if grid[index] == 0:
                choices = candidates(grid, index)
                if not choices:
                    return 0
                if best_c is None or len(choices) < len(best_c):
                    best, best_c = index, choices
                    if len(choices) == 1:
                        break
        if best < 0:
            return 1
        if work is not None and len(best_c) > 1:
            work.append(len(best_c))
        found = 0
        for value in sorted(best_c):
            grid[best] = value
            found += count(cap - found)
            if found >= cap:
                break
        grid[best] = 0
        return found

    return count(limit)


def solve(grid: list[int]) -> list[int] | None:
    grid = list(grid)
    if not valid_grid(grid):
        return None
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
        if "puzzle" in self.options:
            raw = str(self.options["puzzle"])
            if not re.fullmatch(r"[0-9.\s]+", raw):
                raise ValueError("a puzzle is 81 digits; use zero or a dot for blanks")
            p = [0 if ch == "." else int(ch) for ch in raw if not ch.isspace()]
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
        self.notes: dict[int, set[int]] = {}
        self._undo: list[tuple] = []
        self.message = f"{self.rating.capitalize()}. {81 - sum(1 for v in self.puzzle if v)} to fill."

    # ---- moves ----------------------------------------------------------------------------------
    def _remember(self):
        self._undo.append((list(self.grid), {i: set(values) for i, values in self.notes.items()},
                           set(self.wrong), self.chosen))
        self._undo = self._undo[-100:]

    def _remaining_message(self):
        empty = self.grid.count(0)
        if self.wrong:
            return f"{empty} to fill. {len(self.wrong)} to correct."
        return f"{empty} to fill."

    @staticmethod
    def _digit(value, allow_clear=False):
        if allow_clear and value in ("", "clear"):
            return 0
        if type(value) is int:
            return value if (0 if allow_clear else 1) <= value <= 9 else None
        if isinstance(value, str) and re.fullmatch(r"[0-9]", value):
            digit = int(value)
            return digit if (allow_clear or digit > 0) else None
        return None

    def apply(self, move: dict, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        if move.get("undo") is True:
            if not self._undo:
                return {"error": "nothing to undo yet"}
            self.grid, self.notes, self.wrong, self.chosen = self._undo.pop()
            self.message = self._remaining_message()
            self.changed()
            return {"undone": True}
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
        if "note" in move:
            digit = self._digit(move["note"])
            if digit is None:
                return {"error": "a note is a digit, one to nine"}
            if self.grid[i]:
                return {"error": "erase this entry before adding notes"}
            self._remember()
            values = self.notes.setdefault(i, set())
            if digit in values:
                values.remove(digit)
            else:
                values.add(digit)
            if not values:
                self.notes.pop(i, None)
            self.chosen = i
            self.message = "Pencil notes saved."
            self.changed()
            return {"cell": i, "notes": sorted(self.notes.get(i, set()))}
        if "digit" not in move and "value" not in move:
            return {"error": "choose a digit or erase the cell"}
        digit = self._digit(move.get("digit", move.get("value")), allow_clear=True)
        if digit is None:
            return {"error": "a digit, one to nine; zero to erase"}
        if self.grid[i] != digit or self.notes.get(i):
            self._remember()
        self.grid[i] = digit
        self.notes.pop(i, None)
        self.chosen = i
        if digit and digit != self.solution[i]:
            self.wrong.add(i)
            self.message = "That one is wrong. Try another digit or undo."
        else:
            self.wrong.discard(i)
            if digit:
                for peer in PEERS[i]:
                    if peer in self.notes:
                        self.notes[peer].discard(digit)
                        if not self.notes[peer]:
                            self.notes.pop(peer)
            self.message = self._remaining_message()
        if self.grid == self.solution:
            self.finish(won=True, message="Solved. Every number in its place.")
        else:
            self.changed()
        return {"cell": i, "digit": digit, "right": digit == self.solution[i]}

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
        if type(v) is int:
            return v if 0 <= v < 81 else None
        if isinstance(v, (list, tuple)) and len(v) == 2:
            r, c = v
            if type(r) is int and type(c) is int and 0 <= r < 9 and 0 <= c < 9:
                return r * 9 + c
        if isinstance(v, str) and re.fullmatch(r"[0-9]{1,2}", v) and 0 <= int(v) < 81:
            return int(v)
        return None

    def state(self) -> dict:
        return {"puzzle": "".join(str(v) for v in self.puzzle), "grid": "".join(str(v) for v in self.grid),
                "solution": "".join(str(v) for v in self.solution) if self.over else None,
                "wrong": sorted(self.wrong), "chosen": self.chosen, "rating": self.rating,
                "left": self.grid.count(0),
                "notes": {str(i): sorted(values) for i, values in self.notes.items()},
                "can_undo": bool(self._undo) and not self.over,
                "remaining": sum(value != self.solution[i] for i, value in enumerate(self.grid)),
                "filled_by_you": sum(bool(value) and not self.puzzle[i] and i not in self.wrong
                                     for i, value in enumerate(self.grid))}

    def voice_words(self) -> list[str]:
        return ["row", "column", "clear"] + list(_NUM)[:9]

    # ---- the wall --------------------------------------------------------------------------------
    @staticmethod
    def board_geometry(size: int) -> tuple[int, int, int]:
        margin = 0 if size <= 96 else max(2, size // 64)
        cell = max(1, (size - margin * 2) // 9)
        origin = (size - cell * 9) // 2
        return origin, origin, cell

    def frame_at(self, size: int, t: float):
        from .board import rect
        canvas = blank(size)
        canvas[:] = (11, 10, 9)
        x0, y0, cell = self.board_geometry(size)
        extent = cell * 9
        fill(canvas, x0, y0, extent, extent, (22, 24, 27))
        chosen = self.chosen if self.chosen is not None and not self.over else None
        if chosen is not None:
            row, column = divmod(chosen, 9)
            fill(canvas, x0, y0 + row * cell, extent, cell, (29, 36, 44))
            fill(canvas, x0 + column * cell, y0, cell, extent, (29, 36, 44))
            fill(canvas, x0 + column // 3 * cell * 3, y0 + row // 3 * cell * 3,
                 cell * 3, cell * 3, (32, 40, 49))
            selected = self.grid[chosen]
            if selected:
                for index, value in enumerate(self.grid):
                    if value == selected:
                        r, col = divmod(index, 9)
                        fill(canvas, x0 + col * cell, y0 + r * cell, cell, cell, (38, 53, 65))
            fill(canvas, x0 + column * cell, y0 + row * cell, cell, cell, (43, 67, 85))
        for index in range(81):
            row, column = divmod(index, 9)
            x, y = x0 + column * cell, y0 + row * cell
            value = self.grid[index]
            if value:
                colour = WHITE if self.puzzle[index] else (224, 76, 63) if index in self.wrong else (157, 205, 231)
                if cell < 12:
                    self._small_digit(canvas, str(value), x + (cell - 3) // 2 + 1, y + (cell - 5) // 2, colour)
                else:
                    scale = max(1, (cell - 5) // 7)
                    text(canvas, str(value), x + (cell - 5 * scale) // 2,
                         y + (cell - 7 * scale) // 2, colour, scale)
                if index in self.wrong:
                    # An underline marks an incorrect entry even without colour.
                    fill(canvas, x + 2, y + cell - 2, max(2, cell - 4), 1, (255, 167, 143))
            elif self.notes.get(index):
                for digit in self.notes[index]:
                    nr, nc = divmod(digit - 1, 3)
                    if cell < 12:
                        fill(canvas, x + 1 + nc * 2, y + 1 + nr * 2, 1, 1, (135, 162, 181))
                    else:
                        step = (cell - 2) / 3
                        xx = x + 1 + round(nc * step + (step - 3) / 2)
                        yy = y + 1 + round(nr * step + (step - 5) / 2)
                        self._small_digit(canvas, str(digit), xx, yy, (135, 162, 181))
        for line_ in range(10):
            strong = line_ % 3 == 0
            colour = (116, 126, 134) if strong else (54, 62, 69)
            thickness = max(1, round(size / 96)) if strong else max(1, size // 256)
            position = line_ * cell
            edge = thickness if line_ == 9 else 0
            fill(canvas, x0 + position - edge, y0, thickness, extent, colour)
            fill(canvas, x0, y0 + position - edge, extent, thickness, colour)
        if chosen is not None:
            row, column = divmod(chosen, 9)
            rect(canvas, x0 + column * cell, y0 + row * cell, cell, cell, (162, 211, 240), max(1, round(size / 96)))
        elif self.over:
            rect(canvas, x0, y0, extent, extent, (163, 207, 155), max(1, round(size / 96)))
        return canvas

    @staticmethod
    def _small_digit(canvas, digit, x, y, colour):
        for dy, row in enumerate(DIGITS_3X5[digit]):
            for dx, bit in enumerate(row):
                if bit == "1" and 0 <= y + dy < canvas.shape[0] and 0 <= x + dx < canvas.shape[1]:
                    canvas[y + dy, x + dx] = colour
