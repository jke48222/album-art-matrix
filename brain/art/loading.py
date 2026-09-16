"""Prepare a sleeve in the background while the wall keeps its current face.

A network lookup or image decode can take seconds. The drawing loop asks
for a prepared sleeve and keeps drawing until it is ready. One worker and
at most one outstanding request bound both memory and network work. A
failed sleeve rests for thirty seconds before another attempt.
"""
from concurrent.futures import ThreadPoolExecutor
import time

from .fetch import fetch_art
from .pipeline import prepare


class Preparing(Exception):
    """The caller keeps drawing the previous face until the worker is done."""


class Sleeves:
    def __init__(self, notify, fetch=fetch_art):
        self.notify, self.fetch = notify, fetch
        self.pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="sleeve")
        self.pending = None
        self.ready = None
        self.failed = None

    def _prepare(self, key):
        url, size, radius, percent = key
        return prepare(self.fetch(url), size, unsharp_radius=radius, unsharp_percent=percent)

    def get(self, url, size, radius, percent):
        key = (url, size, radius, percent)
        if self.pending and self.pending[1].done():
            completed, future = self.pending
            self.pending = None
            try:
                self.ready = completed, future.result()
                self.failed = None
            except Exception as exc:
                self.failed = completed, time.monotonic() + 30
                print(f"[art] could not prepare sleeve: {type(exc).__name__}; keeping current face", flush=True)
        if self.ready and self.ready[0] == key:
            return self.ready[1]
        if self.failed and self.failed[0] == key and time.monotonic() < self.failed[1]:
            raise Preparing()
        if self.pending is None:
            future = self.pool.submit(self._prepare, key)
            self.pending = key, future
            future.add_done_callback(lambda _: self.notify())
        raise Preparing()
