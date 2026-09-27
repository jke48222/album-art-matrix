"""Wall-local daily schedules and live routine state, independent of rendering."""
from __future__ import annotations

from datetime import date, timedelta
from functools import lru_cache
import math
import os
from pathlib import Path
import time

from .sun import sun_times, sun_factor


def wall_timezone() -> str:
    return _wall_timezone(os.environ.get("TZ", "").lstrip(":"))


@lru_cache(maxsize=8)
def _wall_timezone(tz: str) -> str:
    """The OS zone changes at process restart, or through an explicit TZ."""
    if tz and not tz.startswith("/"):
        return tz
    try:
        path = str(Path("/etc/localtime").resolve())
        if "/zoneinfo/" in path:
            return path.split("/zoneinfo/", 1)[1]
        value = Path("/etc/timezone").read_text().strip()
        if value:
            return value
    except OSError:
        pass
    return time.tzname[0]


def daily_at(day: date, hhmm: str) -> float:
    """A local occurrence, with the OS's DST rules.

    A missing spring-forward minute moves forward by the gap. On the repeated
    autumn hour, the first occurrence wins, so a daily alarm rings once.
    """
    return _daily_at(day, hhmm, (os.environ.get("TZ"), time.tzname))


@lru_cache(maxsize=128)
def _daily_at(day: date, hhmm: str, zone_key: tuple) -> float:
    hour, minute = map(int, hhmm.split(":"))
    fields = (day.year, day.month, day.day, hour, minute, 0, 0, 0)
    candidates = [time.mktime((*fields, dst)) for dst in (-1, 0, 1)]
    exact = [stamp for stamp in candidates
             if time.localtime(stamp)[:5] == fields[:5]]
    if exact:
        return min(exact)
    return time.mktime((*fields, -1))


def next_daily(hhmm: str, now: float, consumed: date | None = None) -> float:
    local = time.localtime(now)
    day = date(local.tm_year, local.tm_mon, local.tm_mday)
    at = daily_at(day, hhmm)
    if at <= now or consumed == day:
        at = daily_at(day + timedelta(days=1), hhmm)
    return at


def solar_status(state: dict, now: float) -> dict:
    result = {"sun_factor": 1.0, "sun_phase": "off"}
    lat, lon = state["lat"], state["lon"]
    valid = math.isfinite(lat) and math.isfinite(lon) and abs(lat) <= 90 and abs(lon) <= 180
    if not valid:
        result["sun_phase"] = "location" if state["sun"] == "on" else "off"
        return result
    # Events stay available while disabled, so setting up a location can show
    # an honest solar day before the person chooses to enable dimming.
    events = sun_times(lat, lon, now)
    if isinstance(events, tuple):
        rise, setting = events
        result.update(sunrise_at=rise, sunset_at=setting)
        phase = ("dawn" if abs(now - rise) < 1200 else
                 "dusk" if abs(now - setting) < 1200 else
                 "day" if rise <= now < setting else "night")
    else:
        phase = events
    if state["sun"] == "on":
        result.update(sun_phase=phase, sun_factor=sun_factor(lat, lon, state["sun_night"], now))
    return result


# How long a knock that lit a dark wall, or a wake-up that just finished,
# counts as someone in the room: Away and the idle face stand back this long
# (ControlState.rest_hold_until; main.py honours it). Away's own threshold.
REST_HOLD_S = 900.0
# A daily alarm that could not ring in its minute (a countdown had the
# panel) rings when the panel is free, up to this long after its time.
ALARM_LATE_S = 1800.0


