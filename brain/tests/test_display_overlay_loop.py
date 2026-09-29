"""A display check over the running render loop, and what comes back after it.

These run main()'s own loop, the way test_display_batch.py and
test_ticker_batch.py do. Only the sink, the music source, the network and the
video decoder are fixtures. A face that caches its last paint (Nine, a paused
video) or has nothing to paint (Art before any sleeve) would otherwise leave
the check's frame on the wall after the check is over.

    .venv/bin/python -m pytest brain/tests/test_display_overlay_loop.py -q
"""
import threading
import time
from types import SimpleNamespace

import pytest
from PIL import Image

from brain.tests.test_display_session_batch import TOKEN, frame, request

SIDE = 64
BLACK = bytes(SIDE * SIDE * 3)
CHECK = frame(color=(255, 0, 255))
GUEST_CODE = frame(color=(250, 250, 250))


class PausedVideo:
    """The decoder, held on one picture: frame_at hands back the same image,
    which is what a paused video does and why its face never repaints alone."""

    def __init__(self, size, dirty, **kwargs):
        self.picture = Image.new("RGB", (size, size), (30, 90, 160))
        self.busy, self.status, self.error, self.url = False, "idle", None, ""
        self.audio_path, self.audio_ready = None, False
        self.unsharp_radius = self.unsharp_percent = None

    def start(self, url, **kwargs):
        self.url, self.busy, self.status = url, True, "paused"

    def stop(self, error=None):
        self.busy, self.status, self.error = False, "idle", error

    def frame_at(self):
        return self.picture, 0.5

    def public(self):
        return {"status": self.status}


@pytest.fixture
def wall(monkeypatch):
    from brain import main as runtime
    from brain.features import KNOWN

    controls, errors, shown = [], [], []
    stop = threading.Event()
    source = SimpleNamespace(name="fixture", answer=None, phone_age=None)
    source.get_current = lambda: source.answer

    class EndLoop(BaseException):
        pass

    class Sink:
        def show(self, rgb888, pre_wb_img=None):
            if stop.is_set():
                raise EndLoop()
            ctrl = controls[0]
            picture = pre_wb_img.tobytes() if pre_wb_img is not None else bytes(rgb888)
            # The tee has already named this frame by now, so the record says
            # what the wall lit next to what everyone else was told it lit.
            shown.append((picture, ctrl.last_frame, ctrl.display_session.item is not None))

    def sources(config, control):
        controls.append(control)
        return [source]

    config = {"panel": {"width": SIDE, "height": SIDE}, "sink": {"type": "preview"},
              "nowplaying": {"poll_seconds": .02},
              "features": {name: False for name, _ in KNOWN}}
    monkeypatch.setattr(runtime, "load_config", lambda path: config)
    monkeypatch.setattr(runtime, "build_sources", sources)
    monkeypatch.setattr(runtime, "make_sink", lambda *args: Sink())
    monkeypatch.setattr(runtime, "serve_control", lambda *args: None)
    monkeypatch.setattr(runtime, "VideoPlayer", PausedVideo)
    monkeypatch.setattr(runtime, "fetch_art", lambda url: Image.new("RGB", (SIDE, SIDE), url))
    monkeypatch.setattr("brain.art.lyrics.fetch_sheet", lambda *args, **kwargs: None)
    monkeypatch.setattr("sys.argv", ["brain", "--config", "fixture"])

    def run():
        try:
            runtime.main()
        except EndLoop:
            pass
        except BaseException as error:
            errors.append(error)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()

    def wait(predicate):
        deadline = time.monotonic() + 4
        while not predicate() and not errors and time.monotonic() < deadline:
            time.sleep(.01)
        assert not errors, errors
        assert predicate()

    pre_render, post_render = [], []
    try:
        wait(lambda: bool(controls))
        session = controls[0].display_session
        render = session.render

        def render_on_the_loop(gains):
            # Requests queued here land on the loop's own thread just as it
            # looks for a check, so the wake-up each one raises is taken by
            # the check's own wait and never reaches the face underneath.
            while pre_render:
                pre_render.pop(0)()
            overlay = render(gains)
            while overlay is not None and post_render:
                post_render.pop(0)()
            return overlay

        session.render = render_on_the_loop
        yield SimpleNamespace(ctrl=controls[0], source=source, shown=shown, wait=wait,
                              pre_render=pre_render, post_render=post_render)
    finally:
        stop.set()
        if controls:
            controls[0].apply({"mode": "clock"})
            controls[0].dirty.set()
            controls[0].news.set()
        thread.join(5)
        assert not thread.is_alive()


def begin(wall, purpose="panel", pixels=CHECK):
    wall.ctrl.display_session.begin(request(purpose=purpose, pixels=pixels, seconds=600))


def end(wall):
    assert wall.ctrl.display_session.end({"token": TOKEN}) == {"active": False}


def send(action, queue, on_loop):
    """A phone request, answered on its own thread, or queued for the loop to
    take at the moment it looks for a check."""
    if on_loop:
        queue.append(action)
    else:
        action()


