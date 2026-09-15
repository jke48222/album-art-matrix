"""Imagine: a picture from a description.

    "create a purple elephant"  ->  a purple elephant on the panel

The words go to Claude first, when a key is set, to be written out as a
prompt for a picture that will be seen on a 64 or 192 pixel LED panel:
one clear subject, large and centred, real light and depth, deep colour,
no text (without Claude a fixed template does the same job, less well).
The prompt goes to an image model at high quality, OpenAI's newest image
model that the key can reach (gpt-image-2, then 1.5, then 1) or Google's
Imagen Ultra through their REST APIs, whichever the phone chose (Services
> Images), and the picture comes back as bytes. It is brought to the
wall's size in linear light with a light autocontrast, so the fine bright
details keep their brightness, then through the sleeve pipeline, and
shown in the frame face for ten minutes, or until something else is
chosen; it is kept at full size with its prompt in
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
    ("openai", "gpt-image-1.5", "low"): 0.009, ("openai", "gpt-image-1.5", "medium"): 0.034,
    ("openai", "gpt-image-1.5", "high"): 0.133,
    ("openai", "gpt-image-1", "low"): 0.011, ("openai", "gpt-image-1", "medium"): 0.042,
    ("openai", "gpt-image-1", "high"): 0.167,
    ("openai", "gpt-image-1-mini", "low"): 0.005, ("openai", "gpt-image-1-mini", "medium"): 0.011,
    ("openai", "gpt-image-1-mini", "high"): 0.036,
    ("google", "imagen-4.0-fast-generate-001", "*"): 0.02,
    ("google", "imagen-4.0-generate-001", "*"): 0.04,
    ("google", "imagen-4.0-ultra-generate-001", "*"): 0.06,
}

PANEL_BRIEF = ("A richly detailed, finely rendered picture: one clear subject, large, centred and filling the frame, "
               "with real lighting, depth and texture, strong contrast between the subject and a simple background, "
               "deep colour, nothing written anywhere. Photographic or painterly, as the subject wants; never flat "
               "clip art.")

IMAGE_SYSTEM = ("You write prompts for an image model. The picture will be shown on a {size} by {size} pixel LED panel, "
                "so it needs one clear subject, large, centred and filling the frame, against a simple background "
                "that does not compete with it, with strong light and shadow and deep colour; fine text is unreadable "
                "there, so no words or letters anywhere. Within that, ask for the most beautiful, detailed and "
                "believable rendering of the request: real materials, real light, atmosphere, depth. Keep every detail "
                "the request asked for (colours, objects, mood, style). One paragraph, at most 70 words. Answer with "
                "the prompt only.")

# the OpenAI models to try, best first, when the one asked for is not
# there for this key (a 404, or "model not found")
OPENAI_FALLBACK = ["gpt-image-2", "gpt-image-1.5", "gpt-image-1"]
QUALITIES = ("low", "medium", "high")


def enhance_for_panel(img: Image.Image, size: int) -> Image.Image:
    """The picture at the wall's size, downscaled in linear light so the
    bright fine details keep their brightness instead of greying into
    their neighbours, then a gentle stretch so the panel gets the whole
    range. What a 64 pixel panel can show of a picture is decided here,
    so this is where fidelity is won or lost."""
    import numpy as np
    a = np.asarray(img.convert("RGB"), dtype=np.float32) / 255.0
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    # Pillow's Lanczos on a float image, channel by channel
    chans = []
    for k in range(3):
        ch = Image.fromarray((lin[..., k] * 65535.0).astype(np.uint16) if False else lin[..., k], mode="F")
        chans.append(np.asarray(ch.resize((size, size), Image.LANCZOS), dtype=np.float32))
    lin_small = np.clip(np.stack(chans, axis=-1), 0.0, 1.0)
    srgb = np.where(lin_small <= 0.0031308, lin_small * 12.92, 1.055 * np.power(lin_small, 1 / 2.4) - 0.055)
    out = np.clip(srgb, 0, 1) * 255.0
    # a gentle stretch: the darkest one percent to near black, the brightest
    # one percent towards white, never more than a third brighter, so a
    # moody picture stays moody and a dull one wakes up
    lum = out[..., 0] * 0.299 + out[..., 1] * 0.587 + out[..., 2] * 0.114
    p1, p99 = float(np.percentile(lum, 1)), float(np.percentile(lum, 99))
    offset = max(0.0, p1 - 6.0)
    gain = min(1.3, 235.0 / max(1.0, p99 - offset))
    out = np.clip((out - offset) * max(1.0, gain), 0, 255)
    return Image.fromarray((out + 0.5).astype(np.uint8))


def _slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return s[:40] or "picture"


class Imaginer:
    def __init__(self, ctrl, shower=None, asker=None, provider: str = "openai", api_key: str = "",
                 openai_model: str = "gpt-image-2", google_model: str = "imagen-4.0-ultra-generate-001",
                 quality: str = "high", path: str = DIR, post=None, clock=None):
        self.ctrl = ctrl
        self.shower = shower
        self.asker = asker
        self.provider = provider if provider in PROVIDERS else "openai"
        self.api_key = (api_key or "").strip()
        self.openai_model = openai_model
        self.google_model = google_model
        self.quality = quality if quality in QUALITIES else "high"
        self.model_used: str | None = None      # the OpenAI model that last answered
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

    def configure(self, provider=None, api_key=None, quality=None, model=None):
        if provider is not None and provider in PROVIDERS and provider != self.provider:
            self.provider, self.problem = provider, None
        if api_key is not None and api_key.strip() != self.api_key:
            self.api_key, self.problem = api_key.strip(), None
        if quality is not None and quality in QUALITIES:
            self.quality = quality
        if model is not None and model.strip():
            if self.provider == "openai":
                self.openai_model = model.strip()
            else:
                self.google_model = model.strip()

    def status(self) -> dict:
        return {"ready": self.ready, "provider": self.provider, "model": self.model,
                "model_used": self.model_used, "quality": self.quality, "images": self.count,
                "cost_usd": round(self.cost_usd, 4), "last": self.last, "busy": self.busy,
                "problem": self.problem}

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
        models = [self.openai_model] + [m for m in OPENAI_FALLBACK if m != self.openai_model]
        data = None
        for i, model in enumerate(models):
            body = {"model": model, "prompt": prompt, "n": 1, "size": "1024x1024",
                    "quality": self.quality, "output_format": "png"}
            try:
                data = self._post(OPENAI_URL, {"Authorization": f"Bearer {self.api_key}"}, body)
                self.model_used = model
                break
            except RuntimeError as exc:
                msg = str(exc).lower()
                missing = msg.startswith("404") or "model" in msg and ("not found" in msg or "does not exist" in msg
                                                                          or "not exist" in msg or "invalid" in msg
                                                                          or "no access" in msg or "not supported" in msg)
                if missing and i < len(models) - 1:
                    print(f"[imagine] {model} is not available for this key, trying {models[i + 1]}", flush=True)
                    continue
                raise
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
        model = self.model_used if (self.provider == "openai" and self.model_used) else self.model
        return COST.get((self.provider, model, self.quality)) or COST.get((self.provider, model, "*"))

    # ---- the deed ------------------------------------------------------------------------------
    def draw(self, prompt: str, expanded: str | None = None) -> Image.Image:
        """The picture for a prompt, in hand, not shown and not kept: the
        games' way in (AI pictionary). Raises with the reason when it
        cannot."""
        prompt = " ".join((prompt or "").split())
        if not prompt:
            raise ValueError("describe the picture")
        if not self.ready:
            raise RuntimeError("no image key on the wall yet")
        with self._lock:
            now = self._clock()
            if self.busy:
                raise RuntimeError("still drawing the last one")
            if now - self._last_at < MIN_GAP_S:
                raise RuntimeError(f"one picture every {int(MIN_GAP_S)} seconds")
            self._last_at = now
            self.busy = True
        try:
            size = int(getattr(getattr(self.ctrl, "wall", None), "width", 64) or 64)
            expanded = expanded or self.expand(prompt, size)
            try:
                raw = self._openai(expanded) if self.provider == "openai" else self._google(expanded)
            except Exception as exc:
                self.problem = f"{type(exc).__name__}: {str(exc)[:160]}"
                print(f"[imagine] {self.provider} {self.model}: {self.problem}", flush=True)
                raise RuntimeError(f"the image model said no: {str(exc)[:120]}") from exc
            try:
                img = Image.open(io.BytesIO(raw)).convert("RGB")
                img.load()
            except Exception as exc:
                self.problem = f"bad image: {exc}"
                raise RuntimeError("the image came back unreadable") from exc
            usd = self._cost()
            with self._lock:
                self.count += 1
                if usd:
                    self.cost_usd += usd
            return img
        finally:
            self.busy = False

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
                     "model": (self.model_used if self.provider == "openai" and self.model_used else self.model),
                     "quality": self.quality, "ts": int(self._clock()),
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
            print(f"[imagine] {self.provider} {entry['model']} {self.quality}: {prompt!r} in {entry['took_s']} s, "
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
            size = int(getattr(getattr(self.ctrl, "wall", None), "width", 64) or 64)
            return bool(self.shower.show_image(enhance_for_panel(img, size), SHOW_S))
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
