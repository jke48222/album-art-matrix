"""Strands on the wall.

A grid of letters, six across and eight down, hiding a themed set of
words that together use every letter once: the theme words, and one
spangram that touches two opposite sides and says what the theme is.
Words wind through the grid, each letter touching the next, sideways or
diagonally. Say a word or trace it on the phone; a found theme word
lights blue on the wall, the spangram yellow, and the letters still
loose stay white. Three words found that are real but not in the set
earn a hint: the next theme word's letters glow.

The sets come from Claude when a key is on the wall (a theme, a spangram
and six to seven words whose letters total forty-eight) or from the
wall's own sets below; the grid is laid by a randomised search that
threads every word through the empty cells until the grid is full. Sets
that cannot be threaded within a bounded search fall back to one that can. Options:
{"set": n}, {"seed": n}.
"""
from __future__ import annotations

import random
import re

from . import Game, register
from .board import blank, disc, line, text, fill, rect
from .words import common_set

ROWS, COLS = 8, 6
NEIGH = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]

# theme, spangram, words (letters total 48 with the spangram)
BUNDLED = [
    ("On the turntable", "recordplayer", ["needle", "vinyl", "sleeve", "groove", "spindle", "stylus"]),
    ("In the kitchen", "cookingtools", ["whisk", "ladle", "grater", "spatula", "peeler", "skillet"]),
    ("Weather words", "forecasting", ["drizzle", "breeze", "thunder", "frost", "sleet", "monsoon"]),
    ("Things with keys", "keyboards", ["piano", "laptop", "typewriter", "cipher", "padlock", "organ"]),
    ("At the beach", "seasideday", ["sandcastle", "towel", "shell", "waves", "sunscreen", "tide"]),
    ("Card games", "deckofcards", ["poker", "rummy", "solitaire", "bridge", "hearts", "euchre"]),
]

_WORD = re.compile(r"^(?:(?:the word is|try|how about|i see|i found)\s+)?([a-z]+)[.!?]*$")


def hamiltonian(rng: random.Random, steps: int = 4000) -> list[tuple[int, int]]:
    """A random path through every cell, each step to a neighbour (eight
    ways). Starts as rows back and forth, then "backbite" moves, which keep
    the path whole while making it wander: take an end, pick a neighbour
    of it further along the path, and turn the stretch between around."""
    path = []
    for r in range(ROWS):
        cols = range(COLS) if r % 2 == 0 else range(COLS - 1, -1, -1)
        path.extend((r, c) for c in cols)
    index = {cell: i for i, cell in enumerate(path)}
    n = len(path)
    for _ in range(steps):
        if rng.random() < 0.5:
            path.reverse()
            index = {cell: i for i, cell in enumerate(path)}
        y, x = path[-1]
        options = []
        for dy, dx in NEIGH:
            cell = (y + dy, x + dx)
            k = index.get(cell)
            if k is not None and k < n - 2:
                options.append(k)
        if not options:
            continue
        k = rng.choice(options)
        path[k + 1:] = path[k + 1:][::-1]
        index = {cell: i for i, cell in enumerate(path)}
    return path


def thread(words: list[str], rng: random.Random, budget_s: float = 3.0) -> list[list[tuple[int, int]]] | None:
    """Every word as a run of cells along one random path through the
    whole grid, so the words tile it exactly and each winds through its
    neighbours. The first word is the spangram and must touch two
    opposite sides; the words are cut from the path in a random order
    until a cut does."""
    total = sum(len(w) for w in words)
    if total != ROWS * COLS:
        return None
    # Fixed work keeps seeded puzzles reproducible on a Pi and a fast host.
    # The historical budget argument remains compatible with callers.
    for _ in range(64):
        path = hamiltonian(rng)
        order = list(range(len(words)))
        for _ in range(40):
            rng.shuffle(order)
            paths: dict[int, list[tuple[int, int]]] = {}
            at = 0
            for wi in order:
                paths[wi] = path[at:at + len(words[wi])]
                at += len(words[wi])
            if spangram_ok(paths[0]):
                return [paths[i] for i in range(len(words))]
    return None


