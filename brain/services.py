"""Service credentials the phone hands the wall, kept on the wall.

config.toml seeds them. Anything set from the phone lands in
~/.config/album-art-matrix/services.json and wins from then on, which is
what lets a service be connected with nothing but a phone. The values are
applied to the running adapters straight away: no restart, no file to edit.
"""
import json
import os
import re
import threading

PATH = os.path.expanduser("~/.config/album-art-matrix/services.json")

# section -> key -> pattern a value must match. Empty clears a value.
FIELDS = {
    "spotify": {"client_id": r"^[0-9A-Za-z]{8,64}$"},
    "lastfm": {"api_key": r"^[0-9A-Za-z]{16,64}$",
               "user": r"^[^\s/]{1,64}$"},
    "listenbrainz": {"user": r"^[^\s/]{1,64}$"},
    "acoustid": {"api_key": r"^[0-9A-Za-z_-]{6,64}$",
                 "device": r"^(auto|[A-Za-z0-9:_,.=-]{1,64})$"},
}


class Services:
    def __init__(self, cfg: dict):
        self._lock = threading.Lock()
        self.data = {s: {k: "" for k in keys} for s, keys in FIELDS.items()}
        for s, keys in FIELDS.items():
            for k in keys:
                v = (cfg.get(s) or {}).get(k, "")
                if isinstance(v, str) and not v.startswith("PASTE"):
                    self.data[s][k] = v.strip()
        try:
            with open(PATH) as fh:
                saved = json.load(fh)
            for s, keys in FIELDS.items():
                for k in keys:
                    v = (saved.get(s) or {}).get(k)
                    if isinstance(v, str):
                        self.data[s][k] = v.strip()
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            pass

    def get(self, section: str, key: str) -> str:
        with self._lock:
            return self.data[section][key]

    def update(self, patch: dict):
        """Apply {section: {key: value}}. Returns (changed, rejected), and
        writes the file when anything changed."""
        changed, rejected = {}, {}
        with self._lock:
            for s, vals in (patch or {}).items():
                if s not in FIELDS or not isinstance(vals, dict):
                    rejected[s] = vals
                    continue
                for k, v in vals.items():
                    pattern = FIELDS[s].get(k)
                    if pattern is None or not isinstance(v, str):
                        rejected[f"{s}.{k}"] = v
                        continue
                    v = v.strip()
                    if v and not re.match(pattern, v):
                        rejected[f"{s}.{k}"] = v
                        continue
                    if self.data[s][k] != v:
                        self.data[s][k] = v
                        changed.setdefault(s, {})[k] = v
            if changed:
                self._save()
        return changed, rejected

    def _save(self):
        os.makedirs(os.path.dirname(PATH), exist_ok=True)
        tmp = PATH + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(self.data, fh, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, PATH)
