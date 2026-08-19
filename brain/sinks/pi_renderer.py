"""Send frames to the art_display daemon over its named pipe.

One frame per open/write/close; the daemon re-opens on EOF. Non-blocking open
so the brain never hangs when the renderer isn't up yet.
"""
import errno
import os

from . import FrameSink


class PiRendererSink(FrameSink):
    def __init__(self, fifo: str = "/tmp/album-frame.fifo"):
        self.fifo = fifo
        self._warned = False

    def show(self, rgb888: bytes, pre_wb_img=None):
        try:
            fd = os.open(self.fifo, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as exc:
            if exc.errno in (errno.ENXIO, errno.ENOENT):
                if not self._warned:
                    print(f"[sink] renderer not listening on {self.fifo} — "
                          "start pi/run_renderer.sh")
                    self._warned = True
                return
            raise
        self._warned = False
        with os.fdopen(fd, "wb") as fh:
            fh.write(rgb888)
