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
