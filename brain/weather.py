"""The weather, from Open-Meteo, for the weather face.

No key: Open-Meteo is free for this. The wall asks every ten minutes for
the place the phone set (a name, geocoded once through Open-Meteo's own
geocoder into the latitude and longitude the sun code already keeps), and
keeps the last answer; after an hour without a fresh one the face shows a
small stale mark, and after a day it says it has no weather at all.

What the face needs, and what this keeps:

    now      temperature, feels-like, WMO weather code, day or night, wind,
             cloud cover, precipitation this hour
    day      today's high and low, sunrise and sunset
    hours    the next six hours: temperature and code each
    fetched  when, so the face can say how old it is

WMO codes are the standard's short list; SCENES maps every one of them to a
scene the face knows how to draw, with an intensity. Anything the standard
adds later lands on "overcast" rather than on an error.
"""
from __future__ import annotations

import threading
import time
import math

import requests

UA = "album-art-matrix/1.0 (github.com/jke48222/album-art-matrix)"
FORECAST = "https://api.open-meteo.com/v1/forecast"
GEOCODE = "https://geocoding-api.open-meteo.com/v1/search"
REFRESH_S = 600.0
STALE_S = 3600.0
DEAD_S = 86400.0
HOURS_AHEAD = 6

# WMO code -> (scene, intensity 0..1). Scenes the face draws:
# clear, mostly_clear, partly_cloudy, overcast, fog, drizzle, rain, freezing,
# snow, showers, thunder
SCENES = {
    0: ("clear", 0.0), 1: ("mostly_clear", 0.2), 2: ("partly_cloudy", 0.5), 3: ("overcast", 0.9),
    45: ("fog", 0.6), 48: ("fog", 0.9),
    51: ("drizzle", 0.3), 53: ("drizzle", 0.6), 55: ("drizzle", 0.9),
    56: ("freezing", 0.4), 57: ("freezing", 0.8),
    61: ("rain", 0.3), 63: ("rain", 0.6), 65: ("rain", 1.0),
    66: ("freezing", 0.5), 67: ("freezing", 1.0),
    71: ("snow", 0.3), 73: ("snow", 0.6), 75: ("snow", 1.0), 77: ("snow", 0.4),
    80: ("showers", 0.4), 81: ("showers", 0.7), 82: ("showers", 1.0),
    85: ("snow", 0.5), 86: ("snow", 0.9),
    95: ("thunder", 0.7), 96: ("thunder", 0.9), 99: ("thunder", 1.0),
}
ALL_CODES = sorted(SCENES)


def scene_for(code) -> tuple[str, float]:
    try:
        return SCENES[int(code)]
    except (KeyError, TypeError, ValueError):
        return ("overcast", 0.7)


def parse_forecast(data: dict, fetched: float | None = None) -> dict:
    """Open-Meteo's answer (unix times) into what the face keeps."""
    cur = data.get("current") or {}
    # A 200 response without usable current data must not replace a good cache.
    if not isinstance(cur, dict) or not any(cur.get(k) is not None for k in
                                           ("temperature_2m", "weather_code")):
        raise ValueError("the forecast is temporarily unavailable")
    daily = data.get("daily") or {}
    hourly = data.get("hourly") or {}
    fetched = time.time() if fetched is None else fetched
    now_t = int(cur.get("time") or fetched)
    times = hourly.get("time") or []
    temps = hourly.get("temperature_2m") or []
    codes = hourly.get("weather_code") or []
    days = hourly.get("is_day") or []
    hours = []
    for i, t in enumerate(times):
        if isinstance(t, (int, float)) and math.isfinite(t) and t > now_t and len(hours) < HOURS_AHEAD:
            hours.append({"t": int(t), "temp": temps[i] if i < len(temps) else None,
                          "code": codes[i] if i < len(codes) else None,
                          "is_day": bool(days[i]) if i < len(days) else True})
    def first(key):
        v = daily.get(key)
        return v[0] if isinstance(v, list) and v else None
    return {
        "temp": cur.get("temperature_2m"),
        "feels": cur.get("apparent_temperature"),
        "code": cur.get("weather_code"),
        "is_day": bool(cur.get("is_day", 1)),
        "wind_kmh": cur.get("wind_speed_10m"),
        "cloud": cur.get("cloud_cover"),
        "precip_mm": cur.get("precipitation"),
        "high": first("temperature_2m_max"),
        "low": first("temperature_2m_min"),
        "sunrise": first("sunrise"),
        "sunset": first("sunset"),
        "hours": hours,
        "fetched": fetched,
        "utc_offset_s": data.get("utc_offset_seconds", 0),
    }


def geocode(query: str) -> dict | None:
    """{name, region, country, lat, lon} for a place name, or None."""
    try:
        r = requests.get(GEOCODE, params={"name": query, "count": 5, "language": "en",
                                          "format": "json"},
                         headers={"User-Agent": UA}, timeout=10)
        r.raise_for_status()
        results = r.json().get("results") or []
    except (requests.RequestException, ValueError) as exc:
        print(f"[weather] geocode: {exc}", flush=True)
        return None
    if not results:
        return None
    for x in results:
        try:
            lat, lon = float(x["latitude"]), float(x["longitude"])
            if not math.isfinite(lat) or not math.isfinite(lon) or abs(lat) > 90 or abs(lon) > 180:
                continue
            return {"name": x.get("name") or query, "region": x.get("admin1") or "",
                    "country": x.get("country") or "", "lat": lat, "lon": lon}
        except (TypeError, KeyError, ValueError):
            continue
    return None


