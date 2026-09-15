"""Feature switches: one line in config.toml turns a whole feature off.

    [features]
    scrobble = true
    knock = false

Every feature asks its switch at the moment it would act, through
`features.on("knock")`, so flipping a line and restarting the brain is all
it takes to test one thing at a time, or to run two builds against the same
settings with the same things turned off. Nothing is gated by default: a
name this file has never heard of is on, because a switch is for turning a
finished thing off, not a hoop a feature has to remember to jump through.

GET /features lists every known switch with its state and a line about
what it switches, so the phone can show them without an app build.
"""
from __future__ import annotations

# name -> what it switches, in the order the roadmap builds them
KNOWN = [
    ("homekit", "the wall in the Home app: light, television, sensors"),
    ("scrobble", "records the ear names go to ListenBrainz"),
    ("knock", "two knocks on the frame, or a whistle, toggle the wall"),
    ("teach", "the wall's own song library, asked before Shazam"),
    ("ask", "a spoken question answered on the panel"),
    ("voice", "the wake word and speech on the Pi"),
    ("note", "a note left on the panel from a Shortcut"),
    ("airplay", "the wall as an AirPlay receiver"),
    ("shelf", "the Discogs collection, and the corner mark"),
    ("earworm", "name a song from the words you remember"),
    ("show", "show a cover or play a video by name"),
    ("imagine", "a picture from a description"),
    ("weather", "the weather faces"),
    ("posters", "posters for what the Mac watches"),
    ("games", "every game"),
]


class Features:
    def __init__(self, cfg: dict | None = None):
        table = (cfg or {}).get("features") or {}
        self._off = {name for name, v in table.items() if v is False}
        unknown = sorted(set(table) - {n for n, _ in KNOWN})
        if unknown:
            print(f"[features] config names switches nobody has: {unknown}", flush=True)

    def on(self, name: str) -> bool:
        return name not in self._off

    def public(self) -> dict:
        return {"features": [{"name": n, "on": self.on(n), "what": w} for n, w in KNOWN],
                "off": sorted(self._off)}
