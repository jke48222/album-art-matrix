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
from .board import blank, disc, line, text, rect
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
        self.hinted: str | None = None
        self.message = f"Try it in {len(self.par)}."

    def apply(self, move: dict, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        if not isinstance(move, dict):
            return {"error": "send a word"}
        if "undo" in move:
            return self.undo() if move["undo"] is True else {"error": "undo must be true"}
        if "hint" in move:
            return self.hint() if move["hint"] is True else {"error": "hint must be true"}
        word = move.get("word", move.get("guess", ""))
        if not isinstance(word, str):
            return {"error": "send a word"}
        word = word.lower().strip()
        return self.undo() if word == "undo" else self.play(word, player)

    def hear(self, text: str, player: str) -> dict | None:
        if not isinstance(text, str):
            return None
        t = text.lower().strip()
        if t in ("undo", "take it back", "go back"):
            return self.undo()
        if t in ("hint", "give me a hint"):
            return self.hint()
        m = _WORD.match(t)
        if not m:
            return None
        w = m.group(1)
        if len(w) < 3 or not set(w) <= self.letters:
            return None
        return self.play(w, player)

    def check(self, word: str) -> str | None:
        """Why a word cannot be played, or None."""
        if not isinstance(word, str) or not re.fullmatch(r"[a-z]{3,12}", word):
            return "use three to twelve English letters"
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
        self.hinted = None
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
        self.hinted = None
        self.words.pop()
        self.used = set("".join(self.words))
        self.message = f"{len(self.letters - self.used)} letters to go."
        self.changed()
        return {"undone": True}

    def hint(self) -> dict:
        if self.over:
            return {"error": "the game is over"}
        if self.hinted:
            return {"hint": self.hinted}
        candidates = [w for w in common(3, 12) if self.check(w) is None]
        if not candidates:
            return {"error": "no continuation here; undo the last word to try another route"}
        # Prefer the known solution while the player follows it, otherwise a
        # legal continuation that reaches the most unused letters.
        next_par = self.par[len(self.words)] if len(self.words) < len(self.par) and self.words == list(self.par[:len(self.words)]) else None
        word = next_par if next_par in candidates else max(candidates, key=lambda w: (len(set(w) - self.used), -len(w)))
        self.hinted = word[:2]
        self.message = f"Try a word beginning {self.hinted.upper()}."
        self.changed()
        return {"hint": self.hinted}

    def state(self) -> dict:
        return {"sides": self.sides, "words": self.words, "used": sorted(self.used),
                "left": sorted(self.letters - self.used), "par": len(self.par),
                "solution": list(self.par) if self.over else None,
                "next_letter": self.words[-1][-1] if self.words and not self.over else None,
                "hint": self.hinted, "can_undo": bool(self.words) and not self.over}

    def voice_words(self) -> list[str]:
        return [w for w in common(3, 9, 6000) if set(w) <= self.letters][:1500] + ["undo", "hint"]

    # The square and letter centres use the same normalized positions as iOS.
    def _spots(self, size: int) -> dict[str, tuple[float, float]]:
        pts = {}
        low, high = size * .14, size * .86
        span = high - low
        for side, letters in enumerate(self.sides):
            for k, ch in enumerate(letters):
                along = low + span * (k + 1) / 4
                pts[ch] = ((along, low), (high, along), (along, high), (low, along))[side]
        return pts

    def frame_at(self, size: int, t: float):
        canvas = blank(size)
        canvas[:] = (11, 10, 9)
        pts = self._spots(size)
        low, high = size * .14, size * .86
        rule, old, gold, paper, empty = (67, 60, 47), (99, 80, 38), (223, 185, 101), (250, 242, 222), (31, 28, 23)
        width = max(1, round(size * .006))
        for a, b in (((low, low), (high, low)), ((high, low), (high, high)), ((high, high), (low, high)), ((low, high), (low, low))):
            line(canvas, a, b, gold if self.over else rule, width)
        for wi, word in enumerate(self.words):
            colour = gold if wi == len(self.words) - 1 else old
            for a, b in zip(word, word[1:]):
                line(canvas, pts[a], pts[b], colour, max(1, round(size * .013)))
        radius = max(4.75, size * .056) if size <= 96 else size * .056
        scale = max(1, int(size * .075 / 7))
        next_letter = self.words[-1][-1] if self.words and not self.over else None
        for ch, (x, y) in pts.items():
            used = ch in self.used
            small = size <= 96
            back = (44, 36, 20) if small and used else gold if used else empty
            disc(canvas, x, y, radius, back)
            if ch == next_letter or (self.hinted and ch in self.hinted):
                disc(canvas, x, y, radius + max(1, size * .012), paper)
                disc(canvas, x, y, radius, back)
            tx, ty = round(x - 2.5 * scale), round(y - 3.5 * scale)
            ink = gold if small and used else (15, 12, 8) if used else paper
            text(canvas, ch.upper(), tx, ty, ink, scale)
            # At 64, the old underline cut through a glyph's last rows.
            # Put the status mark below the entire 5×7 glyph instead.
            if used:
                marker_y = ty + 7 * scale + 1
                line(canvas, (x - radius * .38, marker_y), (x + radius * .38, marker_y), ink, max(1, round(size * .004)))
        if self.over:
            rect(canvas, 1, 1, size - 2, size - 2, gold, max(1, round(size * .005)))
        return canvas
