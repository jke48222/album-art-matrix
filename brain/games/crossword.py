"""The mini crossword on the wall.

Five by five with a few black squares, the clues on the phone, the
letters by voice ("one across is crane", "three down, opera") or typed
on the phone. The wall is the grid: the black squares, the numbers in the
corners at 192, the letters as they land, the chosen word lit, a wrong
letter shown when the puzzle is checked.

The fills are our own: a symmetric pattern of blacks is chosen, then the
slots are filled from the common words by backtracking, most constrained
slot first, so every across and down word is a real one. Claude writes
the clues when a key is on the wall; without one the wall uses its own
puzzles below, clued by hand. Options: {"set": n}, {"seed": n}.
"""
from __future__ import annotations

import random
import re

from . import Game, register
from .board import (BLACK, DIM, EDGE, FAINT, INK, RED, SLATE, SLATE2, WHITE, YELLOW, banner, blank, fill, header,
                    mix, rounded, text, letter_tile)
from .words import common

N = 5
# black squares as (row, col); each pattern is rotationally symmetric
PATTERNS = [
    [],
    [(0, 0), (4, 4)],
    [(0, 4), (4, 0)],
    [(0, 0), (0, 4), (4, 0), (4, 4)],
    [(0, 0), (1, 0), (3, 4), (4, 4)],
    [(0, 3), (0, 4), (4, 0), (4, 1)],
    [(0, 0), (0, 1), (4, 3), (4, 4)],
    [(0, 0), (0, 1), (1, 0), (4, 4), (4, 3), (3, 4)],
]

# hand-clued puzzles for a wall with no key: (blacks, rows, clues by slot)
BUNDLED = [
    ([(0, 0), (4, 4)],
     ["_lamp", "irony", "vinyl", "ester", "date_"],
     {"1A": "Bedside light", "5A": "Rain on your wedding day, per Alanis", "6A": "What a record is pressed on",
      "7A": "Fragrant compound in perfume", "8A": "Calendar square", "1D": "Toy that spins", "2D": "Country, in short",
      "3D": "Bird of the night", "4D": "Small ones are put in a stroller? No: to enter data", "5D": "Frozen water"}),
]
_SAY = re.compile(r"^(?:(\w+)\s*(across|down|a|d)\s*(?:is|,|:)?\s*([a-z]+))[.!?]*$")
_NUM = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10}


def slots(blacks: set[tuple[int, int]]) -> list[dict]:
    """The across and down slots of two letters or more, numbered the
    crossword way."""
    out = []
    number = 0
    numbered: dict[tuple[int, int], int] = {}
    for r in range(N):
        for c in range(N):
            if (r, c) in blacks:
                continue
            starts_across = (c == 0 or (r, c - 1) in blacks) and c + 1 < N and (r, c + 1) not in blacks
            starts_down = (r == 0 or (r - 1, c) in blacks) and r + 1 < N and (r + 1, c) not in blacks
            if starts_across or starts_down:
                number += 1
                numbered[(r, c)] = number
            if starts_across:
                cells = []
                cc = c
                while cc < N and (r, cc) not in blacks:
                    cells.append((r, cc)); cc += 1
                out.append({"id": f"{number}A", "n": number, "dir": "across", "cells": cells})
            if starts_down:
                cells = []
                rr = r
                while rr < N and (rr, c) not in blacks:
                    cells.append((rr, c)); rr += 1
                out.append({"id": f"{number}D", "n": number, "dir": "down", "cells": cells})
    return out


