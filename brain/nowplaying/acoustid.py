"""S3 stub: acoustic fingerprint source.

Line-in (or mic) -> Chromaprint -> AcoustID lookup -> MusicBrainz recording
-> Cover Art Archive (free, no auth, up to 1200x1200). Identifies whatever is
audible in the room — vinyl, CD, radio. No API can take it away.
"""
from . import NowPlayingSource


class AcoustIDSource(NowPlayingSource):
    name = "acoustid"

    def get_current(self):
        return None  # not built yet (stage S3)
