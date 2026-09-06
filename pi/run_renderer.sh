#!/usr/bin/env bash
# Start the display daemon for S1: 1 port, 1 chain, one 64x64 panel.
#   -d 64  : 64-bit BCM (the camera-flicker killer, with the 9600 Hz refresh)
#   -g 2.2 : decode our sRGB-encoded frames to linear for BCM
#   -t none: no tone mapping — album art should not be "enhanced"
#   -l 1.0 : spatial dithering on. Turning it off, and halving the bit depth,
#            were tried against the last-row ghost; neither touched it and
#            both cost colour, so both are back where they were.
#   -b 160 : brightness cap 0-254; raise once PSU headroom is confirmed
set -euo pipefail
FIFO="${FRAME_FIFO:-/tmp/album-frame.fifo}"
[ -p "$FIFO" ] || mkfifo "$FIFO"
export FRAME_FIFO="$FIFO"
# Map-rate cap; must cover [animation] fps in config.toml (the brain produces
# at fps, this decides how many of those map). Set HERE so a tuned value has
# one home that survives reboots — the systemd unit runs this script.
MAPHZ="$(cat "$HOME/album-art-matrix/map-hz" 2>/dev/null || echo 60)"
case "$MAPHZ" in ''|*[!0-9]*) MAPHZ=60 ;; esac
export MAX_MAP_HZ="${MAX_MAP_HZ:-$MAPHZ}"
# The panel's own brightness cap, 1-254. The brain writes this file when the
# cap is changed from the phone and restarts the renderer, because the cap is
# a launch flag: there is no way to change it in a running panel.
BRIGHT="$(cat "$HOME/album-art-matrix/panel-brightness" 2>/dev/null || echo 160)"
case "$BRIGHT" in ''|*[!0-9]*) BRIGHT=160 ;; esac
[ "$BRIGHT" -ge 1 ] 2>/dev/null && [ "$BRIGHT" -le 254 ] 2>/dev/null || BRIGHT=160
# The panel's row addressing, 0-7. This board ghosts the content's colour into
# the last row of its scan, which is what a wrong addressing looks like, so it
# is worth sweeping. Written by the brain, same as the cap.
# Row-change settle in the library's scan loop (see the block below): the
# output stays off this long after every row address change. Dark time, so
# the cap above pays it back; tune with the file, 0 turns it off.
SETTLE="$(cat "$HOME/album-art-matrix/addr-settle-ns" 2>/dev/null || echo 1000)"
case "$SETTLE" in ''|*[!0-9]*) SETTLE=1000 ;; esac
export HUB75_ADDR_SETTLE_NS="$SETTLE"
# Spatial dithering strength, 0-10. It buys colour in dark areas by toggling
# the lowest bits, and at the very bottom of the range that shows as single
# LEDs of one colour in a field that should be grey — red first, because a
# red LED reaches current soonest in a drive window. A file, so it can be
# tuned against the panel without editing this script.
DITHER="$(cat "$HOME/album-art-matrix/dither" 2>/dev/null || echo 1.0)"
case "$DITHER" in ''|*[!0-9.]*) DITHER=1.0 ;; esac
# Bit depth, 4-64 in fours. Higher is more colour and a slower refresh.
DEPTH="$(cat "$HOME/album-art-matrix/bit-depth" 2>/dev/null || echo 64)"
case "$DEPTH" in ''|*[!0-9]*) DEPTH=64 ;; esac
# The panel's row addressing, 0-7. Written by the brain, same as the rest.
PTYPE="$(cat "$HOME/album-art-matrix/panel-type" 2>/dev/null || echo 0)"
case "$PTYPE" in ''|*[!0-9]*) PTYPE=0 ;; esac
exec "$HOME/album-art-matrix/renderer/art_display" \
  -w 64 -h 64 -p 1 -c 1 -x 64 -y 64 \
  -d "$DEPTH" -f 120 -g 2.2 -t none -l "$DITHER" -b "$BRIGHT" -P "$PTYPE"

# The last row. This panel used to ghost the content's own colour into the
# bottom row of its scan (a red clock left a red line there) on frames whose
# bottom rows were exactly zero. None of the flags here touch that: the cause
# was the library changing the row address with the output still enabled, and
# the fix is in its scan loop (pi/hub75-address-guard.py): the output held
# off while the row address settles, a microsecond by default, because the
# row just left keeps conducting the new row's data until its driver is off.
# The flags are the panel's original set and should stay that way.
