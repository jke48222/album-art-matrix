"""Send frames to the art_display daemon over its named pipe.

The pipe is opened ONCE and held. An earlier version opened and closed per
frame, which was survivable at 20 fps and is not at 120: it costs two syscalls
and a reader re-open per frame, and it loses every frame the writer happens to
send while the reader is between opens (O_NONBLOCK returns ENXIO and there is
nothing to do but drop it). Holding the pipe also means the renderer sees one
continuous stream instead of a new EOF sixty times a second.

Non-blocking open so the brain never hangs when the renderer isn't up yet.

A frame that could not be delivered is not dropped, it is KEPT. The brain only
calls show() when the picture changes, so a still sleeve is sent exactly once;
if that one send finds no renderer (the brain came up first after a reboot) or
a renderer that has just been restarted (the pipe's reader is gone, the write
fails), nothing would send it again until the next song. That is how a wall
sat black for four minutes after a boot while the brain believed it was
showing a sleeve. So a keeper thread holds the undelivered frame and retries
it every quarter second until it lands, and while the picture is still it
watches the pipe for a reader that has gone away, so a renderer that comes
back gets the picture the brain is on rather than waiting for the next one.
"""
import errno
import os
import select
import threading
import time

from . import FrameSink


MAGIC = b"TSRA"
RETRY_S = 0.25          # how often the keeper tries again


class PiRendererSink(FrameSink):
    """Every frame goes out behind an eight-byte header: the magic, the
    panel's brightness cap (1-254), the spatial dither in tenths, two bytes
    spare. The renderer scans for the magic, so a renderer that comes up
    mid-frame, or a pipe that kept half a frame across a restart, lines
    itself back up on the next one instead of showing every frame after it
    shifted. And the cap rides on every frame, so it changes without
    restarting anything."""

    def __init__(self, fifo: str = "/tmp/album-frame.fifo", wall=None):
        self.fifo = fifo
        # The wall's shape, when there is more than one panel: the frame is
        # cut into tiles and each one goes to the panel standing in that
        # spot. None, or a wall needing no bending, costs nothing.
        self.wall = wall if (wall is not None and not wall.plain) else None
        self._fd = None
        self._warned = False
        self.brightness = 160
        self.dither = 0.0
        # The last frame actually written, and the cap it went out with.
        # Sending the same picture again is not free: the renderer maps it
        # into the very bit-plane buffer its scan is reading, and the scan
        # shows the seam. On a still sleeve the brain was writing about
        # once a second, so the wall tore about once a second.
        self._last = None
        self._last_cap = None
        self._last_dither = None
        # The frame the panel should be showing but is not yet: (rgb, cap,
        # dither). Set by show() when a write cannot happen, cleared by the
        # write that lands it. The keeper thread owns retrying it.
        self._pending = None
        self._lock = threading.Lock()
        self._keeper = threading.Thread(target=self._keep, name="sink-keeper",
                                        daemon=True)
        self._keeper.start()

    # ---- the pipe ---------------------------------------------------------
    def _connect(self) -> bool:
        """True with the pipe open for writing. A fresh connection means a
        renderer that has just come up with nothing of ours on its panel, so
        the picture the brain is on is queued for it, whether or not it is
        the one already sent."""
        if self._fd is not None:
            return True
        try:
            # O_NONBLOCK so a missing reader is an immediate ENXIO, not a hang.
            self._fd = os.open(self.fifo, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as exc:
            if exc.errno in (errno.ENXIO, errno.ENOENT):
                if not self._warned:
                    print(f"[sink] renderer not listening on {self.fifo} — "
                          "start pi/run_renderer.sh; the frame waits for it")
                    self._warned = True
                return False
            raise
        # Writes should block until the reader drains, rather than failing with
        # EAGAIN and tearing a frame in half.
        os.set_blocking(self._fd, True)
        if self._warned:
            print("[sink] renderer is back")
            self._warned = False
        if self._pending is None and self._last is not None:
            self._pending = (self._last, self._last_cap, self._last_dither)
        self._last = None
        return True

    def _drop(self):
        if self._fd is not None:
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = None

    def _reader_gone(self) -> bool:
        """Whether the renderer has closed its end, found out without putting
        a byte on the pipe. Linux reports POLLERR on the write end of a pipe
        with no readers. macOS reports nothing there but refuses a zero-byte
        write with EPIPE, which Linux accepts silently, so both are asked."""
        if self._fd is None:
            return False
        p = select.poll()
        p.register(self._fd, select.POLLERR)
        try:
            if any(ev & (select.POLLERR | select.POLLHUP | select.POLLNVAL)
                   for _, ev in p.poll(0)):
                return True
            os.write(self._fd, b"")
            return False
        except OSError:
            return True

    # ---- delivery ---------------------------------------------------------
    def _deliver(self) -> bool:
        """Try to put the pending frame on the pipe. Lock held by the caller.
        False leaves it pending for the keeper."""
        if self._pending is None:
            return True
        if not self._connect():
            return False
        rgb888, cap, dit = self._pending
        try:
            # A frame exceeds PIPE_BUF, so a signal landing mid-write can
            # return a short count; anything short would shift every later
            # frame boundary — write all. The magic lets the renderer resync
            # if a write does die halfway.
            head = MAGIC + bytes((cap, dit, 0, 0))
            out = self.wall.remap(rgb888) if self.wall is not None else rgb888
            view = memoryview(head + bytes(out))
            sent = 0
            while sent < len(view):
                sent += os.write(self._fd, view[sent:])
        except (BrokenPipeError, OSError):
            # The renderer went away. The frame stays pending; the keeper
            # reconnects to the one that comes back and sends it then.
            self._drop()
            return False
        self._last, self._last_cap, self._last_dither = rgb888, cap, dit
        self._pending = None
        return True

    def _keep(self):
        """Stay attached to the renderer, retry what did not land, and notice
        a renderer that left under a still picture. Runs for the life of the
        brain. Attaching before there is anything to send is deliberate: the
        first frame after a boot then finds the pipe already open instead of
        racing the renderer's start."""
        while True:
            time.sleep(RETRY_S)
            with self._lock:
                try:
                    if self._fd is not None and self._reader_gone():
                        self._drop()
                        if self._last is not None:
                            self._pending = (self._last, self._last_cap,
                                             self._last_dither)
                    if self._fd is None and not self._connect():
                        continue            # no renderer yet; next tick
                    if self._pending is not None:
                        self._deliver()
                except Exception as exc:       # never let the keeper die
                    print(f"[sink] keeper: {exc}")

    def show(self, rgb888: bytes, pre_wb_img=None):
        cap = max(1, min(254, int(self.brightness)))
        dit = max(0, min(100, int(round(self.dither * 10))))
        with self._lock:
            if self._pending is None and rgb888 == self._last \
                    and cap == self._last_cap and dit == self._last_dither:
                return                  # the panel is already showing this
            self._pending = (bytes(rgb888), cap, dit)
            self._deliver()
