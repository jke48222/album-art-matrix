"""Imagine: a picture from a description.

    "create a purple elephant"  ->  a purple elephant on the panel

The words go to Claude first, when a key is set, to be written out as a
prompt for a picture that will be seen on a 64 or 192 pixel LED panel:
one bold subject, centred, simple shapes, strong contrast, plain
background, no text (without Claude a fixed template does the same job,
less well). The prompt goes to an image model, OpenAI's gpt-image-1 or
Google's Imagen through their REST APIs, whichever the phone chose
(Services > Images), and the picture comes back as bytes. It is
downscaled through the sleeve pipeline (Lanczos, unsharp) at the wall's
own size and shown in the frame face for ten minutes, or until something
else is chosen, and kept at full size with its prompt in
~/.config/album-art-matrix/imagined/, listed by GET /imagine and shown
again by POST /imagine/show {id}.

One picture every ten seconds at most. Every picture's cost is counted.
"""
from __future__ import annotations

import base64
import io
import json
import os
import re
import threading
import time

import requests
from PIL import Image

DIR = os.path.expanduser("~/.config/album-art-matrix/imagined")
MIN_GAP_S = 10.0
SHOW_S = 600.0
KEEP = 200                       # pictures kept; the oldest go

OPENAI_URL = "https://api.openai.com/v1/images/generations"
GOOGLE_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:predict"
PROVIDERS = ("openai", "google")

# dollars a picture, as published when this was written (2026-09); a model
# not listed costs "?" in the log and nothing in the total
COST = {
    ("openai", "gpt-image-1", "low"): 0.011, ("openai", "gpt-image-1", "medium"): 0.042,
    ("openai", "gpt-image-1", "high"): 0.167,
    ("openai", "gpt-image-1-mini", "low"): 0.005, ("openai", "gpt-image-1-mini", "medium"): 0.011,
    ("openai", "gpt-image-1-mini", "high"): 0.036,
    ("google", "imagen-4.0-fast-generate-001", "*"): 0.02,
    ("google", "imagen-4.0-generate-001", "*"): 0.04,
    ("google", "imagen-4.0-ultra-generate-001", "*"): 0.06,
}

PANEL_BRIEF = ("A picture to be shown on a {size} by {size} pixel LED panel, so: one bold subject, "
               "centred and filling the frame, simple shapes, strong contrast, flat saturated colours, "
               "a plain uncluttered background, no text, no fine detail, no small features; like a large "
               "pixel-art icon or a poster seen from across the room.")

IMAGE_SYSTEM = ("You write prompts for an image model. The picture will be shown on a {size} by {size} pixel LED "
                "panel, where fine detail vanishes and text is unreadable. Rewrite the request as one paragraph "
                "of at most 60 words describing exactly one bold subject, centred and filling the frame, in simple "
                "shapes, strong contrast and flat saturated colours on a plain background, with no text anywhere. "
                "Keep every detail the request actually asked for (colours, objects, mood). Answer with the prompt "
                "only.")


def _slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return s[:40] or "picture"


