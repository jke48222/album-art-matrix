"""The pipe to the renderer: a frame that cannot go out now goes out later.

Two things went wrong on the wall and both are here. After a reboot the brain
sent its first frames before the renderer was listening, and nothing sent
them again until the next song, so the wall sat black for four minutes with
the brain believing it was showing a sleeve. And killing the renderer (the
tuning page does it on purpose) made the brain's next write fail, dropping
that frame until the next change.
"""
import os
import threading
import time

import pytest

from brain.sinks.pi_renderer import MAGIC, PiRendererSink

SIDE = 8
FRAME = SIDE * SIDE * 3
HEAD = 8


def frame(r, g, b):
    return bytes((r, g, b)) * (SIDE * SIDE)


def read_exact(fd, n, timeout=3.0):
    """Read n bytes off the pipe, or fail. Blocking reads on a pipe whose
    writer is alive but quiet would hang a test, so it is done non-blocking
    with a deadline."""
    os.set_blocking(fd, False)
    got = bytearray()
    end = time.monotonic() + timeout
    while len(got) < n:
        try:
            chunk = os.read(fd, n - len(got))
        except BlockingIOError:
            chunk = b""
        if chunk:
            got += chunk
        elif time.monotonic() > end:
            raise AssertionError(f"pipe gave {len(got)} of {n} bytes")
        else:
            time.sleep(0.01)
    return bytes(got)


def nothing_more(fd, wait=0.6):
    os.set_blocking(fd, False)
    time.sleep(wait)
    with pytest.raises(BlockingIOError):
        os.read(fd, 1)


def open_reader(path, timeout=3.0):
    """A renderer arriving: open the read end, which blocks until the sink
    connects. The keeper connects within a retry, so this returns."""
    box = {}

    def go():
        box["fd"] = os.open(path, os.O_RDONLY)

    t = threading.Thread(target=go, daemon=True)
    t.start()
    t.join(timeout)
    assert "fd" in box, "no writer ever connected to the pipe"
    return box["fd"]


@pytest.fixture
def fifo(tmp_path):
    path = str(tmp_path / "frame.fifo")
    os.mkfifo(path)
    return path


def test_frame_sent_before_the_renderer_listens_arrives_when_it_does(fifo):
    sink = PiRendererSink(fifo)
    sink.brightness = 200
    sink.show(frame(10, 20, 30))          # nobody listening: ENXIO, kept
    fd = open_reader(fifo)                # the renderer comes up
    try:
        data = read_exact(fd, HEAD + FRAME)
        assert data[:4] == MAGIC
        assert data[4] == 200
        assert data[HEAD:] == frame(10, 20, 30)
        nothing_more(fd)                  # once, not once per retry
    finally:
        os.close(fd)


def test_a_still_picture_reaches_a_restarted_renderer(fifo):
    sink = PiRendererSink(fifo)
    fd = open_reader(fifo)
    sink.show(frame(1, 2, 3))
    assert read_exact(fd, HEAD + FRAME)[HEAD:] == frame(1, 2, 3)
    os.close(fd)                          # the renderer dies under a still sleeve
    time.sleep(0.6)                       # systemd waits a second before it
    fd = open_reader(fifo)                # brings it back
    try:
        # no new show(): the keeper noticed the reader go and resends
        assert read_exact(fd, HEAD + FRAME)[HEAD:] == frame(1, 2, 3)
        nothing_more(fd)
    finally:
        os.close(fd)


def test_a_frame_that_hits_a_dead_pipe_is_not_lost(fifo):
    sink = PiRendererSink(fifo)
    fd = open_reader(fifo)
    sink.show(frame(1, 1, 1))
    read_exact(fd, HEAD + FRAME)
    os.close(fd)                          # renderer gone
    sink.show(frame(9, 9, 9))             # EPIPE: the old code dropped this
    fd = open_reader(fifo)
    try:
        assert read_exact(fd, HEAD + FRAME)[HEAD:] == frame(9, 9, 9)
        nothing_more(fd)
    finally:
        os.close(fd)


def test_the_same_picture_is_not_sent_twice(fifo):
    sink = PiRendererSink(fifo)
    fd = open_reader(fifo)
    try:
        sink.show(frame(5, 5, 5))
        sink.show(frame(5, 5, 5))
        read_exact(fd, HEAD + FRAME)
        nothing_more(fd)
        sink.brightness = 120             # but a new cap is a new frame
        sink.show(frame(5, 5, 5))
        assert read_exact(fd, HEAD + FRAME)[4] == 120
    finally:
        os.close(fd)


# ---- status(), for /health and /tuning ---------------------------------------

def wait_until(predicate, timeout=3.0):
    end = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > end:
            raise AssertionError("condition never held")
        time.sleep(0.02)


def test_status_says_how_long_a_picture_has_waited_for_a_renderer(fifo):
    sink = PiRendererSink(fifo)
    before = sink.status()
    assert before["attached"] is False and before["connects"] == 0
    assert before["detached_s"] is not None and before["pending_s"] is None
    sink.show(frame(10, 20, 30))                   # nobody listening: kept
    first = sink.status()["pending_s"]
    assert first is not None
    time.sleep(0.25)
    sink.show(frame(40, 50, 60))                   # replacing it keeps the stamp
    later = sink.status()
    assert later["pending_s"] > first
    assert later["detached_s"] >= 0.2
    fd = open_reader(fifo)
    try:
        read_exact(fd, HEAD + FRAME)
        wait_until(lambda: sink.status()["attached"])
        now = sink.status()
        assert now == {"attached": True, "connects": 1, "detached_s": None, "pending_s": None}
    finally:
        os.close(fd)


def test_status_counts_each_renderer_connection(fifo):
    """A restart is over when the count goes up: that is how /tuning tells a
    renderer that came back from one that did not."""
    sink = PiRendererSink(fifo)
    assert sink.status()["connects"] == 0
    fd = open_reader(fifo)
    wait_until(lambda: sink.status()["attached"])
    assert sink.status()["connects"] == 1
    os.close(fd)                                   # the renderer is killed
    wait_until(lambda: not sink.status()["attached"])
    gone = sink.status()
    assert gone["connects"] == 1 and gone["detached_s"] >= 0
    fd = open_reader(fifo)                         # systemd brings it back
    try:
        wait_until(lambda: sink.status()["attached"])
        assert sink.status()["connects"] == 2
    finally:
        os.close(fd)


def test_status_never_waits_for_the_pipe_lock(fifo):
    """_lock is held through a blocking write to a renderer that has stopped
    reading. /health and /tuning must still answer."""
    sink = PiRendererSink(fifo)
    held, release = threading.Event(), threading.Event()

    def hold():
        with sink._lock:
            held.set()
            release.wait(2)

    t = threading.Thread(target=hold, daemon=True)
    t.start()
    held.wait(1)
    try:
        start = time.monotonic()
        sink.status()
        assert time.monotonic() - start < 0.05
    finally:
        release.set()
        t.join(2)
