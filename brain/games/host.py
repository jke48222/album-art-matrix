"""The GameHost: one game at a time on the wall.

    GET  /game/list                     the games, with what each needs
    GET  /game                          the running game's state, or none
    POST /game/start {name, options, players}
    POST /game/move  {player, move}     a move from the phone
    POST /game/hear  {player, text}     words, from the phone's ear or the wall's
    POST /game/end                      put the game down

Starting a game puts the wall in mode "game" and remembers what it was
showing; ending one hands that back. Every state change bumps `seq`, so a
phone polls cheaply and redraws only when the number moves. Results go
to ~/.config/album-art-matrix/games.json: played, won, streak and best
per player per game, for the scoreboard.
"""
from __future__ import annotations

import json
import os
import threading
import time
import uuid

from . import GAMES, Game
from .board import scoreboard

PATH = os.path.expanduser("~/.config/album-art-matrix/games.json")


class GameHost:
    def __init__(self, ctrl, path: str = PATH, clock=None):
        self.ctrl = ctrl
        self.path = path
        self._clock = clock or time.monotonic
        self._lock = threading.RLock()
        self.game: Game | None = None
        self.seq = 0
        self.records: dict = {"players": {}}
        self._ret: str | None = None
        self._t0 = self._clock()
        self.session_id: str | None = None
        self._starting: str | None = None
        self._generation = 0
        self._recorded: Game | None = None
        self.last: dict | None = None
        self._load()

    # ---- disk ---------------------------------------------------------------------------
    def _load(self):
        try:
            with open(self.path) as fh:
                d = json.load(fh)
            if isinstance(d, dict) and isinstance(d.get("players"), dict):
                self.records = d
        except (OSError, ValueError):
            pass

    def _save(self):
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            tmp = self.path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(self.records, fh)
            os.replace(tmp, self.path)
        except OSError as exc:
            print(f"[games] could not save: {exc}", flush=True)

    # ---- the games --------------------------------------------------------------------------
    def listing(self) -> list[dict]:
        return [cls.describe() for cls in GAMES.values()]

    def _stale(self, session_id):
        if session_id is not None and session_id != self.session_id:
            return {**self.status(), "error": "The game changed. Refresh before making another move.", "code": 409}
        return None

    def start(self, name: str, options: dict | None = None, players: list[str] | None = None,
              session_id: str | None = None) -> dict:
        cls = GAMES.get(str(name or "").strip().lower())
        if cls is None:
            return {**self.status(), "error": f"no game called {name}", "code": 404}
        if options is not None and not isinstance(options, dict):
            return {**self.status(), "error": "Game options must be an object.", "code": 400}
        if players is not None and (not isinstance(players, list) or any(not isinstance(p, str) for p in players)):
            return {**self.status(), "error": "Players must be a list of names.", "code": 400}
        players = list(dict.fromkeys(p.strip()[:24] for p in (players or []) if p.strip())) or ["You"]
        if len(players) < cls.min_players:
            return {**self.status(), "error": f"{cls.title} needs {cls.min_players} players", "code": 400}
        players = players[:cls.max_players]
        with self._lock:
            stale = self._stale(session_id)
            if stale:
                return stale
            if self._starting:
                return {**self.status(), "error": "Another game is getting ready.", "code": 409}
            self._generation += 1
            generation = self._generation
            self._starting = cls.name
            previous_mode = self.ctrl.get()["mode"]
            previous_shown = self.ctrl.shown_seq
        # Provider-backed games may need the network. Keep status, rendering and
        # ending the old game responsive while the new puzzle is prepared.
        try:
            game = cls(self, options or {}, players)
            game.setup()
        except Exception as exc:
            with self._lock:
                if generation == self._generation:
                    self._starting = None
                print(f"[games] {name} could not start: {exc}", flush=True)
                detail = str(exc)[:200] if isinstance(exc, (ValueError, RuntimeError)) else "Try again when the service is available."
                return {**self.status(), "error": f"{cls.title} couldn't start. {detail}", "code": 400 if isinstance(exc, ValueError) else 502}
        with self._lock:
            if generation != self._generation:
                return {**self.status(), "error": "Starting this game was cancelled.", "code": 409}
            self._starting = None
            if self.ctrl.get()["mode"] != previous_mode or self.ctrl.shown_seq != previous_shown:
                return {**self.status(), "error": "The wall changed while this game was loading. Start it again when you're ready.", "code": 409}
            if self.game is not None and not self.game.over:
                self._note_abandoned(self.game)
            elif self.game is not None:
                self._record(self.game)
            self.game = game
            self._recorded = None
            self.session_id = uuid.uuid4().hex
            self._t0 = self._clock()
            if previous_mode != "game":
                self._ret = previous_mode if previous_mode not in ("frame", "clip", "timer", "video") else "art"
            self.seq += 1
            self.ctrl.apply({"mode": "game"})
            self.ctrl.shown_seq += 1
            self.ctrl.dirty.set()
            for p in players:
                self.records["players"].setdefault(p, {})
            self._save()
            return self.status()

    def move(self, player: str | None, move: dict, session_id: str | None = None) -> dict:
        restart = None
        with self._lock:
            stale = self._stale(session_id)
            if stale:
                return stale
            g = self.game
            if g is None:
                return {**self.status(), "error": "no game is on", "code": 409}
            if not isinstance(move, dict):
                return {**self.status(), "error": "A move must be an object.", "code": 400}
            if g.over:
                if set(move) == {"again"} and move["again"] is True:
                    # Provider setup must not inherit this outer RLock. Pin the
                    # observed session even for a legacy caller without an ID.
                    restart = (g.name, dict(g.options), list(g.players), self.session_id)
                else:
                    return {**self.status(), "error": "that game is over", "code": 409}
            else:
                try:
                    result = g.apply(move, self._who(player))
                except Exception as exc:
                    print(f"[games] {g.name} move failed: {exc}", flush=True)
                    return {**self.status(), "error": "That move could not be applied. Try again.", "code": 400}
                self.seq += 1
                self.ctrl.dirty.set()
                if g.over:
                    self._record(g)
                return {**self.status(), **(result or {})}
        return self.start(*restart)

    def hear(self, text: str, player: str | None = None, session_id: str | None = None) -> dict | None:
        with self._lock:
            stale = self._stale(session_id)
            if stale:
                return stale
            g = self.game
            if g is None or g.over:
                return None
            try:
                result = g.hear(" ".join((text or "").split()), self._who(player))
            except Exception as exc:
                print(f"[games] {g.name} heard move failed: {exc}", flush=True)
                return None
            if result is None:
                return None
            self.seq += 1
            self.ctrl.dirty.set()
            if g.over:
                self._record(g)
            return {**self.status(), **result}

    def event(self, kind: str, info: dict) -> bool:
        with self._lock:
            g = self.game
            if g is None or g.over or self.ctrl.get()["mode"] != "game":
                return False
            try:
                used = bool(g.event(kind, info))
            except Exception as exc:
                print(f"[games] {g.name} {kind}: {exc}", flush=True)
                return False
            if used:
                if kind != "pitch":
                    self.seq += 1
                self.ctrl.dirty.set()
                if g.over:
                    self._record(g)
            return used

    def resume(self, session_id: str | None = None) -> dict:
        with self._lock:
            stale = self._stale(session_id)
            if stale:
                return stale
            if self.game is None:
                return {**self.status(), "error": "No game to return to.", "code": 409}
            here = self.ctrl.get()["mode"]
            if here != "game":
                self._ret = here if here not in ("frame", "clip", "timer", "video") else "art"
                self.ctrl.apply({"mode": "game"})
                self.ctrl.shown_seq += 1
                self.seq += 1
                self.ctrl.dirty.set()
            return self.status()

    def end(self, session_id: str | None = None) -> dict:
        with self._lock:
            stale = self._stale(session_id)
            if stale:
                return stale
            self._generation += 1
            self._starting = None
            g = self.game
            if g is None:
                return {"ended": False, **self.status()}
            if not g.over:
                self._note_abandoned(g)
            else:
                self._record(g)
            self.game = None
            self.session_id = None
            self.seq += 1
            if self.ctrl.get()["mode"] == "game":
                self.ctrl.apply({"mode": self._ret or "art"})
            self._ret = None
            self.ctrl.dirty.set()
            return {"ended": True, **self.status()}

    def _who(self, player: str | None) -> str:
        p = (player or "").strip()
        if self.game and p and p in self.game.players:
            return p
        return self.game.players[0] if self.game else p

    # ---- results ------------------------------------------------------------------------------
    def _record(self, g: Game):
        if self._recorded is g:
            return
        self._recorded = g
        for p in g.players:
            rec = self.records["players"].setdefault(p, {}).setdefault(
                g.name, {"played": 0, "won": 0, "streak": 0, "best": 0})
            rec["played"] += 1
            won = (g.winner == p) if g.winner is not None else (g.won and len(g.players) == 1)
            if won:
                rec["won"] += 1
                rec["streak"] += 1
                rec["best"] = max(rec["best"], rec["streak"])
            else:
                rec["streak"] = 0
            rec["last"] = int(time.time())
        self.last = {"game": g.name, "title": g.title, "players": g.players, "won": g.won,
                     "winner": g.winner, "message": g.message, "at": int(time.time())}
        self._save()
        print(f"[games] {g.title}: " + (f"{g.winner} won" if g.winner else "solved" if g.won else "not solved")
              + (f" ({g.message})" if g.message else ""), flush=True)

    def _note_abandoned(self, g: Game):
        if self._recorded is g:
            return
        self._recorded = g
        g.over = True
        g.finished = time.time()
        for p in g.players:
            rec = self.records["players"].setdefault(p, {}).setdefault(
                g.name, {"played": 0, "won": 0, "streak": 0, "best": 0})
            rec["played"] += 1
            rec["streak"] = 0
        self._save()

    def scores(self, name: str | None = None) -> dict:
        out = {}
        for p, games in self.records["players"].items():
            if name:
                if name in games:
                    out[p] = games[name]
            else:
                out[p] = games
        return out

    # ---- for the wall and the phone --------------------------------------------------------------
    def changed(self):
        with self._lock:
            self.seq += 1
            self.ctrl.dirty.set()

    def status(self) -> dict:
        with self._lock:
            g = self.game
            public = g.public() if g else None
            if g is not None and g.over:
                self._record(g)
            return {"running": g is not None, "seq": self.seq, "game": public,
                    "session_id": self.session_id, "on_wall": g is not None and self.ctrl.get()["mode"] == "game",
                    "starting": self._starting, "scores": self.scores(g.name) if g else {}, "last": self.last,
                    "voice_words": (g.voice_words() if g else [])[:3000]}

    def artwork(self, size: int, session_id: str, sequence: int, frame_step: int | None = None):
        """A detailed rendering of this exact session, without changing faces."""
        with self._lock:
            if not session_id or session_id != self.session_id or self.game is None:
                return None
            game = self.game
            def matches():
                state = game.state()
                return game.seq == sequence and (frame_step is None or state.get("frame_step") == frame_step)
            if not matches():
                return None
            frame = self.frame_at(size).copy()
            return frame if matches() else None

    def frame_at(self, size: int, now: float | None = None):
        with self._lock:
            t = (now if now is not None else self._clock()) - self._t0
            g = self.game
            if g is None:
                lines = []
                if self.last:
                    lines = [(p, "won" if self.last["winner"] == p or (self.last["won"] and len(self.last["players"]) == 1)
                              else "played") for p in self.last["players"]]
                return scoreboard(size, self.last["title"] if self.last else "Games", lines, t)
            frame = g.frame_at(size, t)
            if g.over:
                self._record(g)
            return frame
