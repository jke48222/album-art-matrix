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

from brain.imagine import (Imaginer, LiveDrawing, PANEL_BRIEF, MIN_GAP_S, OPENAI_URL, KEEP,   # noqa: E402
                           PARTIALS, FADE_S)

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
        self.s = {"mode": "art"}
        self.shown_seq = 0
        self.dirty = type("E", (), {"set": lambda self_: None})()
    def get(self):
        return dict(self.s)
    def apply(self, p):
        self.s.update(p)
        return {}


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
        ctrl = im.ctrl
        assert ctrl.s["mode"] == "imagine" and im.live.stage == "done"
        frame = im.live.frame_at(size, im.live.updated_at + 5.0)
        assert frame.shape == (size, size, 3)
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
    assert im.quality == "medium" and im.model == "gpt-image-2"
    res = im.imagine("a lighthouse")
    assert res.get("imagined") and calls == ["gpt-image-2", "gpt-image-1.5", "gpt-image-1"]
    assert im.listing()[0]["model"] == "gpt-image-1" and im.status()["model_used"] == "gpt-image-1"
    assert res["usd"] == 0.042                                          # medium, on the model that drew
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
    assert res["shown"] and res["prompt"] == "a yellow sun" and again.live.stage == "done" and again.live.quick
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


def sse(events):
    """A fake stream: the events OpenAI sends, as dicts."""
    def stream(url, headers, body):
        assert body["stream"] is True and body["partial_images"] == PARTIALS
        for ev in events:
            yield ev
    return stream


def test_streaming_partials_reach_the_live_face_and_pictionary(tmp_path):
    p1, p2, p3 = png_bytes((60, 60, 200)), png_bytes((120, 60, 200)), png_bytes((150, 40, 200))
    final = png_bytes((160, 40, 220))
    events = [{"type": "image_generation.partial_image", "b64_json": base64.b64encode(p1).decode(), "partial_image_index": 0},
              {"type": "image_generation.partial_image", "b64_json": base64.b64encode(p2).decode(), "partial_image_index": 1},
              {"type": "image_generation.partial_image", "b64_json": base64.b64encode(p3).decode(), "partial_image_index": 2},
              {"type": "image_generation.completed", "b64_json": base64.b64encode(final).decode(), "usage": {}}]
    ctrl = Ctrl()
    clock = [1_760_000_000.0]
    im = Imaginer(ctrl, api_key="k" * 24, path=str(tmp_path / "im"), post=lambda *a: (_ for _ in ()).throw(AssertionError("no plain call")),
                  stream=sse(events), clock=lambda: clock[0])
    stages = []
    orig = im.live.partial
    def watch(img):
        stages.append(im.live.stage)
        orig(img)
    im.live.partial = watch
    res = im.imagine("a purple elephant")
    assert res.get("imagined") and ctrl.s["mode"] == "imagine"
    assert stages[0] == "waiting" and len(im.live.images) == PARTIALS + 1 and im.live.stage == "done"
    assert im.live.public()["partials"] == PARTIALS and im.model_used == "gpt-image-2"
    # the frames: black then a sweep while waiting, partials crossfading, the final held
    live = LiveDrawing(clock=lambda: 0.0)
    live.start("a thing")
    f = live.frame_at(64, 0.4)
    assert f.shape == (64, 64, 3) and f.max() > 20 and f.max() < 120          # the sweep, nothing else
    live.partial(Image.open(io.BytesIO(p1)).convert("RGB"))
    live.updated_at = 1.0
    mid = live.frame_at(64, 1.0 + FADE_S / 2)
    after = live.frame_at(64, 1.0 + FADE_S + 1.0)
    assert after[32, 32][2] > 150 and mid[32, 32][2] < after[32, 32][2]        # fading in
    assert after[63, :16].mean() > 150                                          # the foot line, one of four
    live.finish(Image.open(io.BytesIO(final)).convert("RGB"))
    live.updated_at = live.done_at = 5.0
    held = live.frame_at(64, 5.0 + FADE_S + 1.0)
    assert held[63, :].mean() < 120 and not live.expired(5.0 + 100)             # no foot line, held
    assert live.expired(5.0 + 601)
    # pictionary sees the sketch forming
    from brain.games.host import GameHost
    from brain.games import pictionary                                           # noqa: F401
    from brain.tests.test_pictures import Ctrl as GCtrl
    seen = []
    class Drawer:
        ready = True
        def draw(self, prompt, expanded=None, on_partial=None):
            for raw in (p1, p2):
                on_partial(Image.open(io.BytesIO(raw)).convert("RGB")); seen.append(1)
            return Image.open(io.BytesIO(final)).convert("RGB")
    host = GameHost(GCtrl(64), path=str(tmp_path / "g.json"))
    host.start("pictionary", {"word": "elephant", "imaginer": Drawer()})
    import time as _t
    for _ in range(100):
        if not host.game.drawing:
            break
        _t.sleep(0.02)
    assert len(seen) == 2 and host.game.t0 is not None and host.game.picture is not None


def test_a_model_that_will_not_stream_is_drawn_in_one_go(tmp_path):
    raw = png_bytes()
    calls = []
    def stream(url, headers, body):
        calls.append("stream")
        raise RuntimeError("400: Unknown parameter: 'partial_images'.")
        yield  # noqa
    def post(url, headers, body):
        calls.append("post")
        return {"data": [{"b64_json": base64.b64encode(raw).decode()}]}
    im = Imaginer(Ctrl(), api_key="k" * 24, path=str(tmp_path / "im"), post=post, stream=stream)
    assert im.imagine("a cat").get("imagined") and calls == ["stream", "post"]
    im.release()
    assert im.ctrl.s["mode"] == "art" and im.live.stage == "idle"
