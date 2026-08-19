"""S3 stub: Last.fm scrobble source — cross-service fallback, still open and free."""
from . import NowPlayingSource


class LastFmSource(NowPlayingSource):
    name = "lastfm"

    def get_current(self):
        return None  # not built yet (stage S3)
