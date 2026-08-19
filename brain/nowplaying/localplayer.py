"""S3 stub: local player source (MPRIS/D-Bus via playerctl on Linux).

Note from research: macOS nowplaying-cli broke when Apple restricted the
private MediaRemote framework around macOS 15.4 [MED confidence] — verify
before depending on a macOS path.
"""
from . import NowPlayingSource


class LocalPlayerSource(NowPlayingSource):
    name = "localplayer"

    def get_current(self):
        return None  # not built yet (stage S3)
