"""Imagine: a picture from words, drawn on the wall as it is drawn.

    "create a purple elephant"  ->  a purple elephant on the panel

The words go to Claude first, when a key is set, to be written out as a
prompt for a picture that will be seen on a 64 or 192 pixel LED panel:
one clear subject, large and centred, real light and depth, deep colour,
no text (without Claude a fixed template does the same job, less well).
The prompt goes to an image model, the newest OpenAI image model the key
can reach (gpt-image-2, then 1.5, then 1) or Google's Imagen Ultra,
whichever the phone chose (Services > Images), at the quality the phone
chose (medium to start: a good picture in well under a minute; high is
the most detailed and takes minutes).

OpenAI streams the picture as it forms: three partial images, then the
final one. The wall goes into its "imagine" face the moment the words
arrive: a pencil wanders the dark canvas while the model thinks, and each
partial that lands is drawn the way a picture is drawn, its lines
sketched first in a warm ink and then the colour painted in along the
same sweep, so the picture is seen being drawn. Every image is brought to the
wall's size in linear light with a gentle stretch, so fine bright detail
keeps its brightness. The finished picture stays for ten minutes, or
until something else is chosen, and is kept at full size with its prompt
in ~/.config/album-art-matrix/imagined/, listed by GET /imagine and shown
again by POST /imagine/show {id}. One picture every ten seconds at most.
"""
from __future__ import annotations

import base64
import io
import json
import os
import re
import threading
import time

import numpy as np
import requests
from PIL import Image

from .art.pixelfont import draw_text, text_width

DIR = os.path.expanduser("~/.config/album-art-matrix/imagined")
MIN_GAP_S = 10.0
SHOW_S = 600.0
KEEP = 200                       # pictures kept; the oldest go
PARTIALS = 3                     # partial images asked of OpenAI while it draws
FADE_S = 2.4                     # a new partial is sketched then painted over this

OPENAI_URL = "https://api.openai.com/v1/images/generations"
GOOGLE_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:predict"
PROVIDERS = ("openai", "google")
QUALITIES = ("low", "medium", "high")
# the OpenAI models to try, best first, when the one asked for is not
# there for this key (a 404, or "model not found")
OPENAI_FALLBACK = ["gpt-image-2", "gpt-image-1.5", "gpt-image-1"]

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


def _slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return s[:40] or "picture"


def enhance_for_panel(img: Image.Image, size: int) -> Image.Image:
    """The picture at the wall's size, downscaled in linear light so the
    bright fine details keep their brightness instead of greying into
    their neighbours, then a gentle stretch so the panel gets the whole
    range. What a 64 pixel panel can show of a picture is decided here,
    so this is where fidelity is won or lost."""
    a = np.asarray(img.convert("RGB"), dtype=np.float32) / 255.0
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    chans = []
    for k in range(3):
        ch = Image.fromarray(lin[..., k], mode="F")
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


def _ease(t: float) -> float:
    t = 0.0 if t < 0 else 1.0 if t > 1 else t
    return t * t * (3 - 2 * t)


