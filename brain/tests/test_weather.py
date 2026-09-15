"""The weather: the code table, the parser, the place, and the face at both
sizes on eight kinds of weather.

    .venv/bin/python -m pytest brain/tests/test_weather.py -q
"""
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.weather import (SCENES, ALL_CODES, scene_for, parse_forecast, Weather,   # noqa: E402
                           REFRESH_S, STALE_S)
from brain.art.weather import WeatherFace, moon_phase                             # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")

WMO_STANDARD = [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77,
                80, 81, 82, 85, 86, 95, 96, 99]


def test_every_wmo_code_has_a_scene():
    assert ALL_CODES == WMO_STANDARD
    for c in WMO_STANDARD:
        scene, k = scene_for(c)
        assert scene in ("clear", "mostly_clear", "partly_cloudy", "overcast", "fog", "drizzle",
                         "rain", "freezing", "snow", "showers", "thunder")
        assert 0.0 <= k <= 1.0
    assert scene_for(123) == ("overcast", 0.7) and scene_for(None)[0] == "overcast"


def fixture(now: int):
    hours = [now - 3600 + 3600 * i for i in range(10)]
    return {
        "utc_offset_seconds": -14400,
        "current": {"time": now, "temperature_2m": 21.4, "apparent_temperature": 22.0, "is_day": 1,
                    "precipitation": 0.0, "weather_code": 2, "cloud_cover": 40, "wind_speed_10m": 12.3},
        "hourly": {"time": hours, "temperature_2m": [20 + i for i in range(10)],
                   "weather_code": [2, 2, 3, 61, 61, 63, 80, 0, 0, 0], "is_day": [1] * 10,
                   "precipitation": [0] * 10},
        "daily": {"temperature_2m_max": [27.0, 25.0], "temperature_2m_min": [17.0, 16.0],
                  "sunrise": [now - 20000, now + 66400], "sunset": [now + 20000, now + 106400]},
    }


def test_parse_keeps_what_the_face_needs():
    now = 1_760_000_000
    d = parse_forecast(fixture(now), fetched=now)
    assert d["temp"] == 21.4 and d["code"] == 2 and d["is_day"] is True
    assert d["high"] == 27.0 and d["low"] == 17.0
    assert d["sunrise"] == now - 20000 and d["sunset"] == now + 20000
    assert [h["code"] for h in d["hours"]] == [3, 61, 61, 63, 80, 0]     # the six after now
    assert d["hours"][0]["temp"] == 22


class FakeCtrl:
    def __init__(self, lat=33.95, lon=-84.55):
        self.s = {"lat": lat, "lon": lon, "place": "Marietta, Georgia", "weather_units": "f"}
        self.applied = []

    def get(self):
        return dict(self.s)

    def apply(self, p):
        self.s.update(p)
        self.applied.append(p)
        return {}


def test_the_service_fetches_when_due_and_says_when_stale():
    clock = [1_760_000_000.0]
    calls = []
    def fetch(lat, lon):
        calls.append((lat, lon))
        return fixture(int(clock[0]))
    w = Weather(FakeCtrl(), fetch=fetch, clock=lambda: clock[0])
    w.tick()
    assert calls == [(33.95, -84.55)] and w.current()["temp"] == 21.4
    w.tick()
    assert len(calls) == 1                                       # not due yet
    clock[0] += REFRESH_S
    w.tick()
    assert len(calls) == 2
    assert not w.stale()
    clock[0] += STALE_S + 10
    assert w.stale()
    st = w.status()
    assert st["place"] == "Marietta, Georgia" and st["scene"] == "partly_cloudy" and st["units"] == "f"


def test_no_place_means_no_fetch():
    calls = []
    w = Weather(FakeCtrl(lat=999.0, lon=999.0), fetch=lambda *a: calls.append(a) or {},
                clock=lambda: 1_760_000_000.0)
    w.tick()
    assert calls == [] and w.problem == "no place set" and w.current() is None
    w2 = Weather(FakeCtrl(lat=90.0, lon=180.0), fetch=lambda *a: calls.append(a) or {},
                 clock=lambda: 1_760_000_000.0)
    w2.tick()
    assert calls == []                                           # the app's own "not set"


def test_moon_phase_is_full_two_weeks_after_new():
    new = 947182440.0
    assert abs(moon_phase(new)) < 0.01
    assert abs(moon_phase(new + 14.765 * 86400) - 0.5) < 0.01


CONDITIONS = [("clear day", 0, True), ("clear night", 0, False), ("partly cloudy", 2, True),
              ("overcast", 3, True), ("fog", 45, True), ("rain", 63, True), ("snow", 73, True),
              ("thunder", 95, False)]


def test_eight_conditions_at_both_sizes():
    from PIL import Image
    now = 1_760_000_000
    lat, lon = 33.95, -84.55
    for size, scale in ((64, 3), (192, 1)):
        frames = []
        for name, code, day in CONDITIONS:
            fx = fixture(now)
            fx["current"]["weather_code"] = code
            fx["current"]["is_day"] = 1 if day else 0
            fx["current"]["temperature_2m"] = 3.0 if code == 73 else 21.4
            d = parse_forecast(fx, fetched=now)
            face = WeatherFace(size)
            f = face.frame_at(2.5, d, units="f", lat=lat, lon=lon, stale=(code == 3), place="x",
                              now=now + 5000 - 20000)
            assert f.shape == (size, size, 3) and f.dtype == np.uint8
            assert f.max() > 40, name                                # something is drawn
            f2 = face.frame_at(3.5, d, units="f", lat=lat, lon=lon, now=now + 5000 - 20000)
            if code in (2, 63, 73, 95, 45):
                assert (f != f2).any(), name                         # it moves
            frames.append(f)
        none = WeatherFace(size).frame_at(0.0, None, place="")
        assert none.max() > 0
        frames.append(none)
        if OUT:
            n = len(frames)
            canvas = np.zeros((size, n * size + (n - 1) * 4, 3), dtype=np.uint8)
            for i, fr in enumerate(frames):
                canvas[:, i * (size + 4):i * (size + 4) + size] = fr
            Image.fromarray(canvas).resize((canvas.shape[1] * scale, size * scale),
                                           Image.NEAREST).save(os.path.join(OUT, f"weather-{size}.png"))


def test_units():
    now = 1_760_000_000
    d = parse_forecast(fixture(now), fetched=now)
    face = WeatherFace(64)
    assert face._temp(21.4, "f") == 71 and face._temp(21.4, "c") == 21
    fahrenheit = face.frame_at(0.0, d, units="f")
    celsius = face.frame_at(0.0, d, units="c")
    assert (fahrenheit != celsius).any()
