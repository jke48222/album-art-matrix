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
that will not thread in time fall back to one that does. Options:
{"set": n}, {"seed": n}.
"""
from __future__ import annotations

import random
import re
import time

from . import Game, register
from .board import (BLACK, BLUE, DIM, FAINT, INK, SLATE2, WHITE, YELLOW, banner, blank, breathe, disc, fill,
                    glow, header, line, mix, text, letter_tile, text_centred, fit_text)
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
    deadline = time.monotonic() + budget_s
    while time.monotonic() < deadline:
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
    allw = [spangram] + list(words)
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
        if self.options.get("set") is None and asker is not None and getattr(asker, "ready", False):
            got = None
            try:
                got = asker.strands_set(rng.random())
            except Exception as exc:
                print(f"[games] strands from Claude: {exc}", flush=True)
            if got:
                theme, span, words = got
                built = build(theme, span, words, rng, 4.0)
                if built:
                    chosen = (theme, span, words, built)
        if chosen is None:
            n = self.options.get("set")
            sets = [BUNDLED[int(n) % len(BUNDLED)]] if n is not None else rng.sample(BUNDLED, len(BUNDLED))
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
        self.message = f"Theme: {self.theme}."

    def apply(self, move: dict, player: str) -> dict:
        if move.get("hint"):
            return self.hint()
        word = str(move.get("word") or move.get("guess") or "").lower().strip()
        return self.say(word, player)

    def hear(self, text: str, player: str) -> dict | None:
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
        if len(word) < 4:
            return {"error": "four letters or more"}
        if word in self.found:
            return {"error": "already found"}
        if word == self.spangram or word in self.words:
            self.found.append(word)
            if self.hinted == word:
                self.hinted = None
            span = word == self.spangram
            self.message = "The spangram!" if span else f"{len(self.words) + 1 - len(self.found)} to go."
            if len(self.found) == len(self.words) + 1:
                self.finish(won=True, winner=player if len(self.players) > 1 else None, message="Every strand.")
            else:
                self.changed()
            return {"word": word, "theme_word": True, "spangram": span,
                    "path": self.path_of(word)}
        if word in common_set() and word not in self.extra and self._in_grid(word):
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
        if len(self.extra) // 3 <= self.hints:
            return {"error": "find three extra words for a hint"}
        nxt = next((w for w in self.words if w not in self.found), None)
        if nxt is None:
            return {"error": "only the spangram is left"}
        self.hints += 1
        self.hinted = nxt
        self.message = "The hint is lit."
        self.changed()
        return {"hint": self.path_of(nxt)}

    def _in_grid(self, word: str) -> bool:
        """Can the word be traced through neighbouring cells?"""
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
                "left": len(self.words) + 1 - len(self.found),
                "answers": ([self.spangram] + list(self.words)) if self.over else None}

    def voice_words(self) -> list[str]:
        return [self.spangram] + list(self.words) + ["hint"]

    def frame_at(self, size: int, t: float):
        c = blank(size)
        big = size > 96
        s = 2 if big else 1
        cell = 7 if not big else 21
        gap = 1 if not big else 2
        gw = COLS * cell + (COLS - 1) * gap
        gh = ROWS * cell + (ROWS - 1) * gap
        x0 = (size - gw) // 2
        y0 = (size - gh) // 2 if not big else 16
        def centre(r, cc):
            return (x0 + cc * (cell + gap) + cell / 2, y0 + r * (cell + gap) + cell / 2)
        colour = {}
        # the paths first, as lines between centres, then the letters over them
        for w in self.found:
            col = YELLOW if w == self.spangram else BLUE
            path = self.path_of(w)
            for (r, cc) in path:
                colour[(r, cc)] = col
            for a, b in zip(path, path[1:]):
                line(c, centre(*a), centre(*b), mix(col, BLACK, 0.35), 5 if big else 1)
        hinted = set(tuple(p) for p in (self.path_of(self.hinted) if self.hinted else []))
        for r in range(ROWS):
            for cc in range(COLS):
                x, y = centre(r, cc)
                back = colour.get((r, cc))
                if back is None and (r, cc) in hinted:
                    glow(c, x, y, cell * 0.9, YELLOW, 0.25 + 0.25 * breathe(t, 1.6))
                if big:
                    disc(c, x, y, cell / 2 - 0.5, back or SLATE2, soft=0.8)
                elif back:
                    fill(c, int(x - cell / 2), int(y - cell / 2), cell, cell, back)
                ch = self.grid[r][cc]
                gw_, gh_ = 5 * s, 7 * s
                text(c, ch.upper(), int(x - gw_ / 2) + (1 if big else 1), int(y - gh_ / 2) + (1 if big else 0),
                     BLACK if back else INK, s)
        if self.over:
            banner(c, size, self.message, BLACK, YELLOW)
        header(c, size, "STRANDS", fit_text(self.theme, 100, 1) if not self.over else "", s, accent=BLUE)
        return c

