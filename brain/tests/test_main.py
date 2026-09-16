"""The pieces of main.py that can be held still.

main() itself is the render loop: it opens a sink, starts threads and does
not come back, so it is not something a test can call. What can be tested is
everything around it, and that is where the decisions live: which sink a
config asks for, which sources go in the chain and in what order, whether a
song already on the wall counts as the same song, and the tee every frame
passes through on its way out.

    .venv/bin/python -m pytest brain/tests/test_main.py -q
"""
import os
import sys
import time

import numpy as np
import pytest
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain import main as brain_main                             # noqa: E402
from brain.control import ControlState                           # noqa: E402
from brain.main import (DEFAULT_ORDER, _FrameTee, _is_shown,     # noqa: E402
                        load_config, make_sink)


# ---- the config ------------------------------------------------------------

def test_load_config_reads_toml(tmp_path):
    p = tmp_path / "config.toml"
    p.write_text('[sink]\ntype = "preview"\n\n[nowplaying]\npoll_seconds = 3.5\n')
    cfg = load_config(str(p))
    assert cfg["sink"]["type"] == "preview"
    assert cfg["nowplaying"]["poll_seconds"] == 3.5


def test_the_shipped_example_config_parses():
    """config.example.toml is what a new wall is seeded from, so a typo in it
    is a wall that will not start."""
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    cfg = load_config(os.path.join(here, "config.example.toml"))
    assert cfg["sink"]["type"] in ("preview", "pi")
    assert "features" in cfg


# ---- the sink --------------------------------------------------------------

def test_preview_sink_from_config(tmp_path):
    sink = make_sink({"sink": {"type": "preview", "preview_dir": str(tmp_path)}})
    assert sink.__class__.__name__ == "MacPreviewSink"


def test_override_beats_the_config(tmp_path):
    """--sink on the command line, for running the Mac's preview against a
    config that says pi."""
    sink = make_sink({"sink": {"type": "pi", "preview_dir": str(tmp_path)}},
                     override="preview")
    assert sink.__class__.__name__ == "MacPreviewSink"


def test_an_unknown_sink_is_refused_by_name():
    with pytest.raises(ValueError, match="hologram"):
        make_sink({"sink": {"type": "hologram"}})


# ---- is this the song already up? ------------------------------------------

class Now:
    def __init__(self, track_id, title, artist):
        self.track_id, self.title, self.artist = track_id, title, artist


def test_the_same_id_is_the_same_song():
    assert _is_shown(Now("spotify:1", "Nights", "Frank Ocean"), "spotify:1", {})


def test_the_same_name_under_a_different_id_is_the_same_song():
    """Two sources report one song with ids of their own. Without this the
    wall redraws the sleeve every time the chain changes its mind about who
    answered."""
    now = Now("lastfm:abc", "Nights", "Frank Ocean")
    showing = {"title": "Nights", "artist": "Frank Ocean"}
    assert _is_shown(now, "spotify:1", showing)


def test_case_and_spacing_do_not_make_it_a_new_song():
    now = Now("lastfm:abc", "  NIGHTS ", "frank ocean")
    assert _is_shown(now, "spotify:1", {"title": "Nights", "artist": "Frank Ocean"})


def test_a_different_song_is_a_different_song():
    now = Now("lastfm:abc", "Pyramids", "Frank Ocean")
    assert not _is_shown(now, "spotify:1", {"title": "Nights", "artist": "Frank Ocean"})


def test_nothing_showing_means_not_shown():
    assert not _is_shown(Now("lastfm:abc", "Nights", "Frank Ocean"), "spotify:1", {})


def test_a_missing_artist_does_not_match_a_present_one():
    now = Now("lastfm:abc", "Nights", None)
    assert not _is_shown(now, "spotify:1", {"title": "Nights", "artist": "Frank Ocean"})


# ---- the chain -------------------------------------------------------------

def test_the_default_order_is_the_documented_one():
    """The phone first and the ear last: a reading someone made on purpose
    outranks one the room guessed at."""
    assert DEFAULT_ORDER[0] == "phone"
    assert DEFAULT_ORDER[-1] == "ears"


