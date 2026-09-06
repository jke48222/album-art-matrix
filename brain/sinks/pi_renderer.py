"""Send frames to the art_display daemon over its named pipe.

The pipe is opened ONCE and held. An earlier version opened and closed per
frame, which was survivable at 20 fps and is not at 120: it costs two syscalls
and a reader re-open per frame, and it loses every frame the writer happens to
send while the reader is between opens (O_NONBLOCK returns ENXIO and there is
nothing to do but drop it). Holding the pipe also means the renderer sees one
continuous stream instead of a new EOF sixty times a second.

Non-blocking open so the brain never hangs when the renderer isn't up yet; the
handle is dropped and retried if the renderer goes away.
"""
import errno
import os

from . import FrameSink


MAGIC = b"TSRA"


class PiRendererSink(FrameSink):
    """Every frame goes out behind an eight-byte header: the magic, the
    panel's brightness cap (1-254), three bytes spare. The renderer scans for
    the magic, so a renderer that comes up mid-frame, or a pipe that kept
    half a frame across a restart, lines itself back up on the next one
    instead of showing every frame after it shifted. And the cap rides on
    every frame, so it changes without restarting anything."""

    def __init__(self, fifo: str = "/tmp/album-frame.fifo", wall=None):
        self.fifo = fifo
        # The wall's shape, when there is more than one panel: the frame is
        # cut into tiles and each one goes to the panel standing in that
        # spot. None, or a wall needing no bending, costs nothing.
        self.wall = wall if (wall is not None and not wall.plain) else None
        self._fd = None
        self._warned = False
        self.brightness = 160
        # The last frame actually written, and the cap it went out with.
        # Sending the same picture again is not free: the renderer maps it
        # into the very bit-plane buffer its scan is reading, and the scan
        # shows the seam. On a still sleeve the brain was writing about
        # once a second, so the wall tore about once a second.
        self._last = None
        self._last_cap = None

    def _connect(self) -> bool:
        if self._fd is not None:
            return True
        try:
            # O_NONBLOCK so a missing reader is an immediate ENXIO, not a hang.
            self._fd = os.open(self.fifo, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as exc:
            if exc.errno in (errno.ENXIO, errno.ENOENT):
                if not self._warned:
                    print(f"[sink] renderer not listening on {self.fifo} — "
                          "start pi/run_renderer.sh")
                    self._warned = True
                return False
            raise
        # Writes should block until the reader drains, rather than failing with
        # EAGAIN and tearing a frame in half.
        os.set_blocking(self._fd, True)
        self._warned = False
        # A renderer that has just come up has nothing on its panel, so the
        # next frame must go even if it is the one already sent.
        self._last = None
        return True

    def _drop(self):
        if self._fd is not None:
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = None

    def show(self, rgb888: bytes, pre_wb_img=None):
        if not self._connect():
            return
        cap = max(1, min(254, int(self.brightness)))
        if rgb888 == self._last and cap == self._last_cap:
            return                      # the panel is already showing this
        try:
            # A frame exceeds PIPE_BUF, so a signal landing mid-write can
            # return a short count; anything short would shift every later
            # frame boundary (the protocol has no resync marker) — write all.
            head = MAGIC + bytes((cap, 0, 0, 0))
            out = self.wall.remap(rgb888) if self.wall is not None else rgb888
            view = memoryview(head + bytes(out))
            sent = 0
            while sent < len(view):
                sent += os.write(self._fd, view[sent:])
            self._last, self._last_cap = bytes(rgb888), cap
        except (BrokenPipeError, OSError):
            # The renderer restarted. Reconnect on the next frame.
            self._last = None
            self._drop()
