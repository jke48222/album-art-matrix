"""Letter Boxed on the wall.

Twelve letters round a square, three a side. Make words of three letters
or more, each letter's next from a different side, each word starting
with the last letter of the one before, until every letter is used. The
wall draws the square with the letters on its sides and the lines each
word draws across it, the current word brighter.

Puzzles are our own: two common words are found that chain (the second
starts with the first's last letter), use exactly twelve distinct letters
between them, and can be laid out on four sides so no word ever needs two
letters from one side in a row. That known two-word solution is kept as
the "par". Options: {"seed": n}.
"""
from __future__ import annotations

import random
import re

from . import Game, register
from .board import (BLACK, DIM, EDGE, FAINT, INK, SLATE2, WHITE, YELLOW, banner, blank, disc, header,
                    line, mix, text, text_centred, fit_text, text_scrolled)
from .words import common, common_set

_WORD = re.compile(r"^(?:(?:the word is|try|then|and then|next)\s+)?([a-z]+)[.!?]*$")


def sides_for(pair: tuple[str, str], rng: random.Random) -> list[str] | None:
    """Four sides of three letters each, such that neither word ever takes
    two letters in a row from one side; None when no layout works."""
    letters = sorted(set(pair[0] + pair[1]))
    if len(letters) != 12:
        return None
    steps = set()
    for w in pair:
        for a, b in zip(w, w[1:]):
            if a == b:
                return None
            steps.add(frozenset((a, b)))
    # a graph colouring: 4 sides, 3 letters each, adjacent letters apart
    order = list(letters)
    rng.shuffle(order)
    sides: list[list[str]] = [[], [], [], []]
    def ok(letter: str, side: int) -> bool:
        return len(sides[side]) < 3 and all(frozenset((letter, o)) not in steps for o in sides[side])
    def go(i: int) -> bool:
        if i == 12:
            return True
        letter = order[i]
        for side in range(4):
            if ok(letter, side):
                sides[side].append(letter)
                if go(i + 1):
                    return True
                sides[side].pop()
        return False
    if not go(0):
        return None
    return ["".join(sorted(s)) for s in sides]


def make_puzzle(rng: random.Random, words: list[str]) -> tuple[list[str], tuple[str, str]]:
    """(sides, the two-word solution)."""
    pool = [w for w in words if 5 <= len(w) <= 9 and len(set(w)) >= 5
            and all(a != b for a, b in zip(w, w[1:]))]
    by_first: dict[str, list[str]] = {}
    for w in pool:
        by_first.setdefault(w[0], []).append(w)
    rng.shuffle(pool)
    for first in pool[:4000]:
        for second in by_first.get(first[-1], []):
            if second == first:
                continue
            letters = set(first) | set(second)
            if len(letters) != 12:
                continue
            sides = sides_for((first, second), rng)
            if sides:
                return sides, (first, second)
    raise RuntimeError("no puzzle in the words")


