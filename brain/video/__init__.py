"""Video on the wall: a link from the phone, the picture at 64 px on the
panel, the sound on the phone.

  youtube.py   turns a YouTube link into two stream URLs (picture, sound)
  ytdlp.py     the fallback for the ones YouTube will not hand over: yt-dlp
               fetches them itself, and hands back two files
  direct.py    any other link ffmpeg can read: an mp4, a webm, an HLS playlist
  player.py    fetches, decodes with ffmpeg off the main loop, keeps a window
               of frames, and answers "which frame is it now" on a clock the
               phone drives when it has the sound, the wall when it does not
"""
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class Media:
    """What a resolver hands the player."""
    title: str
    author: str
    duration_s: float
    video_url: str
    video_note: str                     # "144p avc1", for the app to show
    video_bytes: Optional[int] = None   # known size: small enough to keep whole
    local: bool = False                 # the urls are files on this machine already
    audio_url: Optional[str] = None     # None: no sound to give the phone
    audio_bytes: Optional[int] = None   # known size, for a progress figure
    audio_transcode: bool = False       # True: ffmpeg must make the m4a
    headers: dict = field(default_factory=dict)


class ResolveError(Exception):
    """A link the wall could not turn into streams, said in plain words."""
