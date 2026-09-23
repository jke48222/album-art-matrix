"""The weather: the code table, the parser, the place, and the face at both
sizes on eight kinds of weather.

    .venv/bin/python -m pytest brain/tests/test_weather.py -q
"""
import os
import sys
import pytest

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.weather import (ALL_CODES, scene_for, parse_forecast, Weather,   # noqa: E402
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
    assert d["utc_offset_s"] == -14400
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
    assert st["utc_offset_s"] == -14400
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
    from brain.sun import sun_times
    now = 1_760_000_000
    lat, lon = 33.95, -84.55
    rise, set_ = sun_times(lat, lon, now)
    noon, midnight = (rise + set_) / 2, set_ + 4 * 3600          # the real day at this place
    for size, scale in ((64, 3), (192, 1)):
        frames = []
        for name, code, day in CONDITIONS:
            fx = fixture(now)
            fx["current"]["weather_code"] = code
            fx["current"]["is_day"] = 1 if day else 0
            fx["current"]["temperature_2m"] = 3.0 if code == 73 else 21.4
            d = parse_forecast(fx, fetched=now)
            face = WeatherFace(size)
            when = noon if day else midnight
            f = face.frame_at(2.5, d, units="f", lat=lat, lon=lon, stale=(code == 3), place="x", now=when)
            assert f.shape == (size, size, 3) and f.dtype == np.uint8
            assert f.max() > 40, name                                # something is drawn
            f2 = face.frame_at(3.5, d, units="f", lat=lat, lon=lon, now=when)
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


def test_changing_place_never_relabels_the_previous_forecast():
    now = 1_760_000_000.0
    ctrl = FakeCtrl()
    w = Weather(ctrl, fetch=lambda *args: fixture(int(now)), clock=lambda: now)
    w.tick()
    assert w.current() is not None
    ctrl.apply({"lat": 51.5, "lon": -0.1, "place": "London"})
    assert w.current() is None
    assert w.status()["now"] is None
    assert w.status()["utc_offset_s"] is None
    w.tick()
    assert w.current() is not None


def test_all_conditions_render_extreme_temperatures_and_cache_clouds():
    now = 1_760_000_000
    for size in (64, 192):
        face = WeatherFace(size)
        for code in WMO_STANDARD:
            data = parse_forecast(fixture(now), fetched=now)
            data.update(code=code, temp=-40.0, high=-30.0, low=-50.0)
            for day in (True, False):
                data["is_day"] = day
                frame = face.frame_at(0, data, units="c", now=now)
                assert frame.shape == (size, size, 3)
                assert frame.dtype == np.uint8
                assert np.isfinite(frame).all()
        cached = {key: id(value) for key, value in face._cloud_sprites.items()}
        face.frame_at(0.1, data, units="c", now=now)
        assert cached == {key: id(value) for key, value in face._cloud_sprites.items()}


def test_hero_temperature_stays_above_conditions_and_fits_signed_three_digits():
    """The wall uses the phone's hierarchy, including extreme-temperature fit."""
    for size in (64, 192):
        for celsius in (-100, -40, 22.8, 100):
            data = dict(temp=celsius, code=3, is_day=False, high=celsius+5, low=celsius-5)
            f = WeatherFace(size).frame_at(0, data, units="c", place="Douglasville, Georgia")
            bright = (f.min(axis=2) > 150)
            # The dominant text is above the condition and range, not at the bottom.
            hero = bright[int(size*.30):int(size*.64)]
            footer = bright[int(size*.86):]
            assert hero.sum() > size
            assert footer.sum() < hero.sum() * .1
            assert not bright[:, -1].any(), "temperature or labels clipped at right edge"


def test_place_range_staleness_and_missing_values_are_visible():
    data = dict(temp=22.8, code=3, is_day=False, high=24.4, low=17.2)
    for size in (64, 192):
        face = WeatherFace(size)
        a = face.frame_at(0, data, place="Douglasville, Georgia")
        b = face.frame_at(0, data, place="London")
        assert (a[:int(size*.25)] != b[:int(size*.25)]).any()
        stale = face.frame_at(0, data, place="London", stale=True)
        assert (stale != b).any()
        missing = face.frame_at(0, dict(code=None), place="London")
        assert (missing != b).any()
        changed = face.frame_at(0, dict(data, high=30, low=-5), place="London")
        assert (changed[int(size*.75):] != b[int(size*.75):]).any()


def test_manual_refresh_fetches_immediately_even_when_the_cache_is_young():
    now = 1_760_000_000.0
    calls = []
    def fetch(*args):
        calls.append(args)
        return fixture(int(now))
    w = Weather(FakeCtrl(), fetch=fetch, clock=lambda: now)
    w.tick()
    w.refresh()
    assert w.status()["refreshing"] is True
    w.tick()
    assert len(calls) == 2
    assert w.status()["refreshing"] is False
    w.tick()
    assert len(calls) == 2


def test_invalid_upstream_response_preserves_last_good_forecast():
    now = 1_760_000_000.0
    responses = iter([fixture(int(now)), {"current": {}}, {"current": None}])
    w = Weather(FakeCtrl(), fetch=lambda *a: next(responses), clock=lambda: now)
    w.tick()
    for _ in range(2):
        w.refresh()
        w.tick()
        assert w.current()["temp"] == 21.4
        assert "temporarily unavailable" in w.status()["problem"]
        assert w.status()["refreshing"] is False


def test_location_change_during_fetch_discards_old_data_and_retries_new_place():
    now = 1_760_000_000.0
    ctrl = FakeCtrl()
    calls = []
    def fetch(*where):
        calls.append(where)
        if len(calls) == 1:
            ctrl.apply({"lat": 51.5, "lon": -0.1, "place": "London"})
        return fixture(int(now))
    w = Weather(ctrl, fetch=fetch, clock=lambda: now)
    w.tick()
    assert w.current() is None
    assert w.status()["place"] == "London"
    assert w.status()["refreshing"] is True
    assert w._wake.is_set()
    w.tick()
    assert calls == [(33.95, -84.55), (51.5, -0.1)]
    assert w.current()["temp"] == 21.4
    assert w.status()["refreshing"] is False


@pytest.mark.parametrize("lat,lon", [(None, 10), ("bad", 0), (float("nan"), 0),
                                      (0, float("inf")), (91, 0), (0, 181)])
def test_invalid_coordinates_never_reach_the_weather_provider(lat, lon):
    calls = []
    w = Weather(FakeCtrl(lat=lat, lon=lon), fetch=lambda *args: calls.append(args))
    w.tick()
    assert not calls
    assert w.status()["now"] is None
    assert w.status()["refreshing"] is False


@pytest.mark.parametrize("temperature,expected", [(22.5, 23), (23.5, 24), (-22.5, -23),
                                                 (-23.5, -24), (0.5, 1), (-0.5, -1)])
def test_wall_temperature_rounding_matches_swift(temperature, expected):
    assert WeatherFace._temp(temperature, "c") == expected


def test_clock_adjustment_never_reports_negative_forecast_age():
    now = [1_760_000_000.0]
    w = Weather(FakeCtrl(), fetch=lambda *a: fixture(int(now[0])), clock=lambda: now[0])
    w.tick()
    now[0] -= 30
    assert w.status()["age_s"] == 0


def test_status_never_attaches_old_weather_to_a_new_place_during_snapshot():
    class SwitchingCtrl(FakeCtrl):
        armed = False
        reads = 0

        def get(self):
            snapshot = super().get()
            if self.armed:
                self.reads += 1
                if self.reads == 1:
                    self.apply({"lat": 51.5, "lon": -0.1, "place": "London", "weather_units": "c"})
            return snapshot

    now = 1_760_000_000.0
    ctrl = SwitchingCtrl()
    weather = Weather(ctrl, fetch=lambda *args: fixture(int(now)), clock=lambda: now)
    weather.tick()
    ctrl.armed = True
    status = weather.status()
    assert ctrl.reads == 1
    assert status["place"] == "Marietta, Georgia"
    assert status["where"] == (33.95, -84.55)
    assert status["units"] == "f"
    assert status["now"]["temp"] == 21.4
    next_status = weather.status()
    assert next_status["place"] == "London"
    assert next_status["where"] == (51.5, -0.1)
    assert next_status["units"] == "c"
    assert next_status["now"] is None
    assert next_status["age_s"] is None and next_status["stale"] is False
