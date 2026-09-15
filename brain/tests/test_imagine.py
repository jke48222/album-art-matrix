"""Imagine: the prompt for a panel, both providers' requests, the picture
on the wall at both sizes, the gallery, the pace and the money.

    .venv/bin/python -m pytest brain/tests/test_imagine.py -q
"""
import base64
import io
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.imagine import Imaginer, PANEL_BRIEF, MIN_GAP_S, OPENAI_URL, KEEP   # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def png_bytes(color=(150, 40, 200), size=1024):
    img = Image.new("RGB", (size, size), (10, 10, 10))
    px = img.load()
    cx = cy = size // 2
    for y in range(size):
        for x in range(size):
            if (x - cx) ** 2 + (y - cy) ** 2 < (size * 0.4) ** 2:
                px[x, y] = color
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


class FakeShower:
    def __init__(self, size):
        self.size = size
        self.shown = []

    def show_image(self, img, seconds):
        from brain.art.pipeline import prepare
        pre = prepare(img, self.size)
        self.shown.append((np.asarray(pre), seconds))
        return True


class FakeAsker:
    ready = True

    def image_prompt(self, prompt, size):
        return f"A {prompt}, bold and centred, for {size} pixels."


class Wall:
    def __init__(self, w):
        self.width = w


class Ctrl:
    def __init__(self, w=64):
        self.wall = Wall(w)


def fake_post(calls, raw):
    def post(url, headers, body):
        calls.append((url, headers, body))
        if "openai" in url:
            return {"data": [{"b64_json": base64.b64encode(raw).decode()}]}
        return {"predictions": [{"bytesBase64Encoded": base64.b64encode(raw).decode()}]}
    return post


def test_expand_with_and_without_claude(tmp_path):
    im = Imaginer(Ctrl(), asker=FakeAsker(), api_key="k", path=str(tmp_path / "im"))
    assert im.expand("purple elephant", 64) == "A purple elephant, bold and centred, for 64 pixels."
    plain = Imaginer(Ctrl(), asker=None, api_key="k", path=str(tmp_path / "im2"))
    assert plain.expand("a purple elephant.", 192) == "a purple elephant. " + PANEL_BRIEF.format(size=192)


