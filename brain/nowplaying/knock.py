"""Two knocks on the frame, or a whistle: the wall's own switch.

The microphone is zip tied to the bottom edge of the board, so a knock on
the frame reaches it through the wood as a thump far louder than anything
the room is playing. Two thumps close together, with nothing before and
nothing after, is a person asking, and the wall answers by going dark or
coming back. A drum track hits every half second too, but it never stops,
and that is the whole difference: a double knock is a PAIR standing alone.

The whistle is the fallback for a mount that does not carry a knock. A
whistle is close to a pure tone, one spectral peak with almost nothing
around it, which the ear can pick out even over a song. The pitch bending
up means on, bending down means off.

Both detectors run on the ear's capture thread, on the same 100 ms chunks
the ring keeps, so they cost a few FFTs per second and no new audio path.
Knocks are looked for at 10 ms resolution inside each chunk; whistles in
1024-sample windows, two per chunk. Every candidate is logged with its
numbers so the thresholds can be tuned from the journal after a session of
real knocking: the numbers here are the starting point, not the last word.

Knobs (on the phone's Hearing page): knock, knock_sensitivity (dB over the
last second's level), whistle. The ear must be on for either to hear.
"""
from __future__ import annotations

import math
import time
from collections import deque

import numpy as np

RATE = 16000
SUB_S = 0.010                     # a knock is resolved in 10 ms steps
SUB_N = int(RATE * SUB_S)         # 160 samples
BASE_S = 1.0                      # "the last second": the level a knock rises over
BURST_MAX_S = 0.080               # a knock is over within this
BURST_EDGE_DB = 6.0               # the burst lasts while it stays this far over the base
RISE_WITHIN_S = 0.020             # ... and it got there within this
MUSIC_EXTRA_DB = 6.0              # while the room plays, the bar is raised this much more
LOW_HZ, HIGH_HZ = 500.0, 2000.0   # a knock has energy both below and above
BROADBAND_SHARE = 0.15            # ... at least this share in each
PAIR_MIN_S, PAIR_MAX_S = 0.150, 0.800
ALONE_BEFORE_S = 0.800            # nothing in the 0.8 s before the first knock
ALONE_AFTER_S = 0.600             # nothing in the 0.6 s after the second
TOGGLE_REFRACTORY_S = 2.0         # a knock right after a toggle is ignored

WHISTLE_LOW_HZ, WHISTLE_HIGH_HZ = 800.0, 3500.0
WHISTLE_N = 1024                  # samples per window; 64 ms at 16 kHz
WHISTLE_STEP = 576                # two windows per 100 ms chunk
WHISTLE_PEAK_SHARE = 0.60         # the peak (three bins) carries this much of the band
WHISTLE_BAND_SHARE = 0.35         # ... and the band this much of everything
WHISTLE_MIN_S = 0.300             # held at least this long
WHISTLE_MAX_S = 2.500             # decided by then at the latest
WHISTLE_GLIDE_BINS = 3            # window to window, the peak may move this far
WHISTLE_BEND_HZ = 100.0           # rising or falling needs this much travel
WHISTLE_REFRACTORY_S = 1.5


def _db(x: np.ndarray) -> float:
    rms = math.sqrt(float(np.mean(x * x))) if x.size else 0.0
    return 20.0 * math.log10(max(rms / 32768.0, 1e-7))


def band_shares(samples: np.ndarray, rate: int = RATE) -> tuple[float, float]:
    """Share of the energy below LOW_HZ and above HIGH_HZ, for a short
    window around a burst. A knock has plenty of both; a plucked note or a
    voice sits in the middle."""
    if samples.size < 64:
        return 0.0, 0.0
    w = samples.astype(np.float64) * np.hanning(samples.size)
    spec = np.abs(np.fft.rfft(w)) ** 2
    freqs = np.fft.rfftfreq(samples.size, 1.0 / rate)
    total = float(spec[1:].sum()) or 1e-12
    low = float(spec[(freqs > 0) & (freqs < LOW_HZ)].sum()) / total
    high = float(spec[freqs > HIGH_HZ].sum()) / total
    return low, high