class RoutineEngine:
    def __init__(self):
        self.sleep_state = "idle"
        self.sleep_total = 0.0
        self.wake = None
        self.woke_on = None
        self.rang_on = None
        self.alarm_due = None        # the day whose alarm is waiting for the panel
        self._solar_key = None
        self._solar = {}

    def tick(self, ctrl, now: float, mono: float) -> None:
        """Called under the control lock; a command cannot race completion."""
        state = ctrl.get()
        sl = ctrl.sleep
        if sl and mono >= sl["t0"] + sl["minutes"] * 60:
            ctrl.sleep = None
            self.sleep_state = "completed"
            # The wall finishing its own fade is not a command, so a check
            # someone is in the middle of stays up (interrupt=False).
            ctrl.apply({"mode": "off"}, interrupt=False)
            state = ctrl.get()
        if self.sleep_state == "completed" and state["mode"] != "off":
            # The wall is on again: "resting" is over. Left as "completed",
            # the Sleep page kept saying the wall was resting the next day.
            self.sleep_state = "idle"

        local = time.localtime(now)
        today = date(local.tm_year, local.tm_mon, local.tm_mday)
        wake_at = daily_at(today, state["wake_time"])
        span = state["wake_fade_min"] * 60
        if self.wake:
            if not state["wake_enabled"] or state["mode"] == "off":
                self.wake = None
            elif now >= self.wake["end"]:
                self.wake = None
                # The fade brought the wall up for someone waking: that is
                # someone in the room, or Away or the idle face would blank
                # the wall again the moment the fade ended.
                ctrl.rest_hold_until = mono + REST_HOLD_S
        if state["wake_enabled"] and self.woke_on != today and wake_at <= now < wake_at + span:
            # Consume the day even when it is already on. Turning it off later
            # in the window is a deliberate choice and must stay off.
            self.woke_on = today
            # Dark counts whether it was chosen (Off) or is only shown (Away,
            # or the idle face gone black with the saved face still up): the
            # wall looks off either way. Only a chosen Off is changed.
            if state["mode"] == "off" or getattr(ctrl, "display_mode", None) == "off":
                self.wake = {"start": wake_at, "end": wake_at + span}
                if state["mode"] == "off":
                    ctrl.apply({"mode": "art"})
                    state = ctrl.get()
        alarm_at = daily_at(today, state["alarm_time"])
        if state["alarm_enabled"] and self.rang_on != today:
            # Due in its own minute (enabling it later that day does not
            # ring it), then rung as soon as the panel is free: a countdown
            # running through the minute used to skip the day silently.
            if alarm_at <= now < alarm_at + 60:
                self.alarm_due = today
            if self.alarm_due == today and ctrl.timer is None and now < alarm_at + ALARM_LATE_S:
                self.rang_on = today
                self.alarm_due = None
                ctrl.ring()
            elif self.alarm_due == today and now >= alarm_at + ALARM_LATE_S:
                # Too late to ring: dropped, so the next alarm reads as
                # tomorrow's and not today's, already past.
                self.alarm_due = None

        timer = ctrl.timer
        if timer and mono >= timer["end"] + 180:
            ctrl.timer = None
            ctrl.apply({"mode": timer["ret"]}, interrupt=False)

    def snapshot(self, ctrl, now: float, mono: float) -> dict:
        state = ctrl.get()
        local = time.localtime(now)
        result = {"wall_time": now, "wall_timezone": wall_timezone(),
                  "wall_utc_offset_s": getattr(local, "tm_gmtoff", -time.timezone),
                  "sleep_state": self.sleep_state, "sleep_total_s": int(self.sleep_total),
                  "timer_state": "idle", "timer_ringing": False,
                  "timer_snoozed": False, "timer_ring_elapsed_s": 0.0,
                  "wake_active": False, "wake_progress": 0.0}
        solar_key = (state["sun"], state["lat"], state["lon"], state["sun_night"], int(now))
        if solar_key != self._solar_key:
            self._solar = solar_status(state, now)
            self._solar_key = solar_key
        result.update(self._solar)
        fade = 1.0
        if ctrl.sleep:
            sl = ctrl.sleep
            total = sl["minutes"] * 60
            remaining = max(0.0, sl["t0"] + total - mono)
            fade = remaining / total
            result.update(sleep_state="fading", sleep_total_s=round(total),
                          sleep_remaining_s=math.ceil(remaining), sleep_ends_at=now + remaining)
        if ctrl.timer:
            tm = ctrl.timer
            remaining = tm["end"] - mono
            result.update(timer_state="counting" if remaining > 0 else "ringing",
                          timer_ringing=remaining <= 0, timer_kind=tm.get("kind", "countdown"),
                          timer_id=tm.get("id"), timer_snoozed=tm.get("snoozed", False),
                          timer_ring_elapsed_s=max(0.0, -remaining),
                          timer_total_s=round(tm["total"]), timer_remaining_s=math.ceil(max(0, remaining)),
                          timer_ends_at=now + remaining)
        wake_factor = 1.0
        # Not under a timer: the alarm (or a countdown) takes the panel at
        # full light. Drawn at the fade's 2 to 15 percent, an alarm that
        # shares the wake's time was all but invisible. The wake stays, so
        # the fade picks up again when the alarm hands back.
        if self.wake and state["wake_enabled"] and state["mode"] not in ("off", "timer"):
            progress = max(0.0, min(1.0, (now - self.wake["start"]) / (self.wake["end"] - self.wake["start"])))
            result.update(wake_active=progress < 1, wake_progress=progress,
                          wake_started_at=self.wake["start"], wake_ends_at=self.wake["end"])
            wake_factor = max(0.02, progress)
        if state["wake_enabled"]:
            at = next_daily(state["wake_time"], now, self.woke_on)
            result.update(wake_next_at=at, wake_next_end_at=at + state["wake_fade_min"] * 60)
        if state["alarm_enabled"]:
            day = date(local.tm_year, local.tm_mon, local.tm_mday)
            if self.alarm_due == day and self.rang_on != day:
                # Waiting for a countdown to finish: still today's alarm.
                result["alarm_next_at"] = daily_at(day, state["alarm_time"])
            else:
                result["alarm_next_at"] = next_daily(state["alarm_time"], now, self.rang_on)
        result["sleep_factor"] = fade
        result["wake_factor"] = wake_factor
        idle = ctrl.idle_now if state["mode"] in ("art", "cd") and not result["wake_active"] else None
        idle_factor = .3 if idle == "dim" else 1
        result["effective_brightness"] = (0 if state["mode"] == "off" or idle == "black" or ctrl.away_now else
                                          state["brightness"] * result["sun_factor"] * fade * wake_factor * idle_factor)
        return result
