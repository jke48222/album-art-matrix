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

    def start(self, name: str, options: dict | None = None, players: list[str] | None = None) -> dict:
        cls = GAMES.get(str(name or "").strip().lower())
        if cls is None:
            return {"error": f"no game called {name}"}
        players = [str(p).strip()[:24] for p in (players or []) if str(p).strip()] or ["You"]
        if len(players) < cls.min_players:
            return {"error": f"{cls.title} needs {cls.min_players} players"}
        players = players[:cls.max_players]
        with self._lock:
            if self.game is not None and not self.game.over:
                self._note_abandoned(self.game)
            game = cls(self, options or {}, players)
            try:
                game.setup()
            except Exception as exc:
                print(f"[games] {name} could not start: {exc}", flush=True)
                return {"error": f"{cls.title} could not start: {str(exc)[:120]}"}
            self.game = game
            self._t0 = self._clock()
            here = self.ctrl.get()["mode"]
            if here != "game":
                self._ret = here if here not in ("frame", "clip", "timer", "video") else "art"
            self.seq += 1
            self.ctrl.apply({"mode": "game"})
            self.ctrl.shown_seq += 1
            self.ctrl.dirty.set()
        for p in players:
            self.records["players"].setdefault(p, {})
        self._save()
        print(f"[games] {cls.title} for {', '.join(players)}", flush=True)
        return self.status()

    def move(self, player: str | None, move: dict) -> dict:
        with self._lock:
            g = self.game
            if g is None:
                return {"error": "no game is on"}
            if g.over:
                return {"error": "that game is over", **self.status()}
            who = self._who(player)
            try:
                result = g.apply(move or {}, who)
            except Exception as exc:
                print(f"[games] {g.name} move {move}: {exc}", flush=True)
                return {"error": f"the move went wrong: {str(exc)[:120]}"}
            self.seq += 1
            self.ctrl.dirty.set()
            if g.over:
                self._record(g)
            return {**(result or {}), **self.status()}

    def hear(self, text: str, player: str | None = None) -> dict | None:
        """Words heard: the game's move, or None when they are not one."""
        with self._lock:
            g = self.game
            if g is None or g.over:
                return None
            try:
                result = g.hear(" ".join((text or "").split()), self._who(player))
            except Exception as exc:
                print(f"[games] {g.name} hear {text!r}: {exc}", flush=True)
                return None
            if result is None:
                return None
            self.seq += 1
            self.ctrl.dirty.set()
            if g.over:
                self._record(g)
            return {**result, **self.status()}

    def event(self, kind: str, info: dict) -> bool:
        """The ear's knocks, whistles and pitch, to the running game."""
        g = self.game
        if g is None or g.over:
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

    def end(self) -> dict:
        with self._lock:
            g = self.game
            if g is None:
                return {"ended": False, **self.status()}
            if not g.over:
                self._note_abandoned(g)
            self.game = None
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
        self.seq += 1
        self.ctrl.dirty.set()

    def status(self) -> dict:
        g = self.game
        return {"running": g is not None, "seq": self.seq, "game": g.public() if g else None,
                "scores": self.scores(g.name) if g else {}, "last": self.last,
                "voice_words": (g.voice_words() if g else [])[:3000]}

    def frame_at(self, size: int, now: float | None = None):
        t = (now if now is not None else self._clock()) - self._t0
        g = self.game
        if g is None:
            lines = []
            if self.last:
                lines = [(p, "won" if self.last["winner"] == p or (self.last["won"] and len(self.last["players"]) == 1)
                          else "played") for p in self.last["players"]]
            return scoreboard(size, self.last["title"] if self.last else "Games", lines, t)
        return g.frame_at(size, t)
