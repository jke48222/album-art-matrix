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

# Problems the phone acts on. It keys on the code, never on the words: a 403
# also mentions a workspace, but only the 400 below needs the workspace field.
REFUSED = "Claude rejected the key. Replace it in Services."
FORBIDDEN = "This key cannot use the configured model or workspace. Check access in Claude Console."
LIMITED = "Claude is limiting requests. Try again in a moment."
NEEDS_WORKSPACE = "This key needs a workspace ID. Add it in Services, Claude."
TIMED_OUT = "Claude took too long to respond. Try again."
OFFLINE = "The wall could not reach Claude. Check its network."
PROBLEM_CODES = {REFUSED: "refused", FORBIDDEN: "forbidden", LIMITED: "rate_limited",
                 NEEDS_WORKSPACE: "needs_workspace", TIMED_OUT: "timeout", OFFLINE: "offline"}


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
    def __init__(self, ctrl, api_key: str = "", model: str = MODEL, workspace: str = ""):
        self.ctrl = ctrl
        self.model = model or MODEL
        self.api_key = (api_key or "").strip()
        # a key made at the organisation level must name the workspace it
        # spends from (Console > Settings > Workspaces, "wrkspc_...")
        self.workspace = (workspace or "").strip()
        self.history: list[dict] = []          # the last questions and answers, newest first
        self._client = None
        self._lock = threading.RLock()
        self._generation = 0
        self._ask_lock = threading.Lock()
        self.pending = False
        # The Claude connection's problem, which the Claude page shows as
        # "needs attention". Only failures the owner must fix (the key, its
        # access, its workspace) or a question's own failure set it.
        self.problem = None
        # The last song guess's miss, for the earworm page only: a line that
        # names no song is not a broken connection.
        self.earworm_problem = None
        self.answers = 0
        self.cost_usd = 0.0
        self.last = None                    # {"q", "a", "s", "usd", "tools"}

    def configure(self, api_key=None, workspace=None):
        with self._lock:
            key = self.api_key if api_key is None else api_key.strip()
            space = self.workspace if workspace is None else workspace.strip()
            if (key, space) == (self.api_key, self.workspace):
                return
            self.api_key, self.workspace = key, space
            self._generation += 1
            self._client = None
            self.problem = None
            self.earworm_problem = None

    @property
    def ready(self) -> bool:
        return bool(self.api_key)

    def _client_(self):
        with self._lock:
            if not self.ready:
                raise PermissionError("Claude key removed")
            if self._client is None:
                import anthropic
                headers = {"anthropic-workspace-id": self.workspace} if self.workspace else None
                self._client = anthropic.Anthropic(api_key=self.api_key, default_headers=headers,
                                                  timeout=75.0, max_retries=0)
            return self._client

    @staticmethod
    def _safe_problem(exc: Exception) -> str:
        """Provider exception bodies and URLs can contain secrets; never publish them."""
        code = getattr(exc, "status_code", None)
        if code == 401:
            return REFUSED
        if code == 403:
            return FORBIDDEN
        if code == 429:
            return LIMITED
        if code == 400 and "workspace" in str(exc).lower():
            return NEEDS_WORKSPACE
        if isinstance(exc, TimeoutError):
            return TIMED_OUT
        return "Claude could not complete the request. Check the connection and try again."

    def _problem_for(self, generation: int, message: str | None):
        with self._lock:
            if generation == self._generation:
                self.problem = message

    @staticmethod
    def _needs_owner(exc: Exception) -> bool:
        """A failure only the owner can fix: the key refused, no access to the
        model or workspace, or a workspace ID missing. A timeout, a busy
        service or a dropped network passes on its own."""
        code = getattr(exc, "status_code", None)
        return code in (401, 403) or (code == 400 and "workspace" in str(exc).lower())

    def _helper_failed(self, generation: int, what: str, exc: Exception):
        """A game's or a drawing's call to Claude failed. The caller already
        falls back or says so, so only an owner-level failure is kept as the
        connection's problem."""
        why = self._safe_problem(exc)
        print(f"[ask] {what}: {why}", flush=True)
        if self._needs_owner(exc):
            self._problem_for(generation, why)

    def _worked(self, generation: int):
        """Claude answered, so the key and workspace work: a problem from an
        earlier call no longer describes this connection."""
        self._problem_for(generation, None)

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
        """Voice-compatible words; HTTP callers use ask_reply for error status."""
        reply = self.ask_reply(question, size)
        return reply.get("answer") or reply.get("error") or "The wall could not answer."

    def ask_reply(self, question: str, size: int = 64) -> dict:
        """One charged question at a time, with honest success/error semantics."""
        if not self._ask_lock.acquire(blocking=False):
            return {"answer": None, "error": "The wall is already answering a question.", "busy": True}
        self.pending = True
        generation = self._generation
        try:
            if not self.ready:
                return {"answer": None, "error": "Add your Claude key in Services to begin.", "busy": False}
            self.problem = None
            try:
                answer, ok = self._ask_answer(question, size)
            except Exception as exc:
                # Client construction and optional dependencies can fail before
                # the request itself. Never strand a phone's pending state.
                self._problem_for(generation, self._safe_problem(exc))
                answer, ok = "The wall couldn't reach Claude. Check Services and try again.", False
            if generation != self._generation:
                return {"answer": None, "error": "The Claude connection changed. Try the question again.", "busy": False}
            # Success is what _ask_answer says, never self.problem: the
            # earworm and the games write that from other threads, and a
            # paid answer must not come back as an error because of them.
            if not ok:
                return {"answer": None, "error": answer, "busy": False}
            return {"answer": answer, "error": None, "busy": False}
        finally:
            self.pending = False
            self._ask_lock.release()

    def _ask_answer(self, question: str, size: int = 64) -> tuple[str, bool]:
        """(words, answered): the answer, or the words that say why not."""
        import anthropic
        t0 = time.monotonic()
        generation = self._generation
        client = self._client_()
        messages = [{"role": "user", "content": question}]
        usage_in = usage_out = 0
        used = []
        try:
            for _ in range(MAX_TOOL_ROUNDS):
                if generation != self._generation:
                    return "The Claude connection changed. Try the question again.", False
                remaining = 75.0 - (time.monotonic() - t0)
                if remaining <= 0:
                    raise TimeoutError("Question exceeded its response window")
                resp = client.messages.create(
                    model=self.model, max_tokens=MAX_TOKENS,
                    system=system_prompt(size), tools=TOOLS, messages=messages,
                    output_config={"effort": "low"}, timeout=remaining,
                )
                if generation != self._generation:
                    return "The Claude connection changed. Try the question again.", False
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
                            with self._lock:
                                if generation != self._generation:
                                    return "The Claude connection changed. Try the question again.", False
                                out = self._run_tool(block.name, dict(block.input or {}))
                            results.append({"type": "tool_result", "tool_use_id": block.id,
                                            "content": json.dumps(out)})
                    messages.append({"role": "user", "content": results})
                    continue
                answer = " ".join(b.text for b in resp.content if b.type == "text").strip()
                break
            else:
                answer = "That took too many steps. Ask me again more simply."
        except TimeoutError:
            self._problem_for(generation, TIMED_OUT)
            return "That took too long. Try a shorter question.", False
        except anthropic.AuthenticationError:
            self._problem_for(generation, REFUSED)
            return "Claude rejected the key on this wall.", False
        except anthropic.RateLimitError:
            self._problem_for(generation, LIMITED)
            return "Claude is busy. Ask again in a moment.", False
        except anthropic.APIConnectionError:
            self._problem_for(generation, OFFLINE)
            return "No answer right now: the network is away.", False
        except anthropic.APIStatusError as exc:
            self._problem_for(generation, self._safe_problem(exc))
            return "Claude could not answer just now.", False
        except Exception as exc:
            self._problem_for(generation, self._safe_problem(exc))
            return "Something went wrong asking.", False
        answer = answer or "I have nothing to say to that."
        usd = usage_in * PRICE_IN + usage_out * PRICE_OUT
        with self._lock:
            if generation != self._generation:
                return "The Claude connection changed. Try the question again.", False
            self.cost_usd += usd
            self.answers += 1
            self.problem = None
            self.last = {"q": question, "a": answer, "s": round(time.monotonic() - t0, 2),
                         "usd": round(usd, 4), "tools": used, "ts": int(time.time())}
            self.history.insert(0, dict(self.last))
            del self.history[12:]
            print(f"[ask] {question!r} -> {answer!r} in {self.last['s']} s, "
                  f"{usage_in}+{usage_out} tokens, ${usd:.4f}, tools {used}", flush=True)
        return answer, True

    def earworm(self, words: str) -> dict | None:
        """{title, artist, confidence, alternatives:[{title, artist}]} from
        the words someone remembers, or None."""
        if not self.ready:
            self.earworm_problem = "Connect Claude in Services to identify a song."
            return None
        if not isinstance(words, str) or not words.strip() or len(words) > 2000:
            self.earworm_problem = "Add a lyric or a description, up to 2,000 characters."
            return None
        try:
            from pydantic import BaseModel, Field
        except ImportError:
            self.earworm_problem = "Song identification needs the Claude service dependencies installed on this wall."
            return None
        class Guess(BaseModel):
            title: str
            artist: str
        class Earworm(BaseModel):
            title: str
            artist: str
            confidence: float = Field(ge=0, le=1, allow_inf_nan=False)
            alternatives: list[Guess]
        if not self._ask_lock.acquire(blocking=False):
            self.earworm_problem = "Claude is finishing another request. Try again in a moment."
            return None
        self.pending, self.earworm_problem = True, None
        generation = self._generation
        try:
            resp = self._client_().messages.parse(
                model=self.model, max_tokens=400,
                system="Someone remembers a fragment of a song's lyrics, or a description of it. Name the song. "
                       "confidence is 0 to 1. Give up to three alternatives when unsure. "
                       "Never invent a title. If no plausible song exists, return an empty title and artist "
                       "with confidence 0. Return song metadata only; do not quote lyrics.",
                messages=[{"role": "user", "content": words}],
                output_format=Earworm, output_config={"effort": "low"},
            )
            if generation != self._generation:
                return None
            self._worked(generation)
            self.answers += 1
            got = resp.parsed_output
            if got is None or not got.title.strip() or not got.artist.strip():
                self.earworm_problem = "No confident match yet. Add another line, an artist, or the decade."
                return None
            title, artist = got.title.strip()[:300], got.artist.strip()[:300]
            alternatives, seen = [], {(title.casefold(), artist.casefold())}
            for guess in got.alternatives:
                name, who = guess.title.strip()[:300], guess.artist.strip()[:300]
                key = (name.casefold(), who.casefold())
                if name and who and key not in seen:
                    alternatives.append({"title": name, "artist": who})
                    seen.add(key)
                if len(alternatives) == 3:
                    break
            return {"title": title, "artist": artist, "confidence": got.confidence,
                    "alternatives": alternatives}
        except Exception as exc:
            print(f"[ask] earworm: {type(exc).__name__}", flush=True)
            # The page shows why this guess failed. Only a failure the owner
            # must fix also marks the Claude connection.
            self.earworm_problem = (self._safe_problem(exc) if self._needs_owner(exc) else
                                    "Song identification could not finish. Check Claude in Services, then try again.")
            if self._needs_owner(exc):
                self._problem_for(generation, self.earworm_problem)
            return None
        finally:
            self.pending = False
            self._ask_lock.release()

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
        generation = self._generation
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
            self._worked(generation)
            usage = getattr(resp, "usage", None)
            if usage is not None:
                self.cost_usd += (getattr(usage, "input_tokens", 0) or 0) * PRICE_IN \
                    + (getattr(usage, "output_tokens", 0) or 0) * PRICE_OUT
            got = resp.parsed_output
            return [(g.theme, [w.strip().lower() for w in g.words]) for g in got.groups]
        except Exception as exc:
            self._helper_failed(generation, "connections", exc)
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
        generation = self._generation
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
                self._worked(generation)
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
                self._helper_failed(generation, "strands", exc)
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
        generation = self._generation
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
            self._worked(generation)
            usage = getattr(resp, "usage", None)
            if usage is not None:
                self.cost_usd += (getattr(usage, "input_tokens", 0) or 0) * PRICE_IN \
                    + (getattr(usage, "output_tokens", 0) or 0) * PRICE_OUT
            got = resp.parsed_output
            qs = [(q.question.strip(), [a.strip() for a in q.answers if a.strip()]) for q in got.questions]
            qs = [q for q in qs if q[0] and q[1]][:n]
            return (got.theme.strip(), qs) if len(qs) >= 5 else None
        except Exception as exc:
            self._helper_failed(generation, "quiz", exc)
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
        generation = self._generation
        try:
            resp = self._client_().messages.parse(
                model=self.model, max_tokens=600,
                system="Write mini crossword clues: short, fair, in the style of a newspaper's mini, one per word. "
                       "Never include the word itself or its plain form in its clue. Keep each under nine words.",
                messages=[{"role": "user", "content": ", ".join(words)}],
                output_format=Clues, output_config={"effort": "low"},
            )
            self._worked(generation)
            usage = getattr(resp, "usage", None)
            if usage is not None:
                self.cost_usd += (getattr(usage, "input_tokens", 0) or 0) * PRICE_IN \
                    + (getattr(usage, "output_tokens", 0) or 0) * PRICE_OUT
            out = {c.word.strip().lower(): c.clue.strip() for c in resp.parsed_output.clues}
            return out if all(w in out for w in words) else None
        except Exception as exc:
            self._helper_failed(generation, "clues", exc)
            return None

    def image_prompt(self, prompt: str, size: int = 64) -> str | None:
        """The words rewritten as a prompt for a picture on a panel of this
        size (brain/imagine.py), or None when Claude cannot be asked."""
        if not self.ready:
            return None
        from .imagine import IMAGE_SYSTEM
        generation = self._generation
        try:
            resp = self._client_().messages.create(
                model=self.model, max_tokens=200,
                system=IMAGE_SYSTEM.format(size=size),
                messages=[{"role": "user", "content": prompt}],
                output_config={"effort": "low"},
            )
            text = " ".join(b.text for b in resp.content if getattr(b, "type", "") == "text").strip()
            self._worked(generation)
            usage = getattr(resp, "usage", None)
            if usage is not None:
                self.cost_usd += (getattr(usage, "input_tokens", 0) or 0) * PRICE_IN \
                    + (getattr(usage, "output_tokens", 0) or 0) * PRICE_OUT
            return text or None
        except Exception as exc:
            self._helper_failed(generation, "image prompt", exc)
            return None

    def status(self) -> dict:
        with self._lock:
            return {"ready": self.ready, "pending": self.pending, "model": self.model, "answers": self.answers,
                    "cost_usd": round(self.cost_usd, 4), "last": dict(self.last) if self.last else None, "problem": self.problem,
                    # None for any other problem, so the phone never guesses from the words
                    "problem_code": PROBLEM_CODES.get(self.problem),
                    "workspace_set": bool(self.workspace), "history": [dict(item) for item in self.history]}