@register
class LetterBoxed(Game):
    name = "letterboxed"
    title = "Letter Boxed"
    blurb = "Twelve letters round a square. Chain words until all are used."
    min_players = 1
    max_players = 2

    def setup(self):
        rng = random.Random(self.options.get("seed"))
        words = common(3, 12)
        if not words:
            raise RuntimeError("no word list")
        self.sides, self.par = make_puzzle(rng, words)
        self.side_of = {ch: i for i, s in enumerate(self.sides) for ch in s}
        self.letters = set(self.side_of)
        self.words: list[str] = []
        self.used: set[str] = set()
        self.message = f"Try it in {len(self.par)}."

    def apply(self, move: dict, player: str) -> dict:
        if "undo" in move or move.get("word") == "undo":
            return self.undo()
        word = str(move.get("word") or move.get("guess") or "").lower().strip()
        return self.play(word, player)

    def hear(self, text: str, player: str) -> dict | None:
        t = text.lower().strip()
        if t in ("undo", "take it back", "go back"):
            return self.undo()
        m = _WORD.match(t)
        if not m:
            return None
        w = m.group(1)
        if len(w) < 3 or not set(w) <= self.letters:
            return None
        return self.play(w, player)

    def check(self, word: str) -> str | None:
        """Why a word cannot be played, or None."""
        if len(word) < 3:
            return "three letters or more"
        if not set(word) <= self.letters:
            return "a letter that is not on the box"
        for a, b in zip(word, word[1:]):
            if self.side_of[a] == self.side_of[b]:
                return f"{a.upper()} and {b.upper()} are on the same side"
        if self.words and word[0] != self.words[-1][-1]:
            return f"must start with {self.words[-1][-1].upper()}"
        if word not in common_set():
            return "not in the list"
        if word in self.words:
            return "already played"
        return None

    def play(self, word: str, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        why = self.check(word)
        if why:
            return {"error": why}
        self.words.append(word)
        self.used |= set(word)
        left = len(self.letters - self.used)
        if left == 0:
            n = len(self.words)
            self.finish(won=True, message=f"Solved in {n}." + (" Par." if n <= len(self.par) else ""))
        else:
            self.message = f"{left} letter{'s' if left != 1 else ''} to go."
            self.changed()
        return {"word": word, "left": left}

    def undo(self) -> dict:
        if self.over or not self.words:
            return {"error": "nothing to take back"}
        self.words.pop()
        self.used = set("".join(self.words))
        self.message = f"{len(self.letters - self.used)} letters to go."
        self.changed()
        return {"undone": True}

    def state(self) -> dict:
        return {"sides": self.sides, "words": self.words, "used": sorted(self.used),
                "left": sorted(self.letters - self.used), "par": len(self.par),
                "solution": list(self.par) if self.over else None}

    def voice_words(self) -> list[str]:
        return [w for w in common(3, 9, 6000) if set(w) <= self.letters][:1500] + ["undo"]

    # ---- the wall --------------------------------------------------------------------------------
    def _spots(self, size: int) -> dict[str, tuple[int, int]]:
        big = size > 96
        m = 12 if not big else 34
        x0, y0, x1, y1 = m, m + (0 if not big else 6), size - m - 1, size - m - 1 + (0 if not big else 6)
        pts = {}
        for i, s in enumerate(self.sides):
            for k, ch in enumerate(s):
                f = (k + 1) / 4
                if i == 0:
                    pts[ch] = (int(x0 + (x1 - x0) * f), y0)
                elif i == 1:
                    pts[ch] = (x1, int(y0 + (y1 - y0) * f))
                elif i == 2:
                    pts[ch] = (int(x0 + (x1 - x0) * f), y1)
                else:
                    pts[ch] = (x0, int(y0 + (y1 - y0) * f))
        return pts

    def frame_at(self, size: int, t: float):
        c = blank(size)
        big = size > 96
        s = 2 if big else 1
        pts = self._spots(size)
        m = 12 if not big else 34
        x0, y0, x1, y1 = m, m + (0 if not big else 6), size - m - 1, size - m - 1 + (0 if not big else 6)
        # the box
        for (ax, ay, bx, by) in ((x0, y0, x1, y0), (x1, y0, x1, y1), (x0, y1, x1, y1), (x0, y0, x0, y1)):
            line(c, (ax, ay), (bx, by), EDGE if big else FAINT, 2 if big else 1)
        # the lines the words draw, the current word bright and thicker
        for wi, w in enumerate(self.words):
            last = wi == len(self.words) - 1
            colour = YELLOW if last else mix(YELLOW, BLACK, 0.55)
            for a, b in zip(w, w[1:]):
                line(c, pts[a], pts[b], colour, (3 if last else 2) if big else 1)
        for ch, (x, y) in pts.items():
            used = ch in self.used
            disc(c, x + 0.5, y + 0.5, (4.0 if big else 2.0), WHITE if used else SLATE2, soft=0.8 if big else 0.0)
            if big and not used:
                disc(c, x + 0.5, y + 0.5, 2.2, EDGE)
            side = self.side_of[ch]
            gw, gh = 5 * s, 7 * s
            off = 6 if not big else 12
            tx, ty = x - gw // 2, y - gh // 2
            if side == 0:
                ty = y - off - gh
            elif side == 1:
                tx = x + off
            elif side == 2:
                ty = y + off
            else:
                tx = x - off - gw
            text(c, ch.upper(), tx, ty, INK if not used else DIM, s)
        if self.words:
            # The word just played, in full. It was cut to fit the square
            # ("PRECISE" came out "PREC."), which hides the thing the game is
            # about; a long one travels across the square instead.
            box = (x1 - x0) - 8
            text_scrolled(c, self.words[-1].upper(), x0 + 4, (y0 + y1) // 2 - 3 * s, box, t,
                          INK, s, height=7 if s == 1 else 9)
            if big and len(self.words) > 1:
                text_centred(c, fit_text(" ".join(w.upper() for w in self.words[:-1]), (x1 - x0) - 12, 1), size // 2,
                             (y0 + y1) // 2 + 12, DIM, 1)
        if self.over:
            banner(c, size, self.message, BLACK, YELLOW)
        header(c, size, "LETTER BOXED", f"{len(self.letters - self.used)} to go" if not self.over else "", s, accent=YELLOW)
        return c