class LiveDrawing:
    """What the wall shows while a picture is being drawn, and after.

    While the model thinks, a pencil wanders the dark canvas leaving a
    fading trail, and a breath of light rises and falls in the middle.
    Each partial image that lands is drawn the way a picture is drawn:
    first its lines, sketched in a warm ink along a ragged sweep from the
    top left, over the last picture gone dim; then the colour is painted
    in along the same sweep and the lines dissolve into it. A thin line at
    the foot counts the passes. The finished picture is held for a while.
    One of these lives on the Imaginer; the render loop asks it for frames
    in mode "imagine"."""

    REVEAL_S = 2.4                  # sketch then paint, for each partial
    SKETCH_SHARE = 0.5              # the sketch's share of the reveal

    def __init__(self, clock=None):
        self._clock = clock or time.monotonic
        self.stage = "idle"             # idle | waiting | partial | done | failed
        self.prompt = ""
        self.images: list[Image.Image] = []       # the partials, then the final
        self.final: Image.Image | None = None
        self.problem: str | None = None
        self.t0 = 0.0
        self.updated_at = 0.0
        self.done_at: float | None = None
        self.hold_s = SHOW_S
        self.quick = False
        self._frames: dict[tuple[int, int], np.ndarray] = {}
        self._edges: dict[tuple[int, int], np.ndarray] = {}
        self._orders: dict[int, np.ndarray] = {}
        self._trail: dict[int, np.ndarray] = {}
        self._trail_at: dict[int, float] = {}
        self._lock = threading.Lock()

    # ---- what happens ----------------------------------------------------------------------
    def start(self, prompt: str, quick: bool = False):
        with self._lock:
            now = self._clock()
            self.stage, self.prompt, self.quick = "waiting", prompt, quick
            self.images, self.final, self.problem = [], None, None
            self.t0 = self.updated_at = now
            self.done_at = None
            self._frames, self._edges, self._trail = {}, {}, {}

    def partial(self, img: Image.Image):
        with self._lock:
            self.images.append(img)
            self.stage = "partial"
            self.updated_at = self._clock()

    def finish(self, img: Image.Image):
        with self._lock:
            self.images.append(img)
            self.final = img
            self.stage = "done"
            self.updated_at = self.done_at = self._clock()

    def fail(self, why: str):
        with self._lock:
            self.problem = why
            self.stage = "failed"
            self.updated_at = self.done_at = self._clock()

    def clear(self):
        with self._lock:
            self.stage = "idle"
            self._frames, self._edges, self._trail = {}, {}, {}

    def busy(self) -> bool:
        return self.stage in ("waiting", "partial")

    def expired(self, now: float | None = None) -> bool:
        now = self._clock() if now is None else now
        if self.stage == "done":
            return now - (self.done_at or now) > self.hold_s
        if self.stage == "failed":
            return now - (self.done_at or now) > 4.0
        return False

    def elapsed(self) -> float:
        return self._clock() - self.t0 if self.stage != "idle" else 0.0

    def public(self) -> dict:
        return {"stage": self.stage, "prompt": self.prompt, "partials": max(0, len(self.images) - (1 if self.final else 0)),
                "of": PARTIALS, "elapsed": round(self.elapsed(), 1), "problem": self.problem,
                "done_ago": round(self._clock() - self.done_at, 1) if self.done_at else None}

    # ---- the pieces of a frame -----------------------------------------------------------------
    def _frame(self, k: int, size: int) -> np.ndarray:
        key = (k, size)
        f = self._frames.get(key)
        if f is None:
            f = np.asarray(enhance_for_panel(self.images[k], size), dtype=np.uint8)
            self._frames[key] = f
        return f

    def _edge(self, k: int, size: int) -> np.ndarray:
        """The picture's lines, 0..1: where its luminance changes fastest,
        the strongest twelfth of the panel kept, so it reads as a sketch
        and not a smear."""
        key = (k, size)
        e = self._edges.get(key)
        if e is None:
            f = self._frame(k, size).astype(np.float32)
            lum = f[..., 0] * 0.299 + f[..., 1] * 0.587 + f[..., 2] * 0.114
            gx = np.zeros_like(lum)
            gy = np.zeros_like(lum)
            gx[:, 1:-1] = lum[:, 2:] - lum[:, :-2]
            gy[1:-1, :] = lum[2:, :] - lum[:-2, :]
            mag = np.sqrt(gx * gx + gy * gy)
            cut = float(np.percentile(mag, 88))
            top = float(np.percentile(mag, 99.5)) or 1.0
            e = np.clip((mag - cut) / max(1.0, top - cut), 0.0, 1.0) ** 0.7
            self._edges[key] = e
        return e

    def _order(self, size: int) -> np.ndarray:
        """When each pixel gets drawn, 0..1: a sweep from the top left made
        ragged with a little noise, so the sketch grows like a hand's."""
        o = self._orders.get(size)
        if o is None:
            ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
            sweep = (xs + ys * 0.85) / (size * 1.85)
            rng = np.random.default_rng(7)
            coarse = rng.random((max(3, size // 12), max(3, size // 12))).astype(np.float32)
            noise = np.asarray(Image.fromarray(coarse, mode="F").resize((size, size), Image.BICUBIC), dtype=np.float32)
            o = np.clip(sweep * 0.86 + noise * 0.14, 0.0, 1.0)
            self._orders[size] = o
        return o

    @staticmethod
    def _smooth(x: np.ndarray) -> np.ndarray:
        x = np.clip(x, 0.0, 1.0)
        return x * x * (3 - 2 * x)

    def _reveal(self, prev: np.ndarray, cur: np.ndarray, edges: np.ndarray, order: np.ndarray, f: float) -> np.ndarray:
        """The frame `f` (0..1) of the way through drawing `cur` over `prev`:
        the sketch first, then the paint."""
        share = self.SKETCH_SHARE
        # the last picture goes dim as the pencil works over it, not all at once
        dim = 1.0 - 0.45 * min(1.0, f / share)
        base = prev.astype(np.float32) * dim
        ink = np.array([255.0, 238.0, 205.0], np.float32)
        if f < share:
            p = f / share
            drawn = self._smooth((p * 1.15 - order) / 0.12)                   # the pencil's front
            lines = (edges * drawn)[..., None]
            out = base * (1 - lines * 0.9) + ink * lines
        else:
            q = (f - share) / (1 - share)
            painted = self._smooth((q * 1.2 - order) / 0.24)[..., None]         # the brush's front, soft
            out = base * (1 - painted) + cur.astype(np.float32) * painted
            lines = (edges * (1 - q) ** 1.5)[..., None]
            out = out * (1 - lines * 0.6) + ink * lines * (1 - painted * 0.85)
        return np.clip(out, 0, 255).astype(np.uint8)

    # ---- the frame -------------------------------------------------------------------------------
    def frame_at(self, size: int, now: float | None = None) -> np.ndarray:
        now = self._clock() if now is None else now
        with self._lock:
            stage, n = self.stage, len(self.images)
            since = now - self.updated_at
            t = now - self.t0
            if stage in ("idle", "waiting") or n == 0:
                f = np.zeros((size, size, 3), dtype=np.uint8)
                f[...] = (5, 5, 9)
                if stage == "failed":
                    self._words(f, size, "could not draw", (200, 90, 80))
                elif stage == "waiting":
                    # the mark going round while the model thinks: the
                    # sting's icon on its own (art/sting.py), the pencil
                    # only if the sting cannot be drawn
                    icon = None
                    try:
                        from .art.sting import Sting
                        icon = Sting.get(size).icon_frame(t)
                    except Exception:
                        icon = None
                    if icon is not None:
                        f = icon.copy()
                    else:
                        breath = 0.5 - 0.5 * np.cos(t * 1.6)
                        self._glow(f, size, 6 + 8 * breath)
                        self._pencil(f, size, now, t)
                    if size > 96:
                        self._words(f, size, self.prompt, (120, 118, 112))
                return f
            reveal = self.REVEAL_S * (0.5 if self.quick else 1.0)
            cur = self._frame(n - 1, size)
            if since < reveal:
                prev = (self._frame(n - 2, size) if n >= 2 else np.full((size, size, 3), 5, dtype=np.uint8))
                out = self._reveal(prev, cur, self._edge(n - 1, size), self._order(size), since / reveal)
            else:
                out = cur.copy()
            if stage == "partial":
                self._sweep(out, size, t, 0.05)
                w = int(size * n / (PARTIALS + 1))
                out[size - 1, :w] = (230, 226, 216)
            elif stage == "failed":
                self._words(out, size, "could not draw", (200, 90, 80))
            return out

    def _pencil(self, f: np.ndarray, size: int, now: float, t: float):
        """A pencil wandering the canvas while the model thinks: a point of
        light on a smooth, aimless path, and the trail it leaves fading."""
        trail = self._trail.get(size)
        if trail is None:
            trail = np.zeros((size, size), dtype=np.float32)
            self._trail[size] = trail
            self._trail_at[size] = now
        dt = min(0.2, max(0.0, now - self._trail_at.get(size, now)))
        self._trail_at[size] = now
        trail *= float(np.exp(-dt / 1.4))
        s = 1 if size <= 96 else 3
        # the path: a few sines against each other, never the same twice
        steps = max(1, int(dt / 0.01))
        for k in range(steps):
            tt = t - dt + dt * (k + 1) / steps
            x = size / 2 + size * (0.33 * np.sin(0.9 * tt) + 0.11 * np.sin(2.7 * tt + 1.0))
            y = size / 2 + size * (0.28 * np.sin(0.7 * tt + 2.0) + 0.12 * np.cos(2.1 * tt))
            xi, yi = int(x), int(y)
            if 0 <= xi < size and 0 <= yi < size:
                trail[max(0, yi - s + 1):yi + s, max(0, xi - s + 1):xi + s] = np.maximum(
                    trail[max(0, yi - s + 1):yi + s, max(0, xi - s + 1):xi + s], 1.0)
        ink = np.array([255.0, 238.0, 205.0], np.float32)
        f[...] = np.clip(f.astype(np.float32) + trail[..., None] * ink * 0.75, 0, 255).astype(np.uint8)

    @staticmethod
    def _glow(f: np.ndarray, size: int, level: float):
        """A soft light in the middle of the canvas, `level` at its heart."""
        ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
        d = np.sqrt((xs + 0.5 - size / 2) ** 2 + (ys + 0.5 - size / 2) ** 2) / (size * 0.55)
        a = np.clip(1 - d, 0, 1) ** 2 * level
        f[...] = np.clip(f.astype(np.float32) + a[..., None] * np.array([1.0, 0.94, 0.82], np.float32), 0, 255).astype(np.uint8)

    @staticmethod
    def _sweep(f: np.ndarray, size: int, t: float, strength: float):
        """A soft band of warm light crossing the picture, once every 1.6 s."""
        phase = (t / 1.6) % 1.0
        x = (phase * 1.4 - 0.2) * size
        xs = np.arange(size, dtype=np.float32)
        band = np.exp(-((xs - x) / (size * 0.09)) ** 2) * strength
        f[...] = np.clip(f.astype(np.float32) + band[None, :, None] * np.array([255, 235, 200], np.float32), 0, 255).astype(np.uint8)

    @staticmethod
    def _words(f: np.ndarray, size: int, words: str, colour):
        line, lines = "", []
        for w in (words or "").split():
            cand = (line + " " + w).strip()
            if text_width(cand, 1) <= size - 8 or not line:
                line = cand
            else:
                lines.append(line)
                line = w
        if line:
            lines.append(line)
        y = size - 6 - 9 * min(3, len(lines))
        for ln in lines[:3]:
            draw_text(f, ln, (size - text_width(ln, 1)) // 2, y, colour, 1)
            y += 9


class Imaginer:
    def __init__(self, ctrl, shower=None, asker=None, provider: str = "openai", api_key: str = "",
                 openai_model: str = "gpt-image-2", google_model: str = "imagen-4.0-ultra-generate-001",
                 quality: str = "medium", path: str = DIR, post=None, stream=None, clock=None):
        self.ctrl = ctrl
        self.shower = shower
        self.asker = asker
        self.provider = provider if provider in PROVIDERS else "openai"
        self.api_key = (api_key or "").strip()
        self.openai_model = openai_model
        self.google_model = google_model
        self.quality = quality if quality in QUALITIES else "medium"
        self.path = path
        self._post = post or self._http_post
        # streaming is the real thing's; a test that hands in `post` gets the
        # plain call unless it hands in `stream` too
        self._stream = stream if stream is not None else (self._http_stream if post is None else None)
        self._clock = clock or time.time
        self._lock = threading.Lock()
        self.index: list[dict] = []
        self.count = 0
        self.cost_usd = 0.0
        self.last: dict | None = None
        self.problem: str | None = None
        self.model_used: str | None = None
        self._last_at = 0.0
        self.busy = False
        self.live = LiveDrawing()
        self._ret: str | None = None
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
                "problem": self.problem, "live": self.live.public()}

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
        r = requests.post(url, headers=headers, json=body, timeout=300)
        if r.status_code >= 400:
            try:
                msg = r.json().get("error", {}).get("message") or r.text[:200]
            except ValueError:
                msg = r.text[:200]
            raise RuntimeError(f"{r.status_code}: {msg}")
        return r.json()

    def _http_stream(self, url: str, headers: dict, body: dict):
        """OpenAI's server-sent events for a streamed image: each `data:`
        line is one event, yielded as a dict."""
        r = requests.post(url, headers=headers, json=body, timeout=(20, 300), stream=True)
        if r.status_code >= 400:
            try:
                msg = r.json().get("error", {}).get("message") or r.text[:200]
            except ValueError:
                msg = r.text[:200]
            raise RuntimeError(f"{r.status_code}: {msg}")
        for line in r.iter_lines(decode_unicode=True):
            if not line or not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                yield json.loads(payload)
            except ValueError:
                continue

    @staticmethod
    def _missing_model(exc: Exception) -> bool:
        msg = str(exc).lower()
        return msg.startswith("404") or ("model" in msg and any(w in msg for w in (
            "not found", "does not exist", "not exist", "invalid", "no access", "not supported")))

    def _openai(self, prompt: str, on_partial=None) -> bytes:
        models = [self.openai_model] + [m for m in OPENAI_FALLBACK if m != self.openai_model]
        for i, model in enumerate(models):
            body = {"model": model, "prompt": prompt, "n": 1, "size": "1024x1024",
                    "quality": self.quality, "output_format": "png"}
            try:
                if self._stream is not None:
                    try:
                        raw = self._openai_streamed(dict(body, stream=True, partial_images=PARTIALS), on_partial)
                        self.model_used = model
                        return raw
                    except RuntimeError as exc:
                        low = str(exc).lower()
                        if "stream" in low or "partial_images" in low:
                            print(f"[imagine] {model} would not stream; drawing it in one go", flush=True)
                        else:
                            raise
                data = self._post(OPENAI_URL, {"Authorization": f"Bearer {self.api_key}"}, body)
                self.model_used = model
                item = (data.get("data") or [{}])[0]
                if item.get("b64_json"):
                    return base64.b64decode(item["b64_json"])
                if item.get("url"):
                    r = requests.get(item["url"], timeout=60)
                    r.raise_for_status()
                    return r.content
                raise RuntimeError("no image in the answer")
            except RuntimeError as exc:
                if self._missing_model(exc) and i < len(models) - 1:
                    print(f"[imagine] {model} is not available for this key, trying {models[i + 1]}", flush=True)
                    continue
                raise
        raise RuntimeError("no model answered")

    def _openai_streamed(self, body: dict, on_partial=None) -> bytes:
        final = None
        for ev in self._stream(OPENAI_URL, {"Authorization": f"Bearer {self.api_key}"}, body):
            kind = ev.get("type", "")
            if kind == "image_generation.partial_image" and ev.get("b64_json"):
                if on_partial is not None:
                    try:
                        on_partial(base64.b64decode(ev["b64_json"]), int(ev.get("partial_image_index", 0)))
                    except Exception as exc:
                        print(f"[imagine] partial: {exc}", flush=True)
            elif kind == "image_generation.completed" and ev.get("b64_json"):
                final = base64.b64decode(ev["b64_json"])
            elif kind == "error" or "error" in ev:
                err = ev.get("error") if isinstance(ev.get("error"), dict) else {"message": str(ev.get("error") or ev)}
                raise RuntimeError(f"stream: {err.get('message', 'error')}")
        if final is None:
            raise RuntimeError("the stream ended without a picture")
        return final

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

    @staticmethod
    def _decode(raw: bytes) -> Image.Image:
        img = Image.open(io.BytesIO(raw)).convert("RGB")
        img.load()
        return img

    # ---- the deed ------------------------------------------------------------------------------
    def _take(self, prompt: str) -> str | None:
        """The pace and the one-at-a-time rule; the reason when refused."""
        prompt = " ".join((prompt or "").split())
        if not prompt:
            return "describe the picture"
        if not self.ready:
            return "no image key on the wall yet"
        with self._lock:
            now = self._clock()
            if self.busy:
                return "still drawing the last one"
            if now - self._last_at < MIN_GAP_S:
                return f"one picture every {int(MIN_GAP_S)} seconds"
            self._last_at = now
            self.busy = True
        return None

    def draw(self, prompt: str, expanded: str | None = None, on_partial=None) -> Image.Image:
        """The picture for a prompt, in hand, not shown and not kept: the
        games' way in (AI pictionary). `on_partial(img)` gets each partial
        as the model streams it. Raises with the reason when it cannot."""
        why = self._take(prompt)
        if why:
            raise RuntimeError(why)
        try:
            size = int(getattr(getattr(self.ctrl, "wall", None), "width", 64) or 64)
            expanded = expanded or self.expand(prompt, size)
            def partial(raw, idx):
                if on_partial is not None:
                    on_partial(self._decode(raw))
            try:
                raw = self._openai(expanded, partial) if self.provider == "openai" else self._google(expanded)
            except Exception as exc:
                self.problem = f"{type(exc).__name__}: {str(exc)[:160]}"
                print(f"[imagine] {self.provider} {self.model}: {self.problem}", flush=True)
                raise RuntimeError(f"the image model said no: {str(exc)[:120]}") from exc
            try:
                img = self._decode(raw)
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
        why = self._take(prompt)
        if why:
            words = {"describe the picture": "Describe the picture.",
                     "no image key on the wall yet": "No image key on the wall yet. Set one under Services, Images.",
                     "still drawing the last one": "Still drawing the last one."}
            return {"error": words.get(why, why[0].upper() + why[1:] + ".")}
        try:
            size = int(getattr(getattr(self.ctrl, "wall", None), "width", 64) or 64)
            self._go_live(prompt)
            expanded = self.expand(prompt, size)
            t0 = time.monotonic()
            def partial(raw, idx):
                self.live.partial(self._decode(raw))
                self._nudge()
            try:
                raw = self._openai(expanded, partial) if self.provider == "openai" else self._google(expanded)
            except Exception as exc:
                self.problem = f"{type(exc).__name__}: {str(exc)[:160]}"
                print(f"[imagine] {self.provider} {self.model}: {self.problem}", flush=True)
                self.live.fail(self.problem)
                self._nudge()
                return {"error": f"The image model said no: {str(exc)[:120]}"}
            try:
                img = self._decode(raw)
            except Exception as exc:
                self.problem = f"bad image: {exc}"
                self.live.fail(self.problem)
                self._nudge()
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
            self.live.finish(img)
            self._nudge()
            return {"imagined": True, "shown": True, "id": image_id, "prompt": prompt,
                    "expanded": expanded, "usd": usd, "seconds": SHOW_S, "took_s": entry["took_s"],
                    "said": "Drawn."}
        finally:
            self.busy = False

    # ---- the wall ----------------------------------------------------------------------------------
    def _go_live(self, prompt: str, quick: bool = False):
        """The wall into its imagine face, remembering what it was doing."""
        self.live.start(prompt, quick=quick)
        ctrl = self.ctrl
        try:
            here = ctrl.get()["mode"]
            if here != "imagine":
                self._ret = here if here not in ("frame", "clip", "timer", "video", "game") else "art"
            ctrl.apply({"mode": "imagine"})
            ctrl.shown_seq += 1
        except Exception as exc:
            print(f"[imagine] could not take the wall: {exc}", flush=True)
        self._nudge()

    def _nudge(self):
        d = getattr(self.ctrl, "dirty", None)
        if d is not None:
            try:
                d.set()
            except Exception:
                pass

    def release(self):
        """The finished picture has had its time: hand the wall back."""
        try:
            if self.ctrl.get()["mode"] == "imagine":
                self.ctrl.apply({"mode": self._ret or "art"})
        except Exception:
            pass
        self._ret = None
        self.live.clear()

    def show_again(self, image_id: str) -> dict:
        p = self.image_path(image_id)
        if p is None:
            return {"error": "No such picture."}
        try:
            img = self._decode(open(p, "rb").read())
        except Exception as exc:
            return {"error": f"That picture would not open: {exc}"}
        entry = next((e for e in self.index if e["id"] == image_id), {"id": image_id, "prompt": ""})
        self._go_live(entry.get("prompt", ""), quick=True)
        self.live.finish(img)
        self._nudge()
        return {"shown": True, **entry, "seconds": SHOW_S, "said": "Up."}

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
