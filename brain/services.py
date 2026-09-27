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
import tempfile
from contextlib import nullcontext

PATH = os.path.expanduser("~/.config/album-art-matrix/services.json")

# section -> key -> pattern a value must match. Empty clears a value.
FIELDS = {
    "mac": {"endpoint": r"^.{1,300}$"},
    "spotify": {"client_id": r"^[0-9A-Za-z]{8,64}$"},
    "lastfm": {"api_key": r"^[0-9A-Za-z]{16,64}$",
               "user": r"^[^\s/]{1,64}$"},
    # the token is what lets the wall WRITE listens (brain/scrobble.py); it
    # comes from listenbrainz.org/settings and is shaped like a UUID
    "listenbrainz": {"user": r"^[^\s/]{1,64}$",
                     "token": r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"},
    "ears": {"device": r"^(auto|[A-Za-z0-9:_,.=-]{1,64})$"},
    # Ask the wall (brain/ask.py): an Anthropic API key, set from the phone
    "claude": {"api_key": r"^sk-ant-[A-Za-z0-9_\-]{20,200}$",
               # a key made at the organisation level must name a workspace
               "workspace": r"^wrkspc_[A-Za-z0-9_\-]{4,80}$"},
    # imagine (brain/imagine.py): which image model draws, and its key
    "images": {"provider": r"^(openai|google)$",
               "api_key": r"^[A-Za-z0-9_\-]{20,300}$",
               "quality": r"^(low|medium|high)$",
               "model": r"^[A-Za-z0-9._\-]{3,64}$"},
    # posters (brain/posters.py): a TMDB API key (v3, 32 hex) or read access
    # token (v4, a JWT), from themoviedb.org/settings/api
    "tmdb": {"api_key": r"^([0-9a-f]{32}|eyJ[A-Za-z0-9._\-]{40,800})$"},
    # pictures (brain/show.py): Google Images through the Custom Search JSON
    # API: an API key from the Cloud console and the id of a Programmable
    # Search Engine set to search the whole web with image search on
    "google": {"api_key": r"^[A-Za-z0-9_\-]{30,80}$",
               "cx": r"^[A-Za-z0-9:_\-]{8,80}$"},
    # the shelf (brain/shelf.py): a Discogs personal access token, from
    # discogs.com/settings/developers, and the username whose collection it is
    "discogs": {"token": r"^[A-Za-z0-9]{20,100}$",
                "user": r"^[^\s/]{1,64}$"},
    # the ear's old name. Still accepted, so a phone that has not been
    # rebuilt can keep sending its AcoustID key without being refused;
    # nothing reads the key now.
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
        if not self.data["mac"]["endpoint"]:
            self.data["mac"]["endpoint"] = str((cfg.get("applemusic") or {}).get("endpoint") or "")
        try:
            with open(PATH) as fh:
                saved = json.load(fh)
            if not isinstance(saved, dict):
                raise ValueError("invalid service store")
            for s, keys in FIELDS.items():
                section = saved.get(s)
                if not isinstance(section, dict):
                    continue
                for k in keys:
                    v = section.get(k)
                    if isinstance(v, str):
                        self.data[s][k] = v.strip()
        except (ValueError, OSError):
            pass

    def get(self, section: str, key: str) -> str:
        with self._lock:
            return self.data[section][key]

    def update(self, patch: dict, transaction=None):
        """Apply {section: {key: value}}. Returns (changed, rejected), and
        writes the file when anything changed."""
        changed, rejected = {}, {}
        with self._lock:
            candidate = {section: dict(values) for section, values in self.data.items()}
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
                    if s == "mac" and k == "endpoint":
                        from .nowplaying.reporter_endpoint import normalize_endpoint
                        try:
                            v = normalize_endpoint(v)
                        except ValueError:
                            rejected["mac.endpoint"] = "Invalid reporter address"
                            continue
                    if v and not re.match(pattern, v):
                        rejected[f"{s}.{k}"] = v
                        continue
                    if candidate[s][k] != v:
                        candidate[s][k] = v
                        changed.setdefault(s, {})[k] = v
            if "provider" in changed.get("images", {}):
                # A credential and model belong to one provider. An omitted or
                # rejected replacement must never carry a previous key across.
                for key in ("api_key", "model"):
                    provided = isinstance(patch.get("images"), dict) and key in patch["images"] and f"images.{key}" not in rejected
                    if not provided and candidate["images"][key]:
                        candidate["images"][key] = ""
                        changed.setdefault("images", {})[key] = ""
            if changed:
                # Adapters may stage a reversible credential change. Publish
                # neither values nor side effects until the disk commit succeeds.
                with transaction(changed, candidate) if transaction else nullcontext():
                    self._save(candidate)
                self.data = candidate
        return changed, rejected

    def _save(self, data):
        directory = os.path.dirname(PATH)
        os.makedirs(directory, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".services-", dir=directory)
        try:
            with os.fdopen(fd, "w") as fh:
                os.fchmod(fh.fileno(), 0o600)
                json.dump(data, fh, indent=2)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(temporary, PATH)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
