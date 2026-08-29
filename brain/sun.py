"""Where the sun is, from latitude, longitude and the clock. Offline.

The NOAA solar-position approximation, good to a couple of minutes, which is
two orders of magnitude tighter than anyone's sense of dusk. Nothing here
asks the network anything: a wall should know when evening is even when the
router is in a box.
"""
import calendar
import math
import time


def sun_times(lat: float, lon: float, when: float | None = None):
    """(sunrise_epoch, sunset_epoch) for the given day, or the strings
    "polar_day" / "polar_night" when the sun does not cross the horizon."""
    t = time.gmtime(when or time.time())
    frac_year = 2 * math.pi / 365.0 * (
        t.tm_yday - 1 + (t.tm_hour - 12) / 24.0
    )

    eqtime = 229.18 * (0.000075
                       + 0.001868 * math.cos(frac_year)
                       - 0.032077 * math.sin(frac_year)
                       - 0.014615 * math.cos(2 * frac_year)
                       - 0.040849 * math.sin(2 * frac_year))
    decl = (0.006918
            - 0.399912 * math.cos(frac_year)
            + 0.070257 * math.sin(frac_year)
            - 0.006758 * math.cos(2 * frac_year)
            + 0.000907 * math.sin(2 * frac_year)
            - 0.002697 * math.cos(3 * frac_year)
            + 0.00148 * math.sin(3 * frac_year))

    lat_r = math.radians(lat)
    # 90.833 degrees: the sun's centre plus refraction, i.e. the moment the
    # top of it touches the horizon, which is what people mean by sunset.
    cos_ha = (math.cos(math.radians(90.833))
              / (math.cos(lat_r) * math.cos(decl))
              - math.tan(lat_r) * math.tan(decl))
    if cos_ha > 1:
        return "polar_night"
    if cos_ha < -1:
        return "polar_day"

    ha = math.degrees(math.acos(cos_ha))
    utc_midnight = calendar.timegm((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0))
    sunrise = utc_midnight + (720 - 4 * (lon + ha) - eqtime) * 60
    sunset = utc_midnight + (720 - 4 * (lon - ha) - eqtime) * 60
    return (sunrise, sunset)


def sun_factor(lat: float, lon: float, night_level: float,
               when: float | None = None) -> float:
    """1.0 in daylight, night_level after dark, a 40-minute ramp centred on
    each horizon crossing. Multiplied into the wall's brightness."""
    st = sun_times(lat, lon, when)
    if st == "polar_night":
        return night_level
    if st == "polar_day":
        return 1.0
    sunrise, sunset = st
    now = when or time.time()
    ramp = 40 * 60.0

    def smooth(x: float) -> float:
        x = max(0.0, min(1.0, x))
        return x * x * (3 - 2 * x)          # ease both ends of the dusk

    up = smooth((now - (sunrise - ramp / 2)) / ramp)
    down = smooth(((sunset + ramp / 2) - now) / ramp)
    day = min(up, down)
    return night_level + (1.0 - night_level) * day