def spangram_ok(path: list[tuple[int, int]]) -> bool:
    rows = {r for r, _ in path}
    cols = {c for _, c in path}
    return (0 in rows and ROWS - 1 in rows) or (0 in cols and COLS - 1 in cols)


def build(theme: str, spangram: str, words: list[str], rng: random.Random, budget_s: float = 3.0):
    """The grid and the paths, with the spangram touching two opposite
    sides; None when the letters do not add up or nothing threads."""
    if not isinstance(theme, str) or not theme.strip() or len(theme) > 120:
        return None
    if not isinstance(words, (list, tuple)) or not isinstance(spangram, str):
        return None
    allw = [spangram] + list(words)
    if not all(isinstance(w, str) and re.fullmatch(r"[a-z]{4,24}", w) for w in allw) or len(set(allw)) != len(allw):
        return None
    paths = thread(allw, rng, budget_s)
    if paths is None:
        return None
    grid = [[""] * COLS for _ in range(ROWS)]
    for w, p in zip(allw, paths):
        for ch, (r, c) in zip(w, p):
            grid[r][c] = ch
    return grid, paths


@register
class Strands(Game):
    name = "strands"
    title = "Strands"
    blurb = "A grid of letters hiding a themed set. Say a word; the wall lights its path."
    min_players = 1
    max_players = 4

    def setup(self):
        rng = random.Random(self.options.get("seed"))
        chosen = None
        asker = getattr(getattr(self.host, "ctrl", None), "asker", None)
        if self.options.get("set") is None and self.options.get("seed") is None and asker is not None and getattr(asker, "ready", False):
            got = None
            try:
                got = asker.strands_set(rng.random())
            except Exception as exc:
                print(f"[games] strands from Claude: {exc}", flush=True)
            if isinstance(got, (list, tuple)) and len(got) == 3:
                theme, span, words = got
                built = build(theme, span, words, rng, 4.0)
                if built:
                    chosen = (theme, span, list(words), built)
        if chosen is None:
            n = self.options.get("set")
            if n is not None and (type(n) is not int or not 0 <= n < len(BUNDLED)):
                raise ValueError("set must identify a bundled puzzle")
            sets = [BUNDLED[n]] if n is not None else rng.sample(BUNDLED, len(BUNDLED))
            for theme, span, words in sets:
                built = build(theme, span, words, rng, 6.0)
                if built:
                    chosen = (theme, span, words, built)
                    break
        if chosen is None:
            raise RuntimeError("no grid would thread")
        self.theme, self.spangram, self.words, (self.grid, self.paths) = chosen
        self.found: list[str] = []
        self.extra: list[str] = []
        self.hints = 0
        self.hinted: str | None = None
        self.hint_ordered = False
        self.message = f"Theme: {self.theme}."

    def apply(self, move: dict, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        if not isinstance(move, dict):
            return {"error": "send a word or trace"}
        if "hint" in move:
            return self.hint() if move["hint"] is True else {"error": "hint must be true"}
        word = move.get("word", move.get("guess", ""))
        if not isinstance(word, str):
            return {"error": "send a word"}
        word = word.lower().strip()
        if "path" in move:
            path = move["path"]
            if not self.valid_trace(path):
                return {"error": "trace neighbouring letters without repeating a cell"}
            traced = "".join(self.grid[r][c] for r, c in path)
            if word and word != traced:
                return {"error": "the word does not match the trace"}
            word = traced
        return self.say(word, player)

    @staticmethod
    def valid_trace(path) -> bool:
        if not isinstance(path, list) or not 4 <= len(path) <= ROWS * COLS:
            return False
        if any(not isinstance(cell, (list, tuple)) or len(cell) != 2 or
               type(cell[0]) is not int or type(cell[1]) is not int or
               not 0 <= cell[0] < ROWS or not 0 <= cell[1] < COLS for cell in path):
            return False
        if len(set(tuple(cell) for cell in path)) != len(path):
            return False
        return all(max(abs(a[0] - b[0]), abs(a[1] - b[1])) == 1 for a, b in zip(path, path[1:]))

    def hear(self, text: str, player: str) -> dict | None:
        if not isinstance(text, str):
            return None
        t = text.lower().strip()
        if t in ("hint", "give me a hint", "a hint please"):
            return self.hint()
        m = _WORD.match(t)
        if not m:
            return None
        w = m.group(1)
        if len(w) < 4:
            return None
        letters = "".join("".join(r) for r in self.grid)
        if any(letters.count(ch) < w.count(ch) for ch in set(w)):
            return None                                   # not in the grid at all
        return self.say(w, player)

    def say(self, word: str, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        if not isinstance(word, str) or not re.fullmatch(r"[a-z]{4,48}", word):
            return {"error": "use four or more English letters"}
        if word in self.found:
            return {"error": "already found"}
        if word == self.spangram or word in self.words:
            self.found.append(word)
            if self.hinted == word:
                self.hinted = None
                self.hint_ordered = False
            span = word == self.spangram
            self.message = "The spangram!" if span else f"{len(self.words) + 1 - len(self.found)} to go."
            if len(self.found) == len(self.words) + 1:
                self.finish(won=True, winner=player if len(self.players) > 1 else None, message="Every strand.")
            else:
                self.changed()
            return {"word": word, "theme_word": True, "spangram": span,
                    "path": self.path_of(word)}
        if word in self.extra:
            return {"error": "already counted toward a hint"}
        if word in common_set() and self._in_grid(word):
            self.extra.append(word)
            self.message = f"Not a theme word. {3 - len(self.extra) % 3 if len(self.extra) % 3 else 'Hint ready'}."
            if len(self.extra) % 3 == 0:
                self.message = "Hint earned. Say hint."
            self.changed()
            return {"word": word, "theme_word": False, "extras": len(self.extra)}
        return {"error": "not in the grid"}

    def hint(self) -> dict:
        if self.over:
            return {"error": "the game is over"}
        if self.hinted and self.hint_ordered:
            return {"error": "follow the outlined strand before using another hint"}
        if len(self.extra) // 3 <= self.hints:
            return {"error": "find three extra words for a hint"}
        nxt = self.hinted or next((w for w in self.words if w not in self.found), None)
        if nxt is None:
            return {"error": "only the spangram is left"}
        self.hints += 1
        self.hint_ordered = self.hinted == nxt
        self.hinted = nxt
        self.message = "Follow the dotted path." if self.hint_ordered else "The outlined letters belong to one word."
        self.changed()
        return {"hint": self.path_of(nxt), "ordered": self.hint_ordered}

    def _in_grid(self, word: str) -> bool:
        """Can the word be traced through neighbouring cells?"""
        if not word or len(word) > ROWS * COLS:
            return False
        letters = "".join("".join(row) for row in self.grid)
        if any(word.count(ch) > letters.count(ch) for ch in set(word)):
            return False
        def go(k, y, x, used):
            if k == len(word):
                return True
            for dy, dx in NEIGH:
                ny, nx = y + dy, x + dx
                if 0 <= ny < ROWS and 0 <= nx < COLS and (ny, nx) not in used and self.grid[ny][nx] == word[k]:
                    if go(k + 1, ny, nx, used | {(ny, nx)}):
                        return True
            return False
        return any(self.grid[r][c] == word[0] and go(1, r, c, {(r, c)}) for r in range(ROWS) for c in range(COLS))

    def path_of(self, word: str) -> list[list[int]]:
        allw = [self.spangram] + list(self.words)
        i = allw.index(word)
        return [[r, c] for r, c in self.paths[i]]

    def state(self) -> dict:
        return {"theme": self.theme, "rows": ["".join(r) for r in self.grid],
                "found": [{"word": w, "spangram": w == self.spangram, "path": self.path_of(w)} for w in self.found],
                "extra": self.extra, "hints": self.hints, "hint": self.path_of(self.hinted) if self.hinted else None,
                "left": len(self.words) + 1 - len(self.found), "total": len(self.words) + 1,
                "hints_available": max(0, len(self.extra) // 3 - self.hints),
                "hint_progress": len(self.extra) % 3, "hint_ordered": self.hint_ordered,
                "answers": ([self.spangram] + list(self.words)) if self.over else None}

    def voice_words(self) -> list[str]:
        return [self.spangram] + list(self.words) + ["hint"]

    @staticmethod
    def geometry(size: int):
        # An 8×6 field centred in square artwork, shared with the phone.
        if size <= 96:
            # Align the eight 5×7 letter rows to whole LED cells. At 64 this
            # gives each glyph seven rows plus one clear row of separation.
            step = size / 8
            return (size - 5 * step) / 2, step / 2, step
        step = size * .12
        return size * .2, size * .08, step

    def frame_at(self, size: int, t: float):
        canvas = blank(size)
        canvas[:] = (11, 10, 9)
        x0, y0, step = self.geometry(size)
        blue, gold, paper, dark = (144, 196, 215), (223, 185, 101), (250, 242, 222), (13, 21, 25)
        centre = lambda r, c: (x0 + c * step, y0 + r * step)
        if self.over:
            # Completion framing is behind the board: at true64, eight full
            # glyph rows leave no room for an overlaid horizontal border.
            rect(canvas, 1, 1, size - 2, size - 2, gold, max(1, round(size * .005)))
        colours = {}
        width = max(1, round(size * .038))
        for word in self.found:
            colour = gold if word == self.spangram else blue
            path = self.path_of(word)
            for cell in path:
                colours[tuple(cell)] = colour
            for a, b in zip(path, path[1:]):
                line(canvas, centre(*a), centre(*b), tuple(int(v * .45) for v in colour), width)
        hinted = self.path_of(self.hinted) if self.hinted else []
        if self.hint_ordered:
            for a, b in zip(hinted, hinted[1:]):
                ax, ay = centre(*a); bx, by = centre(*b)
                for k in range(1, 6, 2):
                    disc(canvas, ax + (bx - ax) * k / 6, ay + (by - ay) * k / 6, max(.6, size * .005), paper)
        hinted = set(tuple(cell) for cell in hinted)
        scale = max(1, int(size * .083 / 7))
        # A full pixel-font rectangle has wider corners than a typographic
        # cap-height. Keep even N/M corner pixels inside the bright disc.
        radius = size * .046 if size <= 96 else max(size * .046, (2.5 ** 2 + 3.5 ** 2) ** .5 * scale + 1)
        for r in range(ROWS):
            for c in range(COLS):
                x, y = centre(r, c)
                back = colours.get((r, c))
                if (r, c) in hinted:
                    disc(canvas, x, y, radius + max(1, size * .008), paper)
                disc(canvas, x, y, radius, back or (26, 30, 31))
                ink = dark if back and size > 96 else back or paper
                if size <= 96:
                    # The coloured path must not show through a letter's
                    # counters. Clear its full cell before stamping the bright
                    # glyph; neighbouring cells cannot overwrite its last row.
                    tx, ty = int(x) - 2, int(y) - 3
                    background = tuple(int(v * .20) for v in back) if back else (26, 30, 31)
                    fill(canvas, tx - 1, ty, 7, 7, background)
                else:
                    tx, ty = round(x - 2.5 * scale), round(y - 3.5 * scale)
                text(canvas, self.grid[r][c].upper(), tx, ty, ink, scale)
                if back and size > 96:
                    marker_y = ty + 7 * scale + 1
                    line(canvas, (x - radius * .3, marker_y), (x + radius * .3, marker_y), dark, max(1, round(size * .003)))
        return canvas
