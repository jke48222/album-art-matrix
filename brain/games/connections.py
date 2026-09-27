"""Connections on the wall.

Sixteen words, four groups of four, each with a theme; find the groups.
Four mistakes and the game is over. The groups have a difficulty order,
yellow (easiest) to green, blue and purple, and the wall draws the found
groups as bars in their colour with the theme, the words still loose
below. On the phone the words are tiles: tap four and submit; by voice,
say the four words ("apple banana cherry date") or "submit" after naming
them one at a time. "One away" is said when three of four are together.

Claude writes a fresh set when a key is on the wall (brain/ask.py): four
groups with themes, a difficulty order, no word in two groups, no theme
too plain and none impossible. Without a key the wall draws from its own
sets, written into this file, so the game works on a Pi with no keys at
all. Options: {"set": n} for a bundled set, {"seed": n}.
"""
from __future__ import annotations

import random
import re

from . import Game, register
from .board import BLACK, blank, tile, text_scrolled

COLOURS = [(219, 185, 88), (145, 191, 151), (139, 174, 218), (180, 152, 208)]
NAMES = ["yellow", "green", "blue", "purple"]

# (theme, words) x4, easiest first. The wall's own, for a Pi without a key.
BUNDLED = [
    [("Things in a record shop", ["sleeve", "vinyl", "crate", "needle"]),
     ("Frank Ocean songs", ["nights", "ivy", "pyramids", "solo"]),
     ("___ light", ["moon", "spot", "flash", "lime"]),
     ("Words before 'board'", ["key", "skate", "dash", "surf"])],
    [("Weather", ["fog", "hail", "sleet", "mist"]),
     ("Coffee orders", ["latte", "mocha", "flat white", "cortado"]),
     ("Pixel ___", ["art", "font", "perfect", "peep"]),
     ("Hidden body parts", ["chinese", "shindig", "earnest", "legend"])],
    [("Card games", ["poker", "rummy", "whist", "hearts"]),
     ("Parts of a song", ["verse", "chorus", "bridge", "hook"]),
     ("Things that spin", ["record", "top", "planet", "fan"]),
     ("Apple things", ["watch", "vision", "music", "pencil"])],
    [("Kinds of key", ["major", "minor", "house", "car"]),
     ("Radiohead albums", ["pablo", "amnesiac", "kid", "moon"]),
     ("Bread", ["rye", "naan", "pita", "sourdough"]),
     ("Add a letter for a colour", ["gree", "blu", "whit", "pin"])],
    [("Chess pieces", ["rook", "bishop", "knight", "queen"]),
     ("Bond actors", ["moore", "craig", "connery", "dalton"]),
     ("Pasta shapes", ["penne", "orzo", "fusilli", "farfalle"]),
     ("Homophones of letters", ["sea", "bee", "eye", "tea"])],
    [("Things with strings", ["guitar", "kite", "puppet", "tennis racket"]),
     ("Planets, missing a letter", ["mar", "venu", "eart", "satur"]),
     ("Dances", ["tango", "waltz", "salsa", "jive"]),
     ("Slang for money", ["bread", "dough", "cheddar", "bacon"])],
    [("Shades of blue", ["navy", "teal", "azure", "cobalt"]),
     ("Album formats", ["single", "ep", "lp", "mixtape"]),
     ("Tennis terms", ["love", "deuce", "let", "ace"]),
     ("___ hole", ["black", "key", "pot", "worm"])],
    [("Camera settings", ["shutter", "iso", "aperture", "focus"]),
     ("Beatles", ["john", "paul", "george", "ringo"]),
     ("Things that are dealt", ["cards", "blows", "damage", "hands"]),
     ("Palindromes", ["level", "kayak", "civic", "radar"])],
]
_SUBMIT = re.compile(r"^(?:submit|that's it|those four|go|lock it in)[.!?]*$")


def _plain(w: str) -> str:
    return " ".join(re.sub(r"[^a-z0-9' ]", " ", w.lower()).split())


