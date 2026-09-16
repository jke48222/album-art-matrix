"""Choose which new abilities the wall uses while comparing the two builds.

The switches belong to this build's config.toml. A small watcher reads edits
away from the drawing loop; callers check the in-memory choice at the moment
an ability would act. Missing switches stay off so an upgrade is quiet.
"""
import threading
import tomllib
from pathlib import Path

NAMES = ("scrobble", "knock", "teach", "ask", "wake", "horizon", "note",
         "airplay", "shelf", "earworm", "show", "imagine", "weather", "posters", "games")


class Features:
    def __init__(self, cfg=None, path=None):
        self.path = Path(path) if path else None
        self._values = self._parse(cfg or {})
        self.problem = None
        self._stop = threading.Event()

    @staticmethod
    def _parse(cfg):
        table = cfg.get("features", {})
        return {name: table.get(name) is True for name in NAMES}

    def enabled(self, name):
        return self._values.get(name, False)

    def public(self):
        return {"features": dict(self._values), "problem": self.problem}

    def reload(self):
        if self.path is None:
            return
        try:
            with self.path.open("rb") as fh:
                values = self._parse(tomllib.load(fh))
            self._values, self.problem = values, None
        except (OSError, ValueError) as exc:
            problem = f"could not read feature switches: {type(exc).__name__}"
            if self.problem != problem:
                print(f"[features] {problem}; keeping previous switches", flush=True)
            self.problem = problem

    def start(self):
        def watch():
            while not self._stop.wait(1):
                self.reload()
        threading.Thread(target=watch, daemon=True, name="features").start()
        return self

    def close(self):
        self._stop.set()