def nine(wall):
    wall.ctrl.apply({"mode": "nine"})
    # Black stands in while the grid is built, so wait for the grid itself.
    return lambda: wall.ctrl.display_mode == "nine" and wall.ctrl.last_frame not in (None, BLACK)


def paused_video(wall):
    assert wall.ctrl.video_start("fixture.mp4", sound=False, loop=False) is None
    return lambda: wall.ctrl.display_mode == "video" and wall.ctrl.last_frame is not None


def sleeve(wall):
    from brain.nowplaying import NowPlaying
    wall.source.answer = NowPlaying("one", "one", "Fixture", "Album", "blue", 40000, 180000, True)
    wall.ctrl.repoll.set()
    return lambda: wall.ctrl.now_showing.get("title") == "one" and wall.ctrl.last_frame is not None


def off(wall):
    wall.ctrl.apply({"mode": "off"})
    return lambda: wall.ctrl.display_mode == "off" and wall.ctrl.last_frame == BLACK


def drawing(wall):
    wall.ctrl.frame_override = frame(color=(12, 140, 60))
    wall.ctrl.shown_seq += 1
    wall.ctrl.apply({"mode": "frame"})
    return lambda: wall.ctrl.display_mode == "frame" and wall.ctrl.last_frame is not None


@pytest.mark.parametrize("on_loop", [False, True], ids=["phone thread", "loop thread"])
@pytest.mark.parametrize("face", [nine, paused_video, sleeve, off, drawing],
                         ids=["nine", "paused video", "sleeve", "off", "drawing"])
def test_the_face_under_a_check_is_painted_again_when_it_ends(wall, face, on_loop):
    ctrl = wall.ctrl
    wall.wait(face(wall))
    before = ctrl.last_frame
    send(lambda: begin(wall), wall.pre_render, on_loop)
    wall.wait(lambda: ctrl.last_frame == CHECK)
    send(lambda: end(wall), wall.post_render, on_loop)
    wall.wait(lambda: ctrl.last_frame == before)


def test_art_with_no_sleeve_yet_clears_the_check_instead_of_keeping_it(wall):
    ctrl = wall.ctrl
    assert ctrl.get()["mode"] == "art" and ctrl.last_frame is None
    begin(wall)
    wall.wait(lambda: ctrl.last_frame == CHECK)
    end(wall)
    wall.wait(lambda: ctrl.last_frame == BLACK)
    assert ctrl.finish_base.tobytes() == BLACK
    # Cleared once: the empty face does not keep pushing black at the panel.
    settled = len(wall.shown)
    time.sleep(.3)
    assert len(wall.shown) == settled


def test_the_wall_lights_the_guest_code_but_reports_the_face_under_it(wall):
    ctrl = wall.ctrl
    wall.wait(nine(wall))
    before = ctrl.last_frame
    begin(wall, purpose="guests", pixels=GUEST_CODE)
    wall.wait(lambda: any(picture == GUEST_CODE for picture, _, _ in wall.shown))
    assert ctrl.last_frame == before
    assert all(reported == before for picture, reported, active in wall.shown
               if picture == GUEST_CODE and active)
    settled = len(wall.shown)
    end(wall)
    wall.wait(lambda: any(picture == before for picture, _, _ in wall.shown[settled:]))
    assert ctrl.last_frame == before


def test_a_guest_check_ending_mid_frame_never_reports_the_code(wall):
    ctrl = wall.ctrl
    wall.wait(nine(wall))
    before = ctrl.last_frame
    # Stands in for the phone's end landing on its own thread after the loop
    # took the code's frame and before it showed it. Nothing orders the two.
    wall.pre_render.append(lambda: begin(wall, purpose="guests", pixels=GUEST_CODE))
    wall.post_render.append(lambda: end(wall))
    wall.wait(lambda: any(picture == GUEST_CODE for picture, _, _ in wall.shown))
    wall.wait(lambda: ctrl.last_frame == before)
    assert all(reported != GUEST_CODE for _, reported, _ in wall.shown)


def test_ceiling_change_during_a_check_reaches_the_nearest_colour_cap(wall):
    """A tuning pattern stays up while the ceiling is dragged. Only the loop's
    face branch used to set the cap, and it does not run under a check, so
    the pattern's dark colours were picked for the old ceiling."""
    from brain.art import pipeline
    ctrl = wall.ctrl
    begin(wall, purpose="tuning")
    wall.wait(lambda: ctrl.last_frame == CHECK)
    ctrl.apply({"panel_brightness": 120}, interrupt=False)
    wall.wait(lambda: pipeline.PANEL_CAP == 120)
    assert ctrl.display_session.status()["purpose"] == "tuning"


def test_a_preview_sink_has_no_renderer_to_report(wall):
    """No status() on the sink: tuning reports the renderer absent and never
    shows a restart, and /health has no renderer reading."""
    assert wall.ctrl.tuning.renderer is None
    assert wall.ctrl.tuning.renderer_state()["state"] == "absent"
    assert wall.ctrl.renderer_status() is None
    assert wall.ctrl.health()["renderer"] is None
    assert wall.ctrl.fps_target == 120
