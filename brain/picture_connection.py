"""Private Google search verification, independent from displaying a picture."""
import threading
import time

import requests

UNANSWERED = "Google did not answer. Built-in picture search remains available."
REFUSED = "Google refused this connection. Check your existing API access, key and search engine ID."
LIMITED = "Google's search limit was reached. Try later or use built-in search."
# What an answer from Google says about the saved connection.
OUTCOMES = {200: ("ready", None), 400: ("refused", REFUSED), 401: ("refused", REFUSED),
            403: ("refused", REFUSED), 429: ("limited", LIMITED)}


class PictureConnection:
    def __init__(self, key="", engine=""):
        self.lock = threading.RLock()
        self.generation = 0
        self.key, self.engine = key, engine
        self.state = "saved" if key and engine else "default"
        self.problem = None
        self.checked_at = None

    def configure(self, key, engine):
        with self.lock:
            if (key, engine) == (self.key, self.engine):
                return
            self.generation += 1
            self.key, self.engine = key, engine
            self.state = "saved" if key and engine else "default"
            self.problem = self.checked_at = None

    def status(self):
        with self.lock:
            return {"state": self.state, "verified": self.state == "ready",
                    "checking": self.state == "checking", "checked_at": self.checked_at,
                    "problem": self.problem}

    def check(self):
        """False only when there is nothing saved to check."""
        with self.lock:
            if not self.key or not self.engine:
                return False
            if self.state == "checking":
                return True
            generation, key, engine = self.generation, self.key, self.engine
            self.state, self.problem = "checking", None
        try:
            threading.Thread(target=self._run, args=(generation, key, engine), daemon=True).start()
        except RuntimeError:
            # The Pi can refuse a new thread when memory is short. Settle the
            # check here, or every later one would wait on a thread that never ran.
            with self.lock:
                if generation == self.generation:
                    self.state, self.problem = "unavailable", UNANSWERED
        return True

    def note(self, key, engine, code):
        """A real search answers the same question a check does, so a key
        Google starts refusing (or accepts again) shows without a manual check."""
        outcome = OUTCOMES.get(code)
        with self.lock:
            if outcome is None or self.state == "checking" or (key, engine) != (self.key, self.engine):
                return
            self.state, self.problem = outcome
            self.checked_at = int(time.time())

    def _run(self, generation, key, engine):
        state, problem = "unavailable", UNANSWERED
        try:
            response = requests.get("https://www.googleapis.com/customsearch/v1", params={
                "key": key, "cx": engine, "q": "landscape", "searchType": "image", "num": 1,
                "safe": "active"}, timeout=10)
            try:
                if response.status_code == 200:
                    body = response.json()
                    if isinstance(body, dict) and isinstance(body.get("items", []), list) and "error" not in body:
                        state, problem = OUTCOMES[200]
                elif response.status_code in OUTCOMES:
                    state, problem = OUTCOMES[response.status_code]
            finally:
                response.close()
        except Exception:
            # Any failure must still end the check below, and its text is not
            # logged because a requests error can carry the URL with the key.
            pass
        with self.lock:
            if generation == self.generation:
                self.state, self.problem, self.checked_at = state, problem, int(time.time())