class KnockDetector:
    """Feed it the ear's chunks; it calls `on_double(info)` for a lone pair."""

    def __init__(self, on_double=None, sensitivity_db: float = 20.0, log=print,
                 rate: int = RATE):
        self.on_double = on_double
        self.sensitivity_db = float(sensitivity_db)
        self.log = log
        self.rate = rate
        self._sub_db: deque = deque(maxlen=int(BASE_S / SUB_S))   # the last second, 10 ms steps
        self._t = 0.0                       # audio time of the next sub-frame
        self._in_burst = False
        self._burst_start = 0.0
        self._burst_peak_db = -120.0
        self._burst_peak_t = 0.0
        self._burst_base = -120.0
        self._burst_rise_ok = False
        self._prev_db = -120.0
        self._prev2_db = -120.0
        self._burst_samples = []            # the burst's samples, for the band check
        self.candidates: list[dict] = []    # onset time, db over, ms, shares
        self._pending_pair = None           # (first, second), waiting to be alone after
        self._last_toggle_t = -10.0
        self.count_candidates = 0
        self.count_doubles = 0
        self.last: dict | None = None

    def configure(self, sensitivity_db=None):
        if sensitivity_db is not None:
            self.sensitivity_db = float(sensitivity_db)

    def feed(self, chunk: bytes, gate_open: bool = False, now: float | None = None):
        """One 100 ms chunk of int16 mono. `now` is monotonic time for the
        chunk's end; the audio clock runs from it."""
        x = np.frombuffer(chunk, dtype=np.int16)
        n_sub = x.size // SUB_N
        if now is None:
            now = time.monotonic()
        t0 = now - n_sub * SUB_S
        for i in range(n_sub):
            seg = x[i * SUB_N:(i + 1) * SUB_N]
            self._step(seg, t0 + i * SUB_S, gate_open)
        self._settle(now)

    # ---- one 10 ms step ------------------------------------------------------------
    def _step(self, seg: np.ndarray, t: float, gate_open: bool):
        db = _db(seg.astype(np.float64))
        base = self._base_db()
        bar = base + self.sensitivity_db + (MUSIC_EXTRA_DB if gate_open else 0.0)
        if not self._in_burst:
            if db >= bar and len(self._sub_db) >= 20:
                self._in_burst = True
                self._burst_start = t
                self._burst_peak_db, self._burst_peak_t = db, t
                self._burst_base = base
                # rose from under the edge to over the bar within two steps
                self._burst_rise_ok = min(self._prev_db, self._prev2_db) < base + BURST_EDGE_DB
                self._burst_samples = [seg]
        else:
            self._burst_samples.append(seg)
            if db > self._burst_peak_db:
                self._burst_peak_db, self._burst_peak_t = db, t
            if db < self._burst_base + BURST_EDGE_DB or t - self._burst_start > BURST_MAX_S + SUB_S:
                self._end_burst(t)
        self._prev2_db, self._prev_db = self._prev_db, db
        # the base is the second before the burst, so a burst does not raise its own bar
        if not self._in_burst:
            self._sub_db.append(db)

    def _base_db(self) -> float:
        if not self._sub_db:
            return -120.0
        pw = np.mean([10 ** (d / 10.0) for d in self._sub_db])
        return 10.0 * math.log10(max(pw, 1e-12))

    def _end_burst(self, t: float):
        self._in_burst = False
        length = t - self._burst_start
        samples = np.concatenate(self._burst_samples) if self._burst_samples else np.zeros(0)
        self._burst_samples = []
        over = self._burst_peak_db - self._burst_base
        low, high = band_shares(samples[:int(0.020 * self.rate) + SUB_N], self.rate)
        ok = (length <= BURST_MAX_S + SUB_S / 2 and self._burst_rise_ok
              and low >= BROADBAND_SHARE and high >= BROADBAND_SHARE)
        self.log(f"[knock] {'candidate' if ok else 'not a knock'}: +{over:.1f} dB over "
                 f"{self._burst_base:.1f}, {int(length * 1000)} ms, low {int(low * 100)}% "
                 f"high {int(high * 100)}%"
                 + ("" if ok else (" (too long)" if length > BURST_MAX_S + SUB_S / 2
                                   else " (slow rise)" if not self._burst_rise_ok
                                   else " (not broadband)")))
        if not ok:
            # a loud, long, or narrow sound in the middle of a pair spoils it
            self._pending_pair = None
            return
        self.count_candidates += 1
        cand = {"t": self._burst_start, "over_db": round(over, 1), "ms": int(length * 1000),
                "low": round(low, 2), "high": round(high, 2)}
        self.last = dict(cand, kind="knock")
        self._pair(cand)

    def _pair(self, cand: dict):
        cands = self.candidates
        cands.append(cand)
        del cands[:-8]
        if self._pending_pair is not None:
            # a third knock inside the quiet-after window: not a lone pair
            self._pending_pair = None
            return
        if len(cands) < 2:
            return
        first, second = cands[-2], cands[-1]
        gap = second["t"] - first["t"]
        if not (PAIR_MIN_S <= gap <= PAIR_MAX_S):
            return
        if len(cands) >= 3 and first["t"] - cands[-3]["t"] < ALONE_BEFORE_S:
            return                            # something knocked just before the pair
        if second["t"] - self._last_toggle_t < TOGGLE_REFRACTORY_S:
            return
        self._pending_pair = (first, second)

    def _settle(self, now: float):
        """The pair counts once the quiet after it has passed."""
        pp = self._pending_pair
        if pp is None:
            return
        first, second = pp
        if now - second["t"] < ALONE_AFTER_S:
            return
        self._pending_pair = None
        self.count_doubles += 1
        self._last_toggle_t = now
        info = {"kind": "double", "gap_ms": int((second["t"] - first["t"]) * 1000),
                "over_db": max(first["over_db"], second["over_db"]), "t": second["t"]}
        self.last = info
        self.log(f"[knock] double knock, {info['gap_ms']} ms apart")
        if self.on_double is not None:
            try:
                self.on_double(info)
            except Exception as exc:
                self.log(f"[knock] on_double: {exc}")

    def status(self) -> dict:
        return {"sensitivity_db": self.sensitivity_db, "candidates": self.count_candidates,
                "doubles": self.count_doubles, "last": self.last}