def fill_grid(blacks: set[tuple[int, int]], rng: random.Random, words_by_len: dict[int, list[str]],
              tries: int = 4000) -> dict[tuple[int, int], str] | None:
    """Letters for every white cell such that every slot is a word."""
    sl = slots(blacks)
    grid: dict[tuple[int, int], str] = {}
    used: set[str] = set()
    budget = [tries]

    def fits(slot) -> list[str]:
        pat = [grid.get(cell) for cell in slot["cells"]]
        n = len(pat)
        out = []
        for w in words_by_len.get(n, ()):
            if w in used:
                continue
            if all(p is None or p == ch for p, ch in zip(pat, w)):
                out.append(w)
        return out

    def go(done: set[str]) -> bool:
        budget[0] -= 1
        if budget[0] < 0:
            raise TimeoutError
        left = [s for s in sl if s["id"] not in done]
        if not left:
            return True
        # most constrained first
        best, best_fits = None, None
        for s_ in left:
            f = fits(s_)
            if not f:
                return False
            if best_fits is None or len(f) < len(best_fits):
                best, best_fits = s_, f
        rng.shuffle(best_fits)
        for w in best_fits[:40]:
            before = dict(grid)
            for cell, ch in zip(best["cells"], w):
                grid[cell] = ch
            used.add(w)
            if go(done | {best["id"]}):
                return True
            used.discard(w)
            grid.clear(); grid.update(before)
        return False

    try:
        ok = go(set())
    except TimeoutError:
        return None
    return dict(grid) if ok else None