@register
class Connections(Game):
    name = "connections"
    title = "Connections"
    blurb = "Sixteen words, four groups of four. Four mistakes allowed."
    min_players = 1
    max_players = 4

    def setup(self):
        rng = random.Random(self.options.get("seed"))
        self._rng = rng
        groups = None
        asker = getattr(getattr(self.host, "ctrl", None), "asker", None)
        if self.options.get("set") is None and asker is not None and getattr(asker, "ready", False):
            groups = self._from_claude(asker, rng)
        if groups is None:
            n = self.options.get("set")
            groups = BUNDLED[int(n) % len(BUNDLED)] if n is not None else rng.choice(BUNDLED)
        self.groups = [(theme, [_plain(w) for w in words]) for theme, words in groups]
        self.words = [w for _, words in self.groups for w in words]
        rng.shuffle(self.words)
        self.found: list[int] = []                 # group indices, in the order found
        self.picked: list[str] = []
        self.mistakes = 0
        self.tries: list[list[str]] = []
        self.message = "Find four that go together."

    def _from_claude(self, asker, rng: random.Random):
        try:
            got = asker.connections_set(rng.random())
        except Exception as exc:
            print(f"[games] connections from Claude: {exc}", flush=True)
            return None
        if not isinstance(got, (list, tuple)) or len(got) != 4:
            return None
        if any(not isinstance(group, (list, tuple)) or len(group) != 2 for group in got):
            return None
        seen = set()
        for theme, words in got:
            if not isinstance(theme, str) or not isinstance(words, (list, tuple)) or any(not isinstance(w, str) for w in words):
                return None
            if len(words) != 4 or not theme.strip() or len(theme) > 100:
                return None
            for w in words:
                p = _plain(w)
                if not p or len(p) > 32 or p in seen:
                    return None
                seen.add(p)
        return got

    # ---- moves ------------------------------------------------------------------------------
    def apply(self, move: dict, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        words = move.get("words")
        if isinstance(words, list) and len(words) == 4:
            return self.submit([_plain(str(w)) for w in words], player)
        if "pick" in move:
            return self.pick(_plain(str(move["pick"])))
        if move.get("submit") or move.get("word") == "submit":
            return self.submit(list(self.picked), player)
        if move.get("clear"):
            self.picked = []
            self.changed()
            return {"picked": []}
        if move.get("shuffle") is True:
            self._rng.shuffle(self.words)
            self.changed()
            return {"shuffled": True}
        return {"error": "four words, or a pick"}

    def hear(self, text: str, player: str) -> dict | None:
        t = _plain(text)
        if not t:
            return None
        if _SUBMIT.match(t):
            return self.submit(list(self.picked), player) if len(self.picked) == 4 else {"error": "pick four first"}
        loose = [w for w in self.words if w not in self._found_words()]
        # the words said, longest first so "flat white" is not "white"
        said = []
        rest = " " + t + " "
        for w in sorted(loose, key=len, reverse=True):
            if " " + w + " " in rest:
                said.append(w)
                rest = rest.replace(" " + w + " ", " ", 1)
        if not said:
            return None
        if len(said) >= 4:
            return self.submit(said[:4], player)
        out = None
        for w in said:
            out = self.pick(w)
        if len(self.picked) == 4:
            return self.submit(list(self.picked), player)
        return out

    def pick(self, word: str) -> dict:
        if word not in self.words or word in self._found_words():
            return {"error": "not one of the words"}
        if word in self.picked:
            self.picked.remove(word)
        elif len(self.picked) < 4:
            self.picked.append(word)
        else:
            return {"error": "four already picked"}
        self.changed()
        return {"picked": list(self.picked)}

    def submit(self, words: list[str], player: str) -> dict:
        if len(set(words)) != 4 or any(w not in self.words for w in words):
            return {"error": "four of the words, please"}
        if any(w in self._found_words() for w in words):
            return {"error": "one of those is already placed"}
        if sorted(words) in [sorted(t) for t in self.tries]:
            return {"error": "already tried"}
        self.tries.append(list(words))
        self.picked = []
        best, best_n = None, 0
        for gi, (theme, group) in enumerate(self.groups):
            n = len(set(words) & set(group))
            if n > best_n:
                best, best_n = gi, n
        if best_n == 4:
            self.found.append(best)
            theme = self.groups[best][0]
            self.message = f"{theme}."
            if len(self.found) == 4:
                self.finish(won=True, winner=player if len(self.players) > 1 else None,
                            message=["Perfect.", "Great.", "Solid.", "Phew."][min(self.mistakes, 3)])
            else:
                self.changed()
            return {"group": best, "theme": theme, "colour": NAMES[best]}
        self.mistakes += 1
        self.message = "One away." if best_n == 3 else "Not a group."
        self.picked = list(words)
        if self.mistakes >= 4:
            self.picked = []
            self.finish(won=False, message="Four mistakes. " + "; ".join(f"{t}: {', '.join(g)}" for t, g in self.groups
                                                                       if self.groups.index((t, g)) not in self.found))
        else:
            self.changed()
        return {"group": None, "one_away": best_n == 3, "mistakes": self.mistakes}

    def _found_words(self) -> set[str]:
        return {w for gi in self.found for w in self.groups[gi][1]}

    def state(self) -> dict:
        return {"words": [w for w in self.words if w not in self._found_words()],
                "found": [{"theme": self.groups[gi][0], "words": self.groups[gi][1], "colour": NAMES[gi], "difficulty": gi + 1, "solved": True}
                          for gi in self.found],
                "picked": self.picked, "mistakes": self.mistakes, "mistakes_left": 4 - self.mistakes,
                "groups": ([{"theme": t, "words": g, "colour": NAMES[i], "difficulty": i + 1, "solved": i in self.found} for i, (t, g) in enumerate(self.groups)]
                           if self.over else None)}

    def voice_words(self) -> list[str]:
        return list(self.words) + ["submit"]

    # ---- the wall --------------------------------------------------------------------------------
    def frame_at(self, size: int, t: float):
        """The same four-column board at every resolution; labels scroll in
        their own cells when a real LED panel cannot hold the complete word.
        Completed groups remain the board, including the unreached solution.
        """
        from .board import fill, text, text_right
        c = blank(size)
        unit = size / 64.0
        margin, gap = max(1, round(2 * unit)), max(1, round(unit))
        top, bottom = round(10 * unit), round(10 * unit)
        height = (size - top - bottom - 3 * gap) // 4
        width = (size - 2 * margin - 3 * gap) // 4
        font = max(1, round(size / 192))
        paper, quiet = (234, 228, 216), (20, 18, 16)
        label = f"{len(self.found)}/4 FOUND"
        text(c, label, margin, max(1, round(2 * unit)), paper, font)
        if size >= 128:
            text_right(c, "CONNECTIONS", size - margin, round(2 * unit), (150, 144, 127), font)
        placed = list(range(4)) if self.over else list(self.found)
        for row, gi in enumerate(placed):
            theme, words = self.groups[gi]
            y = top + row * (height + gap)
            tile(c, margin, y, size - 2 * margin, height, COLOURS[gi], max(1, round(unit)))
            if size >= 128:
                title = f"{gi + 1}  {theme.upper()}"
                text_scrolled(c, title, margin + gap, y + max(1, height // 5), size - 2 * margin - 2 * gap,
                              t, BLACK, font, height=7)
                text_scrolled(c, " / ".join(w.upper() for w in words), margin + gap,
                              y + height - 7 * font - max(1, gap), size - 2 * margin - 2 * gap,
                              t, BLACK, font, height=7)
            else:
                text_scrolled(c, f"{gi + 1} {theme.upper()}", margin + 1,
                              y + (height - 7) // 2, size - 2 * margin - 2, t, BLACK, 1, height=7)
        loose = [] if self.over else [w for w in self.words if w not in self._found_words()]
        for index, word in enumerate(loose):
            row, column = divmod(index, 4)
            x, y = margin + column * (width + gap), top + (len(placed) + row) * (height + gap)
            selected = word in self.picked
            tile(c, x, y, width, height, paper if selected else quiet, max(1, round(unit)))
            inset = max(1, round(unit))
            text_scrolled(c, word.upper(), x + inset, y + (height - 7 * font) // 2,
                          width - inset * 2, t, BLACK if selected else paper, font, height=7)
            if selected:
                # A small underline echoes the phone's checkmark without
                # spending scarce LEDs on a second meaning-bearing color.
                fill(c, x + inset, y + height - 2 * inset, max(1, width - 2 * inset), max(1, inset // 2), BLACK)
        footer = ("COMPLETE" if self.won else "REVEALED") if self.over else f"{4 - self.mistakes} LEFT"
        text(c, footer, margin, size - margin - 7 * font, paper, font)
        if not self.over:
            dot = max(2, round(2 * unit))
            for index in range(4):
                fill(c, size - margin - (4 - index) * (dot + gap), size - margin - dot,
                     dot, dot, paper if index < 4 - self.mistakes else (70, 65, 57))
        return c