class WhistleDetector:
    """Feed it the ear's chunks; it calls `on_whistle("up" | "down", info)`."""

    def __init__(self, on_whistle=None, log=print, rate: int = RATE):
        self.on_whistle = on_whistle
        self.log = log
        self.rate = rate
        self._carry = np.zeros(0, dtype=np.int16)
        self._track: list[tuple[float, float]] = []     # (time, hz) of tonal windows
        self._last_event_t = -10.0
        self._hann = np.hanning(WHISTLE_N)
        self._freqs = np.fft.rfftfreq(WHISTLE_N, 1.0 / rate)
        self._band = (self._freqs >= WHISTLE_LOW_HZ) & (self._freqs <= WHISTLE_HIGH_HZ)
        self.count = 0
        self.last: dict | None = None

    def feed(self, chunk: bytes, now: float | None = None):
        if now is None:
            now = time.monotonic()
        x = np.concatenate([self._carry, np.frombuffer(chunk, dtype=np.int16)])
        n_win = 0
        pos = 0
        total = x.size
        while pos + WHISTLE_N <= total:
            win = x[pos:pos + WHISTLE_N].astype(np.float64)
            t = now - (total - (pos + WHISTLE_N)) / self.rate
            self._window(win, t)
            pos += WHISTLE_STEP
            n_win += 1
        self._carry = x[pos:].copy()
        self._decide(now, ended=False)

    def _window(self, win: np.ndarray, t: float):
        spec = np.abs(np.fft.rfft(win * self._hann)) ** 2
        total = float(spec[1:].sum()) or 1e-12
        band = spec * self._band
        band_e = float(band.sum())
        if band_e / total < WHISTLE_BAND_SHARE or band_e <= 0:
            self._decide(t, ended=True)
            return
        k = int(np.argmax(band))
        peak = float(band[max(0, k - 1):k + 2].sum())
        if peak / band_e < WHISTLE_PEAK_SHARE:
            self._decide(t, ended=True)
            return
        # the peak's exact place, from the bins either side of it
        a, b, c = spec[k - 1], spec[k], spec[k + 1] if k + 1 < spec.size else 0.0
        denom = (a - 2 * b + c) or 1e-12
        delta = 0.5 * (a - c) / denom if abs(denom) > 1e-9 else 0.0
        hz = float((k + max(-0.5, min(0.5, delta))) * self.rate / WHISTLE_N)
        if self._track and abs(hz - self._track[-1][1]) > WHISTLE_GLIDE_BINS * self.rate / WHISTLE_N:
            self._decide(t, ended=True)      # a jump: a new whistle, or not one
        self._track.append((t, hz))
        if self._track[-1][0] - self._track[0][0] >= WHISTLE_MAX_S:
            self._decide(t, ended=True)

    def _decide(self, now: float, ended: bool):
        tr = self._track
        if not tr:
            return
        held = tr[-1][0] - tr[0][0]
        if not ended:
            return
        self._track = []
        if held < WHISTLE_MIN_S or len(tr) < 4:
            return
        if now - self._last_event_t < WHISTLE_REFRACTORY_S:
            return
        # the bend: the end against the start, each as a short mean
        k = max(1, len(tr) // 4)
        start = float(np.mean([h for _, h in tr[:k]]))
        end = float(np.mean([h for _, h in tr[-k:]]))
        travel = end - start
        kind = "up" if travel >= WHISTLE_BEND_HZ else "down" if travel <= -WHISTLE_BEND_HZ else "flat"
        self.log(f"[whistle] {kind}: {int(start)} -> {int(end)} Hz over {int(held * 1000)} ms")
        info = {"kind": kind, "from_hz": int(start), "to_hz": int(end), "ms": int(held * 1000),
                "t": tr[-1][0]}
        self.last = info
        if kind == "flat":
            return
        self.count += 1
        self._last_event_t = now
        if self.on_whistle is not None:
            try:
                self.on_whistle(kind, info)
            except Exception as exc:
                self.log(f"[whistle] on_whistle: {exc}")

    def status(self) -> dict:
        return {"count": self.count, "last": self.last}


class KnockEar:
    """What the ear holds: both detectors, the knobs, and the wall's switch."""

    def __init__(self, ctrl, knock: bool = True, sensitivity_db: float = 20.0,
                 whistle: bool = True, log=None):
        self.ctrl = ctrl
        self.log = log or (lambda s: print(s, flush=True))
        self.knock_on = bool(knock)
        self.whistle_on = bool(whistle)
        self.knocks = KnockDetector(on_double=self._double, sensitivity_db=sensitivity_db,
                                    log=self.log)
        self.whistles = WhistleDetector(on_whistle=self._whistle, log=self.log)
        self.toggles = 0

    def configure(self, knock=None, sensitivity_db=None, whistle=None):
        if knock is not None:
            self.knock_on = bool(knock)
        if whistle is not None:
            self.whistle_on = bool(whistle)
        if sensitivity_db is not None:
            self.knocks.configure(sensitivity_db=float(sensitivity_db))

    def feed(self, chunk: bytes, gate_open: bool, now: float):
        if self.knock_on:
            self.knocks.feed(chunk, gate_open=gate_open, now=now)
        if self.whistle_on:
            self.whistles.feed(chunk, now=now)

    def _double(self, info):
        self.toggles += 1
        what = self.ctrl.knock_toggle("two knocks")
        self.log(f"[knock] the wall goes {what}")

    def _whistle(self, kind, info):
        self.toggles += 1
        what = self.ctrl.knock_toggle("a whistle " + kind, want="on" if kind == "up" else "off")
        self.log(f"[whistle] the wall goes {what}")

    def status(self) -> dict:
        return {"knock": self.knock_on, "whistle": self.whistle_on, "toggles": self.toggles,
                "knocks": self.knocks.status(), "whistles": self.whistles.status()}
