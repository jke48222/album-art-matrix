"""Explicit, bounded archive holds, independent of the current-song cache."""
from dataclasses import dataclass


@dataclass
class ReplayHold:
    active: bool = False
    track: str | None = None
    playing: bool = False
    until: float = 0

    def arm(self, now, tick: float):
        self.active = True
        self.track = now.track_id if now else None
        self.playing = bool(now and now.is_playing)
        self.until = tick + 600

    def release(self, now, tick: float, requested: bool = False) -> bool:
        if not self.active:
            return False
        playing = bool(now and now.is_playing)
        changed = bool(now and now.track_id != self.track)
        resumed = playing and not self.playing
        self.playing = playing
        if requested or changed or resumed or tick >= self.until:
            self.active = False
            return True
        return False