@register
class Crossword(Game):
    name = "crossword"
    title = "Mini crossword"
    blurb = "Five by five. Clues on the phone, answers by voice or by typing."
    min_players = 1
    max_players = 4

    def setup(self):
        rng = random.Random(self.options.get("seed"))
        asker = getattr(getattr(self.host, "ctrl", None), "asker", None)
        can_clue = asker is not None and getattr(asker, "ready", False)
        chosen = None
        if self.options.get("set") is None and can_clue:
            words = common(3, 5, 8000)
            by_len: dict[int, list[str]] = {}
            for w in words:
                by_len.setdefault(len(w), []).append(w)
            for pattern in rng.sample(PATTERNS, len(PATTERNS)):
                blacks = set(pattern)
                grid = fill_grid(blacks, rng, by_len)
                if grid is None:
                    continue
                sl = slots(blacks)
                answers = {s["id"]: "".join(grid[c] for c in s["cells"]) for s in sl}
                clues = None
                try:
                    clues = asker.crossword_clues(sorted(set(answers.values())))
                except Exception as exc:
                    print(f"[games] clues from Claude: {exc}", flush=True)
                if clues:
                    chosen = (blacks, grid, {sid: clues[w] for sid, w in answers.items()})
                    break
        if chosen is None:
            n = self.options.get("set")
            blacks_l, rows, clues = BUNDLED[int(n) % len(BUNDLED)] if n is not None else rng.choice(BUNDLED)
            blacks = set(blacks_l)
            grid = {(r, c): rows[r][c] for r in range(N) for c in range(N) if rows[r][c] != "_"}
            chosen = (blacks, grid, clues)
        self.blacks, self.solution, self.clues = chosen
        self.slots = slots(self.blacks)
        self.grid: dict[tuple[int, int], str] = {}
        self.wrong: set[tuple[int, int]] = set()
        self.chosen: str | None = self.slots[0]["id"] if self.slots else None
        self.checks = 0
        self.message = f"{len(self.slots)} clues."

    # ---- moves ---------------------------------------------------------------------------------
    def apply(self, move: dict, player: str) -> dict:
        if "choose" in move:
            sid = str(move["choose"]).upper()
            if not any(s["id"] == sid for s in self.slots):
                return {"error": "no such clue"}
            self.chosen = sid
            self.changed()
            return {"chosen": sid}
        if move.get("check"):
            return self.check()
        if "cell" in move and "letter" in move:
            cell = move["cell"]
            if not (isinstance(cell, (list, tuple)) and len(cell) == 2):
                return {"error": "a cell is row and column"}
            cell = (int(cell[0]), int(cell[1]))
            if cell in self.blacks or not (0 <= cell[0] < N and 0 <= cell[1] < N):
                return {"error": "not a white square"}
            letter = str(move["letter"]).lower()[:1]
            if letter:
                self.grid[cell] = letter
            else:
                self.grid.pop(cell, None)
            self.wrong.discard(cell)
            return self._after()
        sid = str(move.get("slot") or self.chosen or "").upper()
        word = str(move.get("word") or move.get("guess") or "").lower().strip()
        return self.enter(sid, word)

    def hear(self, text: str, player: str) -> dict | None:
        t = text.lower().strip()
        if t in ("check", "check it", "check the puzzle"):
            return self.check()
        m = _SAY.match(t)
        if not m:
            return None
        num, direction, word = m.groups()
        n = int(num) if num.isdigit() else _NUM.get(num)
        if n is None:
            return None
        sid = f"{n}{'A' if direction.startswith('a') else 'D'}"
        if not any(s["id"] == sid for s in self.slots):
            return None
        return self.enter(sid, word)

    def enter(self, sid: str, word: str) -> dict:
        if self.over:
            return {"error": "the puzzle is done"}
        slot = next((s for s in self.slots if s["id"] == sid), None)
        if slot is None:
            return {"error": "pick a clue"}
        if len(word) != len(slot["cells"]) or not word.isalpha():
            return {"error": f"{sid} is {len(slot['cells'])} letters"}
        for cell, ch in zip(slot["cells"], word):
            self.grid[cell] = ch
            self.wrong.discard(cell)
        self.chosen = sid
        return self._after()

    def _after(self) -> dict:
        white = [(r, c) for r in range(N) for c in range(N) if (r, c) not in self.blacks]
        full = all(cell in self.grid for cell in white)
        if full and all(self.grid[cell] == self.solution[cell] for cell in white):
            self.finish(won=True, message="Solved.")
            return {"solved": True}
        self.message = "Full. Check it?" if full else f"{sum(1 for c in white if c not in self.grid)} squares left."
        self.changed()
        return {"solved": False, "filled": sum(1 for c in white if c in self.grid)}

    def check(self) -> dict:
        self.checks += 1
        self.wrong = {cell for cell, ch in self.grid.items() if self.solution.get(cell) != ch}
        self.message = "All right so far." if not self.wrong else f"{len(self.wrong)} wrong."
        self.changed()
        return {"wrong": [list(c) for c in sorted(self.wrong)]}

    def state(self) -> dict:
        return {"blacks": [list(b) for b in sorted(self.blacks)],
                "grid": [["#" if (r, c) in self.blacks else self.grid.get((r, c), "") for c in range(N)] for r in range(N)],
                "slots": [{"id": s["id"], "n": s["n"], "dir": s["dir"], "cells": [list(c) for c in s["cells"]],
                           "clue": self.clues.get(s["id"], "")} for s in self.slots],
                "chosen": self.chosen, "wrong": [list(c) for c in sorted(self.wrong)], "checks": self.checks,
                "solution": ([["#" if (r, c) in self.blacks else self.solution[(r, c)] for c in range(N)]
                              for r in range(N)] if self.over else None)}

    def voice_words(self) -> list[str]:
        return ["across", "down", "check"] + list(_NUM)[:10] + sorted(set(self.solution.values()))

    # ---- the wall --------------------------------------------------------------------------------
    def frame_at(self, size: int, t: float):
        c = blank(size)
        big = size > 96
        cell = 11 if not big else 30
        gap = 1 if not big else 2
        gw = N * cell + (N - 1) * gap
        x0 = (size - gw) // 2
        y0 = (size - gw) // 2 if not big else 20
        lit = set(next((s["cells"] for s in self.slots if s["id"] == self.chosen), []))
        for r in range(N):
            for col in range(N):
                x = x0 + col * (cell + gap)
                y = y0 + r * (cell + gap)
                if (r, col) in self.blacks:
                    rounded(c, x, y, cell, cell, (14, 14, 18), 1 if not big else 3)
                    continue
                back = mix(SLATE2, YELLOW, 0.22) if (r, col) in lit and not self.over else SLATE2
                ch = self.grid.get((r, col), "")
                ink = RED if (r, col) in self.wrong else INK
                letter_tile(c, x, y, cell, ch, back, ink, 1 if not big else 3)
                if big:
                    n = next((s["n"] for s in self.slots if s["cells"][0] == (r, col)), None)
                    if n is not None:
                        text(c, str(n), x + 2, y + 2, DIM, 1)
        if self.over:
            banner(c, size, "Solved.", INK, mix((40, 120, 70), BLACK, 0.45))
        elif big and self.chosen:
            clue = self.clues.get(self.chosen, "")
            text(c, f"{self.chosen}  " + clue, 6, size - 12, DIM, 1) if len(clue) < 26 else \
                text(c, f"{self.chosen}  " + clue[:24] + ".", 6, size - 12, DIM, 1)
        header(c, size, "MINI", self.message[:22] if not self.over else "", 3 if big else 1, accent=YELLOW)
        return c