class Weather:
    """Keeps the forecast fresh for the wall's place, on its own thread."""

    def __init__(self, ctrl, fetch=None, clock=None):
        self.ctrl = ctrl
        self._fetch = fetch or self._http_fetch
        self._clock = clock or time.time
        self.data: dict | None = None
        self.problem: str | None = None
        self.place: str = ""
        self._for = None                 # (lat, lon) the data is for
        self._lock = threading.Lock()
        self._fetch_lock = threading.Lock()
        self._force = False
        self._fetching_for = None
        self._wake = threading.Event()
        self._thread = threading.Thread(target=self._loop, name="weather", daemon=True)

    def start(self) -> "Weather":
        self._thread.start()
        return self

    # ---- where -----------------------------------------------------------------------------
    def where(self) -> tuple[float, float] | None:
        return self._coordinates(self.ctrl.get())

    @staticmethod
    def _coordinates(s: dict) -> tuple[float, float] | None:
        try:
            lat, lon = float(s.get("lat", 999.0)), float(s.get("lon", 999.0))
        except (TypeError, ValueError):
            return None
        if not math.isfinite(lat) or not math.isfinite(lon) or abs(lat) > 90 or abs(lon) > 180 or (lat == 90.0 and lon == 180.0):
            return None                 # 999 is "never told"; 90/180 is the app's own "not set"
        return lat, lon

    def set_place(self, query: str) -> dict | None:
        found = geocode(query)
        if found is None:
            return None
        label = ", ".join(p for p in (found["name"], found["region"] or found["country"]) if p)
        self.ctrl.apply({"lat": found["lat"], "lon": found["lon"], "place": label[:64]})
        self.place = label
        with self._lock:
            self.problem = None
        self.refresh()
        return found

    def refresh(self):
        with self._lock:
            self._force = True
        self._wake.set()

    # ---- fetching ------------------------------------------------------------------------------
    def _http_fetch(self, lat: float, lon: float) -> dict:
        r = requests.get(FORECAST, params={
            "latitude": lat, "longitude": lon,
            "current": "temperature_2m,apparent_temperature,is_day,precipitation,weather_code,"
                       "cloud_cover,wind_speed_10m",
            "hourly": "temperature_2m,weather_code,is_day,precipitation",
            "daily": "temperature_2m_max,temperature_2m_min,sunrise,sunset",
            "timezone": "auto", "forecast_days": 2, "timeformat": "unixtime",
        }, headers={"User-Agent": UA}, timeout=15)
        r.raise_for_status()
        return r.json()

    def _loop(self):
        while True:
            # Clear before fetching so a place change during an HTTP request is
            # preserved and serviced immediately on the next iteration.
            self._wake.clear()
            try:
                self.tick()
            except Exception as exc:
                self.problem = f"{type(exc).__name__}: {str(exc)[:100]}"
                print(f"[weather] {self.problem}", flush=True)
            self._wake.wait(REFRESH_S)

    def tick(self):
        """One look: fetch when the place is known and the data is due."""
        if not self._fetch_lock.acquire(blocking=False):
            return
        try:
            self._tick()
        finally:
            self._fetch_lock.release()

    def _tick(self):
        where = self.where()
        if where is None:
            self.problem = "no place set"
            return
        with self._lock:
            due = (self._force or self.data is None or self._for != where
                   or self._clock() - self.data["fetched"] >= REFRESH_S - 5)
            self._force = False
        if not due:
            return
        with self._lock:
            self._fetching_for = where
        try:
            raw = self._fetch(*where)
            fresh = parse_forecast(raw, self._clock())
        except Exception as exc:
            if self.where() == where:
                self.problem = f"no weather: {str(exc)[:80]}"
            print(f"[weather] {self.problem}", flush=True)
            return
        finally:
            with self._lock:
                self._fetching_for = None
        if self.where() != where:
            self.refresh()
            return
        with self._lock:
            self.data = fresh
            self._for = where
            self.problem = None
        self.place = self.ctrl.get().get("place", "") or self.place
        d = self.data
        print(f"[weather] {self.place or where}: {d['temp']} C, code {d['code']}, "
              f"{'day' if d['is_day'] else 'night'}, wind {d['wind_kmh']} km/h", flush=True)

    # ---- for the face and the phone ------------------------------------------------------------
    def current(self) -> dict | None:
        with self._lock:
            d = self.data
            fetched_for = self._for
        if d is None or fetched_for != self.where():
            return None
        if self._clock() - d["fetched"] > DEAD_S:
            return None
        return d

    def stale(self) -> bool:
        d = self.current()
        return d is not None and self._clock() - d["fetched"] > STALE_S

    def status(self) -> dict:
        # Place, coordinates and units must come from the same control snapshot.
        # A location update may land at any point while this request is served.
        s = self.ctrl.get()
        where = self._coordinates(s)
        now = self._clock()
        with self._lock:
            d = self.data
            if d is None or self._for != where or now - d["fetched"] > DEAD_S:
                d = None
            else:
                d = dict(d)
            refreshing = where is not None and (self._force or self._fetching_for == where)
            problem = self.problem
        age = None if d is None else max(0, int(now - d["fetched"]))
        return {"place": s.get("place", ""), "where": where,
                "units": s.get("weather_units", "f"),
                "utc_offset_s": (None if d is None else d.get("utc_offset_s")),
                "age_s": age, "refreshing": refreshing,
                "stale": age is not None and age > STALE_S, "problem": problem,
                "now": (None if d is None else {k: d.get(k) for k in (
                    "temp", "feels", "code", "is_day", "wind_kmh", "cloud", "precip_mm",
                    "high", "low", "sunrise", "sunset")}),
                "scene": (None if d is None else scene_for(d["code"])[0]),
                "hours": (None if d is None else d["hours"])}
