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


class PiRendererSink(FrameSink):
    def __init__(self, fifo: str = "/tmp/album-frame.fifo"):
        self.fifo = fifo
        self._fd = None
        self._warned = False

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
        try:
            os.write(self._fd, rgb888)
        except (BrokenPipeError, OSError):
            # The renderer restarted. Reconnect on the next frame.
            self._drop()