def test_openai_and_google_requests_and_the_picture_at_both_sizes(tmp_path):
    raw = png_bytes()
    for size, provider in ((64, "openai"), (192, "google")):
        calls, clock = [], [1_760_000_000.0]
        shower = FakeShower(size)
        im = Imaginer(Ctrl(size), shower=shower, asker=FakeAsker(), provider=provider, api_key="sk-test-key-12345",
                      openai_model="gpt-image-1", google_model="imagen-4.0-generate-001", quality="low",
                      path=str(tmp_path / f"im-{size}"), post=fake_post(calls, raw), clock=lambda: clock[0])
        res = im.imagine("a purple elephant")
        assert res.get("imagined") and res["shown"] and res["id"].endswith("-a-purple-elephant")
        url, headers, body = calls[0]
        if provider == "openai":
            assert url == OPENAI_URL and headers["Authorization"] == "Bearer sk-test-key-12345"
            assert body["model"] == "gpt-image-1" and body["size"] == "1024x1024" and body["quality"] == "low"
            assert body["n"] == 1 and body["output_format"] == "png" and "elephant" in body["prompt"]
            assert res["usd"] == 0.011
        else:
            assert url.endswith("/models/imagen-4.0-generate-001:predict") and headers["x-goog-api-key"] == "sk-test-key-12345"
            assert body["instances"][0]["prompt"].startswith("A a purple elephant") or "elephant" in body["instances"][0]["prompt"]
            assert body["parameters"]["sampleCount"] == 1 and body["parameters"]["aspectRatio"] == "1:1"
            assert res["usd"] == 0.04
        frame, seconds = shower.shown[0]
        assert frame.shape == (size, size, 3) and seconds == 600.0
        centre = frame[size // 2, size // 2]
        assert centre[2] > 150 and centre[1] < 80                       # the purple disc, downscaled
        assert frame[1, 1].max() < 30                                    # the dark corner
        assert os.path.exists(tmp_path / f"im-{size}" / (res["id"] + ".png"))
        st = im.status()
        assert st["images"] == 1 and st["cost_usd"] == res["usd"] and st["last"]["prompt"] == "a purple elephant"
        if OUT:
            Image.fromarray(frame).resize((size * (4 if size == 64 else 2),) * 2, Image.NEAREST).save(
                os.path.join(OUT, f"imagine-{size}.png"))


def test_the_best_model_first_then_the_next(tmp_path):
    """The newest model is asked for; a key that cannot reach it falls back,
    once, and the picture records the model that drew it."""
    raw = png_bytes()
    calls = []
    def post(url, headers, body):
        calls.append(body["model"])
        if body["model"] in ("gpt-image-2", "gpt-image-1.5"):
            raise RuntimeError(f"404: The model `{body['model']}` does not exist or you do not have access to it.")
        return {"data": [{"b64_json": base64.b64encode(raw).decode()}]}
    im = Imaginer(Ctrl(), shower=FakeShower(64), api_key="k" * 24, path=str(tmp_path / "im"), post=post)
    assert im.quality == "high" and im.model == "gpt-image-2"
    res = im.imagine("a lighthouse")
    assert res.get("imagined") and calls == ["gpt-image-2", "gpt-image-1.5", "gpt-image-1"]
    assert im.listing()[0]["model"] == "gpt-image-1" and im.status()["model_used"] == "gpt-image-1"
    assert res["usd"] == 0.167                                          # high, on the model that drew
    # a different refusal is not a missing model: it is passed on
    def refusing(url, headers, body):
        raise RuntimeError("400: Your request was rejected by the safety system")
    im2 = Imaginer(Ctrl(), api_key="k" * 24, path=str(tmp_path / "im2"), post=refusing, clock=lambda: 9e9)
    assert "said no" in im2.imagine("x")["error"]
    im.configure(quality="medium", model="gpt-image-1.5")
    assert im.quality == "medium" and im.openai_model == "gpt-image-1.5"
    im.configure(quality="ultra")                                       # not a quality: ignored
    assert im.quality == "medium"


def test_the_panel_version_keeps_the_light(tmp_path):
    """A fine bright line on a dark ground: in linear light it stays bright
    at the panel's size; in sRGB it greys."""
    from brain.imagine import enhance_for_panel
    from brain.art.pipeline import prepare
    img = Image.new("RGB", (1024, 1024), (8, 8, 12))
    px = img.load()
    for y in range(1024):
        for x in range(1024):
            if (x // 16) % 2 == 0 and (y // 16) % 2 == 0:
                px[x, y] = (250, 250, 250)                              # a fine bright grid
    plain = np.asarray(prepare(img, 64, unsharp_percent=0), dtype=np.float32)
    lit = np.asarray(enhance_for_panel(img, 64), dtype=np.float32)
    assert lit.shape == (64, 64, 3)
    assert lit.mean() > plain.mean() + 15                               # brighter, as the eye would see it
    big = enhance_for_panel(img, 192)
    assert big.size == (192, 192)


def test_pace_gallery_and_restart(tmp_path):
    raw = png_bytes((240, 200, 30))
    calls, clock = [], [1_760_000_000.0]
    shower = FakeShower(64)
    im = Imaginer(Ctrl(), shower=shower, api_key="k" * 24, path=str(tmp_path / "im"),
                  openai_model="gpt-image-1", quality="low",
                  post=fake_post(calls, raw), clock=lambda: clock[0])
    first = im.imagine("a yellow sun")
    assert first.get("imagined")
    assert "every" in im.imagine("another")["error"]                    # ten seconds
    clock[0] += MIN_GAP_S + 1
    second = im.imagine("a blue moon")
    assert second.get("imagined") and len(calls) == 2
    ids = [e["id"] for e in im.listing()]
    assert ids == [second["id"], first["id"]]                           # newest first
    again = Imaginer(Ctrl(), shower=shower, api_key="k" * 24, path=str(tmp_path / "im"),
                     openai_model="gpt-image-1", quality="low",
                     post=fake_post(calls, raw), clock=lambda: clock[0])
    assert [e["id"] for e in again.listing()] == ids and again.status()["images"] == 2
    res = again.show_again(first["id"])
    assert res["shown"] and res["prompt"] == "a yellow sun" and len(shower.shown) == 3
    assert again.show_again("nope")["error"]
    again.forget(first["id"])
    assert [e["id"] for e in again.listing()] == [second["id"]]
    assert again.image_path(first["id"]) is None and again.image_path("../etc/passwd") is None


def test_no_key_and_a_refusal(tmp_path):
    im = Imaginer(Ctrl(), api_key="", path=str(tmp_path / "im"))
    assert "key" in im.imagine("a cat")["error"]
    def refusing(url, headers, body):
        raise RuntimeError("400: Your request was rejected by the safety system")
    im2 = Imaginer(Ctrl(), api_key="k" * 24, path=str(tmp_path / "im2"), post=refusing)
    res = im2.imagine("something")
    assert "said no" in res["error"] and im2.status()["problem"].startswith("RuntimeError")
    assert im2.imagine("")["error"] == "Describe the picture."
