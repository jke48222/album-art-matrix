"""Short-lived exact-pixel overlays; underlying content and settings stay intact."""
import base64
import math
import re
import threading
import time


class DisplaySession:
    PURPOSES = {"onboarding", "calibration", "panel", "guests"}
    GAINS = {"wb_r", "wb_g", "wb_b"}

    def __init__(self, ctrl):
        self.ctrl = ctrl
        self.item = None
        self.timer = None
        # The guest frame render() last handed out and the cover it stood
        # for. A check can end between render() and the show that follows,
        # and that one frame must still not be reported as shown.
        self._guest_frame = None

    @staticmethod
    def patch(value, *, keep=False):
        allowed = DisplaySession.GAINS if keep else DisplaySession.GAINS | {"brightness"}
        if not isinstance(value, dict) or not set(value) <= allowed:
            raise ValueError("Only brightness and colour gains can be previewed.")
        result = {}
        for key, number in value.items():
            low = .05 if key == "brightness" else .3
            if isinstance(number, bool) or not isinstance(number, (int, float)) or not math.isfinite(number) or not low <= number <= 1:
                raise ValueError("Use valid brightness and colour gain values.")
            result[key] = float(number)
        return result

    def status(self):
        with self.ctrl._lock:
            self._expire()
            if not self.item:
                return {"active": False}
            return {"active": True, "token": self.item["token"], "purpose": self.item["purpose"],
                    "seconds_remaining": max(0, self.item["until"] - time.monotonic())}

    def _expire(self):
        if self.item and self.item["until"] <= time.monotonic():
            self.cancel()

    def cancel(self):
        with self.ctrl._lock:
            if self.timer:
                self.timer.cancel()
            self.timer = None
            self.item = None
            self.ctrl.dirty.set()

    def _deadline(self, token, deadline):
        with self.ctrl._lock:
            if self.item and self.item["token"] == token and self.item["until"] == deadline:
                self._expire()

    def begin(self, data):
        token, purpose = data.get("token"), data.get("purpose")
        if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9-]{16,64}", token):
            raise ValueError("Use a valid display session identifier.")
        if not isinstance(purpose, str) or purpose not in self.PURPOSES:
            raise ValueError("Unknown display purpose.")
        seconds = data.get("seconds", 300)
        if isinstance(seconds, bool) or not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or not 1 <= seconds <= 600:
            raise ValueError("Choose a duration from 1 to 600 seconds.")
        patch = self.patch(data.get("patch", {}))
        pixels = None
        if "px" in data:
            try:
                pixels = self.ctrl.wall.fit(base64.b64decode(data["px"], validate=True))
            except (TypeError, ValueError):
                pass
            if pixels is None:
                raise ValueError("Send a square RGB frame that fits the wall.")
        # HomeKit takes its code lock and then the control lock, so ask it
        # before taking the control lock here. The other order can deadlock.
        hk = getattr(self.ctrl, "homekit", None)
        code_up = bool(hk and hk.is_showing_code())
        with self.ctrl._lock:
            self._expire()
            if self.item and (self.item["token"] != token or self.item["purpose"] != purpose):
                raise RuntimeError("Something else is showing on the wall. Finish it first.")
            if not self.item:
                if pixels is None:
                    raise ValueError("A new display session needs a frame.")
                if code_up:
                    raise RuntimeError("Hide the Home pairing code before starting this check.")
                self.item = {"token": token, "purpose": purpose, "px": pixels, "patch": {},
                             "cover": self.ctrl.last_frame}
            self.item["patch"].update(patch)
            if pixels is not None:
                self.item["px"] = pixels
            self.item["until"] = time.monotonic() + seconds
            if self.timer:
                self.timer.cancel()
            self.timer = threading.Timer(seconds, self._deadline, args=(token, self.item["until"]))
            self.timer.daemon = True
            self.timer.start()
            self.ctrl.dirty.set()
            return self.status()

    def end(self, data):
        keep = self.patch(data.get("keep", {}), keep=True)
        with self.ctrl._lock:
            self._expire()
            if not self.item:
                if keep:
                    raise RuntimeError("The measurement expired. Start again before saving it.")
                return {"active": False}
            if data.get("token") != self.item["token"]:
                raise RuntimeError("Something else is showing on the wall now.")
            if keep and self.item["purpose"] != "calibration":
                raise ValueError("Only calibration can save colour gains.")
            if keep:
                # Persist before discarding the preview. A disk error leaves it
                # available for a retry instead of claiming a successful save.
                self.ctrl.save_colour_gains(keep)
            self.cancel()
            return {"active": False}

    def cover(self, image=None):
        """(private, frame): while a guest code is up, or for the guest frame
        render() made just before the check ended, the frame to report as
        shown instead of it, so the password never leaves the wall."""
        with self.ctrl._lock:
            if self.item and self.item["purpose"] == "guests":
                return True, self.item["cover"]
            if image is not None and self._guest_frame and image is self._guest_frame[0]:
                return True, self._guest_frame[1]
            return False, None

    def render(self, gains):
        """Return the exact source and balanced output, with no artistic finish."""
        from PIL import Image
        from .art.pipeline import white_balance
        with self.ctrl._lock:
            self._expire()
            if not self.item:
                return None
            settings = {**self.ctrl.get(), **self.item["patch"]}
            image = Image.frombytes("RGB", (self.ctrl.wall.width, self.ctrl.wall.height), self.item["px"])
            self._guest_frame = (image, self.item["cover"]) if self.item["purpose"] == "guests" else None
        colour = tuple(g * settings[k] for g, k in zip(gains, ("wb_r", "wb_g", "wb_b")))
        peak = max(1, max(colour))
        effective = tuple(v / peak * settings["brightness"] for v in colour)
        return image, white_balance(image, effective, floor=False).tobytes()
