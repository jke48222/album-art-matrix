"""Ask the wall: a question in, an answer on the panel, by way of Claude.

The wall is a 64 pixel LED panel in a bedroom (192 once the nine are up),
so an answer is a few short lines of a 5x7 font, not a page. Claude is told
exactly how many characters a line and lines a page the wall has, and to
answer in plain words. It can also look at the wall: what is playing, what
played earlier today (the journal), what the ear is doing; and it can act,
changing the face, the brightness, or starting a timer, when the question
is really a request.

The key is a service the phone sets (Services > Claude); it lives in
services.json and nowhere else. The model is `[ask] model` in config.toml,
Claude Opus 5 by default, with adaptive thinking left on and effort low,
because a wall's questions are short and its answers must come in seconds.
Every answer logs its tokens and cost.

The earworm finder uses the same client with a structured answer: a title,
an artist and a confidence, so the wall can fetch the sleeve without
guessing at the words.
"""
from __future__ import annotations

import json
import threading
import time

from .art.answer import layout

MODEL = "claude-opus-5"
MAX_TOOL_ROUNDS = 6
MAX_TOKENS = 400
PRICE_IN, PRICE_OUT = 5.0 / 1e6, 25.0 / 1e6      # dollars a token, Claude Opus 5

TOOLS = [
    {"name": "wall_state",
     "description": "What the wall is showing and hearing right now: the face that is up, "
                    "the song on the wall with its progress, the ear's state, brightness.",
     "input_schema": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"name": "journal",
     "description": "What has played on the wall lately, newest first, with local times.",
     "input_schema": {"type": "object",
                      "properties": {"limit": {"type": "integer", "minimum": 1, "maximum": 50}},
                      "additionalProperties": False}},
    {"name": "set_face",
     "description": "Change what the wall shows. Faces: art (the sleeve), cd (the spinning record), "
                    "ambient (light), clock, lyrics, nine (the last nine sleeves), off.",
     "input_schema": {"type": "object", "properties": {"face": {"type": "string"}},
                      "required": ["face"], "additionalProperties": False}},
    {"name": "set_brightness",
     "description": "Set the wall's brightness, 5 to 100 percent.",
     "input_schema": {"type": "object", "properties": {"percent": {"type": "integer"}},
                      "required": ["percent"], "additionalProperties": False}},
    {"name": "timer",
     "description": "Start a countdown on the wall, in minutes (1 to 180). 0 cancels.",
     "input_schema": {"type": "object", "properties": {"minutes": {"type": "integer"}},
                      "required": ["minutes"], "additionalProperties": False}},
]

FACES = ("art", "cd", "ambient", "clock", "lyrics", "nine", "off")


def system_prompt(size: int) -> str:
    _, chars, lines, _ = layout(size)
    return (
        "You are the voice of a small LED wall in a bedroom, an album-art panel that also listens. "
        f"Your answer is drawn on the panel in a pixel font, {chars} characters a line and {lines} lines a page; "
        "longer answers are paged every three seconds, so keep to one or two plain sentences unless "
        "more is truly needed. Plain words only: no markdown, no bullet points, no emoji, no headings. "
        "Use the tools when the question is about the wall, the music, or what played; use set_face, "
        "set_brightness or timer when the person is asking you to do something rather than tell them "
        "something, then confirm in a few words. If you do not know, say so briefly. "
        "The person is the wall's owner, in the room, talking out loud."
    )


