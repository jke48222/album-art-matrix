"""Touch the frame with two knocks, or whistle, to wake or quiet the wall.

The microphone looks for two short, broad clicks against the room's recent
sound. A held clear whistle goes up to turn the wall on and down to turn it
off. The face you left is remembered on the wall. Everything is measured
from small slices of the existing audio stream; no extra recording is made
or kept. Music is harder than a quiet room, so both gestures can be switched
off and knock sensitivity adjusted from Hearing on the phone.
"""
from collections import deque
import math
import queue
import threading
import time

import numpy as np

RATE = 16000
SLICE = 160                       # 10 ms resolves the brief's 20 ms rise
FFT = 1024
HOP = 512
KNOCK_MIN, KNOCK_MAX = .15, .8
MAX_BURST = .08
DEBOUNCE = 2.0
WHISTLE_HOLD = .3
PURITY = .70


def db(power):
    return 10 * math.log10(max(float(power), 1e-12))


class GestureDetector:
    def __init__(self, log=None):
        self.log = log or (lambda value: print("[knock] " + value, flush=True))
        self.history = deque(maxlen=100)
        self.tail = np.empty(0, dtype=np.float32)
        self.whistle_tail = np.empty(0, dtype=np.float32)
        self.samples = 0
        self.burst = None
        self.first = None
        self.last_toggle = -math.inf
        self.whistle_start = None
        self.whistle_pitch = None
        self.whistle_last = None
        self.whistle_fired = False
        self.window = np.hanning(FFT).astype(np.float32)
        self.freq = np.fft.rfftfreq(FFT, 1 / RATE)

    def _spike_end(self, now):
        burst, self.burst = self.burst, None
        duration = now - burst["at"]
        samples = np.concatenate(burst["parts"])
        spectrum = abs(np.fft.rfft(samples * np.hanning(len(samples)))) ** 2
        freq = np.fft.rfftfreq(len(samples), 1 / RATE)
        total = max(float(spectrum.sum()), 1e-12)
        low = float(spectrum[(freq > 30) & (freq < 500)].sum()) / total
        high = float(spectrum[freq > 2000].sum()) / total
        candidate = duration < MAX_BURST and low >= .015 and high >= .10
        self.log(f"peak={burst['peak']:.1f}dB rise={burst['rise']:.1f}dB "
                 f"duration={duration * 1000:.0f}ms low={low:.3f} high={high:.3f} "
                 f"candidate={candidate}")
        if not candidate:
            self.first = None
            return None
        previous = self.first
        self.first = (burst["at"], burst["peak"])
        if previous and KNOCK_MIN <= burst["at"] - previous[0] <= KNOCK_MAX:
            self.first = None
            if now - self.last_toggle >= DEBOUNCE:
                self.last_toggle = now
                return {"gesture": "knock", "action": "toggle", "at": now,
                        "interval_ms": round((burst["at"] - previous[0]) * 1000)}
        return None

    def _knock(self, part, sensitivity, music_db):
        now = self.samples / RATE
        power = float(np.mean(part * part))
        level = db(power)
        baseline = db(np.mean(self.history)) if self.history else -120
        threshold = max(baseline + sensitivity, music_db + 6 if music_db is not None else -120)
        event = None
        if self.burst is not None:
            self.burst["parts"].append(part.copy())
            self.burst["peak"] = max(self.burst["peak"], level)
            if level < self.burst["peak"] - 24:
                event = self._spike_end(now)
            elif now - self.burst["at"] >= MAX_BURST:
                self.log(f"peak={self.burst['peak']:.1f}dB duration>=80ms candidate=False")
                self.burst, self.first = None, None
        elif len(self.history) >= 100 and level >= threshold:
            self.burst = {"at": now, "parts": [part.copy()], "peak": level,
                          "rise": level - baseline, "threshold": threshold}
        elif self.first and (level > self.first[1] or now - self.first[0] > KNOCK_MAX):
            self.first = None
        self.history.append(power)
        return event

    def _whistle(self, samples, end):
        power = abs(np.fft.rfft(samples * self.window)) ** 2
        band = (self.freq >= 800) & (self.freq <= 3500)
        peak = int(np.argmax(np.where(band, power, 0)))
        energy = float(power[band].sum())
        purity = float(power[max(0, peak - 1):peak + 2].sum()) / max(energy, 1e-12)
        clear = purity >= PURITY and db(np.mean(samples * samples)) > -55
        pitch = float(self.freq[peak])
        if not clear:
            self.whistle_start = self.whistle_pitch = self.whistle_last = None
            self.whistle_fired = False
            return None
        if self.whistle_start is None:
            self.whistle_start = end - FFT / RATE
            self.whistle_pitch = pitch
        self.whistle_last = pitch
        if end - self.whistle_start >= WHISTLE_HOLD and not self.whistle_fired:
            self.whistle_fired = True
            if end - self.last_toggle < DEBOUNCE:
                return None
            self.last_toggle = end
            delta = pitch - self.whistle_pitch
            action = "on" if delta >= 30 else "off" if delta <= -30 else "toggle"
            self.log(f"whistle purity={purity:.3f} pitch={pitch:.0f}Hz change={delta:.0f}Hz action={action}")
            return {"gesture": "whistle", "action": action, "pitch": pitch, "at": end}
        return None

    def feed(self, pcm, *, knock=True, sensitivity=20, whistle=True, music_db=None):
        x = np.frombuffer(pcm, dtype='<i2').astype(np.float32) / 32768
        events = []
        self.tail = np.concatenate((self.tail, x))
        while len(self.tail) >= SLICE:
            part, self.tail = self.tail[:SLICE], self.tail[SLICE:]
            self.samples += SLICE
            if knock:
                event = self._knock(part, sensitivity, music_db)
                if event:
                    events.append(event)
            else:
                self.burst, self.first = None, None
                self.history.append(float(np.mean(part * part)))
            self.whistle_tail = np.concatenate((self.whistle_tail, part))
            if len(self.whistle_tail) >= FFT:
                if whistle:
                    event = self._whistle(self.whistle_tail[:FFT], self.samples / RATE)
                    if event:
                        events.append(event)
                else:
                    self.whistle_start = None
                    self.whistle_fired = False
                self.whistle_tail = self.whistle_tail[HOP:]
        return events


class Gestures:
    def __init__(self, ctrl):
        self.ctrl = ctrl
        self.detector = GestureDetector()
        self.events = queue.SimpleQueue()
        self.last = None
        self._enabled = False
        threading.Thread(target=self._actions, name="gestures", daemon=True).start()

    def feed(self, pcm, settings, gate_open, music_db):
        enabled = bool(self.ctrl.features and self.ctrl.features.enabled("knock"))
        if not enabled:
            if self._enabled:
                self.detector = GestureDetector()
            self._enabled = False
            return
        self._enabled = True
        for event in self.detector.feed(pcm, knock=settings["knock"],
                                        sensitivity=settings["knock_sensitivity"],
                                        whistle=settings["whistle"],
                                        music_db=music_db if gate_open else None):
            self.events.put(event)

    def _actions(self):
        while True:
            event = self.events.get()
            if not self.ctrl.features.enabled("knock"):
                continue
            try:
                self.ctrl.gesture_power(event["action"])
                self.last = {**event, "at": time.time()}
            except Exception as exc:
                print(f"[knock] could not change face: {type(exc).__name__}", flush=True)
