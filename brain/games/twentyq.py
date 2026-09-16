"""Twenty questions with knocks.

Think of something. The wall asks yes-or-no questions, up to twenty, and
tries to guess it. Answer with the frame: one knock for yes, a whistle
for no (or say "yes", "no", "sort of", or tap on the phone). The wall
shows the question number and, at 192, the question; the phone shows the
question too. Claude asks the questions and makes the guesses, given the
whole history each turn, so it needs the Claude key. A guess is a
question too: knock if it is right.
"""
from __future__ import annotations

from . import Game, register
from .board import (BLACK, DIM, GREEN, HONEY, INK, banner, blank, breathe, header, mix,
                    scale_for, text_centred, fit_text, wrap_text)

MAX_Q = 20


def ask_claude(asker, history: list[tuple[str, str]], salt: float = 0.0) -> dict | None:
    """{"question": str} or {"guess": str} from Claude for this history."""
    from pydantic import BaseModel
    from .. import ask as ask_mod
    class Turn(BaseModel):
        question: str
        guess: str
        confidence: float
    lines = "\n".join(f"Q: {q}\nA: {a}" for q, a in history) or "(no questions yet)"
    resp = asker._client_().messages.parse(
        model=asker.model, max_tokens=200,
        system="You are playing twenty questions. The player has thought of a thing (an object, an animal, a "
               "person, a place, a food, anything). Ask one yes-or-no question at a time that splits what is "
               "left as evenly as you can; when you are fairly sure, guess instead: put the guess in `guess`, "
               "leave `question` empty, and set `confidence` 0 to 1. Otherwise put the question in `question` "
               "and leave `guess` empty. Short questions, under twelve words. Never repeat a question.",
        messages=[{"role": "user", "content": f"Questions so far ({len(history)} of {MAX_Q}):\n{lines}\n\nYour move."}],
        output_format=Turn, output_config={"effort": "low"},
    )
    usage = getattr(resp, "usage", None)
    if usage is not None:
        asker.cost_usd += (getattr(usage, "input_tokens", 0) or 0) * ask_mod.PRICE_IN \
            + (getattr(usage, "output_tokens", 0) or 0) * ask_mod.PRICE_OUT
    got = resp.parsed_output
    if got.guess.strip() and (got.confidence >= 0.5 or not got.question.strip() or len(history) >= MAX_Q - 1):
        return {"guess": got.guess.strip()}
    if got.question.strip():
        return {"question": got.question.strip()}
    return None


@register
class TwentyQuestions(Game):
    name = "twentyq"
    title = "Twenty questions"
    blurb = "Think of a thing. The wall asks; knock for yes, whistle for no."
    min_players = 1
    max_players = 4

    def setup(self):
        self.asker = self.options.get("asker") or getattr(getattr(self.host, "ctrl", None), "asker", None)
        if self.asker is None or not getattr(self.asker, "ready", False):
            raise RuntimeError("Twenty questions needs the Claude key (Services > Claude)")
        self.history: list[tuple[str, str]] = []
        self.current: str | None = None
        self.guessing: str | None = None
        self.last_answer: str | None = None
        self.message = "Think of something. Knock when you have it."
        self.thinking = False
        self._next()

    def _next(self):
        self.thinking = True
        try:
            turn = ask_claude(self.asker, self.history)
        except Exception as exc:
            print(f"[games] twenty questions: {exc}", flush=True)
            turn = None
        self.thinking = False
        if turn is None:
            self.finish(won=False, message="The wall lost its train of thought.")
            return
        if "guess" in turn:
            self.guessing = turn["guess"]
            self.current = f"Is it {turn['guess']}?"
        else:
            self.guessing = None
            self.current = turn["question"]
        self.message = self.current
        self.changed()

    def answer(self, a: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        if self.current is None:
            return {"error": "no question yet"}
        a = {"y": "yes", "n": "no", "sort of": "sort of", "maybe": "sort of", "kind of": "sort of"}.get(a, a)
        if a not in ("yes", "no", "sort of"):
            return {"error": "yes, no or sort of"}
        self.last_answer = a
        self.history.append((self.current, a))
        if self.guessing is not None and a == "yes":
            self.finish(won=True, message=f"{self.guessing}, in {len(self.history)}.")
            return {"answered": a, "got_it": True}
        if len(self.history) >= MAX_Q:
            self.finish(won=False, message="Twenty questions and the wall could not guess. You win.")
            return {"answered": a, "got_it": False}
        self._next()
        return {"answered": a, "question": self.current}

    def apply(self, move: dict, player: str) -> dict:
        a = str(move.get("answer") or "").lower().strip()
        return self.answer(a)

    def hear(self, text: str, player: str) -> dict | None:
        t = text.lower().strip(" .!")
        words = {"yes": "yes", "yeah": "yes", "yep": "yes", "correct": "yes", "no": "no", "nope": "no",
                 "sort of": "sort of", "kind of": "sort of", "maybe": "sort of", "sometimes": "sort of"}
        if t in words:
            return self.answer(words[t])
        return None

    def event(self, kind: str, info: dict) -> bool:
        if kind == "knock":
            r = self.answer("yes")
            return "error" not in r
        if kind == "whistle":
            r = self.answer("no")
            return "error" not in r
        return kind == "double"

    def state(self) -> dict:
        return {"number": len(self.history) + (0 if self.over else 1), "max": MAX_Q,
                "question": self.current, "is_guess": self.guessing is not None,
                "history": [{"q": q, "a": a} for q, a in self.history], "thinking": self.thinking}

    def voice_words(self) -> list[str]:
        return ["yes", "no", "sort of"]

    def frame_at(self, size: int, t: float):
        c = blank(size)
        s = scale_for(size)
        big = size > 96
        n = len(self.history) + (0 if self.over else 1)
        if self.over:
            text_centred(c, "GOT IT" if self.won else "YOU WIN", size // 2, size // 2 - 9 * s, GREEN if self.won else HONEY, s)
            text_centred(c, fit_text(self.guessing or "", size - 4, s) if self.won else f"{len(self.history)} asked",
                         size // 2, size // 2 + 2 * s, INK, s)
            banner(c, size, f"in {len(self.history)}", INK, mix(GREEN, BLACK, 0.55) if self.won else (40, 40, 30))
            return c
        big_s = 3 * s if not big else 4
        text_centred(c, str(n), size // 2, 8 if not big else 34, INK, big_s)
        q_col = HONEY if self.guessing else mix(DIM, INK, breathe(t, 2.0))
        text_centred(c, "?", size // 2, 36 if not big else 76, q_col, 2 * s)
        if big and self.current:
            lines = wrap_text(self.current, size - 16, 1)[:4]
            y = size - 14 - 9 * len(lines)
            for ln in lines:
                text_centred(c, ln, size // 2, y, INK if self.guessing else DIM, 1)
                y += 9
        elif not big and self.thinking:
            text_centred(c, "...", size // 2, size - 10, DIM, 1)
        header(c, size, "TWENTY QUESTIONS", f"{n} of {MAX_Q}", s, accent=HONEY)
        return c