class Imaginer:
    def __init__(self, ctrl, shower=None, asker=None, provider: str = "openai", api_key: str = "",
                 openai_model: str = "gpt-image-1", google_model: str = "imagen-4.0-generate-001",
                 quality: str = "low", path: str = DIR, post=None, clock=None):
        self.ctrl = ctrl
        self.shower = shower
        self.asker = asker
        self.provider = provider if provider in PROVIDERS else "openai"
        self.api_key = (api_key or "").strip()
        self.openai_model = openai_model
        self.google_model = google_model
        self.quality = quality if quality in ("low", "medium", "high") else "low"
        self.path = path
        self._post = post or self._http_post
        self._clock = clock or time.time
        self._lock = threading.Lock()
        self.index: list[dict] = []
        self.count = 0
        self.cost_usd = 0.0
        self.last: dict | None = None
        self.problem: str | None = None
        self._last_at = 0.0
        self.busy = False
        self._load()

    # ---- settings -----------------------------------------------------------------------
    @property
    def ready(self) -> bool:
        return bool(self.api_key)

    @property
    def model(self) -> str:
        return self.openai_model if self.provider == "openai" else self.google_model

    def configure(self, provider=None, api_key=None):
        if provider is not None and provider in PROVIDERS and provider != self.provider:
            self.provider, self.problem = provider, None
        if api_key is not None and api_key.strip() != self.api_key:
            self.api_key, self.problem = api_key.strip(), None

    def status(self) -> dict:
        return {"ready": self.ready, "provider": self.provider, "model": self.model,
                "quality": self.quality, "images": self.count, "cost_usd": round(self.cost_usd, 4),
                "last": self.last, "busy": self.busy, "problem": self.problem}

    # ---- disk -----------------------------------------------------------------------------
    def _index_path(self) -> str:
        return os.path.join(self.path, "index.json")

    def _load(self):
        try:
            with open(self._index_path()) as fh:
                d = json.load(fh)
            self.index = d.get("images", [])
            self.count = int(d.get("count", len(self.index)))
            self.cost_usd = float(d.get("cost_usd", 0.0))
            self.last = d.get("last")
        except (OSError, ValueError, TypeError):
            self.index = []

    def _save(self):
        try:
            os.makedirs(self.path, exist_ok=True)
            tmp = self._index_path() + ".tmp"
            with open(tmp, "w") as fh:
                json.dump({"images": self.index, "count": self.count, "cost_usd": self.cost_usd,
                           "last": self.last}, fh)
            os.replace(tmp, self._index_path())
        except OSError as exc:
            print(f"[imagine] could not save: {exc}", flush=True)

    def image_path(self, image_id: str) -> str | None:
        if not re.fullmatch(r"[a-z0-9\-]{1,80}", image_id or ""):
            return None
        p = os.path.join(self.path, image_id + ".png")
        return p if os.path.exists(p) else None

    # ---- the prompt ------------------------------------------------------------------------
    def expand(self, prompt: str, size: int) -> str:
        """The words as an image prompt for a panel of this size."""
        asker = self.asker
        if asker is not None and getattr(asker, "ready", False) and hasattr(asker, "image_prompt"):
            try:
                out = asker.image_prompt(prompt, size)
                if out:
                    return out
            except Exception as exc:
                print(f"[imagine] Claude could not write the prompt: {exc}", flush=True)
        return f"{prompt.strip().rstrip('.')}. " + PANEL_BRIEF.format(size=size)

    # ---- the providers -----------------------------------------------------------------------
    def _http_post(self, url: str, headers: dict, body: dict) -> dict:
        r = requests.post(url, headers=headers, json=body, timeout=180)
        if r.status_code >= 400:
            try:
                msg = r.json().get("error", {}).get("message") or r.text[:200]
            except ValueError:
                msg = r.text[:200]
            raise RuntimeError(f"{r.status_code}: {msg}")
        return r.json()

    def _openai(self, prompt: str) -> bytes:
        body = {"model": self.openai_model, "prompt": prompt, "n": 1, "size": "1024x1024",
                "quality": self.quality, "output_format": "png"}
        data = self._post(OPENAI_URL, {"Authorization": f"Bearer {self.api_key}"}, body)
        item = (data.get("data") or [{}])[0]
        if item.get("b64_json"):
            return base64.b64decode(item["b64_json"])
        if item.get("url"):
            r = requests.get(item["url"], timeout=60)
            r.raise_for_status()
            return r.content
        raise RuntimeError("no image in the answer")

    def _google(self, prompt: str) -> bytes:
        body = {"instances": [{"prompt": prompt}],
                "parameters": {"sampleCount": 1, "aspectRatio": "1:1", "personGeneration": "allow_adult"}}
        data = self._post(GOOGLE_URL.format(model=self.google_model), {"x-goog-api-key": self.api_key}, body)
        preds = data.get("predictions") or []
        if preds and preds[0].get("bytesBase64Encoded"):
            return base64.b64decode(preds[0]["bytesBase64Encoded"])
        raise RuntimeError("no image in the answer (the prompt may have been refused)")

    def _cost(self) -> float | None:
        return COST.get((self.provider, self.model, self.quality)) or COST.get((self.provider, self.model, "*"))

    # ---- the deed ------------------------------------------------------------------------------
    def imagine(self, prompt: str) -> dict:
        prompt = " ".join((prompt or "").split())
        if not prompt:
            return {"error": "Describe the picture."}
        if not self.ready:
            return {"error": "No image key on the wall yet. Set one under Services, Images."}
        with self._lock:
            now = self._clock()
            if self.busy:
                return {"error": "Still drawing the last one."}
            if now - self._last_at < MIN_GAP_S:
                return {"error": f"One picture every {int(MIN_GAP_S)} seconds. A moment."}
            self._last_at = now
            self.busy = True
        try:
            size = int(getattr(getattr(self.ctrl, "wall", None), "width", 64) or 64)
            expanded = self.expand(prompt, size)
            t0 = time.monotonic()
            try:
                raw = self._openai(expanded) if self.provider == "openai" else self._google(expanded)
            except Exception as exc:
                self.problem = f"{type(exc).__name__}: {str(exc)[:160]}"
                print(f"[imagine] {self.provider} {self.model}: {self.problem}", flush=True)
                return {"error": f"The image model said no: {str(exc)[:120]}"}
            try:
                img = Image.open(io.BytesIO(raw)).convert("RGB")
                img.load()
            except Exception as exc:
                self.problem = f"bad image: {exc}"
                return {"error": "The image came back unreadable."}
            usd = self._cost()
            image_id = f"{int(self._clock())}-{_slug(prompt)}"
            os.makedirs(self.path, exist_ok=True)
            img.save(os.path.join(self.path, image_id + ".png"), "PNG")
            entry = {"id": image_id, "prompt": prompt, "expanded": expanded, "provider": self.provider,
                     "model": self.model, "quality": self.quality, "ts": int(self._clock()),
                     "usd": usd, "took_s": round(time.monotonic() - t0, 1),
                     "size": list(img.size)}
            with self._lock:
                self.index.insert(0, entry)
                for old in self.index[KEEP:]:
                    try:
                        os.remove(os.path.join(self.path, old["id"] + ".png"))
                    except OSError:
                        pass
                self.index = self.index[:KEEP]
                self.count += 1
                if usd:
                    self.cost_usd += usd
                self.last = {"id": image_id, "prompt": prompt, "usd": usd, "ts": entry["ts"]}
                self.problem = None
                self._save()
            print(f"[imagine] {self.provider} {self.model} {self.quality}: {prompt!r} in {entry['took_s']} s, "
                  f"${usd if usd is not None else '?'}", flush=True)
            shown = self._show(img)
            return {"imagined": True, "shown": shown, "id": image_id, "prompt": prompt,
                    "expanded": expanded, "usd": usd, "seconds": SHOW_S,
                    "said": "Drawn." if shown else "Drawn, but the wall could not show it."}
        finally:
            self.busy = False

    def _show(self, img) -> bool:
        if self.shower is None:
            return False
        try:
            return bool(self.shower.show_image(img, SHOW_S))
        except Exception as exc:
            print(f"[imagine] could not show: {exc}", flush=True)
            return False

    def show_again(self, image_id: str) -> dict:
        p = self.image_path(image_id)
        if p is None:
            return {"error": "No such picture."}
        try:
            img = Image.open(p).convert("RGB")
            img.load()
        except Exception as exc:
            return {"error": f"That picture would not open: {exc}"}
        entry = next((e for e in self.index if e["id"] == image_id), {"id": image_id, "prompt": ""})
        shown = self._show(img)
        return {"shown": shown, **entry, "seconds": SHOW_S,
                "said": "Up." if shown else "The wall could not show it."}

    def forget(self, image_id: str) -> dict:
        p = self.image_path(image_id)
        with self._lock:
            self.index = [e for e in self.index if e["id"] != image_id]
            self._save()
        if p:
            try:
                os.remove(p)
            except OSError:
                pass
        return {"forgotten": image_id}

    def listing(self) -> list[dict]:
        with self._lock:
            return list(self.index)
