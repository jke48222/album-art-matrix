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
import math
import time

from . import Game, register
from .board import blank, text_centred, fit_text, wrap_text, text, text_right, fill
from .heardle import answer_key
from .parking import ParkedClock, parked
from ..art.pixelfont import text_width

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


def question_lines(value, width, scale):
    """Wrap whole questions without silently clipping long words at 64 LEDs."""
    words = []
    for word in value.split():
        chunk = ""
        for letter in word:
            if chunk and text_width(chunk + letter, scale) > width:
                words.append(chunk)
                chunk = letter
            else:
                chunk += letter
        if chunk:
            words.append(chunk)
    return wrap_text(" ".join(words), width, scale)


@register
class Quiz(Game):
    name = "quiz"
    title = "Pub quiz"
    blurb = "Ten questions, one answer each. A room full of good guesses."
    min_players = 1
    max_players = 8

    def setup(self):
        rng = random.Random(self.options.get("seed"))
        seconds = self.options.get("seconds", SECONDS)
        if type(seconds) not in (int, float) or not math.isfinite(seconds) or not 5 <= seconds <= 120:
            raise ValueError("seconds must be between 5 and 120")
        self.seconds = float(seconds)
        theme = self.options.get("theme", "")
        if not isinstance(theme, str) or len(theme) > 120:
            raise ValueError("theme must contain at most 120 characters")
        n = self.options.get("set")
        if n is not None and (type(n) is not int or n not in range(len(BUNDLED))):
            raise ValueError("unknown question set")
        round_ = None
        asker = getattr(getattr(self.host, "ctrl", None), "asker", None)
        if n is None and "seed" not in self.options and asker is not None and getattr(asker, "ready", False):
            try:
                candidate = asker.quiz_round(theme.strip() or None, 10, rng.random())
                if self._valid_round(candidate):
                    round_ = candidate
            except Exception as exc:
                print(f"[games] quiz provider: {exc}", flush=True)
        if round_ is None:
            round_ = BUNDLED[n] if n is not None else rng.choice(BUNDLED)
        self.theme = round_[0]
        self.questions = [(q.strip(), [answer_key(a) for a in accept]) for q, accept in round_[1]]
        self.display_answers = [accept[0].strip() for _, accept in round_[1]]
        self.i, self.phase = 0, "question"
        self.scores = {p: 0 for p in self.players}
        self.answered = {}
        self.history = []
        self.leaders = []
        self._clock = time.monotonic
        self._park = ParkedClock()
        self.t_q = self._now()
        self.message = self.theme

    def _now(self):
        """The round's own time, which stands still while the game is parked
        off the wall: the phone locks answering then, so the timer must not
        reveal and move on with nobody able to reply."""
        return self._park.read(self, self._clock())

    @staticmethod
    def _valid_round(value):
        try:
            return (isinstance(value, (list, tuple)) and len(value) == 2 and isinstance(value[0], str)
                    and 1 <= len(value[0]) <= 120 and isinstance(value[1], (list, tuple)) and len(value[1]) == 10
                    and all(isinstance(row, (list, tuple)) and len(row) == 2 and isinstance(row[0], str)
                            and 1 <= len(row[0].strip()) <= 240 and isinstance(row[1], (list, tuple))
                            and 1 <= len(row[1]) <= 20 and all(isinstance(a, str) and 1 <= len(a.strip()) <= 120
                            and answer_key(a) for a in row[1]) for row in value[1]))
        except (TypeError, ValueError):
            return False

    @property
    def question(self):
        return self.questions[self.i][0] if self.i < len(self.questions) else ""

    @property
    def question_id(self):
        return self.i + 1

    def tick(self):
        if self.over:
            return
        now = self._now()
        if self.phase == "question" and (now - self.t_q >= self.seconds or len(self.answered) >= len(self.players)):
            self._reveal()
        elif self.phase == "answer" and now - self.t_q >= SHOW_ANSWER_S:
            self._next()

    def _reveal(self):
        if self.over or self.phase != "question":
            return
        self.phase, self.t_q = "answer", self._now()
        self.history.append({"question": self.question, "answer": self.display_answers[self.i],
                             "answered": {p: {"text": t, "right": r} for p, (t, r) in self.answered.items()}})
        self.message = f"Answer: {self.display_answers[self.i]}."
        self.changed()

    def _next(self):
        if self.over or self.phase != "answer":
            return
        self.i += 1
        self.answered = {}
        if self.i >= len(self.questions):
            self.phase = "done"
            top = max(self.scores.values(), default=0)
            self.leaders = [p for p in self.players if self.scores[p] == top]
            winner = self.leaders[0] if len(self.players) > 1 and len(self.leaders) == 1 and top > 0 else None
            tied = len(self.leaders) > 1
            scores = ", ".join(f"{p} {self.scores[p]}" for p in sorted(self.players, key=lambda p: -self.scores[p]))
            self.finish(won=top > 0, winner=winner, message=("Draw. " if tied else "") + scores)
        else:
            self.phase, self.t_q = "question", self._now()
            self.message = f"Question {self.i + 1}."
            self.changed()

    def apply(self, move, player):
        if self.over:
            return {"error": "the round is over"}
        if player not in self.players:
            return {"error": "unknown player"}
        token = move.get("question_id")
        if "question_id" in move and (type(token) is not int or token != self.question_id):
            return {"error": "the question has changed"}
        if parked(self):
            return {"error": "Return the quiz to the wall to answer."}
        if "next" in move:
            if move["next"] is not True:
                return {"error": "next must be true"}
            # A receipt is pinned to its observed phase as well as its question.
            before = (self.question_id, self.phase)
            self.tick()
            if before != (self.question_id, self.phase):
                return {"error": "the question has changed"}
            if self.phase == "question":
                self._reveal()
            else:
                self._next()
            return {"phase": self.phase}
        if token is None:
            return {"error": "question_id is required"}
        value = next((move[k] for k in ("answer", "text", "guess") if k in move), "")
        return self.answer(value, player, token)

    def hear(self, text, player):
        if self.phase != "question" or not isinstance(text, str) or not text.strip():
            return None
        return self.answer(text, player, self.question_id)

    def answer(self, text, player, question_id=None):
        token = self.question_id if question_id is None else question_id
        self.tick()
        if self.over:
            return {"error": "the round is over"}
        if type(token) is not int or token != self.question_id:
            return {"error": "the question has changed"}
        if self.phase != "question":
            return {"error": "wait for the next question"}
        if parked(self):
            return {"error": "Return the quiz to the wall to answer."}
        if player not in self.players:
            return {"error": "unknown player"}
        if player in self.answered:
            return {"error": "you have answered"}
        if not isinstance(text, str) or not 1 <= len(text.strip()) <= 120 or not answer_key(text):
            return {"error": "enter an answer, up to 120 characters"}
        text = text.strip()
        right = answer_key(text) in self.questions[self.i][1]
        self.answered[player] = (text, right)
        if right:
            self.scores[player] += 1
        self.message = f"{player} answered."
        self.changed()
        self.tick()
        return {"right": right, "answered": len(self.answered), "question_id": token}

    def state(self):
        self.tick()
        now = self._now()
        left = max(0.0, self.seconds - (now - self.t_q)) if self.phase == "question" else 0.0
        reveal = max(0.0, SHOW_ANSWER_S - (now - self.t_q)) if self.phase == "answer" else 0.0
        # Correctness and score changes are revealed together after everyone locks in.
        scores = {p: score - int(self.phase == "question" and self.answered.get(p, ("", False))[1])
                  for p, score in self.scores.items()}
        return {"theme": self.theme, "number": min(self.i + 1, len(self.questions)), "count": len(self.questions),
                "question_id": self.question_id, "question": self.question, "phase": self.phase,
                "seconds": self.seconds, "seconds_left": round(left, 1), "reveal_seconds_left": round(reveal, 1),
                "frame_step": 0 if self.over else int((now - self.t_q) * 2), "scores": scores,
                "paused": self._park.since is not None and not self.over,
                "answered": {p: {"text": t, "right": r if self.phase != "question" else None} for p, (t, r) in self.answered.items()},
                "answer": self.display_answers[self.i] if self.phase == "answer" else None,
                "leaders": list(self.leaders), "tied": self.over and len(self.leaders) > 1,
                "results": list(self.history) if self.over else None}

    def voice_words(self):
        # Never the accepted answers: every poll carries these to the phone,
        # where they could be read, and priming the recogniser with them
        # biases what it hears toward the right answer.
        return []

    def frame_at(self, size, t):
        state = self.state()
        c = blank(size)
        c[:] = (19, 25, 30)
        gold, cream, dim = (220, 185, 70), (246, 230, 195), (135, 152, 159)
        margin = max(3, round(size * .065))
        sc = max(1, size // 150)
        if self.over:
            text_centred(c, "DRAW" if len(self.leaders) > 1 else "SCORES" if size <= 96 else "FINAL SCORES", size // 2, margin, gold, sc)
            ranking = sorted(self.players, key=lambda p: -self.scores[p])
            if size <= 96 and len(ranking) > 4:
                for i, player in enumerate(ranking):
                    x = margin + (i // 4) * (size // 2)
                    y = 17 + (i % 4) * 11
                    text(c, fit_text(player, 18, 1), x, y, cream, 1)
                    text_right(c, str(self.scores[player]), x + 26, y, gold, 1)
                return c
            rowh = max(7, round(size * .79 / max(4, len(ranking))))
            y = round(size * .2)
            for p in ranking:
                text(c, fit_text(p, size - margin * 2 - 14 * sc, sc), margin, y, cream, sc)
                text_right(c, str(self.scores[p]), size - margin, y, gold, sc)
                y += rowh
            return c
        text(c, f"Q{self.i + 1}/{len(self.questions)}", margin, margin, gold, sc)
        label = f"{math.ceil(state['seconds_left'])}s" if self.phase == "question" else "ANSWER"
        text_right(c, label, size - margin, margin, cream, sc)
        bar_y = round(size * .24) if size == 64 else round(size * .19)
        fill(c, margin, bar_y, size - margin * 2, max(1, round(size * .01)), (49, 65, 70))
        if self.phase == "question":
            fill(c, margin, bar_y, round((size - margin * 2) * state["seconds_left"] / self.seconds), max(1, round(size * .01)), gold)
        else:
            fill(c, margin, bar_y, size - margin * 2, max(1, round(size * .01)), (144, 206, 165))
        content = self.question if self.phase == "question" else self.display_answers[self.i]
        width = size - margin * 2
        y0, y1 = round(size * .3), round(size * .86)
        content_scale = max(1, size // 96)
        lines = question_lines(content, width, content_scale)
        while content_scale > 1 and len(lines) * 9 * content_scale > y1 - y0:
            content_scale -= 1
            lines = question_lines(content, width, content_scale)
        lineheight = 9 * content_scale
        capacity = max(1, (y1 - y0) // lineheight)
        # At 64 LEDs the actual question scrolls through a readable four-line window.
        offset = 0
        if len(lines) > capacity:
            window = self.seconds if self.phase == "question" else SHOW_ANSWER_S
            elapsed = max(0, self._now() - self.t_q - min(2, window / 4))
            offset = min(int(elapsed / max(1, window - min(4, window / 2)) * (len(lines) - capacity + 1)), len(lines) - capacity)
        for i, line_ in enumerate(lines[offset:offset + capacity]):
            text(c, line_, margin, y0 + i * lineheight, cream if self.phase == "question" else (166, 223, 185), content_scale)
        if size > 96:
            text(c, f"{len(self.answered)}/{len(self.players)} LOCKED IN" if self.phase == "question" else "NEXT QUESTION SOON", margin, round(size * .92), dim, max(1, size // 192))
        else:
            for i in range(len(self.players)):
                fill(c, margin + i * 7, size - 4, 4, 1, gold if i < len(self.answered) else dim)
        return c
