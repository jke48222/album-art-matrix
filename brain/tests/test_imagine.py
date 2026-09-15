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


def test_pace_gallery_and_restart(tmp_path):
    raw = png_bytes((240, 200, 30))
    calls, clock = [], [1_760_000_000.0]
    shower = FakeShower(64)
    im = Imaginer(Ctrl(), shower=shower, api_key="k" * 24, path=str(tmp_path / "im"),
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
