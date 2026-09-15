"""Pub quiz on the wall.

A round of ten questions on a theme. The wall shows the question number,
a timer bar and, at 192, the question itself; the phone shows the question
and takes the answers, by voice or typed, one from each player. Twenty
seconds a question, then the answer, then the next. Right answers score;
a scoreboard at the end. Claude writes the round when a key is on the
wall (a theme of your choosing, or its own), with a list of acceptable
answers for each question; without a key the wall has two rounds of its
own below. Options: {"theme": "...", "set": n, "seconds": s}.
"""
from __future__ import annotations

import random
import re
import time

from . import Game, register
from .board import (BLACK, DIM, EDGE, FAINT, GREEN, INK, RED, WHITE, YELLOW, arc, banner, blank, fill, header, mix,
                    progress, scale_for, scoreboard, text, text_centred, fit_text, wrap_text, text_right)
from .pictures import _fold

SECONDS = 20.0
SHOW_ANSWER_S = 4.0

BUNDLED = [
    ("Records and record players", [
        ("How many revolutions a minute does an LP turn at?", ["33", "thirty three", "33 and a third", "thirty-three"]),
        ("What does the A in A-side stand for?", ["nothing", "it does not stand for anything", "no"]),
        ("Which Beatles album has the zebra crossing on its cover?", ["abbey road"]),
        ("Frank Ocean's 2016 album, spelt Blond on the cover, is called what?", ["blonde", "blond"]),
        ("What is the small hole in the middle of a record for?", ["the spindle", "spindle"]),
        ("Which band's album Rumours came out in 1977?", ["fleetwood mac"]),
        ("What colour is the label on most Motown records?", ["black", "blue", "black and blue"]),
        ("A record with about four songs, longer than a single, is an what?", ["ep", "e p", "extended play"]),
        ("Which Pink Floyd album has a prism on the cover?", ["the dark side of the moon", "dark side of the moon"]),
        ("What material are most records made of?", ["vinyl", "pvc", "polyvinyl chloride", "plastic"]),
    ]),
    ("A general round", [
        ("What is the capital of Australia?", ["canberra"]),
        ("How many sides does a hexagon have?", ["6", "six"]),
        ("Which planet is known as the red planet?", ["mars"]),
        ("What is the largest ocean?", ["pacific", "the pacific", "pacific ocean"]),
        ("Who painted the Mona Lisa?", ["leonardo da vinci", "da vinci", "leonardo"]),
        ("What is H2O?", ["water"]),
        ("How many minutes in a day?", ["1440", "one thousand four hundred and forty", "fourteen forty"]),
        ("Which country has the most people?", ["india"]),
        ("What is the hardest natural substance?", ["diamond", "diamonds"]),
        ("How many strings on a standard guitar?", ["6", "six"]),
    ]),
]


