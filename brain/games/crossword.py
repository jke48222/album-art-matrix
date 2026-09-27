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
from copy import deepcopy

from . import Game, register
from .board import blank, fill, rect, text
from ..art.pixelfont import text_width
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
     ["_puff", "final", "ladle", "anise", "node_"],
     {"1A": "A little cloud of smoke", "5A": "Last in a series", "6A": "Spoon for serving soup",
      "7A": "Spice with a licorice flavor", "8A": "Point in a network", "1D": "Instrument with 88 keys",
      "2D": "Reversed an action", "3D": "Not true", "4D": "Run away", "5D": "Caramel-topped custard"}),
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


# Kept in step with CrosswordBoard.swift. The entire square belongs to the
# grid; clues and results live outside it on the phone, never over the letters.
CROSSWORD_COLOURS = {
    "ground": (11, 10, 9), "square": (28, 32, 34), "block": (14, 13, 11),
    "word": (37, 52, 59), "selected": (54, 91, 102), "rule": (101, 114, 122),
    "letter": (255, 255, 255), "number": (187, 201, 207),
    "cursor": (162, 211, 240), "wrong": (236, 105, 89), "solved": (163, 207, 155),
}


@register
class Crossword(Game):
    name = "crossword"
    title = "Mini crossword"
    blurb = "Five by five. Follow a clue, find a word, make the crossings meet."
    min_players = 1
    max_players = 4

    def setup(self):
        rng = random.Random(self.options.get("seed"))
        n = self.options.get("set")
        if n is not None and type(n) is not int:
            raise ValueError("Choose a numbered crossword set.")
        asker = getattr(getattr(self.host, "ctrl", None), "asker", None)
        chosen = None
        if n is None and asker is not None and getattr(asker, "ready", False):
            by_len: dict[int, list[str]] = {}
            for word in common(3, 5, 8000):
                by_len.setdefault(len(word), []).append(word)
            for pattern in rng.sample(PATTERNS, len(PATTERNS)):
                blacks = set(pattern)
                grid = fill_grid(blacks, rng, by_len)
                if grid is None:
                    continue
                answers = {s["id"]: "".join(grid[c] for c in s["cells"]) for s in slots(blacks)}
                try:
                    clues = asker.crossword_clues(sorted(set(answers.values())))
                except Exception as exc:
                    print(f"[games] crossword clues unavailable: {type(exc).__name__}", flush=True)
                    break
                # A partial provider result must never create an unclued puzzle.
                if isinstance(clues, dict) and all(isinstance(clues.get(w), str) and clues[w].strip() for w in answers.values()):
                    chosen = (blacks, grid, {sid: clues[w].strip() for sid, w in answers.items()})
                    break
        if chosen is None:
            blacks_l, rows, clues = BUNDLED[n % len(BUNDLED)] if n is not None else rng.choice(BUNDLED)
            blacks = set(blacks_l)
            grid = {(r, c): rows[r][c] for r in range(N) for c in range(N) if (r, c) not in blacks}
            chosen = (blacks, grid, dict(clues))
        self.blacks, self.solution, self.clues = chosen
        self.slots = slots(self.blacks)
        self.grid: dict[tuple[int, int], str] = {}
        self.wrong: set[tuple[int, int]] = set()
        self.chosen = self.slots[0]["id"]
        self.selected = self.slots[0]["cells"][0]
        self.checks = 0
        self.last_move_id: str | None = None
        self._last_move_payload: dict | None = None
        self.feedback = {"kind": "ready", "message": "Start anywhere. Every crossing helps."}
        self.message = f"{len(self.slots)} clues. One little grid."

    def _slot(self, sid=None):
        return next((s for s in self.slots if s["id"] == (self.chosen if sid is None else sid)), None)

    def _cell(self, value):
        if not isinstance(value, (list, tuple)) or len(value) != 2 or any(type(v) is not int for v in value):
            return None
        cell = tuple(value)
        return cell if cell in self.solution else None

    def _ordered_slots(self):
        return sorted(self.slots, key=lambda s: (s["dir"] == "down", s["n"]))

    def _choose(self, sid, cell=None):
        slot = self._slot(sid)
        if slot is None:
            return {"error": "Choose a clue from this puzzle."}
        self.chosen = sid
        self.selected = cell if cell in slot["cells"] else next((c for c in slot["cells"] if c not in self.grid), slot["cells"][0])
        self.changed()
        return {"chosen": sid, "selected": list(self.selected)}

    def _advance(self):
        slot = self._slot()
        cells = slot["cells"]
        start = cells.index(self.selected) if self.selected in cells else -1
        later = cells[start + 1:] + cells[:start + 1]
        empty = next((c for c in later if c not in self.grid), None)
        if empty is not None:
            self.selected = empty
            return
        ordered = self._ordered_slots()
        index = next(i for i, s in enumerate(ordered) if s["id"] == self.chosen)
        for next_slot in ordered[index + 1:] + ordered[:index]:
            empty = next((c for c in next_slot["cells"] if c not in self.grid), None)
            if empty is not None:
                self.chosen, self.selected = next_slot["id"], empty
                return

    def apply(self, move: dict, player: str) -> dict:
        if self.over:
            return {"error": "The puzzle is complete. Start a new one to play again."}
        if not isinstance(move, dict):
            return {"error": "Send a crossword move."}
        token = move.get("client_move_id")
        if token is not None and (not isinstance(token, str) or not 1 <= len(token) <= 80):
            return {"error": "The move identifier is invalid."}
        # Repeating a request after a lost response must not type twice or
        # backspace twice. Rejected requests never consume the identifier.
        payload = {key: value for key, value in move.items() if key != "client_move_id"}
        if token is not None and token == self.last_move_id:
            return ({"acknowledged": token} if payload == self._last_move_payload else
                    {"error": "That move identifier was already used for a different move."})
        result = self._apply(payload)
        if "error" not in result:
            self.last_move_id = token
            self._last_move_payload = deepcopy(payload) if token else None
        return result

    def _apply(self, move):
        keys = set(move)
        if keys == {"choose"}:
            if not isinstance(move["choose"], str):
                return {"error": "Choose a clue from this puzzle."}
            return self._choose(move["choose"].upper())
        if keys in ({"select"}, {"select", "direction"}):
            cell = self._cell(move["select"])
            direction = move.get("direction")
            if cell is None or direction not in (None, "across", "down"):
                return {"error": "Select a white square and an across or down direction."}
            candidates = [s for s in self.slots if cell in s["cells"]]
            current = self._slot()
            if direction is not None:
                slot = next((s for s in candidates if s["dir"] == direction), None)
                if slot is None:
                    return {"error": "There is no clue in that direction at this square."}
            elif cell == self.selected and len(candidates) > 1:
                slot = next(s for s in candidates if s["id"] != self.chosen)
            else:
                slot = next((s for s in candidates if s["dir"] == current["dir"]), candidates[0])
            return self._choose(slot["id"], cell)
        if keys == {"check"} and move["check"] is True:
            return self.check()
        if keys == {"backspace"} and move["backspace"] is True:
            cells = self._slot()["cells"]
            if self.selected not in self.grid:
                self.selected = cells[max(0, cells.index(self.selected) - 1)]
            self.grid.pop(self.selected, None)
            self.wrong.discard(self.selected)
            return self._after("erased", "One square cleared.")
        if keys == {"clear"}:
            sid = move["clear"]
            if not isinstance(sid, str) or self._slot(sid.upper()) is None:
                return {"error": "Choose the clue to clear."}
            slot = self._slot(sid.upper())
            for cell in slot["cells"]:
                self.grid.pop(cell, None)
                self.wrong.discard(cell)
            self.chosen, self.selected = slot["id"], slot["cells"][0]
            return self._after("erased", f"{slot['n']} {slot['dir']} cleared. Crossing clues share these squares.")
        if keys in ({"letter"}, {"cell", "letter"}):
            cell = self._cell(move["cell"]) if "cell" in move else self.selected
            letter = move["letter"]
            if cell is None:
                return {"error": "Choose a white square in this grid."}
            if not isinstance(letter, str) or not re.fullmatch(r"[a-zA-Z]?", letter):
                return {"error": "A square holds one letter from A to Z."}
            if "cell" in move and cell not in self._slot()["cells"]:
                self.chosen = next(s["id"] for s in self.slots if cell in s["cells"])
            self.selected = cell
            if letter:
                self.grid[cell] = letter.lower()
            else:
                self.grid.pop(cell, None)
            self.wrong.discard(cell)
            if letter:
                self._advance()
            return self._after()
        if keys in ({"word"}, {"guess"}, {"slot", "word"}, {"slot", "guess"}):
            sid = move.get("slot", self.chosen)
            word = move.get("word", move.get("guess"))
            if not isinstance(sid, str) or not isinstance(word, str):
                return {"error": "Enter a clue and its answer as text."}
            return self.enter(sid.upper(), word.strip().lower())
        return {"error": "Choose a clue, enter letters, or check the puzzle."}

    def hear(self, spoken: str, player: str) -> dict | None:
        if not isinstance(spoken, str):
            return None
        t = spoken.lower().strip().rstrip(".!?")
        if t in ("check", "check it", "check the puzzle", "check puzzle"):
            return self.apply({"check": True}, player)
        if t in ("backspace", "delete letter", "erase letter"):
            return self.apply({"backspace": True}, player)
        match = _SAY.fullmatch(t)
        if match:
            num, direction, word = match.groups()
            n = int(num) if num.isdigit() else _NUM.get(num)
            if n is not None:
                return self.apply({"slot": f"{n}{'A' if direction.startswith('a') else 'D'}", "word": word}, player)
        # A single spoken answer belongs to the selected clue. Explicit clue
        # commands remain available so room voice can change direction too.
        if re.fullmatch(r"[a-z]+", t) and len(t) == len(self._slot()["cells"]):
            return self.apply({"word": t}, player)
        return None

    def enter(self, sid: str, word: str) -> dict:
        if self.over:
            return {"error": "The puzzle is complete. Start a new one to play again."}
        slot = self._slot(sid)
        if slot is None:
            return {"error": "Choose a clue from this puzzle."}
        if not isinstance(word, str) or len(word) != len(slot["cells"]) or not re.fullmatch(r"[a-z]+", word):
            return {"error": f"{sid} is {len(slot['cells'])} letters"}
        for cell, ch in zip(slot["cells"], word):
            self.grid[cell] = ch
            self.wrong.discard(cell)
        self.chosen, self.selected = sid, slot["cells"][-1]
        self._advance()
        return self._after("entered", f"{slot['n']} {slot['dir']} placed.")

    def _after(self, kind="entered", message=None):
        remaining = len(self.solution) - len(self.grid)
        if remaining == 0 and self.grid == self.solution:
            self.wrong.clear()
            self.feedback = {"kind": "solved", "message": "Every crossing comes together."}
            self.finish(won=True, message="Solved. Every crossing comes together.")
            return {"solved": True, "filled": len(self.grid)}
        self.message = "Every square is filled. Check the crossings." if remaining == 0 else f"{remaining} {'square' if remaining == 1 else 'squares'} to fill."
        self.feedback = {"kind": kind, "message": message or self.message}
        self.changed()
        return {"solved": False, "filled": len(self.grid)}

    def check(self):
        if self.over:
            return {"error": "The puzzle is complete. Start a new one to play again."}
        self.checks += 1
        self.wrong = {cell for cell, ch in self.grid.items() if self.solution.get(cell) != ch}
        count = len(self.wrong)
        self.message = ("Fill a few squares, then check your crossings." if not self.grid else
                        "Every entered letter is right so far." if not count else
                        f"{count} {'square needs' if count == 1 else 'squares need'} another look. Follow the crossed corners.")
        self.feedback = {"kind": "incorrect" if count else "checked", "message": self.message}
        self.changed()
        return {"wrong": [list(c) for c in sorted(self.wrong)]}

    def state(self):
        return {"blacks": [list(b) for b in sorted(self.blacks)],
                "grid": [["#" if (r, c) in self.blacks else self.grid.get((r, c), "") for c in range(N)] for r in range(N)],
                "slots": [{"id": s["id"], "n": s["n"], "dir": s["dir"], "cells": [list(c) for c in s["cells"]],
                           "clue": self.clues.get(s["id"], "")} for s in self.slots],
                "chosen": self.chosen, "selected": list(self.selected), "direction": self._slot()["dir"],
                "wrong": [list(c) for c in sorted(self.wrong)], "checks": self.checks,
                "filled": len(self.grid), "total": len(self.solution), "remaining": len(self.solution) - len(self.grid),
                "filled_slots": [s["id"] for s in self.slots if all(c in self.grid for c in s["cells"])],
                "feedback": dict(self.feedback), "last_move_id": self.last_move_id,
                "solution": ([["#" if (r, c) in self.blacks else self.solution[(r, c)] for c in range(N)]
                              for r in range(N)] if self.over else None)}

    def voice_words(self):
        return ["across", "down", "check", "backspace"] + list(_NUM) + sorted({"".join(self.solution[c] for c in s["cells"]) for s in self.slots})

    def frame_at(self, size: int, t: float):
        canvas = blank(size)
        colours = CROSSWORD_COLOURS
        canvas[:] = colours["ground"]
        margin = max(1, round(size * 2 / 64))
        rule = max(1, round(size / 192))
        available = size - margin * 2
        edges = [margin + round(i * available / N) for i in range(N + 1)]
        fill(canvas, margin, margin, available, available, colours["solved"] if self.over else colours["rule"])
        lit = set(self._slot()["cells"]) if not self.over else set()
        for row in range(N):
            for col in range(N):
                cell = (row, col)
                x, y = edges[col] + rule, edges[row] + rule
                width, height = edges[col + 1] - x, edges[row + 1] - y
                if cell in self.blacks:
                    fill(canvas, x, y, width, height, colours["block"])
                    continue
                selected = cell == self.selected and not self.over
                back = colours["selected"] if selected else colours["word"] if cell in lit else colours["square"]
                fill(canvas, x, y, width, height, back)
                if selected:
                    rect(canvas, x, y, width, height, colours["cursor"], rule)
                ch = self.grid.get(cell, "").upper()
                scale = max(1, int(height * 0.57 / 7))
                if ch:
                    text(canvas, ch, x + (width - text_width(ch, scale)) // 2, y + (height - 7 * scale) // 2, colours["letter"], scale)
                if size >= 128:
                    number = next((s["n"] for s in self.slots if s["cells"][0] == cell), None)
                    if number is not None:
                        text(canvas, str(number), x + rule, y + rule, colours["number"], max(1, size // 256))
                if cell in self.wrong:
                    # A crossed corner is a shape cue, independent of red.
                    arm = max(2, round(width * 0.16))
                    for k in range(arm):
                        fill(canvas, x + width - arm - rule + k, y + rule + k, rule, rule, colours["wrong"])
                        fill(canvas, x + width - rule - 1 - k, y + rule + k, rule, rule, colours["wrong"])
                if selected:
                    fill(canvas, x + width // 3, y + height - rule * 2, max(2, width // 3), rule, colours["cursor"])
        rect(canvas, margin, margin, available, available, colours["solved"] if self.over else colours["rule"], rule)
        return canvas
