#!/usr/bin/env bash
# yt-dlp on the wall: the fallback for videos YouTube will not hand over to
# the wall's own resolver (see VIDEO.md, "YouTube's token wall").
# Idempotent: run it again to update yt-dlp, which needs updating often.
#
#   ssh wall 'bash ~/album-art-matrix/pi/install-ytdlp.sh'
#
# No JavaScript runtime is installed. yt-dlp warns that YouTube extraction
# without one is deprecated, but the client it reaches these videos with
# needs no player script, and deno's 80 MB plus V8's appetite are a lot to
# put on a 1 GB board. If a video ever does need one, yt-dlp says so, the
# wall reports it, and installing deno is the next step:
#   curl -fsSL https://deno.land/install.sh | sh
set -euo pipefail

ROOT="$HOME/album-art-matrix"
VENV="$ROOT/.venv"
[ -x "$VENV/bin/pip" ] || { echo "no venv at $VENV — run pi/bootstrap.sh first"; exit 1; }

echo ">>> installing/updating yt-dlp in the brain's venv"
"$VENV/bin/pip" install -q --upgrade yt-dlp

echo ">>> version: $("$VENV/bin/yt-dlp" --version)"
echo ">>> ffmpeg:  $(ffmpeg -version | head -1 | cut -d' ' -f1-3)"

echo ">>> a video the wall's own resolver cannot get, through yt-dlp"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if "$VENV/bin/python" -c "
import sys
sys.path.insert(0, '$ROOT')
from brain.video import ytdlp
m = ytdlp.resolve('https://youtu.be/FyS5dAywkEo', '$TMP')
print(f'    {m.title!r}: {m.video_note}, picture {(m.video_bytes or 0)/1e6:.2f} MB, sound {(m.audio_bytes or 0)/1e6:.2f} MB')
"; then
  echo ">>> yt-dlp works. The brain uses it on its own when its own resolver is refused."
  echo ">>> restart the brain to pick it up:"
  echo "    pkill -9 -f '^$VENV/bin/python -m brain'"
else
  echo ">>> yt-dlp could not fetch the test video. The wall keeps working without it;"
  echo "    videos behind YouTube's token wall stay unplayable. See VIDEO.md."
  exit 1
fi
