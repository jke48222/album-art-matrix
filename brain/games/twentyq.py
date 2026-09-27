"""Twenty questions with knocks.

Think of something. The wall asks yes-or-no questions, up to twenty, and
tries to guess it. Answer with the frame: one knock for yes, a whistle
for no (or say "yes", "no", "sort of", or tap on the phone). The wall
shares a numbered question card with the phone; small panels page longer
questions without dropping words. Claude prepares each turn asynchronously
from the acknowledged history. Failed turns can be retried without losing
answers. A guess is a question too: knock if it is right.
"""
from __future__ import annotations

import math
import threading
import uuid

from . import Game, register
from .board import blank, disc, fill, text_centred, text_scrolled, wrap_text

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
    blurb = "Think of something. Answer the wall's questions in twenty turns."
    min_players = 1
    max_players = 4

    def setup(self):
        self.asker = self.options.get("asker") or getattr(getattr(self.host, "ctrl", None), "asker", None)
        if self.asker is None or not getattr(self.asker, "ready", False):
            raise RuntimeError("Twenty questions needs the Claude key (Services > Claude)")
        self._lock = getattr(self.host, "_lock", threading.RLock())
        self._host_generation = getattr(self.host, "_generation", None)
        self._request = 0
        self.history: list[tuple[str, str]] = []
        self.current = self.guessing = self.question_id = None
        self.last_answer = None
        self.receipt = 0
        self.problem = None
        self.thinking = False
        with self._lock:
            self._next()

    def _owned(self):
        if self.over:
            return False
        if self.host is None or not hasattr(self.host, "game"):
            return True
        return self.host.game is self or (getattr(self.host, "_generation", None) == self._host_generation
                                         and getattr(self.host, "_starting", None) == self.name)

    def _next(self):
        """Caller holds the host's lock; provider work never holds that lock."""
        self._request += 1
        request, history = self._request, list(self.history)
        self.current = self.guessing = self.question_id = None
        self.problem = None
        self.thinking = True
        self.message = "Finding the next question. Your answers are saved."
        self.changed()
        threading.Thread(target=self._ask, args=(request, history), name="twentyq-question", daemon=True).start()

    def _ask(self, request, history):
        try:
            turn = ask_claude(self.asker, history)
            if not isinstance(turn, dict):
                raise ValueError("empty question")
            question, guess = turn.get("question", ""), turn.get("guess", "")
            if not isinstance(question, str) or not isinstance(guess, str):
                raise ValueError("invalid question")
            question, guess = " ".join(question.split()), " ".join(guess.split())
            if bool(question) == bool(guess) or len(question) > 180 or len(guess) > 80:
                raise ValueError("one concise question is required")
            current = f"Is it {guess}?" if guess else question
            if any(current.casefold().rstrip("?.! ") == old.casefold().rstrip("?.! ") for old, _ in history):
                raise ValueError("repeated question")
        except Exception as exc:
            print(f"[games] twenty questions provider: {type(exc).__name__}", flush=True)
            with self._lock:
                if request != self._request or not self._owned():
                    return
                self.thinking = False
                self.problem = "The next question couldn't be prepared. Your answers are saved."
                self.message = "Try the next question again."
                self.changed()
            return
        with self._lock:
            if request != self._request or not self._owned():
                return
            self.current, self.guessing = current, guess or None
            self.question_id = uuid.uuid4().hex
            self.thinking = False
            self.message = current
            self.changed()

    def answer(self, answer: str, question_id: str | None = None) -> dict:
        with self._lock:
            if self.over:
                return {"error": "the game is over"}
            if self.thinking or self.current is None or self.problem:
                return {"error": "wait for the next question"}
            if question_id is not None and question_id != self.question_id:
                return {"error": "That question changed. Answer the one now on the wall."}
            if not isinstance(answer, str):
                return {"error": "yes, no or sort of"}
            answer = answer.lower().strip()
            answer = {"y": "yes", "n": "no", "maybe": "sort of", "kind of": "sort of"}.get(answer, answer)
            if answer not in ("yes", "no", "sort of"):
                return {"error": "yes, no or sort of"}
            self.receipt += 1
            self.last_answer = {"question_id": self.question_id, "answer": answer, "number": len(self.history) + 1}
            self.history.append((self.current, answer))
            if self.guessing and answer == "yes":
                self.finish(won=True, message=f"{self.guessing}, in {len(self.history)}.")
                return {"answered": answer, "got_it": True, "receipt": self.receipt}
            if len(self.history) >= MAX_Q:
                self.finish(won=False, message="Twenty questions. Your secret stays safe.")
                return {"answered": answer, "got_it": False, "receipt": self.receipt}
            self._next()
            return {"answered": answer, "thinking": True, "receipt": self.receipt}

    def finish(self, won=False, winner=None, message=None):
        with self._lock:
            if self.over:
                return
            self._request += 1
            self.thinking = False
            super().finish(won, winner, message)

    def apply(self, move: dict, player: str) -> dict:
        with self._lock:
            if self.over:
                return {"error": "the game is over"}
            if not isinstance(move, dict):
                return {"error": "answer yes, no or sort of"}
            if "retry" in move:
                if set(move) != {"retry"} or move["retry"] is not True:
                    return {"error": "retry must be true"}
                if self.thinking or not self.problem:
                    return {"error": "there is no failed question to retry"}
                self._next()
                return {"retrying": True}
            if set(move) - {"answer", "question_id"} or "answer" not in move:
                return {"error": "answer yes, no or sort of"}
            if "question_id" in move and (not isinstance(move["question_id"], str) or not move["question_id"]):
                return {"error": "a valid question identifier is required"}
            return self.answer(move["answer"], move.get("question_id"))

    def hear(self, text: str, player: str) -> dict | None:
        if not isinstance(text, str):
            return None
        spoken = text.lower().strip(" .!")
        answers = {"yes": "yes", "yeah": "yes", "yep": "yes", "correct": "yes", "no": "no", "nope": "no",
                   "sort of": "sort of", "kind of": "sort of", "maybe": "sort of", "sometimes": "sort of"}
        with self._lock:
            return self.answer(answers[spoken], self.question_id) if spoken in answers else None

    def event(self, kind: str, info: dict) -> bool:
        with self._lock:
            if self.over:
                return False
            if kind in ("knock", "whistle"):
                return "error" not in self.answer("yes" if kind == "knock" else "no", self.question_id)
            return kind == "double"

    def state(self) -> dict:
        with self._lock:
            return {"number": min(MAX_Q, len(self.history) + (0 if self.over else 1)), "max": MAX_Q,
                    "question": self.current, "question_id": self.question_id, "is_guess": self.guessing is not None,
                    "history": [{"q": q, "a": a} for q, a in self.history], "thinking": self.thinking,
                    "phase": "finished" if self.over else "thinking" if self.thinking else "error" if self.problem else "question",
                    "problem": self.problem, "can_retry": bool(self.problem) and not self.thinking and not self.over,
                    "receipt": self.receipt, "last_answer": dict(self.last_answer) if self.last_answer else None,
                    "answer": self.guessing if self.over and self.won else None}

    def voice_words(self) -> list[str]:
        return ["yes", "no", "sort of"]

    def frame_at(self, size: int, t: float):
        with self._lock:
            state = self.state()
            canvas = blank(size); canvas[:] = (16, 14, 12)
            paper, gold, muted = (240, 231, 211), (223, 185, 101), (150, 144, 127)
            scale = max(1, round(size * .038 / 7))
            number = f"{state['number']:02d}"
            text_centred(canvas, number, round(size * .5), round(size * .075), gold, max(1, round(size * .14 / 7)))
            label = "FOUND IT" if self.over and self.won else ("KEPT" if size < 128 else "SECRET KEPT") if self.over else "THINKING" if self.thinking else "RETRY" if self.problem else "A GUESS" if self.guessing else "QUESTION"
            text_centred(canvas, label, size // 2, round(size * .265), muted, scale)
            content = (self.guessing if self.won else "You kept your secret.") if self.over else self.current
            if content:
                question_scale = max(1, round(size * .06 / 7))
                lines = wrap_text(content.upper(), round(size * .84), question_scale)
                rows = max(1, int(size * .39 / (9 * question_scale)))
                pages = max(1, math.ceil(len(lines) / rows))
                page = int(max(0, t) / 4) % pages
                for offset, line_ in enumerate(lines[page * rows:(page + 1) * rows]):
                    text_scrolled(canvas, line_, round(size * .08), round(size * .39) + offset * 9 * question_scale,
                                  round(size * .84), t, paper, question_scale)
            else:
                for index in range(3):
                    disc(canvas, size * (.40 + index * .10), size * .51, max(1, size * .017), gold if self.thinking else muted)
                if self.problem:
                    text_centred(canvas, "TRY AGAIN", size // 2, round(size * .65), paper, scale)
            for index in range(MAX_Q):
                x = round(size * (.07 + index * .86 / (MAX_Q - 1)))
                fill(canvas, x, round(size * .9), max(1, round(size * .021)), max(2, round(size * .026)), gold if index < len(self.history) else (55, 48, 38))
            return canvas