@register
class Quiz(Game):
    name = "quiz"
    title = "Pub quiz"
    blurb = "Ten questions on a theme. Twenty seconds each. Scores on the wall."
    min_players = 1
    max_players = 8

    def setup(self):
        rng = random.Random(self.options.get("seed"))
        self.seconds = float(self.options.get("seconds", SECONDS))
        theme = str(self.options.get("theme", "")).strip()
        round_ = None
        asker = getattr(getattr(self.host, "ctrl", None), "asker", None)
        if self.options.get("set") is None and asker is not None and getattr(asker, "ready", False):
            try:
                round_ = asker.quiz_round(theme or None, 10, rng.random())
            except Exception as exc:
                print(f"[games] quiz from Claude: {exc}", flush=True)
        if round_ is None:
            n = self.options.get("set")
            round_ = BUNDLED[int(n) % len(BUNDLED)] if n is not None else rng.choice(BUNDLED)
        self.theme, self.questions = round_[0], [(q, [_fold(a) for a in accept]) for q, accept in round_[1]]
        self.i = 0
        self.phase = "question"         # question | answer | done
        self.scores = {p: 0 for p in self.players}
        self.answered: dict[str, tuple[str, bool]] = {}
        self.t_q = time.monotonic()
        self._clock = time.monotonic
        self.message = self.theme

    @property
    def question(self) -> str:
        return self.questions[self.i][0] if self.i < len(self.questions) else ""

    def tick(self):
        if self.over:
            return
        now = self._clock()
        if self.phase == "question" and (now - self.t_q >= self.seconds or len(self.answered) >= len(self.players)):
            self._reveal()
        elif self.phase == "answer" and now - self.t_q >= SHOW_ANSWER_S:
            self._next()

    def _reveal(self):
        self.phase = "answer"
        self.t_q = self._clock()
        q, accept = self.questions[self.i]
        self.message = f"Answer: {accept[0]}."
        self.changed()

    def _next(self):
        self.i += 1
        self.answered = {}
        if self.i >= len(self.questions):
            self.phase = "done"
            ranked = sorted(self.scores.items(), key=lambda kv: -kv[1])
            winner = ranked[0][0] if len(self.players) > 1 and ranked[0][1] > 0 else None
            self.finish(won=ranked[0][1] > 0, winner=winner,
                        message=", ".join(f"{p} {s}" for p, s in ranked))
        else:
            self.phase = "question"
            self.t_q = self._clock()
            self.message = f"Question {self.i + 1}."
            self.changed()

    def apply(self, move: dict, player: str) -> dict:
        if move.get("next"):
            if self.phase == "question":
                self._reveal()
            elif self.phase == "answer":
                self._next()
            return {"phase": self.phase}
        text = str(move.get("answer") or move.get("text") or move.get("guess") or "").strip()
        return self.answer(text, player)

    def hear(self, text: str, player: str) -> dict | None:
        if self.phase != "question" or not text.strip():
            return None
        return self.answer(text, player)

    def answer(self, text: str, player: str) -> dict:
        self.tick()
        if self.over:
            return {"error": "the round is over"}
        if self.phase != "question":
            return {"error": "wait for the next question"}
        if player in self.answered:
            return {"error": "you have answered"}
        g = _fold(text)
        if not g:
            return {"error": "an answer, please"}
        q, accept = self.questions[self.i]
        right = any(g == a or (len(a) > 3 and (a in g)) for a in accept)
        self.answered[player] = (text, right)
        if right:
            self.scores[player] += 1
        self.message = f"{player} answered."
        self.changed()
        self.tick()
        return {"right": right, "answered": len(self.answered)}

    def state(self) -> dict:
        self.tick()
        left = max(0.0, self.seconds - (self._clock() - self.t_q)) if self.phase == "question" else 0.0
        return {"theme": self.theme, "number": self.i + 1, "count": len(self.questions),
                "question": self.question if not self.over else "", "phase": self.phase,
                "seconds_left": round(left, 1), "scores": self.scores,
                "answered": {p: {"text": t, "right": r} for p, (t, r) in self.answered.items()},
                "answer": self.questions[self.i][1][0] if self.phase == "answer" and self.i < len(self.questions) else None,
                "results": [{"question": q, "answer": a[0]} for q, a in self.questions] if self.over else None}

    def voice_words(self) -> list[str]:
        return [a for _, accept in self.questions for a in accept][:400]

    def frame_at(self, size: int, t: float):
        self.tick()
        s = scale_for(size)
        big = size > 96
        if self.over:
            ranked = sorted(self.scores.items(), key=lambda kv: -kv[1])
            return scoreboard(size, self.theme if big else "Scores", [(p, str(sc)) for p, sc in ranked], self.age(), YELLOW)
        c = blank(size)
        cx = size // 2
        cy = (size // 2 - 6 * s) if not big else 58
        r = 15 * s if not big else 30
        if self.phase == "question":
            frac = max(0.0, 1.0 - (self._clock() - self.t_q) / self.seconds)
            arc(c, cx, cy, r, 0, 360, FAINT, 2 if not big else 4)
            if frac > 0:
                arc(c, cx, cy, r, 0, 360 * frac, YELLOW if frac > 0.25 else RED, 2 if not big else 4)
            text_centred(c, str(self.i + 1), cx, cy - 7 * s, INK, 2 * s)
            if big:
                lines = wrap_text(self.question, size - 14, 1)[:5]
                y = cy + r + 10
                for ln in lines:
                    text_centred(c, ln, cx, y, INK, 1)
                    y += 9
            else:
                text_centred(c, f"{len(self.answered)}/{len(self.players)}", cx, cy + r + 4, DIM, 1)
        else:
            q, accept = self.questions[self.i]
            arc(c, cx, cy, r, 0, 360, mix(GREEN, BLACK, 0.4), 2 if not big else 4)
            text_centred(c, str(self.i + 1), cx, cy - 7 * s, DIM, 2 * s)
            ans = accept[0].upper()
            sc = 2 if big and len(ans) <= 14 else 1
            text_centred(c, fit_text(ans, size - 6 * s, sc), cx, cy + r + (8 if big else 4), GREEN, sc)
            if big:
                right = [p for p, (_, ok) in self.answered.items() if ok]
                text_centred(c, fit_text(", ".join(right) if right else "nobody", size - 12, 1), cx, size - 12, DIM, 1)
        header(c, size, fit_text(self.theme.upper(), 110, 1), f"{self.i + 1}/{len(self.questions)}", s, accent=YELLOW)
        return c

