"""Resolve quiet-room output without replacing the owner's selected face.

Away is an observation, not an Off command: it must never persist a different
face, dismiss a timer, or cancel a wake-up. Both automatic policies lift as
soon as their conditions end. Explicit Off is a separate, lasting choice.
"""
from dataclasses import dataclass
import math


@dataclass(frozen=True)
class RestDecision:
    mode: str
    brightness: float = 1.0
    idle: str | None = None
    away: bool = False


def resolve_rest(mode: str, *, idle: str, quiet_for: float | None,
                 away: str, presence_age: float | None, playing: bool,
                 waking: bool = False, sleeping: bool = False,
                 weather_available: bool = True) -> RestDecision:
    """Return the currently visible face and its quiet-room light multiplier.

    Presence ages are seconds since the app or music reporter last contacted
    the wall. An unknown age cannot establish absence. Timers and active light
    routines take precedence; choosing Off always does too.
    """
    if mode == "off" or mode == "timer" or waking or sleeping:
        return RestDecision(mode)
    if away == "off" and not playing and presence_age is not None \
            and math.isfinite(presence_age) and presence_age > 900:
        return RestDecision("off", away=True)
    if mode not in ("art", "cd") or quiet_for is None \
            or not math.isfinite(quiet_for) or quiet_for <= 60:
        return RestDecision(mode)
    if idle == "black":
        return RestDecision("off", idle="black")
    if idle == "dim":
        return RestDecision(mode, brightness=0.3, idle="dim")
    if idle == "ambient":
        return RestDecision("ambient", idle="ambient")
    if idle == "weather" and weather_available:
        return RestDecision("weather", idle="weather")
    # An unavailable weather service holds the sleeve, rather than displaying
    # an invented forecast or turning a quiet room black unexpectedly.
    return RestDecision(mode, idle="hold")
