"""Describe one bold picture and keep it in the wall's private gallery.

Claude first turns the request into a square composition that survives 64
LEDs: one centred subject, strong silhouette, restrained colours, no tiny
text or decorative detail. OpenAI or Google's current image API draws it.
The original and prompt remain in the user's wall config directory until the
phone wipes them; generation and disk work happen on the request thread.
"""
import base64
import io
import json
import os
from pathlib import Path
import threading
import time
import uuid

from PIL import Image
import requests

from .art.pipeline import prepare

ROOT = Path("~/.config/album-art-matrix/imagined").expanduser()
RATE_SECONDS = 10
OPENAI_MODEL = "gpt-image-1"
GOOGLE_MODEL = "gemini-3.1-flash-image"
COST = {"openai": .042, "google": .067}
EXPAND = ("Rewrite this as one concise image-generation prompt for a square LED artwork. "
          "Use one centred subject, bold readable silhouette, high contrast, no words, no fine detail, "
          "a plain background and a restrained palette. Preserve the person's actual idea. "
          "Return only the prompt, at most 500 characters.")


def _image_data(value):
    """Google has changed its response envelope; accept image blocks only."""
    if isinstance(value, dict):
        if value.get("type") == "image" and isinstance(value.get("data"), str):
            return base64.b64decode(value["data"])
        for key in ("output_image", "outputs", "steps", "content", "parts", "result"):
            if key in value:
                found = _image_data(value[key])
                if found:
                    return found
    elif isinstance(value, list):
        for item in value:
            found = _image_data(item)
            if found:
                return found
    return None


class Imagine:
    def __init__(self, ctrl, root=ROOT, session=requests, clock=time.monotonic,
                 claude_factory=None):
        self.ctrl, self.root, self.http, self.clock = ctrl, Path(root), session, clock
        self.claude_factory = claude_factory
        self._lock = threading.Lock()
        self.last_at = -RATE_SECONDS
        self.problem = None
        self.busy = False
        self.root.mkdir(parents=True, exist_ok=True)

    def _meta(self):
        rows = []
        for path in sorted(self.root.glob("*.json"), reverse=True):
            try:
                row = json.loads(path.read_text())
                if (self.root / (row["id"] + ".jpg")).exists():
                    rows.append(row)
            except (OSError, ValueError, KeyError):
                continue
        return rows

    def public(self):
        provider = self.ctrl.services_store.get("images", "provider") or "openai"
        return {"enabled": self.ctrl.features.enabled("imagine"), "provider": provider,
                "key_set": bool(self.ctrl.services_store.get("images", "api_key")),
                "busy": self.busy, "problem": self.problem, "images": self._meta()}

    def _expand(self, prompt):
        key = self.ctrl.services_store.get("claude", "api_key")
        if not key:
            raise ValueError("Add the Claude key to expand image prompts.")
        if self.claude_factory:
            client = self.claude_factory(key)
        else:
            import anthropic
            client = anthropic.Anthropic(api_key=key, base_url="https://api.anthropic.com",
                                         timeout=8, max_retries=0)
        try:
            response = client.messages.create(model="claude-opus-5", max_tokens=300,
                system=EXPAND, messages=[{"role": "user", "content": prompt}])
            expanded = " ".join(block.text for block in response.content if block.type == "text").strip()
            return expanded[:500] or prompt
        finally:
            if hasattr(client, "close"):
                client.close()

    def _generate(self, provider, key, prompt):
        if provider == "openai":
            response = self.http.post("https://api.openai.com/v1/images/generations",
                headers={"Authorization": "Bearer " + key},
                json={"model": OPENAI_MODEL, "prompt": prompt, "size": "1024x1024",
                      "quality": "medium", "n": 1}, timeout=60)
            response.raise_for_status()
            return base64.b64decode(response.json()["data"][0]["b64_json"]), OPENAI_MODEL
        if provider == "google":
            response = self.http.post("https://generativelanguage.googleapis.com/v1beta/interactions",
                headers={"x-goog-api-key": key},
                json={"model": GOOGLE_MODEL, "input": [{"type": "text", "text": prompt}],
                      "response_format": {"type": "image", "mime_type": "image/jpeg",
                                          "aspect_ratio": "1:1", "image_size": "1K"}}, timeout=60)
            response.raise_for_status()
            data = _image_data(response.json())
            if not data:
                raise ValueError("Google returned no image block")
            return data, GOOGLE_MODEL
        raise ValueError("provider must be openai or google")

    def _show(self, path):
        image = Image.open(path)
        image.load()
        frame = prepare(image, self.ctrl.wall.width,
                        self.ctrl.tuning.get("unsharp_radius"),
                        self.ctrl.tuning.get("unsharp_percent"))
        self.ctrl.frame_override = frame.tobytes()
        self.ctrl.shown_seq += 1
        self.ctrl.apply({"mode": "frame"})

    def create(self, prompt):
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 1000:
            raise ValueError("prompt must contain 1 to 1000 characters")
        if not self.ctrl.features.enabled("imagine"):
            return {"problem": "Imagine is off for this build.", "shown": False}
        provider = self.ctrl.services_store.get("images", "provider") or "openai"
        key = self.ctrl.services_store.get("images", "api_key")
        if not key:
            return {"problem": "Add the image provider key in Services.", "shown": False}
        if not self._lock.acquire(blocking=False):
            return {"problem": "One image is already being made.", "shown": False}
        try:
            left = RATE_SECONDS - (self.clock() - self.last_at)
            if left > 0:
                return {"problem": f"Wait {left:.1f} seconds before another image.", "shown": False}
            self.last_at = self.clock()
            self.busy = True
            expanded = self._expand(prompt.strip())
            raw, model = self._generate(provider, key, expanded)
            image = Image.open(io.BytesIO(raw)).convert("RGB")
            ident = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
            image_path = self.root / (ident + ".jpg")
            image.save(image_path, "JPEG", quality=94)
            meta = {"id": ident, "prompt": prompt.strip(), "expanded_prompt": expanded,
                    "provider": provider, "model": model, "created": int(time.time()),
                    "cost_usd": COST[provider]}
            temp = self.root / (ident + ".tmp")
            temp.write_text(json.dumps(meta, ensure_ascii=False, indent=2))
            os.chmod(temp, 0o600)
            os.replace(temp, self.root / (ident + ".json"))
            self._show(image_path)
            self.problem = None
            print(f"[imagine] provider={provider} model={model} estimated_cost_usd={COST[provider]:.3f}", flush=True)
            return {**meta, "shown": True}
        except (OSError, ValueError, KeyError, requests.RequestException) as exc:
            self.problem = f"Image could not be made: {type(exc).__name__}"
            print("[imagine] " + self.problem, flush=True)
            return {"problem": self.problem, "shown": False}
        finally:
            self.busy = False
            self._lock.release()

    def show(self, ident):
        if not isinstance(ident, str) or not re_full_id(ident):
            raise ValueError("invalid image id")
        path = self.root / (ident + ".jpg")
        if not path.exists():
            raise ValueError("image not found")
        self._show(path)
        return {"shown": True, "id": ident}

    def art(self, ident):
        if not re_full_id(ident):
            return None
        path = self.root / (ident + ".jpg")
        try:
            return path.read_bytes()
        except OSError:
            return None


def re_full_id(value):
    import re
    return bool(re.fullmatch(r"\d{8}-\d{6}-[0-9a-f]{8}", value or ""))