def test_build_sources_hands_every_adapter_to_the_control_state():
    """Every adapter exists whether or not it has its details yet, so the
    phone can set them up later without a restart."""
    ctrl = ControlState(frame_len=64 * 64 * 3)
    brain_main.build_sources({"nowplaying": {"order": ["phone"]}}, ctrl)
    assert ctrl.pushed is not None
    for name in ("spotify", "lastfm", "listenbrainz"):
        assert hasattr(ctrl, name)


# ---- the tee every frame goes through --------------------------------------

class Sink:
    def __init__(self):
        self.shown, self.brightness, self.dither = [], None, None

    def show(self, rgb888, pre_wb_img=None):
        self.shown.append((rgb888, pre_wb_img))


@pytest.fixture
def tee():
    ctrl = ControlState(frame_len=64 * 64 * 3)
    ctrl.transition = None
    sink = Sink()
    return sink, ctrl, _FrameTee(sink, ctrl, 64)


def test_a_frame_reaches_the_sink_and_the_control_state(tee):
    sink, ctrl, t = tee
    raw = bytes(range(256)) * 48                      # 64*64*3 bytes
    t.show(raw)
    assert sink.shown[0][0] == raw
    assert ctrl.last_frame == raw                     # what /frame.raw serves


def test_the_pre_balance_picture_is_the_one_the_phone_previews(tee):
    """The phone shows the frame before white balance, because the gains are
    the wall's own correction and would be applied twice on screen."""
    sink, ctrl, t = tee
    img = Image.new("RGB", (64, 64), (10, 20, 30))
    t.show(bytes(64 * 64 * 3), pre_wb_img=img)
    assert ctrl.last_frame == img.tobytes()
    assert ctrl.last_frame != bytes(64 * 64 * 3)


def test_panel_brightness_follows_the_control_state(tee, tmp_path, monkeypatch):
    """The panel's own cap, 1-254, read off the control state on every frame.

    HOME is moved because apply() writes the level down beside the renderer
    for its next launch; on the Pi that file is real."""
    monkeypatch.setenv("HOME", str(tmp_path))
    sink, ctrl, t = tee
    ctrl.apply({"panel_brightness": 200})
    t.show(bytes(64 * 64 * 3))
    assert sink.brightness == 200


def test_panel_brightness_is_clamped_to_what_the_panel_takes(tee, tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    sink, ctrl, t = tee
    ctrl.apply({"panel_brightness": 9999})
    assert ctrl.get()["panel_brightness"] == 254
    ctrl.apply({"panel_brightness": 0})
    assert ctrl.get()["panel_brightness"] == 1


def test_the_voice_opening_masks_the_frame_then_lets_go(tee):
    """After a spoken command the face opens from a line in the middle. Part
    way through, the top and bottom rows are dark; once it is done the
    transition clears itself and full frames go out again."""
    sink, ctrl, t = tee
    white = bytes([255]) * (64 * 64 * 3)

    ctrl.transition = ("open", time.monotonic(), (255, 200, 60))
    t.show(white)
    out = np.frombuffer(sink.shown[-1][0], dtype=np.uint8).reshape(64, 64, 3)
    assert out[0].max() == 0                          # the top is held back
    assert out[32].max() > 0                          # the middle band is lit
    assert ctrl.transition is not None

    ctrl.transition = ("open", time.monotonic() - 999, (255, 200, 60))
    t.show(white)
    assert ctrl.transition is None                    # done, and cleared
    assert sink.shown[-1][0] == white                 # unmasked again


def test_the_opening_masks_the_preview_picture_the_same_way(tee):
    sink, ctrl, t = tee
    arr = np.full((64, 64, 3), 255, dtype=np.uint8)
    ctrl.transition = ("open", time.monotonic(), (255, 200, 60))
    t.show(bytes([255]) * (64 * 64 * 3), pre_wb_img=arr)
    masked = np.frombuffer(ctrl.last_frame, dtype=np.uint8).reshape(64, 64, 3)
    assert masked[0].max() == 0
    assert masked[32].max() > 0


def test_a_pil_picture_comes_back_as_a_pil_picture(tee):
    """The sleeve faces hand over a PIL image and the animated ones a numpy
    array; the mask must not change which one the sink receives."""
    sink, ctrl, t = tee
    ctrl.transition = ("open", time.monotonic(), (255, 200, 60))
    t.show(bytes([255]) * (64 * 64 * 3), pre_wb_img=Image.new("RGB", (64, 64), (255, 255, 255)))
    assert isinstance(sink.shown[-1][1], Image.Image)