class Asker:
    def __init__(self, ctrl, api_key: str = "", model: str = MODEL):
        self.ctrl = ctrl
        self.model = model or MODEL
        self.api_key = (api_key or "").strip()
        self._client = None
        self._lock = threading.Lock()
        self.problem = None
        self.answers = 0
        self.cost_usd = 0.0
        self.last = None                    # {"q", "a", "s", "usd", "tools"}

    def configure(self, api_key=None):
        if api_key is not None and api_key.strip() != self.api_key:
            self.api_key = api_key.strip()
            self._client = None
            self.problem = None

    @property
    def ready(self) -> bool:
        return bool(self.api_key)

    def _client_(self):
        if self._client is None:
            import anthropic
            self._client = anthropic.Anthropic(api_key=self.api_key)
        return self._client

    # ---- the tools ------------------------------------------------------------------------
    def _run_tool(self, name: str, args: dict):
        ctrl = self.ctrl
        try:
            if name == "wall_state":
                s = ctrl.get()
                ear = getattr(ctrl, "ears", None)
                hearing = ear.status() if ear is not None else {}
                return {"face": s["mode"], "brightness_percent": int(s["brightness"] * 100),
                        "now_showing": ctrl.now_showing or None,
                        "progress": ctrl.progress or None,
                        "hearing": {k: hearing.get(k) for k in ("state", "heard", "gate_open", "level_db")},
                        "idle_in_silence": s.get("idle")}
            if name == "journal":
                n = int(args.get("limit", 10))
                out = []
                for e in ctrl.journal_read(max(1, min(50, n))):
                    when = time.strftime("%a %H:%M", time.localtime(e.get("ts", 0)))
                    out.append({"when": when, "title": e.get("title"), "artist": e.get("artist"),
                                "album": e.get("album")})
                return out
            if name == "set_face":
                face = str(args.get("face", "")).lower()
                if face not in FACES:
                    return {"error": f"no face called {face}; faces are {', '.join(FACES)}"}
                ctrl.apply({"mode": face})
                return {"ok": True, "face": face}
            if name == "set_brightness":
                p = max(5, min(100, int(args.get("percent", 100))))
                ctrl.apply({"brightness": p / 100.0})
                return {"ok": True, "percent": p}
            if name == "timer":
                m = max(0, min(180, int(args.get("minutes", 0))))
                ctrl.apply({"timer_min": m})
                return {"ok": True, "minutes": m}
        except Exception as exc:
            return {"error": str(exc)[:160]}
        return {"error": f"unknown tool {name}"}

    # ---- asking -----------------------------------------------------------------------------
    def ask(self, question: str, size: int = 64) -> str:
        """The answer, as words for the panel. Never raises: a problem is
        an answer that says so, and a log line."""
        if not self.ready:
            return "I have no Claude key yet."
        import anthropic
        t0 = time.monotonic()
        client = self._client_()
        messages = [{"role": "user", "content": question}]
        usage_in = usage_out = 0
        used = []
        try:
            for _ in range(MAX_TOOL_ROUNDS):
                resp = client.messages.create(
                    model=self.model, max_tokens=MAX_TOKENS,
                    system=system_prompt(size), tools=TOOLS, messages=messages,
                    output_config={"effort": "low"},
                )
                usage_in += getattr(resp.usage, "input_tokens", 0) or 0
                usage_out += getattr(resp.usage, "output_tokens", 0) or 0
                if resp.stop_reason == "refusal":
                    answer = "I would rather not answer that one."
                    break
                if resp.stop_reason == "tool_use":
                    messages.append({"role": "assistant", "content": resp.content})
                    results = []
                    for block in resp.content:
                        if block.type == "tool_use":
                            used.append(block.name)
                            out = self._run_tool(block.name, dict(block.input or {}))
                            results.append({"type": "tool_result", "tool_use_id": block.id,
                                            "content": json.dumps(out)})
                    messages.append({"role": "user", "content": results})
                    continue
                answer = " ".join(b.text for b in resp.content if b.type == "text").strip()
                break
            else:
                answer = "That took too many steps; ask me again more simply."
        except anthropic.AuthenticationError:
            self.problem = "Claude rejected the key"
            return "Claude rejected the key on this wall."
        except anthropic.RateLimitError:
            self.problem = "rate limited"
            return "Claude is busy; ask again in a moment."
        except anthropic.APIConnectionError:
            self.problem = "no network"
            return "No answer right now: the network is away."
        except anthropic.APIStatusError as exc:
            self.problem = f"Claude answered {exc.status_code}"
            return "Claude could not answer just now."
        except Exception as exc:
            self.problem = f"{type(exc).__name__}: {str(exc)[:100]}"
            return "Something went wrong asking."
        usd = usage_in * PRICE_IN + usage_out * PRICE_OUT
        self.cost_usd += usd
        self.answers += 1
        self.problem = None
        self.last = {"q": question, "a": answer, "s": round(time.monotonic() - t0, 2),
                     "usd": round(usd, 4), "tools": used}
        print(f"[ask] {question!r} -> {answer!r} in {self.last['s']} s, "
              f"{usage_in}+{usage_out} tokens, ${usd:.4f}, tools {used}", flush=True)
        return answer or "I have nothing to say to that."

    def earworm(self, words: str) -> dict | None:
        """{title, artist, confidence, alternatives:[{title, artist}]} from
        the words someone remembers, or None."""
        if not self.ready:
            return None
        import anthropic
        from pydantic import BaseModel
        class Guess(BaseModel):
            title: str
            artist: str
        class Earworm(BaseModel):
            title: str
            artist: str
            confidence: float
            alternatives: list[Guess]
        try:
            resp = self._client_().messages.parse(
                model=self.model, max_tokens=400,
                system="Someone remembers a fragment of a song's lyrics, or a description of it. Name the song. "
                       "confidence is 0 to 1. Give up to three alternatives when unsure.",
                messages=[{"role": "user", "content": words}],
                output_format=Earworm, output_config={"effort": "low"},
            )
            self.answers += 1
            got = resp.parsed_output
            return {"title": got.title, "artist": got.artist, "confidence": got.confidence,
                    "alternatives": [{"title": g.title, "artist": g.artist} for g in got.alternatives]}
        except Exception as exc:
            self.problem = f"{type(exc).__name__}: {str(exc)[:100]}"
            print(f"[ask] earworm: {self.problem}", flush=True)
            return None

    def connections_set(self, salt: float = 0.0) -> list[tuple[str, list[str]]] | None:
        """Four groups of four for Connections (brain/games/connections.py),
        easiest first, or None."""
        if not self.ready:
            return None
        from pydantic import BaseModel
        class Group(BaseModel):
            theme: str
            words: list[str]
        class Puzzle(BaseModel):
            groups: list[Group]
        try:
            resp = self._client_().messages.parse(
                model=self.model, max_tokens=600,
                system="Write a Connections puzzle: sixteen words in four groups of four, each group with a "
                       "short theme. Order the groups easiest to hardest. Every word must belong to exactly "
                       "one group, with at least two words that could plausibly fit another group as red "
                       "herrings. No word may repeat. Single words or short two-word terms, lower case. Themes "
                       "should be varied: categories, fill-in-the-blanks, hidden words, wordplay. Pop music, "
                       "records and everyday life are welcome.",
                messages=[{"role": "user", "content": f"A fresh puzzle, please (variation {salt:.3f})."}],
                output_format=Puzzle, output_config={"effort": "low"},
            )
            usage = getattr(resp, "usage", None)
            if usage is not None:
                self.cost_usd += (getattr(usage, "input_tokens", 0) or 0) * PRICE_IN \
                    + (getattr(usage, "output_tokens", 0) or 0) * PRICE_OUT
            got = resp.parsed_output
            return [(g.theme, [w.strip().lower() for w in g.words]) for g in got.groups]
        except Exception as exc:
            self.problem = f"{type(exc).__name__}: {str(exc)[:100]}"
            print(f"[ask] connections: {self.problem}", flush=True)
            return None

    def strands_set(self, salt: float = 0.0) -> tuple[str, str, list[str]] | None:
        """(theme, spangram, words) for Strands (brain/games/strands.py):
        the spangram and the words together have exactly 48 letters. Two
        tries, then None."""
        if not self.ready:
            return None
        from pydantic import BaseModel
        class StrandsSet(BaseModel):
            theme: str
            spangram: str
            words: list[str]
        for attempt in range(2):
            try:
                resp = self._client_().messages.parse(
                    model=self.model, max_tokens=400,
                    system="Write a Strands puzzle set: a short theme (a hint, like 'On the turntable'), a spangram "
                           "of 8 to 13 letters that names the theme (one word or two words run together, letters "
                           "only), and six or seven theme words of 4 to 10 letters. The spangram and the words "
                           "together must have EXACTLY 48 letters: count them. Lower case, letters only, no "
                           "repeats, everyday words.",
                    messages=[{"role": "user", "content": f"A fresh set, please (variation {salt:.3f}, try {attempt + 1})."}],
                    output_format=StrandsSet, output_config={"effort": "low"},
                )
                usage = getattr(resp, "usage", None)
                if usage is not None:
                    self.cost_usd += (getattr(usage, "input_tokens", 0) or 0) * PRICE_IN \
                        + (getattr(usage, "output_tokens", 0) or 0) * PRICE_OUT
                got = resp.parsed_output
                span = "".join(ch for ch in got.spangram.lower() if ch.isalpha())
                words = ["".join(ch for ch in w.lower() if ch.isalpha()) for w in got.words]
                words = [w for w in words if 4 <= len(w) <= 10]
                if 8 <= len(span) <= 13 and len(span) + sum(len(w) for w in words) == 48 \
                        and len(set(words + [span])) == len(words) + 1:
                    return got.theme.strip(), span, words
            except Exception as exc:
                self.problem = f"{type(exc).__name__}: {str(exc)[:100]}"
                print(f"[ask] strands: {self.problem}", flush=True)
                return None
        return None

    def quiz_round(self, theme: str | None, n: int = 10, salt: float = 0.0):
        """(theme, [(question, [acceptable answers])]) for the pub quiz
        (brain/games/quiz.py), or None."""
        if not self.ready:
            return None
        from pydantic import BaseModel
        class Q(BaseModel):
            question: str
            answers: list[str]
        class Round(BaseModel):
            theme: str
            questions: list[Q]
        try:
            resp = self._client_().messages.parse(
                model=self.model, max_tokens=1500,
                system=f"Write a pub quiz round of {n} questions" + (f" on the theme: {theme}." if theme else
                       ", on a theme of your choosing (music, film, food, places, science, the everyday).")
                       + " Each question has a short factual answer that can be said in a few words; give every "
                       "acceptable way of saying it (numbers as digits and as words, with and without 'the'). "
                       "Mix easy and hard. No trick questions.",
                messages=[{"role": "user", "content": f"A round, please (variation {salt:.3f})."}],
                output_format=Round, output_config={"effort": "low"},
            )
            usage = getattr(resp, "usage", None)
            if usage is not None:
                self.cost_usd += (getattr(usage, "input_tokens", 0) or 0) * PRICE_IN \
                    + (getattr(usage, "output_tokens", 0) or 0) * PRICE_OUT
            got = resp.parsed_output
            qs = [(q.question.strip(), [a.strip() for a in q.answers if a.strip()]) for q in got.questions]
            qs = [q for q in qs if q[0] and q[1]][:n]
            return (got.theme.strip(), qs) if len(qs) >= 5 else None
        except Exception as exc:
            self.problem = f"{type(exc).__name__}: {str(exc)[:100]}"
            print(f"[ask] quiz: {self.problem}", flush=True)
            return None

    def crossword_clues(self, words: list[str]) -> dict[str, str] | None:
        """A crossword clue for every word (brain/games/crossword.py)."""
        if not self.ready or not words:
            return None
        from pydantic import BaseModel
        class Clue(BaseModel):
            word: str
            clue: str
        class Clues(BaseModel):
            clues: list[Clue]
        try:
            resp = self._client_().messages.parse(
                model=self.model, max_tokens=600,
                system="Write mini crossword clues: short, fair, in the style of a newspaper's mini, one per word. "
                       "Never include the word itself or its plain form in its clue. Keep each under nine words.",
                messages=[{"role": "user", "content": ", ".join(words)}],
                output_format=Clues, output_config={"effort": "low"},
            )
            usage = getattr(resp, "usage", None)
            if usage is not None:
                self.cost_usd += (getattr(usage, "input_tokens", 0) or 0) * PRICE_IN \
                    + (getattr(usage, "output_tokens", 0) or 0) * PRICE_OUT
            out = {c.word.strip().lower(): c.clue.strip() for c in resp.parsed_output.clues}
            return out if all(w in out for w in words) else None
        except Exception as exc:
            self.problem = f"{type(exc).__name__}: {str(exc)[:100]}"
            print(f"[ask] clues: {self.problem}", flush=True)
            return None

    def image_prompt(self, prompt: str, size: int = 64) -> str | None:
        """The words rewritten as a prompt for a picture on a panel of this
        size (brain/imagine.py), or None when Claude cannot be asked."""
        if not self.ready:
            return None
        from .imagine import IMAGE_SYSTEM
        try:
            resp = self._client_().messages.create(
                model=self.model, max_tokens=200,
                system=IMAGE_SYSTEM.format(size=size),
                messages=[{"role": "user", "content": prompt}],
                output_config={"effort": "low"},
            )
            text = " ".join(b.text for b in resp.content if getattr(b, "type", "") == "text").strip()
            usage = getattr(resp, "usage", None)
            if usage is not None:
                self.cost_usd += (getattr(usage, "input_tokens", 0) or 0) * PRICE_IN \
                    + (getattr(usage, "output_tokens", 0) or 0) * PRICE_OUT
            return text or None
        except Exception as exc:
            self.problem = f"{type(exc).__name__}: {str(exc)[:100]}"
            print(f"[ask] image prompt: {self.problem}", flush=True)
            return None

    def status(self) -> dict:
        return {"ready": self.ready, "model": self.model, "answers": self.answers,
                "cost_usd": round(self.cost_usd, 4), "last": self.last, "problem": self.problem}
