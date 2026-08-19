#!/usr/bin/env bash
# Start the display daemon for S1: 1 port, 1 chain, one 64x64 panel.
#   -d 64  : 64-bit BCM (the camera-flicker killer, with the 9600 Hz refresh)
#   -g 2.2 : decode our sRGB-encoded frames to linear for BCM
#   -t none: no tone mapping — album art should not be "enhanced"
#   -l 1.0 : temporal dither on
#   -b 160 : brightness cap 0-254; raise once PSU headroom is confirmed
set -euo pipefail
FIFO="${FRAME_FIFO:-/tmp/album-frame.fifo}"
[ -p "$FIFO" ] || mkfifo "$FIFO"
export FRAME_FIFO="$FIFO"
exec "$HOME/album-art-matrix/renderer/art_display" \
  -w 64 -h 64 -p 1 -c 1 -x 64 -y 64 \
  -d 64 -f 120 -g 2.2 -t none -l 1.0 -b 160
